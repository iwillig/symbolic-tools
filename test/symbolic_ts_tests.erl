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
    Tree = symbolic_ts:parser_parse_string(Parser, Source),
    symbolic_ts:tree_root_node(Tree).

node_text_binary_and_list_agree_test() ->
    Source = "f() -> hello_world.\n",
    RootFromList = parse(Source),
    RootFromBinary = parse(Source), %% parser_parse_string itself still needs a list (NIF-side enif_get_string) — both trees are built the same way; only node_text's own SourceCode argument type differs below.
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
