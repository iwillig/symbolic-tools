%%% Extract Prolog facts from one Erlang source file via tree-sitter
%%% (symbolic_ts). See docs/tree-sitter-erlang.md.
%%%
%%% Facts (deliberately simpler than the original design sketch — no
%%% module name yet, see the Phase 1 plan notes):
%%%   defines(Function, Arity, Params, File, Line)
%%%   export(Function, Arity, File, Line)          — a `-export([f/1])` entry point,
%%%                                                       one fact per list element; what
%%%                                                       .symbolic/rules.pl's entry_point/3
%%%                                                       reads to keep exported API out of
%%%                                                       the dead-code report
%%%   calls(Caller, CallerArity, local(Callee, ArgCount), File, Line)
%%%   calls(Caller, CallerArity, remote(Module, Function, ArgCount), File, Line)
%%%   comment(File, Line, Text)                       — every comment, unconditionally
%%%   doc(Function, Arity, File, Line, Text)           — a comment run immediately
%%%                                                       preceding a fun_decl
%%%   branch(Function, Arity, Kind, File, Line)        — a decision point (cr_clause/
%%%                                                       if_clause/receive_after) inside
%%%                                                       Function; see ?BRANCH_QUERIES and
%%%                                                       .symbolic/rules.pl's real_complexity/4
%%%   expr(Id, Function, Arity, Kind, File, Line)      — a binary/unary expression, Id keyed
%%%                                                       on a byte span (see exprs/4)
%%%   expr_operator(Id, Op)                            — that expression's operator, e.g. '==', 'andalso'
%%%   expr_operand(Id, Role, ChildId)                  — Role: left/right/operand
%%%   literal(Id, Function, Arity, LitKind, Value, File, Line) — a literal used as an operand
%%%   expr_ref(Id, Function, Arity, Name, File, Line)  — a bare `var` used as an operand
%%%
%%% Arity/ArgCount and Params come from the `function_clause`/`call`
%%% node's own "args" field (an `expr_args` node) — its named-child count
%%% IS the arity (a destructured pattern like `{Y,Z}` or `[H|T]` is still
%%% one named child, matching real Erlang arity semantics, confirmed by
%%% parsing `baz(X, {Y,Z}, [H|T])` and getting 3), and Params is that
%%% field's raw source text (e.g. `"(A, B)"`) so a human/LLM can see what
%%% the arguments actually are, not just how many. This closes the
%%% documented false-positive gap (`docs/lint-queries.md`,
%%% `docs/prolog-schema.md`): same-named functions of different arity
%%% (`query/2` vs `query/3`) were previously indistinguishable from real
%%% recursion or duplication.
%%%
%%% CallerArity closes the other half of that gap: the caller-attribution
%%% walk-up (below) now grabs the enclosing function_clause's own arity
%%% too, not just its name, so a call site inside `query/1`'s body (which
%%% calls `query/2`) is no longer indistinguishable from a call site
%%% genuinely inside `query/2` itself.
%%%
%%% A `call` node with NO enclosing `function_clause` is not emitted as a
%%% calls/5 fact at all (see `call_site/4`). That is the whole set of
%%% `-spec`/`-type`/`-callback` type references, which this grammar parses
%%% with the same `call` node type as real calls — see call_site/4's own
%%% comment for the verified node paths and the concrete damage they did
%%% before they were dropped.
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
-export([file/1, text/2]).
-import(ts_extract_text, [to_atom/1, to_text/1]).

-define(DEF_QUERY, "(function_clause name: (atom) @fun_name)").
-define(LOCAL_CALL_QUERY, "(call expr: (atom) @callee)").
-define(REMOTE_CALL_QUERY, "(call expr: (remote) @call)").
-define(COMMENT_QUERY, "(comment) @c").

%% One fact per element of every `-export([...])` list — the query binds
%% the whole attribute and `export_facts/3` reads its `fa` children, so a
%% 5-function list yields 5 facts and the two node-walk conventions
%% (multi-capture queries double their matches; `fa` has no addressable
%% fields) never have to be fought. See ?DEF_QUERY's module header.
-define(EXPORT_QUERY, "(export_attribute) @e").

%% One query per decision-point construct, for real (McCabe-style)
%% complexity instead of the fan_out/3-based proxy too_complex/3 uses.
%% cr_clause covers BOTH `case ... of` arms and `receive` arms (same
%% node type for both, confirmed empirically) — no need for separate
%% queries. receive_after is a receive's `after Timeout -> ...` escape
%% path, itself a decision point. andalso/orelse are deliberately not
%% here yet: both are a plain binary_op_expr, same as `+`/`>`, and
%% whether the grammar exposes an addressable operator field the way
%% TypeScript's binary_expression does hasn't been verified — see
%% .symbolic/rules.pl's real_complexity/4 doc comment.
-define(BRANCH_QUERIES, [
    {cr_clause, "(cr_clause) @b"},
    {if_clause, "(if_clause) @b"},
    {receive_after, "(receive_after) @b"}
]).

%% binary_op_expr/unary_op_expr have NO addressable fields at all —
%% confirmed empirically: node_child_by_field_name(_, "left"/"right"/
%% "operator") all return null, unlike TypeScript's binary_expression.
%% Operands are purely positional (node_named_child/2 at index 0/1), and
%% the operator token itself isn't even a named child. A literal-token
%% query works instead — confirmed empirically, e.g.
%% (binary_op_expr "andalso") @b matches correctly — so one query per
%% known operator, same shape as ?BRANCH_QUERIES, rather than one
%% generic query the way ts_extract_typescript.erl's exprs/4 reads
%% TypeScript's operator field. Scoped to comparisons and logical
%% operators (what the motivating ESLint rules need); arithmetic/
%% bitwise are the same mechanism, just unbuilt.
-define(BINARY_OP_QUERIES, [
    {'==', "(binary_op_expr \"==\") @b"},
    {'/=', "(binary_op_expr \"/=\") @b"},
    {'=:=', "(binary_op_expr \"=:=\") @b"},
    {'=/=', "(binary_op_expr \"=/=\") @b"},
    {'<', "(binary_op_expr \"<\") @b"},
    {'>', "(binary_op_expr \">\") @b"},
    {'>=', "(binary_op_expr \">=\") @b"},
    {'=<', "(binary_op_expr \"=<\") @b"},
    {'and', "(binary_op_expr \"and\") @b"},
    {'or', "(binary_op_expr \"or\") @b"},
    {'andalso', "(binary_op_expr \"andalso\") @b"},
    {'orelse', "(binary_op_expr \"orelse\") @b"}
]).

-define(UNARY_OP_QUERIES, [
    {'-', "(unary_op_expr \"-\") @b"},
    {'not', "(unary_op_expr \"not\") @b"}
]).

-spec file(file:filename()) -> [tuple()].
file(Path) ->
    {ok, Bin} = file:read_file(Path),
    text(Path, binary_to_list(Bin)).

%% Same extraction as file/1, but against an already-in-memory source
%% string rather than a file on disk — used by ts_extract_markdown to
%% run this extractor against a fenced code block's contents, with
%% `Path` set to the enclosing Markdown file (not a real .erl file).
-spec text(file:filename(), string()) -> [tuple()].
text(Path, Src) ->
    {ok, Parser} = symbolic_ts:parser_new(),
    {ok, Lang} = symbolic_ts:tree_sitter_erlang(),
    true = symbolic_ts:parser_set_language(Parser, Lang),
    Tree = symbolic_ts:parser_parse_string(Parser, Src),
    Root = symbolic_ts:tree_root_node(Tree),
    PathAtom = list_to_atom(Path),
    Facts =
        defines(Lang, Root, Src, PathAtom) ++
        exports(Lang, Root, Src, PathAtom) ++
        local_calls(Lang, Root, Src, PathAtom) ++
        remote_calls(Lang, Root, Src, PathAtom) ++
        comments(Lang, Root, Src, PathAtom) ++
        docs(Lang, Root, Src, PathAtom) ++
        branches(Lang, Root, Src, PathAtom) ++
        exprs(Lang, Root, Src, PathAtom),
    lists:usort(Facts).

%% A `-export([f/1, g/0])` attribute is `export_attribute` with one `fa`
%% child per entry, and each `fa` is positional: named child 0 is the
%% function's `atom`, named child 1 is `arity`, whose own single named
%% child is the `integer` (all four node types confirmed by dumping the
%% tree — `fa` exposes no fields, unlike `function_clause`'s "name").
%% Line is the `fa`'s own row, not the attribute's: a long export list
%% wraps across lines, and the element's row is the anchor worth having.
exports(Lang, Root, Src, PathAtom) ->
    {Q, _, _} = symbolic_ts:query_new(Lang, ?EXPORT_QUERY),
    Caps = symbolic_ts:query_capture(Root, Q),
    lists:usort(lists:flatmap(
        fun(Attr) -> export_facts(Attr, Src, PathAtom) end,
        lists:usort([N || {"e", N} <- Caps]))).

export_facts(Attr, Src, PathAtom) ->
    [export_fact(Fa, Src, PathAtom) || Fa <- fa_children(Attr, 0)].

export_fact(Fa, Src, PathAtom) ->
    NameNode = symbolic_ts:node_named_child(Fa, 0),
    ArityNode = symbolic_ts:node_named_child(
        symbolic_ts:node_named_child(Fa, 1), 0),
    {export,
        to_atom(symbolic_ts:node_text(NameNode, Src)),
        parse_number(symbolic_ts:node_text(ArityNode, Src)), PathAtom, line(Fa)}.

%% Collect an attribute's `fa` children by index — node_named_child/2 is
%% the only child accessor this grammar needs here, and an
%% `export_attribute` holds nothing else.
fa_children(Attr, I) ->
    case I >= symbolic_ts:node_named_child_count(Attr) of
        true -> [];
        false ->
            Node = symbolic_ts:node_named_child(Attr, I),
            case symbolic_ts:node_type(Node) of
                "fa" -> [Node | fa_children(Attr, I + 1)];
                _ -> fa_children(Attr, I + 1)
            end
    end.

defines(Lang, Root, Src, PathAtom) ->
    {Q, _, _} = symbolic_ts:query_new(Lang, ?DEF_QUERY),
    Caps = symbolic_ts:query_capture(Root, Q),
    lists:usort([
        define_fact(N, Src, PathAtom)
     || {"fun_name", N} <- Caps
    ]).

define_fact(NameNode, Src, PathAtom) ->
    Clause = symbolic_ts:node_parent(NameNode),
    {Arity, Params} = args_shape(Clause, "args", Src),
    {defines, to_atom(symbolic_ts:node_text(NameNode, Src)), Arity, Params,
     PathAtom, line(NameNode)}.

%% A node's "args" field (an `expr_args` node, e.g. "(A, B)") — see this
%% module's header for why its named-child count is the real arity.
args_shape(Node, FieldName, Src) ->
    ArgsNode = symbolic_ts:node_child_by_field_name(Node, FieldName),
    {symbolic_ts:node_named_child_count(ArgsNode),
     to_text(symbolic_ts:node_text(ArgsNode, Src))}.

local_calls(Lang, Root, Src, PathAtom) ->
    {Q, _, _} = symbolic_ts:query_new(Lang, ?LOCAL_CALL_QUERY),
    Caps = symbolic_ts:query_capture(Root, Q),
    lists:usort(lists:filtermap(
        fun(N) -> local_call_fact(N, Src, PathAtom) end,
        [N || {"callee", N} <- Caps])).

local_call_fact(N, Src, PathAtom) ->
    case call_site(N, Src) of
        false ->
            false;
        {true, {Caller, CallerArity}} ->
            CallNode = symbolic_ts:node_parent(N),
            {ArgCount, _Params} = args_shape(CallNode, "args", Src),
            {true, {calls, Caller, CallerArity,
                {local, to_atom(symbolic_ts:node_text(N, Src)), ArgCount},
                PathAtom, line(N)}}
    end.

remote_calls(Lang, Root, Src, PathAtom) ->
    {Q, _, _} = symbolic_ts:query_new(Lang, ?REMOTE_CALL_QUERY),
    Caps = symbolic_ts:query_capture(Root, Q),
    lists:usort(lists:filtermap(
        fun(N) -> remote_call_fact(N, Src, PathAtom) end,
        [N || {"call", N} <- Caps])).

%% The @call capture binds to the `remote` node itself (the `expr` field's
%% value, e.g. `io:format`), not the enclosing `call` node — its "args"
%% field lives one level up, on the parent (confirmed empirically: "args"
%% on the captured node is null).
remote_call_fact(RemoteNode, Src, PathAtom) ->
    case call_site(RemoteNode, Src) of
        false ->
            false;
        {true, {Caller, CallerArity}} ->
            ModNode = symbolic_ts:node_child_by_field_name(RemoteNode, "module"),
            ModAtomNode = symbolic_ts:node_child_by_field_name(ModNode, "module"),
            FunNode = symbolic_ts:node_child_by_field_name(RemoteNode, "fun"),
            CallNode = symbolic_ts:node_parent(RemoteNode),
            {ArgCount, _Params} = args_shape(CallNode, "args", Src),
            {true, {calls, Caller, CallerArity,
                {remote, to_atom(symbolic_ts:node_text(ModAtomNode, Src)),
                    to_atom(symbolic_ts:node_text(FunNode, Src)), ArgCount},
                PathAtom, line(RemoteNode)}}
    end.

%% A `call` node with no enclosing `function_clause` is not a call site, so
%% it gets no calls/5 fact. That set is exactly the type references in
%% `-spec`/`-callback`/`-type` attributes, which this grammar gives the SAME
%% node shape as a real call — verified by dumping the tree: `file:filename()`
%% in `-spec f(file:filename())` walks `remote <- call <- expr_args <-
%% type_sig <- spec` and matches ?REMOTE_CALL_QUERY, and `list(integer())`
%% in `-type t() :: list(integer())` matches ?LOCAL_CALL_QUERY twice (`list`
%% and `integer`). Before this filter those references were facts — 25 sites
%% across 12 of this repo's own 19 .erl files — which is why all_risky_calls/1
%% reported filesystem access no code performs and module_dependency/2 claimed
%% a `file` dependency from a -spec alone. Drop rather than re-attribute:
%% calls/5's first two fields ARE the attribution, so a fact with
%% Caller=undefined can never answer callers/3 or callees/2 — it can only
%% pollute them.
call_site(Node, Src) ->
    case caller_info(Node, Src) of
        {undefined, undefined} -> false;
        Info -> {true, Info}
    end.

%% One branch/5 fact per decision point (see ?BRANCH_QUERIES), attributed
%% to its enclosing function_clause via caller_info/2 — the exact same
%% walk-up local_call_fact/3 uses for calls/5's Caller/CallerArity.
branches(Lang, Root, Src, PathAtom) ->
    lists:flatmap(
        fun({Kind, Query}) -> branch_facts(Lang, Root, Src, PathAtom, Kind, Query) end,
        ?BRANCH_QUERIES).

branch_facts(Lang, Root, Src, PathAtom, Kind, Query) ->
    {Q, _, _} = symbolic_ts:query_new(Lang, Query),
    Caps = symbolic_ts:query_capture(Root, Q),
    lists:usort([branch_fact(N, Src, PathAtom, Kind) || {"b", N} <- Caps]).

branch_fact(N, Src, PathAtom, Kind) ->
    {Caller, CallerArity} = caller_info(N, Src),
    {branch, Caller, CallerArity, Kind, PathAtom, line(N)}.

%% Expression content: what a decision point's condition actually
%% compares, not just that it exists — see ts_extract_typescript.erl's
%% exprs/4 for the full rationale (shared with this module) on why a
%% new node identity (node_id/2, keyed on a byte SPAN) is needed here
%% and nowhere else in this schema.
exprs(Lang, Root, Src, PathAtom) ->
    binary_exprs(Lang, Root, Src, PathAtom) ++ unary_exprs(Lang, Root, Src, PathAtom).

binary_exprs(Lang, Root, Src, PathAtom) ->
    lists:flatmap(
        fun({Op, Query}) -> binary_op_facts(Lang, Root, Src, PathAtom, Op, Query) end,
        ?BINARY_OP_QUERIES).

binary_op_facts(Lang, Root, Src, PathAtom, Op, Query) ->
    {Q, _, _} = symbolic_ts:query_new(Lang, Query),
    Caps = symbolic_ts:query_capture(Root, Q),
    Nodes = lists:usort([N || {"b", N} <- Caps]),
    lists:flatmap(fun(N) -> binary_op_fact_set(N, Src, PathAtom, Op) end, Nodes).

%% Operands are positional (no fields — see ?BINARY_OP_QUERIES' own doc
%% comment): node_named_child(N, 0) is left, node_named_child(N, 1) is
%% right, confirmed empirically against a real `X > 0`-shaped clause.
binary_op_fact_set(N, Src, PathAtom, Op) ->
    Id = node_id(PathAtom, N),
    {Caller, CallerArity} = caller_info(N, Src),
    ExprFact = {expr, Id, Caller, CallerArity, binary, PathAtom, line(N)},
    OpFact = {expr_operator, Id, Op},
    LeftNode = symbolic_ts:node_named_child(N, 0),
    RightNode = symbolic_ts:node_named_child(N, 1),
    [ExprFact, OpFact]
        ++ operand_facts(Id, left, LeftNode, Caller, CallerArity, Src, PathAtom)
        ++ operand_facts(Id, right, RightNode, Caller, CallerArity, Src, PathAtom).

unary_exprs(Lang, Root, Src, PathAtom) ->
    lists:flatmap(
        fun({Op, Query}) -> unary_op_facts(Lang, Root, Src, PathAtom, Op, Query) end,
        ?UNARY_OP_QUERIES).

unary_op_facts(Lang, Root, Src, PathAtom, Op, Query) ->
    {Q, _, _} = symbolic_ts:query_new(Lang, Query),
    Caps = symbolic_ts:query_capture(Root, Q),
    Nodes = lists:usort([N || {"b", N} <- Caps]),
    lists:flatmap(fun(N) -> unary_op_fact_set(N, Src, PathAtom, Op) end, Nodes).

unary_op_fact_set(N, Src, PathAtom, Op) ->
    Id = node_id(PathAtom, N),
    {Caller, CallerArity} = caller_info(N, Src),
    ExprFact = {expr, Id, Caller, CallerArity, unary, PathAtom, line(N)},
    OpFact = {expr_operator, Id, Op},
    OperandNode = symbolic_ts:node_named_child(N, 0),
    [ExprFact, OpFact] ++ operand_facts(Id, operand, OperandNode, Caller, CallerArity, Src, PathAtom).

%% Classify one operand node: a literal gets its own literal/7 fact, a
%% bare `var` gets expr_ref/6, and anything else (a nested
%% binary_op_expr/unary_op_expr, already captured independently by
%% binary_exprs/1's or unary_exprs/1's own queries) needs no new fact —
%% just the expr_operand link to the Id that capture already produced.
operand_facts(ParentId, Role, Node, Caller, CallerArity, Src, PathAtom) ->
    ChildId = node_id(PathAtom, Node),
    Link = {expr_operand, ParentId, Role, ChildId},
    case classify_literal(Node, Src) of
        {LitKind, Value} ->
            [Link, {literal, ChildId, Caller, CallerArity, LitKind, Value, PathAtom, line(Node)}];
        no ->
            case symbolic_ts:node_type(Node) of
                "var" ->
                    [Link, {expr_ref, ChildId, Caller, CallerArity,
                        to_atom(symbolic_ts:node_text(Node, Src)), PathAtom, line(Node)}];
                _ ->
                    [Link]
            end
    end.

%% integer/float/atom are the literal node types verified here. `atom`
%% covers Erlang's true/false too — they're ordinary atoms in Erlang,
%% not a distinct boolean type, so LitKind stays `atom` rather than
%% inventing a `boolean` kind that doesn't correspond to any real
%% grammar distinction. `string` is deliberately not classified yet —
%% whether its text includes surrounding quotes the way TypeScript's
%% does hasn't been verified.
classify_literal(Node, Src) ->
    case symbolic_ts:node_type(Node) of
        "integer" -> {integer, parse_number(symbolic_ts:node_text(Node, Src))};
        "float" -> {float, parse_number(symbolic_ts:node_text(Node, Src))};
        "atom" -> {atom, to_atom(symbolic_ts:node_text(Node, Src))};
        _ -> no
    end.

%% Erlang's own numeral syntax allows two things that don't round-trip
%% through list_to_integer/1 or list_to_float/1 unchanged: a `_` digit
%% separator (1_000_000) and a `Base#Digits` radix prefix (16#FF,
%% 2#1010, any base 2-36) — confirmed empirically, not just a separator
%% problem: list_to_integer("16#FF") badargs exactly like
%% list_to_integer("16#FF_FF") does. Same bug class, same fix shape, as
%% ts_extract_typescript.erl's parse_number/1 (issue #1) — that one hits
%% JS/TS's own radix-prefix/separator/BigInt syntax instead.
parse_number(Text0) ->
    Text1 = [C || C <- Text0, C =/= $_],
    case string:split(Text1, "#") of
        [BaseStr, Digits] -> list_to_integer(Digits, list_to_integer(BaseStr));
        [Text] ->
            try list_to_integer(Text)
            catch error:badarg -> list_to_float(Text)
            end
    end.

%% Same node-identity scheme as ts_extract_typescript.erl's node_id/2 —
%% see that module for why a byte span, not start-byte alone, is needed.
node_id(PathAtom, Node) ->
    {PathAtom, symbolic_ts:node_start_byte(Node), symbolic_ts:node_end_byte(Node)}.

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
        {Name, Arity} ->
            {true, {doc, Name, Arity, PathAtom, line(Target), clean_join(Texts)}}
    end.

%% Target is the fun_decl wrapper, one level above the function_clause
%% defines/3 targets — descend one named child to reach it. Arity comes
%% from that same clause's "args" field, same reasoning as define_fact/3.
definition_name(Node, Src) ->
    case symbolic_ts:node_type(Node) of
        "fun_decl" ->
            Clause = symbolic_ts:node_named_child(Node, 0),
            NameNode = symbolic_ts:node_child_by_field_name(Clause, "name"),
            {Arity, _Params} = args_shape(Clause, "args", Src),
            {to_atom(symbolic_ts:node_text(NameNode, Src)), Arity};
        _ ->
            false
    end.

%% Walk up to the nearest enclosing function_clause to attribute a call
%% site to the function it appears in — {Name, Arity}, or
%% {undefined, undefined} if the call isn't inside any recognized
%% definition (a bare top-level statement, or a -spec attribute's type
%% references — the set call_site/2 exists to drop). Arity comes from that
%% same clause's "args" field, same technique as define_fact/3.
caller_info(Node, Src) ->
    case symbolic_ts:node_type(Node) of
        "function_clause" ->
            NameNode = symbolic_ts:node_child_by_field_name(Node, "name"),
            {Arity, _Params} = args_shape(Node, "args", Src),
            {to_atom(symbolic_ts:node_text(NameNode, Src)), Arity};
        _ ->
            Parent = symbolic_ts:node_parent(Node),
            case symbolic_ts:node_is_null(Parent) of
                true -> {undefined, undefined};
                false -> caller_info(Parent, Src)
            end
    end.

line(Node) ->
    maps:get(row, symbolic_ts:node_start_point(Node)) + 1.

%% Comment text cleaning: strip leading `%`/`%%` and join a run into
%% one line — keeps output one-fact-per-line. Rendered as a binary
%% (ts_extract_text:to_text/1), not an atom: free text like this has no
%% natural length bound and is never unified against a hand-typed query
%% literal, unlike the identifier atoms `to_atom/1` produces elsewhere
%% in this module. See ts_extract_text.erl.
clean_join(Texts) ->
    Lines = lists:flatmap(fun to_lines/1, Texts),
    Cleaned = [clean_line(L) || L <- Lines],
    NonEmpty = [L || L <- Cleaned, L =/= ""],
    to_text(lists:flatten(lists:join(" ", NonEmpty))).

to_lines(Text) when is_binary(Text) -> to_lines(binary_to_list(Text));
to_lines(Text) when is_list(Text) -> string:split(Text, "\n", all).

clean_line(Line) ->
    string:trim(string:trim(Line, leading, "%")).
