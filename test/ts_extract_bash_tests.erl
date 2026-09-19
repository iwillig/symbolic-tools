-module(ts_extract_bash_tests).
-include_lib("eunit/include/eunit.hrl").

-define(FIXTURE, "test/fixtures/sample.sh").

extracts_defines_test() ->
    Facts = ts_extract_bash:file(?FIXTURE),
    Path = list_to_atom(?FIXTURE),
    ?assert(lists:member({defines, deploy, Path, 2}, Facts)),
    ?assert(lists:member({defines, build, Path, 7}, Facts)).

extracts_local_call_test() ->
    Facts = ts_extract_bash:file(?FIXTURE),
    Path = list_to_atom(?FIXTURE),
    ?assert(lists:member({calls, deploy, {local, build}, Path, 3}, Facts)),
    ?assert(lists:member({calls, deploy, {local, scp}, Path, 4}, Facts)),
    ?assert(lists:member({calls, build, {local, echo}, Path, 8}, Facts)).

extracts_comment_test() ->
    Facts = ts_extract_bash:file(?FIXTURE),
    Path = list_to_atom(?FIXTURE),
    ?assert(lists:member(
        {comment, Path, 1, 'Deploys the app to the given environment.'}, Facts)),
    ?assert(lists:member(
        {comment, Path, 11, 'standalone comment, not attached to anything'}, Facts)).

extracts_doc_test() ->
    Facts = ts_extract_bash:file(?FIXTURE),
    Path = list_to_atom(?FIXTURE),
    ?assert(lists:member(
        {doc, deploy, Path, 2, 'Deploys the app to the given environment.'}, Facts)).

standalone_comment_has_no_doc_test() ->
    Facts = ts_extract_bash:file(?FIXTURE),
    ?assertEqual(
        [], [F || {doc, _, _, 11, _} = F <- Facts]).

no_duplicate_facts_test() ->
    Facts = ts_extract_bash:file(?FIXTURE),
    ?assertEqual(lists:usort(Facts), lists:sort(Facts)).
