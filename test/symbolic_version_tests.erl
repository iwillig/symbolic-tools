%% symbolic_version — the running build's own identity (vsn + git_sha),
%% deliberately NOT a parsed project's metadata. Coverage gap noted by a
%% symbolic-tools review: no test file depends on this module at all, so
%% its three exported functions ran only as incidental output inside
%% serve/CLI tests.
%%
%% Execution-heavy, assertion-light on purpose, same shape as
%% print_fact_does_not_crash_test: git_sha/0's value depends on WHERE
%% the suite runs (a real checkout writes a real SHA at compile time
%% via scripts/gen_git_sha.sh; a packaged build may not), and vsn/0's
%% on how the app was started. What can be pinned is the CONTRACT: all
%% three return binaries (never crash, never a non-binary), and info/0
%% carries exactly the vsn and git_sha its own two helpers return —
%% the "compare git_sha against `git rev-parse HEAD`" workflow in the
%% module's header comment is only sound if info/0 is not allowed to
%% drift from the pair it claims to report.
-module(symbolic_version_tests).
-include_lib("eunit/include/eunit.hrl").

info_is_vsn_and_git_sha_test() ->
    Info = symbolic_version:info(),
    ?assertEqual([git_sha, vsn], lists:sort(maps:keys(Info))),
    ?assertEqual(symbolic_version:git_sha(), maps:get(git_sha, Info)),
    ?assertEqual(symbolic_version:vsn(), maps:get(vsn, Info)).

all_three_return_binaries_test() ->
    %% info/0 is a MAP (its two scalar helpers below are the binaries);
    %% vsn/0's "unknown" fallback is a real contract value, not a crash —
    %% application:get_key/2 yields undefined whenever the app is not
    %% loaded (eunit runs the module without a full release boot), and
    %% the module's own header documents that as a covered case.
    ?assert(is_binary(symbolic_version:vsn())),
    ?assert(is_binary(symbolic_version:git_sha())).

%% In this repo eunit always runs after the gen_git_sha.sh pre_hook has
%% written priv/git_sha (a rebar3 pre_hook on `compile`), and the file's
%% content is `git rev-parse HEAD` — a 40-char hex SHA. So inside THIS
%% checkout the strong assertion holds: a non-hex or "unknown" value
%% here means the pre_hook wiring broke, which is exactly the failure
%% the "which build am I talking to" workflow needs to catch.
git_sha_is_a_real_sha_in_this_checkout_test() ->
    Sha = symbolic_version:git_sha(),
    ?assert(Sha =/= <<"unknown">>),
    ?assertMatch({match, _}, re:run(Sha, "^[0-9a-f]{40}$")).

