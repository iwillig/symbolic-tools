# Design: Testing, Property-Based Testing, and Coverage (rebar3)

This document covers the `rebar3` tooling for tests and coverage: **EUnit**
for unit tests, **Common Test** for integration-style tests, **PropEr** for
property-based testing, and OTP's **`cover`** for coverage. It supplies the
tooling detail behind the testing strategies already sketched in
[`erlang-mcp-design.md`](erlang-mcp-design.md) §9 and
[`cli-erlang.md`](cli-erlang.md) §5. A design/research document only —
nothing here is implemented.

**Recommendation up front:**

- **Unit tests:** **EUnit** (stdlib, zero deps) for pure logic modules —
  `symbolic_parse`, `symbolic_query`, the `prolog_marshal` term↔JSON
  conversion.
- **Integration tests:** **Common Test** (`rebar3 ct`) for the
  `prolog_session` lifecycle, the erlmcp stdio smoke test, and invoking the
  escriptized binary — as already called for in `erlang-mcp-design.md` §9
  and `cli-erlang.md` §5.
- **Property-based tests:** **PropEr** (free, GPLv3), not Triq or Quviq
  QuickCheck. Use it specifically for the marshalling round-trip and the
  cyclic-graph/timeout invariant (`erlang-mcp-design.md` §5/§9) — properties
  a handful of hand-written cases will under-test.
- **Coverage:** turn on `cover_enabled` + `cover_export_enabled` from day
  one so EUnit, Common Test, and PropEr runs all merge into one `rebar3
  cover` report; add a CI export tool (`coveralls-erl` or `rebar3_codecov`)
  only once there's a CI pipeline to report to.
- **Mocking:** prefer not to — swap a behaviour implementation or run
  against the real (fast, in-process) collaborator, e.g. a real `erlog`
  session, instead of mocking it. Reach for **meck** only at genuine
  boundaries (an external service, `os:cmd`, a rarely-hit error path) — not
  for `erlog`, and not for anything NIF-backed like `symbolic_ts`
  ([`tree-sitter-erlang.md`](tree-sitter-erlang.md)), which meck cannot
  safely mock at all.

## 1. The three native tools, compared

| Tool | Command | Scope | Deps |
|---|---|---|---|
| **EUnit** | `rebar3 eunit` | fast unit tests, function-level | stdlib, zero deps |
| **Common Test** | `rebar3 ct` | integration/system tests, suites with setup/teardown | stdlib, zero deps |
| **`cover`** | `rebar3 cover` | coverage analysis, feeds off eunit/ct/proper runs | stdlib, zero deps |

All three ship in OTP itself — no third-party dependency is needed to get
unit tests, integration tests, and coverage working.

## 2. EUnit

Run with `rebar3 eunit`. It auto-compiles everything under `test/` and
compiles all project modules with `{d, TEST, true}` and `{d, EUNIT, true}`
defined, so test-only code can be gated with `-ifdef(TEST).`. Default
behavior is `eunit:test([{application, App}])` per app in the project.

Targeting a subset:

```sh
rebar3 eunit --module=symbolic_parse,symbolic_query
rebar3 eunit --test=symbolic_parse:parses_module_names+parses_calls
rebar3 eunit --dir="test,extra_tests"
```

`rebar.config` knobs:

```erlang
{eunit_opts, [verbose]}.               % or no_tty + a custom {report, {Mod, Args}}
{eunit_tests, [{module, smoke_tests}]}. % override the default test set
```

## 3. Property-based testing

### 3.1 Options

| Tool | License | Notes |
|---|---|---|
| **[Quviq QuickCheck](http://www.quviq.com/)** | commercial | Best-engineered implementation, but paid; not needed here. |
| **[PropEr](https://github.com/proper-testing/proper)** | GPLv3 | ✅ recommended — the standard free QuickCheck-alike, active. |
| **[Triq](https://triq.gitlab.io/)** | Apache-2.0 | Exists mainly for people who need a permissive license instead of PropEr's GPLv3; less powerful/active. |

GPLv3 only reaches code that includes PropEr's headers — i.e. your test
suite, which never ships in a release — so it does not affect the license
of `symbolic-tools` itself.

### 3.2 rebar3 setup

```erlang
{plugins, [rebar3_proper]}.

{profiles, [
  {test, [
    {deps, [{proper, "1.5.0"}]}
  ]}
]}.

{proper_opts, [{numtests, 200}]}.
```

Run with `rebar3 proper`.

### 3.3 EUnit interop gotcha

PropEr's `?LET` macro collides with EUnit's. Fix: include PropEr's header
**before** EUnit's:

```erlang
-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").
```

When calling `proper:quickcheck/2` from inside an EUnit test, pass
`{to_file, user}` — otherwise PropEr's counterexample output is swallowed by
EUnit's stdout suppression.

### 3.4 Where this repo needs it

Two properties in `erlang-mcp-design.md` are exactly the shape PropEr is
for — a broad input space where hand-picked examples miss cases:

- **Marshalling round-trip** (§4): for any generated erlog term (atom,
  number, list, `{Name}` variable, compound `{Functor, Args...}`),
  `json_to_erlog(erlog_to_json(Term)) =:= Term`.
- **Cyclic-graph/timeout invariant** (§5/§9): for any generated `depends/2`
  fact set — including cyclic ones — a bounded transitive-closure query
  either returns within the session timeout or is killed by it; it never
  hangs the session past that budget. Generate random graphs (including
  cycles) rather than relying on one fixed regression fixture.

## 4. Coverage

`rebar.config`:

```erlang
{cover_enabled, true}.
{cover_export_enabled, true}.
{cover_opts, [verbose]}.
{cover_excl_mods, []}.
```

- `cover_enabled` turns coverage on for any command that supports it —
  `eunit`, `ct`, and `proper` all feed into the same coverage data.
- `cover_export_enabled` writes `.coverdata` files (needed to merge across
  runs) instead of just an in-memory report.
- `cover_opts, [verbose]` prints the report to the terminal in addition to
  the HTML file.

Every test run with coverage enabled accumulates a `.coverdata` file;
running `rebar3 cover` afterward **merges all of them** into one report —
so an EUnit run, a Common Test run, and a PropEr run in the same CI job all
contribute to one combined number:

```sh
rebar3 eunit
rebar3 ct
rebar3 proper
rebar3 cover --verbose
```

Output: a terminal summary table, plus an HTML report at
`_build/test/cover/index.html`.

### 4.1 CI export

Only add once there is a CI pipeline to report to:

- **[`coveralls-erl`](https://github.com/markusn/coveralls-erl)** — `rebar3
  as test coveralls send` — for coveralls.io.
- **[`rebar3_codecov`](https://github.com/esl/rebar3_codecov)** — converts
  `.coverdata` to Codecov's JSON format instead.

### 4.2 `erlang:halt/0,1` as a coverage boundary — and why it's an
     anti-pattern to leave alone

`erlang:halt/0,1,2` terminates the **entire runtime**, not just the
current operation — calling a function that halts from EUnit kills the
whole test VM, not just that test case. `symbolic_query.erl`'s
`run/2,3` and `symbolic_parse.erl`'s `run/1,2` are the CLI entry points
this project actually has, and both used to weave `halt/1` calls through
their real decision-making logic (deciding *what* to print, not just
printing it) — every branch of that logic was therefore permanently
stuck at 0% coverage, not because it was untested but because it was
*untestable in place*.

**The fix, not a workaround**: push `halt/0,1` out to the literal edge —
one thin function that calls a halt-free "what happened" function and
maps its plain-term result to `halt(0)`/`halt(1)`. Everything that used
to be inline in the halting function moves into that halt-free one,
which EUnit can call directly:

```erlang
%% halt() belongs only here.
run(DbPath, RulesPath, Goal) ->
    case run_result(DbPath, RulesPath, Goal) of
        {solutions, Bindings} -> print_bindings(Bindings), halt(0);
        no_solution            -> io:format("No.~n"), halt(1);
        {error, Reason}        -> fail(Reason)
    end.

%% Everything else — halt-free, fully unit-testable.
-spec run_result(...) -> {solutions, [...]} | no_solution | {error, term()}.
run_result(DbPath, RulesPath, Goal) -> ...
```

`symbolic_query:run_result/3` and `symbolic_parse:error_message/1` are
the two real instances of this split in this project — see
`symbolic_query_tests.erl`/`symbolic_parse_tests.erl` for the resulting
tests. The thin `run/*` wrapper stays untested (there's nothing left in
it to assert on beyond "does it halt"), but that's now a couple of
lines, not the actual logic.

## 5. Mocking

### 5.1 The idiomatic answer: try not to need one

Erlang has no interfaces/objects to substitute, so "mocking" means replacing
an entire **module** in the global code server — that affects every process
in the VM using that module, not just the process under test. The community
default is therefore to reach for a mocking library *last*, not first:

- **Run the real collaborator when it's cheap.** `erlog` is in-process, pure
  Erlang, deterministic, and fast — a test should consult real facts into a
  real `erlog` state rather than mock `erlog:prove/2`. This is generally
  true of anything in [`erlang-mcp-design.md`](erlang-mcp-design.md) and
  [`prolog-store.md`](prolog-store.md) that doesn't cross a process/OS
  boundary.
- **Prefer a behaviour + swappable implementation over a mock.** Define a
  behaviour for the seam that genuinely varies between test and prod (an
  external service, a NIF), write a real module and a fake module that both
  implement it, and pick which one loads via config or a passed-in module
  name — no mocking library, no global-module-replacement risk.
- **Reach for a mocking library only for the boundary you can't avoid**: an
  external system, non-determinism (`os:timestamp`), or an error path that's
  rare/expensive to trigger for real.

### 5.2 meck — when mocking is the right call

[`meck`](https://github.com/eproxus/meck) is the standard Erlang mocking
library. It works by recompiling and hot-loading a stand-in version of a
module.

```erlang
% rebar.config
{profiles, [{test, [{deps, [meck]}]}]}.
```

```erlang
meck:new(dog, [non_strict]),                    % non_strict: mock a module that
meck:expect(dog, bark, fun() -> "Woof!" end),    % doesn't exist / isn't loaded yet
"Woof!" = dog:bark(),
true = meck:validate(dog),                       % false if a mocked call raised unexpectedly
meck:unload(dog).
```

Core API:

| Call | Purpose |
|---|---|
| `meck:new(Mod, Opts)` | Create the mock. `passthrough` keeps real functions except overridden ones; `unstick` mocks a sticky/preloaded module; `non_strict` mocks a module that doesn't exist yet (e.g. a behaviour callback module); `no_link` detaches the mock's lifetime from the calling process (needed in Common Test's `init_per_suite`); `stub_all` stubs every function. |
| `meck:expect(Mod, Fun, Fun/Arity)` | Set the mocked behavior: a function clause, a fixed return, `meck:seq([...])` (values in order), `meck:loop([...])` (repeat), or `meck:exception(Class, Reason)` to force an error path. |
| `meck:passthrough(Args)` | Inside an expect fun, delegate to the real implementation — for a partial mock. |
| `meck:validate(Mod)` | Did any mocked call raise unexpectedly? |
| `meck:called/3`, `meck:num_calls/3`, `meck:history/1` | Assert on call history (spy-style). |
| `meck:unload(Mod)` / `meck:unload()` | Restore the real module. |

**Sharp edges:**

- A mock only intercepts calls made through the module qualifier
  (`Mod:Fun(...)`) — a call from *inside* the same module with no `Mod:`
  prefix is compiled as a local call and bypasses the mock entirely.
- `erlang`, `os`, `crypto`, `global`, `timer`, the `gen_*` behaviours, and
  `supervisor` are not safely mockable — replacing them can destabilize the
  whole VM or the test runner.
- A NIF-backed module generally **cannot** be mocked, since the NIF is
  loaded natively rather than through the module's Erlang code — this rules
  out mocking `symbolic_ts` itself (see 5.3).

### 5.3 Where this applies in `symbolic-tools`

- **Don't mock `erlog`.** Run real sessions in tests (§3.4 above already
  covers this at the property level).
- **`symbolic_ts`** ([`tree-sitter-erlang.md`](tree-sitter-erlang.md)) is a NIF,
  so meck can't mock it directly. Put a thin behaviour around "parse source
  → facts" and swap in a fake implementation for unit tests of the
  extraction pipeline; save the real NIF for a dedicated integration suite.
- **erlmcp's transport** (stdio) is a reasonable `meck:passthrough` partial
  mock, or a fake, if you want to unit-test `prolog_session` dispatch logic
  without a real stdio round-trip.

## 6. Suggested `rebar.config` additions

```erlang
{plugins, [rebar3_proper]}.

{profiles, [
  {test, [
    {deps, [{proper, "1.5.0"}, meck]},
    {eunit_opts, [verbose]}
  ]}
]}.

{cover_enabled, true}.
{cover_export_enabled, true}.
{cover_opts, [verbose]}.
```

## 7. Command cheat sheet

```sh
rebar3 eunit                 # unit tests
rebar3 ct                    # integration/suite tests
rebar3 proper                # property-based tests
rebar3 cover --verbose       # merge + report coverage from all of the above
rebar3 as test coveralls send  # optional: push coverage to coveralls.io
```

## References

- [`erlang-mcp-design.md`](erlang-mcp-design.md) §9 — the testing strategy
  this tooling supports (correctness, cyclic-graph regression, failure
  modes, timeout-kill, erlmcp integration).
- [`cli-erlang.md`](cli-erlang.md) §5 — the CLI's own testing guidance
  (logic modules vs. the escriptized binary).
- [rebar3 EUnit docs](https://rebar3.org/docs/testing/eunit/)
- [rebar3 Coverage docs](https://rebar3.org/docs/testing/coverage/)
- [`proper-testing/proper`](https://github.com/proper-testing/proper) —
  PropEr.
- [Triq](https://triq.gitlab.io/) — the Apache-licensed alternative.
- [`markusn/coveralls-erl`](https://github.com/markusn/coveralls-erl) ·
  [`esl/rebar3_codecov`](https://github.com/esl/rebar3_codecov) — CI
  coverage export.
- [`eproxus/meck`](https://github.com/eproxus/meck) — the standard Erlang
  mocking library.
- [`tree-sitter-erlang.md`](tree-sitter-erlang.md) — the NIF (`symbolic_ts`) that
  can't be mocked directly (§5.3).
