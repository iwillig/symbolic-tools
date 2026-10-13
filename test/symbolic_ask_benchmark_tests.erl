-module(symbolic_ask_benchmark_tests).
-include_lib("eunit/include/eunit.hrl").

%% Curated regression benchmark. Labels are deliberately data, not
%% assertions hidden in the implementation: each row carries the intended
%% catalog operation, slots, expected epistemic status, answer, and citations.

benchmark_cases_match_intent_slots_answers_and_evidence_test() ->
    BenchmarkPath = "test/fixtures/ask-benchmark.json",
    {ok, Json} = file:read_file(BenchmarkPath),
    Cases = jsx:decode(Json, [return_maps]),
    SamplePath = filename:absname("test/fixtures/sample.ts"),
    {ok, {SampleFiles, SampleFacts}} = symbolic_parse:scan_paths([SamplePath]),
    {ok, {ProjectFiles, ProjectFacts}} = symbolic_parse:scan("src"),
    SampleSource = #{facts => SampleFacts,
        path => filename:dirname(SamplePath), files => length(SampleFiles)},
    ProjectSource = #{facts => ProjectFacts,
        path => filename:absname("src"), files => length(ProjectFiles)},
    SyntheticSource = #{path => "/project", files => 1},
    Sources = #{<<"sample_ts">> => SampleSource,
                <<"project_src">> => ProjectSource,
                <<"overloaded">> => SyntheticSource#{facts => overloaded_facts()},
                <<"relation_word">> => SyntheticSource#{facts => relation_word_facts()} },
    Operations = maps:from_list([{maps:get(<<"id">>, Op), Op}
        || Op <- maps:get(<<"operations">>, symbolic_ask_catalog:describe())]),
    Scores = [score_case(Case, Sources, Operations) || Case <- Cases],
    ?assertEqual(length(Cases), length([ok || #{answer := pass} <- Scores])),
    ?assertEqual(length(Cases), length([ok || #{evidence := pass} <- Scores])),
    ?assertEqual(length(Cases), length([ok || #{intent := pass} <- Scores])),
    ?assertEqual(length(Cases), length([ok || #{slots := Score} <- Scores,
        Score =:= pass orelse Score =:= not_applicable])).

score_case(Case, Sources, Operations) ->
    Id = maps:get(<<"id">>, Case),
    assert_plan_reference(Case),
    Intent = maps:get(<<"operation">>, Case),
    Slots = maps:get(<<"slots">>, Case),
    Expected = maps:get(<<"expected">>, Case),
    ExpectedEvidence = maps:get(<<"evidence">>, Case),
    Source = maps:get(maps:get(<<"source">>, Case), Sources),
    SourceFacts = maps:get(facts, Source),
    Metadata = benchmark_metadata(Case, Source),
    {Result, Trace} = symbolic_ask:ask_detailed(SourceFacts,
        binary_to_list(maps:get(<<"question">>, Case)), Metadata),
    ExpectedStatus = maps:get(<<"status">>, Expected),
    ActualStatus = result_status(Result),
    ?assertEqual({Id, ExpectedStatus}, {Id, ActualStatus}),
    OperationScore = intent_score(Intent, Expected, ActualStatus, Trace, Operations),
    ?assertEqual({Id, pass}, {Id, OperationScore}),
    AnswerScore = score_bool(answer_score(Result, Expected, ExpectedStatus)),
    ?assertEqual({Id, pass}, {Id, AnswerScore}),
    EvidenceScore = score_bool(evidence_score(Result, ExpectedEvidence)),
    ?assertEqual({Id, pass}, {Id, EvidenceScore}),
    SlotScore = slots_score(Result, Slots, ExpectedStatus),
    ?assert(SlotScore =:= pass orelse SlotScore =:= not_applicable),
    #{id => Id, intent => OperationScore, slots => SlotScore,
      answer => AnswerScore, evidence => EvidenceScore}.

assert_plan_reference(Case) ->
    case maps:find(<<"plan_reference">>, Case) of
        {ok, Reference} ->
            [Path, Anchor] = binary:split(Reference, <<"#">>),
            ?assert(Anchor =/= <<>>),
            ?assert(filelib:is_regular(binary_to_list(Path)));
        error -> ok
    end.

benchmark_metadata(Case, Source) ->
    Complete = maps:get(<<"scan">>, Case, <<"complete">>) =/= <<"incomplete">>,
    Failed = case Complete of true -> []; false -> [<<"/project/broken.ts">>] end,
    #{<<"metadata_available">> => true,
      <<"complete">> => Complete,
      <<"scan_paths">> => [filename:absname(maps:get(path, Source))],
      <<"files">> => maps:get(files, Source),
      <<"failed_files">> => Failed}.

score_bool(true) -> pass;
score_bool(false) -> fail.

result_status({ok, #{<<"type">> := <<"unknown">>}}) -> <<"unknown">>;
result_status({ok, _Answer}) -> <<"answer">>;
result_status({error, {ambiguous, _Candidates}}) -> <<"ambiguous">>;
result_status({error, {unverifiable, _Reason}}) -> <<"unverifiable">>;
result_status(unrecognized) -> <<"unrecognized">>.

intent_score(<<"unsupported">>, _Expected, <<"unrecognized">>, undefined, _Operations) -> pass;
intent_score(Intent, _Expected, Status, Trace, Operations) ->
    case maps:find(Intent, Operations) of
        {ok, Operation} when is_map(Trace) ->
            ExpectedType = maps:get(<<"answer_type">>, Operation),
            TraceOperation = maps:get(<<"operation">>, Trace, undefined),
            TraceType = maps:get(<<"answer_type">>, Trace, undefined),
            case TraceOperation =:= Intent andalso TraceType =:= ExpectedType andalso
                 lists:member(Status, [<<"answer">>, <<"ambiguous">>,
                                       <<"unverifiable">>, <<"unknown">>]) of
                true -> pass;
                false -> fail
            end;
        _ -> fail
    end.

answer_score({ok, Answer}, Expected, <<"answer">>) ->
    TypeMatches = maps:get(<<"type">>, Answer) =:= maps:get(<<"type">>, Expected),
    case maps:find(<<"answer">>, Expected) of
        {ok, ExpectedValue} -> TypeMatches andalso
            maps:get(<<"answer">>, Answer) =:= ExpectedValue;
        error -> TypeMatches
    end;
answer_score({ok, #{<<"type">> := <<"unknown">>}}, _Expected, <<"unknown">>) -> true;
answer_score({error, {ambiguous, Candidates}}, Expected, <<"ambiguous">>) ->
    CandidateNames = [<<Name/binary, "/", (integer_to_binary(Arity))/binary>>
        || #{<<"name">> := Name, <<"arity">> := Arity} <- Candidates],
    CandidateNames =:= maps:get(<<"candidates">>, Expected);
answer_score({error, {unverifiable, _}}, _Expected, <<"unverifiable">>) -> true;
answer_score(unrecognized, _Expected, <<"unrecognized">>) -> true;
answer_score(_, _, _) -> false.

evidence_score(Result, ExpectedEvidence) ->
    Actual = case Result of
        {ok, Answer} -> maps:get(<<"evidence">>, Answer, []);
        _ -> []
    end,
    ActualCitations = lists:sort([citation(Evidence) || Evidence <- Actual]),
    ExpectedCitations = lists:sort([
        {maps:get(<<"predicate">>, E, maps:get(<<"kind">>, E, undefined)),
         binary_to_list(maps:get(<<"file">>, E)), maps:get(<<"line">>, E)}
        || E <- ExpectedEvidence]),
    case ActualCitations =:= ExpectedCitations of
        true -> true;
        false -> io:format("evidence mismatch: actual=~p expected=~p~n",
                           [ActualCitations, ExpectedCitations]), false
    end.

citation(Evidence) ->
    {maps:get(<<"predicate">>, Evidence, maps:get(<<"kind">>, Evidence, undefined)),
     filename:basename(binary_to_list(maps:get(<<"file">>, Evidence))),
     maps:get(<<"line">>, Evidence)}.

slots_score({ok, Answer}, Slots, <<"answer">>) ->
    case maps:is_key(<<"query">>, Slots) of
        true -> not_applicable;
        false -> score_fact_slots(Answer, Slots)
    end;
slots_score({error, {ambiguous, Candidates}}, Slots, <<"ambiguous">>) ->
    ExpectedName = maps:get(<<"function">>, Slots, undefined),
    case ExpectedName of
        undefined -> fail;
        _ ->
            case lists:all(fun(#{<<"name">> := Name}) -> Name =:= ExpectedName end,
                           Candidates) of
                true -> pass;
                false -> fail
            end
    end;
slots_score(_, _Slots, _) -> not_applicable.

score_fact_slots(Answer, Slots) ->
    Evidence = maps:get(<<"evidence">>, Answer, []),
    case Evidence of
        [] -> not_applicable;
        _ ->
            case lists:all(fun(E) -> evidence_matches_slots(E, Slots) end, Evidence) of
                true -> pass;
                false -> fail
            end
    end.

evidence_matches_slots(Evidence, Slots) ->
    Fact = maps:get(<<"fact">>, Evidence, #{}),
    CallerOk = case maps:find(<<"caller">>, Slots) of
        {ok, Caller} -> maps:get(<<"caller">>, Fact, undefined) =:= Caller;
        error -> true
    end,
    FunctionOk = case maps:find(<<"function">>, Slots) of
        {ok, Function} -> maps:get(<<"function">>, Fact, undefined) =:= Function;
        error -> true
    end,
    CalleeOk = case maps:find(<<"callee">>, Slots) of
        {ok, Callee} -> call_matches(maps:get(<<"call">>, Fact, #{}), Callee);
        error -> true
    end,
    CallerOk andalso FunctionOk andalso CalleeOk.

call_matches(Call, Callee) ->
    Name = maps:get(<<"name">>, Call, maps:get(<<"method">>, Call, undefined)),
    Arity = maps:get(<<"arity">>, Call, undefined),
    case binary:split(Callee, <<"/">>) of
        [ExpectedName, ExpectedArity] ->
            Name =:= ExpectedName andalso Arity =:= binary_to_integer(ExpectedArity);
        _ -> false
    end.

overloaded_facts() ->
    [{defines, lookup, 1, [], "/project/lookup.ts", 1},
     {defines, lookup, 2, [], "/project/lookup.ts", 2}].

relation_word_facts() ->
    [{defines, call, 0, [], "/project/relation-word.ts", 1},
     {defines, bar, 1, [], "/project/relation-word.ts", 2},
     {calls, call, 0, {local, bar, 1}, "/project/relation-word.ts", 4}].
