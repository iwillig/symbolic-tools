-module(ts_extract_tests).
-include_lib("eunit/include/eunit.hrl").

-define(FIXTURE, "test/fixtures/sample.erl.fixture").

extracts_defines_test() ->
    Facts = ts_extract_erlang:file(?FIXTURE),
    Path = list_to_atom(?FIXTURE),
    ?assert(lists:member({defines, foo, Path, 4}, Facts)),
    ?assert(lists:member({defines, other, Path, 8}, Facts)).

extracts_local_call_test() ->
    Facts = ts_extract_erlang:file(?FIXTURE),
    Path = list_to_atom(?FIXTURE),
    ?assert(lists:member({calls, foo, {local, bar}, Path, 5}, Facts)),
    ?assert(lists:member({calls, other, {local, bar}, Path, 9}, Facts)).

extracts_remote_call_test() ->
    Facts = ts_extract_erlang:file(?FIXTURE),
    Path = list_to_atom(?FIXTURE),
    ?assert(lists:member({calls, foo, {remote, baz, qux}, Path, 6}, Facts)).

no_duplicate_facts_test() ->
    Facts = ts_extract_erlang:file(?FIXTURE),
    ?assertEqual(lists:usort(Facts), lists:sort(Facts)).

extracts_comment_test() ->
    Facts = ts_extract_erlang:file(?FIXTURE),
    Path = list_to_atom(?FIXTURE),
    ?assert(lists:member({comment, Path, 11, 'Doubles a number.'}, Facts)),
    ?assert(lists:member(
        {comment, Path, 15, 'standalone comment, not attached to anything'}, Facts)).

extracts_doc_test() ->
    Facts = ts_extract_erlang:file(?FIXTURE),
    Path = list_to_atom(?FIXTURE),
    ?assert(lists:member({doc, double, Path, 12, 'Doubles a number.'}, Facts)).

standalone_comment_has_no_doc_test() ->
    Facts = ts_extract_erlang:file(?FIXTURE),
    ?assertEqual(
        [], [F || {doc, _, _, 15, _} = F <- Facts]).
