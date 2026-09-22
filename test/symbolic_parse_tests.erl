-module(symbolic_parse_tests).
-include_lib("eunit/include/eunit.hrl").

%% scan/1 (the side-effect-free core) is already exercised end-to-end by
%% symbolic_codebase_tests.erl, which is the main consumer. This module
%% covers the rest of run/2's body: maybe_store/2, print_fact/1, and
%% error_message/1 (the exact text printed for each scan/1 error, pulled
%% out specifically so it's assertable without calling run/2 itself,
%% which halt()s on every path).

error_message_no_such_directory_test() ->
    Text = lists:flatten(symbolic_parse:error_message({no_such_directory, "no/such/dir"})),
    ?assertEqual("parse: no such directory: no/such/dir\n", Text).

error_message_nif_not_loadable_test() ->
    Text = lists:flatten(symbolic_parse:error_message({nif_not_loadable, some_reason})),
    ?assertEqual(
        "parse: symbolic_ts (the tree-sitter NIF) isn't loadable "
        "in this build - a known packaging limitation, not a code "
        "bug. Run via a `rebar3 release` (or `rebar3 shell`); see "
        "docs/cli-erlang.md.\n",
        Text).

maybe_store_undefined_is_noop_test() ->
    ?assertEqual(ok, symbolic_parse:maybe_store(undefined, [{defines, foo, 0, <<"()">>, f, 1}])).

maybe_store_writes_to_dets_test() ->
    Path = filename:join(["_build", "parse_maybe_store_test_scratch.dets"]),
    Facts = [{defines, foo, 0, <<"()">>, 'f.erl', 1}],
    ?assertEqual(ok, symbolic_parse:maybe_store(Path, Facts)),
    ?assertEqual(Facts, symbolic_fact_store:read(Path)),
    ok = file:delete(Path).

%% Execution-only (see symbolic_query_tests.erl's print_bindings/1 note)
%% — print_fact/1 is a pure io:format wrapper with no branching logic to
%% assert on beyond "it doesn't crash on a real fact term".
print_fact_does_not_crash_test() ->
    ?assertEqual(
        ok,
        begin symbolic_parse:print_fact({defines, foo, 0, <<"()">>, 'f.erl', 1}), ok end).
