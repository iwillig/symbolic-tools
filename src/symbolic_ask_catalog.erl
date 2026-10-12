%%% The allowlisted operations that symbolic_ask may execute.
%%%
%%% Natural-language parsers produce typed templates, not Prolog source.
%%% This catalog is the validation seam: every template must map to a
%%% declared operation before the proof layer can run. Add an operation
%%% here only after its semantics and answer shape are tested.
-module(symbolic_ask_catalog).
-export([lookup/2, operations/0, describe/0]).

-spec operations() -> [map()].
operations() ->
    [operation(calls, yes_no, closed_world, none),
     operation(defines, yes_no, closed_world, none),
     operation(callers, enumerate, closed_world, none),
     operation(callers_count, count, closed_world, none),
     operation(prose_search, prose, corpus_evidence, source_location),
     operation(uses, yes_no, closed_world, none),
     operation(returns_mention, yes_no, closed_world, none),
     operation(handles_literal, yes_no, closed_world, none),
     operation(calls_in_file, yes_no, closed_world, none),
     operation(uses_in_file, yes_no, closed_world, none),
     operation(file_scanned, yes_no, scan_scope, none),
     operation(config_defined, yes_no, closed_world, none),
     operation(call_sites, sites, closed_world, source_location),
     operation(definition_sites, sites, closed_world, source_location)].

-spec describe() -> #{binary() => term()}.
describe() ->
    #{<<"operations">> => [public_operation(Op) || Op <- operations()] }.

-spec lookup(atom(), term()) -> {ok, map()} | error.
lookup(yes_no, {calls, _, _}) -> find(calls);
lookup(yes_no, {defines, _}) -> find(defines);
lookup(enumerate, {callers_of, _}) -> find(callers);
lookup(count, {callers_of, _}) -> find(callers_count);
lookup(prose, _Span) -> find(prose_search);
lookup(yes_no, {uses, _, _}) -> find(uses);
lookup(yes_no, {uses_file, _, _}) -> find(uses_in_file);
lookup(yes_no, {returns, _, _}) -> find(returns_mention);
lookup(yes_no, {handles, _, _}) -> find(handles_literal);
lookup(yes_no, {calls_file, _, _}) -> find(calls_in_file);
lookup(yes_no, {file_scanned, _}) -> find(file_scanned);
lookup(yes_no, {config_defined, _}) -> find(config_defined);
lookup(sites, {call_sites_of, _}) -> find(call_sites);
lookup(sites, {def_site_of, _}) -> find(definition_sites);
lookup(_Type, _Relation) -> error.

find(Id) ->
    case lists:keyfind(Id, 1, [{maps:get(id, Op), Op} || Op <- operations()]) of
        {Id, Descriptor} -> {ok, Descriptor};
        false -> error
    end.

operation(Id, Answer, World, Evidence) ->
    {Description, Inputs, Examples} = details(Id),
    #{id => Id, description => Description, inputs => Inputs,
      answer => Answer, answer_shape => answer_shape(Id, Answer),
      world => World, world_description => world_description(World),
      evidence => Evidence, evidence_description => evidence_description(Evidence),
      examples => Examples,
      limits => <<"Results describe extracted facts in the configured scan; "
                 "they do not establish behavior outside that scope.">>}.

public_operation(Op) ->
    #{<<"id">> => atom_to_binary(maps:get(id, Op)),
      <<"description">> => maps:get(description, Op),
      <<"inputs">> => maps:get(inputs, Op),
      <<"answer_type">> => atom_to_binary(maps:get(answer, Op)),
      <<"answer_shape">> => maps:get(answer_shape, Op),
      <<"world">> => atom_to_binary(maps:get(world, Op)),
      <<"world_description">> => maps:get(world_description, Op),
      <<"evidence">> => atom_to_binary(maps:get(evidence, Op)),
      <<"evidence_description">> => maps:get(evidence_description, Op),
      <<"examples">> => maps:get(examples, Op),
      <<"limits">> => maps:get(limits, Op)}.

details(calls) ->
    {<<"Check whether a function calls another function.">>,
     [input(caller, function, <<"Function that may make the call.">>),
      input(callee, function, <<"Function that may be called.">>)],
     [<<"does foo/2 call bar/1?">>]};
details(defines) ->
    {<<"Check whether a function with an exact arity is defined.">>,
     [input(function, function, <<"Function name and arity.">>)],
     [<<"is foo/2 defined?">>]};
details(callers) ->
    {<<"List functions with a call fact targeting the named function.">>,
     [input(function, function, <<"Called function name and arity.">>)],
     [<<"which functions call bar/1?">>, <<"who calls bar/1?">>]};
details(callers_count) ->
    {<<"Count distinct functions with a call fact targeting the named function.">>,
     [input(function, function, <<"Called function name and arity.">>)],
     [<<"how many functions call bar/1?">>]};
details(prose_search) ->
    {<<"Find ranked prose evidence that matches a phrase.">>,
     [input(phrase, text, <<"Words or phrase to find in indexed prose.">>)],
     [<<"where is dirty scheduler documented?">>]};
details(uses) ->
    {<<"Check whether a function contains a reference to a named identifier.">>,
     [input(function, function, <<"Function to inspect.">>),
      input(identifier, identifier, <<"Identifier to find.">>)],
     [<<"does foo/2 use cache_key?">>]};
details(returns_mention) ->
    {<<"Check whether a function has a return expression mentioning a value.">>,
     [input(function, function, <<"Function to inspect.">>),
      input(value, identifier, <<"Value or identifier mentioned by a return.">>)],
     [<<"does foo/2 return result?">>]};
details(handles_literal) ->
    {<<"Check whether a function contains a matching literal.">>,
     [input(function, function, <<"Function to inspect.">>),
      input(literal, text, <<"Literal value to find.">>)],
     [<<"does getClaimPhoneErrorMessage/1 handle alreadySignedIn?">>]};
details(calls_in_file) ->
    {<<"Check whether a file contains a call to a named function.">>,
     [input(file, path, <<"File to inspect.">>),
      input(callee, function, <<"Function name and arity that may be called.">>)],
     [<<"does file JoinAccountModal.ts call setError/1?">>]};
details(uses_in_file) ->
    {<<"Check whether a file contains a reference to a named identifier.">>,
     [input(file, path, <<"File to inspect.">>),
      input(identifier, identifier, <<"Identifier to find.">>)],
     [<<"does file src/foo.ts use cache_key?">>]};
details(file_scanned) ->
    {<<"Check whether a file belongs to the parsed scan scope.">>,
     [input(file, path, <<"File path to check.">>)],
     [<<"is file src/foo.erl scanned?">>]};
details(config_defined) ->
    {<<"Check whether a configuration key is present in indexed configuration facts.">>,
     [input(key, identifier, <<"Configuration key to check.">>)],
     [<<"is config auth.codeExpiredError defined?">>]};
details(call_sites) ->
    {<<"List source locations where a named function is called.">>,
     [input(function, function, <<"Called function name and arity.">>)],
     [<<"where is foo/1 called?">>]};
details(definition_sites) ->
    {<<"List source locations that define a function with an exact arity.">>,
     [input(function, function, <<"Function name and arity.">>)],
     [<<"where is foo/1 defined?">>]}.

input(Name, Type, Description) ->
    #{<<"name">> => atom_to_binary(Name),
      <<"type">> => atom_to_binary(Type),
      <<"format">> => input_format(Type),
      <<"required">> => true,
      <<"description">> => Description}.

input_format(function) -> <<"name/arity; remote or member names may use module/name/arity">>;
input_format(path) -> <<"file path">>;
input_format(identifier) -> <<"code identifier">>;
input_format(text) -> <<"plain text">>.

answer_shape(_Id, yes_no) ->
    answer_object(<<"yes_no">>, #{<<"answer">> => #{<<"type">> => <<"boolean">>}},
        [<<"type">>, <<"answer">>]);
answer_shape(_Id, enumerate) ->
    answer_object(<<"enumerate">>, #{<<"answer">> => array_of(#{<<"type">> => <<"string">>})},
        [<<"type">>, <<"answer">>]);
answer_shape(_Id, count) ->
    answer_object(<<"count">>, #{<<"answer">> => #{<<"type">> => <<"integer">>}},
        [<<"type">>, <<"answer">>]);
answer_shape(_Id, prose) ->
    answer_object(<<"prose">>, #{<<"evidence">> => array_of(#{
        <<"type">> => <<"object">>,
        <<"properties">> => #{
            <<"kind">> => #{<<"type">> => <<"string">>},
            <<"file">> => #{<<"type">> => <<"string">>},
            <<"line">> => #{<<"type">> => <<"integer">>},
            <<"score">> => #{<<"type">> => <<"number">>}},
        <<"required">> => [<<"kind">>, <<"file">>, <<"line">>, <<"score">>]
    })}, [<<"type">>, <<"evidence">>]);
answer_shape(call_sites, sites) ->
    answer_object(<<"sites">>, #{<<"answer">> => array_of(#{
        <<"type">> => <<"object">>,
        <<"properties">> => #{
            <<"caller">> => #{<<"type">> => <<"string">>},
            <<"file">> => #{<<"type">> => <<"string">>},
            <<"line">> => #{<<"type">> => <<"integer">>}},
        <<"required">> => [<<"caller">>, <<"file">>, <<"line">>]
    })}, [<<"type">>, <<"answer">>]);
answer_shape(definition_sites, sites) ->
    answer_object(<<"sites">>, #{<<"answer">> => array_of(#{
        <<"type">> => <<"object">>,
        <<"properties">> => #{
            <<"function">> => #{<<"type">> => <<"string">>},
            <<"file">> => #{<<"type">> => <<"string">>},
            <<"line">> => #{<<"type">> => <<"integer">>}},
        <<"required">> => [<<"function">>, <<"file">>, <<"line">>]
    })}, [<<"type">>, <<"answer">>]).

answer_object(Type, Properties, Required) ->
    #{<<"type">> => <<"object">>,
      <<"properties">> => Properties#{<<"type">> => #{<<"const">> => Type}},
      <<"required">> => Required}.

array_of(ItemSchema) ->
    #{<<"type">> => <<"array">>, <<"items">> => ItemSchema}.

world_description(closed_world) ->
    <<"A negative answer means no matching extracted fact was found in the loaded fact base; it is limited by scan and extraction coverage.">>;
world_description(corpus_evidence) ->
    <<"Search returns matching indexed prose as evidence. No hits do not prove a claim false.">>;
world_description(scan_scope) ->
    <<"The answer describes the configured parse scope, not whether every file was successfully extracted.">>.

evidence_description(none) ->
    <<"This operation currently returns no source citations.">>;
evidence_description(source_location) ->
    <<"Returns source file and line locations for matching facts.">>.
