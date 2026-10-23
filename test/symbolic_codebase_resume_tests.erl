-module(symbolic_codebase_resume_tests).
-include_lib("eunit/include/eunit.hrl").

%% Startup lifecycle integration: persist with one cache process, then
%% verify that a second one can query the disk snapshot before a blocked
%% incremental scan publishes the new snapshot.
resumes_before_background_refresh_test() ->
    Root = filename:absname(filename:join("_build", "codebase_resume_scratch")),
    _ = file:del_dir_r(Root),
    Src = filename:join(Root, "src"),
    File = filename:join(Src, "a.erl"),
    Config = filename:join([Root, ".symbolic", "config.json"]),
    ok = filelib:ensure_dir(Config),
    ok = filelib:ensure_dir(File),
    ok = file:write_file(Config,
         <<"{\"paths\":[\"src\"],\"database\":\".symbolic/facts.dets\"}">>),
    ok = file:write_file(File, <<"-module(a).\nold_name() -> ok.\n">>),
    {ok, PreviousCwd} = file:get_cwd(),
    {ok, First} = symbolic_codebase:start_link(),
    try
        {ok, FirstMeta} = symbolic_codebase:parse(Root),
        ?assertEqual(true, maps:get(scan_complete, FirstMeta)),
        stop_cache(First),
        ok = file:set_cwd(Root),
        ok = file:write_file(File, <<"-module(a).\nnew_name() -> ok.\n">>),
        TestPid = self(),
        meck:new(symbolic_parse, [passthrough]),
        meck:expect(symbolic_parse, scan_paths_report, fun(Paths, Cache) ->
            TestPid ! {scan_waiting, self()},
            receive release_scan -> ok end,
            meck:passthrough([Paths, Cache])
        end),
        {ok, Second} = symbolic_codebase:start_link(#{startup_refresh => true}),
        try
            receive {scan_waiting, Worker} ->
                {ok, Meta} = symbolic_codebase:overview(),
                ?assertEqual(disk, maps:get(snapshot_source, Meta)),
                ?assertEqual(true, maps:get(refreshing, Meta)),
                Json = jsx:decode(symbolic_serve:handle_overview(#{}), [return_maps]),
                ?assertMatch(#{<<"ok">> := #{<<"snapshot_source">> := <<"disk">>,
                                            <<"refreshing">> := true,
                                            <<"scan_complete">> := true,
                                            <<"type_analysis">> :=
                                                #{<<"status">> := <<"disabled">>}}}, Json),
                ?assertMatch({ok, [_ | _]}, symbolic_codebase:query("defines(old_name, 0, _, _, _)")),
                ?assertEqual({ok, []}, symbolic_codebase:query("defines(new_name, 0, _, _, _)")),
                Worker ! release_scan,
                wait_for_scan_snapshot(),
                ?assertEqual({ok, []}, symbolic_codebase:query("defines(old_name, 0, _, _, _)")),
                ?assertMatch({ok, [_ | _]}, symbolic_codebase:query("defines(new_name, 0, _, _, _)"))
            after 5000 -> error(scan_did_not_start)
            end
        after stop_cache(Second) end
    after
        catch meck:unload(symbolic_parse),
        ok = file:set_cwd(PreviousCwd),
        _ = file:del_dir_r(Root)
    end.

wait_for_scan_snapshot() ->
    case symbolic_codebase:overview() of
        {ok, #{snapshot_source := scan, refreshing := false}} -> ok;
        _ -> timer:sleep(25), wait_for_scan_snapshot()
    end.

stop_cache(Pid) ->
    unlink(Pid),
    Ref = erlang:monitor(process, Pid),
    exit(Pid, shutdown),
    receive {'DOWN', Ref, process, Pid, _} -> ok after 2000 -> error(cache_stop_timeout) end.

failed_refresh_keeps_disk_snapshot_test() ->
    with_saved_fixture(fun(Root, _File) ->
        meck:new(symbolic_parse, [passthrough]),
        meck:expect(symbolic_parse, scan_paths_report,
            fun(_Paths, _Cache) -> {error, simulated_refresh_failure} end),
        try
            {ok, Pid} = symbolic_codebase:start_link(#{startup_refresh => true}),
            try
                wait_for_refresh_end(),
                {ok, Meta} = symbolic_codebase:overview(),
                ?assertEqual(disk, maps:get(snapshot_source, Meta)),
                ?assertEqual(false, maps:get(refreshing, Meta)),
                ?assertMatch({ok, [_ | _]},
                    symbolic_codebase:query("defines(old_name, 0, _, _, _)")),
                ?assertEqual(true, maps:get(scan_complete, Meta)),
                ?assertEqual(true, filelib:is_regular(filename:join([Root, ".symbolic", "facts.dets"])))
            after stop_cache(Pid) end
        after meck:unload(symbolic_parse) end
    end).

explicit_parse_supersedes_background_refresh_test() ->
    with_saved_fixture(fun(Root, File) ->
        ok = file:write_file(File, <<"-module(a).\nnew_name() -> ok.\n">>),
        TestPid = self(),
        Attempts = atomics:new(1, []),
        meck:new(symbolic_parse, [passthrough]),
        meck:expect(symbolic_parse, scan_paths_report,
            fun(Paths, Cache) ->
                case atomics:add_get(Attempts, 1, 1) of
                    1 ->
                        TestPid ! {blocked_refresh, self()},
                        receive release_stale -> ok end;
                    _ -> ok
                end,
                meck:passthrough([Paths, Cache])
            end),
        try
            {ok, Pid} = symbolic_codebase:start_link(#{startup_refresh => true}),
            try
                receive {blocked_refresh, Stale} ->
                    {ok, _} = symbolic_codebase:parse(Root),
                    Stale ! release_stale,
                    {ok, Meta} = symbolic_codebase:overview(),
                    ?assertEqual(scan, maps:get(snapshot_source, Meta)),
                    ?assertEqual(false, maps:get(refreshing, Meta)),
                    ?assertMatch({ok, [_ | _]},
                        symbolic_codebase:query("defines(new_name, 0, _, _, _)")),
                    ?assertEqual({ok, []},
                        symbolic_codebase:query("defines(old_name, 0, _, _, _)"))
                after 5000 -> error(refresh_did_not_start)
                end
            after stop_cache(Pid) end
        after meck:unload(symbolic_parse) end
    end).

with_saved_fixture(Fun) ->
    Root = filename:absname(filename:join("_build", "codebase_resume_fixture")),
    _ = file:del_dir_r(Root),
    File = filename:join([Root, "src", "a.erl"]),
    Config = filename:join([Root, ".symbolic", "config.json"]),
    ok = filelib:ensure_dir(Config),
    ok = filelib:ensure_dir(File),
    ok = file:write_file(Config,
         <<"{\"paths\":[\"src\"],\"database\":\".symbolic/facts.dets\"}">>),
    ok = file:write_file(File, <<"-module(a).\nold_name() -> ok.\n">>),
    {ok, PreviousCwd} = file:get_cwd(),
    {ok, First} = symbolic_codebase:start_link(),
    try
        {ok, _} = symbolic_codebase:parse(Root),
        stop_cache(First),
        ok = file:set_cwd(Root),
        Fun(Root, File)
    after
        catch file:set_cwd(PreviousCwd),
        _ = file:del_dir_r(Root)
    end.

wait_for_refresh_end() ->
    case symbolic_codebase:overview() of
        {ok, #{refreshing := false}} -> ok;
        _ -> timer:sleep(25), wait_for_refresh_end()
    end.

invalid_saved_metadata_does_not_become_proof_test() ->
    with_saved_fixture(fun(Root, _File) ->
        DbMeta = filename:join([Root, ".symbolic", "facts.dets.scan.json"]),
        ok = file:write_file(DbMeta, <<"not JSON">>),
        TestPid = self(),
        meck:new(symbolic_parse, [passthrough]),
        meck:expect(symbolic_parse, scan_paths_report, fun(Paths, Cache) ->
            TestPid ! {blocked_scan, self()},
            receive release_scan -> ok end,
            meck:passthrough([Paths, Cache])
        end),
        try
            {ok, Pid} = symbolic_codebase:start_link(#{startup_refresh => true}),
            try
                receive {blocked_scan, Worker} ->
                    ?assertMatch({not_parsed, _}, symbolic_codebase:overview()),
                    ?assertEqual({error, not_parsed},
                        symbolic_codebase:query("defines(old_name, 0, _, _, _)")),
                    Worker ! release_scan,
                    wait_for_scan_snapshot()
                after 5000 -> error(refresh_did_not_start)
                end
            after stop_cache(Pid) end
        after meck:unload(symbolic_parse) end
    end).

incomplete_background_scan_keeps_disk_snapshot_test() ->
    with_saved_fixture(fun(_Root, _File) ->
        meck:new(symbolic_parse, [passthrough]),
        meck:expect(symbolic_parse, scan_paths_report,
            fun(_Paths, _Cache) ->
                {ok, #{complete => false, failed_files => ["vanished.ts"]}}
            end),
        try
            {ok, Pid} = symbolic_codebase:start_link(#{startup_refresh => true}),
            try
                wait_for_refresh_end(),
                {ok, Meta} = symbolic_codebase:overview(),
                ?assertEqual(disk, maps:get(snapshot_source, Meta)),
                ?assertEqual(true, maps:get(scan_complete, Meta)),
                ?assertMatch({ok, [_ | _]},
                    symbolic_codebase:query("defines(old_name, 0, _, _, _)"))
            after stop_cache(Pid) end
        after meck:unload(symbolic_parse) end
    end).
