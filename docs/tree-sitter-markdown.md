# Design: Parsing Markdown into an AST (tree-sitter)

This document covers extending the tree-sitter extraction layer
([`tree-sitter-erlang.md`](tree-sitter-erlang.md)) to **Markdown** —
`readme.md` and `docs/*.md` — so their structure (headings, links,
fenced-code-block languages) becomes Prolog facts the same way source-code
definitions and call sites do.

**Status: partially implemented.** `heading/4`, `code_block/3`,
`paragraph/3`, and `example_defines/3`/`example_calls/4` (facts
re-extracted from a fenced code block's own contents — see §4) are real
today via `symbolic parse`, using only the **block** grammar — see
`src/ts_extract_markdown.erl`. `link/4` (§4) is **not implemented yet**;
it needs the separate *inline* grammar plus a NIF function
(`ts_parser_set_included_ranges`) that turned out to be an unimplemented
stub in the vendored `erl_ts` fork — see §3's "resolved" open question.

**Recommendation up front:** use
[`tree-sitter-grammars/tree-sitter-markdown`](https://github.com/tree-sitter-grammars/tree-sitter-markdown)
through the same `erl_ts` NIF as the code grammars ([`tree-sitter-erlang.md`](tree-sitter-erlang.md)
§2). It is **two grammars, not one** (block + inline) and ships with an
explicit correctness caveat from its own maintainers — scope extraction to
structural facts (headings, links, code-block languages), not anything
requiring exact CommonMark fidelity. The motivating use case is dogfooding:
turn this repo's own `docs/*.md` cross-references into Prolog facts and
query for exactly the kind of dangling reference already found by hand in
this repo (§4).

## 1. Why parse Markdown at all

`symbolic-tools` already builds a fact base over source code so an agent can
reason about it instead of re-reading files. The same repo's own design docs
are full of the same kind of structure a code file has — a "definition"
(a heading), a "call site" (a link to another doc or section), an
"import" (a fenced code block's declared language) — and the same kind of
bug: a link to a section or file that doesn't exist. This repo's own docs
already had that exact problem (see §4) before it was caught by hand.
Parsing Markdown into the same fact shape lets that class of check run as a
Prolog query instead of a manual read-through.

## 2. The grammar

[`tree-sitter-grammars/tree-sitter-markdown`](https://github.com/tree-sitter-grammars/tree-sitter-markdown)
(MIT, actively maintained, the successor to `MDeiml/tree-sitter-markdown`,
now under the official `tree-sitter-grammars` org — the same adoption
pattern as most language grammars). Follows CommonMark plus GFM extensions
(task lists, strikethrough, pipe tables).

- **Split into two grammars**, mirroring the CommonMark spec's own two-pass
  strategy: `tree-sitter-markdown` parses **block** structure (headings,
  lists, fenced code blocks, block quotes); `tree-sitter-markdown-inline`
  parses **inline** structure (links, emphasis, code spans) within the
  regions the block parse marks as inline content.
- Two C entry points, one per grammar: `tree_sitter_markdown` and
  `tree_sitter_markdown_inline` — the same one-function-per-grammar shape
  every other tree-sitter grammar exposes.
- **Explicit correctness caveat from the maintainers**: built for syntax
  highlighting (it's what Neovim and Helix use), and the README says
  directly it is "not recommended to use where correctness is important" —
  Markdown's ambiguity (lazy list continuation, link-reference resolution)
  doesn't fit tree-sitter's incremental grammar model cleanly.
- Alternatives, for context, not recommended over this one: `ikatyang/tree-sitter-markdown`
  (older, largely superseded), `mattmassicotte/tree-sitter-markdown-2` (a
  newer independent rewrite, less adopted).

## 3. Integration with `erl_ts`

Same pattern as adding any language to `erl_ts`
([`tree-sitter-erlang.md`](tree-sitter-erlang.md) §5) — except this is
**two grammars for one file**, not one. **The block half is done**;
the inline half (needed only for `link/4`) is not:

1. ~~Vendor both grammar submodules~~ — done for the **block** grammar
   only, vendored at
   `_checkouts/erl_ts/tree-sitter-langs/tree-sitter-markdown/src/`
   (`parser.c`, `scanner.c`, its own `tree_sitter/{alloc.h,array.h,
   parser.h}` — same trimmed shape as the erlang/typescript grammars,
   skipping `grammar.json`/`node-types.json`/bindings/tests). The
   **inline** grammar (`tree-sitter-markdown-inline`) is not vendored.
2. `tree_sitter_markdown/0` is added, following the existing
   `tree_sitter_typescript/0` example exactly (extern declaration, a
   `tree_sitter_markdown_nif` function, registered in `nif_funcs[]`, plus
   the three-places `erl_ts.erl` edit — export, `-nifs`, stub function).
   `tree_sitter_markdown_inline/0` does not exist yet.
3. The two-parse-with-included-ranges step is **not implemented** — see
   the resolved open question below.

**Open question — resolved by reading the code, not by guessing.**
`erl_ts` claims to wrap "essentially the whole tree-sitter C API," but
`ts_parser_set_included_ranges` does not actually work: reading
`_checkouts/erl_ts/c_src/erl_ts_nif.c` directly shows
`parser_set_included_ranges_nif` is an unimplemented stub —

```c
ERL_TS_FUNCTION(parser_set_included_ranges_nif) {
  /* TODO: */
  /* bool ts_parser_set_included_ranges( */
  /* TSParser *self, */
  /* const TSRange *ranges, */
  /* uint32_t count */
  return atom_undefined;
}
```

— it never calls the real C function at all. Implementing it looks
tractable when this is picked back up: `map_to_tsrange/3` already exists
in the same file (used by `parser_included_ranges_nif`'s inverse
direction) and does the per-range Erlang-map-to-`TSRange` conversion, so
the stub mostly needs a loop building a `TSRange[]` from an Erlang list
via that existing helper, then the real `ts_parser_set_included_ranges`
call. That, plus vendoring the inline grammar and its own
`tree_sitter_markdown_inline/0` NIF entry (steps 1-2 above), is what
`link/4` needs — deliberately not attempted in this pass, since
`heading`/`code_block` deliver real value from the block grammar alone
with none of that risk.

## 4. What facts to extract

Mirrors the shape in [`tree-sitter-erlang.md`](tree-sitter-erlang.md) §3 —
facts, not a rendered tree. `Line`, not `Span`, following the same
simplification `defines/3`/`calls/4` already made (see
`tree-sitter-erlang.md`'s Phase 1 notes) — a single 1-based line number,
not a byte range:

- **`heading(File, Level, Text, Line)`** — implemented, from the block
  grammar (`src/ts_extract_markdown.erl`). ATX (`#`) headings only —
  this repo's own docs never use the underline (setext) style, so that's
  a real scope limit, not a hypothetical one.
- **`code_block(File, Lang, Line)`** — implemented, from the block
  grammar. `Lang` is the fenced code block's declared language (e.g.
  `erlang`, `sh`) as an atom, or the atom `none` for a bare ``` fence.
- **`paragraph(File, Text, Line)`** — implemented, from the block
  grammar. A `paragraph` node's own `node_text/2` already spans its full
  text (no `heading_content`-style field to dig for), and a soft-wrapped
  paragraph's embedded newlines are collapsed into single spaces the same
  way a multi-line doc-comment run already is for code. One real quirk,
  kept rather than filtered: this grammar also parses a list item's
  content as a `paragraph` node, so list-item text shows up as
  `paragraph/3` facts too.
- **`link(File, Text, Target, Line)`** — **not implemented.** Needs the
  inline grammar (§3); `Target` would be the raw link destination (a URL,
  or a relative path like `cli-erlang.md` or `cli-erlang.md#5-testing`).
- **`example_defines(Function, File, Line)` / `example_calls(Caller,
  CallSpec, File, Line)`** — implemented. For a fenced block tagged
  `erlang`, `ts`, or `typescript`, the block's own text is re-run through
  the real `ts_extract_erlang`/`ts_extract_typescript` extractors
  (`text/2`, added alongside their existing `file/1`), with `File` set to
  *this* Markdown file and `Line` offset back to this file's real line
  numbers. **Deliberately a different predicate name than
  `defines/3`/`calls/4`**, not the same predicate reused with an `.md`
  `File` — conflating "this function really exists" with "a doc's
  example happened to show a function of this name" would undercut the
  fact base's whole point. `comment/3`/`doc/4` are not extracted from
  snippets. See `src/ts_extract_markdown.erl` for the exact mapping and
  line-offset math.

Once `link/4` exists, it's enough to write the check that would have
caught this repo's own stale cross-references by query instead of by
hand — e.g. a `Target` that looks like a local file path but doesn't
resolve to a real file or heading:

```prolog
broken_link(File, Target) :-
    link(File, _, Target, _),
    is_local_path(Target),
    \+ resolves(Target).
```

`is_local_path/1` and `resolves/1` are ordinary Erlang-side helpers (file
existence, heading-anchor lookup across the parsed doc set) — consistent
with `erlang-mcp-design.md` §5's "compute what doesn't fit Prolog's
execution model in Erlang, not Prolog."

`example_defines/3` already enables the analogous check for code
*samples*, no further implementation needed — parse a doc together with
the real source it documents, then:

```prolog
stale_doc_example(Fun, DocFile, Line) :-
    example_defines(Fun, DocFile, Line),
    \+ defines(Fun, _, _).
```

catches a doc's example showing a function that doesn't (or no longer)
exist in the real codebase — see the readme's "Parsing Markdown" example
for a real run of this against a doc and source file parsed together.

## 5. Scope limits

Given the maintainers' own correctness caveat (§2), do not rely on this
grammar for anything that needs exact CommonMark semantics — rendering
Markdown to HTML, or anything sensitive to edge cases like link-reference
definitions or nested-list lazy continuation. Headings, inline links, and
fenced-code-block language tags are simple, well-supported node types where
the caveat is unlikely to bite; that is deliberately all §4 asks for.
`heading/4` and `code_block/3` (block grammar only) are within that safe
zone and implemented; `link/4` (inline grammar) is designed but not yet
built, per §3/§4.

## 6. Suggested path

1. ~~Prototype against the `tree-sitter` CLI~~ — done directly against the
   real grammar instead (fetched `node-types.json` and parsed a sample via
   `erl_ts` once vendored): `atx_heading`/`fenced_code_block` node shapes
   confirmed empirically, not guessed, before `src/ts_extract_markdown.erl`
   was written.
2. ~~Bring the grammar into `erl_ts`~~ — done for the block grammar; see
   §3 for exactly what's vendored and what isn't.
3. ~~Wire it into the same fact-emission path the code grammars use~~ —
   done: `src/ts_extract.erl` dispatches `.md` to
   `ts_extract_markdown:file/1`, and `src/symbolic_parse.erl`'s folder
   walk picks up `.md` files alongside `.erl`/`.ts`.
4. **Remaining:** implement `ts_parser_set_included_ranges` for real (§3),
   vendor the inline grammar, add `link/4`, then write the `broken_link/2`
   check from §4 as its first consumer.

## References

- [`tree-sitter-erlang.md`](tree-sitter-erlang.md) — the `erl_ts` NIF and
  parser-pool design this plugs into; §5 is the general "adding a language"
  recipe this document specializes for Markdown's two-grammar split.
- [`erlang-mcp-design.md`](erlang-mcp-design.md) §5 — "compute closure in
  Erlang, not Prolog," the same split applied to `resolves/1` in §4.
- [`tree-sitter-grammars/tree-sitter-markdown`](https://github.com/tree-sitter-grammars/tree-sitter-markdown)
  — the recommended grammar (block + inline, MIT, maintained).
- [`ikatyang/tree-sitter-markdown`](https://github.com/ikatyang/tree-sitter-markdown) ·
  [`mattmassicotte/tree-sitter-markdown-2`](https://github.com/mattmassicotte/tree-sitter-markdown-2)
  — alternatives considered, not recommended over the above.
