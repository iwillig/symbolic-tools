%%% Extract Prolog facts from one TypeScript source file via tree-sitter
%%% (erl_ts). See docs/tree-sitter-erlang.md §5.
%%%
%%% Same shape and same caveats as ts_extract_erlang: facts only
%%% (defines/3, calls/4), caller attribution via node_parent/1 walk-up
%%% rather than a combined query (query_capture/2's per-capture
%%% duplication quirk), dedupe via lists:usort/1.
%%%
%%%   defines(Function, File, Line)
%%%   calls(Caller, local(Callee), File, Line)          — plain calls: bar(x)
%%%   calls(Caller, member(Object, Method), File, Line)  — method calls: obj.method(x)
-module(ts_extract_typescript).
-export([file/1]).

-define(DEF_QUERY, "(function_declaration name: (identifier) @fun_name)").
-define(LOCAL_CALL_QUERY, "(call_expression function: (identifier) @callee)").
-define(MEMBER_CALL_QUERY,
    "(call_expression function: (member_expression "
    "object: (_) @obj property: (property_identifier) @prop))").

-spec file(file:filename()) -> [tuple()].
file(Path) ->
    {ok, Bin} = file:read_file(Path),
    Src = binary_to_list(Bin),
    {ok, Parser} = erl_ts:parser_new(),
    {ok, Lang} = erl_ts:tree_sitter_typescript(),
    true = erl_ts:parser_set_language(Parser, Lang),
    Tree = erl_ts:parser_parse_string(Parser, Src),
    Root = erl_ts:tree_root_node(Tree),
    PathAtom = list_to_atom(Path),
    Facts =
        defines(Lang, Root, Src, PathAtom) ++
        local_calls(Lang, Root, Src, PathAtom) ++
        member_calls(Lang, Root, Src, PathAtom),
    lists:usort(Facts).

defines(Lang, Root, Src, PathAtom) ->
    {Q, _, _} = erl_ts:query_new(Lang, ?DEF_QUERY),
    Caps = erl_ts:query_capture(Root, Q),
    lists:usort([
        {defines, to_atom(erl_ts:node_text(N, Src)), PathAtom, line(N)}
     || {"fun_name", N} <- Caps
    ]).

local_calls(Lang, Root, Src, PathAtom) ->
    {Q, _, _} = erl_ts:query_new(Lang, ?LOCAL_CALL_QUERY),
    Caps = erl_ts:query_capture(Root, Q),
    lists:usort([
        {calls, caller_name(N, Src), {local, to_atom(erl_ts:node_text(N, Src))},
         PathAtom, line(N)}
     || {"callee", N} <- Caps
    ]).

%% Query returns each match's two captures (@obj, @prop) as separate
%% entries, not paired — find each unique property_identifier's own
%% call_expression ancestor and re-derive the object from there, rather
%% than trying to zip the flat capture list (unreliable given the
%% per-capture duplication quirk noted above).
member_calls(Lang, Root, Src, PathAtom) ->
    {Q, _, _} = erl_ts:query_new(Lang, ?MEMBER_CALL_QUERY),
    Caps = erl_ts:query_capture(Root, Q),
    PropNodes = lists:usort([N || {"prop", N} <- Caps]),
    lists:usort([member_call_fact(N, Src, PathAtom) || N <- PropNodes]).

member_call_fact(PropNode, Src, PathAtom) ->
    MemberNode = erl_ts:node_parent(PropNode),
    ObjNode = erl_ts:node_child_by_field_name(MemberNode, "object"),
    CallNode = erl_ts:node_parent(MemberNode),
    {calls, caller_name(CallNode, Src),
     {member, to_atom(erl_ts:node_text(ObjNode, Src)),
      to_atom(erl_ts:node_text(PropNode, Src))},
     PathAtom, line(PropNode)}.

%% Walk up to the nearest enclosing function_declaration to attribute a
%% call site to the function it appears in.
caller_name(Node, Src) ->
    case erl_ts:node_type(Node) of
        "function_declaration" ->
            NameNode = erl_ts:node_child_by_field_name(Node, "name"),
            to_atom(erl_ts:node_text(NameNode, Src));
        _ ->
            Parent = erl_ts:node_parent(Node),
            case erl_ts:node_is_null(Parent) of
                true -> undefined;
                false -> caller_name(Parent, Src)
            end
    end.

line(Node) ->
    maps:get(row, erl_ts:node_start_point(Node)) + 1.

to_atom(Text) when is_list(Text) -> list_to_atom(Text);
to_atom(Text) when is_binary(Text) -> binary_to_atom(Text, utf8).
