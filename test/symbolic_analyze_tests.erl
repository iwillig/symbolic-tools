-module(symbolic_analyze_tests).
-include_lib("eunit/include/eunit.hrl").

run_result_decodes_nlprule_json_test() ->
    meck:new(symbolic_nlprule),
    meck:expect(symbolic_nlprule, analyze, fun(<<"Hello.">>) ->
        {ok, <<"{\"sentences\":[{\"text\":\"Hello.\",\"span\":{\"byte\":{\"start\":0,\"end\":6},\"char\":{\"start\":0,\"end\":6}},\"tokens\":[{\"text\":\"Hello\",\"span\":{\"byte\":{\"start\":0,\"end\":5},\"char\":{\"start\":0,\"end\":5}},\"tags\":[],\"chunks\":[]}]}]}">>}
    end),
    {ok, Result} = symbolic_analyze:run_result("Hello."),
    ?assertMatch(#{<<"sentences">> := [_]}, Result),
    meck:unload(symbolic_nlprule).

run_result_reports_missing_data_test() ->
    meck:new(symbolic_nlprule),
    meck:expect(symbolic_nlprule, analyze, fun(_) ->
        {error, {missing_data, <<"set SYMBOLIC_NLPRULE_DATA">>}}
    end),
    ?assertEqual({error, {missing_data, <<"set SYMBOLIC_NLPRULE_DATA">>}},
        symbolic_analyze:run_result("Hello.")),
    meck:unload(symbolic_nlprule).

run_result_rejects_invalid_unicode_test() ->
    ?assertMatch({error, {invalid_text, _}},
        symbolic_analyze:run_result(<<255>>)).
