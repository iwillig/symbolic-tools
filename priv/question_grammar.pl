%% Bounded question grammar
%% ------------------------
%%
%% Turns a short, fixed-shape question into a q(Type, Relation) term
%% for `symbolic ask` (src/symbolic_ask.erl) to gate, prove, and shape
%% into an answer. The statement grammar (priv/nlp_grammar.pl) is
%% untouched — questions and claims are different pipelines (see
%% docs/research-questions-to-prolog.md §6).
%%
%% Loaded via `consult`, never `assertz`, for the same DCG-translation
%% reason priv/nlp_grammar.pl documents: `-->` becomes a difference-list
%% clause at consult time only (docs/curt-approach.md §5).
%%
%% Deliberately narrow — v1 covers three relations (calls, defines,
%% discussed) in five phrasings, mirroring the fact predicates the gate
%% knows (calls/5, defines/5) and the prose surface (text_search/2):
%%
%%   does foo/2 call bar/1?          → q(yes_no, calls(foo/2, bar/1))
%%   which functions call bar/1?     → q(enumerate, callers_of(bar/1))
%%   who calls bar/1?                → q(enumerate, callers_of(bar/1))
%%   how many functions call bar/1?  → q(count, callers_of(bar/1))
%%   does foo/2 exist?               → q(yes_no, defines(foo/2))
%%   is foo/2 defined?              → q(yes_no, defines(foo/2))
%%   where is dirty scheduler documented? → q(prose, [dirty, scheduler])
%%   where is ... discussed?         → q(prose, [...])
%%
%% A question outside these shapes fails to parse and comes back
%% `unrecognized`, loudly — exactly like priv/nlp_grammar.pl's stance
%% for statements. `ident/1` requires a Name/Arity term (the shape
%% defines/5's own values take); the prose span is a plain word list
%% between "is" and "documented"/"discussed".

question(yes_no, calls(Subject, Object)) -->
    [does], ident(Subject), [call], ident(Object).

question(yes_no, defines(Ident)) -->
    [does], ident(Ident), [exist].
question(yes_no, defines(Ident)) -->
    [is], ident(Ident), [defined].

question(enumerate, callers_of(Object)) -->
    [which], [functions], [call], ident(Object).
question(enumerate, callers_of(Object)) -->
    [who], [calls], ident(Object).

question(count, callers_of(Object)) -->
    [how], [many], [functions], [call], ident(Object).

question(prose, Span) -->
    [where], [is], span(Span), [documented].
question(prose, Span) -->
    [where], [is], span(Span), [discussed].

%% A Name/Arity term, never a bare word — same contract as
%% priv/nlp_grammar.pl's ident/1.
ident(Ident) --> [Ident], { compound(Ident) }.

%% Greedy word span, shrunk by backtracking until the trailing terminal
%% matches and the whole token list is consumed — `phrase(question(Q),
%% Tokens)` returns the first full-consumption split.
span([Word | Words]) --> [Word], span(Words).
span([]) --> [].
