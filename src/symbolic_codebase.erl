%%% The MCP server's in-memory codebase cache.
%%%
%%% A single registered gen_server, but it can hold more than one cached
%%% codebase at once — one per directory `parse` was pointed at, keyed by
%%% that directory's normalized (absolute) path. Still no on-disk
%%% persistence; the CLI's DETS path in symbolic_fact_store.erl is separate
%%% and untouched. The `parse` tool populates/replaces the entry for its
%%% own directory (every other cached directory is left exactly as it
%%% was); `query`/`overview` take an optional directory to select which
%%% entry to use, defaulting to whichever directory was most recently
%%% parsed successfully when omitted — so existing no-argument callers see
%%% the same behavior as the single-codebase design this replaces.
%%%
%%% Each cache entry is an erlog state (facts asserted in, ready to prove
%%% against) plus a small Meta summary computed at parse time. Queries are
%%% read-only: no entry is ever advanced or mutated by a query, and a
%%% timed-out / killed query leaves the whole cache exactly as it was.
%%%
%%% See docs/erlang-mcp-design.md for the broader MCP architecture this
%%% refocuses.
-module(symbolic_codebase).
-behaviour(gen_server).

-export([start_link/0, parse/1, parse/2, query/1, query/2, query/3,
         overview/0, overview/1]).
-export([init/1, handle_call/3, handle_cast/2, terminate/2, code_change/3]).

-define(DEFAULT_LIMIT, 50).
-define(MAX_LIMIT, 1000).
-define(QUERY_TIMEOUT_MS, 10000).

%% API

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Scan Dir, extract facts, and (re)build that directory's cache entry —
%% every other directory already cached is left untouched. Returns the
%% same summary `overview` reports, so a parse immediately shows what
%% landed. Also resolves and consults a `.symbolic/rules.pl` derived-
%% predicate library, same as the CLI's `symbolic query` does for a fact
%% database: auto-discovered by walking up from Dir (then falling back to
%% the server's own cwd) unless RulesOverride is given, in which case that
%% path is used outright — see symbolic_query:discover_rules_from_dir/1.
-spec parse(file:name()) -> {ok, map()} | {error, term()}.
parse(Dir) ->
    parse(Dir, undefined).

-spec parse(file:name(), file:filename() | undefined) -> {ok, map()} | {error, term()}.
parse(Dir, RulesOverride) ->
    gen_server:call(?MODULE, {parse, Dir, RulesOverride}, infinity).

%% Prove Goal against a cached directory's fact base, returning ALL
%% solutions (capped at Limit, default ?DEFAULT_LIMIT). Returns
%% {ok, [Solutions]} or {truncated, [Solutions]} (cap hit) or
%% {error, Reason}.
-spec query(string()) -> query_result().
query(Goal) ->
    query(Goal, ?DEFAULT_LIMIT, undefined).

-spec query(string(), non_neg_integer()) -> query_result().
query(Goal, Limit) ->
    query(Goal, Limit, undefined).

%% Path selects which cached directory to query, by the same string
%% `parse` was given for it — undefined means "whichever directory was
%% most recently parsed successfully". {error, not_parsed} means nothing
%% has ever been parsed at all; {error, {unknown_path, Path}} means Path
%% itself was never (successfully) parsed, distinct from that.
-spec query(string(), non_neg_integer(), file:name() | undefined) -> query_result().
query(Goal, Limit, Path) ->
    %% gen_server:call timeout must exceed the proof's own timeout, so the
    %% worker gets a chance to reply {error, timeout} rather than the call
    %% itself timing out first (same reasoning as prolog_session:query/3).
    gen_server:call(?MODULE, {query, Goal, Limit, Path}, ?QUERY_TIMEOUT_MS + 1000).

-type query_result() ::
    {ok, [Solutions :: [{atom(), term()}]]}
    | {truncated, [Solutions :: [{atom(), term()}]]}
    | {error, term()}.

%% The current state of the most-recently-parsed cache entry — see
%% compute_meta/5 for the shape.
-spec overview() -> {not_parsed, #{loaded => false}} | {ok, map()}.
overview() ->
    overview(undefined).

%% Same as overview/0, but Path selects which cached directory to report
%% on (same meaning as query/3's Path). An explicit Path that was never
%% parsed reports {error, {unknown_path, Path}} rather than the
%% "nothing at all parsed yet" {not_parsed, ...} shape.
-spec overview(file:name() | undefined) ->
    {not_parsed, #{loaded => false}} | {ok, map()} | {error, term()}.
overview(Path) ->
    gen_server:call(?MODULE, {overview, Path}).

%% gen_server callbacks

%% caches: NormalizedDir -> #{erl => ErlState, meta => Meta}.
%% current: the NormalizedDir most recently parsed successfully, or
%% undefined if nothing has been parsed yet — what query/3 and
%% overview/1 fall back to when their Path argument is undefined.
init([]) ->
    {ok, #{caches => #{}, current => undefined}}.

handle_call({parse, Dir, RulesOverride}, _From, State) ->
    StartMs = erlang:monotonic_time(millisecond),
    case symbolic_parse:scan(Dir) of
        {ok, {Files, Facts}} ->
            RulesPath = resolve_rules(Dir, RulesOverride),
            case build_state(Facts, RulesPath) of
                {ok, Erl} ->
                    ElapsedMs = erlang:monotonic_time(millisecond) - StartMs,
                    NormDir = normalize_dir(Dir),
                    Meta = compute_meta(Files, Facts, RulesPath, NormDir, ElapsedMs),
                    Caches = maps:get(caches, State),
                    NewState = State#{
                        caches => Caches#{NormDir => #{erl => Erl, meta => Meta}},
                        current => NormDir},
                    {reply, {ok, Meta}, NewState};
                {error, Reason} ->
                    %% A bad rules file fails the whole parse rather than
                    %% caching a facts-only session silently missing the
                    %% library the caller asked for — State is untouched
                    %% (this directory's previous entry, every other
                    %% directory's entry, and `current` all stay exactly
                    %% as they were), same as a query timeout/crash leaves
                    %% it untouched.
                    {reply, {error, {rules_error, RulesPath, Reason}}, State}
            end;
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end;

handle_call({query, Goal, Limit, Path}, _From, State) ->
    case resolve_cache_entry(Path, State) of
        {error, Reason} ->
            {reply, {error, Reason}, State};
        {ok, #{erl := Erl}} ->
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

handle_call({overview, Path}, _From, State) ->
    case resolve_cache_entry(Path, State) of
        {error, not_parsed} -> {reply, {not_parsed, #{loaded => false}}, State};
        {error, Reason} -> {reply, {error, Reason}, State};
        {ok, #{meta := Meta}} -> {reply, {ok, Meta}, State}
    end.

handle_cast(_Msg, State) -> {noreply, State}.

terminate(_Reason, _State) -> ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

%% Internal

%% Look up which cache entry Path (or, if undefined, `current`) names.
%% {error, not_parsed} only ever means "nothing has been parsed at all
%% yet" (Path undefined, current undefined) — an explicit Path that just
%% isn't cached is the distinct {error, {unknown_path, Path}}, so a caller
%% can tell "you haven't parsed anything" apart from "you asked for a
%% directory you never parsed".
resolve_cache_entry(undefined, State) ->
    case maps:get(current, State) of
        undefined -> {error, not_parsed};
        Dir -> {ok, maps:get(Dir, maps:get(caches, State))}
    end;
resolve_cache_entry(Path, State) ->
    NormDir = normalize_dir(Path),
    case maps:find(NormDir, maps:get(caches, State)) of
        {ok, Entry} -> {ok, Entry};
        error -> {error, {unknown_path, Path}}
    end.

%% The cache key: Dir made absolute (relative to this process's cwd) so
%% "src" and an equivalent absolute path parsed in two different calls
%% land in the same entry instead of silently doubling up.
%% filename:absname/1 already strips any trailing "/" on its own
%% (confirmed: filename:absname("test/fixtures/") =:=
%% filename:absname("test/fixtures")), so there's nothing extra to do for
%% that case — no need to duplicate work it already does. Doesn't resolve
%% symlinks or collapse ".." segments beyond what filename:absname/1
%% itself does — good enough for "the same string names the same entry",
%% not a general path-canonicalization utility.
normalize_dir(Dir) ->
    filename:absname(Dir).

%% A fresh erlog state with every fact asserted. Same asserta pattern as
%% prolog_session:load_facts/2's handle_call (asserta is O(1); facts have no
%% order-dependent meaning, only backtracking order). When RulesPath is
%% resolved, the same derived-predicate library the CLI consults
%% (prolog_session:consult/2) is consulted here too, via the same
%% erlog:consult/2 primitive, so `undefined`/RulesPath's absence is the
%% only difference from a facts-only cache.
build_state(Facts, RulesPath) ->
    {ok, Erl} = erlog:new(),
    Erl1 = lists:foldl(
        fun(Fact, ErlAcc) ->
            {{succeed, _}, ErlAcc1} = erlog:prove({asserta, Fact}, ErlAcc),
            ErlAcc1
        end, Erl, Facts),
    consult_rules(Erl1, RulesPath).

consult_rules(Erl, undefined) -> {ok, Erl};
consult_rules(Erl, RulesPath) -> erlog:consult(RulesPath, Erl).

%% Explicit RulesOverride wins outright (mirrors the CLI's -rules, which
%% is never second-guessed by discovery); otherwise auto-discover by
%% walking up from Dir, then the server's own cwd — see
%% symbolic_query:discover_rules_from_dir/1. There's no MCP equivalent of
%% -no-rules yet (a persistent cache has less need for a one-off
%% "consult nothing" switch); pass an explicit RulesOverride if that's
%% ever needed.
resolve_rules(_Dir, RulesOverride) when RulesOverride =/= undefined -> RulesOverride;
resolve_rules(Dir, undefined) -> symbolic_query:discover_rules_from_dir(Dir).

compute_meta(Files, Facts, RulesPath, NormDir, ElapsedMs) ->
    #{
        loaded => true,
        path => NormDir,
        parse_ms => ElapsedMs,
        files => length(Files),
        file_list => Files,
        languages => languages_from_files(Files),
        facts_by_predicate => counts_by_predicate(Facts),
        total_facts => length(Facts),
        rules_file => RulesPath
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
