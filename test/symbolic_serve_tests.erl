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
%% Deliberately NOT tested here: run/0, setup_logging/0, register_tools/0
%% — they mutate global logger/erlmcp state (removing the default logger
%% handler process-wide, starting the erlmcp application), which a unit
%% test shouldn't do. Covered instead by the manual stdio smoke tests
%% (docs/erlang-mcp-design.md).

-define(FIXTURES, "test/fixtures").

setup() ->
    {ok, Pid} = symbolic_codebase:start_link(),
    Pid.

teardown(Pid) ->
    unlink(Pid),
    Ref = erlang:monitor(process, Pid),
    exit(Pid, shutdown),
    receive
        {'DOWN', Ref, process, Pid, _Reason} -> ok
    after 1000 ->
        ok
    end.

decode(JsonBinary) ->
    jsx:decode(JsonBinary, [return_maps]).

serve_test_() ->
    {foreach, fun setup/0, fun teardown/1, [
        fun overview_before_parse/1,
        fun query_before_parse_is_friendly_error/1,
        fun parse_reports_summary/1,
        fun parse_missing_dir_is_friendly_error/1,
        fun parse_bad_path_type_is_caught/1,
        fun overview_after_parse_matches_parse/1,
        fun query_all_solutions/1,
        fun query_with_limit_truncates/1,
        fun query_default_limit_is_50/1,
        fun query_undefined_predicate_is_friendly_error/1,
        fun query_malformed_goal_is_error/1,
        fun query_bad_goal_type_is_caught/1
    ]}.

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
        Json = decode(symbolic_serve:handle_parse(#{<<"path">> => list_to_binary(?FIXTURES)})),
        #{<<"ok">> := Ok} = Json,
        ?assertEqual(true, maps:get(<<"loaded">>, Ok)),
        ?assert(maps:get(<<"files">>, Ok) > 0),
        ?assert(maps:get(<<"total_facts">>, Ok) > 0),
        ?assert(lists:member(<<"typescript">>, maps:get(<<"languages">>, Ok)))
    end.

parse_missing_dir_is_friendly_error(_Setup) ->
    fun() ->
        Json = decode(symbolic_serve:handle_parse(#{<<"path">> => <<"no/such/dir_zz">>})),
        ?assertMatch(#{<<"error">> := <<"no such directory: ", _/binary>>}, Json)
    end.

%% to_list/1 has no clause for an integer — a non-binary, non-list `path`
%% hits that function_clause error inside handle_parse/1's try, exercising
%% the catch-all "handlers never crash" path (caught_str/3) rather than
%% needing anything exotic to fail.
parse_bad_path_type_is_caught(_Setup) ->
    fun() ->
        Json = decode(symbolic_serve:handle_parse(#{<<"path">> => 123})),
        ?assertMatch(#{<<"error">> := <<"caught error: function_clause", _/binary>>}, Json)
    end.

overview_after_parse_matches_parse(_Setup) ->
    fun() ->
        ParseJson = decode(symbolic_serve:handle_parse(#{<<"path">> => list_to_binary(?FIXTURES)})),
        OverviewJson = decode(symbolic_serve:handle_overview(#{})),
        #{<<"ok">> := ParseOk} = ParseJson,
        #{<<"ok">> := OverviewOk} = OverviewJson,
        ?assertEqual(maps:get(<<"total_facts">>, ParseOk), maps:get(<<"total_facts">>, OverviewOk)),
        ?assertEqual(maps:get(<<"files">>, ParseOk), maps:get(<<"files">>, OverviewOk))
    end.

query_all_solutions(_Setup) ->
    fun() ->
        _ = symbolic_serve:handle_parse(#{<<"path">> => list_to_binary(?FIXTURES)}),
        Json = decode(symbolic_serve:handle_query(#{<<"goal">> => <<"defines(F, _, _, _, _)">>})),
        ?assertMatch(#{<<"truncated">> := false, <<"count">> := C} when C > 0, Json)
    end.

query_with_limit_truncates(_Setup) ->
    fun() ->
        _ = symbolic_serve:handle_parse(#{<<"path">> => list_to_binary(?FIXTURES)}),
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
        _ = symbolic_serve:handle_parse(#{<<"path">> => list_to_binary(?FIXTURES)}),
        Json = decode(symbolic_serve:handle_query(#{<<"goal">> => <<"defines(F, _, _, _, _)">>})),
        ?assertMatch(#{<<"limit">> := 50}, Json)
    end.

query_undefined_predicate_is_friendly_error(_Setup) ->
    fun() ->
        _ = symbolic_serve:handle_parse(#{<<"path">> => list_to_binary(?FIXTURES)}),
        Json = decode(symbolic_serve:handle_query(#{<<"goal">> => <<"zzz_no_such_pred(X)">>})),
        ?assertMatch(
            #{<<"error">> := <<"no such predicate: zzz_no_such_pred/1", _/binary>>}, Json)
    end.

%% An unbalanced goal is a parse error inside erlog_io, not a clean
%% no-solution — falls through error_str/1's final catch-all clause
%% (jstr(io_lib:format("~p", [Reason]))), not one of the named cases.
query_malformed_goal_is_error(_Setup) ->
    fun() ->
        _ = symbolic_serve:handle_parse(#{<<"path">> => list_to_binary(?FIXTURES)}),
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
