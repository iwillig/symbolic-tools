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
                    Facts = lists:usort(lists:flatmap(fun ts_extract:file/1, Files)),
                    {ok, {Files, Facts}};
                {error, Reason} ->
                    {error, {nif_not_loadable, Reason}}
            end;
        false ->
            {error, {no_such_directory, Dir}}
    end.

scan_files(Dir) ->
    filelib:wildcard(filename:join(Dir, "**/*.erl")) ++
    filelib:wildcard(filename:join(Dir, "**/*.ts")) ++
    filelib:wildcard(filename:join(Dir, "**/*.md")) ++
    filelib:wildcard(filename:join(Dir, "**/*.toml")) ++
    filelib:wildcard(filename:join(Dir, "**/*.json")) ++
    filelib:wildcard(filename:join(Dir, "**/*.sh")) ++
    filelib:wildcard(filename:join(Dir, "**/*.bash")).

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
