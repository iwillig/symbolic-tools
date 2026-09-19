%%% `symbolic parse <dir>` — walk a folder, run tree-sitter extraction,
%%% emit Prolog facts to stdout. See docs/tree-sitter-erlang.md.
-module(symbolic_parse).
-export([run/1]).

run(Dir) ->
    case filelib:is_dir(Dir) of
        true -> run_checked(Dir);
        false ->
            io:put_chars(standard_error,
                io_lib:format("parse: no such directory: ~s~n", [Dir])),
            halt(1)
    end.

run_checked(Dir) ->
    case code:ensure_loaded(erl_ts) of
        {module, erl_ts} ->
            Files = filelib:wildcard(filename:join(Dir, "**/*.erl")) ++
                    filelib:wildcard(filename:join(Dir, "**/*.ts")) ++
                    filelib:wildcard(filename:join(Dir, "**/*.md")),
            Facts = lists:usort(lists:flatmap(fun ts_extract:file/1, Files)),
            lists:foreach(fun print_fact/1, Facts),
            halt(0);
        {error, _} ->
            %% Known limitation, not a bug in this code: the escript build
            %% doesn't (can't) embed erl_ts's NIF .so — see rebar.config's
            %% escript_incl_apps comment and docs/cli-erlang.md. Run via
            %% `rebar3 shell` (or a future `rebar3 release`) instead of
            %% the escript binary until that's resolved.
            io:put_chars(standard_error,
                "parse: erl_ts (the tree-sitter NIF) isn't loadable from "
                "this escript binary — a known packaging limitation, not a "
                "code bug. Run via `rebar3 shell` for now; see "
                "docs/cli-erlang.md.\n"),
            halt(1)
    end.

print_fact(Fact) ->
    io:format("~s.~n", [erlog_io:writeq1(Fact)]).
