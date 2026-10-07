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

%% Stage 2 changed this question's fate: the DCG tokenizer still
%% rejects the capitalized token, but the question now falls through to
%% the statistical tier, which parses it and gates it — `Foo/2` is not
%% in the fact base, so the answer is `unverifiable`, loudly, not a
%% tokenizer rejection and never a silent false.
capitalized_words_fall_through_to_the_statistical_tier_test() ->
    with_db(facts(), fun(Db) ->
        ?assertMatch({error, {unverifiable, {no_such_function, _, _}}},
            symbolic_ask:run_result(Db, "does Foo/2 call bar/1?"))
    end).

%% --- stage 2 unit tests: the pure mapper, no NIF, no session ---

%% Expected terms are bound to variables first: eunit's macro-argument
%% scanner mishandles deeply nested terms with binaries split across
%% lines, and a simple variable argument sidesteps it.

mapper_does_calls_shape_test() ->
    Tags = [{<<"does">>, <<"VBZ">>}, {<<"verifyPhoneCode">>, <<"NNP">>},
            {<<"call">>, <<"VB">>}, {<<"verifyOtp">>, <<"NNP">>},
            {<<"?">>, <<".">>}],
    Expected = {ok, {yes_no, {calls,
        [{<<"verifyPhoneCode">>, <<"NNP">>}],
        [{<<"verifyOtp">>, <<"NNP">>}]}}},
    ?assertEqual(Expected, symbolic_ask:map_tags(Tags)).

mapper_does_defines_shape_test() ->
    Tags = [{<<"does">>, <<"VBZ">>}, {<<"verifyResult">>, <<"NN">>},
            {<<"exist">>, <<"VBZ">>}],
    Expected = {ok, {yes_no, {defines, [{<<"verifyResult">>, <<"NN">>}]}}},
    ?assertEqual(Expected, symbolic_ask:map_tags(Tags)).

mapper_passive_swaps_subject_and_object_test() ->
    Tags = [{<<"is">>, <<"VBZ">>}, {<<"verifyOtp">>, <<"NNP">>},
            {<<"called">>, <<"VBN">>}, {<<"by">>, <<"IN">>},
            {<<"verifyPhoneCode">>, <<"NNP">>}],
    Expected = {ok, {yes_no, {calls,
        [{<<"verifyPhoneCode">>, <<"NNP">>}],
        [{<<"verifyOtp">>, <<"NNP">>}]}}},
    ?assertEqual(Expected, symbolic_ask:map_tags(Tags)).

mapper_which_and_how_many_shapes_test() ->
    Pair = {<<"setError">>, <<"NN">>},
    ExpectedWhich = {ok, {enumerate, {callers_of, [Pair]}}},
    ?assertEqual(ExpectedWhich,
        symbolic_ask:map_tags([{<<"which">>, <<"WDT">>},
                               {<<"functions">>, <<"NNS">>},
                               {<<"call">>, <<"VB">>},
                               {<<"setError">>, <<"NN">>}])),
    ExpectedCount = {ok, {count, {callers_of, [Pair]}}},
    ?assertEqual(ExpectedCount,
        symbolic_ask:map_tags([{<<"how">>, <<"RB">>},
                               {<<"many">>, <<"JJ">>},
                               {<<"functions">>, <<"NNS">>},
                               {<<"call">>, <<"VB">>},
                               {<<"setError">>, <<"NN">>}])).

mapper_snake_case_rejoins_via_glue_tokens_test() ->
    Tags = [{<<"how">>, <<"RB">>}, {<<"many">>, <<"JJ">>},
            {<<"functions">>, <<"NNS">>}, {<<"call">>, <<"VB">>},
            {<<"optional">>, <<"JJ">>}, {<<"_">>, <<"NFP">>},
            {<<"path">>, <<"NN">>}],
    ?assertMatch({ok, {count, {callers_of, _}}}, symbolic_ask:map_tags(Tags)),
    ?assertEqual([<<"optional_path">>],
        symbolic_ask:ident_candidates([{<<"optional">>, <<"JJ">>},
                                       {<<"_">>, <<"NFP">>},
                                       {<<"path">>, <<"NN">>}])).

mapper_dotted_path_and_arity_rejoin_test() ->
    ?assertEqual([<<"supabase.auth.verifyOtp/2">>],
        symbolic_ask:ident_candidates(
            [{<<"supabase">>, <<"NNP">>}, {<<".">>, <<"NFP">>},
             {<<"auth">>, <<"NNP">>}, {<<".">>, <<"NFP">>},
             {<<"verifyOtp">>, <<"NNP">>}, {<<"/">>, <<"SYN">>},
             {<<"2">>, <<"CD">>}])).

mapper_prose_shape_test() ->
    Tags = [{<<"where">>, <<"WRB">>}, {<<"is">>, <<"VBZ">>},
            {<<"the">>, <<"DT">>}, {<<"question">>, <<"NN">>},
            {<<"grammar">>, <<"NN">>}, {<<"documented">>, <<"VBN">>}],
    Expected = {ok, {prose, [{<<"the">>, <<"DT">>},
                             {<<"question">>, <<"NN">>},
                             {<<"grammar">>, <<"NN">>}]}},
    ?assertEqual(Expected, symbolic_ask:map_tags(Tags)).

mapper_unrecognized_outside_the_vocabulary_test() ->
    ?assertEqual(unrecognized,
        symbolic_ask:map_tags([{<<"does">>, <<"VBZ">>},
                               {<<"verifyPhoneCode">>, <<"NNP">>},
                               {<<"celebrate">>, <<"VB">>},
                               {<<"a">>, <<"DT">>},
                               {<<"reason">>, <<"NN">>}])).

mapper_returns_and_handles_shapes_test() ->
    Subj = [{<<"verifyPhoneCode">>, <<"NNP">>}],
    ExpectedReturns = {ok, {yes_no, {returns, Subj, [{<<"message">>, <<"NN">>}]}}},
    ?assertEqual(ExpectedReturns,
        symbolic_ask:map_tags([{<<"does">>, <<"VBZ">>},
                               {<<"verifyPhoneCode">>, <<"NNP">>},
                               {<<"return">>, <<"VB">>},
                               {<<"message">>, <<"NN">>}])),
    ExpectedHandles = {ok, {yes_no, {handles,
        [{<<"getClaimPhoneErrorMessage">>, <<"NNP">>}],
        [{<<"alreadySignedIn">>, <<"JJ">>}]}}},
    ?assertEqual(ExpectedHandles,
        symbolic_ask:map_tags([{<<"does">>, <<"VBZ">>},
                               {<<"getClaimPhoneErrorMessage">>, <<"NNP">>},
                               {<<"handle">>, <<"VB">>},
                               {<<"alreadySignedIn">>, <<"JJ">>}])).

mapper_where_shapes_test() ->
    Site = [{<<"setError">>, <<"NNP">>}, {<<"/">>, <<".">>}, {<<"1">>, <<"CD">>}],
    ExpectedSites = {ok, {sites, {call_sites_of, Site}}},
    ?assertEqual(ExpectedSites,
        symbolic_ask:map_tags([{<<"where">>, <<"WRB">>},
                               {<<"is">>, <<"VBZ">>},
                               {<<"setError">>, <<"NNP">>},
                               {<<"/">>, <<".">>},
                               {<<"1">>, <<"CD">>},
                               {<<"called">>, <<"VBN">>}])).

mapper_file_and_config_shapes_test() ->
    FileTokens = [{<<"JoinAccountModal">>, <<"NNP">>},
                  {<<".">>, <<"NFP">>}, {<<"ts">>, <<"NN">>}],
    ExpectedFile = {ok, {yes_no, {file_scanned, FileTokens}}},
    ?assertEqual(ExpectedFile,
        symbolic_ask:map_tags([{<<"is">>, <<"VBZ">>},
                               {<<"file">>, <<"NN">>},
                               {<<"JoinAccountModal">>, <<"NNP">>},
                               {<<".">>, <<"NFP">>},
                               {<<"ts">>, <<"NN">>},
{<<"scanned">>,<<"VBN">>}])),
    KeyTokens = [{<<"auth">>, <<"NNP">>}, {<<".">>, <<"NFP">>},
                 {<<"codeExpiredError">>, <<"NNP">>}],
    ExpectedConfig = {ok, {yes_no, {config_defined, KeyTokens}}},
    ?assertEqual(ExpectedConfig,
        symbolic_ask:map_tags([{<<"is">>, <<"VBZ">>},
                               {<<"config">>, <<"NN">>},
                               {<<"auth">>, <<"NNP">>},
                               {<<".">>, <<"NFP">>},
                               {<<"codeExpiredError">>, <<"NNP">>},
                               {<<"defined">>, <<"VBN">>}])).

pipeline_uses_returns_handles_sites_scanned_config_test() ->
    Facts = [
        {defines, verifyCode, 1, [], 'supabaseOtp.ts', 1},
        {defines, getClaimPhoneErrorMessage, 1, [], 'useClaimAccount.ts', 2},
        {defines, 'JoinAccountModal', 1, [], 'JoinAccountModal.ts', 3},
        {expr_ref, [0, 1], verifyCode, 1, message, 'supabaseOtp.ts', 4},
        {return_stmt, verifyCode, 1, true, 'supabaseOtp.ts', 5},
        {object_key, verifyCode, 1, reason, 'supabaseOtp.ts', 5},
        {literal, [0, 2], getClaimPhoneErrorMessage, 1, string,
         alreadySignedIn, 'useClaimAccount.ts', 6, "\"alreadySignedIn\""},
        {calls, 'JoinAccountModal', 1, {local, verifyCode, 1}, 'JoinAccountModal.ts', 7},
        {comment, 'JoinAccountModal.ts', 8, <<"the join modal prose">>},
        {config_value, 'en.json', 'auth.codeExpiredError', <<"expired copy">>, 3}
    ],
    with_db(Facts, fun(Db) ->
        ?assertEqual({ok, yes_no_true()},
            symbolic_ask:run_result(Db, "does verifyCode/1 use message?")),
        %% Line-scoped returns: the expr_ref message sits on line 4, the
        %% return on line 5 — a mention outside the return statement
        %% does not make "returns message" true.
        ?assertEqual({ok, yes_no_false()},
            symbolic_ask:run_result(Db, "does verifyCode/1 return message?")),
        ?assertEqual({ok, yes_no_true()},
            symbolic_ask:run_result(Db, "does getClaimPhoneErrorMessage/1 handle alreadySignedIn?")),
        SitesResult = symbolic_ask:run_result(Db, "where is verifyCode/1 called?"),
        ?assertMatch({ok, #{<<"type">> := <<"sites">>, <<"answer">> := [_ | _]}},
            SitesResult),
        ?assertEqual({ok, yes_no_true()},
            symbolic_ask:run_result(Db, "is file JoinAccountModal.ts scanned?")),
        ?assertEqual({ok, yes_no_false()},
            symbolic_ask:run_result(Db, "is file nope.ts scanned?")),
        ?assertEqual({ok, yes_no_true()},
            symbolic_ask:run_result(Db, "is config auth.codeExpiredError defined?"))
    end).

%% Gap 1: a returned object's field is a property KEY, not an expr_ref —
%% the returns join must see object_key or "does X return reason?"
%% answers a confident false about `{ reason: "expired" }`.
pipeline_returns_object_key_test() ->
    Facts = [
        {defines, verifyCode, 1, [], 'supabaseOtp.ts', 1},
        {return_stmt, verifyCode, 1, true, 'supabaseOtp.ts', 2},
        {object_key, verifyCode, 1, reason, 'supabaseOtp.ts', 2}
    ],
    with_db(Facts, fun(Db) ->
        ?assertEqual({ok, yes_no_true()},
            symbolic_ask:run_result(Db, "does verifyCode/1 return reason?"))
    end).

%% The line scope cuts both ways: a mention elsewhere in the function
%% (a logger diagnostic naming the field) must NOT make "returns"
%% true — that is the true→false flip the claims check depends on.
pipeline_returns_line_scope_test() ->
    Facts = [
        {defines, verifyPhoneCode, 1, [], 'useClaimAccount.ts', 1},
        {return_stmt, verifyPhoneCode, 1, true, 'useClaimAccount.ts', 2},
        {object_key, verifyPhoneCode, 1, message, 'useClaimAccount.ts', 5}
    ],
    with_db(Facts, fun(Db) ->
        ?assertEqual({ok, yes_no_false()},
            symbolic_ask:run_result(Db, "does verifyPhoneCode/1 return message?"))
    end).

%% Gap 2: file subjects route through the calls path — "does file F
%% call X?" gates the file, then proves through the sites answer.
pipeline_file_subject_calls_test() ->
    Facts = [
        {defines, 'JoinAccountModal', 1, [], 'JoinAccountModal.ts', 1},
        {calls, 'JoinAccountModal', 1, {local, setError, 1}, 'JoinAccountModal.ts', 2},
        {defines, setError, 1, [], 'JoinAccountModal.ts', 3}
    ],
    with_db(Facts, fun(Db) ->
        ?assertEqual({ok, yes_no_true()},
            symbolic_ask:run_result(Db, "does file JoinAccountModal.ts call setError/1?")),
        ?assertMatch({error, {unverifiable, {no_such_file, _}}},
            symbolic_ask:run_result(Db, "does file nope.ts call setError/1?"))
    end).

%% Gap 3: "what calls X?" parses like which/who.
pipeline_what_calls_test() ->
    Facts = [
        {calls, 'JoinAccountModal', 1, {local, setError, 1}, 'm.ts', 1},
        {defines, 'JoinAccountModal', 1, [], 'm.ts', 2}
    ],
    with_db(Facts, fun(Db) ->
        ?assertEqual({ok, #{<<"type">> => <<"enumerate">>, <<"answer">> => [<<"JoinAccountModal/1">>]}},
            symbolic_ask:run_result(Db, "what calls setError/1?"))
    end).

yes_no_true() -> #{<<"type">> => <<"yes_no">>, <<"answer">> => true}.
yes_no_false() -> #{<<"type">> => <<"yes_no">>, <<"answer">> => false}.

tmp_db() ->
    filename:join(["/tmp", "symbolic_ask_tests_"
        ++ integer_to_list(erlang:unique_integer([positive])) ++ ".dets"]).
