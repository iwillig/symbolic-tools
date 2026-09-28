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

%% --- run_result/2: §4.2 Phase 3's fallback chaining onto
%% symbolic_extract_llm. DCG first, always; the LLM tier is only ever
%% consulted on `unrecognized`, and only when a model path is given.

%% A DCG-recognized sentence must never touch the LLM tier at all --
%% proved here with a deliberately nonexistent model path: if the
%% fallback branch ran, model_opts/1 would fail on the missing file and
%% surface as {error, {model_error, _}} instead of the real DCG result.
run_result_2_never_falls_back_when_the_dcg_recognizes_it_test() ->
    ?assertEqual({ok, {svo, {'/', foo, 2}, calls, {'/', bar, 1}}},
        symbolic_extract:run_result("foo/2 calls bar/1", "/no/such/model.gguf")).

%% Unrecognized by the DCG, no model configured: same as run_result/1
%% alone -- no fallback attempted, no error about a missing model either.
run_result_2_unrecognized_with_no_model_configured_test() ->
    ?assertEqual(unrecognized,
        symbolic_extract:run_result("foo/2 improves performance", undefined)).

%% Unrecognized by the DCG, a model path given, but the file doesn't
%% exist -- the fallback really was attempted (not silently skipped),
%% and its own failure is reported, not swallowed as `unrecognized`.
run_result_2_reports_a_real_model_load_failure_test() ->
    ?assertMatch({error, {model_error, _}},
        symbolic_extract:run_result("foo/2 improves performance", "/no/such/model.gguf")).

%% Unrecognized by the DCG, a model configured: the LLM tier's own
%% result is what comes back, verbatim -- meck-mocked so this proves the
%% composition wiring, not symbolic_extract_llm's own logic (that's
%% symbolic_extract_llm_tests.erl's job).
run_result_2_returns_the_llm_tiers_result_when_the_dcg_cant_parse_it_test() ->
    meck:new(symbolic_extract_llm),
    meck:expect(symbolic_extract_llm, model_opts, fun(_Path) -> {ok, #{model_path => "m"}} end),
    meck:expect(symbolic_extract_llm, run_result, fun(_Sentence, _Opts) ->
        {ok, {svo, {'/', foo, 2}, removed, none}}
    end),
    Result =
        try symbolic_extract:run_result("foo/2 improves performance", "/some/model.gguf")
        after meck:unload(symbolic_extract_llm)
        end,
    ?assertEqual({ok, {svo, {'/', foo, 2}, removed, none}}, Result).
