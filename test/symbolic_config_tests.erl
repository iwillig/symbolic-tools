-module(symbolic_config_tests).
-include_lib("eunit/include/eunit.hrl").

%% symbolic_config:discover/1's own walk-up algorithm is exercised by
%% symbolic_query_tests.erl's discover_up_* tests (this module just calls
%% through to symbolic_query:discover_up/2 with .symbolic/config.json
%% baked in — a one-line wrapper, not worth re-testing the walk itself).
%% This module covers what's actually new here: read/1's JSON decoding,
%% validation, and path resolution, plus project_root/1.

discover_finds_the_config_file_test() ->
    with_scratch_config(<<"{\"paths\": [\"src\"]}">>, fun(Root, ConfigPath) ->
        ?assertEqual(ConfigPath, symbolic_config:discover(Root)),
        ?assertEqual(ConfigPath,
            symbolic_config:discover(filename:join([Root, "src"])))
    end).

project_root_is_two_levels_above_the_config_file_test() ->
    ?assertEqual(filename:absname("some/project"),
        symbolic_config:project_root(
            filename:join(["some", "project", ".symbolic", "config.json"]))).

read_resolves_relative_paths_against_the_project_root_test() ->
    with_scratch_config(<<"{\"paths\": [\"src\", \"test\"]}">>, fun(Root, ConfigPath) ->
        ?assertEqual({ok, [filename:join(Root, "src"), filename:join(Root, "test")]},
            symbolic_config:read(ConfigPath))
    end).

%% filename:join/2 already leaves an absolute second argument untouched
%% (verified against the real stdlib, not assumed) — an absolute entry in
%% `paths` is used as-is rather than nested under the project root.
read_leaves_an_absolute_path_entry_untouched_test() ->
    with_scratch_config(<<"{\"paths\": [\"/already/absolute\"]}">>, fun(_Root, ConfigPath) ->
        ?assertEqual({ok, ["/already/absolute"]}, symbolic_config:read(ConfigPath))
    end).

read_missing_file_is_an_error_test() ->
    ?assertMatch({error, {cannot_read_config, "no/such/config_zz.json", enoent}},
        symbolic_config:read("no/such/config_zz.json")).

read_invalid_json_is_an_error_test() ->
    with_scratch_config(<<"not valid json">>, fun(_Root, ConfigPath) ->
        ?assertMatch({error, {invalid_config_json, ConfigPath}}, symbolic_config:read(ConfigPath))
    end).

read_missing_paths_key_is_an_error_test() ->
    with_scratch_config(<<"{\"something_else\": 1}">>, fun(_Root, ConfigPath) ->
        ?assertMatch({error, {missing_config_paths, ConfigPath}}, symbolic_config:read(ConfigPath))
    end).

read_empty_paths_list_is_an_error_test() ->
    with_scratch_config(<<"{\"paths\": []}">>, fun(_Root, ConfigPath) ->
        ?assertMatch({error, {invalid_config_paths, ConfigPath, _}}, symbolic_config:read(ConfigPath))
    end).

read_paths_not_a_list_is_an_error_test() ->
    with_scratch_config(<<"{\"paths\": \"src\"}">>, fun(_Root, ConfigPath) ->
        ?assertMatch({error, {invalid_config_paths, ConfigPath, _}}, symbolic_config:read(ConfigPath))
    end).

read_a_non_string_path_entry_is_an_error_test() ->
    with_scratch_config(<<"{\"paths\": [\"src\", 1]}">>, fun(_Root, ConfigPath) ->
        ?assertMatch({error, {invalid_config_paths, ConfigPath, _}}, symbolic_config:read(ConfigPath))
    end).

with_scratch_config(ConfigBin, Fun) ->
    Root = filename:absname(filename:join(["_build", "config_scratch_project"])),
    _ = file:del_dir_r(Root),
    ConfigPath = filename:join([Root, ".symbolic", "config.json"]),
    ok = filelib:ensure_dir(ConfigPath),
    ok = file:write_file(ConfigPath, ConfigBin),
    try
        Fun(Root, ConfigPath)
    after
        _ = file:del_dir_r(Root)
    end.
