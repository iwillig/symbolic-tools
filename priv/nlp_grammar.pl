%% Bounded subject-verb-object grammar
%% ------------------------------------
%%
%% Turns a short, fixed-vocabulary sentence into an svo(Subject, Verb,
%% Object) term shaped to compose directly with this project's own fact
%% predicates (calls/5, defines/5, ...) — see docs/reviewing-llm-output.md
%% SS3.1/3.2. Loaded via `consult` (symbolic_extract.erl), never
%% `assertz`: DCG translation (`-->` into a real difference-list clause)
%% happens at consult time in erlog, not at assertz time — confirmed
%% directly earlier this project's own session (docs/curt-approach.md
%% SS5) — so an assertz of a DCG rule would silently register nothing
%% usable.
%%
%% Deliberately narrow: covers exactly the two claim shapes
%% check_claim/1's own sketch (docs/reviewing-llm-output.md SS3.2) already
%% knows how to check against real facts — `calls` and `removed` — not a
%% general-purpose sentence grammar. A sentence outside this bounded
%% vocabulary simply fails to parse (phrase/2 has no solution), which
%% symbolic_extract:run_result/1 reports as `unrecognized`, not something
%% silently guessed at.

sentence(svo(Subject, calls, Object)) -->
    ident(Subject), [calls], ident(Object).

sentence(svo(Subject, removed, none)) -->
    ident(Subject), [was], [removed].

sentence(svo(Subject, removed, none)) -->
    ident(Subject), [no], [longer], [exists].

%% A subject/object must already be a Function/Arity term (`foo/2`), not
%% a bare word — the same shape defines/5's own Function values take.
%% symbolic_extract:tokenize/1 only ever emits a bare lowercase atom or a
%% Name/Arity term, never anything else, so this mainly guards against a
%% mis-shapen token reaching here some other way.
ident(Ident) --> [Ident], { compound(Ident) }.
