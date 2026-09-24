# Benchmarking the Extraction Layer

`bench/symbolic_bench.erl` measures `ts_extract:file/1` — the tree-sitter
extraction dispatcher, i.e. the actual per-file parsing cost `symbolic
parse` pays — using [erlperf](https://hex.pm/packages/erlperf), the tool
the [official Erlang docs' own benchmarking
page](https://www.erlang.org/doc/system/benchmarking.html) recommends, not
a hand-rolled `timer:tc/1` loop.

## 1. Run it

```sh
rebar3 as bench compile
erl -pa _build/bench/lib/*/ebin -pa _build/bench/lib/symbolic_tools/bench \
    -noshell -eval 'symbolic_bench:run(), init:stop().'
```

`rebar3 as bench shell --eval '...'` looks like the more obvious way to do
this and does not work: `rebar3 shell` expects an interactive TTY, and
piping/redirecting it (as any non-interactive invocation does) hits an
immediate stdin EOF that terminates the node before the eval's output
flushes — confirmed by trying it. The `erl -noshell -eval ... ` form above
is the one that actually runs to completion. The two `-pa` paths matter:
`extra_src_dirs` (how `bench/` gets compiled — see `rebar.config`'s `bench`
profile) puts `symbolic_bench.beam` under
`_build/bench/lib/symbolic_tools/bench/`, not `.../ebin/`, so it needs its
own `-pa` entry separate from every other app's `.../ebin`.

`erlperf` is scoped to the `bench` profile, not the main `deps` list — it's
a real dependency with its own runtime footprint and has no reason to ship
in the CLI/MCP release.

## 2. Reading the report

```
input            path                               qps    us/call       MB/s    lines/s
erlang_small     src/symbolic_gitignore.erl          31    32258.1       0.18       4185
erlang_medium    src/symbolic_serve.erl              22    45454.5       0.47       9460
erlang_large     src/ts_extract_typescript.erl        7   142857.1       0.43       8785
typescript_small test/fixtures/sample.ts             16    62500.0       0.01        368
```

(A real run, `sample_duration => 2000`, on the machine this was written on
— expect different absolute numbers on yours; see §4.)

- **qps** — calls/second to `ts_extract:file/1` on that one input, erlperf's
  own headline number.
- **us/call**, **MB/s**, **lines/s** — the same measurement renormalized by
  the input's own size, computed by this module (not erlperf itself), so a
  regression that scales with file size — not just a fixed per-call
  overhead — has somewhere to show up even though the four inputs are very
  different sizes.

**MB/s and lines/s are not monotonic with file size** in the sample run
above — `erlang_medium` is faster per byte AND per line than both
`erlang_small` and `erlang_large`. That's real, not a bug: extraction cost
tracks a file's actual branch/expression complexity, not just its line
count, so two files of different sizes can trade places on throughput.
Don't average across inputs expecting a single "lines/sec for Erlang"
constant — there isn't one.

## 3. Why these four inputs, specifically

Real, already-committed source files — not synthetic/fabricated fixtures —
picked to span roughly an order of magnitude in size on the Erlang side
(134 → 429 → 1254 lines) so a size-dependent regression has a chance to
appear across the series, not just at one point.

**The TypeScript side is one small input, not a series, and that's a real
gap, not a stylistic choice**: `test/fixtures/sample.ts` (22 lines) is the
only real TypeScript file in this repo — every other `.ts` reference in the
codebase is documentation prose, not committed source. It was built for
EUnit fact-shape coverage, not throughput measurement. Closing this
properly means committing a large, real, representative `.ts` file (or a
small corpus of them) the same way the Erlang side already has one built
in — not synthesizing one, which would benchmark tree-sitter's handling of
invented code shapes instead of the real ones a user's own project
actually contains.

## 4. `sample_duration` and precision

`symbolic_bench:run/1` takes `#{sample_duration => Ms}` (default `2000`).
erlperf's own docs are explicit that a short sample window
underestimates throughput, because fixed per-sample overhead dominates
before the loop reaches a steady state ("ensure that each individual
measurement lasts for at least several seconds") — confirmed directly
here, not just taken on faith: every input's QPS roughly *doubled* when
`sample_duration` was raised from erlperf's own 1-second default to 2000ms
in the same session, on the same machine, with no code change in between.
Raise it further (`5000`, `10000`) for a more precise number at the cost
of a slower run; lower it (`500`) for a quick, noisier smoke check.

## 5. Extending it

- **Re-picking the Erlang inputs** as this codebase grows: edit
  `erlang_inputs/0` in `bench/symbolic_bench.erl` directly — they don't
  need to stay pinned to the exact files chosen when this was written.
- **A richer report** (median, p99, stddev — not just the mean QPS this
  module currently prints): `erlperf:run/2` supports a `report => full`
  option returning a detailed map; this module deliberately doesn't use it
  yet, since its exact field shape wasn't independently verified against
  the real dependency the way the `runner` callable shape here was (see
  `bench/symbolic_bench.erl`'s own comment on that call) — verify it live
  before building on it, the same way this whole feature was.
