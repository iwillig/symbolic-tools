%%% Extract Prolog facts from one Erlang source file via tree-sitter
%%% (erl_ts). See docs/tree-sitter-erlang.md.
%%%
%%% Facts (deliberately simpler than the original design sketch — no
%%% module name or arity yet, see the Phase 1 plan notes):
%%%   defines(Function, File, Line)
%%%   calls(Caller, local(Callee), File, Line)
%%%   calls(Caller, remote(Module, Function), File, Line)
%%%   comment(File, Line, Text)                       — every comment, unconditionally
%%%   doc(Function, File, Line, Text)                  — a comment run immediately
%%%                                                       preceding a fun_decl
%%%
%%% Caller/callee attribution walks up node_parent/1 to the nearest
%%% enclosing function_clause, rather than a single combined query —
%%% erl_ts's query_capture/2 duplicates each match once per named capture
%%% in the pattern (verified empirically: a 2-capture query returns every
%%% match twice, a 3-capture query three times), so a query correlating
%%% caller+callee in one pattern can't be trusted without deduplication
%%% logic anyway. Walking the tree directly sidesteps that quirk entirely.
%%%
%%% Doc-comment attribution needs a *different* part of the API —
%%% sibling navigation, not the parent-walk above. A comment is a
%%% sibling of what it documents, not a child of it (confirmed by
%%% parsing a sample and reading node_string/1's output), and each `%%`
%%% line is its own separate comment node — a multi-line edoc block is a
%%% *run* of consecutive comment siblings, collected by collect_run/3.
%%% One extra indirection versus TypeScript: a doc comment's next
%%% sibling is the whole `fun_decl` wrapper, not the inner
%%% `function_clause` that `defines/3` targets (a `fun_decl` can hold
%%% several clauses) — confirmed the path is
%%% node_next_sibling(Comment) -> fun_decl,
%%% node_named_child(FunDecl, 0) -> function_clause, then the same
%%% node_child_by_field_name(_, "name") lookup defines/3 already uses.
%%%
%%% Confirmed by testing, not assumed: node_next_sibling/1 and
%%% node_prev_sibling/1 return the plain atom `undefined` when there's
%%% no such sibling — NOT a null resource checked via node_is_null/1,
%%% unlike node_parent/1. Calling node_is_null/1 on `undefined` raises
%%% badarg. See docs/tree-sitter-erlang.md §6.
-module(ts_extract_erlang).
-export([file/1]).

-define(DEF_QUERY, "(function_clause name: (atom) @fun_name)").
-define(LOCAL_CALL_QUERY, "(call expr: (atom) @callee)").
-define(REMOTE_CALL_QUERY, "(call expr: (remote) @call)").
-define(COMMENT_QUERY, "(comment) @c").

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
        remote_calls(Lang, Root, Src, PathAtom) ++
        comments(Lang, Root, Src, PathAtom) ++
        docs(Lang, Root, Src, PathAtom),
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

comments(Lang, Root, Src, PathAtom) ->
    lists:usort([
        {comment, PathAtom, line(N), clean_join([erl_ts:node_text(N, Src)])}
     || N <- comment_nodes(Lang, Root)
    ]).

docs(Lang, Root, Src, PathAtom) ->
    RunStarts = [N || N <- comment_nodes(Lang, Root), is_run_start(N)],
    lists:filtermap(fun(Start) -> doc_fact(Start, Src, PathAtom) end, RunStarts).

comment_nodes(Lang, Root) ->
    {Q, _, _} = erl_ts:query_new(Lang, ?COMMENT_QUERY),
    Caps = erl_ts:query_capture(Root, Q),
    lists:usort([N || {"c", N} <- Caps]).

is_run_start(Node) ->
    case erl_ts:node_prev_sibling(Node) of
        undefined -> true;
        Prev -> erl_ts:node_type(Prev) =/= "comment"
    end.

%% Walk forward from the first comment in a run, collecting text, until
%% hitting a non-comment sibling (the run's Target — undefined if the
%% run is the last thing in the file).
collect_run(Node, Src, Acc) ->
    Acc1 = [erl_ts:node_text(Node, Src) | Acc],
    case erl_ts:node_next_sibling(Node) of
        undefined -> {lists:reverse(Acc1), undefined};
        Next ->
            case erl_ts:node_type(Next) of
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

%% Target is the fun_decl wrapper, one level above the function_clause
%% defines/3 targets — descend one named child to reach it.
definition_name(Node, Src) ->
    case erl_ts:node_type(Node) of
        "fun_decl" ->
            Clause = erl_ts:node_named_child(Node, 0),
            NameNode = erl_ts:node_child_by_field_name(Clause, "name"),
            to_atom(erl_ts:node_text(NameNode, Src));
        _ ->
            false
    end.

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

%% Comment text cleaning: strip leading `%`/`%%` and join a run into
%% one line — keeps the .pl output one-fact-per-line (a quoted atom may
%% legally contain raw newlines, but nothing else this project emits
%% does, and there's no benefit to being the exception).
clean_join(Texts) ->
    Lines = lists:flatmap(fun to_lines/1, Texts),
    Cleaned = [clean_line(L) || L <- Lines],
    NonEmpty = [L || L <- Cleaned, L =/= ""],
    to_atom(lists:flatten(lists:join(" ", NonEmpty))).

to_lines(Text) when is_binary(Text) -> to_lines(binary_to_list(Text));
to_lines(Text) when is_list(Text) -> string:split(Text, "\n", all).

clean_line(Line) ->
    string:trim(string:trim(Line, leading, "%")).
