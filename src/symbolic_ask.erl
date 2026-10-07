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
%% Exported for symbolic_ask_tests.erl — run_result/2 is the halt-free
%% core.
-export([run_result/2]).

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

%% Tokenize, load the fact database, consult the question grammar, and
%% parse — all halt-free. `unrecognized` is its own return value, not an
%% error: the phrasing fell outside the grammar, which is a fact about
%%% the question, not a failure of the machinery.
-spec run_result(file:filename(), string()) ->
    {ok, map()} | unrecognized | {error, term()}.
run_result(DbPath, Question) ->
    case filelib:is_regular(DbPath) of
        false ->
            {error, {no_such_db, DbPath}};
        true ->
            case symbolic_extract:tokenize(Question) of
                {ok, TokensText} ->
                    ask(DbPath, TokensText);
                {error, Reason} ->
                    {error, {tokenize_error, Reason}}
            end
    end.

ask(DbPath, TokensText) ->
    {ok, Pid} = prolog_session:start_link(),
    Result =
        case prolog_session:load_facts(Pid, symbolic_fact_store:read(DbPath)) of
            ok ->
                case prolog_session:consult(Pid, grammar_file()) of
                    ok -> parse(Pid, TokensText);
                    {error, Reason} -> {error, {grammar_error, Reason}}
                end
        end,
    prolog_session:stop(Pid),
    Result.

parse(Pid, TokensText) ->
    Goal = "phrase(question(Type, Rel), " ++ TokensText ++ ")",
    case prolog_session:query(Pid, Goal) of
        {ok, Bindings} ->
            %% Bindings come back in engine order, not goal-text order —
            %% look them up by name, never by position.
            answer(Pid, proplists:get_value('Type', Bindings),
                   proplists:get_value('Rel', Bindings));
        no_solution ->
            unrecognized;
        {error, Reason} ->
            {error, {parse_failed, Reason}}
    end.

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
answer(_Pid, Type, Rel) ->
    {error, {unknown_question_shape, Type, Rel}}.

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
%% the base cannot be expected to define external functions.
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

defines_goal(Name, Arity) when is_atom(Name), is_integer(Arity) ->
    "defines(" ++ atom_to_list(Name) ++ ", " ++ integer_to_list(Arity)
        ++ ", _, _, _)";
defines_goal(Name, ArityText) when is_atom(Name), is_list(ArityText) ->
    "defines(" ++ atom_to_list(Name) ++ ", " ++ ArityText ++ ", _, _, _)".

%% --- proving helpers ---

yes_no_calls(Pid, {'/', SName, SArity}, {'/', OName, OArity}) ->
    Local = "calls(" ++ atom_to_list(SName) ++ ", " ++ integer_to_list(SArity)
        ++ ", local(" ++ atom_to_list(OName) ++ ", " ++ integer_to_list(OArity)
        ++ "), _, _)",
    Remote = "calls(" ++ atom_to_list(SName) ++ ", " ++ integer_to_list(SArity)
        ++ ", remote(_, " ++ atom_to_list(OName) ++ ", " ++ integer_to_list(OArity)
        ++ "), _, _)",
    case prolog_session:query(Pid, Local) of
        {ok, _} -> {ok, yes_no_answer(true)};
        no_solution ->
            case prolog_session:query(Pid, Remote) of
                {ok, _} -> {ok, yes_no_answer(true)};
                no_solution -> {ok, yes_no_answer(false)};
                {error, Reason} -> {error, {query_failed, Reason}}
            end;
        {error, Reason} ->
            {error, {query_failed, Reason}}
    end.

enumerate_callers(Pid, {'/', OName, OArity}) ->
    Goal = "findall(C-A, calls(C, A, local(" ++ atom_to_list(OName)
        ++ ", " ++ integer_to_list(OArity) ++ "), _, _), L1), "
        ++ "findall(C-A, calls(C, A, remote(_, " ++ atom_to_list(OName)
        ++ ", " ++ integer_to_list(OArity) ++ "), _, _), L2)",
    case prolog_session:query(Pid, Goal) of
        {ok, Bindings} ->
            L1 = proplists:get_value('L1', Bindings),
            L2 = proplists:get_value('L2', Bindings),
            Callers = lists:usort(
                [render_ident(I) || I <- L1 ++ L2]),
            {ok, #{<<"type">> => <<"enumerate">>, <<"answer">> => Callers}};
        no_solution ->
            {error, {findall_never_fails, callers_of}};
        {error, Reason} ->
            {error, {query_failed, Reason}}
    end.

%% --- shaping helpers ---

yes_no_answer(Bool) ->
    #{<<"type">> => <<"yes_no">>, <<"answer">> => Bool}.

render_ident({'-', Name, Arity}) when is_atom(Name) ->
    iolist_to_binary([atom_to_list(Name), "/", integer_to_list(Arity)]).

evidence({'hit', Kind, File, Line, Score}) ->
    #{
        <<"kind">> => atom_to_binary(Kind, utf8),
        <<"file">> => to_bin(File),
        <<"line">> => Line,
        <<"score">> => Score
    }.

span_word(Word) when is_atom(Word) -> atom_to_list(Word);
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
