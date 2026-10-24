%%% The MCP server's in-memory codebase cache.
%%%
%%% A single registered gen_server that can hold more than one cached
%%% codebase at once — one per PROJECT `parse` was pointed at, keyed by
%%% that project's own root. A project's optional config database is
%%% persisted to DETS on parse. The MCP server restores it at startup,
%%% then runs a background differential scan while queries use the saved
%%% snapshot. `query`/`overview` take an optional path to select an
%%% entry, defaulting to the most recently published project.
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

-export([start_link/0, start_link/1, parse/1, parse/2, parse_config/2, query/1, query/2, query/3,
    ask/2, facts/1, overview/0, overview/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(DEFAULT_LIMIT, 50).
-define(MAX_LIMIT, 1000).
-define(QUERY_TIMEOUT_MS, 10000).

%% API

%% The shared cache gen_server: THE long-lived state of the MCP
%% server, a map from normalized absolute directory to its parsed
%% project (erlog state + meta). Multiple projects coexist and stay
%% independently queryable; a crash in one parse never disturbs the
%% others (safely/2).
start_link() -> start_link(#{}).

%% Only the MCP entry point opts into saved-snapshot hydration and
%% background refresh; callers of start_link/0 keep their explicit-parse
%% lifecycle.
start_link(Options) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [Options], []).

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
%% Parse a directory into the cache, .symbolic/rules.pl auto-discovered.
%% Dir omitted: discover the enclosing project from this server's own
%% cwd; Dir given: a project only if Dir itself has a
%% .symbolic/config.json, otherwise scanned literally. Returns the
%% same summary `overview` reports. See the longer prose above and
%% parse/2 below for the full shape.
parse(Dir) ->
    parse(Dir, undefined).

-spec parse(file:name() | undefined, file:filename() | undefined) -> {ok, map()} | {error, term()}.
%% Same as parse/1 with an explicit rules library: RulesOverride
%% replaces .symbolic/rules.pl discovery outright (undefined = discover,
%% which is parse/1's behavior). A rules file that fails to consult
%% fails the whole parse and leaves the previous cache untouched.
parse(Dir, RulesOverride) ->
    gen_server:call(?MODULE, {parse, Dir, RulesOverride}, infinity).

-spec parse_config(file:filename(), file:filename() | undefined) -> {ok, map()} | {error, term()}.
%% Parse a project selected by an EXPLICIT .symbolic/config.json path (the
%% MCP `parse` tool's `config_file` target) — the same scan/persist tail as
%% parse/1's server-cwd discovery, but the config file is named rather than
%% discovered by walking up from this server's own working directory. The
%% config is still validated (paths required, database optional, typescript
%% settings read), and every error leaves the previous cache untouched.
parse_config(ConfigPath, RulesOverride) ->
    gen_server:call(?MODULE, {parse_config, ConfigPath, RulesOverride}, infinity).

%% Prove Goal against a cached directory's fact base, returning ALL
%% solutions (capped at Limit, default ?DEFAULT_LIMIT). Returns
%% {ok, [Solutions]} or {truncated, [Solutions]} (cap hit) or
%% {error, Reason}.
-spec query(string()) -> query_result().
%% Prove Goal against the most recently parsed project's fact base
%% (default limit, default path) — the MCP `query` tool's no-path shape.
query(Goal) ->
    query(Goal, ?DEFAULT_LIMIT, undefined).

-spec query(string(), non_neg_integer()) -> query_result().
%% Prove Goal against the most recently parsed project, capped at Limit
%% solutions (default ?DEFAULT_LIMIT via query/1).
query(Goal, Limit) ->
    query(Goal, Limit, undefined).

%% Path selects which cached directory to query, by the same string
%% `parse` was given for it — undefined means "whichever directory was
%% most recently parsed successfully". {error, not_parsed} means nothing
%% has ever been parsed at all; {error, {unknown_path, Path}} means Path
%% itself was never (successfully) parsed, distinct from that.
-spec query(string(), non_neg_integer(), file:name() | undefined) -> query_result().
%% Path selects which cached directory to query, by the same string
%% `parse` was given for it — undefined means "whichever directory was
%% most recently parsed successfully". {error, not_parsed} means nothing
%% has ever been parsed at all; {error, {unknown_path, Path}} means
%% Path itself was never (successfully) parsed, distinct from that.
query(Goal, Limit, Path) ->
    %% gen_server:call timeout must exceed the proof's own timeout, so the
    %% worker gets a chance to reply {error, timeout} rather than the call
    %% itself timing out first (same reasoning as prolog_session:query/3).
    gen_server:call(?MODULE, {query, Goal, Limit, Path}, ?QUERY_TIMEOUT_MS + 1000).

%% Answer a bounded English question against a cached directory's fact
%% base — the MCP `ask` tool's back end. Runs symbolic_ask's whole
%% pipeline (parse, gate, prove, shape) in its own one-shot prolog_session
%% built from the cache entry's raw fact list, never on the cached erlog
%% state itself, so a question can never advance or corrupt the cache —
%% the same isolation discipline query's timeout handling carries.
-spec ask(string(), file:name() | undefined) ->
    {ok, map()} | unrecognized | {error, term()}.
ask(Question, Path) ->
    gen_server:call(?MODULE, {ask, Question, Path}, ?QUERY_TIMEOUT_MS + 1000).

%% Raw facts for read-only cache consumers such as MCP full-text search.
-spec facts(file:name() | undefined) -> {ok, [tuple()]} | {error, term()}.
facts(Path) ->
    gen_server:call(?MODULE, {facts, Path}).

-type query_result() ::
    {ok, [Solutions :: [{atom(), term()}]]}
    | {truncated, [Solutions :: [{atom(), term()}]]}
    | {error, term()}.

%% The current state of the most-recently-parsed cache entry — see
%% compute_meta/5 for the shape.
-spec overview() -> {not_parsed, #{loaded => false}} | {ok, map()}.
%% What is loaded right now, most recently parsed project — the MCP
%% tool's no-path shape. The staleness check: total_facts/files here.
overview() ->
    overview(undefined).

%% Same as overview/0, but Path selects which cached directory to report
%% on (same meaning as query/3's Path). An explicit Path that was never
%% parsed reports {error, {unknown_path, Path}} rather than the
%% "nothing at all parsed yet" {not_parsed, ...} shape.
-spec overview(file:name() | undefined) ->
    {not_parsed, #{loaded => false}} | {ok, map()} | {error, term()}.
%% Same as overview/0, but Path selects which cached directory to
%% report on (same meaning as query/3's Path). An explicit Path that
%% was never parsed reports {error, {unknown_path, Path}} rather than
%% the "nothing at all parsed yet" {not_parsed, ...} shape.
overview(Path) ->
    gen_server:call(?MODULE, {overview, Path}).

%% gen_server callbacks

%% caches: NormalizedDir -> #{erl => ErlState, meta => Meta,
%%                        facts => [Fact]} (raw facts — the ask
%% pipeline's one-shot sessions; see the finish_parse comment).
%% current: the NormalizedDir most recently published (from disk or a
%% scan), or undefined if neither exists — the default for query/3 and
%% overview/1. refresh: optional startup worker, never a published cache.
init([Options]) ->
    Empty = #{caches => #{}, current => undefined, refresh => undefined,
              resuming => maps:get(startup_refresh, Options, false)},
    case maps:get(startup_refresh, Options, false) of
        true ->
            {State, Config} = resume_configured_project(Empty),
            case Config of undefined -> ok; _ -> self() ! {start_refresh, Config} end,
            {ok, State};
        false -> {ok, Empty}
    end.

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
handle_call({parse, undefined, RulesOverride}, _From, State0) ->
    State = cancel_refresh(State0),
    tracked_parse(fun() ->
        symbolic_operation_status:phase(discovering),
        StartMs = erlang:monotonic_time(millisecond),
        case discovery_start_dir(undefined) of
            {ok, Cwd} ->
                case symbolic_config:discover(Cwd) of
                    undefined -> {reply, {error, {no_config_found, Cwd}}, State};
                    ConfigPath -> parse_from_config(ConfigPath, RulesOverride, StartMs, State)
                end;
            {error, Reason} -> {reply, {error, Reason}, State}
        end
    end, undefined, State);
handle_call({parse, Dir, RulesOverride}, _From, State0) ->
    State = cancel_refresh(State0),
    tracked_parse(fun() ->
        symbolic_operation_status:phase(discovering),
        StartMs = erlang:monotonic_time(millisecond),
        case own_config(Dir) of
            undefined ->
                Key = normalize_dir(Dir),
                symbolic_operation_status:project(Key),
                Cache = previous_file_cache(Key, undefined, State),
                symbolic_operation_status:phase(extracting),
                finish_parse(symbolic_parse:scan_report(Dir, Cache), Key,
                             RulesOverride, StartMs, State, undefined, #{});
            ConfigPath -> parse_from_config(ConfigPath, RulesOverride, StartMs, State)
        end
    end, Dir, State);
handle_call({parse_config, ConfigPath, RulesOverride}, _From, State0) ->
    State = cancel_refresh(State0),
    tracked_parse(fun() ->
        symbolic_operation_status:phase(discovering),
        StartMs = erlang:monotonic_time(millisecond),
        parse_from_config(ConfigPath, RulesOverride, StartMs, State)
    end, ConfigPath, State);

handle_call({query, Goal, Limit, Path}, _From, State) ->
    symbolic_operation_status:started(query, Path),
    symbolic_operation_status:phase(validating),
    Result = case resolve_cache_entry(Path, State) of
        {error, Reason} -> {error, Reason};
        {ok, #{erl := Erl}} ->
            Project = case Path of
                undefined -> maps:get(current, State);
                _ -> normalize_dir(Path)
            end,
            symbolic_operation_status:project(Project),
            query_reply(Goal, Limit, Erl)
    end,
    symbolic_operation_status:finished(status_outcome(Result)),
    {reply, Result, State};

handle_call({ask, Question, Path}, _From, State) ->
    case resolve_cache_entry(Path, State) of
        {error, Reason} ->
            {reply, {error, Reason}, State};
        {ok, #{facts := Facts, meta := Meta}} ->
            {reply, symbolic_ask:ask(Facts, Question, Meta), State}
    end;

handle_call({facts, Path}, _From, State) ->
    case resolve_cache_entry(Path, State) of
        {error, Reason} -> {reply, {error, Reason}, State};
        {ok, #{facts := Facts}} -> {reply, {ok, Facts}, State}
    end;

handle_call({overview, Path}, _From, State) ->
    case resolve_cache_entry(Path, State) of
        {error, not_parsed} -> {reply, {not_parsed, #{loaded => false}}, State};
        {error, Reason} -> {reply, {error, Reason}, State};
        {ok, #{meta := Meta}} ->
            case maps:get(resuming, State, false) of
                false -> {reply, {ok, Meta}, State};
                true ->
                    Refreshing = case maps:get(refresh, State) of
                        #{root := Root} -> maps:get(path, Meta) =:= Root;
                        undefined -> false
                    end,
                    {reply, {ok, Meta#{refreshing => Refreshing}}, State}
            end
    end.

%% The query ladder, extracted so handle_call/3 reads as dispatch: no
%% triple-nested case. prove_all_with_timeout/3's three result shapes
%% ({ok,...}, {truncated,...}, {error,...}) ARE the caller's reply
%% shapes, so this only folds the parse-goal step into the same ladder.
query_reply(Goal, Limit, Erl) ->
    case parse_goal(Goal) of
        {ok, ParsedGoal} ->
            case symbolic_query_schema:validate(ParsedGoal) of
                ok ->
                    symbolic_operation_status:phase(proving),
                    prove_all_with_timeout(ParsedGoal, Erl, clamp_limit(Limit));
                {error, _} = Error -> Error
            end;
        {error, Reason} ->
            {error, Reason}
    end.

status_outcome({error, Reason}) -> {error, Reason};
status_outcome(_Result) -> ok.

%% Hydrate only the MCP server's configured project. A missing or
%% unreadable snapshot is not a fact base: log and let the refresh build
%% one; never publish a partially loaded erlog state.
resume_configured_project(State) ->
    case file:get_cwd() of
        {ok, Cwd} ->
            case symbolic_config:discover(Cwd) of
                undefined -> {State, undefined};
                ConfigPath ->
                    case symbolic_config:read_settings(ConfigPath) of
                        {ok, #{database := Db} = Settings} when Db =/= undefined ->
                            Root = symbolic_config:project_root(ConfigPath),
                            Config = #{root => Root, db => Db, config => ConfigPath,
                                       paths => maps:get(paths, Settings),
                                       typescript => maps:get(typescript, Settings, undefined)},
                            {resume_snapshot(Root, Db, State), Config};
                        {ok, _} -> {State, undefined};
                        {error, Reason} ->
                            ?LOG_WARNING("cannot read startup project config: ~p", [Reason]),
                            {State, undefined}
                    end
            end;
        {error, Reason} ->
            ?LOG_WARNING("cannot get cwd for startup snapshot: ~p", [Reason]),
            {State, undefined}
    end.

resume_snapshot(Root, Db, State) ->
    case {filelib:is_regular(Db), symbolic_fact_store:read_metadata(Db)} of
        {true, {ok, Saved}} ->
            try
                Facts = symbolic_fact_store:read(Db),
                Rules = resolve_rules(Root, undefined),
                case build_state(Facts, Rules) of
                    {ok, Erl} ->
                        Meta = saved_meta(Root, Db, Rules, Saved, Facts),
                        ?LOG_INFO("restored ~p facts from ~s; refreshing in background",
                                  [length(Facts), Db]),
                        State#{caches => #{Root => #{erl => Erl, facts => Facts,
                                                     database => Db, meta => Meta}},
                               current => Root};
                    {error, RuleError} ->
                        ?LOG_WARNING("cannot load saved rules ~p: ~p", [Rules, RuleError]),
                        State
                end
            catch Class:Reason:Stack ->
                ?LOG_WARNING("cannot restore ~s: ~p:~p ~p", [Db, Class, Reason, Stack]),
                State
            end;
        {true, Other} ->
            ?LOG_WARNING("saved database metadata unavailable ~s: ~p", [Db, Other]),
            State;
        {false, _} -> State
    end.

saved_meta(Root, Db, Rules, Saved, Facts) ->
    #{loaded => true, path => Root, database => Db, rules_file => Rules,
      snapshot_source => disk, refreshing => false, parse_ms => null,
      scan_complete => maps:get(<<"complete">>, Saved, false),
      scan_metadata_available => maps:get(<<"metadata_available">>, Saved, false),
      files => maps:get(<<"files">>, Saved, 0),
      scan_paths => [binary_to_list(P) || P <- maps:get(<<"scan_paths">>, Saved, [])],
      failed_files => [binary_to_list(P) || P <- maps:get(<<"failed_files">>, Saved, [])],
      languages => [binary_to_list(L) || L <- maps:get(<<"languages">>, Saved,
                                                       [<<"unknown">>])],
      type_analysis => maps:get(<<"typescript_analysis">>, Saved,
                                #{<<"status">> => <<"unknown">>}),
      facts_by_predicate => counts_by_predicate(Facts), total_facts => length(Facts)}.

start_refresh(#{root := Root, db := Db, paths := Paths, typescript := TS} = Config, State) ->
    Parent = self(),
    {Pid, Ref} = spawn_monitor(fun() ->
        symbolic_operation_status:started(parse, Root),
        symbolic_operation_status:phase(extracting),
        Result = try
            Cache = symbolic_file_cache:load(Db),
            case symbolic_parse:scan_paths_report(Paths, Cache) of
                {ok, #{complete := false, failed_files := Failed}} ->
                    {error, {incomplete_scan, Failed}};
                {ok, Scan} ->
                    symbolic_operation_status:phase(analyzing),
                    symbolic_ts_project:analyze(Scan, Root, TS);
                Error -> Error
            end
        catch Class:Reason:Stack ->
            ?LOG_ERROR("startup refresh crashed: ~p:~p ~p", [Class, Reason, Stack]),
            {error, {refresh_crashed, Class, Reason}}
        end,
        Parent ! {refresh_result, self(), Result},
        receive
            {refresh_published, Outcome} -> symbolic_operation_status:finished(Outcome)
        end
    end),
    ?LOG_INFO("startup differential scan for ~s", [Root]),
    State#{refresh => Config#{pid => Pid, ref => Ref}}.

cancel_refresh(#{refresh := undefined} = State) -> State;
cancel_refresh(#{refresh := #{pid := Pid, ref := Ref}} = State) ->
    symbolic_operation_status:cancelled(Pid),
    exit(Pid, kill),
    erlang:demonitor(Ref, [flush]),
    State#{refresh => undefined}.

tracked_parse(Fun, Path, State) ->
    symbolic_operation_status:started(parse, Path),
    Reply = safely(Fun, State),
    {reply, Result, _} = Reply,
    symbolic_operation_status:finished(status_outcome(Result)),
    Reply.

%% Standard OTP no-op: nothing in this module uses casts.
handle_cast(_Msg, State) -> {noreply, State}.

handle_info({start_refresh, Config}, State) ->
    {noreply, start_refresh(Config, State)};
handle_info({refresh_result, Pid, Result}, #{refresh := #{pid := Pid} = Job} = State) ->
    Reply = case Result of
        {ok, ScanReport} ->
            #{root := Root, db := Db, config := Config} = Job,
            StartMs = erlang:monotonic_time(millisecond),
            safely(fun() -> finish_parse_report(ScanReport, Root, undefined,
                        StartMs, State#{refresh => undefined}, Db,
                        #{config_file => Config}) end, State#{refresh => undefined});
        {error, Reason} ->
            ?LOG_ERROR("startup refresh failed: ~p; keeping saved snapshot", [Reason]),
            {reply, {error, Reason}, State#{refresh => undefined}}
    end,
    {reply, Outcome, NewState} = Reply,
    case Outcome of
        {ok, Meta} -> ?LOG_INFO("startup refresh published ~p facts for ~s",
                                [maps:get(total_facts, Meta), maps:get(path, Meta)]);
        {error, PublishError} -> ?LOG_ERROR("startup refresh publish failed: ~p; saved snapshot kept",
                                            [PublishError])
    end,
    Pid ! {refresh_published, status_outcome(Outcome)},
    erlang:demonitor(maps:get(ref, Job), [flush]),
    {noreply, NewState};
handle_info({refresh_result, _StalePid, _Result}, State) -> {noreply, State};
handle_info({'DOWN', Ref, process, Pid, Reason},
            #{refresh := #{pid := Pid, ref := Ref}} = State) ->
    ?LOG_ERROR("startup refresh worker stopped: ~p; keeping saved snapshot", [Reason]),
    {noreply, State#{refresh => undefined}};
handle_info(_Message, State) -> {noreply, State}.

terminate(_Reason, State) when is_map(State) -> _ = cancel_refresh(State), ok;
terminate(_Reason, _State) -> ok.

%% Standard OTP no-op: the cache is rebuilt by a fresh parse, never
%% migrated in place.
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

%% A fresh erlog state loaded through the same bulk loader as the CLI.
%% When RulesPath is resolved, the same derived-predicate library the CLI
%% consults is consulted here too through erlog:consult/2.
build_state(Facts, RulesPath) ->
    {ok, Erl0} = erlog:new(),
    %% Same native-builtin layering prolog_session:init/1 does — see
    %% symbolic_prolog_lib.erl. Both erlog session constructors in this
    %% codebase need it independently; erlog:new/0 itself has no way to
    %% take extra library modules.
    {ok, Erl} = erlog:load(symbolic_prolog_lib, Erl0),
    consult_rules(symbolic_fact_loader:load(Erl, Facts), RulesPath).

consult_rules(Erl, undefined) -> {ok, Erl};
consult_rules(Erl, RulesPath) -> erlog:consult(RulesPath, Erl).

%% Explicit RulesOverride wins outright (mirrors the CLI's -rules, which
%% is never second-guessed by discovery); otherwise auto-discover by
%% walking up from Dir, then the server's own cwd — see
%% symbolic_query:discover_rules_from_dir/1. There's no MCP equivalent of
%% -no-rules yet (a persistent cache has less need for a one-off
%% "consult nothing" switch); pass an explicit RulesOverride if that's
%% ever needed.
%% Which rules file a parse consults: an explicit override wins
%% outright, otherwise auto-discovery walks up from the scan's own
%% directory — same precedence as symbolic_query:resolve_rules/3, but
%% for a directory rather than a fact database.
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
%%  A .symbolic/config.json was found — read and validate it, merge its
%%  paths into one cache entry, and persist facts to its optional DETS
%%  database, all keyed by the config's own project root.
previous_file_cache(Key, undefined, State) ->
    case maps:find(Key, maps:get(caches, State)) of
        {ok, Entry} -> symbolic_file_cache:load_memory(maps:get(file_cache, Entry, #{}));
        error -> #{}
    end;
previous_file_cache(_Key, DbPath, _State) -> symbolic_file_cache:load(DbPath).

parse_from_config(ConfigPath, RulesOverride, StartMs, State) ->
    symbolic_operation_status:project(symbolic_config:project_root(ConfigPath)),
    case symbolic_config:read_settings(ConfigPath) of
        {ok, Settings = #{paths := Paths, database := DbPath}} ->
            ProjectRoot = symbolic_config:project_root(ConfigPath),
            Cache = previous_file_cache(ProjectRoot, DbPath, State),
            symbolic_operation_status:phase(extracting),
            finish_parse(symbolic_parse:scan_paths_report(Paths, Cache), ProjectRoot,
                RulesOverride, StartMs, State, DbPath,
                #{config_file => ConfigPath,
                  typescript_settings => maps:get(typescript, Settings, undefined)});
        {error, Reason} -> {reply, {error, Reason}, State}
    end.

%% finish_parse(ScanResult, CacheKey, RulesOverride, StartMs, State, DbPath, ExtraMeta)
%%  -> {reply, ..., NewState}.
%%  The shared tail of both `parse` variants above: given a
%%  scan/1-or-scan_paths/1 result and the (already-absolute) key to use
%%  for both caching and rules discovery, build the erlog state, compute
%%  the summary (merging in ExtraMeta — e.g. `config_file` for the
%%  config-driven variant), and cache it. Every "leave State untouched on
%%  error" guarantee handle_call({parse,...}) documented before this was
%%  factored out still holds, since both callers still route every error
%%  branch through the same {reply, {error,_}, State} (State unchanged).
finish_parse({ok, RawScanReport}, CacheKey, RulesOverride, StartMs, State, DbPath, ExtraMeta) ->
    symbolic_operation_status:phase(analyzing),
    TypeScriptSettings = maps:get(typescript_settings, ExtraMeta, undefined),
    PublicExtraMeta = maps:remove(typescript_settings, ExtraMeta),
    case symbolic_ts_project:analyze(RawScanReport, CacheKey, TypeScriptSettings) of
        {ok, ScanReport} ->
            finish_parse_report(ScanReport, CacheKey, RulesOverride, StartMs,
                                State, DbPath, PublicExtraMeta);
        {error, Reason} ->
            {reply, {error, {typescript_analysis_failed, Reason}}, State}
    end;
finish_parse({error, Reason}, _CacheKey, _RulesOverride, _StartMs, State, _DbPath, _ExtraMeta) ->
    {reply, {error, Reason}, State}.

finish_parse_report(ScanReport, CacheKey, RulesOverride, StartMs, State, DbPath, ExtraMeta) ->
    symbolic_operation_status:phase(loading),
    Facts = maps:get(facts, ScanReport),
    RulesPath = resolve_rules(CacheKey, RulesOverride),
    case build_state(Facts, RulesPath) of
        {ok, Erl} ->
            symbolic_operation_status:phase(persisting),
            case persist_database(DbPath, Facts, ScanReport) of
                ok ->
                    symbolic_operation_status:phase(publishing),
                    ElapsedMs = erlang:monotonic_time(millisecond) - StartMs,
                    DbMeta = case DbPath of undefined -> #{}; _ -> #{database => DbPath} end,
                    Meta = maps:merge(compute_meta(ScanReport, RulesPath, CacheKey, ElapsedMs),
                                      maps:merge(ExtraMeta, DbMeta)),
                    Caches = maps:get(caches, State),
                    %% A later CLI write to the shared DETS file is visible
                    %% only after MCP parses again or a fresh MCP process
                    %% restores the saved snapshot.
                    FileCache = case DbPath of
                        undefined -> #{file_cache => #{version => symbolic_file_cache:version(),
                                                        files => maps:get(file_cache, ScanReport)}};
                        _ -> #{} %% The persisted sidecar supplies the next scan.
                    end,
                    EntryMeta = case maps:get(resuming, State, false) of
                        true -> Meta#{snapshot_source => scan, refreshing => false};
                        false -> Meta
                    end,
                    Entry = maps:merge(#{erl => Erl, meta => EntryMeta,
                                         facts => Facts, database => DbPath}, FileCache),
                    NewState = State#{caches => Caches#{CacheKey => Entry},
                                      current => CacheKey},
                    {reply, {ok, Meta}, NewState};
                {error, Reason} -> {reply, {error, Reason}, State}
            end;
        {error, Reason} ->
            {reply, {error, {rules_error, RulesPath, Reason}}, State}
    end.

persist_database(undefined, _Facts, _ScanReport) -> ok;
persist_database(DbPath, Facts, ScanReport) ->
    case symbolic_fact_store:write_bundle(DbPath, Facts, scan_metadata(ScanReport),
                                          maps:get(file_cache, ScanReport)) of
        ok -> ok;
        {error, Reason} -> {error, {database_write_failed, DbPath, Reason}}
    end.

scan_metadata(Report) ->
    Base = #{<<"metadata_available">> => true,
      <<"complete">> => maps:get(complete, Report),
      <<"scan_paths">> => [unicode:characters_to_binary(filename:absname(Path))
          || Path <- maps:get(scan_paths, Report)],
      <<"files">> => length(maps:get(files, Report)),
      <<"languages">> => [unicode:characters_to_binary(L)
          || L <- languages_from_files(maps:get(files, Report))],
      <<"failed_files">> => [unicode:characters_to_binary(filename:absname(Path))
          || Path <- maps:get(failed_files, Report)],
      <<"typescript_analysis">> => symbolic_ts_project:summary_json(
          maps:get(type_analysis, Report))},
    maps:merge(Base, symbolic_ts_inputs:metadata(Report)).

compute_meta(ScanReport, RulesPath, NormDir, ElapsedMs) ->
    Files = maps:get(files, ScanReport),
    Facts = maps:get(facts, ScanReport),
    #{
        loaded => true,
        path => NormDir,
        scan_paths => [filename:absname(P) || P <- maps:get(scan_paths, ScanReport)],
        scan_complete => maps:get(complete, ScanReport),
        scan_metadata_available => true,
        failed_files => [filename:absname(P) || P <- maps:get(failed_files, ScanReport)],
        parse_ms => ElapsedMs,
        %% `files` is a count, not the full path list — a large project can
        %% have thousands of paths, and dumping every one into the MCP
        %% response (and into the per-directory cache below) risked
        %% blowing up the calling harness. Nothing else in this codebase
        %% reads a `file_list` key, so it's intentionally not stored here.
        files => length(Files),
        languages => languages_from_files(Files),
        facts_by_predicate => counts_by_predicate(Facts),
        total_facts => length(Facts),
        type_analysis => maps:get(type_analysis, ScanReport),
        rules_file => RulesPath
    }.

%% filename:extension/1 returns the dotted form (".ts", ".erl", ...).
languages_from_files(Files) ->
    lists:usort([language_from_ext(filename:extension(F)) || F <- Files]).

language_from_ext(".erl") -> "erlang";
language_from_ext(".rs") -> "rust";
language_from_ext(".ts") -> "typescript";
language_from_ext(".tsx") -> "typescript";
language_from_ext(".clj") -> "clojure";
language_from_ext(".rb") -> "ruby";
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
