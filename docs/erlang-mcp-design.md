# Design: An Erlang/OTP MCP Server for Prolog (rebar3 + erlmcp + erlog)

This document describes an alternative to [`readme.md`](../readme.md)'s
Python + SWI-Prolog design: run Prolog **in-process on the BEAM**, with no
external `swipl` binary, using [rebar3](https://rebar3.org/) as the build
tool, [erlmcp](https://github.com/erlsci/erlmcp) as the MCP server SDK, and
[erlog](https://github.com/rvirding/erlog) as the Prolog engine. **Implemented**
— `symbolic serve` (`src/symbolic_serve.erl`) is this design, built and
verified end-to-end over real stdio JSON-RPC (see §2.1 for two real
integration issues found and fixed along the way, not knowable from
erlmcp's own docs). It targets the same four-tool contract as `readme.md`
§3 so the two backends stay interchangeable from the client's point of
view.

## 1. Architecture

```
Claude/LLM  <--MCP(stdio/TCP/HTTP)-->  erlmcp_server  <--in-process-->  prolog_session (gen_server, owns one erlog state)
 (client)         (erlmcp)              (BEAM node)                     prolog_session_sup (one child per session)
```

The whole stack runs as one BEAM node: `erlmcp_server` terminates MCP, a
supervised pool of `prolog_session` workers each wrap one `erlog` state, and
there is no subprocess boundary between the MCP transport and the Prolog
engine — session isolation comes from Erlang process isolation, not OS
process isolation (see §8).

## 2. Toolchain

- **rebar3** — standard, no open questions.
- **erlmcp** (`erlsci/erlmcp`, Apache 2.0, requires OTP 25+, **Hex package**
  `erlmcp` — a plain `{erlmcp, "0.5.1"}` dependency, no vendoring needed,
  unlike `erl_ts`). It is a community SDK, not the official Anthropic one;
  §2.1 covers what turned out to actually need verifying.
- **erlog** (`rvirding/erlog`, Apache 2.0) — **dormant**: last commit
  2022-04-18, latest tag `v0.6`. Written by Robert Virding (Erlang core
  team, LFE author), so the code quality is solid, but there will be no
  upstream fixes. Any gap found here (see §5) is either worked around
  locally or forked.
- `Brewfile` already has `erlang`/`rebar3` (added when the CLI itself was
  built) — nothing extra needed for the server.

### 2.1 Two real integration issues, found by building it

Neither is discoverable from erlmcp's own README/docs — both required
actually compiling and running it.

- **`erlmcp` 0.5.1 fails to compile on OTP 29.** It uses the prefix
  `catch Expr` form, deprecated in OTP 29; something in the OTP 29
  compiler escalates that specific deprecation to a hard error
  (confirmed: not a `warnings_as_errors` setting — overriding erlmcp's
  own `erl_opts` down to just `[debug_info]` still failed identically).
  Fix: a rebar3 `overrides` entry adding the `nowarn_deprecated_catch`
  compile directive named right in the warning text, scoped to just this
  dependency (see `rebar.config`).
- **The README's own usage example doesn't produce a working stdio
  server.** `erlmcp_server:start_link({stdio, []}, Capabilities)` starts
  a process, but it isn't wired into any actual stdin-reading loop unless
  the `erlmcp` OTP application itself has been started first — and
  nothing says so. The API that actually works, found by reading
  `erlmcp_stdio.erl`/`erlmcp_stdio_server.erl` directly: call
  `application:ensure_all_started(erlmcp)`, then
  `erlmcp_stdio:start/0` (which goes through `erlmcp_sup`, erlmcp's real
  top-level supervisor) and `erlmcp_stdio:add_tool/4` — not
  `erlmcp_server:add_tool_with_schema/4`. Verified end-to-end with a
  hand-written stdio JSON-RPC client: `initialize` → `tools/list` →
  `tools/call` for all four tools, correct responses throughout.

## 3. Tool surface

**Implemented as designed**, in `src/symbolic_serve.erl`, registered via
`erlmcp_stdio:add_tool/4` (not `erlmcp_server:add_tool_with_schema/4` —
see §2.1):

- `prolog_start_session() -> session_id` — starts a `prolog_session` child
  under `prolog_session_sup` (`simple_one_for_one`); the child calls
  `erlog:new/0` and holds the resulting state. The session_id ↔ pid
  mapping lives in `prolog_session_registry`, a small ETS-backed
  `gen_server` — MCP tool handlers are stateless (`Params -> Result`),
  so something has to bridge them to a stateful `erlog` session across
  separate tool calls; this is that bridge.
- `prolog_consult(session_id, program: str) -> ok | error` — parses the
  program text and asserts clauses into that session's `erlog` state, via
  `prolog_session:consult_string/2` (writes to a temp file and reuses the
  already-tested `erlog:consult/2` path, rather than reaching into
  `erlog_int`'s internals).
- `prolog_query(session_id, goal: str) -> bindings[] | error` — proves the
  goal, returns bindings or `"No."` as plain text (structured erlog↔JSON
  marshalling per §4 below is not yet built; text is enough for an LLM
  agent to consume, and keeps this proportional to what's already built
  for the CLI). Simpler than originally sketched: no `max_solutions`
  param yet — one solution only, matching `erlog:prove/2`'s own single-
  solution-per-call shape; backtracking via `next_solution/1` would be
  the way to add multi-solution support later.
- `prolog_end_session(session_id)` — terminates the child via the
  supervisor and removes the registry entry.

## 4. Data marshalling (erlog term ↔ JSON)

erlog's term representation (from `erlog.erl`) is different from a
JSON-friendly shape and must be converted explicitly in a `prolog_marshal`
module:

- Atoms → Erlang atoms → JSON strings.
- Numbers → Erlang integers/floats → JSON numbers (same arbitrary-precision
  caveat as `readme.md` §4 — Erlang integers are bignums, JS/JSON numbers
  are not).
- Lists → Erlang lists → JSON arrays.
- Variables → erlog represents an unbound variable as `{Name}` (a 1-tuple);
  don't drop these — represent explicitly, e.g. `{"var": "X"}`, matching
  `readme.md` §4.
- Compound terms → erlog represents a structure as a tuple
  `{Functor, Arg1, Arg2, ...}` where `Functor` is an atom — map this
  directly to `{"functor": ..., "args": [...]}`.
- Double-quoted strings → the scanner (`erlog_scan.xrl`) tokenizes `"..."`
  into a raw character list (`chars/1`), which looks like the same
  code-list behavior SWI defaults to (`double_quotes=codes`, per
  `docs/prolog-as-primary-reasoner.md`). **Verify this with a scripted
  check before relying on it** — if confirmed, the same "atoms for names,
  `atomic_list_concat`-equivalent for text" discipline applies here too.
- Prolog/erlog errors → `erlog:prove/2` returns `{{error, Error}, State}`
  (see `erlog.erl`'s `prove_result/3`) rather than throwing past the
  boundary — map `Error` to a structured MCP tool error, not a crash.

## 5. Known engine gap: no tabling, no CLP(FD)

`erlog:new/0` loads exactly three modules into a fresh database:
`erlog_bips`, `erlog_lib_dcg`, `erlog_lib_lists`. There is no tabling
module and no constraint solver. This directly conflicts with a **hard
rule** already established in `docs/prolog-as-primary-reasoner.md`:

> Recursive predicates over possibly-cyclic graphs MUST be tabled:
> `:- table pred/arity.`

On erlog there is no `:- table` to reach for. A transitive-closure query
(exactly the kind `graph-facts/` exists to generate facts for) over a
cyclic graph **will not terminate** — leftmost SLD resolution with no
memoization loops forever, same failure mode the SWI doc describes for
*untabled* recursion, except here there's no fix available in the engine
itself.

This must be resolved before erlog is used for graph-reachability queries.
Options, roughly in order of effort:

1. **Cycle-guard wrapper predicate.** Thread a "visited" accumulator
   through the recursive rule and fail on revisit, e.g.
   `tdp(A, B, Visited) :- depends(A, M), \+ member(M, Visited), tdp(M, B, [M|Visited])`.
   Correct, no engine changes, but pushes the burden onto whoever (LLM or
   human) writes the rule — the exact "coherent-but-wrong translation" risk
   `docs/lorp-approach.md` and `docs/grpo-prolog-tool.md` flag, since a
   forgotten guard silently reproduces the hang.
2. **Compute closure in Erlang, not Prolog.** Since the whole thing already
   runs on the BEAM, transitive closure over a cyclic graph is a
   straightforward Erlang graph traversal (e.g. via `digraph`) done before
   or alongside the erlog session, with the result asserted back as facts.
   Trades "Prolog does the reasoning" purity for correctness; consistent
   with the existing guidance to route what doesn't fit Prolog's execution
   model elsewhere (`readme.md`'s Z3 split is the same idea).
3. **Add tabling to a local fork of erlog.** Highest effort, and erlog is
   unmaintained upstream (§2) so a fork wouldn't get reviewed or merged
   back — only worth it if this becomes a heavily-used backend.
4. **Server-side timeout as a safety net regardless of which option above
   is chosen** — see §8. This bounds the damage but does not make an
   untabled cyclic query return a correct answer set; it just stops it from
   hanging the session forever.

Until one of 1–3 is chosen and tested, treat erlog as **not yet suitable**
for the reachability/transitive-closure use case that motivated `chiasmus`'s
tabling requirement in the first place, even though it's fine for
non-recursive or acyclic rule inference.

## 6. Predicate coverage: what's missing relative to SWI/ISO

Read directly from source (`erlog_int.erl`, `erlog_bips.erl`,
`erlog_lib_lists.erl`, `erlog_lib_dcg.erl`), not from the README's vague "a
subset of the standard":

**Solid.** Core control flow is real ISO-equivalent behavior: `,`/`;`/`->`
/if-then-else, properly-scoped cut, `\+` (negation as failure), `call/1`,
`once/1`, `fail`/`true`. DCG translation (`-->`, `phrase/2,3`) is also
implemented (`erlog_lib_dcg.erl`).

**Missing — likely to break typical LLM-generated Prolog immediately:**

| Category | Present | Missing |
|---|---|---|
| Exceptions | — | `catch/3`, `throw/1` (not in the core proof loop at all — see §7 tier 3) |
| Generate/bound | — | `between/3` |
| Higher-order | — | `maplist/2..5`, `foldl/3..6`, `include/3`, `exclude/3` |
| Solutions | `findall/3` | `bagof/3`, `setof/3` |
| Lists (`erlog_lib_lists.erl` has only 7 predicates) | `length/2`, `append/3`, `insert/3`, `member/2`, `memberchk/2`, `reverse/2`, `sort/2` | `msort/2`, `keysort/2`, `nth0/nth1`, `last/2`, `permutation/2`, `subtract/3`, `intersection/3`, `union/3`, `sum_list/2`, `max_list/2`/`min_list/2`, `numlist/3` |
| Atoms/strings | `atom_chars/2`, `atom_codes/2`, `atom_length/2` | `atom_concat/3`, `split_string/4`, `number_codes/2`, `atom_number/2` — `sub_atom/5` and `sub_text/5` are missing from *erlog itself* but shipped as this project's own extension, `src/symbolic_prolog_lib.erl` (see §7 tier 2, `docs/erlog-missing-builtins.md`) |
| I/O | `write`/`writeq`/`write_canonical`/`nl`/`read/1` | `format/2,3`, stream I/O (`open/3`, `close/1`, `see/1`, `tell/1`) |

**Missing — matters for this repo's specific use cases (see §5):** no
tabling, no CLP(FD)/CLP(QR)/CLP(B).

**Missing — lower practical impact:** no modules, no Erlang maps as a term
type, opaque types (refs/ports/pids) only support `==`/`\=`.

**Net effect:** the tabling gap in §5 is one instance of a broader pattern.
erlog implements ISO *control flow* faithfully but a much smaller *library*
than SWI. Prolog generated in the style `docs/prolog-as-primary-reasoner.md`
and `docs/lorp-approach.md` describe (which assumes SWI's full builtin set)
will fail on missing predicates far more often against erlog than against
SWI, independent of tabling.

## 7. Extending erlog: three tiers, and which ones need a fork

Closing the gaps in §6 splits into three tiers of effort and risk. This
matters because they are easy to conflate — "erlog is missing X" does not
by itself imply "we must fork erlog."

### Tier 1 — pure Prolog, no Erlang code, no fork

Most of the library gaps in §6 (`between/3`, `maplist`, `foldl`, `msort`,
`nth0`/`nth1`, `last`, `permutation`, `subtract`/`intersection`/`union`,
`sum_list`/`max_list`/`min_list`, even a workable `atom_concat/3` via
`atom_codes`+`append`) can be written as ordinary Prolog clauses on top of
what erlog already has, then loaded via `erlog:consult/2` as a "prelude"
every session pulls in automatically at `prolog_session` startup — no
Erlang code, no engine knowledge, lowest risk. Example:

```prolog
between(L, H, L) :- L =< H.
between(L, H, X) :- L < H, L1 is L + 1, between(L1, H, X).
```

### Tier 2 — native Erlang builtins via `add_compiled_proc/4`, no fork

For predicates that need custom control (e.g. `sub_atom/5`'s multiple
nondeterministic modes, `format/2`) — the mechanism this project has
actually since used, shipping both `sub_atom/5` and `sub_text/5` this
way (`src/symbolic_prolog_lib.erl`, `docs/erlog-missing-builtins.md`) —
erlog_int.erl's goal dispatch has two registration paths, and only one
of them is fork-only:

```erlang
%% erlog_int.erl — prove_goal/3 dispatch on a functor already in the db
try get_procedure(functor(G), Db) of
    built_in          -> erlog_bips:prove_goal(G, Next, St);  %% hardcoded target
    {code,{Mod,Func}} -> Mod:Func(G, Next, St);               %% generic — any module
    {clauses,Cs}      -> prove_goal_clauses(G, Cs, Next, St);
```

- `erlog_int:add_built_in/2` marks a functor as core; dispatch is
  **hardcoded to `erlog_bips:prove_goal/3`** — this path cannot target an
  external module without patching `erlog_int.erl`/`erlog_bips.erl`
  (fork-only).
- `erlog_int:add_compiled_proc/4` stores `{code,{Mod,Func}}`, and the
  dispatch line calls `Mod:Func(Goal, Next, State)` **generically on
  whatever module is registered**. No core file is touched.

This is not a hypothetical extension point: `erlog_lib_lists.erl`,
`erlog_lib_dcg.erl`, and `erlog_ets.erl` — all three predicate libraries
that ship with erlog — use exactly this `add_compiled_proc` path, none of
them go through `erlog_bips`/`add_built_in`. `erlog_ets` in particular is
the precedent to copy: a self-contained module adding new predicates
(`ets_match/2`), loaded at runtime with `erlog:load(Pid, erlog_ets)`.

To add a Tier 2 predicate: write a module (e.g. `prolog_ext_lists.erl`) in
our own rebar3 app with a `load/1` that calls
`erlog_int:add_compiled_proc({between,3}, prolog_ext_lists, between_3, Db)`
etc., implement `between_3(Goal, Next, State)` using `erlog_int`'s exported
`unify_prove_body/4`/`deref/2`/`unify/3`, and call
`erlog:load(prolog_ext_lists, ErlogState)` when a session starts.

**Real caveat, distinct from forking:** this couples our code to
`erlog_int`'s internal `#est{}`/`#db{}` records and continuation-passing
calling convention, which the project treats as implementation detail, not
a stable public API, and there is no upstream maintainer (last commit
2022-04-18, §2) to keep that contract from shifting under us. No fork is
required, but the code we write lives inside erlog's internals — a real
form of lock-in even without a repo fork.

### Tier 3 — `catch/throw` and tabling: this needs a fork

`catch/3`/`throw/1` are absent from the core proof loop itself, not just
missing from a library — confirmed by grepping `erlog_int.erl` for any
`{{catch},...}`-style clause (there is none). Adding them means threading
exception-unwinding through the same continuation (`Next`) and choicepoint
(`St#est.cps`) machinery that implements cut and backtracking — that is a
cross-cutting change to every goal's control flow, not a new functor, and
cannot be done through `add_compiled_proc`. The same is true for tabling
(§5, option 3): it requires a memoization layer inside that same core loop.
Both therefore require an actual fork of `erlog_int.erl`, maintained
locally with no chance of upstream review.

### Recommendation

Start with Tier 1 (low risk, closes most of the practical gap in §6
immediately). Add Tier 2 predicates case-by-case as they're actually hit,
accepting the internals-coupling caveat above. Treat Tier 3 (`catch/throw`,
tabling) as a separate, bigger decision — it changes erlog from "a library
we depend on" to "a library we maintain a permanent fork of."

## 8. Process model, isolation, and timeouts

This is where the Erlang engine is a genuinely better fit than the Python
design's isolation tradeoffs (`readme.md` §2's three options, all of which
pay either a process-spawn cost or an in-process-crash risk):

- **Isolation is structural, not bolted on.** One `prolog_session` gen_server
  per MCP session, under a `simple_one_for_one` supervisor, gives per-session
  fault isolation for free — a crash in one session's erlog state doesn't
  affect any other session or the MCP server itself, without spawning an OS
  process per session the way the SWI subprocess/MQI options do.
- **Attack surface is smaller by construction.** `erlog_bips.erl` has no
  `shell`, `os:cmd`, `open_port`, or filesystem-touching builtins — the
  category of predicate `readme.md` §6 says to sandbox against
  (`shell/1`, `open/3`, `halt/0`) largely doesn't exist in erlog's builtin
  set at all. This doesn't mean skip validation (a future erlog version, a
  loaded library module, or a locally-added BIP could change this) but the
  starting risk is materially lower than SWI's full builtin library.
  `consult/reconsult` take a *file path chosen by our own Erlang code*, not
  something a proven Prolog goal can invoke — so there's no path from
  LLM-supplied Prolog text to arbitrary file reads the way there would be if
  a goal itself could call a file-reading BIP.
- **A `gen_server:call` timeout does NOT stop computation.** This is the one
  place naive code will get it wrong: if `prolog_session` calls
  `erlog:prove/2` directly inside `handle_call/3` and the caller times out,
  the gen_server process keeps executing the (possibly infinite) proof —
  the timeout only stops the *caller* from waiting, not the callee from
  spinning. The fix: run `erlog:prove/2` in a separate `spawn_monitor`ed
  process, `receive` its result with an explicit timeout, and
  `exit(WorkerPid, kill)` on timeout. This is the direct BEAM analogue of
  `readme.md` §6's `call_with_time_limit/2` requirement — same rule,
  different mechanism (preemptive process kill instead of a library call).
  **Implemented**: `prolog_session:query/2,3` does exactly this (a 5s
  default timeout, overridable via `query/3` — mainly so tests can use a
  short one), verified with a real regression test: a deliberately cyclic
  `loop(X) :- loop(X).` goal is killed within budget, and the session
  stays usable for a normal query immediately afterward
  (`test/prolog_session_timeout_tests.erl`).
- Resource limits beyond wall-clock (memory, reduction count per session)
  can use `erlang:process_flag(max_heap_size, ...)` on the session process
  — no per-session container is needed for this class of limit, unlike the
  OS-level approach `readme.md` recommends for SWI subprocesses.

## 9. Testing strategy

Same categories as `readme.md` §8, plus one specific to this engine. See
[`testing-erlang.md`](testing-erlang.md) for the `rebar3` tooling
(EUnit/Common Test/PropEr/cover) behind these bullets.

- **Correctness**: same word-problem-style Prolog programs, run against
  both backends where possible to catch semantic divergence early (string
  handling, error shapes, arithmetic).
- **Cyclic-graph regression test**: a deliberately cyclic `depends/2` fact
  set and an untabled transitive-closure rule, asserted to *not* hang past
  the session timeout — this is the test that would have caught §5 before
  shipping. A single fixture only checks one graph shape; see
  [`testing-erlang.md`](testing-erlang.md) §3.4 for generating this as a
  PropEr property over random (including cyclic) graphs instead.
- **Failure modes**: malformed programs, undefined predicates, no-solution
  queries — verify `erlog:prove/2`'s `{error, Error}` shape reaches the MCP
  client as a structured tool error, not a crashed session.
- **Timeout kill test**: an intentionally infinite-looping predicate,
  confirm the `spawn_monitor` + `exit(Pid, kill)` path in §8 actually
  reclaims the session within budget and the session is usable again
  afterward (or is cleanly restarted by the supervisor).
- **erlmcp integration**: since erlmcp is a smaller/younger SDK than the
  official Python one, add a smoke test that goes through the actual MCP
  transport (stdio), not just direct calls to `prolog_session`.

## 10. Open questions

- Confirm double-quoted string semantics empirically (§4) before writing
  the "how to write erlog Prolog" guidance — do not assume parity with SWI.
- Pick one of the §5 tabling-gap mitigations before using this backend for
  any reachability-style query; until then, scope this backend to
  non-recursive / acyclic rule inference only.
- Decide whether `graph-facts/` output should target this backend at all,
  or stay SWI-only until §5 is resolved.
- Build the Tier 1 prelude (§7) as the first concrete implementation step
  once the rebar3 scaffold exists, since it's the lowest-risk way to close
  most of the §6 predicate gap.

## References

- rebar3: `https://rebar3.org/`
- erlmcp: `https://github.com/erlsci/erlmcp`
- erlog: `https://github.com/rvirding/erlog`
- Baseline design (Python + SWI-Prolog): [`readme.md`](../readme.md)
- Tabling requirement this design must satisfy or work around:
  [`docs/prolog-as-primary-reasoner.md`](prolog-as-primary-reasoner.md)
- Testing tooling (EUnit/Common Test/PropEr/cover) §9 runs on:
  [`testing-erlang.md`](testing-erlang.md)
- NLP tooling survey, scoped by this design's no-subprocess philosophy:
  [`nlp-tooling.md`](nlp-tooling.md)
