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
-export([write/2, read/1, write_metadata/2, read_metadata/1, delete_metadata/1]).

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
    end.

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
