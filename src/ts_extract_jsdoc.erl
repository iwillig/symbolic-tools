%%% Extract structured JSDoc tag facts from one `/** ... */` comment's raw
%%% text, via tree-sitter (symbolic_ts, tree_sitter_jsdoc/0). Not a
%%% standalone file-type extractor like ts_extract_typescript/erlang/bash
%%% (there's no such thing as a `.jsdoc` source file) — JSDoc only ever
%%% occurs embedded inside a TypeScript/JavaScript block comment, so this
%%% is invoked directly from ts_extract_typescript.erl's doc_fact/3, the
%%% same "re-parse a substring through another extractor" pattern
%%% ts_extract_markdown.erl already uses to re-extract fenced code blocks
%%% (example_defines/5, example_calls/5).
%%%
%%%   doc_tag(Function, Arity, TagName, Type, Name, Description, File, Line)
%%%     Function, Arity, File: the SAME attribution as the doc/5 fact this
%%%       tag's enclosing comment produced — the function the comment as a
%%%       whole documents, not anything re-derived from the tag itself.
%%%     TagName: the raw '@'-prefixed tag atom, e.g. '@param', '@returns',
%%%       '@deprecated' — whatever the comment actually wrote (`@return`
%%%       and `@returns` are NOT normalized to one atom; query both if you
%%%       care about either).
%%%     Type: the raw text inside a tag's `{...}` (e.g. <<"number">>,
%%%       <<"Array<string>">>), or the atom `none` if the tag has no type
%%%       annotation at all.
%%%     Name: the tagged expression's raw text — a bare identifier
%%%       (<<"a">>), a qualified/member/path/array expression
%%%       (<<"options.foo">>), or a bracketed optional parameter
%%%       (<<"[b=1]">>, brackets included, exactly as written) — or `none`
%%%       for a tag with no name position at all (@returns, @deprecated).
%%%     Description: the tag's own trailing free-text, already stripped of
%%%       the comment's `/** */`/leading-`*` syntax by the grammar's own
%%%       tokenizer (confirmed empirically — no clean_join/strip_markers
%%%       needed here, unlike doc/5's flattened Text), or `none`.
%%%
%%% One doc_tag/8 fact per @-tag. Line is a REAL file line — the caller
%%% passes StartLine (the comment's own first line in the real file, the
%%% same Line doc/5 itself is keyed one line off of), and every tag's
%%% jsdoc-LOCAL row (0-based, relative to the start of the comment string
%%% handed to this parser, not the file) is added to it. This only works
%%% because Src here is expected to be the exact, unmodified raw comment
%%% text (including its own leading `/**` and trailing `*/`) — the
%%% grammar's own `_begin`/`_end` rules require those delimiters to parse
%%% at all, so this must be called with the pre-clean_join text
%%% ts_extract_typescript:collect_run/3 already collects, never the
%%% flattened doc/5 Text.
%%%
%%% A comment that isn't real JSDoc (no tags, or not even a `/** */` block)
%%% just yields zero `tag`-shaped children — tree-sitter is
%%% error-recoverable, never crashes on malformed/non-matching input, so
%%% no separate validity check is needed before calling tags/5; the
%%% pre-filter (only call this for a single, `/**`-prefixed comment) lives
%%% in the caller, same as every other "decide what a fact means before
%%% trusting a query" judgment call in this codebase.
-module(ts_extract_jsdoc).
-export([tags/5]).
-import(ts_extract_text, [to_atom/1, to_text/1]).

-spec tags(atom(), non_neg_integer(), atom(), pos_integer(), string()) -> [tuple()].
tags(Function, Arity, PathAtom, StartLine, Src) ->
    {ok, Parser} = symbolic_ts:parser_new(),
    {ok, Lang} = symbolic_ts:tree_sitter_jsdoc(),
    true = symbolic_ts:parser_set_language(Parser, Lang),
    Tree = symbolic_ts:parser_parse_string(Parser, Src),
    Root = symbolic_ts:tree_root_node(Tree),
    N = symbolic_ts:node_named_child_count(Root),
    lists:filtermap(
        fun(I) ->
            Child = symbolic_ts:node_named_child(Root, I),
            case symbolic_ts:node_type(Child) of
                "tag" -> {true, tag_fact(Child, Src, Function, Arity, PathAtom, StartLine)};
                _ -> false
            end
        end, lists:seq(0, N - 1)).

%% tag's own children carry no field names at all (confirmed via
%% node-types.json — `"fields": {}`) — each of the four possible slots
%% (type/name/description; tag_name is always present) is told apart
%% purely by node TYPE, one pass over the named children, same idiom as
%% ts_extract_typescript.erl's classify_literal/2.
tag_fact(TagNode, Src, Function, Arity, PathAtom, StartLine) ->
    N = symbolic_ts:node_named_child_count(TagNode),
    Slots = lists:foldl(
        fun(I, Acc) -> classify_tag_child(symbolic_ts:node_named_child(TagNode, I), Src, Acc) end,
        #{tag_name => none, type => none, name => none, description => none},
        lists:seq(0, N - 1)),
    #{tag_name := TagName, type := Type, name := Name, description := Description} = Slots,
    {doc_tag, Function, Arity, TagName, Type, Name, Description, PathAtom,
     StartLine + row(TagNode)}.

%% "expression" is a grammar SUPERTYPE (grammar.js: `supertypes: $ =>
%% [$.expression]`) — it never appears as a concrete node's own type,
%% confirmed empirically by dumping a real parse (`identifier`, not
%% `expression`, is what a plain @param name's node_type/1 actually
%% returns). Its six possible concrete shapes are matched explicitly
%% instead; the grammar guarantees nothing else can occupy that slot.
classify_tag_child(Node, Src, Acc) ->
    case symbolic_ts:node_type(Node) of
        "tag_name" -> Acc#{tag_name => to_atom(symbolic_ts:node_text(Node, Src))};
        "type" -> Acc#{type => to_text(symbolic_ts:node_text(Node, Src))};
        "description" -> Acc#{description => to_text(symbolic_ts:node_text(Node, Src))};
        "optional_identifier" -> Acc#{name => to_text(symbolic_ts:node_text(Node, Src))};
        Expr when Expr =:= "identifier"; Expr =:= "number"; Expr =:= "member_expression";
                  Expr =:= "path_expression"; Expr =:= "qualified_expression";
                  Expr =:= "array_expression" ->
            Acc#{name => to_text(symbolic_ts:node_text(Node, Src))};
        _ -> Acc
    end.

row(Node) -> maps:get(row, symbolic_ts:node_start_point(Node)).
