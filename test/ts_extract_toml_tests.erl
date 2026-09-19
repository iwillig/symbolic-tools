-module(ts_extract_toml_tests).
-include_lib("eunit/include/eunit.hrl").

-define(FIXTURE, "test/fixtures/sample.toml").

extracts_top_level_value_test() ->
    Facts = ts_extract_toml:file(?FIXTURE),
    Path = list_to_atom(?FIXTURE),
    ?assert(lists:member({config_value, Path, title, 'My Project', 1}, Facts)).

extracts_inline_table_test() ->
    Facts = ts_extract_toml:file(?FIXTURE),
    Path = list_to_atom(?FIXTURE),
    ?assert(lists:member({config_section, Path, inline, 2}, Facts)),
    ?assert(lists:member({config_value, Path, 'inline.x', '1', 2}, Facts)),
    ?assert(lists:member({config_value, Path, 'inline.y', '2', 2}, Facts)).

extracts_table_test() ->
    Facts = ts_extract_toml:file(?FIXTURE),
    Path = list_to_atom(?FIXTURE),
    ?assert(lists:member({config_section, Path, owner, 4}, Facts)),
    ?assert(lists:member({config_value, Path, 'owner.name', 'Tom', 5}, Facts)),
    ?assert(lists:member({config_value, Path, 'owner.age', '3', 6}, Facts)).

%% Two [[servers]] blocks share the same Path ('servers.host') — no
%% array indexing in this pass — but keep their own Line, so both
%% facts coexist rather than one clobbering the other.
extracts_array_of_tables_test() ->
    Facts = ts_extract_toml:file(?FIXTURE),
    Path = list_to_atom(?FIXTURE),
    ?assert(lists:member({config_section, Path, servers, 8}, Facts)),
    ?assert(lists:member({config_section, Path, servers, 11}, Facts)),
    ?assert(lists:member({config_value, Path, 'servers.host', alpha, 9}, Facts)),
    ?assert(lists:member({config_value, Path, 'servers.host', beta, 12}, Facts)).

no_duplicate_facts_test() ->
    Facts = ts_extract_toml:file(?FIXTURE),
    ?assertEqual(lists:usort(Facts), lists:sort(Facts)).
