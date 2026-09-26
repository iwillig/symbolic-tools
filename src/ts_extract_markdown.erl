%%% Extract Prolog facts from one Markdown file via tree-sitter
%%% (symbolic_ts). See docs/tree-sitter-markdown.md.
%%%
%%% Block grammar only — no inline-link `link/4` yet. A markdown link
%%% *use* (`[text](url)`) only exists as a structured node in
%%% tree-sitter-markdown's separate *inline* grammar, which needs a
%%% second parse restricted to the byte ranges the block parse marks as
%%% inline content (`ts_parser_set_included_ranges`) — a real C API
%%% function `symbolic_ts` (c_src/symbolic_ts_nif.c) simply doesn't
%%% expose yet, since nothing has needed it so far. See
%%% docs/tree-sitter-markdown.md for the deferred plan. A link
%%% *definition* (`[label]: url "title"`) is a different story — that's
%%% a real block-grammar node (`link_reference_definition`), so
%%% `link_definition/5` below needs none of that.
%%%
%%%   heading(File, Level, Text, Line)        — ATX and setext
%%%   section(File, Level, StartLine, EndLine) — a heading plus
%%%                                       everything under it, nested by
%%%                                       level (the grammar's own
%%%                                       `section` node)
%%%   code_block(File, Lang, Line)     — Lang is `none` for a fence with
%%%                                       no declared language, or for an
%%%                                       indented code block (which
%%%                                       never declares one)
%%%   paragraph(File, Text, Line)
%%%   list_item(File, Ordered, Checked, Line) — Ordered is `ordered` or
%%%                                       `unordered`; Checked is
%%%                                       `checked`/`unchecked` (a GFM
%%%                                       task-list item) or `none`
%%%   table(File, Line)
%%%   table_row(File, TableLine, RowIndex, Line) — RowIndex 0 is the
%%%                                       header row; the delimiter row
%%%                                       (`---|---`) is not its own fact
%%%   table_cell(File, TableLine, Row, Col, Text, Line)
%%%   blockquote(File, Text, Line)
%%%   link_definition(File, Label, Destination, Title, Line) — Title is
%%%                                       `none` when the definition has
%%%                                       no title
%%%   example_defines(Function, Arity, Params, File, Line)
%%%   example_calls(Caller, CallerArity, CallSpec, File, Line)
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
%%%       example_defines(Fun, _, _, DocFile, Line),
%%%       \+ defines(Fun, _, _, _, _).
%%%
%%% `comment/3`/`doc/5` are deliberately NOT extracted from embedded
%%% snippets — not asked for, and a fragment's own comments add noise
%%% without helping answer "does this still exist for real."
%%%
%%% A snippet is often deliberately partial (elided context, illustrative
%%% pseudocode) — tree-sitter doesn't crash on that, it just produces
%%% `ERROR` nodes for the broken part, so a query over the malformed
%%% portion simply finds nothing there rather than failing the whole
%%% file's extraction.
%%%
%%% Confirmed by parsing a sample fixture and recursively walking it with
%%% node_type/1 + node_named_child_count/1 + node_named_child/2 (there is
%%% no node_string/1 here despite an earlier version of this comment
%%% saying so — `symbolic_ts` never exported one; the standalone
%%% `tree-sitter` CLI, this project's original exploration tool per
%%% docs/tree-sitter-markdown.md §6, isn't installed either, so a
%%% throwaway recursive dump was the real tool used this time), not
%%% assumed from the upstream grammar's own docs:
%%%
%%% An ATX heading (`# Title`) is an `atx_heading` node whose first named
%%% child is an `atx_h<N>_marker` (N = 1..6, giving the level) and whose
%%% `heading_content` field holds the heading text as one opaque `inline`
%%% leaf node — no second parse needed to read it as plain text. A setext
%%% heading (`Title` on one line, `===`/`---` on the next) is shaped
%%% differently — a `setext_heading` node whose children are a
%%% `paragraph` (the text) followed by a `setext_h1_underline` or
%%% `setext_h2_underline` (the level; setext only ever has two levels) —
%%% found by type, not by a field name, since it has none. A fenced code
%%% block is a `fenced_code_block` node with, only when a language is
%%% declared, an `info_string` named child holding a `language` named
%%% child; a bare ``` fence has no `info_string` child at all. An
%%% indented code block (`indented_code_block`) never has one either — it
%%% never declares a language at all — so the same `code_lang/2` lookup
%%% already handles it for free, giving `Lang = none`.
%%%
%%% A `section` node wraps a heading and everything under it, nesting by
%%% level (confirmed against a real ATX fixture: a `# H1`/`## H2`/`# H1b`
%%% sequence produces `document -> [section(H1) -> [..., section(H2)],
%%% section(H1b)]`, the `## H2` section nested INSIDE the `# H1` one, not
%%% a sibling) — exactly a CommonMark document outline. Getting a
%%% section's `EndLine` needed a real end point, which `symbolic_ts` only
%%% had for the start (`node_start_point/1`); `node_end_point/1`
%%% (`c_src/symbolic_ts_nif.c`) mirrors that wrapper exactly, one more
%%% call to the same already-linked tree-sitter C API (`ts_node_end_point`,
%%% the counterpart to `ts_node_start_point` that wrapper already calls) —
%%% not a new grammar, not a new dependency.
%%% `EndLine` is that end point's row used AS a 1-based number with no
%%% `+1` (unlike every `StartLine` here, which does) — tree-sitter's own
%%% end point is the 0-based row of the first line NOT included, which is
%%% numerically identical to the 1-based number of the LAST line that is.
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
%%% things, not a hand-picked notion of "real" paragraphs. `list_item/4`
%%% below is additive, not a replacement for that: a `list_item` node's
%%% children are its marker (`list_marker_dot`/`_parenthesis` for an
%%% ordered item, `list_marker_minus`/`_plus`/`_star` for an unordered
%%% one), optionally a `task_list_marker_checked`/`_unchecked` right after
%%% it for a GFM task item, then the same `paragraph` child `paragraph/3`
%%% already sees independently — found by child type, not fixed position,
%%% since a soft-wrapped item adds a trailing `block_continuation` child
%%% that shifts anything found by index.
%%%
%%% A `pipe_table` node's named children are one `pipe_table_header`
%%% (always first, always exactly one), one `pipe_table_delimiter_row`
%%% (the `---|---` alignment row — no cell text worth a fact), then zero
%%% or more `pipe_table_row`; header and data rows both hold
%%% `pipe_table_cell` children directly, trailing padding included in
%%% each cell's own `node_text/2` (trimmed). `RowIndex` counts the header
%%% as row 0 and skips the delimiter row entirely, so `table_row/4`'s
%%% indices land exactly on what a person reading the rendered table
%%% would call row 0, 1, 2, ...
%%%
%%% A `block_quote` node's own `node_text/2` is NOT clean multi-line
%%% content the way `paragraph/3` gets for free: only the marker on the
%%% quote's OWN first line is a separate sibling (`block_quote_marker`);
%%% every continuation line's own `> ` is folded into the following
%%% `block_continuation` node's text and stays embedded in whatever
%%% contains it (confirmed directly — a two-line quote's inner
%%% `paragraph` text came back as `"first line\n> second line"`, the
%%% second line's marker very much still there). `blockquote/3` strips a
%%% leading `>` (and one following space, if present) from every line
%%% itself, rather than trusting the grammar to have already done it.
%%%
%%% A `link_reference_definition` node's children are `link_label`
%%% (brackets included in its own text — `"[foo]"`, not `"foo"`),
%%% `link_destination`, and an optional `link_title` (present only when
%%% the definition actually gives one; quote/paren characters included in
%%% its own text the same way brackets are in the label's). All three get
%%% their wrapping punctuation stripped before becoming a fact — nobody
%%% asking `link_definition(_, "foo", _, _, _)` wants to have typed the
%%% brackets themselves to match.
-module(ts_extract_markdown).
-export([file/1]).
-import(ts_extract_text, [to_atom/1, to_text/1]).

-define(HEADING_QUERY, "[(atx_heading) (setext_heading)] @h").
-define(SECTION_QUERY, "(section) @s").
-define(CODE_BLOCK_QUERY, "[(fenced_code_block) (indented_code_block)] @c").
-define(FENCED_QUERY, "(fenced_code_block) @c").
-define(PARAGRAPH_QUERY, "(paragraph) @p").
-define(LIST_ITEM_QUERY, "(list_item) @li").
-define(TABLE_QUERY, "(pipe_table) @t").
-define(BLOCKQUOTE_QUERY, "(block_quote) @bq").
-define(LINK_DEFINITION_QUERY, "(link_reference_definition) @ld").

-spec file(file:filename()) -> [tuple()].
file(Path) ->
    {ok, Bin} = file:read_file(Path),
    %% Src stays a binary — see ts_extract_toml:file/1's identical
    %% comment (symbolic_ts:node_text/2's own comment has the full
    %% story). example_facts/4 below forwards a node_text/2-extracted
    %% fenced-code-block's own text (still a list — see that function's
    %% own type) into e.g. ts_extract_erlang:text/2, which already
    %% accepts either form.
    Src = Bin,
    SrcList = binary_to_list(Bin),
    {ok, Parser} = symbolic_ts:parser_new(),
    {ok, Lang} = symbolic_ts:tree_sitter_markdown(),
    true = symbolic_ts:parser_set_language(Parser, Lang),
    Tree = symbolic_ts:parser_parse_string(Parser, SrcList),
    Root = symbolic_ts:tree_root_node(Tree),
    PathAtom = list_to_atom(Path),
    Facts =
        headings(Lang, Root, Src, PathAtom) ++
        sections(Lang, Root, Src, PathAtom) ++
        code_blocks(Lang, Root, Src, PathAtom) ++
        paragraphs(Lang, Root, Src, PathAtom) ++
        list_items(Lang, Root, Src, PathAtom) ++
        tables(Lang, Root, Src, PathAtom) ++
        blockquotes(Lang, Root, Src, PathAtom) ++
        link_definitions(Lang, Root, Src, PathAtom) ++
        example_facts(Lang, Root, Src, Path),
    lists:usort(Facts).

headings(Lang, Root, Src, PathAtom) ->
    {Q, _, _} = symbolic_ts:query_new(Lang, ?HEADING_QUERY),
    Caps = symbolic_ts:query_capture(Root, Q),
    Nodes = lists:usort([N || {"h", N} <- Caps]),
    lists:usort([heading_fact(N, Src, PathAtom) || N <- Nodes]).

heading_fact(Node, Src, PathAtom) ->
    Level = heading_level_of(Node),
    Text = to_text(string:trim(heading_text(Node, Src))),
    {heading, PathAtom, Level, Text, line(Node)}.

%% ATX (`# Title`): first named child is the `atx_h<N>_marker`, and the
%% level lives on the HEADING node's own type — heading_level_of/1 below
%% needs to tell the two shapes apart first, so the marker-only helper
%% stays separate.
heading_text(Node, Src) ->
    case symbolic_ts:node_type(Node) of
        "atx_heading" ->
            Content = symbolic_ts:node_child_by_field_name(Node, "heading_content"),
            symbolic_ts:node_text(Content, Src);
        "setext_heading" ->
            %% No field name — found by type instead (see this module's
            %% header comment). The underline sibling holds no text worth
            %% reading; the `paragraph` child is the whole heading text.
            Content = find_named_child_by_type(Node, "paragraph"),
            symbolic_ts:node_text(Content, Src)
    end.

%% Shared by heading_fact/3 and section_fact/3 (a section's Level is its
%% own leading heading's level) — takes either an atx_heading or a
%% setext_heading node directly, not a marker.
heading_level_of(Node) ->
    case symbolic_ts:node_type(Node) of
        "atx_heading" ->
            Marker = symbolic_ts:node_named_child(Node, 0),
            atx_heading_level(symbolic_ts:node_type(Marker));
        "setext_heading" ->
            setext_heading_level(Node)
    end.

atx_heading_level("atx_h1_marker") -> 1;
atx_heading_level("atx_h2_marker") -> 2;
atx_heading_level("atx_h3_marker") -> 3;
atx_heading_level("atx_h4_marker") -> 4;
atx_heading_level("atx_h5_marker") -> 5;
atx_heading_level("atx_h6_marker") -> 6.

setext_heading_level(Node) ->
    case find_named_child_by_type(Node, "setext_h1_underline") of
        false -> 2;   %% only two setext levels exist; not h1 means h2
        _ -> 1
    end.

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

sections(Lang, Root, _Src, PathAtom) ->
    {Q, _, _} = symbolic_ts:query_new(Lang, ?SECTION_QUERY),
    Caps = symbolic_ts:query_capture(Root, Q),
    Nodes = lists:usort([N || {"s", N} <- Caps]),
    lists:usort([section_fact(N, PathAtom) || N <- Nodes]).

%% A section's own first named child is always its heading (atx_heading
%% or setext_heading) — the rest is whatever falls under it, nested
%% sections for subheadings included (see this module's header comment).
section_fact(Node, PathAtom) ->
    Heading = symbolic_ts:node_named_child(Node, 0),
    Level = heading_level_of(Heading),
    EndLine = maps:get(row, symbolic_ts:node_end_point(Node)),
    {section, PathAtom, Level, line(Node), EndLine}.

%% Fenced blocks only, deliberately narrower than code_blocks/4's own
%% query — an indented code block never declares a language, so
%% extractor_for_lang/1 would always return `undefined` for one anyway;
%% asking only for what could possibly match skips the wasted lookup
%% rather than relying on that fallthrough.
example_facts(Lang, Root, Src, Path) ->
    {Q, _, _} = symbolic_ts:query_new(Lang, ?FENCED_QUERY),
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

example_fact({defines, Name, Arity, Params, File, Line}, Offset) ->
    {true, {example_defines, Name, Arity, Params, File, Line + Offset}};
example_fact({calls, Caller, CallerArity, CallSpec, File, Line}, Offset) ->
    {true, {example_calls, Caller, CallerArity, CallSpec, File, Line + Offset}};
example_fact(_Other, _Offset) ->
    false.

paragraphs(Lang, Root, Src, PathAtom) ->
    {Q, _, _} = symbolic_ts:query_new(Lang, ?PARAGRAPH_QUERY),
    Caps = symbolic_ts:query_capture(Root, Q),
    Nodes = lists:usort([N || {"p", N} <- Caps]),
    lists:usort([paragraph_fact(N, Src, PathAtom) || N <- Nodes]).

paragraph_fact(Node, Src, PathAtom) ->
    Text = to_text(clean_text(symbolic_ts:node_text(Node, Src))),
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

named_children(Node) ->
    Count = symbolic_ts:node_named_child_count(Node),
    [symbolic_ts:node_named_child(Node, I) || I <- lists:seq(0, Count - 1)].

list_items(Lang, Root, _Src, PathAtom) ->
    {Q, _, _} = symbolic_ts:query_new(Lang, ?LIST_ITEM_QUERY),
    Caps = symbolic_ts:query_capture(Root, Q),
    Nodes = lists:usort([N || {"li", N} <- Caps]),
    lists:usort([list_item_fact(N, PathAtom) || N <- Nodes]).

list_item_fact(Node, PathAtom) ->
    {list_item, PathAtom, list_item_ordered(Node), list_item_checked(Node), line(Node)}.

%% `.`/`)` markers (`1.`, `1)`) are an ordered item; `-`/`+`/`*` are not —
%% found by type since this project extracts facts as the grammar names
%% things, same reasoning as paragraph/3's own list-item quirk above.
list_item_ordered(Node) ->
    case find_named_child_by_type(Node, "list_marker_dot") of
        false ->
            case find_named_child_by_type(Node, "list_marker_parenthesis") of
                false -> unordered;
                _ -> ordered
            end;
        _ -> ordered
    end.

%% A GFM task item (`- [ ] ...` / `- [x] ...`) has one more named child,
%% right after its list marker, that a plain item doesn't: `none` for
%% every ordinary item, of either list kind.
list_item_checked(Node) ->
    case find_named_child_by_type(Node, "task_list_marker_checked") of
        false ->
            case find_named_child_by_type(Node, "task_list_marker_unchecked") of
                false -> none;
                _ -> unchecked
            end;
        _ -> checked
    end.

tables(Lang, Root, Src, PathAtom) ->
    {Q, _, _} = symbolic_ts:query_new(Lang, ?TABLE_QUERY),
    Caps = symbolic_ts:query_capture(Root, Q),
    Nodes = lists:usort([N || {"t", N} <- Caps]),
    lists:usort(lists:flatmap(fun(N) -> table_facts(N, Src, PathAtom) end, Nodes)).

table_facts(Node, Src, PathAtom) ->
    TableLine = line(Node),
    RowNodes = [C || C <- named_children(Node),
                     lists:member(symbolic_ts:node_type(C),
                                  ["pipe_table_header", "pipe_table_row"])],
    [{table, PathAtom, TableLine} | row_facts(RowNodes, 0, Src, PathAtom, TableLine)].

%% RowIndex counts the header as row 0 (it's always first — see this
%% module's header comment) and skips the delimiter row entirely, since
%% it names no real column data.
row_facts([], _Index, _Src, _PathAtom, _TableLine) ->
    [];
row_facts([RowNode | Rest], Index, Src, PathAtom, TableLine) ->
    RowFact = {table_row, PathAtom, TableLine, Index, line(RowNode)},
    CellFacts = cell_facts(named_children(RowNode), 0, Src, PathAtom, TableLine, Index),
    [RowFact | CellFacts] ++ row_facts(Rest, Index + 1, Src, PathAtom, TableLine).

cell_facts([], _Col, _Src, _PathAtom, _TableLine, _Row) ->
    [];
cell_facts([CellNode | Rest], Col, Src, PathAtom, TableLine, Row) ->
    Text = to_text(string:trim(symbolic_ts:node_text(CellNode, Src))),
    Fact = {table_cell, PathAtom, TableLine, Row, Col, Text, line(CellNode)},
    [Fact | cell_facts(Rest, Col + 1, Src, PathAtom, TableLine, Row)].

blockquotes(Lang, Root, Src, PathAtom) ->
    {Q, _, _} = symbolic_ts:query_new(Lang, ?BLOCKQUOTE_QUERY),
    Caps = symbolic_ts:query_capture(Root, Q),
    Nodes = lists:usort([N || {"bq", N} <- Caps]),
    lists:usort([blockquote_fact(N, Src, PathAtom) || N <- Nodes]).

blockquote_fact(Node, Src, PathAtom) ->
    Text = to_text(strip_blockquote(symbolic_ts:node_text(Node, Src))),
    {blockquote, PathAtom, Text, line(Node)}.

%% Every line of a block_quote node's own raw text starts with `>` — only
%% the first line's marker is excluded by the grammar (a separate
%% block_quote_marker sibling); a continuation line's own `>` stays
%% embedded in whatever contains it (see this module's header comment).
%% Strip a leading `>` (and one following space, if present) from every
%% line before the usual multi-line collapse.
strip_blockquote(Text) ->
    Lines = string:split(Text, "\n", all),
    Stripped = [strip_quote_marker(string:trim(L, leading)) || L <- Lines],
    Trimmed = [string:trim(L) || L <- Stripped],
    NonEmpty = [L || L <- Trimmed, L =/= ""],
    lists:flatten(lists:join(" ", NonEmpty)).

strip_quote_marker([$>, $\s | Rest]) -> Rest;
strip_quote_marker([$> | Rest]) -> Rest;
strip_quote_marker(Line) -> Line.

link_definitions(Lang, Root, Src, PathAtom) ->
    {Q, _, _} = symbolic_ts:query_new(Lang, ?LINK_DEFINITION_QUERY),
    Caps = symbolic_ts:query_capture(Root, Q),
    Nodes = lists:usort([N || {"ld", N} <- Caps]),
    lists:usort([link_definition_fact(N, Src, PathAtom) || N <- Nodes]).

link_definition_fact(Node, Src, PathAtom) ->
    LabelNode = find_named_child_by_type(Node, "link_label"),
    DestNode = find_named_child_by_type(Node, "link_destination"),
    Label = to_text(strip_wrapping(symbolic_ts:node_text(LabelNode, Src), $[, $])),
    Destination = to_text(strip_wrapping(symbolic_ts:node_text(DestNode, Src), $<, $>)),
    Title = case find_named_child_by_type(Node, "link_title") of
        false -> none;
        TitleNode -> to_text(strip_title(symbolic_ts:node_text(TitleNode, Src)))
    end,
    {link_definition, PathAtom, Label, Destination, Title, line(Node)}.

%% link_label/link_destination's own raw text includes its wrapping
%% punctuation (`"[foo]"`, not `"foo"`; an angle-bracketed destination
%% keeps its `<`/`>` too) — stripped here rather than left for every
%% caller to redo. A destination given without angle brackets (the
%% common case, confirmed against a real fixture) has no wrapping
%% punctuation to strip, so this is a no-op for it.
strip_wrapping([Open | Rest], Open, Close) ->
    case lists:reverse(Rest) of
        [Close | RevInner] -> lists:reverse(RevInner);
        _ -> Rest
    end;
strip_wrapping(Text, _Open, _Close) ->
    Text.

%% link_title's own raw text keeps whichever of the three CommonMark
%% title quotings was used: "..."/'...'/(...) — the closing character
%% differs only for the paren form.
strip_title(Text) ->
    case Text of
        [$" | _] -> strip_wrapping(Text, $", $");
        [$' | _] -> strip_wrapping(Text, $', $');
        [$( | _] -> strip_wrapping(Text, $(, $));
        _ -> Text
    end.

line(Node) ->
    maps:get(row, symbolic_ts:node_start_point(Node)) + 1.
