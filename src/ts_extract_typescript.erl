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
%%%   calls(Caller, CallerArity, new(Constructor, ArgCount), File, Line)        — new X(...); bare-identifier
%%%                                                         constructors only, see new_calls/4
%%%   bare_new(Caller, CallerArity, Constructor, File, Line) — a `new X()` whose value is discarded
%%%                                                         outright (its own expression_statement)
%%%   import_decl(Module, File, Line)                    — an import_statement's raw module path
%%%   export_decl(Name, Kind, File, Line)                — Kind: named/default/wildcard; see exports/4
%%%   comment(File, Line, Text)                          — every comment, unconditionally
%%%   doc(Function, Arity, File, Line, Text)             — a comment run immediately
%%%                                                         preceding a function_declaration
%%%   doc_tag(Function, Arity, TagName, Type, Name, Description, File, Line)
%%%                                                       — one structured @-tag from a
%%%                                                         real `/** */` doc/5 comment,
%%%                                                         re-parsed via tree-sitter-jsdoc
%%%                                                         (symbolic_ts:tree_sitter_jsdoc/0);
%%%                                                         see ts_extract_jsdoc:tags/5
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
%%%   scope(ScopeId, Kind, ParentScopeId, File)          — Kind: function/block/module; see
%%%                                                         scope_facts/3
%%%   var_decl(Id, Name, Kind, ScopeId, File, Line)      — Kind: var/let/const/param/import (an
%%%                                                         import binding, scoped at module
%%%                                                         level — see imports/5)
%%%   var_ref(Id, Name, ScopeId, RefKind, File, Line)    — RefKind: read/write/read_write
%%%   resolves_to(RefId, DeclId)                         — DeclId is `undefined` if unresolved
%%%   var_decl_initialized(Id)                           — that var_decl has a "value" (initializer)
%%%   stmt_block(BlockId, Function, Arity, Kind, File, Line) — Kind: block/switch_case/
%%%                                                         switch_default; see stmt_blocks/4
%%%   stmt(Id, BlockId, Index, Kind, File, Line)         — a direct statement inside that
%%%                                                         block, in order; Kind is the raw
%%%                                                         node type (comments excluded)
%%%   last_switch_case(BlockId)                          — present only when no next
%%%                                                         case/default sibling exists
%%%   braceless_body(Function, Arity, Kind, File, Line)  — Kind: if/else/for/while whose
%%%                                                         body isn't a statement_block
%%%   return_stmt(Function, Arity, HasValue, File, Line) — HasValue: true/false
%%%
%%% scope/var_decl/var_ref/resolves_to are TypeScript-only (Erlang's
%%% variable model — single-assignment, pattern-bound, no var/let/const
%%% distinction — needs its own separate design) and deliberately don't
%%% handle destructuring (`let {a,b} = x`) or for-in/for-of — see
%%% scope_facts/3's own doc comment for the full boundary.
%%%
%%% stmt_block/stmt/last_switch_case/braceless_body/return_stmt are also
%%% TypeScript-only (Erlang has no brace-optional if/for/while and no
%%% separate `return` statement at all — every rule on top of these is a
%%% JS/TS-specific concept). `stmt/6` deliberately excludes comment
%%% children — a comment is an ordinary named child of whatever block
%%% contains it (confirmed by this module's own comment-handling code
%%% below, which navigates comments via sibling traversal), so including
%%% one would make a trailing comment after a `return` look like
%%% unreachable code.
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
-define(NEW_EXPR_QUERY, "(new_expression) @n").
-define(IMPORT_QUERY, "(import_statement) @i").
-define(EXPORT_QUERY, "(export_statement) @e").
-define(COMMENT_QUERY, "(comment) @c").

%% Statement/block structure: one query per block-shaped construct —
%% a real {} block, or a switch_case/switch_default, which have no
%% wrapping block node at all and need their own query (see
%% stmt_blocks/4's own doc comment).
-define(STMT_BLOCK_QUERIES, [
    {block, "(statement_block) @b"},
    {switch_case, "(switch_case) @b"},
    {switch_default, "(switch_default) @b"}
]).

-define(RETURN_STMT_QUERY, "(return_statement) @r").

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
        new_calls(Lang, Root, Src, PathAtom) ++
        comments(Lang, Root, Src, PathAtom) ++
        docs(Lang, Root, Src, PathAtom) ++
        branches(Lang, Root, Src, PathAtom) ++
        exprs(Lang, Root, Src, PathAtom) ++
        exports(Lang, Root, Src, PathAtom) ++
        scope_facts(Lang, Root, Src, PathAtom) ++
        stmt_blocks(Lang, Root, Src, PathAtom) ++
        braceless_bodies(Lang, Root, Src, PathAtom) ++
        return_stmts(Lang, Root, Src, PathAtom),
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

%% `new X(...)` — modeled as one more calls/5 CallSpec shape
%% (new(Constructor, ArgCount)), not a separate fact family: it's
%% conceptually a call, just spelled with `new`, the same way a
%% language-specific CallSpec already varies (local/member/remote) —
%% see this module's own header. Only a bare-identifier constructor is
%% tracked (`new foo.Bar()`'s qualified constructor is skipped, not
%% mis-tracked, same policy as every other "skip the complex case"
%% choice in this schema).
%%
%% `new Baz` (no parens at all — real, legal TS/JS) has a NULL
%% "arguments" field — confirmed the hard way: calling
%% node_named_child_count/1 on a null node segfaults the whole BEAM
%% (not a catchable Erlang error), so this checks node_is_null/1 first
%% and treats the paren-less form as ArgCount 0, same as `new Baz()`.
new_calls(Lang, Root, Src, PathAtom) ->
    {Q, _, _} = symbolic_ts:query_new(Lang, ?NEW_EXPR_QUERY),
    Caps = symbolic_ts:query_capture(Root, Q),
    Nodes = lists:usort([N || {"n", N} <- Caps]),
    lists:flatmap(fun(N) -> new_call_facts(N, Src, PathAtom) end, Nodes).

new_call_facts(N, Src, PathAtom) ->
    ConsNode = symbolic_ts:node_child_by_field_name(N, "constructor"),
    case symbolic_ts:node_type(ConsNode) of
        "identifier" ->
            Constructor = to_atom(symbolic_ts:node_text(ConsNode, Src)),
            ArgCount = new_expr_arg_count(N),
            {Caller, CallerArity} = caller_info(N, Src),
            CallFact = {calls, Caller, CallerArity, {new, Constructor, ArgCount}, PathAtom, line(N)},
            [CallFact | bare_new_fact(N, Caller, CallerArity, Constructor, PathAtom)];
        _ ->
            []
    end.

new_expr_arg_count(N) ->
    Args = symbolic_ts:node_child_by_field_name(N, "arguments"),
    case symbolic_ts:node_is_null(Args) of
        true -> 0;
        false -> symbolic_ts:node_named_child_count(Args)
    end.

%% bare_new/5: only when a `new X()`'s constructed value is discarded
%% outright — its immediate parent is an expression_statement, e.g.
%% `new Logger();` as its own statement, not `const x = new Logger();`
%% or `if (new Foo())`. Powers no_new/4 specifically; every other
%% new-expression rule just needs calls/5's new(...) shape above.
bare_new_fact(N, Caller, CallerArity, Constructor, PathAtom) ->
    case symbolic_ts:node_type(symbolic_ts:node_parent(N)) of
        "expression_statement" -> [{bare_new, Caller, CallerArity, Constructor, PathAtom, line(N)}];
        _ -> []
    end.

%% import_decl/4 (the raw module path, for no-duplicate-imports/
%% no-restricted-imports) plus one var_decl/6 (Kind='import') per
%% binding actually introduced — reusing the existing fact shape rather
%% than a parallel one, see scope_facts/4's own doc comment.
imports(Lang, Root, Src, PathAtom, ModuleScope) ->
    {Q, _, _} = symbolic_ts:query_new(Lang, ?IMPORT_QUERY),
    Caps = symbolic_ts:query_capture(Root, Q),
    Nodes = lists:usort([N || {"i", N} <- Caps]),
    lists:flatmap(fun(N) -> import_facts(N, Src, PathAtom, ModuleScope) end, Nodes).

import_facts(N, Src, PathAtom, ModuleScope) ->
    SourceNode = symbolic_ts:node_child_by_field_name(N, "source"),
    Module = to_atom(string_fragment_text(SourceNode, Src)),
    DeclFact = {import_decl, Module, PathAtom, line(N)},
    [DeclFact | import_bindings(N, Src, PathAtom, ModuleScope)].

%% import_statement's own named children besides "source": either
%% none at all (a side-effect-only `import "./x";`) or exactly one
%% import_clause — confirmed empirically, the clause (when present) is
%% always the first named child, "source" always the last.
import_bindings(N, Src, PathAtom, ModuleScope) ->
    case symbolic_ts:node_named_child_count(N) of
        2 -> import_clause_bindings(symbolic_ts:node_named_child(N, 0), Src, PathAtom, ModuleScope);
        _ -> []
    end.

%% A clause can hold more than one part at once (`import Foo, { a, b }
%% from "./x"` is valid) — walk every named child, not just the first.
import_clause_bindings(ClauseNode, Src, PathAtom, ModuleScope) ->
    N = symbolic_ts:node_named_child_count(ClauseNode),
    lists:flatmap(
        fun(I) -> import_clause_part(symbolic_ts:node_named_child(ClauseNode, I), Src, PathAtom, ModuleScope) end,
        lists:seq(0, N - 1)).

import_clause_part(Node, Src, PathAtom, ModuleScope) ->
    case symbolic_ts:node_type(Node) of
        "identifier" ->
            [import_binding_fact(Node, Src, PathAtom, ModuleScope)];
        "namespace_import" ->
            [import_binding_fact(symbolic_ts:node_named_child(Node, 0), Src, PathAtom, ModuleScope)];
        "named_imports" ->
            N = symbolic_ts:node_named_child_count(Node),
            lists:flatmap(
                fun(I) -> import_specifier_binding(symbolic_ts:node_named_child(Node, I), Src, PathAtom, ModuleScope) end,
                lists:seq(0, N - 1));
        _ -> []
    end.

%% import_specifier: one child (`{a}` — local name only) or two
%% (`{b as c}` — original, then alias). Either way the LAST child is
%% the real local binding this file uses (the alias, if one exists).
import_specifier_binding(SpecNode, Src, PathAtom, ModuleScope) ->
    case symbolic_ts:node_type(SpecNode) of
        "import_specifier" ->
            N = symbolic_ts:node_named_child_count(SpecNode),
            LocalNode = symbolic_ts:node_named_child(SpecNode, N - 1),
            [import_binding_fact(LocalNode, Src, PathAtom, ModuleScope)];
        _ -> []
    end.

import_binding_fact(IdNode, Src, PathAtom, ModuleScope) ->
    {var_decl, node_id(PathAtom, IdNode), to_atom(symbolic_ts:node_text(IdNode, Src)),
     'import', ModuleScope, PathAtom, line(IdNode)}.

%% export_decl/4: what name (if any) an export_statement makes public,
%% and under what shape (named/default/wildcard). A wrapped declaration
%% (`export function f() {}`, `export const x = 1`) needs no special
%% attribution walk of its own here — its "declaration" field is a real
%% function_declaration/lexical_declaration node, already walked
%% normally by walk_scope/5's generic fallthrough (defines/5, var_decl/6
%% etc. all still get produced exactly as if `export` weren't there).
exports(Lang, Root, Src, PathAtom) ->
    {Q, _, _} = symbolic_ts:query_new(Lang, ?EXPORT_QUERY),
    Caps = symbolic_ts:query_capture(Root, Q),
    Nodes = lists:usort([N || {"e", N} <- Caps]),
    lists:flatmap(fun(N) -> export_facts(N, Src, PathAtom) end, Nodes).

export_facts(N, Src, PathAtom) ->
    DeclNode = symbolic_ts:node_child_by_field_name(N, "declaration"),
    case symbolic_ts:node_is_null(DeclNode) of
        false -> exported_declaration_facts(DeclNode, Src, PathAtom);
        true -> exported_other_facts(N, Src, PathAtom)
    end.

exported_declaration_facts(DeclNode, Src, PathAtom) ->
    case symbolic_ts:node_type(DeclNode) of
        "function_declaration" ->
            NameNode = symbolic_ts:node_child_by_field_name(DeclNode, "name"),
            [{export_decl, to_atom(symbolic_ts:node_text(NameNode, Src)), named, PathAtom, line(NameNode)}];
        "lexical_declaration" -> exported_variable_names(DeclNode, Src, PathAtom);
        "variable_declaration" -> exported_variable_names(DeclNode, Src, PathAtom);
        _ -> []
    end.

%% `export const a = 1, b = 2;` — one export_decl/4 fact per declarator,
%% same "only a plain identifier name" limit walk_declaration/6 already
%% has for var_decl/6 (a destructured export name is skipped).
exported_variable_names(DeclNode, Src, PathAtom) ->
    N = symbolic_ts:node_named_child_count(DeclNode),
    lists:flatmap(
        fun(I) ->
            Declarator = symbolic_ts:node_named_child(DeclNode, I),
            case symbolic_ts:node_type(Declarator) of
                "variable_declarator" ->
                    NameNode = symbolic_ts:node_child_by_field_name(Declarator, "name"),
                    case symbolic_ts:node_type(NameNode) of
                        "identifier" ->
                            [{export_decl, to_atom(symbolic_ts:node_text(NameNode, Src)),
                              named, PathAtom, line(NameNode)}];
                        _ -> []
                    end;
                _ -> []
            end
        end, lists:seq(0, N - 1)).

%% An export_statement with a null "declaration" field: `export { ... }`
%% (dispatch to export_clause_facts/4), `export default ...` (Name is
%% always the literal atom 'default' — the export SLOT's own name in ES
%% module semantics, not whatever expression fills it), or
%% `export * from "...";` (Name is `undefined` — no specific name at all).
exported_other_facts(N, Src, PathAtom) ->
    case symbolic_ts:node_named_child_count(N) of
        0 -> [];
        _ ->
            Child = symbolic_ts:node_named_child(N, 0),
            case symbolic_ts:node_type(Child) of
                "export_clause" -> export_clause_facts(Child, Src, PathAtom, line(N));
                "string" -> [{export_decl, undefined, wildcard, PathAtom, line(N)}];
                _ -> [{export_decl, 'default', default, PathAtom, line(N)}]
            end
    end.

export_clause_facts(ClauseNode, Src, PathAtom, Line) ->
    N = symbolic_ts:node_named_child_count(ClauseNode),
    lists:flatmap(
        fun(I) -> export_specifier_fact(symbolic_ts:node_named_child(ClauseNode, I), Src, PathAtom, Line) end,
        lists:seq(0, N - 1)).

%% export_specifier: one child (`{a}` — exported under its own name) or
%% two (`{b as d}` — local, then the chosen public alias). Either way
%% the LAST child is the real PUBLIC name consumers of this module see
%% — the opposite half of import_specifier_binding/4's identical "last
%% child wins" rule, which cares about the LOCAL name instead.
export_specifier_fact(SpecNode, Src, PathAtom, Line) ->
    case symbolic_ts:node_type(SpecNode) of
        "export_specifier" ->
            N = symbolic_ts:node_named_child_count(SpecNode),
            PublicNode = symbolic_ts:node_named_child(SpecNode, N - 1),
            [{export_decl, to_atom(symbolic_ts:node_text(PublicNode, Src)), named, PathAtom, Line}];
        _ -> []
    end.

%% stmt_block/6 + stmt/6 + last_switch_case/1: statement/block
%% structure. A real {} block (statement_block) and the two switch-arm
%% shapes (switch_case/switch_default, which have no wrapping block
%% node at all — their own children ARE their statement list directly,
%% confirmed empirically) all need the same treatment, just via
%% different queries (see ?STMT_BLOCK_QUERIES) since each is captured
%% by a different node type.
stmt_blocks(Lang, Root, Src, PathAtom) ->
    lists:flatmap(
        fun({Kind, Query}) -> stmt_block_facts(Lang, Root, Src, PathAtom, Kind, Query) end,
        ?STMT_BLOCK_QUERIES).

stmt_block_facts(Lang, Root, Src, PathAtom, Kind, Query) ->
    {Q, _, _} = symbolic_ts:query_new(Lang, Query),
    Caps = symbolic_ts:query_capture(Root, Q),
    Nodes = lists:usort([N || {"b", N} <- Caps]),
    lists:flatmap(fun(N) -> stmt_block_fact_set(N, Src, PathAtom, Kind) end, Nodes).

stmt_block_fact_set(N, Src, PathAtom, Kind) ->
    BlockId = node_id(PathAtom, N),
    {Caller, CallerArity} = caller_info(N, Src),
    BlockFact = {stmt_block, BlockId, Caller, CallerArity, Kind, PathAtom, line(N)},
    SkipNode = case Kind of
        switch_case -> symbolic_ts:node_child_by_field_name(N, "value");
        _ -> undefined
    end,
    StmtFacts = block_stmt_facts(N, BlockId, SkipNode, PathAtom),
    LastCaseFact =
        case Kind of
            block -> [];
            _ -> last_switch_case_fact(N, BlockId)
        end,
    [BlockFact | StmtFacts] ++ LastCaseFact.

%% Every named child of the block/case/default IS a direct statement,
%% in source order, except a comment — a comment is an ordinary named
%% child of its enclosing block (see this module's own header comment
%% for why), and including one here would make an entirely ordinary
%% trailing comment after a `return` look like unreachable code — and,
%% for a switch_case specifically, its own case *value* (`case 1:`'s
%% `1`, confirmed to be its own addressable "value" field, always its
%% first child in practice but identified by field, not position): a
%% real bug found by actually running this against a `case 1: case 2:
%% foo(); break;`-shaped switch — including the value as a "statement"
%% meant an empty case (`case 1:` alone, immediately falling into the
%% next) could never register as truly empty, defeating the whole
%% point of the empty-case-stacking exemption `no_fallthrough_case/5`
%% needs. Compared by identity (matching byte span), not position, so
%% it's correct regardless of where the grammar actually places it.
block_stmt_facts(BlockNode, BlockId, SkipNode, PathAtom) ->
    SkipId = case SkipNode of
        undefined -> undefined;
        _ -> case symbolic_ts:node_is_null(SkipNode) of
            true -> undefined;
            false -> node_id(PathAtom, SkipNode)
        end
    end,
    N = symbolic_ts:node_named_child_count(BlockNode),
    lists:filtermap(
        fun(Index) ->
            Child = symbolic_ts:node_named_child(BlockNode, Index),
            ChildId = node_id(PathAtom, Child),
            case {symbolic_ts:node_type(Child), ChildId} of
                {"comment", _} -> false;
                {_, SkipId} -> false;
                {Type, _} -> {true, {stmt, ChildId, BlockId, Index, to_atom(Type), PathAtom, line(Child)}}
            end
        end, lists:seq(0, N - 1)).

%% A switch_case/switch_default is "last" for fallthrough purposes when
%% nothing case-shaped follows it — its own next sibling is either
%% `undefined` (genuinely the last child in switch_body) or some other
%% non-case node (none exist in practice, but this doesn't assume that).
last_switch_case_fact(N, BlockId) ->
    case symbolic_ts:node_next_sibling(N) of
        undefined -> [{last_switch_case, BlockId}];
        Next ->
            case symbolic_ts:node_type(Next) of
                "switch_case" -> [];
                "switch_default" -> [];
                _ -> [{last_switch_case, BlockId}]
            end
    end.

%% braceless_body/5: an if/else/for/while whose body is a single bare
%% statement, not a real {} block — if_statement uses "consequence"/
%% "alternative" fields, for_statement/while_statement use "body",
%% confirmed empirically (different field names per construct, same
%% story as every other per-construct field lookup in this module).
braceless_bodies(Lang, Root, Src, PathAtom) ->
    if_braceless_bodies(Lang, Root, Src, PathAtom)
        ++ loop_braceless_bodies(Lang, Root, Src, PathAtom, 'for', "(for_statement) @b")
        ++ loop_braceless_bodies(Lang, Root, Src, PathAtom, 'while', "(while_statement) @b").

if_braceless_bodies(Lang, Root, Src, PathAtom) ->
    {Q, _, _} = symbolic_ts:query_new(Lang, "(if_statement) @b"),
    Caps = symbolic_ts:query_capture(Root, Q),
    Nodes = lists:usort([N || {"b", N} <- Caps]),
    lists:flatmap(
        fun(N) ->
            {Caller, CallerArity} = caller_info(N, Src),
            braceless_field_fact(N, "consequence", 'if', Caller, CallerArity, PathAtom, Src)
                ++ else_braceless_fact(N, Caller, CallerArity, PathAtom)
        end, Nodes).

%% "alternative" is always wrapped in an else_clause node (confirmed
%% empirically — unlike "consequence", which holds the statement
%% directly), so it's unwrapped before the same brace check applies.
%% An `else if` chain (else_clause's own child is itself an
%% if_statement) is never a curly violation for the else branch
%% itself — that's ordinary chaining, and the nested if is checked
%% independently for its own consequence/alternative.
else_braceless_fact(IfNode, Caller, CallerArity, PathAtom) ->
    Alt = symbolic_ts:node_child_by_field_name(IfNode, "alternative"),
    case symbolic_ts:node_is_null(Alt) of
        true -> [];
        false ->
            Body = symbolic_ts:node_named_child(Alt, 0),
            case symbolic_ts:node_type(Body) of
                "statement_block" -> [];
                "if_statement" -> [];
                _ -> [{braceless_body, Caller, CallerArity, 'else', PathAtom, line(Body)}]
            end
    end.

loop_braceless_bodies(Lang, Root, Src, PathAtom, Kind, Query) ->
    {Q, _, _} = symbolic_ts:query_new(Lang, Query),
    Caps = symbolic_ts:query_capture(Root, Q),
    Nodes = lists:usort([N || {"b", N} <- Caps]),
    lists:flatmap(
        fun(N) ->
            {Caller, CallerArity} = caller_info(N, Src),
            braceless_field_fact(N, "body", Kind, Caller, CallerArity, PathAtom, Src)
        end, Nodes).

%% A field is only present (an `else` may not exist at all — node_is_null
%% guards that, same as every other optional-field lookup in this
%% module) and only reported when its own node type isn't statement_block.
braceless_field_fact(N, FieldName, Kind, Caller, CallerArity, PathAtom, _Src) ->
    Field = symbolic_ts:node_child_by_field_name(N, FieldName),
    case symbolic_ts:node_is_null(Field) of
        true -> [];
        false ->
            case symbolic_ts:node_type(Field) of
                "statement_block" -> [];
                _ -> [{braceless_body, Caller, CallerArity, Kind, PathAtom, line(Field)}]
            end
    end.

%% return_stmt/5: HasValue is whether a return_statement wraps a value
%% (`return x;`) or not (a bare `return;`, zero named children —
%% confirmed empirically). Powers consistent_return/3 in
%% .symbolic/rules.pl, which needs no path-sensitive control-flow
%% analysis at all — just every return in one function agreeing on
%% whether it specifies a value.
return_stmts(Lang, Root, Src, PathAtom) ->
    {Q, _, _} = symbolic_ts:query_new(Lang, ?RETURN_STMT_QUERY),
    Caps = symbolic_ts:query_capture(Root, Q),
    Nodes = lists:usort([N || {"r", N} <- Caps]),
    lists:map(fun(N) -> return_stmt_fact(N, Src, PathAtom) end, Nodes).

return_stmt_fact(N, Src, PathAtom) ->
    {Caller, CallerArity} = caller_info(N, Src),
    HasValue = symbolic_ts:node_named_child_count(N) > 0,
    {return_stmt, Caller, CallerArity, HasValue, PathAtom, line(N)}.

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

%% JS/TS numeric literals allow three things Erlang's own
%% list_to_integer/1 and list_to_float/1 don't understand at all, so the
%% raw node text needs normalizing before either BIF sees it (issue #1 —
%% confirmed empirically, not assumed: list_to_integer("0b100000")
%% badargs exactly like list_to_integer("0b1_00000") does, so a fix that
%% only strips `_` is incomplete):
%%   - `_` as a purely cosmetic digit separator (5_000, 1_000_000) —
%%     stripped outright, same treatment real JS/TS engines give it.
%%   - a `0x`/`0b`/`0o` radix prefix (0x1F, 0b101, 0o17) — Erlang's
%%     list_to_integer/1 has no concept of one at all; parsed via the
%%     2-arity `list_to_integer(Digits, Base)` instead, prefix stripped.
%%   - a trailing BigInt `n` suffix (100n, 0x1Fn) — Erlang integers are
%%     already arbitrary-precision, so this is just stripped; the value
%%     underneath is parsed the same way as a non-BigInt integer.
%% Order matters: strip `_` and the `n` suffix BEFORE checking for a
%% radix prefix, so `0x1_Fn` normalizes to `0x1F` before the prefix check
%% ever runs.
parse_number(Text0) ->
    Text1 = [C || C <- Text0, C =/= $_],
    Text2 = strip_bigint_suffix(Text1),
    parse_normalized_number(Text2).

strip_bigint_suffix(Text) ->
    case lists:last(Text) of
        $n -> lists:droplast(Text);
        _ -> Text
    end.

parse_normalized_number([$0, Radix | Digits]) when Radix =:= $x; Radix =:= $X ->
    list_to_integer(Digits, 16);
parse_normalized_number([$0, Radix | Digits]) when Radix =:= $b; Radix =:= $B ->
    list_to_integer(Digits, 2);
parse_normalized_number([$0, Radix | Digits]) when Radix =:= $o; Radix =:= $O ->
    list_to_integer(Digits, 8);
parse_normalized_number(Text) ->
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

%% Variable/scope facts: scope/4, var_decl/6, var_ref/6, resolves_to/2.
%% Unlike every other fact family in this module, this isn't a flat
%% query_capture/2 pass — no single query pattern can express "which
%% scope is this identifier in," so this is a real top-down recursive
%% walk over the whole tree instead, threading two accumulators:
%% Scope (the nearest enclosing scope, for let/const/param and for
%% where a reference starts its lookup) and FuncScope (the nearest
%% enclosing function-or-module scope, for `var`'s hoisting — a `var`
%% declared inside a nested block still belongs to the function, not
%% the block, confirmed against real nested-block/for-loop snippets;
%% see docs/prolog-schema.md).
%%
%% Two passes, not one: walk_scope/5 below only collects scope/var_decl
%% facts and *raw* references (Name, starting Scope, RefKind — not yet
%% resolved), then resolve_refs/3 resolves every reference against the
%% complete declaration set once the whole tree has been walked. A
%% single combined pass would get this wrong for a reference that
%% textually precedes its own declaration in the same block.
%%
%% Deliberately out of scope (skipped, not mis-tracked): destructured
%% declarations/assignments (`let {a,b} = x`, `[a,b] = x`) — a
%% variable_declarator's "name" field or an assignment's "left" field
%% that isn't a bare identifier is silently not turned into a fact;
%% for-in/for-of (same mechanism as for_statement, needs its own field
%% verification); a globals allowlist — resolves_to(Ref, undefined)
%% means "not declared in anything this walk tracked," which includes
%% every real global (console, Math, ...), not just genuine bugs.
%% Lang (unlike everywhere else this walk needs no query) is only here
%% to hand to imports/5: import bindings are emitted as ordinary
%% var_decl/6 facts (Kind='import', scoped at module level, since ES
%% imports are always top-level) rather than a parallel fact family —
%% unused_var/4, shadowed_var/5, etc. from .symbolic/rules.pl already
%% apply to an unused/shadowed import for free as a result.
%%
%% ImportFacts is computed BEFORE resolve_refs/3, not after — a real
%% bug found by actually running this against a file with both an
%% import and a later reference to it: resolve_refs/3 only ever saw
%% walk_scope/5's own DeclFacts, so an import binding didn't exist yet
%% as far as the resolver was concerned, and EVERY reference to an
%% imported name came back resolves_to(_, undefined) — indistinguishable
%% from a genuinely undeclared name, anywhere in the file, not just
%% inside an export specifier. resolve_refs/3's DeclIndex builder
%% already pattern-matches specifically on {var_decl, ...} tuples (a
%% list comprehension, safe to feed it import_decl/4 facts mixed in too
%% — they're simply ignored), so folding ImportFacts into the same
%% DeclFacts list resolve_refs/3 consults is the whole fix.
scope_facts(Lang, Root, Src, PathAtom) ->
    ModuleScope = node_id(PathAtom, Root),
    {DeclFacts, ScopeFacts, RawRefs} = walk_scope(Root, ModuleScope, ModuleScope, Src, PathAtom),
    AllScopeFacts = [{scope, ModuleScope, module, none, PathAtom} | ScopeFacts],
    ImportFacts = imports(Lang, Root, Src, PathAtom, ModuleScope),
    AllDeclFacts = DeclFacts ++ ImportFacts,
    RefFacts = resolve_refs(RawRefs, AllDeclFacts, AllScopeFacts),
    AllScopeFacts ++ AllDeclFacts ++ RefFacts.

%% -> {DeclFacts, ScopeFacts, RawRefs}; RawRefs :: [{RefId, Name, Scope, RefKind, Line}]
walk_scope(Node, Scope, FuncScope, Src, PathAtom) ->
    case symbolic_ts:node_is_null(Node) of
        true ->
            {[], [], []};
        false ->
            case symbolic_ts:node_type(Node) of
                "function_declaration" -> walk_function(Node, Scope, Src, PathAtom);
                "function_expression" -> walk_function(Node, Scope, Src, PathAtom);
                "arrow_function" -> walk_function(Node, Scope, Src, PathAtom);
                "statement_block" -> walk_block(Node, Scope, FuncScope, Src, PathAtom);
                "for_statement" -> walk_for(Node, Scope, FuncScope, Src, PathAtom);
                "lexical_declaration" ->
                    walk_declaration(Node, Scope, FuncScope, Src, PathAtom, decl_kind_of_lexical(Node, Src));
                "variable_declaration" ->
                    walk_declaration(Node, Scope, FuncScope, Src, PathAtom, 'var');
                "assignment_expression" -> walk_assignment(Node, Scope, FuncScope, Src, PathAtom, write);
                "augmented_assignment_expression" ->
                    walk_assignment(Node, Scope, FuncScope, Src, PathAtom, read_write);
                "import_statement" ->
                    %% Import bindings are handled entirely by imports/5
                    %% (they're declarations, introduced here, not
                    %% references) — recursing generically would treat
                    %% every imported name as a phantom read instead.
                    {[], [], []};
                "export_specifier" ->
                    %% `export { a, b as d }`: child 0 (a/b) is a real
                    %% reference to an existing local binding, worth
                    %% walking normally; a second child, if present
                    %% (d), is only the chosen PUBLIC name — not a
                    %% reference to anything, so it's deliberately not
                    %% visited (export_decl/4 in .symbolic/rules.pl
                    %% captures it directly, via exports/4's own pass).
                    walk_scope(symbolic_ts:node_named_child(Node, 0), Scope, FuncScope, Src, PathAtom);
                "identifier" ->
                    {[], [], [{node_id(PathAtom, Node), to_atom(symbolic_ts:node_text(Node, Src)),
                               Scope, read, line(Node)}]};
                _ -> walk_children(Node, Scope, FuncScope, Src, PathAtom)
            end
    end.

%% Generic recurse: every named child, same Scope/FuncScope, facts merged.
walk_children(Node, Scope, FuncScope, Src, PathAtom) ->
    N = symbolic_ts:node_named_child_count(Node),
    lists:foldl(
        fun(I, {Ds, Ss, Rs}) ->
            {D1, S1, R1} = walk_scope(symbolic_ts:node_named_child(Node, I), Scope, FuncScope, Src, PathAtom),
            {Ds ++ D1, Ss ++ S1, Rs ++ R1}
        end, {[], [], []}, lists:seq(0, N - 1)).

%% function_declaration/function_expression/arrow_function all become a
%% new `function`-kind scope covering both their parameters and body.
walk_function(Node, ParentScope, Src, PathAtom) ->
    NewScope = node_id(PathAtom, Node),
    ScopeFact = {scope, NewScope, function, ParentScope, PathAtom},
    ParamDecls = param_decls(Node, NewScope, Src, PathAtom),
    Body = symbolic_ts:node_child_by_field_name(Node, "body"),
    {BodyDecls, BodyScopes, BodyRefs} = walk_body(Body, NewScope, Src, PathAtom),
    {ParamDecls ++ BodyDecls, [ScopeFact | BodyScopes], BodyRefs}.

%% The function's own immediate body gets no *extra* block scope of its
%% own (a param and a body-level `let` of the same name are meant to
%% collide in the same scope, not shadow across an invisible extra
%% layer) — recurse into its children directly rather than dispatching
%% back through walk_scope/5, which would create one via the
%% "statement_block" -> walk_block/4 case. An arrow function's bare
%% expression body (`x => x + 1`, no block at all) has no such concern.
walk_body(Body, FuncScope, Src, PathAtom) ->
    case symbolic_ts:node_type(Body) of
        "statement_block" -> walk_children(Body, FuncScope, FuncScope, Src, PathAtom);
        _ -> walk_scope(Body, FuncScope, FuncScope, Src, PathAtom)
    end.

%% A function/arrow's parameters: `parameter` (singular) is the bare
%% identifier of a single unparenthesized arrow param (`x => ...` — no
%% formal_parameters wrapper at all, confirmed empirically); otherwise
%% `parameters` wraps one required_parameter/optional_parameter per
%% param. A destructured parameter (`{a,b}`) has no plain identifier at
%% its own first named child and is silently skipped — out of scope.
param_decls(FnNode, Scope, Src, PathAtom) ->
    Bare = symbolic_ts:node_child_by_field_name(FnNode, "parameter"),
    case symbolic_ts:node_is_null(Bare) of
        false ->
            [param_decl_fact(Bare, Scope, Src, PathAtom)];
        true ->
            Params = symbolic_ts:node_child_by_field_name(FnNode, "parameters"),
            case symbolic_ts:node_is_null(Params) of
                true -> [];
                false ->
                    N = symbolic_ts:node_named_child_count(Params),
                    lists:filtermap(
                        fun(I) ->
                            Wrapper = symbolic_ts:node_named_child(Params, I),
                            case identifier_of(Wrapper) of
                                {ok, IdNode} -> {true, param_decl_fact(IdNode, Scope, Src, PathAtom)};
                                error -> false
                            end
                        end, lists:seq(0, N - 1))
            end
    end.

%% A parameter wrapper's own bare name — itself if already an
%% identifier, else its first named child if THAT'S an identifier.
%% Anything else (a destructured pattern) is out of scope for v1.
identifier_of(Node) ->
    case symbolic_ts:node_type(Node) of
        "identifier" ->
            {ok, Node};
        _ ->
            case symbolic_ts:node_named_child_count(Node) of
                0 -> error;
                _ ->
                    Child = symbolic_ts:node_named_child(Node, 0),
                    case symbolic_ts:node_type(Child) of
                        "identifier" -> {ok, Child};
                        _ -> error
                    end
            end
    end.

param_decl_fact(IdNode, Scope, Src, PathAtom) ->
    {var_decl, node_id(PathAtom, IdNode), to_atom(symbolic_ts:node_text(IdNode, Src)),
     param, Scope, PathAtom, line(IdNode)}.

%% Any other statement_block (an if/while/try/bare-block body) — a new
%% `block`-kind scope, FuncScope unchanged (blocks never host `var`'s
%% hoisting target).
walk_block(Node, ParentScope, FuncScope, Src, PathAtom) ->
    NewScope = node_id(PathAtom, Node),
    ScopeFact = {scope, NewScope, block, ParentScope, PathAtom},
    {Ds, Ss, Rs} = walk_children(Node, NewScope, FuncScope, Src, PathAtom),
    {Ds, [ScopeFact | Ss], Rs}.

%% A for-loop's header (`for (let i = 0; ...)`) is its own block scope,
%% covering the header's own declarations; its body statement_block, if
%% present, gets a further nested block scope of its own via the normal
%% walk_children -> walk_scope dispatch — one extra harmless scope
%% layer, not a correctness problem (nothing needs to see across it
%% from outside the loop either way).
walk_for(Node, ParentScope, FuncScope, Src, PathAtom) ->
    NewScope = node_id(PathAtom, Node),
    ScopeFact = {scope, NewScope, block, ParentScope, PathAtom},
    {Ds, Ss, Rs} = walk_children(Node, NewScope, FuncScope, Src, PathAtom),
    {Ds, [ScopeFact | Ss], Rs}.

%% lexical_declaration (let/const) or variable_declaration (var) — Kind
%% decides which scope accumulator the declaration lands in: `var`
%% hoists to FuncScope, let/const/param stay in the immediate Scope.
%% Only a plain-identifier "name" becomes a var_decl (destructured names
%% are skipped, not mis-tracked); the initializer ("value") is walked
%% normally so identifiers inside it become ordinary references.
%%
%% var_decl_initialized/1 is a separate, additive fact (not a wider
%% var_decl/7) recording whether a declarator actually has a "value" —
%% `.symbolic/rules.pl`'s prefer_const/4 needs it to avoid ever
%% suggesting `const x;` for a bare `let x;`, which isn't valid syntax.
walk_declaration(Node, Scope, FuncScope, Src, PathAtom, Kind) ->
    DeclScope = case Kind of 'var' -> FuncScope; _ -> Scope end,
    N = symbolic_ts:node_named_child_count(Node),
    lists:foldl(
        fun(I, {Ds, Ss, Rs}) ->
            Declarator = symbolic_ts:node_named_child(Node, I),
            case symbolic_ts:node_type(Declarator) of
                "variable_declarator" ->
                    NameNode = symbolic_ts:node_child_by_field_name(Declarator, "name"),
                    ValueNode = symbolic_ts:node_child_by_field_name(Declarator, "value"),
                    HasValue = not symbolic_ts:node_is_null(ValueNode),
                    DeclFacts =
                        case symbolic_ts:node_type(NameNode) of
                            "identifier" ->
                                DeclId = node_id(PathAtom, NameNode),
                                [{var_decl, DeclId, to_atom(symbolic_ts:node_text(NameNode, Src)),
                                  Kind, DeclScope, PathAtom, line(NameNode)}]
                                ++ [{var_decl_initialized, DeclId} || HasValue];
                            _ -> []
                        end,
                    {ValDs, ValSs, ValRs} =
                        case HasValue of
                            false -> {[], [], []};
                            true -> walk_scope(ValueNode, Scope, FuncScope, Src, PathAtom)
                        end,
                    {Ds ++ DeclFacts ++ ValDs, Ss ++ ValSs, Rs ++ ValRs};
                _ ->
                    {Ds, Ss, Rs}
            end
        end, {[], [], []}, lists:seq(0, N - 1)).

%% `let`/`const` are the SAME node type (lexical_declaration) — the
%% grammar doesn't distinguish them structurally, confirmed empirically
%% (a literal-token query matches either). node_text/2 on the
%% declaration's own span starts exactly at the keyword (no leading
%% whitespace), so a prefix check is reliable here — there's no
%% per-node literal-token query available mid-walk the way there is for
%% a query_capture/2 pass.
decl_kind_of_lexical(Node, Src) ->
    case lists:prefix("const", symbolic_ts:node_text(Node, Src)) of
        true -> const;
        false -> 'let'
    end.

%% assignment_expression (RefKind write) / augmented_assignment_expression
%% (RefKind read_write, e.g. `+=` — it reads the old value too). Only a
%% plain-identifier "left" becomes a reference (a destructured target
%% is skipped); "right" is walked normally.
walk_assignment(Node, Scope, FuncScope, Src, PathAtom, RefKind) ->
    LeftNode = symbolic_ts:node_child_by_field_name(Node, "left"),
    RightNode = symbolic_ts:node_child_by_field_name(Node, "right"),
    LeftRefs =
        case symbolic_ts:node_type(LeftNode) of
            "identifier" ->
                [{node_id(PathAtom, LeftNode), to_atom(symbolic_ts:node_text(LeftNode, Src)),
                  Scope, RefKind, line(LeftNode)}];
            _ -> []
        end,
    {RightDs, RightSs, RightRs} = walk_scope(RightNode, Scope, FuncScope, Src, PathAtom),
    {RightDs, RightSs, LeftRefs ++ RightRs}.

%% Resolves every raw reference against the complete scope/declaration
%% set built by walk_scope/5 — a plain scope-chain walk (nearest
%% enclosing scope with a matching Name wins, which is exactly
%% shadowing precedence), computed once here rather than left for
%% Prolog to re-walk per query, the same design choice caller_info/2
%% already makes for call attribution.
%% DeclFacts also carries var_decl_initialized/1 facts alongside
%% var_decl/6 ones (walk_declaration/6 emits both from the same
%% declarator) — the comprehension below picks out only the var_decl
%% ones building this index, rather than a foldl whose fun only has a
%% clause for var_decl and crashes on anything else in the same list
%% (found by actually running this against a real `let x = 1;` snippet,
%% not assumed).
resolve_refs(RawRefs, DeclFacts, ScopeFacts) ->
    ScopeIndex = maps:from_list([{Id, Parent} || {scope, Id, _Kind, Parent, _File} <- ScopeFacts]),
    DeclIndex = maps:from_list(
        [{{Scope, Name}, Id} || {var_decl, Id, Name, _Kind, Scope, _File, _Line} <- DeclFacts]),
    lists:flatmap(
        fun({RefId, Name, Scope, RefKind, Line}) ->
            DeclId = resolve_lookup(Name, Scope, ScopeIndex, DeclIndex),
            {PathAtom, _Start, _End} = RefId,
            [{var_ref, RefId, Name, Scope, RefKind, PathAtom, Line},
             {resolves_to, RefId, DeclId}]
        end, RawRefs).

resolve_lookup(Name, Scope, ScopeIndex, DeclIndex) ->
    case maps:find({Scope, Name}, DeclIndex) of
        {ok, DeclId} -> DeclId;
        error ->
            case maps:find(Scope, ScopeIndex) of
                {ok, Parent} when Parent =/= none -> resolve_lookup(Name, Parent, ScopeIndex, DeclIndex);
                _ -> undefined
            end
    end.

comments(Lang, Root, Src, PathAtom) ->
    lists:usort([
        {comment, PathAtom, line(N), clean_join([symbolic_ts:node_text(N, Src)])}
     || N <- comment_nodes(Lang, Root)
    ]).

docs(Lang, Root, Src, PathAtom) ->
    RunStarts = [N || N <- comment_nodes(Lang, Root), is_run_start(N)],
    lists:flatmap(fun(Start) -> doc_facts(Start, Src, PathAtom) end, RunStarts).

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

doc_facts(StartNode, Src, PathAtom) ->
    {Texts, Target} = collect_run(StartNode, Src, []),
    case Target =/= undefined andalso definition_name(Target, Src) of
        false -> [];
        {Name, Arity} ->
            DocFact = {doc, Name, Arity, PathAtom, line(Target), clean_join(Texts)},
            [DocFact | jsdoc_tag_facts(Name, Arity, PathAtom, StartNode, Texts)]
    end.

%% Structured @-tag facts, on top of the flattened doc/5 Text above —
%% only attempted for a genuine single JSDoc block comment (`/** ... */`),
%% never a run of consecutive `//` lines or a plain non-doc `/* */` block:
%% the jsdoc grammar's own `_begin`/`_end` rules require exactly those
%% delimiters to parse at all (confirmed empirically — see
%% ts_extract_jsdoc.erl's own header comment), and only ONE raw comment's
%% own text is valid input to it, never clean_join's flattened,
%% delimiter-stripped join of a whole run.
jsdoc_tag_facts(Name, Arity, PathAtom, StartNode, [RawText]) ->
    case lists:prefix("/**", RawText) of
        true -> ts_extract_jsdoc:tags(Name, Arity, PathAtom, line(StartNode), RawText);
        false -> []
    end;
jsdoc_tag_facts(_Name, _Arity, _PathAtom, _StartNode, _Texts) ->
    [].

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
