%%% Extract Prolog facts from one Markdown file via tree-sitter
%%% (symbolic_ts). See docs/tree-sitter-markdown.md.
%%%
%%% Block grammar only — no `link/4` yet. Markdown links only exist as
%%% structured nodes in tree-sitter-markdown's separate *inline* grammar,
%%% which needs a second parse restricted to the byte ranges the block
%%% parse marks as inline content (`ts_parser_set_included_ranges`) — a
%%% real C API function `symbolic_ts` (c_src/symbolic_ts_nif.c) simply
%%% doesn't expose yet, since nothing has needed it so far. See
%%% docs/tree-sitter-markdown.md for the deferred plan.
%%%
%%%   heading(File, Level, Text, Line)
%%%   code_block(File, Lang, Line)     — Lang is `none` for a fence with
%%%                                       no declared language
%%%   paragraph(File, Text, Line)
%%%   example_defines(Function, File, Line)
%%%   example_calls(Caller, CallSpec, File, Line)
%%%
%%% `example_defines`/`example_calls` re-run the real
%%% ts_extract_erlang/ts_extract_typescript/ts_extract_bash extractors
%%% against a fenced code block's own text (only for
%%% `erlang`/`ts`/`typescript`/`sh`/`bash`-tagged fences), with `File`
%%% set to *this* Markdown file rather than a
%%% synthetic path, and `Line` offset to this file's real line numbers.
%%% Deliberately a **different predicate name** than `defines/3`/
%%% `calls/4`, not the same predicate reused with an .md `File` — this
%%% project's fact base is meant to be trustworthy ("a real fact base,
%%% not a grep result"), and blurring "this function really exists" with
%%% "a doc's example happened to show a function of this name" would
%%% undercut that. The split makes the actual motivating query trivial:
%%%
%%%   stale_doc_example(Fun, DocFile, Line) :-
%%%       example_defines(Fun, DocFile, Line),
%%%       \+ defines(Fun, _, _).
%%%
%%% `comment/3`/`doc/4` are deliberately NOT extracted from embedded
%%% snippets — not asked for, and a fragment's own comments add noise
%%% without helping answer "does this still exist for real."
%%%
%%% A snippet is often deliberately partial (elided context, illustrative
%%% pseudocode) — tree-sitter doesn't crash on that, it just produces
%%% `ERROR` nodes for the broken part, so a query over the malformed
%%% portion simply finds nothing there rather than failing the whole
%%% file's extraction.
%%%
%%% Confirmed by parsing a sample and reading node_string/1's output:
%%% an ATX heading (`# Title`) is an `atx_heading` node whose first named
%%% child is an `atx_h<N>_marker` (N = 1..6, giving the level) and whose
%%% `heading_content` field holds the heading text as one opaque `inline`
%%% leaf node — no second parse needed to read it as plain text. A fenced
%%% code block is a `fenced_code_block` node with, only when a language is
%%% declared, an `info_string` named child holding a `language` named
%%% child; a bare ``` fence has no `info_string` child at all. Only ATX
%%% (`#`) headings are handled — this repo's own docs never use the
%%% underline (setext) style, so that's a real rather than hypothetical
%%% scope limit for now.
%%%
%%% A `paragraph` node's own `node_text/2` already spans its full text —
%%% no need to descend into its `inline` child like heading does, since
%%% there's no marker/prefix token to exclude the way `#` needs excluding
%%% from a heading. A soft-wrapped paragraph (multiple source lines, no
%%% blank line between them) is still one `paragraph` node whose raw text
%%% contains embedded newlines — cleaned into one line the same way the
%%% comment/doc extractors clean a multi-line run, so `paragraph/3` stays
%%% one fact per printed line like everything else this project emits.
%%% One real quirk, not filtered out: a list item's own content is also a
%%% `paragraph` node in this grammar, so `paragraph/3` includes list-item
%%% text too — this project extracts facts as the grammar actually names
%%% things, not a hand-picked notion of "real" paragraphs.
-module(ts_extract_markdown).
-export([file/1]).

-define(HEADING_QUERY, "(atx_heading) @h").
-define(CODE_BLOCK_QUERY, "(fenced_code_block) @c").
-define(PARAGRAPH_QUERY, "(paragraph) @p").

-spec file(file:filename()) -> [tuple()].
file(Path) ->
    {ok, Bin} = file:read_file(Path),
    Src = binary_to_list(Bin),
    {ok, Parser} = symbolic_ts:parser_new(),
    {ok, Lang} = symbolic_ts:tree_sitter_markdown(),
    true = symbolic_ts:parser_set_language(Parser, Lang),
    Tree = symbolic_ts:parser_parse_string(Parser, Src),
    Root = symbolic_ts:tree_root_node(Tree),
    PathAtom = list_to_atom(Path),
    Facts =
        headings(Lang, Root, Src, PathAtom) ++
        code_blocks(Lang, Root, Src, PathAtom) ++
        paragraphs(Lang, Root, Src, PathAtom) ++
        example_facts(Lang, Root, Src, Path),
    lists:usort(Facts).

headings(Lang, Root, Src, PathAtom) ->
    {Q, _, _} = symbolic_ts:query_new(Lang, ?HEADING_QUERY),
    Caps = symbolic_ts:query_capture(Root, Q),
    Nodes = lists:usort([N || {"h", N} <- Caps]),
    lists:usort([heading_fact(N, Src, PathAtom) || N <- Nodes]).

heading_fact(Node, Src, PathAtom) ->
    Marker = symbolic_ts:node_named_child(Node, 0),
    Level = heading_level(symbolic_ts:node_type(Marker)),
    Content = symbolic_ts:node_child_by_field_name(Node, "heading_content"),
    Text = to_atom(string:trim(symbolic_ts:node_text(Content, Src))),
    {heading, PathAtom, Level, Text, line(Node)}.

heading_level("atx_h1_marker") -> 1;
heading_level("atx_h2_marker") -> 2;
heading_level("atx_h3_marker") -> 3;
heading_level("atx_h4_marker") -> 4;
heading_level("atx_h5_marker") -> 5;
heading_level("atx_h6_marker") -> 6.

code_blocks(Lang, Root, Src, PathAtom) ->
    {Q, _, _} = symbolic_ts:query_new(Lang, ?CODE_BLOCK_QUERY),
    Caps = symbolic_ts:query_capture(Root, Q),
    Nodes = lists:usort([N || {"c", N} <- Caps]),
    lists:usort([code_block_fact(N, Src, PathAtom) || N <- Nodes]).

code_block_fact(Node, Src, PathAtom) ->
    {code_block, PathAtom, code_lang(Node, Src), line(Node)}.

code_lang(Node, Src) ->
    case find_named_child_by_type(Node, "info_string") of
        false ->
            none;
        InfoString ->
            case find_named_child_by_type(InfoString, "language") of
                false -> none;
                LangNode -> to_atom(symbolic_ts:node_text(LangNode, Src))
            end
    end.

example_facts(Lang, Root, Src, Path) ->
    {Q, _, _} = symbolic_ts:query_new(Lang, ?CODE_BLOCK_QUERY),
    Caps = symbolic_ts:query_capture(Root, Q),
    Nodes = lists:usort([N || {"c", N} <- Caps]),
    lists:usort(lists:flatmap(fun(N) -> example_facts_for_block(N, Src, Path) end, Nodes)).

example_facts_for_block(Node, Src, Path) ->
    case extractor_for_lang(code_lang(Node, Src)) of
        undefined ->
            [];
        ExtractorFun ->
            case find_named_child_by_type(Node, "code_fence_content") of
                false ->
                    [];
                ContentNode ->
                    Snippet = symbolic_ts:node_text(ContentNode, Src),
                    Offset = maps:get(row, symbolic_ts:node_start_point(ContentNode)),
                    RawFacts = ExtractorFun(Path, Snippet),
                    lists:filtermap(
                        fun(F) -> example_fact(F, Offset) end, RawFacts)
            end
    end.

extractor_for_lang(erlang) -> fun ts_extract_erlang:text/2;
extractor_for_lang(ts) -> fun ts_extract_typescript:text/2;
extractor_for_lang(typescript) -> fun ts_extract_typescript:text/2;
extractor_for_lang(sh) -> fun ts_extract_bash:text/2;
extractor_for_lang(bash) -> fun ts_extract_bash:text/2;
extractor_for_lang(_) -> undefined.

example_fact({defines, Name, File, Line}, Offset) ->
    {true, {example_defines, Name, File, Line + Offset}};
example_fact({calls, Caller, CallSpec, File, Line}, Offset) ->
    {true, {example_calls, Caller, CallSpec, File, Line + Offset}};
example_fact(_Other, _Offset) ->
    false.

paragraphs(Lang, Root, Src, PathAtom) ->
    {Q, _, _} = symbolic_ts:query_new(Lang, ?PARAGRAPH_QUERY),
    Caps = symbolic_ts:query_capture(Root, Q),
    Nodes = lists:usort([N || {"p", N} <- Caps]),
    lists:usort([paragraph_fact(N, Src, PathAtom) || N <- Nodes]).

paragraph_fact(Node, Src, PathAtom) ->
    Text = to_atom(clean_text(symbolic_ts:node_text(Node, Src))),
    {paragraph, PathAtom, Text, line(Node)}.

%% Collapse a soft-wrapped paragraph's embedded newlines into a single
%% line, same reasoning as the comment/doc run-cleaning in
%% ts_extract_erlang.erl/ts_extract_typescript.erl.
clean_text(Text) ->
    Lines = string:split(Text, "\n", all),
    Trimmed = [string:trim(L) || L <- Lines],
    NonEmpty = [L || L <- Trimmed, L =/= ""],
    lists:flatten(lists:join(" ", NonEmpty)).

find_named_child_by_type(Node, Type) ->
    find_named_child_by_type(Node, Type, 0, symbolic_ts:node_named_child_count(Node)).

find_named_child_by_type(_Node, _Type, I, Count) when I >= Count ->
    false;
find_named_child_by_type(Node, Type, I, Count) ->
    Child = symbolic_ts:node_named_child(Node, I),
    case symbolic_ts:node_type(Child) of
        Type -> Child;
        _ -> find_named_child_by_type(Node, Type, I + 1, Count)
    end.

line(Node) ->
    maps:get(row, symbolic_ts:node_start_point(Node)) + 1.

%% Erlang atoms are capped at 255 bytes — confirmed by hitting it for
%% real: `symbolic parse` on this project's own readme.md crashed with
%% `system_limit` on a long paragraph's `list_to_atom/1`. Text fields
%% (heading/paragraph text) aren't identifiers, so truncating past a
%% generous length is a safe, simple fix rather than switching every text
%% fact to a binary just to accommodate the rare long one.
-define(MAX_ATOM_TEXT, 200).

to_atom(Text) when is_binary(Text) -> to_atom(binary_to_list(Text));
to_atom(Text) when is_list(Text) -> list_to_atom(truncate(Text)).

truncate(Text) when length(Text) > ?MAX_ATOM_TEXT ->
    lists:sublist(Text, ?MAX_ATOM_TEXT) ++ "...";
truncate(Text) ->
    Text.
