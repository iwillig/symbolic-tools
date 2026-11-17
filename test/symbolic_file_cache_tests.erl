-module(symbolic_file_cache_tests).
-include_lib("eunit/include/eunit.hrl").

extractors_invalidate_both_cache_types_test_() ->
    {timeout, 60, fun() ->
        %% Keep this list aligned with the language dispatch in ts_extract:file/1.
        Modules = [ts_extract_erlang, ts_extract_rust, ts_extract_clojure,
                   ts_extract_ruby, ts_extract_python, ts_extract_typescript,
                   ts_extract_markdown, ts_extract_toml, ts_extract_json,
                   ts_extract_bash],
        Path = filename:join("/tmp", "symbolic_cache_version_" ++
            integer_to_list(erlang:unique_integer([positive])) ++ ".dets"),
        Files = #{"sample" => #{facts => []}},
        try
            lists:foreach(fun(Module) ->
                OriginalVersion = symbolic_file_cache:version(),
                Memory = #{version => OriginalVersion, files => Files},
                ok = symbolic_fact_store:write_bundle(Path, [], #{}, Files),
                ?assertEqual(Files, symbolic_file_cache:load(Path)),
                {Module, Binary, Filename} = code:get_object_code(Module),
                Forms = [{attribute, 1, module, Module},
                         {attribute, 2, export, [{test_marker, 0}]},
                         {function, 3, test_marker, 0,
                          [{clause, 3, [], [], [{atom, 3, changed}]}]}],
                {ok, Module, Replacement} = compile:forms(Forms),
                {module, Module} = code:load_binary(Module, "cache-test", Replacement),
                try
                    ?assertNotEqual(OriginalVersion, symbolic_file_cache:version()),
                    ?assertEqual(#{}, symbolic_file_cache:load_memory(Memory)),
                    ?assertEqual(#{}, symbolic_file_cache:load(Path))
                after
                    code:purge(Module),
                    {module, Module} = code:load_binary(Module, Filename, Binary),
                    code:purge(Module)
                end
            end, Modules)
        after
            [file:delete(File) || File <- filelib:wildcard(Path ++ "*")]
        end
    end}.
