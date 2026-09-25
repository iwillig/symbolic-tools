-module(symbolic_parse_tests).
-include_lib("eunit/include/eunit.hrl").

%% Issue #4's "broader" fix: a crash anywhere inside ts_extract:file/1 —
%% generic over WHY it crashed, not tied to the specific bare-exponent
%% bug that triggered it (see ts_extract_typescript_tests.erl's own
%% extracts_bare_exponent_literal_facts_test for that narrow fix) —
%% degrades to "this file contributed zero facts" instead of failing the
%% whole scan. meck-mocked (not a real crashing file) because the point
%% here is the CATCHING mechanism itself, not any one bug.
extract_file_timed_survives_a_crashing_file_test() ->
    Root = filename:join(["_build", "parse_crash_survives_scratch"]),
    _ = file:del_dir_r(Root),
    Good = filename:join([Root, "good.erl"]),
    Bad = filename:join([Root, "bad.erl"]),
    ok = filelib:ensure_dir(Good),
    ok = file:write_file(Good, <<"-module(good).\nf() -> ok.\n">>),
    ok = file:write_file(Bad, <<"-module(bad).\ng() -> ok.\n">>),
    meck:new(ts_extract, [passthrough]),
    meck:expect(ts_extract, file, fun(F) ->
        case F of
            Bad -> error(boom);
            _ -> meck:passthrough([F])
        end
    end),
    try
        {ok, {Files, Facts}} = symbolic_parse:scan(Root),
        ?assertEqual(2, length(Files)),
        %% The crashing file contributed nothing; the good one's facts
        %% are still there — the scan as a whole still succeeded.
        ?assert(lists:any(
            fun(Fact) -> element(1, Fact) =:= defines andalso element(2, Fact) =:= f end, Facts)),
        ?assertNot(lists:any(
            fun(Fact) -> element(1, Fact) =:= defines andalso element(2, Fact) =:= g end, Facts))
    after
        meck:unload(ts_extract),
        _ = file:del_dir_r(Root)
    end.

%% scan/1 (the side-effect-free core) is already exercised end-to-end by
%% symbolic_codebase_tests.erl, which is the main consumer. This module
%% covers the rest of run/2's body: maybe_store/2, print_fact/1, and
%% error_message/1 (the exact text printed for each scan/1 error, pulled
%% out specifically so it's assertable without calling run/2 itself,
%% which halt()s on every path).

error_message_no_such_directory_test() ->
    Text = lists:flatten(symbolic_parse:error_message({no_such_directory, "no/such/dir"})),
    ?assertEqual("parse: no such directory: no/such/dir\n", Text).

error_message_nif_not_loadable_test() ->
    Text = lists:flatten(symbolic_parse:error_message({nif_not_loadable, some_reason})),
    ?assertEqual(
        "parse: symbolic_ts (the tree-sitter NIF) isn't loadable "
        "in this build - a known packaging limitation, not a code "
        "bug. Run via a `rebar3 release` (or `rebar3 shell`); see "
        "docs/cli-erlang.md.\n",
        Text).

error_message_no_such_path_test() ->
    Text = lists:flatten(symbolic_parse:error_message({no_such_path, "no/such/thing"})),
    ?assertEqual("parse: no such file or directory: no/such/thing\n", Text).

error_message_unsupported_file_test() ->
    Text = lists:flatten(symbolic_parse:error_message({unsupported_file, "notes.txt"})),
    ?assertMatch("parse: notes.txt has no extension" ++ _, Text).

error_message_no_such_config_test() ->
    Text = lists:flatten(symbolic_parse:error_message({no_such_config, "no/such/config.json"})),
    ?assertEqual("parse: no such config file: no/such/config.json\n", Text).

error_message_no_config_found_test() ->
    Text = lists:flatten(symbolic_parse:error_message({no_config_found, "/some/dir"})),
    ?assertMatch("parse: no directory given and no .symbolic/config.json found" ++ _, Text).

%% --- resolve_config/1: an explicit -config path wins outright (and must
%% exist); otherwise .symbolic/config.json is discovered by walking up
%% from the current directory — same shape as symbolic_query:resolve_rules/3.

resolve_config_explicit_override_test() ->
    Path = filename:join(["_build", "parse_resolve_config_override_scratch.json"]),
    ok = filelib:ensure_dir(Path),
    ok = file:write_file(Path, <<"{}">>),
    ?assertEqual({ok, Path}, symbolic_parse:resolve_config(Path)),
    ok = file:delete(Path).

resolve_config_explicit_override_missing_is_an_error_test() ->
    ?assertMatch({error, {no_such_config, "no/such/config_zz.json"}},
        symbolic_parse:resolve_config("no/such/config_zz.json")).

%% --- parallel_map/2: the one-process-per-item helper scan_paths/1 and
%% scan/1's own file extraction are both built on (see its own doc
%% comment for why concurrent tree-sitter NIF calls are safe). Two
%% properties worth locking down: results come back in the ORIGINAL
%% item order regardless of which worker finishes first, and a worker
%% crash is re-raised in the caller rather than silently dropped. The
%% timing test proves it's genuinely concurrent, not just
%% spawn-then-immediately-collect-in-a-loop with no real overlap: five
%% 150ms sleeps sequentially would take >=750ms; a generous 500ms bound
%% still leaves 250ms of margin over the fully-parallel ~150ms case. ---

parallel_map_preserves_item_order_test() ->
    ?assertEqual([1, 4, 9, 16, 25],
        symbolic_parse:parallel_map(fun(X) -> X * X end, [1, 2, 3, 4, 5])).

parallel_map_on_empty_list_is_empty_test() ->
    ?assertEqual([], symbolic_parse:parallel_map(fun(X) -> X end, [])).

parallel_map_runs_concurrently_not_sequentially_test() ->
    Fun = fun(_) -> timer:sleep(150) end,
    {ElapsedUs, _Results} = timer:tc(fun() ->
        symbolic_parse:parallel_map(Fun, [a, b, c, d, e])
    end),
    ?assert(ElapsedUs < 500000).

parallel_map_reraises_a_worker_crash_test() ->
    ?assertError({parse_worker_crashed, _},
        symbolic_parse:parallel_map(fun(X) ->
            case X of 2 -> error(boom); _ -> X end
        end, [1, 2, 3])).

%% --- scan_paths/1: merges a directory walk and a directly-named file
%% into one fact set, and reports the same errors scan_one/2's two
%% branches (missing path, unsupported extension) are meant to surface. ---

scan_paths_merges_a_directory_and_a_file_test() ->
    Root = filename:join(["_build", "parse_scan_paths_scratch"]),
    _ = file:del_dir_r(Root),
    ok = filelib:ensure_dir(filename:join([Root, "src", "placeholder"])),
    ok = file:write_file(filename:join([Root, "src", "greeter.erl"]),
        <<"-module(greeter).\nhello() -> ok.\n">>),
    ok = file:write_file(filename:join([Root, "config.toml"]), <<"name = \"greeter\"\n">>),
    try
        {ok, {Files, Facts}} = symbolic_parse:scan_paths(
            [filename:join([Root, "src"]), filename:join([Root, "config.toml"])]),
        ?assertEqual(["config.toml", "greeter.erl"],
            lists:sort([filename:basename(F) || F <- Files])),
        ?assert(lists:member(
            {config_value, list_to_atom(filename:join([Root, "config.toml"])), name, <<"greeter">>, 1},
            Facts)),
        ?assert(lists:any(fun(F) -> element(1, F) =:= defines end, Facts))
    after
        _ = file:del_dir_r(Root)
    end.

scan_paths_reports_a_missing_path_test() ->
    ?assertEqual({error, {no_such_path, "no/such/thing_zz"}},
        symbolic_parse:scan_paths(["no/such/thing_zz"])).

scan_paths_reports_an_unsupported_file_extension_test() ->
    Path = filename:join(["_build", "parse_scan_paths_unsupported_scratch.txt"]),
    ok = filelib:ensure_dir(Path),
    ok = file:write_file(Path, <<"hello\n">>),
    ?assertEqual({error, {unsupported_file, Path}}, symbolic_parse:scan_paths([Path])),
    ok = file:delete(Path).

maybe_store_undefined_is_noop_test() ->
    ?assertEqual(ok, symbolic_parse:maybe_store(undefined, [{defines, foo, 0, <<"()">>, f, 1}])).

maybe_store_writes_to_dets_test() ->
    Path = filename:join(["_build", "parse_maybe_store_test_scratch.dets"]),
    Facts = [{defines, foo, 0, <<"()">>, 'f.erl', 1}],
    ?assertEqual(ok, symbolic_parse:maybe_store(Path, Facts)),
    ?assertEqual(Facts, symbolic_fact_store:read(Path)),
    ok = file:delete(Path).

%% Execution-only (see symbolic_query_tests.erl's print_bindings/1 note)
%% — print_fact/1 is a pure io:format wrapper with no branching logic to
%% assert on beyond "it doesn't crash on a real fact term".
print_fact_does_not_crash_test() ->
    ?assertEqual(
        ok,
        begin symbolic_parse:print_fact({defines, foo, 0, <<"()">>, 'f.erl', 1}), ok end).

%% --- scan/1's directory walk: node_modules/.git always pruned,
%% .gitignore honored — the matching logic itself (globs, anchoring,
%% negation, precedence) is unit-tested in symbolic_gitignore_tests.erl;
%% this is the end-to-end proof that scan/1 actually calls it and that
%% an ignored directory is genuinely never descended into, not just
%% filtered out of the result afterward (real files on disk, not
%% hand-built facts — the whole point is proving the WALK, not the
%% extractor). ---

scan_prunes_node_modules_and_a_gitignore_entry_test() ->
    Root = filename:join(["_build", "parse_scan_ignore_scratch"]),
    _ = file:del_dir_r(Root),
    ok = filelib:ensure_dir(filename:join([Root, "src", "placeholder"])),
    ok = filelib:ensure_dir(filename:join([Root, "node_modules", "some_pkg", "placeholder"])),
    ok = filelib:ensure_dir(filename:join([Root, "vendor", "placeholder"])),
    ok = file:write_file(filename:join(Root, ".gitignore"), <<"vendor/\n">>),
    ok = file:write_file(filename:join([Root, "src", "kept.erl"]),
        <<"-module(kept).\nf() -> ok.\n">>),
    %% node_modules is pruned unconditionally (no .gitignore entry needed
    %% for it at all) — this file must never even be looked at.
    ok = file:write_file(filename:join([Root, "node_modules", "some_pkg", "index.erl"]),
        <<"-module(index).\nbroken(.\n">>),
    ok = file:write_file(filename:join([Root, "vendor", "dropped.erl"]),
        <<"-module(dropped).\nf() -> ok.\n">>),
    try
        {ok, {Files, _Facts}} = symbolic_parse:scan(Root),
        Basenames = lists:sort([filename:basename(F) || F <- Files]),
        ?assertEqual(["kept.erl"], Basenames)
    after
        _ = file:del_dir_r(Root)
    end.
