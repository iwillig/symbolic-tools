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

%% --- Variables and scope (TypeScript only), on top of scope/4 + var_decl/6 + var_ref/6 + resolves_to/2 ---
%%
%% The single biggest gap the ESLint-support review turned up: this
%% project tracks functions, calls, branches and expressions, never a
%% variable. Unlike branch/5 or expr/6, this genuinely needed real
%% scope containment computed at extraction time (ts_extract_typescript.erl's
%% scope_facts/3), not just one more query — an unused-variable check
%% that ignored scope would confuse one function's unused `x` with an
%% unrelated `x` read in a completely different function.
%%
%% Same existence_error-on-zero-clauses guard as branch/5 and expr/6.
scope(none, none, none, none) :- fail.
var_decl(none, none, none, none, none, 0) :- fail.
var_ref(none, none, none, none, none, 0) :- fail.
resolves_to(none, none) :- fail.

%% Declared but never read (or read_write'd, e.g. `+=`) afterward.
%% Parameters excluded on purpose: an intentionally-unused parameter
%% (`function(_req, res)`-style) is a much noisier, more debatable
%% signal than an unused local, and this isn't trying to settle that.
unused_var(Id, Name, File, Line) :-
    var_decl(Id, Name, Kind, _Scope, File, Line),
    Kind \= param,
    \+ (resolves_to(RefId, Id), var_ref(RefId, _, _, RK, _, _), member(RK, [read, read_write])).

all_unused_vars(Triples) :-
    findall(Name-File-Line, unused_var(_Id, Name, File, Line), Raw),
    sort(Raw, Triples).

%% An inner declaration whose own scope is nested inside an outer
%% declaration's scope, same Name — real shadowing, not a same-scope
%% redeclaration (that's a different, stricter question this doesn't
%% ask: two decls sharing one scope exactly, not one nested in the other).
scope_ancestor(Scope, Ancestor) :- scope(Scope, _Kind, Ancestor, _File).
scope_ancestor(Scope, Ancestor) :-
    scope(Scope, _Kind, Parent, _File), Parent \= none, scope_ancestor(Parent, Ancestor).

shadowed_var(InnerId, OuterId, Name, File, Line) :-
    var_decl(InnerId, Name, _IK, InnerScope, File, Line),
    var_decl(OuterId, Name, _OK, OuterScope, _, _),
    InnerId \= OuterId,
    scope_ancestor(InnerScope, OuterScope).

all_shadowed_vars(Triples) :-
    findall(Name-File-Line, shadowed_var(_InnerId, _OuterId, Name, File, Line), Raw),
    sort(Raw, Triples).

%% --- More rules on the same scope facts — no new extraction needed ---
%%
%% Same existence_error guard as every other data-derived predicate
%% above, for the one new fact this batch adds.
var_decl_initialized(none) :- fail.

%% A `let` never reassigned after its own declaration should be a
%% `const` — var_decl_initialized/1 guards against ever suggesting
%% `const x;` for a bare, initializer-less `let x;` (not valid syntax).
prefer_const(Id, Name, File, Line) :-
    var_decl(Id, Name, 'let', _Scope, File, Line),
    var_decl_initialized(Id),
    \+ (resolves_to(RefId, Id), var_ref(RefId, _, _, RK, _, _), member(RK, [write, read_write])).

all_prefer_const(Triples) :-
    findall(Name-File-Line, prefer_const(_Id, Name, File, Line), Raw),
    sort(Raw, Triples).

%% Two declarations of the SAME name in the EXACT same scope — not one
%% nested inside the other (shadowed_var/5's question). EarlierId is
%% whichever comes first by line, so the report always names the real
%% redeclaration site, not an arbitrary one of the two.
redeclared_var(EarlierId, LaterId, Name, File, LaterLine) :-
    var_decl(EarlierId, Name, _EK, Scope, File, EarlierLine),
    var_decl(LaterId, Name, _LK, Scope, File, LaterLine),
    EarlierId \= LaterId,
    EarlierLine < LaterLine.

all_redeclared_vars(Triples) :-
    findall(Name-File-Line, redeclared_var(_E, _L, Name, File, Line), Raw),
    sort(Raw, Triples).

%% A declaration named after one of JS's own restricted identifiers —
%% edit this table if this project's own runtime has more to add.
restricted_name('undefined').
restricted_name('NaN').
restricted_name('Infinity').
restricted_name(arguments).
restricted_name(eval).

shadows_restricted_name(Id, Name, File, Line) :-
    var_decl(Id, Name, _Kind, _Scope, File, Line),
    restricted_name(Name).

all_restricted_name_shadows(Triples) :-
    findall(Name-File-Line, shadows_restricted_name(_Id, Name, File, Line), Raw),
    sort(Raw, Triples).

%% A reference that resolves to a declaration textually AFTER it — a
%% real ReferenceError for let/const (the temporal dead zone), a softer
%% "silently undefined until reached" bug for var, reported either way.
use_before_define(RefId, DeclId, Name, File, RefLine) :-
    resolves_to(RefId, DeclId),
    DeclId \= undefined,
    var_ref(RefId, Name, _RefScope, _RK, File, RefLine),
    var_decl(DeclId, Name, _DK, _DeclScope, File, DeclLine),
    RefLine < DeclLine.

all_use_before_define(Triples) :-
    findall(Name-File-Line, use_before_define(_R, _D, Name, File, Line), Raw),
    sort(Raw, Triples).

%% A small, editable set of ambient/global names common to Node and
%% browser JS/TS — edit for this project's own runtime. The one thing
%% that turns resolves_to(_, undefined) (see scope/4's own doc comment
%% — it means "not declared in anything tracked," not "definitely a
%% bug") into a real no-undef check: everything in this table is a
%% real global, not a mistake, so it's excluded rather than flagged.
known_global(console). known_global('Math'). known_global('JSON').
known_global('Object'). known_global('Array'). known_global('String').
known_global('Number'). known_global('Boolean'). known_global('Symbol').
known_global('Promise'). known_global('Map'). known_global('Set').
known_global('WeakMap'). known_global('WeakSet'). known_global('Date').
known_global('RegExp'). known_global('Error'). known_global('TypeError').
known_global('RangeError'). known_global('SyntaxError'). known_global('Function').
known_global('Proxy'). known_global('Reflect'). known_global('ArrayBuffer').
known_global('undefined'). known_global('NaN'). known_global('Infinity').
known_global('globalThis'). known_global(window). known_global(document).
known_global(process). known_global(module). known_global(require).
known_global(exports). known_global('__dirname'). known_global('__filename').
known_global(setTimeout). known_global(clearTimeout). known_global(setInterval).
known_global(clearInterval). known_global(fetch). known_global('URL').
known_global('URLSearchParams'). known_global('Buffer'). known_global(structuredClone).

undeclared_var(RefId, Name, File, Line) :-
    resolves_to(RefId, undefined),
    var_ref(RefId, Name, _Scope, _RK, File, Line),
    \+ known_global(Name).

all_undeclared_vars(Triples) :-
    findall(Name-File-Line, undeclared_var(_RefId, Name, File, Line), Raw),
    sort(Raw, Triples).

%% --- `new` expressions, on top of calls/5's new(Constructor, ArgCount) shape + bare_new/5 ---
%%
%% `new X(...)` is modeled as one more calls/5 CallSpec, the same way a
%% call's shape already varies by language (local/member/remote) — see
%% ts_extract_typescript.erl's new_calls/4. Only bare_new/5 (no_new/4
%% below) is a genuinely new predicate; everything else here is plain
%% Prolog over calls/5, same as risky_call/3's own pattern.
bare_new(none, 0, none, none, 0) :- fail.

%% A constructed value discarded outright (`new Logger();` as its own
%% statement) — almost always a mistake unless the constructor has a
%% real side effect, which this can't tell either way; flag and let a
%% human judge.
no_new(Caller, Arity, Constructor, File, Line) :-
    bare_new(Caller, Arity, Constructor, File, Line).

all_no_new(Triples) :-
    findall(Constructor-File-Line, no_new(_C, _A, Constructor, File, Line), Raw),
    sort(Raw, Triples).

%% `new String(...)`/`new Number(...)`/`new Boolean(...)` build a boxed
%% wrapper object, not the primitive — a classic footgun (`new
%% Boolean(false) == true` in a truthiness check).
no_new_wrapper(Caller, Arity, Constructor, File, Line) :-
    calls(Caller, Arity, new(Constructor, _ArgCount), File, Line),
    member(Constructor, ['String', 'Number', 'Boolean']).

all_no_new_wrappers(Triples) :-
    findall(Constructor-File-Line, no_new_wrapper(_C, _A, Constructor, File, Line), Raw),
    sort(Raw, Triples).

%% `new Function(...)` compiles a string as code, the same risk class
%% as `eval` — already in banned_target/2's spirit, but Function is a
%% constructor call, not a member call, so it needs its own rule.
no_new_func(Caller, Arity, File, Line) :-
    calls(Caller, Arity, new('Function', _ArgCount), File, Line).

all_no_new_func(Triples) :-
    findall(File-Line, no_new_func(_C, _A, File, Line), Raw),
    sort(Raw, Triples).

%% `Object()`/`new Object()` with no arguments is always exactly `{}` —
%% checked with or without `new`, since a bare call works identically
%% in JS/TS (calls/5's existing local(...) shape already covers the
%% bare half, no new extraction needed for it).
no_object_constructor(Caller, Arity, File, Line) :-
    ( calls(Caller, Arity, new('Object', 0), File, Line)
    ; calls(Caller, Arity, local('Object', 0), File, Line)
    ).

all_no_object_constructors(Triples) :-
    findall(File-Line, no_object_constructor(_C, _A, File, Line), Raw),
    sort(Raw, Triples).

%% `new RegExp(...)`/`RegExp(...)` — a regex *literal* (`/a+/`) is
%% preferred when the pattern is static text; this can't tell a static
%% string apart from a dynamically-built one (that needs literal/7's
%% Value, a further check this doesn't make), so it flags every call
%% and leaves the "was the pattern actually static" judgment to a human.
prefer_regex_literal(Caller, Arity, File, Line) :-
    ( calls(Caller, Arity, new('RegExp', _), File, Line)
    ; calls(Caller, Arity, local('RegExp', _), File, Line)
    ).

all_prefer_regex_literals(Triples) :-
    findall(File-Line, prefer_regex_literal(_C, _A, File, Line), Raw),
    sort(Raw, Triples).

%% A constructor name that doesn't start with a capital letter — atom_codes
%% on the *letters* 'a'/'z' rather than a `0'a`-style char-code literal,
%% the same safe-derivation technique short_name/4 already uses (erlog's
%% reader support for that literal syntax was never verified, so this
%% never needed to rely on it).
lowercase_constructor(Caller, Arity, Constructor, File, Line) :-
    calls(Caller, Arity, new(Constructor, _ArgCount), File, Line),
    atom_codes(Constructor, [C | _]),
    atom_codes(a, [Lo]), atom_codes(z, [Hi]),
    C >= Lo, C =< Hi.

all_lowercase_constructors(Triples) :-
    findall(Constructor-File-Line, lowercase_constructor(_C, _A, Constructor, File, Line), Raw),
    sort(Raw, Triples).

%% --- Imports and exports, on top of import_decl/4 + export_decl/4 (+ var_decl/6's new 'import' Kind) ---
%%
%% Import bindings are ordinary var_decl/6 facts (Kind='import') — see
%% ts_extract_typescript.erl's imports/5 — so unused_var/4, shadowed_var/5
%% etc. above already apply to an unused/shadowed import for free; the
%% two facts here (import_decl/4, export_decl/4) exist for what those
%% can't answer: which MODULE a name came from, and what a file makes
%% PUBLIC. sort-imports is deliberately not built here — it needs each
%% binding tied back to which import STATEMENT introduced it, a
%% per-statement grouping key this pass doesn't have cheaply (var_decl/6
%% alone can't tell two same-line bindings from the same import apart
%% from two coincidentally-same-line bindings from different ones), and
%% it's the most purely stylistic of this whole group — a reasoned
%% skip, not an oversight.
import_decl(none, none, 0) :- fail.
export_decl(none, none, none, 0) :- fail.

%% The same module path imported in more than one separate
%% import_statement. EarlierLine/LaterLine ordered the same way
%% redeclared_var/5 orders its two occurrences, so the report always
%% names the real second (redundant) import, not an arbitrary one.
duplicate_import(Module, File, EarlierLine, LaterLine) :-
    import_decl(Module, File, EarlierLine),
    import_decl(Module, File, LaterLine),
    EarlierLine < LaterLine.

all_duplicate_imports(Triples) :-
    findall(Module-File-Line, duplicate_import(Module, File, _E, Line), Raw),
    sort(Raw, Triples).

%% A small, editable set of commonly-restricted modules — genuinely
%% project-specific (unlike known_global/1's list, there's no universal
%% "always risky" import the way there's a universal set of real
%% globals), so this ships with a couple of realistic, commonly-cited
%% examples rather than either an empty table or a false claim of
%% universality. Edit for this project's own conventions.
restricted_module(moment).
restricted_module(lodash).

restricted_import(Module, File, Line) :-
    import_decl(Module, File, Line),
    restricted_module(Module).

all_restricted_imports(Triples) :-
    findall(Module-File-Line, restricted_import(Module, File, Line), Raw),
    sort(Raw, Triples).

%% Same reasoning as restricted_module/1 — genuinely project-specific,
%% shipped with one realistic illustrative example (a team that wants
%% every module to use named exports, banning `export default`
%% entirely, restricts the literal name 'default' — see export_decl/4's
%% own doc comment for why that's the real exported name of a default
%% export, not whatever expression fills it).
restricted_export_name('default').

restricted_export(Name, Kind, File, Line) :-
    export_decl(Name, Kind, File, Line),
    restricted_export_name(Name).

all_restricted_exports(Triples) :-
    findall(Name-Kind-File-Line, restricted_export(Name, Kind, File, Line), Raw),
    sort(Raw, Triples).

%% --- Statement/block structure, on top of stmt_block/6 + stmt/6 + last_switch_case/1 + braceless_body/5 + return_stmt/5 ---
%%
%% The last unbuilt bucket from the ESLint review, and less uniform
%% than it looked: curly/consistent_return needed nothing beyond a flat
%% per-node fact each (braceless_body/5, return_stmt/5); no_empty_block,
%% unreachable_stmt, no_fallthrough_case needed the one genuinely new
%% capability nothing before this had — a statement's *position* within
%% its block, not just that it exists. TypeScript only (Erlang has no
%% brace-optional if/for/while and no separate `return` statement at
%% all — every rule here is a JS/TS-specific concept).
stmt_block(none, none, 0, none, none, 0) :- fail.
stmt(none, none, 0, none, none, 0) :- fail.
last_switch_case(none) :- fail.
braceless_body(none, 0, none, none, 0) :- fail.
return_stmt(none, 0, none, none, 0) :- fail.

terminator_kind('return_statement').
terminator_kind('throw_statement').
terminator_kind('break_statement').
terminator_kind('continue_statement').

%% A real {} block with zero statements — switch_case/switch_default
%% deliberately excluded: an empty case immediately followed by another
%% (`case 1: case 2: ...`) is idiomatic stacking, not this rule's
%% concern (no_fallthrough_case/5 below is the one that cares, and
%% explicitly allows it).
no_empty_block(BlockId, Fun, Arity, File, Line) :-
    stmt_block(BlockId, Fun, Arity, block, File, Line),
    \+ stmt(_, BlockId, _, _, _, _).

all_no_empty_blocks(Triples) :-
    findall(Fun-Arity-File-Line, no_empty_block(_BlockId, Fun, Arity, File, Line), Raw),
    sort(Raw, Triples).

%% Any statement whose Index comes after some terminator statement's
%% Index in the SAME block — stmt/6's Index can have gaps (a filtered-
%% out comment leaves its own slot empty), which is harmless here since
%% this only ever compares Index values with `>`, never assumes they're
%% contiguous.
unreachable_stmt(Id, BlockId, File, Line) :-
    stmt(_TermId, BlockId, TermIndex, TermKind, _, _),
    terminator_kind(TermKind),
    stmt(Id, BlockId, Index, _Kind, File, Line),
    Index > TermIndex.

all_unreachable_stmts(Triples) :-
    findall(File-Line, unreachable_stmt(_Id, _BlockId, File, Line), Raw),
    sort(Raw, Triples).

%% A switch_case/switch_default that (a) isn't the last one in its
%% switch, (b) has at least one statement (an empty case is allowed to
%% stack into the next — the ONLY exemption this rule has), and (c)
%% whose last statement isn't a terminator.
no_fallthrough_case(BlockId, Fun, Arity, File, Line) :-
    stmt_block(BlockId, Fun, Arity, Kind, File, Line),
    member(Kind, [switch_case, switch_default]),
    \+ last_switch_case(BlockId),
    findall(Idx-K, stmt(_, BlockId, Idx, K, _, _), Stmts),
    Stmts \= [],
    sort(Stmts, Sorted),
    reverse(Sorted, [_-LastKind | _]),
    \+ terminator_kind(LastKind).

all_no_fallthrough_cases(Triples) :-
    findall(Fun-Arity-File-Line, no_fallthrough_case(_BlockId, Fun, Arity, File, Line), Raw),
    sort(Raw, Triples).

%% An if/else/for/while whose body is a single bare statement, not a
%% real {} block.
curly_violation(Fun, Arity, Kind, File, Line) :-
    braceless_body(Fun, Arity, Kind, File, Line).

all_curly_violations(Triples) :-
    findall(Fun-Arity-Kind-File-Line, curly_violation(Fun, Arity, Kind, File, Line), Raw),
    sort(Raw, Triples).

%% A function with at least one `return` that specifies a value AND at
%% least one that doesn't — no control-flow-path analysis needed at
%% all, real ESLint semantics just check the whole function's returns
%% for consistency.
inconsistent_return(Fun, Arity, File) :-
    return_stmt(Fun, Arity, true, File, _),
    return_stmt(Fun, Arity, false, File, _).

all_inconsistent_returns(Triples) :-
    findall(Fun-Arity-File, inconsistent_return(Fun, Arity, File), Raw),
    sort(Raw, Triples).
