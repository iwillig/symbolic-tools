-module(symbolic_analyze_nlprule_tests).
-include_lib("eunit/include/eunit.hrl").

%% End-to-end coverage uses the separately installed LGPL tokenizer data.
%% Run with SYMBOLIC_NLPRULE_DATA set; ordinary builds stay asset-free.
nlprule_tokenizer_integration_test_() ->
    case os:getenv("SYMBOLIC_NLPRULE_DATA") of
        false -> [];
        _ -> [fun analyzes_sentences_tokens_and_unicode_spans/0]
    end.

analyzes_sentences_tokens_and_unicode_spans() ->
    {ok, #{<<"language">> := <<"en">>, <<"sentences">> := [First, Second]}} =
        symbolic_analyze:run_result("Café works. It helps."),
    ?assertEqual(<<"Caf", 195, 169>>, maps:get(<<"text">>, hd(maps:get(<<"tokens">>, First)))),
    TokenSpan = maps:get(<<"span">>, hd(maps:get(<<"tokens">>, First))),
    ?assertEqual(5, maps:get(<<"end">>, maps:get(<<"byte">>, TokenSpan))),
    ?assertEqual(4, maps:get(<<"end">>, maps:get(<<"char">>, TokenSpan))),
    ?assertMatch([#{<<"pos">> := _} | _],
        maps:get(<<"tags">>, hd(maps:get(<<"tokens">>, First)))),
    ?assertMatch([_ | _], maps:get(<<"chunks">>, hd(maps:get(<<"tokens">>, First)))),
    ?assertEqual(<<"It helps.">>, maps:get(<<"text">>, Second)).
