%%% Full-text search NIF (native/symbolic_text — a Rustler crate, built
%%% into priv/symbolic_text.so by scripts/build_nif.sh). A purpose-built
%%% inverted index scored with BM25, over UAX #29 word tokens from
%%% unicode-segmentation — zero-model, deterministic: the same query
%%% against the same index always returns the same order (scores
%%% descending, ties by doc id ascending). The stack decision and its
%%% rejected alternatives (tantivy, charabia, stemming) are recorded in
%%% docs/full-text-search.md.
%%%
%%% Unlike symbolic_ts's raw-pointer resources, this NIF's resource is a
%%% Mutex<Index> — genuinely thread-safe, so any process may hold an
%%% index term. Fallible calls return {error, Reason} tuples (never a
%%% raise): invalid_utf8 for text that isn't valid UTF-8, io_error /
%%% bad_snapshot for save/load. index_add_doc/3 and index_save/2 return
%%% the bare atom ok on success. Text and path arguments are UTF-8
%%% BINARIES — rustler's String decoder rejects plain lists loudly,
%%% never guessing (use unicode:characters_to_binary/1 on the caller's
%%% side).
%%%
%%% Concurrency contract: index_add_doc/3 and index_search/3 are
%%% DirtyCpu (a whole corpus is unbounded CPU); index_save/2 and
%%% index_load/1 are DirtyIo; tokenize/1 and index_stats/1 are cheap.
-module(symbolic_text).
-export([
    index_new/0,
    index_add_doc/3,
    index_search/3,
    index_stats/1,
    index_save/2,
    index_snapshot/1,
    index_load/1,
    index_load_binary/1,
    tokenize/1
]).

-on_load(init/0).

-define(APPNAME, symbolic_tools).
-define(LIBNAME, symbolic_text).

init() ->
    ok = load_first_so_candidate(so_candidates()).

%% so_candidates() -> [file()].
%%
%% Same priv_dir-into-a-stale-_build-copy hazard as symbolic_ts.erl's own
%% comment describes: try code:priv_dir/1 first (right for a packaged
%% release), then the repo-relative priv/ that build_nif.sh writes on
%% every compile.
so_candidates() ->
    RepoPriv = filename:join(["priv", atom_to_list(?LIBNAME)]),
    case code:priv_dir(?APPNAME) of
        {error, bad_name} -> [RepoPriv];
        Dir -> [filename:join(Dir, atom_to_list(?LIBNAME)), RepoPriv]
    end.

load_first_so_candidate([SoFile]) ->
    erlang:load_nif(SoFile, 0);
load_first_so_candidate([SoFile | Rest]) ->
    case erlang:load_nif(SoFile, 0) of
        ok -> ok;
        {error, _LoadReason} -> load_first_so_candidate(Rest)
    end.

index_new() -> erlang:nif_error(nif_not_loaded).
index_add_doc(_Index, _DocId, _Text) -> erlang:nif_error(nif_not_loaded).
index_search(_Index, _Query, _Limit) -> erlang:nif_error(nif_not_loaded).
index_stats(_Index) -> erlang:nif_error(nif_not_loaded).
index_save(_Index, _Path) -> erlang:nif_error(nif_not_loaded).
index_snapshot(_Index) -> erlang:nif_error(nif_not_loaded).
index_load(_Path) -> erlang:nif_error(nif_not_loaded).
index_load_binary(_Bytes) -> erlang:nif_error(nif_not_loaded).
tokenize(_Text) -> erlang:nif_error(nif_not_loaded).
