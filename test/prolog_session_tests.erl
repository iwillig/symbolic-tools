-module(prolog_session_tests).
-include_lib("eunit/include/eunit.hrl").

-define(FIXTURE, "test/fixtures/sample.pl").

consult_and_query_test() ->
    {ok, Pid} = prolog_session:start_link(),
    ?assertEqual(ok, prolog_session:consult(Pid, ?FIXTURE)),
    {ok, Bindings} = prolog_session:query(Pid, "foo(X)"),
    ?assertEqual([{'X', bar}], Bindings),
    prolog_session:stop(Pid).

consult_and_query_multi_arg_test() ->
    {ok, Pid} = prolog_session:start_link(),
    ok = prolog_session:consult(Pid, ?FIXTURE),
    {ok, Bindings} = prolog_session:query(Pid, "depends_on(module_a, X)"),
    ?assertEqual([{'X', module_b}], Bindings),
    prolog_session:stop(Pid).

no_solution_test() ->
    {ok, Pid} = prolog_session:start_link(),
    ok = prolog_session:consult(Pid, ?FIXTURE),
    ?assertEqual(no_solution, prolog_session:query(Pid, "foo(quux)")),
    prolog_session:stop(Pid).

missing_fact_file_test() ->
    {ok, Pid} = prolog_session:start_link(),
    ?assertMatch({error, _}, prolog_session:consult(Pid, "test/fixtures/does_not_exist.pl")),
    prolog_session:stop(Pid).

%% consult_string/2's own error branch — distinct from consult/2's above
%% (a different handle_call clause; each writes the text to a temp file
%% first, so the failure mode is a genuine syntax error, not a missing
%% file).
consult_string_malformed_text_is_error_test() ->
    {ok, Pid} = prolog_session:start_link(),
    ?assertMatch({error, _}, prolog_session:consult_string(Pid, "foo(bar" )),
    prolog_session:stop(Pid).

%% ensure_terminated/1's `true` branch: a goal already ending in "."
%% works the same as one without.
query_already_terminated_goal_test() ->
    {ok, Pid} = prolog_session:start_link(),
    ok = prolog_session:consult(Pid, ?FIXTURE),
    ?assertEqual({ok, [{'X', bar}]}, prolog_session:query(Pid, "foo(X).")),
    prolog_session:stop(Pid).

%% tmp_dir/0's fallback branch: with $TMPDIR unset, consult_string/2
%% (the only caller of tmp_path/0) must still work, writing its scratch
%% file under "/tmp" directly.
consult_string_works_without_tmpdir_env_test() ->
    Original = os:getenv("TMPDIR"),
    true = os:unsetenv("TMPDIR"),
    try
        {ok, Pid} = prolog_session:start_link(),
        ?assertEqual(ok, prolog_session:consult_string(Pid, "foo(bar).")),
        prolog_session:stop(Pid)
    after
        case Original of
            false -> ok;
            _ -> os:putenv("TMPDIR", Original)
        end
    end.

handle_cast_is_a_noop_test() ->
    ?assertEqual({noreply, some_state}, prolog_session:handle_cast(ignored, some_state)).

code_change_keeps_state_test() ->
    ?assertEqual({ok, some_state}, prolog_session:code_change(old_vsn, some_state, extra)).

malformed_goal_test() ->
    {ok, Pid} = prolog_session:start_link(),
    ok = prolog_session:consult(Pid, ?FIXTURE),
    ?assertMatch({error, _}, prolog_session:query(Pid, "this is not valid prolog (")),
    prolog_session:stop(Pid).

undefined_predicate_test() ->
    {ok, Pid} = prolog_session:start_link(),
    ok = prolog_session:consult(Pid, ?FIXTURE),
    ?assertMatch({error, _}, prolog_session:query(Pid, "nonexistent_predicate(X)")),
    prolog_session:stop(Pid).

%% load_facts/2 asserts pre-built Erlang terms directly — no text
%% parsing, so a binary value with an embedded quote (the exact shape
%% that broke erlog_io:writeq1/1-based round trips) needs no escaping
%% at all to load and query correctly.
load_facts_and_query_test() ->
    {ok, Pid} = prolog_session:start_link(),
    ok = prolog_session:load_facts(Pid, [
        {defines, foo, 'file.erl', 3},
        {comment, 'file.erl', 1, <<"it's a test">>}
    ]),
    {ok, Bindings} = prolog_session:query(Pid, "defines(foo, File, Line)"),
    ?assertEqual([{'File', 'file.erl'}, {'Line', 3}], Bindings),
    {ok, TextBindings} = prolog_session:query(Pid, "comment(_, _, Text)"),
    ?assertEqual([{'Text', <<"it's a test">>}], TextBindings),
    prolog_session:stop(Pid).
