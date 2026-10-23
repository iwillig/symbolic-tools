%%% Independent observer for the cache process's parse/query lifecycle.
-module(symbolic_operation_status).
-behaviour(gen_statem).
-export([start_link/0, started/2, project/1, phase/1, finished/1, cancelled/1, status/0]).
-export([init/1, callback_mode/0, handle_event/4]).

start_link() -> gen_statem:start_link({local, ?MODULE}, ?MODULE, [], []).
started(Kind, Path) ->
    Ref = make_ref(),
    put({?MODULE, operation}, Ref),
    emit({started, self(), Ref, Kind, Path}).
project(Path) -> emit({project, self(), get({?MODULE, operation}), Path}).
phase(Phase) -> emit({phase, self(), get({?MODULE, operation}), Phase}).
finished(Outcome) ->
    Ref = erase({?MODULE, operation}),
    emit({finished, self(), Ref, Outcome}).
%% An explicit parse supersedes an automatic refresh. The cache process
%% names that worker so the tracker can retire it before starting the
%% explicit operation, without a stale DOWN replacing the new status.
cancelled(Owner) -> emit({cancelled, Owner}).
status() ->
    case whereis(?MODULE) of
        undefined -> {error, not_running};
        Pid -> gen_statem:call(Pid, status, 1000)
    end.
emit(Event) ->
    case whereis(?MODULE) of
        undefined -> ok;
        Pid -> gen_statem:cast(Pid, Event)
    end.
init([]) -> {ok, idle, #{active => undefined, last => undefined,
                          owner => undefined, token => undefined, monitor => undefined}}.
callback_mode() -> handle_event_function.
handle_event({call, From}, status, State, Data) ->
    Active = case maps:get(active, Data) of
        undefined -> null;
        Item -> Item#{elapsed_ms => now_ms() - maps:get(started_ms, Item)}
    end,
    Last = case maps:get(last, Data) of undefined -> null; Previous -> Previous end,
    {keep_state_and_data, [{reply, From,
        {ok, #{state => State, active => Active, last => Last}}}]};
handle_event(cast, {started, Owner, Token, Kind, Path}, idle, Data) ->
    Monitor = erlang:monitor(process, Owner),
    Active = #{kind => Kind, phase => starting, path => json_path(Path),
               started_ms => now_ms()},
    {next_state, running, Data#{owner => Owner, token => Token,
                               monitor => Monitor, active => Active}};
handle_event(cast, {phase, Owner, Token, Phase}, running,
             #{owner := Owner, token := Token} = Data) ->
    Active = maps:get(active, Data),
    {keep_state, Data#{active => Active#{phase => Phase}}};
handle_event(cast, {project, Owner, Token, Path}, running,
             #{owner := Owner, token := Token} = Data) ->
    Active = maps:get(active, Data),
    {keep_state, Data#{active => Active#{path => json_path(Path)}}};
handle_event(cast, {finished, Owner, Token, Outcome}, running,
             #{owner := Owner, token := Token} = Data) ->
    erlang:demonitor(maps:get(monitor, Data), [flush]),
    complete(Outcome, Data);
handle_event(cast, {cancelled, Owner}, running,
             #{owner := Owner} = Data) ->
    erlang:demonitor(maps:get(monitor, Data), [flush]),
    complete({error, superseded}, Data);
handle_event(info, {'DOWN', Monitor, process, Owner, Reason}, running,
             #{owner := Owner, monitor := Monitor} = Data) ->
    complete({crashed, Reason}, Data);
handle_event(_Type, _Event, _State, _Data) -> keep_state_and_data.
complete(Outcome, Data) ->
    Active = maps:get(active, Data),
    Last = Active#{elapsed_ms => now_ms() - maps:get(started_ms, Active),
                   completed_ms => now_ms(), outcome => outcome(Outcome)},
    {next_state, idle, Data#{active => undefined, last => Last, owner => undefined,
                             token => undefined, monitor => undefined}}.
outcome(ok) -> #{status => succeeded};
outcome({error, Reason}) -> #{status => failed, error => brief(Reason)};
outcome({crashed, Reason}) -> #{status => crashed, error => brief(Reason)}.
brief(Reason) ->
    Text = unicode:characters_to_binary(io_lib:format("~p", [Reason])),
    binary:part(Text, 0, min(byte_size(Text), 512)).
json_path(undefined) -> null;
json_path(Path) -> unicode:characters_to_binary(Path).
now_ms() -> erlang:system_time(millisecond).
