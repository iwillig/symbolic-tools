%%% Minimal client for the version-matched TypeScript 7 native API.
%%% The API uses MessagePack tuple framing with JSON payloads; this module
%%% deliberately implements only the operations needed by Symbolic and does
%%% not require Node or TypeScript source code.
-module(symbolic_tsgo).

-export([resolve/1, analyze/3]).

%% Whole-project deadline; a large project can spend 30s in diagnostics alone.
%% Keep a finite cap so a stuck compiler cannot stall the scan indefinitely.
-define(TIMEOUT_MS, 90000).
-define(MAX_MESSAGE_BYTES, 33554432).
-define(MAX_LOCATIONS, 20000).
-define(MAX_TYPES, 10000).
-define(MAX_EDGES, 50000).
-define(MAX_TYPE_DEPTH, 12).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

location_facts_scaling_test_() ->
    {timeout, 60, fun() ->
        {SmallUs, _} = timer:tc(fun() -> location_facts_fixture(2000) end),
        {LargeUs, _} = timer:tc(fun() -> location_facts_fixture(8000) end),
        ?debugFmt("location_facts: 2k=~p us 8k=~p us", [SmallUs, LargeUs]),
        ?assert(LargeUs < 12 * max(1, SmallUs))
    end}.

location_facts_deduplicates_symbols_test() ->
    File = "/tmp/symbolic-tsgo-dedup.ts",
    Location = #{start => 0, 'end' => 1, category => reference},
    Symbol = #{<<"id">> => 42, <<"name">> => <<"same">>, <<"flags">> => 8},
    Rows = [{File, <<>>, Location, #{<<"id">> => 1}, Symbol},
            {File, <<>>, Location#{start => 2, 'end' => 3}, #{<<"id">> => 1}, Symbol}],
    {Symbols, _, _, TypesAt, Links} = location_facts(
        Rows, #{nodes => [#{<<"id">> => <<"1">>}]}),
    ?assertEqual([#{<<"id">> => <<"42">>, <<"name">> => <<"same">>,
                    <<"kind">> => <<"value">>}], Symbols),
    ?assertEqual(2, length(TypesAt)),
    ?assertEqual(2, length(Links)).

location_facts_fixture(Count) ->
    File = "/tmp/symbolic-tsgo-perf.ts",
    Locations = [{File, <<>>, #{start => I, 'end' => I + 1,
                     category => reference},
                  #{<<"id">> => 1},
                  #{<<"id">> => I, <<"name">> => <<"symbol">>, <<"flags">> => 8}}
                 || I <- lists:seq(1, Count)],
    {Symbols, _, _, TypesAt, _} = location_facts(Locations,
                                                #{nodes => [#{<<"id">> => <<"1">>}]}),
    ?assertEqual(Count, length(Symbols)),
    ?assertEqual(Count, length(TypesAt)).
-endif.

-spec resolve(file:filename()) -> {ok, map()} | {error, atom()}.
resolve(ConfigPath) ->
    case find_typescript_package(filename:dirname(filename:absname(ConfigPath))) of
        {ok, PackageRoot, Version} ->
            case Version of
                <<"7.0.2">> -> resolve_native_binary(PackageRoot, Version);
                _ -> {error, unsupported_compiler_api}
            end;
        error -> {error, compiler_missing}
    end.

-spec analyze(map(), file:filename(), map()) -> {ok, map()} | {error, term()}.
analyze(Report, ConfigPath, Compiler) ->
    Started = erlang:monotonic_time(microsecond),
    Exe = maps:get(executable, Compiler),
    Cwd = filename:dirname(filename:absname(ConfigPath)),
    Args = ["--api", "--cwd", Cwd],
    Result = try open_port({spawn_executable, Exe},
            [binary, exit_status, use_stdio, hide, {args, Args},
             {env, [{"GOMEMLIMIT", "768MiB"}]}]) of
        Port ->
            try analyze_port(Port, Report, ConfigPath, maps:get(version, Compiler))
            after
                try port_close(Port) catch _:_ -> ok end
            end
    catch
        error:Reason -> {error, {worker_start, Reason}}
    end,
    add_worker_total_timing(Result, elapsed_ms(Started)).

analyze_port(Port, Report, ConfigPath, Version) ->
    Deadline = erlang:monotonic_time(millisecond) + ?TIMEOUT_MS,
    put(symbolic_tsgo_current_stage, initialize),
    put(symbolic_tsgo_stage_timings, #{}),
    try
        {Init, Buffer1} = timed_stage(initialize, fun() ->
            rpc(Port, <<>>, Deadline, "initialize", null)
        end),
        true = is_map(Init),
        {_Parsed, Buffer2} = timed_stage(parse_config, fun() ->
            rpc(Port, Buffer1, Deadline, "parseConfigFile",
                #{<<"file">> => filename_binary(ConfigPath)})
        end),
        {Snapshot, Buffer3} = timed_stage(update_snapshot, fun() ->
            rpc(Port, Buffer2, Deadline, "updateSnapshot",
                 #{<<"openProjects">> => [filename_binary(ConfigPath)]})
        end),
        SnapshotId = required_json_value(Snapshot, <<"snapshot">>),
        [Project | _] = required_json_value(Snapshot, <<"projects">>),
        ProjectId = required_json_value(Project, <<"id">>),
        Context = #{<<"snapshot">> => SnapshotId, <<"project">> => ProjectId},
        {SourceFileNames, Buffer4} = timed_stage(source_files, fun() ->
            rpc(Port, Buffer3, Deadline, "getSourceFileNames", Context)
        end),
        ProjectFiles = intersect_files(SourceFileNames, maps:get(files, Report, [])),
        {Diagnostics0, Buffer5} = timed_stage(diagnostics, fun() ->
            collect_diagnostics(Port, Buffer4, Deadline, Context, ProjectFiles)
        end),
        {LocationTypes, Buffer6, Truncated, SourceMap} = timed_stage(locations, fun() ->
            query_locations(Port, Buffer5, Deadline, Context, Report, ProjectFiles)
        end),
        {Graph, _Buffer7, GraphTruncated} = timed_stage(type_graph, fun() ->
            build_type_graph(Port, Buffer6, Deadline, Context, LocationTypes)
        end),
        Result = timed_stage(result_conversion, fun() ->
            make_result(Version, Snapshot, ProjectFiles, SourceMap, Diagnostics0,
                        LocationTypes, Graph, Truncated orelse GraphTruncated)
        end),
        {ok, Result#{<<"timingsMs">> => stage_timings()}}
    catch
        throw:{tsgo, Reason} ->
            {error, {tsgo_stage, get(symbolic_tsgo_current_stage), Reason, stage_timings()}};
        error:{badmatch, _} ->
            {error, {tsgo_stage, get(symbolic_tsgo_current_stage),
                     invalid_worker_output, stage_timings()}};
        error:Reason ->
            {error, {tsgo_stage, get(symbolic_tsgo_current_stage),
                     {worker_crash, Reason}, stage_timings()}}
    after
        erase(symbolic_tsgo_current_stage),
        erase(symbolic_tsgo_stage_timings)
    end.

timed_stage(Stage, Fun) ->
    put(symbolic_tsgo_current_stage, Stage),
    Started = erlang:monotonic_time(microsecond),
    try Fun()
    after
        Duration = elapsed_ms(Started),
        Timings = stage_timings(),
        StageKey = atom_to_binary(Stage, utf8),
        put(symbolic_tsgo_stage_timings,
            maps:update_with(StageKey, fun(Previous) -> Previous + Duration end,
                             Duration, Timings))
    end.

stage_timings() ->
    case get(symbolic_tsgo_stage_timings) of
        Timings when is_map(Timings) -> Timings;
        _ -> #{}
    end.

elapsed_ms(StartedMicroseconds) ->
    (erlang:monotonic_time(microsecond) - StartedMicroseconds + 500) div 1000.

add_worker_total_timing({ok, Json}, TotalMs) ->
    Timings = maps:get(<<"timingsMs">>, Json, #{}),
    {ok, Json#{<<"timingsMs">> => Timings#{<<"worker_total">> => TotalMs}}};
add_worker_total_timing({error, {tsgo_stage, Stage, Reason, Timings}}, TotalMs) ->
    {error, {tsgo_stage, Stage, Reason, Timings#{<<"worker_total">> => TotalMs}}};
add_worker_total_timing(Result, _TotalMs) ->
    Result.

collect_diagnostics(Port, Buffer0, Deadline, Context, Files) ->
    lists:foldl(fun(File, {Acc, Buffer}) ->
        FileContext = Context#{<<"file">> => filename_binary(File)},
        {Syntactic, Buffer1} = timed_stage(syntactic_diagnostics, fun() ->
            rpc(Port, Buffer, Deadline, "getSyntacticDiagnostics", FileContext)
        end),
        {Semantic, Buffer2} = timed_stage(semantic_diagnostics, fun() ->
            rpc(Port, Buffer1, Deadline, "getSemanticDiagnostics", FileContext)
        end),
        {Semantic ++ Syntactic ++ Acc, Buffer2}
    end, {[], Buffer0}, Files).

query_locations(Port, Buffer0, Deadline, Context, Report, Files) ->
    {SourceMap, ByFile, Truncated} = timed_stage(location_selection, fun() ->
        InScope = maps:from_list([{filename:absname(F), true} || F <- Files]),
        Facts = location_facts_for_project(Report, Files, InScope),
        SourceMap = read_sources(Files),
        RawLocations = lists:append([
            variable_locations(Facts), reference_locations(Facts),
            function_locations(Facts, SourceMap)
        ]),
        Locations0 = unique_locations([L || L <- RawLocations,
                                             maps:is_key(maps:get(file, L), InScope)]),
        {Locations, WasTruncated} = limit_list(Locations0, ?MAX_LOCATIONS),
        {SourceMap, group_locations(Locations), WasTruncated}
    end),
    {TypesRev, Buffer, Truncated2} = maps:fold(fun(File, FileLocations, {Acc, Buf, Trunc}) ->
        Source = maps:get(File, SourceMap, <<>>),
        Starts = [Start || #{start := Start} <- FileLocations],
        Positions = timed_stage(offset_conversion, fun() ->
            byte_offsets_to_utf16(Source, Starts)
        end),
        Params = Context#{<<"file">> => filename_binary(File), <<"positions">> => Positions},
        {Types, NextBuf} = timed_stage(type_queries, fun() ->
            rpc(Port, Buf, Deadline, "getTypesAtPositions", Params)
        end),
        {Symbols, NextBuf2} = timed_stage(symbol_queries, fun() ->
            rpc(Port, NextBuf, Deadline, "getSymbolsAtPositions", Params)
        end),
        true = is_list(Types) andalso is_list(Symbols),
        true = length(Types) =:= length(FileLocations),
        true = length(Symbols) =:= length(FileLocations),
        Pairs = zip_locations(FileLocations, Types, Symbols),
        {[{File, Source, Location, Type, Symbol} || {Location, Type, Symbol} <- Pairs] ++ Acc,
         NextBuf2, Trunc}
    end, {[], Buffer0, Truncated}, ByFile),
    {lists:reverse(TypesRev), Buffer, Truncated2, SourceMap}.

location_facts_for_project(Report, Files, InScope) ->
    case maps:get(typescript_location_facts_by_file, Report, undefined) of
        Index when is_map(Index) ->
            lists:append([maps:get(filename:absname(File), Index, []) || File <- Files]);
        _ -> project_location_facts(maps:get(facts, Report, []), InScope)
    end.

project_location_facts(Facts, InScope) ->
    [Fact || Fact <- Facts,
             case location_fact_path(Fact) of
                 undefined -> false;
                 Path -> maps:is_key(Path, InScope)
             end].

location_fact_path({var_decl, {File, _, _}, _, _, _, File, _}) when is_atom(File) ->
    filename:absname(atom_to_list(File));
location_fact_path({var_ref, {File, _, _}, _, _, _, File, _}) when is_atom(File) ->
    filename:absname(atom_to_list(File));
location_fact_path({function_decl, {File, _, _}, _, _, _, _, File, _}) when is_atom(File) ->
    filename:absname(atom_to_list(File));
location_fact_path({ts_syntax_type, File, _, _, _, _, _, _, _}) when is_atom(File) ->
    filename:absname(atom_to_list(File));
location_fact_path(_) -> undefined.

variable_locations(Facts) ->
    ExplicitAnnotations = explicit_variable_annotations(Facts),
    [variable_location(File, Start, End, Name, Kind, Line, ExplicitAnnotations) ||
        {var_decl, {File, Start, End}, Name, Kind, _Scope, File, Line} <- Facts,
        is_atom(File), is_integer(Start), is_integer(End)].

explicit_variable_annotations(Facts) ->
    lists:foldl(fun
        ({ts_syntax_type, FactFile, Subject, FactName, annotation, _, _, _, FactLine}, Acc) ->
            Key = {file_path(FactFile), Subject, name_binary(FactName), FactLine},
            maps:put(Key, true, Acc);
        (_, Acc) -> Acc
    end, #{}, Facts).

variable_location(File0, Start, End, Name, Kind, Line, ExplicitAnnotations) ->
    File = file_path(File0),
    Key = {File, subject_kind(Kind), name_binary(Name), Line},
    Explicit = maps:is_key(Key, ExplicitAnnotations),
    (location(File, Start, End, Name, variable, Kind, Line))#{explicit => Explicit}.

reference_locations(Facts) ->
    [location(file_path(File), Start, End, Name, reference, RefKind, Line) ||
        {var_ref, {File, Start, End}, Name, _Scope, RefKind, File, Line} <- Facts,
        is_atom(File), is_integer(Start), is_integer(End)].

function_locations(Facts, SourceMap) ->
    ReturnAnnotations = function_return_annotations(Facts),
    [function_location(Path, Start, End, Name, Line, Source,
                       function_has_return_type(ReturnAnnotations, File, Start, End, Name)) ||
        {function_decl, {File, Start, End}, _Language, Name, _Arity, _Kind, File, Line} <- Facts,
        is_atom(File), is_integer(Start), is_integer(End),
        Path <- [file_path(File)],
        Source <- [maps:get(Path, SourceMap, <<>>)],
        function_name_range(Source, Start, End, Name) =/= error].

function_location(File, Start, End, Name, Line, Source, Explicit) ->
    {NameStart, NameEnd} = function_name_range(Source, Start, End, Name),
    (location(File, NameStart, NameEnd, Name, function, function, Line))#{
        declaration_start => Start, declaration_end => End, explicit => Explicit}.

function_return_annotations(Facts) ->
    lists:foldl(fun
        ({ts_syntax_type, FactFile, function, FactName, return_type, _, Start, End, _}, Acc) ->
            Key = {file_path(FactFile), name_binary(FactName)},
            maps:update_with(Key, fun(Spans) -> [{Start, End} | Spans] end,
                             [{Start, End}], Acc);
        (_, Acc) -> Acc
    end, #{}, Facts).

function_has_return_type(Annotations, File, DeclStart, DeclEnd, Name) ->
    Key = {file_path(File), name_binary(Name)},
    lists:any(fun({Start, End}) -> Start >= DeclStart andalso End =< DeclEnd end,
              maps:get(Key, Annotations, [])).

subject_kind('param') -> parameter;
subject_kind(_) -> variable.

function_name_range(Source, Start, End, Name) ->
    NameBin = name_binary(Name),
    case End > Start andalso End =< byte_size(Source) of
        false -> error;
        true ->
            Span = binary:part(Source, Start, End - Start),
            case binary:match(Span, NameBin) of
                {Offset, Length} when Length > 0 -> {Start + Offset, Start + Offset + Length};
                nomatch -> error
            end
    end.

file_path(File) when is_atom(File) -> filename:absname(atom_to_list(File));
file_path(File) when is_list(File) -> filename:absname(File).

location(File, Start, End, Name, Category, Kind, Line) ->
    #{file => File, start => Start, 'end' => End, name => name_binary(Name),
      category => Category, kind => Kind, line => Line}.

unique_locations(Locations) ->
    Unique = maps:values(lists:foldl(fun(Location, Acc) ->
        Key = {maps:get(file, Location), maps:get(start, Location), maps:get('end', Location),
               maps:get(category, Location)},
        maps:put(Key, Location, Acc)
    end, #{}, Locations)),
    lists:sort(fun location_before/2, Unique).

location_before(Left, Right) -> location_sort_key(Left) < location_sort_key(Right).

location_sort_key(Location) ->
    Priority = case maps:get(category, Location) of
        function -> 0;
        variable -> 1;
        reference -> 2
    end,
    {Priority, maps:get(file, Location), maps:get(start, Location), maps:get('end', Location)}.

group_locations(Locations) ->
    lists:foldl(fun(Location, Acc) ->
        File = maps:get(file, Location),
        maps:update_with(File, fun(Items) -> [Location | Items] end, [Location], Acc)
    end, #{}, Locations).

zip_locations([], [], []) -> [];
zip_locations([Location | Locations], [Type | Types], [Symbol | Symbols]) ->
    [{Location, Type, normalize_symbol(Symbol, Location)} |
     zip_locations(Locations, Types, Symbols)];
zip_locations(_, _, _) -> throw({tsgo, invalid_worker_output}).

normalize_symbol(Symbol, #{name := Name} = Location) when is_map(Symbol) ->
    case display_binary(maps:get(<<"name">>, Symbol, <<>>)) of
        Name -> Symbol;
        _ -> fallback_symbol(Location)
    end;
normalize_symbol(_Symbol, Location) -> fallback_symbol(Location).

fallback_symbol(#{category := function, file := File,
                  start := Start, 'end' := End, name := Name}) ->
    #{<<"id">> => <<"sym:", (filename_binary(File))/binary, ":",
                    (integer_to_binary(Start))/binary, ":", (integer_to_binary(End))/binary>>,
      <<"name">> => Name, <<"flags">> => 16};
fallback_symbol(_) -> undefined.

build_type_graph(Port, Buffer, Deadline, Context, LocationTypes) ->
    Initial = [{Type, 0} || {_File, _Source, _Location, Type, _Symbol} <- LocationTypes,
                            is_map(Type)],
    build_types(Port, Buffer, Deadline, Context, Initial, #{}, [], [], false, 0).

build_types(_Port, Buffer, _Deadline, _Context, [], _Seen, Nodes, Edges, Truncated, _EdgeCount) ->
    {#{nodes => lists:reverse(Nodes), edges => lists:reverse(Edges)}, Buffer, Truncated};
build_types(Port, Buffer, Deadline, Context, [{Type, Depth} | Rest], Seen, Nodes, Edges,
            Truncated, EdgeCount) ->
    TypeId = required_json_value(Type, <<"id">>),
    Key = json_id(TypeId),
    case maps:is_key(Key, Seen) of
        true -> build_types(Port, Buffer, Deadline, Context, Rest, Seen, Nodes, Edges,
                            Truncated, EdgeCount);
        false when map_size(Seen) >= ?MAX_TYPES ->
            build_types(Port, Buffer, Deadline, Context, Rest, Seen, Nodes, Edges,
                        true, EdgeCount);
        false ->
            Flags = maps:get(<<"flags">>, Type, 0),
            {Display, Buffer1} = rpc(Port, Buffer, Deadline, "typeToString",
                Context#{<<"type">> => TypeId, <<"flags">> => 1}),
            Node = #{<<"id">> => Key, <<"kind">> => type_kind(Flags),
                     <<"display">> => display_binary(Display)},
            {Children0, Buffer2, ChildTruncated0} =
                case Depth >= ?MAX_TYPE_DEPTH of
                    true -> {[], Buffer1, type_has_children(Type, Flags)};
                    false -> type_children(Port, Buffer1, Deadline, Context, Type, Flags)
                end,
            TypeBudget = max(0, ?MAX_TYPES - map_size(Seen) - 1),
            {Children, TypeTruncated} = limit_type_children(
                Children0, maps:put(Key, true, Seen), TypeBudget),
            NewEdges0 = [#{<<"parent">> => Key, <<"role">> => Role,
                           <<"child">> => json_id(required_json_value(Child, <<"id">>))}
                         || {Role, Child} <- Children],
            {NewEdges, EdgeTruncated} = limit_list(NewEdges0, ?MAX_EDGES - EdgeCount),
            KeptChildren = lists:sublist(Children, length(NewEdges)),
            build_types(Port, Buffer2, Deadline, Context,
                [{Child, Depth + 1} || {_Role, Child} <- KeptChildren] ++ Rest,
                maps:put(Key, true, Seen), [Node | Nodes], NewEdges ++ Edges,
                Truncated orelse ChildTruncated0 orelse TypeTruncated orelse EdgeTruncated,
                EdgeCount + length(NewEdges))
    end.

type_children(Port, Buffer, Deadline, Context, Type, Flags)
        when is_integer(Flags), Flags band 402653184 =/= 0 ->
    type_children_rpc(Port, Buffer, Deadline, Context, Type,
                      "getTypesOfType", <<"objectId">>, <<"constituent:">>);
type_children(Port, Buffer, Deadline, Context,
              #{<<"id">> := TypeId, <<"objectFlags">> := ObjectFlags}, Flags)
        when is_integer(Flags), Flags band 1048576 =/= 0,
             is_integer(ObjectFlags), ObjectFlags band 4 =/= 0 ->
    type_children_rpc(Port, Buffer, Deadline, Context, #{<<"id">> => TypeId},
                      "getTypeArguments", <<"type">>, <<"type_argument:">>);
type_children(_Port, Buffer, _Deadline, _Context, _Type, _Flags) -> {[], Buffer, false}.

type_has_children(_Type, Flags) when is_integer(Flags), Flags band 402653184 =/= 0 -> true;
type_has_children(#{<<"objectFlags">> := ObjectFlags}, Flags)
        when is_integer(Flags), Flags band 1048576 =/= 0,
             is_integer(ObjectFlags), ObjectFlags band 4 =/= 0 -> true;
type_has_children(_, _) -> false.

limit_type_children(Children, Seen, Budget) ->
    {KeptRev, _Seen, _Count, Truncated} = lists:foldl(fun({_Role, Type} = Pair,
            {Kept, SeenTypes, Count, WasTruncated}) ->
        Id = json_id(required_json_value(Type, <<"id">>)),
        case maps:is_key(Id, SeenTypes) of
            true -> {[Pair | Kept], SeenTypes, Count, WasTruncated};
            false when Count < Budget ->
                {[Pair | Kept], maps:put(Id, true, SeenTypes), Count + 1, WasTruncated};
            false -> {Kept, SeenTypes, Count, true}
        end
    end, {[], Seen, 0, false}, Children),
    {lists:reverse(KeptRev), Truncated}.

type_children_rpc(Port, Buffer, Deadline, Context, Type, Method, Key, Prefix) ->
    TypeId = required_json_value(Type, <<"id">>),
    {Children, NextBuffer} = rpc(Port, Buffer, Deadline, Method, Context#{Key => TypeId}),
    case is_list(Children) of
        true ->
            Pairs = [{<<Prefix/binary, (integer_to_binary(I))/binary>>, Child} ||
                {Child, I} <- lists:zip(Children, lists:seq(0, length(Children) - 1)),
                is_map(Child)],
            {Pairs, NextBuffer, false};
        false -> {[], NextBuffer, true}
    end.

type_kind(Flags) when is_integer(Flags), Flags band 402653184 =/= 0,
                       Flags band 134217728 =/= 0 -> <<"union">>;
type_kind(Flags) when is_integer(Flags), Flags band 402653184 =/= 0 -> <<"intersection">>;
type_kind(Flags) when is_integer(Flags), Flags band 1 =/= 0 -> <<"any">>;
type_kind(Flags) when is_integer(Flags), Flags band 2 =/= 0 -> <<"unknown">>;
type_kind(Flags) when is_integer(Flags), Flags band 262144 =/= 0 -> <<"never">>;
type_kind(Flags) when is_integer(Flags), Flags band 1024 =/= 0 -> <<"string_literal">>;
type_kind(Flags) when is_integer(Flags), Flags band 2048 =/= 0 -> <<"number_literal">>;
type_kind(Flags) when is_integer(Flags), Flags band 8192 =/= 0 -> <<"boolean_literal">>;
type_kind(Flags) when is_integer(Flags), Flags band 12583968 =/= 0 -> <<"string">>;
type_kind(Flags) when is_integer(Flags), Flags band 67648 =/= 0 -> <<"number">>;
type_kind(Flags) when is_integer(Flags), Flags band 8448 =/= 0 -> <<"boolean">>;
type_kind(Flags) when is_integer(Flags), Flags band 4224 =/= 0 -> <<"bigint">>;
type_kind(Flags) when is_integer(Flags), Flags band 8 =/= 0 -> <<"null">>;
type_kind(Flags) when is_integer(Flags), Flags band 4 =/= 0 -> <<"undefined">>;
type_kind(Flags) when is_integer(Flags), Flags band 524288 =/= 0 -> <<"type_parameter">>;
type_kind(Flags) when is_integer(Flags), Flags band 1048576 =/= 0 -> <<"object">>;
type_kind(_) -> <<"other">>.

make_result(Version, Snapshot, Files, SourceMap, Diagnostics0, LocationTypes, Graph, Truncated) ->
    Allowed = maps:from_list([{filename:absname(F), true} || F <- Files]),
    Diagnostics = [diagnostic_json(D, Allowed, SourceMap) || D <- Diagnostics0,
                    is_map(D), diagnostic_in_scope(D, Allowed)],
    {Symbols, Declarations, DeclaredTypes, TypesAt, LocationSymbols} =
        location_facts(LocationTypes, Graph),
    Status = case Truncated of true -> <<"partial">>; false -> <<"ok">> end,
    Reason = case Truncated of true -> <<"resource_limit">>; false -> <<"none">> end,
    #{<<"schemaVersion">> => 1, <<"status">> => Status, <<"reason">> => Reason,
      <<"compilerVersion">> => Version, <<"optionsHash">> => null,
      <<"filesProcessed">> => project_file_count(Snapshot),
      <<"symbols">> => Symbols, <<"declarations">> => Declarations,
      <<"declaredTypes">> => DeclaredTypes,
      <<"typeNodes">> => maps:get(nodes, Graph), <<"typeEdges">> => maps:get(edges, Graph),
      <<"typeAt">> => TypesAt, <<"locationSymbols">> => LocationSymbols,
      <<"diagnostics">> => Diagnostics}.

location_facts(LocationTypes, Graph) ->
    Nodes = maps:get(nodes, Graph),
    NodeIds = maps:from_list([{maps:get(<<"id">>, N), true} || N <- Nodes]),
    {SymbolMap, Declarations, DeclaredTypes, TypesAt, LocationSymbols} =
        lists:foldl(fun({File, _Source, Location, Type, Symbol},
                        {Syms, Decls, DTypes, TAt, LocSyms}) ->
        case is_map(Type) of
            false -> {Syms, Decls, DTypes, TAt, LocSyms};
            true ->
                TypeId = json_id(required_json_value(Type, <<"id">>)),
                case maps:is_key(TypeId, NodeIds) of
                    false -> {Syms, Decls, DTypes, TAt, LocSyms};
                    true ->
                        Start = maps:get(start, Location), End = maps:get('end', Location),
                        LocId = location_id(File, Start, End),
                        Origin = origin(Location),
                        TypeAt = #{<<"locationId">> => LocId, <<"typeId">> => TypeId,
                                   <<"origin">> => Origin, <<"file">> => filename_binary(File),
                                   <<"start">> => Start, <<"end">> => End},
                        {SymbolFacts, SymbolLinks} = symbol_json(Symbol, LocId),
                        {NewDecls, NewDeclaredTypes} = declaration_json(Location, Symbol, File,
                                                                          Start, End, TypeId),
                        {lists:foldl(fun(Item, Acc) ->
                            maps:put(maps:get(<<"id">>, Item), Item, Acc)
                        end, Syms, SymbolFacts), NewDecls ++ Decls,
                         NewDeclaredTypes ++ DTypes, [TypeAt | TAt], SymbolLinks ++ LocSyms}
                end
        end
    end, {#{}, [], [], [], []}, LocationTypes),
    {maps:values(SymbolMap), Declarations, DeclaredTypes, TypesAt, LocationSymbols}.

symbol_json(Symbol, LocationId) when is_map(Symbol) ->
    case maps:get(<<"id">>, Symbol, undefined) of
        undefined -> {[], []};
        Id0 ->
            Id = json_id(Id0), Name = display_binary(maps:get(<<"name">>, Symbol, <<"unknown">>)),
            Kind = symbol_kind(maps:get(<<"flags">>, Symbol, 0)),
            {[#{<<"id">> => Id, <<"name">> => Name, <<"kind">> => Kind}],
             [#{<<"locationId">> => LocationId, <<"symbolId">> => Id,
                <<"role">> => <<"reference">>}]}
    end;
symbol_json(_, _) -> {[], []}.

symbol_kind(Flags) when is_integer(Flags), Flags band 32 =/= 0 -> <<"class">>;
symbol_kind(Flags) when is_integer(Flags), Flags band 64 =/= 0 -> <<"interface">>;
symbol_kind(Flags) when is_integer(Flags), Flags band 524288 =/= 0 -> <<"type_alias">>;
symbol_kind(Flags) when is_integer(Flags), Flags band 16 =/= 0 -> <<"function">>;
symbol_kind(Flags) when is_integer(Flags), Flags band 8192 =/= 0 -> <<"method">>;
symbol_kind(Flags) when is_integer(Flags), Flags band 4 =/= 0 -> <<"property">>;
symbol_kind(Flags) when is_integer(Flags), Flags band 262144 =/= 0 -> <<"type_parameter">>;
symbol_kind(Flags) when is_integer(Flags), Flags band 8 =/= 0 -> <<"value">>;
symbol_kind(_) -> <<"value">>.

declaration_json(#{category := function, declaration_start := Start,
                    declaration_end := End}, Symbol, File,
                 _NameStart, _NameEnd, _TypeId) when is_map(Symbol) ->
    case maps:get(<<"id">>, Symbol, undefined) of
        undefined -> {[], []};
        SymbolId0 ->
            SymbolId = json_id(SymbolId0),
            DeclId = declaration_id(File, Start, End),
            {[#{<<"id">> => DeclId, <<"symbolId">> => SymbolId,
               <<"file">> => filename_binary(File), <<"start">> => Start, <<"end">> => End}], []}
    end;
declaration_json(_, _, _, _, _, _) -> {[], []}.

origin(#{category := reference}) -> <<"inferred">>;
origin(#{explicit := true}) -> <<"declared">>;
origin(_) -> <<"inferred">>.

project_file_count(Snapshot) ->
    case required_json_value(Snapshot, <<"projects">>) of
        [Project | _] -> length(maps:get(<<"rootFiles">>, Project, []));
        _ -> 0
    end.

diagnostic_in_scope(D, Allowed) ->
    case maps:get(<<"fileName">>, D, undefined) of
        File when is_binary(File) -> maps:is_key(filename:absname(binary_to_list(File)), Allowed);
        _ -> false
    end.

diagnostic_json(D, _Allowed, SourceMap) ->
    File0 = maps:get(<<"fileName">>, D), File = filename:absname(binary_to_list(File0)),
    Source = maps:get(File, SourceMap, <<>>),
    Pos = maps:get(<<"pos">>, D, 0), End = maps:get(<<"end">>, D, Pos),
    StartByte = utf16_to_byte(Source, Pos), EndByte = utf16_to_byte(Source, End),
    #{<<"code">> => maps:get(<<"code">>, D, 0),
      <<"category">> => diagnostic_category(maps:get(<<"category">>, D, 3)),
      <<"file">> => filename_binary(File), <<"start">> => StartByte,
      <<"length">> => max(0, EndByte - StartByte),
      <<"message">> => display_binary(maps:get(<<"text">>, D, <<>>))}.

diagnostic_category(1) -> <<"error">>;
diagnostic_category(0) -> <<"warning">>;
diagnostic_category(2) -> <<"suggestion">>;
diagnostic_category(_) -> <<"message">>.

intersect_files(SourceNames, ScannedFiles) when is_list(SourceNames) ->
    Scanned = maps:from_list([{filename:absname(path_list(F)), true} || F <- ScannedFiles]),
    lists:usort([Path || Name <- SourceNames,
                         Path <- [filename:absname(path_list(Name))],
                         maps:is_key(Path, Scanned)]);
intersect_files(_, _) -> [].

path_list(Path) when is_binary(Path) -> unicode:characters_to_list(Path);
path_list(Path) when is_list(Path) -> Path;
path_list(Path) when is_atom(Path) -> atom_to_list(Path).

read_sources(Files) ->
    lists:foldl(fun(File0, Acc) ->
        File = filename:absname(File0),
        case is_source_file(File) of
            false -> Acc;
            true -> read_source(File, Acc)
        end
    end, #{}, Files).

read_source(File, Acc) ->
        case file:read_file(File) of
            {ok, Source} -> maps:put(File, Source, Acc);
            _ -> Acc
        end.

is_source_file(Path) ->
    lists:member(filename:extension(Path),
                 [".ts", ".tsx", ".mts", ".cts", ".js", ".jsx", ".mjs", ".cjs"]).

byte_to_utf16(_Source, ByteOffset) when ByteOffset =< 0 -> 0;
byte_to_utf16(Source, ByteOffset) when ByteOffset =< byte_size(Source) ->
    Prefix = binary:part(Source, 0, ByteOffset),
    case unicode:characters_to_list(Prefix, utf8) of
        Chars when is_list(Chars) -> lists:sum([if C > 16#FFFF -> 2; true -> 1 end || C <- Chars]);
        _ -> 0
    end;
byte_to_utf16(Source, _ByteOffset) -> byte_to_utf16(Source, byte_size(Source)).

byte_offsets_to_utf16(_Source, []) -> [];
byte_offsets_to_utf16(Source, Offsets) ->
    Size = byte_size(Source),
    Normalized = [normalize_byte_offset(Offset, Size) || Offset <- Offsets],
    Requested = lists:usort(Normalized),
    Mapping = try build_utf16_offsets(Source, Requested, 0, 0, #{})
    catch
        error:badarg -> fallback_byte_offsets(Source, Normalized);
        error:function_clause -> fallback_byte_offsets(Source, Normalized)
    end,
    case Mapping of
        Values when is_map(Values) -> [maps:get(Offset, Values, 0) || Offset <- Normalized];
        Values when is_list(Values) -> Values
    end.

normalize_byte_offset(Offset, _Size) when Offset =< 0 -> 0;
normalize_byte_offset(Offset, Size) when Offset >= Size -> Size;
normalize_byte_offset(Offset, _Size) -> Offset.

build_utf16_offsets(<<>>, Requested, ByteOffset, Units, Acc) ->
    map_eof_offsets(Requested, ByteOffset, Units, Acc);
build_utf16_offsets(<<Codepoint/utf8, Rest/binary>>, Requested, ByteOffset, Units, Acc) ->
    NextByteOffset = ByteOffset + utf8_width(Codepoint),
    NextUnits = Units + if Codepoint > 16#FFFF -> 2; true -> 1 end,
    {Remaining, NextAcc} = map_offsets_before(
        Requested, NextByteOffset, ByteOffset, Units, Acc),
    build_utf16_offsets(Rest, Remaining, NextByteOffset, NextUnits, NextAcc).

map_offsets_before([Offset | Rest], NextByteOffset, ByteOffset, Units, Acc)
        when Offset < NextByteOffset ->
    Value = case Offset =:= ByteOffset of true -> Units; false -> 0 end,
    map_offsets_before(Rest, NextByteOffset, ByteOffset, Units, maps:put(Offset, Value, Acc));
map_offsets_before(Requested, _NextByteOffset, _ByteOffset, _Units, Acc) ->
    {Requested, Acc}.

map_eof_offsets([], _ByteOffset, _Units, Acc) -> Acc;
map_eof_offsets([Offset | Rest], ByteOffset, Units, Acc) ->
    Value = case Offset =:= ByteOffset of true -> Units; false -> 0 end,
    map_eof_offsets(Rest, ByteOffset, Units, maps:put(Offset, Value, Acc)).

utf8_width(Codepoint) when Codepoint =< 16#7F -> 1;
utf8_width(Codepoint) when Codepoint =< 16#7FF -> 2;
utf8_width(Codepoint) when Codepoint =< 16#FFFF -> 3;
utf8_width(_) -> 4.

fallback_byte_offsets(Source, Offsets) ->
    [byte_to_utf16(Source, Offset) || Offset <- Offsets].

utf16_to_byte(_Source, Position) when Position =< 0 -> 0;
utf16_to_byte(Source, Position) ->
    utf16_to_byte(Source, Position, 0, 0).
utf16_to_byte(Source, _Position, ByteOffset, _Units) when ByteOffset >= byte_size(Source) -> byte_size(Source);
utf16_to_byte(Source, Position, ByteOffset, Units) ->
    <<_:ByteOffset/binary, First/utf8, _/binary>> = Source,
    Width = if First > 16#FFFF -> 2; true -> 1 end,
    case Units + Width > Position of
        true -> ByteOffset;
        false ->
            Encoded = unicode:characters_to_binary([First]),
            utf16_to_byte(Source, Position, ByteOffset + byte_size(Encoded), Units + Width)
    end.

limit_list(List, Limit) when length(List) =< Limit -> {List, false};
limit_list(List, Limit) -> {lists:sublist(List, Limit), true}.

rpc(Port, Buffer, Deadline, Method, Params) ->
    Payload = jsx:encode(Params),
    Frame = message(1, unicode:characters_to_binary(Method), Payload),
    try port_command(Port, Frame) of
        true -> receive_rpc(Port, Buffer, Deadline, unicode:characters_to_binary(Method), 0)
    catch
        error:Reason -> throw({tsgo, {worker_start, Reason}})
    end.

receive_rpc(Port, Buffer, Deadline, Method, Size) ->
    case decode_message(Buffer) of
        {ok, Type, Name, Payload, Rest} ->
            case Type of
                4 when Name =:= Method ->
                    try jsx:decode(Payload, [return_maps]) of
                        Json -> {Json, Rest}
                    catch _:_ -> throw({tsgo, invalid_worker_output}) end;
                5 -> throw({tsgo, {compiler_error, Payload}});
                6 ->
                    _ = port_command(Port, message(3, Name,
                        <<"Filesystem callbacks are unsupported in the native client.">>)),
                    throw({tsgo, {callback_unsupported, Name}});
                4 -> throw({tsgo, {response_name_mismatch, Method, Name}});
                _ -> throw({tsgo, {unexpected_message_type, Type}})
            end;
        more ->
            Remaining = ?MAX_MESSAGE_BYTES - Size,
            case Remaining =< 0 of
                true -> throw({tsgo, output_limit});
                false ->
                    Timeout = max(0, Deadline - erlang:monotonic_time(millisecond)),
                    receive
                        {Port, {data, Data}} when byte_size(Data) =< Remaining ->
                            receive_rpc(Port, <<Buffer/binary, Data/binary>>, Deadline,
                                        Method, Size + byte_size(Data));
                        {Port, {data, _Data}} -> throw({tsgo, output_limit});
                        {Port, {exit_status, Status}} -> throw({tsgo, {worker_exit, Status}})
                    after Timeout -> throw({tsgo, timeout})
                    end
            end;
        {error, Reason} -> throw({tsgo, {invalid_message, Reason}})
    end.

message(Type, Name, Payload) ->
    <<16#93, Type, (msgpack_bin(Name))/binary, (msgpack_bin(Payload))/binary>>.

msgpack_bin(Bin) when byte_size(Bin) < 256 -> <<16#c4, (byte_size(Bin)), Bin/binary>>;
msgpack_bin(Bin) when byte_size(Bin) < 65536 ->
    <<16#c5, (byte_size(Bin)):16/unsigned-big, Bin/binary>>;
msgpack_bin(Bin) -> <<16#c6, (byte_size(Bin)):32/unsigned-big, Bin/binary>>.

decode_message(<<16#93, Rest/binary>>) ->
    case decode_uint(Rest) of
        {ok, Type, R1} ->
            case decode_bin(R1) of
                {ok, Name, R2} ->
                    case decode_bin(R2) of
                        {ok, Payload, R3} -> {ok, Type, Name, Payload, R3};
                        more -> more;
                        Error -> Error
                    end;
                more -> more;
                Error -> Error
            end;
        more -> more;
        Error -> Error
    end;
decode_message(<<>>) -> more;
decode_message(<<Header, _/binary>>) -> {error, {invalid_array_header, Header}}.

decode_uint(<<N, Rest/binary>>) when N < 128 -> {ok, N, Rest};
decode_uint(<<16#cc, N, Rest/binary>>) -> {ok, N, Rest};
decode_uint(<<16#cd, N:16/unsigned-big, Rest/binary>>) -> {ok, N, Rest};
decode_uint(<<16#ce, N:32/unsigned-big, Rest/binary>>) -> {ok, N, Rest};
decode_uint(Bin) when byte_size(Bin) < 1 -> more;
decode_uint(<<Header, _/binary>>) -> {error, {invalid_uint, Header}}.

decode_bin(<<16#c4, Length, Rest/binary>>) when byte_size(Rest) >= Length ->
    <<Value:Length/binary, Tail/binary>> = Rest, {ok, Value, Tail};
decode_bin(<<16#c4, _Length, _/binary>>) -> more;
decode_bin(<<16#c5, Length:16/unsigned-big, Rest/binary>>) when byte_size(Rest) >= Length ->
    <<Value:Length/binary, Tail/binary>> = Rest, {ok, Value, Tail};
decode_bin(<<16#c5, _Length:16/unsigned-big, _/binary>>) -> more;
decode_bin(<<16#c6, Length:32/unsigned-big, Rest/binary>>) when byte_size(Rest) >= Length ->
    <<Value:Length/binary, Tail/binary>> = Rest, {ok, Value, Tail};
decode_bin(<<16#c6, _Length:32/unsigned-big, _/binary>>) -> more;
decode_bin(Bin) when byte_size(Bin) < 1 -> more;
decode_bin(<<Header, _/binary>>) -> {error, {invalid_bin, Header}}.

find_typescript_package(Dir) ->
    Package = filename:join([Dir, "node_modules", "typescript", "package.json"]),
    case file:read_file(Package) of
        {ok, Json} ->
            try jsx:decode(Json, [return_maps]) of
                Map ->
                    Version = maps:get(<<"version">>, Map, <<>>),
                    {ok, filename:dirname(Package), display_binary(Version)}
            catch _:_ -> error end;
        _ ->
            Parent = filename:dirname(Dir),
            case Parent =:= Dir of true -> error; false -> find_typescript_package(Parent) end
    end.

resolve_symlink(Path) ->
    case file:read_link_all(Path) of
        {ok, Target} ->
            Next = filename:absname(Target, filename:dirname(Path)),
            case Next =:= Path of true -> Path; false -> resolve_symlink(Next) end;
        _ -> Path
    end.

resolve_native_binary(PackageRoot, Version) ->
    case native_platform() of
        unsupported -> {error, unsupported_compiler_api};
        Suffix ->
            PackageName = "typescript-" ++ Suffix,
            ParentModules = filename:dirname(PackageRoot),
            RealPackageRoot = resolve_symlink(PackageRoot),
            PnpmName = "@typescript+" ++ PackageName ++ "@" ++ binary_to_list(Version),
            Candidates = [
                filename:join([PackageRoot, "node_modules", "@typescript", PackageName]),
                filename:join([ParentModules, "@typescript", PackageName]),
                filename:join([filename:dirname(RealPackageRoot), "@typescript", PackageName]),
                filename:join([ParentModules, ".pnpm", PnpmName, "node_modules",
                               "@typescript", PackageName])
            ],
            Existing = [Root || Root <- Candidates,
                                filelib:is_regular(filename:join(Root, "package.json"))],
            Matching = [Root || Root <- Existing,
                                package_version(filename:join(Root, "package.json")) =:= Version],
            case Matching of
                [NativeRoot | _] ->
                    ExeName = case os:type() of {win32, _} -> "tsc.exe"; _ -> "tsc" end,
                    Exe = filename:join([NativeRoot, "lib", ExeName]),
                    case filelib:is_regular(Exe) of
                        true -> {ok, #{executable => Exe, version => Version}};
                        false -> {error, compiler_missing}
                    end;
                [] when Existing =/= [] -> {error, unsupported_compiler_api};
                [] -> {error, compiler_missing}
            end
    end.

package_version(Path) ->
    case file:read_file(Path) of
        {ok, Json} ->
            try jsx:decode(Json, [return_maps]) of Map -> display_binary(maps:get(<<"version">>, Map, <<>>))
            catch _:_ -> <<>> end;
        _ -> <<>>
    end.

native_platform() ->
    Arch = string:lowercase(erlang:system_info(system_architecture)),
    IsArm = lists:prefix("aarch64", Arch) orelse lists:prefix("arm64", Arch),
    IsX64 = lists:prefix("x86_64", Arch) orelse lists:prefix("amd64", Arch),
    case {os:type(), IsArm, IsX64} of
        {{unix, darwin}, true, _} -> "darwin-arm64";
        {{unix, darwin}, _, true} -> "darwin-x64";
        {{unix, linux}, true, _} -> "linux-arm64";
        {{unix, linux}, _, true} -> "linux-x64";
        {{win32, _}, true, _} -> "win32-arm64";
        {{win32, _}, _, true} -> "win32-x64";
        _ -> unsupported
    end.

required_json_value(Map, Key) when is_map(Map) ->
    case maps:find(Key, Map) of {ok, Value} -> Value; error -> throw({tsgo, invalid_worker_output}) end;
required_json_value(_, _) -> throw({tsgo, invalid_worker_output}).

json_id(Value) when is_binary(Value) -> Value;
json_id(Value) when is_integer(Value) -> integer_to_binary(Value);
json_id(Value) when is_float(Value) -> float_to_binary(Value, [short]);
json_id(Value) -> display_binary(Value).

filename_binary(File) -> unicode:characters_to_binary(filename:absname(File)).
name_binary(Name) when is_atom(Name) -> atom_to_binary(Name, utf8);
name_binary(Name) when is_binary(Name) -> Name;
name_binary(Name) when is_list(Name) -> unicode:characters_to_binary(Name);
name_binary(_) -> <<>>.

display_binary(Value) when is_binary(Value) -> Value;
display_binary(Value) when is_list(Value) -> unicode:characters_to_binary(Value);
display_binary(Value) when is_integer(Value) -> integer_to_binary(Value);
display_binary(_) -> <<>>.

declaration_id(File, Start, End) ->
    <<"decl:", (filename_binary(File))/binary, ":", (integer_to_binary(Start))/binary,
      ":", (integer_to_binary(End))/binary>>.
location_id(File, Start, End) ->
    <<"loc:", (filename_binary(File))/binary, ":", (integer_to_binary(Start))/binary,
      ":", (integer_to_binary(End))/binary>>.
