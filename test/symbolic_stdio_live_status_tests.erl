-module(symbolic_stdio_live_status_tests).
-include_lib("eunit/include/eunit.hrl").

%% The gate test for docs/plans/live-mcp-operation-status.md: prove that
%% a `status` request issued on the SAME MCP connection is answered with
%% the live parse/query phase BEFORE the blocked parse/query reply
%% arrives. This is the assertion direct-handler invocation cannot make
%% and the reason the project-local adapter exists.
%%
%% Only the underlying scan/proof work is mocked (blocking when armed,
%% then passing through to the real implementation), so everything else
%% — JSON-RPC framing, dispatch, workers, the tracker, the cache, the
%% handlers — is the real server path. Same fixture layout as
%% symbolic_serve_tests: a throwaway configured project whose paths
%% point at test/fixtures.

with_server(Fun) ->
    catch gen_server:stop(symbolic_stdio),
    catch gen_statem:stop(symbolic_operation_status),
    catch gen_server:stop(symbolic_codebase),
    persistent_term:put({?MODULE, block}, false),
    persistent_term:put({?MODULE, release}, false),

    Root = filename:absname(filename:join(["_build", "live_status_project"])),
    _ = file:del_dir_r(Root),
    ConfigPath = filename:join([Root, ".symbolic", "config.json"]),
    ok = filelib:ensure_dir(ConfigPath),
    ok = file:write_file(ConfigPath,
        <<"{\"paths\": [\"../../test/fixtures\"], "
          "\"database\": \".symbolic/facts.dets\"}">>),
    {ok, OldCwd} = file:get_cwd(),

    {ok, _StatusPid} = symbolic_operation_status:start_link(),
    {ok, CachePid} = symbolic_codebase:start_link(),
    {ok, _StdioPid} = symbolic_stdio:start_test(self()),
    ok = file:set_cwd(Root),
    ok = symbolic_serve:register_tools(),

    meck:new(symbolic_parse, [non_strict]),
    meck:expect(symbolic_parse, scan_paths_report,
        fun(Paths, Cache) -> maybe_wait(), meck:passthrough([Paths, Cache]) end),

    try
        Fun()
    after
        meck:unload(symbolic_parse),
        ok = file:set_cwd(OldCwd),
        catch gen_server:stop(symbolic_stdio),
        catch gen_statem:stop(symbolic_operation_status),
        unlink(CachePid),
        Ref = erlang:monitor(process, CachePid),
        exit(CachePid, shutdown),
        receive {'DOWN', Ref, process, CachePid, _} -> ok after 1000 -> ok end,
        _ = file:del_dir_r(Root),
        persistent_term:erase({?MODULE, block}),
        persistent_term:erase({?MODULE, release})
    end,
    ok.

status_reaches_the_client_while_parse_blocks_test() ->
    with_server(fun() ->
        send_initialize(),
        arm_block(),
        send_call(<<"p1">>, <<"parse">>, #{}),
        %% Let the parse worker reach the blocked extraction phase.
        timer:sleep(300),
        send_call(<<"s1">>, <<"status">>, #{}),
        StatusWhileRunning = receive_payload(),
        ?assertMatch(#{<<"id">> := <<"s1">>,
                       <<"payload">> := #{<<"ok">> :=
                             #{<<"state">> := <<"running">>,
                               <<"active">> := #{<<"kind">> := <<"parse">>,
                                                 <<"phase">> := <<"extracting">>}}}},
                     StatusWhileRunning),
        %% The parse reply cannot exist yet: the scan is still latched.
        ?assertEqual(no_early_parse_reply, receive_parse_reply_or_nothing()),

        release(),
        disarm_block(),
        #{<<"id">> := <<"p1">>} = receive_response(),
        send_call(<<"s2">>, <<"status">>, #{}),
        ?assertMatch(#{<<"id">> := <<"s2">>,
                       <<"payload">> := #{<<"ok">> :=
                             #{<<"state">> := <<"idle">>,
                               <<"active">> := null,
                               <<"last">> := #{<<"kind">> := <<"parse">>,
                                               <<"outcome">> :=
                                                   #{<<"status">> := <<"succeeded">>}}}}},
                     receive_payload())
    end).

status_reaches_the_client_while_query_proves_test() ->
    with_server(fun() ->
        send_initialize(),
        send_call(<<"p1">>, <<"parse">>, #{}),
        #{<<"id">> := <<"p1">>} = receive_response(),

        meck:new(erlog, [non_strict]),
        meck:expect(erlog, prove,
            fun(Goal, Erl) -> maybe_wait(), meck:passthrough([Goal, Erl]) end),
        try
            arm_block(),
            send_call(<<"q1">>, <<"query">>,
                      #{<<"goal">> => <<"defines(F, A, _, File, _)">>,
                        <<"limit">> => 1}),
            timer:sleep(300),
            send_call(<<"s1">>, <<"status">>, #{}),
            ?assertMatch(#{<<"id">> := <<"s1">>,
                           <<"payload">> := #{<<"ok">> :=
                                 #{<<"state">> := <<"running">>,
                                   <<"active">> := #{<<"kind">> := <<"query">>,
                                                     <<"phase">> := <<"proving">>}}}},
                         receive_payload()),
            ?assertEqual(no_early_query_reply, receive_query_reply_or_nothing()),

            release(),
            disarm_block(),
            #{<<"id">> := <<"q1">>,
              <<"payload">> := #{<<"solutions">> := [_ | _]}} =
                receive_payload(),
            send_call(<<"s2">>, <<"status">>, #{}),
            ?assertMatch(#{<<"payload">> := #{<<"ok">> :=
                               #{<<"state">> := <<"idle">>,
                                 <<"last">> := #{<<"outcome">> :=
                                     #{<<"status">> := <<"succeeded">>}}}}},
                         receive_payload())
        after
            catch meck:unload(erlog)
        end
    end).

failed_operation_reports_failed_outcome_test() ->
    with_server(fun() ->
        send_initialize(),
        %% A query before any parse fails during validation; the tracker
        %% must record a failed outcome, not a crash.
        send_call(<<"e1">>, <<"query">>, #{<<"goal">> => <<"defines(x, 1)">>}),
        ?assertMatch(#{<<"id">> := <<"e1">>, <<"payload">> := #{<<"error">> := _}},
                     receive_payload()),
        send_call(<<"e2">>, <<"status">>, #{}),
        ?assertMatch(#{<<"id">> := <<"e2">>,
                       <<"payload">> := #{<<"ok">> :=
                             #{<<"state">> := <<"idle">>,
                               <<"last">> := #{<<"kind">> := <<"query">>,
                                               <<"outcome">> :=
                                                   #{<<"status">> := <<"failed">>}}}}},
                     receive_payload())
    end).

%% Helpers

%% Blocking latch: mocks wait only while the current test has armed the
%% block flag, so tests that need a clean parse are not affected.
arm_block() -> persistent_term:put({?MODULE, block}, true).
disarm_block() -> persistent_term:put({?MODULE, block}, false).
release() -> persistent_term:put({?MODULE, release}, true).

maybe_wait() ->
    case persistent_term:get({?MODULE, block}, false) of
        true -> wait_release();
        false -> ok
    end.

wait_release() ->
    case persistent_term:get({?MODULE, release}, false) of
        true -> ok;
        false -> timer:sleep(10), wait_release()
    end.

send_initialize() ->
    Line = jsx:encode(#{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 0,
                        <<"method">> => <<"initialize">>, <<"params">> => #{}}),
    symbolic_stdio ! {stdin_line, Line},
    #{<<"result">> := #{<<"protocolVersion">> := <<"2025-06-18">>}} = receive_response(),
    Notify = jsx:encode(#{<<"jsonrpc">> => <<"2.0">>,
                          <<"method">> => <<"notifications/initialized">>}),
    symbolic_stdio ! {stdin_line, Notify},
    ok.

send_call(Id, Tool, Arguments) ->
    Line = jsx:encode(#{<<"jsonrpc">> => <<"2.0">>, <<"id">> => Id,
                        <<"method">> => <<"tools/call">>,
                        <<"params">> => #{<<"name">> => Tool,
                                         <<"arguments">> => Arguments}}),
    symbolic_stdio ! {stdin_line, Line}.

receive_response() ->
    receive
        {stdio_line, Json} -> jsx:decode(Json, [return_maps]);
        _Other -> receive_response()
    after 15000 ->
        erlang:error(timeout_waiting_for_response)
    end.

%% Tool results are wrapped in the MCP content envelope; the handler's
%% own JSON lives in content[0].text.
receive_payload() ->
    #{<<"id">> := Id, <<"result">> := #{<<"content">> := [#{<<"text">> := Text}]}} =
        receive_response(),
    #{<<"id">> => Id, <<"payload">> => jsx:decode(Text, [return_maps])}.

receive_parse_reply_or_nothing() ->
    receive
        {stdio_line, Json} ->
            case jsx:decode(Json, [return_maps]) of
                #{<<"id">> := <<"p1">>} -> got_parse_reply_early;
                _ -> receive_parse_reply_or_nothing()
            end
    after 200 ->
        no_early_parse_reply
    end.

receive_query_reply_or_nothing() ->
    receive
        {stdio_line, Json} ->
            case jsx:decode(Json, [return_maps]) of
                #{<<"id">> := <<"q1">>} -> got_query_reply_early;
                _ -> receive_query_reply_or_nothing()
            end
    after 200 ->
        no_early_query_reply
    end.
