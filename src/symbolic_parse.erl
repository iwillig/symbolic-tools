%%% `symbolic parse <dir> [--db <path>]` — walk a folder, run tree-sitter
%%% extraction, print facts as JSON to stdout (one JSON array per line —
%%% JSON Lines, still greppable/pipeable like the old one-fact-per-line
%%% Prolog text was), and optionally persist the fact set into a DETS
%%% database for `symbolic query --db` to read back. See
%%% docs/tree-sitter-erlang.md, docs/prolog-store.md.
%%%
%%% Facts used to print as raw Prolog text via `erlog_io:writeq1/1` —
%%% replaced because that printer doesn't escape an atom's embedded
%%% single quotes at all (real prose, including this project's own
%%% comments, breaks it) and because free-text fields could only be
%%% truncated-at-200-chars atoms, not arbitrary-length values. See
%%% symbolic_term_json.erl and ts_extract_text.erl.
-module(symbolic_parse).
-include_lib("kernel/include/logger.hrl").
-export([run/1, run/2, run_config/2, scan/1, scan_paths/1]).
%% Exported for symbolic_parse_tests.erl only — run/1,2 halt() on every
%% path and can't be called directly from EUnit; maybe_store/2 and
%% print_fact/1 are the halt-free parts of that same code worth testing
%% in isolation.
-export([maybe_store/2, print_fact/1, error_message/1, resolve_config/1, parallel_map/2]).

%% Scan a directory and extract facts with NO side effects — no printing,
%% no DETS write, no halt. Returns the scanned file list alongside the
%% (usorted) fact set. The MCP server's `parse` tool (symbolic_codebase) is
%% the main consumer; the CLI's run/2 below reuses it too. This is the
%% single source of truth for "which files does a scan look at".
-spec scan(file:name()) ->
    {ok, {Files :: [file:name()], Facts :: [tuple()]}} | {error, term()}.
scan(Dir) ->
    case filelib:is_dir(Dir) of
        true ->
            case code:ensure_loaded(symbolic_ts) of
                {module, symbolic_ts} ->
                    Files = scan_files(Dir),
                    ?LOG_INFO("parse: scanning ~p files under ~s", [length(Files), Dir]),
                    StartAll = erlang:monotonic_time(millisecond),
                    Facts = lists:usort(parallel_extract(Files)),
                    ElapsedAllMs = erlang:monotonic_time(millisecond) - StartAll,
                    ?LOG_INFO("parse: finished ~s - ~p files, ~p facts, ~p ms",
                              [Dir, length(Files), length(Facts), ElapsedAllMs]),
                    {ok, {Files, Facts}};
                {error, Reason} ->
                    {error, {nif_not_loadable, Reason}}
            end;
        false ->
            {error, {no_such_directory, Dir}}
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
    Facts = extract_file_safely(File),
    ElapsedMs = erlang:monotonic_time(millisecond) - Start,
    ?LOG_INFO("parse: ~s - ~p facts, ~p ms", [File, length(Facts), ElapsedMs]),
    Facts.

extract_file_safely(File) ->
    try ts_extract:file(File)
    catch
        Class:Reason:ST ->
            ?LOG_ERROR("parse: ~s - extraction crashed (~p:~p), skipping this "
                       "file's facts rather than failing the whole scan~n~p",
                       [File, Class, Reason, ST]),
            []
    end.

%% parallel_extract(Files) -> Facts (not usorted — every caller usorts
%% the combined list itself).
%%  One process per file instead of lists:flatmap/2's sequential walk.
%%  Safe to run concurrently: every ts_extract:file/1 call makes its own
%%  fresh symbolic_ts:parser_new/0 (confirmed against every
%%  ts_extract_*.erl module and c_src/symbolic_ts_nif.c directly — each
%%  parse gets its own TSParser resource; the NIF's own globals are
%%  read-only atoms/resource-type handles set once at load time, nothing
%%  mutable shared across calls). A crash in any one file's extraction
%%  is re-raised in THIS process rather than silently dropped, so a bad
%%  file still fails the whole scan exactly as it would have sequentially
%%  — parallelizing the common (successful) case must not quietly change
%%  what happens on the uncommon (crashing) one.
parallel_extract(Files) ->
    lists:append(parallel_map(fun extract_file_timed/1, Files)).

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
        {Pid, Ref}
    end || Item <- Items],
    [parallel_collect(Pid, Ref) || {Pid, Ref} <- Workers].

parallel_collect(Pid, Ref) ->
    receive
        {Pid, Result} ->
            erlang:demonitor(Ref, [flush]),
            Result;
        {'DOWN', Ref, process, Pid, Reason} ->
            error({parse_worker_crashed, Reason})
    end.

%% Extensions matcher below to a language ts_extract:file/1 knows how to
%% handle. Kept as a list (not a set) — 7 entries, checked once per file.
-define(SCAN_EXTENSIONS, [".erl", ".ts", ".md", ".toml", ".json", ".sh", ".bash"]).

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
    case code:ensure_loaded(symbolic_ts) of
        {module, symbolic_ts} -> scan_each(Paths);
        {error, Reason} -> {error, {nif_not_loadable, Reason}}
    end.

%% Each path's own scan_one/1 runs in its own process too — a directory
%% walk and a single file's extraction are both independent I/O + NIF
%% work with no shared state between paths (same reasoning as
%% parallel_extract/1 above; scan_one/1's own directory branch is
%% already parallel per-file on top of this), so a config listing
%% src/test/package.json scans all three at once instead of one after
%% another. Merged in the ORIGINAL Paths order regardless of which
%% finishes first (parallel_map/2's own ordering guarantee) — so "the
%% first path with a problem" stays deterministic even though execution
%% order isn't.
scan_each(Paths) ->
    Results = parallel_map(fun scan_one/1, Paths),
    case lists:keyfind(error, 1, Results) of
        {error, _Reason} = Error -> Error;
        false ->
            {FilesLists, FactsLists} = lists:unzip([FF || {ok, FF} <- Results]),
            {ok, {lists:append(FilesLists), lists:usort(lists:append(FactsLists))}}
    end.

scan_one(Path) ->
    case filelib:is_dir(Path) of
        true ->
            Files = scan_files(Path),
            {ok, {Files, parallel_extract(Files)}};
        false ->
            case filelib:is_regular(Path) of
                true -> scan_one_file(Path);
                false -> {error, {no_such_path, Path}}
            end
    end.

scan_one_file(Path) ->
    case lists:member(filename:extension(Path), ?SCAN_EXTENSIONS) of
        true -> {ok, {[Path], extract_file_timed(Path)}};
        false -> {error, {unsupported_file, Path}}
    end.

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
    walk(Dir, "", Rules).

walk(AbsDir, RelDir, Rules) ->
    case file:list_dir(AbsDir) of
        {ok, Entries} ->
            lists:flatmap(
                fun(Entry) -> walk_entry(AbsDir, RelDir, Entry, Rules) end,
                lists:sort(Entries));
        {error, _Reason} ->
            []
    end.

walk_entry(AbsDir, RelDir, Entry, Rules) ->
    AbsPath = filename:join(AbsDir, Entry),
    RelPath = case RelDir of
        "" -> Entry;
        _ -> RelDir ++ "/" ++ Entry
    end,
    case filelib:is_dir(AbsPath) of
        true ->
            case symbolic_gitignore:ignored(RelPath, true, Rules) of
                true -> [];
                false -> walk(AbsPath, RelPath, Rules)
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
    case scan(Dir) of
        {ok, {_Files, Facts}} ->
            maybe_store(DbPath, Facts),
            lists:foreach(fun print_fact/1, Facts),
            halt(0);
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
    case resolve_config(ConfigOverride) of
        {ok, ConfigPath} ->
            case symbolic_config:read(ConfigPath) of
                {ok, Paths} -> run_paths(Paths, DbPath);
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

run_paths(Paths, DbPath) ->
    case scan_paths(Paths) of
        {ok, {_Files, Facts}} ->
            maybe_store(DbPath, Facts),
            lists:foreach(fun print_fact/1, Facts),
            halt(0);
        {error, Reason} -> halt_error(Reason)
    end.

halt_error(Reason) ->
    io:put_chars(standard_error, error_message(Reason)),
    halt(1).

error_message({no_such_directory, Dir}) ->
    io_lib:format("parse: no such directory: ~s~n", [Dir]);
error_message({no_such_path, Path}) ->
    io_lib:format("parse: no such file or directory: ~s~n", [Path]);
error_message({unsupported_file, Path}) ->
    io_lib:format(
        "parse: ~s has no extension symbolic knows how to extract "
        "(expected one of .erl/.ts/.md/.toml/.json/.sh/.bash)~n", [Path]);
error_message({no_such_config, ConfigPath}) ->
    io_lib:format("parse: no such config file: ~s~n", [ConfigPath]);
error_message({no_config_found, StartDir}) ->
    io_lib:format(
        "parse: no directory given and no .symbolic/config.json found "
        "walking up from ~s (or the current directory) - pass a "
        "directory, or -config <file>, or add .symbolic/config.json~n",
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
maybe_store(DbPath, Facts) -> symbolic_fact_store:write(DbPath, Facts).

%% ~ts, not ~s: jsx:encode/1 returns a binary that's already-encoded
%% UTF-8 bytes (e.g. free text from ts_extract_text:to_text/1). ~s
%% treats a binary argument as a flat list of Latin-1 codepoints and
%% re-encodes each one — for any byte above 127 (part of a multi-byte
%% UTF-8 sequence, like an em dash) that doubly UTF-8-encodes it into
%% mojibake. Confirmed by hitting it for real: dogfooding `symbolic
%% parse` against this project's own em-dash-heavy comments.
print_fact(Fact) ->
    io:format("~ts~n", [jsx:encode(symbolic_term_json:encode_term(Fact))]).
