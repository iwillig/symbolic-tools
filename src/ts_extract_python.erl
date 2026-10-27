%%% Syntax-only Python facts. Calls are sites, never resolved callees.
%%% In particular, calls with keywords/unpacking, methods, nested definitions,
%%% and lambdas cannot be represented unambiguously by calls/5's name+arity
%%% caller identity, so they do not emit calls/5 facts.
-module(ts_extract_python).
-export([file/1, text/2]).
-import(ts_extract_text, [to_atom/1, to_text/1]).

-define(DEFINITION_QUERY, <<"(function_definition) @definition">>).
-define(CALL_QUERY, <<"(call) @call">>).
-define(COMMENT_QUERY, <<"(comment) @comment">>).

-spec file(file:filename()) -> [tuple()].
file(Path) ->
    {ok, Source} = file:read_file(Path),
    text(Path, Source).

-spec text(file:filename(), binary()) -> [tuple()].
text(Path, Source) when is_binary(Source) ->
    ok = check_encoding(Source),
    PathAtom = to_atom(Path),
    {ok, Parser} = symbolic_ts:parser_new(),
    {ok, Language} = symbolic_ts:tree_sitter_python(),
    true = symbolic_ts:parser_set_language(Parser, Language),
    Tree = symbolic_ts:parser_parse_string(Parser, Source),
    Root = symbolic_ts:tree_root_node(Tree),
    case symbolic_ts:node_has_error(Root) of
        true -> error(invalid_python_syntax);
        false -> ok
    end,
    Definitions = captures(Language, Root, ?DEFINITION_QUERY, "definition"),
    Calls = captures(Language, Root, ?CALL_QUERY, "call"),
    Comments = captures(Language, Root, ?COMMENT_QUERY, "comment"),
    %% Name/arity alone cannot distinguish class methods, nested definitions,
    %% or two top-level definitions with the same identity. Only give calls
    %% the caller identity of a unique, top-level definition.
    TopLevel = [Node || Node <- Definitions, is_top_level(Node)],
    Identities = [definition_identity(Node, Source) || Node <- TopLevel],
    lists:usort(
        [definition_fact(Node, Source, PathAtom) || Node <- Definitions] ++
        lists:flatmap(fun(Node) -> call_facts(Node, Source, PathAtom, Identities) end, Calls) ++
        [{comment, PathAtom, line(Node), to_text(symbolic_ts:node_text(Node, Source))}
         || Node <- Comments]).

check_encoding(Source) ->
    %% Tree-sitter receives the original bytes. A non-UTF-8 source would
    %% make its byte spans and identifier text disagree with Python's parser.
    case unicode:characters_to_binary(Source, utf8, utf8) of
        Source -> check_declaration(Source);
        _ -> error(unsupported_python_encoding)
    end.

check_declaration(Source) ->
    %% Inspect at most two lines, not a list of every line in a large file.
    Header = case binary:match(Source, <<"\n">>) of
        nomatch -> Source;
        {FirstEnd, 1} ->
            case binary:match(Source, <<"\n">>, [{scope, {FirstEnd + 1,
                                                byte_size(Source) - FirstEnd - 1}}]) of
                nomatch -> Source;
                {SecondEnd, 1} -> binary:part(Source, 0, SecondEnd)
            end
    end,
    case re:run(Header, <<"^[ \\t]*\\#[^\\r\\n]*coding[=:][ \\t]*([-\\w.]+)">>,
                [multiline, {capture, [1], binary}]) of
        {match, [Encoding]} ->
            case binary:replace(string:lowercase(Encoding), <<"_">>, <<"-">>, [global]) of
                <<"utf-8">> -> ok;
                <<"utf8">> -> ok;
                _ -> error(unsupported_python_encoding)
            end;
        nomatch -> ok
    end.

definition_fact(Node, Source, Path) ->
    {Name, Arity} = definition_identity(Node, Source),
    ParamsNode = symbolic_ts:node_child_by_field_name(Node, <<"parameters">>),
    {defines, Name, Arity, to_text(symbolic_ts:node_text(ParamsNode, Source)), Path, line(Node)}.

definition_identity(Node, Source) ->
    NameNode = symbolic_ts:node_child_by_field_name(Node, <<"name">>),
    ParamsNode = symbolic_ts:node_child_by_field_name(Node, <<"parameters">>),
    {identifier(NameNode, Source), parameter_count(ParamsNode)}.

parameter_count(ParamsNode) ->
    count_named(ParamsNode, fun(Type) -> Type =/= "positional_separator" andalso
                                           Type =/= "keyword_separator" end).

count_named(Node, Accept) ->
    length([ok || Index <- lists:seq(0, symbolic_ts:node_named_child_count(Node) - 1),
                  Accept(symbolic_ts:node_type(symbolic_ts:node_named_child(Node, Index)))]).

call_facts(Node, Source, Path, Identities) ->
    case enclosing_definition(Node) of
        undefined -> [];
        CallerNode ->
            Identity = definition_identity(CallerNode, Source),
            case is_top_level(CallerNode) andalso within_body(Node, CallerNode) andalso
                 length([Id || Id <- Identities, Id =:= Identity]) =:= 1 of
                false -> [];
                true ->
                    Function = symbolic_ts:node_child_by_field_name(Node, <<"function">>),
                    Arguments = symbolic_ts:node_child_by_field_name(Node, <<"arguments">>),
                    case positional_argument_count(Arguments) of
                        undefined -> [];
                        Arity ->
                            case call_spec(Function, Arity, Source) of
                                undefined -> [];
                                Spec ->
                                    {Caller, CallerArity} = Identity,
                                    [{calls, Caller, CallerArity, Spec, Path, line(Node)}]
                            end
                    end
            end
    end.

within_body(Call, Definition) ->
    Body = symbolic_ts:node_child_by_field_name(Definition, <<"body">>),
    symbolic_ts:node_start_byte(Call) >= symbolic_ts:node_start_byte(Body) andalso
    symbolic_ts:node_end_byte(Call) =< symbolic_ts:node_end_byte(Body).

positional_argument_count(Node) ->
    case symbolic_ts:node_type(Node) of
        "argument_list" ->
            Count = symbolic_ts:node_named_child_count(Node),
            Kinds = [symbolic_ts:node_type(symbolic_ts:node_named_child(Node, I)) ||
                     I <- lists:seq(0, Count - 1)],
            case lists:any(fun(K) -> lists:member(K, ["keyword_argument", "list_splat",
                                                   "dictionary_splat", "parenthesized_list_splat"]) end,
                           Kinds) of
                true -> undefined;
                false -> Count
            end;
        _ -> undefined
    end.

call_spec(Function, Arity, Source) ->
    case symbolic_ts:node_type(Function) of
        "identifier" -> {local, identifier(Function, Source), Arity};
        "attribute" ->
            Object = symbolic_ts:node_child_by_field_name(Function, <<"object">>),
            Method = symbolic_ts:node_child_by_field_name(Function, <<"attribute">>),
            case symbolic_ts:node_type(Object) of
                "identifier" ->
                    {member, identifier(Object, Source), identifier(Method, Source), Arity};
                _ -> undefined
            end;
        _ -> undefined
    end.

enclosing_definition(Node) ->
    Parent = symbolic_ts:node_parent(Node),
    case symbolic_ts:node_is_null(Parent) of
        true -> undefined;
        false ->
            case symbolic_ts:node_type(Parent) of
                "function_definition" -> Parent;
                "lambda" -> undefined;
                _ -> enclosing_definition(Parent)
            end
    end.

is_top_level(Node) ->
    Parent = symbolic_ts:node_parent(Node),
    case symbolic_ts:node_type(Parent) of
        "module" -> true;
        "decorated_definition" -> symbolic_ts:node_type(symbolic_ts:node_parent(Parent)) =:= "module";
        _ -> false
    end.

%% node_text/2 returns raw UTF-8 bytes. list_to_atom/1 on those bytes
%% would turn non-ASCII Python identifiers into mojibake.
identifier(Node, Source) ->
    Chars = unicode:characters_to_list(list_to_binary(symbolic_ts:node_text(Node, Source)), utf8),
    case length(Chars) > 200 of
        true -> list_to_atom(lists:sublist(Chars, 200) ++ "...");
        false -> list_to_atom(Chars)
    end.

line(Node) -> maps:get(row, symbolic_ts:node_start_point(Node)) + 1.

captures(Language, Root, Query, CaptureName) ->
    {Compiled, _, _} = symbolic_ts:query_new(Language, Query),
    lists:usort([Node || {Name, Node} <- symbolic_ts:query_capture(Root, Compiled),
                         Name =:= CaptureName]).
