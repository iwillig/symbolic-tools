-module(ts_extract_tests).
-include_lib("eunit/include/eunit.hrl").

-define(FIXTURE, "test/fixtures/sample.erl.fixture").

extracts_defines_test() ->
    Facts = ts_extract_erlang:file(?FIXTURE),
    Path = list_to_atom(?FIXTURE),
    ?assert(lists:member({defines, foo, 1, <<"(X)">>, Path, 4}, Facts)),
    ?assert(lists:member({defines, other, 0, <<"()">>, Path, 8}, Facts)).

extracts_arity_for_destructured_args_test() ->
    %% A destructured pattern ({Y,Z}, [H|T]) is still one named child, so
    %% one argument — confirmed empirically against the real grammar, not
    %% assumed. Uses an inline snippet since the fixture has no such case.
    Facts = ts_extract_erlang:text("scratch.erl", "baz(X, {Y,Z}, [H|T]) -> ok."),
    ?assert(lists:member(
        {defines, baz, 3, <<"(X, {Y,Z}, [H|T])">>, 'scratch.erl', 1}, Facts)).

extracts_local_call_test() ->
    Facts = ts_extract_erlang:file(?FIXTURE),
    Path = list_to_atom(?FIXTURE),
    ?assert(lists:member({calls, foo, 1, {local, bar, 1}, Path, 5}, Facts)),
    ?assert(lists:member({calls, other, 0, {local, bar, 1}, Path, 9}, Facts)).

extracts_remote_call_test() ->
    Facts = ts_extract_erlang:file(?FIXTURE),
    Path = list_to_atom(?FIXTURE),
    ?assert(lists:member({calls, foo, 1, {remote, baz, qux, 2}, Path, 6}, Facts)).

extracts_caller_arity_test() ->
    %% CallerArity comes from the enclosing clause's own arity, not the
    %% callee's — foo/1 calling a 2-arg function still reports CallerArity
    %% 1. Confirms the query/1-calls-query/2 false positive is closed:
    %% a call site's CallerArity now identifies which exact overload it's
    %% textually inside.
    Src = "foo(X) -> bar(X, 1).\nfoo(X, Y) -> bar(X, Y).",
    Facts = ts_extract_erlang:text("scratch2.erl", Src),
    ?assert(lists:member(
        {calls, foo, 1, {local, bar, 2}, 'scratch2.erl', 1}, Facts)),
    ?assert(lists:member(
        {calls, foo, 2, {local, bar, 2}, 'scratch2.erl', 2}, Facts)).

no_duplicate_facts_test() ->
    Facts = ts_extract_erlang:file(?FIXTURE),
    ?assertEqual(lists:usort(Facts), lists:sort(Facts)).

extracts_comment_test() ->
    Facts = ts_extract_erlang:file(?FIXTURE),
    Path = list_to_atom(?FIXTURE),
    ?assert(lists:member({comment, Path, 11, <<"Doubles a number.">>}, Facts)),
    ?assert(lists:member(
        {comment, Path, 15, <<"standalone comment, not attached to anything">>}, Facts)).

extracts_doc_test() ->
    Facts = ts_extract_erlang:file(?FIXTURE),
    Path = list_to_atom(?FIXTURE),
    ?assert(lists:member({doc, double, 1, Path, 12, <<"Doubles a number.">>}, Facts)).

standalone_comment_has_no_doc_test() ->
    Facts = ts_extract_erlang:file(?FIXTURE),
    ?assertEqual(
        [], [F || {doc, _, _, _, 15, _} = F <- Facts]).

%% Inline snippet, not the shared fixture — cr_clause covers BOTH `case`
%% and `receive` arms (same node type for both, confirmed empirically),
%% if_clause covers `if ... end`'s clauses, receive_after the `after
%% Timeout -> ...` escape path.
extracts_branch_facts_test() ->
    Src =
        "f(X) ->\n"                              %% 1
        "  case X of\n"                          %% 2
        "    0 -> zero;\n"                       %% 3
        "    N when N > 0 -> pos;\n"             %% 4
        "    _ -> other\n"                       %% 5
        "  end,\n"                               %% 6
        "  Y = if X > 0 -> a; true -> b end,\n"  %% 7
        "  receive\n"                            %% 8
        "    msg -> ok\n"                        %% 9
        "  after 100 -> timeout\n"                %% 10
        "  end.\n",                               %% 11
    Facts = ts_extract_erlang:text("scratch_branch.erl", Src),
    Path = 'scratch_branch.erl',
    Branches = [{K, L} || {branch, f, 1, K, P, L} <- Facts, P =:= Path],
    ?assertEqual(
        lists:sort([{cr_clause, 3}, {cr_clause, 4}, {cr_clause, 5}, {cr_clause, 9},
                    {if_clause, 7}, {receive_after, 10}]),
        lists:sort(Branches)).

%% The multi-clause case: each clause of a same-named/same-arity function
%% is its own defines/5 row (confirmed empirically — different Line/
%% Params per clause), which real_complexity/4 in .symbolic/rules.pl
%% relies on to get the "+1 per extra alternative" part of McCabe's
%% formula for free on Erlang.
multi_clause_function_produces_one_defines_per_clause_test() ->
    Src = "foo(0) -> zero;\nfoo(N) -> pos.\n",
    Facts = ts_extract_erlang:text("scratch_clauses.erl", Src),
    Path = 'scratch_clauses.erl',
    Defines = [F || {defines, foo, 1, _, P, _} = F <- Facts, P =:= Path],
    ?assertEqual(2, length(Defines)).

%% Ids are a byte span, not hand-countable — same reasoning as
%% ts_extract_typescript_tests.erl's identical test. `X == X` is a
%% binary expr whose operands both resolve to an expr_ref named 'X'
%% (Erlang vars are capitalized atoms); `X andalso true` has a left
%% expr_ref and a right literal atom 'true' — Erlang's true/false are
%% ordinary atoms, not a distinct boolean type (see classify_literal/2's
%% own doc comment).
extracts_expression_facts_test() ->
    Src =
        "f(X) ->\n"                %% 1
        "  Y = X == X,\n"          %% 2
        "  Z = X andalso true,\n"  %% 3
        "  {Y, Z}.\n",             %% 4
    Facts = ts_extract_erlang:text("scratch_expr.erl", Src),
    Path = 'scratch_expr.erl',
    EqId = only_id([Id || {expr, Id, f, 1, binary, P, 2} <- Facts, P =:= Path]),
    ?assert(lists:member({expr_operator, EqId, '=='}, Facts)),
    LeftId = operand_id(Facts, EqId, left),
    RightId = operand_id(Facts, EqId, right),
    ?assert(lists:member({expr_ref, LeftId, f, 1, 'X', Path, 2}, Facts)),
    ?assert(lists:member({expr_ref, RightId, f, 1, 'X', Path, 2}, Facts)),

    AndId = only_id([Id || {expr, Id, f, 1, binary, P, 3} <- Facts, P =:= Path]),
    ?assert(lists:member({expr_operator, AndId, 'andalso'}, Facts)),
    AndLeftId = operand_id(Facts, AndId, left),
    ?assert(lists:member({expr_ref, AndLeftId, f, 1, 'X', Path, 3}, Facts)),
    AndRightId = operand_id(Facts, AndId, right),
    ?assert(lists:member({literal, AndRightId, f, 1, atom, 'true', Path, 3}, Facts)).

only_id([Id]) -> Id.

operand_id(Facts, ParentId, Role) ->
    only_id([ChildId || {expr_operand, Id, R, ChildId} <- Facts, Id =:= ParentId, R =:= Role]).
