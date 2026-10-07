%%% `symbolic ask -db <facts.dets> "<question>"` — answer a bounded
%%% English question against a fact database: parse it with the question
%%% DCG (priv/question_grammar.pl), gate what is verifiable, prove the
%%% built goal in one prolog_session, shape the answer back by question
%%% type. The pipeline design and its research grounding are in
%%% docs/research-questions-to-prolog.md; the v1 vocabulary is
%%% deliberately the minimal one that plan §"final plan" records
%%% (calls, defines, discussed — DCG-only, JSON-only).
%%%
%%% Three design rules, each load-bearing:
%%%
%%% 1. The gate rejects before proving, never after. A wrong-arity
%%%    entity is {unverifiable, {wrong_arity, ...}} — loudly — because
%%%    a wrong arity otherwise answers a DIFFERENT question with full
%%%    confidence: "does anything call query_binary/1" proves N = 0
%%%    while query_binary/2 has a caller (found live, not assumed — the
%%%    research doc's §4 arity rule). Subjects are gated strictly
%%%    (must exist in defines/5); callees loosely (arity checked only
%%%    when the name is known to the base — a stdlib callee like
%%%    halt/1 has no defines/5 fact and must pass).
%%% 2. Prose questions return evidence, never verdicts. "Where is X
%%%    documented" routes to text_search/2 and reports hits; the
%%%    closed-world rule from the research doc §4 — absence in prose
%%%    is not falsity — is structural here, not a convention.
%%% 3. Exit codes carry the epistemics: 0 an answer (including false
%%%    and 0 — those ARE answers), 1 unrecognized phrasing, 2
%%%    unverifiable (the question needs repair, the asker should know).
%%%
%%% Like symbolic_query:run_result/3, one session per invocation, loaded
%%% fresh from the fact database, always stopped — and no Prolog engine
%%% on the tokenize path (symbolic_extract:tokenize/1 builds goal text
%%% directly).
-module(symbolic_ask).
-export([run/2]).
%% run_result/2 exported for symbolic_ask_tests.erl (the halt-free CLI
%% core); ask/2 for the MCP server's ask tool — the shared pipeline core
%% over a raw fact list: the CLI reads DETS, the MCP tool reads the
%% codebase cache. map_tags/1 and ident_candidates/1 are the Stage 2
%% statistical tier's pure halves (PLAN-statistical-nlp-tier.md),
%% exported for unit tests without the NIF.
-export([run_result/2, ask/2, map_tags/1, ident_candidates/1]).

-define(GRAMMAR_FILE, "question_grammar.pl").

%% halt() belongs only here, at the CLI's edge — same rule as
%% symbolic_query, symbolic_extract, symbolic_check, symbolic_search.
-spec run(file:filename(), string()) -> no_return().
run(DbPath, Question) ->
    case run_result(DbPath, Question) of
        {ok, Answer} ->
            io:format("~ts~n", [jsx:encode(Answer)]),
            halt(0);
        unrecognized ->
            io:put_chars(standard_error, "Unrecognized.\n"),
            halt(1);
        {error, {unverifiable, Reason}} ->
            io:format("~ts~n", [jsx:encode(#{
                <<"type">> => <<"unverifiable">>,
                <<"reason">> => iolist_to_binary(io_lib:format("~p", [Reason]))
            })]),
            halt(2);
        {error, Reason} ->
            fail("cannot answer: ~p", [Reason])
    end.

%% The CLI path: read the fact database, run the shared core. All
%% halt-free. `unrecognized` is its own return value, not an error: the
%% phrasing fell outside the grammar, which is a fact about the
%% question, not a failure of the machinery.
-spec run_result(file:filename(), string()) ->
    {ok, map()} | unrecognized | {error, term()}.
run_result(DbPath, Question) ->
    case filelib:is_regular(DbPath) of
        false ->
            {error, {no_such_db, DbPath}};
        true ->
            ask(symbolic_fact_store:read(DbPath), Question)
    end.

%% The shared pipeline core: tokenize, load a one-shot session from a
%% raw fact list, consult the question grammar, gate, prove, shape. The
%% CLI path (run_result/2, facts from DETS) and the MCP ask tool (facts
%% from the codebase cache) both land here — one pipeline, two sources.
-spec ask([tuple()], string()) ->
    {ok, map()} | unrecognized | {error, term()}.
ask(Facts, Question) ->
    {ok, Pid} = prolog_session:start_link(),
    Result =
        case prolog_session:load_facts(Pid, Facts) of
            ok ->
                case prolog_session:consult(Pid, grammar_file()) of
                    ok ->
                        %% The DCG's tokenizer rejects capitalized and
                        %% dotted tokens by design — those are exactly
                        %% what the statistical tier handles, so a
                        %% tokenize error falls through to it too.
                        case symbolic_extract:tokenize(Question) of
                            {ok, TokensText} ->
                                parse(Pid, TokensText, Question);
                            {error, _TokenizeReason} ->
                                statistical_fallback(Pid, Question)
                        end;
                    {error, Reason} ->
                        {error, {grammar_error, Reason}}
                end
        end,
    prolog_session:stop(Pid),
    Result.

parse(Pid, TokensText, Question) ->
    Goal = "phrase(question(Type, Rel), " ++ TokensText ++ ")",
    case prolog_session:query(Pid, Goal) of
        {ok, Bindings} ->
            %% Bindings come back in engine order, not goal-text order —
            %% look them up by name, never by position.
            answer(Pid, proplists:get_value('Type', Bindings),
                   proplists:get_value('Rel', Bindings));
        no_solution ->
            %% DCG said no: fall through to the statistical tier (Stage
            %% 2, PLAN-statistical-nlp-tier.md). Same session, same gate,
            %% same answer/3 — only the parse differs.
            statistical_fallback(Pid, Question);
        {error, Reason} ->
            {error, {parse_failed, Reason}}
    end.

%% --- stage 2: statistical fallback — POS tag sequence → relation ---
%%
%% DCG unrecognized no longer ends the pipeline. symbolic_nlp:tag/1
%% tags the raw question, map_tags/2 turns the tag sequence into a
%% bounded relation template (the SAME shapes the DCG emits), Stage 3's
%% ident_candidates/1 + resolve reconstruct Name/Arity idents from word
%% spans, and the existing gate + answer/3 run unchanged. The tier is
%% deterministic (one tag sequence, one answer) and degrades to plain
%% `unrecognized` when the NIF is absent — it never takes the pipeline
%% down.

statistical_fallback(Pid, Question) ->
    try symbolic_nlp:tag(unicode:characters_to_binary(Question)) of
        {ok, Tags} ->
            case map_tags(Tags) of
                unrecognized -> unrecognized;
                {ok, {prose, SpanWords}} ->
                    %% Same prose clause the DCG uses — evidence, never a
                    %% verdict. Glue tokens never make search sense.
                    Words = [W || {W, _} <- SpanWords,
                                  W =/= <<"_">>, W =/= <<".">>],
                    case Words of
                        [] -> unrecognized;
                        _ -> answer(Pid, prose, Words)
                    end;
                {ok, Template} ->
                    build_relation(Pid, Template)
            end;
        {error, _} ->
            unrecognized
    catch
        _:_ -> unrecognized   %% NIF not built/loaded: tier absent
    end.

%% The mapper: pure, no NIF, no session — unit-tested directly.
%% Input: [{Word, PosTag}] binaries from symbolic_nlp:tag/1, question
%% order. Output: a relation template in the SAME shapes the DCG emits
%% (spans of words standing where Name/Arity idents will go), or
%% `unrecognized`.

-define(VERB_TAGS, ["VB", "VBD", "VBG", "VBN", "VBP", "VBZ"]).

%% The NIF returns {Word, Tag, Score}; the mapper works on pairs. Both
%% shapes accepted so the pure unit tests need no fake scores.
pair({W, T}) -> {W, T};
pair({W, T, _Score}) -> {W, T}.

pair_word({W, _}) -> W;
pair_word({W, _, _}) -> W.

map_tags(Tags0) ->
    Tags = [pair(T) || T <- Tags0, not punctuation(pair_word(T))],
    case Tags of
        [{<<"does">>, _} | Rest] -> does_shape(Rest);
        [{<<"is">>, _} | Rest] -> is_shape(Rest);
        [{<<"are">>, _} | Rest] -> is_shape(Rest);
        [{<<"where">>, _}, {<<"is">>, _} | Rest] ->
            where_shape(Rest);
        [{<<"which">>, _} | Rest] -> wh_shape(enumerate, Rest);
        [{<<"who">>, _} | Rest] -> wh_shape(enumerate, Rest);
        [{<<"what">>, _} | Rest] -> wh_shape(enumerate, Rest);
        [{<<"how">>, _}, {<<"many">>, _} | Rest] -> wh_shape(count, Rest);
        _ -> unrecognized
    end.

%% Question-sentence punctuation only. A bare period token is NOT
%% punctuation here: inside dotted paths it is the glue that joins
%% `supabase` `.` `auth` back into `supabase.auth` (spike finding), and
%% ident_candidates handles a trailing one as a no-op.
punctuation(Word) when is_binary(Word) ->
    Chars = binary_to_list(Word),
    Chars =/= [] andalso lists:all(fun(C) -> C =:= $, orelse C =:= $? orelse C =:= $! end, Chars).

%% Returns the verb WORD (not the pair) plus the spans around it.
%%
%% Vocabulary-driven, not tag-driven: the tagger mis-tags code-adjacent
%% verbs (spike: `call` came back NN between two camelCase identifiers).
%% The closed relation table is the stronger prior — a token whose stem
%% is a known relation verb IS the main verb of a question in this
%% domain, whatever tag the model gave it. Tags still matter for
%% anything the table does not know (those stay unrecognized).
%%
%% One exception: a token followed by identifier glue (`handle` `_`
%% `query` in snake_case) is the FRONT HALF of an identifier, not a
%% verb — `handle_query` is a subject, and misreading its first half
%% as the verb left the question with an empty subject span.
find_verb(Tags) ->
    find_verb(Tags, []).

find_verb([], _Acc) ->
    none;
find_verb([{W, _} = T | Rest], Acc) ->
    %% A known-verb token whose NEXT word is identifier glue is the
    %% front half of a snake_case identifier (handle_query), not a verb.
    GlueNext = case Rest of
        [{NW, _} | _] -> NW =:= <<"_">> orelse NW =:= <<".">>;
        _ -> false
    end,
    case verb_relation(W) =/= other andalso not GlueNext of
        true -> {W, lists:reverse(Acc), Rest};
        false -> find_verb(Rest, [T | Acc])
    end.

find_tagged(Pred, Tags) -> find_tagged(Pred, Tags, []).

find_tagged(_Pred, [], _Acc) -> none;
find_tagged(Pred, [T | Rest], Acc) ->
    case Pred(T) of
        true -> {T, lists:reverse(Acc), Rest};
        false -> find_tagged(Pred, Rest, [T | Acc])
    end.

%% "does X call Y?" — verb splits the question into subject and object
%% spans; the verb's stem picks the relation. defines-family verbs take
%% no object ("does X exist?").
%% "does X call Y?" / "does X use Y?" / "does X return Y?" / "does X
%% handle Y?" — the verb's relation class picks the shape; object-taking
%% relations all read as {Relation, SubjectSpan, ObjectSpan}. The
%% subject span may open with the word `file` (a file subject; Stage
%% 2b's uses relation accepts it, others resolve as idents and gate).
does_shape(Words) ->
    case find_verb(Words) of
        {V, Before, After} when After =/= [] ->
            case verb_relation(V) of
                calls -> {ok, {yes_no, {calls, Before, After}}};
                uses -> {ok, {yes_no, {uses, Before, After}}};
                returns -> {ok, {yes_no, {returns, Before, After}}};
                handles -> {ok, {yes_no, {handles, Before, After}}};
                _ -> unrecognized
            end;
        {V, Before, []} ->
            case verb_relation(V) of
                defines -> {ok, {yes_no, {defines, Before}}};
                _ -> unrecognized
            end;
        none ->
            unrecognized
    end.

%% "is X defined?", the passive "is X called by Y?", and Stage 2b's
%% "is file F scanned?" / "is config K defined?" — a leading `file` or
%% `config` word switches to those shapes; otherwise the verb's stem
%% decides: define/exist → defines(subject); call-family + a `by` tail
%% → calls with subject and object swapped.
is_shape(Words) ->
    case Words of
        [{<<"file">>, _} | Rest] -> file_scanned_shape(Rest);
        [{<<"config">>, _} | Rest] -> config_defined_shape(Rest);
        _ -> is_verb_shape(Words)
    end.

file_scanned_shape(Words) ->
    case find_verb(Words) of
        {V, Before, _After} ->
            case verb_relation(V) of
                scanned when Before =/= [] ->
                    {ok, {yes_no, {file_scanned, Before}}};
                _ ->
                    unrecognized
            end;
        none ->
            unrecognized
    end.

config_defined_shape(Words) ->
    case find_verb(Words) of
        {V, Before, _After} ->
            case verb_relation(V) of
                defines when Before =/= [] ->
                    {ok, {yes_no, {config_defined, Before}}};
                _ ->
                    unrecognized
            end;
        none ->
            unrecognized
    end.

is_verb_shape(Words) ->
    case find_verb(Words) of
        {V, Before, After} ->
            case verb_relation(V) of
                defines ->
                    {ok, {yes_no, {defines, Before}}};
                calls ->
                    case After of
                        [{<<"by">>, _} | ByRest] when ByRest =/= [] ->
                            {ok, {yes_no, {calls, ByRest, Before}}};
                        _ ->
                            unrecognized
                    end;
                _ ->
                    unrecognized
            end;
        none ->
            unrecognized
    end.

%% "which functions call X?" / "who calls X?" / "how many functions
%% call X?" — Type carries enumerate vs count. The subject NP is
%% ignored (it is always "functions"/"callers"-shaped); the object span
%% after the verb is the callee. A passive tail (`called by X`) makes X
%% the caller instead.
wh_shape(Type, Words) ->
    case find_verb(Words) of
        {V, _Before, After} ->
            case verb_relation(V) of
                calls ->
                    Callee = lists:dropwhile(fun({W, _}) -> W =:= <<"by">> end, After),
                    case Callee of
                        [] -> unrecognized;
                        _ -> {ok, {Type, {callers_of, Callee}}}
                    end;
                _ ->
                    unrecognized
            end;
        none ->
            unrecognized
    end.

%% "where is X ...?" — the first known verb's class picks the answer:
%% prose verbs (documented/discussed) → prose evidence; call-family →
%% call SITES (file:line, Stage 2b); define-family → the definition
%% site. Everything between `is` and the verb is the subject span.
where_shape(Words) ->
    case find_verb(Words) of
        {V, Before, _After} when Before =/= [] ->
            case verb_relation(V) of
                prose -> {ok, {prose, Before}};
                calls -> {ok, {sites, {call_sites_of, Before}}};
                defines -> {ok, {sites, {def_site_of, Before}}};
                _ -> unrecognized
            end;
        _ ->
            unrecognized
    end.

%% --- stage 3: word span → Name/Arity candidates ---
%%
%% The tagger word-splits code identifiers (spike finding): snake_case
%% arrives as `optional` `_` `path`, dotted paths as `supabase` `.`
%% `auth` `.` `verifyOtp`, arities as `verifyOtp` `/` `2`. This joins
%% them back with the source spelling preserved — the gate matches
%% atoms exactly as defines/5 stores them. CamelCase tokens usually
%% survive whole (`verifyPhoneCode`), so the common case is one token.

ident_candidates(Tags) ->
    Ws = [W || {W, _} <- Tags,
               not lists:member(W, [<<"the">>, <<"a">>, <<"an">>,
                                    <<"this">>, <<"that">>, <<"these">>,
                                    <<"those">>, <<"my">>, <<"our">>,
                                    <<"their">>, <<"its">>])],
    case [S || S <- segments(Ws, none, <<>>, []), S =/= <<>>] of
        [] -> [];
        [Only] -> [Only];
        Multi ->
            Joined = iolist_to_binary(lists:join(<<"_">>, Multi)),
            [Joined | Multi]
    end.

%% Word list → identifier segments. Glue tokens merge their neighbours
%% into one segment (`optional` `_` `path` → `optional_path`; `supabase`
%% `.` `auth` → `supabase.auth`); a slash followed by digits is an arity
%% that closes the segment (`verifyOtp` `/` `2` → `verifyOtp/2`);
%% otherwise each word is its own segment (candidates to try in order).
segments([], _Joiner, Cur, Segs) ->
    lists:reverse([Cur | Segs]);
segments([W | Rest], Joiner, Cur, Segs) ->
    if
        W =:= <<"_">> orelse W =:= <<".">> ->
            seg_glue(Rest, W, Cur, Segs);
        W =:= <<"/">> ->
            seg_slash(Rest, Cur, Segs);
        Joiner =/= none ->
            seg_plain(Rest, none, <<Cur/binary, Joiner/binary, W/binary>>, Segs);
        Cur =:= <<>> ->
            seg_plain(Rest, none, W, Segs);
        true ->
            seg_plain(Rest, none, W, [Cur | Segs])
    end.

seg_glue(Rest, Joiner, Cur, Segs) ->
    %% A trailing glue token with nothing after it contributes nothing.
    case Rest of
        [] -> segments([], none, Cur, Segs);
        _ -> segments(Rest, Joiner, Cur, Segs)
    end.

seg_slash(Rest, Cur, Segs) ->
    case Rest of
        [D | Rest2] ->
            case is_digits(D) of
                true ->
                    WithArity = <<Cur/binary, "/", D/binary>>,
                    segments(Rest2, none, <<>>, [WithArity | Segs]);
                false ->
                    %% Stray slash: boundary, not an arity.
                    segments(Rest, none, <<>>, [Cur | Segs])
            end;
        [] ->
            segments([], none, <<>>, [Cur | Segs])
    end.

seg_plain(Rest, Joiner, Cur, Segs) ->
    segments(Rest, Joiner, Cur, Segs).

is_digits(B) when is_binary(B), byte_size(B) > 0 ->
    lists:all(fun(C) -> C >= $0 andalso C =< $9 end, binary_to_list(B));
is_digits(_) -> false.

split_arity(Cand) ->
    %% Last slash followed by only digits = an explicit arity.
    Size = byte_size(Cand),
    DigitsEnd = digits_run_from_end(Cand, Size),
    case DigitsEnd > 0 andalso binary:at(Cand, DigitsEnd - 1) =:= $/ of
        true ->
            Digits = binary:part(Cand, DigitsEnd, Size - DigitsEnd),
            {binary:part(Cand, 0, DigitsEnd - 1), binary_to_integer(Digits)};
        false ->
            {Cand, undefined}
    end.

digits_run_from_end(B, Pos) when Pos > 0 ->
    C = binary:at(B, Pos - 1),
    case C >= $0 andalso C =< $9 of
        true -> digits_run_from_end(B, Pos - 1);
        false -> Pos
    end;
digits_run_from_end(_B, 0) -> 0.

quoted_atom(Name) ->
    %% Always quote: code identifiers carry capitals and dots that bare
    %% atom syntax cannot hold, and a quoted atom can never become a
    %% Prolog variable.
    Escaped = binary:replace(
        binary:replace(Name, <<"\\">>, <<"\\\\">>, [global]),
        <<"'">>, <<"\\'">>, [global]),
    ["'", binary_to_list(Escaped), "'"].

arities_of(Pid, Name) ->
    Goal = "findall(A, defines(" ++ quoted_atom(Name) ++ ", A, _, _, _), L)",
    case prolog_session:query(Pid, Goal) of
        {ok, Bindings} -> {ok, proplists:get_value('L', Bindings)};
        no_solution -> {ok, []};   %% findall never fails; defensive
        {error, Reason} -> {error, Reason}
    end.

%% Subject resolution — strict-gate semantics. Candidates are tried in
%% order against defines/5; the first one present wins. No arity in the
%% question and exactly one known arity → use it; several known arities
%% → loudly ambiguous; an explicit arity that mismatches → wrong_arity.
resolve_ident(Pid, Words) ->
    Candidates = [split_arity(C) || C <- ident_candidates(Words)],
    resolve_strict(Pid, Candidates, Candidates).

resolve_strict(_Pid, [], []) ->
    {error, {unverifiable, {no_such_function, none, none}}};
resolve_strict(_Pid, [], [{Name, _} | _]) ->
    {error, {unverifiable, {no_such_function, Name, unknown}}};
resolve_strict(Pid, [{Name, Given} | Rest], All) ->
    case arities_of(Pid, Name) of
        {ok, []} -> resolve_strict(Pid, Rest, All);
        {ok, [A]} when Given =:= undefined -> {ok, {'/', Name, A}};
        {ok, [A]} when Given =:= A -> {ok, {'/', Name, A}};
        {ok, [_]} -> {error, {unverifiable, {wrong_arity, Name, Given}}};
        {ok, Many} when Given =:= undefined ->
            {error, {unverifiable, {ambiguous_arity, Name, Many}}};
        {ok, Many} ->
            case lists:member(Given, Many) of
                true -> {ok, {'/', Name, Given}};
                false -> {error, {unverifiable, {wrong_arity, Name, Given}}}
            end;
        {error, Reason} -> {error, Reason}
    end.

%% Object resolution — loose-gate semantics. A name unknown to the base
%% entirely (a stdlib or external callee) passes with `any` arity: the
%% proof then binds any arity, which is the honest reading of a question
%% that named no arity.
resolve_object(Pid, Words) ->
    Candidates = [split_arity(C) || C <- ident_candidates(Words)],
    resolve_loose(Pid, Candidates, Candidates).

resolve_loose(Pid, [{Name, Given} | Rest], All) ->
    case arities_of(Pid, Name) of
        {ok, []} when Rest =:= [] -> {ok, {'/', Name, any}};
        {ok, []} -> resolve_loose(Pid, Rest, All);
        {ok, [A]} when Given =:= undefined; Given =:= A -> {ok, {'/', Name, A}};
        {ok, [_]} -> {error, {unverifiable, {wrong_arity, Name, Given}}};
        {ok, Many} when Given =:= undefined ->
            {error, {unverifiable, {ambiguous_arity, Name, Many}}};
        {ok, Many} ->
            case lists:member(Given, Many) of
                true -> {ok, {'/', Name, Given}};
                false -> {error, {unverifiable, {wrong_arity, Name, Given}}}
            end;
        {error, Reason} -> {error, Reason}
    end;
resolve_loose(_Pid, [], [{Name, _} | _]) ->
    {ok, {'/', Name, any}}.

%% Template → resolved relation → the SAME answer/3 the DCG uses.
build_relation(Pid, {yes_no, {calls, SWords, OWords}}) ->
    case subject_kind(SWords) of
        {file, FileWords} ->
            %% "does file F call X?" — the file subject is gated on the
            %% scan, then the call is proven through the sites answer,
            %% whose {caller, file, line} entries already merge all
            %% three call shapes.
            case file_scanned_check(Pid, FileWords) of
                {ok, true} ->
                    FileBin = file_segment(FileWords),
                    case resolve_object(Pid, OWords) of
                        {ok, Object} ->
                            answer(Pid, yes_no, {calls_file, FileBin, Object});
                        Error -> Error
                    end;
                {ok, false} ->
                    {error, {unverifiable, {no_such_file, file_segment(FileWords)}}};
                Error ->
                    Error
            end;
        {ident, IdentWords} ->
            case resolve_ident(Pid, IdentWords) of
                {ok, Subject} ->
                    case resolve_object(Pid, OWords) of
                        {ok, Object} -> answer(Pid, yes_no, {calls, Subject, Object});
                        Error -> Error
                    end;
                Error -> Error
            end
    end;
build_relation(Pid, {yes_no, {defines, SWords}}) ->
    case resolve_ident(Pid, SWords) of
        {ok, Ident} -> answer(Pid, yes_no, {defines, Ident});
        Error -> Error
    end;
build_relation(Pid, {Type, {callers_of, OWords}})
    when Type =:= enumerate; Type =:= count ->
    case resolve_object(Pid, OWords) of
        {ok, Object} -> answer(Pid, Type, {callers_of, Object});
        Error -> Error
    end;
%% Stage 2b: uses. The subject may be a function (resolved strictly)
%% or a FILE (the span opens with the word `file`; gated on the file
%% actually being scanned). The object is a referenced NAME — tried as
%% candidates against expr_ref/6.
build_relation(Pid, {yes_no, {uses, SWords, OWords}}) ->
    case subject_kind(SWords) of
        {file, FileWords} ->
            case file_scanned_check(Pid, FileWords) of
                {ok, true} ->
                    FileBin = file_segment(FileWords),
                    answer(Pid, yes_no, {uses_file, FileBin, name_candidates(OWords)});
                {ok, false} ->
                    {error, {unverifiable, {no_such_file, file_segment(FileWords)}}};
                Error -> Error
            end;
        {ident, IdentWords} ->
            case resolve_ident(Pid, IdentWords) of
                {ok, Subject} ->
                    answer(Pid, yes_no, {uses, Subject, name_candidates(OWords)});
                Error -> Error
            end
    end;
%% Stage 2b: returns — a valued return statement that references the
%% name (return_stmt ∧ expr_ref join; mention-level, per the plan).
build_relation(Pid, {yes_no, {returns, SWords, OWords}}) ->
    case resolve_ident(Pid, SWords) of
        {ok, Subject} ->
            answer(Pid, yes_no, {returns, Subject, name_candidates(OWords)});
        Error -> Error
    end;
%% Stage 2b: handles — a branch-level literal equal to the name.
build_relation(Pid, {yes_no, {handles, SWords, OWords}}) ->
    case resolve_ident(Pid, SWords) of
        {ok, Subject} ->
            answer(Pid, yes_no, {handles, Subject, name_candidates(OWords)});
        Error -> Error
    end;
%% Stage 2b: file/config questions prove directly in their answer
%% clauses — pass the template through.
build_relation(Pid, {yes_no, {file_scanned, FileWords}}) ->
    answer(Pid, yes_no, {file_scanned, FileWords});
build_relation(Pid, {yes_no, {config_defined, KeyWords}}) ->
    answer(Pid, yes_no, {config_defined, KeyWords});
%% Stage 2b: where is X called / defined — file:line sites.
build_relation(Pid, {sites, {call_sites_of, OWords}}) ->
    case resolve_object(Pid, OWords) of
        {ok, Object} -> answer(Pid, sites, {call_sites_of, Object});
        Error -> Error
    end;
build_relation(Pid, {sites, {def_site_of, SWords}}) ->
    case resolve_ident(Pid, SWords) of
        {ok, Subject} -> answer(Pid, sites, {def_site_of, Subject});
        Error -> Error
    end.

%% A span opening with the word `file` is a file subject; the rest is
%% the file name. Anything else is an ident subject.
subject_kind([{<<"file">>, _} | Rest]) -> {file, Rest};
subject_kind(Words) -> {ident, Words}.

%% Name candidates for uses/returns/handles objects: identifier-shaped
%% words with the same glue reassembly, no arity pinning (a name in a
%% return or a comparison has no /N).
name_candidates(OWords) ->
    [C || C <- ident_candidates(OWords)].

%% The file name: dot-glued segments joined; the first candidate is the
%% full dotted name (JoinAccountModal.ts), which is what a scan check
%% matches on.
file_segment(FileWords) ->
    case ident_candidates(FileWords) of
        [First | _] -> First;
        [] -> <<>>
    end.

stem(Word) ->
    B = lower(Word),
    case suffix_of(B, [<<"ing">>, <<"ed">>, <<"es">>, <<"s">>]) of
        nomatch -> B;
        Stem -> Stem
    end.

%% The verb lookup with a consonant-doubling fallback: "scanned" stems
%% to "scann" (stripping "ed" cannot know not to undouble), and the
%% table entry is "scan". Try the stem, then the de-doubled form —
%% "called" → "call" hits directly, so the fallback never mangles it.
verb_relation(Word) ->
    S = stem(Word),
    case relation_of(S) of
        other ->
            case relation_of(dedup_consonant(S)) of
                other -> relation_of(e_form(S));
                R -> R
            end;
        R ->
            R
    end.

%% "defined" stems to "defin" — the -ed strip cannot know an -e belongs
%% back. Only consulted when neither the stem nor its de-doubled form is
%% in the table, so it never overrides a real entry.
e_form(S) -> <<S/binary, "e">>.

dedup_consonant(B) when byte_size(B) >= 2 ->
    Size = byte_size(B),
    A = binary:at(B, Size - 2),
    Z = binary:at(B, Size - 1),
    case A =:= Z andalso not lists:member(A, "aeiou") of
        true -> binary:part(B, 0, Size - 1);
        false -> B
    end;
dedup_consonant(B) -> B.

suffix_of(B, [Suf | Rest]) ->
    Size = byte_size(B),
    SufSize = byte_size(Suf),
    case Size > SufSize andalso binary:part(B, Size - SufSize, SufSize) =:= Suf of
        true -> binary:part(B, 0, Size - SufSize);
        false -> suffix_of(B, Rest)
    end;
suffix_of(_, []) -> nomatch.

relation_of(<<"call">>) -> calls;
relation_of(<<"invoke">>) -> calls;
relation_of(<<"hit">>) -> calls;
relation_of(<<"run">>) -> calls;
relation_of(<<"reach">>) -> calls;
relation_of(<<"delegate">>) -> calls;
relation_of(<<"depend">>) -> calls;
%% `use` is its own relation (Stage 2b): the object is a referenced
%% NAME (expr_ref), not necessarily a callee — "does verifyCode use
%% message" is about mentioning `message`, not calling it.
relation_of(<<"use">>) -> uses;
relation_of(<<"return">>) -> returns;
relation_of(<<"handle">>) -> handles;
relation_of(<<"map">>) -> handles;
relation_of(<<"define">>) -> defines;
relation_of(<<"exist">>) -> defines;
relation_of(<<"export">>) -> defines;
relation_of(<<"document">>) -> prose;
relation_of(<<"discuss">>) -> prose;
relation_of(<<"describe">>) -> prose;
relation_of(<<"scan">>) -> scanned;
relation_of(_) -> other.

lower(B) when is_binary(B) ->
    list_to_binary(string:lowercase(binary_to_list(B))).

%% --- stage 2+3: gate, then prove, per question type ---

%% Yes/no about a call: gate both idents, then prove either call shape
%% (a call fact is local(Name, Arity) inside a module or
%% remote(Module, Name, Arity) across one — the question is about
%%% "calls bar/1", not about which boundary).
answer(Pid, yes_no, {calls, Subject, Object}) ->
    case gate(Pid, Subject, strict, Object, loose) of
        ok -> yes_no_calls(Pid, Subject, Object);
        Unverifiable -> Unverifiable
    end;
%% Yes/no about existence: no gate — the proof IS the answer. "is zzz/9
%% defined" answering false is precise, not a trap (the arity trap is
%% about asking the WRONG question confidently; here the question asked
%% is the question answered).
%% Existence with an unresolved arity (statistical tier): true iff the
%% name has ANY defines fact — the honest reading of "is X defined?"
%% when the question named no arity. MUST precede the general
%% {defines, Ident} clause, which would otherwise swallow it.
answer(Pid, yes_no, {defines, {'/', Name, any}}) ->
    case prolog_session:query(Pid, defines_goal(Name, "_")) of
        {ok, _} -> {ok, yes_no_answer(true)};
        no_solution -> {ok, yes_no_answer(false)};
        {error, Reason} -> {error, {query_failed, Reason}}
    end;
answer(Pid, yes_no, {defines, Ident}) ->
    {'/', Name, Arity} = Ident,
    case prolog_session:query(Pid, defines_goal(Name, Arity)) of
        {ok, _} -> {ok, #{<<"type">> => <<"yes_no">>, <<"answer">> => true}};
        no_solution -> {ok, #{<<"type">> => <<"yes_no">>, <<"answer">> => false}};
        {error, Reason} -> {error, {query_failed, Reason}}
    end;
%% Enumeration: gate the callee, findall both call shapes, merge, dedup,
%% sort — stable output whatever order load_facts' asserta left.
answer(Pid, enumerate, {callers_of, Object}) ->
    case gate(Pid, Object, loose) of
        ok -> enumerate_callers(Pid, Object);
        Unverifiable -> Unverifiable
    end;
%% Count: distinct functions, same merge as enumerate.
answer(Pid, count, {callers_of, Object}) ->
    case gate(Pid, Object, loose) of
        ok ->
            case enumerate_callers(Pid, Object) of
                {ok, #{<<"answer">> := Callers}} ->
                    {ok, #{<<"type">> => <<"count">>,
                           <<"answer">> => length(Callers)}};
                Other -> Other
            end;
        Unverifiable -> Unverifiable
    end;
%% Prose: evidence, never a verdict (rule 2). No gate — there is nothing
%% to resolve in free text.
answer(Pid, prose, Span) ->
    QueryText = string:join([span_word(Word) || Word <- Span], " "),
    Goal = "text_search(\"" ++ QueryText ++ "\", Hits)",
    case prolog_session:query(Pid, Goal) of
        {ok, [{'Hits', Hits}]} ->
            {ok, #{<<"type">> => <<"prose">>,
                   <<"evidence">> => [evidence(H) || H <- Hits]}};
        no_solution ->
            unrecognized;   %% unreachable: text_search binds [] on no hits
        {error, Reason} ->
            {error, {query_failed, Reason}}
    end;
%% --- stage 2b answers: uses / returns / handles / sites / scanned / config ---

%% uses — the subject's code mentions the name (expr_ref/6). Each
%% candidate name is tried until one proves; none does → false, which
%% is an answer, not an error.
answer(Pid, yes_no, {uses, Subject, Candidates}) ->
    case bool_any(Pid, Candidates,
                  fun(C) -> expr_ref_anywhere(Subject, C) end) of
        {ok, Bool} -> {ok, yes_no_answer(Bool)};
        Error -> Error
    end;
%% uses with a file subject — any expr_ref of the name in a file whose
%% basename matches the question's file name.
answer(Pid, yes_no, {uses_file, FileBin, Candidates}) ->
    case bool_any(Pid, Candidates,
                  fun(C) ->
                      "findall(F, expr_ref(_, _, _, "
                          ++ quoted_atom_name(C) ++ ", F, _), L)"
                  end) of
        {ok, _} ->
            {ok, yes_no_answer(file_hits(Pid, FileBin, Candidates))};
        Error ->
            Error
    end;

%% returns — a valued return statement in the subject that references
%% the name: the return_stmt ∧ expr_ref join from the plan, mention
%% level by design (checks the claim, not value-flow).
%% returns — a valued return statement whose OWN LINE mentions the
%% name. Line-scoped deliberately: a function-level mention join would
%% answer true for a logger diagnostic that happens to name the field,
%% defeating the very true→false flip the claims check. Multi-line
%% return expressions are the accepted v1 blind spot.
answer(Pid, yes_no, {returns, Subject, Candidates}) ->
    case return_lines(Pid, Subject) of
        {ok, []} ->
            {ok, yes_no_answer(false)};
        {ok, Lines} ->
            Found = lists:any(
                fun(Line) ->
                    ViaRef = mentions_at_line(Pid, Subject, Candidates, Line,
                                              fun expr_ref_goal/3),
                    ViaKey = mentions_at_line(Pid, Subject, Candidates, Line,
                                              fun object_key_goal/3),
                    mention_true(ViaRef) orelse mention_true(ViaKey)
                end,
                Lines),
            {ok, yes_no_answer(Found)};
        Error ->
            Error
    end;

%% handles — a branch-level literal whose value equals the name
%% (case-insensitive), proving "maps/handles X" against literal/7.
answer(Pid, yes_no, {handles, {'/', SName, SArity}, Candidates}) ->
    %% literal/8: Id, Function, Arity, Kind, Value, File, Line, Raw
    %% (the tool description's literal/7 predates the Raw column).
    Goal = "findall(V, literal(_, " ++ quoted_atom_name(SName)
        ++ ", " ++ integer_to_list(SArity) ++ ", _, V, _, _, _), L)",
    case prolog_session:query(Pid, Goal) of
        {ok, Bindings} ->
            Values = proplists:get_value('L', Bindings, []),
            Wanted = [string:lowercase(binary_to_list(C)) || C <- Candidates],
            Found = lists:any(
                fun(V) ->
                    case flatten_value(V) of
                        nomatch -> false;
                        Flat -> lists:member(string:lowercase(Flat), Wanted)
                    end
                end,
                Values),
            {ok, yes_no_answer(Found)};
        no_solution ->
            {ok, yes_no_answer(false)};
        {error, Reason} ->
            {error, {query_failed, Reason}}
    end;

%% sites — WHERE is X called: every call site as {caller, file, line},
%% all three call shapes merged, deduped, sorted by file then line.
answer(Pid, sites, {call_sites_of, {'/', OName, OArity}}) ->
    OArityText = arity_text(OArity),
    Goal = "findall(st(C, A, F, L), calls(C, A, local("
        ++ quoted_atom_name(OName) ++ ", " ++ OArityText ++ "), F, L), L1), "
        ++ "findall(st(C, A, F, L), calls(C, A, remote(_, "
        ++ quoted_atom_name(OName) ++ ", " ++ OArityText ++ "), F, L), L2)"
        ++ member_sites_tail(OName, OArityText),
    case prolog_session:query(Pid, Goal) of
        {ok, Bindings} ->
            Sites = lists:usort(
                [site_entry(I)
                 || L <- [proplists:get_value('L1', Bindings, []),
                          proplists:get_value('L2', Bindings, []),
                          proplists:get_value('L3', Bindings, [])],
                    I <- L]),
            {ok, #{<<"type">> => <<"sites">>, <<"answer">> => Sites}};
        no_solution ->
            {error, {findall_never_fails, call_sites_of}};
        {error, Reason} ->
            {error, {query_failed, Reason}}
    end;

%% sites — WHERE is X defined: its defines/5 sites.
answer(Pid, sites, {def_site_of, {'/', SName, _SArity}}) ->
    Goal = "findall(st(" ++ quoted_atom_name(SName) ++ ", A, F, L), defines("
        ++ quoted_atom_name(SName) ++ ", A, _, F, L), L1)",
    case prolog_session:query(Pid, Goal) of
        {ok, Bindings} ->
            Sites = lists:usort(
                [site_entry(I)
                 || I <- proplists:get_value('L1', Bindings, [])]),
            {ok, #{<<"type">> => <<"sites">>, <<"answer">> => Sites}};
        no_solution ->
            {error, {findall_never_fails, def_site_of}};
        {error, Reason} ->
            {error, {query_failed, Reason}}
    end;

%% calls with a file subject — any call site of the object whose file
%% basename matches. Reuses the sites answer, which already merges all
%% three call shapes.
answer(Pid, yes_no, {calls_file, FileBin, Object}) ->
    case answer(Pid, sites, {call_sites_of, Object}) of
        {ok, #{<<"answer">> := Sites}} ->
            Found = lists:any(
                fun(#{<<"file">> := F}) -> file_matches(F, FileBin) end,
                Sites),
            {ok, yes_no_answer(Found)};
        {error, Reason} ->
            {error, Reason}
    end;

%% is file F scanned? — the gate IS the proof: the basename appears in
%% any fact's File field (defines, comments, paragraphs, config).
answer(Pid, yes_no, {file_scanned, FileWords}) ->
    case file_scanned_check(Pid, FileWords) of
        {ok, Bool} -> {ok, yes_no_answer(Bool)};
        Error -> Error
    end;

%% is config K defined? — exact dotted key against config_value/4.
answer(Pid, yes_no, {config_defined, KeyWords}) ->
    Key = file_segment(KeyWords),
    Goal = "config_value(_, " ++ quoted_atom_name(Key) ++ ", _, _)",
    bool_answer(Pid, Goal);
answer(_Pid, Type, Rel) ->
    {error, {unknown_question_shape, Type, Rel}}.

%% Helpers for the stage 2b answers — kept below the catch-all so the
%% answer/3 clause group stays unbroken.
member_sites_tail(OName, OArityText) ->
    case split_receiver_method(OName) of
        {Receiver, Method} ->
            ", findall(st(C, A, F, L), calls(C, A, member("
                ++ quoted_atom_name(Receiver) ++ ", "
                ++ quoted_atom_name(Method) ++ ", " ++ OArityText
                ++ "), F, L), L3)";
        none ->
            ""
    end.

site_entry({'st', Caller, CallerArity, File, Line}) ->
    #{<<"caller">> => render_ident({'-', Caller, CallerArity}),
      <<"file">> => to_bin(File),
      <<"line">> => Line};
site_entry(_Other) ->
    #{}.

file_scanned_check(Pid, FileWords) ->
    Base = file_segment(FileWords),
    %% Each source queried separately: a fact base may not carry every
    %% predicate (paragraph/3 is markdown-only), and an unknown
    %% predicate is an empty source, not an error.
    Sources = ["findall(F, defines(_, _, _, F, _), L)",
               "findall(F, comment(F, _, _), L)",
               "findall(F, paragraph(F, _, _), L)",
               "findall(F, config_value(F, _, _, _), L)"],
    Files = lists:append([files_from(Pid, G) || G <- Sources]),
    {ok, lists:any(fun(F) -> file_matches(F, Base) end, Files)}.

files_from(Pid, Goal) ->
    case prolog_session:query(Pid, Goal) of
        {ok, Bindings} -> proplists:get_value('L', Bindings, []);
        _ -> []
    end.

file_matches(File, BaseBin) when is_binary(BaseBin) ->
    Base = binary_to_list(BaseBin),
    case File of
        B when is_binary(B) -> filename:basename(binary_to_list(B)) =:= Base;
        L when is_list(L) -> filename:basename(lists:flatten(L)) =:= Base;
        A when is_atom(A) -> filename:basename(atom_to_list(A)) =:= Base;
        _ -> false
    end.

flatten_value(V) when is_atom(V) -> atom_to_list(V);
flatten_value(V) when is_binary(V) -> binary_to_list(V);
flatten_value(V) when is_list(V) ->
    case V of
        [] -> "";
        [C | _] when is_integer(C) -> V;
        _ -> nomatch
    end;
flatten_value(_) -> nomatch.

bool_answer(Pid, Goal) ->
    case prolog_session:query(Pid, Goal) of
        {ok, _} -> {ok, yes_no_answer(true)};
        no_solution -> {ok, yes_no_answer(false)};
        {error, Reason} -> {error, {query_failed, Reason}}
    end.

bool_any(_Pid, [], _GoalFun) ->
    {ok, false};
bool_any(Pid, [C | Rest], GoalFun) ->
    case prolog_session:query(Pid, GoalFun(C)) of
        {ok, _} -> {ok, true};
        no_solution -> bool_any(Pid, Rest, GoalFun);
        {error, Reason} -> {error, Reason}
    end.

expr_ref_goal({'/', SName, SArity}, Candidate, Line) ->
    "expr_ref(_, " ++ quoted_atom_name(SName) ++ ", "
        ++ integer_to_list(SArity) ++ ", " ++ quoted_atom_name(Candidate)
        ++ ", _, " ++ integer_to_list(Line) ++ ")".

%% uses stays function-level: "does X use W" asks whether X's code
%% mentions W anywhere, unlike returns which is line-scoped.
expr_ref_anywhere({'/', SName, SArity}, Candidate) ->
    "expr_ref(_, " ++ quoted_atom_name(SName) ++ ", "
        ++ integer_to_list(SArity) ++ ", " ++ quoted_atom_name(Candidate)
        ++ ", _, _)".

%% HasValue is the extractor's string "true" (a charlist in erlog),
    %% not the atom — matching the atom proves nothing and answers a
    %% confident false about real returns.
%% HasValue is the atom true (erlog's printer quotes every atom, which
%% once masqueraded as a string and sent this goal chasing "true").
object_key_goal({'/', SName, SArity}, Candidate, Line) ->
    "object_key(" ++ quoted_atom_name(SName) ++ ", "
        ++ integer_to_list(SArity) ++ ", " ++ quoted_atom_name(Candidate)
        ++ ", _, " ++ integer_to_list(Line) ++ ")".

mentions_at_line(Pid, Subject, Candidates, Line, GoalFun) ->
    bool_any_lenient(Pid, Candidates, fun(C) -> GoalFun(Subject, C, Line) end).

mention_true({ok, Bool}) -> Bool;
mention_true(_) -> false.

%% Like bool_any, but a predicate absent from the fact base counts as
%% an empty source instead of failing the question.
bool_any_lenient(_Pid, [], _GoalFun) ->
    {ok, false};
bool_any_lenient(Pid, [C | Rest], GoalFun) ->
    case prolog_session:query(Pid, GoalFun(C)) of
        {ok, _} -> {ok, true};
        no_solution -> bool_any_lenient(Pid, Rest, GoalFun);
        {error, {existence_error, procedure, _}} -> bool_any_lenient(Pid, Rest, GoalFun);
        {error, Reason} -> {error, Reason}
    end.

return_lines(Pid, {'/', SName, SArity}) ->
    Goal = "findall(L, return_stmt(" ++ quoted_atom_name(SName) ++ ", "
        ++ integer_to_list(SArity) ++ ", true, _, L), Ls)",
    case prolog_session:query(Pid, Goal) of
        {ok, Bindings} -> {ok, proplists:get_value('Ls', Bindings, [])};
        no_solution -> {ok, []};
        {error, {existence_error, procedure, _}} -> {ok, []};
        {error, Reason} -> {error, Reason}
    end.

file_hits(Pid, FileBin, Candidates) ->
    Hit = lists:any(
        fun(C) ->
            Goal = "findall(F, expr_ref(_, _, _, "
                ++ quoted_atom_name(C) ++ ", F, _), L)",
            case prolog_session:query(Pid, Goal) of
                {ok, Bindings} ->
                    Files = proplists:get_value('L', Bindings, []),
                    lists:any(fun(F) -> file_matches(F, FileBin) end, Files);
                _ ->
                    false
            end
        end,
        Candidates),
    Hit.

%% --- the gate: verifiability decided BEFORE proving ---

%% Subject strict: must exist in defines/5, or the question is about a
%% function that isn't in the scanned code at all.
gate(Pid, Ident, strict) ->
    {'/', Name, Arity} = Ident,
    case prolog_session:query(Pid, defines_goal(Name, Arity)) of
        {ok, _} -> ok;
        no_solution -> {error, {unverifiable, {no_such_function, Name, Arity}}};
        {error, Reason} -> {error, {query_failed, Reason}}
    end;
%% Callee loose: when the name is known to the base, the arity must be
%% one of its real arities (the query_binary/1 trap); when the name is
%% unknown entirely (a stdlib callee — halt/1, format/1), it passes —
%% the base cannot be expected to define external functions. `any`
%% arrives only from the statistical tier's resolver, which already
%% decided the arity question before handing the ident over.
gate(_Pid, {'/', _Name, any}, loose) ->
    ok;
gate(Pid, Ident, loose) ->
    {'/', Name, Arity} = Ident,
    case prolog_session:query(Pid, defines_goal(Name, "_")) of
        {ok, _} ->
            case prolog_session:query(Pid, defines_goal(Name, Arity)) of
                {ok, _} -> ok;
                no_solution -> {error, {unverifiable, {wrong_arity, Name, Arity}}};
                {error, Reason} -> {error, {query_failed, Reason}}
            end;
        no_solution -> ok;
        {error, Reason} -> {error, {query_failed, Reason}}
    end.

%% A gate for a calls-question's both idents at once — subject strict,
%% callee loose, subject checked first so its error wins.
gate(Pid, Subject, strict, Object, loose) ->
    case gate(Pid, Subject, strict) of
        ok -> gate(Pid, Object, loose);
        Unverifiable -> Unverifiable
    end.

%% Name may be an atom (DCG path) or a binary (statistical tier's
%% resolver) — both render quoted, which is harmless for legal atoms.
defines_goal(Name, Arity) when is_integer(Arity) ->
    "defines(" ++ quoted_atom_name(Name) ++ ", " ++ integer_to_list(Arity)
        ++ ", _, _, _)";
defines_goal(Name, ArityText) when is_list(ArityText) ->
    "defines(" ++ quoted_atom_name(Name) ++ ", " ++ ArityText ++ ", _, _, _)".

%% --- proving helpers ---

yes_no_calls(Pid, {'/', SName, SArity}, {'/', OName, OArity}) ->
    OArityText = arity_text(OArity),
    Local = "calls(" ++ quoted_atom_name(SName) ++ ", " ++ integer_to_list(SArity)
        ++ ", local(" ++ quoted_atom_name(OName) ++ ", " ++ OArityText
        ++ "), _, _)",
    Remote = "calls(" ++ quoted_atom_name(SName) ++ ", " ++ integer_to_list(SArity)
        ++ ", remote(_, " ++ quoted_atom_name(OName) ++ ", " ++ OArityText
        ++ "), _, _)",
    case prolog_session:query(Pid, Local) of
        {ok, _} -> {ok, yes_no_answer(true)};
        no_solution ->
            case prolog_session:query(Pid, Remote) of
                {ok, _} -> {ok, yes_no_answer(true)};
                no_solution -> yes_no_member(Pid, SName, SArity, OName, OArityText);
                {error, Reason} -> {error, {query_failed, Reason}}
            end;
        {error, Reason} ->
            {error, {query_failed, Reason}}
    end.

enumerate_callers(Pid, {'/', OName, OArity}) ->
    OArityText = arity_text(OArity),
    Goal = "findall(C-A, calls(C, A, local(" ++ quoted_atom_name(OName)
        ++ ", " ++ OArityText ++ "), _, _), L1), "
        ++ "findall(C-A, calls(C, A, remote(_, " ++ quoted_atom_name(OName)
        ++ ", " ++ OArityText ++ "), _, _), L2)" ++ member_findall_tail(OName, OArityText),
    case prolog_session:query(Pid, Goal) of
        {ok, Bindings} ->
            L1 = proplists:get_value('L1', Bindings),
            L2 = proplists:get_value('L2', Bindings),
            L3 = proplists:get_value('L3', Bindings, []),
            L4 = proplists:get_value('L4', Bindings, []),
            Callers = lists:usort(
                [render_ident(I) || I <- L1 ++ L2 ++ L3 ++ L4]),
            {ok, #{<<"type">> => <<"enumerate">>, <<"answer">> => Callers}};
        no_solution ->
            {error, {findall_never_fails, callers_of}};
        {error, Reason} ->
            {error, {query_failed, Reason}}
    end.

%% Method calls (`supabase.auth.verifyOtp(...)`) are stored as
%% calls(..., member(Receiver, Method, Arity), ...). A dotted object
%% name splits at the last dot into receiver.method — matching how the
%% extractor records chained receivers (`this.baz` → receiver
%% `this.baz`). Without this third probe the question would prove
%% nothing and answer a confident false about a call the fact base
%% does hold — the exact silent-wrong failure this pipeline exists to
%% prevent.
yes_no_member(Pid, SName, SArity, OName, OArityText) ->
    case split_receiver_method(OName) of
        {Receiver, Method} ->
            Member = "calls(" ++ quoted_atom_name(SName) ++ ", "
                ++ integer_to_list(SArity) ++ ", member("
                ++ quoted_atom_name(Receiver) ++ ", "
                ++ quoted_atom_name(Method) ++ ", " ++ OArityText
                ++ "), _, _)",
            case prolog_session:query(Pid, Member) of
                {ok, _} -> {ok, yes_no_answer(true)};
                no_solution -> dotted_remote_probe(Pid, SName, SArity,
                                                   Receiver, Method, OArityText);
                {error, Reason} -> {error, {query_failed, Reason}}
            end;
        none ->
            {ok, yes_no_answer(false)}
    end.

%% A dotted name is ambiguous between a method call (obj.method) and an
%% Erlang remote call (module:function) — the fact base decides. Without
%% the remote probe, "does handle_query/1 call maps.get/2?" answers a
%% confident false about a real remote call.
dotted_remote_probe(Pid, SName, SArity, Receiver, Method, OArityText) ->
    Remote = "calls(" ++ quoted_atom_name(SName) ++ ", "
        ++ integer_to_list(SArity) ++ ", remote("
        ++ quoted_atom_name(Receiver) ++ ", "
        ++ quoted_atom_name(Method) ++ ", " ++ OArityText ++ "), _, _)",
    case prolog_session:query(Pid, Remote) of
        {ok, _} -> {ok, yes_no_answer(true)};
        no_solution -> {ok, yes_no_answer(false)};
        {error, Reason} -> {error, {query_failed, Reason}}
    end.

split_receiver_method(Name) when is_atom(Name) ->
    split_receiver_method(atom_to_binary(Name, utf8));
split_receiver_method(Name) when is_binary(Name) ->
    case last_dot(Name, byte_size(Name)) of
        0 -> none;
        Pos ->
            {binary:part(Name, 0, Pos - 1),
             binary:part(Name, Pos, byte_size(Name) - Pos)}
    end.

%% Returns the 1-based position just after the last dot, or 0.
last_dot(Name, 0) -> 0;
last_dot(Name, Pos) when Pos > 0 ->
    case binary:at(Name, Pos - 1) of
        $. -> Pos;
        _ -> last_dot(Name, Pos - 1)
    end.

%% Dotted callee names add a third findall over the member shape so
%% "who calls supabase.auth.verifyOtp/2?" sees method callers too.
member_findall_tail(OName, OArityText) ->
    case split_receiver_method(OName) of
        {Receiver, Method} ->
            ", findall(C-A, calls(C, A, member("
                ++ quoted_atom_name(Receiver) ++ ", "
                ++ quoted_atom_name(Method) ++ ", " ++ OArityText
                ++ "), _, _), L3), "
                ++ "findall(C-A, calls(C, A, remote("
                ++ quoted_atom_name(Receiver) ++ ", "
                ++ quoted_atom_name(Method) ++ ", " ++ OArityText
                ++ "), _, _), L4)";
        none ->
            ""
    end.

%% --- shaping helpers ---

yes_no_answer(Bool) ->
    #{<<"type">> => <<"yes_no">>, <<"answer">> => Bool}.

render_ident({'-', Name, Arity}) when is_atom(Name) ->
    iolist_to_binary([atom_to_list(Name), "/", integer_to_list(Arity)]).

%% `any` (statistical tier, arity not pinned by the question) proves
%% against an unbound Prolog variable — every arity counts.
arity_text(any) -> "_";
arity_text(N) when is_integer(N) -> integer_to_list(N).

%% The DCG hands erlog already-legal atoms (the tokenizer guarantees
%% lowercase-start); the statistical tier hands binaries that may carry
%% capitals or dots, so goal text always quotes. Quoting a legal atom is
%% harmless, so both paths quote.
quoted_atom_name(Name) when is_atom(Name) ->
    quoted_atom(atom_to_binary(Name, utf8));
quoted_atom_name(Name) when is_binary(Name) ->
    quoted_atom(Name).

evidence({'hit', Kind, File, Line, Score}) ->
    #{
        <<"kind">> => atom_to_binary(Kind, utf8),
        <<"file">> => to_bin(File),
        <<"line">> => Line,
        <<"score">> => Score
    }.

span_word(Word) when is_atom(Word) -> atom_to_list(Word);
span_word(Word) when is_binary(Word) -> binary_to_list(Word);
span_word({'/', Name, Arity}) when is_atom(Name) ->
    atom_to_list(Name) ++ "/" ++ integer_to_list(Arity).

to_bin(File) when is_binary(File) -> File;
to_bin(File) when is_list(File) -> unicode:characters_to_binary(File);
to_bin(File) when is_atom(File) -> atom_to_binary(File, utf8).

grammar_file() ->
    filename:join(priv_dir(), ?GRAMMAR_FILE).

%% Same code:priv_dir/1 + {error, bad_name} fallback shape as
%% symbolic_extract.erl's own priv_dir/0.
priv_dir() ->
    case code:priv_dir(symbolic_tools) of
        {error, bad_name} -> "priv";
        Dir -> Dir
    end.

fail(Fmt, Args) ->
    io:put_chars(standard_error, io_lib:format(Fmt ++ "~n", Args)),
    halt(1).
