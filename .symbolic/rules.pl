%% Default rule library for this project — the reusable half of the
%% query vocabulary, on top of the raw facts `symbolic parse` writes.
%%
%% `symbolic query` auto-consults this file when no `-rules` is given, so
%% the goals below work with no extra flag:
%%   symbolic query -db .pi/facts.dets 'self_recursive(F, A, Fl)'
%% Discovery walks up from the fact database's directory, then from the
%% current directory, looking for `.symbolic/rules.pl` — the same
%% "find the project root" shape git uses for `.git`. `-rules <path>`
%% overrides discovery entirely; `-no-rules` turns it off.
%%
%% Add a new rule here whenever you'd want to ask the same shape of
%% question again — don't rebuild it as an inline one-off goal.
%% See docs/lint-queries.md and docs/agent-examples.md for the source of
%% most of these, including a known caveat (-spec noise in calls/5) that
%% also applies here. `calls/4` is now `calls/5`:
%% `calls(Caller, CallerArity, CallSpec, File, Line)` — CallerArity is
%% unbound (`_`) in most rules below since they key on bare Fun/Object
%% names by design; only self_recursive/3 binds it, since same-name-and-
%% arity on BOTH sides is exactly what makes a call site genuinely
%% self-recursive.
%%
%% Names, modules and file paths in facts are atoms (integers for
%% arities), so `local(caller_name, 1)` matches and
%% `local("caller_name", 1)` does not.

%% Everything a function calls, deduplicated. Fun here is still
%% bare-name, so this merges call sites from same-named functions of
%% different arity — use self_recursive/3 or a direct calls/5 query when
%% that distinction matters.
callees(Fun, Callees) :-
    findall(C, calls(Fun, _CallerArity, C, _, _), Raw),
    sort(Raw, Callees).

%% Every local caller of a function/arity.
callers(Fun, Arity, Callers) :-
    findall(Caller, calls(Caller, _CallerArity, local(Fun, Arity), _, _), Raw),
    sort(Raw, Callers).

%% A function with no doc comment immediately preceding it.
undocumented(Fun, Arity, File, Line) :-
    defines(Fun, Arity, _Params, File, Line),
    \+ doc(Fun, Arity, _, _, _).

%% A TypeScript-style method call target, e.g. calls_object(charge, stripeClient).
calls_object(Fun, Object) :-
    calls(Fun, _CallerArity, member(Object, _, _), _, _).

%% A Markdown code sample that defines a function the real code no longer
%% (or never actually) has — the doc-drift check.
stale_doc_example(Fun, Arity, DocFile, Line) :-
    example_defines(Fun, Arity, _Params, DocFile, Line),
    \+ defines(Fun, Arity, _, _, _).

%% Same function/arity defined in more than one file.
duplicate_name(Fun, Arity, Files) :-
    defines(Fun, Arity, _, _, _),
    findall(File, defines(Fun, Arity, _, File, _), AllFiles),
    sort(AllFiles, Files),
    length(Files, N),
    N > 1.

all_duplicate_names(Triples) :-
    findall(Fun-Arity-Files, duplicate_name(Fun, Arity, Files), Raw),
    sort(Raw, Triples).

%% A function that calls itself directly by name AND arity — fixed from
%% the old bare-name version, which conflated e.g. query/2 calling
%% query/3 with real recursion. Now fully precise on BOTH sides: binding
%% CallerArity = Arity requires the call site to be textually inside
%% THIS exact clause (not merely inside some same-named overload), and
%% local(Fun, Arity) requires the call target to be this exact arity too.
%% This is what finally closes the query/1-calls-query/2 false positive:
%% that call site's CallerArity is 1 (it's inside query/1's body), so it
%% no longer unifies with query/2's Arity=2 check, and its own target
%% arity (2) doesn't match query/1's own Arity=1 either.
self_recursive(Fun, Arity, File) :-
    defines(Fun, Arity, _, File, _),
    calls(Fun, Arity, local(Fun, Arity), File, _).

%% Fan-out: how many distinct things a function calls.
fan_out(Fun, File, Count) :-
    defines(Fun, _Arity, _Params, File, _),
    findall(Callee, calls(Fun, _CallerArity, Callee, File, _), Callees),
    sort(Callees, Unique),
    length(Unique, Count).

%% Top N by fan-out — rank first (sort ascending, reverse, take/3) so the
%% busiest orchestrators come back first.
top_fan_out(N, Top) :-
    findall(Count-Fun-File, fan_out(Fun, File, Count), Raw),
    sort(Raw, Sorted),
    reverse(Sorted, Ranked),
    take(N, Ranked, Top).

%% Fan-in: how many distinct local callers a function/arity has.
fan_in(Fun, Arity, Count) :-
    defines(Fun, Arity, _, _, _),
    findall(Caller, calls(Caller, _CallerArity, local(Fun, Arity), _, _), Callers),
    sort(Callers, Unique),
    length(Unique, Count).

%% Top N by fan-in — the most relied-upon functions in the codebase.
top_fan_in(N, Top) :-
    findall(Count-Fun-Arity, fan_in(Fun, Arity, Count), Raw),
    sort(Raw, Sorted),
    reverse(Sorted, Ranked),
    take(N, Ranked, Top).

%% Defined but never called locally (by name+arity) within this same
%% parse. Caveat: a real caller in another directory, or a remote/
%% qualified call, won't show up here — see docs/lint-queries.md's
%% "mostly false positives" note before treating a match as dead code.
no_local_callers(Fun, Arity, File) :-
    defines(Fun, Arity, _, File, _),
    \+ calls(_, _, local(Fun, Arity), _, _).

all_no_local_callers(Triples) :-
    findall(Fun-Arity-File, no_local_callers(Fun, Arity, File), Raw),
    sort(Raw, Triples).

%% A comment not immediately followed by a recognized definition —
%% section headers, module-doc headers, inline explanations, etc.
undocumented_comment(File, Line, Text) :-
    comment(File, Line, Text),
    \+ doc(_, _, File, Line, _).

%% Calls into modules worth a second look in review (process control,
%% the filesystem, NIF loading, env vars).
risky_call(Caller, Module, Fun) :-
    calls(Caller, _CallerArity, remote(Module, Fun, _ArgCount), _, _),
    member(Module, [os, erlang, file, init]).

all_risky_calls(Triples) :-
    findall(Caller-Module-Fun, risky_call(Caller, Module, Fun), Raw),
    sort(Raw, Triples).

%% First N elements of a list — for ranking results (sort a Count-Key list,
%% reverse, take/3) into a readable top-N.
take(0, _, []) :- !.
take(_, [], []) :- !.
take(N, [H|T], [H|Rest]) :- N > 0, N1 is N - 1, take(N1, T, Rest).

%% Reachability over the local call graph, guarded against cycles — erlog
%% has no tabling, so an unguarded version of this can hang forever on a
%% cyclic call graph. See docs/erlang-mcp-design.md §5.
reaches(A, B) :- reaches(A, B, []).

%% Any arity of A/B/M reaches — deliberately arity-blind on both ends,
%% unlike self_recursive/3 above: reachability asks "can A's call chain
%% ever get to B at all," not "to this exact overload, from this exact
%% overload."
reaches(A, B, _) :- calls(A, _CallerArity, local(B, _), _, _).
reaches(A, B, Visited) :-
    calls(A, _CallerArity, local(M, _), _, _),
    \+ member(M, Visited),
    reaches(M, B, [M|Visited]).

%% Component-level (C4 L3) dependency edges: which file (component)
%% calls into which named module (component). Deliberately only
%% remote(...) calls — local(...) is same-file, intra-component detail
%% (C4 Code/L4), not a component boundary. See docs/lint-queries.md's
%% "Module dependency graph" section for the internal-vs-stdlib/library
%% filtering this needs on top, and a real gap: a dependency reached
%% only through a `fun Mod:Fun/Arity` reference (not a direct
%% `Mod:Fun(Args)` call) is invisible here — ts_extract_markdown's real
%% calls into ts_extract_erlang/typescript/bash are exactly this case.
module_dependency(CallerFile, CalleeModule) :-
    calls(_, _, remote(CalleeModule, _, _), CallerFile, _).

all_module_dependencies(Edges) :-
    findall(CallerFile-CalleeModule, module_dependency(CallerFile, CalleeModule), Raw),
    sort(Raw, Edges).

%% --- ESLint-style structural checks, on top of the library above ---

%% More parameters than a human can comfortably track at a call site.
%% Arity already *is* the parameter count (the same field self_recursive/3
%% and duplicate_name/3 key on), so this needs no new fact — just a
%% threshold, matching ESLint's `max-params` default (4).
too_many_params(Fun, Arity, File, Line) :-
    defines(Fun, Arity, _Params, File, Line),
    Arity > 4.

all_too_many_params(Triples) :-
    findall(Fun-Arity-File, too_many_params(Fun, Arity, File, _Line), Raw),
    sort(Raw, Triples).

%% A rough complexity signal on top of fan_out/3 — not real branch
%% counting (no control-flow facts exist to count), just "this function
%% orchestrates a lot of distinct calls," the same shape of concern
%% ESLint's `complexity` rule flags via cyclomatic branch count instead.
too_complex(Fun, File, Count) :-
    fan_out(Fun, File, Count),
    Count > 10.

all_too_complex(Ranked) :-
    findall(Count-Fun-File, too_complex(Fun, File, Count), Raw),
    sort(Raw, Sorted),
    reverse(Sorted, Ranked).

%% Two functions each reachable from the other's call chain — the
%% function-level analogue of eslint-plugin-import's `no-cycle`. Built on
%% reaches/2, which already guards against infinite loops on a cyclic
%% call graph (docs/erlang-mcp-design.md §5). `A @< B` keeps each pair to
%% one entry: reaches both ways is symmetric, so without it A-B and B-A
%% would both match as separate solutions.
mutual_recursion(A, B) :-
    reaches(A, B),
    reaches(B, A),
    A @< B.

all_mutual_recursion(Pairs) :-
    findall(A-B, mutual_recursion(A, B), Raw),
    sort(Raw, Pairs).

%% Never called at all — local OR remote — closing the exact blind spot
%% no_local_callers/3 has ("mostly false positives" in
%% docs/lint-queries.md): that one only checks local(...) call sites, so
%% every remotely-called entry point (a module's own public API, called
%% from elsewhere) shows up there as a false positive. Still blind to
%% member(...) (method/dynamic-dispatch) calls and to callers outside
%% this same parse — a much stronger dead-code signal, not a perfect one.
truly_uncalled(Fun, Arity, File) :-
    defines(Fun, Arity, _, File, _),
    \+ calls(_, _, local(Fun, Arity), _, _),
    \+ calls(_, _, remote(_, Fun, Arity), _, _).

all_truly_uncalled(Triples) :-
    findall(Fun-Arity-File, truly_uncalled(Fun, Arity, File), Raw),
    sort(Raw, Triples).

%% A method call worth flagging outright, the shape ESLint's `no-console`
%% (or `no-restricted-properties`) checks — edit banned_target/2 for this
%% project's own conventions; shown here with a common JS/TS default.
banned_target(console, log).
banned_target(console, debug).
banned_target(console, warn).

banned_call(Caller, Method, File, Line) :-
    calls(Caller, _CallerArity, member(Object, Method, _ArgCount), File, Line),
    banned_target(Object, Method).

all_banned_calls(Triples) :-
    findall(Caller-Method-File, banned_call(Caller, Method, File, _Line), Raw),
    sort(Raw, Triples).

%% Too many functions crammed into one file — max-lines-per-file's shape,
%% approximated by function count since line spans aren't tracked (only
%% each definition's own start Line). The distinct-files findall/member
%% step (rather than leaving File unbound going into the inner findall)
%% matters: File isn't in that findall's own template, so with nothing
%% grounding it first, backtracking would let it vary freely across every
%% defines/5 fact instead of grouping by one file — silently counting
%% every function in the whole codebase under an unbound File, not per
%% file. See docs/lint-queries.md's "god_file" section for what that
%% looked like when this file_define_count/2 body had that bug.
file_define_count(File, Count) :-
    findall(F, defines(_, _, _, F, _), AllFiles),
    sort(AllFiles, Files),
    member(File, Files),
    findall(Fun, defines(Fun, _Arity, _, File, _), Funs),
    length(Funs, Count).

god_file(File, Count) :-
    file_define_count(File, Count),
    Count > 20.

all_god_files(Ranked) :-
    findall(Count-File, god_file(File, Count), Raw),
    sort(Raw, Sorted),
    reverse(Sorted, Ranked).

%% A branch/5 fact only gets asserted when a real decision point exists
%% (ts_extract_typescript.erl/ts_extract_erlang.erl/ts_extract_bash.erl's
%% own ?BRANCH_QUERIES) — so a codebase (or a single .erl/.ts file) with
%% no if/for/case/etc. anywhere has ZERO branch/5 clauses, and erlog
%% raises existence_error for a predicate with no clauses at all rather
%% than failing cleanly (confirmed: the exact same issue already hits
%% stale_doc_example/4 below, whenever example_defines/5 has zero clauses
%% too — e.g. an Erlang-only tree with no Markdown parsed alongside it —
%% pre-existing, not introduced here). erlog has neither catch/3 nor
%% dynamic/1 to work around this from the querying side, so the fix has
%% to make branch/5 "exist" outright: a clause whose body can never
%% succeed. Its arguments are the sentinel atom `none`/integer `0`, which
%% can only unify with a real query if some codebase genuinely named a
%% function `none` — even then, `fail` makes it categorically
%% unsatisfiable, so it can never contribute a real solution.
branch(none, 0, none, none, 0) :- fail.

%% --- Real cyclomatic complexity, on top of branch/5 ---
%%
%% too_complex/3 above is fan-out (distinct callees), not real branch
%% counting, and says so in its own doc comment. branch/5 (one fact per
%% if/for/while/switch_case/ternary/catch/and/or — see each
%% ts_extract_*.erl's own ?BRANCH_QUERIES for the exact node types per
%% language) makes McCabe's actual "decision points + 1" computable.
%%
%% Erlang's multi-clause functions already give this the "+1" for free:
%% a 3-clause `foo(0) -> ...; foo(N) -> ...; foo(_) -> ...` produces
%% THREE defines/5 facts (one per clause, confirmed empirically), so
%% counting defines/5 rows for one Fun/Arity/File generalizes the "+1"
%% across languages — it's 1 for TypeScript/Bash (one function, one
%% clause) and Clauses for Erlang (each extra clause already IS an
%% extra decision point, same as a switch case).
%%
%% Caveat, not a bug: two decision points sharing the exact same source
%% line collapse into one branch/5 fact, same as any other same-shape
%% fact on the same line in this schema (facts dedupe by tuple equality,
%% keyed on Line, not on a per-node byte offset) — undercounts in that
%% case. Rare in normally-formatted code; a real limitation worth
%% knowing before trusting a number here to the last integer.
%% Distinct (Fun, Arity, File) groups are generated FIRST (findall+sort,
%% backtracked via member/2) before either inner findall runs — the same
%% fix file_define_count/2 above needed for the identical reason: Fun/
%% Arity/File aren't in the inner findalls' own templates, so with
%% nothing grounding them first, calling this with all three unbound
%% (exactly what all_too_complex_real/1 does) would let them vary freely
%% across every defines/5 fact in the whole database instead of grouping
%% by one function — found the same way, by actually running
%% all_too_complex_real(X) against a real codebase rather than trusting
%% the bound-arguments test cases alone.
real_complexity(Fun, Arity, File, Count) :-
    findall(F-A-Fl, defines(F, A, _, Fl, _), AllDefs),
    sort(AllDefs, Defs),
    member(Fun-Arity-File, Defs),
    findall(L, defines(Fun, Arity, _, File, L), Lines),
    length(Lines, Clauses),
    findall(_, branch(Fun, Arity, _, File, _), Bs),
    length(Bs, BranchCount),
    Count is Clauses + BranchCount.

too_complex_real(Fun, Arity, File, Count) :-
    real_complexity(Fun, Arity, File, Count),
    Count > 10.

all_too_complex_real(Ranked) :-
    findall(Count-Fun-Arity-File, too_complex_real(Fun, Arity, File, Count), Raw),
    sort(Raw, Sorted),
    reverse(Sorted, Ranked).

%% --- Naming convention: id-length ---
%%
%% ESLint's `id-length` — a name so short it's likely to hurt
%% readability (`f`, `x1`) rather than a deliberate, idiomatic
%% abbreviation. erlog has no atom_concat/sub_atom (docs/erlang-mcp-
%% design.md §6), but atom_length/2 works directly on the Fun atoms
%% defines/5 already gives us — no new fact needed, unlike branch/5.
%%
%% Bare length alone is noisy without an escape hatch: `ok`, `id` are
%% fine in most codebases. allow_short_name/1 is that escape hatch —
%% edit it for this project's own conventions, same pattern as
%% banned_target/2 above.
allow_short_name(ok).
allow_short_name(id).

short_name(Fun, Arity, File, Line) :-
    defines(Fun, Arity, _, File, Line),
    atom_length(Fun, N),
    N < 3,
    \+ allow_short_name(Fun).

all_short_names(Triples) :-
    findall(Fun-Arity-File, short_name(Fun, Arity, File, _Line), Raw),
    sort(Raw, Triples).

%% --- Expression content, on top of expr/6 + literal/7 + expr_operand/3 + expr_ref/6 ---
%%
%% branch/5 says a decision point exists; these say what it actually
%% compares — the "==" in an `if`, not just that an `if` is there. `Id`
%% (a {File, StartByte, EndByte} byte span — see each ts_extract_*.erl's
%% own node_id/2) is the first fact family in this schema keyed on real
%% node identity rather than (Fun, Arity, File, Line) alone: a byte
%% *span*, not start-byte alone, because a binary expression and its own
%% leftmost operand routinely start at the same byte (`x == x`) — found
%% empirically, by running this against a real snippet and seeing a
%% collision, the same way file_define_count/2's and real_complexity/4's
%% bugs above were found by actually running queries rather than trusting
%% hand-built fixtures alone.
%%
%% Same existence_error caveat as branch/5 above (a codebase with zero
%% expressions of some kind has zero clauses for that predicate, and
%% erlog errors rather than failing cleanly) — one sentinel clause per
%% new predicate, same reasoning as branch/5's.
expr(none, none, 0, none, none, 0) :- fail.
expr_operator(none, none) :- fail.
expr_operand(none, none, none) :- fail.
literal(none, none, 0, none, none, none, 0) :- fail.
expr_ref(none, none, 0, none, none, 0) :- fail.

%% x == x / x === x (or Erlang's X == X) — the "no-self-compare" shape.
%% Scoped to the simple case: both operands are a bare reference to the
%% same name. Not full structural equality of two arbitrary
%% sub-expressions (e.g. `f(x) == f(x)`) — that would need recursive
%% term comparison across the whole operand tree, a real simplification,
%% not hidden.
self_compare(Id, Fun, Arity, File, Line) :-
    expr(Id, Fun, Arity, binary, File, Line),
    expr_operator(Id, Op),
    member(Op, ['==', '===', '!=', '!==', '=:=', '=/=']),
    expr_operand(Id, left, L), expr_ref(L, _, _, Name, _, _),
    expr_operand(Id, right, R), expr_ref(R, _, _, Name, _, _).

all_self_compares(Triples) :-
    findall(Fun-Arity-File, self_compare(_Id, Fun, Arity, File, _Line), Raw),
    sort(Raw, Triples).

%% A literal on the left of a comparison, a non-literal on the right —
%% "Yoda" condition order (`0 === x` instead of `x === 0`).
yoda_condition(Id, Fun, Arity, File, Line) :-
    expr(Id, Fun, Arity, binary, File, Line),
    expr_operator(Id, Op),
    member(Op, ['==', '===', '!=', '!==', '<', '>', '<=', '>=', '=<', '=:=', '=/=']),
    expr_operand(Id, left, L), literal(L, _, _, _, _, _, _),
    expr_operand(Id, right, R), \+ literal(R, _, _, _, _, _, _).

all_yoda_conditions(Triples) :-
    findall(Fun-Arity-File, yoda_condition(_Id, Fun, Arity, File, _Line), Raw),
    sort(Raw, Triples).
