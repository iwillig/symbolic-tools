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

%% The CLI entry point: argv through argparse's command tree (cli/0
%% below). argparse owns usage text, help, and bad-input halts.
main(Argv) ->
    argparse:run(Argv, cli(), #{progname => "symbolic"}).

%% The argparse command tree, one entry per subcommand module
%% (symbolic_query, symbolic_parse, symbolic_serve, symbolic_extract,
%% symbolic_check). Exported for symbolic_cli_tests.erl only — tests
%% inspect help text and call handler closures directly rather than go
%% through argparse:run/3.
cli() ->
    #{
        commands => #{
            "query" => query_cmd(),
            "parse" => parse_cmd(),
            "serve" => serve_cmd(),
            "extract" => extract_cmd(),
            "check" => check_cmd(),
            "search" => search_cmd()
        }
    }.

query_cmd() ->
    #{
        help => "Load a fact database and prove a goal against it",
        arguments => [
            #{name => db, long => "db", required => true,
              help => "Path to a fact database (.dets), written by `symbolic parse --db`"},
            #{name => rules, long => "rules", required => false,
              help => "Hand-written Prolog rule file (.pl) to consult alongside the facts. "
                      "Defaults to the nearest .symbolic/rules.pl, searched upwards from the "
                      "fact database and then the current directory"},
            #{name => no_rules, long => "no-rules", type => boolean, default => false,
              help => "Skip the automatic .symbolic/rules.pl lookup (an explicit -rules still applies)"},
            #{name => goal, help => "Goal to prove, e.g. \"foo(X)\""}
        ],
        handler => fun(Args) ->
            #{db := Db, goal := Goal} = Args,
            symbolic_query:run(Db, maps:get(rules, Args, undefined),
                maps:get(no_rules, Args, false), Goal)
        end
    }.

parse_cmd() ->
    #{
        help => "Walk a folder, extract Prolog facts, and print them as JSON",
        arguments => [
            #{name => dir, nargs => 'maybe', required => false, default => undefined,
              help => "Directory to walk. Omit to scan every path listed in the project's "
                      ".symbolic/config.json instead (see -config)"},
            #{name => db, long => "db", required => false,
              help => "Also write facts to this fact database (.dets), for `symbolic query --db`"},
            #{name => config, long => "config", required => false,
              help => "Config file (JSON, {\"paths\": [...]}) listing multiple paths to merge "
                      "into one scan. Only used when Dir is omitted; defaults to the nearest "
                      ".symbolic/config.json, searched upwards from the current directory"}
        ],
        handler => fun(Args) ->
            DbPath = maps:get(db, Args, undefined),
            case maps:get(dir, Args, undefined) of
                undefined -> symbolic_parse:run_config(maps:get(config, Args, undefined), DbPath);
                Dir -> symbolic_parse:run(Dir, DbPath)
            end
        end
    }.

serve_cmd() ->
    #{
        help => "Start the MCP server over stdio (parse / query / overview)",
        handler => fun(_) ->
            symbolic_serve:run()
        end
    }.

extract_cmd() ->
    #{
        help => "Parse a short, bounded-vocabulary sentence into an svo(Subject, Verb, Object) "
                "claim (see docs/reviewing-llm-output.md)",
        arguments => [
            #{name => sentence, help => "Sentence to extract, e.g. \"foo/2 calls bar/1\""},
            #{name => model, long => "model", required => false,
              help => "GGUF model path -- used only when the bounded grammar can't parse "
                      "the sentence (see docs/reviewing-llm-output.md §4, "
                      "docs/symbolic-extract-llm-setup.md)"}
        ],
        handler => fun(Args) ->
            #{sentence := Sentence} = Args,
            symbolic_extract:run(Sentence, maps:get(model, Args, undefined))
        end
    }.

search_cmd() ->
    #{
        help => "Full-text search over the prose facts (comments, paragraphs, headings, "
                "block quotes) in a fact database (see docs/full-text-search.md)",
        arguments => [
            #{name => db, long => "db", required => true,
              help => "Path to a fact database (.dets), written by `symbolic parse --db`"},
            #{name => limit, long => "limit", type => integer, default => 10,
              help => "Maximum number of results (default 10, must be >= 1)"},
            #{name => query, help => "Search query — plain words, e.g. \"inverted index\""}
        ],
        handler => fun(Args) ->
            #{db := Db, query := Query} = Args,
            symbolic_search:run(Db, Query, maps:get(limit, Args, 10))
        end
    }.

check_cmd() ->
    #{
        help => "Extract a claim from a sentence and check it against a fact database "
                "in one step (see docs/reviewing-llm-output.md)",
        arguments => [
            #{name => db, long => "db", required => true,
              help => "Path to a fact database (.dets), written by `symbolic parse --db`"},
            #{name => rules, long => "rules", required => false,
              help => "Hand-written Prolog rule file (.pl) to consult alongside the facts. "
                      "Defaults to the nearest .symbolic/rules.pl, searched upwards from the "
                      "fact database and then the current directory"},
            #{name => no_rules, long => "no-rules", type => boolean, default => false,
              help => "Skip the automatic .symbolic/rules.pl lookup (an explicit -rules still "
                      "applies) -- check_claim/2 itself lives there, so this makes every claim "
                      "unverifiable unless -rules points somewhere else that defines it"},
            #{name => model, long => "model", required => false,
              help => "GGUF model path -- used only when the bounded grammar can't parse "
                      "the sentence (see docs/reviewing-llm-output.md §4, "
                      "docs/symbolic-extract-llm-setup.md)"},
            #{name => sentence, help => "Sentence to extract and check, e.g. \"foo/2 calls bar/1\""}
        ],
        handler => fun(Args) ->
            #{db := Db, sentence := Sentence} = Args,
            symbolic_check:run(Db, maps:get(rules, Args, undefined),
                maps:get(no_rules, Args, false), Sentence, maps:get(model, Args, undefined))
        end
    }.
