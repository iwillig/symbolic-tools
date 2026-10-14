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
-export([run_result/2, ask/2, ask/3, ask_detailed/3, ambiguity_answer/1,
         map_tags/1, ident_candidates/1]).

-define(GRAMMAR_FILE, "question_grammar.pl").
-define(CALLER_EVIDENCE_LIMIT, 50).

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
        {error, {ambiguous, Candidates}} ->
            io:format("~ts~n", [jsx:encode(ambiguity_answer(Candidates))]),
            halt(2);
        {error, {unverifiable, Reason}} ->
            io:format("~ts~n", [
                jsx:encode(#{
                    <<"type">> => <<"unverifiable">>,
                    <<"reason">> => iolist_to_binary(io_lib:format("~p", [Reason]))
                })
            ]),
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
            Facts = symbolic_fact_store:read(DbPath),
            Metadata = case symbolic_fact_store:read_metadata(DbPath) of
                {ok, ParsedMetadata} -> ParsedMetadata;
                _ -> #{<<"metadata_available">> => false,
                       <<"complete">> => false, <<"scan_paths">> => [],
                       <<"files">> => 0, <<"failed_files">> => []}
            end,
            ask(Facts, Question, Metadata)
    end.

%% The shared pipeline core: tokenize, load a one-shot session from a
%% raw fact list, consult the question grammar, gate, prove, shape. The
%% CLI path (run_result/2, facts from DETS) and the MCP ask tool (facts
%% from the codebase cache) both land here — one pipeline, two sources.
-spec ask([tuple()], string()) ->
    {ok, map()} | unrecognized | {error, term()}.
ask(Facts, Question) ->
    ask(Facts, Question, #{<<"complete">> => false,
        <<"scan_paths">> => [], <<"files">> => 0, <<"failed_files">> => []}).

-spec ask([tuple()], string(), map()) ->
    {ok, map()} | unrecognized | {error, term()}.
%% Benchmark seam: preserves the public answer and additionally returns the
%% catalog operation selected by the interpreter. It is for regression
%% measurement, not part of CLI/MCP answer payloads.
-spec ask_detailed([tuple()], string(), map()) ->
    {{ok, map()} | unrecognized | {error, term()}, map() | undefined}.
ask_detailed(Facts, Question, Metadata) ->
    erase({?MODULE, operation_trace}),
    try
        Result = ask(Facts, Question, Metadata),
        {Result, get({?MODULE, operation_trace})}
    after
        erase({?MODULE, operation_trace})
    end.

ask(Facts, Question, Metadata) ->
    erase({?MODULE, operation_trace}),
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
    scope_answer(Result, Metadata).

scope_answer({ok, #{<<"type">> := <<"unknown">>} = Answer}, Metadata) ->
    {ok, Answer#{<<"scope">> => scope_from_metadata(Metadata)}};
scope_answer({ok, Answer}, Metadata) ->
    case metadata_complete(Metadata) of
        true ->
            HasScope = maps:is_key(<<"scan_paths">>, Metadata) orelse
                maps:is_key(scan_paths, Metadata),
            case HasScope andalso scope_dependent_answer(Answer) of
                true -> {ok, Answer#{<<"scope">> => scope_from_metadata(Metadata)}};
                false -> {ok, Answer}
            end;
        false ->
            case scope_dependent_answer(Answer) of
                true -> {ok, #{<<"type">> => <<"unknown">>,
                    <<"reason">> => <<"The scan is incomplete; absence is not reliable.">>,
                    <<"scope">> => scope_from_metadata(Metadata)}};
                false -> {ok, Answer}
            end
    end;
scope_answer(Result, _Metadata) -> Result.

metadata_complete(#{<<"complete">> := Complete}) -> Complete =:= true;
metadata_complete(#{scan_complete := Complete}) -> Complete =:= true;
metadata_complete(_) -> false.

scope_dependent_answer(#{<<"type">> := <<"yes_no">>, <<"answer">> := false}) -> true;
scope_dependent_answer(#{<<"type">> := <<"enumerate">>}) -> true;
scope_dependent_answer(#{<<"type">> := <<"count">>}) -> true;
scope_dependent_answer(#{<<"type">> := <<"sites">>}) -> true;
scope_dependent_answer(_) -> false.

scope_from_metadata(Metadata) ->
    ScopePaths = maps:get(<<"scan_paths">>, Metadata,
        maps:get(scan_paths, Metadata, [])),
    FailedFiles = maps:get(<<"failed_files">>, Metadata,
        maps:get(failed_files, Metadata, [])),
    Files = maps:get(<<"files">>, Metadata,
        maps:get(files, Metadata, 0)),
    Complete = metadata_complete(Metadata),
    MetadataAvailable = maps:get(<<"metadata_available">>, Metadata,
        maps:get(scan_metadata_available, Metadata,
            maps:is_key(<<"complete">>, Metadata) orelse maps:is_key(scan_complete, Metadata))),
    #{<<"scan_paths">> => [to_bin(Path) || Path <- ScopePaths],
      <<"files">> => Files,
      <<"complete">> => Complete,
      <<"metadata_available">> => MetadataAvailable,
      <<"failed_files">> => [to_bin(File) || File <- FailedFiles]}.

parse(Pid, TokensText, Question) ->
    Goal = "phrase(question(Type, Rel), " ++ TokensText ++ ")",
    case prolog_session:query(Pid, Goal) of
        {ok, Bindings} ->
            %% Bindings come back in engine order, not goal-text order —
            %% look them up by name, never by position.
            answer(
                Pid,
                proplists:get_value('Type', Bindings),
                proplists:get_value('Rel', Bindings)
            );
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

record_operation({Type, Relation}) ->
    case symbolic_ask_catalog:lookup(Type, Relation) of
        {ok, Operation} ->
            put({?MODULE, operation_trace}, #{
                <<"operation">> => atom_to_binary(maps:get(id, Operation)),
                <<"answer_type">> => atom_to_binary(Type)});
        error -> erase({?MODULE, operation_trace})
    end;
record_operation(_) -> erase({?MODULE, operation_trace}).

statistical_fallback(Pid, Question) ->
    try symbolic_nlp:tag(unicode:characters_to_binary(Question)) of
        {ok, Tags} ->
            case map_tags(Tags) of
                unrecognized ->
                    unrecognized;
                {ok, {prose, SpanWords}} ->
                    %% Same prose clause the DCG uses — evidence, never a
                    %% verdict. Glue tokens never make search sense.
                    Words = [
                        W
                     || {W, _} <- SpanWords,
                        W =/= <<"_">>,
                        W =/= <<".">>
                    ],
                    case Words of
                        [] -> unrecognized;
                        _ -> answer(Pid, prose, Words)
                    end;
                {ok, Template} ->
                    record_operation(Template),
                    build_relation(Pid, Template)
            end;
        {error, _} ->
            unrecognized
    catch
        %% NIF not built/loaded: tier absent
        _:_ -> unrecognized
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
        [{<<"where">>, _}, {<<"is">>, _} | Rest] -> where_shape(Rest);
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
    GlueNext =
        case Rest of
            [{NW, _} | _] -> NW =:= <<"_">> orelse NW =:= <<".">>;
            _ -> false
        end,
    case verb_relation(W) =/= other andalso not GlueNext of
        true -> {W, lists:reverse(Acc), Rest};
        false -> find_verb(Rest, [T | Acc])
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
    Ws = [
        W
     || {W, _} <- Tags,
        not lists:member(W, [
            <<"the">>,
            <<"a">>,
            <<"an">>,
            <<"this">>,
            <<"that">>,
            <<"these">>,
            <<"those">>,
            <<"my">>,
            <<"our">>,
            <<"their">>,
            <<"its">>
        ])
    ],
    case [S || S <- segments(Ws, none, <<>>, []), S =/= <<>>] of
        [] ->
            [];
        [Only] ->
            [Only];
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
is_digits(_) ->
    false.

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
digits_run_from_end(_B, 0) ->
    0.

quoted_atom(Name) ->
    %% Always quote: code identifiers carry capitals and dots that bare
    %% atom syntax cannot hold, and a quoted atom can never become a
    %% Prolog variable.
    Escaped = binary:replace(
        binary:replace(Name, <<"\\">>, <<"\\\\">>, [global]),
        <<"'">>,
        <<"\\'">>,
        [global]
    ),
    ["'", binary_to_list(Escaped), "'"].

arities_of(Pid, Name) ->
    Goal = "findall(A, defines(" ++ quoted_atom(Name) ++ ", A, _, _, _), L)",
    case prolog_session:query(Pid, Goal) of
        {ok, Bindings} -> {ok, proplists:get_value('L', Bindings)};
        %% findall never fails; defensive
        no_solution -> {ok, []};
        {error, Reason} -> {error, Reason}
    end.

%% Resolve every plausible identifier against the fact base before
%% proving. Selecting the first defined candidate would silently answer
%% a different question when a phrase contains multiple code identifiers.
resolve_candidates(Pid, Candidates, Mode) ->
    Entities = defined_entities(Pid, Candidates),
    Matching = [Entity || Entity = {Name, Arity, _File, _Line} <- Entities,
        candidate_allows_arity(Name, Arity, Candidates)],
    case Matching of
        [{Name, Arity, _File, _Line}] -> {ok, {'/', Name, Arity}};
        [_First, _Second | _] -> {error, {ambiguous, candidate_json(Matching)}};
        [] when Entities =/= [] ->
            case Entities of
                [{Name, _Arity, _File, _Line}] ->
                    {Given, _} = lists:keyfind(Name, 1, Candidates),
                    {error, {unverifiable, {wrong_arity, Name, Given}}};
                _ -> {error, {ambiguous, candidate_json(Entities)}}
            end;
        [] when Mode =:= strict -> resolve_strict(Pid, Candidates, Candidates);
        [] -> resolve_loose(Pid, Candidates, Candidates)
    end.

defined_entities(Pid, Candidates) ->
    Rows = lists:append([definition_rows(Pid, Name) || {Name, _} <- Candidates]),
    unique_definition_identities(lists:usort(Rows), []).

definition_rows(Pid, Name) ->
    Goal = "findall(st(A, F, Line), defines(" ++ quoted_atom(Name) ++
        ", A, _, F, Line), L)",
    source_fact_entries(Pid, Goal, fun({'st', Arity, File, Line}) ->
        {Name, Arity, to_bin(File), Line}
    end).

unique_definition_identities([], Acc) -> lists:reverse(Acc);
unique_definition_identities([{Name, Arity, File, Line} | Rest], Acc) ->
    %% The current fact schema's function identity is exactly name/arity;
    %% multiple source locations for that identity are sites, not separate
    %% overload candidates.
    case lists:any(fun({N, A, _F, _}) -> N =:= Name andalso A =:= Arity end, Acc) of
        true -> unique_definition_identities(Rest, Acc);
        false -> unique_definition_identities(Rest, [{Name, Arity, File, Line} | Acc])
    end.

candidate_allows_arity(Name, Arity, Candidates) ->
    lists:any(fun
        ({CandidateName, undefined}) -> CandidateName =:= Name;
        ({CandidateName, Given}) -> CandidateName =:= Name andalso Given =:= Arity
    end, Candidates).

candidate_json(Entities) ->
    [#{<<"name">> => Name, <<"arity">> => Arity,
       <<"file">> => File, <<"line">> => Line}
     || {Name, Arity, File, Line} <- Entities].

ambiguity_answer(Candidates) ->
    #{<<"type">> => <<"ambiguous">>,
      <<"reason">> => <<"The name matches multiple functions. Choose one candidate or specify its arity.">>,
      <<"candidates">> => Candidates}.

%% Subject resolution — strict-gate semantics. The unresolved fallback
%% preserves precise no-such-function and wrong-arity errors.
resolve_ident(Pid, Words) ->
    Candidates = [split_arity(C) || C <- ident_candidates(Words)],
    resolve_candidates(Pid, Candidates, strict).

resolve_strict(_Pid, [], []) ->
    {error, {unverifiable, {no_such_function, none, none}}};
resolve_strict(_Pid, [], [{Name, _} | _]) ->
    {error, {unverifiable, {no_such_function, Name, unknown}}};
resolve_strict(Pid, [{Name, Given} | Rest], All) ->
    case arities_of(Pid, Name) of
        {ok, []} ->
            resolve_strict(Pid, Rest, All);
        {ok, [A]} when Given =:= undefined -> {ok, {'/', Name, A}};
        {ok, [A]} when Given =:= A -> {ok, {'/', Name, A}};
        {ok, [_]} ->
            {error, {unverifiable, {wrong_arity, Name, Given}}};
        {ok, Many} when Given =:= undefined ->
            {error, {unverifiable, {ambiguous_arity, Name, Many}}};
        {ok, Many} ->
            case lists:member(Given, Many) of
                true -> {ok, {'/', Name, Given}};
                false -> {error, {unverifiable, {wrong_arity, Name, Given}}}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%% Object resolution — loose-gate semantics. A name unknown to the base
%% entirely (a stdlib or external callee) passes with `any` arity: the
%% proof then binds any arity, which is the honest reading of a question
%% that named no arity.
resolve_object(Pid, Words) ->
    Candidates = [split_arity(C) || C <- ident_candidates(Words)],
    resolve_candidates(Pid, Candidates, loose).

resolve_loose(Pid, [{Name, Given} | Rest], All) ->
    case arities_of(Pid, Name) of
        {ok, []} when Rest =:= [] -> {ok, {'/', Name, any}};
        {ok, []} ->
            resolve_loose(Pid, Rest, All);
        {ok, [A]} when Given =:= undefined; Given =:= A -> {ok, {'/', Name, A}};
        {ok, [_]} ->
            {error, {unverifiable, {wrong_arity, Name, Given}}};
        {ok, Many} when Given =:= undefined ->
            {error, {unverifiable, {ambiguous_arity, Name, Many}}};
        {ok, Many} ->
            case lists:member(Given, Many) of
                true -> {ok, {'/', Name, Given}};
                false -> {error, {unverifiable, {wrong_arity, Name, Given}}}
            end;
        {error, Reason} ->
            {error, Reason}
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
                        Error ->
                            Error
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
                Error ->
                    Error
            end
    end;
build_relation(Pid, {yes_no, {defines, SWords}}) ->
    case resolve_ident(Pid, SWords) of
        {ok, Ident} -> answer(Pid, yes_no, {defines, Ident});
        Error -> Error
    end;
build_relation(Pid, {Type, {callers_of, OWords}}) when
    Type =:= enumerate; Type =:= count
->
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
                Error ->
                    Error
            end;
        {ident, IdentWords} ->
            case resolve_ident(Pid, IdentWords) of
                {ok, Subject} ->
                    answer(Pid, yes_no, {uses, Subject, name_candidates(OWords)});
                Error ->
                    Error
            end
    end;
%% Stage 2b: returns — a valued return statement that references the
%% name (return_stmt ∧ expr_ref join; mention-level, per the plan).
build_relation(Pid, {yes_no, {returns, SWords, OWords}}) ->
    case resolve_ident(Pid, SWords) of
        {ok, Subject} ->
            answer(Pid, yes_no, {returns, Subject, name_candidates(OWords)});
        Error ->
            Error
    end;
%% Stage 2b: handles — a branch-level literal equal to the name.
build_relation(Pid, {yes_no, {handles, SWords, OWords}}) ->
    case resolve_ident(Pid, SWords) of
        {ok, Subject} ->
            answer(Pid, yes_no, {handles, Subject, name_candidates(OWords)});
        Error ->
            Error
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
dedup_consonant(B) ->
    B.

suffix_of(B, [Suf | Rest]) ->
    Size = byte_size(B),
    SufSize = byte_size(Suf),
    case Size > SufSize andalso binary:part(B, Size - SufSize, SufSize) =:= Suf of
        true -> binary:part(B, 0, Size - SufSize);
        false -> suffix_of(B, Rest)
    end;
suffix_of(_, []) ->
    nomatch.

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
answer(Pid, Type, Rel) ->
    case symbolic_ask_catalog:lookup(Type, Rel) of
        {ok, Operation} ->
            put({?MODULE, operation_trace}, #{
                <<"operation">> => atom_to_binary(maps:get(id, Operation)),
                <<"answer_type">> => atom_to_binary(Type)}),
            execute_answer(Pid, Type, Rel);
        error -> {error, {unknown_question_shape, Type, Rel}}
    end.

execute_answer(Pid, yes_no, {calls, Subject, Object}) ->
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
execute_answer(Pid, yes_no, {defines, {'/', Name, any}}) ->
    definition_answer(Pid, Name, "A");
execute_answer(Pid, yes_no, {defines, {'/', Name, Arity}}) ->
    definition_answer(Pid, Name, integer_to_list(Arity));
%% Enumeration: gate the callee, findall both call shapes, merge, dedup,
%% sort — stable output whatever order load_facts' asserta left.
execute_answer(Pid, enumerate, {callers_of, Object}) ->
    case gate(Pid, Object, loose) of
        ok -> enumerate_callers(Pid, Object);
        Unverifiable -> Unverifiable
    end;
%% Count: distinct functions, same merge as enumerate.
execute_answer(Pid, count, {callers_of, Object}) ->
    case gate(Pid, Object, loose) of
        ok ->
            case enumerate_callers(Pid, Object) of
                {ok, #{<<"answer">> := Callers,
                       <<"evidence">> := Evidence,
                       <<"evidence_complete">> := Complete}} ->
                    {ok, #{
                        <<"type">> => <<"count">>,
                        <<"answer">> => length(Callers),
                        <<"evidence">> => Evidence,
                        <<"evidence_complete">> => Complete
                    }};
                Other ->
                    Other
            end;
        Unverifiable ->
            Unverifiable
    end;
%% Prose: evidence, never a verdict (rule 2). No gate — there is nothing
%% to resolve in free text.
execute_answer(Pid, prose, Span) ->
    QueryText = string:join([span_word(Word) || Word <- Span], " "),
    Goal = "text_search(\"" ++ QueryText ++ "\", Hits)",
    case prolog_session:query(Pid, Goal) of
        {ok, [{'Hits', Hits}]} ->
            {ok, #{
                <<"type">> => <<"prose">>,
                <<"evidence">> => [evidence(H) || H <- Hits]
            }};
        no_solution ->
            %% unreachable: text_search binds [] on no hits
            unrecognized;
        {error, Reason} ->
            {error, {query_failed, Reason}}
    end;
%% --- stage 2b answers: uses / returns / handles / sites / scanned / config ---

%% uses — the subject's code mentions the name (expr_ref/6). Each
%% candidate name is tried until one proves; none does → false, which
%% is an answer, not an error.
execute_answer(Pid, yes_no, {uses, Subject, Candidates}) ->
    case expr_ref_evidence(Pid, Subject, Candidates, undefined) of
        {ok, Evidence} -> {ok, yes_no_evidence_from_witness(Evidence)};
        Error -> Error
    end;
%% uses with a file subject — any expr_ref of the name in a file whose
%% basename matches the question's file name.
execute_answer(Pid, yes_no, {uses_file, FileBin, Candidates}) ->
    case file_expr_ref_evidence(Pid, Candidates, FileBin, []) of
        {ok, Evidence} -> {ok, yes_no_evidence_from_witness(Evidence)};
        Error -> Error
    end;
%% returns — a valued return statement in the subject that references
%% the name: the return_stmt ∧ expr_ref join from the plan, mention
%% level by design (checks the claim, not value-flow).
%% returns — a valued return statement whose OWN LINE mentions the
%% name. Line-scoped deliberately: a function-level mention join would
%% answer true for a logger diagnostic that happens to name the field,
%% defeating the very true→false flip the claims check. Multi-line
%% return expressions are the accepted v1 blind spot.
execute_answer(Pid, yes_no, {returns, Subject, Candidates}) ->
    case return_mention_evidence(Pid, Subject, Candidates) of
        {ok, []} -> {ok, yes_no_evidence(false, [])};
        {ok, Evidence} -> {ok, yes_no_evidence(true, Evidence)};
        Error -> Error
    end;
%% handles — a branch-level literal whose value equals the name
%% (case-insensitive), proving "maps/handles X" against literal/7.
execute_answer(Pid, yes_no, {handles, {'/', SName, SArity}, Candidates}) ->
    %% literal/8: Id, Function, Arity, Kind, Value, File, Line, Raw
    %% (the tool description's literal/7 predates the Raw column).
    Goal = "findall(st(K, V, F, L), literal(_, " ++ quoted_atom_name(SName) ++
        ", " ++ integer_to_list(SArity) ++ ", K, V, F, L, _), Literals)",
    case prolog_session:query(Pid, Goal) of
        {ok, Bindings} ->
            Literals = proplists:get_value('Literals', Bindings, []),
            Evidence = lists:sort(fun evidence_before/2,
                [literal_evidence(SName, SArity, K, V, F, L)
                 || {'st', K, V, F, L} <- Literals,
                    literal_matches(V, Candidates)]),
            {ok, yes_no_evidence_from_witness(Evidence)};
        no_solution -> {ok, yes_no_evidence(false, [])};
        {error, Reason} -> {error, {query_failed, Reason}}
    end;
%% sites — WHERE is X called: every call site as {caller, file, line},
%% all three call shapes merged, deduped, sorted by file then line.
execute_answer(Pid, sites, {call_sites_of, {'/', OName, OArity}}) ->
    OArityText = arity_text(OArity),
    Goal =
        "findall(st(C, A, F, L), calls(C, A, local(" ++
            quoted_atom_name(OName) ++ ", " ++ OArityText ++ "), F, L), L1), " ++
            "findall(st(C, A, F, L), calls(C, A, remote(_, " ++
            quoted_atom_name(OName) ++ ", " ++ OArityText ++ "), F, L), L2)" ++
            member_sites_tail(OName, OArityText),
    case prolog_session:query(Pid, Goal) of
        {ok, Bindings} ->
            Sites = lists:usort(
                [
                    site_entry(I)
                 || L <- [
                        proplists:get_value('L1', Bindings, []),
                        proplists:get_value('L2', Bindings, []),
                        proplists:get_value('L3', Bindings, [])
                    ],
                    I <- L
                ]
            ),
            {ok, #{<<"type">> => <<"sites">>, <<"answer">> => Sites}};
        no_solution ->
            {error, {findall_never_fails, call_sites_of}};
        {error, Reason} ->
            {error, {query_failed, Reason}}
    end;
%% sites — WHERE is X defined: its defines/5 sites.
execute_answer(Pid, sites, {def_site_of, {'/', SName, SArity}}) ->
    Goal =
        "findall(st(" ++ quoted_atom_name(SName) ++ ", " ++
            integer_to_list(SArity) ++ ", F, L), defines(" ++
            quoted_atom_name(SName) ++ ", " ++ integer_to_list(SArity) ++
            ", _, F, L), L1)",
    case prolog_session:query(Pid, Goal) of
        {ok, Bindings} ->
            Sites = lists:usort(
                [
                    definition_site_entry(I)
                 || I <- proplists:get_value('L1', Bindings, [])
                ]
            ),
            {ok, #{<<"type">> => <<"sites">>, <<"answer">> => Sites}};
        no_solution ->
            {error, {findall_never_fails, def_site_of}};
        {error, Reason} ->
            {error, {query_failed, Reason}}
    end;
%% calls with a file subject — preserve the basename match semantics,
%% and return one matching calls fact when the answer is positive.
execute_answer(Pid, yes_no, {calls_file, FileBin, Object}) ->
    case call_evidence_in_file(Pid, Object, FileBin) of
        {ok, []} -> {ok, yes_no_evidence(false, [])};
        {ok, [Witness | _]} -> {ok, yes_no_evidence(true, [Witness])};
        Error -> Error
    end;
%% is file F scanned? — the gate IS the proof: the basename appears in
%% any fact's File field (defines, comments, paragraphs, config).
execute_answer(Pid, yes_no, {file_scanned, FileWords}) ->
    case file_scanned_evidence(Pid, file_segment(FileWords)) of
        {ok, Evidence} -> {ok, yes_no_evidence_from_witness(Evidence)};
        Error -> Error
    end;
%% is config K defined? — exact dotted key against config_value/4.
execute_answer(Pid, yes_no, {config_defined, KeyWords}) ->
    Key = file_segment(KeyWords),
    Goal = "findall(st(F, V, L), config_value(F, " ++ quoted_atom_name(Key) ++
        ", V, L), ConfigFacts)",
    case prolog_session:query(Pid, Goal) of
        {ok, Bindings} ->
            Evidence = lists:sort(fun evidence_before/2,
                [source_evidence(<<"config_value">>, File, Line,
                    #{<<"key">> => to_bin(Key), <<"value">> => to_bin(Value)})
                 || {'st', File, Value, Line} <-
                    proplists:get_value('ConfigFacts', Bindings, [])]),
            {ok, yes_no_evidence_from_witness(Evidence)};
        no_solution -> {ok, yes_no_evidence(false, [])};
        {error, Reason} -> {error, {query_failed, Reason}}
    end;
execute_answer(_Pid, Type, Rel) ->
    {error, {unknown_question_shape, Type, Rel}}.

%% Helpers for the stage 2b answers — kept below the catch-all so the
%% answer/3 clause group stays unbroken.
member_sites_tail(OName, OArityText) ->
    case split_receiver_method(OName) of
        {Receiver, Method} ->
            ", findall(st(C, A, F, L), calls(C, A, member(" ++
                quoted_atom_name(Receiver) ++ ", " ++
                quoted_atom_name(Method) ++ ", " ++ OArityText ++
                "), F, L), L3)";
        none ->
            ""
    end.

site_entry({'st', Caller, CallerArity, File, Line}) ->
    #{
        <<"caller">> => render_ident({'-', Caller, CallerArity}),
        <<"file">> => to_bin(File),
        <<"line">> => Line
    };
site_entry(_Other) ->
    #{}.

definition_site_entry({'st', Function, Arity, File, Line}) ->
    #{
        <<"function">> => render_ident({'-', Function, Arity}),
        <<"file">> => to_bin(File),
        <<"line">> => Line
    };
definition_site_entry(_Other) ->
    #{}.

file_scanned_check(Pid, FileWords) ->
    case file_scanned_evidence(Pid, file_segment(FileWords)) of
        {ok, []} -> {ok, false};
        {ok, _Evidence} -> {ok, true};
        Error -> Error
    end.

file_scanned_evidence(Pid, Base) ->
    Defines = source_fact_entries(Pid,
        "findall(st(N, A, F, Line), defines(N, A, _, F, Line), L)",
        fun({'st', N, A, F, L}) -> source_evidence(<<"defines">>, F, L,
            #{<<"function">> => render_ident({'-', N, A})}) end),
    Comments = source_fact_entries(Pid,
        "findall(st(F, Line, T), comment(F, Line, T), L)",
        fun({'st', F, L, T}) -> source_evidence(<<"comment">>, F, L,
            #{<<"text">> => to_bin(T)}) end),
    Paragraphs = source_fact_entries(Pid,
        "findall(st(F, Line, T), paragraph(F, Line, T), L)",
        fun({'st', F, L, T}) -> source_evidence(<<"paragraph">>, F, L,
            #{<<"text">> => to_bin(T)}) end),
    Config = source_fact_entries(Pid,
        "findall(st(F, K, V, Line), config_value(F, K, V, Line), L)",
        fun({'st', F, K, V, L}) -> source_evidence(<<"config_value">>, F, L,
            #{<<"key">> => to_bin(K), <<"value">> => to_bin(V)}) end),
    Matches = [Entry || Entry <- Defines ++ Comments ++ Paragraphs ++ Config,
        file_matches(maps:get(<<"file">>, Entry), Base)],
    {ok, lists:sort(fun evidence_before/2, Matches)}.

source_fact_entries(Pid, Goal, Convert) ->
    case prolog_session:query(Pid, Goal) of
        {ok, Bindings} -> [Convert(Fact) || Fact <- proplists:get_value('L', Bindings, [])];
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
flatten_value(_) ->
    nomatch.

literal_matches(Value, Candidates) ->
    case flatten_value(Value) of
        nomatch -> false;
        Flat -> lists:member(string:lowercase(Flat),
            [string:lowercase(binary_to_list(to_bin(C))) || C <- Candidates])
    end.

literal_evidence(Name, Arity, Kind, Value, File, Line) ->
    #{<<"predicate">> => <<"literal">>, <<"file">> => to_bin(File),
      <<"line">> => Line,
      <<"fact">> => #{<<"function">> => render_ident({'-', Name, Arity}),
          <<"kind">> => to_bin(Kind), <<"value">> => to_bin(Value)}}.

return_mention_evidence(Pid, {'/', Name, Arity}, Candidates) ->
    NameText = quoted_atom_name(Name),
    ArityText = integer_to_list(Arity),
    ReturnGoal = "findall(st(F, Line), return_stmt(" ++ NameText ++ ", " ++
        ArityText ++ ", true, F, Line), ReturnFacts)",
    RefGoal = "findall(st(Identifier, F, Line), expr_ref(_, " ++ NameText ++
        ", " ++ ArityText ++ ", Identifier, F, Line), RefFacts)",
    KeyGoal = "findall(st(Key, F, Line), object_key(" ++ NameText ++ ", " ++
        ArityText ++ ", Key, F, Line), KeyFacts)",
    case query_fact_list(Pid, ReturnGoal, 'ReturnFacts') of
        {ok, ReturnFacts} ->
            case query_fact_list(Pid, RefGoal, 'RefFacts') of
                {ok, RefFacts} ->
                    case query_fact_list(Pid, KeyGoal, 'KeyFacts') of
                        {ok, KeyFacts} ->
                            {ok, return_witness_pair(Name, Arity, Candidates,
                                ReturnFacts, RefFacts, KeyFacts)};
                        Error -> Error
                    end;
                Error -> Error
            end;
        Error -> Error
    end.

query_fact_list(Pid, Goal, Binding) ->
    case prolog_session:query(Pid, Goal) of
        {ok, Bindings} -> {ok, proplists:get_value(Binding, Bindings, [])};
        no_solution -> {ok, []};
        {error, {existence_error, procedure, _}} -> {ok, []};
        {error, Reason} -> {error, Reason}
    end.

return_witness_pair(Name, Arity, Candidates, ReturnFacts, RefFacts, KeyFacts) ->
    CandidateSet = [to_bin(Candidate) || Candidate <- Candidates],
    MentionFacts =
        [{<<"expr_ref">>, Identifier, File, Line}
         || {'st', Identifier, File, Line} <- RefFacts,
            lists:member(to_bin(Identifier), CandidateSet)] ++
        [{<<"object_key">>, Key, File, Line}
         || {'st', Key, File, Line} <- KeyFacts,
            lists:member(to_bin(Key), CandidateSet)],
    Pairs = [[return_stmt_evidence(Name, Arity, ReturnFile, ReturnLine),
              return_mention_fact(Name, Arity, Predicate, NameOrKey, File, Line)]
        || {'st', ReturnFile, ReturnLine} <- ReturnFacts,
           {Predicate, NameOrKey, File, Line} <- MentionFacts,
           ReturnLine =:= Line],
    case lists:sort([lists:sort(fun evidence_before/2, Pair) || Pair <- Pairs]) of
        [] -> [];
        [WitnessPair | _] -> WitnessPair
    end.

return_stmt_evidence(Name, Arity, File, Line) ->
    source_evidence(<<"return_stmt">>, File, Line,
        #{<<"function">> => render_ident({'-', Name, Arity}),
          <<"has_value">> => true}).

return_mention_fact(Name, Arity, <<"expr_ref">>, Identifier, File, Line) ->
    source_evidence(<<"expr_ref">>, File, Line,
        #{<<"function">> => render_ident({'-', Name, Arity}),
          <<"identifier">> => to_bin(Identifier)});
return_mention_fact(Name, Arity, <<"object_key">>, Key, File, Line) ->
    source_evidence(<<"object_key">>, File, Line,
        #{<<"function">> => render_ident({'-', Name, Arity}),
          <<"key">> => to_bin(Key)}).

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
        no_solution ->
            ok;
        {error, Reason} ->
            {error, {query_failed, Reason}}
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
    "defines(" ++ quoted_atom_name(Name) ++ ", " ++ integer_to_list(Arity) ++
        ", _, _, _)";
defines_goal(Name, ArityText) when is_list(ArityText) ->
    "defines(" ++ quoted_atom_name(Name) ++ ", " ++ ArityText ++ ", _, _, _)".

%% --- proving helpers ---

yes_no_calls(Pid, Caller, Callee) ->
    case all_call_evidence(Pid, Caller, Callee) of
        {ok, []} -> {ok, call_answer(false, [])};
        {ok, [Witness | _]} -> {ok, call_answer(true, [Witness])};
        Error -> Error
    end.

all_call_evidence(Pid, {'/', SName, SArity}, {'/', OName, OArity}) ->
    OArityText = call_arity(OArity),
    CallerText = quoted_atom_name(SName) ++ ", " ++ caller_arity_text(SArity),
    LocalGoal = "findall(st(local, " ++ OArityText ++ ", F, L), calls(" ++ CallerText ++
        ", local(" ++ quoted_atom_name(OName) ++ ", " ++ OArityText ++
        "), F, L), L1)",
    RemoteGoal = ", findall(st(remote, M, " ++ OArityText ++ ", F, L), calls(" ++ CallerText ++
        ", remote(M, " ++ quoted_atom_name(OName) ++ ", " ++ OArityText ++
        "), F, L), L2)",
    {MemberGoal, RemoteDottedGoal} = call_shape_goals(
        CallerText, OName, OArityText),
    Goal = LocalGoal ++ RemoteGoal ++ MemberGoal ++ RemoteDottedGoal,
    case prolog_session:query(Pid, Goal) of
        {ok, Bindings} ->
            Local = proplists:get_value('L1', Bindings, []),
            Remote = proplists:get_value('L2', Bindings, []),
            Member = proplists:get_value('L3', Bindings, []),
            RemoteDotted = proplists:get_value('L4', Bindings, []),
            {ok, lists:sort(fun evidence_before/2,
                [call_evidence(Item, SName, SArity, OName, OArity)
                 || Item <- Local ++ Remote ++ Member ++ RemoteDotted])};
        no_solution -> {error, {findall_never_fails, calls}};
        {error, Reason} -> {error, {query_failed, Reason}}
    end.

call_evidence_in_file(Pid, {'/', OName, OArity}, FileBin) ->
    OArityText = call_arity(OArity),
    CalleeName = quoted_atom_name(OName),
    LocalGoal = "findall(st(C, CallerArity, local, " ++ OArityText ++ ", F, L), calls(C, CallerArity, local(" ++
        CalleeName ++ ", " ++ OArityText ++ "), F, L), L1)",
    RemoteGoal = ", findall(st(C, CallerArity, remote, " ++ OArityText ++ ", M, F, L), " ++
        "calls(C, CallerArity, remote(M, " ++ CalleeName ++ ", " ++ OArityText ++
        "), F, L), L2)",
    {MemberGoal, RemoteDottedGoal} = call_file_shape_goals(OName, OArityText),
    Goal = LocalGoal ++ RemoteGoal ++ MemberGoal ++ RemoteDottedGoal,
    case prolog_session:query(Pid, Goal) of
        {ok, Bindings} ->
            Facts = lists:append([
                proplists:get_value(Name, Bindings, [])
                || Name <- ['L1', 'L2', 'L3', 'L4']]),
            Evidence = lists:sort(fun evidence_before/2,
                [file_call_evidence(Fact, OName, OArity)
                 || Fact <- Facts, fact_file_matches(Fact, FileBin)]),
            {ok, Evidence};
        no_solution -> {error, {findall_never_fails, calls}};
        {error, Reason} -> {error, {query_failed, Reason}}
    end.

call_file_shape_goals(OName, OArityText) ->
    case split_receiver_method(OName) of
        {Receiver, Method} ->
            ReceiverText = quoted_atom_name(Receiver),
            MethodText = quoted_atom_name(Method),
            Member = ", findall(st(C, CallerArity, member, " ++ OArityText ++ ", F, L), " ++
                "calls(C, CallerArity, member(" ++ ReceiverText ++ ", " ++ MethodText ++
                ", " ++ OArityText ++ "), F, L), L3)",
            RemoteDotted = ", findall(st(C, CallerArity, remote_dotted, " ++
                OArityText ++ ", M, N, F, L), calls(C, CallerArity, remote(" ++
                ReceiverText ++ ", " ++ MethodText ++ ", " ++ OArityText ++
                "), F, L), L4)",
            {Member, RemoteDotted};
        none -> {"", ""}
    end.

fact_file_matches({'st', _, _, _, _, File, _}, FileBin) -> file_matches(File, FileBin);
fact_file_matches({'st', _, _, _, _, _, File, _}, FileBin) -> file_matches(File, FileBin);
fact_file_matches({'st', _, _, _, _, _, _, File, _}, FileBin) -> file_matches(File, FileBin).

file_call_evidence({'st', Caller, CallerArity, local, CallArity, File, Line}, OName, _OArity) ->
    call_evidence_entry(Caller, CallerArity, File, Line,
        #{<<"kind">> => <<"local">>, <<"name">> => to_bin(OName),
          <<"arity">> => CallArity});
file_call_evidence({'st', Caller, CallerArity, remote, CallArity, Module, File, Line}, OName, _OArity) ->
    call_evidence_entry(Caller, CallerArity, File, Line,
        #{<<"kind">> => <<"remote">>, <<"module">> => to_bin(Module),
          <<"name">> => to_bin(OName), <<"arity">> => CallArity});
file_call_evidence({'st', Caller, CallerArity, member, CallArity, File, Line}, OName, _OArity) ->
    {Receiver, Method} = split_receiver_method(OName),
    call_evidence_entry(Caller, CallerArity, File, Line,
        #{<<"kind">> => <<"member">>, <<"receiver">> => to_bin(Receiver),
          <<"method">> => to_bin(Method), <<"arity">> => CallArity});
file_call_evidence({'st', Caller, CallerArity, remote_dotted, CallArity, Module, Name, File, Line},
        _OName, _OArity) ->
    call_evidence_entry(Caller, CallerArity, File, Line,
        #{<<"kind">> => <<"remote">>, <<"module">> => to_bin(Module),
          <<"name">> => to_bin(Name), <<"arity">> => CallArity}).

call_shape_goals(Caller, OName, OArityText) ->
    case split_receiver_method(OName) of
        {Receiver, Method} ->
            ReceiverText = quoted_atom_name(Receiver),
            MethodText = quoted_atom_name(Method),
            Member = ", findall(st(member, " ++ OArityText ++ ", F, L), calls(" ++ Caller ++
                ", member(" ++ ReceiverText ++ ", " ++ MethodText ++
                ", " ++ OArityText ++ "), F, L), L3)",
            RemoteDotted = ", findall(st(remote_dotted, " ++ ReceiverText ++ ", " ++ MethodText ++
                ", " ++ OArityText ++ ", F, L), calls(" ++ Caller ++
                ", remote(" ++ ReceiverText ++ ", " ++ MethodText ++
                ", " ++ OArityText ++ "), F, L), L4)",
            {Member, RemoteDotted};
        none -> {"", ""}
    end.

call_evidence({'st', local, Arity, File, Line}, SName, SArity, OName, _OArity) ->
    call_evidence_entry(SName, SArity, File, Line,
        #{<<"kind">> => <<"local">>, <<"name">> => to_bin(OName),
          <<"arity">> => Arity});
call_evidence({'st', remote, Module, Arity, File, Line}, SName, SArity, OName, _OArity) ->
    call_evidence_entry(SName, SArity, File, Line,
        #{<<"kind">> => <<"remote">>, <<"module">> => to_bin(Module),
          <<"name">> => to_bin(OName), <<"arity">> => Arity});
call_evidence({'st', member, Arity, File, Line},
        SName, SArity, OName, _OArity) ->
    {Receiver, Method} = split_receiver_method(OName),
    call_evidence_entry(SName, SArity, File, Line,
        #{<<"kind">> => <<"member">>, <<"receiver">> => to_bin(Receiver),
          <<"method">> => to_bin(Method), <<"arity">> => Arity});
call_evidence({'st', remote_dotted, Module, Name, Arity, File, Line},
        SName, SArity, _OName, _OArity) ->
    call_evidence_entry(SName, SArity, File, Line,
        #{<<"kind">> => <<"remote">>, <<"module">> => to_bin(Module),
          <<"name">> => to_bin(Name), <<"arity">> => Arity}).

call_evidence_entry(SName, SArity, File, Line, Call) ->
    #{<<"predicate">> => <<"calls">>,
      <<"file">> => to_bin(File),
      <<"line">> => Line,
      <<"fact">> => #{<<"caller">> => render_ident({'-', SName, SArity}),
          <<"call">> => Call}}.

definition_answer(Pid, Name, ArityText) ->
    Goal = "findall(st(" ++ ArityText ++ ", F, L), defines(" ++
        quoted_atom_name(Name) ++ ", " ++ ArityText ++ ", _, F, L), L1)",
    case prolog_session:query(Pid, Goal) of
        {ok, Bindings} ->
            Entries = [definition_evidence(Name, A, F, L)
                || {'st', A, F, L} <- proplists:get_value('L1', Bindings, [])],
            case lists:sort(fun evidence_before/2, Entries) of
                [] -> {ok, yes_no_evidence(false, [])};
                [Witness | _] -> {ok, yes_no_evidence(true, [Witness])}
            end;
        no_solution -> {error, {findall_never_fails, defines}};
        {error, Reason} -> {error, {query_failed, Reason}}
    end.

definition_evidence(Name, Arity, File, Line) ->
    #{<<"predicate">> => <<"defines">>, <<"file">> => to_bin(File),
      <<"line">> => Line,
      <<"fact">> => #{<<"function">> => render_ident({'-', Name, Arity})}}.

yes_no_evidence(Bool, Evidence) ->
    #{<<"type">> => <<"yes_no">>, <<"answer">> => Bool,
      <<"evidence">> => Evidence}.

evidence_before(A, B) ->
    {maps:get(<<"file">>, A), maps:get(<<"line">>, A), maps:get(<<"fact">>, A)} =<
        {maps:get(<<"file">>, B), maps:get(<<"line">>, B), maps:get(<<"fact">>, B)}.

call_answer(Bool, Evidence) ->
    #{<<"type">> => <<"yes_no">>, <<"answer">> => Bool,
      <<"evidence">> => Evidence}.

yes_no_evidence_from_witness([]) -> yes_no_evidence(false, []);
yes_no_evidence_from_witness([Witness | _]) -> yes_no_evidence(true, [Witness]).

expr_ref_evidence(Pid, Subject = {'/', SName, SArity}, Candidates, FileFilter) ->
    collect_expr_ref_candidates(Pid, Subject, SName, SArity,
        Candidates, FileFilter, []).

collect_expr_ref_candidates(_Pid, _Subject, _Name, _Arity, [], _FileFilter, Acc) ->
    {ok, lists:sort(fun evidence_before/2, Acc)};
collect_expr_ref_candidates(Pid, Subject, Name, Arity, [Candidate | Rest], FileFilter, Acc) ->
    Goal = "findall(st(F, L), expr_ref(_, " ++ quoted_atom_name(Name) ++ ", " ++
        integer_to_list(Arity) ++ ", " ++ quoted_atom_name(Candidate) ++ ", F, L), Hits)",
    case prolog_session:query(Pid, Goal) of
        {ok, Bindings} ->
            Entries = [expr_ref_entry(Subject, Candidate, File, Line)
                || {'st', File, Line} <- proplists:get_value('Hits', Bindings, []),
                   matches_optional_file(File, FileFilter)],
            collect_expr_ref_candidates(Pid, Subject, Name, Arity, Rest,
                FileFilter, Entries ++ Acc);
        no_solution ->
            collect_expr_ref_candidates(Pid, Subject, Name, Arity, Rest,
                FileFilter, Acc);
        {error, Reason} -> {error, Reason}
    end.

expr_ref_entry({'/', Name, Arity}, Candidate, File, Line) ->
    source_evidence(<<"expr_ref">>, File, Line,
        #{<<"function">> => render_ident({'-', Name, Arity}),
          <<"identifier">> => to_bin(Candidate)}).

file_expr_ref_evidence(_Pid, [], _FileFilter, Acc) ->
    {ok, lists:sort(fun evidence_before/2, Acc)};
file_expr_ref_evidence(Pid, [Candidate | Rest], FileFilter, Acc) ->
    Goal = "findall(st(N, A, F, L), expr_ref(_, N, A, " ++
        quoted_atom_name(Candidate) ++ ", F, L), Hits)",
    case prolog_session:query(Pid, Goal) of
        {ok, Bindings} ->
            Entries = [source_evidence(<<"expr_ref">>, File, Line,
                #{<<"function">> => render_ident({'-', Name, Arity}),
                  <<"identifier">> => to_bin(Candidate)})
                || {'st', Name, Arity, File, Line} <-
                    proplists:get_value('Hits', Bindings, []),
                   file_matches(File, FileFilter)],
            file_expr_ref_evidence(Pid, Rest, FileFilter, Entries ++ Acc);
        no_solution -> file_expr_ref_evidence(Pid, Rest, FileFilter, Acc);
        {error, Reason} -> {error, Reason}
    end.

matches_optional_file(_File, undefined) -> true;
matches_optional_file(File, Filter) -> file_matches(File, Filter).

source_evidence(Predicate, File, Line, Fact) ->
    #{<<"predicate">> => Predicate, <<"file">> => to_bin(File),
      <<"line">> => Line, <<"fact">> => Fact}.

enumerate_callers(Pid, {'/', OName, OArity}) ->
    OArityText = arity_text(OArity),
    Goal =
        "findall(C-A, calls(C, A, local(" ++ quoted_atom_name(OName) ++
            ", " ++ OArityText ++ "), _, _), L1), " ++
            "findall(C-A, calls(C, A, remote(_, " ++ quoted_atom_name(OName) ++
            ", " ++ OArityText ++ "), _, _), L2)" ++ member_findall_tail(OName, OArityText),
    case prolog_session:query(Pid, Goal) of
        {ok, Bindings} ->
            L1 = proplists:get_value('L1', Bindings),
            L2 = proplists:get_value('L2', Bindings),
            L3 = proplists:get_value('L3', Bindings, []),
            L4 = proplists:get_value('L4', Bindings, []),
            CallerIdentities = lists:usort(L1 ++ L2 ++ L3 ++ L4),
            case lists:any(fun caller_name_unknown/1, CallerIdentities) of
                true ->
                    {ok, #{<<"type">> => <<"unknown">>,
                        <<"reason">> => <<"A call fact has no caller identity, so the caller list is unknown.">>}};
                false ->
                    Callers = [render_ident(I) || I <- CallerIdentities],
                    case caller_evidence(Pid, Callers, {'/', OName, OArity}) of
                        {ok, Evidence, Complete} ->
                            {ok, #{<<"type">> => <<"enumerate">>,
                                <<"answer">> => Callers,
                                <<"evidence">> => Evidence,
                                <<"evidence_complete">> => Complete}};
                        Error -> Error
                    end
            end;
        no_solution ->
            {error, {findall_never_fails, callers_of}};
        {error, Reason} ->
            {error, {query_failed, Reason}}
    end.

caller_name_unknown({'-', undefined, _Arity}) -> true;
caller_name_unknown(_) -> false.

caller_evidence(Pid, Callers, Object) ->
    Covered = lists:sublist(Callers, ?CALLER_EVIDENCE_LIMIT),
    case caller_evidence_for(Pid, Covered, Object, []) of
        {ok, Evidence} ->
            {ok, Evidence, length(Callers) =< ?CALLER_EVIDENCE_LIMIT};
        Error -> Error
    end.

caller_evidence_for(_Pid, [], _Object, Acc) ->
    {ok, lists:sort(fun evidence_before/2, Acc)};
caller_evidence_for(Pid, [Caller | Rest], Object, Acc) ->
    case split_rendered_ident(Caller) of
        {ok, CallerIdent} ->
            case all_call_evidence(Pid, CallerIdent, Object) of
                {ok, [Witness | _]} ->
                    caller_evidence_for(Pid, Rest, Object, [Witness | Acc]);
                {ok, []} -> {error, {missing_caller_witness, Caller}};
                Error -> Error
            end;
        error -> {error, {invalid_caller_identity, Caller}}
    end.

split_rendered_ident(Ident) when is_binary(Ident) ->
    case binary:split(Ident, <<"/">>) of
        [Name, <<"?">>] -> {ok, {'/', Name, undefined}};
        [Name, ArityBin] ->
            try {ok, {'/', Name, binary_to_integer(ArityBin)}}
            catch error:badarg -> error end;
        _ -> error
    end.

%% Dotted names can denote a member receiver/method or a remote
%% module/function. The evidence query tests both shapes and preserves
%% the actual CallSpec in its witness.
split_receiver_method(Name) when is_atom(Name) ->
    split_receiver_method(atom_to_binary(Name, utf8));
split_receiver_method(Name) when is_binary(Name) ->
    case last_dot(Name, byte_size(Name)) of
        0 -> none;
        Pos -> {binary:part(Name, 0, Pos - 1), binary:part(Name, Pos, byte_size(Name) - Pos)}
    end.

%% Returns the 1-based position just after the last dot, or 0.
last_dot(_Name, 0) ->
    0;
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
            ", findall(C-A, calls(C, A, member(" ++
                quoted_atom_name(Receiver) ++ ", " ++
                quoted_atom_name(Method) ++ ", " ++ OArityText ++
                "), _, _), L3), " ++
                "findall(C-A, calls(C, A, remote(" ++
                quoted_atom_name(Receiver) ++ ", " ++
                quoted_atom_name(Method) ++ ", " ++ OArityText ++
                "), _, _), L4)";
        none ->
            ""
    end.

%% --- shaping helpers ---

render_ident({'-', Name, Arity}) when is_atom(Name), is_integer(Arity) ->
    iolist_to_binary([atom_to_list(Name), "/", integer_to_list(Arity)]);
render_ident({'-', Name, _UnknownArity}) when is_atom(Name) ->
    iolist_to_binary([atom_to_list(Name), "/?"]);
render_ident({'-', Name, Arity}) when is_binary(Name), is_integer(Arity) ->
    iolist_to_binary([Name, "/", integer_to_list(Arity)]);
render_ident({'-', Name, _UnknownArity}) when is_binary(Name) ->
    iolist_to_binary([Name, "/?"]).

%% `any` (statistical tier, arity not pinned by the question) proves
%% against an unbound Prolog variable — every arity counts.
arity_text(any) -> "_";
arity_text(N) when is_integer(N) -> integer_to_list(N).

call_arity(any) -> "A";
call_arity(N) when is_integer(N) -> integer_to_list(N).

caller_arity_text(N) when is_integer(N) -> integer_to_list(N);
caller_arity_text(_UnknownArity) -> "undefined".

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
