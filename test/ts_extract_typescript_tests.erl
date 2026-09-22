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
