%%% Extract Prolog facts from one TOML file via tree-sitter (symbolic_ts).
%%% See docs/tree-sitter-erlang.md §5.
%%%
%%%   config_value(File, Path, Value, Line)
%%%   config_section(File, Path, Line)
%%%
%%% Shared predicate names with ts_extract_json.erl (see that module's
%%% header for why), but no shared code — TOML's `pair` is positional
%%% (first named child is the key part, second is the value; no field
%%% names at all), unlike JSON's field-named `pair`.
%%%
%%% Deliberately out of scope, not silently missing: no recursion into
%%% array elements — a TOML `array` value is captured as one opaque
%%% leaf, same limit and same reasoning as ts_extract_json.erl.
%%%
%%% Confirmed by parsing real samples and walking node_type/1 by hand,
%%% not assumed:
%%%   - `[owner]`/`[[servers]]` (`table`/`table_array_element`) are
%%%     **flat siblings** of `document`, never nested inside each other
%%%     in the tree, even for a dotted header like `[owner.contact]` —
%%%     TOML's dotted-path nesting is a naming convention baked into
%%%     the header's own text, not a tree-structural relationship. So
%%%     a table's header text can be used directly as the Path prefix
%%%     for everything inside it, with no need to track "am I inside
%%%     another table" across sibling boundaries.
%%%   - A `table`/`table_array_element` node's first named child is
%%%     always its header key; every following named child is a `pair`
%%%     (or a nested `inline_table` reached via a pair's value) scoped
%%%     to that table, not a fact about the header itself.
%%%   - `dotted_key` (`a.b.c`) is recursive in the tree
%%%     (`dotted_key("a.b.c") -> [dotted_key("a.b") -> [...], bare_key
%%%     ("c")]`), but its own `node_text/2` already spans the whole
%%%     dotted string — no need to walk the recursive structure, just
%%%     take the raw text once.
%%%   - `pair` always has exactly 2 named children (no interposed
%%%     comment nodes); a `comment` node appears only as a *sibling* of
%%%     `pair`/`table`, never as a pair's child.
%%%   - A `string` leaf's own raw text includes its surrounding quotes
%%%     (unlike JSON, there's no separate unwrapped-content child) —
%%%     stripped by hand. Only single quote-character delimiters
%%%     (`"..."`/`'...'`) are handled; TOML's triple-quoted multi-line
%%%     string form isn't specially unwrapped — a real, minor, and
%%%     deliberately unhandled edge case for a first pass.
-module(ts_extract_toml).
-export([file/1]).

-define(MAX_ATOM_TEXT, 200).

-spec file(file:filename()) -> [tuple()].
file(Path) ->
    {ok, Bin} = file:read_file(Path),
    Src = binary_to_list(Bin),
    {ok, Parser} = symbolic_ts:parser_new(),
    {ok, Lang} = symbolic_ts:tree_sitter_toml(),
    true = symbolic_ts:parser_set_language(Parser, Lang),
    Tree = symbolic_ts:parser_parse_string(Parser, Src),
    Root = symbolic_ts:tree_root_node(Tree),
    PathAtom = list_to_atom(Path),
    Count = symbolic_ts:node_named_child_count(Root),
    TopChildren = [symbolic_ts:node_named_child(Root, I) || I <- lists:seq(0, Count - 1)],
    Facts = lists:flatmap(fun(C) -> walk_top(C, Src, PathAtom) end, TopChildren),
    lists:usort(Facts).

walk_top(Node, Src, PathAtom) ->
    case symbolic_ts:node_type(Node) of
        "pair" -> walk_pair(Node, "", Src, PathAtom);
        "table" -> walk_table(Node, Src, PathAtom);
        "table_array_element" -> walk_table(Node, Src, PathAtom);
        _ -> []
    end.

walk_table(TableNode, Src, PathAtom) ->
    HeaderNode = symbolic_ts:node_named_child(TableNode, 0),
    HeaderPath = symbolic_ts:node_text(HeaderNode, Src),
    Line = line(TableNode),
    Count = symbolic_ts:node_named_child_count(TableNode),
    Contents = [symbolic_ts:node_named_child(TableNode, I) || I <- lists:seq(1, Count - 1)],
    [{config_section, PathAtom, to_atom(HeaderPath), Line}
     | lists:flatmap(fun(C) -> walk_pair(C, HeaderPath, Src, PathAtom) end, Contents)].

walk_pair(PairNode, PathPrefix, Src, PathAtom) ->
    case symbolic_ts:node_type(PairNode) of
        "pair" ->
            KeyNode = symbolic_ts:node_named_child(PairNode, 0),
            ValueNode = symbolic_ts:node_named_child(PairNode, 1),
            KeyText = symbolic_ts:node_text(KeyNode, Src),
            Path = join_path(PathPrefix, KeyText),
            Line = line(PairNode),
            case symbolic_ts:node_type(ValueNode) of
                "inline_table" ->
                    InnerCount = symbolic_ts:node_named_child_count(ValueNode),
                    Inner = [symbolic_ts:node_named_child(ValueNode, I) || I <- lists:seq(0, InnerCount - 1)],
                    [{config_section, PathAtom, to_atom(Path), Line}
                     | lists:flatmap(fun(C) -> walk_pair(C, Path, Src, PathAtom) end, Inner)];
                _ ->
                    [{config_value, PathAtom, to_atom(Path), to_atom(leaf_value(ValueNode, Src)), Line}]
            end;
        _ ->
            []
    end.

leaf_value(Node, Src) ->
    Text = symbolic_ts:node_text(Node, Src),
    case symbolic_ts:node_type(Node) of
        "string" -> strip_quotes(Text);
        _ -> Text
    end.

strip_quotes([Q | Rest] = Text) when Q =:= $"; Q =:= $' ->
    case lists:reverse(Rest) of
        [Q | RevInner] -> lists:reverse(RevInner);
        _ -> Text
    end;
strip_quotes(Text) ->
    Text.

join_path("", Key) -> Key;
join_path(Prefix, Key) -> Prefix ++ "." ++ Key.

line(Node) ->
    maps:get(row, symbolic_ts:node_start_point(Node)) + 1.

%% Erlang atoms are capped at 255 bytes — truncate rather than crash on
%% a long value, same fix already applied in the other extractors.
to_atom(Text) when is_binary(Text) -> to_atom(binary_to_list(Text));
to_atom(Text) when is_list(Text) -> list_to_atom(truncate(Text)).

truncate(Text) when length(Text) > ?MAX_ATOM_TEXT ->
    lists:sublist(Text, ?MAX_ATOM_TEXT) ++ "...";
truncate(Text) ->
    Text.
