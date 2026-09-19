-module(symbolic_fact_store_tests).
-include_lib("eunit/include/eunit.hrl").

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

tmp_path() ->
    Name = io_lib:format("symbolic_fact_store_test_~p.dets", [erlang:unique_integer([positive])]),
    filename:join(tmp_dir(), lists:flatten(Name)).

tmp_dir() ->
    case os:getenv("TMPDIR") of
        false -> "/tmp";
        Dir -> Dir
    end.
