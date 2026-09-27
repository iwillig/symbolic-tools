%%% The open-vocabulary extraction tier — same `svo(Subject, Verb,
%%% Object)` output shape as the bounded-vocabulary `symbolic_extract`
%%% (DCG, priv/nlp_grammar.pl), so a downstream `check_claim/1` never
%%% needs to know which tier produced a claim. See
%%% docs/reviewing-llm-output.md §4/§4.2.
%%%
%%% Uses `erllama:chat/3`'s OpenAI-style tool calling (guides/tool-
%%% calls.md in the erllama dependency), not `complete/2,3` plus a raw-
%%% text parse: `arguments` comes back as an already-decoded, schema-
%%% typed Erlang map, and the model's own grammar-synthesizing auto-
%%% parser enforces the JSON schema during sampling — no re-parsing free
%%% text as Prolog syntax and hoping.
%%%
%%% `erllama_model_stub` (erllama's own no-model, no-NIF test backend)
%%% cannot exercise the `chat/3` + tools path at all — verified directly
%%% by spiking it, not assumed: `erllama_model.erl`'s `do_chat_apply/2`
%%% gates the whole chat path on the backend module exporting
%%% `get_model_ref/1`, which only the real llama.cpp backend does. So
%%% `test/symbolic_extract_llm_tests.erl` covers this module in three
%%% tiers: pure unit tests for the decoding helpers, a real integration
%%% test against the real stub (which can only ever reach the
%%% `chat_not_supported` branch), and meck-mocked `erllama:chat/3` for
%%% every other response shape — see that file's own header comment.
-module(symbolic_extract_llm).
-export([run/2]).
%% Exported for symbolic_extract_llm_tests.erl.
-export([run_result/2, decode_call/1, parse_ident/1, parse_verb/1, tools/0]).

%% The closed relation vocabulary — deliberately the same two verbs
%% check_claim/1's own sketch (docs/reviewing-llm-output.md §3.2) already
%% knows how to check, and the same two the DCG tier (priv/nlp_grammar.pl)
%% covers. This tier's whole value is open *phrasing*, not open
%% *vocabulary* — a relation outside this set should decay to
%% `unverifiable` downstream (§3.2's catch-all), never be invented here.
-define(KNOWN_VERBS, [<<"calls">>, <<"removed">>]).

%% halt() belongs only here, at the CLI's edge — see symbolic_query.erl's
%% own run/4 doc comment for why (run_result/2 stays a plain-term-
%% returning function so EUnit can exercise it directly).
-spec run(unicode:chardata(), map()) -> no_return().
run(Sentence, ModelOpts) ->
    case run_result(Sentence, ModelOpts) of
        {ok, Fact} ->
            io:format("~ts~n", [jsx:encode(symbolic_term_json:encode_term(Fact))]),
            halt(0);
        unrecognized ->
            io:format("Unrecognized.~n"),
            halt(1);
        {error, Reason} ->
            fail("cannot extract claim: ~p", [Reason])
    end.

%% The halt-free core: load a model (ModelOpts is passed straight to
%% erllama:load_model/1 — a real GGUF config for production, or
%% `#{backend => erllama_model_stub}` for the stub-backed integration
%% test), run one chat turn with the extract_svo tool, decode the
%% result, and always unload the model whether or not the chat itself
%% succeeded. One model load per call, the same "start fresh, do work,
%% tear down" shape as symbolic_query:run_result/3's own prolog_session
%% and symbolic_extract:run_result/1's own prolog_session — the only
%% viable shape for a one-shot CLI invocation anyway, no long-running
%% server to keep a model warm across calls.
-spec run_result(unicode:chardata(), map()) ->
    {ok, term()} | unrecognized | {error, term()}.
run_result(Sentence, ModelOpts) ->
    case erllama:load_model(ModelOpts) of
        {ok, Model} ->
            Result = chat_result(Model, Sentence),
            _ = erllama:unload(Model),
            Result;
        {error, Reason} ->
            {error, {load_model_error, Reason}}
    end.

chat_result(Model, Sentence) ->
    Messages = [#{role => user, content => unicode:characters_to_binary(Sentence)}],
    %% tool_choice defaults to `auto`, not `required`: the model must be
    %% free to decline the tool entirely for a sentence that doesn't
    %% describe a checkable relation at all — that's the `unrecognized`
    %% case below, not something to force a fabricated call for.
    case erllama:chat(Model, Messages, #{tools => tools(), temperature => 0.0}) of
        {ok, #{message := #{tool_calls := []}}} ->
            unrecognized;
        {ok, #{message := #{tool_calls := [Call | _]}}} ->
            decode_call(Call);
        {error, chat_not_supported} ->
            {error, {chat_not_supported, Model}};
        {error, Reason} ->
            {error, {chat_error, Reason}}
    end.

%% The one tool definition offered to the model. A closed `enum` on
%% `verb` keeps the relation vocabulary as narrow as check_claim/1
%% itself, enforced during sampling by erllama's own lazy tool-call
%% grammar (guides/tool-calls.md) — not just requested in a prompt.
%% `object` is not `required`: a `removed` claim has no real object (the
%% same asymmetry priv/nlp_grammar.pl's own DCG clauses encode).
-spec tools() -> [map()].
tools() ->
    [#{name => <<"extract_svo">>,
       description =>
           <<"Extract a subject-verb-object claim about code from a sentence, "
             "if and only if the sentence describes one of the supported "
             "relations. Do not call this for a sentence that isn't a "
             "structural claim about code.">>,
       parameters => #{
           type => object,
           properties => #{
               subject => #{type => string,
                            description => <<"Function/Arity, e.g. \"foo/2\"">>},
               verb => #{type => string, 'enum' => ?KNOWN_VERBS},
               object => #{type => string,
                           description =>
                               <<"Function/Arity for \"calls\"; omit for \"removed\"">>}},
           required => [subject, verb]}}].

%% Turn one tool_calls entry into the same {svo, Subject, Verb, Object}
%% shape symbolic_extract:run_result/1 (the DCG tier) already returns —
%% Subject/Object as {'/', Name, Arity} tuples, matching erlog's own
%% compound-term encoding (symbolic_term_json.erl's own convention).
-spec decode_call(map()) -> {ok, term()} | {error, term()}.
decode_call(#{name := <<"extract_svo">>, arguments := Args}) ->
    Subject = maps:get(<<"subject">>, Args, undefined),
    VerbBin = maps:get(<<"verb">>, Args, undefined),
    ObjectBin = maps:get(<<"object">>, Args, <<>>),
    case {parse_ident(Subject), parse_verb(VerbBin)} of
        {{ok, S}, {ok, calls}} ->
            case parse_ident(ObjectBin) of
                {ok, O} -> {ok, {svo, S, calls, O}};
                error -> {error, {malformed_arguments, Args}}
            end;
        {{ok, S}, {ok, removed}} ->
            {ok, {svo, S, removed, none}};
        _ ->
            {error, {malformed_arguments, Args}}
    end;
decode_call(Call) ->
    {error, {unexpected_tool_call, Call}}.

%% A Function/Arity identifier, e.g. <<"foo/2">> -> {'/', foo, 2} — the
%% same shape defines/5's own Function values take (Erlang function
%% names are always lowercase-initial atoms), and the same validation
%% symbolic_extract:tokenize/1 already applies for the DCG tier, applied
%% here to a tool-call argument instead of a raw sentence word.
-spec parse_ident(binary() | undefined) -> {ok, term()} | error.
parse_ident(Bin) when is_binary(Bin) ->
    case re:run(Bin, "^([a-z][a-zA-Z0-9_]*)/([0-9]+)$",
                [{capture, all_but_first, binary}]) of
        {match, [NameBin, ArityBin]} ->
            {ok, {'/', binary_to_atom(NameBin, utf8), binary_to_integer(ArityBin)}};
        nomatch ->
            error
    end;
parse_ident(_) ->
    error.

%% A defense-in-depth check even though the tool schema's own `enum`
%% should already keep a well-behaved model from emitting anything
%% outside ?KNOWN_VERBS.
-spec parse_verb(binary() | undefined) -> {ok, atom()} | error.
parse_verb(<<"calls">>) -> {ok, calls};
parse_verb(<<"removed">>) -> {ok, removed};
parse_verb(_) -> error.

fail(Fmt, Args) ->
    io:put_chars(standard_error, io_lib:format(Fmt ++ "~n", Args)),
    halt(1).
