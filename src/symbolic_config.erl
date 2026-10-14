%%% `.symbolic/config.json` — project paths and optional shared fact database.
%%%
%%% Paths and database files are resolved relative to the config file's
%%% project root, not the caller's working directory. Existing configs with
%%% only `paths` remain valid. See docs/prolog-store.md and docs/cli-erlang.md.
-module(symbolic_config).

-export([discover/1, read/1, read_settings/1, default_database/1, project_root/1]).

-define(CONFIG_DIR, ".symbolic").
-define(CONFIG_FILE, "config.json").

-spec discover(file:filename()) -> file:filename() | undefined.
discover(StartDir) ->
    symbolic_query:discover_up(StartDir, [?CONFIG_DIR, ?CONFIG_FILE]).

%% Backward-compatible paths-only API.
-spec read(file:filename()) -> {ok, [file:filename()]} | {error, term()}.
read(ConfigPath) ->
    case read_settings(ConfigPath) of
        {ok, #{paths := Paths}} -> {ok, Paths};
        Error -> Error
    end.

%% Read and validate paths and the optional shared database setting.
-spec read_settings(file:filename()) -> {ok, map()} | {error, term()}.
read_settings(ConfigPath) ->
    case file:read_file(ConfigPath) of
        {ok, Bin} -> decode(ConfigPath, Bin);
        {error, Reason} -> {error, {cannot_read_config, ConfigPath, Reason}}
    end.

%% Resolve an optional database setting from the nearest project config.
%% No config or no database key preserves existing caller behavior.
-spec default_database(file:filename()) -> {ok, file:filename() | undefined} | {error, term()}.
default_database(StartDir) ->
    case discover(StartDir) of
        undefined -> {ok, undefined};
        ConfigPath ->
            case read_settings(ConfigPath) of
                {ok, #{database := DbPath}} -> {ok, DbPath};
                Error -> Error
            end
    end.

decode(ConfigPath, Bin) ->
    try jsx:decode(Bin, [return_maps]) of
        Json -> validate(ConfigPath, Json)
    catch
        _:_ -> {error, {invalid_config_json, ConfigPath}}
    end.

validate(ConfigPath, #{<<"paths">> := Paths} = Json) when is_list(Paths), Paths =/= [] ->
    case lists:all(fun is_binary/1, Paths) of
        true ->
            Root = project_root(ConfigPath),
            case database_path(ConfigPath, maps:get(<<"database">>, Json, undefined), Root) of
                {ok, DbPath} ->
                    case typescript_settings(ConfigPath, Json, Root) of
                        {ok, undefined} ->
                            {ok, #{paths => [filename:join(Root, binary_to_list(P)) || P <- Paths],
                                   database => DbPath}};
                        {ok, TypeScript} ->
                            {ok, #{paths => [filename:join(Root, binary_to_list(P)) || P <- Paths],
                                   database => DbPath, typescript => TypeScript}};
                        Error -> Error
                    end;
                Error -> Error
            end;
        false ->
            {error, {invalid_config_paths, ConfigPath,
                "every entry in \"paths\" must be a string"}}
    end;
validate(ConfigPath, #{<<"paths">> := []}) ->
    {error, {invalid_config_paths, ConfigPath, "\"paths\" must not be empty"}};
validate(ConfigPath, #{<<"paths">> := _NotAList}) ->
    {error, {invalid_config_paths, ConfigPath, "\"paths\" must be a list of strings"}};
validate(ConfigPath, _Json) ->
    {error, {missing_config_paths, ConfigPath}}.

database_path(_ConfigPath, undefined, _Root) -> {ok, undefined};
database_path(ConfigPath, <<>>, _Root) ->
    {error, {invalid_config_database, ConfigPath, "database must not be empty"}};
database_path(_ConfigPath, DbPath, Root) when is_binary(DbPath) ->
    {ok, filename:join(Root, binary_to_list(DbPath))};
database_path(ConfigPath, _DbPath, _Root) ->
    {error, {invalid_config_database, ConfigPath, "database must be a string"}}.

typescript_settings(_ConfigPath, Json, _Root) when not is_map_key(<<"typescript">>, Json) ->
    {ok, undefined};
typescript_settings(ConfigPath, Json, Root) ->
    case maps:get(<<"typescript">>, Json) of
        Settings when is_map(Settings) ->
            Enabled = maps:get(<<"enabled">>, Settings, false),
            Projects = maps:get(<<"projects">>, Settings, []),
            case is_boolean(Enabled) andalso is_list(Projects) andalso
                 length(Projects) =< 32 andalso lists:all(fun is_binary/1, Projects) of
                false ->
                    {error, {invalid_config_typescript, ConfigPath,
                             "typescript.enabled must be a boolean and typescript.projects a list of at most 32 strings"}};
                true ->
                    case resolve_typescript_projects(ConfigPath, Root, Projects, []) of
                        {ok, Resolved} -> {ok, #{enabled => Enabled, projects => Resolved}};
                        Error -> Error
                    end
            end;
        _ ->
            {error, {invalid_config_typescript, ConfigPath,
                     "typescript must be an object"}}
    end.

resolve_typescript_projects(_ConfigPath, _Root, [], Acc) ->
    {ok, lists:reverse(Acc)};
resolve_typescript_projects(ConfigPath, Root, [Project | Rest], Acc) ->
    ProjectPath = binary_to_list(Project),
    Parts = filename:split(ProjectPath),
    case ProjectPath =/= "" andalso filename:pathtype(ProjectPath) =:= relative
         andalso not lists:member("..", Parts) of
        true ->
            Absolute = filename:absname(filename:join(Root, ProjectPath)),
            resolve_typescript_projects(ConfigPath, Root, Rest, [Absolute | Acc]);
        false ->
            {error, {invalid_config_typescript, ConfigPath,
                     "typescript.projects entries must be non-empty relative paths without .."}}
    end.

%% The project root is two levels above .symbolic/config.json.
-spec project_root(file:filename()) -> file:filename().
project_root(ConfigPath) ->
    filename:dirname(filename:dirname(filename:absname(ConfigPath))).
