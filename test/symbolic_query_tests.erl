-module(symbolic_query_tests).
-include_lib("eunit/include/eunit.hrl").

%% run/2,3 themselves stay untested here — they only print a result and
%% halt(), nothing left to assert on. Everything that decides *what*
%% the outcome is now lives in the halt-free run_result/3, exercised
%% directly below for every outcome shape.

-define(DB, filename:join(["_build", "symbolic_query_test_scratch.dets"])).

with_db(Facts, Test) ->
    ok = symbolic_fact_store:write(?DB, Facts),
    try Test() after file:delete(?DB) end.

run_result_missing_db_is_error_test() ->
    ?assertEqual(
        {error, {no_such_db, "no/such/facts_zz.dets"}},
        symbolic_query:run_result("no/such/facts_zz.dets", undefined, "foo(X)")).

run_result_returns_solutions_test() ->
    with_db([{defines, foo, 0, <<"()">>, 'f.erl', 1}], fun() ->
        ?assertEqual(
            {solutions, [{'File', 'f.erl'}, {'Line', 1}]},
            symbolic_query:run_result(?DB, undefined, "defines(foo, _, _, File, Line)"))
    end).

run_result_no_solution_test() ->
    with_db([{defines, foo, 0, <<"()">>, 'f.erl', 1}], fun() ->
        ?assertEqual(
            no_solution,
            symbolic_query:run_result(?DB, undefined, "defines(bar, _, _, _, _)"))
    end).

run_result_query_failed_is_error_test() ->
    with_db([{defines, foo, 0, <<"()">>, 'f.erl', 1}], fun() ->
        ?assertMatch(
            {error, {query_failed, _}},
            symbolic_query:run_result(?DB, undefined, "defines("))
    end).

run_result_rules_error_test() ->
    with_db([{defines, foo, 0, <<"()">>, 'f.erl', 1}], fun() ->
        ?assertMatch(
            {error, {rules_error, "no/such/rules_zz.pl", _}},
            symbolic_query:run_result(?DB, "no/such/rules_zz.pl", "defines(foo, _, _, _, _)"))
    end).

run_result_uses_a_rules_file_test() ->
    with_db([{defines, foo, 0, <<"()">>, 'f.erl', 1}], fun() ->
        RulesPath = filename:join(["_build", "query_run_result_rules_scratch.pl"]),
        ok = file:write_file(RulesPath, <<"named(F) :- defines(F, _, _, _, _).\n">>),
        Result = symbolic_query:run_result(?DB, RulesPath, "named(F)"),
        ok = file:delete(RulesPath),
        ?assertEqual({solutions, [{'F', foo}]}, Result)
    end).

name_to_list_atom_test() ->
    ?assertEqual("charge", symbolic_query:name_to_list(charge)).

name_to_list_integer_test() ->
    ?assertEqual("_3", symbolic_query:name_to_list(3)).

%% print_bindings/1 writes straight to stdout — execution-only here (not
%% content-captured), since standing up an io-protocol group_leader
%% collector just to check two format strings isn't worth it for a
%% CLI-output helper with no logic beyond formatting.
print_bindings_empty_is_yes_test() ->
    ?assertEqual(ok, begin symbolic_query:print_bindings([]), ok end).

print_bindings_nonempty_test() ->
    ?assertEqual(ok, begin
        symbolic_query:print_bindings([{'F', foo}, {'Line', 3}]),
        ok
    end).

maybe_consult_rules_undefined_is_ok_test() ->
    {ok, Pid} = prolog_session:start_link(),
    ?assertEqual(ok, symbolic_query:maybe_consult_rules(Pid, undefined)),
    stop_session(Pid).

maybe_consult_rules_real_file_test() ->
    {ok, Pid} = prolog_session:start_link(),
    Path = filename:join(["_build", "query_rules_test_scratch.pl"]),
    ok = file:write_file(Path, <<"double_of(X, Y) :- Y is X * 2.\n">>),
    ?assertEqual(ok, symbolic_query:maybe_consult_rules(Pid, Path)),
    ok = file:delete(Path),
    stop_session(Pid).

maybe_consult_rules_missing_file_is_error_test() ->
    {ok, Pid} = prolog_session:start_link(),
    ?assertMatch({error, _}, symbolic_query:maybe_consult_rules(Pid, "no/such/rules_zz.pl")),
    stop_session(Pid).

stop_session(Pid) ->
    unlink(Pid),
    Ref = erlang:monitor(process, Pid),
    exit(Pid, shutdown),
    receive
        {'DOWN', Ref, process, Pid, _Reason} -> ok
    after 1000 ->
        ok
    end.
