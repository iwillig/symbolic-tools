%% Default derived-predicate library — auto-consulted by `symbolic query`
%% (override with -rules/-no-rules). calls/5 = calls(Caller, CallerArity,
%% CallSpec, File, Line); most rules below leave CallerArity unbound.

%% Sentinel: keeps calls/5 defined so a tree with zero function-call sites
%% at all fails cleanly instead of raising existence_error, same
%% convention as branch/5, export/4, comment/3, etc. below. This project's
%% own prior assumption ("a real parse always has calls in it" — see
%% test/symbolic_query_tests.erl's truly_uncalled fixture comments) turned
%% out to be false: a real TS file containing only expressions and no
%% actual invocations (verified live) produces zero calls/5 facts, and
%% every predicate built directly on calls/5 with no other guard —
%% callees/2, no_new_wrapper/5, banned_call/4, and more, all below —
%% shared this same latent crash until now.
calls(none, 0, none, none, 0) :- fail.

%% Everything Fun calls, deduplicated (bare name, arity-blind).
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

%% Direct self-call, precise on both Fun AND Arity (not just the bare name).
self_recursive(Fun, Arity, File) :-
    defines(Fun, Arity, _, File, _),
    calls(Fun, Arity, local(Fun, Arity), File, _).

%% Fan-out: how many distinct things a function calls.
fan_out(Fun, File, Count) :-
    defines(Fun, _Arity, _Params, File, _),
    findall(Callee, calls(Fun, _CallerArity, Callee, File, _), Callees),
    sort(Callees, Unique),
    length(Unique, Count).

%% Top N by fan-out, busiest first.
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

%% Defined but never called locally — blind to remote/external callers,
%% see truly_uncalled/3 for the fuller check.
no_local_callers(Fun, Arity, File) :-
    defines(Fun, Arity, _, File, _),
    \+ calls(_, _, local(Fun, Arity), _, _).

all_no_local_callers(Triples) :-
    findall(Fun-Arity-File, no_local_callers(Fun, Arity, File), Raw),
    sort(Raw, Triples).

%% A comment not immediately followed by a recognized definition.
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

%% Transitive risk propagation: does a GIVEN function (Fun bound — the
%% starting value a caller supplies, same "fine when bound" contract
%% mutual_recursion/2 above documents) reach a risky call without making
%% one itself? `risky_call/3` alone only sees the one function actually
%% holding the os:cmd/file:write/etc. call — every innocent-looking
%% function standing between it and a caller several layers up is
%% invisible to it, exactly the ones a reviewer most needs flagged (the
%% risk is hidden BEHIND a name that gives no hint of it).
%%
%% This is the case a normal, per-file AST-visitor linter (ESLint
%% included) cannot express as a "rule" at all: answering it needs a real
%% call graph and a walk over arbitrary-depth call chains — exactly what
%% taint-tracking tools like CodeQL or Semgrep exist to bolt on as a
%% separate analysis engine, because the linter's own visitor model has
%% no notion of "reachable," only "present at this node." Here it's two
%% lines over facts already extracted.
%%
%% Deliberately scoped to ONE starting Fun, not "every hidden risky
%% function in the codebase" — that version was tried first and empirically
%% doesn't work: materializing the whole-codebase closure once via
%% all_reaches_pairs/1 (1929 pairs here, fast on its own) and then
%% cross-joining it against every risky_call/3 site, re-checking the
%% `\+ risky_call/3` negation per candidate pair, blew well past the
%% query timeout (verified live, even after fixing a goal-order variant
%% of the same trap along the way). The fix isn't a smarter join, it's
%% not asking the open-ended question at all: reaches/2's own
%% visited-list guard already makes a SINGLE bounded forward search fast,
%% the same way callers/3 and fan_out/3 already require a bound Fun
%% rather than offering an "every function" form.
hidden_risky_call(Fun, Module, Target) :-
    reaches(Fun, RiskyCaller),
    risky_call(RiskyCaller, Module, Target),
    \+ risky_call(Fun, Module, Target).

%% First N elements of a list, for ranking a sorted Count-Key list into a top-N.
take(0, _, []) :- !.
take(_, [], []) :- !.
take(N, [H|T], [H|Rest]) :- N > 0, N1 is N - 1, take(N1, T, Rest).

%% Reachability with a Visited-list cycle guard (erlog has no tabling).
%% Arity-blind on both ends.
reaches(A, B) :- reaches(A, B, []).

reaches(A, B, _) :- calls(A, _CallerArity, local(B, _), _, _).
reaches(A, B, Visited) :-
    calls(A, _CallerArity, local(M, _), _, _),
    \+ member(M, Visited),
    reaches(M, B, [M|Visited]).

%% C4-L3 file-to-module edges via remote/3 calls only — local/3 is
%% intra-file detail, not a component boundary.
module_dependency(CallerFile, CalleeModule) :-
    calls(_, _, remote(CalleeModule, _, _), CallerFile, _).

all_module_dependencies(Edges) :-
    findall(CallerFile-CalleeModule, module_dependency(CallerFile, CalleeModule), Raw),
    sort(Raw, Edges).

%% --- ESLint-style structural checks, on top of the library above ---

%% ESLint max-params: https://eslint.org/docs/latest/rules/max-params
%% Default threshold (4) — Arity already is the parameter count.
too_many_params(Fun, Arity, File, Line) :-
    defines(Fun, Arity, _Params, File, Line),
    Arity > 4.

all_too_many_params(Triples) :-
    findall(Fun-Arity-File, too_many_params(Fun, Arity, File, _Line), Raw),
    sort(Raw, Triples).

%% Fan-out-based complexity proxy — not real branch counting, see
%% too_complex_real/4 for that.
too_complex(Fun, File, Count) :-
    fan_out(Fun, File, Count),
    Count > 10.

all_too_complex(Ranked) :-
    findall(Count-Fun-File, too_complex(Fun, File, Count), Raw),
    sort(Raw, Sorted),
    reverse(Sorted, Ranked).

%% Two functions each reachable from the other's call chain. Fine when at
%% least one side is bound — NOT what all_mutual_recursion/1 below uses.
mutual_recursion(A, B) :-
    reaches(A, B),
    reaches(B, A),
    A @< B.

%% all_mutual_recursion/1's own path: findall(A-B, mutual_recursion(A,B), _)
%% with both sides unbound re-derives the whole search per candidate and
%% times out on a real codebase (no tabling in erlog). Instead compute the
%% full reachability relation once via a semi-naive fixpoint join, then
%% read mutual pairs off it with a sorted-list merge (not `member/2` scans
%% — both shapes of naive filtering were independently confirmed to be the
%% quadratic bottleneck here).
call_edge(A, B) :- calls(A, _CallerArity, local(B, _), _, _).

all_call_edges(Edges) :-
    findall(A-B, call_edge(A, B), Raw),
    sort(Raw, Edges).

%% One fixpoint round: extend last round's new pairs (Frontier) by one edge.
join_step(Frontier, Edges, New) :-
    findall(A-C, ( member(A-B, Frontier), member(B-C, Edges) ), Raw),
    sort(Raw, New).

%% Ordered set difference over two sorted, duplicate-free lists (New \ Known).
ordered_diff([], _Known, []) :- !.
ordered_diff(New, [], New) :- !.
ordered_diff([X|New], [X|Known], Diff) :- !, ordered_diff(New, Known, Diff).
ordered_diff([X|New], [Y|Known], [X|Diff]) :- X @< Y, !, ordered_diff(New, [Y|Known], Diff).
ordered_diff([X|New], [Y|Known], Diff) :- X @> Y, ordered_diff([X|New], Known, Diff).

%% Fixpoint: stop once a round's Frontier produces nothing new. Terminates
%% because Known only grows and is bounded by the finite Fun-Fun pair count.
closure(_Edges, [], Known, Known) :- !.
closure(Edges, Frontier, Known, Closed) :-
    join_step(Frontier, Edges, Joined),
    ordered_diff(Joined, Known, Fresh),
    append(Known, Fresh, All),
    sort(All, NextKnown),
    closure(Edges, Fresh, NextKnown, Closed).

%% Every A-B pair such that A's call chain reaches B, computed once.
all_reaches_pairs(Closed) :-
    all_call_edges(Edges),
    closure(Edges, Edges, Edges, Closed).

%% Closed with every pair swapped end-for-end.
swap_pairs(Pairs, Swapped) :-
    findall(B-A, member(A-B, Pairs), Raw),
    sort(Raw, Swapped).

%% Ordered set intersection over two sorted, duplicate-free lists.
ordered_intersect([], _, []) :- !.
ordered_intersect(_, [], []) :- !.
ordered_intersect([X|Xs], [X|Ys], [X|Zs]) :- !, ordered_intersect(Xs, Ys, Zs).
ordered_intersect([X|Xs], [Y|Ys], Zs) :- X @< Y, !, ordered_intersect(Xs, [Y|Ys], Zs).
ordered_intersect(Xs, [_Y|Ys], Zs) :- ordered_intersect(Xs, Ys, Zs).

%% Mutual pairs = Closed ∩ reverse(Closed), canonicalized via A @< B.
all_mutual_recursion(Pairs) :-
    all_reaches_pairs(Closed),
    swap_pairs(Closed, Swapped),
    ordered_intersect(Closed, Swapped, Mutual),
    findall(A-B, ( member(A-B, Mutual), A @< B ), Raw),
    sort(Raw, Pairs).

%% --- Entry points ---

%% Sentinel: keeps export/4 defined so a TS-only tree (no -export lists)
%% fails cleanly instead of raising existence_error.
export(none, 0, none, 0) :- fail.

%% Entry points the BEAM reaches without an export — only -on_load hooks
%% genuinely need an entry here.
runtime_entry_point(init, 0).

entry_point(Fun, Arity, File) :-
    export(Fun, Arity, File, _).
entry_point(Fun, Arity, _) :-
    runtime_entry_point(Fun, Arity).

%% Never called at all, local OR remote, and not an entry point — closes
%% no_local_callers/3's false positives (remote callers, OTP callbacks).
%% Still blind to member(...) dynamic dispatch and `fun Name/Arity` refs.
truly_uncalled(Fun, Arity, File) :-
    defines(Fun, Arity, _, File, _),
    \+ calls(_, _, local(Fun, Arity), _, _),
    \+ calls(_, _, remote(_, Fun, Arity), _, _),
    \+ entry_point(Fun, Arity, File).

all_truly_uncalled(Triples) :-
    findall(Fun-Arity-File, truly_uncalled(Fun, Arity, File), Raw),
    sort(Raw, Triples).

%% ESLint no-console: https://eslint.org/docs/latest/rules/no-console
%% (the default banned_target/2 table below is exactly console.log/debug/warn)
%% ESLint no-restricted-properties: https://eslint.org/docs/latest/rules/no-restricted-properties
%% (the generalized form — edit banned_target/2 for this project's own conventions)
banned_target(console, log).
banned_target(console, debug).
banned_target(console, warn).

banned_call(Caller, Method, File, Line) :-
    calls(Caller, _CallerArity, member(Object, Method, _ArgCount), File, Line),
    banned_target(Object, Method).

all_banned_calls(Triples) :-
    findall(Caller-Method-File, banned_call(Caller, Method, File, _Line), Raw),
    sort(Raw, Triples).

%% Function count per file — groups by File via findall+sort+member first
%% so it doesn't drift unbound across the whole codebase.
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

%% Sentinel: keeps branch/5 defined for a tree with zero decision points.
branch(none, 0, none, none, 0) :- fail.

%% --- Real cyclomatic complexity, on top of branch/5 ---

%% ESLint complexity: https://eslint.org/docs/latest/rules/complexity
%% McCabe complexity: clause count + branch count per (Fun,Arity,File) —
%% groups are bound first (findall+sort+member), same reason as
%% file_define_count/2. Caveat: two decision points on the same source
%% line collapse into one branch/5 fact (undercounts).
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

%% ESLint id-length: https://eslint.org/docs/latest/rules/id-length
%% Fun atoms shorter than 3 chars, minus an escape
%% hatch (allow_short_name/1, edit for this project's own conventions).
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

%% --- Expression content, on top of expr/6 + literal/8 + expr_operand/3 + expr_ref/6 ---
%% (byte-span Id; Erlang/TypeScript only). literal/8's 8th argument,
%% RawText, is the verbatim source slice captured BEFORE any
%% parsing/unescaping (classify_literal/2 in each extractor) — was
%% literal/7 until the Fact Debt Ledger's "Raw literal source text"
%% bucket widened it; every existing consultation below took one more
%% trailing `_`.

expr(none, none, 0, none, none, 0) :- fail.
expr_operator(none, none) :- fail.
expr_operand(none, none, none) :- fail.
literal(none, none, 0, none, none, none, 0, none) :- fail.
expr_ref(none, none, 0, none, none, 0) :- fail.

%% ESLint no-self-compare: https://eslint.org/docs/latest/rules/no-self-compare
%% x == x / x === x — bare-reference self-comparison only, not deep
%% structural equality of two arbitrary sub-expressions.
self_compare(Id, Fun, Arity, File, Line) :-
    expr(Id, Fun, Arity, binary, File, Line),
    expr_operator(Id, Op),
    member(Op, ['==', '===', '!=', '!==', '=:=', '=/=']),
    expr_operand(Id, left, L), expr_ref(L, _, _, Name, _, _),
    expr_operand(Id, right, R), expr_ref(R, _, _, Name, _, _).

all_self_compares(Triples) :-
    findall(Fun-Arity-File, self_compare(_Id, Fun, Arity, File, _Line), Raw),
    sort(Raw, Triples).

%% ESLint yoda: https://eslint.org/docs/latest/rules/yoda
%% A literal on the left, non-literal on the right of a comparison —
%% "Yoda" condition order.
yoda_condition(Id, Fun, Arity, File, Line) :-
    expr(Id, Fun, Arity, binary, File, Line),
    expr_operator(Id, Op),
    member(Op, ['==', '===', '!=', '!==', '<', '>', '<=', '>=', '=<', '=:=', '=/=']),
    expr_operand(Id, left, L), literal(L, _, _, _, _, _, _, _),
    expr_operand(Id, right, R), \+ literal(R, _, _, _, _, _, _, _).

all_yoda_conditions(Triples) :-
    findall(Fun-Arity-File, yoda_condition(_Id, Fun, Arity, File, _Line), Raw),
    sort(Raw, Triples).

%% A call site (Kind=call) gets the same Id-keyed expr/expr_operator/
%% expr_operand treatment a binary/unary comparison does — expr_operator's
%% Op is the exact same CallSpec term calls/5's own third field carries
%% (Erlang: local(F,ArgCount) / remote(M,F,ArgCount); TypeScript: those
%% same shapes plus member(Obj,M,ArgCount) / new(C,ArgCount)), and
%% expr_operand's Role is a 0-based argument index rather than left/right.
%% These two wrappers pull out the concrete VALUE calls/5 alone never
%% carries (it only has ArgCount) — e.g. what literal string a
%% `filename:join(Dir, "x.log")` (Erlang) or `fs.writeFileSync(path,
%% "x.log")` (TypeScript) call was actually made with. One goal, not two
%% lookups joined in prose — see this project's own rule on composing
%% chains.
call_arg_literal(Fun, Arity, CallSpec, ArgIndex, LitKind, Value, File, Line) :-
    expr(Id, Fun, Arity, call, File, Line),
    expr_operator(Id, CallSpec),
    expr_operand(Id, ArgIndex, ArgId),
    literal(ArgId, Fun, Arity, LitKind, Value, File, Line, _RawText).

all_call_arg_literals(Rows) :-
    findall(Fun-Arity-CallSpec-ArgIndex-LitKind-Value-File-Line,
        call_arg_literal(Fun, Arity, CallSpec, ArgIndex, LitKind, Value, File, Line),
        Raw),
    sort(Raw, Rows).

%% Same shape, for a call argument that's a bare variable rather than a
%% literal (e.g. the `Dir` in `filename:join(Dir, "x.log")`).
call_arg_ref(Fun, Arity, CallSpec, ArgIndex, Name, File, Line) :-
    expr(Id, Fun, Arity, call, File, Line),
    expr_operator(Id, CallSpec),
    expr_operand(Id, ArgIndex, ArgId),
    expr_ref(ArgId, Fun, Arity, Name, File, Line).

%% --- Variables and scope (TypeScript only), on top of scope/4 + var_decl/6 + var_ref/6 + resolves_to/2 ---

scope(none, none, none, none) :- fail.
var_decl(none, none, none, none, none, 0) :- fail.
var_ref(none, none, none, none, none, 0) :- fail.
resolves_to(none, none) :- fail.

%% ESLint no-unused-vars: https://eslint.org/docs/latest/rules/no-unused-vars
%% Declared (non-param) but never read/read_write'd afterward.
unused_var(Id, Name, File, Line) :-
    var_decl(Id, Name, Kind, _Scope, File, Line),
    Kind \= param,
    \+ (resolves_to(RefId, Id), var_ref(RefId, _, _, RK, _, _), member(RK, [read, read_write])).

all_unused_vars(Triples) :-
    findall(Name-File-Line, unused_var(_Id, Name, File, Line), Raw),
    sort(Raw, Triples).

%% ESLint no-shadow: https://eslint.org/docs/latest/rules/no-shadow
%% Shadowing: an inner decl nested inside an outer decl's scope, same name.
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

var_decl_initialized(none) :- fail.

%% ESLint prefer-const: https://eslint.org/docs/latest/rules/prefer-const
%% A never-reassigned `let` should be a `const` (var_decl_initialized/1
%% excludes a bare, initializer-less `let x;`).
prefer_const(Id, Name, File, Line) :-
    var_decl(Id, Name, 'let', _Scope, File, Line),
    var_decl_initialized(Id),
    \+ (resolves_to(RefId, Id), var_ref(RefId, _, _, RK, _, _), member(RK, [write, read_write])).

all_prefer_const(Triples) :-
    findall(Name-File-Line, prefer_const(_Id, Name, File, Line), Raw),
    sort(Raw, Triples).

%% ESLint no-redeclare: https://eslint.org/docs/latest/rules/no-redeclare
%% Same name declared twice in the exact same scope (not shadowed_var/5's
%% nested-scope question).
redeclared_var(EarlierId, LaterId, Name, File, LaterLine) :-
    var_decl(EarlierId, Name, _EK, Scope, File, EarlierLine),
    var_decl(LaterId, Name, _LK, Scope, File, LaterLine),
    EarlierId \= LaterId,
    EarlierLine < LaterLine.

all_redeclared_vars(Triples) :-
    findall(Name-File-Line, redeclared_var(_E, _L, Name, File, Line), Raw),
    sort(Raw, Triples).

%% ESLint no-shadow-restricted-names: https://eslint.org/docs/latest/rules/no-shadow-restricted-names
%% A declaration named after a JS restricted identifier — edit
%% restricted_name/1 for this project's own runtime.
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

%% ESLint no-use-before-define: https://eslint.org/docs/latest/rules/no-use-before-define
%% A reference resolving to a declaration that comes later in the file.
use_before_define(RefId, DeclId, Name, File, RefLine) :-
    resolves_to(RefId, DeclId),
    DeclId \= undefined,
    var_ref(RefId, Name, _RefScope, _RK, File, RefLine),
    var_decl(DeclId, Name, _DK, _DeclScope, File, DeclLine),
    RefLine < DeclLine.

all_use_before_define(Triples) :-
    findall(Name-File-Line, use_before_define(_R, _D, Name, File, Line), Raw),
    sort(Raw, Triples).

%% Ambient/global names common to Node and browser JS/TS — edit for this
%% project's own runtime.
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

%% ESLint no-undef: https://eslint.org/docs/latest/rules/no-undef
%% A reference with no tracked declaration and not a known global.
undeclared_var(RefId, Name, File, Line) :-
    resolves_to(RefId, undefined),
    var_ref(RefId, Name, _Scope, _RK, File, Line),
    \+ known_global(Name).

all_undeclared_vars(Triples) :-
    findall(Name-File-Line, undeclared_var(_RefId, Name, File, Line), Raw),
    sort(Raw, Triples).

%% --- `new` expressions, on top of calls/5's new(Constructor, ArgCount) shape + bare_new/5 ---

bare_new(none, 0, none, none, 0) :- fail.

%% ESLint no-new: https://eslint.org/docs/latest/rules/no-new
%% A constructed value discarded outright (`new Logger();` as its own statement).
no_new(Caller, Arity, Constructor, File, Line) :-
    bare_new(Caller, Arity, Constructor, File, Line).

all_no_new(Triples) :-
    findall(Constructor-File-Line, no_new(_C, _A, Constructor, File, Line), Raw),
    sort(Raw, Triples).

%% ESLint no-new-wrappers: https://eslint.org/docs/latest/rules/no-new-wrappers
%% new String/Number/Boolean — a boxed wrapper, not the primitive.
no_new_wrapper(Caller, Arity, Constructor, File, Line) :-
    calls(Caller, Arity, new(Constructor, _ArgCount), File, Line),
    member(Constructor, ['String', 'Number', 'Boolean']).

all_no_new_wrappers(Triples) :-
    findall(Constructor-File-Line, no_new_wrapper(_C, _A, Constructor, File, Line), Raw),
    sort(Raw, Triples).

%% ESLint no-new-func: https://eslint.org/docs/latest/rules/no-new-func
%% new Function(...) compiles a string as code — same risk class as eval.
no_new_func(Caller, Arity, File, Line) :-
    calls(Caller, Arity, new('Function', _ArgCount), File, Line).

all_no_new_func(Triples) :-
    findall(File-Line, no_new_func(_C, _A, File, Line), Raw),
    sort(Raw, Triples).

%% ESLint no-object-constructor: https://eslint.org/docs/latest/rules/no-object-constructor
%% Object()/new Object() with no arguments is always exactly {}.
no_object_constructor(Caller, Arity, File, Line) :-
    ( calls(Caller, Arity, new('Object', 0), File, Line)
    ; calls(Caller, Arity, local('Object', 0), File, Line)
    ).

all_no_object_constructors(Triples) :-
    findall(File-Line, no_object_constructor(_C, _A, File, Line), Raw),
    sort(Raw, Triples).

%% ESLint prefer-regex-literals: https://eslint.org/docs/latest/rules/prefer-regex-literals
%% new RegExp(...)/RegExp(...) — prefer a literal /pattern/ when static.
prefer_regex_literal(Caller, Arity, File, Line) :-
    ( calls(Caller, Arity, new('RegExp', _), File, Line)
    ; calls(Caller, Arity, local('RegExp', _), File, Line)
    ).

all_prefer_regex_literals(Triples) :-
    findall(File-Line, prefer_regex_literal(_C, _A, File, Line), Raw),
    sort(Raw, Triples).

%% ESLint new-cap: https://eslint.org/docs/latest/rules/new-cap
%% A constructor name that doesn't start with a capital letter.
lowercase_constructor(Caller, Arity, Constructor, File, Line) :-
    calls(Caller, Arity, new(Constructor, _ArgCount), File, Line),
    atom_codes(Constructor, [C | _]),
    atom_codes(a, [Lo]), atom_codes(z, [Hi]),
    C >= Lo, C =< Hi.

all_lowercase_constructors(Triples) :-
    findall(Constructor-File-Line, lowercase_constructor(_C, _A, Constructor, File, Line), Raw),
    sort(Raw, Triples).

%% --- Imports and exports, on top of import_decl/4 + export_decl/4 (+ var_decl/6's new 'import' Kind) ---

import_decl(none, none, 0) :- fail.
export_decl(none, none, none, 0) :- fail.

%% ESLint no-duplicate-imports: https://eslint.org/docs/latest/rules/no-duplicate-imports
%% The same module path imported more than once in a file.
duplicate_import(Module, File, EarlierLine, LaterLine) :-
    import_decl(Module, File, EarlierLine),
    import_decl(Module, File, LaterLine),
    EarlierLine < LaterLine.

all_duplicate_imports(Triples) :-
    findall(Module-File-Line, duplicate_import(Module, File, _E, Line), Raw),
    sort(Raw, Triples).

%% ESLint no-restricted-imports: https://eslint.org/docs/latest/rules/no-restricted-imports
%% A project-banned import — edit restricted_module/1 for this project's
%% own conventions.
restricted_module(moment).
restricted_module(lodash).

restricted_import(Module, File, Line) :-
    import_decl(Module, File, Line),
    restricted_module(Module).

all_restricted_imports(Triples) :-
    findall(Module-File-Line, restricted_import(Module, File, Line), Raw),
    sort(Raw, Triples).

%% ESLint no-restricted-exports: https://eslint.org/docs/latest/rules/no-restricted-exports
%% A project-banned export name — edit restricted_export_name/1.
restricted_export_name('default').

restricted_export(Name, Kind, File, Line) :-
    export_decl(Name, Kind, File, Line),
    restricted_export_name(Name).

all_restricted_exports(Triples) :-
    findall(Name-Kind-File-Line, restricted_export(Name, Kind, File, Line), Raw),
    sort(Raw, Triples).

%% --- Statement/block structure, on top of stmt_block/6 + stmt/6 + last_switch_case/1 + braceless_body/5 + return_stmt/5 ---
%% (TypeScript only)

stmt_block(none, none, 0, none, none, 0) :- fail.
stmt(none, none, 0, none, none, 0) :- fail.
last_switch_case(none) :- fail.
braceless_body(none, 0, none, none, 0) :- fail.
return_stmt(none, 0, none, none, 0) :- fail.

terminator_kind('return_statement').
terminator_kind('throw_statement').
terminator_kind('break_statement').
terminator_kind('continue_statement').

%% ESLint no-empty: https://eslint.org/docs/latest/rules/no-empty
%% A real {} block with zero statements (switch cases excluded — see
%% no_fallthrough_case/5, which allows an empty case to stack).
no_empty_block(BlockId, Fun, Arity, File, Line) :-
    stmt_block(BlockId, Fun, Arity, block, File, Line),
    \+ stmt(_, BlockId, _, _, _, _).

all_no_empty_blocks(Triples) :-
    findall(Fun-Arity-File-Line, no_empty_block(_BlockId, Fun, Arity, File, Line), Raw),
    sort(Raw, Triples).

%% ESLint no-unreachable: https://eslint.org/docs/latest/rules/no-unreachable
%% A statement after a terminator (return/throw/break/continue) in the same block.
unreachable_stmt(Id, BlockId, File, Line) :-
    stmt(_TermId, BlockId, TermIndex, TermKind, _, _),
    terminator_kind(TermKind),
    stmt(Id, BlockId, Index, _Kind, File, Line),
    Index > TermIndex.

all_unreachable_stmts(Triples) :-
    findall(File-Line, unreachable_stmt(_Id, _BlockId, File, Line), Raw),
    sort(Raw, Triples).

%% ESLint no-fallthrough: https://eslint.org/docs/latest/rules/no-fallthrough
%% A non-last, non-empty switch case whose last statement isn't a terminator.
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

%% ESLint curly: https://eslint.org/docs/latest/rules/curly
%% An if/else/for/while whose body is a single bare statement, not a real block.
curly_violation(Fun, Arity, Kind, File, Line) :-
    braceless_body(Fun, Arity, Kind, File, Line).

all_curly_violations(Triples) :-
    findall(Fun-Arity-Kind-File-Line, curly_violation(Fun, Arity, Kind, File, Line), Raw),
    sort(Raw, Triples).

%% ESLint consistent-return: https://eslint.org/docs/latest/rules/consistent-return
%% A function with at least one value-returning `return` and at least one bare one.
inconsistent_return(Fun, Arity, File) :-
    return_stmt(Fun, Arity, true, File, _),
    return_stmt(Fun, Arity, false, File, _).

all_inconsistent_returns(Triples) :-
    findall(Fun-Arity-File, inconsistent_return(Fun, Arity, File), Raw),
    sort(Raw, Triples).

%% --- JSDoc tags, on top of doc_tag/8 (ts_extract_jsdoc.erl via
%% ts_extract_typescript.erl's docs/4; TypeScript-only, and only for a
%% real `/** */` doc comment, never a plain `//`-run or tag-less block) ---

%% Sentinel: keeps doc_tag/8 defined so a tree with no JSDoc-tagged
%% comments at all (or no TypeScript) fails cleanly instead of raising
%% existence_error, same convention as branch/5, export/4, etc. above.
doc_tag(none, 0, none, none, none, none, none, 0) :- fail.

%% A documented parameter/property: one @param/@prop/@property tag that
%% actually named something (Name \= none rules out a malformed tag with
%% no name position at all, which shouldn't occur for these three tag
%% names in practice but costs nothing to guard).
param_doc(Fun, Arity, Name, Type, Description, File) :-
    doc_tag(Fun, Arity, TagName, Type, Name, Description, File, _Line),
    member(TagName, ['@param', '@prop', '@property']),
    Name \= none.

all_param_docs(Rows) :-
    findall(Fun-Arity-Name-Type-Description-File,
            param_doc(Fun, Arity, Name, Type, Description, File), Raw),
    sort(Raw, Rows).

%% A documented function (real doc/5 comment) with at least one
%% value-returning `return` (return_stmt/5's HasValue=true) but no
%% @return/@returns tag anywhere in that same comment — catches a doc
%% comment that never mentioned what the function returns, or one whose
%% `@returns` fell out of sync after a bare `return;` grew a value.
%% `@return` and `@returns` are both real, common spellings (see
%% tag_name_with_type in tree-sitter-jsdoc's own grammar) — checked
%% independently, not normalized to one atom, same policy as every other
%% tag name doc_tag/8 itself leaves un-normalized.
missing_return_doc(Fun, Arity, File) :-
    doc(Fun, Arity, File, _DocLine, _Text),
    return_stmt(Fun, Arity, true, File, _),
    \+ doc_tag(Fun, Arity, '@returns', _, _, _, File, _),
    \+ doc_tag(Fun, Arity, '@return', _, _, _, File, _).

all_missing_return_docs(Triples) :-
    findall(Fun-Arity-File, missing_return_doc(Fun, Arity, File), Raw),
    sort(Raw, Triples).

%% --- Newly-provable ESLint rules, on top of the fact families above (no new extraction) ---

%% ESLint no-const-assign: https://eslint.org/docs/latest/rules/no-const-assign
%% A `const` with a later write/read_write reference resolving to it.
%% Reported at the offending reference's own site, not the declaration's.
no_const_assign(RefId, Name, File, Line) :-
    var_decl(DeclId, Name, const, _Scope, _DeclFile, _DeclLine),
    resolves_to(RefId, DeclId),
    var_ref(RefId, _, _, RK, File, Line),
    member(RK, [write, read_write]).

all_no_const_assigns(Triples) :-
    findall(Name-File-Line, no_const_assign(_RefId, Name, File, Line), Raw),
    sort(Raw, Triples).

%% ESLint no-unassigned-vars: https://eslint.org/docs/latest/rules/no-unassigned-vars
%% A var/let with no initializer, read somewhere, but never written
%% anywhere (stays undefined forever).
unassigned_var(Id, Name, File, Line) :-
    var_decl(Id, Name, Kind, _Scope, File, Line),
    member(Kind, [var, 'let']),
    \+ var_decl_initialized(Id),
    resolves_to(RefId, Id),
    var_ref(RefId, _, _, read, _, _),
    \+ (resolves_to(RefId2, Id), var_ref(RefId2, _, _, RK2, _, _), member(RK2, [write, read_write])).

all_unassigned_vars(Triples) :-
    findall(Name-File-Line, unassigned_var(_Id, Name, File, Line), Raw),
    sort(Raw, Triples).

%% ESLint no-case-declarations: https://eslint.org/docs/latest/rules/no-case-declarations
%% A lexical/function/class declaration directly inside a
%% switch_case/switch_default (no block of its own).
case_declaration(StmtId, Fun, Arity, File, Line) :-
    stmt_block(BlockId, Fun, Arity, Kind, File, _BLine),
    member(Kind, [switch_case, switch_default]),
    stmt(StmtId, BlockId, _Index, DeclKind, File, Line),
    member(DeclKind, ['lexical_declaration', 'function_declaration', 'class_declaration']).

all_case_declarations(Triples) :-
    findall(Fun-Arity-File-Line, case_declaration(_StmtId, Fun, Arity, File, Line), Raw),
    sort(Raw, Triples).

%% ESLint no-debugger: https://eslint.org/docs/latest/rules/no-debugger
%% A `debugger;` statement.
no_debugger(Id, File, Line) :- stmt(Id, _BlockId, _Index, 'debugger_statement', File, Line).

all_no_debuggers(Pairs) :-
    findall(File-Line, no_debugger(_Id, File, Line), Raw),
    sort(Raw, Pairs).

%% ESLint no-continue: https://eslint.org/docs/latest/rules/no-continue
%% A `continue` statement.
no_continue(Id, File, Line) :- stmt(Id, _BlockId, _Index, 'continue_statement', File, Line).

all_no_continues(Pairs) :-
    findall(File-Line, no_continue(_Id, File, Line), Raw),
    sort(Raw, Pairs).

%% ESLint no-with: https://eslint.org/docs/latest/rules/no-with
%% A `with (...) { ... }` statement.
no_with(Id, File, Line) :- stmt(Id, _BlockId, _Index, 'with_statement', File, Line).

all_no_withs(Pairs) :-
    findall(File-Line, no_with(_Id, File, Line), Raw),
    sort(Raw, Pairs).

%% ESLint no-new-native-nonconstructor: https://eslint.org/docs/latest/rules/no-new-native-nonconstructor
%% `new Symbol(...)`/`new BigInt(...)`, both callable but not constructible.
%% Same banned-constructor-list shape as no_new_wrapper/5.
no_new_native_nonconstructor(Caller, Arity, Constructor, File, Line) :-
    calls(Caller, Arity, new(Constructor, _ArgCount), File, Line),
    member(Constructor, ['Symbol', 'BigInt']).

all_no_new_native_nonconstructors(Triples) :-
    findall(Constructor-File-Line, no_new_native_nonconstructor(_C, _A, Constructor, File, Line), Raw),
    sort(Raw, Triples).

%% ESLint init-declarations: https://eslint.org/docs/latest/rules/init-declarations
%% (default "always" mode) — a var/let with no initializer.
uninitialized_declaration(Id, Name, Kind, File, Line) :-
    var_decl(Id, Name, Kind, _Scope, File, Line),
    member(Kind, [var, 'let']),
    \+ var_decl_initialized(Id).

all_uninitialized_declarations(Triples) :-
    findall(Name-Kind-File-Line, uninitialized_declaration(_Id, Name, Kind, File, Line), Raw),
    sort(Raw, Triples).

%% ESLint no-param-reassign: https://eslint.org/docs/latest/rules/no-param-reassign
%% A parameter with a later write/read_write reference resolving to it.
%% Reported at the offending reference's own site.
param_reassign(RefId, Name, File, Line) :-
    var_decl(DeclId, Name, param, _Scope, _DeclFile, _DeclLine),
    resolves_to(RefId, DeclId),
    var_ref(RefId, _, _, RK, File, Line),
    member(RK, [write, read_write]).

all_param_reassigns(Triples) :-
    findall(Name-File-Line, param_reassign(_RefId, Name, File, Line), Raw),
    sort(Raw, Triples).

%% ESLint no-var: https://eslint.org/docs/latest/rules/no-var
%% A `var` declaration.
no_var(Id, Name, File, Line) :- var_decl(Id, Name, var, _Scope, File, Line).

all_no_vars(Triples) :-
    findall(Name-File-Line, no_var(_Id, Name, File, Line), Raw),
    sort(Raw, Triples).

%% ESLint no-void: https://eslint.org/docs/latest/rules/no-void
%% A `void` unary operator.
void_operator(Id, Fun, Arity, File, Line) :-
    expr(Id, Fun, Arity, unary, File, Line),
    expr_operator(Id, 'void').

all_void_operators(Triples) :-
    findall(Fun-Arity-File, void_operator(_Id, Fun, Arity, File, _Line), Raw),
    sort(Raw, Triples).

%% ESLint no-delete-var: https://eslint.org/docs/latest/rules/no-delete-var
%% `delete` on a bare identifier (not a property: expr_operand's ChildId
%% only unifies with expr_ref/6 for a bare name).
delete_var(Id, Name, Fun, Arity, File, Line) :-
    expr(Id, Fun, Arity, unary, File, Line),
    expr_operator(Id, 'delete'),
    expr_operand(Id, operand, R),
    expr_ref(R, _, _, Name, _, _).

all_delete_vars(Triples) :-
    findall(Name-Fun-Arity-File, delete_var(_Id, Name, Fun, Arity, File, _Line), Raw),
    sort(Raw, Triples).

%% ESLint max-statements: https://eslint.org/docs/latest/rules/max-statements
%% stmt/6 has no Fun/Arity of its own, so groups are found by joining
%% through stmt_block/6 (the same "bind the grouping key first" fix
%% file_define_count/2 and real_complexity/4 already need).
%% Fun \= undefined excludes the caller-attribution fallback (code with no
%% named enclosing function — an anonymous `describe`/`it` callback body,
%% top-level module statements): every such block in one file shares the
%% same undefined/undefined "group," so without this guard they'd all get
%% merged into one bogus, wildly inflated count instead of being left out
%% (the same coverage gap real_complexity/4 already has for the same
%% functions, since they have no defines/5 fact either — not a new
%% limitation, just one this predicate would otherwise mask as a false
%% violation instead of a silent omission).
statement_count(Fun, Arity, File, Count) :-
    findall(F-A-Fl, ( stmt_block(_, F, A, _, Fl, _), F \= undefined ), AllGroupsRaw),
    sort(AllGroupsRaw, Groups),
    member(Fun-Arity-File, Groups),
    findall(Id,
        ( stmt_block(BlockId, Fun, Arity, _, File, _),
          stmt(Id, BlockId, _, _, _, _) ),
        Ids),
    length(Ids, Count).

too_many_statements(Fun, Arity, File, Count) :-
    statement_count(Fun, Arity, File, Count),
    Count > 10.

all_too_many_statements(Ranked) :-
    findall(Count-Fun-Arity-File, too_many_statements(Fun, Arity, File, Count), Raw),
    sort(Raw, Sorted),
    reverse(Sorted, Ranked).

%% --- Round 2 of previously-"feasible" ESLint rules, now written ---
%%
%% Two of these (invalid_typeof/5, no_implicit_coercion/5) are narrower
%% than ESLint's own rule: erlog's Prolog reader has NO literal syntax for
%% a binary at all — confirmed empirically, `X = <<"">>` is a hard parse
%% error (`{1,erlog_parse,{operator_expected,[]}}`), and neither `''` nor
%% `""` unifies with a real string-literal Value (which the extractor
%% stores as an Erlang binary — see docs/prolog-schema.md and the
%% dialect notes in this project's own agent-facing docs). So a rule that
%% needs to compare a literal's actual string CONTENT against a fixed
%% constant (a type-name set, an empty string) cannot be written here at
%% all — each such case below is scoped down to what's left provable
%% rather than papered over with a wrong match.

%% Sentinel: keeps comment/3 defined so a tree with zero comments (proven
%% live: a real TS file with no `//`/`/* */` at all) fails cleanly instead
%% of raising existence_error, same convention as branch/5, export/4, etc.
%% above. This was a LATENT gap in undocumented_comment/3 too (already in
%% this library, above) — it just never hit a fixture with zero comment
%% facts until inline_comment/3 below did.
comment(none, 0, none) :- fail.

%% ESLint no-compare-neg-zero: https://eslint.org/docs/latest/rules/no-compare-neg-zero
%% `x === -0` (or ==/!=/!==) — a negative literal is a unary '-' wrapping a
%% positive literal.number 0 (confirmed against a real TS parse: `x===-0`
%% is expr(unary,'-') -> expr_operand(operand,_) -> literal(number,0)),
%% exactly the shape yoda_condition/5 already establishes. LitKind varies
%% by language — TS/JS use 'number' for everything, Erlang splits it into
%% 'integer'/'float' (confirmed against a real Erlang parse) — so all
%% three are checked, with `=:=` for numeric (not term) equality to 0.
no_compare_neg_zero(Id, Fun, Arity, File, Line) :-
    expr(Id, Fun, Arity, binary, File, Line),
    expr_operator(Id, Op),
    member(Op, ['==', '===', '!=', '!==']),
    ( expr_operand(Id, left, Side) ; expr_operand(Id, right, Side) ),
    expr(Side, _, _, unary, _, _),
    expr_operator(Side, '-'),
    expr_operand(Side, operand, LitId),
    literal(LitId, _, _, LitKind, Value, _, _, _),
    member(LitKind, [number, integer, float]),
    Value =:= 0.

all_no_compare_neg_zeros(Triples) :-
    findall(Fun-Arity-File, no_compare_neg_zero(_Id, Fun, Arity, File, _Line), Raw),
    sort(Raw, Triples).

%% ESLint no-prototype-builtins: https://eslint.org/docs/latest/rules/no-prototype-builtins
%% obj.hasOwnProperty(...)/isPrototypeOf(...)/propertyIsEnumerable(...)
%% called directly on an arbitrary object — Method-only match (unlike
%% banned_call/4, this isn't tied to one specific Object, since any object
%% can carry these inherited Object.prototype methods).
no_prototype_builtin(Caller, Method, File, Line) :-
    calls(Caller, _CallerArity, member(_Object, Method, _ArgCount), File, Line),
    member(Method, [hasOwnProperty, isPrototypeOf, propertyIsEnumerable]).

all_no_prototype_builtins(Triples) :-
    findall(Caller-Method-File, no_prototype_builtin(Caller, Method, File, _Line), Raw),
    sort(Raw, Triples).

%% ESLint no-unsafe-negation: https://eslint.org/docs/latest/rules/no-unsafe-negation
%% `!x < y` (parses as `(!x) < y`, almost always a typo for `!(x < y)`) —
%% the left operand of a relational comparison is itself a `!` unary expr.
%% Scoped to the numeric relational operators actually in this vocabulary
%% (in/instanceof aren't extracted as expr_operator values).
no_unsafe_negation(Id, Fun, Arity, File, Line) :-
    expr(Id, Fun, Arity, binary, File, Line),
    expr_operator(Id, Op),
    member(Op, ['<', '>', '<=', '>=', '=<']),
    expr_operand(Id, left, Side),
    expr(Side, _, _, unary, _, _),
    expr_operator(Side, '!').

all_no_unsafe_negations(Triples) :-
    findall(Fun-Arity-File, no_unsafe_negation(_Id, Fun, Arity, File, _Line), Raw),
    sort(Raw, Triples).

%% ESLint use-isnan: https://eslint.org/docs/latest/rules/use-isnan
%% `x == NaN` / `x === NaN` — NaN is a bare global, so it comes back as an
%% expr_ref/6 (not a literal/7) on one side of the comparison; a direct
%% comparison against NaN is always wrong (NaN is never == itself).
use_isnan(Id, Fun, Arity, File, Line) :-
    expr(Id, Fun, Arity, binary, File, Line),
    expr_operator(Id, Op),
    member(Op, ['==', '===', '!=', '!==']),
    ( expr_operand(Id, left, Side) ; expr_operand(Id, right, Side) ),
    expr_ref(Side, _, _, 'NaN', _, _).

all_use_isnans(Triples) :-
    findall(Fun-Arity-File, use_isnan(_Id, Fun, Arity, File, _Line), Raw),
    sort(Raw, Triples).

%% ESLint valid-typeof: https://eslint.org/docs/latest/rules/valid-typeof
%% `typeof x === <something not a string>` — e.g. `typeof x === 42` or
%% `typeof x === true`. See the binary-literal note at the top of this
%% section: this catches the always-wrong case (a non-string literal on
%% the other side) but NOT a misspelled valid type name
%% (`typeof x === "strnig"`), which needs string-content comparison this
%% dialect cannot express.
invalid_typeof(Id, Fun, Arity, File, Line) :-
    expr(Id, Fun, Arity, binary, File, Line),
    expr_operator(Id, Op),
    member(Op, ['==', '===', '!=', '!==']),
    ( expr_operand(Id, left, TSide), expr_operand(Id, right, LitSide)
    ; expr_operand(Id, right, TSide), expr_operand(Id, left, LitSide)
    ),
    expr(TSide, _, _, unary, _, _),
    expr_operator(TSide, typeof),
    literal(LitSide, _, _, LitKind, _, _, _, _),
    LitKind \= string.

all_invalid_typeofs(Triples) :-
    findall(Fun-Arity-File, invalid_typeof(_Id, Fun, Arity, File, _Line), Raw),
    sort(Raw, Triples).

%% ESLint camelcase: https://eslint.org/docs/latest/rules/camelcase
%% A defines/5 name containing an underscore — same atom_codes technique as
%% short_name/4. NOTE: this is a JS/TS style convention; Erlang's own
%% idiomatic naming is snake_case, so running this over a mixed-language
%% tree flags every ordinary Erlang function name too — scope the query to
%% specific Files yourself if mixing languages.
not_camel_case(Fun, Arity, File, Line) :-
    defines(Fun, Arity, _, File, Line),
    atom_codes(Fun, Codes),
    atom_codes('_', [U]),
    member(U, Codes).

all_not_camel_cases(Triples) :-
    findall(Fun-Arity-File, not_camel_case(Fun, Arity, File, _Line), Raw),
    sort(Raw, Triples).

%% ESLint eqeqeq: https://eslint.org/docs/latest/rules/eqeqeq
%% Require `===`/`!==` over `==`/`!=`. NOTE: expr_operator/2's '==' is
%% shared vocabulary with Erlang's own (semantically different, often
%% idiomatic) `==` — `!=` alone is unambiguous (Erlang's inequality
%% operator is `/=`, never `!=`), but including `==` will over-flag
%% ordinary Erlang comparisons on a mixed-language tree; scope by File
%% yourself if mixing languages.
loose_equality(Id, Fun, Arity, File, Line) :-
    expr(Id, Fun, Arity, binary, File, Line),
    expr_operator(Id, Op),
    member(Op, ['==', '!=']).

all_loose_equalities(Triples) :-
    findall(Fun-Arity-File, loose_equality(_Id, Fun, Arity, File, _Line), Raw),
    sort(Raw, Triples).

%% ESLint id-denylist: https://eslint.org/docs/latest/rules/id-denylist
%% A defines/5 name on a project-specific denylist — edit
%% denylisted_identifier/1 for this project's own conventions, same shape
%% as allow_short_name/1 and restricted_module/1.
denylisted_identifier(data).
denylisted_identifier(e).
denylisted_identifier(err).
denylisted_identifier(cb).

id_denylisted(Fun, Arity, File, Line) :-
    defines(Fun, Arity, _, File, Line),
    denylisted_identifier(Fun).

all_id_denylisted(Triples) :-
    findall(Fun-Arity-File, id_denylisted(Fun, Arity, File, _Line), Raw),
    sort(Raw, Triples).

%% ESLint max-lines: https://eslint.org/docs/latest/rules/max-lines
%% Approximated via the highest defines/5 or calls/5 Line seen in a file —
%% same count-based-proxy spirit as god_file/2, not an exact source line
%% count (doc/comment/branch lines aren't included, so a file whose tail is
%% pure comments is slightly undercounted). Default ESLint threshold (300).
file_max_line(File, MaxLine) :-
    findall(F, defines(_, _, _, F, _), DFiles),
    findall(F2, calls(_, _, _, F2, _), CFiles),
    append(DFiles, CFiles, AllFiles),
    sort(AllFiles, Files),
    member(File, Files),
    findall(L, defines(_, _, _, File, L), DLines),
    findall(L2, calls(_, _, _, File, L2), CLines),
    append(DLines, CLines, AllLines),
    sort(AllLines, SortedLines),
    reverse(SortedLines, [MaxLine | _]).

too_many_lines(File, MaxLine) :-
    file_max_line(File, MaxLine),
    MaxLine > 300.

all_too_many_lines(Ranked) :-
    findall(MaxLine-File, too_many_lines(File, MaxLine), Raw),
    sort(Raw, Sorted),
    reverse(Sorted, Ranked).

%% ESLint no-alert: https://eslint.org/docs/latest/rules/no-alert
%% A direct call to alert/confirm/prompt — the banned-local-call sibling to
%% banned_call/4 (which only matches member(...) calls).
no_alert(Caller, Arity, Name, File, Line) :-
    calls(Caller, Arity, local(Name, _ArgCount), File, Line),
    member(Name, [alert, confirm, prompt]).

all_no_alerts(Triples) :-
    findall(Name-File-Line, no_alert(_C, _A, Name, File, Line), Raw),
    sort(Raw, Triples).

%% ESLint no-array-constructor: https://eslint.org/docs/latest/rules/no-array-constructor
%% `Array(...)`/`new Array(...)` with 0 or 2+ args — ArgCount is already
%% tracked, so the one-arg "array of length N" idiom (`new Array(5)`) is
%% correctly exempted, the same precision ESLint's own rule has.
no_array_constructor(Caller, Arity, File, Line) :-
    ( calls(Caller, Arity, new('Array', ArgCount), File, Line)
    ; calls(Caller, Arity, local('Array', ArgCount), File, Line)
    ),
    ArgCount \= 1.

all_no_array_constructors(Triples) :-
    findall(File-Line, no_array_constructor(_C, _A, File, Line), Raw),
    sort(Raw, Triples).

%% ESLint no-bitwise: https://eslint.org/docs/latest/rules/no-bitwise
%% Verified against a real TS parse: &,|,^,~,<<,>>,>>> are exactly the
%% expr_operator/2 atoms produced (no new extraction needed for TS/JS).
%% Erlang's own bitwise operators (band/bor/bxor/bsl/bsr/bnot) are NOT
%% covered — a tree-sitter query addition, out of scope for a rules-only
%% change.
no_bitwise(Id, Fun, Arity, File, Line) :-
    expr(Id, Fun, Arity, Kind, File, Line),
    member(Kind, [binary, unary]),
    expr_operator(Id, Op),
    member(Op, ['&', '|', '^', '~', '<<', '>>', '>>>']).

all_no_bitwises(Triples) :-
    findall(Fun-Arity-File, no_bitwise(_Id, Fun, Arity, File, _Line), Raw),
    sort(Raw, Triples).

%% ESLint no-eq-null: https://eslint.org/docs/latest/rules/no-eq-null
%% `x == null` / `x != null` — verified against a real TS parse: a `null`
%% literal is literal(Id,_,_,null,null,_,_); LitKind alone (not Value) is
%% enough to identify it, so this needs no binary-content comparison at all.
no_eq_null(Id, Fun, Arity, File, Line) :-
    expr(Id, Fun, Arity, binary, File, Line),
    expr_operator(Id, Op),
    member(Op, ['==', '!=']),
    ( expr_operand(Id, left, Side) ; expr_operand(Id, right, Side) ),
    literal(Side, _, _, null, _, _, _, _).

all_no_eq_nulls(Triples) :-
    findall(Fun-Arity-File, no_eq_null(_Id, Fun, Arity, File, _Line), Raw),
    sort(Raw, Triples).

%% ESLint no-eval: https://eslint.org/docs/latest/rules/no-eval
%% A direct call to `eval(...)`.
no_eval(Caller, Arity, File, Line) :-
    calls(Caller, Arity, local(eval, _ArgCount), File, Line).

all_no_evals(Pairs) :-
    findall(File-Line, no_eval(_C, _A, File, Line), Raw),
    sort(Raw, Pairs).

%% ESLint no-implicit-coercion: https://eslint.org/docs/latest/rules/no-implicit-coercion
%% `!!x` (double negation), `~~x` (double bitwise-not), and a bare unary
%% `+x` used for numeric coercion. NARROWER than ESLint's own rule: the
%% `"" + x` string-coercion shape needs comparing a literal's Value against
%% an empty-string constant, which this dialect cannot express (see the
%% binary-literal note at the top of this section) — omitted rather than
%% approximated into false positives on ordinary string concatenation.
no_implicit_coercion(Id, Fun, Arity, File, Line) :-
    expr(Id, Fun, Arity, unary, File, Line),
    expr_operator(Id, '!'),
    expr_operand(Id, operand, Inner),
    expr(Inner, _, _, unary, _, _),
    expr_operator(Inner, '!').
no_implicit_coercion(Id, Fun, Arity, File, Line) :-
    expr(Id, Fun, Arity, unary, File, Line),
    expr_operator(Id, '~'),
    expr_operand(Id, operand, Inner),
    expr(Inner, _, _, unary, _, _),
    expr_operator(Inner, '~').
no_implicit_coercion(Id, Fun, Arity, File, Line) :-
    expr(Id, Fun, Arity, unary, File, Line),
    expr_operator(Id, '+').

all_no_implicit_coercions(Triples) :-
    findall(Fun-Arity-File, no_implicit_coercion(_Id, Fun, Arity, File, _Line), Raw),
    sort(Raw, Triples).

%% ESLint no-implied-eval: https://eslint.org/docs/latest/rules/no-implied-eval
%% A direct call to setTimeout/setInterval — ESLint's real rule only flags
%% these when given a string argument (compiled as code, same risk as
%% eval); ArgCount alone can't distinguish a string arg from a function
%% arg, so this over-approximates by flagging every call regardless of
%% argument type.
no_implied_eval(Caller, Arity, Name, File, Line) :-
    calls(Caller, Arity, local(Name, _ArgCount), File, Line),
    member(Name, [setTimeout, setInterval]).

all_no_implied_evals(Triples) :-
    findall(Name-File-Line, no_implied_eval(_C, _A, Name, File, Line), Raw),
    sort(Raw, Triples).

%% ESLint no-inline-comments: https://eslint.org/docs/latest/rules/no-inline-comments
%% Approximated: a comment/3 sharing its exact File+Line with a calls/5 or
%% defines/5 fact — a real inline (same-line) comment almost always sits on
%% a line that also has code creating one of those two fact kinds.
inline_comment(File, Line, Text) :-
    comment(File, Line, Text),
    ( calls(_, _, _, File, Line) ; defines(_, _, _, File, Line) ).

all_inline_comments(Triples) :-
    findall(File-Line-Text, inline_comment(File, Line, Text), Raw),
    sort(Raw, Triples).

%% ESLint no-magic-numbers: https://eslint.org/docs/latest/rules/no-magic-numbers
%% A numeric literal not in a small allowlist — edit magic_number_allowed/1
%% for this project's own conventions (ESLint's own default allowlist is
%% just 0 and 1; -1 added here as a second common sentinel value). LitKind
%% varies by language — TS/JS use 'number' for everything, Erlang splits
%% it into 'integer'/'float' (confirmed against a real Erlang parse: a
%% source file with zero LitKind=number facts nonetheless had `42` as
%% LitKind=integer and `3.5` as LitKind=float) — all three are checked,
%% with both integer and float allowlist spellings so 1 and 1.0 are each
%% recognized on their own representation (Prolog's exact-term match
%% doesn't unify them with each other).
magic_number_allowed(0).
magic_number_allowed(1).
magic_number_allowed(-1).
magic_number_allowed(0.0).
magic_number_allowed(1.0).
magic_number_allowed(-1.0).

magic_number(Id, Fun, Arity, File, Line) :-
    literal(Id, Fun, Arity, LitKind, Value, File, Line, _RawText),
    member(LitKind, [number, integer, float]),
    \+ magic_number_allowed(Value).

all_magic_numbers(Triples) :-
    findall(Fun-Arity-File, magic_number(_Id, Fun, Arity, File, _Line), Raw),
    sort(Raw, Triples).

%% ESLint no-restricted-globals: https://eslint.org/docs/latest/rules/no-restricted-globals
%% A direct call to a project-banned global function — edit
%% restricted_global/1 for this project's own conventions, same
%% banned-local-call shape as no_alert/5.
restricted_global(event).
restricted_global(name).
restricted_global(history).

no_restricted_global(Caller, Arity, Name, File, Line) :-
    calls(Caller, Arity, local(Name, _ArgCount), File, Line),
    restricted_global(Name).

all_no_restricted_globals(Triples) :-
    findall(Name-File-Line, no_restricted_global(_C, _A, Name, File, Line), Raw),
    sort(Raw, Triples).

%% ESLint no-ternary: https://eslint.org/docs/latest/rules/no-ternary
%% branch/5 already has Kind=ternary for every conditional expression —
%% this just names that existing fact as its own rule.
no_ternary(Fun, Arity, File, Line) :-
    branch(Fun, Arity, ternary, File, Line).

all_no_ternaries(Triples) :-
    findall(Fun-Arity-File, no_ternary(Fun, Arity, File, _Line), Raw),
    sort(Raw, Triples).

%% ESLint no-underscore-dangle: https://eslint.org/docs/latest/rules/no-underscore-dangle
%% A defines/5 name starting or ending with `_` — same atom_codes
%% technique as short_name/4 and not_camel_case/4.
dangling_underscore(Fun) :-
    atom_codes(Fun, Codes),
    Codes \= [],
    atom_codes('_', [U]),
    ( Codes = [U | _]
    ; reverse(Codes, [U | _])
    ).

no_underscore_dangle(Fun, Arity, File, Line) :-
    defines(Fun, Arity, _, File, Line),
    dangling_underscore(Fun).

all_no_underscore_dangles(Triples) :-
    findall(Fun-Arity-File, no_underscore_dangle(Fun, Arity, File, _Line), Raw),
    sort(Raw, Triples).

%% ESLint radix: https://eslint.org/docs/latest/rules/radix
%% `parseInt(x)` with no radix argument — ArgCount already tracked.
radix_missing(Caller, Arity, File, Line) :-
    calls(Caller, Arity, local(parseInt, 1), File, Line).

all_radix_missings(Pairs) :-
    findall(File-Line, radix_missing(_C, _A, File, Line), Raw),
    sort(Raw, Pairs).

%% ESLint symbol-description: https://eslint.org/docs/latest/rules/symbol-description
%% `Symbol()` with no description argument — ArgCount already tracked, the
%% same shape as radix_missing/4.
symbol_description_missing(Caller, Arity, File, Line) :-
    calls(Caller, Arity, local('Symbol', 0), File, Line).

all_symbol_description_missings(Pairs) :-
    findall(File-Line, symbol_description_missing(_C, _A, File, Line), Raw),
    sort(Raw, Pairs).

%% --- await/yield, on top of async_function/4 + generator_function/4 +
%% await_expr/4 + yield_expr/4 (TypeScript only) ---
async_function(none, 0, none, 0) :- fail.
generator_function(none, 0, none, 0) :- fail.
await_expr(none, 0, none, 0) :- fail.
yield_expr(none, 0, none, 0) :- fail.

%% ESLint require-await: https://eslint.org/docs/latest/rules/require-await
%% An async function with no await_expr anywhere inside its own body —
%% same (Fun, Arity, File) attribution await_expr/4 already carries, no
%% new join needed.
require_await(Fun, Arity, File, Line) :-
    async_function(Fun, Arity, File, Line),
    \+ await_expr(Fun, Arity, File, _Line).

all_require_awaits(Triples) :-
    findall(Fun-Arity-File, require_await(Fun, Arity, File, _Line), Raw),
    sort(Raw, Triples).

%% ESLint require-yield: https://eslint.org/docs/latest/rules/require-yield
%% A generator_function_declaration with no yield_expr anywhere inside its
%% own body — same shape as require_await/4 above.
require_yield(Fun, Arity, File, Line) :-
    generator_function(Fun, Arity, File, Line),
    \+ yield_expr(Fun, Arity, File, _Line).

all_require_yields(Triples) :-
    findall(Fun-Arity-File, require_yield(Fun, Arity, File, _Line), Raw),
    sort(Raw, Triples).

%% ESLint no-sequences: https://eslint.org/docs/latest/rules/no-sequences
%% expr/6's Kind=sequence directly names the comma operator.
no_sequences(Fun, Arity, File, Line) :-
    expr(_Id, Fun, Arity, sequence, File, Line).

all_no_sequences(Triples) :-
    findall(Fun-Arity-File, no_sequences(Fun, Arity, File, _Line), Raw),
    sort(Raw, Triples).

%% no-sparse-arrays is NOT built, deliberately: a hole in `[1, , 3]` is
%% represented by tree-sitter as an absence between two anonymous comma
%% tokens, not a node of its own (confirmed against
%% tree-sitter-typescript's own node-types.json — "array"'s only children
%% are named "expression"/"spread_element", no elision/hole type at all).
%% Detecting it needs RAW (not named-only) child access — symbolic_ts's
%% NIF wrapper (c_src/symbolic_ts_nif.c) exports node_named_child/2 and
%% node_named_child_count/1 only, no node_child/2 or node_child_count/1 —
%% confirmed by probing a real `[1, , 3]` parse. Closing this needs a new
%% NIF primitive and a rebuild, not a query — a different risk class than
%% everything else in this ledger bucket, so it's out of this pass.

%% --- Property reads, on top of member_read/6 (TypeScript only) ---
member_read(none, 0, none, none, none, 0) :- fail.

%% ESLint no-caller: https://eslint.org/docs/latest/rules/no-caller
no_caller(Fun, Arity, File, Line) :-
    member_read(Fun, Arity, _Obj, callee, File, Line).
no_caller(Fun, Arity, File, Line) :-
    member_read(Fun, Arity, _Obj, caller, File, Line).

all_no_callers(Triples) :-
    findall(Fun-Arity-File, no_caller(Fun, Arity, File, _Line), Raw),
    sort(Raw, Triples).

%% ESLint no-iterator: https://eslint.org/docs/latest/rules/no-iterator
no_iterator(Fun, Arity, File, Line) :-
    member_read(Fun, Arity, _Obj, '__iterator__', File, Line).

all_no_iterators(Triples) :-
    findall(Fun-Arity-File, no_iterator(Fun, Arity, File, _Line), Raw),
    sort(Raw, Triples).

%% ESLint no-proto: https://eslint.org/docs/latest/rules/no-proto
no_proto(Fun, Arity, File, Line) :-
    member_read(Fun, Arity, _Obj, '__proto__', File, Line).

all_no_protos(Triples) :-
    findall(Fun-Arity-File, no_proto(Fun, Arity, File, _Line), Raw),
    sort(Raw, Triples).

%% --- Labels, on top of label_stmt/5 + label_ref/6 (TypeScript only) ---
label_stmt(none, 0, none, none, 0) :- fail.
label_ref(none, 0, none, none, none, 0) :- fail.

%% ESLint no-labels: https://eslint.org/docs/latest/rules/no-labels
no_labels(Fun, Arity, File, Line) :-
    label_stmt(Fun, Arity, _Name, File, Line).

all_no_labels(Triples) :-
    findall(Fun-Arity-File, no_labels(Fun, Arity, File, _Line), Raw),
    sort(Raw, Triples).

%% ESLint no-unused-labels: https://eslint.org/docs/latest/rules/no-unused-labels
%% Scoped to the SAME (Fun, Arity, File) as the label's own declaration —
%% labels are function-local in JS, so a break/continue in a different
%% function reusing the same label name is a different label entirely,
%% not a use of this one.
no_unused_labels(Fun, Arity, File, Line) :-
    label_stmt(Fun, Arity, Name, File, Line),
    \+ label_ref(Fun, Arity, Name, _Kind, File, _RefLine).

all_no_unused_labels(Triples) :-
    findall(Fun-Arity-File, no_unused_labels(Fun, Arity, File, _Line), Raw),
    sort(Raw, Triples).

%% ESLint no-label-var: https://eslint.org/docs/latest/rules/no-label-var
%% A label sharing a name with a variable declared anywhere in the same
%% file — approximate (var_decl/6's own Scope isn't consulted here, so a
%% variable declared in a wholly unrelated function of the same file
%% would also trigger this), same "reasonable approximation, documented"
%% policy short_name/4's allow_short_name/1 exemption list already uses.
no_label_var(Fun, Arity, File, Line) :-
    label_stmt(Fun, Arity, Name, File, Line),
    var_decl(_Id, Name, _Kind, _Scope, File, _VarLine).

all_no_label_vars(Triples) :-
    findall(Fun-Arity-File, no_label_var(Fun, Arity, File, _Line), Raw),
    sort(Raw, Triples).

%% no-extra-label is NOT built, deliberately: telling a label
%% "unnecessary" needs knowing it's the label of the NEAREST enclosing
%% loop/switch — i.e. nesting depth, the same statement-block-ownership
%% gap that blocks the Fact Debt Ledger's own "large" bucket (see
%% require-await's sibling comment above). label_stmt/5 alone can't
%% distinguish a label on the nearest loop from one on an outer loop two
%% levels up.

%% ESLint no-useless-concat: https://eslint.org/docs/latest/rules/no-useless-concat
%% `"a" + "b"` — a binary '+' whose BOTH operands are already string
%% literals, foldable at parse time with no variable involved at all.
no_useless_concat(Fun, Arity, File, Line) :-
    expr(Id, Fun, Arity, binary, File, Line),
    expr_operator(Id, '+'),
    expr_operand(Id, left, L), literal(L, _, _, string, _, _, _, _),
    expr_operand(Id, right, R), literal(R, _, _, string, _, _, _, _).

all_no_useless_concats(Triples) :-
    findall(Fun-Arity-File, no_useless_concat(Fun, Arity, File, _Line), Raw),
    sort(Raw, Triples).

%% ESLint prefer-template: https://eslint.org/docs/latest/rules/prefer-template
%% A binary '+' with at least one string-literal operand — string
%% concatenation via `+`, the shape a template literal replaces. A
%% superset of no_useless_concat/4 above (that one requires BOTH sides to
%% be literals); real projects don't enable both at once, so the overlap
%% is intentional, not a bug.
prefer_template(Fun, Arity, File, Line) :-
    expr(Id, Fun, Arity, binary, File, Line),
    expr_operator(Id, '+'),
    ( expr_operand(Id, left, S), literal(S, _, _, string, _, _, _, _)
    ; expr_operand(Id, right, S), literal(S, _, _, string, _, _, _, _)
    ).

all_prefer_templates(Triples) :-
    findall(Fun-Arity-File, prefer_template(Fun, Arity, File, _Line), Raw),
    sort(Raw, Triples).

%% The other 8 rules in the Fact Debt Ledger's "Raw literal source text"
%% bucket are NOT built from literal/8's RawText yet, deliberately:
%% RawText is a Prolog BINARY (same reason literal's own string Value and
%% comment/3's Text already are — see ts_extract_text.erl's to_text/1 doc
%% comment: unbounded length, no atom-table pressure), and erlog has no
%% sub_atom/atom_codes-on-binary — the exact same blocker that already
%% keeps capitalized-comments/no-warning-comments unbuilt. Closing
%% no-octal, no-template-curly-in-string and no-script-url needs a
%% PRECOMPUTED FLAG fact instead (checked once in Erlang, where real
%% string ops exist, over the raw list form BEFORE it's wrapped into a
%% binary) — same "different mechanism" fix as the comment-text bucket,
%% not yet built. no-multi-str, no-nonoctal-decimal-escape,
%% no-octal-escape and no-useless-escape need real per-character
%% escape-sequence classification (which specific `\X` sequence, and
%% whether it's redundant given the surrounding quote style) — also flag
%% work, just more of it. no-loss-of-precision needs comparing the raw
%% digit string's EXACT mathematical value against what it rounds to as
%% an IEEE-754 double — a real numeric algorithm, not a lookup.

%% no-await-in-loop is NOT built yet, deliberately: await_expr/4 only
%% carries (Fun, Arity, File, Line) attribution, the same granularity
%% every other fact family in this schema uses — it doesn't know whether
%% a given await sits specifically inside a loop's own body versus
%% anywhere else in the same function. That needs the statement-block
%% ownership link (branch/loop body -> owning construct), the same
%% cross-cutting gap that also blocks default-case, default-case-last and
%% sort-imports — see the Fact Debt Ledger's "Statement-block ownership
%% link" bucket. Approximating it here (e.g. "await co-occurs with a
%% for/while branch/5 fact in the same function") would produce false
%% positives on any async function that merely CONTAINS both a loop and
%% an unrelated top-level await, so it's left unbuilt rather than wrong.
