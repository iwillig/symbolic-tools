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
            {solutions, [{'Edges', [dash('f.erl', os)]}]}}].

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

banned_call_flags_a_console_log_call_test() ->
    with_db([{defines, noisy, 0, <<"()">>, 's.ts', 1},
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
             {expr_operand, cmp1, left, lit1}, {literal, lit1, busy, 1, number, 0, 'p.ts', 2},
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
             {expr_operand, cmp2, right, lit2}, {literal, lit2, calm, 1, number, 0, 'p.ts', 2}], fun() ->
        ?assertEqual(no_solution,
            symbolic_query:run_result(?DB, real_rules(), "yoda_condition(_, calm, 1, _, _)"))
    end).

yoda_condition_is_clean_with_zero_expressions_test() ->
    with_db([{defines, plain, 0, <<"()">>, 'p.erl', 1}], fun() ->
        ?assertEqual(no_solution,
            symbolic_query:run_result(?DB, real_rules(), "yoda_condition(_, plain, 0, _, _)"))
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
