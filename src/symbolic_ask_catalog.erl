%%% The allowlisted operations that symbolic_ask may execute.
%%%
%%% Natural-language parsers produce typed templates, not Prolog source.
%%% This catalog is the validation seam: every template must map to a
%%% declared operation before the proof layer can run it. Add an operation
%%% here only after its semantics and answer shape are tested.
-module(symbolic_ask_catalog).
-export([lookup/2, operations/0]).

-spec operations() -> [map()].
operations() ->
    [
        operation(calls, yes_no, closed_world, none),
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
        operation(definition_sites, sites, closed_world, source_location)
    ].

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
    #{id => Id, answer => Answer, world => World, evidence => Evidence}.
