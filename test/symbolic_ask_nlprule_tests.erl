-module(symbolic_ask_nlprule_tests).
-include_lib("eunit/include/eunit.hrl").

nlprule_analysis_generates_a_bounded_call_frame_test() ->
    Analysis = #{<<"sentences">> => [#{<<"tokens">> => [
        token(<<"Does">>, <<"do">>, <<"VBZ">>, [<<"O">>], 0, 4),
        token(<<"foo">>, <<"foo">>, <<"NN">>, [], 5, 8),
        token(<<"/">>, <<"/">>, <<"UNKNOWN">>, [], 8, 9),
        token(<<"2">>, <<"2">>, <<"CD">>, [], 9, 10),
        token(<<"call">>, <<"call">>, <<"VBP">>, [<<"B-VP">>], 11, 15),
        token(<<"bar">>, <<"bar">>, <<"NN">>, [], 16, 19),
        token(<<"/">>, <<"/">>, <<"UNKNOWN">>, [], 19, 20),
        token(<<"1">>, <<"1">>, <<"CD">>, [], 20, 21),
        token(<<"?">>, <<"?">>, <<"PCT">>, [<<"O">>], 21, 22)
    ]}]},

    [#{sentence_index := 1, frame := {yes_no, {calls, Subject, Object}},
       analysis_tokens := AnalysisTokens}] = symbolic_ask_nlprule:extract_frames(Analysis),
    ?assertEqual([<<"foo">>, <<"/">>, <<"2">>], token_texts(Subject)),
    ?assertEqual([<<"bar">>, <<"/">>, <<"1">>], token_texts(Object)),
    ?assertEqual([<<"B-VP">>], maps:get(<<"chunks">>, lists:nth(5, AnalysisTokens))),
    ?assertEqual([#{<<"lemma">> => <<"call">>, <<"pos">> => <<"VBP">>}],
        maps:get(<<"tags">>, lists:nth(5, AnalysisTokens))).

nlprule_analysis_preserves_answer_kinds_and_abstains_test() ->
    Analysis = #{<<"sentences">> => [
        #{<<"tokens">> => [
            token(<<"Which">>, <<"which">>, <<"WP">>, [], 0, 5),
            token(<<"functions">>, <<"function">>, <<"NNS">>, [<<"B-VP">>], 6, 15),
            token(<<"call">>, <<"call">>, <<"VBP">>, [<<"B-NP-singular">>], 16, 20),
            token(<<"foo">>, <<"foo">>, <<"NN">>, [], 21, 24),
            token(<<"/">>, <<"/">>, <<"UNKNOWN">>, [], 24, 25),
            token(<<"2">>, <<"2">>, <<"CD">>, [], 25, 26),
            token(<<"?">>, <<"?">>, <<"PCT">>, [<<"O">>], 26, 27)
        ]},
        #{<<"tokens">> => [
            token(<<"How">>, <<"how">>, <<"WRB">>, [], 28, 31),
            token(<<"many">>, <<"many">>, <<"JJ">>, [], 32, 36),
            token(<<"functions">>, <<"function">>, <<"NNS">>, [<<"B-VP">>], 37, 46),
            token(<<"call">>, <<"call">>, <<"VBP">>, [<<"B-NP-singular">>], 47, 51),
            token(<<"foo">>, <<"foo">>, <<"NN">>, [], 52, 55),
            token(<<"/">>, <<"/">>, <<"UNKNOWN">>, [], 55, 56),
            token(<<"2">>, <<"2">>, <<"CD">>, [], 56, 57),
            token(<<"?">>, <<"?">>, <<"PCT">>, [<<"O">>], 57, 58)
        ]},
        #{<<"tokens">> => [
            token(<<"Where">>, <<"where">>, <<"WRB">>, [], 59, 64),

            token(<<"is">>, <<"be">>, <<"VBZ">>, [<<"B-VP">>], 34, 36),
            token(<<"dirty">>, <<"dirty">>, <<"JJ">>, [<<"B-NP-singular">>], 37, 42),
            token(<<"scheduler">>, <<"scheduler">>, <<"NN">>, [<<"E-NP-singular">>], 43, 52),
            token(<<"documented">>, <<"document">>, <<"VBN">>, [<<"B-VP">>], 53, 63),
            token(<<"?">>, <<"?">>, <<"PCT">>, [<<"O">>], 63, 64)
        ]},
        #{<<"tokens">> => [
            token(<<"Why">>, <<"why">>, <<"WRB">>, [], 65, 68),
            token(<<"does">>, <<"do">>, <<"VBZ">>, [<<"O">>], 69, 73),
            token(<<"foo">>, <<"foo">>, <<"NN">>, [], 74, 77),
            token(<<"cause">>, <<"cause">>, <<"VB">>, [<<"B-VP">>], 78, 83),
            token(<<"bar">>, <<"bar">>, <<"NN">>, [], 84, 87),
            token(<<"?">>, <<"?">>, <<"PCT">>, [<<"O">>], 87, 88)
        ]}
    ]},
    [Enumerate, Count, Prose] = symbolic_ask_nlprule:extract_frames(Analysis),
    ?assertEqual(1, maps:get(sentence_index, Enumerate)),
    ?assertMatch({enumerate, {callers_of, _}}, maps:get(frame, Enumerate)),
    ?assertEqual(2, maps:get(sentence_index, Count)),
    ?assertMatch({count, {callers_of, _}}, maps:get(frame, Count)),
    ?assertEqual(3, maps:get(sentence_index, Prose)),
    ?assertMatch({prose, _}, maps:get(frame, Prose)),
    [JsonEnumerate, JsonCount, JsonProse] =
        symbolic_ask_nlprule:extract_json_frames(Analysis),
    ?assertEqual(<<"enumerate">>, maps:get(<<"answer_type">>, JsonEnumerate)),
    ?assertEqual(<<"subject">>, maps:get(<<"answer_slot">>, JsonEnumerate)),
    ?assertEqual(<<"count">>, maps:get(<<"answer_type">>, JsonCount)),
    ?assertEqual(<<"evidence">>, maps:get(<<"answer_type">>, JsonProse)),
    ?assertEqual(<<"text_search">>, maps:get(<<"relation">>, JsonProse)),
    ?assert(is_binary(jsx:encode([JsonEnumerate, JsonCount, JsonProse]))).

nlprule_frame_serializes_as_llm_ready_json_objects_test() ->
    Analysis = #{<<"sentences">> => [#{
        <<"text">> => <<"Does foo/2 call bar/1?">>,
        <<"tokens">> => [
            token(<<"Does">>, <<"do">>, <<"VBZ">>, [<<"O">>], 0, 4),
            token(<<"foo">>, <<"foo">>, <<"NN">>, [], 5, 8),
            token(<<"/">>, <<"/">>, <<"UNKNOWN">>, [], 8, 9),
            token(<<"2">>, <<"2">>, <<"CD">>, [], 9, 10),
            token(<<"call">>, <<"call">>, <<"VBP">>, [<<"B-VP">>], 11, 15),
            token(<<"bar">>, <<"bar">>, <<"NN">>, [], 16, 19),
            token(<<"/">>, <<"/">>, <<"UNKNOWN">>, [], 19, 20),
            token(<<"1">>, <<"1">>, <<"CD">>, [], 20, 21),
            token(<<"?">>, <<"?">>, <<"PCT">>, [<<"O">>], 21, 22)
        ]}]},
    [JsonFrame] = symbolic_ask_nlprule:extract_json_frames(Analysis),
    ?assertEqual(<<"yes_no">>, maps:get(<<"answer_type">>, JsonFrame)),
    ?assertEqual(<<"calls">>, maps:get(<<"relation">>, JsonFrame)),
    Args = maps:get(<<"arguments">>, JsonFrame),
    Subject = maps:get(<<"subject">>, Args),
    Object = maps:get(<<"object">>, Args),
    ?assertEqual(<<"foo/2">>, maps:get(<<"text">>, Subject)),
    ?assertEqual(<<"bar/1">>, maps:get(<<"text">>, Object)),
    ?assertEqual(5, maps:get(<<"start">>, maps:get(<<"byte">>, maps:get(<<"span">>, Subject)))),
    ?assert(is_binary(jsx:encode([JsonFrame]))),
    ?assertNot(is_tuple(maps:get(<<"arguments">>, JsonFrame))).

malformed_or_unrecognized_analysis_has_no_candidates_test() ->
    ?assertEqual([], symbolic_ask_nlprule:extract_frames(#{<<"sentences">> => not_a_list})),
    ?assertEqual([], symbolic_ask_nlprule:extract_frames(#{<<"sentences">> => [#{<<"tokens">> => []}]})).

nlprule_live_frame_integration_test_() ->
    case os:getenv("SYMBOLIC_NLPRULE_DATA") of
        false -> [];
        _ -> [fun real_nlprule_analysis_generates_a_frame/0]
    end.

real_nlprule_analysis_generates_a_frame() ->
    {ok, Analysis} = symbolic_analyze:run_result("Does foo/2 call bar/1?"),
    [#{frame := {yes_no, {calls, Subject, Object}}}] =
        symbolic_ask_nlprule:extract_frames(Analysis),
    ?assertEqual([<<"foo">>, <<"/">>, <<"2">>], token_texts(Subject)),
    ?assertEqual([<<"bar">>, <<"/">>, <<"1">>], token_texts(Object)),
    [JsonFrame] = symbolic_ask_nlprule:extract_json_frames(Analysis),
    ?assertEqual(<<"yes_no">>, maps:get(<<"answer_type">>, JsonFrame)),
    ?assertEqual(<<"calls">>, maps:get(<<"relation">>, JsonFrame)),
    ?assert(is_binary(jsx:encode([JsonFrame]))).

token(Text, Lemma, Pos, Chunks, Start, End) ->
    #{<<"text">> => Text,
      <<"tags">> => [#{<<"lemma">> => Lemma, <<"pos">> => Pos}],
      <<"chunks">> => Chunks,
      <<"span">> => #{<<"byte">> => #{<<"start">> => Start, <<"end">> => End},
                       <<"char">> => #{<<"start">> => Start, <<"end">> => End}}}.

token_texts(Pairs) ->
    [maps:get(<<"text">>, Meta) || {_Word, Meta} <- Pairs].

