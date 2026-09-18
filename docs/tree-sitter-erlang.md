# Design: Tree-sitter Extraction from Erlang (NIF)

This document covers how the symbolic-tools server parses source code — the
extraction step that produces the **facts** (function definitions, call
sites, positions) fed into the Prolog database. It is the Erlang counterpart
to the code-graph extraction in `readme.md` and the closure step in
[`erlang-mcp-design.md`](erlang-mcp-design.md).

**Recommendation up front:** call tree-sitter through a **NIF** that links
`libtree-sitter` plus the specific language grammars we need, and run it
**in-process on the BEAM**. There is working prior art —
[`cfclavijo/erl_ts`](https://github.com/cfclavijo/erl_ts) — that already wraps
essentially the whole tree-sitter C API as NIFs. Its only gap for us is that
it bundles just the **Erlang** grammar; we extend it to bundle TS/JS/Python/Go/Rust.

This is a design/research document only — no NIF is implemented here.

## 1. Why a NIF (and not a subprocess)

The whole point of [`erlang-mcp-design.md`](erlang-mcp-design.md) is to keep
everything in-process on the BEAM with no OS subprocess boundary. A port to
the `tree-sitter` CLI would reintroduce exactly that boundary (spawn per
parse, parse S-expression/JSON text back). The NIF keeps parsing in-process,
shares the parser with the rest of the node, and lets us drive tree-sitter's
query engine directly.

### The three realistic options

| Approach | Speed | Multi-language | Fits the BEAM design | Effort |
|---|---|---|---|---|
| **NIF** (link `libtree-sitter` + N grammars) | Fastest, in-process | add a grammar per language | ✅ | medium (C build) |
| **Port to `tree-sitter` CLI** (`open_port` / `os:cmd/1`) | subprocess overhead per parse | all languages, zero build | ❌ subprocess boundary | low |
| **WASM / JS host** | — | — | ❌ wrong runtime for an Erlang app | high, no payoff |

The CLI route is only worth using as a **prototype** (§7) to lock down the
per-language query strings before we commit to the NIF build.

## 2. Prior art: `cfclavijo/erl_ts`

[Erlang NIF to use tree-sitter](https://github.com/cfclavijo/erl_ts) — an OTP
library that implements NIFs for tree-sitter. Active (commits through 2026).

- **Scope.** Wraps the full C API as NIFs: `parser_*`, `tree_*`, `node_*`,
  `tree_cursor_*`, `query_*`, `query_cursor_*`, `language_*`,
  `lookahead_iterator_*`. That is everything the extraction layer needs.
- **Build.** rebar3; `tree-sitter` and each grammar are git submodules,
  compiled to C, and **statically linked into `erl_ts.so`**
  (`ERL_TS_LINKING=dynamic` opts into dynamic linking instead).
- **Handles are opaque Erlang references.** Parsers, trees, nodes, queries,
  and languages cross the boundary as `#Ref<...>` values; you call back in to
  read them.

### Usage shape (from the project's README)

```erlang
erl_ts:init(),                                   % load the NIF, once per node
{ok, Parser} = erl_ts:parser_new(),
{ok, Lang}   = erl_ts:tree_sitter_erlang(),      % a TSLanguage* as a ref
true = erl_ts:parser_set_language(Parser, Lang),
Tree = erl_ts:parser_parse_string(Parser, Src),
Root = erl_ts:tree_root_node(Tree),

{ok, Q, _}  = erl_ts:query_new(Lang,
                  "(function_clause name: (atom) @name)"),
Caps        = erl_ts:query_capture(Root, Q),     % [{"name", NodeRef}, ...]
[erl_ts:node_text(N, Src) || {_, N} <- Caps].    % pull only what you need
```

`node_text/2` needs the source string because nodes are (start_byte,
end_byte) spans, not owned text — so keep the source around for the life of
the tree.

### The gap we must fill

Only `tree_sitter_erlang/0` exists. Each tree-sitter grammar exports a single
C entry point, `const TSLanguage *tree_sitter_<name>(void)`; exposing a new
language is (a) add the grammar submodule, (b) add a `tree_sitter_<name>/0`
NIF that returns it, (c) link its compiled lib into the `.so`. See §5.

## 3. What tree-sitter gives us — and what it doesn't

Tree-sitter produces a concrete syntax tree per file. From it we extract
**facts**, per language, via queries:

- function / method / callback **definitions** (name, arity-ish shape, span)
- **call sites** (callee name/text, span, argument spans)
- import / export / module statements (for the resolution step)
- enclosing scope chain (so a call can be attributed to its defining function)

What tree-sitter does **not** give us: which definition a call binds to,
cross-file resolution, or the transitive call graph. That reasoning stays in
Erlang/Prolog — consistent with [`erlang-mcp-design.md`](erlang-mcp-design.md)
§5 ("Compute closure in Erlang, not Prolog"). The split is:

```
tree-sitter (NIF)  -->  facts: defs, calls, imports, spans  (per file)
Erlang            -->  resolution + graph + closure          (cross file)
erlog / Prolog    -->  relational queries over the graph     (the MCP tools)
```

## 4. Recommended design

1. **Vendor (or fork) `erl_ts`** as the extraction dependency. We inherit the
   full API surface and the build system; we only add language entry points.
   If we outgrow it, the code is a single ~85 KB C file plus a rebar app, so
   forking is cheap.

2. **Bundle only the languages we parse** (the `chiasmus_map`/`graph` set:
   TypeScript, JavaScript, Python, Go, Rust, …). Each is one grammar
   submodule + one 3-line NIF + a link flag. Keep the count deliberate —
   statically linking many grammars into one `.so` bloats build time and the
   artifact.

3. **Extract with queries, not full-tree marshalling.** Per language, define
   a query for definitions and one for call sites. Return compact
   `{name, start, end, [arg_spans]}` lists across the NIF boundary — do **not**
   ship the whole tree as Erlang terms. This keeps the boundary cheap and the
   hot loop (parse → extract → emit facts) tight.

4. **Parser pool, not a shared parser.** A `TSParser` instance is not safe to
   drive from multiple NIF threads at once. Mirror the `prolog_session_sup`
   pattern from `erlang-mcp-design.md`: a small supervised pool of `parser`
   gen_servers (one per language); a worker checks a parser out, parses a
   file, returns it. 4–8 parsers is plenty for a "walk a folder" batch.

5. **Manage lifetimes.** Call `tree_delete/1`, `parser_delete/1`,
   `query_delete/1` when done. Reuse one parser across a directory; delete
   each tree once its facts are extracted. Leaking trees is the main
   correctness hazard in a long-running server.

## 5. Adding a language (concretely)

Taking `erl_ts` as the base and adding **TypeScript** as the example:

1. `git submodule add https://github.com/tree-sitter/tree-sitter-typescript
   tree-sitter-langs/tree-sitter-typescript` (pin a tag).
2. Build it in `c_src/Makefile` alongside `libtree-sitter` and add its
   object/lib to the final link line for `erl_ts.so`.
3. Expose the language in the NIF (`c_src/erl_ts_nif.c`):

   ```c
   #include "tree_sitter/typescript.h"

   static ERL_NIF_TERM tree_sitter_typescript(ErlNifEnv *env,
                                              int argc,
                                              const ERL_NIF_TERM *argv) {
     (void)argc; (void)argv;
     return enif_make_resource(env, wrap_language(tree_sitter_typescript()));
   }
   ```

4. Register it in the `ErlNifFunc` table, add the Erlang stub + `-nifs` entry,
   and on the Erlang side:

   ```erlang
   {ok, Ts} = erl_ts:tree_sitter_typescript(),
   erl_ts:parser_set_language(Parser, Ts).
   ```

Repeat per language. The grammar's public query names (e.g.
`function_declaration`, `call_expression`) differ per language and per grammar
version — pin grammar tags and keep the per-language query files in the repo
so a grammar bump is a deliberate, tested change.

## 6. Pitfalls

- **ABI pinning.** The `libtree-sitter` runtime and every grammar must share a
  compatible ABI version. Pin all submodules to known-good commits and bump
  the runtime + grammars together; a mismatch is a hard link/runtime failure,
  not a graceful error.
- **NIF loads once.** `init()` loads `erl_ts.so`; it cannot be hot-reloaded.
  Fine for a server, but you cannot swap grammars at runtime.
- **Scheduler threads.** A NIF holds its calling thread for the parse
  duration. Single-file parses are fast (tree-sitter is ~100s of MB/s), so
  this is usually a non-issue; for very large files consider `enif_thread_fork`
  or capping per-parse input size.
- **Static-link bloat.** Past a handful of grammars, consider dynamic linking
  (`ERL_TS_LINKING=dynamic`) and shipping the `libtree-sitter-*.so` files.
- **Nodes need the source.** `node_text/2` slices the source string by byte
  range, so the source must live as long as the tree.

## 7. Suggested path

1. **Prototype against the `tree-sitter` CLI** (fast, no build): run
   `tree-sitter parse` on samples per language and write the exact
   definition/call-site query strings. This de-risks the per-language queries
   — the fiddliest part — before any C is involved.
2. **Bring in `erl_ts`**, add the target grammars, and run the same queries
   through `query_new/2` + `query_capture/2`.
3. **Wrap it in a parser-pool module** that emits the Prolog facts, feeding
   the extraction half of the pipeline in §3.

## References

- [`cfclavijo/erl_ts`](https://github.com/cfclavijo/erl_ts) — Erlang NIF for
  tree-sitter (prior art / base).
- [`tree-sitter`](https://github.com/tree-sitter/tree-sitter) — runtime + C
  API (`lib/include/tree_sitter/api.h`).
- [`erlang-mcp-design.md`](erlang-mcp-design.md) — the in-process BEAM design
  this plugs into.
- [`readme.md`](../readme.md) — the four-tool contract.
