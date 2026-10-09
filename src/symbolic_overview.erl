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
            {ok, #{total_facts => length(Facts), facts_by_predicate => counts(Facts)}}
    end.

counts(Facts) ->
    lists:foldl(fun(Fact, Acc) ->
        Name = element(1, Fact),
        maps:update_with(Name, fun(N) -> N + 1 end, 1, Acc)
    end, #{}, Facts).
