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
        ok = symbolic_fact_store:write_metadata(Path, #{<<"complete">> => true}),
        Body(Path)
    after
        file:delete(Path),
        file:delete(Path ++ ".scan.json")
    end.

%% --- rule 3: each shape answers in its own JSON type ---

yes_no_call_true_across_both_call_shapes_test() ->
    with_db(facts(), fun(Db) ->
        %% The answer keeps its yes/no fields and cites a matching fact.
        {ok, Local} = symbolic_ask:run_result(Db, "does foo/2 call bar/1?"),
        ?assertEqual(true, maps:get(<<"answer">>, Local)),
        [LocalWitness] = maps:get(<<"evidence">>, Local),
        ?assertEqual(#{
            <<"predicate">> => <<"calls">>,
            <<"file">> => <<"p.erl">>,
            <<"line">> => 10,
            <<"fact">> => #{
                <<"caller">> => <<"foo/2">>,
                <<"call">> => #{<<"kind">> => <<"local">>,
                    <<"name">> => <<"bar">>, <<"arity">> => 1}}},
            LocalWitness),
        {ok, Remote} = symbolic_ask:run_result(Db, "does foo/2 call halt/1?"),
        ?assertEqual(true, maps:get(<<"answer">>, Remote)),
        [RemoteWitness] = maps:get(<<"evidence">>, Remote),
        ?assertEqual(#{
            <<"predicate">> => <<"calls">>,
            <<"file">> => <<"p.erl">>,
            <<"line">> => 11,
            <<"fact">> => #{
                <<"caller">> => <<"foo/2">>,
                <<"call">> => #{<<"kind">> => <<"remote">>,
                    <<"module">> => <<"erlang">>,
                    <<"name">> => <<"halt">>, <<"arity">> => 1}}},
            RemoteWitness)
    end).

legacy_database_without_scan_metadata_makes_negative_unknown_test() ->
    with_db(facts(), fun(Db) ->
        ok = file:delete(Db ++ ".scan.json"),
        ?assertMatch({ok, #{<<"type">> := <<"unknown">>,
                            <<"scope">> := #{<<"complete">> := false}}},
            symbolic_ask:run_result(Db, "does baz/3 call halt/1?"))
    end).

complete_scan_negative_includes_its_scope_test() ->
    Metadata = #{<<"complete">> => true,
        <<"scan_paths">> => [<<"/project/src">>],
        <<"files">> => 4, <<"failed_files">> => []},
    {ok, Answer} = symbolic_ask:ask(facts(),
        "does baz/3 call halt/1?", Metadata),
    ?assertEqual(false, maps:get(<<"answer">>, Answer)),
    ?assertEqual(#{<<"scan_paths">> => [<<"/project/src">>],
                   <<"files">> => 4, <<"complete">> => true,
                   <<"metadata_available">> => true,
                   <<"failed_files">> => []}, maps:get(<<"scope">>, Answer)).

incomplete_scan_makes_absence_unknown_but_keeps_positive_witness_test() ->
    Metadata = #{<<"complete">> => false,
        <<"scan_paths">> => [<<"/project/src">>],
        <<"files">> => 4,
        <<"failed_files">> => [<<"/project/src/broken.ts">>]},
    {ok, Unknown} = symbolic_ask:ask(facts(),
        "does baz/3 call halt/1?", Metadata),
    ?assertEqual(<<"unknown">>, maps:get(<<"type">>, Unknown)),
    ?assertEqual(#{<<"scan_paths">> => [<<"/project/src">>],
                        <<"files">> => 4,
                        <<"complete">> => false,
                        <<"metadata_available">> => true,
                        <<"failed_files">> => [<<"/project/src/broken.ts">>]},
        maps:get(<<"scope">>, Unknown)),
    {ok, Positive} = symbolic_ask:ask(facts(),
        "does foo/2 call bar/1?", Metadata),
    ?assertEqual(true, maps:get(<<"answer">>, Positive)),
    ?assertEqual(1, length(maps:get(<<"evidence">>, Positive))),
    ?assertMatch({ok, #{<<"type">> := <<"unknown">>}},
        symbolic_ask:ask(facts(), "which functions call bar/1?", Metadata)),
    ?assertMatch({ok, #{<<"type">> := <<"unknown">>}},
        symbolic_ask:ask(facts(), "how many functions call bar/1?", Metadata)).

yes_no_call_false_is_an_answer_not_an_error_test() ->
    with_db(facts(), fun(Db) ->
        %% baz/3 exists and calls bar/1, but baz/3 does NOT call halt/1.
        ?assertEqual({ok, #{<<"type">> => <<"yes_no">>,
                            <<"answer">> => false, <<"evidence">> => []}},
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
        {ok, #{<<"type">> := <<"enumerate">>, <<"answer">> := Callers,
               <<"evidence">> := Evidence, <<"evidence_complete">> := Complete}} =
            symbolic_ask:run_result(Db, "which functions call bar/1?"),
        ?assertEqual([<<"baz/3">>, <<"foo/2">>], Callers),
        ?assertEqual(true, Complete),
        ?assertEqual(2, length(Evidence)),
        ?assertEqual([<<"foo/2">>, <<"baz/3">>],
            [maps:get(<<"caller">>, maps:get(<<"fact">>, E)) || E <- Evidence]),
        ?assertEqual([10, 12], [maps:get(<<"line">>, E) || E <- Evidence]),
        ?assert(lists:all(fun(E) -> maps:get(<<"predicate">>, E) =:= <<"calls">> end,
            Evidence))
    end).

count_counts_distinct_functions_test() ->
    with_db(facts(), fun(Db) ->
        {ok, Answer} = symbolic_ask:run_result(Db,
            "how many functions call bar/1?"),
        ?assertEqual(2, maps:get(<<"answer">>, Answer)),
        ?assertEqual(true, maps:get(<<"evidence_complete">>, Answer)),
        ?assertEqual(2, length(maps:get(<<"evidence">>, Answer)))
    end).

caller_evidence_is_capped_and_reports_incompleteness_test() ->
    Callers = [list_to_atom("caller_" ++ integer_to_list(N)) || N <- lists:seq(1, 52)],
    CallFacts = [{calls, Caller, 1, {local, bar, 1}, 'callers.erl', N + 1}
        || {Caller, N} <- lists:zip(Callers, lists:seq(1, 52))],
    with_db([{defines, bar, 1, [], "bar.erl", 1} | CallFacts], fun(Db) ->
        {ok, Enumerated} = symbolic_ask:run_result(Db,
            "which functions call bar/1?"),
        ?assertEqual(52, length(maps:get(<<"answer">>, Enumerated))),
        ?assertEqual(50, length(maps:get(<<"evidence">>, Enumerated))),
        ?assertEqual(false, maps:get(<<"evidence_complete">>, Enumerated)),
        {ok, Counted} = symbolic_ask:run_result(Db,
            "how many functions call bar/1?"),
        ?assertEqual(52, maps:get(<<"answer">>, Counted)),
        ?assertEqual(50, length(maps:get(<<"evidence">>, Counted))),
        ?assertEqual(false, maps:get(<<"evidence_complete">>, Counted))
    end).

is_defined_true_and_false_test() ->
    with_db(facts(), fun(Db) ->
        {ok, Defined} = symbolic_ask:run_result(Db, "is foo/2 defined?"),
        ?assertEqual(true, maps:get(<<"answer">>, Defined)),
        [Definition] = maps:get(<<"evidence">>, Defined),
        ?assertEqual(#{<<"predicate">> => <<"defines">>,
            <<"file">> => <<"p.erl">>, <<"line">> => 1,
            <<"fact">> => #{<<"function">> => <<"foo/2">>}}, Definition),
        ?assertEqual({ok, #{<<"type">> => <<"yes_no">>,
                            <<"answer">> => false, <<"evidence">> => []}},
            symbolic_ask:run_result(Db, "is zzz/9 defined?")),
        ?assertEqual({ok, #{<<"type">> => <<"yes_no">>,
                            <<"answer">> => false, <<"evidence">> => []}},
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

overloaded_identifier_returns_candidates_instead_of_first_arity_test() ->
    Facts = [{defines, lookup, 1, [], "lookup.ts", 1},
             {defines, lookup, 2, [], "lookup.ts", 4}],
    with_db(Facts, fun(Db) ->
        {error, {ambiguous, Candidates}} = symbolic_ask:run_result(Db,
            "is lookup defined?"),
        ?assertEqual([#{<<"name">> => <<"lookup">>, <<"arity">> => 1,
                        <<"file">> => <<"lookup.ts">>, <<"line">> => 1},
                      #{<<"name">> => <<"lookup">>, <<"arity">> => 2,
                        <<"file">> => <<"lookup.ts">>, <<"line">> => 4}], Candidates),
        ?assertEqual(#{<<"type">> => <<"ambiguous">>,
            <<"reason">> => <<"The name matches multiple functions. Choose one candidate or specify its arity.">>,
            <<"candidates">> => Candidates}, symbolic_ask:ambiguity_answer(Candidates))
    end).

multiple_identifier_candidates_are_not_resolved_by_order_test() ->
    Facts = [{defines, foo, 1, [], "x.ts", 1},
             {defines, bar, 1, [], "x.ts", 2},
             {defines, baz, 1, [], "x.ts", 3}],
    with_db(Facts, fun(Db) ->
        ?assertMatch({error, {ambiguous, [_, _]}},
            symbolic_ask:run_result(Db, "does foo bar call baz?"))
    end).

relation_verb_lookalike_identifier_is_grounded_as_a_name_test() ->
    Facts = [{defines, call, 0, [], "relation-word.ts", 1},
             {defines, bar, 1, [], "relation-word.ts", 2},
             {calls, call, 0, {local, bar, 1}, "relation-word.ts", 4}],
    with_db(Facts, fun(Db) ->
        {ok, Answer} = symbolic_ask:run_result(Db,
            "does call/0 call bar/1?"),
        ?assertEqual(true, maps:get(<<"answer">>, Answer)),
        [Witness] = maps:get(<<"evidence">>, Answer),
        ?assertEqual(4, maps:get(<<"line">>, Witness))
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
        {ok, HaltAnswer} = symbolic_ask:run_result(Db, "does foo/2 call halt/1?"),
        ?assertEqual(true, maps:get(<<"answer">>, HaltAnswer)),
        ?assertEqual(1, length(maps:get(<<"evidence">>, HaltAnswer))),
        %% A stdlib-shaped name nothing calls answers false, cleanly.
        ?assertEqual({ok, #{<<"type">> => <<"yes_no">>,
                            <<"answer">> => false, <<"evidence">> => []}},
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
        {ok, UsesAnswer} = symbolic_ask:run_result(Db, "does verifyCode/1 use message?"),
        ?assertEqual(true, maps:get(<<"answer">>, UsesAnswer)),
        [UsesWitness] = maps:get(<<"evidence">>, UsesAnswer),
        ?assertEqual(#{<<"predicate">> => <<"expr_ref">>,
            <<"file">> => <<"supabaseOtp.ts">>, <<"line">> => 4,
            <<"fact">> => #{<<"function">> => <<"verifyCode/1">>,
                            <<"identifier">> => <<"message">>}}, UsesWitness),
        {ok, FileUses} = symbolic_ask:run_result(Db,
            "does file supabaseOtp.ts use message?"),
        ?assertEqual(true, maps:get(<<"answer">>, FileUses)),
        [FileUsesWitness] = maps:get(<<"evidence">>, FileUses),
        ?assertEqual(<<"supabaseOtp.ts">>, maps:get(<<"file">>, FileUsesWitness)),
        %% Line-scoped returns: the expr_ref message sits on line 4, the
        %% return on line 5 — a mention outside the return statement
        %% does not make "returns message" true.
        ?assertEqual({ok, #{<<"type">> => <<"yes_no">>,
                            <<"answer">> => false, <<"evidence">> => []}},
            symbolic_ask:run_result(Db, "does verifyCode/1 return message?")),
        {ok, HandlesAnswer} = symbolic_ask:run_result(Db,
            "does getClaimPhoneErrorMessage/1 handle alreadySignedIn?"),
        ?assertEqual(true, maps:get(<<"answer">>, HandlesAnswer)),
        [LiteralWitness] = maps:get(<<"evidence">>, HandlesAnswer),
        ?assertEqual(#{<<"predicate">> => <<"literal">>,
            <<"file">> => <<"useClaimAccount.ts">>, <<"line">> => 6,
            <<"fact">> => #{<<"function">> => <<"getClaimPhoneErrorMessage/1">>,
                <<"kind">> => <<"string">>, <<"value">> => <<"alreadySignedIn">>}},
            LiteralWitness),
        SitesResult = symbolic_ask:run_result(Db, "where is verifyCode/1 called?"),
        ?assertMatch({ok, #{<<"type">> := <<"sites">>, <<"answer">> := [_ | _]}},
            SitesResult),
        {ok, ScannedAnswer} = symbolic_ask:run_result(Db,
            "is file JoinAccountModal.ts scanned?"),
        ?assertEqual(true, maps:get(<<"answer">>, ScannedAnswer)),
        [ScanWitness] = maps:get(<<"evidence">>, ScannedAnswer),
        ?assertEqual(#{<<"predicate">> => <<"defines">>,
            <<"file">> => <<"JoinAccountModal.ts">>, <<"line">> => 3,
            <<"fact">> => #{<<"function">> => <<"JoinAccountModal/1">>}},
            ScanWitness),
        ?assertEqual({ok, #{<<"type">> => <<"yes_no">>,
                            <<"answer">> => false, <<"evidence">> => []}},
            symbolic_ask:run_result(Db, "is file nope.ts scanned?")),
        {ok, ConfigAnswer} = symbolic_ask:run_result(Db,
            "is config auth.codeExpiredError defined?"),
        ?assertEqual(true, maps:get(<<"answer">>, ConfigAnswer)),
        [ConfigWitness] = maps:get(<<"evidence">>, ConfigAnswer),
        ?assertEqual(#{<<"predicate">> => <<"config_value">>,
            <<"file">> => <<"en.json">>, <<"line">> => 3,
            <<"fact">> => #{<<"key">> => <<"auth.codeExpiredError">>,
                            <<"value">> => <<"expired copy">>}}, ConfigWitness)
    end).

%% Gap 1: a returned object's field is a property KEY, not an expr_ref —
%% the returns join must see object_key or "does X return reason?"
%% answers a confident false about `{ reason: "expired" }`.
catalog_declares_evidence_bearing_definition_sites_test() ->
    {ok, Operation} = symbolic_ask_catalog:lookup(
        sites, {def_site_of, {'/', foo, 1}}),
    ?assertEqual(definition_sites, maps:get(id, Operation)),
    ?assertEqual(sites, maps:get(answer, Operation)),
    ?assertEqual(closed_world, maps:get(world, Operation)),
    ?assertEqual(source_location, maps:get(evidence, Operation)),
    ?assertEqual(error, symbolic_ask_catalog:lookup(arbitrary, goal)).

catalog_discovery_describes_supported_inputs_and_answer_contracts_test() ->
    #{<<"operations">> := Operations} = symbolic_ask_catalog:describe(),
    ?assertEqual(14, length(Operations)),
    Ids = [maps:get(<<"id">>, Op) || Op <- Operations],
    ?assertEqual(length(Ids), length(lists:usort(Ids))),
    lists:foreach(fun(Op) ->
        ?assert(is_binary(maps:get(<<"description">>, Op))),
        ?assert(is_list(maps:get(<<"inputs">>, Op))),
        ?assert(is_map(maps:get(<<"answer_shape">>, Op))),
        ?assert(is_binary(maps:get(<<"world_description">>, Op))),
        ?assert(is_binary(maps:get(<<"evidence_description">>, Op))),
        ?assert(length(maps:get(<<"examples">>, Op)) > 0),
        ?assert(is_binary(maps:get(<<"limits">>, Op)))
    end, Operations),
    Calls = lists:keyfind(<<"calls">>, 1,
        [{maps:get(<<"id">>, Op), Op} || Op <- Operations]),
    {<<"calls">>, CallsOp} = Calls,
    ?assertEqual(<<"yes_no">>, maps:get(<<"answer_type">>, CallsOp)),
    ?assertEqual(<<"closed_world">>, maps:get(<<"world">>, CallsOp)),
    ?assertEqual(<<"source_location">>, maps:get(<<"evidence">>, CallsOp)),
    ?assertEqual(<<"witness">>, maps:get(<<"evidence_mode">>, CallsOp)),
    ?assertMatch(#{<<"properties">> := #{<<"evidence">> := #{<<"type">> := <<"array">>}}},
        maps:get(<<"answer_shape">>, CallsOp)),
    ?assertMatch(#{<<"properties">> := #{<<"type">> :=
        #{<<"const">> := <<"unknown">>}, <<"scope">> := _}},
        maps:get(<<"incomplete_scan_answer_shape">>, CallsOp)),
    {_, ProseOp} = lists:keyfind(<<"prose_search">>, 1,
        [{maps:get(<<"id">>, Op), Op} || Op <- Operations]),
    ?assertEqual(null, maps:get(<<"incomplete_scan_answer_shape">>, ProseOp)),
    ?assertMatch(#{<<"properties">> := #{<<"type">> :=
        #{<<"const">> := <<"ambiguous">>}, <<"candidates">> := _}},
        maps:get(<<"ambiguity_answer_shape">>, symbolic_ask_catalog:describe())),
    ?assertMatch([#{<<"name">> := <<"caller">>, <<"type">> := <<"function">>},
                  #{<<"name">> := <<"callee">>, <<"type">> := <<"function">>}],
        maps:get(<<"inputs">>, CallsOp)),
    ?assert(is_binary(maps:get(<<"description">>, CallsOp))),
    ?assert(length(maps:get(<<"examples">>, CallsOp)) > 0),
    {_, CallersOp} = lists:keyfind(<<"callers">>, 1,
        [{maps:get(<<"id">>, Op), Op} || Op <- Operations]),
    ?assertEqual(50, maps:get(<<"evidence_limit">>, CallersOp)),
    ?assertEqual(<<"capped_matches">>, maps:get(<<"evidence_mode">>, CallersOp)),
    ?assertMatch(#{<<"properties">> := #{<<"evidence_complete">> := #{<<"type">> := <<"boolean">>}}},
        maps:get(<<"answer_shape">>, CallersOp)),
    {_, ReturnsOp} = lists:keyfind(<<"returns_mention">>, 1,
        [{maps:get(<<"id">>, Op), Op} || Op <- Operations]),
    ?assertEqual(<<"witness_pair">>, maps:get(<<"evidence_mode">>, ReturnsOp)),
    ?assertMatch(#{<<"properties">> := #{<<"evidence">> :=
        #{<<"items">> := #{<<"oneOf">> := [_, _, _]}}}},
        maps:get(<<"answer_shape">>, ReturnsOp)),
    {_, CallsInFileOp} = lists:keyfind(<<"calls_in_file">>, 1,
        [{maps:get(<<"id">>, Op), Op} || Op <- Operations]),
    ?assertEqual(<<"source_location">>, maps:get(<<"evidence">>, CallsInFileOp)),
    ?assertEqual(<<"witness">>, maps:get(<<"evidence_mode">>, CallsInFileOp)),
    ?assertMatch(#{<<"properties">> := #{<<"evidence">> :=
        #{<<"items">> := #{<<"properties">> := #{<<"predicate">> :=
            #{<<"const">> := <<"calls">>}}}}}},
        maps:get(<<"answer_shape">>, CallsInFileOp)).

catalog_examples_are_recognized_by_the_question_pipeline_test() ->
    with_db(facts(), fun(Db) ->
        Examples = lists:append([
            maps:get(<<"examples">>, Op) || Op <- maps:get(<<"operations">>,
                symbolic_ask_catalog:describe())]),
        lists:foreach(fun(Example) ->
            ?assertNotEqual(unrecognized,
                symbolic_ask:run_result(Db, binary_to_list(Example)))
        end, Examples)
    end).

definition_site_is_exact_arity_and_carries_function_identity_test() ->
    Facts = [
        {defines, foo, 1, [], 'src/foo.erl', 10},
        {defines, foo, 2, [], 'src/foo.erl', 20},
        {defines, foo, 1, [], 'src/other.erl', 30}
    ],
    Expected = {ok, #{
        <<"type">> => <<"sites">>,
        <<"answer">> => [
            #{<<"function">> => <<"foo/1">>, <<"file">> => <<"src/foo.erl">>, <<"line">> => 10},
            #{<<"function">> => <<"foo/1">>, <<"file">> => <<"src/other.erl">>, <<"line">> => 30}
        ]
    }},
    with_db(Facts, fun(Db) ->
        ?assertEqual(Expected,
            symbolic_ask:run_result(Db, "where is foo/1 defined?"))
    end).

pipeline_returns_object_key_test() ->
    Facts = [
        {defines, verifyCode, 1, [], 'supabaseOtp.ts', 1},
        {return_stmt, verifyCode, 1, true, 'supabaseOtp.ts', 2},
        {object_key, verifyCode, 1, reason, 'supabaseOtp.ts', 2}
    ],
    with_db(Facts, fun(Db) ->
        {ok, Answer} = symbolic_ask:run_result(Db,
            "does verifyCode/1 return reason?"),
        ?assertEqual(true, maps:get(<<"answer">>, Answer)),
        ?assertEqual([
            #{<<"predicate">> => <<"object_key">>,
              <<"file">> => <<"supabaseOtp.ts">>, <<"line">> => 2,
              <<"fact">> => #{<<"function">> => <<"verifyCode/1">>,
                              <<"key">> => <<"reason">>}},
            #{<<"predicate">> => <<"return_stmt">>,
              <<"file">> => <<"supabaseOtp.ts">>, <<"line">> => 2,
              <<"fact">> => #{<<"function">> => <<"verifyCode/1">>,
                              <<"has_value">> => true}}
        ], lists:sort(fun(A, B) ->
            {maps:get(<<"predicate">>, A), maps:get(<<"file">>, A)} =<
            {maps:get(<<"predicate">>, B), maps:get(<<"file">>, B)}
        end, maps:get(<<"evidence">>, Answer)))
    end).

pipeline_returns_expr_ref_includes_both_witness_facts_test() ->
    Facts = [
        {defines, renderError, 1, [], 'src/render.ts', 1},
        {return_stmt, renderError, 1, true, 'src/render.ts', 4},
        {expr_ref, [0], renderError, 1, reason, 'src/render.ts', 4}
    ],
    with_db(Facts, fun(Db) ->
        {ok, Answer} = symbolic_ask:run_result(Db,
            "does renderError/1 return reason?"),
        ?assertEqual(true, maps:get(<<"answer">>, Answer)),
        Evidence = maps:get(<<"evidence">>, Answer),
        ?assertEqual(2, length(Evidence)),
        ?assertEqual([<<"expr_ref">>, <<"return_stmt">>],
            lists:sort([maps:get(<<"predicate">>, E) || E <- Evidence])),
        ?assert(lists:all(fun(E) ->
            maps:get(<<"file">>, E) =:= <<"src/render.ts">> andalso
            maps:get(<<"line">>, E) =:= 4
        end, Evidence))
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
        ?assertEqual({ok, #{<<"type">> => <<"yes_no">>,
                            <<"answer">> => false, <<"evidence">> => []}},
            symbolic_ask:run_result(Db, "does verifyPhoneCode/1 return message?"))
    end).

%% File subjects retain the existing file gate and basename matching,
%% and cite a matching calls fact for positive answers.
pipeline_file_subject_calls_test() ->
    Facts = [
        {defines, 'JoinAccountModal', 1, [], 'JoinAccountModal.ts', 1},
        {calls, 'JoinAccountModal', 1, {local, setError, 1}, 'JoinAccountModal.ts', 2},
        {calls, 'JoinAccountModal', 1, {member, form, setError, 1}, 'JoinAccountModal.ts', 4},
        {defines, setError, 1, [], 'JoinAccountModal.ts', 3},
        {defines, unrelated, 0, [], 'Other.ts', 1},
        {calls, unrelated, 0, {local, setError, 1}, 'Other.ts', 2}
    ],
    with_db(Facts, fun(Db) ->
        {ok, Positive} = symbolic_ask:run_result(Db,
            "does file JoinAccountModal.ts call setError/1?"),
        ?assertEqual(true, maps:get(<<"answer">>, Positive)),
        ?assertEqual([#{<<"predicate">> => <<"calls">>,
            <<"file">> => <<"JoinAccountModal.ts">>, <<"line">> => 2,
            <<"fact">> => #{<<"caller">> => <<"JoinAccountModal/1">>,
                <<"call">> => #{<<"kind">> => <<"local">>,
                    <<"name">> => <<"setError">>, <<"arity">> => 1}}}],
            maps:get(<<"evidence">>, Positive)),
        ?assertEqual({ok, #{<<"type">> => <<"yes_no">>,
                            <<"answer">> => false, <<"evidence">> => []}},
            symbolic_ask:run_result(Db, "does file JoinAccountModal.ts call missing/1?")),
        {ok, MemberAnswer} = symbolic_ask:run_result(Db,
            "does file JoinAccountModal.ts call form.setError/1?"),
        ?assertEqual([#{<<"predicate">> => <<"calls">>,
            <<"file">> => <<"JoinAccountModal.ts">>, <<"line">> => 4,
            <<"fact">> => #{<<"caller">> => <<"JoinAccountModal/1">>,
                <<"call">> => #{<<"kind">> => <<"member">>,
                    <<"receiver">> => <<"form">>, <<"method">> => <<"setError">>,
                    <<"arity">> => 1}}}], maps:get(<<"evidence">>, MemberAnswer)),
        ?assertMatch({error, {unverifiable, {no_such_file, _}}},
            symbolic_ask:run_result(Db, "does file nope.ts call setError/1?"))
    end).

%% Gap 3: "what calls X?" parses like which/who.
%% A snake_case subject whose front half is a relation verb
%% (handle_query) must not be misread as a verb with an empty subject.
pipeline_snake_case_verb_half_subject_test() ->
    Facts = [
        {defines, handle_query, 1, [], 'serve.ts', 1},
        {calls, handle_query, 1, {remote, maps, get, 2}, 'serve.ts', 2},
        {defines, get, 2, [], 'maps.ts', 3}
    ],
    with_db(Facts, fun(Db) ->
        {ok, Answer} = symbolic_ask:run_result(Db, "does handle_query/1 call maps/get/2?"),
        ?assertEqual(true, maps:get(<<"answer">>, Answer)),
        [Witness] = maps:get(<<"evidence">>, Answer),
        ?assertEqual(<<"serve.ts">>, maps:get(<<"file">>, Witness)),
        ?assertEqual(2, maps:get(<<"line">>, Witness)),
        ?assertEqual(<<"remote">>, maps:get(<<"kind">>, maps:get(<<"call">>, maps:get(<<"fact">>, Witness)))),
        ?assertEqual({ok, #{<<"type">> => <<"yes_no">>,
                            <<"answer">> => false, <<"evidence">> => []}},
            symbolic_ask:run_result(Db, "does handle_query/1 call render_query/2?"))
    end).

dotted_remote_call_yes_no_includes_module_and_source_site_test() ->
    Facts = [
        {defines, callRemote, 1, [], 'src/remote.ts', 1},
        {calls, callRemote, 1, {remote, 'supabase.auth', verifyOtp, 2},
            'src/remote.ts', 9}
    ],
    with_db(Facts, fun(Db) ->
        {ok, Answer} = symbolic_ask:run_result(Db,
            "does callRemote/1 call supabase.auth.verifyOtp/2?"),
        ?assertEqual(true, maps:get(<<"answer">>, Answer)),
        [Witness] = maps:get(<<"evidence">>, Answer),
        ?assertEqual(#{<<"predicate">> => <<"calls">>,
            <<"file">> => <<"src/remote.ts">>, <<"line">> => 9,
            <<"fact">> => #{<<"caller">> => <<"callRemote/1">>,
                <<"call">> => #{<<"kind">> => <<"remote">>,
                    <<"module">> => <<"supabase.auth">>,
                    <<"name">> => <<"verifyOtp">>, <<"arity">> => 2}}}, Witness)
    end).

member_call_yes_no_includes_receiver_and_source_site_test() ->
    Facts = [
        {defines, callMember, 1, [], 'src/member.ts', 1},
        {calls, callMember, 1, {member, 'supabase.auth', verifyOtp, 2}, 'src/member.ts', 8}
    ],
    with_db(Facts, fun(Db) ->
        {ok, Answer} = symbolic_ask:run_result(Db,
            "does callMember/1 call supabase.auth.verifyOtp/2?"),
        ?assertEqual(true, maps:get(<<"answer">>, Answer)),
        [Witness] = maps:get(<<"evidence">>, Answer),
        ?assertEqual(#{
            <<"predicate">> => <<"calls">>,
            <<"file">> => <<"src/member.ts">>,
            <<"line">> => 8,
            <<"fact">> => #{
                <<"caller">> => <<"callMember/1">>,
                <<"call">> => #{<<"kind">> => <<"member">>,
                    <<"receiver">> => <<"supabase.auth">>,
                    <<"method">> => <<"verifyOtp">>, <<"arity">> => 2}}},
            Witness)
    end).

pipeline_what_calls_test() ->
    Facts = [
        {calls, 'JoinAccountModal', 1, {local, setError, 1}, 'm.ts', 1},
        {defines, 'JoinAccountModal', 1, [], 'm.ts', 2}
    ],
    with_db(Facts, fun(Db) ->
        {ok, Answer} = symbolic_ask:run_result(Db, "what calls setError/1?"),
        ?assertEqual([<<"JoinAccountModal/1">>], maps:get(<<"answer">>, Answer)),
        ?assertEqual(true, maps:get(<<"evidence_complete">>, Answer)),
        ?assertEqual(1, length(maps:get(<<"evidence">>, Answer)))
    end).

tmp_db() ->
    filename:join(["/tmp", "symbolic_ask_tests_"
        ++ integer_to_list(erlang:unique_integer([positive])) ++ ".dets"]).
