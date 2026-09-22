%%% Thin entry point: an argparse command tree dispatching to a
%%% per-subcommand module. See docs/cli-erlang.md.
%%%
%%% argparse (stdlib) owns usage/help text and error/halt behavior on bad
%%% input — see https://www.erlang.org/doc/apps/stdlib/argparse.html.
-module(symbolic_cli).
-export([main/1]).
%% Exported for symbolic_cli_tests.erl only — lets it inspect the
%% argparse command tree (help text, required flags) and invoke each
%% handler closure directly (mocking the downstream halt()-invoking
%% modules with meck) without going through argparse:run/3 itself.
-export([cli/0]).

main(Argv) ->
    argparse:run(Argv, cli(), #{progname => "symbolic"}).

cli() ->
    #{
        commands => #{
            "query" => query_cmd(),
            "parse" => parse_cmd(),
            "serve" => serve_cmd()
        }
    }.

query_cmd() ->
    #{
        help => "Load a fact database and prove a goal against it",
        arguments => [
            #{name => db, long => "db", required => true,
              help => "Path to a fact database (.dets), written by `symbolic parse --db`"},
            #{name => rules, long => "rules", required => false,
              help => "Optional hand-written Prolog rule file (.pl) to consult alongside the facts"},
            #{name => goal, help => "Goal to prove, e.g. \"foo(X)\""}
        ],
        handler => fun(Args) ->
            #{db := Db, goal := Goal} = Args,
            symbolic_query:run(Db, maps:get(rules, Args, undefined), Goal)
        end
    }.

parse_cmd() ->
    #{
        help => "Walk a folder, extract Prolog facts, and print them as JSON",
        arguments => [
            #{name => dir, help => "Directory to walk"},
            #{name => db, long => "db", required => false,
              help => "Also write facts to this fact database (.dets), for `symbolic query --db`"}
        ],
        handler => fun(Args) ->
            #{dir := Dir} = Args,
            symbolic_parse:run(Dir, maps:get(db, Args, undefined))
        end
    }.

serve_cmd() ->
    #{
        help => "Start the MCP server over stdio (parse / query / overview)",
        handler => fun(_) ->
            symbolic_serve:run()
        end
    }.
