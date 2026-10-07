%%% Tests for text_search/2,3 — symbolic_prolog_lib's compiled-procedure
%%% bridge from the erlog engine to the symbolic_text NIF (BM25 over
%%% the session's own prose facts). Proved through a real prolog_session
%%% with real asserted facts, the exact path an MCP query or
%%% `symbolic query -db` takes. Pins: the ranked hit(Kind, File, Line,
%%% Score) shape, BM25 ordering, the /3 limit, the accepted query types
%%% (code list, atom, binary), and the error modes (unbound query,
%%% non-positive limit, non-text query).
-module(symbolic_text_search_tests).
-include_lib("eunit/include/eunit.hrl").

facts() ->
    [
        {comment, doc_a, 10, <<"the inverted index stores postings">>},
        {comment, doc_a, 20, <<"unrelated chatter about coffee">>},
        {paragraph, <<"m.md">>, <<"BM25 weighs term frequency">>, 3},
        %% heading/4: {heading, File, Level, Text, Line} — a 5-element
        %% Erlang tuple, a 4-arity Prolog functor (the DB-key distinction
        %% symbolic_prolog_lib:session_text_index/1 documents).
        {heading, <<"m.md">>, 1, <<"Full Text Search">>, 1},
        {defines, foo, 2, [], doc_a, 3}
    ].

with_facts(Facts, Body) ->
    {ok, Pid} = prolog_session:start_link(),
    try
        ok = prolog_session:load_facts(Pid, Facts),
        Body(Pid)
    after
        prolog_session:stop(Pid)
    end.

text_search_ranks_by_bm25_test() ->
    with_facts(facts(), fun(Pid) ->
        %% Only the first comment holds both query terms — one hit.
        {ok, [{'Hits', [First]}]} = prolog_session:query(Pid,
            "text_search(\"inverted index\", Hits)"),
        ?assertMatch({'hit', comment, doc_a, 10, Score} when is_float(Score), First)
    end).

text_search_finds_every_prose_kind_test() ->
    with_facts(facts(), fun(Pid) ->
        %% Each kind needs a query only its own text can match — this
        %% pins that the selector enumerated it at all.
        {ok, [{'Hits', [Heading]}]} = prolog_session:query(Pid,
            "text_search(\"search\", Hits)"),
        ?assertMatch({'hit', heading, <<"m.md">>, 1, _}, Heading),
        {ok, [{'Hits', [Paragraph]}]} = prolog_session:query(Pid,
            "text_search(\"term frequency\", Hits)"),
        ?assertMatch({'hit', paragraph, <<"m.md">>, 3, _}, Paragraph),
        {ok, [{'Hits', [Comment]}]} = prolog_session:query(Pid,
            "text_search(\"coffee\", Hits)"),
        ?assertMatch({'hit', comment, doc_a, 20, _}, Comment)
    end).

%% A blockquote-only corpus pins the fourth prose kind without sharing
%%% fixtures with the other tests' queries.
blockquote_kind_is_searchable_test() ->
    {ok, Pid} = prolog_session:start_link(),
    try
        ok = prolog_session:load_facts(Pid, [
            {blockquote, <<"m.md">>, <<"quoted search note">>, 30}
        ]),
        {ok, [{'Hits', [Hit]}]} = prolog_session:query(Pid,
            "text_search(\"search\", Hits)"),
        ?assertMatch({'hit', blockquote, <<"m.md">>, 30, _}, Hit)
    after
        prolog_session:stop(Pid)
    end.

text_search_accepts_atom_and_binary_queries_test() ->
    with_facts(facts(), fun(Pid) ->
        {ok, [{'Hits', AtomHits}]} = prolog_session:query(Pid,
            "text_search(coffee, Hits)"),
        ?assertMatch([{'hit', comment, doc_a, 20, _}], AtomHits),
        %% A binary arrives via a bound variable (erlog has no binary
        %% literal syntax — the same note sub_text/5's own tests carry):
        %% find the coffee comment by sub_text, feed its binary back in.
        {ok, [{'Hits', [_ | _] = BinHits}, {'Text', _}]} = prolog_session:query(Pid,
            "comment(_, _, Text), sub_text(Text, _, _, _, \"coffee\"), "
            "text_search(Text, Hits)"),
        ?assertMatch([{'hit', comment, doc_a, 20, _} | _], BinHits)
    end).

limit_arity_truncates_test() ->
    {ok, Pid} = prolog_session:start_link(),
    try
        ok = prolog_session:load_facts(Pid, [
            {comment, a, 1, <<"alpha">>},
            {comment, b, 1, <<"alpha">>},
            {comment, c, 1, <<"alpha">>}
        ]),
        {ok, [{'Hits', Hits}]} = prolog_session:query(Pid,
            "text_search(\"alpha\", 2, Hits)"),
        ?assertEqual(2, length(Hits))
    after
        prolog_session:stop(Pid)
    end.

no_hits_is_an_empty_list_test() ->
    with_facts(facts(), fun(Pid) ->
        {ok, [{'Hits', Hits}]} = prolog_session:query(Pid,
            "text_search(\"zzzznothing\", Hits)"),
        ?assertEqual([], Hits)
    end).

unbound_query_is_an_instantiation_error_test() ->
    with_facts(facts(), fun(Pid) ->
        ?assertEqual({error, instantiation_error},
            prolog_session:query(Pid, "text_search(Query, Hits)"))
    end).

bad_limit_is_a_type_error_test() ->
    with_facts(facts(), fun(Pid) ->
        ?assertEqual({error, {type_error, integer, 0}},
            prolog_session:query(Pid, "text_search(\"alpha\", 0, Hits)")),
        ?assertEqual({error, {type_error, integer, x}},
            prolog_session:query(Pid, "text_search(\"alpha\", x, Hits)"))
    end).

non_text_query_is_a_type_error_test() ->
    with_facts(facts(), fun(Pid) ->
        ?assertEqual({error, {type_error, list, 3.5}},
            prolog_session:query(Pid, "text_search(3.5, Hits)"))
    end).

empty_corpus_is_an_empty_list_test() ->
    {ok, Pid} = prolog_session:start_link(),
    try
        {ok, [{'Hits', Hits}]} = prolog_session:query(Pid,
            "text_search(\"anything\", Hits)"),
        ?assertEqual([], Hits)
    after
        prolog_session:stop(Pid)
    end.

%% Results unify against caller-bound expectations — the count_pairs
%% mode discipline: Hits is output, but binding it constrains the proof.
%% A fully-bound goal has NO free variables, so success comes back as
%% {ok, []} (no bindings to report), not a Hits entry.
text_search_unifies_against_bound_hits_test() ->
    with_facts(facts(), fun(Pid) ->
        ?assertEqual({ok, []},
            prolog_session:query(Pid,
                "text_search(coffee, [hit(comment, doc_a, 20, _)])")),
        %% A bound list with a score no real result carries fails the
        %% whole goal — no silent truncation to the matching prefix.
        ?assertEqual(no_solution,
            prolog_session:query(Pid,
                "text_search(coffee, [hit(comment, doc_a, 20, 9.9)])"))
    end).
