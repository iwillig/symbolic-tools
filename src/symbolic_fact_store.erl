%%% A DETS-backed store for extracted Prolog facts — the persisted
%%% "database" `symbolic parse` writes to the configured store and `symbolic query --db`
%%% reads back, entirely in Erlang-term space. No Prolog text is ever
%%% written or parsed on this path, unlike the old `.pl`-file round trip
%%% (see docs/prolog-store.md, which recommended exactly this: a named
%%% DETS table as the on-disk "erlang style database", reached for
%%% before ever considering something like SQLite).
%%%
%%% Facts are inserted as-is: a fact tuple's own first element (its
%%% functor, e.g. `defines`, `calls`, `comment`) doubles as its DETS key
%%% in a `bag` table, so `dets:lookup(Table, defines)` returns every
%%% `defines/3` fact directly — a free index by predicate, no wrapping
%%% needed. `read/1` just wants the whole fact set back, via `foldl`.
-module(symbolic_fact_store).
-export([write/2, write_bundle/3, write_bundle/4, read/1, write_metadata/2, read_metadata/1, delete_metadata/1]).

%% `symbolic parse` fully regenerates the fact set every run (it's a
%% deterministic function of the source files), so a write replaces
%% whatever was there rather than merging into it.
-spec write(file:filename(), [tuple()]) -> ok.
write(Path, Facts) ->
    ok = filelib:ensure_dir(Path),
    Table = table_name(Path),
    {ok, Table} = dets:open_file(Table, [{file, Path}, {type, bag}]),
    try
        ok = dets:delete_all_objects(Table),
        ok = dets:insert(Table, Facts),
        ok = dets:sync(Table)
    after
        ok = dets:close(Table)
    end,
    %% A direct legacy write cannot leave metadata claiming that an old
    %% per-file sidecar belongs to the newly written fact snapshot.
    ok = delete_metadata(Path),
    _ = file:delete(symbolic_file_cache:path(Path)),
    ok.

%% Stage the facts and metadata before replacing either persisted snapshot.
%% A failed stage or rename leaves the previous database/metadata pair intact.
-spec write_bundle(file:filename(), [tuple()], map()) -> ok | {error, term()}.
write_bundle(Path, Facts, Metadata) ->
    write_bundle(Path, Facts, Metadata, undefined).

%% The file cache is installed in the same rollback-protected bundle as the
%% query snapshot. Older callers without a cache invalidate any old sidecar.
write_bundle(Path, Facts, Metadata, FileCache) ->
    Suffix = ".stage." ++ integer_to_list(erlang:unique_integer([positive, monotonic])),
    StagedDb = Path ++ Suffix,
    StagedMeta = metadata_path(StagedDb),
    Id = crypto:strong_rand_bytes(16),
    CachePairs = case FileCache of
        undefined -> [];
        _ -> [{symbolic_file_cache:path(StagedDb), symbolic_file_cache:path(Path)}]
    end,
    Metadata1 = case FileCache of
        undefined -> maps:remove(<<"file_cache_id">>, Metadata);
        _ -> Metadata#{<<"file_cache_id">> => binary:encode_hex(Id)}
    end,
    try
        ok = filelib:ensure_dir(Path),
        ok = write(StagedDb, Facts),
        ok = write_metadata(StagedDb, Metadata1),
        case FileCache of
            undefined -> ok;
            _ -> ok = symbolic_file_cache:write_stage(StagedDb,
                maps:get(<<"file_cache_id">>, Metadata1), FileCache)
        end,
        case replace_bundle([{StagedDb, Path}, {StagedMeta, metadata_path(Path)}] ++ CachePairs) of
            ok ->
                case FileCache of
                    undefined -> _ = file:delete(symbolic_file_cache:path(Path));
                    _ -> ok
                end,
                refresh_text_index(Path, Facts);
            Error -> Error
        end
    catch
        Class:Reason -> {error, {snapshot_stage_failed, Class, Reason}}
    after
        _ = file:delete(StagedDb),
        _ = file:delete(StagedMeta),
        _ = file:delete(StagedMeta ++ ".tmp"),
        _ = file:delete(symbolic_file_cache:path(StagedDb))
    end.

refresh_text_index(Path, Facts) ->
    try symbolic_search:write_index_cache(Path, Facts) of
        ok -> ok;
        _ -> _ = file:delete(Path ++ ".text_idx"), ok
    catch
        _:_ -> _ = file:delete(Path ++ ".text_idx"), ok
    end.

replace_bundle(Pairs) ->
    Token = integer_to_list(erlang:unique_integer([positive, monotonic])),
    Backups = [{Final, Final ++ ".backup." ++ Token}
               || {_Staged, Final} <- Pairs],
    case backup_files(Backups, []) of
        {ok, Saved} ->
            case install_files(Pairs, []) of
                ok ->
                    delete_backups(Saved),
                    ok;
                {error, Reason, Installed} ->
                    lists:foreach(fun({_Staged, Final}) -> _ = file:delete(Final) end,
                                  Installed),
                    restore_backups(Saved),
                    {error, {snapshot_commit_failed, Reason}}
            end;
        {error, Reason, Saved} ->
            restore_backups(Saved),
            {error, {snapshot_backup_failed, Reason}}
    end.

backup_files([], Saved) -> {ok, Saved};
backup_files([{Final, Backup} | Rest], Saved) ->
    case filelib:is_regular(Final) of
        true ->
            case file:rename(Final, Backup) of
                ok -> backup_files(Rest, [{Final, Backup} | Saved]);
                {error, Reason} -> {error, {Final, Reason}, Saved}
            end;
        false ->
            case file:read_file_info(Final) of
                {error, enoent} -> backup_files(Rest, Saved);
                {ok, _} -> {error, {Final, not_regular_file}, Saved};
                {error, Reason} -> {error, {Final, Reason}, Saved}
            end
    end.

install_files([], _Installed) -> ok;
install_files([{Staged, Final} = Pair | Rest], Installed) ->
    case file:rename(Staged, Final) of
        ok -> install_files(Rest, [Pair | Installed]);
        {error, Reason} -> {error, {Final, Reason}, Installed}
    end.

restore_backups(Saved) ->
    lists:foreach(fun({Final, Backup}) -> _ = file:rename(Backup, Final) end, Saved).

delete_backups(Saved) ->
    lists:foreach(fun({_Final, Backup}) -> _ = file:delete(Backup) end, Saved).

-spec read(file:filename()) -> [tuple()].
read(Path) ->
    Table = table_name(Path),
    {ok, Table} = dets:open_file(Table, [{file, Path}, {type, bag}]),
    try
        dets:foldl(fun(Fact, Acc) -> [Fact | Acc] end, [], Table)
    after
        ok = dets:close(Table)
    end.

-spec write_metadata(file:filename(), map()) -> ok | {error, term()}.
write_metadata(Path, Metadata) ->
    MetaPath = metadata_path(Path),
    filelib:ensure_dir(MetaPath),
    TempPath = MetaPath ++ ".tmp",
    case file:write_file(TempPath, jsx:encode(Metadata)) of
        ok -> file:rename(TempPath, MetaPath);
        Error -> Error
    end.

-spec read_metadata(file:filename()) -> {ok, map()} | not_found | {error, term()}.
read_metadata(Path) ->
    case file:read_file(metadata_path(Path)) of
        {ok, Json} ->
            try {ok, jsx:decode(Json, [return_maps])}
            catch _:_ -> {error, invalid_scan_metadata}
            end;
        {error, enoent} -> not_found;
        {error, Reason} -> {error, Reason}
    end.

delete_metadata(Path) ->
    case file:delete(metadata_path(Path)) of
        ok -> ok;
        {error, enoent} -> ok;
        Error -> Error
    end.

metadata_path(Path) -> Path ++ ".scan.json".

%% dets:open_file/2 registers Table (an atom) as a process-wide name,
%% separate from the file path it's backed by — derived from the path so
%% two different fact databases opened around the same time (e.g. by
%% concurrent eunit tests) never collide on one literal shared atom.
table_name(Path) ->
    list_to_atom("symbolic_fact_store_" ++ integer_to_list(erlang:phash2(Path))).
