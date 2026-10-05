-module(symbolic_ts_tests).
-include_lib("eunit/include/eunit.hrl").

%% node_text/2's SourceCode argument used to only ever be a list — a
%% real, severe performance bug found by profiling this project's own
%% largest source file with fprof (see symbolic_ts.erl's own comment on
%% node_text/2): a plain-list slice via string:sub_string/3 walks the
%% list one character at a time to reach even the START of a node's own
%% span, an O(end byte position) cost PER call. A binary supports O(1)
%% slicing via binary:part/3 instead. This module exists specifically to
%% pin down that the two code paths agree byte-for-byte — there was no
%% dedicated test module for symbolic_ts.erl before this, since its NIFs
%% need a real parsed tree to exercise at all, which every other
%% extractor test module already does implicitly; this one exercises
%% node_text/2's OWN two-code-path contract directly instead of only
%% incidentally through an extractor's own assertions.

%% A real parse, not a hand-built Node term — node_is_null/1,
%% node_start_byte/1, etc. are genuine NIFs with no meaningful fake value.
parse(Source) ->
    {ok, Parser} = symbolic_ts:parser_new(),
    {ok, Lang} = symbolic_ts:tree_sitter_erlang(),
    true = symbolic_ts:parser_set_language(Parser, Lang),
    %% parser_parse_string takes a binary (the NIF hands its raw bytes to
    %% tree-sitter); the test sources below are plain string literals.
    Tree = symbolic_ts:parser_parse_string(Parser, list_to_binary(Source)),
    symbolic_ts:tree_root_node(Tree).

node_text_binary_and_list_agree_test() ->
    Source = "f() -> hello_world.\n",
    RootFromList = parse(Source),
    RootFromBinary = parse(Source), %% both trees are built the same way; only node_text/2's own SourceCode argument type differs below.
    Bin = list_to_binary(Source),
    %% Both trees describe the identical source, so the same child-walk
    %% reaches the same node in both.
    FunClauseFromList = symbolic_ts:node_named_child(RootFromList, 0),
    FunClauseFromBinary = symbolic_ts:node_named_child(RootFromBinary, 0),
    TextViaList = symbolic_ts:node_text(FunClauseFromList, Source),
    TextViaBinary = symbolic_ts:node_text(FunClauseFromBinary, Bin),
    ?assertEqual("f() -> hello_world.", TextViaList),
    ?assertEqual(TextViaList, TextViaBinary).

%% A node's own span rarely starts at byte 0 — this pins the OFFSET
%% arithmetic specifically (binary:part/3's Start is 0-indexed;
%% string:sub_string/3's is 1-indexed and inclusive of End — the two
%% must still agree on the same substring despite the different
%% indexing conventions). A leading newline pushes the function clause's
%% own span away from byte 0, without needing to walk deeper into the
%% tree via a guessed child index to get an offset node — see this
%% module's own header comment on why a second, chained
%% node_named_child/2 call is specifically what to avoid here.
node_text_offset_into_the_middle_of_a_binary_test() ->
    Source = "\nf() -> hello_world.\n",
    Root = parse(Source),
    FunClause = symbolic_ts:node_named_child(Root, 0),
    TextViaList = symbolic_ts:node_text(FunClause, Source),
    TextViaBinary = symbolic_ts:node_text(FunClause, list_to_binary(Source)),
    ?assertEqual("f() -> hello_world.", TextViaList),
    ?assertEqual(TextViaList, TextViaBinary).

node_text_is_undefined_for_a_null_node_test() ->
    Source = "f() -> ok.\n",
    Root = parse(Source),
    %% Index far past any real child — node_named_child/2 returns a null
    %% node rather than raising, and node_text/2 must recognize that
    %% regardless of which SourceCode type it was given.
    NullNode = symbolic_ts:node_named_child(Root, 99),
    ?assertEqual(undefined, symbolic_ts:node_text(NullNode, Source)),
    ?assertEqual(undefined, symbolic_ts:node_text(NullNode, list_to_binary(Source))).

%% A null TSNode — node_named_child/2 past the last child returns one,
%% because make_node_term_always/2 deliberately does NOT collapse it to
%% `undefined` (native/symbolic_ts's null_guard, so callers can node_is_null/1
%% themselves) — must make every node accessor return `undefined`
%% without ever reaching C. node_type on a null node used to deref
%% ts_node__subtree(NULL.id) and SIGSEGV the whole BEAM, verified live
%% against a frontmatter-shaped Markdown document
%% (docs/research-yaml-frontmatter-and-tree-sitter-yaml.md §1); the same
%% guard node_text/2 already applies on the Erlang side, extended here
%% to every NIF that dereferences a node.
null_node_accessors_return_undefined_test() ->
    Root = parse("f() -> hello_world.\n"),
    Null = symbolic_ts:node_named_child(Root, 99),
    ?assertEqual(true, symbolic_ts:node_is_null(Null)),
    ?assertEqual(undefined, symbolic_ts:node_type(Null)),
    ?assertEqual(undefined, symbolic_ts:node_start_byte(Null)),
    ?assertEqual(undefined, symbolic_ts:node_end_byte(Null)),
    ?assertEqual(undefined, symbolic_ts:node_start_point(Null)),
    ?assertEqual(undefined, symbolic_ts:node_end_point(Null)),
    ?assertEqual(undefined, symbolic_ts:node_named_child_count(Null)),
    ?assertEqual(undefined, symbolic_ts:node_named_child(Null, 0)),
    ?assertEqual(undefined, symbolic_ts:node_child_by_field_name(Null, <<"name">>)),
    ?assertEqual(undefined, symbolic_ts:node_parent(Null)),
    ?assertEqual(undefined, symbolic_ts:node_next_sibling(Null)),
    ?assertEqual(undefined, symbolic_ts:node_prev_sibling(Null)).

%% A function-clause-heavy source, parsed N times with the tree AND its
%% root node dropped each iteration. The C NIF's free_tree was a
%% deliberate no-op leak (nothing tied a Node resource to the TSTree it
%% pointed into, so actually freeing was a use-after-free — see its own
%% comment): one TSTree per parse, never freed, growing the VM
%% monotonically for exactly as long as a long-running `symbolic serve`
%% session keeps parsing. The Rustler NIF pins each NodeRes to a
%% ResourceArc of its TreeRes, so ts_tree_delete can really run once the
%% last node resource dies — memory must plateau. Measured as OS-level
%% RSS, NOT erlang:memory/1: tree-sitter allocates trees with libc
%% malloc, which erlang:memory/1 cannot see at all — verified directly
%% that the C NIF's leak was invisible there while RSS grew by ~1 GB
%% over this same window. The two-window shape (warmup parses, GC,
%% measure) exists so allocator warmup and binary noise land in the
%% first window, not the measured one.
%% Generator form so eunit's default 5s per-test timeout doesn't kill a
%% test that deliberately burns a few seconds of parse time.
tree_per_parse_does_not_leak_test_() ->
    {timeout, 120, fun tree_per_parse_does_not_leak_body/0}.

tree_per_parse_does_not_leak_body() ->
    Rss = fun() ->
        list_to_integer(string:trim(os:cmd("ps -o rss= -p " ++ os:getpid())))
    end,
    N = 1000,
    Src = iolist_to_binary(
             [begin
                  I = integer_to_binary(Idx),
                  <<"f(", I/binary, ") -> {", I/binary, ", atom_", I/binary, "}.\n">>
              end || Idx <- lists:seq(1, N)]),
    {ok, Parser} = symbolic_ts:parser_new(),
    {ok, Lang} = symbolic_ts:tree_sitter_erlang(),
    true = symbolic_ts:parser_set_language(Parser, Lang),
    Burn = fun() ->
        Tree = symbolic_ts:parser_parse_string(Parser, Src),
        Root = symbolic_ts:tree_root_node(Tree),
        _ = symbolic_ts:node_named_child_count(Root),
        ok
    end,
    lists:foreach(fun(_) -> Burn() end, lists:seq(1, 600)),
    erlang:garbage_collect(),
    Before = Rss(),
    lists:foreach(fun(_) -> Burn() end, lists:seq(1, 600)),
    erlang:garbage_collect(),
    After = Rss(),
    Growth = After - Before,
    %% Measured directly against the retired C NIF: ~1 GB of RSS growth
    %% over this exact window (one leaked TSTree per parse); the fixed
    %% NIF measures a few MB of noise. The threshold sits two orders of
    %% magnitude below the leak, so it can't flake on noise but will
    %% fire on even a partially reintroduced leak.
    ?assert(Growth < 20 * 1024).

%% A source with codepoints > 255. The C NIF decoded its char-list input
%% via enif_get_string ERL_NIF_LATIN1, truncating every such codepoint
%% to its low 8 bits — the parse buffer was then SHORTER than the real
%% file, desynchronizing every subsequent node byte offset from
%% node_text/2's O(1) slice of the file's actual bytes. The Rustler NIF
%% hands tree-sitter the binary's raw bytes, so the comment node's span
%% must slice out exactly the comment's bytes.
utf8_source_byte_offsets_index_the_real_bytes_test() ->
    %% The comment node's span ends before the trailing newline (the
    %% erlang grammar's shape for comment nodes), so the expectation is
    %% the comment text without it.
    Comment = <<"%% 日本語コメント — UTF-8, not Latin-1">>,
    Src = <<Comment/binary, "\nf() -> ok.\n">>,
    CommentWithNewline = <<Comment/binary, "\n">>,
    {ok, Parser} = symbolic_ts:parser_new(),
    {ok, Lang} = symbolic_ts:tree_sitter_erlang(),
    true = symbolic_ts:parser_set_language(Parser, Lang),
    Tree = symbolic_ts:parser_parse_string(Parser, Src),
    Root = symbolic_ts:tree_root_node(Tree),
    {Q, _, error_none} = symbolic_ts:query_new(Lang, <<"(comment) @c">>),
    [{"c", C} | _] = symbolic_ts:query_capture(Root, Q),
    %% node_text/2 returns a raw-byte code list (binary_to_list of its
    %% slice), and binary_to_list/1 of the UTF-8 comment binary is the
    %% same raw bytes — byte-exact agreement is the assertion. The span
    %% excludes the trailing newline, so slice that off the expectation.
    ?assertEqual(binary_to_list(Comment), symbolic_ts:node_text(C, Src)),
    %% And the span really did cover the multibyte run: byte 31 is the
    %% newline, byte 30 the final ASCII "1" — offsets index the real
    %% file bytes, which is what the Latin-1 C NIF desynchronized.
    ?assertEqual($\n, binary:at(Src, symbolic_ts:node_end_byte(C))),
    _ = CommentWithNewline.

%% The C NIF wrapped a NULL TSQuery in a resource term, deferring the
%% crash to the first query_capture dereference, and never checked
%% ts_parser_parse_string's NULL return at all. The Rustler NIF returns
%% Erlang-level terms a caller can catch: `undefined` for the null query,
%% and a catchable badarg on first use — never a VM-wide crash.
invalid_query_returns_catchable_terms_test() ->
    {ok, Lang} = symbolic_ts:tree_sitter_erlang(),
    ?assertMatch({undefined, _, error_node_type},
                 symbolic_ts:query_new(Lang, <<"(this is not a query">>)),
    %% ...and using that result degrades to an ordinary badarg, not a
    %% SIGSEGV: a real parsed node, a non-resource query term.
    {ok, Parser} = symbolic_ts:parser_new(),
    true = symbolic_ts:parser_set_language(Parser, Lang),
    Tree = symbolic_ts:parser_parse_string(Parser, <<"f() -> ok.\n">>),
    Root = symbolic_ts:tree_root_node(Tree),
    ?assertException(error, badarg, symbolic_ts:query_capture(Root, undefined)).
