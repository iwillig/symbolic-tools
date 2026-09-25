%%% The MCP server's in-memory codebase cache.
%%%
%%% A single registered gen_server, but it can hold more than one cached
%%% codebase at once — one per PROJECT `parse` was pointed at, keyed by
%%% that project's own root (see below for what "project" means here).
%%% Still no on-disk persistence; the CLI's DETS path in
%%% symbolic_fact_store.erl is separate and untouched. The `parse` tool
%%% populates/replaces the entry for its own project (every other cached
%%% project is left exactly as it was); `query`/`overview` take an
%%% optional path to select which entry to use, defaulting to whichever
%%% one was most recently parsed successfully when omitted.
%%%
%%% Each cache entry is an erlog state (facts asserted in, ready to prove
%%% against) plus a small Meta summary computed at parse time. Queries are
%%% read-only: no entry is ever advanced or mutated by a query, and a
%%% timed-out / killed query leaves the whole cache exactly as it was.
%%%
%%% "Parse a project", not just "parse a directory" — with two
%%% deliberately different rules for finding one, depending on whether
%%% Dir was given:
%%%   - Dir omitted: discover a .symbolic/config.json by walking UP from
%%%     this server process's own cwd (see
%%%     symbolic_query:discover_rules_from_dir/1's identical shape for
%%%     .symbolic/rules.pl) — there's no explicit target to
%%%     second-guess here, so climbing to find the enclosing project is
%%%     exactly what this case is for.
%%%   - Dir given: only treated as a project if Dir ITSELF directly has
%%%     a .symbolic/config.json — no walking up its ancestors. An
%%%     explicit Dir is a commitment, not a hint; silently reinterpreting
%%%     it as "somewhere under some ancestor project" would mean a
%%%     typo'd or unrelated directory could get silently rescued into
%%%     scanning the wrong (enclosing) project entirely — confirmed
%%%     while building this. Otherwise Dir is scanned literally, the
%%%     original config-free behavior.
%%% Either way, when a config IS used, every path in its `paths` list is
%%% scanned and merged into ONE cache entry, keyed by that config's own
%%% project root — see symbolic_config.erl and
%%% symbolic_parse:scan_paths/1. Because the "Dir given" rule runs fresh
%%% per call, one running server naturally caches as many different
%%% projects as it's asked to: two `parse` calls naming two different
%%% projects' own root directories land in two different, both-still-
%%% queryable cache entries — see parse/1,2's own doc comment.
%%%
%%% See docs/erlang-mcp-design.md for the broader MCP architecture this
%%% refocuses.
-module(symbolic_codebase).
-behaviour(gen_server).
-include_lib("kernel/include/logger.hrl").

-export([start_link/0, parse/1, parse/2, query/1, query/2, query/3,
         overview/0, overview/1]).
-export([init/1, handle_call/3, handle_cast/2, terminate/2, code_change/3]).

-define(DEFAULT_LIMIT, 50).
-define(MAX_LIMIT, 1000).
-define(QUERY_TIMEOUT_MS, 10000).

%% API

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Discover and parse the PROJECT Dir belongs to (see this module's own
%% header comment), and (re)build that project's cache entry — every
%% other project already cached is left untouched. Returns the same
%% summary `overview` reports, so a parse immediately shows what landed,
%% including which project root it actually got cached under (`path` in
%% the returned map, which may differ from the Dir passed in — see
%% below) and, when a config drove the scan, `config_file`. Also
%% resolves and consults a `.symbolic/rules.pl` derived-predicate
%% library — auto-discovered by walking up from wherever the scan
%% actually happened (the config's project root, or Dir itself in the
%% no-config fallback) unless RulesOverride is given, in which case that
%% path is used outright — see symbolic_query:discover_rules_from_dir/1.
%%
%% Dir omitted -> a .symbolic/config.json is discovered by walking UP
%% from this server process's own cwd; nothing found there is an error
%% (there's nothing else to scan). Dir given -> used as a project ONLY
%% if Dir ITSELF directly has a .symbolic/config.json (no walking up its
%% ancestors — see this module's header comment for why); found -> every
%% path in that config's `paths` list is scanned and merged into one
%% cache entry, keyed by that project root (symbolic_parse:scan_paths/1,
%% symbolic_config.erl). Not found -> Dir is scanned directly as one
%% plain directory, exactly the original config-free behavior.
-spec parse(file:name() | undefined) -> {ok, map()} | {error, term()}.
parse(Dir) ->
    parse(Dir, undefined).

-spec parse(file:name() | undefined, file:filename() | undefined) -> {ok, map()} | {error, term()}.
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

%% Two deliberately DIFFERENT rules for "which project", not one —
%% see this module's header comment and parse/2's own doc comment:
%%   - Dir omitted: discover by WALKING UP from this server's own cwd
%%     (same shape as .symbolic/rules.pl discovery) — there's no
%%     explicit target to second-guess, so climbing to find the
%%     enclosing project is exactly the convenience this case is for.
%%   - Dir given: only treated as a project if Dir ITSELF directly has
%%     a .symbolic/config.json — no walking up. Walking up from an
%%     EXPLICIT Dir would silently reinterpret a typo'd or unrelated
%%     directory as some ancestor's unrelated project (confirmed while
%%     building this: parsing a nonexistent directory nested under this
%%     very project would otherwise silently "succeed" by discovering
%%     THIS project's own config instead of erroring). Otherwise Dir is
%%     scanned literally, exactly the original config-free behavior.
%% Every branch still routes every error through {reply, {error,_},
%% State} (State unchanged), so a bad rules file or a missing directory
%% never disturbs a previously cached project. The whole thing runs
%% inside safely/2 (issue #4's structural fix — see its own doc comment):
%% extract_file_timed/1 (symbolic_parse.erl) already catches the single
%% most likely crash site, a bad literal inside one file, but this is
%% the outer backstop for anything else that might crash during a scan.
handle_call({parse, undefined, RulesOverride}, _From, State) ->
    safely(fun() ->
        StartMs = erlang:monotonic_time(millisecond),
        case discovery_start_dir(undefined) of
            {ok, Cwd} ->
                case symbolic_config:discover(Cwd) of
                    undefined -> {reply, {error, {no_config_found, Cwd}}, State};
                    ConfigPath -> parse_from_config(ConfigPath, RulesOverride, StartMs, State)
                end;
            {error, Reason} -> {reply, {error, Reason}, State}
        end
    end, State);
handle_call({parse, Dir, RulesOverride}, _From, State) ->
    safely(fun() ->
        StartMs = erlang:monotonic_time(millisecond),
        case own_config(Dir) of
            undefined -> finish_parse(symbolic_parse:scan(Dir), normalize_dir(Dir), RulesOverride, StartMs, State, #{});
            ConfigPath -> parse_from_config(ConfigPath, RulesOverride, StartMs, State)
        end
    end, State);

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

%% safely(Fun, State) -> {reply, ..., NewState}.
%%  Issue #4's structural fix: no crash anywhere inside a `parse` call —
%%  not just the specific numeric-literal one that issue reported, any
%%  future one in symbolic_gitignore/symbolic_config/ts_extract/etc. too
%%  — is allowed to kill THIS shared gen_server process. A crash inside
%%  a `handle_call` callback doesn't just fail that one call: it crashes
%%  the whole process, taking every OTHER already-cached, unrelated
%%  project's entry down with it (confirmed against the real report:
%%  four unrelated directories, already parsed and cached successfully,
%%  all started failing with {noproc,...} after one crashed parse
%%  elsewhere, until the MCP client reconnected). State is returned
%%  UNCHANGED on a caught crash — the same "leave every previously
%%  cached project exactly as it was" guarantee every other error branch
%%  here already gives, just covering the crash case too now.
safely(Fun, State) ->
    try Fun()
    catch
        Class:Reason:ST ->
            ?LOG_ERROR("parse: crashed ~p:~p, leaving the cache untouched~n~p",
                       [Class, Reason, ST]),
            {reply, {error, {parse_crashed, {Class, Reason}}}, State}
    end.

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
    {ok, Erl0} = erlog:new(),
    %% Same native-builtin layering prolog_session:init/1 does — see
    %% symbolic_prolog_lib.erl. Both erlog session constructors in this
    %% codebase need it independently; erlog:new/0 itself has no way to
    %% take extra library modules.
    {ok, Erl} = erlog:load(symbolic_prolog_lib, Erl0),
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

%% discovery_start_dir(undefined) -> {ok, file:filename()} | {error, term()}.
%%  Only ever called with `undefined` (see handle_call({parse,...}) —
%%  an explicit Dir never walks up, so it never needs a "start dir" of
%%  its own); this server process's own cwd is the one and only start
%%  point for the "no Dir given" case.
discovery_start_dir(undefined) ->
    case file:get_cwd() of
        {ok, Cwd} -> {ok, Cwd};
        {error, Reason} -> {error, {cannot_get_cwd, Reason}}
    end.

%% own_config(Dir) -> file:filename() | undefined.
%%  Does Dir ITSELF (not any ancestor) directly have a
%%  .symbolic/config.json? Deliberately narrower than
%%  symbolic_config:discover/1's walk-up — see handle_call({parse,
%%  Dir,...})'s own comment for why an explicit Dir must not walk up.
own_config(Dir) ->
    Candidate = filename:join([Dir, ".symbolic", "config.json"]),
    case filelib:is_regular(Candidate) of
        true -> Candidate;
        false -> undefined
    end.

%% parse_from_config(ConfigPath, RulesOverride, StartMs, State) ->
%%  {reply, ..., NewState}.
%%  A .symbolic/config.json was found — read and validate it, then merge
%%  every one of its `paths` into a single cache entry keyed by the
%%  config's own project root (never Dir itself, which may only be a
%%  subdirectory of it).
parse_from_config(ConfigPath, RulesOverride, StartMs, State) ->
    case symbolic_config:read(ConfigPath) of
        {ok, Paths} ->
            ProjectRoot = symbolic_config:project_root(ConfigPath),
            finish_parse(symbolic_parse:scan_paths(Paths), ProjectRoot,
                RulesOverride, StartMs, State, #{config_file => ConfigPath});
        {error, Reason} -> {reply, {error, Reason}, State}
    end.

%% finish_parse(ScanResult, CacheKey, RulesOverride, StartMs, State, ExtraMeta)
%%  -> {reply, ..., NewState}.
%%  The shared tail of both `parse` variants above: given a
%%  scan/1-or-scan_paths/1 result and the (already-absolute) key to use
%%  for both caching and rules discovery, build the erlog state, compute
%%  the summary (merging in ExtraMeta — e.g. `config_file` for the
%%  config-driven variant), and cache it. Every "leave State untouched on
%%  error" guarantee handle_call({parse,...}) documented before this was
%%  factored out still holds, since both callers still route every error
%%  branch through the same {reply, {error,_}, State} (State unchanged).
finish_parse({ok, {Files, Facts}}, CacheKey, RulesOverride, StartMs, State, ExtraMeta) ->
    RulesPath = resolve_rules(CacheKey, RulesOverride),
    case build_state(Facts, RulesPath) of
        {ok, Erl} ->
            ElapsedMs = erlang:monotonic_time(millisecond) - StartMs,
            Meta = maps:merge(compute_meta(Files, Facts, RulesPath, CacheKey, ElapsedMs), ExtraMeta),
            Caches = maps:get(caches, State),
            NewState = State#{
                caches => Caches#{CacheKey => #{erl => Erl, meta => Meta}},
                current => CacheKey},
            {reply, {ok, Meta}, NewState};
        {error, Reason} ->
            %% A bad rules file fails the whole parse rather than caching
            %% a facts-only session silently missing the library the
            %% caller asked for — State is untouched (this key's previous
            %% entry, every other key's entry, and `current` all stay
            %% exactly as they were), same as a query timeout/crash
            %% leaves it untouched.
            {reply, {error, {rules_error, RulesPath, Reason}}, State}
    end;
finish_parse({error, Reason}, _CacheKey, _RulesOverride, _StartMs, State, _ExtraMeta) ->
    {reply, {error, Reason}, State}.

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
