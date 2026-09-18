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

## 5. Adding a language (done for real: TypeScript)

The recipe below replaces an earlier, hypothetical version of this section
— this is what actually adding TypeScript to `erl_ts` took, verified by
doing it. Two corrections to what was originally guessed here: there is
no `tree_sitter/typescript.h` to `#include` (the grammar just needs its
own `extern const TSLanguage *tree_sitter_typescript(void);` declaration,
same as the existing `tree_sitter_erlang` one), and this required editing
**two Makefiles**, not one — `tree-sitter-langs/Makefile` hard-codes
"erlang" throughout with no parametrization to hook into.

**0. Fork first — this can't be done as a git dependency.** `erl_ts` is
vendored at `_checkouts/erl_ts` (rebar3's real local-override mechanism —
see `docs/cli-erlang.md` §1.2's build notes and the note below on why a
plain git dependency doesn't work for this). Editing a dependency's own C
source isn't something a `{git, ...}`/`{pkg, ...}` dep spec can accommodate
at all.

1. Vendor the grammar: fetch
   [`tree-sitter/tree-sitter-typescript`](https://github.com/tree-sitter/tree-sitter-typescript)
   into `_checkouts/erl_ts/tree-sitter-langs/tree-sitter-typescript`
   (confirmed: MIT, plain C — `typescript/src/{parser.c,scanner.c}`, no
   C++; the repo actually holds two grammars, `typescript` and `tsx` —
   only `typescript` was used).
2. `c_src/erl_ts_nif.c` — add the `extern` declaration, a
   `tree_sitter_typescript_nif` function identical in shape to the
   existing `tree_sitter_erlang_nif`, and register it in the `nif_funcs[]`
   table (~10 lines total, exactly as small as this doc originally
   predicted).
3. `src/erl_ts.erl` — the Erlang side needs its own three additions,
   easy to miss: add `tree_sitter_typescript/0` to **both** the `-export`
   and `-nifs` attribute lists, and add the stub function
   (`tree_sitter_typescript() -> erlang:nif_error(nif_library_not_loaded).`)
   — the C change alone isn't enough; skipping this produces "Function
   not found erl_ts:tree_sitter_typescript/0" at load time.
4. `tree-sitter-langs/Makefile` — add a **parallel, separate** set of
   targets (`libtree-sitter-typescript.a`/`.$(SOEXT)`, own `SRC_DIR_TS`,
   own `LINKSHARED_TS` install name) alongside the existing erlang ones,
   rather than generalizing them — lower risk, doesn't touch what's
   already proven working. Add both new targets to `build:`'s dependency
   list.
5. `c_src/Makefile` — add `-l:libtree-sitter-typescript.a` /
   `-ltree-sitter-typescript` to `LDLIBS_TS_STATIC`/`LDLIBS_TS_DYNAMIC`
   alongside the existing erlang entries. No new `-I` include path was
   actually needed here — `erl_ts_nif.c` never `#include`s anything from
   a grammar's own directory, it only forward-declares the `extern`
   function, so the existing `TS_INCLUDE_DIR` (core `tree_sitter/api.h`)
   is enough.
6. Repoint the two/three `.dylib` install-name fixes (§6.1) to also cover
   `libtree-sitter-typescript.dylib` — same `@loader_path`-relative
   pattern, one more `-change` flag, one more file in the `cp`.

Once loaded, the language's own public query names
(`function_declaration`, `call_expression`, `member_expression` for
TypeScript vs. `function_clause`, `call`, `remote` for Erlang) are
completely different per grammar — found empirically the same way both
times: parse a tiny sample, print `node_string/1`, read the real node
names off the tree rather than guessing. See `src/ts_extract_typescript.erl`
and `src/ts_extract_erlang.erl` for the two query sets this produced, and
`src/ts_extract.erl` for the extension-based dispatcher that picks between
them.

## 6. Pitfalls

- **ABI pinning.** The `libtree-sitter` runtime and every grammar must share a
  compatible ABI version. Pin all submodules to known-good commits and bump
  the runtime + grammars together; a mismatch is a hard link/runtime failure,
  not a graceful error.
- **Don't call `erl_ts:init/0` yourself.** Confirmed by running it: `init/0`
  is invoked automatically as the module's `-on_load` hook the first time
  `erl_ts` is referenced. Calling it again explicitly (as the README's own
  usage example shows!) crashes the runtime with a boot-time `undef` for
  `erl_ts:init/0` that's confusing to debug — the module fails to reload
  cleanly. Just call `erl_ts:parser_new/0` etc. directly.
- **`query_capture/2` duplicates captures per pattern.** Confirmed
  empirically: a query with *N* named captures returns every match
  duplicated *N* times (a 2-capture query returns each match twice, a
  3-capture query three times). A query correlating a call site with its
  enclosing function in one pattern (e.g. `(function_clause name: (atom)
  @caller body: (clause_body (call expr: (atom) @callee)))`) cannot be
  trusted without deduplication logic. The robust workaround: query each
  capture independently (one query per node type you actually want), then
  attribute scope by walking `node_parent/1` up to the nearest enclosing
  node of the type you need, rather than relying on multi-capture
  correlation. Also dedupe by node byte-range (`node_start_byte/1` +
  `node_end_byte/1`) before rendering facts, regardless.
- **Scheduler threads.** A NIF holds its calling thread for the parse
  duration. Single-file parses are fast (tree-sitter is ~100s of MB/s), so
  this is usually a non-issue; for very large files consider `enif_thread_fork`
  or capping per-parse input size.
- **Nodes need the source.** `node_text/2` slices the source string by byte
  range, so the source must live as long as the tree.

### 6.1 macOS-specific build issues (confirmed on Apple Silicon, OTP 29)

`cfclavijo/erl_ts` is small (2 stars, 19 commits at the time of writing) and
has not been exercised on macOS. Three real, reproducible problems, found
while actually building it:

- **Static linking (the default) does not work on macOS.** `c_src/Makefile`
  links the final `.so` with raw `ld --exclude-libs ALL --start-group ...
  --end-group` and `-l:libtree-sitter.a` — all GNU-`ld`-only syntax. Apple's
  linker rejects it outright ("unknown options"). **Use
  `ERL_TS_LINKING=dynamic`** — it links through `cc` with ordinary `-l`
  flags, which does work. This is the opposite of the Makefile's own
  guidance (§6's old "static-link bloat" framing assumed static was viable
  everywhere; on macOS it currently isn't at all).
- **The dynamic build's install-name paths are wrong.** Even with
  `ERL_TS_LINKING=dynamic`, the built `.so` records `/usr/local/lib/libtree-sitter.0.25.dylib`
  (never installed there) and `/libtree-sitter-erlang.dylib` (a
  filesystem-root path — a build bug) as load-time dependencies, so
  `erlang:load_nif/2` fails with `on_load_failure` even though the build
  itself reports success. `DYLD_LIBRARY_PATH` does **not** rescue this —
  dyld doesn't fall back to it for a dependency recorded as an absolute
  path. The fix, added as our own project's `post_hooks` (not a fork of
  `erl_ts`): `install_name_tool` with **both** `-change` flags in a
  **single invocation**, repointing each to a short `@loader_path`-relative
  path. Two separate `install_name_tool` invocations (or a `;`-chained pair
  inside one rebar3 hook string) risk failing on the second change with
  "larger updated load commands do not fit" — Mach-O's header has limited
  padding to grow into, one combined invocation needs less of it than two
  sequential ones. See `rebar.config` in the project root for the exact
  hook.
- **The submodule-init pre_hook had a race condition** — `erl_ts`'s own
  `rebar.config` ran `git submodule update --init & make`, backgrounded
  (`&`) rather than sequenced (`&&`), so on a truly fresh git-clone of the
  dependency, `make` started before the submodule checkout finished and
  failed. **Superseded, not just worked around**: since §6.2 below, `erl_ts`
  is a permanent local fork at `_checkouts/erl_ts` rather than a git
  dependency re-fetched on every `rm -rf _build`, so its submodules (now
  plain vendored files, not live submodules at all) are simply always
  already present. This bullet is kept for the history — an `overrides`
  entry to fix the race in-place was tried first and made things worse
  (rebar3 stopped running the dependency's hooks at all), before vendoring
  turned out to sidestep the problem entirely.
- **NIFs cannot be shipped inside a `rebar3 escriptize` binary — this is
  why the project switched to `rebar3 release`.** `escript_incl_apps` only
  bundles `.beam`/`.app` files into the escript's zip archive, never
  `priv/`, and `erlang:load_nif/2` cannot `dlopen` a shared library from
  inside a zip at all. Embedding `erl_ts`'s `.beam` without its `.so`
  produces a module that looks loaded but crashes with `undefined
  function` the moment a NIF function is called — worse than not embedding
  it. A `rebar3 release` keeps `priv/` as real files on disk, which fixes
  this — see `docs/cli-erlang.md` §1.1/§1.2, including why relx's own
  generated start script isn't usable as the CLI entry point either (its
  `eval`/`escript` subcommands both require a node already running) and
  the small wrapper script that is.
- **A release doesn't preserve `erl_ts`'s vendored `tree-sitter`/
  `tree-sitter-langs` submodule checkouts** — only each app's
  `ebin`/`priv`/`include`. The install-name fix in `rebar.config` therefore
  copies both `.dylib` files into `erl_ts`'s own `priv/` (as siblings of
  `erl_ts.so`, referenced via `@loader_path`, not
  `@loader_path/../tree-sitter/...`) specifically so they travel with
  `priv/` wherever it's copied — plain `compile` or a full `release`.

### 6.2 `_checkouts` gotchas (all platforms, not macOS-specific)

Vendoring `erl_ts` (§5, step 0) as a real local fork uses rebar3's
`_checkouts/` mechanism. Three non-obvious things about it, all confirmed
by hitting them directly:

- **The directory must be named `_checkouts`, with a leading underscore**
  — not `checkouts`. Using the wrong name doesn't error; rebar3 silently
  compiles whatever's there (Erlang doesn't check remote-module calls at
  compile time, so this looks like success) but never puts it on any
  runtime code path, so every call into the vendored module fails
  `undef` at runtime, in every command (`compile`, `eunit`, a release) —
  a confusing, late, and misleading failure mode for an early naming typo.
- **`{path, Dir}` is not a real rebar3 dependency source** — it looks
  like it should be (git/hex deps are `{Name, {git, ...}}`/`{Name, "vsn"}`
  tuples, so `{Name, {path, Dir}}` reads as though it fits the pattern),
  but rebar3 has no such resource type; it fails with "Failed to fetch
  and copy dep" and no further detail. `_checkouts/` is the actual native
  mechanism for "use my local copy instead of fetching."
- **`_checkouts` *overrides* a `deps` entry — it does not replace needing
  one.** With `erl_ts` removed from `deps` entirely and only present under
  `_checkouts/erl_ts`, it compiled (again, no compile-time error) but
  `code:which(erl_ts)` returned `non_existing` in every context — `rebar3
  path`, `rebar3 eunit`, everything. Keeping a normal
  `{erl_ts, {git, "https://github.com/cfclavijo/erl_ts.git", ...}}` entry
  in `deps` fixed it immediately, even though that git source is never
  actually fetched from once `_checkouts/erl_ts` is present — the `deps`
  entry is what tells rebar3 "this is a real dependency, put it on the
  path"; `_checkouts` only decides *where the content comes from*.

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
- [`tree-sitter-markdown.md`](tree-sitter-markdown.md) — extending this same
  `erl_ts` approach to Markdown docs (a two-grammar case, §5's recipe
  specialized).
- [`nlp-tooling.md`](nlp-tooling.md) — the same NIF-over-a-C-library pattern
  applied to NLP libraries (`libstemmer_c`, CRFsuite, `llama.cpp`).
