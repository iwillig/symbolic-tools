# Design: Tree-sitter Extraction from Erlang (NIF)

This document covers how the symbolic-tools server parses source code — the
extraction step that produces the **facts** (function definitions, call
sites, positions) fed into the Prolog database. It is the Erlang counterpart
to the code-graph extraction in `readme.md` and the closure step in
[`erlang-mcp-design.md`](erlang-mcp-design.md).

**Status: implemented.** `symbolic_ts` (`native/symbolic_ts`, a
[Rustler](https://github.com/rustler-lang/rustler) crate, + the thin
`src/symbolic_ts.erl` wrapper) is a small, purpose-built NIF wrapping
exactly the ~25 tree-sitter functions this project actually calls — not a
general-purpose binding. History: it started as a vendored fork of the
third-party [`cfclavijo/erl_ts`](https://github.com/cfclavijo/erl_ts)
binding; was inlined as a purpose-built C NIF
(`c_src/symbolic_ts_nif.c`, gone now but visible in git history) once the
fork turned out to actively block packaging; and was then ported to Rust,
because the two crashes the C NIF's own comments documented — a
tree-freeing use-after-free the C side could only paper over with a
deliberate one-tree-per-parse leak, and a null-node deref that SIGSEGV'd
the whole VM — are exactly the failure classes Rust's ownership model
encodes structurally (see §2.1). The C→Rust port was gated on a fact
parity check (`scripts/parity_check.sh`): byte-identical fact output
over this repo's own `src/`, `docs/`, and `test/fixtures/` before and
after. The erl_ts fork had been vendored and hand-patched all session
to add TypeScript and Markdown grammar support directly in its C
source — but keeping that fork untracked in git (to keep it out of this
repo) turned out to actively block packaging: a fresh `git clone` had no
fork to build against, so a plain `rebar3 release` would try to fetch
the *unmodified* upstream and silently produce a broken build. Since
this project only ever called a small fraction of what `erl_ts` exposed,
inlining just that fraction — owned and tracked here, no external
dependency at all — solved that outright, and the Rust port then solved
what the C version itself couldn't (§2.1, §6).

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

## 2. What we inlined, and why

`symbolic_ts` wraps exactly the functions `src/ts_extract_{erlang,
typescript,markdown}.erl` call — 18 called directly, plus 2 more
(`node_start_byte/1`, `node_end_byte/1`) needed to implement `node_text/2`
(which, like in `erl_ts`, is plain Erlang — slicing a source string by
byte range — not a NIF itself), plus the 3 `tree_sitter_<lang>/0`
language loaders. Every function was ported by reading `erl_ts`'s own
real C implementation directly, not guessed from its header comments.

- **Scope, deliberately narrow.** No `tree_cursor_*`, no
  `lookahead_iterator_*`, no `query_cursor_*` exposed to Erlang at all —
  `query_capture/2` creates and destroys its own `TSQueryCursor`
  internally, the same as `erl_ts`'s version did, so Erlang never needs
  to hold one. Only 5 resource types exist: `TSLanguage`, `TSParser`,
  `TSTree`, `TSQuery`, `TSNode`.
- **Build.** Cargo, driven by `scripts/build_nif.sh` through rebar3's
  compile `pre_hooks` (`rebar.config`) — so every `rebar3 compile`,
  `eunit`, `shell`, and `release` picks up a freshly built NIF before
  any beam loads it. The crate compiles the *same* vendored tree-sitter
  runtime (`c_src/tree-sitter/`) and grammars
  (`c_src/grammars/<name>/`) the old `pc`-plugin build did, via the `cc`
  crate (`native/symbolic_ts/build.rs`) — not crates.io grammar
  crates: the vendored grammars are a mix of ABI 14 and 15, several are
  revision-pinned behind what's published, and the extracted fact
  shapes depend on the grammars' node types, so the parity gate depends
  on zero grammar drift. `native/symbolic_ts/src/lib.rs` is the whole
  NIF; `src/ffi.rs` is its `#[repr(C)]` mirror of tree-sitter's `api.h`.
- **Rust ownership is the point, not a style choice** — four things the
  C NIF couldn't express, now structural:
  1. Every `NodeRes` pins a `ResourceArc<TreeRes>` of its tree, so
     `TreeRes`'s `Drop` really calls `ts_tree_delete` — the leak that
     §6 documents from the C era is gone, with a regression test that
     measures RSS (measured directly: the C NIF grew ~1 GB over the
     test's window; the Rust NIF a few MB).
  2. Null nodes are guarded in one place (`null_guard/2`) — every
     accessor returns `undefined` for a null *input* node, the contract
     `test/symbolic_ts_tests.erl` pins.
  3. `parser_parse_string/2` and `query_capture/2` are scheduled
     `DirtyCpu`, off the normal schedulers the whole VM shares.
  4. Source input is a real UTF-8 binary handed to tree-sitter as raw
     bytes; the C NIF decoded Erlang char lists via `enif_get_string`
     with `ERL_NIF_LATIN1`, silently truncating codepoints > 255 and
     desynchronizing every byte offset from the actual file — for
     non-Latin-1 sources, `node_text/2` sliced the wrong bytes.
- **Handles are opaque Erlang resources**, same as before: parsers,
  trees, nodes, queries, and languages cross the boundary as
  `#Ref<...>`-backed resource terms; you call back in to read them.

### Usage shape

```erlang
{ok, Parser} = symbolic_ts:parser_new(),
{ok, Lang}   = symbolic_ts:tree_sitter_erlang(),
true = symbolic_ts:parser_set_language(Parser, Lang),
Tree = symbolic_ts:parser_parse_string(Parser, Src),  % Src: a binary
Root = symbolic_ts:tree_root_node(Tree),

{Q, _, _} = symbolic_ts:query_new(Lang,
                <<"(function_clause name: (atom) @name)">>),
Caps      = symbolic_ts:query_capture(Root, Q),   % [{"name", NodeRef}, ...]
[symbolic_ts:node_text(N, Src) || {_, N} <- Caps].
```

`Src` and the query string are **binaries** — the NIF hands their raw
bytes to tree-sitter (a char list used to be accepted, and silently
mangled; see §2.1's point 4). `node_text/2` needs the source because
nodes are (start_byte, end_byte) spans, not owned text — so keep the
source around for the life of the tree. Capture names and `node_type/1`
still come back as char lists, matching the original C NIF's return
shapes.

## 3. What tree-sitter gives us — and what it doesn't

Tree-sitter produces a concrete syntax tree per file. From it we extract
**facts**, per language, via queries — see `src/ts_extract_erlang.erl`,
`src/ts_extract_typescript.erl`, `src/ts_extract_markdown.erl` for the
real query sets, and `src/ts_extract.erl` for the extension-based
dispatcher that picks between them.

What tree-sitter does **not** give us: which definition a call binds to,
cross-file resolution, or the transitive call graph. That reasoning stays in
Erlang/Prolog — consistent with [`erlang-mcp-design.md`](erlang-mcp-design.md)
§5 ("Compute closure in Erlang, not Prolog"). The split is:

```
tree-sitter (NIF)  -->  facts: defs, calls, imports, spans  (per file)
Erlang            -->  resolution + graph + closure          (cross file)
erlog / Prolog    -->  relational queries over the graph     (the MCP tools)
```

## 4. Design notes

- **Extract with queries, not full-tree marshalling.** Per language, a
  query for definitions and one for call sites, returning only the
  compact fact tuples each extractor module needs — never the whole tree
  as Erlang terms. Keeps the NIF boundary cheap and the hot loop (parse
  → extract → emit facts) tight.
- **Bundle only the languages we parse.** Each is one grammar directory
  under `c_src/grammars/<name>/`, one `tree_sitter_<name>/0` NIF entry,
  and one entry in `native/symbolic_ts/build.rs`'s `GRAMMARS` list. Keep
  the count deliberate.
- **Manage lifetimes — but know what actually holds what.** `TSNode`
  holds a raw, unretained pointer into the `TSTree` it came from, with no
  reference counting of its own — the tree-sitter C API's documented
  contract is that the caller keeps the tree alive as long as any node
  from it is in use. Erlang's GC has no built-in way to know a `Node`
  resource term depends on a `Tree` resource term staying alive. See §6
  for the real bug this caused.
- **Parser pool, not a shared parser**, for a long-running server (the
  MCP session work) — a `TSParser` instance isn't safe to drive from
  multiple NIF threads at once. Not needed yet for the one-shot CLI
  (`parse`/`query`), which never shares a parser across concurrent
  callers.

## 5. Adding a language

1. Vendor the grammar's plain-C source only — `src/{parser.c,scanner.c}`
   and its own `src/tree_sitter/*.h` — into
   `c_src/grammars/<name>/{parser.c,scanner.c,tree_sitter/*.h}`. Skip
   `grammar.json`/`node-types.json`/bindings/tests; none of that is
   needed to compile. Confirm the grammar's license (MIT for all three
   in use today) and that it's plain C, not C++, before vendoring.
2. `native/symbolic_ts/src/ffi.rs` — add the `extern "C"` declaration
   `pub fn tree_sitter_<name>() -> *const TSLanguage;` alongside the
   existing ones (it binds the grammar's own real C symbol).
3. `native/symbolic_ts/src/lib.rs` — add a `#[rustler::nif]` loader
   (`tree_sitter_<name>`, identical in shape to the existing ones, with
   an `unable_to_create_language_<name>` atom in the `atoms!` block),
   then a matching `tree_sitter_<name>/0` stub to `src/symbolic_ts.erl`'s
   `-export` and stub-function list (`erlang:nif_error(nif_not_loaded)`)
   — the Rust change alone isn't enough; skipping the Erlang side
   produces "function not found" at load time.
4. `native/symbolic_ts/build.rs` — add `"<name>"` to the `GRAMMARS`
   list. If the grammar's `scanner.c` needs a shared header from its
   own upstream repo (TypeScript's does — `common/scanner.h`, shared
   between its `typescript` and `tsx` grammars), vendor that too and
   add its directory as a `build.include(...)` in the same script.

Once loaded, the language's own public query names
(`function_declaration`, `call_expression`, `member_expression` for
TypeScript vs. `function_clause`, `call`, `remote` for Erlang, vs.
`atx_heading`, `fenced_code_block` for Markdown) are completely different
per grammar — found empirically the same way every time: parse a tiny
sample, print `node_string/1`, read the real node names off the tree
rather than guessing.

### 5.1 Data formats aren't code (done for real: TOML, JSON)

TOML and JSON have no functions or call sites — `defines`/`calls` don't
apply at all. `src/ts_extract_toml.erl`/`src/ts_extract_json.erl`
instead emit `config_value(File, Path, Value, Line)` and
`config_section(File, Path, Line)`, `Path` a dotted key path built by
real recursive descent (`node_named_child/2`/`node_named_child_count/1`)
— every prior extractor gets away with flat queries plus a limited
`node_parent/1` walk; a multi-level dotted path has no query-only
equivalent. Both formats share these two predicate names on purpose
("does this key path resolve to a value" is the same question whether
the file is a `Cargo.toml` or a `package.json`) but share no code —
TOML's `pair` is positional (no field names at all: first named child
is the key part, second is the value), JSON's has real `key`/`value`
fields. Arrays are deliberately captured as one opaque leaf (their own
raw text), not walked element-by-element, in both — a real, documented
scope limit, not a missing case; see each module's own header comment
for what else was confirmed empirically (TOML's `[[array]]`-of-tables
sharing one `Path` across instances, JSON's `string_content` unwrap
child, etc.).

One new, real build gotcha found adding TOML specifically: its
`parser.c`/`scanner.c` `#include <tree_sitter/parser.h>` with **angle
brackets**, unlike every other vendored grammar's `#include
"tree_sitter/parser.h"` (quotes). Angle-bracket includes search *only*
the compiler's `-I` list, in order — with every grammar's directory on
that same list (needed so each grammar's sources find their own local
header), TOML's parser.c picked up **Erlang's** `tree_sitter/parser.h`
instead of its own (whichever `-I` entry happens to come first),
because a different macro shape between tree-sitter-cli generator
versions. Quote-includes search the including file's own directory
first, ignoring `-I` order entirely — the fix was patching TOML's two
vendored files to use quotes, matching the convention every other
grammar here already happened to use.

**YAML was investigated and deliberately not added.**
`ikatyang/tree-sitter-yaml`'s scanner is genuine C++ (`scanner.cc`,
using `std::vector`/namespaces, itself including a second C++ file,
`schema.generated.cc`) — not just a `.cc` extension on otherwise-C code.
Every scanner-using grammar needs its external scanner for correct
tokenization, so this isn't optional to skip. This project's whole build (the `cc`-compiled C in
`native/symbolic_ts/build.rs`) is pure C with no C++ toolchain wired in
at all — adding YAML for real means wiring one in first (real, separate
scope), not something to force through by fighting the build. Its grammar is also
structurally the most complex of the three by a wide margin even
setting that aside: anchors, aliases, and tags are first-class node
types that can wrap a value in place of a plain scalar, so a "get the
value" extraction has to handle all three cases, not just leaf scalars.

### 5.2 Back to code (done for real: Bash)

Unlike TOML/JSON, Bash has real functions and call sites, so it reuses
the exact `defines`/`calls`/`comment`/`doc` shape §5.1 contrasted itself
against — `src/ts_extract_bash.erl` is close to a line-for-line mirror
of `ts_extract_erlang.erl`. One real difference: `calls/5` only ever
produces `local(Command, ArgCount)`, never `remote`/`member` the way
Erlang/TypeScript can — Bash has no qualified-call syntax
(`mod:fun()`, `obj.method()`) to distinguish a call to a function
defined in the same script from a call to an external program or a
builtin, so this project doesn't invent a distinction the language
itself doesn't make. Confirmed empirically, not assumed: a `command`
node's own callee name is a `command_name` field (queryable directly,
no unwrapping needed), and `function_definition`/`comment` nodes are
siblings of each other and of top-level `command`s the same way
Erlang's `function_clause`/`comment` are — the same `node_parent/1`
caller-attribution walk and `node_next_sibling/1`/`node_prev_sibling/1`
doc-comment-run walk already built for Erlang/TypeScript apply
unchanged. Also wired into `ts_extract_markdown.erl`'s
`example_defines`/`example_calls` re-extraction (§4/`readme.md`'s
"Catching stale doc examples") for `sh`/`bash`-tagged fenced blocks,
alongside the languages already there.

### 5.3 A grammar over a substring, not a file (done for real: JSDoc)

Every case in §5/§5.1/§5.2 vendors a grammar for a real *file type* —
`ts_extract.erl`'s extension dispatcher picks it by suffix. JSDoc has no
file extension of its own: `/** ... */` only ever occurs embedded inside
a `.ts`/`.js` comment. `tree-sitter-jsdoc` (`c_src/grammars/jsdoc/`) is
vendored and wired in exactly per steps 1–4 above — same `parser.c` +
`scanner.c` (its scanner is real: one external token, `TYPE_TOKEN`,
scanning to a balanced `}` for a tag's `{Type}` — confirmed by reading
it, not assumed from its small size) — but there's no fifth "dispatch by
extension" step. Instead `src/ts_extract_jsdoc.erl` is called directly
from `ts_extract_typescript.erl`'s `docs/4`, once per `doc/5` comment,
the same "re-parse a substring through another extractor" shape
`ts_extract_markdown.erl` already uses for fenced code blocks
(`example_defines/5`/`example_calls/5`) — just with a grammar dedicated
to the substring's own syntax instead of reusing a whole-file one.

Two things only matter because the substring being parsed is a comment,
not a file:

- **The grammar requires its own delimiters.** `tree-sitter-jsdoc`'s
  `document` rule is `seq($._begin, optional($.description),
  repeat($.tag), $._end)` where `_begin`/`_end` are literally `/` +
  `repeat('*')` and `/` — so it must be fed the *raw*, unmodified comment
  text (`/**` through `*/` inclusive), never `clean_join`'s flattened,
  delimiter-stripped `doc/5` `Text`. The caller pre-filters on exactly
  that: only a single comment node (not a `//`-run) whose raw text
  starts with `/**` is worth trying at all.
- **Line numbers need an offset.** Parsed in isolation, a tag's own
  `node_start_point/1` row is relative to the start of the comment
  *string*, not the file. `doc_tag/8`'s `Line` is the comment's own real
  file line (the same one `line/1` computes for `doc/5`'s attribution
  walk) plus that row — confirmed empirically, not assumed, with a
  regression test asserting a tag on a doc comment's 3rd real line comes
  back at the right absolute line number
  (`ts_extract_jsdoc_tests:tag_line_is_offset_from_start_line_test`).

See `docs/prolog-schema.md`'s `doc_tag/8` entry for the fact shape
itself, and `.symbolic/rules.pl`'s `param_doc/6`/`missing_return_doc/3`
for what it's used for.

## 6. Pitfalls

- **ABI pinning.** The `libtree-sitter` runtime and every grammar must share a
  compatible ABI version. Pin all vendored sources to known-good versions and
  bump the runtime + grammars together; a mismatch is a hard link/runtime failure,
  not a graceful error.
- **Linux needs `_DEFAULT_SOURCE`/`_POSIX_C_SOURCE`, or the NIF builds
  fine and fails to *load*.** Confirmed by a real CI failure on
  `ubuntu-latest`, not caught locally (this project is developed on
  macOS): the vendored `c_src/tree-sitter/src/unicode.h` always
  includes its own `portable/endian.h`, which on Linux just falls
  through to glibc's real `<endian.h>` — but glibc only *declares*
  `le16toh`/`be16toh`/etc. under one of those feature-test macros.
  Without them, the compiler accepts an implicit external declaration
  (a warning, not a build error, since a NIF `.so` resolves symbols
  lazily), and no such symbol exists anywhere at runtime to satisfy it
  — so it fails at `erlang:load_nif/2` with "undefined symbol:
  le16toh", not at compile time. `native/symbolic_ts/build.rs`'s `cc`
  invocation sets both flags, matching what upstream tree-sitter's own
  Makefile always did (lost when this project's build moved onto the
  `pc` plugin instead of that Makefile, and preserved through the
  Rust port — the same flags, verified by a real CI failure first).
- **Don't call `symbolic_ts:init/0` yourself.** It's the module's
  `-on_load` hook, invoked automatically the first time `symbolic_ts` is
  referenced. Calling it again crashes the runtime with a boot-time
  `undef` that's confusing to debug. Just call `symbolic_ts:parser_new/0`
  etc. directly.
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
  correlation. Also dedupe (`lists:usort/1` over the whole fact list)
  before rendering facts, regardless.
- **`TSTree` lifetime — the C-era trap, now fixed structurally.**
  Confirmed the hard way in the C NIF era: giving the `TSTree` resource
  a real `free` callback (`ts_tree_delete`) reproduced as a consistent
  SIGSEGV in `ts_extract_markdown:file/1` — its `Tree` variable is only
  used once, to compute `Root`, so the BEAM compiler's liveness analysis
  lets the GC collect the `Tree` resource term well before the function
  finishes using nodes derived from it. `TSNode` holds a raw, unretained
  pointer into its tree; the C NIF therefore deliberately leaked every
  tree (no-op `free_tree`), which was safe but grew a long-running MCP
  session monotonically. The Rust NIF fixes the actual lifetime, not
  the symptom: every `NodeRes` pins a `ResourceArc<TreeRes>` of its
  tree, so `TreeRes`'s `Drop` really calls `ts_tree_delete` — and can
  only run once no node resource referencing that tree remains.
  `test/symbolic_ts_tests.erl`'s
  `tree_per_parse_does_not_leak_test_` pins it by measuring OS-level
  RSS (measured against the retired C NIF: ~1 GB of growth over the
  test's window vs a few MB; note `erlang:memory/1` cannot see this
  leak at all, since tree-sitter allocates via libc `malloc`).
- **Scheduler threads.** `parser_parse_string/2` and `query_capture/2`
  do unbounded CPU work, so the Rust NIF registers them as DirtyCpu
  NIFs — they run on dirty schedulers and never block a normal one.
  (The C NIF ran them as ordinary NIFs, violating the ~1 ms
  normal-NIF budget on every large parse.) Every other NIF in the
  binding is a trivial accessor and stays normal-scheduled.
- **A tree-sitter query selects by node *type*, and this grammar reuses
  the code node types inside attributes.** Verified by dumping the parse
  tree: `-spec f(file:filename())` puts a `remote` under
  `call <- expr_args <- type_sig <- spec`, and `-type t() ::
  list(integer())` puts `list` and `integer` under plain `call` nodes —
  byte-for-byte the same shapes `(call expr: (remote) @call)` and
  `(call expr: (atom) @callee)` match real call sites on. So a
  calls-extracting query over-matches every type reference in every
  `-spec`/`-callback`/`-type` in the file (25 sites across 12 of this
  repo's own 19 `.erl` files), and the only tell is that the
  `node_parent/1` walk-up finds no `function_clause` above them.
  `ts_extract_erlang`'s `call_site/2` drops exactly those. The general
  rule for a new language: decide what a fact *means* before trusting a
  query's node type, and check what an attribute body parses as.
- **The same grammar keeps `-export` lists in nodes no call query sees —
  which is a fact worth extracting, not noise.** `export_attribute` holds
  one `fa` child per entry, each `fa` positional (`atom`, then `arity`
  wrapping an `integer`) with no addressable fields, so reading it is a
  `node_named_child/2` walk. Those become `export/4` facts — without them
  an exported function or an OTP behaviour callback is indistinguishable
  from dead code in a per-directory parse, because its caller is a test,
  another module, or the BEAM. Note `-export_type([...])` is a *different*
  node (`export_type_attribute`): it names types, not functions.
- **Nodes need the source.** `node_text/2` slices the source string by byte
  range, so the source must live as long as the tree.
- **Sibling navigation returns `undefined`, not a null resource.**
  `node_parent/1` returns a real node resource even when there's no
  parent — checked via `node_is_null/1`. `node_next_sibling/1` and
  `node_prev_sibling/1` are inconsistent with that: when there's no such
  sibling, they return the plain atom `undefined` instead. Calling
  `node_is_null/1` on `undefined` raises `badarg` — check `=:=
  undefined` (or pattern match the atom directly) when walking siblings,
  e.g. the comment/doc-run walk in
  `ts_extract_typescript.erl`/`ts_extract_erlang.erl`.
- **NIFs cannot be shipped inside a `rebar3 escriptize` binary.**
  `escript_incl_apps` only bundles `.beam`/`.app` files into the
  escript's zip archive, never `priv/`, and `erlang:load_nif/2` cannot
  `dlopen` a shared library from inside a zip at all. A `rebar3 release`
  keeps `priv/` as real files on disk, which fixes this — see
  `docs/cli-erlang.md` §1.1/§1.2, including why relx's own generated
  start script isn't usable as the CLI entry point either (its
  `eval`/`escript` subcommands both require a node already running) and
  the small wrapper script (`scripts/symbolic`) that is.

## 7. Suggested path (historical)

This is roughly the path actually followed, kept for reference:

1. **Prototype against the `tree-sitter` CLI or a third-party binding**
   (fast, no C build of your own) to lock down the per-language query
   strings before committing to owning a NIF.
2. **Start from a full-featured binding if one exists** (this project
   used `erl_ts`) to get the extraction logic and query sets right
   first, extending it for whatever grammars are needed.
3. **Inline only what you actually end up calling**, once the real
   call surface is known — a small, purpose-built NIF is easier to
   reason about, easier to package (no external fork to keep in sync or
   track in git), and easier to fix bugs in (§6's tree-freeing pitfall
   was found and fixed here, not upstream).
4. **Port the boundary to Rust (Rustler) once the semantic quirks are
   pinned by tests** — the two C-era crashes were exactly what Rust's
   ownership model encodes (§2.1), and the port was gated on
   zero-diff fact parity (`scripts/parity_check.sh`) plus the full
   eunit suite. The lesson: do it *after* the behavior is pinned, so
   "identical" is checkable, not asserted.

## References

- [`tree-sitter`](https://github.com/tree-sitter/tree-sitter) — runtime + C
  API (`lib/include/tree_sitter/api.h`), vendored at `c_src/tree-sitter/`.
- [`tree-sitter/tree-sitter-typescript`](https://github.com/tree-sitter/tree-sitter-typescript),
  [`tree-sitter-grammars/tree-sitter-markdown`](https://github.com/tree-sitter-grammars/tree-sitter-markdown),
  [`ikatyang/tree-sitter-toml`](https://github.com/ikatyang/tree-sitter-toml),
  [`tree-sitter/tree-sitter-json`](https://github.com/tree-sitter/tree-sitter-json),
  [`tree-sitter/tree-sitter-bash`](https://github.com/tree-sitter/tree-sitter-bash),
  [`tree-sitter/tree-sitter-jsdoc`](https://github.com/tree-sitter/tree-sitter-jsdoc)
  — the TypeScript, Markdown, TOML, JSON, Bash, and JSDoc grammars,
  vendored at `c_src/grammars/{typescript,markdown,toml,json,bash,jsdoc}/`
  (JSDoc pinned at its `v0.25.0` tag). Erlang's own grammar
  (`c_src/grammars/erlang/`) traces back to
  [`tree-sitter-erlang`](https://github.com/WhatsApp/tree-sitter-erlang).
  [`ikatyang/tree-sitter-yaml`](https://github.com/ikatyang/tree-sitter-yaml)
  was investigated but deliberately not vendored — see §5.1's C++
  blocker.
- [`cfclavijo/erl_ts`](https://github.com/cfclavijo/erl_ts) — the
  third-party binding this project's own NIF was ported from and now
  replaces; credit for the resource-wrapping shape `symbolic_ts` still
  follows.
- [`rustler-lang/rustler`](https://github.com/rustler-lang/rustler) —
  the Rust crate `symbolic_ts` builds with (resources via
  `ResourceArc`, dirty scheduling via the `#[rustler::nif(schedule =
  "DirtyCpu")]` attribute, panics caught and returned as Erlang errors).
  The rebar3 integration is a plain compile pre-hook
  (`scripts/build_nif.sh`) — no Elixir/Mix involvement.
- [`blt/port_compiler`](https://hex.pm/packages/pc) — the rebar3 plugin
  the *previous* C NIF built through, kept as historical context.
- [`erlang-mcp-design.md`](erlang-mcp-design.md) — the in-process BEAM design
  this plugs into.
- [`readme.md`](../readme.md) — the four-tool contract.
- [`tree-sitter-markdown.md`](tree-sitter-markdown.md) — the Markdown
  extraction design (block grammar, plus the deferred inline-grammar/
  `link/4` work).
- [`nlp-tooling.md`](nlp-tooling.md) — the same NIF-over-a-C-library pattern
  applied to NLP libraries (`libstemmer_c`, CRFsuite, `llama.cpp`).
