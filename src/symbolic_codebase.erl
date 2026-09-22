%%% The MCP server's in-memory codebase cache.
%%%
%%% A single registered gen_server holding the extracted fact base for ONE
%%% codebase at a time (a deliberate, "for now" scope — no multi-session
%%% registry, no on-disk persistence; the CLI's DETS path in
%%% symbolic_fact_store.erl is separate and untouched). The `parse` tool
%%% populates it, `query` proves goals against it, `overview` reports on it.
%%%
%%% The fact base lives as an erlog state (facts asserted in, ready to
%%% prove against) plus a small Meta summary computed at parse time. Queries
%%% are read-only: the state is never advanced or mutated by a query, and a
%%% timed-out / killed query leaves it exactly as it was.
%%%
%%% See docs/erlang-mcp-design.md for the broader MCP architecture this
%%% refocuses.
-module(symbolic_codebase).
-behaviour(gen_server).

-export([start_link/0, parse/1, query/1, query/2, overview/0]).
-export([init/1, handle_call/3, handle_cast/2, terminate/2, code_change/3]).

-define(DEFAULT_LIMIT, 50).
-define(MAX_LIMIT, 1000).
-define(QUERY_TIMEOUT_MS, 10000).

%% API

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Scan Dir, extract facts, and (re)build the in-memory cache. Returns the
%% same summary `overview` reports, so a parse immediately shows what landed.
-spec parse(file:name()) -> {ok, map()} | {error, term()}.
parse(Dir) ->
    gen_server:call(?MODULE, {parse, Dir}, infinity).

%% Prove Goal against the cache, returning ALL solutions (capped at Limit,
%% default ?DEFAULT_LIMIT). Returns {ok, [Solutions]} or
%% {truncated, [Solutions]} (cap hit) or {error, Reason}.
-spec query(string()) -> query_result().
query(Goal) ->
    query(Goal, ?DEFAULT_LIMIT).

-spec query(string(), non_neg_integer()) -> query_result().
query(Goal, Limit) ->
    %% gen_server:call timeout must exceed the proof's own timeout, so the
    %% worker gets a chance to reply {error, timeout} rather than the call
    %% itself timing out first (same reasoning as prolog_session:query/3).
    gen_server:call(?MODULE, {query, Goal, Limit}, ?QUERY_TIMEOUT_MS + 1000).

-type query_result() ::
    {ok, [Solutions :: [{atom(), term()}]]}
    | {truncated, [Solutions :: [{atom(), term()}]]}
    | {error, term()}.

%% The current state of the cache — see compute_meta/2 for the shape.
-spec overview() -> {not_parsed, #{loaded => false}} | {ok, map()}.
overview() ->
    gen_server:call(?MODULE, overview).

%% gen_server callbacks

init([]) ->
    {ok, #{erl => undefined, meta => undefined}}.

handle_call({parse, Dir}, _From, State) ->
    case symbolic_parse:scan(Dir) of
        {ok, {Files, Facts}} ->
            Erl = build_state(Facts),
            Meta = compute_meta(Files, Facts),
            {reply, {ok, Meta}, State#{erl => Erl, meta => Meta}};
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end;

handle_call({query, Goal, Limit}, _From, State) ->
    case maps:get(erl, State) of
        undefined ->
            {reply, {error, not_parsed}, State};
        Erl ->
            case parse_goal(Goal) of
                {ok, ParsedGoal} ->
                    case prove_all_with_timeout(ParsedGoal, Erl, clamp_limit(Limit)) of
                        {ok, Solutions} -> {reply, {ok, Solutions}, State};
                        {truncated, Solutions} -> {reply, {truncated, Solutions}, State};
                        {error, Reason} -> {reply, {error, Reason}, State}
                    end;
                {error, Reason} ->
                    {reply, {error, Reason}, State}
            end
    end;

handle_call(overview, _From, State) ->
    case maps:get(meta, State) of
        undefined -> {reply, {not_parsed, #{loaded => false}}, State};
        Meta -> {reply, {ok, Meta}, State}
    end.

handle_cast(_Msg, State) -> {noreply, State}.

terminate(_Reason, _State) -> ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

%% Internal

%% A fresh erlog state with every fact asserted. Same asserta pattern as
%% prolog_session:load_facts/2's handle_call (asserta is O(1); facts have no
%% order-dependent meaning, only backtracking order).
build_state(Facts) ->
    {ok, Erl} = erlog:new(),
    lists:foldl(
        fun(Fact, ErlAcc) ->
            {{succeed, _}, ErlAcc1} = erlog:prove({asserta, Fact}, ErlAcc),
            ErlAcc1
        end, Erl, Facts).

compute_meta(Files, Facts) ->
    #{
        loaded => true,
        files => length(Files),
        file_list => Files,
        languages => languages_from_files(Files),
        facts_by_predicate => counts_by_predicate(Facts),
        total_facts => length(Facts)
    }.

%% filename:extension/1 returns the dotted form (".ts", ".erl", ...).
languages_from_files(Files) ->
    lists:usort([language_from_ext(filename:extension(F)) || F <- Files]).

language_from_ext(".erl") -> "erlang";
language_from_ext(".ts") -> "typescript";
language_from_ext(".md") -> "markdown";
language_from_ext(".toml") -> "toml";
language_from_ext(".json") -> "json";
language_from_ext(".sh") -> "bash";
language_from_ext(".bash") -> "bash";
language_from_ext(_Other) -> "unknown".

%% Single-pass group-by of each fact's functor (element 1).
counts_by_predicate(Facts) ->
    lists:foldl(
        fun(Fact, Acc) ->
            F = element(1, Fact),
            %% update_with/4: third arg is the default VALUE (not a fun) used
            %% when the key is absent; the fun updates an existing count.
            maps:update_with(F, fun(C) -> C + 1 end, 1, Acc)
        end, #{}, Facts).

%% Prove Goal, collecting up to Max solutions, in a spawned+monitored worker
%% killed on timeout — the same fault-isolation shape as
%% prolog_session:prove_with_timeout/3, but looping over next_solution/1.
%% The cache's own Erl state is passed to the worker by copy and never
%% rebound from its result, so a timeout/crash leaves it untouched.
prove_all_with_timeout(Goal, Erl, Max) ->
    Parent = self(),
    {Pid, Ref} = spawn_monitor(fun() ->
        Parent ! {self(), prove_all(Goal, Erl, Max)}
    end),
    receive
        {Pid, Result} ->
            erlang:demonitor(Ref, [flush]),
            Result;
        {'DOWN', Ref, process, Pid, Reason} ->
            {error, {worker_crashed, Reason}}
    after ?QUERY_TIMEOUT_MS ->
        exit(Pid, kill),
        erlang:demonitor(Ref, [flush]),
        {error, timeout}
    end.

%% erlog:prove/2 -> {{succeed, Bs}, Erl1} | {fail, Erl1} | {{error, R}, Erl1}
%% erlog:next_solution/1 takes the state the previous step returned and
%% yields the same shapes for the next answer.
prove_all(Goal, Erl, Max) ->
    case erlog:prove(Goal, Erl) of
        {{succeed, First}, Erl1} -> more_solutions(Erl1, [First], Max);
        {fail, _Erl1} -> {ok, []};
        {{error, Reason}, _Erl1} -> {error, Reason};
        {{'EXIT', Reason}, _Erl1} -> {error, {exit, Reason}}
    end.

more_solutions(_Erl, Acc, Max) when length(Acc) >= Max ->
    {truncated, lists:reverse(Acc)};
more_solutions(Erl, Acc, Max) ->
    case erlog:next_solution(Erl) of
        {{succeed, Bs}, Erl1} -> more_solutions(Erl1, [Bs | Acc], Max);
        {fail, _Erl1} -> {ok, lists:reverse(Acc)};
        {{error, Reason}, _Erl1} -> {error, Reason};
        {{'EXIT', Reason}, _Erl1} -> {error, {exit, Reason}}
    end.

clamp_limit(L) when is_integer(L), L > 0 -> min(L, ?MAX_LIMIT);
clamp_limit(_Bad) -> ?DEFAULT_LIMIT.

%% Parse a goal string into a Prolog term before proving — erlog:prove/2 takes
%% a goal term, not a string (passing a string yields type_error(callable)).
%% Same shape as prolog_session:parse_goal/1: a bare goal typed at the CLI has
%% no trailing '.', and erlog_io:read_string/1 needs one.
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
