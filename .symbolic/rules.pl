%% Default derived-predicate library — auto-consulted by `symbolic query`
%% (override with -rules/-no-rules). calls/5 = calls(Caller, CallerArity,
%% CallSpec, File, Line); most rules below leave CallerArity unbound.

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

%% --- Expression content, on top of expr/6 + literal/7 + expr_operand/3 + expr_ref/6 ---
%% (byte-span Id; Erlang/TypeScript only)

expr(none, none, 0, none, none, 0) :- fail.
expr_operator(none, none) :- fail.
expr_operand(none, none, none) :- fail.
literal(none, none, 0, none, none, none, 0) :- fail.
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
    expr_operand(Id, left, L), literal(L, _, _, _, _, _, _),
    expr_operand(Id, right, R), \+ literal(R, _, _, _, _, _, _).

all_yoda_conditions(Triples) :-
    findall(Fun-Arity-File, yoda_condition(_Id, Fun, Arity, File, _Line), Raw),
    sort(Raw, Triples).

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
