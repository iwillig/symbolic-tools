%%% Extract Prolog facts from one JSON file via tree-sitter (symbolic_ts).
%%% See docs/tree-sitter-erlang.md §5.
%%%
%%%   config_value(File, Path, Value, Line)
%%%   config_section(File, Path, Line)
%%%
%%% Shared predicate names with ts_extract_toml.erl — "a dotted key path
%%% resolves to this value" is the same question regardless of which
%%% config format asked it, so `config_value(File, 'dependencies.foo',
%%% Value, _)` works the same way whether File is a package.json or a
%%% Cargo.toml. The two modules don't share code, though: JSON's `pair`
%%% has real `key`/`value` fields (usable with
%%% node_child_by_field_name/2 directly), while TOML's `pair` is
%%% positional (see ts_extract_toml.erl) — different enough per-node
%%% logic that forcing a shared walker wouldn't actually simplify
%%% either one, the same reasoning ts_extract_erlang.erl and
%%% ts_extract_typescript.erl already don't share "calls" extraction
%%% code despite both being about call sites.
%%%
%%% Deliberately out of scope, not silently missing: no recursion into
%%% array elements. A JSON `array` value is captured as one opaque leaf
%%% (its own raw source text as Value), not walked element-by-element —
%%% real, useful extension later (numeric path segments, arrays of
%%% objects vs. arrays of scalars), not needed for a first pass.
%%%
%%% Confirmed by parsing samples and walking node_type/1 by hand, not
%%% assumed: `document`'s single named child is the top-level JSON
%%% value (usually `object`); a `string` node's actual text lives in a
%%% `string_content` child (quotes excluded) — an empty string `""` has
%%% no such child at all, handled as the empty string, not a crash.
-module(ts_extract_json).
-export([file/1]).
-import(ts_extract_text, [to_atom/1, to_text/1]).

-spec file(file:filename()) -> [tuple()].
file(Path) ->
    {ok, Bin} = file:read_file(Path),
    %% Src stays a binary — see ts_extract_toml:file/1's identical
    %% comment (symbolic_ts:node_text/2's own comment has the full story).
    Src = Bin,
    SrcList = binary_to_list(Bin),
    {ok, Parser} = symbolic_ts:parser_new(),
    {ok, Lang} = symbolic_ts:tree_sitter_json(),
    true = symbolic_ts:parser_set_language(Parser, Lang),
    Tree = symbolic_ts:parser_parse_string(Parser, SrcList),
    Root = symbolic_ts:tree_root_node(Tree),
    PathAtom = list_to_atom(Path),
    Facts =
        case symbolic_ts:node_named_child_count(Root) of
            0 -> [];
            _ -> walk_value(symbolic_ts:node_named_child(Root, 0), "", Src, PathAtom)
        end,
    lists:usort(Facts).

%% Only `object` has a key path worth walking — a document whose whole
%% top-level value is a bare array/string/number has no key to attach
%% any fact to.
walk_value(Node, PathPrefix, Src, PathAtom) ->
    case symbolic_ts:node_type(Node) of
        "object" -> walk_object(Node, PathPrefix, Src, PathAtom);
        _ -> []
    end.

walk_object(ObjNode, PathPrefix, Src, PathAtom) ->
    Count = symbolic_ts:node_named_child_count(ObjNode),
    Children = [symbolic_ts:node_named_child(ObjNode, I) || I <- lists:seq(0, Count - 1)],
    lists:flatmap(fun(C) -> walk_pair(C, PathPrefix, Src, PathAtom) end, Children).

walk_pair(PairNode, PathPrefix, Src, PathAtom) ->
    case symbolic_ts:node_type(PairNode) of
        "pair" ->
            KeyNode = symbolic_ts:node_child_by_field_name(PairNode, "key"),
            ValueNode = symbolic_ts:node_child_by_field_name(PairNode, "value"),
            Path = join_path(PathPrefix, string_content(KeyNode, Src)),
            Line = line(PairNode),
            case symbolic_ts:node_type(ValueNode) of
                "object" ->
                    [{config_section, PathAtom, to_atom(Path), Line}
                     | walk_object(ValueNode, Path, Src, PathAtom)];
                _ ->
                    [{config_value, PathAtom, to_atom(Path), to_text(leaf_value(ValueNode, Src)), Line}]
            end;
        _ ->
            []
    end.

leaf_value(Node, Src) ->
    case symbolic_ts:node_type(Node) of
        "string" -> string_content(Node, Src);
        _ -> symbolic_ts:node_text(Node, Src)
    end.

string_content(Node, Src) ->
    case find_named_child_by_type(Node, "string_content") of
        false -> "";
        ContentNode -> symbolic_ts:node_text(ContentNode, Src)
    end.

join_path("", Key) -> Key;
join_path(Prefix, Key) -> Prefix ++ "." ++ Key.

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
