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
            "analyze" => analyze_cmd(),
            "query" => query_cmd(),
            "parse" => parse_cmd(),
            "serve" => serve_cmd(),
            "extract" => extract_cmd(),
            "check" => check_cmd(),
            "search" => search_cmd(),
            "search-functions" => search_functions_cmd(),
            "ask" => ask_cmd(),
            "overview" => overview_cmd()
        }
    }.

analyze_cmd() ->
    #{
        help => "Split English text into sentences and annotated tokens",
        arguments => [#{name => text, help => "English text to analyze"}],
        handler => fun(#{text := Text}) -> symbolic_analyze:run(Text) end
    }.

query_cmd() ->
    #{
        help => "Load a fact database and prove a goal against it",
        arguments => [
            #{name => db, long => "db", required => false,
              help => "Path to a fact database (.dets); defaults to the project's configured database"},
            #{name => rules, long => "rules", required => false,
              help => "Hand-written Prolog rule file (.pl) to consult alongside the facts. "
                      "Defaults to the nearest .symbolic/rules.pl, searched upwards from the "
                      "fact database and then the current directory"},
            #{name => no_rules, long => "no-rules", type => boolean, default => false,
              help => "Skip the automatic .symbolic/rules.pl lookup (an explicit -rules still applies)"},
            #{name => goal, help => "Goal to prove, e.g. \"foo(X)\""}
        ],
        handler => fun(Args) ->
            Db = resolve_database(Args, undefined, true),
            #{goal := Goal} = Args,
            symbolic_query:run(Db, maps:get(rules, Args, undefined),
                maps:get(no_rules, Args, false), Goal)
        end
    }.

parse_cmd() ->
    #{
        help => "Parse the paths listed in the project's .symbolic/config.json",
        handler => fun(_) -> symbolic_parse:run_config(undefined, undefined) end
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
            #{name => db, long => "db", required => false,
              help => "Path to a fact database (.dets); defaults to the project's configured database"},
            #{name => limit, long => "limit", type => integer, default => 10,
              help => "Maximum number of results (default 10, must be >= 1)"},
            #{name => query, help => "Search query — plain words, e.g. \"inverted index\""}
        ],
        handler => fun(Args) ->
            Db = resolve_database(Args, undefined, true),
            #{query := Query} = Args,
            symbolic_search:run(Db, Query, maps:get(limit, Args, 10))
        end
    }.

search_functions_cmd() ->
    #{
        help => "Rank function definitions by exact, prefix, and full-text name matches",
        arguments => [
            #{name => db, long => "db", required => false,
              help => "Path to a fact database (.dets); defaults to the project's configured database"},
            #{name => limit, long => "limit", type => integer, default => 10,
              help => "Maximum number of results (default 10, must be >= 1)"},
            #{name => query, help => "Function name or identifier terms, optionally with /arity"}
        ],
        handler => fun(Args) ->
            Db = resolve_database(Args, undefined, true),
            #{query := Query} = Args,
            symbolic_search:run_functions(Db, Query, maps:get(limit, Args, 10))
        end
    }.

overview_cmd() ->
    #{
        help => "Report fact counts in a persisted fact database",
        arguments => [#{name => db, long => "db", required => false,
                       help => "Path to a fact database (.dets); defaults to the project's configured database"}],
        handler => fun(Args) -> symbolic_overview:run(resolve_database(Args, undefined, true)) end
    }.

ask_cmd() ->
    #{
        help => "Answer a bounded English question or list supported ASK operations. "
                "Parse the project first if its fact database does not exist.",
        arguments => [
            #{name => db, long => "db", required => false,
              help => "Path to a fact database (.dets); defaults to the project's configured database"},
            #{name => catalog, long => "catalog", type => boolean, default => false,
              help => "Print the supported ASK operations and their contracts as JSON"},
            #{name => question, required => false,
              help => "Question, e.g. \"how many functions call query_binary/2?\""}
        ],
        handler => fun(Args) ->
            case maps:get(catalog, Args, false) of
                true -> io:format("~ts~n", [jsx:encode(symbolic_ask_catalog:describe())]);
                false ->
                    case maps:find(question, Args) of
                        {ok, Question} ->
                            Db = resolve_database(Args, undefined, true),
                            symbolic_ask:run(Db, Question);
                        error ->
                            io:put_chars(standard_error,
                                "Provide a question or use -catalog.\n"),
                            halt(2)
                    end
            end
        end
    }.

check_cmd() ->
    #{
        help => "Extract a claim from a sentence and check it against a fact database "
                "in one step (see docs/reviewing-llm-output.md)",
        arguments => [
            #{name => db, long => "db", required => false,
              help => "Path to a fact database (.dets); defaults to the project's configured database"},
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
            Db = resolve_database(Args, undefined, true),
            #{sentence := Sentence} = Args,
            symbolic_check:run(Db, maps:get(rules, Args, undefined),
                maps:get(no_rules, Args, false), Sentence, maps:get(model, Args, undefined))
        end
    }.

resolve_database(Args, StartDir, Required) ->
    case maps:get(db, Args, undefined) of
        DbPath when is_list(DbPath), DbPath =/= [] -> DbPath;
        undefined ->
            case database_start_dir(StartDir) of
                {ok, Dir} ->
                    case symbolic_config:default_database(Dir) of
                        {ok, DbPath} when is_list(DbPath) -> DbPath;
                        {ok, undefined} when Required ->
                            cli_error("database required: pass -db or set the database key in .symbolic/config.json");
                        {ok, undefined} -> undefined;
                        {error, Reason} ->
                            cli_error(io_lib:format("cannot read project database setting: ~p", [Reason]))
                    end;
                {error, Reason} ->
                    cli_error(io_lib:format("cannot determine project directory: ~p", [Reason]))
            end;
        _InvalidDb -> cli_error("database path must be a non-empty string")
    end.

database_start_dir(undefined) -> file:get_cwd();
database_start_dir(Dir) -> {ok, Dir}.

cli_error(Message) ->
    io:put_chars(standard_error, [Message, "~n"]),
    halt(2).
