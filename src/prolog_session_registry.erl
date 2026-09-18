%%% Maps an opaque MCP session ID to its prolog_session pid. MCP tool
%%% handlers are stateless (Params -> Result); this is what lets
%%% `prolog_consult`/`prolog_query`/`prolog_end_session` find the right
%%% session's process across separate tool calls. See
%%% docs/erlang-mcp-design.md §1, §3.
-module(prolog_session_registry).
-behaviour(gen_server).

-export([start_link/0, start_session/0, lookup/1, end_session/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(TABLE, ?MODULE).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec start_session() -> {ok, binary()}.
start_session() ->
    gen_server:call(?MODULE, start_session).

-spec lookup(binary()) -> {ok, pid()} | error.
lookup(SessionId) ->
    case ets:lookup(?TABLE, SessionId) of
        [{SessionId, Pid}] -> {ok, Pid};
        [] -> error
    end.

-spec end_session(binary()) -> ok | error.
end_session(SessionId) ->
    gen_server:call(?MODULE, {end_session, SessionId}).

%% gen_server callbacks

init([]) ->
    ets:new(?TABLE, [named_table, protected, set]),
    {ok, #{}}.

handle_call(start_session, _From, State) ->
    {ok, Pid} = prolog_session_sup:start_child(),
    SessionId = new_session_id(),
    ets:insert(?TABLE, {SessionId, Pid}),
    erlang:monitor(process, Pid),
    {reply, {ok, SessionId}, State};
handle_call({end_session, SessionId}, _From, State) ->
    Reply =
        case ets:lookup(?TABLE, SessionId) of
            [{SessionId, Pid}] ->
                ets:delete(?TABLE, SessionId),
                prolog_session:stop(Pid),
                ok;
            [] ->
                error
        end,
    {reply, Reply, State}.

handle_cast(_Msg, State) -> {noreply, State}.

%% A session's prolog_session process died (crash, or already stopped via
%% end_session — stop/1 uses gen_server:stop/1, which triggers this too,
%% but by then the ets entry is already gone, so the delete below is a
%% harmless no-op). Clean up the mapping either way so lookup/1 doesn't
%% return a dead pid.
handle_info({'DOWN', _Ref, process, Pid, _Reason}, State) ->
    ets:match_delete(?TABLE, {'_', Pid}),
    {noreply, State}.

terminate(_Reason, _State) -> ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

new_session_id() ->
    base64:encode(crypto:strong_rand_bytes(18)).
