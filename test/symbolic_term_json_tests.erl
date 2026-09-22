-module(symbolic_term_json_tests).
-include_lib("eunit/include/eunit.hrl").

encodes_atom_as_binary_test() ->
    ?assertEqual(<<"foo">>, symbolic_term_json:encode_term(foo)).

encodes_integer_test() ->
    ?assertEqual(3, symbolic_term_json:encode_term(3)).

encodes_binary_as_is_test() ->
    ?assertEqual(<<"hello">>, symbolic_term_json:encode_term(<<"hello">>)).

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
