-module(symbolic_extract_llm_tests).
-include_lib("eunit/include/eunit.hrl").

%% run/2 itself stays untested here — same reasoning as
%% symbolic_query_tests.erl's own note: it only prints and halt()s.
%%
%% Three tiers, deliberately not one, because a real spike found
%% `erllama_model_stub` cannot exercise `chat/3` + tools at all —
%% verified directly (not assumed): `erllama:chat/3` against a
%% stub-backed model returns `{error, chat_not_supported}` every time,
%% because `erllama_model.erl`'s `do_chat_apply/2` gates the whole chat
%% path on the backend module exporting `get_model_ref/1`, which only
%% the real llama.cpp backend does — a structural property of the stub,
%% not a gap in this test suite.
%%
%%   1. Pure unit tests (parse_ident/1, parse_verb/1, decode_call/1) —
%%      no erllama call at all.
%%   2. A real integration test against the real stub backend — covers
%%      the actual load_model/chat/unload call path this module makes,
%%      including the one response shape (`chat_not_supported`) the
%%      stub can genuinely produce.
%%   3. meck-mocked `erllama:chat/3` — the only way to exercise this
%%      module's own tool-call decoding against a realistic well-formed
%%      (or malformed) response shape without a real GGUF model, same
%%      "mock the impure boundary" pattern symbolic_cli_tests.erl
%%      already uses for symbolic_query/symbolic_parse/symbolic_serve.

%% --- pure: parse_ident/1, parse_verb/1, decode_call/1 ---

parse_ident_valid_test() ->
    ?assertEqual({ok, {'/', foo, 2}}, symbolic_extract_llm:parse_ident(<<"foo/2">>)).

parse_ident_rejects_capitalized_test() ->
    ?assertEqual(error, symbolic_extract_llm:parse_ident(<<"Foo/2">>)).

parse_ident_rejects_missing_arity_test() ->
    ?assertEqual(error, symbolic_extract_llm:parse_ident(<<"foo">>)).

parse_ident_rejects_malformed_test() ->
    ?assertEqual(error, symbolic_extract_llm:parse_ident(<<"foo-2">>)).

parse_verb_known_relations_test() ->
    ?assertEqual({ok, calls}, symbolic_extract_llm:parse_verb(<<"calls">>)),
    ?assertEqual({ok, removed}, symbolic_extract_llm:parse_verb(<<"removed">>)).

parse_verb_rejects_unknown_relation_test() ->
    %% Outside the closed vocabulary check_claim/1 (reviewing-llm-output.md
    %% §3.2) knows how to check — the schema's own `enum` should keep a
    %% well-behaved model from emitting this at all, but decode_call/1
    %% doesn't trust that alone.
    ?assertEqual(error, symbolic_extract_llm:parse_verb(<<"improves">>)).

decode_call_calls_test() ->
    Call = #{name => <<"extract_svo">>,
             arguments => #{<<"subject">> => <<"foo/2">>, <<"verb">> => <<"calls">>,
                            <<"object">> => <<"bar/1">>}},
    ?assertEqual({ok, {svo, {'/', foo, 2}, calls, {'/', bar, 1}}},
        symbolic_extract_llm:decode_call(Call)).

%% `removed` needs no real object — the same asymmetry the DCG tier's
%% own grammar (priv/nlp_grammar.pl) encodes structurally.
decode_call_removed_ignores_object_test() ->
    Call = #{name => <<"extract_svo">>,
             arguments => #{<<"subject">> => <<"foo/2">>, <<"verb">> => <<"removed">>}},
    ?assertEqual({ok, {svo, {'/', foo, 2}, removed, none}},
        symbolic_extract_llm:decode_call(Call)).

decode_call_malformed_subject_is_an_error_test() ->
    Call = #{name => <<"extract_svo">>,
             arguments => #{<<"subject">> => <<"Foo/2">>, <<"verb">> => <<"calls">>,
                            <<"object">> => <<"bar/1">>}},
    ?assertMatch({error, {malformed_arguments, _}}, symbolic_extract_llm:decode_call(Call)).

decode_call_unexpected_tool_name_is_an_error_test() ->
    Call = #{name => <<"something_else">>, arguments => #{}},
    ?assertMatch({error, {unexpected_tool_call, _}}, symbolic_extract_llm:decode_call(Call)).

%% --- real integration against the real stub backend ---

%% `erllama_model_sup` (and the rest of erllama's supervision tree) only
%% exists once the application is actually started, not merely on the
%% code path — confirmed directly: without this, load_model/1 fails with
%% `{noproc, {gen_server, call, [erllama_model_sup, ...]}}` rather than
%% ever reaching the stub backend at all. Also confirmed to bite the
%% released CLI binary's own one-shot invocation, not just `rebar3
%% eunit` — so run_result/2 itself now calls
%% application:ensure_all_started(erllama) before doing anything else
%% (see its own doc comment); nothing extra needed here any more.
run_result_against_stub_backend_reports_chat_not_supported_test() ->
    ?assertMatch({error, {chat_not_supported, _}},
        symbolic_extract_llm:run_result(<<"foo/2 calls bar/1">>,
            #{backend => erllama_model_stub})).

%% --- meck-mocked erllama:chat/3: this module's own decoding logic ---

with_mocked_erllama(ChatFun, Test) ->
    meck:new(erllama),
    meck:expect(erllama, load_model, fun(_Opts) -> {ok, <<"fake_model">>} end),
    meck:expect(erllama, unload, fun(_Model) -> ok end),
    meck:expect(erllama, chat, ChatFun),
    try Test() after meck:unload(erllama) end.

run_result_recognizes_a_well_formed_tool_call_test() ->
    with_mocked_erllama(
        fun(_Model, _Messages, _Opts) ->
            {ok, #{message => #{tool_calls => [
                #{name => <<"extract_svo">>,
                  arguments => #{<<"subject">> => <<"foo/2">>, <<"verb">> => <<"calls">>,
                                 <<"object">> => <<"bar/1">>},
                  id => undefined}]}}}
        end,
        fun() ->
            ?assertEqual({ok, {svo, {'/', foo, 2}, calls, {'/', bar, 1}}},
                symbolic_extract_llm:run_result(<<"foo/2 calls bar/1">>, #{model_path => "irrelevant"}))
        end).

%% The model declined to call the tool at all — free-form open-vocabulary
%% prose that doesn't describe a checkable relation. Not an error.
run_result_no_tool_call_is_unrecognized_test() ->
    with_mocked_erllama(
        fun(_Model, _Messages, _Opts) ->
            {ok, #{message => #{tool_calls => [], content => <<"That's not a code claim.">>}}}
        end,
        fun() ->
            ?assertEqual(unrecognized,
                symbolic_extract_llm:run_result(<<"the sky is blue">>, #{model_path => "irrelevant"}))
        end).

run_result_load_model_error_is_reported_test() ->
    meck:new(erllama),
    meck:expect(erllama, load_model, fun(_Opts) -> {error, {invalid_config, model_path, "nope"}} end),
    Result =
        try symbolic_extract_llm:run_result(<<"x/1 calls y/1">>, #{model_path => "nope"})
        after meck:unload(erllama)
        end,
    ?assertMatch({error, {load_model_error, _}}, Result).

run_result_chat_error_is_reported_test() ->
    with_mocked_erllama(
        fun(_Model, _Messages, _Opts) -> {error, decode_timeout} end,
        fun() ->
            ?assertMatch({error, {chat_error, decode_timeout}},
                symbolic_extract_llm:run_result(<<"x/1 calls y/1">>, #{model_path => "irrelevant"}))
        end).
