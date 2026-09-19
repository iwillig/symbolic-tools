%%% A DETS-backed store for extracted Prolog facts — the persisted
%%% "database" `symbolic parse --db` writes and `symbolic query --db`
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
-export([write/2, read/1]).

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

%% dets:open_file/2 registers Table (an atom) as a process-wide name,
%% separate from the file path it's backed by — derived from the path so
%% two different fact databases opened around the same time (e.g. by
%% concurrent eunit tests) never collide on one literal shared atom.
table_name(Path) ->
    list_to_atom("symbolic_fact_store_" ++ integer_to_list(erlang:phash2(Path))).
