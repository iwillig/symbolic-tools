# Self-review, remediation, and what's left

A full review of this project by its own engine (the MCP `symbolic` tools / the
released CLI, same erlog engine and `.symbolic/rules.pl`), the remediation that
came out of it, and the prioritized follow-ups. Everything claimed here was
proved with a goal or measured, not read-and-assumed — the point of the tooling.

## The review's findings, and how each was resolved

### 1. Markdown extractor crashed on `html_block` — FIXED

Scanning the project's own configured tree (`src`, `test`, `docs`) reported:

```
parse: docs/templates/presentation.md - extraction crashed (error:{case_clause,
    "html_block"}), skipping this file's facts
```

Root cause: `ts_extract_markdown:section_fact/2`'s "a section's first named
child is always its heading" invariant is false twice. The empty frontmatter
section was already guarded (child count > 0), but a section whose first child
is an `html_block` (the `<!-- ... -->` template comment right after frontmatter)
*has* named children, so the count guard passed it to `heading_level_of/1`,
which died with `{case_clause, "html_block"}` — and the whole file lost its
facts, not just one section.

Fix: `sections/4` now skips any section whose first named child isn't a heading
(`has_leading_heading/1` + `is_heading/1`), the same "a headingless section
yields no section fact" semantics as the frontmatter case. Regression-locked by
`test/fixtures/html_block.md` plus two tests in `ts_extract_markdown_tests`
(reproduced the exact production stack first — red, then green). A rebuilt
release re-scans the tree with zero crash reports, and `presentation.md`
contributes its 25 facts.

### 2. The tool's own queries timed out on its own codebase — FIXED

Four queries against the project's full base (`src`+`test`+`docs`, 1190 call
edges) failed at the 5s proof budget. Three distinct root causes:

- **`all_mutual_recursion/1` timed out even on a src-only base**, while
  `mutual_recursion(walk_object, G)` answered instantly. Two-stage fix:
  `join_step`'s nested-member cross product (~1.4M unifications in round 1
  alone) became a merge join over sorted lists; then the remaining ~9s closure
  (measured uncapped: 8 rounds, 3321 pairs — erlog resolves ~10k interpreted
  steps/sec) is preceded by **cycle-core pruning**: mutual pairs only live
  inside SCCs, nodes on cycles always have both in- and out-edges, so repeated
  both-endpoint pruning preserves every SCC and collapses the graph before
  closure. Same pairs, well under a second.
- **`top_fan_out/2` and `top_fan_in/2` timed out** — the per-function findall
  re-walks every `calls/5` fact once per function. Rewritten as one pass plus
  grouped counting via a new native `count_pairs/2` BIP in
  `symbolic_prolog_lib` (every interpreted counting shape is quadratic or
  choicepoint-per-element in erlog's interpreter; measured 3.2s interpreted for
  a 3200-pair list vs microseconds native), merged against defined keys so
  zero-count functions still rank at 0.
- **Enumerating `entry_point/3` raised `instantiation_error`** — the
  `runtime_entry_point` clause left `File` unbound. It now ties the -on_load
  exemption to the files that actually define it, same shape as the export
  clause.

Bonus trap found on the way: **erlog's `reverse/2` BIP is the naive
`reverse(T,L), append(L,[H],L1)` expansion — O(n²)**. Measured: reversing a
981-entry fan-out ranking cost **39s** while the whole pipeline without it was
~3s. `rules.pl` now carries a linear accumulator-based `rev/2` and every
library call site uses it (this also un-blocks `all_too_complex/1` and
`file_max_line/2` on large bases).

Verification: `all_mutual_recursion`, `top_fan_out(5)`, `top_fan_in(3)` answer
in ~0.3–0.8s proof; `entry_point` enumeration answers (103 src entry points).
Eight new query tests lock the semantics; `docs/lint-queries.md` was updated
for every changed definition.

### 3. `truly_uncalled/3`'s one hit was a false positive — FIXED

The review's only dead-code candidate, `scan_one/1` in `symbolic_parse.erl`,
was **live**: `parallel_map(fun scan_one/1, Paths)` calls it through a
`fun Name/Arity` reference that the `calls/5` family cannot see. Deleting it
would have broken `scan_paths/1`; the proof-before-deleting step (callers
query returned `N = 0` local *and* remote — then reading the call site) is
why it survived.

**Since fixed** (follow-up #2, below): `ts_extract_erlang` now emits one
`fun_ref/4` fact per `internal_fun` node — tree-sitter-erlang's
`fun Name/Arity` shape (children `[atom, arity[integer]]`, confirmed by
dumping the tree; the `external_fun` and `anonymous_fun` shapes are
deliberately not captured) — and `truly_uncalled/3` treats one as a live
reference. Engine proof on this repo's own base: `truly_uncalled(scan_one, 1,
File)` answers `No.` and `all_truly_uncalled` is `[]` — the dead-code report
is clean AND trustworthy here. Documented in `docs/prolog-schema.md` and
`docs/lint-queries.md`; regression-locked by
`truly_uncalled_ignores_fun_refs_test` plus the two extraction tests in
`ts_extract_tests.erl`.

### 4. Complexity hotspots — 4 → 3, two flattened, two kept deliberately

- `prolog_session:handle_call/3` (16): the 7-way proof-outcome ladder extracted
  into `prove_reply/3`. Off the list.
- `symbolic_codebase:handle_call/3` (20 → 15): `query_reply/3` extracted;
  `prove_all_with_timeout`'s result shapes *are* the reply shapes.
- `error_message/1` (11) and `walk_scope/5` (17): **left on purpose** — a flat
  one-clause-per-error message table and a one-line-per-node-type walker
  dispatch are the idiomatic shapes for what they are. Splitting them would be
  metric-gaming.

### 5. Extractor helper dedup — triaged by measurement, not appearance

Of 35 duplicated helper names across `ts_extract_*`, a mechanical comparison
of every copy showed only **11 were byte-identical** (source *and* macro
expansion); the rest are genuine per-language variants (`line/1`,
`clean_line/1`, `branch_fact/4`, `docs/4` differ per grammar) and were left
alone.

The 5 self-contained identical families moved to a new
`src/ts_extract_common.erl`: `comment_nodes/2`, `is_run_start/1`,
`collect_run/3` (×3 modules each), `find_named_child_by_type/4`
(json+markdown), `join_path/2` (json+toml) — 13 duplicate definitions deleted.
Families that merely *look* duplicated but depend on per-language helpers
(`comments/4` → `clean_line/1`, `branches/4` → `branch_fact/4`) were
deliberately not hoisted. Engine proof: `duplicate_name(collect_run, 3, F)` →
`No.` (and likewise the other four families). The bench suite runs green
post-refactor — extraction throughput unchanged (~12k lines/s on the large
input).

### 6. Doc pass — API modules: 30 → 0 undocumented exports

Discovery along the way: much of the "undocumented" code had excellent prose
stranded **above the `-spec`**, where the extractor attributes the comment run
to the spec node, not the function — the doc never became a `doc/5` fact. The
fix moves prose between the `-spec` and the head (one source of truth).

All exports of `symbolic_cli`, `symbolic_codebase`, `symbolic_query`,
`symbolic_serve`, `prolog_session`, `prolog_session_registry`, and
`symbolic_version` now have real doc facts; all-src the count went 89 → 55,
the remainder being one-line NIF accessors (`node_*`, `tree_sitter_*`,
`parser_*`) and extractor orchestrators whose module headers carry the prose.

The 9 stale doc-example names (`charge/2`, `buildClient/1`, `idle/3`, …) were
triaged: all are deliberate fixtures — lint-rule teaching snippets and a
*proposed* gen_statem design — not drift. `stale_doc_example/3` is working as
intended.

### 7. Coverage quick wins

`test/symbolic_version_tests.erl` added (3 tests pinning the build-identity
contract, including that `git_sha` is a real 40-hex SHA in this checkout —
proving the `gen_git_sha.sh` pre-hook wiring). `symbolic_prolog_lib` gained
direct, asserted coverage via the `count_pairs/2`, `sub_text/5`,
`atom_from_binary/2` cases in `symbolic_query_tests`.

## Verified non-issues (checked, not assumed)

- **The old "parse at repo root dies in `_build`" trap no longer exists**: a
  root scan runs with zero crash reports, `_build` is properly gitignored
  (`symbolic_gitignore:load/1` per root), and `parse_number/1` handles
  radix-prefixed integers (`16#FF`) — tested.
- The bench suite (`bench/symbolic_bench.erl`, `docs/benchmarking.md`) runs
  clean post-dedup.

## Follow-ups, in priority order

1. **Commit the work.** Five separable units, each with its evidence attached:
   the `html_block` fix + fixture; the rules-library perf work (`count_pairs`
   BIP, merge-join closure, cycle core, `rev/2`) + its query tests; the
   `entry_point` fix; the `handle_call` flattenings; the dedup +
   `ts_extract_common` + the doc pass.

2. **DONE — the `fun Name/Arity` blindness.** `fun_ref/4` exists now
   (see finding 3 above); `truly_uncalled/3` consults it. Remaining
   blindness, documented in the rule itself: `member(...)` dynamic dispatch
   and callers outside this same parse.

3. **Document the two erlog traps in `docs/erlog-missing-builtins.md`**, or
   the next agent rediscovers both the hard way: (a) `reverse/2`'s O(n²) BIP —
   the measured 39s-on-981-elements number, and why `rules.pl` carries `rev/2`;
   (b) `count_pairs/2` as a project-added builtin alongside `sub_text/5` and
   `atom_from_binary/2`.

4. **DONE — the rules-library performance regression guard.**
   `test/rules_perf_tests.erl` scans this repo's full configured tree
   (src, test, docs) fresh, then runs the four flagship goals through
   `run_result/3` — whose standard 5s proof budget IS the assertion:
   a timeout surfaces as `{error, {query_failed, timeout}}` and fails the
   test. Deliberately no wall-clock assert (flakey on loaded CI); the
   budget already gives ~6x headroom over the measured 0.3–0.8s proofs.
   Verified to actually guard: a temporarily reintroduced O(n²)
   `reverse/2` in `top_fan_out/2` fails the test on this base — and
   PASSES it on a src-only base, which is why the guard uses the full
   tree (a quadratic regression is invisible until the base is big
   enough; src alone isn't).

5. **Two known-cost edges, watch rather than fix now.**
   `all_reaches_pairs/1` deliberately computes the full closure (~9s on this
   base; times out at the 5s budget for MCP callers — its contract is *every*
   pair, and bound-start `reaches/2` is the budget-safe path, documented in
   `rules.pl`). And `truly_uncalled/3`'s per-candidate negations scan the
   unindexed fact store — fine at this size, the same quadratic class as what
   was fixed if the tree grows 5–10×.
