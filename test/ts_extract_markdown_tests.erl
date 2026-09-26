-module(ts_extract_markdown_tests).
-include_lib("eunit/include/eunit.hrl").

-define(FIXTURE, "test/fixtures/sample.md").

extracts_heading_test() ->
    Facts = ts_extract_markdown:file(?FIXTURE),
    Path = list_to_atom(?FIXTURE),
    ?assert(lists:member({heading, Path, 1, <<"Title">>, 1}, Facts)),
    ?assert(lists:member({heading, Path, 2, <<"Subheading">>, 8}, Facts)),
    ?assert(lists:member({heading, Path, 3, <<"Sub-subheading">>, 14}, Facts)).

extracts_code_block_test() ->
    Facts = ts_extract_markdown:file(?FIXTURE),
    Path = list_to_atom(?FIXTURE),
    ?assert(lists:member({code_block, Path, erlang, 10}, Facts)),
    ?assert(lists:member({code_block, Path, none, 16}, Facts)).

extracts_paragraph_test() ->
    Facts = ts_extract_markdown:file(?FIXTURE),
    Path = list_to_atom(?FIXTURE),
    ?assert(lists:member({paragraph, Path, <<"Some intro text.">>, 3}, Facts)),
    ?assert(lists:member(
        {paragraph, Path, <<"A paragraph that wraps onto a second line.">>, 5},
        Facts)).

no_duplicate_facts_test() ->
    Facts = ts_extract_markdown:file(?FIXTURE),
    ?assertEqual(lists:usort(Facts), lists:sort(Facts)).

extracts_example_defines_test() ->
    Facts = ts_extract_markdown:file(?FIXTURE),
    Path = list_to_atom(?FIXTURE),
    ?assert(lists:member({example_defines, greet, 1, <<"(Name)">>, Path, 23}, Facts)),
    ?assert(lists:member({example_defines, hello, 1, <<"(Name)">>, Path, 26}, Facts)),
    ?assert(lists:member(
        {example_defines, shout, 1, <<"(word: string)">>, Path, 31}, Facts)),
    ?assert(lists:member(
        {example_defines, deploy, undefined, undefined, Path, 37}, Facts)).

extracts_example_calls_test() ->
    Facts = ts_extract_markdown:file(?FIXTURE),
    Path = list_to_atom(?FIXTURE),
    ?assert(lists:member({example_calls, greet, 1, {local, hello, 1}, Path, 24}, Facts)),
    ?assert(lists:member(
        {example_calls, hello, 1, {remote, io, format, 2}, Path, 27}, Facts)),
    ?assert(lists:member(
        {example_calls, shout, 1, {member, word, toUpperCase, 0}, Path, 32}, Facts)),
    ?assert(lists:member(
        {example_calls, deploy, undefined, {local, build, 0}, Path, 38}, Facts)).

unsupported_lang_has_no_example_facts_test() ->
    Facts = ts_extract_markdown:file(?FIXTURE),
    %% The bare (no-language) fence at line 16-18 and the (skipped)
    %% "no lang here" text inside it must never produce example facts.
    ?assertEqual(
        [], [F || {example_defines, _, _, _, _, Line} = F <- Facts, Line >= 16, Line =< 18]).

extracts_setext_heading_test() ->
    Facts = ts_extract_markdown:file("test/fixtures/setext.md"),
    Path = list_to_atom("test/fixtures/setext.md"),
    ?assert(lists:member({heading, Path, 1, <<"Level One">>, 1}, Facts)),
    ?assert(lists:member({heading, Path, 2, <<"Level Two">>, 4}, Facts)).

extracts_section_test() ->
    Facts = ts_extract_markdown:file(?FIXTURE),
    Path = list_to_atom(?FIXTURE),
    %% "# Title" (line 1) is the only level-1 heading in the whole file,
    %% so nothing ever closes its section — it spans the entire
    %% document, exactly like a real CommonMark outline where a level-1
    %% section only ends at the next level-1 heading. "## Subheading"
    %% (line 8) and "### Sub-subheading" (line 14, nested one level
    %% deeper still) both end at line 19, right before "## Examples"
    %% (line 20) — the next heading at or above their own level.
    ?assert(lists:member({section, Path, 1, 1, 63}, Facts)),
    ?assert(lists:member({section, Path, 2, 8, 19}, Facts)),
    ?assert(lists:member({section, Path, 3, 14, 19}, Facts)),
    ?assert(lists:member({section, Path, 2, 20, 41}, Facts)),
    ?assert(lists:member({section, Path, 2, 42, 63}, Facts)).

extracts_list_item_test() ->
    Facts = ts_extract_markdown:file(?FIXTURE),
    Path = list_to_atom(?FIXTURE),
    ?assert(lists:member({list_item, Path, unordered, none, 44}, Facts)),
    ?assert(lists:member({list_item, Path, unordered, none, 45}, Facts)),
    ?assert(lists:member({list_item, Path, ordered, none, 47}, Facts)),
    ?assert(lists:member({list_item, Path, ordered, none, 48}, Facts)),
    ?assert(lists:member({list_item, Path, unordered, unchecked, 50}, Facts)),
    ?assert(lists:member({list_item, Path, unordered, checked, 51}, Facts)).

extracts_blockquote_test() ->
    Facts = ts_extract_markdown:file(?FIXTURE),
    Path = list_to_atom(?FIXTURE),
    %% Both lines' own `>` markers stripped, not just the first line's —
    %% see this predicate's own header-comment note on why that isn't
    %% free from the grammar.
    ?assert(lists:member(
        {blockquote, Path, <<"a quoted line a continued quote">>, 53}, Facts)).

extracts_table_test() ->
    Facts = ts_extract_markdown:file(?FIXTURE),
    Path = list_to_atom(?FIXTURE),
    ?assert(lists:member({table, Path, 56}, Facts)),
    ?assert(lists:member({table_row, Path, 56, 0, 56}, Facts)),
    ?assert(lists:member({table_row, Path, 56, 1, 58}, Facts)),
    ?assert(lists:member({table_row, Path, 56, 2, 59}, Facts)),
    %% Row 0 is the header; the `| ----- | ----- |` delimiter row is
    %% skipped entirely (no table_row/table_cell facts for it at all).
    ?assert(lists:member({table_cell, Path, 56, 0, 0, <<"Col A">>, 56}, Facts)),
    ?assert(lists:member({table_cell, Path, 56, 0, 1, <<"Col B">>, 56}, Facts)),
    ?assert(lists:member({table_cell, Path, 56, 1, 0, <<"x">>, 58}, Facts)),
    ?assert(lists:member({table_cell, Path, 56, 2, 1, <<"2">>, 59}, Facts)),
    ?assertEqual([], [F || {table_row, _, _, _, Line} = F <- Facts, Line =:= 57]).

extracts_indented_code_block_test() ->
    Facts = ts_extract_markdown:file(?FIXTURE),
    Path = list_to_atom(?FIXTURE),
    %% Invisible to code_block/3 before this change — only fenced blocks
    %% were ever queried.
    ?assert(lists:member({code_block, Path, none, 61}, Facts)).

extracts_link_definition_test() ->
    Facts = ts_extract_markdown:file(?FIXTURE),
    Path = list_to_atom(?FIXTURE),
    ?assert(lists:member(
        {link_definition, Path, <<"a ref">>, <<"https://example.com/ref">>,
         <<"Ref Title">>, 63},
        Facts)).
