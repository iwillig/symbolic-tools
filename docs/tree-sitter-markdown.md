# Design: Parsing Markdown into an AST (tree-sitter)

This document covers extending the tree-sitter extraction layer
([`tree-sitter-erlang.md`](tree-sitter-erlang.md)) to **Markdown** —
`readme.md` and `docs/*.md` — so their structure (headings, links,
fenced-code-block languages) becomes Prolog facts the same way source-code
definitions and call sites do. A design/research document only — nothing
here is implemented.

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
**two grammars for one file**, not one:

1. Vendor both grammar submodules (`tree-sitter-markdown`,
   `tree-sitter-markdown-inline`) and build both into `erl_ts.so`.
2. Add two NIF entry points, `tree_sitter_markdown/0` and
   `tree_sitter_markdown_inline/0`, following the existing
   `tree_sitter_typescript/0` example.
3. Parse twice per file: once with the block grammar, then a second parse
   with the inline grammar restricted to the byte ranges the block parse
   marked as inline content (`ts_parser_set_included_ranges` in the C API).

**Open question:** `erl_ts` claims to wrap "essentially the whole
tree-sitter C API," but `ts_parser_set_included_ranges` specifically has not
been verified present. Confirm it's exposed (or add it, if `erl_ts` is
already being forked/extended per `tree-sitter-erlang.md` §2) before
committing to this grammar — without it, the inline parse can't be scoped
and the two-grammar split doesn't work.

## 4. What facts to extract

Mirrors the shape in [`tree-sitter-erlang.md`](tree-sitter-erlang.md) §3 —
facts, not a rendered tree:

- `heading(File, Level, Text, Span)` — from the block grammar.
- `link(File, Text, Target, Span)` — from the inline grammar; `Target` is
  the raw link destination (a URL, or a relative path like `cli-erlang.md`
  or `cli-erlang.md#5-testing`).
- `code_block(File, Lang, Span)` — the declared language of each fenced
  code block (e.g. `erlang`, `sh`).

These are enough to write the check that would have caught this repo's own
stale cross-references by query instead of by hand — e.g. a `Target` that
looks like a local file path but doesn't resolve to a real file or heading:

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

## 5. Scope limits

Given the maintainers' own correctness caveat (§2), do not rely on this
grammar for anything that needs exact CommonMark semantics — rendering
Markdown to HTML, or anything sensitive to edge cases like link-reference
definitions or nested-list lazy continuation. Headings, inline links, and
fenced-code-block language tags are simple, well-supported node types where
the caveat is unlikely to bite; that is deliberately all §4 asks for.

## 6. Suggested path

Same shape as [`tree-sitter-erlang.md`](tree-sitter-erlang.md) §7:

1. **Prototype against the `tree-sitter` CLI** on this repo's own
   `readme.md` and `docs/*.md` — run both grammars, confirm heading/link/
   code-block captures come out clean on real files before any NIF work.
2. **Bring the two grammars into `erl_ts`** per §3, resolving the
   included-ranges open question first.
3. **Wire it into the same parser-pool / fact-emission path** the code
   grammars use, then write the `broken_link/2` check from §4 as the first
   consumer.

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
