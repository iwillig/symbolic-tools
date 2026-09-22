-module(ts_extract_markdown_dispatch_tests).
-include_lib("eunit/include/eunit.hrl").

%% Covers what sample.md doesn't: ATX heading levels 4-6 (it only goes to
%% ###), and the literal "typescript"/"bash" language tags on a fenced
%% block (it only uses the "ts"/"sh" abbreviations) — both map to the
%% same extractor, but extractor_for_lang/1 has a separate clause for
%% each spelling. Written to a scratch file at test-run time, same
%% reasoning as ts_extract_dispatch_tests.erl's scratch .erl file.

-define(SRC,
    "#### H4\n"
    "##### H5\n"
    "###### H6\n"
    "\n"
    "```typescript\n"
    "function foo() {}\n"
    "```\n"
    "\n"
    "```bash\n"
    "build\n"
    "```\n").

setup() ->
    Path = filename:join(["_build", "markdown_dispatch_test_scratch.md"]),
    ok = file:write_file(Path, ?SRC),
    Path.

teardown(Path) ->
    ok = file:delete(Path).

heading_levels_4_to_6_test() ->
    Path = setup(),
    Facts = ts_extract_markdown:file(Path),
    PathAtom = list_to_atom(Path),
    ?assert(lists:member({heading, PathAtom, 4, <<"H4">>, 1}, Facts)),
    ?assert(lists:member({heading, PathAtom, 5, <<"H5">>, 2}, Facts)),
    ?assert(lists:member({heading, PathAtom, 6, <<"H6">>, 3}, Facts)),
    teardown(Path).

literal_typescript_tag_dispatches_test() ->
    Path = setup(),
    Facts = ts_extract_markdown:file(Path),
    PathAtom = list_to_atom(Path),
    ?assert(lists:member({code_block, PathAtom, typescript, 5}, Facts)),
    ?assert(lists:member({example_defines, foo, 0, <<"()">>, PathAtom, 6}, Facts)),
    teardown(Path).

literal_bash_tag_dispatches_test() ->
    Path = setup(),
    Facts = ts_extract_markdown:file(Path),
    PathAtom = list_to_atom(Path),
    ?assert(lists:member({code_block, PathAtom, bash, 9}, Facts)),
    ?assert(lists:member({example_calls, undefined, undefined, {local, build, 0}, PathAtom, 10}, Facts)),
    teardown(Path).
