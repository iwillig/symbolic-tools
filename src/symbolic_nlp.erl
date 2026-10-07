%%% Erlang wrapper for the symbolic_nlp NIF (Rustler crate
%%% native/symbolic_nlp) — the statistical NL tier's tagger:
%%% POS tagging and NER over rust-bert, loaded per
%%% PLAN-statistical-nlp-tier.md Stage 1.
%%%
%%% Same wrapper shape as symbolic_text.erl: on_load dlopen of
%%% priv/<lib>.so, every stub nif_error until loaded. Callers must
%%% tolerate {error, Reason} returns AND an unloadable NIF (the crate
%%% is optional until the statistical tier is benchmarked) — callers
%%% catch nif_not_loaded and degrade, they never crash the pipeline.
-module(symbolic_nlp).
-export([tag/1, ner/1]).

-on_load(init/0).

-define(APPNAME, symbolic_tools).
-define(LIBNAME, symbolic_nlp).

init() ->
    SoFile =
        case code:priv_dir(?APPNAME) of
            {error, bad_name} ->
                filename:join(["priv", atom_to_list(?LIBNAME)]);
            Dir ->
                filename:join(Dir, atom_to_list(?LIBNAME))
        end,
    case erlang:load_nif(SoFile, 0) of
        ok -> ok;
        {error, _LoadReason} -> ok   %% optional NIF: absence degrades,
                                     %% it never takes the app down
    end.

%% tag(<<"does verifyPhoneCode call verifyOtp?">>) ->
%%   {ok, [{<<"does">>, <<"VBZ">>, Score}, ...]} — one {word, tag,
%%   score} tuple per token, question word order. Dirty CPU.
tag(_Text) -> erlang:nif_error(nif_not_loaded).

%% ner(<<"the Twilio Verify error leaks from JoinAccountModal">>) ->
%%   {ok, [{word, label, score}, ...]} — CoNLL-style labels (B-PER,
%%   I-ORG, ...). Dirty CPU.
ner(_Text) -> erlang:nif_error(nif_not_loaded).
