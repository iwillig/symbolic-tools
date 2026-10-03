# Research: YAML Frontmatter, the `section_fact/2` Segfault, and tree-sitter-yaml

- **Date:** 2026-10-02
- **Commit:** `20d24c0` (working tree: presentation toolchain under `docs/` staged, not yet committed)
- **Scope:** the `symbolic_parse` Markdown walker (`ts_extract_markdown.erl`, `symbolic_ts.erl`,
  `c_src/symbolic_ts_nif.c`, the vendored tree-sitter runtime and grammars), the
  `docs/` tree it can no longer scan, and the upstream YAML-grammar ecosystem
  (`tree-sitter-grammars/tree-sitter-yaml`, `ikatyang/tree-sitter-yaml`, `yakaz/yamerl`,
  `processone/fast_yaml`).
- **Method:** the crash was reproduced deterministically and bisected with the real
  CLI; the parse tree was dumped with an instrumented NIF walk; the crash frames came
  from the macOS crash report for `beam.smp`; upstream claims were verified against
  the repos' own files (API listings, raw source), not secondary write-ups. Goals and
  outputs are quoted where the fact base can answer.
- **Status:** decision made — fix the crash, then adopt
  `tree-sitter-grammars/tree-sitter-yaml` (pure C). This document records both.

**Recommendation up front:**

- **The segfault is not a YAML-parsing gap.** The vendored Markdown grammar already
  parses frontmatter (`minus_metadata`); the crash is a violated invariant in
  `section_fact/2` plus a null-unsafe NIF accessor. Both must be fixed regardless of
  any YAML decision — a grammar producing an unexpected shape must never kill the VM.
- **"The standard YAML grammar is C++" is out of date.** The original
  `ikatyang/tree-sitter-yaml` uses `scanner.cc` + `schema.generated.cc` (C++). The
  maintained `tree-sitter-grammars/tree-sitter-yaml` — the one editors ship — has a
  **pure C** external scanner (`src/scanner.c`, read directly, C throughout). Adding
  it brings no C++ toolchain: it is `parser.c` + `scanner.c` + a `tree_sitter/`
  header dir, the same shape as the grammars already vendored, compiled by the
  existing all-C `pc` port config.
- **Decision: fix the crash, then vendor the grammar** and build a `ts_extract_yaml`
  emitting the existing `config_value/4` + `config_section/3` families for `.yaml`
  files and Markdown frontmatter alike — the same one-pipeline story as the other
  seven languages. This reverses the earlier "YAML deliberately unsupported" stance
  deliberately and on the record, not by accident.

## 1. The crash, root-caused

`symbolic parse docs/` (and the MCP `parse` tool on the same path) segfaults the
BEAM. Bisected to a minimal repro with the released CLI (`exit=139` on each):

```markdown
---
title: x
---

# Hello
```

Passes: frontmatter alone · ATX heading alone · setext heading + ATX ·
thematic break + ATX. Crashes: **leading `---` thematic break, one text line,
closing `---`, blank line, then any ATX heading** — i.e. YAML frontmatter followed
by a heading, which is exactly what every deck under `docs/presentations/` is.
`.symbolic/config.json` scans `["src","test","docs"]`, so the project currently
cannot parse its own configured tree.

Crash report frames for `beam.smp` (macOS crash report, this session):

```
symbolic_ts.so   +0x00006c80  ts_node__subtree
symbolic_ts.so   +0x00006eec  ts_node_type
symbolic_ts.so   +0x00000f0c  node_type
beam.smp         +0x00033048  beam_jit_call_nif
```

An instrumented walk of the NIF API over the repro document completes fine and
prints the actual tree — the grammar is not the problem:

```
type="document" (3 children)
  type="minus_metadata" (0 children)     ← frontmatter, already parsed!
  type="section" (0 children)           ← the degenerate one
  type="section" (1 child)
    type="atx_heading" → atx_h1_marker + inline
```

`tree-sitter-markdown` recognizes frontmatter natively as `minus_metadata`; the
block grammar then groups what follows into a `section` that has **no heading
child**, because the frontmatter's closing `---` consumed the line that would
otherwise begin real content. The extractor's clause assumes the opposite:

```erlang
%% ts_extract_markdown.erl — "A section's own first named child is always its
%% heading"
section_fact(Node, PathAtom) ->
    Heading = symbolic_ts:node_named_child(Node, 0),
    Level = heading_level_of(Heading),
```

`node_named_child/2` on an empty section returns a **null TSNode** (by design —
`make_node_term_always/2` deliberately does not collapse nulls to `undefined` so
callers can `node_is_null/1` themselves, per `c_src/symbolic_ts_nif.c`). Then
`heading_level_of/1` calls `node_type/1` on it. The vendored tree-sitter runtime
(`c_src/tree-sitter/src/node.c:51`, `node.c:463`) does not null-check:

```c
static inline Subtree ts_node__subtree(TSNode self) {
  return *(const Subtree *)self.id;      /* NULL deref on a null node */
}
const char *ts_node_type(TSNode self) {
  TSSymbol symbol = ts_node__alias(&self);
  ...                                    /* also derefs self.tree */
}
```

Null → `ts_node__subtree(NULL.id)` → SIGSEGV, and the whole VM dies with it —
which is how the MCP server was lost mid-session on the first `parse docs` call.

### 1.1 The fix, two layers

1. **The invariant** — `section_fact/2`'s comment is wrong for frontmatter-shaped
   documents. A zero-child `section` has no heading, so it is not a section in
   any sense the fact base cares about; skip it rather than index into it.
2. **The boundary** — every NIF node accessor (`node_type`, `node_start_byte`,
   `node_end_byte`, `node_start_point`, `node_end_point`, `node_named_child`,
   `node_named_child_count`, `node_child_by_field_name`, `node_parent`) must
   return `undefined` for a null node instead of dereferencing it — the same
   collapse-to-`undefined` convention `make_node_term/2` already applies to
   sibling navigation. No input to any extractor should ever be able to kill
   the VM.

## 2. Is tree-sitter-yaml actually C++? No — not the one worth having

- **`ikatyang/tree-sitter-yaml`** (original, largely dormant): `src/scanner.cc`
  (31 KB) + `src/schema.generated.cc` — **C++**, confirmed by API directory
  listing. This is the grammar the "full C++ parser" worry is about, and the
  worry is fair: it would drag a C++ toolchain into a build that has none
  (`rebar.config` compiles only `.c` sources; the single C++ requirement the
  project carries today is `erllama`'s vendored llama.cpp, quarantined to one
  optional dep).
- **`tree-sitter-grammars/tree-sitter-yaml`** (maintained fork, the successor,
  active, MIT): `src/scanner.c` (51 KB, **pure C** — `ts_calloc`, the tree-sitter
  `Array()` macros, C functions throughout, read in full this session), plus
  `src/parser.c` (generated C, committed in-repo, so no `tree-sitter` CLI is
  needed to build) and the pluggable `schema.core.c` / `schema.json.c` /
  `schema.legacy.c` — the "core" schema resolves plain scalars to typed nodes
  (`boolean`, `integer`, `float`, `null`), which is exactly the shape a
  `config_value/4` extractor wants.
- Vendoring cost is the same shape as every grammar already under
  `c_src/grammars/` (which includes two external scanners, `markdown/scanner.c`
  and `toml/scanner.c`, both already C): copy `parser.c`, `scanner.c`,
  `schema.core.c`, the grammar's `tree_sitter/` headers and `LICENSE`, add the
  source list to `rebar.config`, add one `nif_tree_sitter_yaml` loader to
  `symbolic_ts_nif.c` and one `tree_sitter_yaml/0` wrapper to `symbolic_ts.erl`.

## 3. The alternatives considered, and why they lost

- **`yakaz/yamerl`** — pure Erlang YAML 1.1/1.2, zero native code, zero deps
  beyond OTP, BSD-2, Hex package, and its `detailed_constr` mode carries
  line/column per node (which `config_value/4`'s `Line` field needs). The
  strongest "no new C" option. Rejected as the primary route because it forks
  the extraction pipeline: every other language goes through tree-sitter →
  node walk → fact terms, and a second, structurally different parser for one
  language is a divergence the fact base's uniformity argument is built
  against. A pure-Erlang dep is also the project's only Hex dep that is a
  whole parser. Worth revisiting only if the grammar proves defective.
- **`processone/fast_yaml`** — NIF/port wrapper over **libyaml** (C, not C++),
  but it requires system libyaml headers at build time — a new external
  dependency this repo's "everything vendored under `c_src/`" build would
  otherwise avoid — and its output carries no line/column. Strictly dominated
  by both other options for this use case.
- **Skip frontmatter entirely** — zero cost, and defensible on the grounds
  that frontmatter is metadata, not content. Rejected because the frontmatter
  is exactly where a deck's `title`/`date`/`description` live, the same
  name/value structure `config_value/4` already models for TOML and JSON, and
  the crash fix had to touch this node family anyway.

## 4. What "deliberately unsupported" reverses to

The fact-schema docs currently say YAML is the one format deliberately left
out. With the grammar vendored, `ts_extract_yaml` emits:

- `config_value(Path, Value, File, Line)` and `config_section/3` for standalone
  `.yaml` / `.yml` files (one dotted-path atom per key, the same convention
  `ts_extract_toml` / `ts_extract_json` already share), and
- the same families for a Markdown file's `minus_metadata` block, extracted by
  `ts_extract_markdown` handing the frontmatter text to the YAML extractor —
  the same re-parse-as-another-language move `example_defines/5` already makes
  for fenced code.

Both belong behind the crash fix, which stands on its own and is what
unblocks `docs/` scanning in the meantime.

## References

- `tree-sitter-grammars/tree-sitter-yaml` —
  <https://github.com/tree-sitter-grammars/tree-sitter-yaml> (fork of
  ikatyang's grammar; `src/scanner.c` verified pure C by direct read this
  session; YAML 1.2)
- `ikatyang/tree-sitter-yaml` —
  <https://github.com/ikatyang/tree-sitter-yaml> (the C++ original:
  `src/scanner.cc`, `src/schema.generated.cc`, via API listing)
- `yakaz/yamerl` — <https://github.com/yakaz/yamerl> (pure-Erlang YAML
  1.1/1.2 parser; README, verified 2026-10-02)
- `processone/fast_yaml` — <https://github.com/processone/fast_yaml>
  (libyaml wrapper; README, verified 2026-10-02)
- `c_src/tree-sitter/src/node.c:51,463` — the null-unsafe accessors
- `c_src/symbolic_ts_nif.c` — `make_node_term_always/2`'s deliberate
  null-node design, the convention the fix extends to the accessors
- `docs/tree-sitter-markdown.md` — the vendored grammar's own doc
