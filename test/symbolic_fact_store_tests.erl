-module(symbolic_fact_store_tests).
-include_lib("eunit/include/eunit.hrl").

metadata_round_trips_and_missing_metadata_is_distinct_test() ->
    Path = filename:join(["/tmp", "symbolic_fact_meta_"
        ++ integer_to_list(erlang:unique_integer([positive])) ++ ".dets"]),
    Metadata = #{<<"complete">> => false,
                 <<"failed_files">> => [<<"src/bad.ts">>]},
    try
        ?assertEqual(not_found, symbolic_fact_store:read_metadata(Path)),
        ?assertEqual(ok, symbolic_fact_store:write_metadata(Path, Metadata)),
        ?assertEqual({ok, Metadata}, symbolic_fact_store:read_metadata(Path))
    after
        _ = file:delete(Path ++ ".scan.json")
    end.

write_and_read_round_trips_test() ->
    Path = tmp_path(),
    Facts = [
        {defines, foo, 'file.erl', 3},
        {comment, 'file.erl', 1, <<"it's a test">>},
        {calls, foo, {local, bar}, 'file.erl', 4}
    ],
    ok = symbolic_fact_store:write(Path, Facts),
    Read = symbolic_fact_store:read(Path),
    ?assertEqual(lists:sort(Facts), lists:sort(Read)),
    file:delete(Path).

%% `symbolic parse` fully regenerates the fact set every run — a write
%% replaces the table's contents rather than merging into it.
write_replaces_previous_contents_test() ->
    Path = tmp_path(),
    ok = symbolic_fact_store:write(Path, [{defines, old, 'a.erl', 1}]),
    ok = symbolic_fact_store:write(Path, [{defines, new, 'a.erl', 2}]),
    ?assertEqual([{defines, new, 'a.erl', 2}], symbolic_fact_store:read(Path)),
    file:delete(Path).

empty_fact_set_round_trips_test() ->
    Path = tmp_path(),
    ok = symbolic_fact_store:write(Path, []),
    ?assertEqual([], symbolic_fact_store:read(Path)),
    file:delete(Path).

write_bundle_replaces_facts_and_metadata_together_test() ->
    Path = tmp_path(),
    OldFacts = [{defines, old, 'a.ts', 1}],
    NewFacts = [{defines, new, 'a.ts', 2}],
    OldMeta = #{<<"typescript_analysis">> => #{<<"status">> => <<"disabled">>}},
    NewMeta = #{<<"typescript_analysis">> => #{<<"status">> => <<"ok">>}},
    try
        ok = symbolic_fact_store:write_bundle(Path, OldFacts, OldMeta),
        ok = symbolic_fact_store:write_bundle(Path, NewFacts, NewMeta),
        ?assertEqual(NewFacts, symbolic_fact_store:read(Path)),
        ?assertEqual({ok, NewMeta}, symbolic_fact_store:read_metadata(Path))
    after
        cleanup(Path)
    end.

write_bundle_stage_failure_preserves_the_previous_snapshot_test() ->
    Path = tmp_path(),
    Facts = [{defines, stable, 'a.ts', 1}],
    Metadata = #{<<"complete">> => true},
    try
        ok = symbolic_fact_store:write_bundle(Path, Facts, Metadata),
        ?assertMatch({error, {snapshot_stage_failed, _, _}},
            symbolic_fact_store:write_bundle(Path, [not_a_fact_tuple],
                #{<<"complete">> => false})),
        ?assertEqual(Facts, symbolic_fact_store:read(Path)),
        ?assertEqual({ok, Metadata}, symbolic_fact_store:read_metadata(Path))
    after
        cleanup(Path)
    end.

file_cache_follows_bundle_commit_and_metadata_identity_test() ->
    Path = tmp_path(),
    A = #{"a.erl" => #{hash => <<1>>, path => "a.erl", facts => [{defines, a, 0}]}},
    B = #{"b.erl" => #{hash => <<2>>, path => "b.erl", facts => [{defines, b, 0}]}},
    try
        ok = symbolic_fact_store:write_bundle(Path, [{defines, a, 0}], #{}, A),
        ?assertEqual(A, symbolic_file_cache:load(Path)),
        ?assertMatch({error, {snapshot_stage_failed, _, _}},
            symbolic_fact_store:write_bundle(Path, [not_a_fact_tuple], #{}, B)),
        ?assertEqual(A, symbolic_file_cache:load(Path)),
        ok = symbolic_fact_store:write_bundle(Path, [{defines, b, 0}], #{}, B),
        ?assertEqual(B, symbolic_file_cache:load(Path)),
        ok = symbolic_fact_store:write_metadata(Path, #{<<"file_cache_id">> => <<"stale">>}),
        ?assertEqual(#{}, symbolic_file_cache:load(Path)),
        ok = symbolic_fact_store:write_bundle(Path, [], #{}),
        ?assertEqual(#{}, symbolic_file_cache:load(Path)),
        ok = symbolic_fact_store:write_bundle(Path, [{defines, a, 0}], #{}, A),
        ok = symbolic_fact_store:write(Path, [{defines, b, 0}]),
        ?assertEqual(#{}, symbolic_file_cache:load(Path))
    after
        cleanup(Path)
    end.

cleanup(Path) ->
    lists:foreach(fun(File) -> _ = file:delete(File) end,
                  filelib:wildcard(Path ++ "*")),
    ok.

tmp_path() ->
    Name = io_lib:format("symbolic_fact_store_test_~p.dets", [erlang:unique_integer([positive])]),
    filename:join(tmp_dir(), lists:flatten(Name)).

tmp_dir() ->
    case os:getenv("TMPDIR") of
        false -> "/tmp";
        Dir -> Dir
    end.
