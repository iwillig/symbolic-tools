-module(symbolic_cli_tests).
-include_lib("eunit/include/eunit.hrl").

%% cli/0 builds the argparse command tree; its structure (help text,
%% required flags) is asserted directly. Each subcommand's `handler`
%% closure calls straight into symbolic_query:run/4, symbolic_parse:run/2,
%% symbolic_serve:run/0, symbolic_extract:run/2, or symbolic_check:run/5
%% — all of which halt() or run forever — so those five modules are
%% meck-mocked here to verify the handler extracts and forwards its Args
%% map correctly, without ever running the real (halting) implementation.
%% main/1 itself (argparse:run/3) is NOT tested here for the same reason:
%% it dispatches straight to these same handlers.

cli_structure_test() ->
    #{commands := Commands} = symbolic_cli:cli(),
    ?assertEqual(["analyze", "ask", "check", "extract", "overview", "parse", "query", "search", "serve"],
        lists:sort(maps:keys(Commands))).

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

overview_handler_forwards_db_test() ->
    meck:new(symbolic_overview),
    meck:expect(symbolic_overview, run, fun(_Db) -> ok end),
    #{commands := #{"overview" := #{handler := Handler}}} = symbolic_cli:cli(),
    Handler(#{db => "facts.dets"}),
    ?assert(meck:called(symbolic_overview, run, ["facts.dets"])),
    meck:unload(symbolic_overview).

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

extract_cmd_sentence_is_positional_and_required_test() ->
    #{commands := #{"extract" := #{arguments := Args}}} = symbolic_cli:cli(),
    #{sentence := Sentence} = args_by_name(Args),
    %% Positional (no `long`), so no `required` key at all — argparse
    %% treats every positional as required by default, same as `query`'s
    %% own `goal` argument.
    ?assertEqual(false, maps:is_key(required, Sentence)).

%% --model enables §4.2 Phase 3's fallback chaining onto
%% symbolic_extract_llm — optional, so a missing flag must default to
%% `undefined`, not crash on maps:get, the same shape query_cmd's own
%% `rules` already established.
extract_cmd_model_is_an_optional_flag_test() ->
    #{commands := #{"extract" := #{arguments := Args}}} = symbolic_cli:cli(),
    #{model := Model} = args_by_name(Args),
    ?assertEqual("model", maps:get(long, Model)),
    ?assertEqual(false, maps:get(required, Model)).

extract_handler_forwards_sentence_and_defaults_missing_model_test() ->
    meck:new(symbolic_extract),
    meck:expect(symbolic_extract, run, fun(_Sentence, _ModelPath) -> ok end),
    #{commands := #{"extract" := #{handler := Handler}}} = symbolic_cli:cli(),
    Handler(#{sentence => "foo/2 calls bar/1"}),
    ?assert(meck:called(symbolic_extract, run, ["foo/2 calls bar/1", undefined])),
    meck:unload(symbolic_extract).

extract_handler_forwards_the_model_flag_when_given_test() ->
    meck:new(symbolic_extract),
    meck:expect(symbolic_extract, run, fun(_Sentence, _ModelPath) -> ok end),
    #{commands := #{"extract" := #{handler := Handler}}} = symbolic_cli:cli(),
    Handler(#{sentence => "foo/2 improves performance", model => "/models/x.gguf"}),
    ?assert(meck:called(symbolic_extract, run,
        ["foo/2 improves performance", "/models/x.gguf"])),
    meck:unload(symbolic_extract).

check_cmd_requires_db_and_sentence_test() ->
    #{commands := #{"check" := #{arguments := Args}}} = symbolic_cli:cli(),
    #{db := Db, rules := Rules, no_rules := NoRules, model := Model, sentence := Sentence} =
        args_by_name(Args),
    ?assertEqual(true, maps:get(required, Db)),
    ?assertEqual(false, maps:get(required, Rules)),
    ?assertEqual(boolean, maps:get(type, NoRules)),
    ?assertEqual(false, maps:get(default, NoRules)),
    ?assertEqual(false, maps:get(required, Model)),
    ?assertEqual(false, maps:is_key(required, Sentence)).

check_handler_forwards_all_args_test() ->
    meck:new(symbolic_check),
    meck:expect(symbolic_check, run, fun(_Db, _Rules, _NoRules, _Sentence, _Model) -> ok end),
    #{commands := #{"check" := #{handler := Handler}}} = symbolic_cli:cli(),
    Handler(#{db => "facts.dets", rules => "rules.pl", no_rules => false,
              model => "/models/x.gguf", sentence => "foo/2 calls bar/1"}),
    ?assert(meck:called(symbolic_check, run,
        ["facts.dets", "rules.pl", false, "foo/2 calls bar/1", "/models/x.gguf"])),
    meck:unload(symbolic_check).

check_handler_defaults_missing_rules_and_model_test() ->
    meck:new(symbolic_check),
    meck:expect(symbolic_check, run, fun(_Db, _Rules, _NoRules, _Sentence, _Model) -> ok end),
    #{commands := #{"check" := #{handler := Handler}}} = symbolic_cli:cli(),
    Handler(#{db => "facts.dets", sentence => "foo/2 calls bar/1"}),
    ?assert(meck:called(symbolic_check, run,
        ["facts.dets", undefined, false, "foo/2 calls bar/1", undefined])),
    meck:unload(symbolic_check).

analyze_cmd_requires_text_test() ->
    #{commands := #{"analyze" := #{arguments := Args}}} = symbolic_cli:cli(),
    #{text := Text} = args_by_name(Args),
    ?assertEqual(text, maps:get(name, Text)),
    ?assertEqual(false, maps:is_key(required, Text)).

analyze_handler_forwards_text_test() ->
    meck:new(symbolic_analyze),
    meck:expect(symbolic_analyze, run, fun(_Text) -> ok end),
    #{commands := #{"analyze" := #{handler := Handler}}} = symbolic_cli:cli(),
    Handler(#{text => "Hello world."}),
    ?assert(meck:called(symbolic_analyze, run, ["Hello world."])),
    meck:unload(symbolic_analyze).

args_by_name(Args) ->
    maps:from_list([{maps:get(name, A), A} || A <- Args]).
