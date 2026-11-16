%% A two-layer regression guard for the rules library. Layer 1 is the
%% PERFORMANCE guard: the four flagship goals run against a SYNTHETIC
%% fact base of fixed size, through symbolic_query:run_result/3 — its
%% standard ?QUERY_TIMEOUT_MS budget (5s) IS the assertion:
%% {solutions, _} means the proof finished inside the standard 5s,
%% {error, {query_failed, timeout}} means it did not. No wall-clock
%% measurement is asserted on purpose: a timing assert flakes on loaded
%% CI machines, and the budget gives ~6x headroom over the proofs as
%% measured against this base (0.3–0.75s locally; CI measures roughly
%% 2–2.5x local, still well under the budget).
%%
%% Why synthetic and not this repo's own tree: the first version of
%% this guard scanned the live configured tree (src, test, docs), and
%% the tree kept growing — ~33k facts/1121 defines when the guard was
%% written (2026-10), ~83k facts/2788 defines/10012 calls by 2026-11 —
%% until the live proofs legitimately crossed the 5s budget and every
%% CI run since 2026-10-15 failed WITHOUT any rules regression. The
%% budget was colliding with organic base growth, not with the
%% quadratic shapes it exists to catch. A fixed base decouples the two.
%%
%% What the fixed base can and cannot catch. It catches
%% order-of-magnitude regressions: a reintroduced O(n^2) reverse/2 in
%% top_fan_out/2 costs ~14s at 600 ranking keys (measured 39s at 981 —
%% the n^2 class the remediation fixed) and fails this test; a
%% src-only base would hide it (same reason the original guard needed
%% a big base). It does NOT catch small multipliers: a shape that
%% merely doubles a proof's work stays well under the budget here, as
%% it would have under the old guard too.
%%
%% Layer 2 is the live-tree guard: scan_paths/1 over the full
%% configured tree (src, test, docs) — the same walk `symbolic parse`
%% with no directory does — with floor assertions that catch a walk
%% that LOST files (they sit well under the measured floor, not at it),
%% then the four flagship goals again, asserting the answers are
%% correct in SHAPE on a real tree. Its proof budget is a generous 45s
%% cap, not a performance assertion: at the 2026-11 base size the
%% honest proof costs are top_fan_out ~16s and all_truly_uncalled ~19s
%% (the latter is inherently O(defines x calls) in the current rules),
%% so any fixed tight budget here would re-create the layer-1-vs-growth
%% collision. The cap only catches hang-class failures.
%%
%% History: the remediation documented in
%% docs/review-self-audit-and-remediation.md fixed four flagship
%% queries that timed out against this repo's own base — every one a
%% quadratic or choicepoint-per-element shape that crept in through a
%% plausible-looking rule. Layer 1 keeps that class caught; layer 2
%% keeps the answers honest on a real tree.
-module(rules_perf_tests).
-include_lib("eunit/include/eunit.hrl").

%% --- Layer 1: the budget guard, on a fixed synthetic base ---

%% Calibrated 2026-11-16 against the measured erlog proof costs:
%% top_fan_out 744ms, top_fan_in 280ms, all_mutual_recursion ~60ms,
%% all_truly_uncalled 624ms at this size (local; CI runs ~2-2.5x
%% slower). The size is the tuning knob: it must stay small enough
%% that the honest proofs keep multi-second headroom under the 5s
%% budget on CI, and big enough that an O(n^2) reintroduction blows
%% the budget instead of finishing in milliseconds.
-define(SYNTH_DEFINES, 600).
-define(SYNTH_CALLS, 1800).
-define(SYNTH_FILES, 60).
-define(SYNTH_MUTUAL_PAIRS, 40).

flagship_queries_stay_within_the_standard_budget_on_a_fixed_base_test_() ->
    {timeout, 120, fun flagship_queries_fixed_base/0}.

flagship_queries_fixed_base() ->
    Facts = synthetic_facts(),
    ?assert(length([F || {defines, _, _, _, _, _} = F <- Facts])
        =:= ?SYNTH_DEFINES + 2 * ?SYNTH_MUTUAL_PAIRS),
    ?assert(length([F || {calls, _, _, _, _, _} = F <- Facts])
        =:= ?SYNTH_CALLS + 2 * ?SYNTH_MUTUAL_PAIRS),
    Db = tmp_db(Facts),
    try
        %% The budget IS the assertion, and this time it means what it
        %% says: the base is fixed, so a timeout can only mean the
        %% rules got slower, never that the tree grew.
        Goals = [
            %% Non-empty answers for the three ranking/cycle goals —
            %% a degenerate "succeeds instantly with []" can't pass.
            {"top_fan_out(5, Top)", non_empty},
            {"top_fan_in(3, Top)", non_empty},
            {"all_mutual_recursion(Pairs)", non_empty},
            %% all_truly_uncalled/1 legitimately answers [] on some
            %% bases, so only the budget is guarded, not the size.
            {"all_truly_uncalled(Triples)", any}],
        lists:foreach(fun({Goal, Shape}) ->
            Result = symbolic_query:run_result(Db, real_rules(), Goal),
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

%% A deterministic call graph shaped like a real project: ?SYNTH_DEFINES
%% functions spread over ?SYNTH_FILES files, each calling a spread of
%% distinct callees; ?SYNTH_MUTUAL_PAIRS mutually-recursive pairs so
%% all_mutual_recursion/1 has witnesses; a slice of exports and
%% `fun Name/Arity` references so entry_point/3 and fun_ref/4 paths are
%% exercised the way a real Erlang base exercises them.
synthetic_facts() ->
    Defines = [{defines, pf(I), 1, <<"(Arg)">>, pf_file(I rem ?SYNTH_FILES), I}
        || I <- lists:seq(1, ?SYNTH_DEFINES)],
    MutualDefines = [{defines, pfa(J), 1, <<"(Arg)">>, pf_file(J rem ?SYNTH_FILES),
        ?SYNTH_DEFINES + J} || J <- lists:seq(1, ?SYNTH_MUTUAL_PAIRS)] ++
        [{defines, pfb(J), 1, <<"(Arg)">>, pf_file(J rem ?SYNTH_FILES),
        ?SYNTH_DEFINES + ?SYNTH_MUTUAL_PAIRS + J}
        || J <- lists:seq(1, ?SYNTH_MUTUAL_PAIRS)],
    Calls = [{calls, pf(I), 1, {local, pf(1 + (I * 3 rem ?SYNTH_DEFINES)), 1},
        pf_file(I rem ?SYNTH_FILES), I} || I <- lists:seq(1, ?SYNTH_CALLS)],
    MutualCalls = [{calls, pfa(J), 1, {local, pfb(J), 1},
        pf_file(J rem ?SYNTH_FILES), ?SYNTH_CALLS + J}
        || J <- lists:seq(1, ?SYNTH_MUTUAL_PAIRS)] ++
        [{calls, pfb(J), 1, {local, pfa(J), 1},
        pf_file(J rem ?SYNTH_FILES), ?SYNTH_CALLS + ?SYNTH_MUTUAL_PAIRS + J}
        || J <- lists:seq(1, ?SYNTH_MUTUAL_PAIRS)],
    Exports = [{export, pf(I), 1, pf_file(I rem ?SYNTH_FILES), I}
        || I <- lists:seq(1, 40)],
    FunRefs = [{fun_ref, pf(I), 1, pf_file(I rem ?SYNTH_FILES), I}
        || I <- lists:seq(1, 20)],
    Defines ++ MutualDefines ++ Calls ++ MutualCalls ++ Exports ++ FunRefs.

pf(I) -> list_to_atom("pf" ++ integer_to_list(I)).
pfa(J) -> list_to_atom("pfa" ++ integer_to_list(J)).
pfb(J) -> list_to_atom("pfb" ++ integer_to_list(J)).
pf_file(I) -> list_to_atom("/rules_perf_fixture/m" ++ integer_to_list(I) ++ ".erl").

%% --- Layer 2: the live-tree guard (scan + answer shape) ---

%% The FULL configured tree (src, test, docs — read the same way
%% `symbolic parse` with no directory does), not just src/: the scan
%% itself is guarded, and a real tree is what makes the shape
%% assertions honest.
-define(PATHS, ["src", "test", "docs"]).

%% A generous hang-class cap, NOT a performance assertion — see the
%% module header for why no tight budget belongs on the live tree.
-define(LIVE_PROOF_BUDGET_MS, 45000).

%% Measured floor of this tree on 2026-11-16: 170 files, 83334 facts,
%% 2788 defines, 10012 calls. Assertions sit well under those (about
%% half): they guard against a walk that LOST files, not against the
%% tree growing or shrinking by a normal edit.
-define(LIVE_MIN_FACTS, 40000).
-define(LIVE_MIN_DEFINES, 2000).
-define(LIVE_MIN_CALLS, 6500).

flagship_queries_answer_correctly_on_the_live_tree_test_() ->
    {timeout, 240, fun flagship_queries_live_tree/0}.

flagship_queries_live_tree() ->
    {ok, {_Files, Facts}} = symbolic_parse:scan_paths(?PATHS),
    ?assert(length(Facts) > ?LIVE_MIN_FACTS),
    ?assert(length([F || {defines, _, _, _, _, _} = F <- Facts])
        > ?LIVE_MIN_DEFINES),
    ?assert(length([F || {calls, _, _, _, _, _} = F <- Facts])
        > ?LIVE_MIN_CALLS),

    Db = tmp_db(Facts),
    try
        Goals = [
            {"top_fan_out(5, Top)", non_empty},
            {"top_fan_in(3, Top)", non_empty},
            {"all_mutual_recursion(Pairs)", non_empty},
            {"all_truly_uncalled(Triples)", any}],
        lists:foreach(fun({Goal, Shape}) ->
            Result = symbolic_query:run_result(Db, real_rules(), Goal,
                ?LIVE_PROOF_BUDGET_MS),
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
