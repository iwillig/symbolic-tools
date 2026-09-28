%%% `symbolic extract "<sentence>"` — parse a short, bounded-vocabulary
%%% sentence into an svo(Subject, Verb, Object) claim shaped to compose
%%% directly with this project's own fact predicates (calls/5, defines/5,
%%% ...). See docs/reviewing-llm-output.md §3.1/§3.2, docs/curt-approach.md
%%% §5.
%%%
%%% Deliberately the "zero-model" tier of the extraction design: a fixed
%%% DCG grammar (priv/nlp_grammar.pl), not an LLM — covers exactly the
%%% bounded vocabulary that grammar knows, nothing open-ended. A sentence
%%% outside it comes back `unrecognized`, loudly, never guessed at; that
%%% open-vocabulary gap is exactly why reviewing-llm-output.md §3.2 points
%%% at an LLM for the general case, not this grammar.
%%%
%%% Loaded via `consult`, not `assertz`: DCG translation (`-->` into a
%%% real difference-list clause) is a consult-time transformation in
%%% erlog, confirmed directly (docs/curt-approach.md §5) — an
%%% `assertz((sentence(_) --> ...))` would silently register nothing
%%% usable.
-module(symbolic_extract).
-export([run/1, run/2]).
%% Exported for symbolic_extract_tests.erl — run_result/1,2 are the
%% halt-free core; tokenize/1 is its own pure, independently-tested piece.
-export([run_result/1, run_result/2, tokenize/1]).

-define(GRAMMAR_FILE, "nlp_grammar.pl").

%% halt() belongs only here, at the CLI's edge — see symbolic_query.erl's
%% own run/4 doc comment for why (erlang:halt/0,1 deep in business logic
%% is a well-known anti-pattern; run_result/1,2 stay plain-term-returning
%% functions so EUnit can exercise them directly).
-spec run(unicode:chardata()) -> no_return().
run(Sentence) -> run(Sentence, undefined).

%% ModelPath enables §4.2 Phase 3's fallback chaining onto
%% symbolic_extract_llm — `undefined` (no `--model` flag given) keeps
%% this identical to run/1: DCG only, `unrecognized` reported as-is.
-spec run(unicode:chardata(), file:filename() | undefined) -> no_return().
run(Sentence, ModelPath) ->
    case run_result(Sentence, ModelPath) of
        {ok, Fact} ->
            io:format("~ts~n", [jsx:encode(symbolic_term_json:encode_term(Fact))]),
            halt(0);
        unrecognized ->
            io:format("Unrecognized.~n"),
            halt(1);
        {error, Reason} ->
            fail("cannot extract claim: ~p", [Reason])
    end.

%% The halt-free core: tokenize the sentence, consult the bundled bounded
%% grammar into a fresh session, and attempt phrase(sentence(Fact),
%% Tokens). Starts (and always stops) its own prolog_session — same
%% shape as symbolic_query:run_result/3.
-spec run_result(unicode:chardata()) ->
    {ok, term()} | unrecognized | {error, term()}.
run_result(Sentence) ->
    case tokenize(Sentence) of
        {ok, TokensText} -> run_checked(TokensText);
        {error, Reason} -> {error, {tokenize_error, Reason}}
    end.

%% The bounded grammar tries first, always — free, deterministic,
%% always available. The open-vocabulary tier (symbolic_extract_llm) is
%% only ever consulted when the DCG comes back `unrecognized`, and only
%% when ModelPath is given: a DCG success or a real tokenize/grammar
%% error never falls through, and no model is loaded at all unless the
%% bounded grammar genuinely couldn't parse the sentence. Exactly the
%% two-tier design docs/reviewing-llm-output.md §3.1 already states in
%% words, as actual fallback logic (§4.2 Phase 3).
-spec run_result(unicode:chardata(), file:filename() | undefined) ->
    {ok, term()} | unrecognized | {error, term()}.
run_result(Sentence, ModelPath) ->
    case run_result(Sentence) of
        unrecognized when ModelPath =/= undefined -> run_with_model(Sentence, ModelPath);
        Other -> Other
    end.

run_with_model(Sentence, ModelPath) ->
    case symbolic_extract_llm:model_opts(ModelPath) of
        {ok, Opts} -> symbolic_extract_llm:run_result(Sentence, Opts);
        {error, Reason} -> {error, {model_error, Reason}}
    end.

run_checked(TokensText) ->
    {ok, Pid} = prolog_session:start_link(),
    Result =
        case prolog_session:consult(Pid, grammar_file()) of
            ok -> query_result(Pid, TokensText);
            {error, Reason} -> {error, {grammar_error, Reason}}
        end,
    prolog_session:stop(Pid),
    Result.

query_result(Pid, TokensText) ->
    Goal = "phrase(sentence(Fact), " ++ TokensText ++ ")",
    case prolog_session:query(Pid, Goal) of
        {ok, Bindings} -> {ok, proplists:get_value('Fact', Bindings)};
        no_solution -> unrecognized;
        {error, Reason} -> {error, {query_failed, Reason}}
    end.

grammar_file() ->
    filename:join(priv_dir(), ?GRAMMAR_FILE).

%% Same code:priv_dir/1 + {error, bad_name} fallback shape as
%% symbolic_version.erl's git_sha/0 and symbolic_ts.erl's own NIF lookup.
priv_dir() ->
    case code:priv_dir(symbolic_tools) of
        {error, bad_name} -> "priv";
        Dir -> Dir
    end.

%% Turn a raw sentence into Prolog list-literal text ("[foo/2, calls,
%% bar/1]") a `phrase/2` goal can embed directly — no separate tokenizer
%% predicate needed on the Prolog side, matching how prolog_session's own
%% query/2 already expects a plain goal string (erlog_io:read_string/1
%% parses it). Every word must already be valid, unquoted Prolog syntax:
%% a bare lowercase atom (a filler word: "calls", "was", ...) or a
%% Name/Arity term ("foo/2") — the same shape defines/5's own Function
%% values take, since Erlang function names are always lowercase-initial
%% atoms by the language's own syntax rules. A capitalized word would
%% otherwise silently become a Prolog VARIABLE inside the goal text
%% instead of the atom it looks like — rejected here, loudly, rather than
%% risking that.
-spec tokenize(unicode:chardata()) ->
    {ok, string()} | {error, empty_sentence | {bad_token, string()}}.
tokenize(Sentence) ->
    Text = unicode:characters_to_list(Sentence),
    Trimmed = strip_trailing_punctuation(string:trim(Text)),
    case string:lexemes(Trimmed, " \t\n") of
        [] -> {error, empty_sentence};
        Words -> check_tokens(Words)
    end.

strip_trailing_punctuation(Text) ->
    string:trim(Text, trailing, ".!?").

check_tokens(Words) ->
    check_tokens(Words, []).

check_tokens([], Acc) ->
    {ok, "[" ++ join_tokens(lists:reverse(Acc)) ++ "]"};
check_tokens([Word | Rest], Acc) ->
    case valid_token(Word) of
        true -> check_tokens(Rest, [Word | Acc]);
        false -> {error, {bad_token, Word}}
    end.

valid_token(Word) ->
    re:run(Word, "^[a-z][a-zA-Z0-9_]*(/[0-9]+)?$") =/= nomatch.

join_tokens([]) -> "";
join_tokens([Word]) -> Word;
join_tokens([Word | Rest]) -> Word ++ ", " ++ join_tokens(Rest).

fail(Fmt, Args) ->
    io:put_chars(standard_error, io_lib:format(Fmt ++ "~n", Args)),
    halt(1).
