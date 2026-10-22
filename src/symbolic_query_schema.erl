%%% Small, explicit query contracts for the facts agents most often confuse.
%%% This is not a universal Prolog type checker. Validation only inspects
%%% simple conjunctions of known goals; unknown/derived predicates still
%%% belong to erlog and must never be rejected on a guessed schema.
-module(symbolic_query_schema).
-export([describe/1, validate/1]).

-spec describe(binary() | undefined) -> {ok, map()} | {error, term()}.
describe(undefined) ->
    {ok, #{predicates => entries(),
           scope => <<"Documented high-use predicates, not an exhaustive fact schema. "
                      "Use overview for loaded predicate counts; unknown goals remain Prolog goals.">>}};
describe(Name) when is_binary(Name) ->
    case [Entry || Entry <- entries(),
            maps:get(name, Entry) =:= Name orelse maps:get(predicate, Entry) =:= Name] of
        [] -> {error, {unknown_documented_predicate, Name}};
        Matches -> {ok, #{predicates => Matches}}
    end.

entry(Name, Args, Types, Mode, Example, Note) ->
    #{predicate => iolist_to_binary([Name, "/", integer_to_list(length(Args))]),
      name => Name, arguments => [#{name => Arg, type => Type} ||
          {Arg, Type} <- lists:zip(Args, Types)],
      mode => Mode, example => Example, note => Note}.

entries() ->
    [entry(<<"defines">>, [<<"Function">>, <<"Arity">>, <<"Params">>, <<"File">>, <<"Line">>],
         [atom, integer, binary, atom, integer], <<"Enumerate definitions; bind name/arity when known.">>,
         <<"defines(foo, 2, _, File, Line)">>, <<"Functions only; not every variable or arrow declaration.">>),
     entry(<<"calls">>, [<<"Caller">>, <<"CallerArity">>, <<"CallSpec">>, <<"File">>, <<"Line">>],
         [atom, integer, compound, atom, integer], <<"Bind caller or CallSpec for focused queries.">>,
         <<"calls(foo, 2, local(bar, 1), File, Line)">>, <<"CallSpec can be local/2, remote/3, member/3, or new/2.">>),
     entry(<<"paragraph">>, [<<"File">>, <<"Text">>, <<"Line">>],
         [atom, binary, integer], <<"Bind File before searching Text.">>,
         <<"paragraph(File, Text, Line), sub_text(Text, _, _, _, \"phrase\")">>,
         <<"Text is the SECOND argument; Line is the THIRD.">>),
     entry(<<"comment">>, [<<"File">>, <<"Line">>, <<"Text">>],
         [atom, integer, binary], <<"Bind File before searching Text.">>,
         <<"comment(File, Line, Text), sub_text(Text, _, _, _, \"phrase\")">>, <<"Unlike paragraph/3, Text is third.">>),
     entry(<<"heading">>, [<<"File">>, <<"Level">>, <<"Title">>, <<"Line">>],
         [atom, integer, binary, integer], <<"Bind File before searching Title.">>,
         <<"heading(File, _, Title, Line), sub_text(Title, _, _, _, \"phrase\")">>, <<"Title is binary.">>),
     entry(<<"import_decl">>, [<<"Module">>, <<"File">>, <<"Line">>],
         [atom, atom, integer], <<"Bind Module or File.">>,
         <<"import_decl(Module, File, Line), sub_atom(Module, _, _, _, middleware)">>, <<"Module is an atom, not binary text.">>),
     entry(<<"literal">>, [<<"Id">>, <<"Function">>, <<"Arity">>, <<"Kind">>, <<"Value">>, <<"File">>, <<"Line">>, <<"Raw">>],
         [term, atom, integer, atom, mixed, atom, integer, binary], <<"Bind Kind and File before filtering Value.">>,
         <<"literal(_, _, _, string, Value, File, Line, _), sub_text(Value, _, _, _, \"needle\")">>,
         <<"Value is binary for string literals, but may be numeric or another type for other kinds.">>),
     entry(<<"sub_text">>, [<<"Text">>, <<"Before">>, <<"Length">>, <<"After">>, <<"Needle">>],
         [binary, integer, integer, integer, code_list], <<"Text and Needle must be bound; ASCII needle uses a fast substring path.">>,
         <<"comment(File, Line, Text), sub_text(Text, _, _, _, \"needle\")">>,
         <<"Offsets count bytes. A goal-level double-quoted Needle is a code list, not a binary.">>),
     entry(<<"sub_atom">>, [<<"Atom">>, <<"Before">>, <<"Length">>, <<"After">>, <<"Needle">>],
         [atom, integer, integer, integer, atom], <<"Atom and Needle must be bound.">>,
         <<"import_decl(Module, File, Line), sub_atom(Module, _, _, _, middleware)">>,
         <<"Use sub_text/5 for binary prose, not sub_atom/5.">>)].

%% Only static contracts which are safe to infer from a fact's argument.
fact_types(paragraph) -> [atom, binary, integer];
fact_types(comment) -> [atom, integer, binary];
fact_types(heading) -> [atom, integer, binary, integer];
fact_types(import_decl) -> [atom, atom, integer];
fact_types(_) -> undefined.

validate(Goal) -> validate_goals(simple_goals(Goal), #{}).

simple_goals({',', A, B}) -> simple_goals(A) ++ simple_goals(B);
simple_goals(Term) when is_tuple(Term), tuple_size(Term) > 1 -> [Term];
simple_goals(_) -> [].

validate_goals([], _Types) -> ok;
validate_goals([Term | Rest], Types) ->
    Name = element(1, Term),
    Arity = tuple_size(Term) - 1,
    case documented_arity(Name) of
        Expected when is_integer(Expected), Expected =/= Arity ->
            {error, {invalid_goal, iolist_to_binary(io_lib:format(
                "~s/~p has the wrong arity; expected ~s/~p. Use schema for argument order.",
                [Name, Arity, Name, Expected]))}};
        _ ->
            case check_text_argument(Term, Types) of
                ok -> validate_goals(Rest, add_fact_types(Term, Types));
                Error -> Error
            end
    end.

documented_arity(Name) when is_atom(Name) ->
    case [length(maps:get(arguments, E)) || E <- entries(),
        maps:get(name, E) =:= atom_to_binary(Name, utf8)] of
        [Arity] -> Arity;
        [] -> undefined
    end;
documented_arity(_) -> undefined.

check_text_argument(Term, Types) ->
    Name = element(1, Term),
    case Name of
        sub_text -> check_haystack(binary, element(2, Term), Types);
        sub_atom -> check_haystack(atom, element(2, Term), Types);
        _ -> ok
    end.

check_haystack(Expected, {Var}, Types) when is_atom(Var) ->
    case maps:get(Var, Types, undefined) of
        undefined -> ok;
        Expected -> ok;
        Actual -> mismatch(Expected, Actual)
    end;
check_haystack(binary, Value, _Types) when is_binary(Value) -> ok;
check_haystack(atom, Value, _Types) when is_atom(Value) -> ok;
check_haystack(Expected, Value, _Types) -> mismatch(Expected, type_of(Value)).

mismatch(Expected, Actual) ->
    {error, {invalid_goal, iolist_to_binary(io_lib:format(
        "~s/5 needs a bound ~s first argument, but this goal supplies ~s. "
        "Check paragraph(File, Text, Line), comment(File, Line, Text), "
        "and import_decl(Module, File, Line); see schema.",
        [filter_name(Expected), Expected, Actual]))}}.

filter_name(binary) -> "sub_text";
filter_name(atom) -> "sub_atom".

type_of(Value) when is_integer(Value) -> integer;
type_of(Value) when is_atom(Value) -> atom;
type_of(Value) when is_list(Value) -> code_list;
type_of(_) -> term.

add_fact_types(Term, Types) ->
    case fact_types(element(1, Term)) of
        undefined -> Types;
        Expected when length(Expected) =:= tuple_size(Term) - 1 ->
            lists:foldl(fun({Arg, Type}, Acc) ->
                case Arg of
                    {Var} when is_atom(Var), Var =/= '_' -> Acc#{Var => Type};
                    _ -> Acc
                end
            end, Types, lists:zip(tl(tuple_to_list(Term)), Expected));
        _ -> Types
    end.
