%%% Candidate freshness fingerprint for a compiler probe. NOT a complete
%%% checker reuse contract: environment and arbitrary external inputs still
%%% need a closed-world proof before cached facts may be served. Include the
%%% root inventory to notice newly resolvable files, and hash known compiler
%%% input types. A missing or external input fails closed.
-module(symbolic_ts_inputs).
-export([workspace/1, project_fingerprint/3, fingerprint/3,
         begin_observation/2, finish_observation/4, candidate/3, metadata/1]).
-include_lib("kernel/include/file.hrl").

-define(CONTENT_EXTENSIONS,
    [".ts", ".tsx", ".mts", ".cts", ".js", ".jsx", ".mjs", ".cjs",
     ".json", ".jsonc", ".yaml", ".yml", ".lock"]).

%% Capture before analysis; then repeat the full observation after analysis.
%% The candidate is accepted only when inputs were stable throughout.
-spec begin_observation(file:filename(), [file:filename()]) -> {ok, map()} | unavailable.
begin_observation(Root, Projects) when is_list(Projects), Projects =/= [] ->
    case workspace(Root) of
        {ok, W} -> candidate_projects(Projects, W, #{});
        unavailable -> unavailable
    end;
begin_observation(_, _) -> unavailable.

-spec finish_observation(map(), map(), file:filename(), [file:filename()]) ->
    {ok, map()} | unavailable.
finish_observation(Before, Report, Root, Projects) ->
    case candidate(Report, Root, Projects) of
        {ok, Before} when is_map(Before) -> {ok, Before#{validated => true}};
        _ -> unavailable
    end.

%% Observe a candidate manifest for a successfully analyzed, complete scan.
%% This never authorizes reuse. A failed probe, an outside dependency, or a
%% missing project yields no candidate rather than a partial manifest.
-spec candidate(map(), file:filename(), [file:filename()]) -> {ok, map()} | unavailable.
candidate(#{complete := true, type_analysis := #{projects := Summaries}}, Root, Projects)
        when is_list(Projects), Projects =/= [] ->
    Successful = length(Summaries) =:= length(Projects) andalso
        lists:all(fun({Summary, Path}) ->
            lists:member(maps:get(status, Summary, failed), [ok, partial]) andalso
            maps:get(config, Summary, undefined) =:= filename:absname(Path)
        end, lists:zip(Summaries, Projects)),
    case Successful of
        false -> unavailable;
        true ->
            case workspace(Root) of
                {ok, W} -> candidate_projects(Projects, W, #{});
                unavailable -> unavailable
            end
    end;
candidate(_, _, _) -> unavailable.

candidate_projects([], W, Acc) ->
    {ok, #{version => 1, workspace => maps:get(digest, W), projects => Acc}};
candidate_projects([Path | Rest], W, Acc) ->
    case symbolic_tsgo:resolve(Path) of
        {ok, Compiler} ->
            case symbolic_tsgo:probe(Path, Compiler) of
                {ok, Probe} ->
                    case project_fingerprint(W, Path, Probe) of
                        {ok, Digest} ->
                            Key = unicode:characters_to_binary(filename:absname(Path)),
                            candidate_projects(Rest, W, Acc#{Key => Digest});
                        unavailable -> unavailable
                    end;
                _ -> unavailable
            end;
        _ -> unavailable
    end.

%% Metadata is written in the same snapshot bundle as facts, but explicitly
%% non-reusable until the input contract and atomic validation are complete.
-spec metadata(map()) -> map().
metadata(#{complete := true, checker_candidate :=
           #{version := 1, validated := true, workspace := Workspace,
             projects := Projects}})
        when is_binary(Workspace), byte_size(Workspace) =:= 32,
             is_map(Projects) ->
    case map_size(Projects) > 0 andalso
         lists:all(fun({K, V}) -> is_binary(K) andalso is_binary(V)
                               andalso byte_size(V) =:= 32 end,
                   maps:to_list(Projects)) of
        true -> #{<<"checker_candidate">> =>
            #{<<"version">> => 1, <<"validated">> => true,
              <<"reusable">> => false,
              <<"workspace">> => binary:encode_hex(Workspace),
              <<"projects">> => maps:map(fun(_, V) -> binary:encode_hex(V) end,
                                         Projects)}};
        false -> #{}
    end;
metadata(_) -> #{}.

%% Compute this once for every configured project in a parse. A root-wide
%% directory inventory detects added and removed resolution candidates.
-spec workspace(file:filename()) -> {ok, map()} | unavailable.
workspace(Root0) ->
    Root = normalize(filename:absname(Root0)),
    try
        H = walk(Root, Root, crypto:hash_init(sha256)),
        {ok, #{root => Root, digest => crypto:hash_final(H)}}
    catch _:_ -> unavailable
    end.

%% Project-specific compiler closure and options, combined with the shared
%% root digest. A probe outside that root (or a vanished input) cannot reuse.
-spec project_fingerprint(map(), file:filename(), map()) -> {ok, binary()} | unavailable.
project_fingerprint(#{root := Root, digest := Digest}, ConfigPath,
                    #{files := Sources, config := Parsed, version := Version,
                      executable := Exe}) when is_list(Sources), is_binary(Digest) ->
    try
        Inputs = [ConfigPath, Exe | Sources],
        true = lists:all(fun(Path) -> in_root(Path, Root) andalso
                                      filelib:is_regular(Path) end, Inputs),
        %% Nonstandard program sources might be read by a compiler plugin.
        %% Until their content contract is known, do not use this fingerprint.
        true = lists:all(fun(Path) -> content_file(Path) end, Sources),
        H0 = crypto:hash_init(sha256),
        H1 = crypto:hash_update(H0, term_to_binary({3, Root, Digest,
             filename:absname(ConfigPath), Parsed, Version, lists:sort(Sources),
             symbolic_tsgo:module_info(md5),
             symbolic_ts_project:module_info(md5)})),
        {ok, crypto:hash_final(hash_file(Exe, H1))}
    catch _:_ -> unavailable
    end;
project_fingerprint(_, _, _) -> unavailable.

%% Convenience form for single-project callers. Multi-project callers must
%% use workspace/1 once and project_fingerprint/3 for each project.
-spec fingerprint(file:filename(), file:filename(), map()) -> {ok, binary()} | unavailable.
fingerprint(Root, ConfigPath, Probe) ->
    case workspace(Root) of
        {ok, Workspace} -> project_fingerprint(Workspace, ConfigPath, Probe);
        unavailable -> unavailable
    end.

walk(Path, Root, Hash) ->
    {ok, Info} = file:read_link_info(Path),
    Relative = relative(Path, Root),
    case Info#file_info.type of
        directory ->
            {ok, Names} = file:list_dir(Path),
            lists:foldl(fun(Name, Acc) ->
                Child = filename:join(Path, Name),
                case generated_snapshot(Child, Root) of
                    true -> Acc;
                    false -> walk(Child, Root, Acc)
                end
            end, crypto:hash_update(Hash, term_to_binary({dir, Relative})),
            lists:sort(Names));
        regular ->
            H1 = crypto:hash_update(Hash, term_to_binary({file, Relative})),
            case content_file(Path) of
                true -> hash_file(Path, H1);
                false -> H1
            end;
        symlink ->
            {ok, Target} = file:read_link_all(Path),
            Resolved = case filename:pathtype(Target) of
                absolute -> Target;
                _ -> filename:join(filename:dirname(Path), Target)
            end,
            true = in_root(Resolved, Root),
            crypto:hash_update(Hash, term_to_binary({link, Relative, Target}));
        _ -> erlang:error(unsupported_file_type)
    end.

%% The database, its staging files and its sidecars are outputs, not compiler
%% inputs. Keep all other .symbolic files, including config.json, in scope.
generated_snapshot(Path, Root) ->
    Dir = filename:join(Root, ".symbolic"),
    filename:dirname(Path) =:= Dir andalso
        lists:prefix("facts.dets", filename:basename(Path)).

content_file(Path) when is_binary(Path) -> content_file(binary_to_list(Path));
content_file(Path) ->
    lists:member(filename:extension(Path), ?CONTENT_EXTENSIONS) orelse
    lists:member(filename:basename(Path),
                 ["pnpm-lock.yaml", "yarn.lock", "package-lock.json", "bun.lockb"]).

hash_file(Path, Hash) ->
    {ok, Fd} = file:open(Path, [read, binary, raw]),
    try hash_chunks(Fd, Hash)
    after ok = file:close(Fd)
    end.

hash_chunks(Fd, Hash) ->
    case file:read(Fd, 1048576) of
        eof -> Hash;
        {ok, Bin} -> hash_chunks(Fd, crypto:hash_update(Hash, Bin));
        {error, Reason} -> erlang:error(Reason)
    end.

relative(Path, Root) ->
    case Path of
        Root -> ".";
        _ -> lists:nthtail(length(Root) + 1, Path)
    end.

in_root(Path, Root) when is_binary(Path) -> in_root(binary_to_list(Path), Root);
in_root(Path, Root) when is_list(Path) ->
    case filename:pathtype(Path) of
        absolute ->
            Canonical = normalize(Path),
            Canonical =:= Root orelse lists:prefix(Root ++ "/", Canonical);
        _ -> false
    end;
in_root(_, _) -> false.

normalize(Path) ->
    Parts = filename:split(Path),
    Reversed = lists:foldl(fun
        ("..", ["/" | _] = Acc) when length(Acc) =:= 1 -> Acc;
        ("..", [_ | Rest]) -> Rest;
        (".", Acc) -> Acc;
        (Part, Acc) -> [Part | Acc]
    end, [], Parts),
    filename:join(lists:reverse(Reversed)).
