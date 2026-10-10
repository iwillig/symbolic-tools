%%% Public English sentence/token analysis API used by CLI and MCP.
-module(symbolic_analyze).
-export([run/1, run_result/1]).

-spec run(unicode:chardata()) -> no_return().
run(Text) ->
    case run_result(Text) of
        {ok, Result} ->
            io:format("~ts~n", [jsx:encode(Result)]),
            halt(0);
        {error, Reason} ->
            io:format(standard_error, "cannot analyze English text: ~p~n", [Reason]),
            halt(1)
    end.

-spec run_result(unicode:chardata() | binary()) -> {ok, map()} | {error, term()}.
run_result(Text) ->
    case unicode:characters_to_binary(Text) of
        Binary when is_binary(Binary) ->
            case code:ensure_loaded(symbolic_nlprule) of
                {module, symbolic_nlprule} ->
                    try decode(symbolic_nlprule:analyze(Binary))
                    catch error:nif_not_loaded -> {error, nlprule_nif_not_loaded}
                    end;
                {error, Reason} -> {error, {nlprule_nif_not_loaded, Reason}}
            end;
        {error, _, _} = Error -> {error, {invalid_text, Error}};
        {incomplete, _, _} = Error -> {error, {invalid_text, Error}}
    end.

decode({ok, Json}) when is_binary(Json) ->
    try {ok, jsx:decode(Json, [return_maps])}
    catch _:_ -> {error, invalid_nlprule_json}
    end;
decode({error, {missing_data, Reason}}) -> {error, {missing_data, Reason}};
decode({error, Reason}) -> {error, Reason};
decode({'EXIT', {nif_not_loaded, _}}) -> {error, nlprule_nif_not_loaded};
decode(Other) -> {error, {unexpected_nlprule_result, Other}}.
