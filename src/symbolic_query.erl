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

run(DbPath, Goal) ->
    run(DbPath, undefined, Goal).

run(DbPath, RulesPath, Goal) ->
    case filelib:is_regular(DbPath) of
        true -> run_checked(DbPath, RulesPath, Goal);
        false -> fail("cannot read fact database: ~s", [DbPath])
    end.

run_checked(DbPath, RulesPath, Goal) ->
    Facts = symbolic_fact_store:read(DbPath),
    {ok, Pid} = prolog_session:start_link(),
    ok = prolog_session:load_facts(Pid, Facts),
    case maybe_consult_rules(Pid, RulesPath) of
        ok -> handle_query(Pid, Goal);
        {error, Reason} -> fail("cannot consult rules ~s: ~p", [RulesPath, Reason])
    end.

maybe_consult_rules(_Pid, undefined) -> ok;
maybe_consult_rules(Pid, RulesPath) -> prolog_session:consult(Pid, RulesPath).

handle_query(Pid, Goal) ->
    case prolog_session:query(Pid, Goal) of
        {ok, Bindings} ->
            print_bindings(Bindings),
            halt(0);
        no_solution ->
            io:format("No.~n"),
            halt(1);
        {error, Reason} ->
            fail("query failed: ~p", [Reason])
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
