-module(ts_extract_typescript_tests).
-include_lib("eunit/include/eunit.hrl").

-define(FIXTURE, "test/fixtures/sample.ts").

extracts_defines_test() ->
    Facts = ts_extract_typescript:file(?FIXTURE),
    Path = list_to_atom(?FIXTURE),
    ?assert(lists:member({defines, foo, 1, <<"(x: number)">>, Path, 1}, Facts)),
    ?assert(lists:member({defines, other, 0, <<"()">>, Path, 6}, Facts)).

extracts_local_call_test() ->
    Facts = ts_extract_typescript:file(?FIXTURE),
    Path = list_to_atom(?FIXTURE),
    ?assert(lists:member({calls, foo, 1, {local, bar, 1}, Path, 2}, Facts)),
    ?assert(lists:member({calls, other, 0, {local, bar, 1}, Path, 7}, Facts)).

extracts_member_call_test() ->
    Facts = ts_extract_typescript:file(?FIXTURE),
    Path = list_to_atom(?FIXTURE),
    ?assert(lists:member(
        {calls, foo, 1, {member, 'this.baz', qux, 2}, Path, 3}, Facts)).

no_duplicate_facts_test() ->
    Facts = ts_extract_typescript:file(?FIXTURE),
    ?assertEqual(lists:usort(Facts), lists:sort(Facts)).

extracts_comment_test() ->
    Facts = ts_extract_typescript:file(?FIXTURE),
    Path = list_to_atom(?FIXTURE),
    ?assert(lists:member(
        {comment, Path, 10, <<"Capitalizes the first letter of a word.">>}, Facts)),
    ?assert(lists:member(
        {comment, Path, 15,
         <<"Shouts a word by capitalizing it and adding an exclamation mark.">>},
        Facts)),
    ?assert(lists:member(
        {comment, Path, 22, <<"standalone comment, not attached to anything">>}, Facts)).

extracts_doc_test() ->
    Facts = ts_extract_typescript:file(?FIXTURE),
    Path = list_to_atom(?FIXTURE),
    ?assert(lists:member(
        {doc, capitalize, 1, Path, 11, <<"Capitalizes the first letter of a word.">>}, Facts)),
    ?assert(lists:member(
        {doc, shout, 1, Path, 18,
         <<"Shouts a word by capitalizing it and adding an exclamation mark.">>},
        Facts)).

standalone_comment_has_no_doc_test() ->
    Facts = ts_extract_typescript:file(?FIXTURE),
    ?assertEqual(
        [], [F || {doc, _, _, _, 22, _} = F <- Facts]).

%% Inline snippet, not the shared fixture — none of ?BRANCH_QUERIES'
%% constructs appear in sample.ts. Covers every kind, and specifically
%% that `else if` is captured as its own `if` (a second if_statement
%% nested in the else_clause) while the trailing plain `else` on line 6
%% correctly adds nothing.
extracts_branch_facts_test() ->
    Src =
        "function f(x: number) {\n"                  %% 1
        "  if (x > 0) {\n"                            %% 2
        "    g();\n"                                  %% 3
        "  } else if (x < 0) {\n"                     %% 4
        "    h();\n"                                   %% 5
        "  } else {\n"                                %% 6
        "    h();\n"                                   %% 7
        "  }\n"                                        %% 8
        "  for (let i = 0; i < x; i++) { j(i); }\n"    %% 9
        "  while (x) { x = x - 1; }\n"                 %% 10
        "  const t = x > 0 ? 1 : 0;\n"                 %% 11
        "  const a = x && t;\n"                        %% 12
        "  const o = x || t;\n"                        %% 13
        "  try { k(); } catch (e) { l(); }\n"          %% 14
        "  switch (x) { case 1: m(); break; default: n(); }\n" %% 15
        "}\n",                                         %% 16
    Facts = ts_extract_typescript:text("scratch_branch.ts", Src),
    Path = 'scratch_branch.ts',
    Branches = [{K, L} || {branch, f, 1, K, P, L} <- Facts, P =:= Path],
    ?assertEqual(
        lists:sort([{'if', 2}, {'if', 4}, {'for', 9}, {'while', 10}, {ternary, 11},
                    {'and', 12}, {'or', 13}, {'catch', 14}, {switch_case, 15}]),
        lists:sort(Branches)).

%% Ids are a {File, StartByte, EndByte} byte span (not hand-countable
%% the way a Line number is), so this asserts relationships between
%% facts rather than hardcoding Id values: `x == x` is a binary expr
%% whose operands both resolve to an expr_ref named x; `0 === -0` is a
%% binary expr whose left is a literal 0 and whose right is a nested
%% unary '-' expr wrapping its own literal 0 operand — the exact
%% "no-self-compare"/"yoda" shapes .symbolic/rules.pl's self_compare/4
%% and yoda_condition/5 look for.
extracts_expression_facts_test() ->
    Src =
        "function f(x: number) {\n"     %% 1
        "  if (x == x) {\n"             %% 2
        "    return true;\n"            %% 3
        "  }\n"                         %% 4
        "  return 0 === -0;\n"          %% 5
        "}\n",                          %% 6
    Facts = ts_extract_typescript:text("scratch_expr.ts", Src),
    Path = 'scratch_expr.ts',
    EqId = only_id([Id || {expr, Id, f, 1, binary, P, 2} <- Facts, P =:= Path]),
    ?assert(lists:member({expr_operator, EqId, '=='}, Facts)),
    LeftRefId = operand_id(Facts, EqId, left),
    RightRefId = operand_id(Facts, EqId, right),
    ?assert(lists:member({expr_ref, LeftRefId, f, 1, x, Path, 2}, Facts)),
    ?assert(lists:member({expr_ref, RightRefId, f, 1, x, Path, 2}, Facts)),

    CmpId = only_id([Id || {expr, Id, f, 1, binary, P, 5} <- Facts, P =:= Path]),
    ?assert(lists:member({expr_operator, CmpId, '==='}, Facts)),
    LitId = operand_id(Facts, CmpId, left),
    ?assert(lists:member({literal, LitId, f, 1, number, 0, Path, 5}, Facts)),
    NegId = operand_id(Facts, CmpId, right),
    ?assert(lists:member({expr, NegId, f, 1, unary, Path, 5}, Facts)),
    ?assert(lists:member({expr_operator, NegId, '-'}, Facts)),
    NegOperandId = operand_id(Facts, NegId, operand),
    ?assert(lists:member({literal, NegOperandId, f, 1, number, 0, Path, 5}, Facts)).

only_id([Id]) -> Id.

operand_id(Facts, ParentId, Role) ->
    only_id([ChildId || {expr_operand, Id, R, ChildId} <- Facts, Id =:= ParentId, R =:= Role]).

%% A deliberately tricky snippet, exercising every real edge this
%% feature needs to get right, not just the easy case: a `let x`
%% shadowed by a nested block's own `let x` (must resolve to the INNER
%% one from inside that block); a `var y` that must be visible from
%% inside a for-loop's own nested body block (a two-level scope-chain
%% walk-up); and an unresolved reference (`b`, never declared) that
%% must come back `undefined`, not error or crash.
extracts_scope_facts_test() ->
    Src =
        "function f(a: number) {\n"    %% 1
        "  let x = 1;\n"               %% 2
        "  var y = 2;\n"               %% 3
        "  x = x + 1;\n"               %% 4
        "  if (a) {\n"                 %% 5
        "    let x = 2;\n"             %% 6
        "    console.log(x);\n"        %% 7
        "  }\n"                        %% 8
        "  for (let i = 0; i < 10; i++) {\n" %% 9
        "    y += i;\n"                %% 10
        "  }\n"                        %% 11
        "  const unused = 99;\n"       %% 12
        "  return b;\n"                %% 13
        "}\n",                         %% 14
    Facts = ts_extract_typescript:text("scratch_scope.ts", Src),
    Path = 'scratch_scope.ts',
    DeclAt = fun(Name, Line) ->
        only_id([Id || {var_decl, Id, N, _K, _S, P, L} <- Facts,
                        N =:= Name, L =:= Line, P =:= Path])
    end,
    RefsAt = fun(Name, Line) ->
        [Id || {var_ref, Id, N, _S, _RK, P, L} <- Facts,
               N =:= Name, L =:= Line, P =:= Path]
    end,
    ResolvesTo = fun(RefId) ->
        only_id([D || {resolves_to, R, D} <- Facts, R =:= RefId])
    end,

    OuterX = DeclAt(x, 2),
    InnerX = DeclAt(x, 6),

    %% x = x + 1 (line 4) is OUTSIDE the if-block and has TWO references
    %% (the write and the read) — both resolve to the OUTER x, not the
    %% shadowed inner one.
    ?assertEqual([OuterX, OuterX], [ResolvesTo(Id) || Id <- RefsAt(x, 4)]),
    %% console.log(x) (line 7) is INSIDE the if-block, so it resolves to
    %% the INNER (shadowing) x instead — the actual point of the test.
    XRefsAtLine7 = [Id || {var_ref, Id, x, _S, _RK, P, 7} <- Facts, P =:= Path],
    ?assertEqual([InnerX], [ResolvesTo(Id) || Id <- XRefsAtLine7]),

    %% y (var, declared at function scope) and i (let, declared in the
    %% for-loop's own header scope) are both read from inside the
    %% for-body's own NESTED block scope — a two-level walk-up each.
    YDecl = DeclAt(y, 3),
    IDecl = DeclAt(i, 9),
    YRefLine10 = only_id([Id || {var_ref, Id, y, _S, _RK, P, 10} <- Facts, P =:= Path]),
    IRefLine10 = only_id([Id || {var_ref, Id, i, _S, _RK, P, 10} <- Facts, P =:= Path]),
    ?assertEqual(YDecl, ResolvesTo(YRefLine10)),
    ?assertEqual(IDecl, ResolvesTo(IRefLine10)),

    %% `b` is never declared anywhere — a clean `undefined`, not a crash.
    ?assertEqual('undefined', ResolvesTo(only_id(RefsAt(b, 13)))).

%% var_decl_initialized/1 — present for a declarator with a "value",
%% absent for a bare one. Also a regression test for a real crash found
%% while building .symbolic/rules.pl's prefer_const/4: resolve_refs/3's
%% declaration index used to pattern-match {var_decl, ...} via a foldl
%% with no other clause, and var_decl_initialized/1 facts sitting in
%% the very same list (walk_declaration/6 emits both from one
%% declarator) hit function_clause. A list comprehension that only
%% picks out var_decl tuples can't crash on the ones it doesn't match.
extracts_var_decl_initialized_test() ->
    Src =
        "function f() {\n"     %% 1
        "  let x = 1;\n"       %% 2
        "  let y;\n"           %% 3
        "}\n",                 %% 4
    Facts = ts_extract_typescript:text("scratch_init.ts", Src),
    Path = 'scratch_init.ts',
    XDecl = only_id([Id || {var_decl, Id, x, _K, _S, P, 2} <- Facts, P =:= Path]),
    YDecl = only_id([Id || {var_decl, Id, y, _K, _S, P, 3} <- Facts, P =:= Path]),
    ?assert(lists:member({var_decl_initialized, XDecl}, Facts)),
    ?assertNot(lists:member({var_decl_initialized, YDecl}, Facts)).

%% `new X(...)` as one more calls/5 CallSpec, plus bare_new/5 for the
%% one case that needs statement-level context: a `new Foo()` whose
%% value is discarded outright (its own expression_statement) versus
%% one that's assigned. `new Baz` (no parens at all — a null
%% "arguments" field, confirmed to segfault the whole BEAM if
%% node_named_child_count/1 is called on it without an is_null guard
%% first) must still come back ArgCount 0, not crash.
extracts_new_expression_facts_test() ->
    Src =
        "function f() {\n"          %% 1
        "  new Logger();\n"         %% 2 — discarded: bare_new too
        "  const a = new Bar(1);\n" %% 3 — assigned: calls/5 only
        "  const b = new Baz;\n"    %% 4 — no parens at all
        "}\n",                      %% 5
    Facts = ts_extract_typescript:text("scratch_new.ts", Src),
    Path = 'scratch_new.ts',
    ?assert(lists:member({calls, f, 0, {new, 'Logger', 0}, Path, 2}, Facts)),
    ?assert(lists:member({bare_new, f, 0, 'Logger', Path, 2}, Facts)),
    ?assert(lists:member({calls, f, 0, {new, 'Bar', 1}, Path, 3}, Facts)),
    ?assertEqual([], [F || {bare_new, f, 0, 'Bar', _, _} = F <- Facts]),
    ?assert(lists:member({calls, f, 0, {new, 'Baz', 0}, Path, 4}, Facts)).

%% A bare call with no `new` at all (`RegExp(...)`) already goes through
%% local_calls/3 unchanged — prefer_regex_literal/4 in .symbolic/rules.pl
%% relies on that existing shape, not on new_calls/4 emitting anything
%% extra for it.
extracts_bare_call_alongside_new_expressions_test() ->
    Src = "function f() {\n  return RegExp(\"a+\");\n}\n",
    Facts = ts_extract_typescript:text("scratch_bare_call.ts", Src),
    Path = 'scratch_bare_call.ts',
    ?assert(lists:member({calls, f, 0, {local, 'RegExp', 1}, Path, 2}, Facts)).

%% Every import_clause shape at once: a default (Foo), named with and
%% without an alias (a; b as c), a namespace (* as ns), and a
%% side-effect-only import (no clause at all, no binding). Each binding
%% is a var_decl(Kind='import') at module scope, same shape as any
%% other declaration — the point being that it composes with the rest
%% of the scope machinery, not a parallel fact family.
extracts_import_facts_test() ->
    Src =
        "import Foo from \"lodash\";\n"     %% 1
        "import { a, b as c } from \"./bar\";\n" %% 2
        "import * as ns from \"./ns\";\n"   %% 3
        "import \"./sideeffect\";\n"        %% 4
        "import Baz from \"lodash\";\n",    %% 5 — duplicate module path
    Facts = ts_extract_typescript:text("scratch_import.ts", Src),
    Path = 'scratch_import.ts',
    ?assertEqual(
        lists:sort([{lodash, 1}, {'./bar', 2}, {'./ns', 3}, {'./sideeffect', 4}, {lodash, 5}]),
        lists:sort([{M, L} || {import_decl, M, P, L} <- Facts, P =:= Path])),
    ModuleScope = only_id([S || {scope, S, module, none, P} <- Facts, P =:= Path]),
    Imported = fun(Name, Line) ->
        lists:member({var_decl, only_id([Id || {var_decl, Id, N, 'import', Sc, P, L} <- Facts,
                                                 N =:= Name, L =:= Line, Sc =:= ModuleScope, P =:= Path]),
                       Name, 'import', ModuleScope, Path, Line}, Facts)
    end,
    ?assert(Imported('Foo', 1)),
    ?assert(Imported(a, 2)),
    ?assert(Imported(c, 2)),
    %% `b` (the original name, aliased away as `c`) is never itself a
    %% local binding — must NOT get a var_decl of its own.
    ?assertEqual([], [F || {var_decl, _, b, 'import', _, _, _} = F <- Facts]),
    ?assert(Imported(ns, 3)),
    ?assert(Imported('Baz', 5)),
    %% Line 4 is a side-effect-only import — no clause, no binding at all.
    ?assertEqual([], [F || {var_decl, _, _, 'import', _, P, 4} = F <- Facts, P =:= Path]).

%% Every export shape at once: a wrapped declaration (const/function —
%% both already produce their own var_decl/6 or defines/5 facts
%% unchanged, via the normal walk_scope/5 fallthrough, not tested again
%% here), a re-export list (own name; aliased), `export default`, and
%% `export * from`.
extracts_export_facts_test() ->
    Src =
        "export const x = 1;\n"     %% 1
        "function f() {}\n"          %% 2
        "export { x, f as g };\n"    %% 3
        "export default x;\n"        %% 4
        "export * from \"./reexport\";\n", %% 5
    Facts = ts_extract_typescript:text("scratch_export.ts", Src),
    Path = 'scratch_export.ts',
    ?assertEqual(
        lists:sort([{x, named, 1}, {x, named, 3}, {g, named, 3}, {'default', default, 4},
                    {undefined, wildcard, 5}]),
        lists:sort([{N, K, L} || {export_decl, N, K, P, L} <- Facts, P =:= Path])).

%% Referencing an imported name anywhere in the file must resolve back
%% to its own import binding — a real regression test for a bug found
%% while building this: scope_facts/4 used to compute import bindings
%% AFTER calling resolve_refs/3, so no reference to an imported name
%% resolved to anything, anywhere in the file (every one came back
%% resolves_to(_, undefined), indistinguishable from a genuinely
%% undeclared name) until the ordering was fixed.
imported_names_resolve_to_their_import_binding_test() ->
    Src =
        "import Foo from \"lodash\";\n" %% 1
        "function use() {\n"             %% 2
        "  return Foo(1);\n"             %% 3
        "}\n",                           %% 4
    Facts = ts_extract_typescript:text("scratch_import_resolve.ts", Src),
    Path = 'scratch_import_resolve.ts',
    FooDecl = only_id([Id || {var_decl, Id, 'Foo', 'import', _, P, 1} <- Facts, P =:= Path]),
    FooRef = only_id([Id || {var_ref, Id, 'Foo', _, read, P, 3} <- Facts, P =:= Path]),
    ?assertEqual(FooDecl, only_id([D || {resolves_to, R, D} <- Facts, R =:= FooRef])).
