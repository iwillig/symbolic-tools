# Reference: The Prolog Fact Schema

Every other doc in this project explains *how* one extractor works, or
walks through *one* worked example. This one is different: it's the
complete data dictionary — every fact predicate `symbolic parse` can
produce, across every supported language, in one place. If you're
writing a query and need to know exactly what a predicate's arguments
mean, or what's deliberately *not* captured, start here.

For how these facts are stored and cached (not what they mean), see
[`prolog-store.md`](prolog-store.md). For worked examples of *using*
these facts, see [`agent-examples.md`](agent-examples.md) and
[`lint-queries.md`](lint-queries.md).

## At a glance

| Predicate | Produced by | Meaning |
|---|---|---|
| `defines/3` | Erlang, TypeScript, Bash | A named function/definition exists |
| `calls/4` | Erlang, TypeScript, Bash | A call site, shape varies per language |
| `comment/3` | Erlang, TypeScript, Bash | Every comment, unconditionally |
| `doc/4` | Erlang, TypeScript, Bash | A comment run immediately preceding a definition |
| `heading/4` | Markdown | An ATX (`#`) heading |
| `code_block/3` | Markdown | A fenced code block and its declared language |
| `paragraph/3` | Markdown | A paragraph (or list-item) of body text |
| `example_defines/3` | Markdown | A `defines/3`-equivalent, but from inside a fenced code sample |
| `example_calls/4` | Markdown | A `calls/4`-equivalent, but from inside a fenced code sample |
| `config_value/4` | TOML, JSON | A dotted key path resolving to a scalar value |
| `config_section/3` | TOML, JSON | A named table/object container exists |

Three genuinely different *shapes* of fact live in this one schema:
**code facts** (something with named definitions and call sites),
**Markdown structural facts** (a document's own headings/prose/fences),
and **config facts** (a key path resolving to a value) — see
`docs/tree-sitter-erlang.md` §5.1 for why config data needed a
different shape than code, and why Markdown needed a third one again.

## Code facts: `defines/3`, `calls/4`, `comment/3`, `doc/4`

Produced by `src/ts_extract_erlang.erl`, `src/ts_extract_typescript.erl`,
and `src/ts_extract_bash.erl` — one query set per language (no shared
extraction code between them, a deliberate choice explained in each
module's own header), but the same four predicate names and arities
across all three, so a query written against one language's facts
reads the same way against another's.

### `defines(Function, File, Line)`

- **`Function`** — the defined name, as an atom (`charge`, `deploy`).
- **`File`** — the source file path, as an atom.
- **`Line`** — 1-based line number of the definition.

No module name and no arity are tracked (`Function` alone, not
`Module:Function/Arity`) — a deliberate Phase 1 simplification kept
ever since, not an oversight. The practical consequence, found via
dogfooding (`docs/lint-queries.md`): two same-named functions of
*different arity* in the same file (Erlang's `query/2` and `query/3`,
say) are indistinguishable from true recursion or genuine duplication
in any query that only looks at `Function`.

### `calls(Caller, CallSpec, File, Line)`

- **`Caller`** — the enclosing definition's name, found by walking
  `node_parent/1` up from the call site to the nearest recognized
  definition node. The atom `undefined` if the call isn't inside any
  recognized definition (e.g. a bare top-level statement, or — a real
  quirk found via dogfooding — Erlang's `-spec` attributes: their type
  references parse identically to real calls, and always come back with
  `Caller = undefined` since a `-spec` lives outside any function
  clause; see `docs/lint-queries.md`).
- **`CallSpec`** — the actual call's shape, and this is where the three
  languages genuinely differ (same pattern `config_value`'s `Path`
  takes per-format, just for a different reason — see below):

  | Language | `CallSpec` shapes | Example |
  |---|---|---|
  | Erlang | `local(Callee)`, `remote(Module, Function)` | `local(bar)`, `remote(io, format)` |
  | TypeScript | `local(Callee)`, `member(Object, Method)` | `local(bar)`, `member(console, log)` |
  | Bash | `local(Command)` only | `local(build)` |

  Bash has no qualified-call syntax (nothing like `mod:fun()` or
  `obj.method()`) to tell a call to a same-script function apart from a
  call to an external program or a shell builtin — so it doesn't
  pretend to know the difference; `local(build)` and `local(rsync)`
  look exactly alike on purpose.
- **`File`**, **`Line`** — same meaning as in `defines/3`, `Line` is the
  call site's own line.

### `comment(File, Line, Text)`

Every comment node, unconditionally — whether or not it documents
anything. `Text` is the comment's content with its language's own
comment-marker syntax stripped (`%`/`%%` for Erlang, `//`/`/** */` for
TypeScript, `#` for Bash) and, for a multi-line run (consecutive `//`
lines, or a multi-line `/** ... */` block), joined into a single space-
separated line — a quoted Prolog atom *can* legally contain a raw
newline, but nothing else this project emits does, and there's no
benefit to being the exception.

### `doc(Function, File, Line, Text)`

Only emitted when a comment (or a contiguous *run* of them) sits
immediately before a recognized definition node — found via sibling
navigation (`node_next_sibling/1`/`node_prev_sibling/1`), not the
`node_parent/1` walk `calls/4` uses, since a comment is a *sibling* of
what it documents, not a child of it. `Line` is the **definition's**
line (so it joins cleanly with that function's own `defines/3` fact),
not the comment's own line. A comment with nothing recognizable
following it (the last thing in a file, or followed by something that
isn't a function) gets a `comment/3` fact and no `doc/4` fact at all.

**Shared caveat across all three languages, worth knowing before
walking siblings yourself:** `node_next_sibling/1`/`node_prev_sibling/1`
return the bare atom `undefined` when there's no such sibling — *not* a
null resource checked via `node_is_null/1`, unlike `node_parent/1`.
Calling `node_is_null/1` on `undefined` raises `badarg`. See
`docs/tree-sitter-erlang.md` §6.

**Shared caveat on text length:** any text-bearing argument above
(`comment/3`'s `Text`, `doc/4`'s `Text`) is truncated at 200 characters
before becoming an atom — Erlang atoms are capped at 255 bytes, hit for
real during dogfooding on a long doc-comment run. A truncated value
ends with `...`.

## Markdown structural facts

Produced by `src/ts_extract_markdown.erl`, using tree-sitter-markdown's
**block** grammar only (see `docs/tree-sitter-markdown.md` for the
still-open inline-grammar/`link/4` work this doesn't cover).

### `heading(File, Level, Text, Line)`

- **`Level`** — 1–6, from the number of `#` characters.
- **`Text`** — the heading's own text, trimmed.

**ATX (`#`) headings only** — the underline (setext) style isn't
handled. A real, not hypothetical, scope limit: this repo's own docs
never use setext headings.

### `code_block(File, Lang, Line)`

- **`Lang`** — the fence's declared language tag as an atom (`erlang`,
  `sh`, `ts`), or the atom `none` for a bare ``` fence with no tag.
- **`Line`** — the fence's own opening line.

### `paragraph(File, Text, Line)`

- **`Text`** — the paragraph's text. A soft-wrapped paragraph (multiple
  source lines, no blank line between them) is still *one* fact, its
  embedded newline collapsed into a single space, the same cleaning
  `comment/3`'s multi-line runs get.

**Real quirk, not filtered out:** this grammar also parses a list
item's own content as a `paragraph` node, so list-item text shows up as
`paragraph/3` facts too — extracted as the grammar actually names
things, not a hand-picked notion of "real" paragraphs.

## Markdown example facts: re-extracting fenced code

### `example_defines(Function, File, Line)` / `example_calls(Caller, CallSpec, File, Line)`

For a fenced code block tagged `erlang`, `ts`, `typescript`, `sh`, or
`bash`, the block's own text is re-parsed by the *real* language
extractor (`text/2`, the same entry point `ts_extract_erlang.erl` etc.
expose for this purpose), with `File` set to the **Markdown file**
(not a synthetic path) and `Line` offset back to that file's real line
numbers.

**Deliberately different predicate names than `defines/3`/`calls/4`**,
not the same predicates reused with an `.md` `File` — this project's
whole value proposition is a fact base worth trusting ("a real fact
base, not a grep result"), and conflating "this function really exists
in the codebase" with "a doc's example happened to show a function of
this name" would undercut that directly. The split makes the actual
motivating check trivial:

```prolog
stale_doc_example(Fun, DocFile, Line) :-
    example_defines(Fun, DocFile, Line),
    \+ defines(Fun, _, _).
```

`comment/3`/`doc/4` are **not** extracted from embedded snippets — a
fragment's own comments aren't the point, and doc-comment attribution
inside an illustrative example adds noise without answering the
question this feature exists for (see `docs/agent-examples.md` for the
full worked scenario).

## Config facts: `config_value/4`, `config_section/3`

Produced by `src/ts_extract_toml.erl` and `src/ts_extract_json.erl` —
**shared predicate names on purpose**, the config-format analogue of
`defines`/`calls` being shared across three programming languages: "a
dotted key path resolves to this value" is the same question regardless
of whether the file is a `Cargo.toml` or a `package.json`.

### `config_value(File, Path, Value, Line)`

- **`Path`** — the fully dotted key path as one atom
  (`'dependencies.serde'`), built by real recursive descent through
  nested tables/objects — there's no flat tree-sitter query that could
  produce a multi-level path directly, unlike every code-fact predicate
  above.
- **`Value`** — the leaf's raw text (quotes stripped for strings) as an
  atom. **Array values are captured whole, as one opaque leaf** — the
  array's own raw source text, not walked element-by-element. A real,
  deliberate scope limit for both formats, not a missing case.

### `config_section(File, Path, Line)`

A named container was opened along the way: a TOML `table`,
`table_array_element`, or `inline_table`; a JSON `object`. The
anonymous document root doesn't get a fact (it has no path worth
naming). A repeated TOML `[[section]]` (array-of-tables) or a JSON
array of objects produces multiple `config_section`/`config_value`
facts **sharing the same `Path`**, each with its own `Line` — the
correct shape for "list every host across all `[[servers]]` blocks,"
since this pass doesn't do numeric array indexing.

## What's deliberately not here yet

- **YAML** — investigated, not vendored. Its grammar needs a real C++
  scanner; this project's build is pure C with no C++ toolchain wired
  in. See `docs/tree-sitter-erlang.md` §5.1.
- **Markdown links (`link/4`)** — needs the separate *inline* grammar
  plus a NIF function (`ts_parser_set_included_ranges`) not yet wrapped
  by `symbolic_ts`. See `docs/tree-sitter-markdown.md` §3.
- **Array-element recursion** for `config_value`/`config_section` — see
  above.
- **Module/arity tracking** for `defines`/`calls` — see `defines/3`
  above.

## References

- [`tree-sitter-erlang.md`](tree-sitter-erlang.md) — how each
  extractor is built, including §5.1/§5.2's per-language case studies
  and §6's pitfalls (the sibling-navigation `undefined` quirk, the
  `query_capture/2` duplication quirk).
- [`tree-sitter-markdown.md`](tree-sitter-markdown.md) — the Markdown
  grammar split and the deferred `link/4` work.
- [`prolog-store.md`](prolog-store.md) — where these facts live at
  runtime and on disk, not what they mean.
- [`agent-examples.md`](agent-examples.md) — narrative worked examples
  of an agent using several of these predicates together.
- [`lint-queries.md`](lint-queries.md) — a reusable rule library over
  `defines`/`calls`/`comment`/`doc`, including two real quirks
  (`-spec` noise, no-arity-tracking recursion false positives) found by
  running it against this project's own `src/`.
- [`../readme.md`](../readme.md) — the CLI-level introduction to all of
  the above, with one real worked example per language.
