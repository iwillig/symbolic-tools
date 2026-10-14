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
    [operation(calls, yes_no, closed_world, source_location),
     operation(defines, yes_no, closed_world, source_location),
     operation(callers, enumerate, closed_world, source_location),
     operation(callers_count, count, closed_world, source_location),
     operation(prose_search, prose, corpus_evidence, source_location),
     operation(uses, yes_no, closed_world, source_location),
     operation(returns_mention, yes_no, closed_world, source_location),
     operation(handles_literal, yes_no, closed_world, source_location),
     operation(calls_in_file, yes_no, closed_world, source_location),
     operation(uses_in_file, yes_no, closed_world, source_location),
     operation(file_scanned, yes_no, scan_scope, source_location),
     operation(config_defined, yes_no, closed_world, source_location),
     operation(call_sites, sites, closed_world, source_location),
     operation(definition_sites, sites, closed_world, source_location)].

-spec describe() -> #{binary() => term()}.
describe() ->
    #{<<"operations">> => [public_operation(Op) || Op <- operations()],
      <<"ambiguity_answer_shape">> => ambiguity_answer_shape()}.

ambiguity_answer_shape() ->
    #{<<"type">> => <<"object">>,
      <<"properties">> => #{
          <<"type">> => #{<<"const">> => <<"ambiguous">>},
          <<"reason">> => #{<<"type">> => <<"string">>},
          <<"candidates">> => array_of(#{<<"type">> => <<"object">>,
              <<"properties">> => #{
                  <<"name">> => #{<<"type">> => <<"string">>},
                  <<"arity">> => #{<<"type">> => <<"integer">>},
                  <<"file">> => #{<<"type">> => <<"string">>},
                  <<"line">> => #{<<"type">> => <<"integer">>}},
              <<"required">> => [<<"name">>, <<"arity">>,
                  <<"file">>, <<"line">>]} )},
      <<"required">> => [<<"type">>, <<"reason">>, <<"candidates">>]}.

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
      incomplete_scan_answer_shape => incomplete_scan_answer_shape(World),
      world => World, world_description => world_description(World),
      evidence => Evidence, evidence_mode => evidence_mode(Id),
      evidence_description => evidence_description(Id, Evidence),
      evidence_limit => evidence_limit(Id),
      examples => Examples,
      limits => operation_limits(Id)}.

public_operation(Op) ->
    Base = #{<<"id">> => atom_to_binary(maps:get(id, Op)),
      <<"description">> => maps:get(description, Op),
      <<"inputs">> => maps:get(inputs, Op),
      <<"answer_type">> => atom_to_binary(maps:get(answer, Op)),
      <<"answer_shape">> => maps:get(answer_shape, Op),
      <<"incomplete_scan_answer_shape">> => maps:get(incomplete_scan_answer_shape, Op),
      <<"world">> => atom_to_binary(maps:get(world, Op)),
      <<"world_description">> => maps:get(world_description, Op),
      <<"evidence">> => atom_to_binary(maps:get(evidence, Op)),
      <<"evidence_mode">> => atom_to_binary(maps:get(evidence_mode, Op)),
      <<"evidence_description">> => maps:get(evidence_description, Op),
      <<"examples">> => maps:get(examples, Op),
      <<"limits">> => maps:get(limits, Op)},
    case maps:get(evidence_limit, Op) of
        undefined -> Base;
        Limit -> Base#{<<"evidence_limit">> => Limit}
    end.

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

answer_shape(calls, yes_no) ->
    answer_object(<<"yes_no">>, #{
        <<"answer">> => #{<<"type">> => <<"boolean">>},
        <<"evidence">> => array_of(call_evidence_schema())},
        [<<"type">>, <<"answer">>, <<"evidence">>]);
answer_shape(defines, yes_no) ->
    answer_object(<<"yes_no">>, #{
        <<"answer">> => #{<<"type">> => <<"boolean">>},
        <<"evidence">> => array_of(definition_evidence_schema())},
        [<<"type">>, <<"answer">>, <<"evidence">>]);
answer_shape(returns_mention, yes_no) ->
    yes_no_evidence_shape(returns_evidence_schema());
answer_shape(uses, yes_no) ->
    yes_no_evidence_shape(expr_ref_evidence_schema());
answer_shape(uses_in_file, yes_no) ->
    yes_no_evidence_shape(expr_ref_evidence_schema());
answer_shape(handles_literal, yes_no) ->
    yes_no_evidence_shape(literal_evidence_schema());
answer_shape(calls_in_file, yes_no) ->
    yes_no_evidence_shape(call_evidence_schema());
answer_shape(config_defined, yes_no) ->
    yes_no_evidence_shape(config_evidence_schema());
answer_shape(file_scanned, yes_no) ->
    yes_no_evidence_shape(file_scan_evidence_schema());
answer_shape(_Id, yes_no) ->
    answer_object(<<"yes_no">>, #{<<"answer">> => #{<<"type">> => <<"boolean">>}},
        [<<"type">>, <<"answer">>]);
answer_shape(callers, enumerate) ->
    answer_object(<<"enumerate">>, #{
        <<"answer">> => array_of(#{<<"type">> => <<"string">>}),
        <<"evidence">> => array_of(call_evidence_schema()),
        <<"evidence_complete">> => #{<<"type">> => <<"boolean">>}},
        [<<"type">>, <<"answer">>, <<"evidence">>, <<"evidence_complete">>]);
answer_shape(callers_count, count) ->
    answer_object(<<"count">>, #{
        <<"answer">> => #{<<"type">> => <<"integer">>},
        <<"evidence">> => array_of(call_evidence_schema()),
        <<"evidence_complete">> => #{<<"type">> => <<"boolean">>}},
        [<<"type">>, <<"answer">>, <<"evidence">>, <<"evidence_complete">>]);
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

call_evidence_schema() ->
    #{<<"type">> => <<"object">>,
      <<"properties">> => #{
          <<"predicate">> => #{<<"const">> => <<"calls">>},
          <<"file">> => #{<<"type">> => <<"string">>},
          <<"line">> => #{<<"type">> => <<"integer">>},
          <<"fact">> => #{<<"type">> => <<"object">>,
              <<"properties">> => #{
                  <<"caller">> => #{<<"type">> => <<"string">>},
                  <<"call">> => #{<<"oneOf">> => [
                      call_shape_schema(<<"local">>, [<<"name">>, <<"arity">>]),
                      call_shape_schema(<<"remote">>, [<<"module">>, <<"name">>, <<"arity">>]),
                      call_shape_schema(<<"member">>, [<<"receiver">>, <<"method">>, <<"arity">>])]}},
              <<"required">> => [<<"caller">>, <<"call">>]}},
      <<"required">> => [<<"predicate">>, <<"file">>, <<"line">>, <<"fact">>]}.

yes_no_evidence_shape(EvidenceSchema) ->
    answer_object(<<"yes_no">>, #{
        <<"answer">> => #{<<"type">> => <<"boolean">>},
        <<"evidence">> => array_of(EvidenceSchema)},
        [<<"type">>, <<"answer">>, <<"evidence">>]).

returns_evidence_schema() ->
    #{<<"oneOf">> => [
        return_fact_schema(<<"return_stmt">>, <<"has_value">>),
        return_fact_schema(<<"expr_ref">>, <<"identifier">>),
        return_fact_schema(<<"object_key">>, <<"key">>),
        return_object_key_evidence_schema()]}.

return_object_key_evidence_schema() ->
    #{<<"type">> => <<"object">>,
      <<"properties">> => #{
          <<"predicate">> => #{<<"const">> => <<"return_object_key">>},
          <<"file">> => #{<<"type">> => <<"string">>},
          <<"line">> => #{<<"type">> => <<"integer">>},
          <<"fact">> => #{<<"type">> => <<"object">>,
              <<"properties">> => #{
                  <<"function">> => #{<<"type">> => <<"string">>},
                  <<"key">> => #{<<"type">> => <<"string">>},
                  <<"key_line">> => #{<<"type">> => <<"integer">>}},
              <<"required">> => [<<"function">>, <<"key">>, <<"key_line">>]}},
      <<"required">> => [<<"predicate">>, <<"file">>, <<"line">>, <<"fact">>]}.

return_fact_schema(Predicate, DetailField) ->
    #{<<"type">> => <<"object">>,
      <<"properties">> => #{
          <<"predicate">> => #{<<"const">> => Predicate},
          <<"file">> => #{<<"type">> => <<"string">>},
          <<"line">> => #{<<"type">> => <<"integer">>},
          <<"fact">> => #{<<"type">> => <<"object">>,
              <<"properties">> => #{
                  <<"function">> => #{<<"type">> => <<"string">>},
                  DetailField => return_detail_schema(DetailField)},
              <<"required">> => [<<"function">>, DetailField]}},
      <<"required">> => [<<"predicate">>, <<"file">>, <<"line">>, <<"fact">>]}.

return_detail_schema(<<"has_value">>) -> #{<<"type">> => <<"boolean">>};
return_detail_schema(_Field) -> #{<<"type">> => <<"string">>}.

expr_ref_evidence_schema() ->
    #{<<"type">> => <<"object">>,
      <<"properties">> => #{
          <<"predicate">> => #{<<"const">> => <<"expr_ref">>},
          <<"file">> => #{<<"type">> => <<"string">>},
          <<"line">> => #{<<"type">> => <<"integer">>},
          <<"fact">> => #{<<"type">> => <<"object">>,
              <<"properties">> => #{
                  <<"function">> => #{<<"type">> => <<"string">>},
                  <<"identifier">> => #{<<"type">> => <<"string">>}},
              <<"required">> => [<<"function">>, <<"identifier">>]}},
      <<"required">> => [<<"predicate">>, <<"file">>, <<"line">>, <<"fact">>]}.

file_scan_evidence_schema() ->
    #{<<"type">> => <<"object">>,
      <<"properties">> => #{
          <<"predicate">> => #{<<"enum">> => [<<"defines">>, <<"comment">>,
              <<"paragraph">>, <<"config_value">>]},
          <<"file">> => #{<<"type">> => <<"string">>},
          <<"line">> => #{<<"type">> => <<"integer">>},
          <<"fact">> => #{<<"type">> => <<"object">>}},
      <<"required">> => [<<"predicate">>, <<"file">>, <<"line">>, <<"fact">>]}.

config_evidence_schema() ->
    #{<<"type">> => <<"object">>,
      <<"properties">> => #{
          <<"predicate">> => #{<<"const">> => <<"config_value">>},
          <<"file">> => #{<<"type">> => <<"string">>},
          <<"line">> => #{<<"type">> => <<"integer">>},
          <<"fact">> => #{<<"type">> => <<"object">>,
              <<"properties">> => #{
                  <<"key">> => #{<<"type">> => <<"string">>},
                  <<"value">> => #{<<"type">> => <<"string">>}},
              <<"required">> => [<<"key">>, <<"value">>]}},
      <<"required">> => [<<"predicate">>, <<"file">>, <<"line">>, <<"fact">>]}.

literal_evidence_schema() ->
    #{<<"type">> => <<"object">>,
      <<"properties">> => #{
          <<"predicate">> => #{<<"const">> => <<"literal">>},
          <<"file">> => #{<<"type">> => <<"string">>},
          <<"line">> => #{<<"type">> => <<"integer">>},
          <<"fact">> => #{<<"type">> => <<"object">>,
              <<"properties">> => #{
                  <<"function">> => #{<<"type">> => <<"string">>},
                  <<"kind">> => #{<<"type">> => <<"string">>},
                  <<"value">> => #{<<"type">> => <<"string">>}},
              <<"required">> => [<<"function">>, <<"kind">>, <<"value">>]}},
      <<"required">> => [<<"predicate">>, <<"file">>, <<"line">>, <<"fact">>]}.

definition_evidence_schema() ->
    #{<<"type">> => <<"object">>,
      <<"properties">> => #{
          <<"predicate">> => #{<<"const">> => <<"defines">>},
          <<"file">> => #{<<"type">> => <<"string">>},
          <<"line">> => #{<<"type">> => <<"integer">>},
          <<"fact">> => #{<<"type">> => <<"object">>,
              <<"properties">> => #{<<"function">> => #{<<"type">> => <<"string">>}},
              <<"required">> => [<<"function">>]}},
      <<"required">> => [<<"predicate">>, <<"file">>, <<"line">>, <<"fact">>]}.

call_shape_schema(Kind, Fields) ->
    Properties0 = maps:from_list([{Field, #{<<"type">> => <<"string">>}}
        || Field <- Fields, Field =/= <<"arity">>]),
    Properties = Properties0#{<<"kind">> => #{<<"const">> => Kind},
        <<"arity">> => #{<<"type">> => <<"integer">>}},
    #{<<"type">> => <<"object">>, <<"properties">> => Properties,
      <<"required">> => [<<"kind">> | Fields]}.

answer_object(Type, Properties, Required) ->
    #{<<"type">> => <<"object">>,
      <<"properties">> => Properties#{<<"type">> => #{<<"const">> => Type}},
      <<"required">> => Required}.

array_of(ItemSchema) ->
    #{<<"type">> => <<"array">>, <<"items">> => ItemSchema}.

incomplete_scan_answer_shape(corpus_evidence) -> null;
incomplete_scan_answer_shape(_World) ->
    #{<<"type">> => <<"object">>,
      <<"properties">> => #{
          <<"type">> => #{<<"const">> => <<"unknown">>},
          <<"reason">> => #{<<"type">> => <<"string">>},
          <<"scope">> => #{<<"type">> => <<"object">>,
              <<"properties">> => #{
                  <<"scan_paths">> => array_of(#{<<"type">> => <<"string">>}),
                  <<"files">> => #{<<"type">> => <<"integer">>},
                  <<"complete">> => #{<<"type">> => <<"boolean">>},
                  <<"metadata_available">> => #{<<"type">> => <<"boolean">>},
                  <<"failed_files">> => array_of(#{<<"type">> => <<"string">>})},
              <<"required">> => [<<"scan_paths">>, <<"files">>,
                  <<"complete">>, <<"metadata_available">>, <<"failed_files">>]}},
      <<"required">> => [<<"type">>, <<"reason">>, <<"scope">>]}.

world_description(closed_world) ->
    <<"A negative answer is scoped to the loaded fact base. If scan metadata is missing or extraction failed, ASK returns unknown instead of treating absence as false.">>;
world_description(corpus_evidence) ->
    <<"Search returns matching indexed prose as evidence. No hits do not prove a claim false.">>;
world_description(scan_scope) ->
    <<"The answer describes the configured parse scope, not whether every file was successfully extracted.">>.

evidence_mode(calls) -> witness;
evidence_mode(callers) -> capped_matches;
evidence_mode(callers_count) -> capped_matches;
evidence_mode(defines) -> witness;
evidence_mode(uses) -> witness;
evidence_mode(returns_mention) -> witness_pair;
evidence_mode(uses_in_file) -> witness;
evidence_mode(handles_literal) -> witness;
evidence_mode(calls_in_file) -> witness;
evidence_mode(config_defined) -> witness;
evidence_mode(file_scanned) -> witness;
evidence_mode(call_sites) -> all_matches;
evidence_mode(definition_sites) -> all_matches;
evidence_mode(prose_search) -> ranked_results;
evidence_mode(_) -> none.

evidence_description(callers, source_location) ->
    <<"Returns one calls fact per distinct caller, capped at 50; evidence_complete indicates whether every caller has a witness.">>;
evidence_description(callers_count, source_location) ->
    <<"Returns one calls fact per distinct caller, capped at 50; evidence_complete indicates whether every caller is cited.">>;
evidence_description(calls, source_location) ->
    <<"Returns one deterministic matching calls fact as a source witness; false answers have no witness.">>;
evidence_description(returns_mention, source_location) ->
    <<"Returns a valued return_stmt and its matching expr_ref or object_key. Multiline returned-object keys include a structural return_object_key witness. This is syntax-level mention evidence, not value-flow proof.">>;
evidence_description(uses, source_location) ->
    <<"Returns one deterministic matching expr_ref fact as a source witness; false answers have no witness.">>;
evidence_description(uses_in_file, source_location) ->
    <<"Returns one deterministic matching expr_ref fact in the named file; false answers have no witness.">>;
evidence_description(file_scanned, source_location) ->
    <<"Returns one deterministic fact whose file matches the named file; false answers have no witness.">>;
evidence_description(config_defined, source_location) ->
    <<"Returns one deterministic matching config_value fact; false answers have no witness.">>;
evidence_description(handles_literal, source_location) ->
    <<"Returns one deterministic matching literal fact, including its kind and value; false answers have no witness.">>;
evidence_description(calls_in_file, source_location) ->
    <<"Returns one deterministic matching calls fact in the named file; false answers have no witness.">>;
evidence_description(defines, source_location) ->
    <<"Returns one deterministic matching defines fact as a source witness; false answers have no witness.">>;
evidence_description(call_sites, source_location) ->
    <<"Returns source file and line locations for all matching calls.">>;
evidence_description(definition_sites, source_location) ->
    <<"Returns source file and line locations for all matching definitions.">>;
evidence_description(prose_search, source_location) ->
    <<"Returns ranked prose hits with source file and line locations.">>;
evidence_description(_Id, none) ->
    <<"This operation currently returns no source citations.">>;
evidence_description(_Id, source_location) ->
    <<"Returns source file and line locations for matching facts.">>.

evidence_limit(callers) -> 50;
evidence_limit(callers_count) -> 50;
evidence_limit(_) -> undefined.

operation_limits(callers) ->
    <<"Callers with a known name but unknown arity appear as name/?. If any caller name is missing, returns unknown instead of a partial list. Cites at most 50 callers; evidence_complete reports citation truncation.">>;
operation_limits(callers_count) ->
    <<"Callers with a known name but unknown arity appear as name/?. If any caller name is missing, returns unknown instead of a partial count. Cites at most 50 callers; evidence_complete reports citation truncation.">>;
operation_limits(_Id) ->
    <<"Results describe extracted facts in the configured scan; they do not establish behavior outside that scope.">>.
