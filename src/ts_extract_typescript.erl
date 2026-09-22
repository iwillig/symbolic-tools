%%% Extract Prolog facts from one TypeScript source file via tree-sitter
%%% (symbolic_ts). See docs/tree-sitter-erlang.md §5.
%%%
%%% Same shape and same caveats as ts_extract_erlang: facts only,
%%% caller attribution via node_parent/1 walk-up rather than a combined
%%% query (query_capture/2's per-capture duplication quirk), dedupe via
%%% lists:usort/1.
%%%
%%%   defines(Function, Arity, Params, File, Line)
%%%   calls(Caller, CallerArity, local(Callee, ArgCount), File, Line)          — plain calls: bar(x)
%%%   calls(Caller, CallerArity, member(Object, Method, ArgCount), File, Line)  — method calls: obj.method(x)
%%%   comment(File, Line, Text)                          — every comment, unconditionally
%%%   doc(Function, Arity, File, Line, Text)             — a comment run immediately
%%%                                                         preceding a function_declaration
%%%   branch(Function, Arity, Kind, File, Line)          — a decision point (if/for/while/
%%%                                                         ternary/switch_case/catch/and/or)
%%%                                                         inside Function; see ?BRANCH_QUERIES
%%%                                                         and .symbolic/rules.pl's real_complexity/4
%%%   expr(Id, Function, Arity, Kind, File, Line)        — a binary/unary expression, Id keyed
%%%                                                         on node_start_byte/1 (see exprs/4)
%%%   expr_operator(Id, Op)                              — that expression's operator, e.g. '==', '&&'
%%%   expr_operand(Id, Role, ChildId)                    — Role: left/right/operand
%%%   literal(Id, Function, Arity, LitKind, Value, File, Line) — a literal used as an operand
%%%   expr_ref(Id, Function, Arity, Name, File, Line)    — a bare identifier used as an operand
%%%
%%% Arity/ArgCount/Params come from `function_declaration`'s "parameters"
%%% field and `call_expression`'s "arguments" field — same technique and
%%% same false-positive fix as ts_extract_erlang.erl's identical header
%%% note (query/2-vs-query/3-style ambiguity, and its CallerArity note
%%% for the query/1-calls-query/2 half of that same gap).
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
-import(ts_extract_text, [to_atom/1, to_text/1]).

-define(DEF_QUERY, "(function_declaration name: (identifier) @fun_name)").
-define(LOCAL_CALL_QUERY, "(call_expression function: (identifier) @callee)").
-define(MEMBER_CALL_QUERY,
    "(call_expression function: (member_expression "
    "object: (_) @obj property: (property_identifier) @prop))").
-define(COMMENT_QUERY, "(comment) @c").

%% One query per decision-point construct, for real (McCabe-style)
%% complexity instead of the fan_out/3-based proxy too_complex/3 uses —
%% each `{Kind, Query}` becomes one branch/5 fact per match, attributed
%% to its enclosing function the same way a call site is. `if_statement`
%% alone covers `else if` too: tree-sitter nests it as another
%% if_statement inside an else_clause, so a plain trailing `else` (no
%% condition of its own) correctly adds nothing. `switch_case`, not
%% `switch_default`, for the same "a fallback isn't a decision" reason.
%% `operator: "&&"`/`"||"` are addressable fields on binary_expression —
%% confirmed empirically, isolates them from every other binary_expression
%% (`+`, `>`, ...) without a separate node type to query on.
-define(BRANCH_QUERIES, [
    {'if', "(if_statement) @b"},
    {'for', "(for_statement) @b"},
    {'while', "(while_statement) @b"},
    {ternary, "(ternary_expression) @b"},
    {switch_case, "(switch_case) @b"},
    {'catch', "(catch_clause) @b"},
    {'and', "(binary_expression operator: \"&&\") @b"},
    {'or', "(binary_expression operator: \"||\") @b"}
]).

-define(BINARY_EXPR_QUERY, "(binary_expression) @b").
-define(UNARY_EXPR_QUERY, "(unary_expression) @b").

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
        docs(Lang, Root, Src, PathAtom) ++
        branches(Lang, Root, Src, PathAtom) ++
        exprs(Lang, Root, Src, PathAtom),
    lists:usort(Facts).

defines(Lang, Root, Src, PathAtom) ->
    {Q, _, _} = symbolic_ts:query_new(Lang, ?DEF_QUERY),
    Caps = symbolic_ts:query_capture(Root, Q),
    lists:usort([
        define_fact(N, Src, PathAtom)
     || {"fun_name", N} <- Caps
    ]).

define_fact(NameNode, Src, PathAtom) ->
    Decl = symbolic_ts:node_parent(NameNode),
    {Arity, Params} = args_shape(Decl, "parameters", Src),
    {defines, to_atom(symbolic_ts:node_text(NameNode, Src)), Arity, Params,
     PathAtom, line(NameNode)}.

%% A node's arg-list field (`formal_parameters` for a declaration,
%% `arguments` for a call) — named-child count is the arity/arg count,
%% and the field's own text is the raw "(a, b)" for a human/LLM to read.
args_shape(Node, FieldName, Src) ->
    ArgsNode = symbolic_ts:node_child_by_field_name(Node, FieldName),
    {symbolic_ts:node_named_child_count(ArgsNode),
     to_text(symbolic_ts:node_text(ArgsNode, Src))}.

local_calls(Lang, Root, Src, PathAtom) ->
    {Q, _, _} = symbolic_ts:query_new(Lang, ?LOCAL_CALL_QUERY),
    Caps = symbolic_ts:query_capture(Root, Q),
    lists:usort([
        local_call_fact(N, Src, PathAtom)
     || {"callee", N} <- Caps
    ]).

local_call_fact(N, Src, PathAtom) ->
    CallNode = symbolic_ts:node_parent(N),
    {ArgCount, _Params} = args_shape(CallNode, "arguments", Src),
    {Caller, CallerArity} = caller_info(N, Src),
    {calls, Caller, CallerArity,
     {local, to_atom(symbolic_ts:node_text(N, Src)), ArgCount},
     PathAtom, line(N)}.

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
    {ArgCount, _Params} = args_shape(CallNode, "arguments", Src),
    {Caller, CallerArity} = caller_info(CallNode, Src),
    {calls, Caller, CallerArity,
     {member, to_atom(symbolic_ts:node_text(ObjNode, Src)),
      to_atom(symbolic_ts:node_text(PropNode, Src)), ArgCount},
     PathAtom, line(PropNode)}.

%% One branch/5 fact per decision point (see ?BRANCH_QUERIES), attributed
%% to its enclosing function via caller_info/2 — the exact same walk-up
%% local_call_fact/3 uses for calls/5's Caller/CallerArity.
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
%% compares, not just that it exists — branch/5 stops at "an if is
%% here." A node's own node_start_byte/1 is the identity (`Id`) this
%% fact family keys on: unlike every other fact so far, a rule over
%% this one needs to reference *one specific operand of one specific
%% expression*, possibly nested inside another expression on the same
%% Line, so (Fun, Arity, File, Line) alone isn't precise enough.
%%
%% binary_expression/unary_expression both have addressable
%% left/right/operator (binary) or argument/operator (unary, NOT
%% "operand" - confirmed empirically) fields, so one query each
%% captures every operator directly via node_text, unlike
%% ts_extract_erlang.erl's binary_op_expr/unary_op_expr which have no
%% fields at all and need one literal-token query per known operator.
%%
%% A nested expression (`x == y && z`) needs no special handling here:
%% binary_exprs/1 and unary_exprs/1's queries already match every
%% occurrence regardless of nesting depth, so the inner expression gets
%% its own expr/6 fact independently — operand_facts/7 just links to
%% the Id that fact already has, via node_start_byte/1 on the same node.
exprs(Lang, Root, Src, PathAtom) ->
    binary_exprs(Lang, Root, Src, PathAtom) ++ unary_exprs(Lang, Root, Src, PathAtom).

binary_exprs(Lang, Root, Src, PathAtom) ->
    {Q, _, _} = symbolic_ts:query_new(Lang, ?BINARY_EXPR_QUERY),
    Caps = symbolic_ts:query_capture(Root, Q),
    Nodes = lists:usort([N || {"b", N} <- Caps]),
    lists:flatmap(fun(N) -> binary_expr_facts(N, Src, PathAtom) end, Nodes).

binary_expr_facts(N, Src, PathAtom) ->
    Id = node_id(PathAtom, N),
    {Caller, CallerArity} = caller_info(N, Src),
    OpNode = symbolic_ts:node_child_by_field_name(N, "operator"),
    ExprFact = {expr, Id, Caller, CallerArity, binary, PathAtom, line(N)},
    OpFact = {expr_operator, Id, to_atom(symbolic_ts:node_text(OpNode, Src))},
    LeftNode = symbolic_ts:node_child_by_field_name(N, "left"),
    RightNode = symbolic_ts:node_child_by_field_name(N, "right"),
    [ExprFact, OpFact]
        ++ operand_facts(Id, left, LeftNode, Caller, CallerArity, Src, PathAtom)
        ++ operand_facts(Id, right, RightNode, Caller, CallerArity, Src, PathAtom).

unary_exprs(Lang, Root, Src, PathAtom) ->
    {Q, _, _} = symbolic_ts:query_new(Lang, ?UNARY_EXPR_QUERY),
    Caps = symbolic_ts:query_capture(Root, Q),
    Nodes = lists:usort([N || {"b", N} <- Caps]),
    lists:flatmap(fun(N) -> unary_expr_facts(N, Src, PathAtom) end, Nodes).

unary_expr_facts(N, Src, PathAtom) ->
    Id = node_id(PathAtom, N),
    {Caller, CallerArity} = caller_info(N, Src),
    OpNode = symbolic_ts:node_child_by_field_name(N, "operator"),
    ExprFact = {expr, Id, Caller, CallerArity, unary, PathAtom, line(N)},
    OpFact = {expr_operator, Id, to_atom(symbolic_ts:node_text(OpNode, Src))},
    ArgNode = symbolic_ts:node_child_by_field_name(N, "argument"),
    [ExprFact, OpFact] ++ operand_facts(Id, operand, ArgNode, Caller, CallerArity, Src, PathAtom).

%% Classify one operand node: a literal gets its own literal/7 fact, a
%% bare identifier gets expr_ref/6, and anything else (notably a nested
%% binary/unary expression — already captured independently, see
%% exprs/4's own doc comment) needs no new fact, just the expr_operand
%% link to the Id that capture already produced.
operand_facts(ParentId, Role, Node, Caller, CallerArity, Src, PathAtom) ->
    ChildId = node_id(PathAtom, Node),
    Link = {expr_operand, ParentId, Role, ChildId},
    case classify_literal(Node, Src) of
        {LitKind, Value} ->
            [Link, {literal, ChildId, Caller, CallerArity, LitKind, Value, PathAtom, line(Node)}];
        no ->
            case symbolic_ts:node_type(Node) of
                "identifier" ->
                    [Link, {expr_ref, ChildId, Caller, CallerArity,
                        to_atom(symbolic_ts:node_text(Node, Src)), PathAtom, line(Node)}];
                _ ->
                    [Link]
            end
    end.

%% number/string/true/false/null are TypeScript's own literal node
%% types. `string` wraps an unquoted string_fragment child (confirmed
%% empirically — no manual quote-stripping needed); an empty string
%% ("") has no such child at all.
classify_literal(Node, Src) ->
    case symbolic_ts:node_type(Node) of
        "number" -> {number, parse_number(symbolic_ts:node_text(Node, Src))};
        "string" -> {string, to_text(string_fragment_text(Node, Src))};
        "true" -> {boolean, true};
        "false" -> {boolean, false};
        "null" -> {null, null};
        _ -> no
    end.

string_fragment_text(Node, Src) ->
    case symbolic_ts:node_named_child_count(Node) of
        0 -> "";
        _ -> symbolic_ts:node_text(symbolic_ts:node_named_child(Node, 0), Src)
    end.

parse_number(Text) ->
    try list_to_integer(Text)
    catch error:badarg -> list_to_float(Text)
    end.

%% A node's identity for the expr/literal/expr_ref fact family. Needs
%% BOTH start and end byte, not start alone: a binary expression and
%% its own leftmost operand routinely start at the same byte (`x == x`
%% — the expression and its left `x` both start where `x` starts), so
%% {File, StartByte} alone collides — found empirically, by running
%% this against a real `x == x` snippet and seeing the left operand's
%% Id come back identical to its parent expression's. A byte SPAN can't
%% collide: no two distinct nodes in one parse occupy the identical
%% range. Every other fact so far keys on (Fun, Arity, File, Line)
%% alone; this family needs finer precision (see exprs/4's own doc
%% comment).
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

definition_name(Node, Src) ->
    case symbolic_ts:node_type(Node) of
        "function_declaration" ->
            NameNode = symbolic_ts:node_child_by_field_name(Node, "name"),
            {Arity, _Params} = args_shape(Node, "parameters", Src),
            {to_atom(symbolic_ts:node_text(NameNode, Src)), Arity};
        _ ->
            false
    end.

%% Walk up to the nearest enclosing function_declaration to attribute a
%% call site to the function it appears in — {Name, Arity}, or
%% {undefined, undefined} if the call isn't inside any recognized
%% definition. Arity comes from that same declaration's "parameters"
%% field, same technique as define_fact/3.
caller_info(Node, Src) ->
    case symbolic_ts:node_type(Node) of
        "function_declaration" ->
            NameNode = symbolic_ts:node_child_by_field_name(Node, "name"),
            {Arity, _Params} = args_shape(Node, "parameters", Src),
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

%% Comment text cleaning: strip `/** */`/`//`/leading `*` syntax and
%% join a run into one line — keeps output one-fact-per-line. Rendered
%% as a binary (ts_extract_text:to_text/1), not an atom — see
%% ts_extract_erlang.erl's identical clean_join/1 for why.
clean_join(Texts) ->
    Lines = lists:flatmap(fun to_lines/1, Texts),
    Cleaned = [clean_line(L) || L <- Lines],
    NonEmpty = [L || L <- Cleaned, L =/= ""],
    to_text(lists:flatten(lists:join(" ", NonEmpty))).

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
