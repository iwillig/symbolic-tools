%%% Syntax-level Ruby facts extracted from tree-sitter-ruby.
-module(ts_extract_ruby).
-export([file/1, text/2]).
-import(ts_extract_text, [to_atom/1, to_text/1]).

-define(DEFINITION_QUERY, <<"[(method) (singleton_method)] @definition">>).
-define(CALL_QUERY, <<"(call) @call">>).
-define(COMMENT_QUERY, <<"(comment) @comment">>).

-spec file(file:filename()) -> [tuple()].
file(Path) ->
    {ok, Source} = file:read_file(Path),
    text(Path, Source).

-spec text(file:filename(), binary()) -> [tuple()].
text(Path, Source) when is_binary(Source) ->
    PathAtom = to_atom(Path),
    {ok, Parser} = symbolic_ts:parser_new(),
    {ok, Language} = symbolic_ts:tree_sitter_ruby(),
    true = symbolic_ts:parser_set_language(Parser, Language),
    Tree = symbolic_ts:parser_parse_string(Parser, Source),
    Root = symbolic_ts:tree_root_node(Tree),
    Definitions = captures(Language, Root, ?DEFINITION_QUERY, "definition"),
    Calls = captures(Language, Root, ?CALL_QUERY, "call"),
    Comments = captures(Language, Root, ?COMMENT_QUERY, "comment"),
    lists:usort(
        lists:flatmap(fun(Node) -> definition_facts(Node, Source, PathAtom) end, Definitions) ++
        lists:flatmap(fun(Node) -> call_facts(Node, Source, PathAtom) end, Calls) ++
        [{comment, PathAtom, line(Node), comment_text(Node, Source)} || Node <- Comments]).

definition_facts(Node, Source, Path) ->
    NameNode = symbolic_ts:node_child_by_field_name(Node, <<"name">>),
    ParamsNode = symbolic_ts:node_child_by_field_name(Node, <<"parameters">>),
    case symbolic_ts:node_is_null(NameNode) of
        true -> [];
        false ->
            Name = to_atom(symbolic_ts:node_text(NameNode, Source)),
            case symbolic_ts:node_is_null(ParamsNode) of
                true -> [{defines, Name, 0, <<"()">>, Path, line(Node)}];
                false ->
                    Arity = symbolic_ts:node_named_child_count(ParamsNode),
                    Params = to_text(symbolic_ts:node_text(ParamsNode, Source)),
                    [{defines, Name, Arity, Params, Path, line(Node)}]
            end
    end.

call_facts(Node, Source, Path) ->
    case enclosing_definition(Node) of
        undefined -> [];
        CallerNode ->
            {Caller, CallerArity} = definition_identity(CallerNode, Source),
            MethodNode = symbolic_ts:node_child_by_field_name(Node, <<"method">>),
            ReceiverNode = symbolic_ts:node_child_by_field_name(Node, <<"receiver">>),
            ArgsNode = symbolic_ts:node_child_by_field_name(Node, <<"arguments">>),
            case symbolic_ts:node_is_null(MethodNode) of
                true -> [];
                false ->
                    Name = to_atom(symbolic_ts:node_text(MethodNode, Source)),
                    Arity = case symbolic_ts:node_is_null(ArgsNode) of
                        true -> 0;
                        false -> symbolic_ts:node_named_child_count(ArgsNode)
                    end,
                    Spec = case symbolic_ts:node_is_null(ReceiverNode) of
                        true -> {local, Name, Arity};
                        false -> {member, to_atom(symbolic_ts:node_text(ReceiverNode, Source)), Name, Arity}
                    end,
                    [{calls, Caller, CallerArity, Spec, Path, line(Node)}]
            end
    end.

definition_identity(Node, Source) ->
    NameNode = symbolic_ts:node_child_by_field_name(Node, <<"name">>),
    ParamsNode = symbolic_ts:node_child_by_field_name(Node, <<"parameters">>),
    {to_atom(symbolic_ts:node_text(NameNode, Source)),
     case symbolic_ts:node_is_null(ParamsNode) of
         true -> 0;
         false -> symbolic_ts:node_named_child_count(ParamsNode)
     end}.

enclosing_definition(Node) ->
    Parent = symbolic_ts:node_parent(Node),
    case symbolic_ts:node_is_null(Parent) of
        true -> undefined;
        false ->
            case symbolic_ts:node_type(Parent) of
                "method" -> Parent;
                "singleton_method" -> Parent;
                _ -> enclosing_definition(Parent)
            end
    end.

comment_text(Node, Source) ->
    to_text(string:trim(symbolic_ts:node_text(Node, Source), trailing, "\r\n")).

line(Node) ->
    maps:get(row, symbolic_ts:node_start_point(Node)) + 1.

captures(Language, Root, Query, CaptureName) ->
    {Compiled, _, _} = symbolic_ts:query_new(Language, Query),
    lists:usort([Node || {Name, Node} <- symbolic_ts:query_capture(Root, Compiled),
                         Name =:= CaptureName]).
