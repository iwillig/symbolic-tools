-module(symbolic_gitignore_tests).
-include_lib("eunit/include/eunit.hrl").

%% --- parse_line/1 ---

parse_line_skips_a_blank_line_test() ->
    ?assertEqual(skip, symbolic_gitignore:parse_line(<<>>)).

parse_line_skips_a_comment_test() ->
    ?assertEqual(skip, symbolic_gitignore:parse_line(<<"# a comment">>)).

parse_line_skips_a_bare_bang_test() ->
    %% `!` alone (no pattern after it) doesn't take the negation branch
    %% (guarded on a non-empty Rest) — it falls through and is treated
    %% as an ordinary, literal one-character pattern instead, matching a
    %% path literally named "!". Not a crash, not a no-op.
    {ok, Rule} = symbolic_gitignore:parse_line(<<"!">>),
    ?assert(symbolic_gitignore:ignored("!", false, [Rule])),
    ?assertNot(symbolic_gitignore:ignored("other", false, [Rule])).

parse_line_trims_trailing_whitespace_test() ->
    {ok, Rule} = symbolic_gitignore:parse_line(<<"*.log  ">>),
    ?assert(symbolic_gitignore:ignored("app.log", false, [Rule])).

%% --- ignored/3: unanchored (no "/" in the pattern) matches a basename
%% at any depth ---

unanchored_pattern_matches_at_the_root_test() ->
    {ok, Rule} = symbolic_gitignore:parse_line(<<"*.beam">>),
    ?assert(symbolic_gitignore:ignored("foo.beam", false, [Rule])).

unanchored_pattern_matches_several_directories_deep_test() ->
    {ok, Rule} = symbolic_gitignore:parse_line(<<"*.beam">>),
    ?assert(symbolic_gitignore:ignored("a/b/c/foo.beam", false, [Rule])).

unanchored_pattern_does_not_match_a_different_extension_test() ->
    {ok, Rule} = symbolic_gitignore:parse_line(<<"*.beam">>),
    ?assertNot(symbolic_gitignore:ignored("foo.erl", false, [Rule])).

%% --- ignored/3: a leading "/" anchors to the scan root ---

leading_slash_anchors_to_the_root_test() ->
    {ok, Rule} = symbolic_gitignore:parse_line(<<"/build">>),
    ?assert(symbolic_gitignore:ignored("build", true, [Rule])),
    ?assertNot(symbolic_gitignore:ignored("nested/build", true, [Rule])).

%% --- ignored/3: an internal "/" (no leading one) also anchors, per
%% real gitignore semantics — only a pattern with NO "/" at all matches
%% at any depth. ---

internal_slash_anchors_to_the_root_test() ->
    {ok, Rule} = symbolic_gitignore:parse_line(<<"docs/generated">>),
    ?assert(symbolic_gitignore:ignored("docs/generated", true, [Rule])),
    ?assertNot(symbolic_gitignore:ignored("nested/docs/generated", true, [Rule])).

%% --- ignored/3: a trailing "/" is directory-only ---

trailing_slash_is_directory_only_test() ->
    {ok, Rule} = symbolic_gitignore:parse_line(<<"vendor/">>),
    ?assert(symbolic_gitignore:ignored("vendor", true, [Rule])),
    ?assertNot(symbolic_gitignore:ignored("vendor", false, [Rule])).

%% --- ignored/3: "**" ---

double_star_matches_any_depth_including_zero_test() ->
    {ok, Rule} = symbolic_gitignore:parse_line(<<"a/**/b">>),
    ?assert(symbolic_gitignore:ignored("a/b", false, [Rule])),
    ?assert(symbolic_gitignore:ignored("a/x/y/b", false, [Rule])),
    ?assertNot(symbolic_gitignore:ignored("a/b/c", false, [Rule])).

%% --- ignored/3: later rules win, same as real git — a later "!"
%% un-ignores what an earlier, broader rule ignored. ---

later_negation_overrides_an_earlier_broader_rule_test() ->
    {ok, R1} = symbolic_gitignore:parse_line(<<"*.log">>),
    {ok, R2} = symbolic_gitignore:parse_line(<<"!keep.log">>),
    ?assertNot(symbolic_gitignore:ignored("keep.log", false, [R1, R2])),
    ?assert(symbolic_gitignore:ignored("drop.log", false, [R1, R2])).

%% A later PLAIN rule (not negated) can also re-ignore something an
%% earlier negation had un-ignored — order matters both ways.
later_plain_rule_overrides_an_earlier_negation_test() ->
    {ok, R1} = symbolic_gitignore:parse_line(<<"!keep.log">>),
    {ok, R2} = symbolic_gitignore:parse_line(<<"*.log">>),
    ?assert(symbolic_gitignore:ignored("keep.log", false, [R1, R2])).

%% --- load/1: node_modules and .git are ignored even with NO
%% .gitignore file at all — the whole point of shipping them as
%% defaults rather than leaving them to a project's own file. ---

load_ignores_node_modules_with_no_gitignore_file_test() ->
    Dir = filename:join(["_build", "gitignore_test_scratch_no_file"]),
    _ = file:del_dir_r(Dir),
    ok = filelib:ensure_dir(filename:join([Dir, "placeholder"])),
    try
        Rules = symbolic_gitignore:load(Dir),
        ?assert(symbolic_gitignore:ignored("node_modules", true, Rules)),
        ?assert(symbolic_gitignore:ignored(".git", true, Rules)),
        ?assertNot(symbolic_gitignore:ignored("src", true, Rules))
    after
        _ = file:del_dir_r(Dir)
    end.

%% --- load/1: a real .gitignore on disk is actually read and its rules
%% actually applied, defaults and all. ---

load_reads_a_real_gitignore_file_test() ->
    Dir = filename:join(["_build", "gitignore_test_scratch_with_file"]),
    _ = file:del_dir_r(Dir),
    ok = filelib:ensure_dir(filename:join([Dir, "placeholder"])),
    ok = file:write_file(filename:join(Dir, ".gitignore"), <<"vendor/\n*.log\n">>),
    try
        Rules = symbolic_gitignore:load(Dir),
        ?assert(symbolic_gitignore:ignored("vendor", true, Rules)),
        ?assert(symbolic_gitignore:ignored("debug.log", false, Rules)),
        ?assert(symbolic_gitignore:ignored("node_modules", true, Rules)),
        ?assertNot(symbolic_gitignore:ignored("src", true, Rules))
    after
        _ = file:del_dir_r(Dir)
    end.
