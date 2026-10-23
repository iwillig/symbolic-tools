%%% Optional project-level TypeScript checker, shared by CLI and MCP parse.
%%% Tree-sitter syntax extraction remains independent of Node and the checker.
-module(symbolic_ts_project).
-include_lib("kernel/include/logger.hrl").

-export([analyze/3, summary_json/1]).

%% Bound the entire worker invocation, not just the interval between stdout chunks.
-define(WORKER_TIMEOUT_MS, 90000).
-define(MAX_WORKER_OUTPUT, 33554432).

-spec analyze(map(), file:filename(), map() | undefined) -> {ok, map()} | {error, term()}.
analyze(Report, ScopeRoot, Settings0) ->
    try analyze_safe(Report, ScopeRoot, Settings0)
    catch
        Class:Reason:Stack ->
            ?LOG_ERROR("TypeScript analysis failed internally (~p:~p): ~p",
                       [Class, Reason, Stack]),
            ScopeId = unicode:characters_to_binary(filename:absname(ScopeRoot)),
            AnalysisId = analysis_id(ScopeId),
            Fact = {ts_analysis, AnalysisId, ScopeId, failed, internal_error},
            Summary = #{status => failed, reason => internal_error, projects => []},
            {ok, Report#{facts => lists:usort(maps:get(facts, Report) ++ [Fact]),
                         type_analysis => Summary}}
    end.

analyze_safe(Report, ScopeRoot, Settings0) ->
    Settings = normalize_settings(Settings0),
    ScopeId = unicode:characters_to_binary(filename:absname(ScopeRoot)),
    AnalysisId = analysis_id(ScopeId),
    {Status, Reason, ProjectFacts, ProjectSummaries, Timings} =
        case maps:get(enabled, Settings) of
            false -> {disabled, disabled, [], [], #{}};
            true -> analyze_projects(maps:get(projects, Settings), Report, AnalysisId)
        end,
    AnalysisFact = {ts_analysis, AnalysisId, ScopeId, Status, Reason},
    Facts = lists:usort(maps:get(facts, Report) ++ [AnalysisFact | ProjectFacts]),
    Summary = #{status => Status, reason => Reason, projects => ProjectSummaries,
                timings_ms => Timings},
    {ok, Report#{facts => Facts, type_analysis => Summary}}.

summary_json(#{status := Status, reason := Reason, projects := Projects} = Analysis) ->
    Summary = #{status => atom_to_binary(Status, utf8),
                reason => atom_to_binary(Reason, utf8),
                projects => [project_summary_json(Project) || Project <- Projects]},
    case maps:find(timings_ms, Analysis) of
        {ok, Timings} -> Summary#{timings_ms => Timings};
        error -> Summary
    end.

project_summary_json(Project) ->
    maps:map(fun(Key, Value) -> summary_value(Key, Value) end, Project).

summary_value(status, Value) when is_atom(Value) -> atom_to_binary(Value, utf8);
summary_value(reason, Value) when is_atom(Value) -> atom_to_binary(Value, utf8);
summary_value(compiler_version, unknown) -> null;
summary_value(options_hash, unknown) -> null;
summary_value(config, Value) when is_list(Value) -> unicode:characters_to_binary(Value);
summary_value(_Key, Value) -> Value.

normalize_settings(undefined) -> #{enabled => false, projects => []};
normalize_settings(#{enabled := Enabled, projects := Projects}) ->
    #{enabled => Enabled, projects => Projects};
normalize_settings(_) -> #{enabled => false, projects => []}.

elapsed_ms(StartedMicroseconds) ->
    (erlang:monotonic_time(microsecond) - StartedMicroseconds + 500) div 1000.

analysis_id(ScopeId) ->
    <<ScopeId/binary, "#", (integer_to_binary(erlang:unique_integer([positive, monotonic])))/binary>>.

analyze_projects([], _Report, _AnalysisId) ->
    {no_project, no_project, [], [], #{}};
analyze_projects(Projects, Report, AnalysisId) ->
    {IndexMicroseconds, LocationFactsByFile} = timer:tc(fun() ->
        index_location_facts(maps:get(facts, Report, []))
    end),
    IndexedReport = Report#{typescript_location_facts_by_file => LocationFactsByFile},
    Results = [analyze_project(Project, IndexedReport, AnalysisId) || Project <- Projects],
    Statuses = [maps:get(status, Result) || Result <- Results],
    Aggregate = aggregate_status(Statuses),
    Reason = aggregate_reason(Aggregate, Results),
    Facts = lists:append([maps:get(facts, Result) || Result <- Results]),
    Summaries = [maps:get(summary, Result) || Result <- Results],
    Timings = #{<<"location_fact_index">> => (IndexMicroseconds + 500) div 1000},
    {Aggregate, Reason, Facts, Summaries, Timings}.

index_location_facts(Facts) ->
    Reversed = lists:foldl(fun(Fact, Acc) ->
        case location_index_file(Fact) of
            undefined -> Acc;
            File ->
                Path = filename:absname(atom_to_list(File)),
                maps:update_with(Path, fun(Items) -> [Fact | Items] end, [Fact], Acc)
        end
    end, #{}, Facts),
    maps:map(fun(_Path, Items) -> lists:reverse(Items) end, Reversed).

location_index_file({var_decl, {File, _, _}, _, _, _, File, _}) when is_atom(File) -> File;
location_index_file({var_ref, {File, _, _}, _, _, _, File, _}) when is_atom(File) -> File;
location_index_file({function_decl, {File, _, _}, _, _, _, _, File, _}) when is_atom(File) -> File;
location_index_file({ts_syntax_type, File, _, _, _, _, _, _, _}) when is_atom(File) -> File;
location_index_file(_) -> undefined.

analyze_project(ConfigPath, Report, AnalysisId) ->
    ProjectId = unicode:characters_to_binary(filename:absname(ConfigPath)),
    case filelib:is_regular(ConfigPath) of
        false -> project_failure(ProjectId, AnalysisId, ConfigPath, failed, bad_config);
        true -> run_project_analyzer(ProjectId, AnalysisId, ConfigPath, Report)
    end.

run_project_analyzer(ProjectId, AnalysisId, ConfigPath, Report) ->
    case symbolic_tsgo:resolve(ConfigPath) of
        {ok, Compiler} ->
            case symbolic_tsgo:analyze(Report, ConfigPath, Compiler) of
                {ok, Json} -> normalize_worker_result(Json, ProjectId, AnalysisId, ConfigPath);
                {error, {tsgo_stage, Stage, Error, Timings}} ->
                    Reason = worker_error_code(Error),
                    project_failure_with_timings(ProjectId, AnalysisId, ConfigPath,
                                                 worker_status(Reason), Reason,
                                                 Stage, Timings);
                {error, Error} ->
                    Reason = worker_error_code(Error),
                    project_failure(ProjectId, AnalysisId, ConfigPath,
                                    worker_status(Reason), Reason)
            end;
        {error, NativeReason} ->
            case os:find_executable("node") of
                false -> project_failure(ProjectId, AnalysisId, ConfigPath,
                                         unavailable, NativeReason);
                Node -> run_worker(Node, ProjectId, AnalysisId, ConfigPath, Report)
            end
    end.

project_failure(ProjectId, AnalysisId, ConfigPath, Status, Reason) ->
    Fact = project_fact(ProjectId, AnalysisId, ConfigPath, unknown, unknown, Status, Reason),
    #{status => Status, reason => Reason, facts => [Fact],
      summary => #{project => ProjectId, config => ConfigPath,
                   status => Status, reason => Reason}}.

project_failure_with_timings(ProjectId, AnalysisId, ConfigPath, Status, Reason,
                              Stage, Timings) ->
    Result = project_failure(ProjectId, AnalysisId, ConfigPath, Status, Reason),
    Summary = maps:get(summary, Result),
    Result#{summary => Summary#{failed_stage => atom_to_binary(Stage, utf8),
                                timings_ms => Timings}}.

run_worker(Node, ProjectId, AnalysisId, ConfigPath, Report) ->
    Request = #{<<"schemaVersion">> => 1,
                <<"projectId">> => ProjectId,
                <<"configFile">> => unicode:characters_to_binary(filename:absname(ConfigPath)),
                <<"scanFiles">> => [unicode:characters_to_binary(filename:absname(F))
                                     || F <- maps:get(files, Report)]},
    case write_request(Request) of
        {ok, RequestPath} ->
            try invoke_worker(Node, RequestPath) of
                {ok, Json} -> normalize_worker_result(Json, ProjectId, AnalysisId, ConfigPath);
                {error, Error} ->
                    Reason = worker_error_code(Error),
                    project_failure(ProjectId, AnalysisId, ConfigPath,
                                    worker_status(Reason), Reason)
            after
                _ = file:delete(RequestPath)
            end;
        {error, _} -> project_failure(ProjectId, AnalysisId, ConfigPath, failed, request_io)
    end.

write_request(Request) ->
    TempDir = filename:basedir(user_cache, "symbolic"),
    ok = filelib:ensure_dir(filename:join(TempDir, "placeholder")),
    Name = "ts-worker-" ++ integer_to_list(erlang:unique_integer([positive, monotonic])) ++ ".json",
    Path = filename:join(TempDir, Name),
    case file:write_file(Path, jsx:encode(Request), [binary, exclusive]) of
        ok -> {ok, Path};
        Error -> Error
    end.

invoke_worker(Node, RequestPath) ->
    WorkerPath = worker_path(),
    Args = ["--max-old-space-size=512", WorkerPath, RequestPath],
    try open_port({spawn_executable, Node},
            [binary, exit_status, use_stdio, hide, {args, Args}]) of
        Port ->
            Deadline = erlang:monotonic_time(millisecond) + ?WORKER_TIMEOUT_MS,
            try collect_output(Port, [], 0, Deadline)
            after
                try port_close(Port) catch _:_ -> ok end
            end
    catch
        error:Reason -> {error, {worker_start, Reason}}
    end.

collect_output(Port, Chunks, Size, Deadline) ->
    case Deadline - erlang:monotonic_time(millisecond) of
        Remaining when Remaining =< 0 -> {error, timeout};
        Remaining ->
            receive
                {Port, {data, Data}} ->
                    NewSize = Size + byte_size(Data),
                    case NewSize > ?MAX_WORKER_OUTPUT of
                        true -> {error, output_limit};
                        false -> collect_output(Port, [Data | Chunks], NewSize, Deadline)
                    end;
                {Port, {exit_status, _Status}} ->
                    decode_worker_output(iolist_to_binary(lists:reverse(Chunks)))
            after Remaining -> {error, timeout}
            end
    end.

decode_worker_output(<<>>) -> {error, invalid_worker_output};
decode_worker_output(Bin) ->
    try jsx:decode(Bin, [return_maps]) of
        Json when is_map(Json) -> {ok, Json};
        _ -> {error, invalid_worker_output}
    catch
        _:_ -> {error, invalid_worker_output}
    end.

worker_path() ->
    Priv = case code:priv_dir(symbolic_tools) of
        {error, bad_name} -> filename:absname("priv");
        Dir -> Dir
    end,
    filename:join(Priv, "typescript-worker.js").

normalize_worker_result(Json, ProjectId, AnalysisId, ConfigPath) ->
    case {maps:get(<<"schemaVersion">>, Json, undefined),
          status_atom(maps:get(<<"status">>, Json, undefined)),
          reason_atom(maps:get(<<"reason">>, Json, undefined))} of
        {1, {ok, Status}, {ok, Reason}} ->
            normalize_success_or_failure(Json, ProjectId, AnalysisId, ConfigPath, Status, Reason);
        _ -> project_failure(ProjectId, AnalysisId, ConfigPath, failed, invalid_worker_output)
    end.

normalize_success_or_failure(Json, ProjectId, AnalysisId, ConfigPath, Status, Reason) ->
    NormalizeStarted = erlang:monotonic_time(microsecond),
    Version = json_binary(maps:get(<<"compilerVersion">>, Json, undefined), unknown),
    OptionsHash = json_binary(maps:get(<<"optionsHash">>, Json, undefined), unknown),
    FactResult = case Status of
        ok -> worker_facts(Json, ProjectId);
        partial -> worker_facts(Json, ProjectId);
        _ -> {ok, []}
    end,
    case FactResult of
        {ok, Facts} ->
            NormalizeMs = elapsed_ms(NormalizeStarted),
            ProjectFact = project_fact(ProjectId, AnalysisId, ConfigPath, Version, OptionsHash,
                                       Status, Reason),
            Timings0 = maps:get(<<"timingsMs">>, Json, #{}),
            Summary = #{project => ProjectId, config => ConfigPath,
                        compiler_version => Version, options_hash => OptionsHash,
                        status => Status, reason => Reason,
                        files_processed => maps:get(<<"filesProcessed">>, Json, 0),
                        timings_ms => Timings0#{<<"normalize">> => NormalizeMs}},
            #{status => Status, reason => Reason,
              facts => [ProjectFact | Facts], summary => Summary};
        {error, _} -> project_failure(ProjectId, AnalysisId, ConfigPath, failed, invalid_worker_output)
    end.

worker_facts(Json, ProjectId) ->
    try
        Symbols = [symbol_fact(ProjectId, S) || S <- maps:get(<<"symbols">>, Json)],
        Declarations = [declaration_fact(ProjectId, D) || D <- maps:get(<<"declarations">>, Json)],
        DeclaredTypes = [declared_type_fact(ProjectId, D) || D <- maps:get(<<"declaredTypes">>, Json)],
        Nodes = [type_node_fact(ProjectId, N) || N <- maps:get(<<"typeNodes">>, Json)],
        Edges = [type_edge_fact(ProjectId, E) || E <- maps:get(<<"typeEdges">>, Json)],
        TypesAt = [type_at_fact(ProjectId, T) || T <- maps:get(<<"typeAt">>, Json)],
        LocationSymbols = [location_symbol_fact(ProjectId, S) || S <- maps:get(<<"locationSymbols">>, Json)],
        Diagnostics = [diagnostic_fact(ProjectId, D) || D <- maps:get(<<"diagnostics">>, Json)],
        {ok, Symbols ++ Declarations ++ DeclaredTypes ++ Nodes ++ Edges ++
             TypesAt ++ LocationSymbols ++ Diagnostics}
    catch
        _:_ -> {error, invalid_worker_output}
    end.

symbol_fact(ProjectId, S) ->
    {ts_symbol, ProjectId, required_binary(S, <<"id">>),
     required_binary(S, <<"name">>), kind_atom(required_binary(S, <<"kind">>))}.

declaration_fact(ProjectId, D) ->
    {ts_declaration, ProjectId, required_binary(D, <<"id">>),
     required_binary(D, <<"symbolId">>), file_atom(required_binary(D, <<"file">>)),
     required_integer(D, <<"start">>), required_integer(D, <<"end">>)}.

declared_type_fact(ProjectId, D) ->
    {ts_declared_type, ProjectId, required_binary(D, <<"declarationId">>),
     required_binary(D, <<"typeId">>)}.

type_node_fact(ProjectId, N) ->
    {ts_type_node, ProjectId, required_binary(N, <<"id">>),
     kind_atom(required_binary(N, <<"kind">>)), required_binary(N, <<"display">>)}.

type_edge_fact(ProjectId, E) ->
    {ts_type_edge, ProjectId, required_binary(E, <<"parent">>),
     required_binary(E, <<"role">>), required_binary(E, <<"child">>)}.

type_at_fact(ProjectId, T) ->
    {ts_type_at, ProjectId, required_binary(T, <<"locationId">>),
     required_binary(T, <<"typeId">>), origin_atom(required_binary(T, <<"origin">>)),
     file_atom(required_binary(T, <<"file">>)),
     required_integer(T, <<"start">>), required_integer(T, <<"end">>)}.

location_symbol_fact(ProjectId, S) ->
    {ts_location_symbol, ProjectId, required_binary(S, <<"locationId">>),
     required_binary(S, <<"symbolId">>), reference_role(required_binary(S, <<"role">>))}.

diagnostic_fact(ProjectId, D) ->
    File = case maps:get(<<"file">>, D, undefined) of
        undefined -> undefined;
        Path -> file_atom(Path)
    end,
    Start = maps:get(<<"start">>, D, -1),
    Length = maps:get(<<"length">>, D, 0),
    {ts_diagnostic, ProjectId, required_integer(D, <<"code">>),
     diagnostic_category(required_binary(D, <<"category">>)), File,
     Start, Length, required_binary(D, <<"message">>)}.

project_fact(ProjectId, AnalysisId, ConfigPath, Version, OptionsHash, Status, Reason) ->
    {ts_project, ProjectId, AnalysisId, file_atom(ConfigPath), Version,
     OptionsHash, Status, Reason}.

required_binary(Map, Key) ->
    case maps:get(Key, Map) of
        Value when is_binary(Value) -> Value;
        Value when is_list(Value) -> unicode:characters_to_binary(Value);
        _ -> erlang:error({invalid_worker_field, Key})
    end.

required_integer(Map, Key) ->
    case maps:get(Key, Map) of
        Value when is_integer(Value) -> Value;
        _ -> erlang:error({invalid_worker_field, Key})
    end.

json_binary(Value, _Default) when is_binary(Value) -> Value;
json_binary(Value, _Default) when is_list(Value) -> unicode:characters_to_binary(Value);
json_binary(_Value, Default) -> Default.

file_atom(Path) when is_binary(Path) -> list_to_atom(binary_to_list(Path));
file_atom(Path) when is_list(Path) -> list_to_atom(Path).

status_atom(<<"ok">>) -> {ok, ok};
status_atom(<<"partial">>) -> {ok, partial};
status_atom(<<"unavailable">>) -> {ok, unavailable};
status_atom(<<"failed">>) -> {ok, failed};
status_atom(_) -> error.

reason_atom(<<"none">>) -> {ok, none};
reason_atom(<<"resource_limit">>) -> {ok, resource_limit};
reason_atom(<<"compiler_missing">>) -> {ok, compiler_missing};
reason_atom(<<"unsupported_compiler_api">>) -> {ok, unsupported_compiler_api};
reason_atom(<<"unsupported_node">>) -> {ok, unsupported_node};
reason_atom(<<"bad_config">>) -> {ok, bad_config};
reason_atom(<<"program_error">>) -> {ok, program_error};
reason_atom(<<"worker_crash">>) -> {ok, worker_crash};
reason_atom(<<"invalid_request">>) -> {ok, invalid_request};
reason_atom(<<"disabled">>) -> {ok, disabled};
reason_atom(<<"no_project">>) -> {ok, no_project};
reason_atom(<<"node_missing">>) -> {ok, node_missing};
reason_atom(<<"config_missing">>) -> {ok, config_missing};
reason_atom(<<"request_io">>) -> {ok, request_io};
reason_atom(<<"timeout">>) -> {ok, timeout};
reason_atom(<<"output_limit">>) -> {ok, output_limit};
reason_atom(<<"invalid_worker_output">>) -> {ok, invalid_worker_output};
reason_atom(<<"worker_start">>) -> {ok, worker_start};
reason_atom(<<"mixed_project_results">>) -> {ok, mixed_project_results};
reason_atom(<<"unknown">>) -> {ok, unknown};
reason_atom(<<"internal_error">>) -> {ok, internal_error};
reason_atom(_) -> error.

kind_atom(<<"union">>) -> union;
kind_atom(<<"intersection">>) -> intersection;
kind_atom(<<"any">>) -> any;
kind_atom(<<"unknown">>) -> unknown;
kind_atom(<<"never">>) -> never;
kind_atom(<<"string_literal">>) -> string_literal;
kind_atom(<<"number_literal">>) -> number_literal;
kind_atom(<<"boolean_literal">>) -> boolean_literal;
kind_atom(<<"string">>) -> string;
kind_atom(<<"number">>) -> number;
kind_atom(<<"boolean">>) -> boolean;
kind_atom(<<"bigint">>) -> bigint;
kind_atom(<<"null">>) -> null;
kind_atom(<<"undefined">>) -> undefined;
kind_atom(<<"type_parameter">>) -> type_parameter;
kind_atom(<<"object">>) -> object;
kind_atom(<<"function">>) -> function;
kind_atom(<<"method">>) -> method;
kind_atom(<<"property">>) -> property;
kind_atom(<<"parameter">>) -> parameter;
kind_atom(<<"class">>) -> class;
kind_atom(<<"interface">>) -> interface;
kind_atom(<<"type_alias">>) -> type_alias;
kind_atom(<<"enum">>) -> enum;
kind_atom(<<"value">>) -> value;
kind_atom(_) -> other.

origin_atom(<<"declared">>) -> declared;
origin_atom(<<"inferred">>) -> inferred;
origin_atom(<<"call_result">>) -> call_result;
origin_atom(_) -> other.

reference_role(<<"reference">>) -> reference;
reference_role(_) -> other.

diagnostic_category(<<"error">>) -> error;
diagnostic_category(<<"warning">>) -> warning;
diagnostic_category(<<"suggestion">>) -> suggestion;
diagnostic_category(_) -> message.

worker_error_code({tsgo_stage, _Stage, Reason, _Timings}) -> worker_error_code(Reason);
worker_error_code(timeout) -> timeout;
worker_error_code(output_limit) -> output_limit;
worker_error_code({worker_start, _}) -> worker_start;
worker_error_code(_) -> worker_crash.

worker_status(timeout) -> unavailable;
worker_status(output_limit) -> partial;
worker_status(node_missing) -> unavailable;
worker_status(compiler_missing) -> unavailable;
worker_status(unsupported_compiler_api) -> unavailable;
worker_status(unsupported_node) -> unavailable;
worker_status(_) -> failed.

aggregate_status(Statuses) ->
    case {lists:member(ok, Statuses), lists:member(partial, Statuses),
          lists:member(unavailable, Statuses), lists:member(failed, Statuses)} of
        {true, false, false, false} -> ok;
        {false, false, true, false} -> unavailable;
        {false, false, false, true} -> failed;
        _ -> partial
    end.

aggregate_reason(ok, _Results) -> none;
aggregate_reason(Status, Results) ->
    Reasons = lists:usort([maps:get(reason, Result) || Result <- Results]),
    case Reasons of
        [Reason] -> Reason;
        _ when Status =:= partial -> mixed_project_results;
        _ -> unknown
    end.
