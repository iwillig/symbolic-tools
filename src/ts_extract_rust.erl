%%% Syntax-level Rust facts extracted from tree-sitter-rust.
%%%
%%% Existing cross-language facts:
%%%   defines(Function, Arity, Params, File, Line)
%%%   calls(Caller, CallerArity, CallSpec, File, Line)
%%%
%%% Additive Rust-specific facts:
%%%   rust_function(Id, Name, Arity, Params, Kind, Context, Visibility, File, Line)
%%%   rust_module(Name, ParentContext, Form, Visibility, File, Line)
%%%   rust_use(PathText, Context, File, Line)
%%%   rust_visibility(Id, Kind, Visibility, File, Line)
%%%   rust_call(Id, CallerFunctionId, CallSpec, File, Line)
%%%   rust_macro(Id, Name, CallerFunctionId, File, Line)
%%%
%%% These are syntax facts, not resolved symbols. Rust call expressions
%%% use {path, Text, Arity} for all supported callee shapes; no claim is
%%% made that the path resolves to a local definition.
%%% The Rust-specific function fact preserves context and source identity,
%%% because `defines/5` alone cannot distinguish equally named items in
%%% separate modules or impl blocks.
-module(ts_extract_rust).
-export([file/1, text/2]).
-import(ts_extract_text, [to_atom/1, to_text/1]).

-define(FUNCTION_QUERY,
    <<"[(function_item) (function_signature_item)] @f">>).
-define(MODULE_QUERY, <<"(mod_item) @m">>).
-define(USE_QUERY, <<"(use_declaration) @u">>).
-define(VISIBILITY_QUERY,
    <<"[(function_item) (function_signature_item) (mod_item) (struct_item) "
      "(enum_item) (union_item) (trait_item) (type_item) (const_item) "
      "(static_item)] @item">>).
-define(CALL_QUERY, <<"(call_expression) @call">>).
-define(MACRO_QUERY, <<"(macro_invocation) @macro">>).

-spec file(file:filename()) -> [tuple()].
file(Path) ->
    {ok, Source} = file:read_file(Path),
    text(Path, Source).

-spec text(file:filename(), binary()) -> [tuple()].
text(Path, Source) when is_binary(Source) ->
    PathAtom = to_atom(Path),
    {ok, Parser} = symbolic_ts:parser_new(),
    {ok, Language} = symbolic_ts:tree_sitter_rust(),
    true = symbolic_ts:parser_set_language(Parser, Language),
    Tree = symbolic_ts:parser_parse_string(Parser, Source),
    Root = symbolic_ts:tree_root_node(Tree),
    Functions = function_facts(Language, Root, Source, PathAtom),
    Modules = module_facts(Language, Root, Source, PathAtom),
    Uses = use_facts(Language, Root, Source, PathAtom),
    Calls = call_facts(Language, Root, Source, PathAtom),
    Macros = macro_facts(Language, Root, Source, PathAtom),
    Visibilities = visibility_facts(Language, Root, Source, PathAtom),
    lists:usort(Functions ++ Modules ++ Uses ++ Calls ++ Macros ++ Visibilities).

function_facts(Language, Root, Source, Path) ->
    Nodes = captures(Language, Root, ?FUNCTION_QUERY, "f"),
    lists:flatmap(fun(N) -> function_facts(N, Source, Path) end, Nodes).

function_facts(Node, Source, Path) ->
    NameNode = symbolic_ts:node_child_by_field_name(Node, <<"name">>),
    ParamsNode = symbolic_ts:node_child_by_field_name(Node, <<"parameters">>),
    case symbolic_ts:node_is_null(NameNode) orelse symbolic_ts:node_is_null(ParamsNode) of
        true -> [];
        false ->
            Name = to_atom(symbolic_ts:node_text(NameNode, Source)),
            Arity = symbolic_ts:node_named_child_count(ParamsNode),
            Params = to_text(symbolic_ts:node_text(ParamsNode, Source)),
            Context = context(Node, Source),
            Kind = function_kind(Node),
            Visibility = visibility(Node, Source),
            Id = node_id(Path, Node),
            Line = line(Node),
            [
                {defines, Name, Arity, Params, Path, Line},
                {function_decl, Id, rust, Name, Arity, Kind, Path, Line},
                {rust_function, Id, Name, Arity, Params, Kind, Context, Visibility, Path, Line}
            ]
    end.

function_kind(Node) ->
    case {symbolic_ts:node_type(Node), nearest_context_kind(symbolic_ts:node_parent(Node))} of
        {"function_signature_item", trait} -> trait_signature;
        {"function_signature_item", _} -> declaration;
        {"function_item", impl} -> method;
        {"function_item", trait} -> trait_method;
        {"function_item", _} -> function
    end.

nearest_context_kind(Node) ->
    case symbolic_ts:node_is_null(Node) of
        true -> none;
        false ->
            case symbolic_ts:node_type(Node) of
                "impl_item" -> impl;
                "trait_item" -> trait;
                _ -> nearest_context_kind(symbolic_ts:node_parent(Node))
            end
    end.

context(Node, Source) ->
    Parts = context_parts(symbolic_ts:node_parent(Node), Source, []),
    to_text(lists:flatten(lists:join("::", context_text_parts(Parts)))).

context_parts(Node, _Source, Acc) when Node =:= undefined ->
    Acc;
context_parts(Node, Source, Acc) ->
    case symbolic_ts:node_is_null(Node) of
        true -> Acc;
        false ->
            Type = symbolic_ts:node_type(Node),
            Part = case Type of
                "mod_item" -> named_context(Node, Source, "mod ");
                "impl_item" -> {context_text, "impl ", Node, Source};
                "trait_item" -> named_context(Node, Source, "trait ");
                _ -> none
            end,
            Next = case Part of
                none -> Acc;
                _ -> [Part | Acc]
            end,
            context_parts(symbolic_ts:node_parent(Node), Source, Next)
    end.

named_context(Node, Source, Prefix) ->
    Name = symbolic_ts:node_child_by_field_name(Node, <<"name">>),
    case symbolic_ts:node_is_null(Name) of
        true -> none;
        false -> {context_name, Prefix, symbolic_ts:node_text(Name, Source)}
    end.

context_text_parts(Parts) ->
    [case P of
         {context_name, Prefix, Name} -> [Prefix, Name];
         {context_text, Prefix, Node, Source} -> [Prefix, context_type_text(Node, Source)]
     end || P <- Parts].

context_type_text(Node, Source) ->
    Type = symbolic_ts:node_child_by_field_name(Node, <<"type">>),
    case symbolic_ts:node_is_null(Type) of
        true -> "<unknown>";
        false -> symbolic_ts:node_text(Type, Source)
    end.

visibility(Node, Source) ->
    case named_child_of_type(Node, "visibility_modifier") of
        undefined -> private;
        Vis -> visibility_value(symbolic_ts:node_text(Vis, Source))
    end.

visibility_value("pub") -> public;
visibility_value("pub(crate)") -> {public, crate};
visibility_value("pub(super)") -> {public, super};
visibility_value(Text) ->
    case lists:prefix("pub(in ", Text) of
        true -> {public_in, to_text(lists:sublist(Text, 8, length(Text) - 8))};
        false -> private
    end.

module_facts(Language, Root, Source, Path) ->
    Nodes = captures(Language, Root, ?MODULE_QUERY, "m"),
    lists:flatmap(
        fun(Node) ->
            NameNode = symbolic_ts:node_child_by_field_name(Node, <<"name">>),
            case symbolic_ts:node_is_null(NameNode) of
                true -> [];
                false ->
                    Name = to_atom(symbolic_ts:node_text(NameNode, Source)),
                    ParentContext = context(Node, Source),
                    Form = case symbolic_ts:node_is_null(
                        symbolic_ts:node_child_by_field_name(Node, <<"body">>)) of
                        true -> external;
                        false -> inline
                    end,
                    [{rust_module, Name, ParentContext, Form,
                      visibility(Node, Source), Path, line(Node)}]
            end
        end, Nodes).

use_facts(Language, Root, Source, Path) ->
    Nodes = captures(Language, Root, ?USE_QUERY, "u"),
    [{rust_use, to_text(use_path(symbolic_ts:node_text(Node, Source))),
      context(Node, Source), Path, line(Node)} || Node <- Nodes].

use_path(Text) ->
    Trimmed = string:trim(Text),
    AfterUse = drop_to_use(Trimmed),
    PathAndSemicolon = string:trim(AfterUse),
    lists:sublist(PathAndSemicolon, length(PathAndSemicolon) - 1).

drop_to_use([ $u, $s, $e, $\s | Rest]) -> Rest;
drop_to_use([_ | Rest]) -> drop_to_use(Rest);
drop_to_use([]) -> [].

visibility_facts(Language, Root, Source, Path) ->
    Nodes = captures(Language, Root, ?VISIBILITY_QUERY, "item"),
    lists:flatmap(
        fun(Node) ->
            Vis = visibility(Node, Source),
            case Vis of
                private -> [];
                _ -> [{rust_visibility, node_id(Path, Node),
                       to_atom(symbolic_ts:node_type(Node)), Vis, Path, line(Node)}]
            end
        end, Nodes).

call_facts(Language, Root, Source, Path) ->
    Nodes = captures(Language, Root, ?CALL_QUERY, "call"),
    lists:flatmap(fun(N) -> call_fact(N, Source, Path) end, Nodes).

%% A macro invocation is its own syntactic operation, not a function call:
%% the extractor records its written path but does not inspect its token tree
%% or claim that macro expansion invokes any functions.
macro_facts(Language, Root, Source, Path) ->
    Nodes = captures(Language, Root, ?MACRO_QUERY, "macro"),
    lists:flatmap(fun(N) -> macro_fact(N, Source, Path) end, Nodes).

macro_fact(Node, Source, Path) ->
    NameNode = symbolic_ts:node_named_child(Node, 0),
    case symbolic_ts:node_is_null(NameNode) of
        true -> [];
        false ->
            CallerId = case caller_node(Node) of
                undefined -> undefined;
                CallerNode -> node_id(Path, CallerNode)
            end,
            [{rust_macro, node_id(Path, Node),
              to_atom(symbolic_ts:node_text(NameNode, Source)),
              CallerId, Path, line(Node)}]
    end.

call_fact(Node, Source, Path) ->
    Callee = symbolic_ts:node_child_by_field_name(Node, <<"function">>),
    Args = symbolic_ts:node_child_by_field_name(Node, <<"arguments">>),
    case symbolic_ts:node_is_null(Callee) orelse symbolic_ts:node_is_null(Args) of
        true -> [];
        false ->
            case caller_node(Node) of
                undefined -> [];
                CallerNode ->
                    {Caller, CallerArity} = function_caller(CallerNode, Source),
                    ArgCount = symbolic_ts:node_named_child_count(Args),
                    case call_spec(Callee, Source, ArgCount) of
                        skip -> [];
                        Spec ->
                            [{calls, Caller, CallerArity, Spec, Path, line(Node)},
                             {rust_call, node_id(Path, Node), node_id(Path, CallerNode),
                              Spec, Path, line(Node)}]
                    end
            end
    end.

call_spec(Callee, Source, ArgCount) ->
    case symbolic_ts:node_type(Callee) of
        "identifier" -> {path, to_atom(symbolic_ts:node_text(Callee, Source)), ArgCount};
        "field_expression" ->
            Receiver = symbolic_ts:node_named_child(Callee, 0),
            Method = symbolic_ts:node_named_child(Callee, 1),
            {member, to_atom(symbolic_ts:node_text(Receiver, Source)),
             to_atom(symbolic_ts:node_text(Method, Source)), ArgCount};
        "scoped_identifier" ->
            {path, to_atom(symbolic_ts:node_text(Callee, Source)), ArgCount};
        "generic_function" ->
            generic_call_spec(Callee, Source, ArgCount);
        _ -> skip
    end.

generic_call_spec(Node, Source, ArgCount) ->
    Function = symbolic_ts:node_child_by_field_name(Node, <<"function">>),
    case symbolic_ts:node_is_null(Function) of
        true -> skip;
        false ->
            case call_spec(Function, Source, ArgCount) of
                {member, Receiver, Method, _} ->
                    {member, Receiver, Method, ArgCount};
                _ ->
                    {path, to_atom(symbolic_ts:node_text(Node, Source)), ArgCount}
            end
    end.

caller_node(Node) ->
    case symbolic_ts:node_is_null(Node) of
        true -> undefined;
        false ->
            case symbolic_ts:node_type(Node) of
                "function_item" -> Node;
                _ -> caller_node(symbolic_ts:node_parent(Node))
            end
    end.

function_caller(Node, Source) ->
    NameNode = symbolic_ts:node_child_by_field_name(Node, <<"name">>),
    ParamsNode = symbolic_ts:node_child_by_field_name(Node, <<"parameters">>),
    case symbolic_ts:node_is_null(NameNode) orelse symbolic_ts:node_is_null(ParamsNode) of
        true -> {undefined, undefined};
        false ->
            {to_atom(symbolic_ts:node_text(NameNode, Source)),
             symbolic_ts:node_named_child_count(ParamsNode)}
    end.

captures(Language, Root, Query, CaptureName) ->
    {Compiled, _, _} = symbolic_ts:query_new(Language, Query),
    lists:usort([Node || {Name, Node} <- symbolic_ts:query_capture(Root, Compiled),
                         Name =:= CaptureName]).

named_child_of_type(Node, WantedType) ->
    Count = symbolic_ts:node_named_child_count(Node),
    find_named_child_of_type(Node, WantedType, 0, Count).

find_named_child_of_type(_Node, _WantedType, Index, Count) when Index >= Count ->
    undefined;
find_named_child_of_type(Node, WantedType, Index, Count) ->
    Child = symbolic_ts:node_named_child(Node, Index),
    case symbolic_ts:node_type(Child) of
        WantedType -> Child;
        _ -> find_named_child_of_type(Node, WantedType, Index + 1, Count)
    end.

node_id(Path, Node) ->
    {Path, symbolic_ts:node_start_byte(Node), symbolic_ts:node_end_byte(Node)}.

line(Node) ->
    maps:get(row, symbolic_ts:node_start_point(Node)) + 1.
