-module(prolog_session_registry_tests).
-include_lib("eunit/include/eunit.hrl").

%% Trivial gen_server boilerplate — no registered process needed.
handle_cast_is_a_noop_test() ->
    ?assertEqual({noreply, some_state}, prolog_session_registry:handle_cast(ignored, some_state)).

terminate_returns_ok_test() ->
    ?assertEqual(ok, prolog_session_registry:terminate(shutdown, some_state)).

code_change_keeps_state_test() ->
    ?assertEqual({ok, some_state}, prolog_session_registry:code_change(old_vsn, some_state, extra)).

setup() ->
    {ok, SupPid} = prolog_session_sup:start_link(),
    {ok, RegPid} = prolog_session_registry:start_link(),
    {SupPid, RegPid}.

teardown({SupPid, RegPid}) ->
    %% exit/2 is asynchronous — without waiting for the process to
    %% actually die, the next test's setup/0 can race registering the
    %% same {local, Name} before this one's name is freed.
    stop_and_wait(RegPid),
    stop_and_wait(SupPid).

stop_and_wait(Pid) ->
    %% unlink first — both SupPid and RegPid were start_link'd from
    %% (effectively) this test process, so without unlinking, killing
    %% them would send an exit signal cascading right back and killing
    %% the current eunit test process too.
    unlink(Pid),
    Ref = erlang:monitor(process, Pid),
    exit(Pid, shutdown),
    receive
        {'DOWN', Ref, process, Pid, _Reason} -> ok
    after 1000 ->
        ok
    end.

registry_test_() ->
    {foreach, fun setup/0, fun teardown/1, [
        fun start_and_lookup_session/1,
        fun end_session_removes_it/1,
        fun lookup_of_unknown_session_is_error/1,
        fun end_session_of_unknown_session_is_error/1,
        fun consult_and_query_through_the_registry/1
    ]}.

start_and_lookup_session(_) ->
    fun() ->
        {ok, SessionId} = prolog_session_registry:start_session(),
        ?assertMatch({ok, _Pid}, prolog_session_registry:lookup(SessionId))
    end.

end_session_removes_it(_) ->
    fun() ->
        {ok, SessionId} = prolog_session_registry:start_session(),
        ?assertEqual(ok, prolog_session_registry:end_session(SessionId)),
        ?assertEqual(error, prolog_session_registry:lookup(SessionId))
    end.

lookup_of_unknown_session_is_error(_) ->
    fun() ->
        ?assertEqual(error, prolog_session_registry:lookup(<<"no-such-session">>))
    end.

end_session_of_unknown_session_is_error(_) ->
    fun() ->
        ?assertEqual(error, prolog_session_registry:end_session(<<"no-such-session">>))
    end.

consult_and_query_through_the_registry(_) ->
    fun() ->
        {ok, SessionId} = prolog_session_registry:start_session(),
        {ok, Pid} = prolog_session_registry:lookup(SessionId),
        ok = prolog_session:consult_string(Pid, "foo(bar)."),
        ?assertEqual({ok, [{'X', bar}]}, prolog_session:query(Pid, "foo(X)"))
    end.
