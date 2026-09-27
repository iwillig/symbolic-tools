-module(symbolic_extract_tests).
-include_lib("eunit/include/eunit.hrl").

%% run/1 itself stays untested here — same reasoning as
%% symbolic_query_tests.erl's own note: it only prints a result and
%% halt()s, nothing left to assert on. Everything that decides *what*
%% the outcome is lives in the halt-free run_result/1 and its own
%% tokenize/1 piece, both exercised directly below.

%% --- tokenize/1: pure, no Prolog session involved ---

tokenize_simple_sentence_test() ->
    ?assertEqual({ok, "[foo/2, calls, bar/1]"},
        symbolic_extract:tokenize("foo/2 calls bar/1")).

tokenize_strips_trailing_period_test() ->
    ?assertEqual({ok, "[foo/2, was, removed]"},
        symbolic_extract:tokenize("foo/2 was removed.")).

tokenize_strips_surrounding_whitespace_test() ->
    ?assertEqual({ok, "[foo/2, calls, bar/1]"},
        symbolic_extract:tokenize("  foo/2 calls bar/1  ")).

%% A capitalized word would otherwise silently become a Prolog VARIABLE
%% inside the goal text instead of the atom it looks like — rejected
%% loudly here instead, the same "loud failure over silent guess" shape
%% this project already uses everywhere else (SYSTEM.md's <errors>).
tokenize_rejects_capitalized_identifier_test() ->
    ?assertEqual({error, {bad_token, "Foo/2"}},
        symbolic_extract:tokenize("Foo/2 calls bar/1")).

tokenize_rejects_malformed_token_test() ->
    ?assertEqual({error, {bad_token, "foo-2"}},
        symbolic_extract:tokenize("foo-2 calls bar/1")).

tokenize_rejects_empty_sentence_test() ->
    ?assertEqual({error, empty_sentence}, symbolic_extract:tokenize("   ")).

%% --- run_result/1: the real bounded grammar, consulted fresh each call ---
%%
%% Deliberately covers only the two claim shapes check_claim/1's own
%% sketch (docs/reviewing-llm-output.md §3.2) already knows how to check
%% against real facts — `calls` and `removed` — not a general-purpose
%% sentence grammar.

run_result_recognizes_calls_sentence_test() ->
    ?assertEqual({ok, {svo, {'/', foo, 2}, calls, {'/', bar, 1}}},
        symbolic_extract:run_result("foo/2 calls bar/1")).

run_result_recognizes_was_removed_sentence_test() ->
    ?assertEqual({ok, {svo, {'/', foo, 2}, removed, none}},
        symbolic_extract:run_result("foo/2 was removed")).

run_result_recognizes_no_longer_exists_sentence_test() ->
    ?assertEqual({ok, {svo, {'/', foo, 2}, removed, none}},
        symbolic_extract:run_result("foo/2 no longer exists.")).

%% Outside the bounded vocabulary: a real word, valid token syntax, but
%% no grammar clause matches it — phrase/2 fails, not a wrong guess.
run_result_unrecognized_outside_bounded_vocabulary_test() ->
    ?assertEqual(unrecognized,
        symbolic_extract:run_result("foo/2 improves performance")).

run_result_bad_token_is_a_tokenize_error_test() ->
    ?assertEqual({error, {tokenize_error, {bad_token, "Foo/2"}}},
        symbolic_extract:run_result("Foo/2 calls bar/1")).
