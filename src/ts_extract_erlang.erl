%%% Extract Prolog facts from one Erlang source file via tree-sitter
%%% (erl_ts). See docs/tree-sitter-erlang.md.
%%%
%%% Facts (deliberately simpler than the original design sketch — no
%%% module name or arity yet, see the Phase 1 plan notes):
%%%   defines(Function, File, Line)
%%%   calls(Caller, local(Callee), File, Line)
%%%   calls(Caller, remote(Module, Function), File, Line)
%%%
%%% Caller/callee attribution walks up node_parent/1 to the nearest
%%% enclosing function_clause, rather than a single combined query —
%%% erl_ts's query_capture/2 duplicates each match once per named capture
%%% in the pattern (verified empirically: a 2-capture query returns every
%%% match twice, a 3-capture query three times), so a query correlating
%%% caller+callee in one pattern can't be trusted without deduplication
%%% logic anyway. Walking the tree directly sidesteps that quirk entirely.
-module(ts_extract_erlang).
-export([file/1]).

-define(DEF_QUERY, "(function_clause name: (atom) @fun_name)").
-define(LOCAL_CALL_QUERY, "(call expr: (atom) @callee)").
-define(REMOTE_CALL_QUERY, "(call expr: (remote) @call)").

-spec file(file:filename()) -> [tuple()].
file(Path) ->
    {ok, Bin} = file:read_file(Path),
    Src = binary_to_list(Bin),
    {ok, Parser} = erl_ts:parser_new(),
    {ok, Lang} = erl_ts:tree_sitter_erlang(),
    true = erl_ts:parser_set_language(Parser, Lang),
    Tree = erl_ts:parser_parse_string(Parser, Src),
    Root = erl_ts:tree_root_node(Tree),
    PathAtom = list_to_atom(Path),
    Facts =
        defines(Lang, Root, Src, PathAtom) ++
        local_calls(Lang, Root, Src, PathAtom) ++
        remote_calls(Lang, Root, Src, PathAtom),
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

remote_calls(Lang, Root, Src, PathAtom) ->
    {Q, _, _} = erl_ts:query_new(Lang, ?REMOTE_CALL_QUERY),
    Caps = erl_ts:query_capture(Root, Q),
    lists:usort([
        remote_call_fact(N, Src, PathAtom)
     || {"call", N} <- Caps
    ]).

remote_call_fact(RemoteNode, Src, PathAtom) ->
    ModNode = erl_ts:node_child_by_field_name(RemoteNode, "module"),
    ModAtomNode = erl_ts:node_child_by_field_name(ModNode, "module"),
    FunNode = erl_ts:node_child_by_field_name(RemoteNode, "fun"),
    {calls, caller_name(RemoteNode, Src),
     {remote, to_atom(erl_ts:node_text(ModAtomNode, Src)),
      to_atom(erl_ts:node_text(FunNode, Src))},
     PathAtom, line(RemoteNode)}.

%% Walk up to the nearest enclosing function_clause to attribute a call
%% site to the function it appears in.
caller_name(Node, Src) ->
    case erl_ts:node_type(Node) of
        "function_clause" ->
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
