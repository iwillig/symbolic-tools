%%% @doc Build identity of the *running* symbolic_tools code itself —
%%% distinct from any parsed project's own metadata (that's `path`,
%%% `files`, `languages`, ... in symbolic_codebase:compute_meta/5).
%%%
%%% The MCP server / released CLI is a long-running BEAM node: after a
%%% source change, `rebar3 compile`/`release` produces new beam files,
%%% but the already-running node keeps the old ones loaded until it is
%%% restarted. `info/0` gives an agent (or a person) a way to tell,
%%% from a `parse`/`overview` response alone, whether the connected
%%% server has actually picked up a given commit yet — compare
%%% `git_sha` here against `git rev-parse HEAD` in a checkout.
-module(symbolic_version).

-export([info/0, vsn/0, git_sha/0]).

-spec info() -> #{vsn := binary(), git_sha := binary()}.
info() ->
    #{vsn => vsn(), git_sha => git_sha()}.

%% The symbolic_tools .app vsn (currently a hand-maintained literal in
%% symbolic_tools.app.src) — coarser than git_sha, but stable across a
%% source tree that has no .git (e.g. a packaged/vendored copy).
-spec vsn() -> binary().
vsn() ->
    case application:get_key(symbolic_tools, vsn) of
        {ok, Vsn} -> unicode:characters_to_binary(Vsn);
        undefined -> <<"unknown">>
    end.

%% The full commit SHA symbolic_tools was built from, read from
%% priv/git_sha — written at build time by scripts/gen_git_sha.sh (a
%% rebar3 pre_hook on `compile`, so it covers `compile`, `eunit`, and
%% `release` alike). "unknown" covers both "built outside a git
%% checkout" and "built before this mechanism existed" — an old release
%% predating priv/git_sha has no such file at all.
-spec git_sha() -> binary().
git_sha() ->
    case code:priv_dir(symbolic_tools) of
        {error, bad_name} ->
            <<"unknown">>;
        PrivDir ->
            case file:read_file(filename:join(PrivDir, "git_sha")) of
                {ok, Bin} -> string:trim(Bin, both, "\n\r\t ");
                {error, _} -> <<"unknown">>
            end
    end.
