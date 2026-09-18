-module(ts_extract_typescript_tests).
-include_lib("eunit/include/eunit.hrl").

-define(FIXTURE, "test/fixtures/sample.ts").

extracts_defines_test() ->
    Facts = ts_extract_typescript:file(?FIXTURE),
    Path = list_to_atom(?FIXTURE),
    ?assert(lists:member({defines, foo, Path, 1}, Facts)),
    ?assert(lists:member({defines, other, Path, 6}, Facts)).

extracts_local_call_test() ->
    Facts = ts_extract_typescript:file(?FIXTURE),
    Path = list_to_atom(?FIXTURE),
    ?assert(lists:member({calls, foo, {local, bar}, Path, 2}, Facts)),
    ?assert(lists:member({calls, other, {local, bar}, Path, 7}, Facts)).

extracts_member_call_test() ->
    Facts = ts_extract_typescript:file(?FIXTURE),
    Path = list_to_atom(?FIXTURE),
    ?assert(lists:member(
        {calls, foo, {member, 'this.baz', qux}, Path, 3}, Facts)).

no_duplicate_facts_test() ->
    Facts = ts_extract_typescript:file(?FIXTURE),
    ?assertEqual(lists:usort(Facts), lists:sort(Facts)).

extracts_comment_test() ->
    Facts = ts_extract_typescript:file(?FIXTURE),
    Path = list_to_atom(?FIXTURE),
    ?assert(lists:member(
        {comment, Path, 10, 'Capitalizes the first letter of a word.'}, Facts)),
    ?assert(lists:member(
        {comment, Path, 15, 'standalone comment, not attached to anything'}, Facts)).

extracts_doc_test() ->
    Facts = ts_extract_typescript:file(?FIXTURE),
    Path = list_to_atom(?FIXTURE),
    ?assert(lists:member(
        {doc, capitalize, Path, 11, 'Capitalizes the first letter of a word.'}, Facts)).

standalone_comment_has_no_doc_test() ->
    Facts = ts_extract_typescript:file(?FIXTURE),
    ?assertEqual(
        [], [F || {doc, _, _, 15, _} = F <- Facts]).
