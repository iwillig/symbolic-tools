-module(symbolic_ts_project_integration_tests).
-include_lib("eunit/include/eunit.hrl").

checker_enriches_shared_facts_and_keeps_diagnostics_source_located_test() ->
    case os:getenv("SYMBOLIC_TEST_TYPESCRIPT_PACKAGE") of
        false ->
            ?debugMsg("Set SYMBOLIC_TEST_TYPESCRIPT_PACKAGE to a TypeScript package path to run the real-checker integration test"),
            ok;
        TypeScriptPackage -> with_project(TypeScriptPackage, fun(Root, ConfigPath, SourcePath, Source) ->
            Report = #{facts => [], files => [SourcePath]},
            {ok, Enriched} = symbolic_ts_project:analyze(
                Report, Root, #{enabled => true, projects => [ConfigPath]}),
            Facts = maps:get(facts, Enriched),
            ?assertEqual(ok, maps:get(status, maps:get(type_analysis, Enriched))),
            ?assert(lists:any(fun
                ({ts_symbol, _Project, _Symbol, <<"identity">>, function}) -> true;
                (_) -> false
            end, Facts)),
            ?assert(lists:any(fun
                ({ts_declared_type, _Project, _Decl, _Type}) -> true;
                (_) -> false
            end, Facts)),
            ?assert(lists:any(fun
                ({ts_type_node, _Project, _Type, union, _Display}) -> true;
                (_) -> false
            end, Facts)),
            ?assert(lists:any(fun
                ({ts_type_at, _Project, _Location, _Type, call_result, _File, _S, _E}) -> true;
                (_) -> false
            end, Facts)),
            Diagnostics = [D || {ts_diagnostic, _, _, _, _, _, _, _} = D <- Facts],
            ?assert(lists:any(fun
                ({ts_diagnostic, _Project, 2322, error, File, Start, Length, _Message}) ->
                    File =:= list_to_atom(SourcePath) andalso
                    Start >= 0 andalso Length > 0 andalso
                    binary:part(Source, Start, Length) =/= <<>>;
                (_) -> false
            end, Diagnostics))
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
        "const invalid: string = 42;\n"),
    ok = file:write_file(SourcePath, Source),
    try Fun(Root, ConfigPath, SourcePath, Source)
    after _ = file:del_dir_r(Root)
    end.
