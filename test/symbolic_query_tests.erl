-module(symbolic_query_tests).
-include_lib("eunit/include/eunit.hrl").

%% run/2,3,4 themselves stay untested here — they only print a result and
%% halt(), nothing left to assert on. Everything that decides *what*
%% the outcome is now lives in the halt-free run_result/3, exercised
%% directly below for every outcome shape; the rules-path decision
%% (explicit vs -no-rules vs .symbolic/rules.pl discovery) is the one
%% other piece with real logic, so resolve_rules/3 is exercised too.

-define(DB, filename:join(["_build", "symbolic_query_test_scratch.dets"])).

with_db(Facts, Test) ->
    ok = symbolic_fact_store:write(?DB, Facts),
    try Test() after file:delete(?DB) end.

run_result_missing_db_is_error_test() ->
    ?assertEqual(
        {error, {no_such_db, "no/such/facts_zz.dets"}},
        symbolic_query:run_result("no/such/facts_zz.dets", undefined, "foo(X)")).

run_result_returns_solutions_test() ->
    with_db([{defines, foo, 0, <<"()">>, 'f.erl', 1}], fun() ->
        ?assertEqual(
            {solutions, [{'File', 'f.erl'}, {'Line', 1}]},
            symbolic_query:run_result(?DB, undefined, "defines(foo, _, _, File, Line)"))
    end).

run_result_no_solution_test() ->
    with_db([{defines, foo, 0, <<"()">>, 'f.erl', 1}], fun() ->
        ?assertEqual(
            no_solution,
            symbolic_query:run_result(?DB, undefined, "defines(bar, _, _, _, _)"))
    end).

run_result_query_failed_is_error_test() ->
    with_db([{defines, foo, 0, <<"()">>, 'f.erl', 1}], fun() ->
        ?assertMatch(
            {error, {query_failed, _}},
            symbolic_query:run_result(?DB, undefined, "defines("))
    end).

run_result_rules_error_test() ->
    with_db([{defines, foo, 0, <<"()">>, 'f.erl', 1}], fun() ->
        ?assertMatch(
            {error, {rules_error, "no/such/rules_zz.pl", _}},
            symbolic_query:run_result(?DB, "no/such/rules_zz.pl", "defines(foo, _, _, _, _)"))
    end).

run_result_uses_a_rules_file_test() ->
    with_db([{defines, foo, 0, <<"()">>, 'f.erl', 1}], fun() ->
        RulesPath = filename:join(["_build", "query_run_result_rules_scratch.pl"]),
        ok = file:write_file(RulesPath, <<"named(F) :- defines(F, _, _, _, _).\n">>),
        Result = symbolic_query:run_result(?DB, RulesPath, "named(F)"),
        ok = file:delete(RulesPath),
        ?assertEqual({solutions, [{'F', foo}]}, Result)
    end).

%% --- default rules: resolve_rules/3 (.symbolic/rules.pl discovery) ---

%% An explicit -rules is never second-guessed, even when discovery would
%% find something: whatever path the caller typed is what gets consulted.
resolve_rules_explicit_path_wins_test() ->
    with_scratch_project(fun(Root) ->
        Db = filename:join([Root, "data", "facts.dets"]),
        ?assertEqual("my/rules.pl", symbolic_query:resolve_rules(Db, "my/rules.pl", false))
    end).

%% -no-rules suppresses discovery only — it never overrides an explicit path.
resolve_rules_no_rules_suppresses_discovery_test() ->
    with_scratch_project(fun(Root) ->
        Db = filename:join([Root, "data", "facts.dets"]),
        ?assertEqual(undefined, symbolic_query:resolve_rules(Db, undefined, true)),
        ?assertEqual("my/rules.pl", symbolic_query:resolve_rules(Db, "my/rules.pl", true))
    end).

%% Found by walking UP from the database's own directory, so the command
%% works from any subdirectory of the project and the db doesn't have to
%% sit beside the root.
resolve_rules_walks_up_from_the_db_test() ->
    with_scratch_project(fun(Root) ->
        Default = filename:join([Root, ".symbolic", "rules.pl"]),
        Deep = filename:join([Root, "data", "nested", "facts.dets"]),
        ?assertEqual(Default, symbolic_query:resolve_rules(Deep, undefined, false)),
        ?assertEqual(Default,
            symbolic_query:resolve_rules(filename:join([Root, "data", "facts.dets"]),
                undefined, false))
    end).

%% A database kept outside the project still picks up the library of the
%% project you're standing in (the second, cwd-based search).
resolve_rules_falls_back_to_the_cwd_test() ->
    with_scratch_project(fun(Root) ->
        OldCwd = get_cwd(),
        set_cwd(filename:join([Root, "data"])),
        try
            %% db in a directory tree with no .symbolic anywhere above it
            %% except the filesystem root (see the assertion below).
            ?assertEqual(filename:join([Root, ".symbolic", "rules.pl"]),
                symbolic_query:resolve_rules("/no-such-project-zz/facts.dets",
                    undefined, false))
        after
            restore_cwd(OldCwd)
        end
    end).

%% The db's own project wins over the cwd's — the two searches are ordered.
resolve_rules_prefers_the_dbs_project_over_the_cwd_test() ->
    with_scratch_project(fun(Root) ->
        OldCwd = get_cwd(),
        Other = filename:join([Root, "other"]),
        OtherRules = filename:join([Other, ".symbolic", "rules.pl"]),
        ok = filelib:ensure_dir(OtherRules),
        ok = file:write_file(OtherRules, <<"other_library.\n">>),
        set_cwd(Other),
        try
            ?assertEqual(filename:join([Root, ".symbolic", "rules.pl"]),
                symbolic_query:resolve_rules(filename:join([Root, "data", "facts.dets"]),
                    undefined, false))
        after
            restore_cwd(OldCwd)
        end
    end).

%% discover_up/2 is the generic walk-up discover_rules_from_dir/1 is
%% built from (symbolic_config.erl's .symbolic/config.json discovery
%% reuses it too) — proves it's genuinely parameterized on RelPathParts,
%% not hardcoded to rules.pl, by discovering an arbitrary marker file.
discover_up_finds_an_arbitrary_marker_file_test() ->
    with_scratch_project(fun(Root) ->
        Marker = filename:join([Root, ".symbolic", "config.json"]),
        ok = file:write_file(Marker, <<"{}">>),
        ?assertEqual(Marker,
            symbolic_query:discover_up(Root, [".symbolic", "config.json"])),
        ?assertEqual(Marker,
            symbolic_query:discover_up(filename:join([Root, "data"]),
                [".symbolic", "config.json"]))
    end).

discover_up_returns_undefined_when_nothing_found_test() ->
    with_scratch_project(fun(Root) ->
        ?assertEqual(undefined,
            symbolic_query:discover_up(Root, [".symbolic", "no-such-marker.json"]))
    end).

%% The full auto path, short of run/4's halt(): whatever resolve_rules/3
%% discovers is what run_result/3 then really consults, so a derived
%% predicate from the discovered file is provable.
resolve_rules_result_is_what_run_result_consults_test() ->
    with_scratch_project(fun(Root) ->
        Db = filename:join([Root, "data", "facts.dets"]),
        ok = symbolic_fact_store:write(Db, [{defines, foo, 0, <<"()">>, 'f.erl', 1}]),
        Rules = symbolic_query:resolve_rules(Db, undefined, false),
        %% named/1 comes from the scratch library (with_scratch_project/1);
        %% the assertion below fails as an error if discovery misfired.
        ?assertEqual({solutions, [{'F', foo}]},
            symbolic_query:run_result(Db, Rules, "named(F)")),
        ok = file:delete(Db)
    end).

%% A guard against the drift this change came out of: every predicate the
%% default .symbolic/rules.pl advertises must not only exist but actually
%% work, so each one is exercised against a known fixture rather than
%% smoke-tested. A missing predicate would show up here as
%% {error, {query_failed, {existence_error, ...}}} — which is exactly how
%% top_fan_out/2 and all_risky_calls/1 were silently absent from the
%% library docs/lint-queries.md tells agents to use.
default_rules_library_over_fixture_test() ->
    Rules = filename:join([".symbolic", "rules.pl"]),
    ?assert(filelib:is_regular(Rules)),
    with_db(library_fixture(), fun() ->
        lists:foreach(
            fun({Goal, Expected}) ->
                %% sorted_solutions/1 because erlog hands back its binding
                %% list in term order ('Arity', 'File', 'Fun'...), not the
                %% order the variables appear in the goal — the assertion is
                %% about which bindings exist, not their spelling order.
                ?assertEqual(sorted_solutions(Expected),
                    sorted_solutions(symbolic_query:run_result(?DB, Rules, Goal)), Goal)
            end, library_cases())
    end).

sorted_solutions({solutions, Bindings}) -> {solutions, lists:sort(Bindings)};
sorted_solutions(no_solution) -> no_solution.

%% erlog keeps Prolog's `-` as an ordinary 2-arity functor, so a rule
%% template like `Count-Fun-File` is {'-',{'-',Count,Fun},File} — NOT an
%% Erlang 3-tuple. (The same term is what makes docs/lint-queries.md's
%% captured output show these results as ["-",...] JSON arrays.)
dash(A, B) -> {'-', A, B}.
dash(A, B, C) -> {'-', {'-', A, B}, C}.
dash(A, B, C, D) -> {'-', {'-', {'-', A, B}, C}, D}.

%% One file, two functions, and at least one example of every fact shape
%% the library touches: a local call, a remote call, a member call, a
%% doc'd function, an undoc'd one, a loose comment, and a Markdown
%% example_defines that has no counterpart in the code.
library_fixture() ->
    [{defines, foo, 1, <<"(X)">>, 'f.erl', 2},
        {defines, bar, 1, <<"(Y)">>, 'f.erl', 6},
        {calls, foo, 1, {local, bar, 1}, 'f.erl', 3},
        {calls, foo, 1, {remote, os, getenv, 1}, 'f.erl', 4},
        {calls, foo, 1, {member, client, charge, 1}, 'f.erl', 5},
        {doc, bar, 1, 'f.erl', 5, <<"bar does things">>},
        {comment, 'f.erl', 1, <<"loose comment">>},
        {example_defines, ghost, 1, <<"()">>, 'd.md', 3}].

%% {Goal, expected run_result/3 outcome}. no_solution cases double as
%% negative checks: a rule that isn't defined would error instead.
library_cases() ->
    [{"callees(foo, Callees)",
            {solutions, [{'Callees',
                [{local, bar, 1}, {member, client, charge, 1}, {remote, os, getenv, 1}]}]}},
        {"callees(bar, Callees)", {solutions, [{'Callees', []}]}},
        {"callers(bar, 1, Callers)", {solutions, [{'Callers', [foo]}]}},
        {"callers(foo, 1, Callers)", {solutions, [{'Callers', []}]}},
        {"undocumented(Fun, Arity, File, Line)",
            {solutions, [{'Fun', foo}, {'Arity', 1}, {'File', 'f.erl'}, {'Line', 2}]}},
        {"undocumented(bar, 1, File, Line)", no_solution},
        {"calls_object(foo, Object)", {solutions, [{'Object', client}]}},
        {"calls_object(bar, Object)", no_solution},
        {"stale_doc_example(Fun, Arity, DocFile, Line)",
            {solutions, [{'Fun', ghost}, {'Arity', 1}, {'DocFile', 'd.md'}, {'Line', 3}]}},
        {"all_duplicate_names(Triples)", {solutions, [{'Triples', []}]}},
        {"self_recursive(foo, 1, File)", no_solution},
        {"fan_out(foo, 'f.erl', Count)", {solutions, [{'Count', 3}]}},
        {"fan_out(bar, 'f.erl', Count)", {solutions, [{'Count', 0}]}},
        {"top_fan_out(1, Top)", {solutions, [{'Top', [dash(3, foo, 'f.erl')]}]}},
        {"fan_in(bar, 1, Count)", {solutions, [{'Count', 1}]}},
        {"top_fan_in(1, Top)", {solutions, [{'Top', [dash(1, bar, 1)]}]}},
        {"no_local_callers(foo, 1, File)", {solutions, [{'File', 'f.erl'}]}},
        {"no_local_callers(bar, 1, File)", no_solution},
        {"all_no_local_callers(Triples)",
            {solutions, [{'Triples', [dash(foo, 1, 'f.erl')]}]}},
        {"undocumented_comment(File, Line, Text)",
            {solutions, [{'File', 'f.erl'}, {'Line', 1}, {'Text', <<"loose comment">>}]}},
        {"risky_call(Caller, Module, Fun)",
            {solutions, [{'Caller', foo}, {'Module', os}, {'Fun', getenv}]}},
        {"all_risky_calls(Triples)",
            {solutions, [{'Triples', [dash(foo, os, getenv)]}]}},
        {"take(2, [a, b, c], Taken)", {solutions, [{'Taken', [a, b]}]}},
        {"reaches(foo, bar)", {solutions, []}},
        {"reaches(bar, foo)", no_solution},
        {"module_dependency(File, Module)",
            {solutions, [{'File', 'f.erl'}, {'Module', os}]}},
        {"all_module_dependencies(Edges)",
            {solutions, [{'Edges', [dash('f.erl', os)]}]}},
        %% sub_atom/5, in the exact mode an LLM agent reaches for first —
        %% "does this atom contain X" (Before/Length/After left unbound,
        %% Sub given as a literal) — erlog has no native sub_atom/5, so a
        %% missing/broken .symbolic/rules.pl definition would surface here
        %% as existence_error, same drift protection as every other case
        %% in this list.
        {"sub_atom(foo, Before, Length, After, oo)",
            {solutions, [{'Before', 1}, {'Length', 2}, {'After', 0}]}},
        {"sub_atom(bar, _, _, _, oo)", no_solution}].

%% --- ESLint-style rules added on top of the library above ---
%%
%% Each one gets its own small, self-contained fixture rather than
%% sharing library_fixture/0 above: several of these rules (mutual
%% recursion, "never called") are sensitive to exactly which functions
%% call which other ones, and piling more call sites onto foo/bar would
%% silently change what fan_out/no_local_callers/etc. above already
%% assert. Still run against the REAL .symbolic/rules.pl (not a scratch
%% rules file), so a rule missing or broken there fails here too — the
%% same drift protection default_rules_library_over_fixture_test gives
%% the original library.

real_rules() -> filename:join([".symbolic", "rules.pl"]).

%% --- hidden_risky_call/3: transitive risk propagation ---
%%
%% Deliberately requires a bound starting Fun (see its own doc comment in
%% .symbolic/rules.pl) — an "every hidden risky function" form was tried
%% first and timed out for real against this project's own source, so
%% there is no all_hidden_risky_calls/1 to test here; only the per-Fun
%% predicate.

%% entry/0 -> mid/0 -> deep/0 -> os:getenv/1 — entry never calls os
%% itself, but reaches it two LOCAL hops away through mid/0 and deep/0
%% (the risky remote call itself isn't a reaches/2 hop — deep/0 is where
%% the local chain ends and risky_call/3 takes over).
hidden_risky_call_flags_a_two_hop_transitive_call_test() ->
    with_db([{defines, entry, 0, <<"()">>, 'p.erl', 1},
             {defines, mid, 0, <<"()">>, 'p.erl', 2},
             {defines, deep, 0, <<"()">>, 'p.erl', 3},
             {calls, entry, 0, {local, mid, 0}, 'p.erl', 1},
             {calls, mid, 0, {local, deep, 0}, 'p.erl', 2},
             {calls, deep, 0, {remote, os, getenv, 1}, 'p.erl', 3}], fun() ->
        ?assertEqual({solutions, [{'Module', os}, {'Target', getenv}]},
            symbolic_query:run_result(?DB, real_rules(), "hidden_risky_call(entry, Module, Target)"))
    end).

%% The base case: a direct one-hop caller of a risky-call site is hidden
%% too, not just multi-hop chains — reaches/2's own direct-call clause.
%% mid/0 is one local hop from deep/0, which makes the risky call itself.
hidden_risky_call_flags_a_direct_one_hop_call_test() ->
    with_db([{defines, mid, 0, <<"()">>, 'p.erl', 1},
             {defines, deep, 0, <<"()">>, 'p.erl', 2},
             {calls, mid, 0, {local, deep, 0}, 'p.erl', 1},
             {calls, deep, 0, {remote, os, getenv, 1}, 'p.erl', 2}], fun() ->
        ?assertEqual({solutions, [{'Module', os}, {'Target', getenv}]},
            symbolic_query:run_result(?DB, real_rules(), "hidden_risky_call(mid, Module, Target)"))
    end).

%% The site making the risky call directly is not "hidden" — it's already
%% visible via risky_call/3 on its own, so hidden_risky_call/3 must not
%% double-report it.
hidden_risky_call_does_not_flag_the_direct_risky_caller_itself_test() ->
    with_db([{defines, mid, 0, <<"()">>, 'p.erl', 1},
             {calls, mid, 0, {remote, os, getenv, 1}, 'p.erl', 2}], fun() ->
        ?assertEqual(no_solution,
            symbolic_query:run_result(?DB, real_rules(), "hidden_risky_call(mid, _, _)"))
    end).

%% A function with no call chain reaching any risky call at all.
hidden_risky_call_does_not_flag_an_unrelated_function_test() ->
    with_db([{defines, harmless, 0, <<"()">>, 'p.erl', 1},
             {defines, mid, 0, <<"()">>, 'p.erl', 2},
             {calls, harmless, 0, {local, format_name, 1}, 'p.erl', 1},
             {calls, mid, 0, {remote, os, getenv, 1}, 'p.erl', 2}], fun() ->
        ?assertEqual(no_solution,
            symbolic_query:run_result(?DB, real_rules(), "hidden_risky_call(harmless, _, _)"))
    end).

too_many_params_flags_over_the_threshold_test() ->
    with_db([{defines, five_args, 5, <<"(a,b,c,d,e)">>, 'p.erl', 1},
             {defines, two_args, 2, <<"(a,b)">>, 'p.erl', 5}], fun() ->
        ?assertEqual({solutions, [{'File', 'p.erl'}]},
            symbolic_query:run_result(?DB, real_rules(),
                "too_many_params(five_args, 5, File, _)")),
        ?assertEqual(no_solution,
            symbolic_query:run_result(?DB, real_rules(),
                "too_many_params(two_args, 2, _, _)"))
    end).

too_complex_flags_high_fan_out_test() ->
    Callees = [{calls, busy, 0, {remote, m, F, 0}, 'p.erl', 1} || F <- lists:seq(1, 11)],
    with_db([{defines, busy, 0, <<"()">>, 'p.erl', 1} | Callees], fun() ->
        ?assertEqual({solutions, [{'Count', 11}]},
            symbolic_query:run_result(?DB, real_rules(), "too_complex(busy, 'p.erl', Count)"))
    end).

too_complex_does_not_flag_low_fan_out_test() ->
    with_db([{defines, calm, 0, <<"()">>, 'p.erl', 1},
             {calls, calm, 0, {remote, m, f, 0}, 'p.erl', 2}], fun() ->
        ?assertEqual(no_solution,
            symbolic_query:run_result(?DB, real_rules(), "too_complex(calm, 'p.erl', _)"))
    end).

%% ping <-> pong is the cycle; solo never calls or is called by either.
mutual_recursion_finds_a_cycle_once_test() ->
    with_db([{defines, ping, 0, <<"()">>, 'p.erl', 1},
             {defines, pong, 0, <<"()">>, 'p.erl', 2},
             {defines, solo, 0, <<"()">>, 'p.erl', 3},
             {calls, ping, 0, {local, pong, 0}, 'p.erl', 1},
             {calls, pong, 0, {local, ping, 0}, 'p.erl', 2}], fun() ->
        ?assertEqual({solutions, [{'Pairs', [dash(ping, pong)]}]},
            symbolic_query:run_result(?DB, real_rules(), "all_mutual_recursion(Pairs)"))
    end).

%% called: has a local caller. remote_entry: only a remote caller (the
%% no_local_callers/3 false-positive truly_uncalled/3 exists to close).
%% never_called: no caller of any kind.
truly_uncalled_ignores_remote_callers_test() ->
    with_db([{defines, called, 0, <<"()">>, 'p.erl', 1},
             {defines, remote_entry, 0, <<"()">>, 'p.erl', 2},
             {defines, never_called, 0, <<"()">>, 'p.erl', 3},
             {calls, caller, 0, {local, called, 0}, 'p.erl', 4},
             {calls, other_file_caller, 0, {remote, p, remote_entry, 0}, 'q.erl', 1}], fun() ->
        ?assertEqual({solutions, [{'Triples', [dash(never_called, 0, 'p.erl')]}]},
            symbolic_query:run_result(?DB, real_rules(), "all_truly_uncalled(Triples)"))
    end).

%% An `-export` entry point is uncalled from inside the parse BY DEFINITION
%% — its caller is a test, another module, or gen_server dispatching a
%% behaviour callback — which is the whole reason entry_point/3 exists.
%% Three separate exemptions are checked here, plus the one case that must
%% NOT be exempt: `ghost` is exported, but from q.erl, and entry_point/3
%% keys on the export's own File, so p.erl's ghost/0 stays on the list.
%% `init/0` has no export at all — an -on_load hook is called by the loader
%% by name — and is covered by the editable runtime_entry_point/2 fact.
truly_uncalled_ignores_entry_points_test() ->
    with_db([{defines, exported, 0, <<"()">>, 'p.erl', 1},
             {defines, handle_call, 3, <<"()">>, 'p.erl', 2},
             {defines, init, 0, <<"()">>, 'p.erl', 3},
             {defines, ghost, 0, <<"()">>, 'p.erl', 4},
             {defines, dead, 0, <<"()">>, 'p.erl', 5},
             {export, exported, 0, 'p.erl', 1},
             {export, handle_call, 3, 'p.erl', 2},
             {export, ghost, 0, 'q.erl', 1},
             %% A calls/5 fact is needed to reach truly_uncalled/3 at all:
             %% unlike export/4, calls/5 carries no zero-clause sentinel (a
             %% real parse always has calls in it), so an all-calls-free
             %% fixture makes erlog raise existence_error on it rather than
             %% answer No. init/0 calling handle_call/3 is a plausible
             %% gen_server shape and changes no expected binding — init/0 is
             %% exempt either way, handle_call/3 stays exempt via export/4.
             {calls, init, 0, {local, handle_call, 3}, 'p.erl', 6}], fun() ->
        ?assertEqual({solutions, [{'Triples',
            [dash(dead, 0, 'p.erl'), dash(ghost, 0, 'p.erl')]}]},
            symbolic_query:run_result(?DB, real_rules(), "all_truly_uncalled(Triples)"))
    end).

%% export/4 has zero clauses for a tree with no Erlang in it (TypeScript,
%% Bash, or this library's own fixture), and erlog raises existence_error
%% on a predicate with no clauses rather than failing — which is why
%% entry_point/3's sentinel exists. Re-running the remote-callers case with
%% NO export facts loaded is what proves the sentinel, not the new goal,
%% answers.
entry_point_without_export_facts_fails_cleanly_test() ->
    with_db([{defines, plain, 0, <<"()">>, 's.ts', 1},
             {defines, exported_anyway, 0, <<"()">>, 's.ts', 2},
             {calls, caller, 0, {local, plain, 0}, 's.ts', 3}], fun() ->
        ?assertEqual({solutions, [{'Triples', [dash(exported_anyway, 0, 's.ts')]}]},
            symbolic_query:run_result(?DB, real_rules(), "all_truly_uncalled(Triples)")),
        ?assertEqual(no_solution,
            symbolic_query:run_result(?DB, real_rules(), "entry_point(plain, 0, 's.ts')"))
    end).

banned_call_flags_a_console_log_call_test() ->    with_db([{defines, noisy, 0, <<"()">>, 's.ts', 1},
             {calls, noisy, 0, {member, console, log, 1}, 's.ts', 2},
             {calls, noisy, 0, {member, console, info, 1}, 's.ts', 3}], fun() ->
        ?assertEqual({solutions, [{'Triples', [dash(noisy, log, 's.ts')]}]},
            symbolic_query:run_result(?DB, real_rules(), "all_banned_calls(Triples)"))
    end).

%% File left unbound on purpose (the shape all_god_files/1 actually uses)
%% — a regression test for a real bug the first version of
%% file_define_count/2 had: with nothing grounding File before the inner
%% findall, it silently counted every defines/5 fact in the whole fixture
%% (across BOTH files) under an unbound File, instead of 21 grouped under
%% 'big.erl'. small.erl's single function proves per-file grouping too:
%% a version that just summed everything would report Count = 22 here,
%% not 21, and would report it against whichever File happened to bind
%% first rather than specifically 'big.erl'.
god_file_flags_a_file_over_the_threshold_test() ->
    Big = [{defines, list_to_atom("f" ++ integer_to_list(N)), 0, <<"()">>, 'big.erl', N}
           || N <- lists:seq(1, 21)],
    Small = [{defines, small_fun, 0, <<"()">>, 'small.erl', 1}],
    with_db(Big ++ Small, fun() ->
        ?assertEqual({solutions, [{'Count', 21}, {'File', 'big.erl'}]},
            symbolic_query:run_result(?DB, real_rules(), "god_file(File, Count)"))
    end).

god_file_does_not_flag_a_small_file_test() ->
    with_db([{defines, f1, 0, <<"()">>, 'small.erl', 1}], fun() ->
        ?assertEqual(no_solution,
            symbolic_query:run_result(?DB, real_rules(), "god_file('small.erl', _)"))
    end).

%% real_complexity/4 and too_complex_real/4 — real branch/5 facts
%% (hand-built here, not a live parse — isolates the Prolog rule from
%% the extraction layer, whose own coverage lives in
%% ts_extract_typescript_tests.erl/ts_extract_tests.erl/
%% ts_extract_bash_tests.erl).

%% One clause, 4 branches -> 1 + 4 = 5, below the >10 threshold.
real_complexity_counts_clauses_plus_branches_test() ->
    with_db([{defines, busy, 1, <<"(x)">>, 'p.ts', 1},
             {branch, busy, 1, 'if', 'p.ts', 2},
             {branch, busy, 1, 'if', 'p.ts', 4},
             {branch, busy, 1, 'for', 'p.ts', 7},
             {branch, busy, 1, 'and', 'p.ts', 8}], fun() ->
        ?assertEqual({solutions, [{'Count', 5}]},
            symbolic_query:run_result(?DB, real_rules(), "real_complexity(busy, 1, 'p.ts', Count)"))
    end).

%% Three clauses (a case-heavy Erlang function), no separate branch/5
%% facts needed to reach 11 — the clause count alone is McCabe's "+1 per
%% alternative" for a multi-clause Erlang function.
real_complexity_counts_erlang_clauses_test() ->
    Defines = [{defines, dispatch, 1, <<"(X)">>, 'p.erl', N} || N <- lists:seq(1, 11)],
    with_db(Defines, fun() ->
        ?assertEqual({solutions, [{'Count', 11}]},
            symbolic_query:run_result(?DB, real_rules(),
                "real_complexity(dispatch, 1, 'p.erl', Count)"))
    end).

too_complex_real_flags_over_the_threshold_test() ->
    Branches = [{branch, busy, 1, remote, 'p.ts', N} || N <- lists:seq(1, 10)],
    with_db([{defines, busy, 1, <<"(x)">>, 'p.ts', 1} | Branches], fun() ->
        %% 1 clause + 10 branches = 11, over the threshold.
        ?assertEqual({solutions, [{'Count', 11}]},
            symbolic_query:run_result(?DB, real_rules(), "too_complex_real(busy, 1, 'p.ts', Count)"))
    end).

%% Fun/Arity/File left unbound on purpose (the shape all_too_complex_real/1
%% actually uses) — a regression test for the same class of bug
%% god_file/2 had earlier: with nothing grounding them before the inner
%% findalls, real_complexity/4 would silently group every defines/5 fact
%% in the WHOLE fixture together under an unbound Fun/Arity/File, rather
%% than reporting one Count per real function. calm's own branch-free
%% clause (Count 1) proves grouping is correct too: a version with the
%% bug would report one combined Count (16) against an unbound Fun, not
%% two separate results.
real_complexity_groups_by_function_when_unbound_test() ->
    Branches = [{branch, busy, 1, remote, 'p.ts', N} || N <- lists:seq(1, 10)],
    with_db([{defines, busy, 1, <<"(x)">>, 'p.ts', 1},
             {defines, calm, 1, <<"(x)">>, 'p.ts', 2} | Branches], fun() ->
        {solutions, Bindings} =
            symbolic_query:run_result(?DB, real_rules(),
                "findall(Fun-Arity-File-Count, real_complexity(Fun, Arity, File, Count), Raw), sort(Raw, Results)"),
        ?assertEqual(
            [dash(busy, 1, 'p.ts', 11), dash(calm, 1, 'p.ts', 1)],
            proplists:get_value('Results', Bindings))
    end).

too_complex_real_does_not_flag_at_the_threshold_test() ->
    Branches = [{branch, calm, 1, remote, 'p.ts', N} || N <- lists:seq(1, 9)],
    with_db([{defines, calm, 1, <<"(x)">>, 'p.ts', 1} | Branches], fun() ->
        %% 1 clause + 9 branches = 10, at (not over) the threshold.
        ?assertEqual(no_solution,
            symbolic_query:run_result(?DB, real_rules(), "too_complex_real(calm, 1, 'p.ts', _)"))
    end).

%% --- Naming convention: id-length ---

short_name_flags_names_under_three_chars_test() ->
    with_db([{defines, f, 1, <<"(x)">>, 'p.ts', 1},
             {defines, process, 1, <<"(x)">>, 'p.ts', 5}], fun() ->
        ?assertEqual({solutions, [{'File', 'p.ts'}]},
            symbolic_query:run_result(?DB, real_rules(), "short_name(f, 1, File, _)")),
        ?assertEqual(no_solution,
            symbolic_query:run_result(?DB, real_rules(), "short_name(process, 1, _, _)"))
    end).

%% ok/id are short but explicitly allowed (allow_short_name/1) — the
%% escape hatch banned_target/2 above has an analogue of.
short_name_respects_the_allowlist_test() ->
    with_db([{defines, ok, 0, <<"()">>, 'p.ts', 1},
             {defines, id, 1, <<"(x)">>, 'p.ts', 3}], fun() ->
        ?assertEqual(no_solution,
            symbolic_query:run_result(?DB, real_rules(), "short_name(ok, 0, _, _)")),
        ?assertEqual(no_solution,
            symbolic_query:run_result(?DB, real_rules(), "short_name(id, 1, _, _)"))
    end).

%% --- Expression content: self_compare/4, yoda_condition/5 ---
%%
%% Facts hand-built here rather than via a live parse (isolates the
%% Prolog rule from the extraction layer, whose own coverage lives in
%% ts_extract_typescript_tests.erl/ts_extract_tests.erl). Id is a
%% {File, StartByte, EndByte} byte span in the real extractors; any
%% distinct ground term works as a stand-in here since the rules never
%% inspect Id's own shape.

self_compare_flags_the_same_name_on_both_sides_test() ->
    with_db([{defines, busy, 1, <<"(x)">>, 'p.ts', 1},
             {expr, eq1, busy, 1, binary, 'p.ts', 2},
             {expr_operator, eq1, '=='},
             {expr_operand, eq1, left, ref1}, {expr_ref, ref1, busy, 1, x, 'p.ts', 2},
             {expr_operand, eq1, right, ref2}, {expr_ref, ref2, busy, 1, x, 'p.ts', 2}], fun() ->
        ?assertEqual({solutions, [{'File', 'p.ts'}]},
            symbolic_query:run_result(?DB, real_rules(), "self_compare(_, busy, 1, File, _)"))
    end).

%% x == y (different names) must NOT match — the negative case a rule
%% that ignored the operand names entirely would get wrong.
self_compare_does_not_flag_different_names_test() ->
    with_db([{defines, calm, 1, <<"(x)">>, 'p.ts', 1},
             {expr, eq2, calm, 1, binary, 'p.ts', 2},
             {expr_operator, eq2, '=='},
             {expr_operand, eq2, left, ref3}, {expr_ref, ref3, calm, 1, x, 'p.ts', 2},
             {expr_operand, eq2, right, ref4}, {expr_ref, ref4, calm, 1, y, 'p.ts', 2}], fun() ->
        ?assertEqual(no_solution,
            symbolic_query:run_result(?DB, real_rules(), "self_compare(_, calm, 1, _, _)"))
    end).

%% self_compare/4 (and yoda_condition/5 below) must still answer cleanly
%% — not existence_error — when NO expr/literal/expr_ref facts exist at
%% all, the same sentinel-clause protection branch/5 needed.
self_compare_is_clean_with_zero_expressions_test() ->
    with_db([{defines, plain, 0, <<"()">>, 'p.erl', 1}], fun() ->
        ?assertEqual(no_solution,
            symbolic_query:run_result(?DB, real_rules(), "self_compare(_, plain, 0, _, _)"))
    end).

yoda_condition_flags_a_literal_on_the_left_test() ->
    with_db([{defines, busy, 1, <<"(x)">>, 'p.ts', 1},
             {expr, cmp1, busy, 1, binary, 'p.ts', 2},
             {expr_operator, cmp1, '==='},
             {expr_operand, cmp1, left, lit1}, {literal, lit1, busy, 1, number, 0, 'p.ts', 2, none},
             {expr_operand, cmp1, right, ref5}, {expr_ref, ref5, busy, 1, x, 'p.ts', 2}], fun() ->
        ?assertEqual({solutions, [{'File', 'p.ts'}]},
            symbolic_query:run_result(?DB, real_rules(), "yoda_condition(_, busy, 1, File, _)"))
    end).

%% x === 0 (literal on the RIGHT) is normal order, not Yoda — must not match.
yoda_condition_does_not_flag_a_literal_on_the_right_test() ->
    with_db([{defines, calm, 1, <<"(x)">>, 'p.ts', 1},
             {expr, cmp2, calm, 1, binary, 'p.ts', 2},
             {expr_operator, cmp2, '==='},
             {expr_operand, cmp2, left, ref6}, {expr_ref, ref6, calm, 1, x, 'p.ts', 2},
             {expr_operand, cmp2, right, lit2}, {literal, lit2, calm, 1, number, 0, 'p.ts', 2, none}], fun() ->
        ?assertEqual(no_solution,
            symbolic_query:run_result(?DB, real_rules(), "yoda_condition(_, calm, 1, _, _)"))
    end).

yoda_condition_is_clean_with_zero_expressions_test() ->
    with_db([{defines, plain, 0, <<"()">>, 'p.erl', 1}], fun() ->
        ?assertEqual(no_solution,
            symbolic_query:run_result(?DB, real_rules(), "yoda_condition(_, plain, 0, _, _)"))
    end).

%% --- Variables and scope: unused_var/4, shadowed_var/5 ---
%%
%% Facts hand-built here rather than via a live parse (isolates the
%% Prolog rule from the extraction layer, whose own coverage — including
%% the trickiest cases, real shadowing and a two-level for-loop
%% scope-chain walk-up — lives in extracts_scope_facts_test in
%% ts_extract_typescript_tests.erl).

unused_var_flags_a_declaration_with_no_read_test() ->
    with_db([{defines, f, 0, <<"()">>, 'p.ts', 1},
             {scope, fscope, function, none, 'p.ts'},
             {var_decl, d1, unused, const, fscope, 'p.ts', 2}], fun() ->
        ?assertEqual({solutions, [{'File', 'p.ts'}, {'Line', 2}]},
            symbolic_query:run_result(?DB, real_rules(), "unused_var(_, unused, File, Line)"))
    end).

%% A read anywhere (even via resolves_to from a nested scope) counts —
%% must NOT flag a variable that's genuinely used.
unused_var_does_not_flag_a_read_variable_test() ->
    with_db([{defines, f, 0, <<"()">>, 'p.ts', 1},
             {scope, fscope, function, none, 'p.ts'},
             {var_decl, d1, used, 'let', fscope, 'p.ts', 2},
             {var_ref, r1, used, fscope, read, 'p.ts', 3},
             {resolves_to, r1, d1}], fun() ->
        ?assertEqual(no_solution,
            symbolic_query:run_result(?DB, real_rules(), "unused_var(_, used, _, _)"))
    end).

%% Parameters are deliberately excluded (see unused_var/4's own doc
%% comment) — a never-read param must NOT be flagged.
unused_var_does_not_flag_an_unread_parameter_test() ->
    with_db([{defines, f, 1, <<"(a)">>, 'p.ts', 1},
             {scope, fscope, function, none, 'p.ts'},
             {var_decl, d1, a, param, fscope, 'p.ts', 1}], fun() ->
        ?assertEqual(no_solution,
            symbolic_query:run_result(?DB, real_rules(), "unused_var(_, a, _, _)"))
    end).

unused_var_is_clean_with_zero_declarations_test() ->
    with_db([{defines, f, 0, <<"()">>, 'p.erl', 1}], fun() ->
        ?assertEqual(no_solution,
            symbolic_query:run_result(?DB, real_rules(), "unused_var(_, _, _, _)"))
    end).

%% A block scope nested inside a function scope, both declaring `x` —
%% real shadowing, the shape shadowed_var/5 exists for.
shadowed_var_flags_an_inner_declaration_of_the_same_name_test() ->
    with_db([{defines, f, 0, <<"()">>, 'p.ts', 1},
             {scope, fscope, function, none, 'p.ts'},
             {scope, bscope, block, fscope, 'p.ts'},
             {var_decl, outer, x, 'let', fscope, 'p.ts', 2},
             {var_decl, inner, x, 'let', bscope, 'p.ts', 6}], fun() ->
        ?assertEqual({solutions, [{'File', 'p.ts'}, {'Line', 6}]},
            symbolic_query:run_result(?DB, real_rules(), "shadowed_var(_, _, x, File, Line)"))
    end).

%% Two DIFFERENT names in nested scopes must not match — the negative
%% case a rule that ignored Name entirely would get wrong.
shadowed_var_does_not_flag_different_names_test() ->
    with_db([{defines, f, 0, <<"()">>, 'p.ts', 1},
             {scope, fscope, function, none, 'p.ts'},
             {scope, bscope, block, fscope, 'p.ts'},
             {var_decl, outer, x, 'let', fscope, 'p.ts', 2},
             {var_decl, inner, y, 'let', bscope, 'p.ts', 6}], fun() ->
        ?assertEqual(no_solution,
            symbolic_query:run_result(?DB, real_rules(), "shadowed_var(_, _, _, _, _)"))
    end).

shadowed_var_is_clean_with_zero_declarations_test() ->
    with_db([{defines, f, 0, <<"()">>, 'p.erl', 1}], fun() ->
        ?assertEqual(no_solution,
            symbolic_query:run_result(?DB, real_rules(), "shadowed_var(_, _, _, _, _)"))
    end).

%% --- More rules on the same scope facts: prefer_const/4, redeclared_var/5,
%% shadows_restricted_name/4, use_before_define/5, undeclared_var/4 ---

%% A `let` with an initializer and no write/read_write ref pointing at
%% it should be a `const`.
prefer_const_flags_a_never_reassigned_let_test() ->
    with_db([{defines, f, 0, <<"()">>, 'p.ts', 1},
             {scope, fscope, function, none, 'p.ts'},
             {var_decl, d1, x, 'let', fscope, 'p.ts', 2},
             {var_decl_initialized, d1}], fun() ->
        ?assertEqual({solutions, [{'File', 'p.ts'}, {'Line', 2}]},
            symbolic_query:run_result(?DB, real_rules(), "prefer_const(_, x, File, Line)"))
    end).

%% A `let` that IS later reassigned must not be flagged — it genuinely
%% needs to stay mutable.
prefer_const_does_not_flag_a_reassigned_let_test() ->
    with_db([{defines, f, 0, <<"()">>, 'p.ts', 1},
             {scope, fscope, function, none, 'p.ts'},
             {var_decl, d1, x, 'let', fscope, 'p.ts', 2},
             {var_decl_initialized, d1},
             {var_ref, r1, x, fscope, write, 'p.ts', 3},
             {resolves_to, r1, d1}], fun() ->
        ?assertEqual(no_solution,
            symbolic_query:run_result(?DB, real_rules(), "prefer_const(_, x, _, _)"))
    end).

%% A bare `let x;` (no var_decl_initialized fact at all) must never be
%% suggested as `const x;` — that's not valid syntax.
prefer_const_does_not_flag_an_uninitialized_let_test() ->
    with_db([{defines, f, 0, <<"()">>, 'p.ts', 1},
             {scope, fscope, function, none, 'p.ts'},
             {var_decl, d1, x, 'let', fscope, 'p.ts', 2}], fun() ->
        ?assertEqual(no_solution,
            symbolic_query:run_result(?DB, real_rules(), "prefer_const(_, x, _, _)"))
    end).

redeclared_var_flags_two_decls_in_the_same_scope_test() ->
    with_db([{defines, f, 0, <<"()">>, 'p.ts', 1},
             {scope, fscope, function, none, 'p.ts'},
             {var_decl, d1, x, 'let', fscope, 'p.ts', 2},
             {var_decl, d2, x, 'let', fscope, 'p.ts', 3}], fun() ->
        ?assertEqual({solutions, [{'File', 'p.ts'}, {'Line', 3}]},
            symbolic_query:run_result(?DB, real_rules(), "redeclared_var(_, _, x, File, Line)"))
    end).

%% shadowed_var/5's own case (a nested scope) must NOT also trip
%% redeclared_var/5 — same scope, not one nested in the other, is the
%% whole distinction between the two rules.
redeclared_var_does_not_flag_a_nested_shadow_test() ->
    with_db([{defines, f, 0, <<"()">>, 'p.ts', 1},
             {scope, fscope, function, none, 'p.ts'},
             {scope, bscope, block, fscope, 'p.ts'},
             {var_decl, outer, x, 'let', fscope, 'p.ts', 2},
             {var_decl, inner, x, 'let', bscope, 'p.ts', 6}], fun() ->
        ?assertEqual(no_solution,
            symbolic_query:run_result(?DB, real_rules(), "redeclared_var(_, _, x, _, _)"))
    end).

shadows_restricted_name_flags_undefined_test() ->
    with_db([{defines, f, 0, <<"()">>, 'p.ts', 1},
             {scope, fscope, function, none, 'p.ts'},
             {var_decl, d1, 'undefined', 'let', fscope, 'p.ts', 2}], fun() ->
        ?assertEqual({solutions, [{'File', 'p.ts'}, {'Line', 2}]},
            symbolic_query:run_result(?DB, real_rules(), "shadows_restricted_name(_, 'undefined', File, Line)"))
    end).

shadows_restricted_name_does_not_flag_an_ordinary_name_test() ->
    with_db([{defines, f, 0, <<"()">>, 'p.ts', 1},
             {scope, fscope, function, none, 'p.ts'},
             {var_decl, d1, x, 'let', fscope, 'p.ts', 2}], fun() ->
        ?assertEqual(no_solution,
            symbolic_query:run_result(?DB, real_rules(), "shadows_restricted_name(_, x, _, _)"))
    end).

%% A reference (line 3) resolving to a declaration one line LATER (line
%% 4) — the temporal-dead-zone shape.
use_before_define_flags_a_reference_before_its_declaration_test() ->
    with_db([{defines, f, 0, <<"()">>, 'p.ts', 1},
             {scope, fscope, function, none, 'p.ts'},
             {var_decl, d1, x, 'let', fscope, 'p.ts', 4},
             {var_ref, r1, x, fscope, read, 'p.ts', 3},
             {resolves_to, r1, d1}], fun() ->
        ?assertEqual({solutions, [{'File', 'p.ts'}, {'Line', 3}]},
            symbolic_query:run_result(?DB, real_rules(), "use_before_define(_, _, x, File, Line)"))
    end).

%% A reference AFTER its declaration (the ordinary case) must not match.
use_before_define_does_not_flag_a_reference_after_its_declaration_test() ->
    with_db([{defines, f, 0, <<"()">>, 'p.ts', 1},
             {scope, fscope, function, none, 'p.ts'},
             {var_decl, d1, x, 'let', fscope, 'p.ts', 2},
             {var_ref, r1, x, fscope, read, 'p.ts', 3},
             {resolves_to, r1, d1}], fun() ->
        ?assertEqual(no_solution,
            symbolic_query:run_result(?DB, real_rules(), "use_before_define(_, _, x, _, _)"))
    end).

%% An unresolved reference to a name NOT in known_global/1 — a genuine
%% no-undef candidate.
undeclared_var_flags_an_unresolved_non_global_reference_test() ->
    with_db([{defines, f, 0, <<"()">>, 'p.ts', 1},
             {scope, fscope, function, none, 'p.ts'},
             {var_ref, r1, totallyUndeclaredThing, fscope, read, 'p.ts', 2},
             {resolves_to, r1, undefined}], fun() ->
        ?assertEqual({solutions, [{'File', 'p.ts'}, {'Line', 2}]},
            symbolic_query:run_result(?DB, real_rules(),
                "undeclared_var(_, totallyUndeclaredThing, File, Line)"))
    end).

%% A real global (console) resolving to undefined must NOT be flagged —
%% the whole point of known_global/1.
undeclared_var_does_not_flag_a_known_global_test() ->
    with_db([{defines, f, 0, <<"()">>, 'p.ts', 1},
             {scope, fscope, function, none, 'p.ts'},
             {var_ref, r1, console, fscope, read, 'p.ts', 2},
             {resolves_to, r1, undefined}], fun() ->
        ?assertEqual(no_solution,
            symbolic_query:run_result(?DB, real_rules(), "undeclared_var(_, console, _, _)"))
    end).

%% --- `new` expressions: no_new/4, no_new_wrapper/5, no_new_func/4,
%% no_object_constructor/4, prefer_regex_literal/4, lowercase_constructor/5 ---

no_new_flags_a_discarded_construction_test() ->
    with_db([{defines, f, 0, <<"()">>, 'p.ts', 1},
             {bare_new, f, 0, 'Logger', 'p.ts', 2}], fun() ->
        ?assertEqual({solutions, [{'File', 'p.ts'}, {'Line', 2}]},
            symbolic_query:run_result(?DB, real_rules(), "no_new(_, _, 'Logger', File, Line)"))
    end).

%% A `new X()` that's assigned (no bare_new/5 fact at all) must not match.
no_new_does_not_flag_an_assigned_construction_test() ->
    with_db([{defines, f, 0, <<"()">>, 'p.ts', 1},
             {calls, f, 0, {new, 'Bar', 0}, 'p.ts', 2}], fun() ->
        ?assertEqual(no_solution,
            symbolic_query:run_result(?DB, real_rules(), "no_new(_, _, 'Bar', _, _)"))
    end).

no_new_wrapper_flags_string_number_and_boolean_test() ->
    with_db([{defines, f, 0, <<"()">>, 'p.ts', 1},
             {calls, f, 0, {new, 'String', 1}, 'p.ts', 2},
             {calls, f, 0, {new, 'Number', 1}, 'p.ts', 3},
             {calls, f, 0, {new, 'Boolean', 1}, 'p.ts', 4},
             {calls, f, 0, {new, 'Bar', 0}, 'p.ts', 5}], fun() ->
        ?assertEqual({solutions, [{'Triples', [dash('Boolean', 'p.ts', 4),
                                                dash('Number', 'p.ts', 3),
                                                dash('String', 'p.ts', 2)]}]},
            symbolic_query:run_result(?DB, real_rules(), "all_no_new_wrappers(Triples)"))
    end).

no_new_func_flags_new_function_test() ->
    with_db([{defines, f, 0, <<"()">>, 'p.ts', 1},
             {calls, f, 0, {new, 'Function', 1}, 'p.ts', 2}], fun() ->
        ?assertEqual({solutions, [{'File', 'p.ts'}, {'Line', 2}]},
            symbolic_query:run_result(?DB, real_rules(), "no_new_func(_, _, File, Line)"))
    end).

%% Both shapes: `new Object()` and the bare `Object()` call (already
%% calls/5's existing local(...) shape, no new extraction needed for it).
no_object_constructor_flags_both_call_shapes_test() ->
    with_db([{defines, f, 0, <<"()">>, 'p.ts', 1},
             {calls, f, 0, {new, 'Object', 0}, 'p.ts', 2},
             {calls, f, 0, {local, 'Object', 0}, 'p.ts', 3}], fun() ->
        ?assertEqual({solutions, [{'Triples', [dash('p.ts', 2), dash('p.ts', 3)]}]},
            symbolic_query:run_result(?DB, real_rules(), "all_no_object_constructors(Triples)"))
    end).

%% `Object(x)` with an argument is a legitimate coercion, not `{}` — must
%% not match (ArgCount 0 is the whole point of both clauses above).
no_object_constructor_does_not_flag_a_coercion_call_test() ->
    with_db([{defines, f, 0, <<"()">>, 'p.ts', 1},
             {calls, f, 0, {local, 'Object', 1}, 'p.ts', 2}], fun() ->
        ?assertEqual(no_solution,
            symbolic_query:run_result(?DB, real_rules(), "no_object_constructor(_, _, _, _)"))
    end).

prefer_regex_literal_flags_both_call_shapes_test() ->
    with_db([{defines, f, 0, <<"()">>, 'p.ts', 1},
             {calls, f, 0, {new, 'RegExp', 1}, 'p.ts', 2},
             {calls, f, 0, {local, 'RegExp', 1}, 'p.ts', 3}], fun() ->
        ?assertEqual({solutions, [{'Triples', [dash('p.ts', 2), dash('p.ts', 3)]}]},
            symbolic_query:run_result(?DB, real_rules(), "all_prefer_regex_literals(Triples)"))
    end).

lowercase_constructor_flags_a_lowercase_name_test() ->
    with_db([{defines, f, 0, <<"()">>, 'p.ts', 1},
             {calls, f, 0, {new, foo, 0}, 'p.ts', 2}], fun() ->
        ?assertEqual({solutions, [{'File', 'p.ts'}, {'Line', 2}]},
            symbolic_query:run_result(?DB, real_rules(), "lowercase_constructor(_, _, foo, File, Line)"))
    end).

%% A properly-capitalized constructor must not match.
lowercase_constructor_does_not_flag_a_capitalized_name_test() ->
    with_db([{defines, f, 0, <<"()">>, 'p.ts', 1},
             {calls, f, 0, {new, 'Bar', 0}, 'p.ts', 2}], fun() ->
        ?assertEqual(no_solution,
            symbolic_query:run_result(?DB, real_rules(), "lowercase_constructor(_, _, 'Bar', _, _)"))
    end).

%% Every `new`-expression rule above must still answer cleanly — not
%% existence_error — against a codebase with zero calls at all (a real
%% predicate-existence trap; calls/5 itself needs no sentinel since a
%% real parse almost always has at least one call, but bare_new/5 is a
%% genuinely new predicate that easily has zero facts).
no_new_is_clean_with_zero_bare_new_facts_test() ->
    with_db([{defines, f, 0, <<"()">>, 'p.erl', 1}], fun() ->
        ?assertEqual(no_solution,
            symbolic_query:run_result(?DB, real_rules(), "no_new(_, _, _, _, _)"))
    end).

%% --- Imports and exports: duplicate_import/4, restricted_import/4, restricted_export/5 ---

duplicate_import_flags_the_second_occurrence_test() ->
    with_db([{import_decl, lodash, 'p.ts', 1},
             {import_decl, lodash, 'p.ts', 5}], fun() ->
        ?assertEqual({solutions, [{'File', 'p.ts'}, {'Line', 5}]},
            symbolic_query:run_result(?DB, real_rules(), "duplicate_import(lodash, File, _, Line)"))
    end).

%% Two DIFFERENT module paths must not match each other.
duplicate_import_does_not_flag_different_modules_test() ->
    with_db([{import_decl, lodash, 'p.ts', 1},
             {import_decl, moment, 'p.ts', 2}], fun() ->
        ?assertEqual(no_solution,
            symbolic_query:run_result(?DB, real_rules(), "duplicate_import(lodash, _, _, _)"))
    end).

restricted_import_flags_a_listed_module_test() ->
    with_db([{import_decl, lodash, 'p.ts', 1}], fun() ->
        ?assertEqual({solutions, [{'File', 'p.ts'}, {'Line', 1}]},
            symbolic_query:run_result(?DB, real_rules(), "restricted_import(lodash, File, Line)"))
    end).

restricted_import_does_not_flag_an_unlisted_module_test() ->
    with_db([{import_decl, 'my-own-module', 'p.ts', 1}], fun() ->
        ?assertEqual(no_solution,
            symbolic_query:run_result(?DB, real_rules(), "restricted_import('my-own-module', _, _)"))
    end).

restricted_export_flags_default_test() ->
    with_db([{export_decl, 'default', default, 'p.ts', 4}], fun() ->
        ?assertEqual({solutions, [{'File', 'p.ts'}, {'Line', 4}]},
            symbolic_query:run_result(?DB, real_rules(), "restricted_export('default', default, File, Line)"))
    end).

restricted_export_does_not_flag_an_ordinary_name_test() ->
    with_db([{export_decl, x, named, 'p.ts', 1}], fun() ->
        ?assertEqual(no_solution,
            symbolic_query:run_result(?DB, real_rules(), "restricted_export(x, named, _, _)"))
    end).

%% Every import/export rule above must still answer cleanly — not
%% existence_error — against a codebase with zero import/export facts
%% at all (an Erlang-only tree, or TS with none), the same
%% predicate-existence trap every other new predicate this session
%% needed a sentinel clause for.
duplicate_import_is_clean_with_zero_import_facts_test() ->
    with_db([{defines, f, 0, <<"()">>, 'p.erl', 1}], fun() ->
        ?assertEqual(no_solution,
            symbolic_query:run_result(?DB, real_rules(), "duplicate_import(_, _, _, _)"))
    end).

restricted_export_is_clean_with_zero_export_facts_test() ->
    with_db([{defines, f, 0, <<"()">>, 'p.erl', 1}], fun() ->
        ?assertEqual(no_solution,
            symbolic_query:run_result(?DB, real_rules(), "restricted_export(_, _, _, _)"))
    end).

%% --- Statement/block structure: no_empty_block/5, unreachable_stmt/4,
%% no_fallthrough_case/5, curly_violation/5, inconsistent_return/3 ---
%%
%% Facts hand-built here rather than via a live parse, same reasoning
%% as the scope-facts section above — extraction-layer coverage
%% (including the switch-case-value exclusion and else-clause
%% unwrapping bugs found while building this) lives in
%% ts_extract_typescript_tests.erl.

no_empty_block_flags_a_block_with_no_statements_test() ->
    with_db([{defines, f, 0, <<"()">>, 'p.ts', 1},
             {stmt_block, b1, f, 0, block, 'p.ts', 1}], fun() ->
        ?assertEqual({solutions, [{'File', 'p.ts'}, {'Line', 1}]},
            symbolic_query:run_result(?DB, real_rules(), "no_empty_block(_, f, 0, File, Line)"))
    end).

no_empty_block_does_not_flag_a_block_with_a_statement_test() ->
    with_db([{defines, f, 0, <<"()">>, 'p.ts', 1},
             {stmt_block, b1, f, 0, block, 'p.ts', 1},
             {stmt, s1, b1, 0, expression_statement, 'p.ts', 2}], fun() ->
        ?assertEqual(no_solution,
            symbolic_query:run_result(?DB, real_rules(), "no_empty_block(_, f, 0, _, _)"))
    end).

no_empty_block_is_clean_with_zero_block_facts_test() ->
    with_db([{defines, f, 0, <<"()">>, 'p.erl', 1}], fun() ->
        ?assertEqual(no_solution,
            symbolic_query:run_result(?DB, real_rules(), "no_empty_block(_, _, _, _, _)"))
    end).

%% A return_statement at index 0, then a later statement at index 1 in
%% the same block — the later one is unreachable.
unreachable_stmt_flags_a_statement_after_a_terminator_test() ->
    with_db([{defines, f, 0, <<"()">>, 'p.ts', 1},
             {stmt_block, b1, f, 0, block, 'p.ts', 1},
             {stmt, s1, b1, 0, return_statement, 'p.ts', 2},
             {stmt, s2, b1, 1, expression_statement, 'p.ts', 3}], fun() ->
        ?assertEqual({solutions, [{'File', 'p.ts'}, {'Line', 3}]},
            symbolic_query:run_result(?DB, real_rules(), "unreachable_stmt(_, b1, File, Line)"))
    end).

%% A lone terminator with nothing after it in the block must not flag
%% anything — there's no later statement to be unreachable.
unreachable_stmt_does_not_flag_a_terminator_with_nothing_after_it_test() ->
    with_db([{defines, f, 0, <<"()">>, 'p.ts', 1},
             {stmt_block, b1, f, 0, block, 'p.ts', 1},
             {stmt, s1, b1, 0, return_statement, 'p.ts', 2}], fun() ->
        ?assertEqual(no_solution,
            symbolic_query:run_result(?DB, real_rules(), "unreachable_stmt(_, b1, _, _)"))
    end).

unreachable_stmt_is_clean_with_zero_stmt_facts_test() ->
    with_db([{defines, f, 0, <<"()">>, 'p.erl', 1}], fun() ->
        ?assertEqual(no_solution,
            symbolic_query:run_result(?DB, real_rules(), "unreachable_stmt(_, _, _, _)"))
    end).

%% A switch_case with statements whose LAST one isn't a terminator, and
%% no last_switch_case/1 fact (so a case/default follows it) — falls
%% through.
no_fallthrough_case_flags_a_non_terminated_non_last_case_test() ->
    with_db([{defines, f, 1, <<"(x)">>, 'p.ts', 1},
             {stmt_block, b1, f, 1, switch_case, 'p.ts', 2},
             {stmt, s1, b1, 1, expression_statement, 'p.ts', 3}], fun() ->
        ?assertEqual({solutions, [{'File', 'p.ts'}, {'Line', 2}]},
            symbolic_query:run_result(?DB, real_rules(), "no_fallthrough_case(_, f, 1, File, Line)"))
    end).

%% An empty case (no stmt facts at all) immediately stacking into the
%% next one is idiomatic (`case 1: case 2: ...`), not a bug — the
%% Stmts \= [] exemption in no_fallthrough_case/5 must hold.
no_fallthrough_case_does_not_flag_an_empty_stacked_case_test() ->
    with_db([{defines, f, 1, <<"(x)">>, 'p.ts', 1},
             {stmt_block, b1, f, 1, switch_case, 'p.ts', 2}], fun() ->
        ?assertEqual(no_solution,
            symbolic_query:run_result(?DB, real_rules(), "no_fallthrough_case(_, f, 1, _, _)"))
    end).

%% A last_switch_case/1 fact present means nothing follows — must not
%% flag even though its last statement isn't a terminator.
no_fallthrough_case_does_not_flag_the_last_case_test() ->
    with_db([{defines, f, 1, <<"(x)">>, 'p.ts', 1},
             {stmt_block, b1, f, 1, switch_case, 'p.ts', 2},
             {stmt, s1, b1, 1, expression_statement, 'p.ts', 3},
             {last_switch_case, b1}], fun() ->
        ?assertEqual(no_solution,
            symbolic_query:run_result(?DB, real_rules(), "no_fallthrough_case(_, f, 1, _, _)"))
    end).

no_fallthrough_case_is_clean_with_zero_block_facts_test() ->
    with_db([{defines, f, 0, <<"()">>, 'p.erl', 1}], fun() ->
        ?assertEqual(no_solution,
            symbolic_query:run_result(?DB, real_rules(), "no_fallthrough_case(_, _, _, _, _)"))
    end).

curly_violation_flags_a_braceless_body_test() ->
    with_db([{defines, f, 0, <<"()">>, 'p.ts', 1},
             {braceless_body, f, 0, 'if', 'p.ts', 2}], fun() ->
        ?assertEqual({solutions, [{'File', 'p.ts'}, {'Line', 2}]},
            symbolic_query:run_result(?DB, real_rules(), "curly_violation(f, 0, 'if', File, Line)"))
    end).

%% A braceless_body fact for a different function must not leak into a
%% query for one with none at all.
curly_violation_does_not_flag_an_unrelated_function_test() ->
    with_db([{defines, f, 0, <<"()">>, 'p.ts', 1},
             {defines, g, 0, <<"()">>, 'p.ts', 3},
             {braceless_body, f, 0, 'if', 'p.ts', 2}], fun() ->
        ?assertEqual(no_solution,
            symbolic_query:run_result(?DB, real_rules(), "curly_violation(g, 0, _, _, _)"))
    end).

curly_violation_is_clean_with_zero_braceless_facts_test() ->
    with_db([{defines, f, 0, <<"()">>, 'p.erl', 1}], fun() ->
        ?assertEqual(no_solution,
            symbolic_query:run_result(?DB, real_rules(), "curly_violation(_, _, _, _, _)"))
    end).

inconsistent_return_flags_a_function_with_mixed_returns_test() ->
    with_db([{defines, f, 0, <<"()">>, 'p.ts', 1},
             {return_stmt, f, 0, true, 'p.ts', 2},
             {return_stmt, f, 0, false, 'p.ts', 3}], fun() ->
        ?assertEqual({solutions, [{'File', 'p.ts'}]},
            symbolic_query:run_result(?DB, real_rules(), "inconsistent_return(f, 0, File)"))
    end).

%% Two returns that both specify a value are consistent — must not flag.
inconsistent_return_does_not_flag_consistent_returns_test() ->
    with_db([{defines, f, 0, <<"()">>, 'p.ts', 1},
             {return_stmt, f, 0, true, 'p.ts', 2},
             {return_stmt, f, 0, true, 'p.ts', 3}], fun() ->
        ?assertEqual(no_solution,
            symbolic_query:run_result(?DB, real_rules(), "inconsistent_return(f, 0, _)"))
    end).

inconsistent_return_is_clean_with_zero_return_facts_test() ->
    with_db([{defines, f, 0, <<"()">>, 'p.erl', 1}], fun() ->
        ?assertEqual(no_solution,
            symbolic_query:run_result(?DB, real_rules(), "inconsistent_return(_, _, _)"))
    end).

%% A scratch project under _build/: <root>/.symbolic/rules.pl, plus a
%% data/ subdirectory to hang a fact database in and an other/ subtree
%% with its own library, for the ordering tests. Fun gets the absolute
%% root path.
with_scratch_project(Fun) ->
    Root = filename:absname(filename:join(["_build", "query_scratch_project"])),
    _ = file:del_dir_r(Root),
    RulesPath = filename:join([Root, ".symbolic", "rules.pl"]),
    ok = filelib:ensure_dir(RulesPath),
    ok = file:write_file(RulesPath, <<"named(F) :- defines(F, _, _, _, _).\n">>),
    ok = filelib:ensure_dir(filename:join([Root, "data", "placeholder"])),
    try
        Fun(Root)
    after
        _ = file:del_dir_r(Root)
    end.

get_cwd() ->
    {ok, Cwd} = file:get_cwd(),
    Cwd.

%% file:set_cwd/1 is the chdir of this runtime (there is no file:pwd/1) —
%% both helpers assert, so a failed cwd change can never leak into the
%% tests that run after these.
set_cwd(Dir) ->
    ok = file:set_cwd(Dir).

restore_cwd(Cwd) ->
    set_cwd(Cwd),
    ?assertEqual(Cwd, get_cwd()).

name_to_list_atom_test() ->
    ?assertEqual("charge", symbolic_query:name_to_list(charge)).

name_to_list_integer_test() ->
    ?assertEqual("_3", symbolic_query:name_to_list(3)).

%% print_bindings/1 writes straight to stdout — execution-only here (not
%% content-captured), since standing up an io-protocol group_leader
%% collector just to check two format strings isn't worth it for a
%% CLI-output helper with no logic beyond formatting.
print_bindings_empty_is_yes_test() ->
    ?assertEqual(ok, begin symbolic_query:print_bindings([]), ok end).

print_bindings_nonempty_test() ->
    ?assertEqual(ok, begin
        symbolic_query:print_bindings([{'F', foo}, {'Line', 3}]),
        ok
    end).

maybe_consult_rules_undefined_is_ok_test() ->
    {ok, Pid} = prolog_session:start_link(),
    ?assertEqual(ok, symbolic_query:maybe_consult_rules(Pid, undefined)),
    stop_session(Pid).

maybe_consult_rules_real_file_test() ->
    {ok, Pid} = prolog_session:start_link(),
    Path = filename:join(["_build", "query_rules_test_scratch.pl"]),
    ok = file:write_file(Path, <<"double_of(X, Y) :- Y is X * 2.\n">>),
    ?assertEqual(ok, symbolic_query:maybe_consult_rules(Pid, Path)),
    ok = file:delete(Path),
    stop_session(Pid).

maybe_consult_rules_missing_file_is_error_test() ->
    {ok, Pid} = prolog_session:start_link(),
    ?assertMatch({error, _}, symbolic_query:maybe_consult_rules(Pid, "no/such/rules_zz.pl")),
    stop_session(Pid).

stop_session(Pid) ->
    unlink(Pid),
    Ref = erlang:monitor(process, Pid),
    exit(Pid, shutdown),
    receive
        {'DOWN', Ref, process, Pid, _Reason} -> ok
    after 1000 ->
        ok
    end.

%% --- Round 2 of previously-"feasible" ESLint rules ---
%%
%% Facts hand-built here, same reasoning as every other section above:
%% isolates the Prolog rule from the extraction layer. Two sentinel
%% regressions first — both found live, against a real TS parse with zero
%% calls/5 and zero comment/3 facts, while building this round.

calls_is_clean_with_zero_call_facts_test() ->
    with_db([{defines, f, 0, <<"()">>, 'p.erl', 1}], fun() ->
        ?assertEqual(no_solution,
            symbolic_query:run_result(?DB, real_rules(), "calls(_, _, _, _, _)"))
    end).

comment_is_clean_with_zero_comment_facts_test() ->
    with_db([{defines, f, 0, <<"()">>, 'p.erl', 1}], fun() ->
        ?assertEqual(no_solution,
            symbolic_query:run_result(?DB, real_rules(), "comment(_, _, _)"))
    end).

no_compare_neg_zero_flags_a_negated_zero_literal_test() ->
    with_db([{defines, f, 1, <<"(x)">>, 'p.ts', 1},
             {expr, cmp1, f, 1, binary, 'p.ts', 2},
             {expr_operator, cmp1, '==='},
             {expr_operand, cmp1, left, ref1}, {expr_ref, ref1, f, 1, x, 'p.ts', 2},
             {expr_operand, cmp1, right, neg1},
             {expr, neg1, f, 1, unary, 'p.ts', 2},
             {expr_operator, neg1, '-'},
             {expr_operand, neg1, operand, lit1}, {literal, lit1, f, 1, number, 0, 'p.ts', 2, none}], fun() ->
        ?assertEqual({solutions, [{'File', 'p.ts'}]},
            symbolic_query:run_result(?DB, real_rules(), "no_compare_neg_zero(_, f, 1, File, _)"))
    end).

%% Erlang's LitKind for whole numbers is 'integer', not TS/JS's 'number' —
%% confirmed against a real Erlang parse. A regression for the fix: this
%% used to be silently invisible to the rule. Uses Erlang's plain `==`
%% (in the checked Op list) rather than `=:=`/`=/=` — this rule stays
%% scoped to the JS/TS comparison vocabulary by design, same choice
%% loose_equality/5 documents for the same reason.
no_compare_neg_zero_flags_a_negated_zero_on_an_erlang_integer_literal_test() ->
    with_db([{defines, f, 1, <<"(x)">>, 'p.erl', 1},
             {expr, cmp1, f, 1, binary, 'p.erl', 2},
             {expr_operator, cmp1, '=='},
             {expr_operand, cmp1, left, ref1}, {expr_ref, ref1, f, 1, x, 'p.erl', 2},
             {expr_operand, cmp1, right, neg1},
             {expr, neg1, f, 1, unary, 'p.erl', 2},
             {expr_operator, neg1, '-'},
             {expr_operand, neg1, operand, lit1}, {literal, lit1, f, 1, integer, 0, 'p.erl', 2, none}], fun() ->
        ?assertEqual({solutions, [{'File', 'p.erl'}]},
            symbolic_query:run_result(?DB, real_rules(), "no_compare_neg_zero(_, f, 1, File, _)"))
    end).

%% Same fix, the float spelling (Erlang's `-0.0`).
no_compare_neg_zero_flags_a_negated_zero_on_an_erlang_float_literal_test() ->
    with_db([{defines, f, 1, <<"(x)">>, 'p.erl', 1},
             {expr, cmp1, f, 1, binary, 'p.erl', 2},
             {expr_operator, cmp1, '=='},
             {expr_operand, cmp1, left, ref1}, {expr_ref, ref1, f, 1, x, 'p.erl', 2},
             {expr_operand, cmp1, right, neg1},
             {expr, neg1, f, 1, unary, 'p.erl', 2},
             {expr_operator, neg1, '-'},
             {expr_operand, neg1, operand, lit1}, {literal, lit1, f, 1, float, 0.0, 'p.erl', 2, none}], fun() ->
        ?assertEqual({solutions, [{'File', 'p.erl'}]},
            symbolic_query:run_result(?DB, real_rules(), "no_compare_neg_zero(_, f, 1, File, _)"))
    end).

%% A plain `x === 0` (not negated) must not match.
no_compare_neg_zero_does_not_flag_a_plain_zero_test() ->
    with_db([{defines, f, 1, <<"(x)">>, 'p.ts', 1},
             {expr, cmp1, f, 1, binary, 'p.ts', 2},
             {expr_operator, cmp1, '==='},
             {expr_operand, cmp1, left, ref1}, {expr_ref, ref1, f, 1, x, 'p.ts', 2},
             {expr_operand, cmp1, right, lit1}, {literal, lit1, f, 1, number, 0, 'p.ts', 2, none}], fun() ->
        ?assertEqual(no_solution,
            symbolic_query:run_result(?DB, real_rules(), "no_compare_neg_zero(_, f, 1, _, _)"))
    end).

no_prototype_builtin_flags_has_own_property_test() ->
    with_db([{defines, f, 0, <<"()">>, 'p.ts', 1},
             {calls, f, 0, {member, obj, hasOwnProperty, 1}, 'p.ts', 2}], fun() ->
        ?assertEqual({solutions, [{'File', 'p.ts'}]},
            symbolic_query:run_result(?DB, real_rules(), "no_prototype_builtin(f, hasOwnProperty, File, _)"))
    end).

no_prototype_builtin_does_not_flag_an_ordinary_method_test() ->
    with_db([{defines, f, 0, <<"()">>, 'p.ts', 1},
             {calls, f, 0, {member, obj, toString, 0}, 'p.ts', 2}], fun() ->
        ?assertEqual(no_solution,
            symbolic_query:run_result(?DB, real_rules(), "no_prototype_builtin(f, toString, _, _)"))
    end).

no_unsafe_negation_flags_a_negated_left_operand_test() ->
    with_db([{defines, f, 2, <<"(x,y)">>, 'p.ts', 1},
             {expr, cmp1, f, 2, binary, 'p.ts', 2},
             {expr_operator, cmp1, '<'},
             {expr_operand, cmp1, left, neg1},
             {expr, neg1, f, 2, unary, 'p.ts', 2},
             {expr_operator, neg1, '!'}], fun() ->
        ?assertEqual({solutions, [{'File', 'p.ts'}]},
            symbolic_query:run_result(?DB, real_rules(), "no_unsafe_negation(_, f, 2, File, _)"))
    end).

no_unsafe_negation_does_not_flag_a_plain_left_operand_test() ->
    with_db([{defines, f, 2, <<"(x,y)">>, 'p.ts', 1},
             {expr, cmp1, f, 2, binary, 'p.ts', 2},
             {expr_operator, cmp1, '<'},
             {expr_operand, cmp1, left, ref1}, {expr_ref, ref1, f, 2, x, 'p.ts', 2}], fun() ->
        ?assertEqual(no_solution,
            symbolic_query:run_result(?DB, real_rules(), "no_unsafe_negation(_, f, 2, _, _)"))
    end).

use_isnan_flags_a_direct_nan_comparison_test() ->
    with_db([{defines, f, 1, <<"(x)">>, 'p.ts', 1},
             {expr, cmp1, f, 1, binary, 'p.ts', 2},
             {expr_operator, cmp1, '==='},
             {expr_operand, cmp1, left, ref1}, {expr_ref, ref1, f, 1, x, 'p.ts', 2},
             {expr_operand, cmp1, right, ref2}, {expr_ref, ref2, f, 1, 'NaN', 'p.ts', 2}], fun() ->
        ?assertEqual({solutions, [{'File', 'p.ts'}]},
            symbolic_query:run_result(?DB, real_rules(), "use_isnan(_, f, 1, File, _)"))
    end).

use_isnan_does_not_flag_an_ordinary_comparison_test() ->
    with_db([{defines, f, 2, <<"(x,y)">>, 'p.ts', 1},
             {expr, cmp1, f, 2, binary, 'p.ts', 2},
             {expr_operator, cmp1, '==='},
             {expr_operand, cmp1, left, ref1}, {expr_ref, ref1, f, 2, x, 'p.ts', 2},
             {expr_operand, cmp1, right, ref2}, {expr_ref, ref2, f, 2, y, 'p.ts', 2}], fun() ->
        ?assertEqual(no_solution,
            symbolic_query:run_result(?DB, real_rules(), "use_isnan(_, f, 2, _, _)"))
    end).

invalid_typeof_flags_a_non_string_comparison_test() ->
    with_db([{defines, f, 1, <<"(x)">>, 'p.ts', 1},
             {expr, cmp1, f, 1, binary, 'p.ts', 2},
             {expr_operator, cmp1, '==='},
             {expr_operand, cmp1, left, tof1},
             {expr, tof1, f, 1, unary, 'p.ts', 2}, {expr_operator, tof1, typeof},
             {expr_operand, cmp1, right, lit1}, {literal, lit1, f, 1, number, 42, 'p.ts', 2, none}], fun() ->
        ?assertEqual({solutions, [{'File', 'p.ts'}]},
            symbolic_query:run_result(?DB, real_rules(), "invalid_typeof(_, f, 1, File, _)"))
    end).

%% A real (binary-valued) string literal, whatever its content, is not
%% flagged by the narrowed rule — see this predicate's own doc comment in
%% .symbolic/rules.pl for why exact content can't be checked here.
invalid_typeof_does_not_flag_a_string_literal_test() ->
    with_db([{defines, f, 1, <<"(x)">>, 'p.ts', 1},
             {expr, cmp1, f, 1, binary, 'p.ts', 2},
             {expr_operator, cmp1, '==='},
             {expr_operand, cmp1, left, tof1},
             {expr, tof1, f, 1, unary, 'p.ts', 2}, {expr_operator, tof1, typeof},
             {expr_operand, cmp1, right, lit1}, {literal, lit1, f, 1, string, <<"string">>, 'p.ts', 2, none}], fun() ->
        ?assertEqual(no_solution,
            symbolic_query:run_result(?DB, real_rules(), "invalid_typeof(_, f, 1, _, _)"))
    end).

not_camel_case_flags_a_snake_case_name_test() ->
    with_db([{defines, my_function, 0, <<"()">>, 'p.ts', 1}], fun() ->
        ?assertEqual({solutions, [{'File', 'p.ts'}]},
            symbolic_query:run_result(?DB, real_rules(), "not_camel_case(my_function, 0, File, _)"))
    end).

not_camel_case_does_not_flag_a_camel_case_name_test() ->
    with_db([{defines, myFunction, 0, <<"()">>, 'p.ts', 1}], fun() ->
        ?assertEqual(no_solution,
            symbolic_query:run_result(?DB, real_rules(), "not_camel_case(myFunction, 0, _, _)"))
    end).

loose_equality_flags_double_equals_test() ->
    with_db([{defines, f, 2, <<"(x,y)">>, 'p.ts', 1},
             {expr, cmp1, f, 2, binary, 'p.ts', 2},
             {expr_operator, cmp1, '=='}], fun() ->
        ?assertEqual({solutions, [{'File', 'p.ts'}]},
            symbolic_query:run_result(?DB, real_rules(), "loose_equality(_, f, 2, File, _)"))
    end).

loose_equality_does_not_flag_triple_equals_test() ->
    with_db([{defines, f, 2, <<"(x,y)">>, 'p.ts', 1},
             {expr, cmp1, f, 2, binary, 'p.ts', 2},
             {expr_operator, cmp1, '==='}], fun() ->
        ?assertEqual(no_solution,
            symbolic_query:run_result(?DB, real_rules(), "loose_equality(_, f, 2, _, _)"))
    end).

id_denylisted_flags_a_listed_name_test() ->
    with_db([{defines, data, 0, <<"()">>, 'p.ts', 1}], fun() ->
        ?assertEqual({solutions, [{'File', 'p.ts'}]},
            symbolic_query:run_result(?DB, real_rules(), "id_denylisted(data, 0, File, _)"))
    end).

id_denylisted_does_not_flag_an_unlisted_name_test() ->
    with_db([{defines, myVar, 0, <<"()">>, 'p.ts', 1}], fun() ->
        ?assertEqual(no_solution,
            symbolic_query:run_result(?DB, real_rules(), "id_denylisted(myVar, 0, _, _)"))
    end).

too_many_lines_flags_a_file_over_the_threshold_test() ->
    with_db([{defines, f, 0, <<"()">>, 'big.ts', 400}], fun() ->
        ?assertEqual({solutions, [{'MaxLine', 400}]},
            symbolic_query:run_result(?DB, real_rules(), "too_many_lines('big.ts', MaxLine)"))
    end).

too_many_lines_does_not_flag_a_small_file_test() ->
    with_db([{defines, f, 0, <<"()">>, 'small.ts', 50}], fun() ->
        ?assertEqual(no_solution,
            symbolic_query:run_result(?DB, real_rules(), "too_many_lines('small.ts', _)"))
    end).

%% File left unbound (the shape all_too_many_lines/1 actually uses) — the
%% same "bind the grouping key first" regression file_define_count/2 and
%% real_complexity/4 both needed.
too_many_lines_groups_by_file_when_unbound_test() ->
    with_db([{defines, f1, 0, <<"()">>, 'big.ts', 400},
             {defines, f2, 0, <<"()">>, 'small.ts', 10}], fun() ->
        ?assertEqual({solutions, [{'File', 'big.ts'}, {'MaxLine', 400}]},
            symbolic_query:run_result(?DB, real_rules(), "too_many_lines(File, MaxLine)"))
    end).

no_alert_flags_a_direct_alert_call_test() ->
    with_db([{defines, f, 0, <<"()">>, 'p.ts', 1},
             {calls, f, 0, {local, alert, 1}, 'p.ts', 2}], fun() ->
        ?assertEqual({solutions, [{'File', 'p.ts'}]},
            symbolic_query:run_result(?DB, real_rules(), "no_alert(_, _, alert, File, _)"))
    end).

no_alert_does_not_flag_an_ordinary_call_test() ->
    with_db([{defines, f, 0, <<"()">>, 'p.ts', 1},
             {calls, f, 0, {local, log, 1}, 'p.ts', 2}], fun() ->
        ?assertEqual(no_solution,
            symbolic_query:run_result(?DB, real_rules(), "no_alert(_, _, log, _, _)"))
    end).

no_array_constructor_flags_zero_args_test() ->
    with_db([{defines, f, 0, <<"()">>, 'p.ts', 1},
             {calls, f, 0, {new, 'Array', 0}, 'p.ts', 2}], fun() ->
        ?assertEqual({solutions, [{'File', 'p.ts'}]},
            symbolic_query:run_result(?DB, real_rules(), "no_array_constructor(_, _, File, _)"))
    end).

%% `new Array(5)` (exactly one arg) is the legitimate array-of-length-N
%% idiom — must not be flagged, the whole point of the ArgCount \= 1 guard.
no_array_constructor_does_not_flag_a_single_length_arg_test() ->
    with_db([{defines, f, 0, <<"()">>, 'p.ts', 1},
             {calls, f, 0, {new, 'Array', 1}, 'p.ts', 2}], fun() ->
        ?assertEqual(no_solution,
            symbolic_query:run_result(?DB, real_rules(), "no_array_constructor(_, _, _, _)"))
    end).

no_bitwise_flags_a_bitwise_and_test() ->
    with_db([{defines, f, 1, <<"(x)">>, 'p.ts', 1},
             {expr, e1, f, 1, binary, 'p.ts', 2},
             {expr_operator, e1, '&'}], fun() ->
        ?assertEqual({solutions, [{'File', 'p.ts'}]},
            symbolic_query:run_result(?DB, real_rules(), "no_bitwise(_, f, 1, File, _)"))
    end).

%% Logical `&&` must not be confused with bitwise `&`.
no_bitwise_does_not_flag_logical_and_test() ->
    with_db([{defines, f, 1, <<"(x)">>, 'p.ts', 1},
             {expr, e1, f, 1, binary, 'p.ts', 2},
             {expr_operator, e1, '&&'}], fun() ->
        ?assertEqual(no_solution,
            symbolic_query:run_result(?DB, real_rules(), "no_bitwise(_, f, 1, _, _)"))
    end).

no_eq_null_flags_loose_equality_with_null_test() ->
    with_db([{defines, f, 1, <<"(x)">>, 'p.ts', 1},
             {expr, cmp1, f, 1, binary, 'p.ts', 2},
             {expr_operator, cmp1, '=='},
             {expr_operand, cmp1, left, ref1}, {expr_ref, ref1, f, 1, x, 'p.ts', 2},
             {expr_operand, cmp1, right, lit1}, {literal, lit1, f, 1, null, null, 'p.ts', 2, none}], fun() ->
        ?assertEqual({solutions, [{'File', 'p.ts'}]},
            symbolic_query:run_result(?DB, real_rules(), "no_eq_null(_, f, 1, File, _)"))
    end).

%% `x === null` (strict, the recommended alternative) must not be flagged.
no_eq_null_does_not_flag_strict_equality_with_null_test() ->
    with_db([{defines, f, 1, <<"(x)">>, 'p.ts', 1},
             {expr, cmp1, f, 1, binary, 'p.ts', 2},
             {expr_operator, cmp1, '==='},
             {expr_operand, cmp1, left, ref1}, {expr_ref, ref1, f, 1, x, 'p.ts', 2},
             {expr_operand, cmp1, right, lit1}, {literal, lit1, f, 1, null, null, 'p.ts', 2, none}], fun() ->
        ?assertEqual(no_solution,
            symbolic_query:run_result(?DB, real_rules(), "no_eq_null(_, f, 1, _, _)"))
    end).

no_eval_flags_a_direct_eval_call_test() ->
    with_db([{defines, f, 0, <<"()">>, 'p.ts', 1},
             {calls, f, 0, {local, eval, 1}, 'p.ts', 2}], fun() ->
        ?assertEqual({solutions, [{'File', 'p.ts'}]},
            symbolic_query:run_result(?DB, real_rules(), "no_eval(_, _, File, _)"))
    end).

no_eval_does_not_flag_an_ordinary_call_test() ->
    with_db([{defines, f, 0, <<"()">>, 'p.ts', 1},
             {calls, f, 0, {local, parse, 1}, 'p.ts', 2}], fun() ->
        ?assertEqual(no_solution,
            symbolic_query:run_result(?DB, real_rules(), "no_eval(_, _, _, _)"))
    end).

no_implicit_coercion_flags_double_negation_test() ->
    with_db([{defines, f, 1, <<"(x)">>, 'p.ts', 1},
             {expr, outer1, f, 1, unary, 'p.ts', 2}, {expr_operator, outer1, '!'},
             {expr_operand, outer1, operand, inner1},
             {expr, inner1, f, 1, unary, 'p.ts', 2}, {expr_operator, inner1, '!'}], fun() ->
        ?assertEqual({solutions, [{'File', 'p.ts'}]},
            symbolic_query:run_result(?DB, real_rules(), "no_implicit_coercion(_, f, 1, File, _)"))
    end).

no_implicit_coercion_flags_a_bare_unary_plus_test() ->
    with_db([{defines, f, 1, <<"(x)">>, 'p.ts', 1},
             {expr, outer1, f, 1, unary, 'p.ts', 2}, {expr_operator, outer1, '+'}], fun() ->
        ?assertEqual({solutions, [{'File', 'p.ts'}]},
            symbolic_query:run_result(?DB, real_rules(), "no_implicit_coercion(_, f, 1, File, _)"))
    end).

%% A single `!x` (not doubled) must not be flagged as coercion.
no_implicit_coercion_does_not_flag_a_single_negation_test() ->
    with_db([{defines, f, 1, <<"(x)">>, 'p.ts', 1},
             {expr, outer1, f, 1, unary, 'p.ts', 2}, {expr_operator, outer1, '!'},
             {expr_operand, outer1, operand, ref1}, {expr_ref, ref1, f, 1, x, 'p.ts', 2}], fun() ->
        ?assertEqual(no_solution,
            symbolic_query:run_result(?DB, real_rules(), "no_implicit_coercion(_, f, 1, _, _)"))
    end).

no_implied_eval_flags_set_timeout_test() ->
    with_db([{defines, f, 0, <<"()">>, 'p.ts', 1},
             {calls, f, 0, {local, setTimeout, 2}, 'p.ts', 2}], fun() ->
        ?assertEqual({solutions, [{'File', 'p.ts'}]},
            symbolic_query:run_result(?DB, real_rules(), "no_implied_eval(_, _, setTimeout, File, _)"))
    end).

no_implied_eval_does_not_flag_set_immediate_test() ->
    with_db([{defines, f, 0, <<"()">>, 'p.ts', 1},
             {calls, f, 0, {local, setImmediate, 1}, 'p.ts', 2}], fun() ->
        ?assertEqual(no_solution,
            symbolic_query:run_result(?DB, real_rules(), "no_implied_eval(_, _, setImmediate, _, _)"))
    end).

inline_comment_flags_a_comment_sharing_a_call_line_test() ->
    with_db([{defines, f, 0, <<"()">>, 'p.ts', 1},
             {calls, f, 0, {local, g, 0}, 'p.ts', 3},
             {comment, 'p.ts', 3, <<"inline">>}], fun() ->
        ?assertEqual({solutions, [{'Text', <<"inline">>}]},
            symbolic_query:run_result(?DB, real_rules(), "inline_comment('p.ts', 3, Text)"))
    end).

inline_comment_does_not_flag_a_standalone_comment_test() ->
    with_db([{defines, f, 0, <<"()">>, 'p.ts', 1},
             {comment, 'p.ts', 5, <<"standalone">>}], fun() ->
        ?assertEqual(no_solution,
            symbolic_query:run_result(?DB, real_rules(), "inline_comment('p.ts', 5, _)"))
    end).

magic_number_flags_an_unlisted_value_test() ->
    with_db([{literal, lit1, f, 0, number, 42, 'p.ts', 2, none}], fun() ->
        ?assertEqual({solutions, [{'File', 'p.ts'}]},
            symbolic_query:run_result(?DB, real_rules(), "magic_number(_, f, 0, File, _)"))
    end).

magic_number_does_not_flag_an_allowed_value_test() ->
    with_db([{literal, lit1, f, 0, number, 1, 'p.ts', 2, none}], fun() ->
        ?assertEqual(no_solution,
            symbolic_query:run_result(?DB, real_rules(), "magic_number(_, f, 0, _, _)"))
    end).

%% Erlang's LitKind for whole numbers is 'integer' and for floats is
%% 'float', not TS/JS's unified 'number' — confirmed against a real Erlang
%% parse. A regression for the fix: this used to be silently invisible to
%% the rule (0 hits over 281 real integer/float literals in this
%% project's own source before the fix).
magic_number_flags_an_erlang_integer_literal_test() ->
    with_db([{literal, lit1, f, 0, integer, 42, 'p.erl', 2, none}], fun() ->
        ?assertEqual({solutions, [{'File', 'p.erl'}]},
            symbolic_query:run_result(?DB, real_rules(), "magic_number(_, f, 0, File, _)"))
    end).

magic_number_flags_an_erlang_float_literal_test() ->
    with_db([{literal, lit1, f, 0, float, 3.5, 'p.erl', 2, none}], fun() ->
        ?assertEqual({solutions, [{'File', 'p.erl'}]},
            symbolic_query:run_result(?DB, real_rules(), "magic_number(_, f, 0, File, _)"))
    end).

magic_number_does_not_flag_an_allowed_erlang_integer_test() ->
    with_db([{literal, lit1, f, 0, integer, 1, 'p.erl', 2, none}], fun() ->
        ?assertEqual(no_solution,
            symbolic_query:run_result(?DB, real_rules(), "magic_number(_, f, 0, _, _)"))
    end).

magic_number_does_not_flag_an_allowed_erlang_float_test() ->
    with_db([{literal, lit1, f, 0, float, 1.0, 'p.erl', 2, none}], fun() ->
        ?assertEqual(no_solution,
            symbolic_query:run_result(?DB, real_rules(), "magic_number(_, f, 0, _, _)"))
    end).

no_restricted_global_flags_a_listed_global_test() ->
    with_db([{defines, f, 0, <<"()">>, 'p.ts', 1},
             {calls, f, 0, {local, event, 1}, 'p.ts', 2}], fun() ->
        ?assertEqual({solutions, [{'File', 'p.ts'}]},
            symbolic_query:run_result(?DB, real_rules(), "no_restricted_global(_, _, event, File, _)"))
    end).

no_restricted_global_does_not_flag_an_unlisted_global_test() ->
    with_db([{defines, f, 0, <<"()">>, 'p.ts', 1},
             {calls, f, 0, {local, myFunc, 1}, 'p.ts', 2}], fun() ->
        ?assertEqual(no_solution,
            symbolic_query:run_result(?DB, real_rules(), "no_restricted_global(_, _, myFunc, _, _)"))
    end).

no_ternary_flags_a_ternary_branch_test() ->
    with_db([{defines, f, 0, <<"()">>, 'p.ts', 1},
             {branch, f, 0, ternary, 'p.ts', 2}], fun() ->
        ?assertEqual({solutions, [{'File', 'p.ts'}]},
            symbolic_query:run_result(?DB, real_rules(), "no_ternary(f, 0, File, _)"))
    end).

no_ternary_does_not_flag_an_if_branch_test() ->
    with_db([{defines, f, 0, <<"()">>, 'p.ts', 1},
             {branch, f, 0, 'if', 'p.ts', 2}], fun() ->
        ?assertEqual(no_solution,
            symbolic_query:run_result(?DB, real_rules(), "no_ternary(f, 0, _, _)"))
    end).

no_underscore_dangle_flags_a_leading_underscore_test() ->
    with_db([{defines, '_private', 0, <<"()">>, 'p.ts', 1}], fun() ->
        ?assertEqual({solutions, [{'File', 'p.ts'}]},
            symbolic_query:run_result(?DB, real_rules(), "no_underscore_dangle('_private', 0, File, _)"))
    end).

no_underscore_dangle_flags_a_trailing_underscore_test() ->
    with_db([{defines, 'trailing_', 0, <<"()">>, 'p.ts', 1}], fun() ->
        ?assertEqual({solutions, [{'File', 'p.ts'}]},
            symbolic_query:run_result(?DB, real_rules(), "no_underscore_dangle('trailing_', 0, File, _)"))
    end).

no_underscore_dangle_does_not_flag_an_ordinary_name_test() ->
    with_db([{defines, ordinary, 0, <<"()">>, 'p.ts', 1}], fun() ->
        ?assertEqual(no_solution,
            symbolic_query:run_result(?DB, real_rules(), "no_underscore_dangle(ordinary, 0, _, _)"))
    end).

radix_missing_flags_a_single_arg_call_test() ->
    with_db([{defines, f, 0, <<"()">>, 'p.ts', 1},
             {calls, f, 0, {local, parseInt, 1}, 'p.ts', 2}], fun() ->
        ?assertEqual({solutions, [{'File', 'p.ts'}]},
            symbolic_query:run_result(?DB, real_rules(), "radix_missing(_, _, File, _)"))
    end).

radix_missing_does_not_flag_a_call_with_a_radix_test() ->
    with_db([{defines, f, 0, <<"()">>, 'p.ts', 1},
             {calls, f, 0, {local, parseInt, 2}, 'p.ts', 2}], fun() ->
        ?assertEqual(no_solution,
            symbolic_query:run_result(?DB, real_rules(), "radix_missing(_, _, _, _)"))
    end).

symbol_description_missing_flags_a_zero_arg_call_test() ->
    with_db([{defines, f, 0, <<"()">>, 'p.ts', 1},
             {calls, f, 0, {local, 'Symbol', 0}, 'p.ts', 2}], fun() ->
        ?assertEqual({solutions, [{'File', 'p.ts'}]},
            symbolic_query:run_result(?DB, real_rules(), "symbol_description_missing(_, _, File, _)"))
    end).

symbol_description_missing_does_not_flag_a_call_with_a_description_test() ->
    with_db([{defines, f, 0, <<"()">>, 'p.ts', 1},
             {calls, f, 0, {local, 'Symbol', 1}, 'p.ts', 2}], fun() ->
        ?assertEqual(no_solution,
            symbolic_query:run_result(?DB, real_rules(), "symbol_description_missing(_, _, _, _)"))
    end).

require_await_flags_an_async_function_with_no_await_test() ->
    with_db([{defines, f, 0, <<"()">>, 'p.ts', 1},
             {async_function, f, 0, 'p.ts', 1}], fun() ->
        ?assertEqual({solutions, [{'File', 'p.ts'}]},
            symbolic_query:run_result(?DB, real_rules(), "require_await(_, _, File, _)"))
    end).

require_await_does_not_flag_an_async_function_with_an_await_test() ->
    with_db([{defines, f, 0, <<"()">>, 'p.ts', 1},
             {async_function, f, 0, 'p.ts', 1},
             {await_expr, f, 0, 'p.ts', 2}], fun() ->
        ?assertEqual(no_solution,
            symbolic_query:run_result(?DB, real_rules(), "require_await(_, _, _, _)"))
    end).

require_yield_flags_a_generator_with_no_yield_test() ->
    with_db([{defines, gen, 0, <<"()">>, 'p.ts', 1},
             {generator_function, gen, 0, 'p.ts', 1}], fun() ->
        ?assertEqual({solutions, [{'File', 'p.ts'}]},
            symbolic_query:run_result(?DB, real_rules(), "require_yield(_, _, File, _)"))
    end).

require_yield_does_not_flag_a_generator_with_a_yield_test() ->
    with_db([{defines, gen, 0, <<"()">>, 'p.ts', 1},
             {generator_function, gen, 0, 'p.ts', 1},
             {yield_expr, gen, 0, 'p.ts', 2}], fun() ->
        ?assertEqual(no_solution,
            symbolic_query:run_result(?DB, real_rules(), "require_yield(_, _, _, _)"))
    end).

no_sequences_flags_a_comma_operator_expr_test() ->
    with_db([{defines, f, 0, <<"()">>, 'p.ts', 1},
             {expr, {'p.ts', 10, 20}, f, 0, sequence, 'p.ts', 2}], fun() ->
        ?assertEqual({solutions, [{'File', 'p.ts'}]},
            symbolic_query:run_result(?DB, real_rules(), "no_sequences(_, _, File, _)"))
    end).

no_sequences_does_not_flag_an_ordinary_binary_expr_test() ->
    with_db([{defines, f, 0, <<"()">>, 'p.ts', 1},
             {expr, {'p.ts', 10, 20}, f, 0, binary, 'p.ts', 2}], fun() ->
        ?assertEqual(no_solution,
            symbolic_query:run_result(?DB, real_rules(), "no_sequences(_, _, _, _)"))
    end).

no_caller_flags_arguments_callee_test() ->
    with_db([{defines, f, 0, <<"()">>, 'p.ts', 1},
             {member_read, f, 0, arguments, callee, 'p.ts', 2}], fun() ->
        ?assertEqual({solutions, [{'File', 'p.ts'}]},
            symbolic_query:run_result(?DB, real_rules(), "no_caller(_, _, File, _)"))
    end).

no_caller_does_not_flag_an_ordinary_member_read_test() ->
    with_db([{defines, f, 0, <<"()">>, 'p.ts', 1},
             {member_read, f, 0, x, prop, 'p.ts', 2}], fun() ->
        ?assertEqual(no_solution,
            symbolic_query:run_result(?DB, real_rules(), "no_caller(_, _, _, _)"))
    end).

no_iterator_flags_dunder_iterator_test() ->
    with_db([{defines, f, 0, <<"()">>, 'p.ts', 1},
             {member_read, f, 0, x, '__iterator__', 'p.ts', 2}], fun() ->
        ?assertEqual({solutions, [{'File', 'p.ts'}]},
            symbolic_query:run_result(?DB, real_rules(), "no_iterator(_, _, File, _)"))
    end).

no_proto_flags_dunder_proto_test() ->
    with_db([{defines, f, 0, <<"()">>, 'p.ts', 1},
             {member_read, f, 0, x, '__proto__', 'p.ts', 2}], fun() ->
        ?assertEqual({solutions, [{'File', 'p.ts'}]},
            symbolic_query:run_result(?DB, real_rules(), "no_proto(_, _, File, _)"))
    end).

no_labels_flags_any_label_stmt_test() ->
    with_db([{defines, f, 0, <<"()">>, 'p.ts', 1},
             {label_stmt, f, 0, outer, 'p.ts', 2}], fun() ->
        ?assertEqual({solutions, [{'File', 'p.ts'}]},
            symbolic_query:run_result(?DB, real_rules(), "no_labels(_, _, File, _)"))
    end).

no_unused_labels_flags_a_label_with_no_ref_test() ->
    with_db([{defines, f, 0, <<"()">>, 'p.ts', 1},
             {label_stmt, f, 0, outer, 'p.ts', 2}], fun() ->
        ?assertEqual({solutions, [{'File', 'p.ts'}]},
            symbolic_query:run_result(?DB, real_rules(), "no_unused_labels(_, _, File, _)"))
    end).

no_unused_labels_does_not_flag_a_referenced_label_test() ->
    with_db([{defines, f, 0, <<"()">>, 'p.ts', 1},
             {label_stmt, f, 0, outer, 'p.ts', 2},
             {label_ref, f, 0, outer, break, 'p.ts', 3}], fun() ->
        ?assertEqual(no_solution,
            symbolic_query:run_result(?DB, real_rules(), "no_unused_labels(_, _, _, _)"))
    end).

no_label_var_flags_a_label_sharing_a_variable_name_test() ->
    with_db([{defines, f, 0, <<"()">>, 'p.ts', 1},
             {label_stmt, f, 0, outer, 'p.ts', 2},
             {var_decl, {'p.ts', 1, 2}, outer, 'let', {'p.ts', 0, 0}, 'p.ts', 3}], fun() ->
        ?assertEqual({solutions, [{'File', 'p.ts'}]},
            symbolic_query:run_result(?DB, real_rules(), "no_label_var(_, _, File, _)"))
    end).

no_label_var_does_not_flag_an_unrelated_variable_test() ->
    with_db([{defines, f, 0, <<"()">>, 'p.ts', 1},
             {label_stmt, f, 0, outer, 'p.ts', 2},
             {var_decl, {'p.ts', 1, 2}, unrelated, 'let', {'p.ts', 0, 0}, 'p.ts', 3}], fun() ->
        ?assertEqual(no_solution,
            symbolic_query:run_result(?DB, real_rules(), "no_label_var(_, _, _, _)"))
    end).

no_useless_concat_flags_two_adjacent_string_literals_test() ->
    with_db([{defines, f, 0, <<"()">>, 'p.ts', 1},
             {expr, id1, f, 0, binary, 'p.ts', 2}, {expr_operator, id1, '+'},
             {expr_operand, id1, left, lit1}, {literal, lit1, f, 0, string, <<"a">>, 'p.ts', 2, <<"\"a\"">>},
             {expr_operand, id1, right, lit2}, {literal, lit2, f, 0, string, <<"b">>, 'p.ts', 2, <<"\"b\"">>}
            ], fun() ->
        ?assertEqual({solutions, [{'File', 'p.ts'}]},
            symbolic_query:run_result(?DB, real_rules(), "no_useless_concat(_, _, File, _)"))
    end).

no_useless_concat_does_not_flag_a_literal_plus_a_variable_test() ->
    with_db([{defines, f, 0, <<"()">>, 'p.ts', 1},
             {expr, id1, f, 0, binary, 'p.ts', 2}, {expr_operator, id1, '+'},
             {expr_operand, id1, left, lit1}, {literal, lit1, f, 0, string, <<"a">>, 'p.ts', 2, <<"\"a\"">>},
             {expr_operand, id1, right, ref1}, {expr_ref, ref1, f, 0, x, 'p.ts', 2}
            ], fun() ->
        ?assertEqual(no_solution,
            symbolic_query:run_result(?DB, real_rules(), "no_useless_concat(_, _, _, _)"))
    end).

prefer_template_flags_a_literal_plus_a_variable_test() ->
    with_db([{defines, f, 0, <<"()">>, 'p.ts', 1},
             {expr, id1, f, 0, binary, 'p.ts', 2}, {expr_operator, id1, '+'},
             {expr_operand, id1, left, lit1}, {literal, lit1, f, 0, string, <<"a">>, 'p.ts', 2, <<"\"a\"">>},
             {expr_operand, id1, right, ref1}, {expr_ref, ref1, f, 0, x, 'p.ts', 2}
            ], fun() ->
        ?assertEqual({solutions, [{'File', 'p.ts'}]},
            symbolic_query:run_result(?DB, real_rules(), "prefer_template(_, _, File, _)"))
    end).

prefer_template_does_not_flag_two_numeric_operands_test() ->
    with_db([{defines, f, 0, <<"()">>, 'p.ts', 1},
             {expr, id1, f, 0, binary, 'p.ts', 2}, {expr_operator, id1, '+'},
             {expr_operand, id1, left, lit1}, {literal, lit1, f, 0, number, 1, 'p.ts', 2, <<"1">>},
             {expr_operand, id1, right, lit2}, {literal, lit2, f, 0, number, 2, 'p.ts', 2, <<"2">>}
            ], fun() ->
        ?assertEqual(no_solution,
            symbolic_query:run_result(?DB, real_rules(), "prefer_template(_, _, _, _)"))
    end).
