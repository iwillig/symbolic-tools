-module(symbolic_ts_project_integration_tests).
-include_lib("eunit/include/eunit.hrl").

native_tsgo_analyzes_configured_project_without_node_worker_test_() ->
    {timeout, 120, fun native_tsgo_analyzes_configured_project_without_node_worker/0}.

native_tsgo_analyzes_configured_project_without_node_worker() ->
    case {os:getenv("SYMBOLIC_TEST_TYPESCRIPT_CONFIG"),
          os:getenv("SYMBOLIC_TEST_TYPESCRIPT_SOURCE")} of
        {false, _} -> ok;
        {_, false} -> ok;
        {ConfigPath, SourcePath} ->
            {ok, Compiler} = symbolic_tsgo:resolve(ConfigPath),
            ?assertEqual(<<"7.0.2">>, maps:get(version, Compiler)),
            Report = native_test_report(SourcePath),
            with_node_not_on_path(fun() ->
                {ok, Enriched} = symbolic_ts_project:analyze(
                    Report, filename:dirname(ConfigPath),
                    #{enabled => true, projects => [ConfigPath]}),
                TypeAnalysis = maps:get(type_analysis, Enriched),
                ?assert(lists:member(maps:get(status, TypeAnalysis), [ok, partial])),
                SharedTimings = maps:get(timings_ms, TypeAnalysis),
                ?assert(is_integer(maps:get(<<"location_fact_index">>, SharedTimings))),
                [ProjectSummary] = maps:get(projects, TypeAnalysis),
                Timings = maps:get(timings_ms, ProjectSummary),
                ?assert(lists:all(fun(Key) ->
                    is_integer(maps:get(Key, Timings, -1)) andalso maps:get(Key, Timings) >= 0
                end, [<<"initialize">>, <<"parse_config">>, <<"update_snapshot">>,
                      <<"source_files">>, <<"diagnostics">>, <<"syntactic_diagnostics">>,
                      <<"semantic_diagnostics">>, <<"locations">>, <<"location_selection">>,
                      <<"offset_conversion">>, <<"type_queries">>, <<"symbol_queries">>,
                      <<"type_graph">>, <<"result_conversion">>,
                      <<"worker_total">>, <<"normalize">>])),
                Facts = maps:get(facts, Enriched),
                ?assert(lists:any(fun
                    ({ts_project, _, _, _, <<"7.0.2">>, _, Status, _})
                            when Status =:= ok; Status =:= partial -> true;
                    (_) -> false
                end, Facts)),
                ?assert(lists:any(fun
                    ({ts_type_node, _, _, _, Display}) when is_binary(Display) ->
                        binary:match(Display, <<"Promise<DecisionSchemaDefinition>">>) =/= nomatch;
                    (_) -> false
                end, Facts))
            end)
    end.

with_node_not_on_path(Fun) ->
    PreviousPath = os:getenv("PATH"),
    EmptyPath = filename:absname(filename:join(["_build", "tsgo-no-node-"
        ++ integer_to_list(erlang:unique_integer([positive]))])),
    ok = filelib:ensure_dir(filename:join(EmptyPath, "placeholder")),
    true = os:putenv("PATH", EmptyPath),
    try Fun()
    after
        case PreviousPath of
            false -> os:unsetenv("PATH");
            Path -> os:putenv("PATH", Path)
        end,
        _ = file:del_dir(EmptyPath)
    end.

native_test_report(Path) ->
    case filelib:is_dir(Path) of
        true ->
            {ok, Report} = symbolic_parse:scan_paths_report([Path]),
            Report;
        false -> #{facts => ts_extract_typescript:file(Path), files => [Path]}
    end.

checker_enriches_shared_facts_and_keeps_diagnostics_source_located_test() ->
    case os:getenv("SYMBOLIC_TEST_TYPESCRIPT_PACKAGE") of
        false ->
            ?debugMsg("Set SYMBOLIC_TEST_TYPESCRIPT_PACKAGE to a TypeScript package path to run the real-checker integration test"),
            ok;
        TypeScriptPackage -> with_project(TypeScriptPackage, fun(Root, ConfigPath, SourcePath, Source) ->
            Report = #{facts => ts_extract_typescript:file(SourcePath), files => [SourcePath]},
            {ok, Enriched} = symbolic_ts_project:analyze(
                Report#{complete => true, capture_checker_candidate => true},
                Root, #{enabled => true, projects => [ConfigPath]}),
            %% The compiler package is an external symlink in this fixture;
            %% candidate capture must fail closed without losing checker facts.
            ?assertNot(maps:is_key(checker_candidate, Enriched)),
            Facts = maps:get(facts, Enriched),
            ?assertEqual(ok, maps:get(status, maps:get(type_analysis, Enriched))),
            ?assert(lists:any(fun
                ({ts_symbol, _Project, _Symbol, <<"identity">>, function}) -> true;
                (_) -> false
            end, Facts)),
            ?assert(lists:any(fun
                ({ts_declaration, _Project, _Decl, _Symbol, _File, _Start, _End}) -> true;
                (_) -> false
            end, Facts)),
            ?assert(lists:any(fun
                ({ts_type_node, _Project, _Type, union, _Display}) -> true;
                (_) -> false
            end, Facts)),
            ?assert(lists:any(fun
                ({ts_type_edge, _Project, _Parent, Role, _Child}) when is_binary(Role) ->
                    binary:match(Role, <<"constituent:">>) =/= nomatch;
                (_) -> false
            end, Facts)),
            ?assert(lists:any(fun
                ({ts_type_edge, _Project, _Parent, Role, _Child}) when is_binary(Role) ->
                    binary:match(Role, <<"type_argument:">>) =/= nomatch;
                (_) -> false
            end, Facts)),
            ?assert(lists:any(fun
                ({ts_type_at, _Project, _Location, _Type, Origin, _File, _S, _E})
                        when Origin =:= declared; Origin =:= inferred -> true;
                (_) -> false
            end, Facts)),
            UnionTypeIds = [Id || {ts_type_node, _, Id, union, _} <- Facts],
            ?assert(lists:any(fun
                ({ts_type_at, _Project, _Location, TypeId, _Origin, File, Start, End}) ->
                    File =:= list_to_atom(SourcePath) andalso
                    binary:match(binary:part(Source, Start, End - Start), <<"choice">>) =/= nomatch
                        andalso lists:member(TypeId, UnionTypeIds);
                (_) -> false
            end, Facts)),
            Diagnostics = [D || {ts_diagnostic, _, _, _, _, _, _, _} = D <- Facts],
            ?assert(lists:any(fun
                ({ts_diagnostic, _Project, 2322, error, File, Start, Length, _Message}) ->
                    File =:= list_to_atom(SourcePath) andalso
                    Start >= 0 andalso Length > 0 andalso
                    binary:part(Source, Start, Length) =:= <<"invalid">>;
                (_) -> false
            end, Diagnostics))
        end)
    end.

compiler_input_files_track_newly_resolved_unscanned_dependency_test() ->
    case os:getenv("SYMBOLIC_TEST_TYPESCRIPT_PACKAGE") of
        false -> ok;
        Package -> with_project(Package, fun(Root, ConfigPath, SourcePath, _Source) ->
            case symbolic_tsgo:resolve(ConfigPath) of
                {ok, Compiler} ->
                    Dependency = filename:join([Root, "src", "dependency.ts"]),
                    ok = file:write_file(SourcePath,
                        <<"import { value } from './dependency'; export const result = value;\n">>),
                    Report = #{facts => ts_extract_typescript:file(SourcePath),
                               files => [SourcePath]},
                    {ok, MissingProbe} = symbolic_tsgo:probe(ConfigPath, Compiler),
                    {ok, SameProbe} = symbolic_tsgo:probe(ConfigPath, Compiler),
                    ?assertEqual(maps:get(config, MissingProbe), maps:get(config, SameProbe)),
                    ?assertEqual(maps:get(files, MissingProbe), maps:get(files, SameProbe)),
                    {ok, Missing} = symbolic_tsgo:analyze(Report, ConfigPath, Compiler),
                    ?assertNot(lists:member(unicode:characters_to_binary(Dependency),
                                            maps:get(<<"inputFiles">>, Missing))),
                    ok = file:write_file(Dependency, <<"export const value = 1;\n">>),
                    {ok, ResolvedProbe} = symbolic_tsgo:probe(ConfigPath, Compiler),
                    ?assertNot(lists:member(unicode:characters_to_binary(Dependency),
                                            maps:get(files, MissingProbe))),
                    ?assert(lists:member(unicode:characters_to_binary(Dependency),
                                         maps:get(files, ResolvedProbe))),
                    {ok, Resolved} = symbolic_tsgo:analyze(Report, ConfigPath, Compiler),
                    ?assert(lists:member(unicode:characters_to_binary(Dependency),
                                         maps:get(<<"inputFiles">>, Resolved))),
                    ok = file:write_file(ConfigPath,
                        <<"{\"compilerOptions\":{\"strict\":false},\"include\":[\"src/**/*.ts\"]}">>),
                    {ok, ChangedConfig} = symbolic_tsgo:probe(ConfigPath, Compiler),
                    ?assertNotEqual(maps:get(config, ResolvedProbe),
                                    maps:get(config, ChangedConfig))
            end
        end)
    end.

with_project(TypeScriptPackage, Fun) ->
    Root = filename:absname(filename:join(["_build", "ts_project_real_compiler_"
        ++ integer_to_list(erlang:unique_integer([positive]))])),
    _ = file:del_dir_r(Root),
    ConfigPath = filename:join(Root, "tsconfig.json"),
    SourcePath = filename:join([Root, "src", "types.ts"]),
    PackageLink = filename:join([Root, "node_modules", "typescript"]),
    ok = filelib:ensure_dir(SourcePath),
    ok = filelib:ensure_dir(PackageLink),
    ok = file:make_symlink(TypeScriptPackage, PackageLink),
    ok = file:write_file(ConfigPath,
        <<"{\"compilerOptions\":{\"strict\":true,\"target\":\"ES2020\"},"
          "\"include\":[\"src/**/*.ts\"]}\n">>),
    Source = unicode:characters_to_binary(
        "// 🧭 byte offsets must survive TypeScript UTF-16 positions\n"
        "export function identity<T>(value: T): T { return value; }\n"
        "const choice: string | number = identity(\"ok\");\n"
        "const values: readonly string[] = [\"ok\"];\n"
        "const invalid: string = 42;\n"),
    ok = file:write_file(SourcePath, Source),
    try Fun(Root, ConfigPath, SourcePath, Source)
    after _ = file:del_dir_r(Root)
    end.
