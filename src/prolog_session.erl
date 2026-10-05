%%% One Prolog (erlog) session, held in a gen_server.
%%%
%%% Wraps a single erlog state so callers never touch the `#erlog{}`
%%% record directly. See docs/erlang-mcp-design.md.
-module(prolog_session).
-behaviour(gen_server).

-export([start_link/0, consult/2, consult_string/2, load_facts/2, query/2, query/3, stop/1]).
-export([init/1, handle_call/3, handle_cast/2, terminate/2, code_change/3]).

-define(QUERY_TIMEOUT_MS, 5000).

%% A fresh erlog state in a gen_server. The state IS the Erl struct
%% — one session's database, consulted rules and asserted facts all
%% live there, so two sessions never share a rule or a fact.
start_link() ->
    gen_server:start_link(?MODULE, [], []).

-spec consult(pid(), file:filename()) -> ok | {error, term()}.
%% Consult a .pl rules file INTO this session's own state. Rules
%% asserted here are session-private: erlog keeps them in the state
%% struct, not a global — which is why every parsed project gets its
%% own copy of the shared .symbolic/rules.pl (see
%% symbolic_codebase:finish_parse/6).
consult(Pid, File) ->
    gen_server:call(Pid, {consult, File}).

%% Load program text directly (an MCP client sends Prolog source as a
%% string, not a file path — unlike the CLI's `-file`).
-spec consult_string(pid(), string() | binary()) -> ok | {error, term()}.
%% Consult Prolog SOURCE TEXT (not a file) — the rules-override path:
%% an MCP client hands `rules` as a string, and the gen_server's
%% handle_clause writes it to a temp file (erlog's consult/2 is
%% file-only) with the trailing newline erlog's scanner needs, then
%% deletes it.
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
%% Assert a whole fact list into the session, front-loaded through
%% `asserta` (order-irrelevant for pure facts, O(1) per call — see the
%% longer comment above for why assertz would have been O(N^2) here).
%% This is how a parse's DETS facts become queryable.
load_facts(Pid, Facts) ->
    gen_server:call(Pid, {load_facts, Facts}, infinity).

-spec query(pid(), string()) ->
    {ok, [{atom(), term()}]} | no_solution | {error, term()}.
%% Prove GoalString against this session, ?QUERY_TIMEOUT_MS budget
%% (5s) — the timeout kills a runaway proof without killing the session
%% or advancing its state. Bindings come back as {atom(), term()} pairs.
query(Pid, GoalString) ->
    query(Pid, GoalString, ?QUERY_TIMEOUT_MS).

%% Same as query/2, with an explicit proof timeout instead of the
%% ?QUERY_TIMEOUT_MS default — mainly so tests can use a short timeout
%% instead of waiting out the real one.
-spec query(pid(), string(), timeout()) ->
    {ok, [{atom(), term()}]} | no_solution | {error, term()}.
%% query/2 with an explicit proof timeout — mainly so tests use a
%% short budget instead of waiting out the real one.
query(Pid, GoalString, TimeoutMs) ->
    %% The gen_server:call timeout must exceed the proof's own timeout,
    %% or the call itself times out before handle_call gets a chance to
    %% reply with {error, timeout}.
    gen_server:call(Pid, {query, GoalString, TimeoutMs}, TimeoutMs + 1000).

%% gen_server:stop/1 — the polite shutdown; used by every
%% run_result-style wrapper that owns its session.
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

%% gen_server dispatch: one clause per tool call. Every clause pairs
%% its reply with the session state it leaves behind — only a
%% successful proof/load advances Erl; every error branch returns it
%% unchanged. See the individual clauses' own comments.
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
            %% waiting, not the callee from spinning — see
            %% prove_reply/3 below and docs/erlang-mcp-design.md §8.
            {Reply, Erl1} = prove_reply(Goal, Erl, TimeoutMs),
            {reply, Reply, Erl1};
        {error, Reason} ->
            {reply, {error, Reason}, Erl}
    end.

%% Standard OTP no-op: nothing in this module uses casts.
handle_cast(_Msg, State) -> {noreply, State}.

%% The proof outcome ladder, extracted from handle_call/3 so the
%% dispatcher reads as dispatch: one line per outcome, no triple-nested
%% case. Every outcome pairs with the session state it leaves behind —
%% a successful proof advances Erl to Erl1; every failure (including
%% timeout and a killed worker) returns the state UNCHANGED, the
%% "a killed query never advances or corrupts the session" guarantee
%% prove_with_timeout/3 already makes (§8).
prove_reply(Goal, Erl, TimeoutMs) ->
    case prove_with_timeout(Goal, Erl, TimeoutMs) of
        {ok, {{succeed, Bindings}, Erl1}} -> {{ok, Bindings}, Erl1};
        {ok, {fail, Erl1}} -> {no_solution, Erl1};
        {ok, {{error, Reason}, Erl1}} -> {{error, Reason}, Erl1};
        {ok, {{'EXIT', Reason}, Erl1}} -> {{error, {exit, Reason}}, Erl1};
        timeout -> {{error, timeout}, Erl};
        {worker_crashed, Reason} -> {{error, {worker_crashed, Reason}}, Erl}
    end.

%% Standard OTP no-ops: the session state is one immutable struct
%% (copied per call, never rebound from a failed proof), so there is
%% nothing to clean up or migrate.
%% Standard OTP no-ops: the session state is one immutable struct
%% (copied per call, never rebound from a failed proof), so there is
%% nothing to clean up or migrate.
terminate(_Reason, _State) -> ok.

%% (Same no-op block as terminate/2 above.)
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
