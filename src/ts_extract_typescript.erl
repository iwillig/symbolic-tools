%%% Extract Prolog facts from one TypeScript source file via tree-sitter
%%% (symbolic_ts). See docs/tree-sitter-erlang.md §5.
%%%
%%% Same shape and same caveats as ts_extract_erlang: facts only,
%%% caller attribution via node_parent/1 walk-up rather than a combined
%%% query (query_capture/2's per-capture duplication quirk), dedupe via
%%% lists:usort/1.
%%%
%%%   defines(Function, File, Line)
%%%   calls(Caller, local(Callee), File, Line)          — plain calls: bar(x)
%%%   calls(Caller, member(Object, Method), File, Line)  — method calls: obj.method(x)
%%%   comment(File, Line, Text)                          — every comment, unconditionally
%%%   doc(Function, File, Line, Text)                    — a comment run immediately
%%%                                                         preceding a function_declaration
%%%
%%% Associating a comment with what it documents needs sibling
%%% navigation (node_next_sibling/1, node_prev_sibling/1), not the
%%% parent-walk used elsewhere — a comment is a *sibling* of the
%%% function_declaration it precedes, not a child of it (confirmed by
%%% parsing a sample and reading node_string/1's output). A JSDoc
%%% `/** ... */` block is one comment node; consecutive `//` lines would
%%% be separate sibling comment nodes forming a run, same as Erlang's
%%% `%%` lines — collect_run/3 below handles either shape.
%%%
%%% Confirmed by testing, not assumed: node_next_sibling/1 and
%%% node_prev_sibling/1 return the plain atom `undefined` when there's
%%% no such sibling — NOT a null resource checked via node_is_null/1,
%%% unlike node_parent/1. Calling node_is_null/1 on `undefined` raises
%%% badarg. See docs/tree-sitter-erlang.md §6.
-module(ts_extract_typescript).
-export([file/1, text/2]).

-define(DEF_QUERY, "(function_declaration name: (identifier) @fun_name)").
-define(LOCAL_CALL_QUERY, "(call_expression function: (identifier) @callee)").
-define(MEMBER_CALL_QUERY,
    "(call_expression function: (member_expression "
    "object: (_) @obj property: (property_identifier) @prop))").
-define(COMMENT_QUERY, "(comment) @c").

-spec file(file:filename()) -> [tuple()].
file(Path) ->
    {ok, Bin} = file:read_file(Path),
    text(Path, binary_to_list(Bin)).

%% Same extraction as file/1, but against an already-in-memory source
%% string rather than a file on disk — used by ts_extract_markdown to
%% run this extractor against a fenced code block's contents, with
%% `Path` set to the enclosing Markdown file (not a real .ts file).
-spec text(file:filename(), string()) -> [tuple()].
text(Path, Src) ->
    {ok, Parser} = symbolic_ts:parser_new(),
    {ok, Lang} = symbolic_ts:tree_sitter_typescript(),
    true = symbolic_ts:parser_set_language(Parser, Lang),
    Tree = symbolic_ts:parser_parse_string(Parser, Src),
    Root = symbolic_ts:tree_root_node(Tree),
    PathAtom = list_to_atom(Path),
    Facts =
        defines(Lang, Root, Src, PathAtom) ++
        local_calls(Lang, Root, Src, PathAtom) ++
        member_calls(Lang, Root, Src, PathAtom) ++
        comments(Lang, Root, Src, PathAtom) ++
        docs(Lang, Root, Src, PathAtom),
    lists:usort(Facts).

defines(Lang, Root, Src, PathAtom) ->
    {Q, _, _} = symbolic_ts:query_new(Lang, ?DEF_QUERY),
    Caps = symbolic_ts:query_capture(Root, Q),
    lists:usort([
        {defines, to_atom(symbolic_ts:node_text(N, Src)), PathAtom, line(N)}
     || {"fun_name", N} <- Caps
    ]).

local_calls(Lang, Root, Src, PathAtom) ->
    {Q, _, _} = symbolic_ts:query_new(Lang, ?LOCAL_CALL_QUERY),
    Caps = symbolic_ts:query_capture(Root, Q),
    lists:usort([
        {calls, caller_name(N, Src), {local, to_atom(symbolic_ts:node_text(N, Src))},
         PathAtom, line(N)}
     || {"callee", N} <- Caps
    ]).

%% Query returns each match's two captures (@obj, @prop) as separate
%% entries, not paired — find each unique property_identifier's own
%% call_expression ancestor and re-derive the object from there, rather
%% than trying to zip the flat capture list (unreliable given the
%% per-capture duplication quirk noted above).
member_calls(Lang, Root, Src, PathAtom) ->
    {Q, _, _} = symbolic_ts:query_new(Lang, ?MEMBER_CALL_QUERY),
    Caps = symbolic_ts:query_capture(Root, Q),
    PropNodes = lists:usort([N || {"prop", N} <- Caps]),
    lists:usort([member_call_fact(N, Src, PathAtom) || N <- PropNodes]).

member_call_fact(PropNode, Src, PathAtom) ->
    MemberNode = symbolic_ts:node_parent(PropNode),
    ObjNode = symbolic_ts:node_child_by_field_name(MemberNode, "object"),
    CallNode = symbolic_ts:node_parent(MemberNode),
    {calls, caller_name(CallNode, Src),
     {member, to_atom(symbolic_ts:node_text(ObjNode, Src)),
      to_atom(symbolic_ts:node_text(PropNode, Src))},
     PathAtom, line(PropNode)}.

comments(Lang, Root, Src, PathAtom) ->
    lists:usort([
        {comment, PathAtom, line(N), clean_join([symbolic_ts:node_text(N, Src)])}
     || N <- comment_nodes(Lang, Root)
    ]).

docs(Lang, Root, Src, PathAtom) ->
    RunStarts = [N || N <- comment_nodes(Lang, Root), is_run_start(N)],
    lists:filtermap(fun(Start) -> doc_fact(Start, Src, PathAtom) end, RunStarts).

comment_nodes(Lang, Root) ->
    {Q, _, _} = symbolic_ts:query_new(Lang, ?COMMENT_QUERY),
    Caps = symbolic_ts:query_capture(Root, Q),
    lists:usort([N || {"c", N} <- Caps]).

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

doc_fact(StartNode, Src, PathAtom) ->
    {Texts, Target} = collect_run(StartNode, Src, []),
    case Target =/= undefined andalso definition_name(Target, Src) of
        false -> false;
        Name -> {true, {doc, Name, PathAtom, line(Target), clean_join(Texts)}}
    end.

definition_name(Node, Src) ->
    case symbolic_ts:node_type(Node) of
        "function_declaration" ->
            NameNode = symbolic_ts:node_child_by_field_name(Node, "name"),
            to_atom(symbolic_ts:node_text(NameNode, Src));
        _ ->
            false
    end.

%% Walk up to the nearest enclosing function_declaration to attribute a
%% call site to the function it appears in.
caller_name(Node, Src) ->
    case symbolic_ts:node_type(Node) of
        "function_declaration" ->
            NameNode = symbolic_ts:node_child_by_field_name(Node, "name"),
            to_atom(symbolic_ts:node_text(NameNode, Src));
        _ ->
            Parent = symbolic_ts:node_parent(Node),
            case symbolic_ts:node_is_null(Parent) of
                true -> undefined;
                false -> caller_name(Parent, Src)
            end
    end.

line(Node) ->
    maps:get(row, symbolic_ts:node_start_point(Node)) + 1.

%% Erlang atoms are capped at 255 bytes — confirmed by hitting it for
%% real: `symbolic parse` crashed with `system_limit` on a long
%% doc-comment/paragraph run elsewhere in this project. Comment/doc text
%% isn't an identifier, so truncating past a generous length is a safe,
%% simple fix rather than switching every text fact to a binary just to
%% accommodate the rare long one.
-define(MAX_ATOM_TEXT, 200).

to_atom(Text) when is_binary(Text) -> to_atom(binary_to_list(Text));
to_atom(Text) when is_list(Text) -> list_to_atom(truncate(Text)).

truncate(Text) when length(Text) > ?MAX_ATOM_TEXT ->
    lists:sublist(Text, ?MAX_ATOM_TEXT) ++ "...";
truncate(Text) ->
    Text.

%% Comment text cleaning: strip `/** */`/`//`/leading `*` syntax and
%% join a run into one line — keeps the .pl output one-fact-per-line
%% (a quoted atom may legally contain raw newlines, but nothing else
%% this project emits does, and there's no benefit to being the
%% exception).
clean_join(Texts) ->
    Lines = lists:flatmap(fun to_lines/1, Texts),
    Cleaned = [clean_line(L) || L <- Lines],
    NonEmpty = [L || L <- Cleaned, L =/= ""],
    to_atom(lists:flatten(lists:join(" ", NonEmpty))).

to_lines(Text) when is_binary(Text) -> to_lines(binary_to_list(Text));
to_lines(Text) when is_list(Text) -> string:split(Text, "\n", all).

clean_line(Line) ->
    string:trim(strip_markers(string:trim(Line))).

strip_markers(Line) ->
    L1 = strip_prefix(Line, "/**"),
    L2 = strip_prefix(L1, "*/"),
    L3 = strip_prefix(L2, "//"),
    L4 = strip_prefix(L3, "*"),
    strip_suffix(L4, "*/").

strip_prefix(Str, Prefix) ->
    case string:prefix(Str, Prefix) of
        nomatch -> Str;
        Rest -> string:trim(Rest, leading)
    end.

strip_suffix(Str, Suffix) ->
    case string:prefix(lists:reverse(Str), lists:reverse(Suffix)) of
        nomatch -> Str;
        Rest -> string:trim(lists:reverse(Rest), trailing)
    end.
