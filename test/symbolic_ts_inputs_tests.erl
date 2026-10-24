-module(symbolic_ts_inputs_tests).
-include_lib("eunit/include/eunit.hrl").

fingerprint_tracks_dependencies_and_resolution_inventory_test() ->
    with_fixture(fun(Root, Config, Source, Probe) ->
        {ok, Base} = symbolic_ts_inputs:fingerprint(Root, Config, Probe),
        ?assertEqual({ok, Base}, symbolic_ts_inputs:fingerprint(Root, Config, Probe)),
        Dependency = filename:join(Root, "node_modules/pkg/index.d.ts"),
        ok = filelib:ensure_dir(Dependency),
        ok = file:write_file(Dependency, <<"export declare const x: string;">>),
        {ok, Added} = symbolic_ts_inputs:fingerprint(Root, Config, Probe),
        ?assertNotEqual(Base, Added),
        ok = file:write_file(Dependency, <<"export declare const x: number;">>),
        {ok, Changed} = symbolic_ts_inputs:fingerprint(Root, Config, Probe),
        ?assertNotEqual(Added, Changed),
        ok = file:delete(Dependency),
        ok = file:del_dir(filename:dirname(Dependency)),
        ?assertEqual({ok, Base}, symbolic_ts_inputs:fingerprint(Root, Config, Probe)),
        ok = file:write_file(Source, <<"export const value = 2;">>),
        ?assertNotEqual({ok, Base}, symbolic_ts_inputs:fingerprint(Root, Config, Probe)),
        {ok, BeforeConfig} = symbolic_ts_inputs:fingerprint(Root, Config, Probe),
        ok = file:write_file(Config, <<"{\"compilerOptions\":{\"strict\":false}}">>),
        ?assertNotEqual({ok, BeforeConfig},
                        symbolic_ts_inputs:fingerprint(Root, Config, Probe)),
        ?assertNotEqual(symbolic_ts_inputs:fingerprint(Root, Config, Probe),
            symbolic_ts_inputs:fingerprint(Root, Config,
                Probe#{config => #{<<"strict">> => false}})),
        {ok, BeforeCompiler} = symbolic_ts_inputs:fingerprint(Root, Config, Probe),
        ok = file:write_file(maps:get(executable, Probe), <<"compiler v2">>),
        ?assertNotEqual({ok, BeforeCompiler},
                        symbolic_ts_inputs:fingerprint(Root, Config, Probe))
    end).

shared_workspace_digest_for_multiple_projects_test() ->
    with_fixture(fun(Root, Config, Source, Probe) ->
        {ok, Workspace} = symbolic_ts_inputs:workspace(Root),
        {ok, First} = symbolic_ts_inputs:project_fingerprint(Workspace, Config, Probe),
        ?assertEqual({ok, First}, symbolic_ts_inputs:fingerprint(Root, Config, Probe)),
        OtherConfig = filename:join(Root, "other/tsconfig.json"),
        ok = filelib:ensure_dir(OtherConfig),
        ok = file:write_file(OtherConfig, <<"{}">>),
        {ok, Second} = symbolic_ts_inputs:project_fingerprint(
            Workspace, OtherConfig, Probe#{config => #{<<"strict">> => false}}),
        ?assertNotEqual(First, Second),
        %% A workspace captured before a change must not be reused for a
        %% later parse: re-inventory it before checking project fingerprints.
        ok = file:write_file(Source, <<"export const value = 2;">>),
        {ok, UpdatedWorkspace} = symbolic_ts_inputs:workspace(Root),
        ?assertNotEqual(maps:get(digest, Workspace), maps:get(digest, UpdatedWorkspace)),
        ?assertNotEqual({ok, First}, symbolic_ts_inputs:project_fingerprint(
            UpdatedWorkspace, Config, Probe))
    end).

workspace_tracks_internal_symlink_targets_test() ->
    with_fixture(fun(Root, _Config, _Source, _Probe) ->
        Target = filename:join(Root, "types/index.d.ts"),
        Link = filename:join(Root, "node_modules/pkg"),
        ok = filelib:ensure_dir(Target),
        ok = filelib:ensure_dir(Link),
        ok = file:write_file(Target, <<"export type A = string;">>),
        ok = file:make_symlink("../types", Link),
        {ok, Before} = symbolic_ts_inputs:workspace(Root),
        ok = file:write_file(Target, <<"export type A = number;">>),
        {ok, After} = symbolic_ts_inputs:workspace(Root),
        ?assertNotEqual(maps:get(digest, Before), maps:get(digest, After))
    end).

fingerprint_fails_closed_for_external_inputs_test() ->
    with_fixture(fun(Root, Config, _Source, Probe) ->
        ?assertEqual(unavailable, symbolic_ts_inputs:fingerprint(Root, Config,
            Probe#{files => [<<"/tmp/outside-project.ts">>]})),
        ?assertEqual(unavailable, symbolic_ts_inputs:fingerprint(Root, Config,
            Probe#{files => [<<"relative.ts">>]})),
        ?assertEqual(unavailable, symbolic_ts_inputs:fingerprint(Root, Config,
            Probe#{files => [filename:join(Root, "missing.ts")]})),
        Unsupported = filename:join(Root, "src/plugin.input"),
        ok = file:write_file(Unsupported, <<"plugin data">>),
        ?assertEqual(unavailable, symbolic_ts_inputs:fingerprint(Root, Config,
            Probe#{files => [Unsupported]})),
        Link = filename:join(Root, "outside"),
        ok = file:make_symlink("/tmp", Link),
        ?assertEqual(unavailable, symbolic_ts_inputs:fingerprint(Root, Config, Probe))
    end).

candidate_observes_all_configured_projects_or_fails_closed_test() ->
    with_fixture(fun(Root, Config, Source, Probe) ->
        Report = #{complete => true, type_analysis =>
                   #{projects => [#{status => partial, config => Config}]}},
        meck:new(symbolic_tsgo, [passthrough]),
        meck:expect(symbolic_tsgo, resolve, fun(_) -> {ok, #{}} end),
        meck:expect(symbolic_tsgo, probe, fun(_, _) -> {ok, Probe} end),
        try
            {ok, First} = symbolic_ts_inputs:begin_observation(Root, [Config]),
            ?assertEqual(1, map_size(maps:get(projects, First))),
            {ok, Validated} = symbolic_ts_inputs:finish_observation(
                First, Report, Root, [Config]),
            ?assertEqual(true, maps:get(validated, Validated)),
            ?assertEqual(unavailable, symbolic_ts_inputs:finish_observation(
                First, Report#{complete => false}, Root, [Config])),
            ok = file:write_file(Source, <<"export const value = 3;">>),
            ?assertEqual(unavailable, symbolic_ts_inputs:finish_observation(
                First, Report, Root, [Config])),
            {ok, Changed} = symbolic_ts_inputs:candidate(Report, Root, [Config]),
            ?assertNotEqual(maps:get(projects, First), maps:get(projects, Changed)),
            meck:expect(symbolic_tsgo, probe, fun(_, _) -> {error, timeout} end),
            ?assertEqual(unavailable, symbolic_ts_inputs:finish_observation(
                Changed, Report, Root, [Config]))
        after meck:unload(symbolic_tsgo)
        end
    end).

candidate_metadata_is_non_reusable_and_atomic_test() ->
    with_fixture(fun(Root, Config, _Source, Probe) ->
        {ok, Fingerprint} = symbolic_ts_inputs:fingerprint(Root, Config, Probe),
        Candidate = #{version => 1, validated => true, workspace => <<0:256>>,
                      projects => #{unicode:characters_to_binary(Config) => Fingerprint}},
        Complete = #{complete => true, checker_candidate => Candidate},
        ?assertEqual(#{}, symbolic_ts_inputs:metadata(
            Complete#{checker_candidate => maps:remove(validated, Candidate)})),
        Extra = symbolic_ts_inputs:metadata(Complete),
        ?assertMatch(#{<<"checker_candidate">> :=
                       #{<<"reusable">> := false, <<"version">> := 1}}, Extra),
        ?assertEqual(#{}, symbolic_ts_inputs:metadata(Complete#{complete => false})),
        ?assertEqual(#{}, symbolic_ts_inputs:metadata(#{complete => true})),
        Db = filename:join(Root, ".symbolic/facts.dets"),
        OldFacts = [{defines, before, 0}],
        NewFacts = [{defines, latest, 0}],
        ok = symbolic_fact_store:write_bundle(Db, OldFacts, #{}),
        ok = symbolic_fact_store:write_bundle(Db, NewFacts, Extra),
        ?assertEqual({ok, Extra}, symbolic_fact_store:read_metadata(Db)),
        ?assertEqual(NewFacts, symbolic_fact_store:read(Db)),
        ?assertMatch({error, _}, symbolic_fact_store:write_bundle(
            Db, [not_a_fact_tuple], #{<<"checker_candidate">> => <<"stale">>})),
        ?assertEqual({ok, Extra}, symbolic_fact_store:read_metadata(Db)),
        ?assertEqual(NewFacts, symbolic_fact_store:read(Db))
    end).

candidate_rejects_incomplete_or_failed_scan_test() ->
    with_fixture(fun(Root, Config, _Source, _Probe) ->
        Projects = [Config],
        Report = #{complete => false, type_analysis =>
                   #{projects => [#{status => ok, config => Config}]}},
        ?assertEqual(unavailable, symbolic_ts_inputs:candidate(Report, Root, Projects)),
        ?assertEqual(unavailable, symbolic_ts_inputs:candidate(
            Report#{complete => true, type_analysis =>
                      #{projects => [#{status => unavailable, config => Config}]}},
            Root, Projects)),
        ?assertEqual(unavailable, symbolic_ts_inputs:candidate(
            Report#{complete => true, type_analysis =>
                      #{projects => [#{status => ok, config => Config ++ ".other"}]}},
            Root, Projects))
    end).

with_fixture(Fun) ->
    Root = filename:absname(filename:join("_build", "ts-inputs-" ++
        integer_to_list(erlang:unique_integer([positive])))),
    Config = filename:join(Root, "tsconfig.json"),
    Source = filename:join(Root, "src/index.ts"),
    ok = filelib:ensure_dir(Source),
    ok = file:write_file(Config, <<"{}">>),
    ok = file:write_file(Source, <<"export const value = 1;">>),
    Executable = filename:join(Root, "node_modules/typescript/bin/tsgo"),
    ok = filelib:ensure_dir(Executable),
    ok = file:write_file(Executable, <<"compiler v1">>),
    Probe = #{files => [unicode:characters_to_binary(Source)],
              config => #{<<"strict">> => true}, version => <<"7.0.2">>,
              executable => Executable},
    try Fun(Root, Config, Source, Probe)
    after _ = file:del_dir_r(Root)
    end.
