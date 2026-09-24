%%% Benchmarks for the tree-sitter extraction layer (ts_extract:file/1 and
%%% the per-language modules it dispatches to), using erlperf
%%% (https://www.erlang.org/doc/system/benchmarking.html — the official
%%% Erlang docs' own recommended tool, not a hand-rolled timer:tc/1 loop).
%%% Scoped to the `bench` rebar3 profile (see rebar.config) — erlperf is a
%%% real dependency with its own runtime footprint and has no reason to
%%% ship in the CLI/MCP release.
%%%
%%% Run (see docs/benchmarking.md §1 for why `rebar3 as bench shell
%%% --eval` — the obvious thing to try — does NOT work: it needs a real
%%% TTY and silently terminates before printing anything otherwise):
%%%   rebar3 as bench compile
%%%   erl -pa _build/bench/lib/*/ebin -pa _build/bench/lib/symbolic_tools/bench \
%%%       -noshell -eval 'symbolic_bench:run(), init:stop().'
%%%
%%% See docs/benchmarking.md for how to read the report and why the
%%% benchmark inputs were chosen the way they were (in particular: there
%%% is no large real TypeScript file committed to this repo yet, so the
%%% TypeScript side is currently a single small input, not a size series
%%% the way the Erlang side is).
-module(symbolic_bench).
-export([run/0, run/1]).

%% Real, already-committed source files — not synthetic fixtures — sized
%% roughly a decade apart so a regression that scales with input size
%% (not just a fixed per-call NIF/setup overhead) has a chance to show up
%% across the series. Picked from this project's own src/ tree at the
%% time of writing; re-picking them as the codebase grows is fine, they
%% don't need to stay pinned to these exact files forever.
erlang_inputs() ->
    [{"erlang_small",  "src/symbolic_gitignore.erl"},   %  134 lines
     {"erlang_medium", "src/symbolic_serve.erl"},       %  429 lines
     {"erlang_large",  "src/ts_extract_typescript.erl"}]. % 1254 lines

%% No comparably large real .ts file exists in this repo (test fixtures
%% are deliberately tiny, built for EUnit coverage of specific fact
%% shapes, not throughput) — see docs/benchmarking.md for this gap and
%% how to close it, rather than papering over it with fabricated content.
typescript_inputs() ->
    [{"typescript_small", "test/fixtures/sample.ts"}]. % 22 lines

-spec run() -> [map()].
run() -> run(#{}).

%% `sample_duration` (ms, default 2000 — double erlperf's own 1-second
%% default): these inputs are small enough that QPS lands in the
%% single-to-low-double digits at the default duration, which erlperf's
%% own docs warn is exactly the low-sample-count regime that's noisiest
%% ("ensure each measurement lasts several seconds"). Override for a
%% quicker, less precise run, e.g. `symbolic_bench:run(#{sample_duration
%% => 500})`.
-spec run(map()) -> [map()].
run(Opts) ->
    ok = ensure_nif_loaded(),
    SampleDuration = maps:get(sample_duration, Opts, 2000),
    Inputs = erlang_inputs() ++ typescript_inputs(),
    Results = [bench_one(Label, Path, SampleDuration) || {Label, Path} <- Inputs],
    print_report(Results),
    Results.

%% Same defensive load symbolic_parse:scan/1 already does before touching
%% ts_extract:file/1 — the tree-sitter NIF (symbolic_ts) isn't guaranteed
%% loaded just because this module is, and a benchmark that silently
%% measured an `undef` error's own (near-instant) failure path would be
%% actively misleading rather than merely wrong.
ensure_nif_loaded() ->
    case code:ensure_loaded(symbolic_ts) of
        {module, symbolic_ts} -> ok;
        {error, Reason} -> error({nif_not_loadable, Reason})
    end.

bench_one(Label, Path, SampleDuration) ->
    {ok, Bytes} = file:read_file(Path),
    Size = byte_size(Bytes),
    Lines = length(binary:split(Bytes, <<"\n">>, [global])),
    %% erlperf_job:code_map()'s `runner` field takes a "callable" — a
    %% bare {Module, Function, Args} tuple is one, verified directly
    %% against the real dependency (both this and a one-element
    %% `[{M,F,A}]` list return the same QPS for the same job). Calls
    %% ts_extract:file(Path) in a tight loop and returns average
    %% calls/second over SampleDuration.
    QPS = erlperf:run(#{runner => {ts_extract, file, [Path]}},
                       #{sample_duration => SampleDuration}),
    UsPerCall = case QPS of 0 -> infinity; _ -> 1000000 / QPS end,
    MbPerSec = QPS * Size / (1024 * 1024),
    #{label => Label, path => Path, bytes => Size, lines => Lines,
      qps => QPS, us_per_call => UsPerCall, mb_per_sec => MbPerSec,
      lines_per_sec => QPS * Lines}.

%% Erlang's own `io:format` field-width control is a trap here: `~-Ns`
%% TRUNCATES a string longer than N rather than just skipping the pad —
%% confirmed directly (`io:format("~-28s|", ["a 30-char string"])` prints
%% only the first 28 characters, silently). A benchmark report silently
%% dropping the tail of a real file path is worse than one with ragged
%% columns, so padding is done by hand instead, only ever adding
%% whitespace, never cutting content.
print_report(Results) ->
    LabelW = max(16, lists:max([length(L) || #{label := L} <- Results])),
    PathW = max(28, lists:max([length(P) || #{path := P} <- Results])),
    io:format("~n~s ~s ~8s ~10s ~10s ~10s~n",
        [pad("input", LabelW), pad("path", PathW), "qps", "us/call", "MB/s", "lines/s"]),
    lists:foreach(fun(R) -> print_row(R, LabelW, PathW) end, Results).

print_row(#{label := Label, path := Path, qps := Qps, us_per_call := Us,
            mb_per_sec := Mb, lines_per_sec := Lps}, LabelW, PathW) ->
    io:format("~s ~s ~8w ~10.1f ~10.2f ~10w~n",
        [pad(Label, LabelW), pad(Path, PathW), Qps, us_time(Us), Mb, round(Lps)]).

pad(S, N) when length(S) >= N -> S;
pad(S, N) -> S ++ lists:duplicate(N - length(S), $\s).

us_time(infinity) -> 0.0;
us_time(Us) -> Us.
