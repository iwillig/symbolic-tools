-module(symbolic_codebase_tests).
-include_lib("eunit/include/eunit.hrl").

%% Exercises the MCP server's in-memory cache (symbolic_codebase) end to
%% end: parse -> overview, parse -> query (all solutions, cap, no-solution,
%% bad-goal), and that the cache matches a side-effect-free scan. Uses the
%% same fixtures the ts_extract tests do; assertions are computed from the
%% scan itself so they don't hard-code the fixture contents.
%%
%% Convention (matching prolog_session_registry_tests): each test function
%% takes the per-test setup value (the cache pid, unused here since the cache
%% is a registered process) and RETURNS a 0-arity fun — the actual test case.

-define(FIXTURES, "test/fixtures").

setup() ->
    {ok, Pid} = symbolic_codebase:start_link(),
    Pid.

teardown(Pid) ->
    %% unlink first — start_link/0 linked the server to this test process, so
    %% killing it without unlinking would cascade the exit signal back and
    %% kill the test process too.
    unlink(Pid),
    Ref = erlang:monitor(process, Pid),
    exit(Pid, shutdown),
    receive
        {'DOWN', Ref, process, Pid, _Reason} -> ok
    after 1000 ->
        ok
    end.

%% Trivial gen_server boilerplate — no registered process needed, called
%% directly as pure functions.
handle_cast_is_a_noop_test() ->
    ?assertEqual({noreply, some_state}, symbolic_codebase:handle_cast(ignored, some_state)).

terminate_returns_ok_test() ->
    ?assertEqual(ok, symbolic_codebase:terminate(shutdown, some_state)).

code_change_keeps_state_test() ->
    ?assertEqual({ok, some_state}, symbolic_codebase:code_change(old_vsn, some_state, extra)).

codebase_test_() ->
    {foreach, fun setup/0, fun teardown/1, [
        fun overview_before_parse/1,
        fun query_before_parse_is_error/1,
        fun parse_then_overview_reports_state/1,
        fun cache_matches_side_effect_free_scan/1,
        fun query_all_solutions_match_scan/1,
        fun query_limit_caps_results/1,
        fun query_no_solution_is_empty_ok/1,
        fun query_undefined_predicate_is_error/1,
        fun query_bad_goal_is_error/1,
        fun parse_missing_dir_is_error/1,
        fun query_already_terminated_goal_works/1,
        fun query_non_integer_limit_falls_back_to_default/1,
        fun parse_reports_bash_by_extension/1,
        fun parse_reports_erlang_by_extension/1,
        fun parse_discovers_and_consults_scratch_rules/1,
        fun parse_rules_override_takes_precedence_over_discovery/1,
        fun parse_with_broken_rules_is_error_and_leaves_cache_untouched/1,
        fun parse_crash_is_an_error_and_leaves_cache_and_process_untouched/1,
        fun fixtures_parse_picks_up_the_real_project_rules_file/1,
        fun fixtures_parse_makes_a_real_library_predicate_provable/1,
        fun meta_reports_path_and_parse_ms/1,
        fun two_parsed_directories_stay_independently_cached/1,
        fun no_path_query_and_overview_use_most_recently_parsed_dir/1,
        fun reparsing_one_directory_leaves_the_other_untouched/1,
        fun query_unknown_path_is_error/1,
        fun overview_unknown_path_is_error/1,
        fun trailing_slash_path_normalizes_to_the_same_entry/1,
        fun parse_with_no_path_merges_config_paths/1,
        fun parse_with_no_path_and_no_config_is_error/1,
        fun path_is_a_project_root_uses_its_own_config/1,
        fun two_projects_stay_independently_cached_via_their_own_roots/1,
        fun path_pointing_inside_a_configured_project_is_scanned_literally/1
    ]}.

overview_before_parse(_Setup) ->
    fun() ->
        ?assertMatch({not_parsed, #{loaded := false}}, symbolic_codebase:overview())
    end.

query_before_parse_is_error(_Setup) ->
    fun() ->
        ?assertMatch({error, not_parsed}, symbolic_codebase:query("defines(F, _, _, _, _)"))
    end.

parse_then_overview_reports_state(_Setup) ->
    fun() ->
        {ok, Meta} = symbolic_codebase:parse(?FIXTURES),
        ?assertEqual(true, maps:get(loaded, Meta)),
        ?assert(maps:get(files, Meta) > 0),
        ?assert(maps:get(total_facts, Meta) > 0),
        Languages = maps:get(languages, Meta),
        ?assert(lists:member("typescript", Languages)),
        ?assert(lists:member("bash", Languages)),
        %% overview reflects the same state parse reported.
        {ok, OV} = symbolic_codebase:overview(),
        ?assertEqual(maps:get(total_facts, Meta), maps:get(total_facts, OV)),
        ?assertEqual(maps:get(files, Meta), maps:get(files, OV))
    end.

cache_matches_side_effect_free_scan(_Setup) ->
    fun() ->
        {ok, {_Files, Facts}} = symbolic_parse:scan(?FIXTURES),
        ?assert(Facts =/= []),
        {ok, Meta} = symbolic_codebase:parse(?FIXTURES),
        ?assertEqual(length(Facts), maps:get(total_facts, Meta))
    end.

query_all_solutions_match_scan(_Setup) ->
    fun() ->
        {ok, {_Files, Facts}} = symbolic_parse:scan(?FIXTURES),
        ExpectedFuns = lists:usort([F || {defines, F, _Arity, _Params, _File, _Line} <- Facts]),
        ?assert(ExpectedFuns =/= []),
        {ok, _Meta} = symbolic_codebase:parse(?FIXTURES),
        {ok, Solutions} = symbolic_codebase:query("defines(F, _, _, _, _)"),
        %% Each solution binds exactly F; collect and compare as sets.
        GotFuns = lists:usort([V || Sol <- Solutions, {_K, V} <- Sol]),
        ?assertEqual(ExpectedFuns, GotFuns)
    end.

query_limit_caps_results(_Setup) ->
    fun() ->
        {ok, _Meta} = symbolic_codebase:parse(?FIXTURES),
        {ok, All} = symbolic_codebase:query("defines(F, _, _, _, _)"),
        {Status, One} = symbolic_codebase:query("defines(F, _, _, _, _)", 1),
        ?assertEqual(1, length(One)),
        %% A limit of 1 caps at one solution; it only truncates when more exist.
        case length(All) > 1 of
            true -> ?assertEqual(truncated, Status);
            false -> ?assertEqual(ok, Status)
        end
    end.

query_no_solution_is_empty_ok(_Setup) ->
    fun() ->
        {ok, _Meta} = symbolic_codebase:parse(?FIXTURES),
        %% predicate exists (defines/5) but nothing matches -> clean empty
        ?assertMatch({ok, []}, symbolic_codebase:query("defines(no_such_fun_zz, _, _, _, _)"))
    end.

query_undefined_predicate_is_error(_Setup) ->
    fun() ->
        {ok, _Meta} = symbolic_codebase:parse(?FIXTURES),
        %% a predicate with no clause at all is an existence_error, distinct
        %% from a clean no-solution (the serve layer turns this into a
        %% friendly "no such predicate" message)
        ?assertMatch({error, {existence_error, _, _}},
                     symbolic_codebase:query("zzz_no_such_pred(X)"))
    end.

query_bad_goal_is_error(_Setup) ->
    fun() ->
        {ok, _Meta} = symbolic_codebase:parse(?FIXTURES),
        %% An unbalanced goal is a guaranteed parse error (not a no-solution).
        ?assertMatch({error, _}, symbolic_codebase:query("defines("))
    end.

parse_missing_dir_is_error(_Setup) ->
    fun() ->
        ?assertMatch({error, {no_such_directory, _}},
                     symbolic_codebase:parse("no/such/dir_zz"))
    end.

%% ensure_terminated/1's `true` branch (goal already ends in ".") vs.
%% every other test here, which always relies on the `false` branch
%% (auto-appending "."). Same result either way.
query_already_terminated_goal_works(_Setup) ->
    fun() ->
        {ok, _Meta} = symbolic_codebase:parse(?FIXTURES),
        {ok, WithDot} = symbolic_codebase:query("defines(F, _, _, _, _)."),
        {ok, WithoutDot} = symbolic_codebase:query("defines(F, _, _, _, _)"),
        ?assertEqual(WithoutDot, WithDot)
    end.

%% clamp_limit/1's fallback clause: a non-integer Limit behaves exactly
%% like the default (50), rather than crashing or hanging.
query_non_integer_limit_falls_back_to_default(_Setup) ->
    fun() ->
        {ok, _Meta} = symbolic_codebase:parse(?FIXTURES),
        {Status, Solutions} = symbolic_codebase:query("defines(F, _, _, _, _)", not_a_number),
        {DefaultStatus, DefaultSolutions} = symbolic_codebase:query("defines(F, _, _, _, _)"),
        ?assertEqual(DefaultStatus, Status),
        ?assertEqual(DefaultSolutions, Solutions)
    end.

%% language_from_ext/1's ".bash" clause — every other test here only
%% ever scans TypeScript/Markdown/TOML/JSON/".sh" fixtures.
parse_reports_bash_by_extension(_Setup) ->
    fun() ->
        {ok, Meta} = symbolic_codebase:parse(?FIXTURES),
        Languages = maps:get(languages, Meta),
        ?assert(lists:member("bash", Languages))
    end.

%% language_from_ext/1's ".erl" clause. A real .erl fixture can't live
%% under test/fixtures/ (rebar3's eunit provider compiles every .erl
%% under test/ as a project module — see ts_extract_dispatch_tests.erl),
%% so this scans a scratch directory created just for this test.
parse_reports_erlang_by_extension(_Setup) ->
    fun() ->
        Dir = filename:join(["_build", "erl_lang_test_scratch"]),
        ok = filelib:ensure_path(Dir),
        Path = filename:join(Dir, "sample.erl"),
        ok = file:write_file(Path, <<"-module(sample).\none() -> ok.\n">>),
        {ok, Meta} = symbolic_codebase:parse(Dir),
        ok = file:delete(Path),
        Languages = maps:get(languages, Meta),
        ?assert(lists:member("erlang", Languages))
    end.

%% --- .symbolic/rules.pl parity with the CLI (symbolic_query:resolve_rules/3) ---

%% Discovery walks up from the scanned directory itself (mirroring
%% symbolic_query:discover_rules_from_dir/1's use of the fact db's own
%% directory), so a project's own library is consulted with no extra
%% argument — the derived predicate it defines (named/1) becomes provable
%% and Meta reports exactly which file was consulted.
parse_discovers_and_consults_scratch_rules(_Setup) ->
    fun() ->
        with_scratch_codebase(fun(Root, RulesPath) ->
            {ok, Meta} = symbolic_codebase:parse(Root),
            ?assertEqual(RulesPath, maps:get(rules_file, Meta)),
            ?assertMatch({ok, [_ | _]}, symbolic_codebase:query("named(F)"))
        end)
    end.

%% An explicit rules override is never second-guessed by discovery — the
%% scratch project's own .symbolic/rules.pl (defining named/1) is skipped
%% entirely in favor of the override (defining other_named/1 instead).
parse_rules_override_takes_precedence_over_discovery(_Setup) ->
    fun() ->
        with_scratch_codebase(fun(Root, _DiscoveredRulesPath) ->
            OverridePath = filename:join(["_build", "codebase_override_rules_scratch.pl"]),
            ok = file:write_file(OverridePath,
                <<"other_named(F) :- defines(F, _, _, _, _).\n">>),
            try
                {ok, Meta} = symbolic_codebase:parse(Root, OverridePath),
                ?assertEqual(OverridePath, maps:get(rules_file, Meta)),
                ?assertMatch({ok, [_ | _]}, symbolic_codebase:query("other_named(F)")),
                ?assertMatch({error, {existence_error, _, _}},
                    symbolic_codebase:query("named(F)"))
            after
                file:delete(OverridePath)
            end
        end)
    end.

%% A rules file that fails to consult fails the whole parse — the
%% previously cached codebase (from a prior good parse) stays exactly as
%% it was, same as a query timeout/crash never touches the cache either.
parse_with_broken_rules_is_error_and_leaves_cache_untouched(_Setup) ->
    fun() ->
        {ok, GoodMeta} = symbolic_codebase:parse(?FIXTURES),
        Result = symbolic_codebase:parse(?FIXTURES, "no/such/rules_zz.pl"),
        ?assertMatch({error, {rules_error, "no/such/rules_zz.pl", _}}, Result),
        {ok, StillGoodMeta} = symbolic_codebase:overview(),
        ?assertEqual(GoodMeta, StillGoodMeta)
    end.

%% Issue #4's structural fix: a crash ANYWHERE during a `parse` call —
%% not just inside file extraction, which
%% symbolic_parse_tests:extract_file_timed_survives_a_crashing_file_test
%% already covers — must never take down this shared gen_server, which
%% would otherwise silently kill every OTHER already-cached, unrelated
%% project's entry too (confirmed against the real bug report: four
%% unrelated directories, already parsed successfully, all started
%% failing with {noproc,...} after one crashed parse elsewhere, until
%% the MCP client reconnected). Forced via meck rather than a real
%% crashing input — the point here is the CATCHING mechanism itself,
%% generic over the cause, not any one specific bug.
parse_crash_is_an_error_and_leaves_cache_and_process_untouched(_Setup) ->
    fun() ->
        {ok, GoodMeta} = symbolic_codebase:parse(?FIXTURES),
        Pid = whereis(symbolic_codebase),
        meck:new(symbolic_parse, [passthrough]),
        meck:expect(symbolic_parse, scan, fun(_Dir) -> error(boom) end),
        try
            Result = symbolic_codebase:parse(?FIXTURES),
            ?assertMatch({error, {parse_crashed, {error, boom}}}, Result)
        after
            meck:unload(symbolic_parse)
        end,
        %% The gen_server process itself is still the SAME pid — a crash
        %% inside handle_call would have killed it (and, if respawned by
        %% a supervisor, come back as a DIFFERENT pid with an empty
        %% cache, losing every entry).
        ?assertEqual(Pid, whereis(symbolic_codebase)),
        {ok, StillGoodMeta} = symbolic_codebase:overview(),
        ?assertEqual(GoodMeta, StillGoodMeta)
    end.

%% test/fixtures lives inside this repo, so a parse of it walks up to this
%% project's own real .symbolic/rules.pl (the same file the CLI's
%% docs/lint-queries.md library documents) — proving discovery reaches
%% the real library, not just a hand-written scratch one.
fixtures_parse_picks_up_the_real_project_rules_file(_Setup) ->
    fun() ->
        {ok, Meta} = symbolic_codebase:parse(?FIXTURES),
        ?assertEqual(filename:absname(filename:join([".symbolic", "rules.pl"])),
            maps:get(rules_file, Meta))
    end.

%% The concrete "an agent calling the tool that's actually connected can
%% use the derived-predicate library" proof: callees/2 (from the real
%% .symbolic/rules.pl) resolves against test/fixtures/sample.ts's `foo`,
%% which calls both a local function and a method — an
%% existence_error here would mean the library silently isn't loaded.
fixtures_parse_makes_a_real_library_predicate_provable(_Setup) ->
    fun() ->
        {ok, _Meta} = symbolic_codebase:parse(?FIXTURES),
        ?assertMatch({ok, [_ | _]}, symbolic_codebase:query("callees(foo, Callees)"))
    end.

%% --- multiple cached directories, keyed by path ---

%% compute_meta/5's two new fields, on top of the ones every other test
%% here already checks: `path` is the normalized (absolute) directory
%% `parse` was given, `parse_ms` is how long that scan+build took.
meta_reports_path_and_parse_ms(_Setup) ->
    fun() ->
        {ok, Meta} = symbolic_codebase:parse(?FIXTURES),
        ?assertEqual(filename:absname(?FIXTURES), maps:get(path, Meta)),
        ?assert(is_integer(maps:get(parse_ms, Meta))),
        ?assert(maps:get(parse_ms, Meta) >= 0)
    end.

%% Parsing DirB no longer evicts DirA's cache entry — both stay queryable
%% by passing their own path to query/3 and overview/1, and each only
%% proves goals against its own facts.
two_parsed_directories_stay_independently_cached(_Setup) ->
    fun() ->
        with_two_scratch_dirs(fun(DirA, DirB) ->
            {ok, _} = symbolic_codebase:parse(DirA),
            {ok, _} = symbolic_codebase:parse(DirB),
            {ok, SolA} = symbolic_codebase:query("defines(alpha_fn, 0, _, _, _)", 50, DirA),
            ?assertEqual(1, length(SolA)),
            {ok, SolB} = symbolic_codebase:query("defines(beta_fn, 0, _, _, _)", 50, DirB),
            ?assertEqual(1, length(SolB)),
            %% DirA's cache has no beta_fn and vice versa — not one merged pool.
            {ok, NoBetaInA} = symbolic_codebase:query("defines(beta_fn, 0, _, _, _)", 50, DirA),
            ?assertEqual([], NoBetaInA),
            {ok, NoAlphaInB} = symbolic_codebase:query("defines(alpha_fn, 0, _, _, _)", 50, DirB),
            ?assertEqual([], NoAlphaInB),
            {ok, OverviewA} = symbolic_codebase:overview(DirA),
            ?assertEqual(filename:absname(DirA), maps:get(path, OverviewA)),
            {ok, OverviewB} = symbolic_codebase:overview(DirB),
            ?assertEqual(filename:absname(DirB), maps:get(path, OverviewB))
        end)
    end.

%% Omitting Path on query/overview falls back to whichever directory was
%% parsed most recently — parsing DirB after DirA moves that fallback from
%% DirA to DirB.
no_path_query_and_overview_use_most_recently_parsed_dir(_Setup) ->
    fun() ->
        with_two_scratch_dirs(fun(DirA, DirB) ->
            {ok, _} = symbolic_codebase:parse(DirA),
            {ok, SolAfterA} = symbolic_codebase:query("defines(alpha_fn, 0, _, _, _)"),
            ?assertEqual(1, length(SolAfterA)),
            {ok, _} = symbolic_codebase:parse(DirB),
            {ok, SolAfterB} = symbolic_codebase:query("defines(alpha_fn, 0, _, _, _)"),
            ?assertEqual([], SolAfterB),
            {ok, OV} = symbolic_codebase:overview(),
            ?assertEqual(filename:absname(DirB), maps:get(path, OV))
        end)
    end.

%% Same guarantee handle_call({parse,...}) documents: a fresh parse of one
%% directory leaves every other cached directory's entry byte-for-byte as
%% it was, whether the fresh parse succeeds or (as
%% parse_with_broken_rules_is_error_and_leaves_cache_untouched already
%% covers for the single-directory case) fails.
reparsing_one_directory_leaves_the_other_untouched(_Setup) ->
    fun() ->
        with_two_scratch_dirs(fun(DirA, DirB) ->
            {ok, _} = symbolic_codebase:parse(DirA),
            {ok, _} = symbolic_codebase:parse(DirB),
            {ok, BeforeA} = symbolic_codebase:overview(DirA),
            {ok, _} = symbolic_codebase:parse(DirB),
            {ok, AfterA} = symbolic_codebase:overview(DirA),
            ?assertEqual(BeforeA, AfterA)
        end)
    end.

%% {error, {unknown_path, Path}} is distinct from {error, not_parsed}: it
%% means *something* is cached, just not the directory asked for.
query_unknown_path_is_error(_Setup) ->
    fun() ->
        {ok, _} = symbolic_codebase:parse(?FIXTURES),
        ?assertMatch({error, {unknown_path, "no/such/dir_never_parsed_zz"}},
            symbolic_codebase:query("defines(F, _, _, _, _)", 50, "no/such/dir_never_parsed_zz"))
    end.

overview_unknown_path_is_error(_Setup) ->
    fun() ->
        {ok, _} = symbolic_codebase:parse(?FIXTURES),
        ?assertMatch({error, {unknown_path, "no/such/dir_never_parsed_zz"}},
            symbolic_codebase:overview("no/such/dir_never_parsed_zz"))
    end.

%% normalize_dir/1 strips a trailing "/" before using a path as a cache
%% key, so "test/fixtures" and "test/fixtures/" name the same entry rather
%% than silently doubling it up.
trailing_slash_path_normalizes_to_the_same_entry(_Setup) ->
    fun() ->
        {ok, Meta} = symbolic_codebase:parse(?FIXTURES),
        ?assertMatch({ok, _}, symbolic_codebase:overview(?FIXTURES ++ "/")),
        {ok, OV} = symbolic_codebase:overview(?FIXTURES ++ "/"),
        ?assertEqual(maps:get(path, Meta), maps:get(path, OV))
    end.

%% Two scratch directories under _build/, each with one distinctively-named
%% function, so a query naming that function proves it's reading the right
%% cache entry rather than some merged pool. Fun gets both absolute roots.
with_two_scratch_dirs(Fun) ->
    DirA = filename:absname(filename:join(["_build", "codebase_multi_scratch_a"])),
    DirB = filename:absname(filename:join(["_build", "codebase_multi_scratch_b"])),
    _ = file:del_dir_r(DirA),
    _ = file:del_dir_r(DirB),
    ok = filelib:ensure_path(DirA),
    ok = filelib:ensure_path(DirB),
    ok = file:write_file(filename:join(DirA, "sample.erl"),
        <<"-module(sample_multi_a).\nalpha_fn() -> ok.\n">>),
    ok = file:write_file(filename:join(DirB, "sample.erl"),
        <<"-module(sample_multi_b).\nbeta_fn() -> ok.\n">>),
    try
        Fun(DirA, DirB)
    after
        _ = file:del_dir_r(DirA),
        _ = file:del_dir_r(DirB)
    end.

%% parse(undefined, ...) — no `path` at all — falls back to
%% .symbolic/config.json's `paths` list, discovered by walking up from
%% this SERVER PROCESS's own cwd (there's no per-call start dir the way
%% a Dir-based parse has), so proving it works means actually chdir-ing
%% for the duration of the test — same technique
%% symbolic_query_tests.erl's resolve_rules_falls_back_to_the_cwd_test
%% already establishes for the analogous rules-discovery case.
parse_with_no_path_merges_config_paths(_Setup) ->
    fun() ->
        with_scratch_config_codebase(fun(Root, _ConfigPath) ->
            OldCwd = get_cwd(),
            set_cwd(Root),
            try
                {ok, Meta} = symbolic_codebase:parse(undefined),
                %% Cached under the project root, not any single Dir —
                %% queryable by that same path afterward.
                ?assertEqual(Root, maps:get(path, Meta)),
                {ok, Solutions} = symbolic_codebase:query("defines(F, _, _, _, _)", 50, Root),
                Names = lists:sort([proplists:get_value('F', Bs) || Bs <- Solutions]),
                ?assertEqual([hello, run], Names)
            after
                restore_cwd(OldCwd)
            end
        end)
    end.

parse_with_no_path_and_no_config_is_error(_Setup) ->
    fun() ->
        OldCwd = get_cwd(),
        %% "/" itself has no .symbolic/config.json, and walking up from it
        %% (and from "/" again as the cwd fallback) can only ever find
        %% nothing — the one starting point discovery can't climb past.
        set_cwd("/"),
        try
            ?assertMatch({error, {no_config_found, _}}, symbolic_codebase:parse(undefined))
        after
            restore_cwd(OldCwd)
        end
    end.

%% Passing a project's own ROOT directory (the one that directly has
%% .symbolic/config.json) as `path` is what actually closes the "only
%% one project at a time via config mode" gap the cwd-only "no path
%% given" case has: it targets that project regardless of this server's
%% own cwd, with no chdir at all — unlike
%% parse_with_no_path_merges_config_paths/1 above, which still had to
%% temporarily chdir to prove the cwd-based DEFAULT path worked. Not a
%% walk-up: Root is passed exactly, and own_config/1 finds
%% Root/.symbolic/config.json directly, no ancestor climbing involved.
path_is_a_project_root_uses_its_own_config(_Setup) ->
    fun() ->
        with_scratch_config_codebase(fun(Root, ConfigPath) ->
            %% The server's own cwd is wherever `rebar3 eunit` runs from —
            %% this project's real root, which has its OWN real
            %% .symbolic/config.json. Proving Root wins means the scratch
            %% project's facts show up, not the real one's.
            {ok, Meta} = symbolic_codebase:parse(Root),
            ?assertEqual(Root, maps:get(path, Meta)),
            ?assertEqual(ConfigPath, maps:get(config_file, Meta)),
            {ok, Solutions} = symbolic_codebase:query("defines(F, _, _, _, _)", 50, Root),
            Names = lists:sort([proplists:get_value('F', Bs) || Bs <- Solutions]),
            ?assertEqual([hello, run], Names)
        end)
    end.

%% The scenario this whole feature is for: ONE running server, TWO
%% projects, both cached and independently queryable at once — neither
%% touches the other's entry, same guarantee two Dir-based parses
%% already had (two_parsed_directories_stay_independently_cached above),
%% now proven for config-driven parsing too.
two_projects_stay_independently_cached_via_their_own_roots(_Setup) ->
    fun() ->
        with_scratch_config_codebase(fun(RootA, _ConfigPathA) ->
            with_scratch_config_codebase(other, fun(RootB, _ConfigPathB) ->
                {ok, MetaA} = symbolic_codebase:parse(RootA),
                {ok, MetaB} = symbolic_codebase:parse(RootB),
                ?assertEqual(RootA, maps:get(path, MetaA)),
                ?assertEqual(RootB, maps:get(path, MetaB)),
                ?assertNotEqual(RootA, RootB),
                %% Both still queryable by their own path after the SECOND
                %% parse — parsing project B didn't touch project A's entry.
                {ok, SolutionsA} = symbolic_codebase:query("defines(F, _, _, _, _)", 50, RootA),
                {ok, SolutionsB} = symbolic_codebase:query("defines(F, _, _, _, _)", 50, RootB),
                ?assertEqual(2, length(SolutionsA)),
                ?assertEqual(2, length(SolutionsB))
            end)
        end)
    end.

%% own_config/1's whole point: an explicit path must NOT walk up its
%% ancestors looking for a project. A subdirectory of an already-
%% configured project (the scratch project's own "src") has no
%% .symbolic/config.json directly inside IT, so it's scanned literally
%% — one file's worth of facts, not the whole two-directory project.
path_pointing_inside_a_configured_project_is_scanned_literally(_Setup) ->
    fun() ->
        with_scratch_config_codebase(fun(Root, _ConfigPath) ->
            Src = filename:join([Root, "src"]),
            {ok, Meta} = symbolic_codebase:parse(Src),
            ?assertEqual(filename:absname(Src), maps:get(path, Meta)),
            ?assertNot(maps:is_key(config_file, Meta)),
            {ok, Solutions} = symbolic_codebase:query("defines(F, _, _, _, _)", 50, Src),
            ?assertEqual([hello], [proplists:get_value('F', Bs) || Bs <- Solutions])
        end)
    end.

get_cwd() ->
    {ok, Cwd} = file:get_cwd(),
    Cwd.

set_cwd(Dir) ->
    ok = file:set_cwd(Dir).

restore_cwd(Cwd) ->
    set_cwd(Cwd),
    ?assertEqual(Cwd, get_cwd()).

%% A scratch project under _build/ with its own .symbolic/config.json
%% listing "src" and "test", plus real source files under each, so
%% parse(undefined, ...) has something real to merge.
with_scratch_config_codebase(Fun) ->
    with_scratch_config_codebase(default, Fun).

%% Tag distinguishes two scratch projects existing AT ONCE (see
%% two_projects_stay_independently_cached_via_config_override/1) — each
%% gets its own root under _build/, so one's setup/teardown never
%% touches the other's files.
with_scratch_config_codebase(Tag, Fun) ->
    Root = filename:absname(filename:join(["_build",
        "codebase_config_scratch_project_" ++ atom_to_list(Tag)])),
    _ = file:del_dir_r(Root),
    ConfigPath = filename:join([Root, ".symbolic", "config.json"]),
    ok = filelib:ensure_dir(ConfigPath),
    ok = file:write_file(ConfigPath, <<"{\"paths\": [\"src\", \"test\"]}">>),
    ok = filelib:ensure_dir(filename:join([Root, "src", "placeholder"])),
    ok = filelib:ensure_dir(filename:join([Root, "test", "placeholder"])),
    ok = file:write_file(filename:join([Root, "src", "greeter.erl"]),
        <<"-module(greeter).\nhello() -> ok.\n">>),
    ok = file:write_file(filename:join([Root, "test", "greeter_tests.erl"]),
        <<"-module(greeter_tests).\nrun() -> ok.\n">>),
    try
        Fun(Root, ConfigPath)
    after
        _ = file:del_dir_r(Root)
    end.

%% A scratch project under _build/: <root>/.symbolic/rules.pl (defining
%% named/1, the same convention symbolic_query_tests.erl's
%% with_scratch_project/1 uses) plus a source file to scan, since
%% symbolic_codebase:parse/1,2 needs something to extract facts from.
%% Fun gets the absolute root path and the rules file's path.
with_scratch_codebase(Fun) ->
    Root = filename:absname(filename:join(["_build", "codebase_scratch_project"])),
    _ = file:del_dir_r(Root),
    RulesPath = filename:join([Root, ".symbolic", "rules.pl"]),
    ok = filelib:ensure_dir(RulesPath),
    ok = file:write_file(RulesPath, <<"named(F) :- defines(F, _, _, _, _).\n">>),
    ok = file:write_file(filename:join([Root, "sample.erl"]),
        <<"-module(sample).\none() -> ok.\n">>),
    try
        Fun(Root, RulesPath)
    after
        _ = file:del_dir_r(Root)
    end.
