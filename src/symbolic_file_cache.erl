%%% Per-file syntax extraction cache. This is an optimization, never a source
%%% of query facts on its own: every parse still discovers the complete file set.
-module(symbolic_file_cache).
-export([version/0, load/1, load_memory/1, write_stage/3, path/1]).

-define(SCHEMA, 1).

%% Include the actual extractor BEAMs and native parser in the cache identity.
%% A changed implementation invalidates all old per-file entries.
version() ->
    Modules = [ts_extract, ts_extract_common, ts_extract_erlang,
        ts_extract_typescript, ts_extract_jsdoc, ts_extract_markdown,
        ts_extract_json, ts_extract_toml, ts_extract_bash,
        ts_extract_clojure, ts_extract_ruby, ts_extract_rust,
        ts_extract_text, symbolic_ts],
    Beams = [begin
        {module, M} = code:ensure_loaded(M),
        {M, M:module_info(md5)}
    end || M <- Modules],
    Native = case code:priv_dir(symbolic_tools) of
        {error, bad_name} -> "priv/symbolic_ts.so";
        Dir -> filename:join(Dir, "symbolic_ts.so")
    end,
    NativeHash = case file:read_file(Native) of
        {ok, Bytes} -> crypto:hash(sha256, Bytes);
        _ -> missing
    end,
    crypto:hash(sha256, term_to_binary({?SCHEMA, Beams, NativeHash})).

path(Db) -> Db ++ ".files_cache".

%% Only trust a sidecar committed with the current fact snapshot. Old or
%% corrupt cache formats are misses, never failed parses.
load(Db) ->
    case symbolic_fact_store:read_metadata(Db) of
        {ok, #{<<"file_cache_id">> := Id}} ->
            case file:read_file(path(Db)) of
                {ok, Bin} ->
                    %% Source identifiers in facts become dynamic atoms. Like DETS, this
                    %% local snapshot must be trusted; [safe] cannot restore
                    %% those atoms after a VM restart.
                    try binary_to_term(Bin) of
                        #{schema := ?SCHEMA, id := Id, version := Version,
                          files := Files} when is_map(Files) ->
                            case Version =:= version() of
                                true -> Files;
                                false -> #{}
                            end;
                        _ -> #{}
                    catch _:_ -> #{}
                    end;
                _ -> #{}
            end;
        _ -> #{}
    end.

load_memory(#{version := Version, files := Files}) when is_map(Files) ->
    case Version =:= version() of true -> Files; false -> #{} end;
load_memory(_) -> #{}.

write_stage(StagedDb, Id, Files) ->
    file:write_file(path(StagedDb), term_to_binary(
        #{schema => ?SCHEMA, id => Id, version => version(), files => Files})).
