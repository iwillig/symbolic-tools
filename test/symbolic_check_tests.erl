-module(symbolic_check_tests).
-include_lib("eunit/include/eunit.hrl").

%% run/5 itself stays untested here — same reasoning as
%% symbolic_query_tests.erl's own note: it only prints and halt()s.
%% run_result/4 is the halt-free core, exercised directly below.

-define(DB, filename:join(["_build", "symbolic_check_test_scratch.dets"])).

with_db(Facts, Test) ->
    ok = symbolic_fact_store:write(?DB, Facts),
    try Test() after file:delete(?DB) end.

real_rules() -> filename:join([".symbolic", "rules.pl"]).

check_fixture() ->
    [{defines, foo, 2, <<"(a,b)">>, 'p.erl', 1},
     {calls, foo, 2, {local, bar, 1}, 'p.erl', 2}].

run_result_recognizes_and_checks_a_true_claim_test() ->
    with_db(check_fixture(), fun() ->
        ?assertEqual({ok, {svo, {'/', foo, 2}, calls, {'/', bar, 1}}, true},
            symbolic_check:run_result(?DB, real_rules(), "foo/2 calls bar/1", undefined))
    end).

run_result_recognizes_and_checks_a_false_claim_test() ->
    with_db(check_fixture(), fun() ->
        ?assertEqual({ok, {svo, {'/', foo, 2}, calls, {'/', baz, 1}}, false},
            symbolic_check:run_result(?DB, real_rules(), "foo/2 calls baz/1", undefined))
    end).

run_result_checks_a_removed_claim_test() ->
    with_db(check_fixture(), fun() ->
        ?assertEqual({ok, {svo, {'/', ghost, 3}, removed, none}, true},
            symbolic_check:run_result(?DB, real_rules(), "ghost/3 was removed", undefined))
    end).

%% Outside the bounded grammar, no model configured — the extraction
%% half never produces a claim to check at all.
run_result_unrecognized_when_extraction_fails_test() ->
    with_db(check_fixture(), fun() ->
        ?assertEqual(unrecognized,
            symbolic_check:run_result(?DB, real_rules(), "foo/2 improves performance", undefined))
    end).

run_result_no_such_db_is_an_error_test() ->
    ?assertMatch({error, {check_error, {no_such_db, _}}},
        symbolic_check:run_result("no/such/facts_zz.dets", real_rules(), "foo/2 calls bar/1", undefined)).

%% Proves the wiring (ModelPath really reaches symbolic_extract's own
%% fallback chaining), not the LLM tier's own extraction logic — that's
%% symbolic_extract_llm_tests.erl's and symbolic_extract_tests.erl's job.
run_result_forwards_model_path_to_extraction_test() ->
    meck:new(symbolic_extract),
    meck:expect(symbolic_extract, run_result, fun(_Sentence, _ModelPath) ->
        {ok, {svo, {'/', foo, 2}, calls, {'/', bar, 1}}}
    end),
    try
        Result = with_db(check_fixture(), fun() ->
            symbolic_check:run_result(?DB, real_rules(), "foo/2 depends on bar/1", "/some/model.gguf")
        end),
        ?assertEqual({ok, {svo, {'/', foo, 2}, calls, {'/', bar, 1}}, true}, Result),
        ?assert(meck:called(symbolic_extract, run_result,
            ["foo/2 depends on bar/1", "/some/model.gguf"]))
    after
        meck:unload(symbolic_extract)
    end.
