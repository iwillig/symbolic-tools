%%% Supervises prolog_session children, one per MCP session. Per-session
%%% fault isolation: a crash in one session's erlog state doesn't affect
%%% any other session. See docs/erlang-mcp-design.md §1, §8.
-module(prolog_session_sup).
-behaviour(supervisor).

-export([start_link/0, start_child/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec start_child() -> {ok, pid()}.
start_child() ->
    supervisor:start_child(?MODULE, []).

init([]) ->
    SupFlags = #{strategy => simple_one_for_one, intensity => 10, period => 60},
    ChildSpec = #{
        id => prolog_session,
        start => {prolog_session, start_link, []},
        restart => temporary,
        shutdown => 1000,
        type => worker,
        modules => [prolog_session]
    },
    {ok, {SupFlags, [ChildSpec]}}.
