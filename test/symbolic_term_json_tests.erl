-module(symbolic_term_json_tests).
-include_lib("eunit/include/eunit.hrl").

encodes_atom_as_binary_test() ->
    ?assertEqual(<<"foo">>, symbolic_term_json:encode_term(foo)).

encodes_integer_test() ->
    ?assertEqual(3, symbolic_term_json:encode_term(3)).

encodes_binary_as_is_test() ->
    ?assertEqual(<<"hello">>, symbolic_term_json:encode_term(<<"hello">>)).

%% Issue #2: encode_term/1 had no clause for a bare float, so a
%% literal/7 fact carrying a non-integer numeric value (a coordinate, a
%% percentage, a threshold) raised function_clause and took the whole
%% `parse` down. A negative float is Value = -82.9371 by the time it
%% reaches here (the extractor already applied unary minus), matching
%% the repro in the issue.
encodes_float_test() ->
    ?assertEqual(3.5, symbolic_term_json:encode_term(3.5)),
    ?assertEqual(-82.9371, symbolic_term_json:encode_term(-82.9371)).

%% Same crash, reached through the compound-term recursion path a real
%% literal/7 fact takes.
encodes_compound_term_with_float_field_test() ->
    ?assertEqual(
        [<<"literal">>, <<"lng">>, -82.9371],
        symbolic_term_json:encode_term({literal, lng, -82.9371})).

encodes_compound_term_as_array_test() ->
    ?assertEqual(
        [<<"defines">>, <<"foo">>, <<"file.erl">>, 3],
        symbolic_term_json:encode_term({defines, foo, 'file.erl', 3})).

encodes_nested_compound_term_test() ->
    ?assertEqual(
        [<<"calls">>, <<"foo">>, [<<"local">>, <<"bar">>], <<"file.erl">>, 4],
        symbolic_term_json:encode_term({calls, foo, {local, bar}, 'file.erl', 4})).

%% A bare Erlang list (not one produced by tuple_to_list/1 internally) —
%% e.g. a fact field like a file_list, distinct from the tuple-recursion
%% path every other test here exercises.
encodes_bare_list_test() ->
    ?assertEqual(
        [<<"a">>, <<"b">>, 3],
        symbolic_term_json:encode_term([a, <<"b">>, 3])).

%% The bug this whole change fixes: erlog_io:writeq1/1 doesn't escape an
%% atom's/binary's embedded single quote at all, producing invalid
%% output for ordinary text like "it's a test" (see docs/prolog-store.md).
%% jsx's JSON string encoding handles it correctly — proven here by a
%% real round trip through jsx:decode/1, not just by not-crashing.
survives_embedded_quote_round_trip_test() ->
    Term = {comment, 'file.erl', 1, <<"it's a test">>},
    Json = jsx:encode(symbolic_term_json:encode_term(Term)),
    Decoded = jsx:decode(Json),
    ?assertEqual([<<"comment">>, <<"file.erl">>, 1, <<"it's a test">>], Decoded).

%% An unbound Prolog variable reaches us from `erlog_int:dderef/2` as the
%% one-element tuple `{V}`, where V is erlog's variable number. The generic
%% tuple clause used to encode that as `[V]` — so `A = 0` was ambiguous
%% whether it meant "the number 0", a line number, or "never solved", and a
%% `findall` template variable left everyone reading residue as an answer.
%% Worse, `tuple_to_list({V})` is the integer V (not `[V]`), so the
%% comprehension in the list clause raised `{bad_generator,{3}}` — the crash
%% a live session hit on `findall(P, current_predicate(P), Ps)`. And a
%% multi-slot tuple `{1,2}` encoded as a charlist, so a comma rendered as
%% `","`. Proven by a real round trip through jsx, like the quote test above
%% — "it didn't crash" would have passed the old code for the top-level case.
unbound_variable_is_not_rendered_as_data_test() ->
    ?assertEqual(<<"_G0">>, symbolic_term_json:encode_term({0})),
    ?assertEqual(<<"_G3">>, symbolic_term_json:encode_term({3})),
    %% The nested case that used to raise bad_generator.
    ?assertEqual([<<"_G0">>], symbolic_term_json:encode_term([{0}])),
    %% The reported crash shape: a free P inside a decoded predicate
    %% indicator list.
    Json = jsx:encode(
        symbolic_term_json:encode_term([<<"/">>, <<"take">>, {3}])),
    ?assertEqual(
        [<<"/">>, <<"take">>, <<"_G3">>], jsx:decode(Json)),
    %% A variable number is not the integer 0, and a real integer stays a
    %% real integer -- the assertion that would have failed before the fix.
    ?assertNotEqual(
        symbolic_term_json:encode_term(0),
        symbolic_term_json:encode_term({0})),
    ?assertEqual(3, symbolic_term_json:encode_term(3)),
    %% Two slots is still a compound term, not a charlist.
    ?assertEqual([1, 2], symbolic_term_json:encode_term({1, 2})).
