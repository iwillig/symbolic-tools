-module(ts_extract_text_tests).
-include_lib("eunit/include/eunit.hrl").

to_atom_from_list_test() ->
    ?assertEqual(foo, ts_extract_text:to_atom("foo")).

to_atom_from_binary_test() ->
    ?assertEqual(foo, ts_extract_text:to_atom(<<"foo">>)).

%% truncate/1's over-limit branch: identifier text longer than the
%% 255-byte Erlang atom cap (200-char project limit) gets truncated with
%% a trailing "...", not list_to_atom/1-crashed.
to_atom_truncates_long_text_test() ->
    Long = lists:duplicate(250, $a),
    Atom = ts_extract_text:to_atom(Long),
    Text = atom_to_list(Atom),
    ?assertEqual(203, length(Text)),
    ?assertEqual("...", lists:sublist(Text, 201, 3)).

to_text_from_binary_test() ->
    ?assertEqual(<<"hi">>, ts_extract_text:to_text(<<"hi">>)).

to_text_from_list_test() ->
    ?assertEqual(<<"hi">>, ts_extract_text:to_text("hi")).
