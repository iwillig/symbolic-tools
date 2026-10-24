-module(symbolic_ts_project_tests).
-include_lib("eunit/include/eunit.hrl").

summary_json_preserves_project_timing_fields_test() ->
    Timings = #{<<"locations">> => 30000, <<"worker_total">> => 30005},
    SharedTimings = #{<<"location_fact_index">> => 7},
    Summary = symbolic_ts_project:summary_json(
        #{status => partial, reason => timeout, timings_ms => SharedTimings,
          projects => [#{config => "_build/ts_project_timing/tsconfig.json",
                         status => unavailable, reason => timeout,
                         failed_stage => <<"locations">>, timings_ms => Timings}]}),
    [Project] = maps:get(projects, Summary),
    ?assertEqual(SharedTimings, maps:get(timings_ms, Summary)),
    ?assertEqual(Timings, maps:get(timings_ms, Project)),
    ?assertEqual(<<"locations">>, maps:get(failed_stage, Project)),
    Json = jsx:decode(jsx:encode(Summary), [return_maps]),
    [JsonProject] = maps:get(<<"projects">>, Json),
    ?assertEqual(SharedTimings, maps:get(<<"timings_ms">>, Json)),
    ?assertEqual(Timings, maps:get(<<"timings_ms">>, JsonProject)).

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

candidate_capture_is_opt_in_and_rejects_mid_analysis_change_test() ->
    Root = filename:absname(filename:join("_build", "ts_candidate_capture")),
    _ = file:del_dir_r(Root),
    Config = filename:join(Root, "tsconfig.json"),
    Source = filename:join(Root, "src/index.ts"),
    Exe = filename:join(Root, "node_modules/typescript/bin/tsgo"),
    ok = filelib:ensure_dir(Source),
    ok = filelib:ensure_dir(Exe),
    ok = file:write_file(Config, <<"{}">>),
    ok = file:write_file(Source, <<"export const value = 1;">>),
    ok = file:write_file(Exe, <<"compiler">>),
    Probe = #{files => [unicode:characters_to_binary(Source)], config => #{},
              version => <<"7.0.2">>, executable => Exe},
    Json0 = #{<<"schemaVersion">> => 1, <<"status">> => <<"ok">>,
              <<"reason">> => <<"none">>, <<"compilerVersion">> => <<"7.0.2">>,
              <<"filesProcessed">> => 1},
    Json = lists:foldl(fun(Key, Acc) -> Acc#{Key => []} end, Json0,
        [<<"symbols">>, <<"declarations">>, <<"declaredTypes">>,
         <<"typeNodes">>, <<"typeEdges">>, <<"typeAt">>,
         <<"locationSymbols">>, <<"diagnostics">>]),
    Settings = #{enabled => true, projects => [Config]},
    Report = #{facts => [], files => [Source], complete => true},
    meck:new(symbolic_tsgo, [passthrough]),
    meck:expect(symbolic_tsgo, resolve, fun(_) -> {ok, #{}} end),
    meck:expect(symbolic_tsgo, probe, fun(_, _) -> {ok, Probe} end),
    meck:expect(symbolic_tsgo, analyze, fun(_, _, _) -> {ok, Json} end),
    try
        {ok, Default} = symbolic_ts_project:analyze(
            Report#{checker_candidate => #{validated => true}}, Root, Settings),
        ?assertNot(maps:is_key(checker_candidate, Default)),
        {ok, Captured} = symbolic_ts_project:analyze(
            Report#{capture_checker_candidate => true}, Root, Settings),
        ?assertMatch(#{validated := true}, maps:get(checker_candidate, Captured)),
        ?assertMatch(#{<<"checker_candidate">> := #{<<"reusable">> := false}},
                     symbolic_ts_inputs:metadata(Captured)),
        meck:expect(symbolic_tsgo, analyze, fun(_, _, _) ->
            ok = file:write_file(Source, <<"export const value = 2;">>),
            {ok, Json}
        end),
        {ok, Changed} = symbolic_ts_project:analyze(
            Report#{capture_checker_candidate => true}, Root, Settings),
        ?assertEqual(ok, maps:get(status, maps:get(type_analysis, Changed))),
        ?assertNot(maps:is_key(checker_candidate, Changed)),
        meck:expect(symbolic_tsgo, analyze, fun(_, _, _) -> {ok, Json} end),
        meck:expect(symbolic_tsgo, probe, fun(_, _) -> error(probe_crash) end),
        {ok, ProbeFailed} = symbolic_ts_project:analyze(
            Report#{capture_checker_candidate => true}, Root, Settings),
        ?assertEqual(ok, maps:get(status, maps:get(type_analysis, ProbeFailed))),
        ?assertNot(maps:is_key(checker_candidate, ProbeFailed))
    after
        meck:unload(symbolic_tsgo),
        _ = file:del_dir_r(Root)
    end.

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
