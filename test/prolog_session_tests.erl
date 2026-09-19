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
