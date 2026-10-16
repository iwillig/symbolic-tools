# Research: `sub_atom/5` and atom-table exhaustion

## Finding

The crash report's central mechanism is strongly supported by both the local implementation and Erlang's documented semantics. In `src/symbolic_prolog_lib.erl`, `sub_atom_5/3` passes `fun list_to_atom/1` into `sub_chars_search/11`. That search constructs a substring with `ToTerm(...)` **before** it tries unification against the caller's `Sub` (`try_unify4/…`). Thus even a bound needle is preceded by atom construction for each candidate visited. The reported crash stack at `list_to_atom/1` inside `sub_chars_search/11` matches this source path.

Erlang's official `erlang` documentation says `list_to_atom/1` returns the corresponding atom, creating a new atom if necessary; `list_to_existing_atom/1` only succeeds if it already exists. This confirms the dangerous operation, though it does not independently establish the report's exact runtime counts or cross-query measurements. [1]

## Search-space implications

The implementation's enumeration visits every `(Before, Length)` split, including empty substrings. For a character list of length `N`, the candidate count is `(N+1)(N+2)/2` (5,151 at `N=100`). With `Sub` bound but positions unbound, most candidates are converted to atoms and then rejected at unification. This is avoidable: compare candidate character ranges directly to the bound needle, and only construct/unify the Prolog atom for a candidate that can match. The matching logic must preserve all supported argument modes and backtracking/order semantics.

If `Sub` is unbound and the caller enumerates results, returning substring atoms inherently requires atom terms. Merely deferring conversion until a candidate is yielded prevents interning rejected candidates but does **not** bound atom growth from enumerated distinct results. Safer API design would constrain modes (require `Sub` or at least one positional constraint), represent generated substrings as code lists/binaries, or impose an explicit enumeration limit. The right choice depends on compatibility requirements; no single option is established by the crash evidence.

## Safeguards and secondary suggestions

- Raising the atom limit is not a root-cause fix: it allows more atoms before exhaustion. OTP's `+t` flag is documented as setting a limit, not reclaiming atoms. [2]
- Sampling `system_info(atom_count)` around a proof is only a coarse guard: unrelated processes can allocate atoms concurrently, and checking after a proof cannot prevent crossing the VM's limit during that proof. Prefer preventing unneeded atom creation at the predicate boundary. Treat atom-count monitoring as telemetry, not a reliable isolation mechanism.
- Crash-dump relocation is operational hygiene, not a crash fix. OTP documents `ERL_CRASH_DUMP` and `ERL_CRASH_DUMP_BYTES` as runtime environment controls; select a user-writable, platform-appropriate log path and test the actual launcher environment. [2]
- Audit other code paths that turn untrusted or high-cardinality strings into atoms, but verify each independently. `sub_text/5` currently uses a code-list result converter, not `list_to_atom/1`, so the specific atom-leak mechanism described here does not directly apply to it.

## Recommended investigation / fix sequence

1. Add regression tests measuring that a bound-needle `sub_atom/5` query does not grow `erlang:system_info(atom_count)` with candidate count. Use fresh VMs or account for test-runner baseline; assert semantic results and backtracking too.
2. Change the bound-`Sub` path to compare character ranges without creating atoms for non-matches. Preserve atom creation only for candidates actually unified as results where required by API behavior.
3. Decide and document behavior for unbound `Sub`; test limits or an alternate output representation if enumeration is supported.
4. Audit neighboring atom conversion operations and separately handle crash dump placement in the launcher.
5. Reproduce against the affected release / realistic fact base and verify atom count, elapsed reductions, and server survival.

## Sources

1. Erlang/OTP 29.1.2 official `erlang` BIF docs: [`list_to_atom/1`](https://www.erlang.org/doc/apps/erts/erlang.html#list_to_atom/1) (creates an atom if necessary) and [`list_to_existing_atom/1`](https://www.erlang.org/doc/apps/erts/erlang.html#list_to_existing_atom/1) (requires an existing atom).
2. Erlang/OTP 29.1.2 official [`erl` command documentation](https://www.erlang.org/doc/apps/erts/erl_cmd.html): emulator `+t` atom-table limit, and the crash-dump environment variables `ERL_CRASH_DUMP` / `ERL_CRASH_DUMP_BYTES` (see the crash dump section).
3. Local implementation: [`src/symbolic_prolog_lib.erl`](../src/symbolic_prolog_lib.erl), `sub_atom_5/3`, `sub_chars_search/11`, and `try_unify4/…`.
4. Incident observations and crash-dump evidence: [`crash-report-atom-table.md`](../crash-report-atom-table.md). These are user-provided report data, not independently reproduced in this research.
