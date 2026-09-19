-module(ts_extract_markdown_tests).
-include_lib("eunit/include/eunit.hrl").

-define(FIXTURE, "test/fixtures/sample.md").

extracts_heading_test() ->
    Facts = ts_extract_markdown:file(?FIXTURE),
    Path = list_to_atom(?FIXTURE),
    ?assert(lists:member({heading, Path, 1, 'Title', 1}, Facts)),
    ?assert(lists:member({heading, Path, 2, 'Subheading', 8}, Facts)),
    ?assert(lists:member({heading, Path, 3, 'Sub-subheading', 14}, Facts)).

extracts_code_block_test() ->
    Facts = ts_extract_markdown:file(?FIXTURE),
    Path = list_to_atom(?FIXTURE),
    ?assert(lists:member({code_block, Path, erlang, 10}, Facts)),
    ?assert(lists:member({code_block, Path, none, 16}, Facts)).

extracts_paragraph_test() ->
    Facts = ts_extract_markdown:file(?FIXTURE),
    Path = list_to_atom(?FIXTURE),
    ?assert(lists:member({paragraph, Path, 'Some intro text.', 3}, Facts)),
    ?assert(lists:member(
        {paragraph, Path, 'A paragraph that wraps onto a second line.', 5},
        Facts)).

no_duplicate_facts_test() ->
    Facts = ts_extract_markdown:file(?FIXTURE),
    ?assertEqual(lists:usort(Facts), lists:sort(Facts)).

extracts_example_defines_test() ->
    Facts = ts_extract_markdown:file(?FIXTURE),
    Path = list_to_atom(?FIXTURE),
    ?assert(lists:member({example_defines, greet, Path, 23}, Facts)),
    ?assert(lists:member({example_defines, hello, Path, 26}, Facts)),
    ?assert(lists:member({example_defines, shout, Path, 31}, Facts)).

extracts_example_calls_test() ->
    Facts = ts_extract_markdown:file(?FIXTURE),
    Path = list_to_atom(?FIXTURE),
    ?assert(lists:member({example_calls, greet, {local, hello}, Path, 24}, Facts)),
    ?assert(lists:member({example_calls, hello, {remote, io, format}, Path, 27}, Facts)),
    ?assert(lists:member(
        {example_calls, shout, {member, word, toUpperCase}, Path, 32}, Facts)).

unsupported_lang_has_no_example_facts_test() ->
    Facts = ts_extract_markdown:file(?FIXTURE),
    %% The bare (no-language) fence at line 16-18 and the (skipped)
    %% "no lang here" text inside it must never produce example facts.
    ?assertEqual(
        [], [F || {example_defines, _, _, Line} = F <- Facts, Line >= 16, Line =< 18]).
