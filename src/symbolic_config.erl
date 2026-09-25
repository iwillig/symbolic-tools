%%% `.symbolic/config.json` — a project config file `symbolic parse`
%%% respects, letting one scan cover MULTIPLE paths (directories and/or
%%% individual files — e.g. `src/`, `test/`, and a config file like
%%% `package.json`/`Cargo.toml`) merged into ONE fact set, instead of
%%% the single directory `symbolic parse <dir>` takes directly. See
%%% docs/prolog-store.md and docs/cli-erlang.md.
%%%
%%% Auto-discovered the exact same way as `.symbolic/rules.pl` — see
%%% symbolic_query:discover_up/2, which this module reuses rather than
%%% re-implementing the walk-up algorithm a second time.
%%%
%%% Shape:
%%%   { "paths": ["src", "test", "package.json"] }
%%% Every entry is resolved relative to the config file's OWN directory
%%% (its `.symbolic/` parent — the project root), not the caller's cwd,
%%% so `symbolic parse` behaves the same regardless of where it's
%%% invoked from. JSON (via the `jsx` dependency already used by
%%% symbolic_term_json.erl) rather than another new format — no new
%%% dependency, and every other structured-config format in the fact
%%% schema (TOML/JSON) already gets its own tree-sitter extractor, so
%%% this project's own tooling can already query its own config file
%%% the same way it queries anyone else's.
-module(symbolic_config).

-export([discover/1, read/1, project_root/1]).

-define(CONFIG_DIR, ".symbolic").
-define(CONFIG_FILE, "config.json").

%% discover(StartDir) -> file:filename() | undefined.
%%  Same two-starting-points walk-up as .symbolic/rules.pl.
-spec discover(file:filename()) -> file:filename() | undefined.
discover(StartDir) ->
    symbolic_query:discover_up(StartDir, [?CONFIG_DIR, ?CONFIG_FILE]).

%% read(ConfigPath) -> {ok, [file:filename()]} | {error, term()}.
%%  Reads, JSON-decodes, and validates the config, returning every
%%  listed path resolved to an absolute path. Doesn't check the paths
%%  actually exist — that's symbolic_parse:scan_paths/1's job, so the
%%  same {no_such_path, Path}/{unsupported_file, Path} errors apply
%%  whether a path came from argv or from this file.
-spec read(file:filename()) -> {ok, [file:filename()]} | {error, term()}.
read(ConfigPath) ->
    case file:read_file(ConfigPath) of
        {ok, Bin} -> decode(ConfigPath, Bin);
        {error, Reason} -> {error, {cannot_read_config, ConfigPath, Reason}}
    end.

decode(ConfigPath, Bin) ->
    try jsx:decode(Bin, [return_maps]) of
        Json -> validate(ConfigPath, Json)
    catch
        _:_ -> {error, {invalid_config_json, ConfigPath}}
    end.

validate(ConfigPath, #{<<"paths">> := Paths}) when is_list(Paths), Paths =/= [] ->
    case lists:all(fun is_binary/1, Paths) of
        true ->
            Root = project_root(ConfigPath),
            {ok, [filename:join(Root, binary_to_list(P)) || P <- Paths]};
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

%% ConfigPath is <root>/.symbolic/config.json — the root is two levels
%% up. Exported so a caller with no single Dir of its own (the MCP
%% server's config-driven parse) has something sensible to use as a
%% cache key / rules-discovery start dir — see symbolic_codebase.erl.
-spec project_root(file:filename()) -> file:filename().
project_root(ConfigPath) ->
    filename:dirname(filename:dirname(filename:absname(ConfigPath))).
