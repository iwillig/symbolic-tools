%%% Tests for the symbolic_text NIF (native/symbolic_text) — pinning the
%%% contract docs/full-text-search.md describes: deterministic BM25
%%% ranking (score descending, ties by doc id ascending), zero-model
%%% UAX #29 tokenization, {error, Reason} tuples for every failure (never
%%% a raise), and the save/load snapshot round trip. Rust-side unit tests
%%% cover the internals; these pin the ERLANG-visible behavior.
-module(symbolic_text_tests).
-include_lib("eunit/include/eunit.hrl").

setup_index(Docs) ->
    Index = symbolic_text:index_new(),
    lists:foldl(
        fun({Id, Text}, ok) ->
            ?assertEqual(ok, symbolic_text:index_add_doc(Index, Id, Text))
        end,
        ok, Docs),
    Index.

tokenize_is_lowercase_uax29_words_test() ->
    ?assertEqual({ok, [<<"hello">>, <<"world">>]},
        symbolic_text:tokenize(<<"Hello, World!">>)),
    ?assertEqual({ok, [<<"foo">>, <<"2">>, <<"calls">>, <<"bar">>, <<"1">>]},
        symbolic_text:tokenize(<<"foo/2 calls bar/1">>)).

tokenize_rejects_invalid_utf8_test() ->
    ?assertEqual({error, invalid_utf8}, symbolic_text:tokenize(<<16#FF>>)).

higher_term_frequency_ranks_first_test() ->
    Index = setup_index([{1, <<"alpha beta">>}, {2, <<"alpha alpha alpha">>}]),
    ?assertMatch({ok, [{2, _}, {1, _}]},
        symbolic_text:index_search(Index, <<"alpha">>, 10)).

rare_term_outranks_common_test() ->
    Index = setup_index([{1, <<"common rare">>}, {2, <<"common common common">>}]),
    ?assertMatch({ok, [{1, _} | _]},
        symbolic_text:index_search(Index, <<"common rare">>, 10)).

unmatched_query_returns_empty_list_test() ->
    Index = setup_index([{1, <<"alpha">>}]),
    ?assertEqual({ok, []}, symbolic_text:index_search(Index, <<"gamma">>, 10)).

ties_break_by_doc_id_ascending_and_limit_truncates_test() ->
    Index = setup_index([{3, <<"same">>}, {1, <<"same">>}, {2, <<"same">>}]),
    {ok, [{Id1, _}, {Id2, _}]} = symbolic_text:index_search(Index, <<"same">>, 2),
    ?assertEqual([1, 2], [Id1, Id2]).

search_is_deterministic_test() ->
    Docs = [{1, <<"the quick brown fox">>}, {2, <<"the lazy dog">>},
             {3, <<"a fox and a dog">>}],
    Index = setup_index(Docs),
    ?assertEqual(symbolic_text:index_search(Index, <<"fox dog">>, 10),
                 symbolic_text:index_search(Index, <<"fox dog">>, 10)).

search_rejects_invalid_utf8_query_test() ->
    Index = setup_index([{1, <<"alpha">>}]),
    ?assertEqual({error, invalid_utf8}, symbolic_text:index_search(Index, <<16#FF>>, 10)).

stats_count_docs_and_distinct_terms_test() ->
    Index = setup_index([{1, <<"alpha beta">>}, {2, <<"beta gamma">>}]),
    ?assertEqual({ok, {2, 3}}, symbolic_text:index_stats(Index)).

save_load_round_trips_exactly_test() ->
    Index = setup_index([{1, <<"alpha beta beta">>}, {2, <<"gamma">>}]),
    {ok, Original} = symbolic_text:index_search(Index, <<"beta">>, 10),
    Path = tmp_path(),
    try
        ?assertEqual(ok, symbolic_text:index_save(Index, to_bin(Path))),
        {ok, Loaded} = symbolic_text:index_load(to_bin(Path)),
        ?assertEqual({ok, Original}, symbolic_text:index_search(Loaded, <<"beta">>, 10)),
        ?assertEqual({ok, {2, 3}}, symbolic_text:index_stats(Loaded))
    after
        file:delete(Path)
    end.

load_rejects_a_missing_file_as_io_error_test() ->
    ?assertEqual({error, io_error},
        symbolic_text:index_load(to_bin(tmp_path()))).

load_rejects_a_non_snapshot_file_as_bad_snapshot_test() ->
    Path = tmp_path(),
    try
        ok = file:write_file(Path, <<"definitely not a snapshot">>),
        ?assertEqual({error, bad_snapshot}, symbolic_text:index_load(to_bin(Path)))
    after
        file:delete(Path)
    end.

%% Paths cross the NIF as UTF-8 binaries — rustler's String decoder
%% rejects plain lists (Binary::from_term), loudly, rather than guessing.
to_bin(Path) ->
    unicode:characters_to_binary(Path).

tmp_path() ->
    filename:join(["/tmp",
        "symbolic_text_tests_" ++ integer_to_list(erlang:unique_integer([positive]))]).
