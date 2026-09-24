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
-export([run/1, run/2, scan/1]).
%% Exported for symbolic_parse_tests.erl only — run/1,2 halt() on every
%% path and can't be called directly from EUnit; maybe_store/2 and
%% print_fact/1 are the halt-free parts of that same code worth testing
%% in isolation.
-export([maybe_store/2, print_fact/1, error_message/1]).

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
                    Facts = lists:usort(lists:flatmap(fun extract_file_timed/1, Files)),
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
extract_file_timed(File) ->
    Start = erlang:monotonic_time(millisecond),
    Facts = ts_extract:file(File),
    ElapsedMs = erlang:monotonic_time(millisecond) - Start,
    ?LOG_INFO("parse: ~s - ~p facts, ~p ms", [File, length(Facts), ElapsedMs]),
    Facts.

%% Extensions matcher below to a language ts_extract:file/1 knows how to
%% handle. Kept as a list (not a set) — 7 entries, checked once per file.
-define(SCAN_EXTENSIONS, [".erl", ".ts", ".md", ".toml", ".json", ".sh", ".bash"]).

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

error_message({no_such_directory, Dir}) ->
    io_lib:format("parse: no such directory: ~s~n", [Dir]);
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
