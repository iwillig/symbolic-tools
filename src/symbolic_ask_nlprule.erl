-module(symbolic_ask_nlprule).
-moduledoc """
Convert nlprule sentence analysis into bounded question-frame candidates.

This module accepts the analysis map returned by `symbolic_analyze` and
reuses the closed frame mapper in `symbolic_ask`. Its results are candidate
interpretations only. It does not resolve code entities, construct Prolog
goals, or prove claims.
""".
-export([extract_frames/1, extract_json_frames/1]).

-doc """
Extract bounded Erlang frame candidates from an nlprule analysis map.

The input map must contain a `sentences` list. For each recognized sentence,
the result contains a 1-based `sentence_index`, the mapped `frame` term, and
the original valid `analysis_tokens`. The `frame` uses the existing bounded
Erlang term shapes from `symbolic_ask:map_tags/1`.

Malformed input and sentences that do not match a supported frame produce no
candidate. An empty result is not a proof that the natural-language claim is
false.

Example:

    {ok, Analysis} = symbolic_analyze:run_result("Does foo/2 call bar/1?"),
    [#{frame := {yes_no, {calls, _, _}}}] =
        symbolic_ask_nlprule:extract_frames(Analysis).
""".
-spec extract_frames(map()) -> [map()].
extract_frames(#{<<"sentences">> := Sentences}) when is_list(Sentences) ->
    extract_sentences(Sentences, 1, []);
extract_frames(_) ->
    [].

-doc """
Return recognized frame candidates as JSON-ready maps.

Each result includes `answer_type`, `relation`, and `arguments`, together
with `sentence_index`, source `sentence`, and annotated `tokens`. Some answer
types also include `answer_slot`. Entity arguments include their reconstructed
`text`, source `tokens`, and combined byte and character `span`. The maps use
binary keys and can be passed to `jsx:encode/1`.

Unsupported frame shapes are omitted. These maps remain unverified candidate
interpretations; callers must map them to the codebase schema and use a query
to validate a claim.

Example:

    {ok, Analysis} = symbolic_analyze:run_result("Does foo/2 call bar/1?"),
    [#{<<"answer_type">> := <<"yes_no">>,
       <<"relation">> := <<"calls">>}] =
        symbolic_ask_nlprule:extract_json_frames(Analysis).
""".
-spec extract_json_frames(map()) -> [map()].
extract_json_frames(Analysis) ->
    [JsonFrame || Candidate <- extract_frames(Analysis),
                  {ok, JsonFrame} <- [json_frame(Candidate)]].

extract_sentences([], _Index, Acc) ->
    lists:reverse(Acc);
extract_sentences([Sentence | Rest], Index, Acc) ->
    Next =
        case sentence_tokens(Sentence) of
            {ok, AnalysisTokens, FrameTokens} ->
                case symbolic_ask:map_tags(FrameTokens) of
                    {ok, Frame} ->
                        [#{sentence_index => Index,
                           sentence_text => sentence_text(Sentence),
                           frame => Frame,
                           analysis_tokens => AnalysisTokens} | Acc];
                    unrecognized -> Acc
                end;
            error ->
                Acc
        end,
    extract_sentences(Rest, Index + 1, Next).

sentence_tokens(#{<<"tokens">> := Tokens}) when is_list(Tokens) ->
    AnalysisTokens = [Token || Token <- Tokens, valid_token(Token)],
    FrameTokens = [token_pair(Token) || Token <- AnalysisTokens],
    {ok, AnalysisTokens, FrameTokens};
sentence_tokens(_) ->
    error.

valid_token(#{<<"text">> := Text}) when is_binary(Text) -> true;
valid_token(_) -> false.

sentence_text(#{<<"text">> := Text}) when is_binary(Text) -> Text;
sentence_text(_) -> <<>>.

token_pair(#{<<"text">> := Text} = Token) ->
    {normalize_question_word(Text), Token}.

%% The existing mapper recognizes these grammar words in lowercase. Preserve
%% all other surface forms exactly because code identifiers can be case-sensitive.
normalize_question_word(Text) ->
    Lower = list_to_binary(string:lowercase(binary_to_list(Text))),
    case lists:member(Lower, [
        <<"does">>, <<"do">>, <<"is">>, <<"are">>, <<"where">>,
        <<"which">>, <<"who">>, <<"what">>, <<"how">>, <<"many">>,
        <<"file">>, <<"config">>, <<"by">>
    ]) of
        true -> Lower;
        false -> Text
    end.

json_frame(#{sentence_index := Index, sentence_text := Sentence,
             analysis_tokens := Tokens, frame := Frame}) ->
    case frame_json(Frame) of
        {ok, Fields} ->
            {ok, Fields#{
                <<"sentence_index">> => Index,
                <<"sentence">> => Sentence,
                <<"tokens">> => Tokens
            }};
        error -> error
    end.

frame_json({yes_no, {Relation, Subject, Object}})
        when Relation =:= calls; Relation =:= uses;
             Relation =:= returns; Relation =:= handles ->
    {ok, #{
        <<"answer_type">> => <<"yes_no">>,
        <<"relation">> => atom_to_binary(Relation, utf8),
        <<"arguments">> => #{
            <<"subject">> => entity_json(Subject),
            <<"object">> => entity_json(Object)
        }
    }};
frame_json({yes_no, {defines, Subject}}) ->
    {ok, single_entity_frame(<<"yes_no">>, <<"defines">>, <<"subject">>, Subject)};
frame_json({yes_no, {file_scanned, Subject}}) ->
    {ok, single_entity_frame(<<"yes_no">>, <<"file_scanned">>, <<"file">>, Subject)};
frame_json({yes_no, {config_defined, Subject}}) ->
    {ok, single_entity_frame(<<"yes_no">>, <<"config_defined">>, <<"config">>, Subject)};
frame_json({AnswerType, {callers_of, Callee}})
        when AnswerType =:= enumerate; AnswerType =:= count ->
    {ok, #{
        <<"answer_type">> => atom_to_binary(AnswerType, utf8),
        <<"relation">> => <<"calls">>,
        <<"answer_slot">> => <<"subject">>,
        <<"arguments">> => #{<<"object">> => entity_json(Callee)}
    }};
frame_json({prose, Query}) ->
    {ok, single_entity_frame(<<"evidence">>, <<"text_search">>, <<"query">>, Query)};
frame_json({sites, {call_sites_of, Subject}}) ->
    {ok, single_entity_frame(<<"locations">>, <<"call_sites_of">>, <<"subject">>, Subject)};
frame_json({sites, {def_site_of, Subject}}) ->
    {ok, single_entity_frame(<<"locations">>, <<"definition_site_of">>, <<"subject">>, Subject)};
frame_json(_) ->
    error.

single_entity_frame(AnswerType, Relation, ArgumentName, Tokens) ->
    #{
        <<"answer_type">> => AnswerType,
        <<"relation">> => Relation,
        <<"arguments">> => #{ArgumentName => entity_json(Tokens)}
    }.

entity_json([]) ->
    #{<<"text">> => <<>>, <<"tokens">> => [], <<"span">> => null};
entity_json(Pairs) ->
    Tokens = [Token || {_Word, Token} <- Pairs],
    #{
        <<"text">> => render_text(Tokens),
        <<"tokens">> => Tokens,
        <<"span">> => combined_span(Tokens)
    }.

render_text(Tokens) ->
    iolist_to_binary(lists:foldl(fun(Token, Acc) ->
        Text = maps:get(<<"text">>, Token),
        Separator = case {Acc, maps:get(<<"has_space_before">>, Token, false)} of
            {[], _} -> <<>>;
            {_, true} -> <<" ">>;
            {_, false} -> <<>>
        end,
        [Acc, Separator, Text]
    end, [], Tokens)).

combined_span(Tokens) ->
    First = maps:get(<<"span">>, hd(Tokens)),
    Last = maps:get(<<"span">>, lists:last(Tokens)),
    #{
        <<"byte">> => #{
            <<"start">> => maps:get(<<"start">>, maps:get(<<"byte">>, First)),
            <<"end">> => maps:get(<<"end">>, maps:get(<<"byte">>, Last))
        },
        <<"char">> => #{
            <<"start">> => maps:get(<<"start">>, maps:get(<<"char">>, First)),
            <<"end">> => maps:get(<<"end">>, maps:get(<<"char">>, Last))
        }
    }.
