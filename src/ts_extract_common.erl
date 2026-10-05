%%% @doc Tree-walk helpers that several `ts_extract_*` extractors share
%%% VERBATIM — moved here from their per-module copies rather than kept
%%% triplicated.
%%%
%%% The bar for entry is deliberately strict: a helper belongs here only
%%% when every copy was byte-identical (source text AND macro expansion —
%%% e.g. `comment_nodes/2`'s `"(comment) @c"` query is the same literal in
%%% the bash, erlang, and typescript grammars). Helpers that merely LOOK
%%% duplicated but differ per language — `line/1`, `text/2`, `clean_line/1`,
%%% `docs/4`, `branch_fact/4`, and the whole per-node-type walk layer —
%%% stay in their own modules; see docs/tree-sitter-*.md for that split.
%%% The duplicate-name report (`all_duplicate_names/1` in
%%% .symbolic/rules.pl) is what found these.
%%%
%%% Callers reach these by full qualification (`ts_extract_common:...`),
%%% so a module reading its own walkers stays self-contained about
%%% everything that IS language-specific.
-module(ts_extract_common).

-export([comment_nodes/2, is_run_start/1, collect_run/3,
         find_named_child_by_type/4, join_path/2]).

%% Every `comment` node in the tree, via the `(comment) @c` query — the
%% same query string in the bash, erlang, and typescript grammars, which
%% is what makes this shareable (comment attachment is one of the few
%% things every grammar spells identically).
comment_nodes(Lang, Root) ->
    {Q, _, _} = symbolic_ts:query_new(Lang, "(comment) @c"),
    Caps = symbolic_ts:query_capture(Root, Q),
    lists:usort([N || {"c", N} <- Caps]).

%% The FIRST comment of a run — no comment sibling immediately before it.
is_run_start(Node) ->
    case symbolic_ts:node_prev_sibling(Node) of
        undefined -> true;
        Prev -> symbolic_ts:node_type(Prev) =/= "comment"
    end.

%% Walk forward from the first comment in a run, collecting text, until
%% hitting a non-comment sibling (the run's Target — undefined if the
%% run is the last thing in the file).
collect_run(Node, Src, Acc) ->
    Acc1 = [symbolic_ts:node_text(Node, Src) | Acc],
    case symbolic_ts:node_next_sibling(Node) of
        undefined -> {lists:reverse(Acc1), undefined};
        Next ->
            case symbolic_ts:node_type(Next) of
                "comment" -> collect_run(Next, Src, Acc1);
                _ -> {lists:reverse(Acc1), Next}
            end
    end.

%% The Nth named child whose type is exactly Type, or false. The /2
%% wrappers each extractor keeps locally (starting the walk at index 0
%% with the node's own child count) delegate here.
find_named_child_by_type(_Node, _Type, I, Count) when I >= Count ->
    false;
find_named_child_by_type(Node, Type, I, Count) ->
    Child = symbolic_ts:node_named_child(Node, I),
    case symbolic_ts:node_type(Child) of
        Type -> Child;
        _ -> find_named_child_by_type(Node, Type, I + 1, Count)
    end.

%% A dotted config path: ["a", "b"] under prefix "x" is "x.a.b".
join_path("", Key) -> Key;
join_path(Prefix, Key) -> Prefix ++ "." ++ Key.
