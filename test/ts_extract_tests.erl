-module(ts_extract_tests).
-include_lib("eunit/include/eunit.hrl").

-define(FIXTURE, "test/fixtures/sample.erl.fixture").

extracts_defines_test() ->
    Facts = ts_extract_erlang:file(?FIXTURE),
    Path = list_to_atom(?FIXTURE),
    ?assert(lists:member({defines, foo, 1, <<"(X)">>, Path, 4}, Facts)),
    ?assert(lists:member({defines, other, 0, <<"()">>, Path, 8}, Facts)).

extracts_arity_for_destructured_args_test() ->
    %% A destructured pattern ({Y,Z}, [H|T]) is still one named child, so
    %% one argument — confirmed empirically against the real grammar, not
    %% assumed. Uses an inline snippet since the fixture has no such case.
    Facts = ts_extract_erlang:text("scratch.erl", "baz(X, {Y,Z}, [H|T]) -> ok."),
    ?assert(lists:member(
        {defines, baz, 3, <<"(X, {Y,Z}, [H|T])">>, 'scratch.erl', 1}, Facts)).

extracts_local_call_test() ->
    Facts = ts_extract_erlang:file(?FIXTURE),
    Path = list_to_atom(?FIXTURE),
    ?assert(lists:member({calls, foo, 1, {local, bar, 1}, Path, 5}, Facts)),
    ?assert(lists:member({calls, other, 0, {local, bar, 1}, Path, 9}, Facts)).

extracts_remote_call_test() ->
    Facts = ts_extract_erlang:file(?FIXTURE),
    Path = list_to_atom(?FIXTURE),
    ?assert(lists:member({calls, foo, 1, {remote, baz, qux, 2}, Path, 6}, Facts)).

extracts_caller_arity_test() ->
    %% CallerArity comes from the enclosing clause's own arity, not the
    %% callee's — foo/1 calling a 2-arg function still reports CallerArity
    %% 1. Confirms the query/1-calls-query/2 false positive is closed:
    %% a call site's CallerArity now identifies which exact overload it's
    %% textually inside.
    Src = "foo(X) -> bar(X, 1).\nfoo(X, Y) -> bar(X, Y).",
    Facts = ts_extract_erlang:text("scratch2.erl", Src),
    ?assert(lists:member(
        {calls, foo, 1, {local, bar, 2}, 'scratch2.erl', 1}, Facts)),
    ?assert(lists:member(
        {calls, foo, 2, {local, bar, 2}, 'scratch2.erl', 2}, Facts)).

no_duplicate_facts_test() ->
    Facts = ts_extract_erlang:file(?FIXTURE),
    ?assertEqual(lists:usort(Facts), lists:sort(Facts)).

extracts_comment_test() ->
    Facts = ts_extract_erlang:file(?FIXTURE),
    Path = list_to_atom(?FIXTURE),
    ?assert(lists:member({comment, Path, 11, <<"Doubles a number.">>}, Facts)),
    ?assert(lists:member(
        {comment, Path, 15, <<"standalone comment, not attached to anything">>}, Facts)).

extracts_doc_test() ->
    Facts = ts_extract_erlang:file(?FIXTURE),
    Path = list_to_atom(?FIXTURE),
    ?assert(lists:member({doc, double, 1, Path, 12, <<"Doubles a number.">>}, Facts)).

standalone_comment_has_no_doc_test() ->
    Facts = ts_extract_erlang:file(?FIXTURE),
    ?assertEqual(
        [], [F || {doc, _, _, _, 15, _} = F <- Facts]).
