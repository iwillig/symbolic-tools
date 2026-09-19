-module(ts_extract_json_tests).
-include_lib("eunit/include/eunit.hrl").

-define(FIXTURE, "test/fixtures/sample.json").

extracts_top_level_value_test() ->
    Facts = ts_extract_json:file(?FIXTURE),
    Path = list_to_atom(?FIXTURE),
    ?assert(lists:member({config_value, Path, name, sample, 2}, Facts)),
    ?assert(lists:member({config_value, Path, version, '1.0.0', 3}, Facts)).

%% Arrays are captured as one opaque leaf (raw source text), not walked
%% element-by-element — a deliberate scope limit, not a missing case.
extracts_array_as_opaque_leaf_test() ->
    Facts = ts_extract_json:file(?FIXTURE),
    Path = list_to_atom(?FIXTURE),
    ?assert(lists:member({config_value, Path, scripts, '["build", "test"]', 4}, Facts)).

extracts_nested_object_test() ->
    Facts = ts_extract_json:file(?FIXTURE),
    Path = list_to_atom(?FIXTURE),
    ?assert(lists:member({config_section, Path, dependencies, 5}, Facts)),
    ?assert(lists:member(
        {config_value, Path, 'dependencies.rebar3', '^3.24', 6}, Facts)).

no_duplicate_facts_test() ->
    Facts = ts_extract_json:file(?FIXTURE),
    ?assertEqual(lists:usort(Facts), lists:sort(Facts)).
