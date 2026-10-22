%%% `symbolic parse` — discover the project config, scan only its listed
%%% paths, persist facts to its configured database when set, and print a
%%% JSON summary. See docs/tree-sitter-erlang.md, docs/prolog-store.md.
-module(symbolic_parse).
-include_lib("kernel/include/logger.hrl").
-include_lib("kernel/include/file.hrl").
-export([run/1, run/2, run_config/2, scan/1, scan_paths/1,
         scan_report/1, scan_report/2, scan_paths_report/1, scan_paths_report/2]).
%% Exported for symbolic_parse_tests.erl only — run/1,2 halt() on every
%% path and can't be called directly from EUnit; summary/2 and maybe_store/2
%% are the halt-free parts of that same code worth testing in isolation.
-export([summary/2, maybe_store/2, error_message/1, resolve_config/1, parallel_map/2]).

%% Scan a directory and extract facts with NO side effects — no printing,
%% no DETS write, no halt. Returns the scanned file list alongside the
%% (usorted) fact set. The MCP server's `parse` tool (symbolic_codebase) and
%% the lower-level run/2 API reuse it. This is the single source of truth for
%% "which files does a scan look at".
-spec scan(file:name()) ->
    {ok, {Files :: [file:name()], Facts :: [tuple()]}} | {error, term()}.
scan(Dir) ->
    case scan_report(Dir) of
        {ok, Report} -> {ok, {maps:get(files, Report), maps:get(facts, Report)}};
        Error -> Error
    end.

-spec scan_report(file:name()) -> {ok, map()} | {error, term()}.
scan_report(Dir) -> scan_report(Dir, #{}).

scan_report(Dir, Cache) ->
    case filelib:is_dir(Dir) of
        false -> {error, {no_such_directory, Dir}};
        true ->
            case code:ensure_loaded(symbolic_ts) of
                {error, Reason} -> {error, {nif_not_loadable, Reason}};
                {module, symbolic_ts} ->
                    case scan_files(Dir) of
                        {error, _} = Error -> Error;
                        {ok, Files} ->
                            ?LOG_INFO("parse: scanning ~p files under ~s", [length(Files), Dir]),
                            StartAll = erlang:monotonic_time(millisecond),
                            {Facts, FailedFiles, Entries} = parallel_extract(Files, Cache),
                            Facts1 = lists:usort(Facts),
                            ElapsedAllMs = erlang:monotonic_time(millisecond) - StartAll,
                            ?LOG_INFO("parse: finished ~s - ~p files, ~p facts, ~p ms",
                                      [Dir, length(Files), length(Facts1), ElapsedAllMs]),
                            {ok, (scan_report_map([Dir], Files, Facts1, FailedFiles))
                                 #{file_cache => Entries}}
                    end
            end
    end.

%% ts_extract:file/1 timed and logged per file — this is what lets an
%% operator (or an agent reading the log) see which file is currently
%% being parsed and how long each one took, rather than only a single
%% total at the end. Logged via `logger`, same as everywhere else in this
%% codebase; filtered out entirely unless the primary log level is raised
%% to `info` (see symbolic_serve:setup_logging/0), so this is silent by
%% default for the CLI and only visible when the MCP server turns logging
%% on and points it at a file.
%%
%% Issue #4's "broader" fix: a crash anywhere inside ts_extract:file/1 —
%% a malformed/unsupported literal (issue #4's own bare-exponent case
%% was one; there is no reason to assume it is the last) — degrades to
%% "this file contributed zero facts" instead of propagating. Before
%% this, ANY such crash reached symbolic_codebase's gen_server
%% `handle_call({parse,...})` uncaught, which doesn't just fail that one
%% call: it kills the whole shared cache PROCESS, taking every OTHER
%% already-cached, unrelated project's entry down with it until the MCP
%% client reconnects (confirmed against the real report: four unrelated
%% directories, already parsed and cached successfully, all started
%% failing with {noproc,...} after one crashed parse elsewhere). One bad
%% file must not cost the whole session's cache — logged at `error` (not
%% `info`, unlike the success path above) so it's visible even at the
%% CLI's default log level, not silently swallowed.
extract_file_timed(File) ->
    Start = erlang:monotonic_time(millisecond),
    {Facts, Failed} = extract_file_safely(File),
    ElapsedMs = erlang:monotonic_time(millisecond) - Start,
    ?LOG_INFO("parse: ~s - ~p facts, ~p ms", [File, length(Facts), ElapsedMs]),
    {File, Facts, Failed}.

extract_file_safely(File) ->
    try {ts_extract:file(File), false}
    catch
        Class:Reason:ST ->
            ?LOG_ERROR("parse: ~s - extraction crashed (~p:~p), skipping this "
                       "file's facts rather than failing the whole scan~n~p",
                       [File, Class, Reason, ST]),
            {[], true}
    end.

%% parallel_extract(Files, Cache) -> {Facts, FailedFiles, Entries}.
%% Facts are not usorted — callers usort the combined list.
%%  One process per file instead of lists:flatmap/2's sequential walk.
%%  Safe to run concurrently: every ts_extract:file/1 call makes its own
%%  fresh symbolic_ts:parser_new/0 (confirmed against every
%%  ts_extract_*.erl module and native/symbolic_ts/src/lib.rs directly —
%%  each parse gets its own TSParser resource; the NIF's own globals are
%%  read-only atoms/resource-type handles set once at load time, nothing
%%  mutable shared across calls). A worker crash outside the per-file
%%  extractor rescue is re-raised in the calling process.
parallel_extract(Files, Cache) ->
    Results = parallel_map(fun(File) -> extract_cached(File, Cache) end, Files),
    Facts = lists:append([FileFacts || {_File, FileFacts, _Failed, _Entry} <- Results]),
    FailedFiles = [File || {File, _FileFacts, true, _Entry} <- Results],
    Entries = maps:from_list([{filename:absname(File), Entry} ||
        {File, _FileFacts, false, Entry} <- Results, Entry =/= undefined]),
    {Facts, FailedFiles, Entries}.

extract_cached(File, Cache) ->
    Key = filename:absname(File),
    case file:read_file(File) of
        {ok, Bytes} ->
            Hash = crypto:hash(sha256, Bytes),
            case maps:get(Key, Cache, undefined) of
                #{hash := Hash, path := File, facts := Facts} when is_list(Facts) ->
                    {File, Facts, false, #{hash => Hash, path => File, facts => Facts}};
                _ ->
                    {File, Facts, Failed} = extract_file_timed(File),
                    %% A file changed during extraction: neither its old nor its
                    %% new contents can safely be cached as this snapshot.
                    case file:read_file(File) of
                        {ok, After} when not Failed ->
                            case crypto:hash(sha256, After) =:= Hash of
                                true -> {File, Facts, false, #{hash => Hash, path => File, facts => Facts}};
                                false ->
                                    ?LOG_ERROR("parse: ~s changed during extraction; "
                                               "skipping this file's facts", [File]),
                                    {File, [], true, undefined}
                            end;
                        {error, Reason} ->
                            ?LOG_ERROR("parse: could not re-read ~s after extraction "
                                       "(~p); skipping this file's facts", [File, Reason]),
                            {File, Facts, true, undefined};
                        {ok, _After} ->
                            %% extract_file_safely already logged the failure.
                            {File, Facts, true, undefined}
                    end
            end;
        {error, Reason} ->
            ?LOG_ERROR("parse: could not read ~s (~p); skipping this file's facts",
                       [File, Reason]),
            {File, [], true, undefined}
    end.

%% parallel_map(Fun, Items) -> [Fun(Item)] (same order as Items).
%%  One process per item, spawn_monitor'd; results are collected by
%%  waiting on each {Pid, Ref} pair IN ORDER — receive's selective match
%%  finds that pair's message in the mailbox whenever it arrives, so
%%  this doesn't require replies to arrive in spawn order, just that
%%  every one eventually does. Bounded only by however many Items there
%%  are — fine here (a handful of scan paths, at most a few hundred
%%  files per directory), so no fixed-size worker pool.
parallel_map(Fun, Items) ->
    Parent = self(),
    Workers = [begin
        {Pid, Ref} = spawn_monitor(fun() -> Parent ! {self(), Fun(Item)} end),
        {Pid, Ref, Item}
    end || Item <- Items],
    [parallel_collect(Pid, Ref, Item) || {Pid, Ref, Item} <- Workers].

parallel_collect(Pid, Ref, Item) ->
    receive
        {Pid, Result} ->
            erlang:demonitor(Ref, [flush]),
            Result;
        {'DOWN', Ref, process, Pid, Reason} ->
            ?LOG_ERROR("parse: worker failed for ~p (~p)", [Item, Reason]),
            error({parse_worker_crashed, Reason})
    end.

%% Extensions matcher below to a language ts_extract:file/1 knows how to
%% handle. Kept as a list (not a set) — checked once per file.
-define(SCAN_EXTENSIONS, [".erl", ".rs", ".ts", ".tsx", ".clj", ".rb", ".md", ".toml", ".json", ".sh", ".bash"]).

%% scan_paths(Paths) -> {ok, {Files, Facts}} | {error, term()}.
%%  Like scan/1, but over a LIST of paths — each entry may be a
%%  directory (walked exactly like scan/1's Dir, gitignore rules loaded
%%  fresh per root since symbolic_gitignore:load/1 only ever reads one
%%  root's own .gitignore) or a single file (extracted directly, no
%%  gitignore/extension check skipped the way a directory walk would —
%%  a path named explicitly always wins, the same way an explicit
%%  -rules always wins over discovery elsewhere in this codebase).
%%  Facts from every path are merged with one shared lists:usort/1, so
%%  a fact two roots would otherwise both produce collapses into one,
%%  exactly as scan/1 already does within a single root. This is what
%%  lets .symbolic/config.json's `paths` list (symbolic_config:read/1)
%%  become one fact set instead of N independent ones.
-spec scan_paths([file:name()]) ->
    {ok, {Files :: [file:name()], Facts :: [tuple()]}} | {error, term()}.
scan_paths(Paths) ->
    case scan_paths_report(Paths) of
        {ok, Report} -> {ok, {maps:get(files, Report), maps:get(facts, Report)}};
        Error -> Error
    end.

-spec scan_paths_report([file:name()]) -> {ok, map()} | {error, term()}.
scan_paths_report(Paths) -> scan_paths_report(Paths, #{}).

scan_paths_report(Paths, Cache) ->
    case code:ensure_loaded(symbolic_ts) of
        {module, symbolic_ts} -> scan_each(Paths, Cache);
        {error, Reason} -> {error, {nif_not_loadable, Reason}}
    end.

%% Discover configured paths in parallel, then extract each distinct file
%% once. Keep the first spelling of an overlapping path: fact file atoms
%% must match the path handed to the extractor, even for relative scans.
scan_each(Paths, Cache) ->
    Discovered = parallel_map(fun discover_path/1, Paths),
    case lists:keyfind(error, 1, Discovered) of
        {error, _Reason} = Error -> Error;
        false ->
            Files = unique_files([F || {ok, Group} <- Discovered, F <- Group]),
            {Facts, FailedFiles, Entries} = parallel_extract(Files, Cache),
            {ok, (scan_report_map(Paths, Files, lists:usort(Facts), FailedFiles))
                 #{file_cache => Entries}}
    end.

unique_files(Files) ->
    {_Seen, Reversed} = lists:foldl(fun(File, {Seen, Acc}) ->
        Key = filename:absname(File),
        case maps:is_key(Key, Seen) of
            true -> {Seen, Acc};
            false -> {Seen#{Key => true}, [File | Acc]}
        end
    end, {#{}, []}, Files),
    lists:reverse(Reversed).

discover_path(Path) ->
    case filelib:is_dir(Path) of
        true -> scan_files(Path);
        false ->
            case filelib:is_regular(Path) of
                false -> {error, {no_such_path, Path}};
                true ->
                    case lists:member(filename:extension(Path), ?SCAN_EXTENSIONS) of
                        true -> {ok, [Path]};
                        false -> {error, {unsupported_file, Path}}
                    end
            end
    end.

scan_report_map(Paths, Files, Facts, FailedFiles) ->
    #{scan_paths => Paths, files => Files, facts => Facts,
      failed_files => lists:usort(FailedFiles), complete => FailedFiles =:= []}.

%% A real recursive walk, not filelib:wildcard's flat "**" glob — the
%% previous form had no way to skip a directory before descending into
%% it, so `symbolic parse` at a repo root always paid the cost of
%% listing every file under node_modules/_build/etc. even though every
%% one of them was certain to be discarded afterward. This prunes an
%% ignored directory the moment it's found, using
%% symbolic_gitignore:load/1 (that project's own top-level `.gitignore`,
%% plus node_modules/.git unconditionally — see that module's own
%% header for exactly what is and isn't supported).
scan_files(Dir) ->
    Rules = symbolic_gitignore:load(Dir),
    try {ok, walk(Dir, "", Rules)}
    catch
        throw:{cannot_list_directory, _, _} = Reason -> {error, Reason};
        throw:{cannot_inspect_directory, _, _} = Reason -> {error, Reason}
    end.

walk(AbsDir, RelDir, Rules) ->
    case file:list_dir(AbsDir) of
        {ok, Entries} ->
            lists:flatmap(
                fun(Entry) -> walk_entry(AbsDir, RelDir, Entry, Rules) end,
                lists:sort(Entries));
        {error, Reason} ->
            ?LOG_ERROR("parse: could not list directory ~s (~p); aborting scan",
                       [AbsDir, Reason]),
            throw({cannot_list_directory, AbsDir, Reason})
    end.

walk_entry(AbsDir, RelDir, Entry, Rules) ->
    AbsPath = filename:join(AbsDir, Entry),
    RelPath = case RelDir of
        "" -> Entry;
        _ -> RelDir ++ "/" ++ Entry
    end,
    case filelib:is_dir(AbsPath) of
        true ->
            %% filelib:is_dir/1 follows symlinks. Do not descend through a
            %% link to a parent (a cycle) or to a directory outside the
            %% configured root. File symlinks retain their existing behavior.
            case file:read_link_info(AbsPath) of
                {ok, #file_info{type = symlink}} -> [];
                {ok, _} ->
                    case symbolic_gitignore:ignored(RelPath, true, Rules) of
                        true -> [];
                        false -> walk(AbsPath, RelPath, Rules)
                    end;
                {error, Reason} ->
                    ?LOG_ERROR("parse: could not inspect ~s (~p); aborting scan",
                               [AbsPath, Reason]),
                    throw({cannot_inspect_directory, AbsPath, Reason})
            end;
        false ->
            case symbolic_gitignore:ignored(RelPath, false, Rules)
                orelse not lists:member(filename:extension(Entry), ?SCAN_EXTENSIONS) of
                true -> [];
                false -> [AbsPath]
            end
    end.

run(Dir) ->
    run(Dir, undefined).

%% halt() belongs only here, at the CLI's actual edge (see
%% symbolic_query:run/4's identical note on why) — scan/1 already
%% returns a plain term, and error_message/1 below turns that term into
%% the exact text printed, so both are directly testable without it.
run(Dir, DbPath) ->
    cli_parse(fun() -> run_dir(Dir, DbPath) end).

run_dir(Dir, DbPath) ->
    case scan_report(Dir, cache_for_db(DbPath)) of
        {ok, Report} -> complete_parse(Report, Dir, undefined, DbPath);
        {error, Reason} ->
            io:put_chars(standard_error, error_message(Reason)),
            halt(1)
    end.

%% run_config(ConfigOverride, DbPath) -> no_return().
%%  `symbolic parse` with no Dir given — resolve_config/1 either uses an
%%  explicit -config path or discovers .symbolic/config.json the same
%%  way .symbolic/rules.pl is discovered, symbolic_config:read/1
%%  resolves its `paths` list to absolute paths, and scan_paths/1 merges
%%  every one of them into a single fact set — same halt()-at-the-edge
%%  shape as run/2.
run_config(ConfigOverride, DbPath) ->
    cli_parse(fun() -> run_configured(ConfigOverride, DbPath) end).

run_configured(ConfigOverride, DbPath) ->
    case resolve_config(ConfigOverride) of
        {ok, ConfigPath} ->
            case symbolic_config:read_settings(ConfigPath) of
                {ok, Settings = #{paths := Paths, database := ConfigDb}} ->
                    run_paths(Paths, choose_db(DbPath, ConfigDb),
                              symbolic_config:project_root(ConfigPath),
                              maps:get(typescript, Settings, undefined));
                {error, Reason} -> halt_error(Reason)
            end;
        {error, Reason} -> halt_error(Reason)
    end.

%% resolve_config(ConfigOverride) -> {ok, file:filename()} | {error, term()}.
%%  An explicit -config path wins outright and must exist (mirrors
%%  symbolic_query:resolve_rules/3's "an explicit path is never
%%  second-guessed" rule); otherwise discover .symbolic/config.json by
%%  walking up from the current directory.
resolve_config(ConfigOverride) when ConfigOverride =/= undefined ->
    case filelib:is_regular(ConfigOverride) of
        true -> {ok, ConfigOverride};
        false -> {error, {no_such_config, ConfigOverride}}
    end;
resolve_config(undefined) ->
    case file:get_cwd() of
        {ok, Cwd} ->
            case symbolic_config:discover(Cwd) of
                undefined -> {error, {no_config_found, Cwd}};
                ConfigPath -> {ok, ConfigPath}
            end;
        {error, Reason} -> {error, {cannot_get_cwd, Reason}}
    end.

choose_db(undefined, ConfigDb) -> ConfigDb;
choose_db(DbPath, _ConfigDb) -> DbPath.

cache_for_db(undefined) -> #{};
cache_for_db(DbPath) -> symbolic_file_cache:load(DbPath).

run_paths(Paths, DbPath, ScopeRoot, TypeScriptSettings) ->
    case scan_paths_report(Paths, cache_for_db(DbPath)) of
        {ok, Report} -> complete_parse(Report, ScopeRoot, TypeScriptSettings, DbPath);
        {error, Reason} -> halt_error(Reason)
    end.

complete_parse(RawReport, ScopeRoot, TypeScriptSettings, DbPath) ->
    case symbolic_ts_project:analyze(RawReport, ScopeRoot, TypeScriptSettings) of
        {ok, Report} ->
            case maybe_store_report(DbPath, Report) of
                ok ->
                    print_summary_report(Report),
                    halt(0);
                {error, Reason} -> halt_error({database_write_failed, DbPath, Reason})
            end;
        {error, Reason} -> halt_error({typescript_analysis_failed, Reason})
    end.

%% Keep unexpected CLI exceptions visible with their stack in the logger,
%% and return a concise error on stderr even if the logger has not flushed
%% before halt/1. The MCP path has its own catch in symbolic_codebase.
cli_parse(Fun) ->
    try
        cli_logger_to_stderr(),
        Fun()
    catch
        Class:Reason:ST ->
            ?LOG_ERROR("parse: crashed ~p:~p~n~p", [Class, Reason, ST]),
            io:format(standard_error, "parse: crashed ~p:~p~n", [Class, Reason]),
            halt(1)
    end.

%% A CLI parse prints one JSON summary on stdout. OTP's default logger
%% handler writes errors to stdout, corrupting that JSON on partial scans.
%% This is a one-shot CLI entry point; the MCP server installs its own file
%% handler and does not call run/2 or run_config/2.
cli_logger_to_stderr() ->
    ok = logger:remove_handler(default),
    ok = logger:add_handler(symbolic_parse_cli_stderr, logger_std_h,
                            #{config => #{type => standard_error}}).

halt_error(Reason) ->
    io:put_chars(standard_error, error_message(Reason)),
    halt(1).

error_message({no_such_directory, Dir}) ->
    io_lib:format("parse: no such directory: ~s~n", [Dir]);
error_message({cannot_list_directory, Dir, Reason}) ->
    io_lib:format("parse: cannot list directory ~s: ~p; last good snapshot unchanged~n",
                  [Dir, Reason]);
error_message({cannot_inspect_directory, Dir, Reason}) ->
    io_lib:format("parse: cannot inspect directory ~s: ~p; last good snapshot unchanged~n",
                  [Dir, Reason]);
error_message({no_such_path, Path}) ->
    io_lib:format("parse: no such file or directory: ~s~n", [Path]);
error_message({unsupported_file, Path}) ->
    io_lib:format(
        "parse: ~s has no extension symbolic knows how to extract "
        "(expected one of .erl/.rs/.ts/.clj/.rb/.md/.toml/.json/.sh/.bash)~n", [Path]);
error_message({no_such_config, ConfigPath}) ->
    io_lib:format("parse: no such config file: ~s~n", [ConfigPath]);
error_message({no_config_found, StartDir}) ->
    io_lib:format(
        "parse: no .symbolic/config.json found walking up from ~s - "
        "add project configuration listing the paths to scan~n",
        [StartDir]);
error_message({cannot_get_cwd, Reason}) ->
    io_lib:format("parse: could not get current directory: ~p~n", [Reason]);
error_message({cannot_read_config, ConfigPath, Reason}) ->
    io_lib:format("parse: could not read ~s: ~p~n", [ConfigPath, Reason]);
error_message({invalid_config_json, ConfigPath}) ->
    io_lib:format("parse: ~s is not valid JSON~n", [ConfigPath]);
error_message({missing_config_paths, ConfigPath}) ->
    io_lib:format("parse: ~s has no \"paths\" key~n", [ConfigPath]);
error_message({invalid_config_paths, ConfigPath, Why}) ->
    io_lib:format("parse: ~s: ~s~n", [ConfigPath, Why]);
error_message({nif_not_loadable, _}) ->
    %% Known packaging limitation, not a bug here: the escript build
    %% can't embed symbolic_ts's NIF .so — see rebar.config /
    %% docs/cli-erlang.md. Run via `rebar3 release` (or `rebar3 shell`)
    %% instead of the escript binary.
    "parse: symbolic_ts (the tree-sitter NIF) isn't loadable "
    "in this build - a known packaging limitation, not a code "
    "bug. Run via a `rebar3 release` (or `rebar3 shell`); see "
    "docs/cli-erlang.md.\n".

maybe_store(undefined, _Facts) -> ok;
maybe_store(DbPath, Facts) ->
    ok = symbolic_fact_store:write(DbPath, Facts),
    %% Write the full-text index sidecar (<db>.text_idx) alongside the
    %% DETS store, same fact set, same write — so `symbolic search` can
    %% load the prebuilt BM25 index instead of re-reading and
    %% re-tokenizing the whole corpus per query (docs/full-text-search.md).
    %% Best-effort: a failed sidecar write never fails the parse, it
    %% only costs `symbolic search` its fast path.
    try symbolic_search:write_index_cache(DbPath, Facts) of
        _ -> ok
    catch
        _:_ -> ok
    end.

maybe_store_report(undefined, _Report) -> ok;
maybe_store_report(DbPath, Report) ->
    Metadata = #{<<"metadata_available">> => true,
        <<"complete">> => maps:get(complete, Report),
        <<"scan_paths">> => [unicode:characters_to_binary(filename:absname(Path))
            || Path <- maps:get(scan_paths, Report)],
        <<"files">> => length(maps:get(files, Report)),
        <<"failed_files">> => [unicode:characters_to_binary(filename:absname(Path))
            || Path <- maps:get(failed_files, Report)],
        <<"typescript_analysis">> => symbolic_ts_project:summary_json(
            maps:get(type_analysis, Report))},
    symbolic_fact_store:write_bundle(DbPath, maps:get(facts, Report), Metadata,
                                     maps:get(file_cache, Report)).

print_summary_report(Report) ->
    FailedFiles = [filename:absname(P) || P <- maps:get(failed_files, Report)],
    case FailedFiles of
        [] -> ok;
        _ -> io:format(standard_error,
             "parse: incomplete scan (~p failed files); see failed_files in JSON summary~n",
             [length(FailedFiles)])
    end,
    Base = summary(maps:get(files, Report), maps:get(facts, Report)),
    Summary = Base#{scan_complete => maps:get(complete, Report),
                    failed_files => [unicode:characters_to_binary(P)
                        || P <- FailedFiles],
                    type_analysis => symbolic_ts_project:summary_json(
                        maps:get(type_analysis, Report))},
    io:format("~ts~n", [jsx:encode(Summary)]).

%% The CLI response matches the documented `Parse a project` response.
summary(Files, Facts) ->
    #{
        files => length(Files),
        languages => languages_from_files(Files),
        total_facts => length(Facts)
    }.

languages_from_files(Files) ->
    lists:usort([language_from_ext(filename:extension(File)) || File <- Files]).

language_from_ext(".erl") -> <<"erlang">>;
language_from_ext(".rs") -> <<"rust">>;
language_from_ext(".ts") -> <<"typescript">>;
language_from_ext(".tsx") -> <<"typescript">>;
language_from_ext(".clj") -> <<"clojure">>;
language_from_ext(".rb") -> <<"ruby">>;
language_from_ext(".md") -> <<"markdown">>;
language_from_ext(".toml") -> <<"toml">>;
language_from_ext(".json") -> <<"json">>;
language_from_ext(".sh") -> <<"bash">>;
language_from_ext(".bash") -> <<"bash">>;
language_from_ext(_Other) -> <<"unknown">>.
