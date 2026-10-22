-module(symbolic_parse_tests).
-include_lib("eunit/include/eunit.hrl").

%% Issue #4's "broader" fix: a crash anywhere inside ts_extract:file/1 —
%% generic over WHY it crashed, not tied to the specific bare-exponent
%% bug that triggered it (see ts_extract_typescript_tests.erl's own
%% extracts_bare_exponent_literal_facts_test for that narrow fix) —
%% degrades to "this file contributed zero facts" instead of failing the
%% whole scan. meck-mocked (not a real crashing file) because the point
%% here is the CATCHING mechanism itself, not any one bug.
extract_file_timed_survives_a_crashing_file_test() ->
    Root = filename:join(["_build", "parse_crash_survives_scratch"]),
    _ = file:del_dir_r(Root),
    Good = filename:join([Root, "good.erl"]),
    Bad = filename:join([Root, "bad.erl"]),
    ok = filelib:ensure_dir(Good),
    ok = file:write_file(Good, <<"-module(good).\nf() -> ok.\n">>),
    ok = file:write_file(Bad, <<"-module(bad).\ng() -> ok.\n">>),
    meck:new(ts_extract, [passthrough]),
    meck:expect(ts_extract, file, fun(F) ->
        case F of
            Bad -> error(boom);
            _ -> meck:passthrough([F])
        end
    end),
    try
        {ok, {Files, Facts}} = symbolic_parse:scan(Root),
        ?assertEqual(2, length(Files)),
        %% The crashing file contributed nothing; the good one's facts
        %% are still there — the scan as a whole still succeeded.
        ?assert(lists:any(
            fun(Fact) -> element(1, Fact) =:= defines andalso element(2, Fact) =:= f end, Facts)),
        ?assertNot(lists:any(
            fun(Fact) -> element(1, Fact) =:= defines andalso element(2, Fact) =:= g end, Facts)),
        {ok, Report} = symbolic_parse:scan_report(Root),
        ?assertEqual([Bad], maps:get(failed_files, Report)),
        ?assertEqual(2, length(maps:get(files, Report))),
        ?assertEqual(false, maps:get(complete, Report))
    after
        meck:unload(ts_extract),
        _ = file:del_dir_r(Root)
    end.

unreadable_subdirectory_never_reports_complete_test() ->
    Root = filename:absname(filename:join("_build", "parse_unreadable_dir_scratch")),
    Unreadable = filename:join(Root, "hidden"),
    Good = filename:join(Root, "good.erl"),
    Hidden = filename:join(Unreadable, "hidden.erl"),
    _ = file:del_dir_r(Root),
    ok = filelib:ensure_dir(Hidden),
    ok = file:write_file(Good, <<"-module(good).\nf() -> ok.\n">>),
    ok = file:write_file(Hidden, <<"-module(hidden).\nf() -> ok.\n">>),
    meck:new(file, [passthrough, unstick]),
    meck:expect(file, list_dir, fun(Path) ->
        case Path of
            Unreadable -> {error, eacces};
            _ -> meck:passthrough([Path])
        end
    end),
    try
        ?assertEqual({error, {cannot_list_directory, Unreadable, eacces}},
                     symbolic_parse:scan_report(Root)),
        ?assertEqual({error, {cannot_list_directory, Unreadable, eacces}},
                     symbolic_parse:scan_paths_report([Root]))
    after
        meck:unload(file),
        _ = file:del_dir_r(Root)
    end.

uninspectable_subdirectory_aborts_scan_test() ->
    Root = filename:absname(filename:join("_build", "parse_uninspectable_dir_scratch")),
    Dir = filename:join(Root, "hidden"),
    File = filename:join(Dir, "hidden.erl"),
    _ = file:del_dir_r(Root),
    ok = filelib:ensure_dir(File),
    ok = file:write_file(File, <<"-module(hidden).\nf() -> ok.\n">>),
    meck:new(file, [passthrough, unstick]),
    meck:expect(file, read_link_info, fun(Path) ->
        case Path of
            Dir -> {error, eacces};
            _ -> meck:passthrough([Path])
        end
    end),
    try
        ?assertEqual({error, {cannot_inspect_directory, Dir, eacces}},
                     symbolic_parse:scan_report(Root)),
        ?assertEqual({error, {cannot_inspect_directory, Dir, eacces}},
                     symbolic_parse:scan_paths_report([Root]))
    after
        meck:unload(file),
        _ = file:del_dir_r(Root)
    end.

unreadable_file_logs_path_and_reason_test() ->
    Root = filename:absname(filename:join("_build", "parse_read_failure_scratch")),
    File = filename:join(Root, "bad.erl"),
    _ = file:del_dir_r(Root),
    ok = filelib:ensure_dir(File),
    ok = file:write_file(File, <<"-module(bad).\nf() -> ok.\n">>),
    Handler = symbolic_parse_read_failure_test,
    ok = logger:add_handler(Handler, symbolic_parse_log_handler,
                            #{receiver => self(), level => error}),
    meck:new(file, [passthrough, unstick]),
    meck:expect(file, read_file, fun(Path) ->
        case Path of
            File -> {error, eacces};
            _ -> meck:passthrough([Path])
        end
    end),
    try
        {ok, Report} = symbolic_parse:scan_paths_report([File]),
        ?assertEqual(false, maps:get(complete, Report)),
        ?assertEqual([File], maps:get(failed_files, Report)),
        receive
            {parse_log, #{msg := {Format, Args}}} ->
                Message = lists:flatten(io_lib:format(Format, Args)),
                ?assert(string:find(Message, File) =/= nomatch),
                ?assert(string:find(Message, "eacces") =/= nomatch)
        after 1000 -> ?assert(false)
        end
    after
        meck:unload(file),
        logger:remove_handler(Handler),
        _ = file:del_dir_r(Root)
    end.

reread_failure_logs_path_and_reason_test() ->
    Root = filename:absname(filename:join("_build", "parse_reread_failure_scratch")),
    File = filename:join(Root, "bad.erl"),
    _ = file:del_dir_r(Root),
    ok = filelib:ensure_dir(File),
    ok = file:write_file(File, <<"-module(bad).\nf() -> ok.\n">>),
    Handler = symbolic_parse_reread_failure_test,
    ok = logger:add_handler(Handler, symbolic_parse_log_handler,
                            #{receiver => self(), level => error}),
    meck:new(file, [passthrough, unstick]),
    meck:new(ts_extract, [passthrough]),
    meck:expect(ts_extract, file, fun(_) -> [] end),
    meck:expect(file, read_file, fun(Path) ->
        case Path of
            File ->
                case get(parse_read_count) of
                    undefined -> put(parse_read_count, 1), meck:passthrough([Path]);
                    _ -> {error, eio}
                end;
            _ -> meck:passthrough([Path])
        end
    end),
    try
        {ok, Report} = symbolic_parse:scan_paths_report([File]),
        ?assertEqual(false, maps:get(complete, Report)),
        ?assertEqual([File], maps:get(failed_files, Report)),
        receive
            {parse_log, #{msg := {Format, Args}}} ->
                Message = lists:flatten(io_lib:format(Format, Args)),
                ?assert(string:find(Message, File) =/= nomatch),
                ?assert(string:find(Message, "eio") =/= nomatch)
        after 1000 -> ?assert(false)
        end
    after
        meck:unload(ts_extract),
        meck:unload(file),
        logger:remove_handler(Handler),
        _ = file:del_dir_r(Root)
    end.

incremental_scan_reuses_unchanged_and_replaces_changed_files_test() ->
    Root = filename:absname(filename:join("_build", "incremental_parse_scratch")),
    Db = filename:join(Root, "facts.dets"),
    Source = filename:join(Root, "src"),
    A = filename:join(Source, "a.erl"),
    B = filename:join(Source, "b.erl"),
    _ = file:del_dir_r(Root),
    ok = filelib:ensure_dir(A),
    ok = file:write_file(A, <<"-module(a).\nold() -> ok.\n">>),
    ok = file:write_file(B, <<"-module(b).\nkeep() -> ok.\n">>),
    meck:new(ts_extract, [passthrough]),
    try
        {ok, First} = symbolic_parse:scan_paths_report([Source, A], #{}),
        ?assertEqual(2, length(maps:get(files, First))),
        Cache = maps:get(file_cache, First),
        ?assertEqual(2, map_size(Cache)),
        ok = symbolic_fact_store:write_bundle(Db, maps:get(facts, First),
            #{<<"complete">> => true}, Cache),
        ?assertEqual(Cache, symbolic_file_cache:load(Db)),
        meck:expect(ts_extract, file, fun(File) ->
            case File of B -> error(should_have_hit_cache);
                _ -> meck:passthrough([File]) end
        end),
        {ok, Unchanged} = symbolic_parse:scan_paths_report([Source], symbolic_file_cache:load(Db)),
        ?assertEqual(maps:get(facts, First), maps:get(facts, Unchanged)),
        ok = file:write_file(A, <<"-module(a).\nnew() -> ok.\n">>),
        {ok, Changed} = symbolic_parse:scan_paths_report([Source], maps:get(file_cache, Unchanged)),
        ?assertEqual([], maps:get(failed_files, Changed)),
        ?assert(lists:any(fun(F) -> element(1, F) =:= defines andalso
            element(2, F) =:= new end, maps:get(facts, Changed))),
        ?assertNot(lists:any(fun(F) -> element(1, F) =:= defines andalso
            element(2, F) =:= old end, maps:get(facts, Changed))),
        ok = file:delete(B),
        {ok, Deleted} = symbolic_parse:scan_paths_report([Source], maps:get(file_cache, Changed)),
        ?assertEqual(1, map_size(maps:get(file_cache, Deleted))),
        ?assertNot(lists:any(fun(F) -> element(1, F) =:= defines andalso
            element(2, F) =:= keep end, maps:get(facts, Deleted)))
    after
        _ = (try meck:unload(ts_extract) catch _:_ -> ok end),
        _ = file:del_dir_r(Root)
    end.

failed_extraction_does_not_cache_empty_facts_test() ->
    Root = filename:absname(filename:join("_build", "incremental_failure_scratch")),
    File = filename:join(Root, "bad.erl"),
    _ = file:del_dir_r(Root),
    ok = filelib:ensure_dir(File),
    ok = file:write_file(File, <<"-module(bad).\nf() -> ok.\n">>),
    meck:new(ts_extract, [passthrough]),
    meck:expect(ts_extract, file, fun(_) -> error(boom) end),
    try
        {ok, Report} = symbolic_parse:scan_report(Root, #{}),
        ?assertEqual([File], maps:get(failed_files, Report)),
        ?assertEqual(#{}, maps:get(file_cache, Report))
    after
        meck:unload(ts_extract),
        _ = file:del_dir_r(Root)
    end.

%% scan/1 (the side-effect-free core) is already exercised end-to-end by
%% symbolic_codebase_tests.erl, which is the main consumer. This module
%% covers the rest of run/2's body: maybe_store/2, print_fact/1, and
%% error_message/1 (the exact text printed for each scan/1 error, pulled
%% out specifically so it's assertable without calling run/2 itself,
%% which halt()s on every path).

error_message_directory_failure_test() ->
    Text = lists:flatten(symbolic_parse:error_message(
        {cannot_list_directory, "/project/hidden", eacces})),
    ?assert(string:find(Text, "/project/hidden") =/= nomatch),
    ?assert(string:find(Text, "eacces") =/= nomatch),
    ?assert(string:find(Text, "snapshot unchanged") =/= nomatch).

error_message_no_such_directory_test() ->
    Text = lists:flatten(symbolic_parse:error_message({no_such_directory, "no/such/dir"})),
    ?assertEqual("parse: no such directory: no/such/dir\n", Text).

error_message_nif_not_loadable_test() ->
    Text = lists:flatten(symbolic_parse:error_message({nif_not_loadable, some_reason})),
    ?assertEqual(
        "parse: symbolic_ts (the tree-sitter NIF) isn't loadable "
        "in this build - a known packaging limitation, not a code "
        "bug. Run via a `rebar3 release` (or `rebar3 shell`); see "
        "docs/cli-erlang.md.\n",
        Text).

error_message_no_such_path_test() ->
    Text = lists:flatten(symbolic_parse:error_message({no_such_path, "no/such/thing"})),
    ?assertEqual("parse: no such file or directory: no/such/thing\n", Text).

error_message_unsupported_file_test() ->
    Text = lists:flatten(symbolic_parse:error_message({unsupported_file, "notes.txt"})),
    ?assertMatch("parse: notes.txt has no extension" ++ _, Text).

error_message_no_such_config_test() ->
    Text = lists:flatten(symbolic_parse:error_message({no_such_config, "no/such/config.json"})),
    ?assertEqual("parse: no such config file: no/such/config.json\n", Text).

error_message_no_config_found_test() ->
    Text = lists:flatten(symbolic_parse:error_message({no_config_found, "/some/dir"})),
    ?assertMatch("parse: no .symbolic/config.json found walking up from /some/dir" ++ _, Text).

%% --- resolve_config/1: an explicit -config path wins outright (and must
%% exist); otherwise .symbolic/config.json is discovered by walking up
%% from the current directory — same shape as symbolic_query:resolve_rules/3.

resolve_config_explicit_override_test() ->
    Path = filename:join(["_build", "parse_resolve_config_override_scratch.json"]),
    ok = filelib:ensure_dir(Path),
    ok = file:write_file(Path, <<"{}">>),
    ?assertEqual({ok, Path}, symbolic_parse:resolve_config(Path)),
    ok = file:delete(Path).

resolve_config_explicit_override_missing_is_an_error_test() ->
    ?assertMatch({error, {no_such_config, "no/such/config_zz.json"}},
        symbolic_parse:resolve_config("no/such/config_zz.json")).

%% --- parallel_map/2: the one-process-per-item helper scan_paths/1 and
%% scan/1's own file extraction are both built on (see its own doc
%% comment for why concurrent tree-sitter NIF calls are safe). Two
%% properties worth locking down: results come back in the ORIGINAL
%% item order regardless of which worker finishes first, and a worker
%% crash is re-raised in the caller rather than silently dropped. The
%% timing test proves it's genuinely concurrent, not just
%% spawn-then-immediately-collect-in-a-loop with no real overlap: five
%% 150ms sleeps sequentially would take >=750ms; a generous 500ms bound
%% still leaves 250ms of margin over the fully-parallel ~150ms case. ---

parallel_map_preserves_item_order_test() ->
    ?assertEqual([1, 4, 9, 16, 25],
        symbolic_parse:parallel_map(fun(X) -> X * X end, [1, 2, 3, 4, 5])).

parallel_map_on_empty_list_is_empty_test() ->
    ?assertEqual([], symbolic_parse:parallel_map(fun(X) -> X end, [])).

parallel_map_runs_concurrently_not_sequentially_test() ->
    Fun = fun(_) -> timer:sleep(150) end,
    {ElapsedUs, _Results} = timer:tc(fun() ->
        symbolic_parse:parallel_map(Fun, [a, b, c, d, e])
    end),
    ?assert(ElapsedUs < 500000).

parallel_map_reraises_a_worker_crash_test() ->
    Handler = symbolic_parse_worker_failure_test,
    ok = logger:add_handler(Handler, symbolic_parse_log_handler,
                            #{receiver => self(), level => error}),
    try
        ?assertError({parse_worker_crashed, _},
            symbolic_parse:parallel_map(fun(X) ->
                case X of 2 -> error(boom); _ -> X end
            end, [1, 2, 3])),
        receive
            {parse_log, #{msg := {Format, Args}}} ->
                Message = lists:flatten(io_lib:format(Format, Args)),
                ?assert(string:find(Message, "worker failed for 2") =/= nomatch),
                ?assert(string:find(Message, "boom") =/= nomatch)
        after 1000 -> ?assert(false)
        end
    after logger:remove_handler(Handler) end.

%% --- scan_paths/1: merges a directory walk and a directly-named file
%% into one fact set, and reports the same errors scan_one/2's two
%% branches (missing path, unsupported extension) are meant to surface. ---

scan_paths_merges_a_directory_and_a_file_test() ->
    Root = filename:join(["_build", "parse_scan_paths_scratch"]),
    _ = file:del_dir_r(Root),
    ok = filelib:ensure_dir(filename:join([Root, "src", "placeholder"])),
    ok = file:write_file(filename:join([Root, "src", "greeter.erl"]),
        <<"-module(greeter).\nhello() -> ok.\n">>),
    ok = file:write_file(filename:join([Root, "config.toml"]), <<"name = \"greeter\"\n">>),
    try
        {ok, {Files, Facts}} = symbolic_parse:scan_paths(
            [filename:join([Root, "src"]), filename:join([Root, "config.toml"])]),
        ?assertEqual(["config.toml", "greeter.erl"],
            lists:sort([filename:basename(F) || F <- Files])),
        ?assert(lists:member(
            {config_value, list_to_atom(filename:join([Root, "config.toml"])), name, <<"greeter">>, 1},
            Facts)),
        ?assert(lists:any(fun(F) -> element(1, F) =:= defines end, Facts))
    after
        _ = file:del_dir_r(Root)
    end.

scan_paths_reports_a_missing_path_test() ->
    ?assertEqual({error, {no_such_path, "no/such/thing_zz"}},
        symbolic_parse:scan_paths(["no/such/thing_zz"])).
tsx_child_text_with_decimal_looking_text_scans_without_errors_test() ->
    File = filename:absname("test/fixtures/tsx_text_numbers.tsx"),
    {ok, Report} = symbolic_parse:scan_paths_report([File]),
    ?assertEqual([], maps:get(failed_files, Report)),
    Facts = maps:get(facts, Report),
    Path = list_to_atom(File),
    ?assert(lists:any(fun
        ({calls, renderStory, 0, {local, renderCard, 1}, Path0, _Line}) ->
            Path0 =:= Path;
        (_) -> false
    end, Facts)),
    NumberLiterals = lists:sort([{Raw, Value} ||
        {literal, _Id, renderStory, 0, number, Value, Path0, _Line, Raw} <- Facts,
        Path0 =:= Path]),
    ?assertEqual([{<<".1">>, 0.1}, {<<"214.">>, 214.0}], NumberLiterals).

scan_paths_reports_an_unsupported_file_extension_test() ->
    Path = filename:join(["_build", "parse_scan_paths_unsupported_scratch.txt"]),
    ok = filelib:ensure_dir(Path),
    ok = file:write_file(Path, <<"hello\n">>),
    ?assertEqual({error, {unsupported_file, Path}}, symbolic_parse:scan_paths([Path])),
    ok = file:delete(Path).

maybe_store_undefined_is_noop_test() ->
    ?assertEqual(ok, symbolic_parse:maybe_store(undefined, [{defines, foo, 0, <<"()">>, f, 1}])).

maybe_store_writes_to_dets_test() ->
    Path = filename:join(["_build", "parse_maybe_store_test_scratch.dets"]),
    Facts = [{defines, foo, 0, <<"()">>, 'f.erl', 1}],
    ?assertEqual(ok, symbolic_parse:maybe_store(Path, Facts)),
    ?assertEqual(Facts, symbolic_fact_store:read(Path)),
    ok = file:delete(Path).

summary_reports_documented_parse_fields_test() ->
    Files = ["src/main.ts", "README.md", "config.toml", "script.sh", "lib.erl"],
    Facts = [{defines, main, 0, <<"()">>, 'src/main.ts', 1},
             {heading, 'README.md', 1, <<"Title">>}],
    ?assertEqual(
        #{files => 5,
          languages => [<<"bash">>, <<"erlang">>, <<"markdown">>, <<"toml">>, <<"typescript">>],
          total_facts => 2},
        symbolic_parse:summary(Files, Facts)).

%% --- scan/1's directory walk: node_modules/.git always pruned,
%% .gitignore honored — the matching logic itself (globs, anchoring,
%% negation, precedence) is unit-tested in symbolic_gitignore_tests.erl;
%% this is the end-to-end proof that scan/1 actually calls it and that
%% an ignored directory is genuinely never descended into, not just
%% filtered out of the result afterward (real files on disk, not
%% hand-built facts — the whole point is proving the WALK, not the
%% extractor). ---

scan_skips_directory_symlinks_but_keeps_file_symlinks_test() ->
    Scratch = filename:join(["_build", "parse_symlink_scratch"]),
    Root = filename:join(Scratch, "root"),
    Outside = filename:join(Scratch, "outside"),
    _ = file:del_dir_r(Scratch),
    ok = filelib:ensure_dir(filename:join(Root, "placeholder")),
    ok = filelib:ensure_dir(filename:join(Outside, "placeholder")),
    ok = file:write_file(filename:join(Root, "kept.erl"),
        <<"-module(kept).\nf() -> ok.\n">>),
    ok = file:write_file(filename:join(Outside, "outside.erl"),
        <<"-module(outside).\nf() -> ok.\n">>),
    ok = file:make_symlink(".", filename:join(Root, "loop")),
    ok = file:make_symlink("../outside", filename:join(Root, "external")),
    ok = file:make_symlink("kept.erl", filename:join(Root, "alias.erl")),
    try
        {ok, Report} = symbolic_parse:scan_report(Root),
        ?assertEqual(true, maps:get(complete, Report)),
        ?assertEqual(["alias.erl", "kept.erl"],
            lists:sort([filename:basename(F) || F <- maps:get(files, Report)]))
    after
        _ = file:del_dir_r(Scratch)
    end.

scan_prunes_node_modules_and_a_gitignore_entry_test() ->
    Root = filename:join(["_build", "parse_scan_ignore_scratch"]),
    _ = file:del_dir_r(Root),
    ok = filelib:ensure_dir(filename:join([Root, "src", "placeholder"])),
    ok = filelib:ensure_dir(filename:join([Root, "node_modules", "some_pkg", "placeholder"])),
    ok = filelib:ensure_dir(filename:join([Root, "vendor", "placeholder"])),
    ok = file:write_file(filename:join(Root, ".gitignore"), <<"vendor/\n">>),
    ok = file:write_file(filename:join([Root, "src", "kept.erl"]),
        <<"-module(kept).\nf() -> ok.\n">>),
    %% node_modules is pruned unconditionally (no .gitignore entry needed
    %% for it at all) — this file must never even be looked at.
    ok = file:write_file(filename:join([Root, "node_modules", "some_pkg", "index.erl"]),
        <<"-module(index).\nbroken(.\n">>),
    ok = file:write_file(filename:join([Root, "vendor", "dropped.erl"]),
        <<"-module(dropped).\nf() -> ok.\n">>),
    try
        {ok, {Files, _Facts}} = symbolic_parse:scan(Root),
        Basenames = lists:sort([filename:basename(F) || F <- Files]),
        ?assertEqual(["kept.erl"], Basenames)
    after
        _ = file:del_dir_r(Root)
    end.
