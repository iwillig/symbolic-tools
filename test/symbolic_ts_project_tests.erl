-module(symbolic_ts_project_tests).
-include_lib("eunit/include/eunit.hrl").

disabled_analysis_is_explicit_and_preserves_syntax_facts_test() ->
    Existing = [{ts_syntax_type, 'src/a.ts', parameter, <<"x">>, annotation,
                 <<"string">>, 0, 6, 1}],
    {ok, Result} = symbolic_ts_project:analyze(
        #{facts => Existing, files => []}, "_build/ts_project_disabled", undefined),
    ?assert(lists:member(hd(Existing), maps:get(facts, Result))),
    ?assertMatch({ts_analysis, _, _, disabled, disabled},
        only([F || {ts_analysis, _, _, _, _} = F <- maps:get(facts, Result)])),
    ?assertEqual(disabled, maps:get(status, maps:get(type_analysis, Result))).

enabled_analysis_without_explicit_projects_is_no_project_test() ->
    {ok, Result} = symbolic_ts_project:analyze(
        #{facts => [], files => []}, "_build/ts_project_empty",
        #{enabled => true, projects => []}),
    ?assertMatch({ts_analysis, _, _, no_project, no_project},
        only([F || {ts_analysis, _, _, _, _} = F <- maps:get(facts, Result)])).

missing_project_config_is_reported_without_failing_syntax_scan_test() ->
    Missing = filename:absname("_build/ts_project_missing/tsconfig.json"),
    {ok, Result} = symbolic_ts_project:analyze(
        #{facts => [], files => []}, "_build/ts_project_missing",
        #{enabled => true, projects => [Missing]}),
    Facts = maps:get(facts, Result),
    ?assertMatch({ts_analysis, _, _, failed, bad_config},
        only([F || {ts_analysis, _, _, _, _} = F <- Facts])),
    ?assertMatch({ts_project, _, _, _, unknown, unknown, failed, bad_config},
        only([F || {ts_project, _, _, _, _, _, _, _} = F <- Facts])).

unsupported_compiler_api_is_unavailable_not_an_empty_success_test() ->
    with_project_stub(fun(Root, ConfigPath) ->
        {ok, Result} = symbolic_ts_project:analyze(
            #{facts => [], files => []}, Root,
            #{enabled => true, projects => [ConfigPath]}),
        Facts = maps:get(facts, Result),
        ?assertMatch({ts_analysis, _, _, unavailable, unsupported_compiler_api},
            only([F || {ts_analysis, _, _, _, _} = F <- Facts])),
        ?assertMatch({ts_project, _, _, _, <<"7.0.2">>, unknown,
                      unavailable, unsupported_compiler_api},
            only([F || {ts_project, _, _, _, _, _, _, _} = F <- Facts]))
    end).

only([Value]) -> Value.

with_project_stub(Fun) ->
    Root = filename:absname(filename:join(["_build", "ts_project_stub"])),
    _ = file:del_dir_r(Root),
    ConfigPath = filename:join(Root, "tsconfig.json"),
    Package = filename:join([Root, "node_modules", "typescript"]),
    ok = filelib:ensure_dir(ConfigPath),
    ok = filelib:ensure_dir(filename:join(Package, "placeholder")),
    ok = file:write_file(ConfigPath, <<"{}\n">>),
    ok = file:write_file(filename:join(Package, "package.json"),
                         <<"{\"name\":\"typescript\",\"version\":\"7.0.2\",\"main\":\"index.js\"}\n">>),
    ok = file:write_file(filename:join(Package, "index.js"),
                         <<"module.exports = { version: '7.0.2' };\n">>),
    try Fun(Root, ConfigPath)
    after _ = file:del_dir_r(Root)
    end.
