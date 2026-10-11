%%% Syntax-level facts from tree-sitter-clojure.
%%% This grammar intentionally handles reader-level primitives, not
%%% semantic forms such as defn; do not infer definitions or calls.
-module(ts_extract_clojure).
-export([file/1, text/2]).
-import(ts_extract_text, [to_atom/1, to_text/1]).

-define(COMMENT_QUERY, <<"(comment) @comment">>).

-spec file(file:filename()) -> [tuple()].
file(Path) ->
    {ok, Source} = file:read_file(Path),
    text(Path, Source).

-spec text(file:filename(), binary()) -> [tuple()].
text(Path, Source) when is_binary(Source) ->
    PathAtom = to_atom(Path),
    {ok, Parser} = symbolic_ts:parser_new(),
    {ok, Language} = symbolic_ts:tree_sitter_clojure(),
    true = symbolic_ts:parser_set_language(Parser, Language),
    Tree = symbolic_ts:parser_parse_string(Parser, Source),
    Root = symbolic_ts:tree_root_node(Tree),
    {Query, _, _} = symbolic_ts:query_new(Language, ?COMMENT_QUERY),
    lists:usort([
        {comment, PathAtom, maps:get(row, symbolic_ts:node_start_point(Node)) + 1,
         comment_text(symbolic_ts:node_text(Node, Source))}
        || {"comment", Node} <- symbolic_ts:query_capture(Root, Query)
    ]).

comment_text(Text) ->
    to_text(string:trim(Text, trailing, "\r\n")).
