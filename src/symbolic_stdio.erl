%%% Tool-only MCP stdio adapter. The registry/reader stays responsive while
%%% monitored tool workers run; this process alone writes JSON-RPC responses.
-module(symbolic_stdio).
-behaviour(gen_server).
-export([start/0, start_test/1, add_tool/4, begin_reading/0, stop/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(MAX_IN_FLIGHT, 16).

start() ->
    case gen_server:start_link({local, ?MODULE}, ?MODULE, #{reader => true}, []) of
        {ok, _Pid} -> ok;
        Error -> Error
    end.
%% Test seam: exercise real JSON-RPC dispatch without taking over stdin/stdout.
start_test(Output) -> gen_server:start_link({local, ?MODULE}, ?MODULE,
                                      #{reader => false, output => Output}, []).
stop() -> gen_server:stop(?MODULE).
add_tool(Name, Description, Handler, Schema) ->
    gen_server:call(?MODULE, {add_tool, Name, Description, Handler, Schema}).
%% Spawn the stdin reader only after tool registration finishes. If the
%% reader ran from init, stdin closing immediately (e.g. a closed pipe
%% during tests or a fast client exit) would stop the server while
%% add_tool calls are still in flight — a noproc race.
begin_reading() -> gen_server:cast(?MODULE, begin_reading).

init(Opts) ->
    process_flag(trap_exit, true),
    {ok, #{reader => undefined, read_wanted => maps:get(reader, Opts),
           output => maps:get(output, Opts, standard_io),
           tools => #{}, workers => #{}, ids => #{}}}.

read_lines(Parent) ->
    case io:get_line("") of
        eof -> Parent ! input_eof;
        {error, Reason} -> exit({stdin_error, Reason});
        Line -> Parent ! {stdin_line, Line}, read_lines(Parent)
    end.

handle_call({add_tool, Name, Desc, Handler, Schema}, _From, State)
    when is_binary(Name), is_binary(Desc), is_function(Handler, 1) ->
    Tools = maps:get(tools, State),
    {reply, ok, State#{tools => Tools#{Name => {Desc, Handler, Schema}}}};
handle_call(_Call, _From, State) -> {reply, {error, bad_request}, State}.
handle_cast(begin_reading, #{read_wanted := true, reader := undefined} = State) ->
    Parent = self(),
    {noreply, State#{reader => spawn_link(fun() -> read_lines(Parent) end)}};
handle_cast(_Event, State) -> {noreply, State}.

handle_info({stdin_line, Line}, State) ->
    {noreply, dispatch(Line, State)};
handle_info({tool_result, Pid, Response}, State) ->
    case maps:take(Pid, maps:get(workers, State)) of
        {#{id := Id, ref := Ref}, Workers} ->
            erlang:demonitor(Ref, [flush]),
            send(Response, State),
            settle(Workers, State, Id);
        error -> {noreply, State}
    end;
handle_info({'DOWN', Ref, process, Pid, Reason}, State) ->
    case maps:find(Pid, maps:get(workers, State)) of
        {ok, #{id := Id, ref := Ref}} ->
            Workers = maps:remove(Pid, maps:get(workers, State)),
            send(failure(Id, -32603, <<"Internal error">>), State),
            logger:error("MCP tool worker crashed: ~p", [Reason]),
            settle(Workers, State, Id);
        error -> {noreply, State}
    end;
%% EOF: stop only when no tool worker is in flight, so responses for
%% requests the client already sent are not lost. Otherwise drain first.
handle_info(input_eof, State) ->
    case maps:size(maps:get(workers, State)) of
        0 -> {stop, normal, State};
        _ -> {noreply, State#{stopping => true}}
    end;
%% The only linked process is the stdin reader (workers are monitored,
%% not linked). It exits normally right after sending input_eof; treat
%% any other exit as a reader failure.
handle_info({'EXIT', _Pid, normal}, State) -> {noreply, State};
handle_info({'EXIT', _Pid, Reason}, State) ->
    {stop, {reader_exit, Reason}, State};
handle_info(_Event, State) -> {noreply, State}.

settle(Workers, State, Id) ->
    NewState = State#{workers => Workers, ids => maps:remove(Id, maps:get(ids, State))},
    case {maps:get(stopping, NewState, false), maps:size(Workers)} of
        {true, 0} -> {stop, normal, NewState};
        _ -> {noreply, NewState}
    end.

terminate(_Reason, State) ->
    [exit(maps:get(pid, Worker), kill) || Worker <- maps:values(maps:get(workers, State))],
    ok.
code_change(_Version, State, _Extra) -> {ok, State}.

dispatch(Line, State) ->
    try jsx:decode(iolist_to_binary(Line), [return_maps]) of
        #{<<"method">> := <<"notifications/initialized">>} -> State;
        #{<<"method">> := <<"initialize">>, <<"id">> := Id} ->
            %% Match the pinned erlmcp 0.5.1 protocol version so client
            %% negotiation behavior is unchanged from the previous transport.
            send(response(Id, #{<<"protocolVersion">> => <<"2025-06-18">>,
                <<"capabilities">> => #{<<"tools">> => #{<<"listChanged">> => false},
                    <<"resources">> => #{<<"subscribe">> => false, <<"listChanged">> => false},
                    <<"prompts">> => #{<<"listChanged">> => false}},
                <<"serverInfo">> => #{<<"name">> => <<"erlmcp-stdio">>,
                                      <<"version">> => <<"1.0.0">>}}), State),
            State;
        #{<<"method">> := <<"tools/list">>, <<"id">> := Id} ->
            Tools = maps:fold(fun(Name, {Desc, _Handler, Schema}, Acc) ->
                Item = #{<<"name">> => Name, <<"description">> => Desc},
                [case Schema of undefined -> Item; _ -> Item#{<<"inputSchema">> => Schema} end | Acc]
            end, [], maps:get(tools, State)),
            send(response(Id, #{<<"tools">> => Tools}), State), State;
        #{<<"method">> := <<"tools/call">>, <<"id">> := Id,
          <<"params">> := #{<<"name">> := Name, <<"arguments">> := Args}} when is_map(Args) ->
            start_tool(Id, Name, Args, State);
        #{<<"method">> := <<"tools/call">>, <<"id">> := Id} ->
            send(failure(Id, -32602, <<"Invalid parameters">>), State), State;
        #{<<"method">> := Method, <<"id">> := Id} when is_binary(Method) ->
            send(failure(Id, -32601, <<"Method not found: ", Method/binary>>), State), State;
        #{<<"id">> := Id} ->
            send(failure(Id, -32600, <<"Invalid Request">>), State), State;
        _ -> State
    catch
        error:_ -> send(failure(null, -32700, <<"Parse error">>), State), State
    end.

start_tool(Id, Name, Args, State) ->
    Workers = maps:get(workers, State),
    Ids = maps:get(ids, State),
    case {maps:is_key(Id, Ids), map_size(Workers) >= ?MAX_IN_FLIGHT,
          maps:find(Name, maps:get(tools, State))} of
        {true, _, _} -> send(failure(Id, -32600, <<"Request ID already in flight">>), State), State;
        {_, true, _} -> send(failure(Id, -32000, <<"Too many active requests">>), State), State;
        {_, _, error} -> send(failure(Id, -32601, <<"Tool not found">>), State), State;
        {false, false, {ok, {_Desc, Handler, _Schema}}} ->
            Parent = self(),
            {Pid, Ref} = spawn_monitor(fun() ->
                Reply = try
                    Result = iolist_to_binary(Handler(Args)),
                    response(Id, #{<<"content">> => [#{<<"type">> => <<"text">>,
                                                    <<"text">> => Result}]})
                catch Class:Reason:Stack ->
                    logger:error("MCP tool failed: ~p:~p ~p", [Class, Reason, Stack]),
                    failure(Id, -32603, <<"Internal error">>)
                end,
                Parent ! {tool_result, self(), Reply}
            end),
            State#{workers => Workers#{Pid => #{id => Id, ref => Ref, pid => Pid}}, ids => Ids#{Id => Pid}}
    end.

response(Id, Result) -> #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => Id, <<"result">> => Result}.
failure(Id, Code, Message) ->
    #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => Id,
      <<"error">> => #{<<"code">> => Code, <<"message">> => Message}}.
send(Response, State) ->
    Json = jsx:encode(Response),
    case maps:get(output, State) of
        standard_io -> io:put_chars(standard_io, [Json, "\n"]);
        Pid -> Pid ! {stdio_line, Json}, ok
    end.
