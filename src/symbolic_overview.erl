%%% `symbolic overview -db facts.dets` — report persisted CLI fact data.
-module(symbolic_overview).
-export([run/1, run_result/1]).

run(DbPath) ->
    case run_result(DbPath) of
        {ok, Summary} ->
            io:format("~ts~n", [jsx:encode(Summary)]),
            halt(0);
        {error, Reason} ->
            io:format(standard_error, "cannot overview facts: ~p~n", [Reason]),
            halt(1)
    end.

run_result(DbPath) ->
    case filelib:is_regular(DbPath) of
        false -> {error, {no_such_db, DbPath}};
        true ->
            Facts = symbolic_fact_store:read(DbPath),
            Summary = #{total_facts => length(Facts), facts_by_predicate => counts(Facts)},
            {ok, Summary#{typescript_analysis => type_analysis(DbPath, Facts)}}
    end.

type_analysis(DbPath, Facts) ->
    case symbolic_fact_store:read_metadata(DbPath) of
        {ok, Metadata} ->
            case maps:get(<<"typescript_analysis">>, Metadata, undefined) of
                undefined -> analysis_from_facts(Facts);
                Summary -> Summary
            end;
        _ -> analysis_from_facts(Facts)
    end.

analysis_from_facts(Facts) ->
    case [Status || {ts_analysis, _Id, _Scope, Status, _Reason} <- Facts] of
        [Status | _] -> #{<<"status">> => atom_to_binary(Status, utf8)};
        [] -> #{<<"status">> => <<"unknown">>,
                <<"reason">> => <<"legacy_or_missing_status">>}
    end.

counts(Facts) ->
    lists:foldl(fun(Fact, Acc) ->
        Name = element(1, Fact),
        maps:update_with(Name, fun(N) -> N + 1 end, 1, Acc)
    end, #{}, Facts).
