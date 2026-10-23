-module(symbolic_stdio_tests).
-include_lib("eunit/include/eunit.hrl").

%% Tests for the project-local stdio MCP adapter (docs/plans/
%% live-mcp-operation-status.md). start_test/1 runs the real dispatch
%% loop, real workers, and real response writing, with the output going
%% to the test process instead of standard_io and no stdin reader — the
%% stdin line injection below covers exactly what io:get_line would
%% return. Protocol shapes (JSON-RPC 2.0 IDs, error codes, framing)
%% must stay compatible with the pinned erlmcp 0.5.1 behavior the
%% previous transport had.

with_adapter(Fun) ->
    catch gen_server:stop(symbolic_stdio),
    {ok, Pid} = symbolic_stdio:start_test(self()),
    try
        ok = symbolic_stdio:add_tool(<<"echo">>, <<"Echo tool">>,
            fun(Args) -> jsx:encode(#{echo => maps:get(<<"value">>, Args, null)}) end,
            #{<<"type">> => <<"object">>}),
        Fun()
    after
        catch gen_server:stop(symbolic_stdio)
    end,
    ok.

initialize_negotiates_pinned_protocol_version_test() ->
    with_adapter(fun() ->
        send_initialize(),
        Response = receive_response(),
        ?assertMatch(#{<<"id">> := 1,
                       <<"result">> := #{<<"protocolVersion">> := <<"2025-06-18">>,
                                         <<"serverInfo">> :=
                                             #{<<"name">> := <<"erlmcp-stdio">>}}},
                     Response)
    end).

tools_list_includes_schema_test() ->
    with_adapter(fun() ->
        send_request(2, <<"tools/list">>, #{}),
        #{<<"result">> := #{<<"tools">> := Tools}} = receive_response(),
        [Echo] = [T || T <- Tools, maps:get(<<"name">>, T) =:= <<"echo">>],
        ?assertEqual(<<"Echo tool">>, maps:get(<<"description">>, Echo)),
        ?assertEqual(#{<<"type">> => <<"object">>}, maps:get(<<"inputSchema">>, Echo))
    end).

tool_call_returns_content_test() ->
    with_adapter(fun() ->
        send_request(3, <<"tools/call">>, #{<<"name">> => <<"echo">>,
                                            <<"arguments">> => #{<<"value">> => 42}}),
        #{<<"result">> := #{<<"content">> := [#{<<"text">> := Text}]}} = receive_response(),
        ?assertEqual(#{<<"echo">> => 42}, jsx:decode(Text, [return_maps]))
    end).

handler_crash_returns_internal_error_test() ->
    with_adapter(fun() ->
        ok = symbolic_stdio:add_tool(<<"boom">>, <<"Crashing tool">>,
                                     fun(_Args) -> exit(deliberate) end, undefined),
        send_request(4, <<"tools/call">>,
                     #{<<"name">> => <<"boom">>, <<"arguments">> => #{}}),
        Response = receive_response(),
        ?assertMatch(#{<<"id">> := 4, <<"error">> := #{<<"code">> := -32603}}, Response)
    end).

killed_worker_returns_internal_error_test() ->
    %% A hard kill is not catchable by the worker's try, so the reply
    %% comes from the monitor ('DOWN') path rather than the catch path.
    with_adapter(fun() ->
        ok = symbolic_stdio:add_tool(<<"hang">>, <<"Hanging tool">>,
            fun(_Args) -> register(stdio_test_hang, self()),
                          receive killed -> ok end end, undefined),
        send_request(5, <<"tools/call">>,
                     #{<<"name">> => <<"hang">>, <<"arguments">> => #{}}),
        Worker = wait_for_hang_worker(),
        exit(Worker, kill),
        Response = receive_response(),
        ?assertMatch(#{<<"id">> := 5, <<"error">> := #{<<"code">> := -32603}}, Response)
    end).

unknown_tool_is_not_found_test() ->
    with_adapter(fun() ->
        send_request(6, <<"tools/call">>,
                     #{<<"name">> => <<"missing">>, <<"arguments">> => #{}}),
        Response = receive_response(),
        ?assertMatch(#{<<"id">> := 6, <<"error">> := #{<<"code">> := -32601}}, Response)
    end).

missing_arguments_is_invalid_params_test() ->
    with_adapter(fun() ->
        send_request(7, <<"tools/call">>, #{<<"name">> => <<"echo">>}),
        Response = receive_response(),
        ?assertMatch(#{<<"id">> := 7, <<"error">> := #{<<"code">> := -32602}}, Response)
    end).

unknown_method_is_method_not_found_test() ->
    with_adapter(fun() ->
        send_request(8, <<"resources/list">>, #{}),
        Response = receive_response(),
        ?assertMatch(#{<<"id">> := 8,
                       <<"error">> := #{<<"code">> := -32601,
                                        <<"message">> :=
                                            <<"Method not found: resources/list">>}},
                     Response)
    end).

malformed_json_is_parse_error_test() ->
    with_adapter(fun() ->
        symbolic_stdio ! {stdin_line, <<"{not json">>},
        Response = receive_response(),
        ?assertMatch(#{<<"id">> := null, <<"error">> := #{<<"code">> := -32700}}, Response)
    end).

duplicate_in_flight_id_is_rejected_test() ->
    with_adapter(fun() ->
        ok = symbolic_stdio:add_tool(<<"slow">>, <<"Slow tool">>,
            fun(_Args) -> timer:sleep(2000), <<"done">> end, undefined),
        send_request(<<"dup">>, <<"tools/call">>,
                     #{<<"name">> => <<"slow">>, <<"arguments">> => #{}}),
        timer:sleep(100),
        send_request(<<"dup">>, <<"tools/call">>,
                     #{<<"name">> => <<"slow">>, <<"arguments">> => #{}}),
        Response = receive_response(),
        %% The only request that can have completed so far is the
        %% duplicate; the first is still blocked in its worker, so
        %% whatever arrives now is the rejection for the second call.
        ?assertMatch(#{<<"error">> := #{<<"code">> := -32600}}, Response)
    end).

id_is_reusable_after_completion_test() ->
    with_adapter(fun() ->
        ok = symbolic_stdio:add_tool(<<"quick">>, <<"Quick tool">>,
            fun(_Args) -> <<"quick">> end, undefined),
        send_request(<<"reuse">>, <<"tools/call">>,
                     #{<<"name">> => <<"quick">>, <<"arguments">> => #{}}),
        #{<<"id">> := <<"reuse">>} = receive_response(),
        send_request(<<"reuse">>, <<"tools/call">>,
                     #{<<"name">> => <<"quick">>, <<"arguments">> => #{}}),
        #{<<"id">> := <<"reuse">>} = receive_response(),
        ok
    end).

in_flight_limit_returns_overload_test() ->
    with_adapter(fun() ->
        ok = symbolic_stdio:add_tool(<<"slow">>, <<"Slow tool">>,
            fun(_Args) -> timer:sleep(2000), <<"done">> end, undefined),
        [begin
             send_request(Id, <<"tools/call">>,
                          #{<<"name">> => <<"slow">>, <<"arguments">> => #{}}),
             timer:sleep(20)
         end || Id <- lists:seq(1, 16)],
        timer:sleep(200),
        send_request(17, <<"tools/call">>,
                     #{<<"name">> => <<"slow">>, <<"arguments">> => #{}}),
        Response = receive_response(),
        ?assertMatch(#{<<"id">> := 17, <<"error">> := #{<<"code">> := -32000}}, Response)
    end).

eof_stops_the_server_test() ->
    catch gen_server:stop(symbolic_stdio),
    {ok, _Pid} = symbolic_stdio:start_test(self()),
    symbolic_stdio ! input_eof,
    wait_stopped(),
    ?assertEqual(undefined, whereis(symbolic_stdio)),
    ok.

%% Helpers

send_initialize() ->
    send_request(1, <<"initialize">>, #{<<"protocolVersion">> => <<"2025-06-18">>}).

send_request(Id, Method, Params) ->
    Line = jsx:encode(#{<<"jsonrpc">> => <<"2.0">>, <<"id">> => Id,
                        <<"method">> => Method, <<"params">> => Params}),
    symbolic_stdio ! {stdin_line, Line}.

receive_response() ->
    receive
        {stdio_line, Json} -> jsx:decode(Json, [return_maps]);
        _Other -> receive_response()
    after 5000 ->
        erlang:error({timeout_waiting_for_response, whereis(symbolic_stdio)})
    end.

wait_for_hang_worker() ->
    case whereis(stdio_test_hang) of
        undefined -> timer:sleep(10), wait_for_hang_worker();
        Pid -> Pid
    end.

wait_stopped() ->
    case whereis(symbolic_stdio) of
        undefined -> ok;
        _ -> timer:sleep(10), wait_stopped()
    end.
