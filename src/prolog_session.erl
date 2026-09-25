%%% One Prolog (erlog) session, held in a gen_server.
%%%
%%% Wraps a single erlog state so callers never touch the `#erlog{}`
%%% record directly. See docs/erlang-mcp-design.md.
-module(prolog_session).
-behaviour(gen_server).

-export([start_link/0, consult/2, consult_string/2, load_facts/2, query/2, query/3, stop/1]).
-export([init/1, handle_call/3, handle_cast/2, terminate/2, code_change/3]).

-define(QUERY_TIMEOUT_MS, 5000).

start_link() ->
    gen_server:start_link(?MODULE, [], []).

-spec consult(pid(), file:filename()) -> ok | {error, term()}.
consult(Pid, File) ->
    gen_server:call(Pid, {consult, File}).

%% Load program text directly (an MCP client sends Prolog source as a
%% string, not a file path — unlike the CLI's `-file`).
-spec consult_string(pid(), string() | binary()) -> ok | {error, term()}.
consult_string(Pid, ProgramText) ->
    gen_server:call(Pid, {consult_string, ProgramText}).

%% Assert a pre-built list of fact tuples directly into the session's
%% database — no text parsing, unlike consult/2 or consult_string/2 (see
%% symbolic_fact_store.erl, which is where such a list normally comes
%% from: a DETS-backed fact database written by `symbolic parse --db`).
%% Uses `asserta`, not `assertz`: order is irrelevant for pure facts (it
%% only affects backtracking order, never correctness), and
%% erlog_db_dict's assertz_clause/4 appends via `Cs ++ [_]` — O(N) per
%% call, so assertz-ing thousands of facts sharing one predicate would
%% be O(N^2). asserta prepends in O(1) (confirmed by reading
%% erlog_int.erl/erlog_db_dict.erl directly, not assumed).
-spec load_facts(pid(), [tuple()]) -> ok.
load_facts(Pid, Facts) ->
    gen_server:call(Pid, {load_facts, Facts}, infinity).

-spec query(pid(), string()) ->
    {ok, [{atom(), term()}]} | no_solution | {error, term()}.
query(Pid, GoalString) ->
    query(Pid, GoalString, ?QUERY_TIMEOUT_MS).

%% Same as query/2, with an explicit proof timeout instead of the
%% ?QUERY_TIMEOUT_MS default — mainly so tests can use a short timeout
%% instead of waiting out the real one.
-spec query(pid(), string(), timeout()) ->
    {ok, [{atom(), term()}]} | no_solution | {error, term()}.
query(Pid, GoalString, TimeoutMs) ->
    %% The gen_server:call timeout must exceed the proof's own timeout,
    %% or the call itself times out before handle_call gets a chance to
    %% reply with {error, timeout}.
    gen_server:call(Pid, {query, GoalString, TimeoutMs}, TimeoutMs + 1000).

stop(Pid) ->
    gen_server:stop(Pid).

%% gen_server callbacks

init([]) ->
    {ok, Erl0} = erlog:new(),
    %% Layer this project's own native (Erlang, not Prolog-shim) builtins
    %% on top of erlog's own — currently just sub_atom/5 — via erlog's own
    %% public extension hook (erlog:load/2 does exactly what erlog:new/2
    %% does internally to load erlog_bips/erlog_lib_lists/etc: fold
    %% Mod:load(Db) into the session's database). See
    %% symbolic_prolog_lib.erl for why this needs no fork of erlog.
    {ok, Erl} = erlog:load(symbolic_prolog_lib, Erl0),
    {ok, Erl}.

handle_call({consult, File}, _From, Erl) ->
    case erlog:consult(File, Erl) of
        {ok, Erl1} -> {reply, ok, Erl1};
        {error, Reason} -> {reply, {error, Reason}, Erl}
    end;
handle_call({consult_string, ProgramText}, _From, Erl) ->
    TmpFile = tmp_path(),
    try
        %% erlog's scanner needs the final clause's `.` followed by
        %% whitespace/newline — without a trailing newline, the last
        %% clause fails with {operator_expected, '.'} (confirmed by
        %% testing: same class of issue as ensure_terminated/1 below,
        %% for the same reason, just at end-of-file instead of
        %% end-of-string).
        ok = file:write_file(TmpFile, [ProgramText, $\n]),
        case erlog:consult(TmpFile, Erl) of
            {ok, Erl1} -> {reply, ok, Erl1};
            {error, Reason} -> {reply, {error, Reason}, Erl}
        end
    after
        file:delete(TmpFile)
    end;
handle_call({load_facts, Facts}, _From, Erl) ->
    Erl1 = lists:foldl(
        fun(Fact, ErlAcc) ->
            {{succeed, _}, ErlAcc1} = erlog:prove({asserta, Fact}, ErlAcc),
            ErlAcc1
        end, Erl, Facts),
    {reply, ok, Erl1};
handle_call({query, GoalString, TimeoutMs}, _From, Erl) ->
    case parse_goal(GoalString) of
        {ok, Goal} ->
            %% A gen_server:call timeout only stops the caller from
            %% waiting, not the callee from spinning — an untabled
            %% cyclic query would hang this session forever otherwise.
            %% Run the actual proof in its own monitored process and
            %% kill it on timeout. See docs/erlang-mcp-design.md §8.
            case prove_with_timeout(Goal, Erl, TimeoutMs) of
                {ok, {{succeed, Bindings}, Erl1}} -> {reply, {ok, Bindings}, Erl1};
                {ok, {fail, Erl1}} -> {reply, no_solution, Erl1};
                {ok, {{error, Reason}, Erl1}} -> {reply, {error, Reason}, Erl1};
                {ok, {{'EXIT', Reason}, Erl1}} -> {reply, {error, {exit, Reason}}, Erl1};
                timeout -> {reply, {error, timeout}, Erl};
                {worker_crashed, Reason} -> {reply, {error, {worker_crashed, Reason}}, Erl}
            end;
        {error, Reason} ->
            {reply, {error, Reason}, Erl}
    end.

handle_cast(_Msg, State) -> {noreply, State}.

terminate(_Reason, _State) -> ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

%% Internal

%% Proves Goal against Erl in a separate process, bounded by TimeoutMs.
%% The session's own state (Erl, in the caller/gen_server) is untouched
%% on timeout — a killed query doesn't advance or corrupt the session.
prove_with_timeout(Goal, Erl, TimeoutMs) ->
    Parent = self(),
    {Pid, Ref} = spawn_monitor(fun() -> Parent ! {self(), erlog:prove(Goal, Erl)} end),
    receive
        {Pid, Result} ->
            erlang:demonitor(Ref, [flush]),
            {ok, Result};
        {'DOWN', Ref, process, Pid, Reason} ->
            {worker_crashed, Reason}
    after TimeoutMs ->
        exit(Pid, kill),
        erlang:demonitor(Ref, [flush]),
        timeout
    end.

%% A bare goal typed at the CLI ("foo(X)") has no trailing terminator;
%% erlog_io:read_string/1 needs one, the same as a clause in a consulted
%% file would have.
-spec parse_goal(string()) -> {ok, term()} | {error, term()}.
parse_goal(GoalString) ->
    case erlog_io:read_string(ensure_terminated(GoalString)) of
        {ok, Term} -> {ok, Term};
        {error, Reason} -> {error, Reason}
    end.

ensure_terminated(Str) ->
    Trimmed = string:trim(Str),
    case lists:suffix(".", Trimmed) of
        true -> Trimmed;
        false -> Trimmed ++ "."
    end.

tmp_path() ->
    Name = io_lib:format("symbolic_consult_~p.pl", [erlang:unique_integer([positive])]),
    filename:join(tmp_dir(), lists:flatten(Name)).

tmp_dir() ->
    case os:getenv("TMPDIR") of
        false -> "/tmp";
        Dir -> Dir
    end.
