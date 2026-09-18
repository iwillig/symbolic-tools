%%% `symbolic query --file <facts.pl> <goal>` — load a fact file and
%%% prove a goal against it. See docs/cli-erlang.md, docs/erlang-mcp-design.md.
-module(symbolic_query).
-export([run/2]).

run(File, Goal) ->
    {ok, Pid} = prolog_session:start_link(),
    case prolog_session:consult(Pid, File) of
        ok -> handle_query(Pid, Goal);
        {error, Reason} -> fail("cannot consult ~s: ~p", [File, Reason])
    end.

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
    lists:foreach(
        fun({Name, Value}) ->
            io:format("~s = ~s~n", [name_to_list(Name), erlog_io:writeq1(Value)])
        end,
        Bindings
    ).

fail(Fmt, Args) ->
    io:put_chars(standard_error, io_lib:format(Fmt ++ "~n", Args)),
    halt(1).

name_to_list(Name) when is_atom(Name) -> atom_to_list(Name);
name_to_list(Name) when is_integer(Name) -> "_" ++ integer_to_list(Name).
