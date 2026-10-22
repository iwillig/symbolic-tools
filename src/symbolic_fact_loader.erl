%%% Bulk-load extracted, ground facts into erlog's default dict database.
%%%
%%% Asserting each fact through erlog:prove({asserta, Fact}, State) runs the
%%% Prolog goal evaluator (including variable dereferencing) once per fact.
%%% Extracted facts are ground Erlang tuples, so the default dict backend
%%% can store the same clauses directly. Non-ground input takes the original
%%% evaluator path: it must rename Prolog variables per asserted clause.
%%% Keep asserta's order, tags, and compiled fact body; rules are still
%%% consulted through erlog:consult. This adapter assumes sessions created
%%% with erlog:new/0 (dict backend).
-module(symbolic_fact_loader).
-export([load/2]).

-spec load(term(), [tuple()]) -> term().
load(Erl, Facts) ->
    case erlog:vars_in(Facts) of
        [] ->
            Ref = lists:foldl(fun add_fact/2, erlog:get_db(Erl), Facts),
            erlog:set_db(Ref, Erl);
        _ ->
            %% A Prolog variable ({Name}) needs erlog's per-clause
            %% renaming; inserting its raw tuple would change semantics.
            lists:foldl(fun(Fact, Acc) ->
                {{succeed, _}, Next} = erlog:prove({asserta, Fact}, Acc),
                Next
            end, Erl, Facts)
    end.

add_fact(Fact, Ref) ->
    Functor = {element(1, Fact), tuple_size(Fact) - 1},
    %% erlog_int:well_form_body(true, false, _) produces {[], false}.
    %% erlog_db_dict performs the same static-procedure check and prepends
    %% {Tag, Head, Body}, advancing the tag just as asserta/1 does.
    {ok, Next} = erlog_db_dict:asserta_clause(Ref, Functor, Fact, {[], false}),
    Next.
