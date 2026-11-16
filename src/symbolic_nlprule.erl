%%% Rustler wrapper for the nlprule English tokenizer NIF.
%%% The external en_tokenizer.bin is loaded from SYMBOLIC_NLPRULE_DATA.
-module(symbolic_nlprule).
-export([analyze/1]).

-on_load(init/0).

-define(APPNAME, symbolic_tools).
-define(LIBNAME, symbolic_nlprule).

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

analyze(_Text) -> erlang:nif_error(nif_not_loaded).
