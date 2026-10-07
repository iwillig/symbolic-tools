%%% Tests for symbolic_ask — the question→answer pipeline (parse with the
%%% question DCG, gate verifiability, prove, shape JSON). Each of the
%%% module's three design rules has a pinned test: the arity trap is
%%% rejected loudly (rule 1), prose returns evidence never verdicts
%%% (rule 2), and every question shape answers in its own JSON type
%%% (rule 3).
-module(symbolic_ask_tests).
-include_lib("eunit/include/eunit.hrl").

%% A miniature codebase: foo/2 calls bar/1 locally and halt/1 remotely
%% (stdlib — no defines fact, the loose-callee-gate case), baz/3 also
%% calls bar/1; qb/2 exists (arity-trap target), nothing calls qb/1;
%% one comment holds prose; zzz/9 defines nothing.
facts() ->
    [
        {defines, foo, 2, <<"(A, B)">>, 'p.erl', 1},
        {defines, bar, 1, <<"(A)">>, 'p.erl', 2},
        {defines, baz, 3, <<"(A, B, C)">>, 'p.erl', 3},
        {defines, qb, 2, <<"(T, St)">>, 'p.erl', 4},
        {calls, foo, 2, {local, bar, 1}, 'p.erl', 10},
        {calls, foo, 2, {remote, erlang, halt, 1}, 'p.erl', 11},
        {calls, baz, 3, {local, bar, 1}, 'p.erl', 12},
        {calls, foo, 2, {local, qb, 2}, 'p.erl', 13},
        {comment, 'p.erl', 5, <<"the dirty scheduler prose lives here">>}
    ].

with_db(Facts, Body) ->
    Path = tmp_db(),
    try
        ok = symbolic_fact_store:write(Path, Facts),
        Body(Path)
    after
        file:delete(Path)
    end.

%% --- rule 3: each shape answers in its own JSON type ---

yes_no_call_true_across_both_call_shapes_test() ->
    with_db(facts(), fun(Db) ->
        %% One question proves BOTH the local shape and the remote shape
        %% are covered: foo/2's call to bar/1 is local, to halt/1 remote.
        ?assertEqual({ok, #{<<"type">> => <<"yes_no">>, <<"answer">> => true}},
            symbolic_ask:run_result(Db, "does foo/2 call bar/1?")),
        ?assertEqual({ok, #{<<"type">> => <<"yes_no">>, <<"answer">> => true}},
            symbolic_ask:run_result(Db, "does foo/2 call halt/1?"))
    end).

yes_no_call_false_is_an_answer_not_an_error_test() ->
    with_db(facts(), fun(Db) ->
        %% baz/3 exists and calls bar/1, but baz/3 does NOT call halt/1.
        ?assertEqual({ok, #{<<"type">> => <<"yes_no">>, <<"answer">> => false}},
            symbolic_ask:run_result(Db, "does baz/3 call halt/1?"))
    end).

who_calls_alias_parses_like_which_functions_test() ->
    with_db(facts(), fun(Db) ->
        ?assertEqual(
            symbolic_ask:run_result(Db, "which functions call bar/1?"),
            symbolic_ask:run_result(Db, "who calls bar/1?"))
    end).

enumerate_lists_distinct_callers_sorted_test() ->
    with_db(facts(), fun(Db) ->
        {ok, #{<<"type">> := <<"enumerate">>, <<"answer">> := Callers}} =
            symbolic_ask:run_result(Db, "which functions call bar/1?"),
        ?assertEqual([<<"baz/3">>, <<"foo/2">>], Callers)
    end).

count_counts_distinct_functions_test() ->
    with_db(facts(), fun(Db) ->
        ?assertEqual({ok, #{<<"type">> => <<"count">>, <<"answer">> => 2}},
            symbolic_ask:run_result(Db, "how many functions call bar/1?"))
    end).

is_defined_true_and_false_test() ->
    with_db(facts(), fun(Db) ->
        ?assertEqual({ok, #{<<"type">> => <<"yes_no">>, <<"answer">> => true}},
            symbolic_ask:run_result(Db, "is foo/2 defined?")),
        ?assertEqual({ok, #{<<"type">> => <<"yes_no">>, <<"answer">> => false}},
            symbolic_ask:run_result(Db, "is zzz/9 defined?")),
        ?assertEqual({ok, #{<<"type">> => <<"yes_no">>, <<"answer">> => false}},
            symbolic_ask:run_result(Db, "does zzz/9 exist?"))
    end).

%% --- rule 2: prose questions return evidence, never verdicts ---

where_documented_returns_evidence_test() ->
    with_db(facts(), fun(Db) ->
        {ok, #{<<"type">> := <<"prose">>, <<"evidence">> := [Hit]}} =
            symbolic_ask:run_result(Db, "where is dirty scheduler documented?"),
        ?assertEqual(<<"comment">>, maps:get(<<"kind">>, Hit)),
        ?assertEqual(<<"p.erl">>, maps:get(<<"file">>, Hit)),
        ?assertEqual(5, maps:get(<<"line">>, Hit))
    end).

where_discussed_is_the_same_shape_test() ->
    with_db(facts(), fun(Db) ->
        ?assertMatch({ok, #{<<"type">> := <<"prose">>, <<"evidence">> := [_]}},
            symbolic_ask:run_result(Db, "where is dirty scheduler discussed?"))
    end).

prose_no_hits_is_empty_evidence_not_false_test() ->
    with_db(facts(), fun(Db) ->
        {ok, #{<<"type">> := <<"prose">>, <<"evidence">> := []}} =
            symbolic_ask:run_result(Db, "where is zebra documented?")
    end).

%% --- rule 1: the gate rejects before proving, loudly ---

wrong_arity_callee_is_unverifiable_never_zero_test() ->
    with_db(facts(), fun(Db) ->
        %% THE canonical trap: qb/2 is real and called, but qb/1 is not
        %% the question anyone meant — a bare proof would answer
        %% {"answer": 0} with total confidence.
        ?assertEqual({error, {unverifiable, {wrong_arity, qb, 1}}},
            symbolic_ask:run_result(Db, "does foo/2 call qb/1?")),
        ?assertEqual({error, {unverifiable, {wrong_arity, qb, 1}}},
            symbolic_ask:run_result(Db, "how many functions call qb/1?"))
    end).

unknown_subject_is_unverifiable_never_false_test() ->
    with_db(facts(), fun(Db) ->
        ?assertEqual({error, {unverifiable, {no_such_function, zzz, 9}}},
            symbolic_ask:run_result(Db, "does zzz/9 call bar/1?"))
    end).

stdlib_callee_without_defines_passes_the_gate_test() ->
    with_db(facts(), fun(Db) ->
        %% halt/1 has no defines/5 fact (it's stdlib) and must still be
        %% answerable — the loose gate only fires when the name is known.
        ?assertEqual({ok, #{<<"type">> => <<"yes_no">>, <<"answer">> => true}},
            symbolic_ask:run_result(Db, "does foo/2 call halt/1?")),
        %% A stdlib-shaped name nothing calls answers false, cleanly.
        ?assertEqual({ok, #{<<"type">> => <<"yes_no">>, <<"answer">> => false}},
            symbolic_ask:run_result(Db, "does foo/2 call format/1?"))
    end).

%% --- unrecognized phrasings and infra errors ---

unrecognized_phrasing_is_reported_test() ->
    with_db(facts(), fun(Db) ->
        ?assertEqual(unrecognized,
            symbolic_ask:run_result(Db, "what is the meaning of life"))
    end).

missing_db_is_reported_test() ->
    Missing = "/tmp/no_such_ask_db_"
        ++ integer_to_list(erlang:unique_integer([positive])) ++ ".dets",
    ?assertEqual({error, {no_such_db, Missing}},
        symbolic_ask:run_result(Missing, "is foo/2 defined?")).

capitalized_words_are_rejected_by_the_tokenizer_test() ->
    with_db(facts(), fun(Db) ->
        ?assertMatch({error, {tokenize_error, {bad_token, _}}},
            symbolic_ask:run_result(Db, "does Foo/2 call bar/1?"))
    end).

tmp_db() ->
    filename:join(["/tmp", "symbolic_ask_tests_"
        ++ integer_to_list(erlang:unique_integer([positive])) ++ ".dets"]).
