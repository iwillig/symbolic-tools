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
-export([run/1, run/2]).

run(Dir) ->
    run(Dir, undefined).

run(Dir, DbPath) ->
    case filelib:is_dir(Dir) of
        true -> run_checked(Dir, DbPath);
        false ->
            io:put_chars(standard_error,
                io_lib:format("parse: no such directory: ~s~n", [Dir])),
            halt(1)
    end.

run_checked(Dir, DbPath) ->
    case code:ensure_loaded(symbolic_ts) of
        {module, symbolic_ts} ->
            Files = filelib:wildcard(filename:join(Dir, "**/*.erl")) ++
                    filelib:wildcard(filename:join(Dir, "**/*.ts")) ++
                    filelib:wildcard(filename:join(Dir, "**/*.md")) ++
                    filelib:wildcard(filename:join(Dir, "**/*.toml")) ++
                    filelib:wildcard(filename:join(Dir, "**/*.json")) ++
                    filelib:wildcard(filename:join(Dir, "**/*.sh")) ++
                    filelib:wildcard(filename:join(Dir, "**/*.bash")),
            Facts = lists:usort(lists:flatmap(fun ts_extract:file/1, Files)),
            maybe_store(DbPath, Facts),
            lists:foreach(fun print_fact/1, Facts),
            halt(0);
        {error, _} ->
            %% Known limitation, not a bug in this code: the escript build
            %% doesn't (can't) embed symbolic_ts's NIF .so — see
            %% rebar.config's escript_incl_apps comment and
            %% docs/cli-erlang.md. Run via `rebar3 shell` (or a
            %% `rebar3 release`) instead of the escript binary until
            %% that's resolved.
            io:put_chars(standard_error,
                "parse: symbolic_ts (the tree-sitter NIF) isn't loadable "
                "from this escript binary — a known packaging limitation, "
                "not a code bug. Run via `rebar3 shell` for now; see "
                "docs/cli-erlang.md.\n"),
            halt(1)
    end.

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
