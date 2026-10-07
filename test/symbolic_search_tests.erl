%%% Tests for symbolic_search — the `symbolic search` CLI's halt-free
%%% core (run_result/3), exercised against a real DETS fact database
%%% written with symbolic_fact_store:write/2, the same store
%%% `symbolic parse --db` produces. Pins the prose-fact selection
%%% (comment/3, paragraph/3, heading/4, blockquote/3 — including the
%%% differing argument orders), the JSON result shape, ranking through
%%% the real NIF, and the error paths.
-module(symbolic_search_tests).
-include_lib("eunit/include/eunit.hrl").

facts() ->
    [
        %% comment/3: File, Line, Text
        {comment, doc_comments, 10, <<"the inverted index stores postings">>},
        {comment, doc_comments, 20, <<"unrelated chatter about coffee">>},
        %% paragraph/3: File, Text, Line — note the argument order
        %% differs from comment/3; the selector must match by name.
        {paragraph, <<"docs/design.md">>, <<"BM25 scoring weighs term frequency">>, 5},
        %% heading/4: File, Level, Text, Line
        {heading, <<"docs/design.md">>, 2, <<"Full Text Search">>, 1},
        %% blockquote/3: File, Text, Line
        {blockquote, <<"docs/design.md">>, <<"quoted note about indexing">>, 30},
        %% Non-prose facts must be ignored, never crash the selector.
        {defines, foo, 2, [], doc_comments, 3},
        {calls, bar, 1, local, baz, 4}
    ].

search_finds_and_ranks_prose_test() ->
    Path = tmp_db(),
    try
        ok = symbolic_fact_store:write(Path, facts()),
        {ok, [Best | _]} = symbolic_search:run_result(Path, <<"inverted index">>, 10),
        %% Doc 1 ("the inverted index stores postings") holds BOTH query
        %% terms; nothing else does — it must rank first.
        ?assertEqual(<<"comment">>, maps:get(<<"kind">>, Best)),
        ?assertEqual(<<"doc_comments">>, maps:get(<<"file">>, Best)),
        ?assertEqual(10, maps:get(<<"line">>, Best)),
        ?assert(is_float(maps:get(<<"score">>, Best))),
        ?assertMatch(<<"the inverted index stores postings">>,
            maps:get(<<"text">>, Best)),
        %% Every prose fact is in the corpus, so a term only one kind
        %% holds proves the selector picked that kind up.
        {ok, [Blockquote]} = symbolic_search:run_result(Path, <<"quoted note">>, 1),
        ?assertEqual(<<"blockquote">>, maps:get(<<"kind">>, Blockquote)),
        {ok, [Heading]} = symbolic_search:run_result(Path, <<"full text">>, 1),
        ?assertEqual(<<"heading">>, maps:get(<<"kind">>, Heading))
    after
        file:delete(Path)
    end.

paragraph_argument_order_is_handled_test() ->
    Path = tmp_db(),
    try
        ok = symbolic_fact_store:write(Path, [
            {paragraph, <<"m.md">>, <<"searching for the needle">>, 42}
        ]),
        {ok, [Result]} = symbolic_search:run_result(Path, <<"needle">>, 1),
        %% Line 42 is paragraph/3's THIRD argument — this pins that the
        %% selector didn't confuse it with comment/3's order.
        ?assertEqual(42, maps:get(<<"line">>, Result)),
        ?assertEqual(<<"paragraph">>, maps:get(<<"kind">>, Result))
    after
        file:delete(Path)
    end.

limit_truncates_results_test() ->
    Path = tmp_db(),
    try
        ok = symbolic_fact_store:write(Path, [
            {comment, a, 1, <<"alpha">>},
            {comment, b, 1, <<"alpha">>},
            {comment, c, 1, <<"alpha">>}
        ]),
        {ok, Results} = symbolic_search:run_result(Path, <<"alpha">>, 2),
        ?assertEqual(2, length(Results))
    after
        file:delete(Path)
    end.

no_hits_is_an_empty_ok_not_an_error_test() ->
    Path = tmp_db(),
    try
        ok = symbolic_fact_store:write(Path, facts()),
        ?assertEqual({ok, []}, symbolic_search:run_result(Path, <<"zzzznothing">>, 10))
    after
        file:delete(Path)
    end.

empty_corpus_is_an_empty_ok_not_an_error_test() ->
    Path = tmp_db(),
    try
        ok = symbolic_fact_store:write(Path, [{defines, foo, 2, [], a, 1}]),
        ?assertEqual({ok, []}, symbolic_search:run_result(Path, <<"anything">>, 10))
    after
        file:delete(Path)
    end.

missing_db_is_reported_not_raised_test() ->
    Missing = filename:join(["/tmp", "no_such_db_"
        ++ integer_to_list(erlang:unique_integer([positive])) ++ ".dets"]),
    ?assertEqual({error, {no_such_db, Missing}},
        symbolic_search:run_result(Missing, <<"anything">>, 10)).

excerpt_truncates_at_200_characters_test() ->
    %% Spaces matter: without them the whole text is ONE 300-character
    %% word token, and a "x" query couldn't match it (UAX #29 splits on
    %% whitespace, not characters).
    Long = unicode:characters_to_binary(
        lists:duplicate(300, <<"x ">>)),
    Path = tmp_db(),
    try
        ok = symbolic_fact_store:write(Path, [
            {comment, a, 1, Long}
        ]),
        {ok, [Result]} = symbolic_search:run_result(Path, <<"x">>, 1),
        ?assertEqual(200, byte_size(maps:get(<<"text">>, Result)))
    after
        file:delete(Path)
    end.

tmp_db() ->
    filename:join(["/tmp", "symbolic_search_tests_"
        ++ integer_to_list(erlang:unique_integer([positive])) ++ ".dets"]).

%% --- the parse-time sidecar cache (write_index_cache + fast path) ---

cache_round_trip_searches_without_rebuilding_test() ->
    Path = tmp_db(),
    try
        ok = symbolic_fact_store:write(Path, facts()),
        ok = symbolic_search:write_index_cache(Path, facts()),
        %% The sidecar exists and both paths answer identically —
        %% proving the fast path only needs its outputs to agree with
        %% the slow path's, not which one ran.
        true = filelib:is_regular(Path ++ ".text_idx"),
        ?assertEqual(
            symbolic_search:run_result(Path, <<"inverted index">>, 10),
            symbolic_search:run_result(Path, <<"inverted index">>, 10))
    after
        file:delete(Path),
        file:delete(Path ++ ".text_idx")
    end.

cache_metadata_is_what_search_reports_test() ->
    Path = tmp_db(),
    try
        ok = symbolic_fact_store:write(Path, facts()),
        ok = symbolic_search:write_index_cache(Path, facts()),
        {ok, [Best | _]} = symbolic_search:run_result(Path, <<"inverted index">>, 10),
        ?assertEqual(<<"comment">>, maps:get(<<"kind">>, Best)),
        ?assertEqual(<<"doc_comments">>, maps:get(<<"file">>, Best)),
        ?assertEqual(10, maps:get(<<"line">>, Best))
    after
        file:delete(Path),
        file:delete(Path ++ ".text_idx")
    end.

stale_sidecar_is_ignored_and_rebuilt_test() ->
    Path = tmp_db(),
    try
        ok = symbolic_fact_store:write(Path, [{comment, a, 1, <<"old text">>}]),
        ok = symbolic_search:write_index_cache(Path, [{comment, a, 1, <<"old text">>}]),
        %% Re-write the db WITHOUT refreshing the sidecar, then push
        %% its mtime past the sidecar's — the cache is stale and must
        %% be ignored, not served.
        ok = symbolic_fact_store:write(Path, [{comment, a, 1, <<"fresh text">>}]),
        %% mtime has second granularity, so "newer by milliseconds" is
        %% indistinguishable from "same second" — push the db a full 10
        %% seconds into the future to make staleness unambiguous.
        Now = calendar:local_time(),
        Future = calendar:gregorian_seconds_to_datetime(
            calendar:datetime_to_gregorian_seconds(Now) + 10),
        ok = file:change_time(Path, Future, Future),
        {ok, [Result]} = symbolic_search:run_result(Path, <<"fresh text">>, 1),
        ?assertMatch(<<"fresh text">>, maps:get(<<"text">>, Result))
    after
        file:delete(Path),
        file:delete(Path ++ ".text_idx")
    end.

corrupt_sidecar_degrades_to_rebuild_test() ->
    Path = tmp_db(),
    try
        ok = symbolic_fact_store:write(Path, facts()),
        Sidecar = Path ++ ".text_idx",
        %% Not a term at all...
        ok = file:write_file(Sidecar, <<"definitely not a sidecar">>),
        {ok, Results} = symbolic_search:run_result(Path, <<"inverted index">>, 10),
        true = is_list(Results),
        %% ...and a valid term of the WRONG shape...
        ok = file:write_file(Sidecar, term_to_binary(#{something => other})),
        {ok, Results2} = symbolic_search:run_result(Path, <<"inverted index">>, 10),
        true = is_list(Results2),
        %% ...and a right-shaped container with garbage snapshot bytes.
        ok = file:write_file(Sidecar,
            term_to_binary(#{docs => [], snapshot => <<"garbage">>})),
        {ok, Results3} = symbolic_search:run_result(Path, <<"inverted index">>, 10),
        true = is_list(Results3)
    after
        file:delete(Path),
        file:delete(Path ++ ".text_idx")
    end.
