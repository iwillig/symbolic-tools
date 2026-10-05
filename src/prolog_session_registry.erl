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

%% The registry gen_server. Its real state is the named ets table
%% (?TABLE) — the gen_server exists to serialize mutations and own the
%% monitors; lookups go straight to ets with no process hop.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec start_session() -> {ok, binary()}.
%% Spawn a fresh prolog_session (via prolog_session_sup) and return its
%% opaque ID. The ID is what an MCP client threads through
%% prolog_consult/prolog_query/prolog_end_session calls.
start_session() ->
    gen_server:call(?MODULE, start_session).

-spec lookup(binary()) -> {ok, pid()} | error.
%% Session ID to pid, straight from ets — no gen_server hop, so
%% stateless tool handlers stay cheap. error means the ID never existed
%% or its session already ended (the monitor cleans dead entries up).
lookup(SessionId) ->
    case ets:lookup(?TABLE, SessionId) of
        [{SessionId, Pid}] -> {ok, Pid};
        [] -> error
    end.

-spec end_session(binary()) -> ok | error.
%% Tear a session down: drop the ets entry, then stop its process.
%% error for an unknown ID — ending twice is a caller bug, not a
%% silent no-op.
end_session(SessionId) ->
    gen_server:call(?MODULE, {end_session, SessionId}).

%% gen_server callbacks

%% One named ets table for the whole registry; the gen_server state
%% itself carries nothing.
init([]) ->
    ets:new(?TABLE, [named_table, protected, set]),
    {ok, #{}}.

%% Dispatch: start_session (spawn + register + monitor) and end_session
%% (unregister + stop). All state lives in the shared ets table, so
%% every clause returns the gen_server state unchanged.
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

%% Standard OTP no-op: every mutation is a call, not a cast.
handle_cast(_Msg, State) -> {noreply, State}.

%% A session's prolog_session process died (crash, or already stopped via
%% end_session — stop/1 uses gen_server:stop/1, which triggers this too,
%% but by then the ets entry is already gone, so the delete below is a
%% harmless no-op). Clean up the mapping either way so lookup/1 doesn't
%% return a dead pid.
handle_info({'DOWN', _Ref, process, Pid, _Reason}, State) ->
    ets:match_delete(?TABLE, {'_', Pid}),
    {noreply, State}.

%% Standard OTP no-op: the ets table dies with the process.
terminate(_Reason, _State) -> ok.

%% Standard OTP no-op.
code_change(_OldVsn, State, _Extra) -> {ok, State}.

new_session_id() ->
    base64:encode(crypto:strong_rand_bytes(18)).
