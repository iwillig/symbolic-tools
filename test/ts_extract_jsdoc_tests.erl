-module(ts_extract_jsdoc_tests).
-include_lib("eunit/include/eunit.hrl").

%% One fact per real @-tag; `document`'s own leading free-text
%% `description` (before any tag) produces no fact of its own here — it's
%% exactly what doc/5's flattened Text already covers, from the caller's
%% side, not this module's job to duplicate.
extracts_param_and_returns_tags_test() ->
    Src =
        "/**\n"
        " * Adds two numbers together.\n"
        " * @param {number} a - the first number\n"
        " * @returns {number} the sum\n"
        " */",
    Facts = ts_extract_jsdoc:tags(add, 2, some_file, 10, Src),
    ?assert(lists:member(
        {doc_tag, add, 2, '@param', <<"number">>, <<"a">>, <<"- the first number">>,
         some_file, 12},
        Facts)),
    ?assert(lists:member(
        {doc_tag, add, 2, '@returns', <<"number">>, none, <<"the sum">>, some_file, 13},
        Facts)).

%% [b=1] — an optional_identifier, brackets and default value both kept
%% verbatim in Name, exactly as the comment wrote it.
extracts_optional_param_test() ->
    Src =
        "/**\n"
        " * @param {number} [b=1] - the second number\n"
        " */",
    Facts = ts_extract_jsdoc:tags(f, 1, some_file, 1, Src),
    ?assert(lists:member(
        {doc_tag, f, 1, '@param', <<"number">>, <<"[b=1]">>, <<"- the second number">>,
         some_file, 2},
        Facts)).

%% @deprecated has no type and no name position at all — both `none`, not
%% a crash or a missing fact.
extracts_tag_with_no_type_or_name_test() ->
    Src = "/**\n * @deprecated use add2 instead\n */",
    Facts = ts_extract_jsdoc:tags(f, 0, some_file, 5, Src),
    ?assert(lists:member(
        {doc_tag, f, 0, '@deprecated', none, none, <<"use add2 instead">>, some_file, 6},
        Facts)).

%% A JSDoc block with a free-text description and no @-tags at all (the
%% common case — most doc comments never use a single tag) yields zero
%% doc_tag facts, not an error.
no_tags_yields_empty_list_test() ->
    Src = "/**\n * Just a plain description, no tags.\n */",
    ?assertEqual([], ts_extract_jsdoc:tags(f, 0, some_file, 1, Src)).

%% Line is a real file line: StartLine (the comment's own first line, as
%% the caller would pass it) plus the tag's own row WITHIN the comment
%% string, confirmed against a tag on the block's 3rd line.
tag_line_is_offset_from_start_line_test() ->
    Src =
        "/**\n"                      %% row 0 -> StartLine
        " * A description line.\n"   %% row 1 -> StartLine + 1
        " * @since 1.0\n"            %% row 2 -> StartLine + 2
        " */",
    [Fact] = ts_extract_jsdoc:tags(f, 0, some_file, 100, Src),
    ?assertEqual({doc_tag, f, 0, '@since', none, none, <<"1.0">>, some_file, 102}, Fact).
