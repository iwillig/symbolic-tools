-module(symbolic_release_config_tests).
-include_lib("eunit/include/eunit.hrl").

%% A release must not request an application that was removed from the
%% dependency list. rebar3 compile and EUnit can pass while relx fails.
release_apps_are_available_test() ->
    {ok, Config} = file:consult("rebar.config"),
    {deps, Deps} = lists:keyfind(deps, 1, Config),
    DependencyNames = [Name || {Name, _} <- Deps],
    {relx, Relx} = lists:keyfind(relx, 1, Config),
    {release, {symbolic_tools, _Version}, Apps} = lists:keyfind(release, 1, Relx),
    Available = [sasl, symbolic_tools | DependencyNames],
    Missing = [App || App <- Apps, not lists:member(App, Available)],
    ?assertEqual([], Missing).
