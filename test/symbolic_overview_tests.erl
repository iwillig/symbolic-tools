-module(symbolic_overview_tests).
-include_lib("eunit/include/eunit.hrl").

legacy_database_reports_unknown_type_analysis_test() ->
    with_database(fun(Path) ->
        ok = symbolic_fact_store:write(Path, [{defines, f, 0, <<"()">>, 'src/f.erl', 1}]),
        {ok, Summary} = symbolic_overview:run_result(Path),
        ?assertEqual(#{<<"status">> => <<"unknown">>,
                       <<"reason">> => <<"legacy_or_missing_status">>},
                     maps:get(typescript_analysis, Summary))
    end).

metadata_reports_configured_type_analysis_test() ->
    with_database(fun(Path) ->
        Status = #{<<"status">> => <<"unavailable">>,
                   <<"reason">> => <<"compiler_missing">>,
                   <<"projects">> => []},
        ok = symbolic_fact_store:write(Path, [
            {ts_analysis, <<"run-1">>, <<"/project">>, unavailable, compiler_missing}]),
        ok = symbolic_fact_store:write_metadata(Path,
            #{<<"typescript_analysis">> => Status}),
        {ok, Summary} = symbolic_overview:run_result(Path),
        ?assertEqual(Status, maps:get(typescript_analysis, Summary))
    end).

with_database(Fun) ->
    Path = filename:join(["_build", "symbolic_overview_" ++
        integer_to_list(erlang:unique_integer([positive])) ++ ".dets"]),
    ok = filelib:ensure_dir(Path),
    try Fun(Path)
    after
        _ = file:delete(Path),
        _ = file:delete(Path ++ ".scan.json")
    end.
