-module(ts_extract_dispatch_tests).
-include_lib("eunit/include/eunit.hrl").

%% ts_extract:file/1 is the per-extension dispatcher — distinct from
%% ts_extract_erlang.erl (etc.), which every other *_tests.erl module
%% calls directly, never through this dispatcher. Confirms each
%% extension actually reaches the right extractor module, not just that
%% the extractor works when called directly.

%% Written to a scratch path under _build/ at test-run time, not a
%% committed test/fixtures/*.erl file — rebar3's eunit provider compiles
%% every .erl file under test/ as a project module, so a real one there
%% collides with the build (confirmed: "Module `sample' not found").
dispatches_ruby_test() ->
    Source = <<"# file comment\ndef greet(name)\n  puts name\nend\n">>,
    Facts = ts_extract_ruby:text("sample.rb", Source),
    ?assert(lists:member({defines, greet, 1, <<"(name)">>, 'sample.rb', 2}, Facts)),
    ?assert(lists:member({comment, 'sample.rb', 1, <<"# file comment">>}, Facts)),
    ?assert(lists:member({calls, greet, 1, {local, puts, 1}, 'sample.rb', 3}, Facts)).

dispatches_rb_test() ->
    ?assertEqual(
        ts_extract_ruby:file("test/fixtures/ruby_sample.rb"),
        ts_extract:file("test/fixtures/ruby_sample.rb")).

dispatches_clojure_test() ->
    Source = <<"; file comment\n(defn not-a-real-function [] (println name))\n">>,
    Facts = ts_extract_clojure:text("sample.clj", Source),
    ?assert(lists:member({comment, 'sample.clj', 1, <<"; file comment">>}, Facts)),
    ?assertEqual([], [F || F = {defines, _, _, _, _, _} <- Facts]),
    ?assertEqual([], [F || F = {calls, _, _, _, _, _} <- Facts]).

dispatches_clj_test() ->
    ?assertEqual(
        ts_extract_clojure:file("test/fixtures/clojure_sample.clj"),
        ts_extract:file("test/fixtures/clojure_sample.clj")).

dispatches_erl_test() ->
    Path = filename:join(["_build", "erl_dispatch_test_scratch.erl"]),
    ok = file:write_file(Path, <<"-module(erl_dispatch_test_scratch).\n"
                                  "-export([one/0]).\n"
                                  "one() -> ok.\n">>),
    ?assertEqual(
        ts_extract_erlang:file(Path),
        ts_extract:file(Path)),
    ok = file:delete(Path).

rust_grammar_loads_and_parses_test() ->
    {ok, Parser} = symbolic_ts:parser_new(),
    {ok, Lang} = symbolic_ts:tree_sitter_rust(),
    ?assertEqual(true, symbolic_ts:parser_set_language(Parser, Lang)),
    Tree = symbolic_ts:parser_parse_string(Parser, <<"fn answer() -> u32 { 42 }\n">>),
    Root = symbolic_ts:tree_root_node(Tree),
    ?assertEqual("source_file", symbolic_ts:node_type(Root)),
    Function = symbolic_ts:node_named_child(Root, 0),
    ?assertEqual("function_item", symbolic_ts:node_type(Function)).

dispatches_rust_test() ->
    ?assertEqual(
        ts_extract_rust:file("test/fixtures/rust_sample.rs"),
        ts_extract:file("test/fixtures/rust_sample.rs")).

dispatches_ts_test() ->
    ?assertEqual(
        ts_extract_typescript:file("test/fixtures/sample.ts"),
        ts_extract:file("test/fixtures/sample.ts")).

dispatches_md_test() ->
    ?assertEqual(
        ts_extract_markdown:file("test/fixtures/sample.md"),
        ts_extract:file("test/fixtures/sample.md")).

dispatches_toml_test() ->
    ?assertEqual(
        ts_extract_toml:file("test/fixtures/sample.toml"),
        ts_extract:file("test/fixtures/sample.toml")).

dispatches_json_test() ->
    ?assertEqual(
        ts_extract_json:file("test/fixtures/sample.json"),
        ts_extract:file("test/fixtures/sample.json")).

dispatches_sh_test() ->
    ?assertEqual(
        ts_extract_bash:file("test/fixtures/sample.sh"),
        ts_extract:file("test/fixtures/sample.sh")).

dispatches_bash_test() ->
    ?assertEqual(
        ts_extract_bash:file("test/fixtures/sample.bash"),
        ts_extract:file("test/fixtures/sample.bash")).
