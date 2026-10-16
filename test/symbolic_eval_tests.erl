-module(symbolic_eval_tests).
-include_lib("eunit/include/eunit.hrl").

validate_accepts_only_catalogued_ground_requests_test() ->
    Request = #{<<"decision">> => <<"supported">>,
        <<"operation">> => <<"calls">>,
        <<"slots">> => #{<<"caller">> => <<"foo/1">>,
                         <<"callee">> => <<"bar/1">>}},
    ?assertMatch({ok, calls, _}, symbolic_eval:validate_request(Request)),
    ?assertEqual({error, <<"unknown_operation">>},
        symbolic_eval:validate_request(Request#{<<"operation">> => <<"exec">>})),
    ?assertMatch({error, _}, symbolic_eval:validate_request(
        Request#{<<"slots">> => #{<<"caller">> => <<"foo),halt/1">>,
                                   <<"callee">> => <<"bar/1">>}})),
    ?assertMatch({error, _}, symbolic_eval:validate_request(
        Request#{<<"goal">> => <<"halt">>})).

fixed_goals_never_accept_model_goal_text_test() ->
    {ok, calls, Slots} = symbolic_eval:validate_request(
        #{<<"decision">> => <<"supported">>, <<"operation">> => <<"calls">>,
          <<"slots">> => #{<<"caller">> => <<"foo/1">>,
                           <<"callee">> => <<"bar/1">>}}),
    ?assertEqual("findall(row(File, Line), calls(foo, 1, local(bar, 1), File, Line), Rows)",
                 symbolic_eval:goal({calls, Slots})).

fixture_requests_execute_against_erlog_test_() ->
    {timeout, 120, fun fixture_requests_execute_against_erlog/0}.

fixture_requests_execute_against_erlog() ->
    lists:foreach(fun(Split) ->
        CasesPath = filename:join(["evals", "executable", "cases." ++ Split ++ ".jsonl"]),
        {ok, Contents} = file:read_file(CasesPath),
        Rows = [jsx:decode(Line, [return_maps]) || Line <- binary:split(Contents, <<"\n">>, [global]), Line =/= <<>>],
        lists:foreach(fun(#{<<"description">> := Id, <<"vars">> := Vars}) ->
            FixtureName = binary_to_list(maps:get(<<"fixture">>, Vars)),
            FixtureDir = filename:absname(filename:join(["evals", "executable", "fixtures", FixtureName])),
            Expected = maps:get(<<"expected">>, Vars),
            Request = expected_request(Expected),
            Actual = symbolic_eval:evaluate(FixtureDir, jsx:encode(Request), Expected),
            Scores = maps:get(<<"scores">>, Actual),
            ?assertEqual({Id, true}, {Id, maps:get(<<"end_to_end">>, Scores)})
        end, Rows)
    end, ["dev", "holdout"]).

expected_request(#{<<"decision">> := <<"supported">>} = Expected) ->
    #{<<"decision">> => <<"supported">>,
      <<"operation">> => maps:get(<<"operation">>, Expected),
      <<"slots">> => maps:get(<<"slots">>, Expected)};
expected_request(#{<<"decision">> := Decision} = Expected) ->
    #{<<"decision">> => Decision,
      <<"reason">> => maps:get(<<"reason">>, Expected, <<"mock_reason">>)}.
