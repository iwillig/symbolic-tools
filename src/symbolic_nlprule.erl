%%% Rustler wrapper for the nlprule English tokenizer NIF.
%%% The external en_tokenizer.bin is loaded from SYMBOLIC_NLPRULE_DATA.
-module(symbolic_nlprule).
-export([analyze/1]).

-on_load(init/0).

-define(APPNAME, symbolic_tools).
-define(LIBNAME, symbolic_nlprule).

init() ->
    SoFile = case code:priv_dir(?APPNAME) of
        {error, bad_name} -> filename:join(["priv", atom_to_list(?LIBNAME)]);
        Dir -> filename:join(Dir, atom_to_list(?LIBNAME))
    end,
    ok = erlang:load_nif(SoFile, 0).

analyze(_Text) -> erlang:nif_error(nif_not_loaded).
