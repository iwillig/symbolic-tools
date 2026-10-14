-module(symbolic_serve_tests).
-include_lib("eunit/include/eunit.hrl").

%% Exercises the three MCP tool handlers directly (handle_parse/1,
%% handle_query/1, handle_overview/1) — exported from symbolic_serve.erl
%% for exactly this purpose (see its header comment). Each returns a JSON
%% binary; tests decode it with jsx and assert on the resulting term
%% rather than matching raw binaries, so they don't depend on jsx's key
%% ordering. Same {foreach, setup, teardown} shape as
%% symbolic_codebase_tests.erl, since these handlers need the same
%% registered symbolic_codebase cache running underneath them.
%%
%% run/0 and setup_logging/0 remain manual-smoke-test seams because they
%% start applications and mutate global logger state. register_tools/0 is
%% tested through a mocked erlmcp_stdio registration boundary.

-define(FIXTURES, "test/fixtures").

setup() ->
    Root = filename:absname(filename:join(["_build", "serve_configured_project"])),
    _ = file:del_dir_r(Root),
    ConfigPath = filename:join([Root, ".symbolic", "config.json"]),
    ok = filelib:ensure_dir(ConfigPath),
    ok = file:write_file(ConfigPath,
        <<"{\"paths\": [\"../../test/fixtures\"], "
          "\"database\": \".symbolic/facts.dets\"}">>),
    {ok, OldCwd} = file:get_cwd(),
    {ok, Pid} = symbolic_codebase:start_link(),
    ok = file:set_cwd(Root),
    #{pid => Pid, cwd => OldCwd, root => Root}.

teardown(#{pid := Pid, cwd := OldCwd, root := Root}) ->
    ok = file:set_cwd(OldCwd),
    unlink(Pid),
    Ref = erlang:monitor(process, Pid),
    exit(Pid, shutdown),
    receive
        {'DOWN', Ref, process, Pid, _Reason} -> ok
    after 1000 ->
        ok
    end,
    _ = file:del_dir_r(Root).

decode(JsonBinary) ->
    jsx:decode(JsonBinary, [return_maps]).

parse_tool_schema_has_no_arguments_test() ->
    meck:new(erlmcp_stdio, [non_strict]),
    meck:expect(erlmcp_stdio, add_tool,
        fun(Name, _Description, _Handler, Schema) ->
            put({registered_tool_schema, Name}, Schema),
            ok
        end),
    try
        ok = symbolic_serve:register_tools(),
        Schema = get({registered_tool_schema, <<"parse">>}),
        ?assertEqual(#{}, maps:get(<<"properties">>, Schema)),
        ?assertEqual(false, maps:get(<<"additionalProperties">>, Schema))
    after
        erase({registered_tool_schema, <<"parse">>}),
        meck:unload(erlmcp_stdio)
    end.

parse_rejects_arguments_test() ->
    Json = decode(symbolic_serve:handle_parse(#{<<"path">> => <<"/tmp">>,
        <<"rules">> => <<"custom.pl">>})),
    ?assertMatch(#{<<"error">> := <<"parse accepts no arguments", _/binary>>}, Json).

ask_catalog_tool_is_discoverable_and_returns_shared_catalog_test() ->
    meck:new(erlmcp_stdio, [non_strict]),
    meck:expect(erlmcp_stdio, add_tool,
        fun(Name, Description, Handler, Schema) ->
            put({registered_tool_description, Name}, Description),
            put({registered_tool_schema, Name}, Schema),
            put({registered_tool_handler, Name}, Handler),
            ok
        end),
    try
        ok = symbolic_serve:register_tools(),
        Schema = get({registered_tool_schema, <<"ask_catalog">>}),
        ?assertEqual(#{}, maps:get(<<"properties">>, Schema)),
        ?assertEqual([], maps:get(<<"required">>, Schema)),
        ?assertEqual(false, maps:get(<<"additionalProperties">>, Schema)),
        AskDescription = get({registered_tool_description, <<"ask">>}),
        ?assertNotEqual(nomatch, binary:match(AskDescription, <<"case-insensitive">>)),
        ?assertEqual(nomatch, binary:match(AskDescription, <<"lowercase words only">>)),
        Handler = get({registered_tool_handler, <<"ask_catalog">>}),
        Json = decode(Handler(#{})),
        ?assertEqual(#{<<"ok">> => symbolic_ask_catalog:describe()}, Json),
        ?assertMatch(#{<<"error">> := <<"ask_catalog accepts no arguments">>},
            decode(Handler(#{<<"unexpected">> => true})))
    after
        erase({registered_tool_description, <<"ask">>}),
        erase({registered_tool_schema, <<"ask_catalog">>}),
        erase({registered_tool_handler, <<"ask_catalog">>}),
        meck:unload(erlmcp_stdio)
    end.

serve_test_() ->
    {foreach, fun setup/0, fun teardown/1, [
        fun overview_before_parse/1,
        fun query_before_parse_is_friendly_error/1,
        fun parse_reports_summary/1,
        fun parse_uses_only_configured_paths/1,
        fun parse_persists_configured_database/1,
        fun parse_without_project_config_is_friendly_error/1,
        fun overview_after_parse_matches_parse/1,
        fun query_all_solutions/1,
        fun query_with_limit_truncates/1,
        fun query_default_limit_is_50/1,
        fun query_undefined_predicate_is_friendly_error/1,
        fun query_malformed_goal_is_error/1,
        fun query_bad_goal_type_is_caught/1,
        fun parse_reports_rules_file/1,
        fun overview_reports_rules_file/1,
        fun query_resolves_a_real_derived_predicate/1,
        fun parse_with_broken_project_rules_is_friendly_error/1,
        fun query_with_unknown_path_is_friendly_error/1,
        fun overview_with_unknown_path_is_friendly_error/1,
        fun overview_reports_version_before_parse/1,
        fun parse_reports_version/1,
        fun parse_omits_file_list/1,
        fun ask_before_parse_is_friendly_error/1,
        fun ask_yes_no_call_against_parsed_cache/1,
        fun ask_count_and_enumerate_shapes/1,
        fun ask_ambiguity_returns_candidates_and_matches_cli/1,
        fun ask_wrong_arity_is_unverifiable_not_wrong/1,
        fun ask_prose_returns_evidence/1,
        fun ask_unrecognized_shape_is_friendly_error/1,
        fun ask_with_unknown_path_is_friendly_error/1,
        fun extract_returns_a_claim/1,
        fun search_returns_cached_prose/1,
        fun check_returns_a_verdict/1,
        fun analyze_text_returns_sentence_components/1
    ]}.

parse_uses_only_configured_paths(Setup) ->
    fun() ->
        Root = maps:get(root, Setup),
        UnlistedPath = filename:join(Root, "unlisted.erl"),
        ok = file:write_file(UnlistedPath,
            <<"-module(unlisted_source).\nnot_configured_fn() -> ok.\n">>),
        try
            _ = decode(symbolic_serve:handle_parse(#{})),
            Query = decode(symbolic_serve:handle_query(
                #{<<"goal">> => <<"defines(not_configured_fn, 0, _, _, _)">>})),
            ?assertMatch(#{<<"count">> := 0}, Query)
        after
            _ = file:delete(UnlistedPath)
        end
    end.

parse_persists_configured_database(Setup) ->
    fun() ->
        Root = maps:get(root, Setup),
        DbPath = filename:join([Root, ".symbolic", "facts.dets"]),
        Json = decode(symbolic_serve:handle_parse(#{})),
        ?assertEqual(list_to_binary(DbPath),
            maps:get(<<"database">>, maps:get(<<"ok">>, Json))),
        ?assert(filelib:is_regular(DbPath))
    end.

extract_returns_a_claim(_Setup) ->
    fun() ->
        Json = decode(symbolic_serve:handle_extract(#{<<"sentence">> => <<"foo/1 calls bar/2">>})),
        ?assertMatch(#{<<"ok">> := _}, Json)
    end.

search_returns_cached_prose(_Setup) ->
    fun() ->
        _ = symbolic_serve:handle_parse(#{}),
        Json = decode(symbolic_serve:handle_search(#{<<"query">> => <<"exclamation">>})),
        ?assertMatch(#{<<"ok">> := [_ | _]}, Json)
    end.

check_returns_a_verdict(_Setup) ->
    fun() ->
        _ = symbolic_serve:handle_parse(#{}),
        Json = decode(symbolic_serve:handle_check(#{<<"sentence">> => <<"shout/1 calls capitalize/1">>})),
        ?assertMatch(#{<<"ok">> := #{<<"verdict">> := <<"true">>}}, Json)
    end.

analyze_text_returns_sentence_components(_Setup) ->
    fun() ->
        meck:new(symbolic_analyze),
        meck:expect(symbolic_analyze, run_result, fun(<<"Does foo/2 call bar/1?">>) ->
            {ok, #{<<"sentences">> => [#{
                <<"text">> => <<"Does foo/2 call bar/1?">>,
                <<"tokens">> => [
                    analysis_token(<<"Does">>, <<"do">>, <<"VBZ">>, 0, 4),
                    analysis_token(<<"foo">>, <<"foo">>, <<"NN">>, 5, 8),
                    analysis_token(<<"/">>, <<"/">>, <<"UNKNOWN">>, 8, 9),
                    analysis_token(<<"2">>, <<"2">>, <<"CD">>, 9, 10),
                    analysis_token(<<"call">>, <<"call">>, <<"VBP">>, 11, 15),
                    analysis_token(<<"bar">>, <<"bar">>, <<"NN">>, 16, 19),
                    analysis_token(<<"/">>, <<"/">>, <<"UNKNOWN">>, 19, 20),
                    analysis_token(<<"1">>, <<"1">>, <<"CD">>, 20, 21),
                    analysis_token(<<"?">>, <<"?">>, <<"PCT">>, 21, 22)
                ]}]}}
        end),
        Json = decode(symbolic_serve:handle_analyze_text(#{
            <<"text">> => <<"Does foo/2 call bar/1?">>})),
        ?assertMatch(#{<<"ok">> := #{<<"sentences">> := [_]}}, Json),
        #{<<"ok">> := #{<<"query_frames">> := [Frame]}} = Json,
        ?assertEqual(<<"yes_no">>, maps:get(<<"answer_type">>, Frame)),
        ?assertEqual(<<"calls">>, maps:get(<<"relation">>, Frame)),
        ?assertEqual(<<"foo/2">>, maps:get(<<"text">>, maps:get(<<"subject">>,
            maps:get(<<"arguments">>, Frame)))),
        meck:unload(symbolic_analyze)
    end.

analysis_token(Text, Lemma, Pos, Start, End) ->
    #{
        <<"text">> => Text,
        <<"tags">> => [#{<<"lemma">> => Lemma, <<"pos">> => Pos}],
        <<"chunks">> => [],
        <<"span">> => #{
            <<"byte">> => #{<<"start">> => Start, <<"end">> => End},
            <<"char">> => #{<<"start">> => Start, <<"end">> => End}
        }
    }.

ask_before_parse_is_friendly_error(_Setup) ->
    fun() ->
        Json = decode(symbolic_serve:handle_ask(#{
            <<"question">> => <<"does foo/1 call bar/1?">>})),
        ?assertMatch(#{<<"error">> := _}, Json)
    end.

ask_yes_no_call_against_parsed_cache(#{root := Root}) ->
    fun() ->
        %% The CLI runner and MCP adapter must expose the same shared answer
        %% map for both a positive witness and an empty-evidence negative.
        _ = decode(symbolic_serve:handle_parse(#{})),
        PositiveQuestion = <<"Does shout/1 call capitalize/1?">>,
        PositiveJson = decode(symbolic_serve:handle_ask(#{
            <<"question">> => PositiveQuestion})),
        ?assertMatch(#{<<"ok">> := #{<<"type">> := <<"yes_no">>,
                                     <<"answer">> := true,
                                     <<"evidence">> := [#{
                                         <<"predicate">> := <<"calls">>,
                                         <<"file">> := _, <<"line">> := 19,
                                         <<"fact">> := #{
                                             <<"caller">> := <<"shout/1">>,
                                             <<"call">> := #{
                                                 <<"kind">> := <<"local">>,
                                                 <<"name">> := <<"capitalize">>,
                                                 <<"arity">> := 1}}}]}}, PositiveJson),
        assert_cli_mcp_answer_equal(Root, PositiveQuestion, PositiveJson),
        NegativeQuestion = <<"does shout/1 call foo/1?">>,
        NegativeJson = decode(symbolic_serve:handle_ask(#{
            <<"question">> => NegativeQuestion})),
        ?assertMatch(#{<<"ok">> := #{<<"type">> := <<"yes_no">>,
                                     <<"answer">> := false,
                                     <<"evidence">> := []}}, NegativeJson),
        assert_cli_mcp_answer_equal(Root, NegativeQuestion, NegativeJson)
    end.

assert_cli_mcp_answer_equal(Root, Question, McpJson) ->
    DbPath = filename:join([Root, ".symbolic", "facts.dets"]),
    {ok, CliAnswer} = symbolic_ask:run_result(DbPath, binary_to_list(Question)),
    CliJsonAnswer = decode(jsx:encode(CliAnswer)),
    ?assertEqual(CliJsonAnswer, maps:get(<<"ok">>, McpJson)).

ask_count_and_enumerate_shapes(_Setup) ->
    fun() ->
        _ = decode(symbolic_serve:handle_parse(#{})),
        Count = decode(symbolic_serve:handle_ask(#{
            <<"question">> => <<"how many functions call capitalize/1?">>})),
        ?assertMatch(#{<<"ok">> := #{<<"type">> := <<"count">>,
                                     <<"answer">> := 1}}, Count),
        Enumerate = decode(symbolic_serve:handle_ask(#{
            <<"question">> => <<"who calls capitalize/1?">>})),
        ?assertMatch(#{<<"ok">> := #{<<"type">> := <<"enumerate">>,
                                     <<"answer">> := [<<"shout/1">>]}},
            Enumerate)
    end.

ask_ambiguity_returns_candidates_and_matches_cli(_Setup) ->
    fun() ->
        Root = filename:absname(filename:join(["_build", "serve_ambiguous_ask"])),
        Config = filename:join([Root, ".symbolic", "config.json"]),
        DbPath = filename:join([Root, ".symbolic", "facts.dets"]),
        Source = filename:join([Root, "src", "lookup.ts"]),
        _ = file:del_dir_r(Root),
        ok = filelib:ensure_dir(Config),
        ok = filelib:ensure_dir(Source),
        ok = file:write_file(Config,
            <<"{\"paths\":[\"src\"],\"database\":\".symbolic/facts.dets\"}">>),
        ok = file:write_file(Source,
            <<"function lookup(value: number) {}\nfunction lookup(value: number, other: number) {}\n">>),
        try
            {ok, _} = symbolic_codebase:parse(Root),
            Question = "is lookup defined?",
            {error, {ambiguous, Candidates}} = symbolic_ask:run_result(DbPath, Question),
            CliAnswer = symbolic_ask:ambiguity_answer(Candidates),
            Mcp = decode(symbolic_serve:handle_ask(#{
                <<"question">> => list_to_binary(Question),
                <<"path">> => list_to_binary(Root)})),
            ?assertEqual(#{<<"ok">> => CliAnswer}, Mcp),
            ?assertEqual([1, 2], [maps:get(<<"arity">>, C) || C <- Candidates])
        after
            _ = file:del_dir_r(Root)
        end
    end.

ask_wrong_arity_is_unverifiable_not_wrong(_Setup) ->
    fun() ->
        _ = decode(symbolic_serve:handle_parse(#{})),
        %% capitalize/2 does not exist; capitalize/1 does — the gate must
        %% report the arity mismatch as an answer, not a tool error, and
        %% never answer a count of 0.
        Json = decode(symbolic_serve:handle_ask(#{
            <<"question">> => <<"how many functions call capitalize/2?">>})),
        ?assertMatch(#{<<"ok">> := #{<<"type">> := <<"unverifiable">>,
                                     <<"reason">> := _}}, Json)
    end.

ask_prose_returns_evidence(_Setup) ->
    fun() ->
        _ = decode(symbolic_serve:handle_parse(#{})),
        %% sample.ts's shout JSDoc contains "exclamation mark" — prose
        %% questions come back as ranked evidence, never a verdict.
        Json = decode(symbolic_serve:handle_ask(#{
            <<"question">> => <<"where is exclamation mark documented?">>})),
        ?assertMatch(#{<<"ok">> := #{<<"type">> := <<"prose">>,
                                     <<"evidence">> := [_ | _]}}, Json)
    end.

ask_unrecognized_shape_is_friendly_error(_Setup) ->
    fun() ->
        _ = decode(symbolic_serve:handle_parse(#{})),
        Json = decode(symbolic_serve:handle_ask(#{
            <<"question">> => <<"what is the meaning of life">>})),
        ?assertMatch(#{<<"error">> := <<"unrecognized question shape", _/binary>>},
            Json),
        ?assertEqual(nomatch, binary:match(
            maps:get(<<"error">>, Json), <<"lowercase words only">>))
    end.

ask_with_unknown_path_is_friendly_error(_Setup) ->
    fun() ->
        _ = decode(symbolic_serve:handle_parse(#{})),
        Json = decode(symbolic_serve:handle_ask(#{
            <<"question">> => <<"does foo/1 call bar/1?">>,
            <<"path">> => <<"no/such/path_zz">>})),
        ?assertMatch(#{<<"error">> := _}, Json)
    end.

overview_before_parse(_Setup) ->
    fun() ->
        Json = decode(symbolic_serve:handle_overview(#{})),
        ?assertMatch(#{<<"ok">> := #{<<"loaded">> := false}}, Json)
    end.

query_before_parse_is_friendly_error(_Setup) ->
    fun() ->
        Json = decode(symbolic_serve:handle_query(#{<<"goal">> => <<"defines(F, _, _, _, _)">>})),
        ?assertMatch(#{<<"error">> := <<"no codebase is cached", _/binary>>}, Json)
    end.

parse_reports_summary(_Setup) ->
    fun() ->
        Json = decode(symbolic_serve:handle_parse(#{})),
        #{<<"ok">> := Ok} = Json,
        ?assertEqual(true, maps:get(<<"loaded">>, Ok)),
        ?assert(maps:get(<<"files">>, Ok) > 0),
        ?assert(maps:get(<<"total_facts">>, Ok) > 0),
        ?assert(lists:member(<<"typescript">>, maps:get(<<"languages">>, Ok)))
    end.

parse_without_project_config_is_friendly_error(Setup) ->
    fun() ->
        OldCwd = get_cwd(),
        ok = file:set_cwd("/"),
        try
            Json = decode(symbolic_serve:handle_parse(#{})),
            ?assertMatch(#{<<"error">> := <<"no .symbolic/config.json", _/binary>>}, Json)
        after
            ok = file:set_cwd(OldCwd)
        end,
        ?assertEqual(maps:get(root, Setup), get_cwd())
    end.

overview_after_parse_matches_parse(_Setup) ->
    fun() ->
        ParseJson = decode(symbolic_serve:handle_parse(#{})),
        OverviewJson = decode(symbolic_serve:handle_overview(#{})),
        #{<<"ok">> := ParseOk} = ParseJson,
        #{<<"ok">> := OverviewOk} = OverviewJson,
        ?assertEqual(maps:get(<<"total_facts">>, ParseOk), maps:get(<<"total_facts">>, OverviewOk)),
        ?assertEqual(maps:get(<<"files">>, ParseOk), maps:get(<<"files">>, OverviewOk))
    end.

query_all_solutions(_Setup) ->
    fun() ->
        _ = symbolic_serve:handle_parse(#{}),
        Json = decode(symbolic_serve:handle_query(#{<<"goal">> => <<"defines(F, _, _, _, _)">>})),
        ?assertMatch(#{<<"truncated">> := false, <<"count">> := C} when C > 0, Json)
    end.

query_with_limit_truncates(_Setup) ->
    fun() ->
        _ = symbolic_serve:handle_parse(#{}),
        AllJson = decode(symbolic_serve:handle_query(#{<<"goal">> => <<"defines(F, _, _, _, _)">>})),
        Total = maps:get(<<"count">>, AllJson),
        ?assert(Total > 1),
        OneJson = decode(symbolic_serve:handle_query(
            #{<<"goal">> => <<"defines(F, _, _, _, _)">>, <<"limit">> => 1})),
        ?assertMatch(#{<<"truncated">> := true, <<"count">> := 1, <<"limit">> := 1}, OneJson)
    end.

%% No `limit` key at all in Params -> limit_of/1's fallback clause (50).
query_default_limit_is_50(_Setup) ->
    fun() ->
        _ = symbolic_serve:handle_parse(#{}),
        Json = decode(symbolic_serve:handle_query(#{<<"goal">> => <<"defines(F, _, _, _, _)">>})),
        ?assertMatch(#{<<"limit">> := 50}, Json)
    end.

query_undefined_predicate_is_friendly_error(_Setup) ->
    fun() ->
        _ = symbolic_serve:handle_parse(#{}),
        Json = decode(symbolic_serve:handle_query(#{<<"goal">> => <<"zzz_no_such_pred(X)">>})),
        ?assertMatch(
            #{<<"error">> := <<"no such predicate: zzz_no_such_pred/1", _/binary>>}, Json)
    end.

%% An unbalanced goal is a parse error inside erlog_io, not a clean
%% no-solution — falls through error_str/1's final catch-all clause
%% (jstr(io_lib:format("~p", [Reason]))), not one of the named cases.
query_malformed_goal_is_error(_Setup) ->
    fun() ->
        _ = symbolic_serve:handle_parse(#{}),
        Json = decode(symbolic_serve:handle_query(#{<<"goal">> => <<"defines(">>})),
        ?assertMatch(#{<<"error">> := Err} when is_binary(Err), Json)
    end.

%% maps:get(<<"goal">>, Params) succeeds but to_list/1 has no integer
%% clause — same "caught, never crashes" path as parse_bad_path_type.
query_bad_goal_type_is_caught(_Setup) ->
    fun() ->
        Json = decode(symbolic_serve:handle_query(#{<<"goal">> => 123})),
        ?assertMatch(#{<<"error">> := <<"caught error: function_clause", _/binary>>}, Json)
    end.

%% --- .symbolic/rules.pl parity (symbolic_codebase's rules_file, surfaced) ---

%% test/fixtures lives inside this repo, so parse's discovery walks up to
%% the real .symbolic/rules.pl — rules_file in the JSON response names it.
parse_reports_rules_file(_Setup) ->
    fun() ->
        Json = decode(symbolic_serve:handle_parse(#{})),
        #{<<"ok">> := Ok} = Json,
        ?assertMatch(<<_/binary>>, maps:get(<<"rules_file">>, Ok)),
        ?assert(binary:match(maps:get(<<"rules_file">>, Ok), <<".symbolic/rules.pl">>) =/= nomatch)
    end.

overview_reports_rules_file(_Setup) ->
    fun() ->
        _ = symbolic_serve:handle_parse(#{}),
        Json = decode(symbolic_serve:handle_overview(#{})),
        #{<<"ok">> := Ok} = Json,
        ?assertMatch(<<_/binary>>, maps:get(<<"rules_file">>, Ok))
    end.

%% The running server's own build identity — distinct from anything a
%% parse computes — should be answerable even before anything has been
%% parsed at all, so an agent can check "which commit is this node
%% running" first, before deciding whether to trust cached facts.
overview_reports_version_before_parse(_Setup) ->
    fun() ->
        Json = decode(symbolic_serve:handle_overview(#{})),
        ?assertMatch(#{<<"ok">> := #{<<"loaded">> := false,
                                      <<"vsn">> := <<_/binary>>,
                                      <<"git_sha">> := <<_/binary>>}}, Json)
    end.

%% Same build-identity fields on `parse`'s own response, so upgrading the
%% MCP tool (rebuilding + restarting the server) is visible without a
%% separate `overview` round trip.
parse_reports_version(_Setup) ->
    fun() ->
        Json = decode(symbolic_serve:handle_parse(#{})),
        #{<<"ok">> := Ok} = Json,
        ?assertMatch(<<_/binary>>, maps:get(<<"vsn">>, Ok)),
        ?assertMatch(<<_/binary>>, maps:get(<<"git_sha">>, Ok))
    end.

%% Regression guard for the fix that dropped the full parsed-file-path
%% array from this response (a large project could return thousands of
%% paths and overwhelm the calling harness) — `files` (a count) stays,
%% `file_list` must not reappear.
parse_omits_file_list(_Setup) ->
    fun() ->
        Json = decode(symbolic_serve:handle_parse(#{})),
        #{<<"ok">> := Ok} = Json,
        ?assert(is_integer(maps:get(<<"files">>, Ok))),
        ?assertNot(maps:is_key(<<"file_list">>, Ok))
    end.

%% The concrete proof that the MCP tool an agent actually calls can now
%% answer with the derived-predicate library, not just raw facts: callees/2
%% (from the real .symbolic/rules.pl) against test/fixtures/sample.ts's
%% `foo`, instead of the existence_error a facts-only cache would give.
query_resolves_a_real_derived_predicate(_Setup) ->
    fun() ->
        _ = symbolic_serve:handle_parse(#{}),
        Json = decode(symbolic_serve:handle_query(#{<<"goal">> => <<"callees(foo, Callees)">>})),
        ?assertMatch(#{<<"count">> := C} when C > 0, Json)
    end.

query_with_unknown_path_is_friendly_error(_Setup) ->
    fun() ->
        _ = symbolic_serve:handle_parse(#{}),
        Json = decode(symbolic_serve:handle_query(#{
            <<"goal">> => <<"defines(F, _, _, _, _)">>,
            <<"path">> => <<"no/such/dir_never_parsed_zz">>})),
        ?assertMatch(
            #{<<"error">> := <<"no codebase cached for path no/such/dir_never_parsed_zz", _/binary>>},
            Json)
    end.

overview_with_unknown_path_is_friendly_error(_Setup) ->
    fun() ->
        _ = symbolic_serve:handle_parse(#{}),
        Json = decode(symbolic_serve:handle_overview(
            #{<<"path">> => <<"no/such/dir_never_parsed_zz">>})),
        ?assertMatch(
            #{<<"error">> := <<"no codebase cached for path no/such/dir_never_parsed_zz", _/binary>>},
            Json)
    end.

%% The MCP tool has no per-call rules override. The project's own rules
%% file remains the only rules source for parse.
parse_with_broken_project_rules_is_friendly_error(Setup) ->
    fun() ->
        Root = maps:get(root, Setup),
        _ = decode(symbolic_serve:handle_parse(#{})),
        RulesPath = filename:join([Root, ".symbolic", "rules.pl"]),
        ok = file:write_file(RulesPath, <<"this is not valid Prolog !">>),
        try
            Json = decode(symbolic_serve:handle_parse(#{})),
            ?assertMatch(#{<<"error">> := <<"cannot consult rules", _/binary>>}, Json),
            Query = decode(symbolic_serve:handle_query(
                #{<<"goal">> => <<"defines(shout, 1, _, _, _)">>})),
            ?assertMatch(#{<<"count">> := C} when C > 0, Query)
        after
            _ = file:delete(RulesPath)
        end
    end.

get_cwd() ->
    {ok, Cwd} = file:get_cwd(),
    Cwd.
