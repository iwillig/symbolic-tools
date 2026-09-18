%%% The regression test docs/erlang-mcp-design.md §9 calls for: a
%%% deliberately non-terminating goal is killed within budget, and the
%%% session is still usable afterward — not just a passing case, but
%%% confirmation the kill doesn't take the session down with it.
-module(prolog_session_timeout_tests).
-include_lib("eunit/include/eunit.hrl").

-define(SHORT_TIMEOUT_MS, 200).

cyclic_goal_is_killed_within_budget_test() ->
    {ok, Pid} = prolog_session:start_link(),
    ok = prolog_session:consult_string(Pid, "loop(X) :- loop(X)."),
    Start = erlang:monotonic_time(millisecond),
    Result = prolog_session:query(Pid, "loop(a)", ?SHORT_TIMEOUT_MS),
    Elapsed = erlang:monotonic_time(millisecond) - Start,
    ?assertEqual({error, timeout}, Result),
    %% Generous upper bound so this isn't flaky under CI load, but tight
    %% enough to catch "the kill never actually happened."
    ?assert(Elapsed < ?SHORT_TIMEOUT_MS + 2000),
    prolog_session:stop(Pid).

session_usable_after_a_killed_query_test() ->
    {ok, Pid} = prolog_session:start_link(),
    ok = prolog_session:consult_string(Pid, "loop(X) :- loop(X).\nfoo(bar)."),
    {error, timeout} = prolog_session:query(Pid, "loop(a)", ?SHORT_TIMEOUT_MS),
    ?assertEqual({ok, [{'X', bar}]}, prolog_session:query(Pid, "foo(X)")),
    prolog_session:stop(Pid).
