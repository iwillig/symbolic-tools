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
        fun fixtures_parse_picks_up_the_real_project_rules_file/1,
        fun fixtures_parse_makes_a_real_library_predicate_provable/1
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
