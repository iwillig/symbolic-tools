-module(symbolic_operation_status_tests).
-include_lib("eunit/include/eunit.hrl").

%% Unit tests for the status tracker gen_statem. The tracker is a
%% registered singleton, so each test stops any leftover instance first
%% and starts a fresh one, then stops it in an after block (same shape
%% as symbolic_serve_tests). Events are casts from the owning process;
%% the owner here is the test process itself except for the crash test,
%% which starts the operation from a spawned process so its 'DOWN' can
%% be observed (mirroring how symbolic_codebase owns parse/query).

with_tracker(Fun) ->
    catch gen_statem:stop(symbolic_operation_status),
    {ok, Pid} = symbolic_operation_status:start_link(),
    try
        Fun(Pid)
    after
        unlink(Pid),
        catch gen_statem:stop(symbolic_operation_status)
    end,
    ok.

reports_phases_and_outcomes_test() ->
    with_tracker(fun(_Pid) ->
        symbolic_operation_status:started(parse, <<"/tmp/some_project">>),
        symbolic_operation_status:phase(discovering),
        symbolic_operation_status:project("/tmp/some_project"),
        symbolic_operation_status:phase(extracting),
        {ok, #{state := running, active := Active, last := null}} =
            symbolic_operation_status:status(),
        ?assertEqual(parse, maps:get(kind, Active)),
        ?assertEqual(extracting, maps:get(phase, Active)),
        ?assertEqual(<<"/tmp/some_project">>, maps:get(path, Active)),
        ?assert(is_integer(maps:get(started_ms, Active))),
        ?assert(is_integer(maps:get(elapsed_ms, Active))),
        symbolic_operation_status:finished(ok),
        {ok, #{state := idle, active := null,
               last := #{kind := parse, outcome := #{status := succeeded}}}} =
            symbolic_operation_status:status(),
        ok
    end).

reports_owner_crash_test() ->
    with_tracker(fun(_Pid) ->
        Owner = erlang:spawn(fun() ->
            symbolic_operation_status:started(query, <<"/tmp/crashing_project">>),
            receive never -> ok end
        end),
        wait_running(),
        {ok, #{state := running, active := #{kind := query}}} =
            symbolic_operation_status:status(),
        exit(Owner, boom),
        wait_idle(),
        {ok, #{state := idle, active := null,
               last := #{kind := query, outcome := #{status := crashed, error := _}}}} =
            symbolic_operation_status:status(),
        ok
    end).

ignores_stale_events_after_finish_test() ->
    with_tracker(fun(_Pid) ->
        symbolic_operation_status:started(query, <<"/tmp/stale_project">>),
        symbolic_operation_status:phase(proving),
        symbolic_operation_status:finished(ok),
        %% A phase cast carrying the finished operation's token must not
        %% reopen or mutate the completed operation. The token is private
        %% to the tracker; a forged cast with a fresh ref cannot match it.
        gen_statem:cast(symbolic_operation_status,
                        {phase, self(), make_ref(), proving}),
        {ok, #{state := idle, active := null,
               last := #{outcome := #{status := succeeded}}}} =
            symbolic_operation_status:status(),
        ok
    end).

reports_failed_outcome_with_brief_error_test() ->
    with_tracker(fun(_Pid) ->
        symbolic_operation_status:started(parse, undefined),
        BigError = lists:duplicate(400, $x),
        symbolic_operation_status:finished({error, {no_config_found, BigError}}),
        {ok, #{state := idle, active := null,
               last := #{path := null,
                         outcome := #{status := failed, error := Text}}}} =
            symbolic_operation_status:status(),
        ?assert(byte_size(Text) =< 512),
        ?assert(byte_size(Text) > 0)
    end).

reports_not_running_without_tracker_test() ->
    catch gen_statem:stop(symbolic_operation_status),
    ?assertEqual({error, not_running}, symbolic_operation_status:status()),
    {ok, Pid} = symbolic_operation_status:start_link(),
    unlink(Pid),
    ok.

wait_running() ->
    case symbolic_operation_status:status() of
        {ok, #{state := running}} -> ok;
        _ -> timer:sleep(10), wait_running()
    end.

wait_idle() ->
    case symbolic_operation_status:status() of
        {ok, #{state := idle, last := Last}} when Last =/= null -> ok;
        _ -> timer:sleep(10), wait_idle()
    end.
