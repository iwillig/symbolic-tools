%% A regression guard for rules-library PERFORMANCE, the one axis the
%% bench suite does not cover (bench/symbolic_bench.erl measures
%% extraction throughput only). The remediation documented in
%% docs/review-self-audit-and-remediation.md fixed four flagship
%% queries that timed out against this repo's own base — every one of
%% them a quadratic or choicepoint-per-element shape that crept in
%% through a plausible-looking rule. A rule that regresses that way
%% again will push these same goals back over the standard proof budget
%% and turn an "answer" into {error, {query_failed, timeout}}.
%%
%% The guard runs the flagship goals through symbolic_query:run_result/3
%% — its ?QUERY_TIMEOUT_MS budget IS the assertion: {solutions, _} means
%% the proof finished inside the standard 5s, {error,
%% {query_failed, timeout}} means it did not. No wall-clock measurement
%% is asserted on purpose: a timing assert flakes on loaded CI machines,
%% and the budget-bound proof already gives ~6x headroom (measured
%% proofs: 0.3-0.8s against this base). A regression to any of the
%% fixed quadratic shapes is order-of-magnitude, not a few percent —
%% exactly the class this catches.
%%
%% The base is this repo's own src/ (a real tree, ~20 modules), scanned
%% ONCE — the scan is also guarded: a walk that re-descends into build
%% output or crashes on one bad file would surface as an error or a
%% fact base too small to exercise the rules at all. {timeout, 120}
%% because the scan itself (~1-2s, one process per file) plus four
%% proofs exceeds eunit's own default 5s per-test budget.
-module(rules_perf_tests).
-include_lib("eunit/include/eunit.hrl").

%% The FULL configured tree (src, test, docs — read the same way
%% `symbolic parse` with no directory does), not just src/: the
%% regression shapes being guarded are quadratic in the BASE SIZE, and
%% a src-only base is too small to push any of them back over the
%% budget — measured, not assumed: a temporarily reintroduced O(n^2)
%% reverse/2 in top_fan_out/2 PASSES this guard on a src-only base (too
%% few entries) and times it out on this one.
-define(PATHS, ["src", "test", "docs"]).

flagship_queries_answer_within_the_standard_budget_test_() ->
    {timeout, 120, fun flagship_queries/0}.

flagship_queries() ->
    {ok, {_Files, Facts}} = symbolic_parse:scan_paths(?PATHS),
    %% The base is big enough that the rules are genuinely exercised:
    %% mutual recursion needs the walker cycle, fan-out needs real call
    %% edges, and a walk that lost files would fall under these.
    %% Real measured floor of this tree: 94 files, ~33k facts, 1121
    %% defines, 3779 calls, 78 fun_refs. Assertions sit comfortably
    %% under those (they guard against a walk that LOST files, not
    %% against the tree growing or shrinking by a normal edit).
    ?assert(length(Facts) > 15000),
    ?assert(length([F || {defines, _, _, _, _, _} = F <- Facts]) > 900),
    ?assert(length([F || {calls, _, _, _, _, _} = F <- Facts]) > 2500),

    Db = tmp_db(Facts),
    try
        Goals = [
            %% Non-empty answers for the three ranking/cycle goals — a
            %% degenerate "succeeds instantly with []" can't pass.
            {"top_fan_out(5, Top)", non_empty},
            {"top_fan_in(3, Top)", non_empty},
            {"all_mutual_recursion(Pairs)", non_empty},
            %% ... but all_truly_uncalled/1 legitimately answers [] on
            %% this repo (the scan_one/1 false positive is closed — see
            %% docs/review-self-audit-and-remediation.md), so only the
            %% budget is guarded here, not the size.
            {"all_truly_uncalled(Triples)", any}],
        lists:foreach(fun({Goal, Shape}) ->
            Result = symbolic_query:run_result(Db, real_rules(), Goal),
            %% {error, {query_failed, timeout}} here is the regression
            %% signal: the proof blew the standard 5s budget again.
            ?assert(element(1, Result) =:= solutions, Goal),
            case Shape of
                non_empty ->
                    ?assertMatch([_ | _], element(2, Result), Goal);
                any ->
                    ok
            end
        end, Goals)
    after
        file:delete(Db)
    end.

tmp_db(Facts) ->
    Name = io_lib:format("rules_perf_test_~p.dets",
        [erlang:unique_integer([positive])]),
    TmpDir = case os:getenv("TMPDIR") of false -> "/tmp"; Dir -> Dir end,
    Path = filename:join(TmpDir, lists:flatten(Name)),
    ok = symbolic_fact_store:write(Path, Facts),
    Path.

real_rules() -> filename:join([".symbolic", "rules.pl"]).
