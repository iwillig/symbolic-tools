%%% Thin entry point: an argparse command tree dispatching to a
%%% per-subcommand module. See docs/cli-erlang.md.
%%%
%%% argparse (stdlib) owns usage/help text and error/halt behavior on bad
%%% input — see https://www.erlang.org/doc/apps/stdlib/argparse.html.
-module(symbolic_cli).
-export([main/1]).

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
        help => "Load a Prolog fact file and prove a goal against it",
        arguments => [
            #{name => file, long => "file", required => true,
              help => "Path to a Prolog fact file (.pl)"},
            #{name => goal, help => "Goal to prove, e.g. \"foo(X)\""}
        ],
        handler => fun(#{file := File, goal := Goal}) ->
            symbolic_query:run(File, Goal)
        end
    }.

parse_cmd() ->
    #{
        help => "Walk a folder and extract Prolog facts from .erl files",
        arguments => [
            #{name => dir, help => "Directory to walk"}
        ],
        handler => fun(#{dir := Dir}) ->
            symbolic_parse:run(Dir)
        end
    }.

serve_cmd() ->
    #{
        help => "Start the MCP server (not yet implemented)",
        handler => fun(_) ->
            symbolic_serve:run()
        end
    }.
