-module(symbolic_fact_loader_tests).
-include_lib("eunit/include/eunit.hrl").

same_database_as_asserta_for_ground_facts_test() ->
    Facts = [{example, first, <<"quoted ' value">>},
             {other, {nested, [1, 2]}, '/tmp/a.erl'},
             {example, second, <<"second">>},
             {example, first, <<"quoted ' value">>}],
    {ok, Erl0} = erlog:new(),
    {ok, Erl} = erlog:load(symbolic_prolog_lib, Erl0),
    Legacy = lists:foldl(fun(Fact, Acc) ->
        {{succeed, _}, Next} = erlog:prove({asserta, Fact}, Acc), Next
    end, Erl, Facts),
    Bulk = symbolic_fact_loader:load(Erl, Facts),
    ?assertEqual(erlog:get_db(Legacy), erlog:get_db(Bulk)),
    {{succeed, Bindings}, _} = erlog:prove({example, {'X'}, {'Text'}}, Bulk),
    ?assertEqual(first, proplists:get_value('X', Bindings)),
    ?assertEqual(<<"quoted ' value">>, proplists:get_value('Text', Bindings)),
    ?assertEqual(error, erlog_db_dict:asserta_clause(
        erlog:get_db(Bulk), {true, 0}, true, {[], false})).

many_mixed_predicates_keep_clause_tags_and_order_test() ->
    Names = [alpha, beta, gamma, delta],
    Facts = [{lists:nth((N rem 4) + 1, Names), N, <<"value">>} ||
             N <- lists:seq(1, 2000)],
    {ok, Erl} = erlog:new(),
    Legacy = lists:foldl(fun(Fact, Acc) ->
        {{succeed, _}, Next} = erlog:prove({asserta, Fact}, Acc), Next
    end, Erl, Facts),
    ?assertEqual(erlog:get_db(Legacy),
                 erlog:get_db(symbolic_fact_loader:load(Erl, Facts))).

non_ground_facts_keep_asserta_variable_renaming_test() ->
    Facts = [{p, {'X'}}, {p, {'Y'}}],
    {ok, Erl} = erlog:new(),
    Legacy = lists:foldl(fun(Fact, Acc) ->
        {{succeed, _}, Next} = erlog:prove({asserta, Fact}, Acc), Next
    end, Erl, Facts),
    Bulk = symbolic_fact_loader:load(Erl, Facts),
    ?assertEqual(erlog:get_db(Legacy), erlog:get_db(Bulk)).

rules_can_be_consulted_after_bulk_load_test() ->
    {ok, Erl} = erlog:new(),
    Bulk = symbolic_fact_loader:load(Erl, [{edge, a, b}, {edge, b, c}]),
    %% Use a temporary rules source to check interaction with the erlog
    %% consultant (not just raw fact lookup). The tempfile stays outside
    %% the repository and is cleaned even when an assertion fails.
    File = filename:join("/tmp", "symbolic_bulk_rules_" ++
        integer_to_list(erlang:unique_integer([positive])) ++ ".pl"),
    try
        ok = file:write_file(File, <<"step(X,Y) :- edge(X,Y).\n">>),
        {ok, WithRules} = erlog:consult(File, Bulk),
        ?assertMatch({{succeed, _}, _}, erlog:prove({step, a, b}, WithRules))
    after file:delete(File) end.
