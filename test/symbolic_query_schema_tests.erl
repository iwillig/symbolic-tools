-module(symbolic_query_schema_tests).
-include_lib("eunit/include/eunit.hrl").

parse(Goal) ->
    {ok, Term} = erlog_io:read_string(Goal ++ "."), Term.

paragraph_contract_exposes_actual_argument_order_test() ->
    {ok, #{predicates := [Entry]}} = symbolic_query_schema:describe(<<"paragraph/3">>),
    ?assertEqual([<<"File">>, <<"Text">>, <<"Line">>],
        [maps:get(name, A) || A <- maps:get(arguments, Entry)]),
    ?assertEqual([atom, binary, integer],
        [maps:get(type, A) || A <- maps:get(arguments, Entry)]).

schema_is_explicitly_partial_test() ->
    {ok, #{predicates := All, scope := Scope}} = symbolic_query_schema:describe(undefined),
    ?assert(length(All) >= 7),
    ?assertNotEqual(nomatch, binary:match(Scope, <<"not an exhaustive">>)),
    ?assertMatch({error, {unknown_documented_predicate, _}},
        symbolic_query_schema:describe(<<"custom_rule">>)).

preflight_catches_wrong_arity_and_swapped_paragraph_arguments_test() ->
    ?assertMatch({error, {invalid_goal, _}},
        symbolic_query_schema:validate(parse("paragraph(F, T, L, X)"))),
    {error, {invalid_goal, Message}} = symbolic_query_schema:validate(
        parse("paragraph(F, Line, Text), sub_text(Text, _, _, _, \"query\")")),
    ?assertNotEqual(nomatch, binary:match(Message, <<"paragraph(File, Text, Line)">>)).

preflight_catches_wrong_filter_type_test() ->
    ?assertMatch({error, {invalid_goal, _}},
        symbolic_query_schema:validate(parse("sub_text(61, _, _, _, \"query\")"))),
    ?assertMatch({error, {invalid_goal, _}},
        symbolic_query_schema:validate(parse("import_decl(M,F,L), sub_text(M,_,_,_,\"mid\")"))),
    ?assertMatch({error, {invalid_goal, _}},
        symbolic_query_schema:validate(parse("comment(F,L,T), sub_atom(T,_,_,_,word)"))).

preflight_leaves_valid_and_unknown_goals_to_erlog_test() ->
    ?assertEqual(ok, symbolic_query_schema:validate(
        parse("paragraph(F, Text, Line), sub_text(Text, _, _, _, \"query\")"))),
    ?assertEqual(ok, symbolic_query_schema:validate(
        parse("import_decl(M,F,L), sub_atom(M,_,_,_,middleware)"))),
    ?assertEqual(ok, symbolic_query_schema:validate(parse("custom_rule(A,B,C,D)"))),
    ?assertEqual(ok, symbolic_query_schema:validate(
        parse("findall(X, paragraph(_,X,_), List)"))).
