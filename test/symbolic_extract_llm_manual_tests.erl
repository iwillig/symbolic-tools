-module(symbolic_extract_llm_manual_tests).
-include_lib("eunit/include/eunit.hrl").

%% Phase 2 of docs/reviewing-llm-output.md §4.2: accuracy checks against
%% a real GGUF model, not the plumbing coverage
%% symbolic_extract_llm_tests.erl already owns (that file is
%% meck-mocked and stub-backed, runs in every ordinary test cycle, and
%% needs no model at all).
%%
%% Skipped by default: EUnit has no first-class "skip" return value —
%% checked directly against eunit's own source rather than assumed
%% (`{skip, Reason}` from a `_test_/0` generator is a "bad test
%% descriptor", confirmed by actually running it), so each gated test
%% below returns `[]` (a documented no-op in a test generator, per
%% eunit_lib.erl's own "skipping an initial/final empty list" comment)
%% when SYMBOLIC_LLM_MODEL_PATH isn't set. `gate_status_test/0` is the
%% one always-run test in this file: it uses `?debugMsg/1` (which prints
%% regardless of verbosity, unlike a bare test name) so the fact that
%% every other test in this module quietly contributed zero cases is
%% visible in ordinary output, not silently absent. See
%% docs/symbolic-extract-llm-setup.md for how to get a model and run
%% this file for real.
%%
%% Every case here was run for real against Qwen2.5-3B-Instruct
%% (Q4_K_M, Metal, n_gpu_layers => 99) before being written down — this
%% file documents actually-observed model behavior, not aspirational
%% "should work" assertions. Two known, real accuracy limits are their
%% own tests below instead of being smoothed over — see each test's own
%% comment.

-define(ENV_VAR, "SYMBOLIC_LLM_MODEL_PATH").

%% Always runs; the one visible signal that the rest of this module is
%% (or isn't) actually exercising a real model this run.
gate_status_test() ->
    case os:getenv(?ENV_VAR) of
        false ->
            ?debugMsg(?ENV_VAR ++
                " not set -- real-model accuracy tests in this module skipped "
                "(see docs/symbolic-extract-llm-setup.md)");
        Path ->
            ?debugMsg("running real-model accuracy tests against " ++ Path)
    end.

with_real_model(TestFun) ->
    case os:getenv(?ENV_VAR) of
        false ->
            [];
        Path ->
            [{timeout, 60, fun() ->
                %% symbolic_extract_llm:run_result/2 itself now starts
                %% erllama (see its own doc comment) -- nothing extra
                %% needed here.
                {ok, Opts} = symbolic_extract_llm:model_opts(Path),
                TestFun(Opts)
            end}]
    end.

%% A real, true dogfooded sentence about this repo's own code:
%% symbolic_extract_llm:run_result/2 really does call chat_result/2
%% (src/symbolic_extract_llm.erl) -- the same dogfooding pattern
%% stale_doc_example/4 already established, applied to a plain sentence
%% instead of a fenced code sample.
recognizes_a_real_calls_claim_test_() ->
    with_real_model(fun(Opts) ->
        ?assertEqual({ok, {svo, {'/', run_result, 2}, calls, {'/', chat_result, 2}}},
            symbolic_extract_llm:run_result(<<"run_result/2 calls chat_result/2">>, Opts))
    end).

recognizes_a_real_removed_claim_test_() ->
    with_real_model(fun(Opts) ->
        ?assertEqual({ok, {svo, {'/', frobnicate_widget, 9}, removed, none}},
            symbolic_extract_llm:run_result(<<"frobnicate_widget/9 was removed">>, Opts))
    end).

%% Known limitation, recorded rather than hidden: prose without a real
%% Function/Arity shape ("the parser", "the scanner") is correctly
%% *rejected* by decode_call/1's own validation, not silently guessed
%% at with a fabricated arity.
rejects_prose_without_function_arity_shape_test_() ->
    with_real_model(fun(Opts) ->
        ?assertMatch({error, {malformed_arguments, _}},
            symbolic_extract_llm:run_result(<<"the parser calls the scanner">>, Opts))
    end).

%% Known limitation, recorded rather than hidden -- and a more
%% surprising one than it first looked. A sentence that names a
%% real-shaped function but describes neither known relation can be
%% confidently misclassified rather than declined (schema validity is
%% not semantic truth, docs/reviewing-llm-output.md §5/§4.2) -- but
%% repeating this exact call across separate real runs, same sentence,
%% same `temperature => 0.0`, produced BOTH outcomes: sometimes a wrong
%% `{ok, {svo, foo/2, removed, none}}`, sometimes a correct
%% `unrecognized`. Not a flaky test -- a genuinely observed
%% non-determinism, most likely `erllama`'s own byte-exact KV cache
%% taking a warm-restored path on a repeat load of the same fingerprint
%% versus a cold prefill on a fresh one, with a floating-point
%% computation-order difference between the two that a temperature-0
%% sampler can't paper over. So this asserts only what's actually
%% stable across every observed run: the call itself always completes
%% (`ok` or `unrecognized`, never a crash or a decode error), which is
%% weaker than "always right" and weaker even than "always the same
%% wrong answer" -- both would overstate what this model, run this way,
%% is actually known to do.
off_topic_sentence_can_be_misclassified_rather_than_declined_test_() ->
    with_real_model(fun(Opts) ->
        Result = symbolic_extract_llm:run_result(<<"foo/2 improves performance">>, Opts),
        ?assert(case Result of
            unrecognized -> true;
            {ok, {svo, _, _, _}} -> true;
            _ -> false
        end)
    end).
