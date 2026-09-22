%%% `symbolic query --db <facts.dets> [--rules <rules.pl>] <goal>` —
%%% load a fact database, optionally consult a hand-written Prolog rule
%%% file alongside it, and prove a goal. See docs/cli-erlang.md,
%%% docs/erlang-mcp-design.md, docs/prolog-store.md.
%%%
%%% Facts used to be consulted from a `.pl` text file the same way rules
%%% are; now they come from a DETS-backed symbolic_fact_store.erl
%%% database instead, asserted directly as Erlang terms
%%% (prolog_session:load_facts/2) with no text parsing involved. `--rules`
%%% keeps the door open for hand-written derived rules (e.g.
%%% docs/lint-queries.md's rule library) via the ordinary text-based
%%% prolog_session:consult/2 — that path isn't buggy (it's real Prolog
%%% syntax a person wrote, not arbitrary extracted prose), so there's no
%%% reason to move it off text.
-module(symbolic_query).
-export([run/2, run/3]).
%% Exported for symbolic_query_tests.erl — run_result/3 is the halt-free
%% core (see its own doc comment); maybe_consult_rules/2, print_bindings/1
%% and name_to_list/1 are its remaining halt-free pieces.
-export([run_result/3, maybe_consult_rules/2, print_bindings/1, name_to_list/1]).

run(DbPath, Goal) ->
    run(DbPath, undefined, Goal).

%% halt() belongs only here, at the CLI's actual edge — everything that
%% decides the outcome lives in run_result/3, which returns a plain term
%% instead of halting, precisely so EUnit can exercise it directly. See
%% docs/testing-erlang.md — using erlang:halt/0,1 anywhere else (deep in
%% business logic) is a well-known Erlang anti-pattern: it kills the
%% entire runtime, not just "the current operation", which is exactly
%% why run_result/3 couldn't be unit tested before this split existed.
run(DbPath, RulesPath, Goal) ->
    case run_result(DbPath, RulesPath, Goal) of
        {solutions, Bindings} ->
            print_bindings(Bindings),
            halt(0);
        no_solution ->
            io:format("No.~n"),
            halt(1);
        {error, {no_such_db, Path}} ->
            fail("cannot read fact database: ~s", [Path]);
        {error, {rules_error, RulesPath1, Reason}} ->
            fail("cannot consult rules ~s: ~p", [RulesPath1, Reason]);
        {error, {query_failed, Reason}} ->
            fail("query failed: ~p", [Reason])
    end.

%% The halt-free core: load the fact database, optionally consult a
%% rules file, prove Goal, and report what happened as a plain term.
%% Starts (and always stops) its own prolog_session — a caller gets a
%% clean session either way, never one left running after this returns.
-spec run_result(file:filename(), file:filename() | undefined, string()) ->
    {solutions, [{atom(), term()}]} | no_solution
    | {error, {no_such_db, file:filename()}}
    | {error, {rules_error, file:filename() | undefined, term()}}
    | {error, {query_failed, term()}}.
run_result(DbPath, RulesPath, Goal) ->
    case filelib:is_regular(DbPath) of
        true -> run_checked(DbPath, RulesPath, Goal);
        false -> {error, {no_such_db, DbPath}}
    end.

run_checked(DbPath, RulesPath, Goal) ->
    Facts = symbolic_fact_store:read(DbPath),
    {ok, Pid} = prolog_session:start_link(),
    ok = prolog_session:load_facts(Pid, Facts),
    Result =
        case maybe_consult_rules(Pid, RulesPath) of
            ok -> query_result(Pid, Goal);
            {error, Reason} -> {error, {rules_error, RulesPath, Reason}}
        end,
    prolog_session:stop(Pid),
    Result.

maybe_consult_rules(_Pid, undefined) -> ok;
maybe_consult_rules(Pid, RulesPath) -> prolog_session:consult(Pid, RulesPath).

query_result(Pid, Goal) ->
    case prolog_session:query(Pid, Goal) of
        {ok, Bindings} -> {solutions, Bindings};
        no_solution -> no_solution;
        {error, Reason} -> {error, {query_failed, Reason}}
    end.

print_bindings([]) ->
    io:format("Yes.~n");
print_bindings(Bindings) ->
    %% ~ts, not ~s, for the JSON value — see symbolic_parse.erl's
    %% print_fact/1 for why (a plain ~s mangles a binary's non-ASCII
    %% UTF-8 bytes).
    lists:foreach(
        fun({Name, Value}) ->
            io:format("~s = ~ts~n",
                [name_to_list(Name), jsx:encode(symbolic_term_json:encode_term(Value))])
        end,
        Bindings
    ).

fail(Fmt, Args) ->
    io:put_chars(standard_error, io_lib:format(Fmt ++ "~n", Args)),
    halt(1).

name_to_list(Name) when is_atom(Name) -> atom_to_list(Name);
name_to_list(Name) when is_integer(Name) -> "_" ++ integer_to_list(Name).
