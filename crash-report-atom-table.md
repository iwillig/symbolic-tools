# symbolic serve crashes: `sub_atom/5` fills the BEAM atom table

## Summary

`symbolic serve` (symbolic-tools 0.4.0, Homebrew) dies while proving a goal
that contains `sub_atom(File, _, _, _, 'needle')`. The BEAM exits with
`no more index entries in atom_tab (max=1048576)`. The cause is
`symbolic_prolog_lib:sub_chars_search/11`, which calls
`erlang:list_to_atom/1` for every candidate substring it enumerates. With
`Before`, `Length` and `After` unbound, one 100-character file path yields
about 5,000 substrings, each a new atom. Atoms are never garbage collected,
so every `sub_atom` query leaks into the next; the table fills after a few
queries and the whole server exits. The MCP client sees `Connection closed`,
and every tool call after the restart answers
`no codebase is cached - call parse first`.

The crash is reproducible. It hit twice in one session, 4 minutes apart,
on two different goals with the same shape.

## Environment

| Item | Value |
|---|---|
| symbolic-tools | 0.4.0 (`/opt/homebrew/Cellar/symbolic-tools/0.4.0`, release libs: erlog-0.7, erlmcp-0.5.1, erllama-0.11.0, symbolic_tools-0.4.0) |
| Launch | `symbolic serve` over stdio, from `~/.claude.json` mcpServers; wrapper runs `erl -pa lib/*/ebin -noshell -eval "symbolic_cli:main(...)"` with no `+t` flag |
| Erlang/OTP | 29, erts-17.1, JIT, 18 schedulers |
| OS | macOS 26.7.1 (Darwin 25.6.0), 64 GB RAM |
| Client | Claude Code 2.1.292 |
| Project | `/Users/iwillig/oneproject/common` (TypeScript monorepo) |
| Scan | 2,061 files, 1,267,808 facts; `defines` 1,135 rows, `calls` 66,483, `literal` 18,033, `object_key` 46,853, `var_ref` 109,918 |
| Database | `.symbolic/facts.dets` (487 MB), `.symbolic/facts.dets.text_idx` (5.3 MB) |
| Config | `.symbolic/config.json`: paths apps, configs, packages, services, tests, docs; 22 tsconfig projects |
| Log | `~/Library/Logs/symbolic/serve.log` |
| Crash dump | `/Users/iwillig/oneproject/common/erl_crash.dump`, 1.59 GB, written 2026-10-15 17:35:16 into the project cwd; not gitignored |

## Crash 2 (fully captured)

Goal sent at 2026-10-15T17:35:07.080 (serve.log line 115036):

```prolog
literal(_, Fn, _, string, V, F, L, Raw),
sub_atom(F, _, _, _, 'functions/notifications/handle'),
sub_text(V, _, _, _, "event.data")
```

No `query: error=` line follows. The next log line is
`symbolic serve starting` at 17:35:28.338 (line 115038): Claude Code
restarted the server after the process exited. The crash dump timestamp is
17:35:16, nine seconds into the query.

### erl_crash.dump header

```
=erl_crash_dump:0.5
Thu Oct 15 17:35:16 2026
Slogan: no more index entries in atom_tab (max=1048576)
System version: Erlang/OTP 29 [erts-17.1] [source] [64-bit] [smp:18:18] [ds:18:18:10] [async-threads:1] [jit] [dtrace]
Taints: symbolic_text,symbolic_ts
Atoms: 1048576
Calling Thread: scheduler:1
Current Process: <0.2218.0>
Current Process Program counter: 0x000000014919c560 (erlang:list_to_atom/1 + 24)
Current Process Limited Stack Trace:
  symbolic_prolog_lib:sub_chars_search/11 + 248
  erlog:next_solution/1 + 152
  symbolic_codebase:more_solutions/3 + 220
  symbolic_codebase:'-prove_all_with_timeout/3-fun-0-'/4 + 88
```

### Memory section

```
=memory
total: 1336117155
processes: 1027455752
system: 308661403
atom: 91102795
atom_used: 91102795
binary: 122085016
ets: 722120
=hash_table:atom_tab
size: 1048576
used: 662080
```

### Crashing process

```
=proc:<0.2218.0>
Spawned as: erlang:apply/2
Spawned by: <0.124.0>
Last scheduled in for: erlang:list_to_atom/1
Reductions: 3750046592
Stack+heap: 4298223
OldHeap: 31936144
Memory: 289875792
```

3.75 billion reductions in 9 seconds: the solver was still enumerating
substrings, not blocked.

### Atom table contents

The dump's `=atoms` section (line 19,596,235 onward) holds 1,048,576 atoms.
939,383 of them contain a `/`. They are substrings of file-path atoms,
every start offset times every length. A sample:

```
'ces/getDecisionBySlug.test.ts'
'ces/getDecisionBySlug.test.t'
'ces/getDecisionBySlug.test.'
'ces/getDecisionBySlug.test'
'ces/getDecisionBySlug.tes'
'ces/getDecisionBySlug.te'
'nces/getDecisionBySlug.test.ts'
'nces/getDecisionBySlug.test.t'
'nces/getDecisionBySlug.test.'
'ances/getDecisionBySlug.test.ts'
'tances/getDecisionBySlug.test.ts'
'stances/getDecisionBySlug.test.ts'
'nstances/getDecisionBySlug.test.ts'
```

The pattern (one atom per `(start, length)` pair, lengths shrinking to the
needle length) shows `sub_chars_search/11` converting each candidate to an
atom before, or instead of, comparing it to the bound `Sub` argument.

## Crash 1 (same shape, no dump kept)

Goal at 2026-10-15T17:30:53.283 (serve.log line 112611):

```prolog
defines(Fn, A, P, F, L), sub_atom(F, _, _, _, 'twilio')
```

Next log line: `symbolic serve starting` at 17:31:05.999 (line 112613), no
error logged. The crash dump from this exit was overwritten by crash 2
(same cwd, same default `erl_crash.dump` name).

Two parallel queries sent in the same batch (`import_decl(M, F, L),
sub_atom(M, _, _, _, twilio)` and a `search`) were lost with it.

## Why earlier `sub_atom` queries survived

These goals ran fine in the same server lifetime, minutes earlier:

```prolog
calls(_, _, member(inngest, createFunction, _), F, L),
  sub_atom(F, 0, _, _, '/Users/iwillig/oneproject/common/services/workflows/src/functions/')
calls(C, _, local(getPhoneSignupState, N), F, L)
import_decl(M, F, L), sub_atom(M, _, _, 0, smsInboundLimits)
```

The first binds `Before = 0`, so only one substring per row is tried. The
third binds `After = 0`, same effect. The crashing goals leave all three
positions unbound and scan a large family (`defines` is small at 1,135 rows,
but each row's `File` is an absolute path of 80-130 characters, giving
roughly 1,135 x 5,000 = 5.7 M candidate atoms; `literal` has 18,033 rows).
Atoms accumulate across queries, so the failing query is the one that
crosses the line, not the only one that leaks.

## Reproduction

1. `cd /Users/iwillig/oneproject/common && symbolic serve` (or let Claude
   Code start it), call `parse`.
2. Call `query` with goal
   `defines(Fn, A, P, F, L), sub_atom(F, _, _, _, 'twilio')`.
3. The process exits within about 10 s, writes `erl_crash.dump` into the
   cwd, and the slogan reads `no more index entries in atom_tab`.

A smaller fact base needs more queries before the exit; the atom count in
`erlang:system_info(atom_count)` grows monotonically with each call.

## Suggested fixes

1. `symbolic_prolog_lib:sub_chars_search/11`: when `Sub` is bound, search
   the subject's character list (or binary) for the needle with
   `string:find/2`, `binary:match/2` or a plain list walk, and never build
   an atom for a candidate. The result positions are integers; `Sub` is
   already an atom. Only when `Sub` is unbound does a result atom need to
   exist, and even then `list_to_atom` should be deferred until a candidate
   is actually returned as a solution, not called per candidate.
2. Apply the same review to `sub_text/5`, `atom_concat/3`, `atom_chars/2`
   and any other library predicate that converts a candidate to an atom
   inside a search loop.
3. Defensive: in `symbolic_codebase:prove_all_with_timeout/3`, sample
   `erlang:system_info(atom_count)` before and after a proof and refuse or
   abort a goal when the delta passes a threshold, returning
   `{error, atom_table_exhausted}` instead of letting the VM exit.
4. Launcher (`bin/symbolic`): set `ERL_CRASH_DUMP` to
   `~/Library/Logs/symbolic/erl_crash.dump` (or `ERL_CRASH_DUMP_BYTES=0`)
   so a 1.6 GB dump does not land in the user's project root. Raising the
   atom limit with `+t` only delays the exit and is not a fix.
5. Log the goal with a `query: error=` line on abnormal exit paths where
   possible, so serve.log shows the cause rather than a bare restart.

## Related, lower priority

- `sub_text/5` raises `{type_error,binary,N}` when the fact's value column
  holds an integer or atom (seen on `literal/8` with `Kind` unbound, and on
  `import_decl/3` whose `Module` is an atom). A guard or a documented
  `is_binary` check would let a goal filter mixed columns.
- `facts.dets.scan.json` reports `typescript_analysis.status = partial`:
  8 of 22 tsconfig projects time out (apps/api, apps/app, packages/common,
  packages/hooks, services/api, services/workflows, tests/e2e). Separate
  issue; noted because `type_analysis` is reported as unavailable in the
  parse result.
