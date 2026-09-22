-module(symbolic_cli_tests).
-include_lib("eunit/include/eunit.hrl").

%% cli/0 builds the argparse command tree; its structure (help text,
%% required flags) is asserted directly. Each subcommand's `handler`
%% closure calls straight into symbolic_query:run/4, symbolic_parse:run/2,
%% or symbolic_serve:run/0 — all of which halt() or run forever — so
%% those three modules are meck-mocked here to verify the handler
%% extracts and forwards its Args map correctly, without ever running
%% the real (halting) implementation. main/1 itself (argparse:run/3) is
%% NOT tested here for the same reason: it dispatches straight to these
%% same handlers.

cli_structure_test() ->
    #{commands := Commands} = symbolic_cli:cli(),
    ?assertEqual(["parse", "query", "serve"], lists:sort(maps:keys(Commands))).

query_cmd_requires_db_and_goal_test() ->
    #{commands := #{"query" := #{arguments := Args}}} = symbolic_cli:cli(),
    #{db := Db, rules := Rules, no_rules := NoRules, goal := Goal} = args_by_name(Args),
    ?assertEqual(true, maps:get(required, Db)),
    ?assertEqual(false, maps:get(required, Rules)),
    %% -no-rules is a switch: boolean-typed and defaulted to false, so it
    %% is never absent from the Args map the handler receives.
    ?assertEqual(boolean, maps:get(type, NoRules)),
    ?assertEqual(false, maps:get(default, NoRules)),
    %% `goal` is positional (no `long`), so it has no `required` key at
    %% all — argparse treats every positional as required by default.
    ?assertEqual(false, maps:is_key(required, Goal)).

parse_cmd_db_is_optional_test() ->
    #{commands := #{"parse" := #{arguments := Args}}} = symbolic_cli:cli(),
    #{db := Db} = args_by_name(Args),
    ?assertEqual(false, maps:get(required, Db)).

query_handler_forwards_db_rules_goal_test() ->
    meck:new(symbolic_query),
    meck:expect(symbolic_query, run, fun(_Db, _Rules, _NoRules, _Goal) -> ok end),
    #{commands := #{"query" := #{handler := Handler}}} = symbolic_cli:cli(),
    Handler(#{db => "facts.dets", rules => "rules.pl", no_rules => false, goal => "foo(X)"}),
    ?assert(meck:called(symbolic_query, run,
        ["facts.dets", "rules.pl", false, "foo(X)"])),
    meck:unload(symbolic_query).

%% `rules` absent entirely from Args (the CLI flag wasn't passed) ->
%% the handler must default it to `undefined`, not crash on maps:get.
%% `undefined` is also precisely what triggers .symbolic/rules.pl
%% discovery downstream (resolve_rules/3, covered in
%% symbolic_query_tests.erl — the run/4 mocked here is where it happens).
%% `no_rules` defaults to false the same way.
query_handler_defaults_missing_rules_test() ->
    meck:new(symbolic_query),
    meck:expect(symbolic_query, run, fun(_Db, _Rules, _NoRules, _Goal) -> ok end),
    #{commands := #{"query" := #{handler := Handler}}} = symbolic_cli:cli(),
    Handler(#{db => "facts.dets", goal => "foo(X)"}),
    ?assert(meck:called(symbolic_query, run,
        ["facts.dets", undefined, false, "foo(X)"])),
    meck:unload(symbolic_query).

%% -no-rules given: forwarded as true, not silently dropped by the handler.
query_handler_forwards_no_rules_test() ->
    meck:new(symbolic_query),
    meck:expect(symbolic_query, run, fun(_Db, _Rules, _NoRules, _Goal) -> ok end),
    #{commands := #{"query" := #{handler := Handler}}} = symbolic_cli:cli(),
    Handler(#{db => "facts.dets", no_rules => true, goal => "foo(X)"}),
    ?assert(meck:called(symbolic_query, run,
        ["facts.dets", undefined, true, "foo(X)"])),
    meck:unload(symbolic_query).

parse_handler_forwards_dir_and_db_test() ->
    meck:new(symbolic_parse),
    meck:expect(symbolic_parse, run, fun(_Dir, _Db) -> ok end),
    #{commands := #{"parse" := #{handler := Handler}}} = symbolic_cli:cli(),
    Handler(#{dir => "src", db => "facts.dets"}),
    ?assert(meck:called(symbolic_parse, run, ["src", "facts.dets"])),
    meck:unload(symbolic_parse).

parse_handler_defaults_missing_db_test() ->
    meck:new(symbolic_parse),
    meck:expect(symbolic_parse, run, fun(_Dir, _Db) -> ok end),
    #{commands := #{"parse" := #{handler := Handler}}} = symbolic_cli:cli(),
    Handler(#{dir => "src"}),
    ?assert(meck:called(symbolic_parse, run, ["src", undefined])),
    meck:unload(symbolic_parse).

serve_handler_calls_run_test() ->
    meck:new(symbolic_serve),
    meck:expect(symbolic_serve, run, fun() -> ok end),
    #{commands := #{"serve" := #{handler := Handler}}} = symbolic_cli:cli(),
    Handler(#{}),
    ?assert(meck:called(symbolic_serve, run, [])),
    meck:unload(symbolic_serve).

args_by_name(Args) ->
    maps:from_list([{maps:get(name, A), A} || A <- Args]).
