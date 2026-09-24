%%% Extract Prolog facts from one Bash script via tree-sitter
%%% (symbolic_ts). See docs/tree-sitter-erlang.md §5.
%%%
%%% Same shape as ts_extract_erlang.erl/ts_extract_typescript.erl —
%%% Bash has real functions and call sites, unlike TOML/JSON, so
%%% `defines`/`calls`/`comment`/`doc` apply directly, not the
%%% `config_value`/`config_section` shape those two use:
%%%
%%%   defines(Function, Arity, Params, File, Line)   — Arity/Params always
%%%                                                     `undefined`: bash
%%%                                                     functions have no
%%%                                                     parameter-list
%%%                                                     grammar node at all
%%%   calls(Caller, CallerArity, local(Command, ArgCount), File, Line) —
%%%                              CallerArity is always `undefined` (same
%%%                              reason as defines/5's), and ArgCount is
%%%                              a word count, not a validated arity
%%%                              (bash has none)
%%%   comment(File, Line, Text)
%%%   doc(Function, Arity, File, Line, Text)
%%%   branch(Function, Arity, Kind, File, Line)     — a decision point (if/elif/for/while/
%%%                                                     case_item) inside Function; Arity is
%%%                                                     always `undefined`, same reason as
%%%                                                     defines/5's. See ?BRANCH_QUERIES and
%%%                                                     .symbolic/rules.pl's real_complexity/4
%%%
%%% Only `local(Command)` — no `remote`/`member` distinction the way
%%% Erlang/TypeScript have, since Bash has no qualified/namespaced call
%%% syntax to tell apart from a bare one. `Command` is whatever name
%%% appears in command position, whether or not it resolves to a
%%% function actually defined in this same file (an external program
%%% like `scp`, a builtin like `echo`, and a local function all look
%%% the same syntactically — Bash doesn't distinguish them at parse
%%% time, so neither do we).
%%%
%%% Confirmed by parsing a sample and reading node_string/1's output,
%%% not assumed: `function_definition` and top-level `command`/
%%% `comment` nodes are direct children of the `program` root and of
%%% each other's enclosing `compound_statement` body — same
%%% node_parent/1 walk-up for caller attribution, and the same sibling
%%% relationship between a `comment` and the `function_definition` it
%%% precedes, that ts_extract_erlang.erl already established. A
%%% `command`'s own name is exposed as a `command_name` field on the
%%% `command` node — a query for `(command name: (command_name) @cmd)`
%%% (not a bare word/string) gets exactly the command name text
%%% directly, no unwrapping needed.
-module(ts_extract_bash).
-export([file/1, text/2]).
-import(ts_extract_text, [to_atom/1, to_text/1]).

-define(DEF_QUERY, "(function_definition name: (word) @fun_name)").
-define(CALL_QUERY, "(command name: (command_name) @callee)").
-define(COMMENT_QUERY, "(comment) @c").

%% One query per decision-point construct, for real (McCabe-style)
%% complexity instead of the fan_out/3-based proxy too_complex/3 uses.
%% if_statement alone only counts the initial `if` of an if/elif/.../else
%% chain — unlike TypeScript, Bash nests `elif` as a SIBLING clause
%% inside the same if_statement, not as another nested if_statement, so
%% elif_clause needs its own query or every elif goes uncounted (confirmed
%% empirically). case_item includes the `*)` wildcard/default arm too —
%% Bash doesn't structurally distinguish it from a real case the way
%% TypeScript's switch_case/switch_default split does; a known
%% simplification, not a bug. `&&`/`||` chaining (a `list` node) is
%% deliberately not here yet — the operator token isn't a named child or
%% an addressable field the way TypeScript's binary_expression is; needs
%% its own grammar spike.
-define(BRANCH_QUERIES, [
    {'if', "(if_statement) @b"},
    {elif, "(elif_clause) @b"},
    {'for', "(for_statement) @b"},
    {'while', "(while_statement) @b"},
    {case_item, "(case_item) @b"}
]).

-spec file(file:filename()) -> [tuple()].
file(Path) ->
    {ok, Bin} = file:read_file(Path),
    %% Pass the binary straight through — see ts_extract_erlang:file/1's
    %% identical comment and symbolic_ts:node_text/2's own for why.
    text(Path, Bin).

%% Same extraction as file/1, but against an already-in-memory source
%% (binary or list — see below) rather than a file on disk — used by
%% ts_extract_markdown to run this extractor against a fenced
%% `sh`/`bash` code block's contents, with `Path` set to the enclosing
%% Markdown file (not a real .sh file).
-spec text(file:filename(), string() | binary()) -> [tuple()].
text(Path, Src0) ->
    {ok, Parser} = symbolic_ts:parser_new(),
    {ok, Lang} = symbolic_ts:tree_sitter_bash(),
    true = symbolic_ts:parser_set_language(Parser, Lang),
    %% See ts_extract_erlang:text/2's identical comment: parser_parse_string
    %% needs a list (enif_get_string), node_text/2 wants a binary.
    {SrcList, Src} = case Src0 of
        B when is_binary(B) -> {binary_to_list(B), B};
        L when is_list(L) -> {L, list_to_binary(L)}
    end,
    Tree = symbolic_ts:parser_parse_string(Parser, SrcList),
    Root = symbolic_ts:tree_root_node(Tree),
    PathAtom = list_to_atom(Path),
    Facts =
        defines(Lang, Root, Src, PathAtom) ++
        local_calls(Lang, Root, Src, PathAtom) ++
        comments(Lang, Root, Src, PathAtom) ++
        docs(Lang, Root, Src, PathAtom) ++
        branches(Lang, Root, Src, PathAtom),
    lists:usort(Facts).

defines(Lang, Root, Src, PathAtom) ->
    {Q, _, _} = symbolic_ts:query_new(Lang, ?DEF_QUERY),
    Caps = symbolic_ts:query_capture(Root, Q),
    lists:usort([
        {defines, to_atom(symbolic_ts:node_text(N, Src)), undefined, undefined,
         PathAtom, line(N)}
     || {"fun_name", N} <- Caps
    ]).

local_calls(Lang, Root, Src, PathAtom) ->
    {Q, _, _} = symbolic_ts:query_new(Lang, ?CALL_QUERY),
    Caps = symbolic_ts:query_capture(Root, Q),
    lists:usort([
        local_call_fact(N, Src, PathAtom)
     || {"callee", N} <- Caps
    ]).

%% A `command`'s named children include the command name itself at index
%% 0, so the word count following it is named_child_count - 1 (confirmed
%% empirically: `scp a b c` -> 4 named children -> ArgCount 3). This is
%% an observed word count, not a validated arity — bash has no fixed
%% parameter list to check it against.
local_call_fact(N, Src, PathAtom) ->
    CommandNode = symbolic_ts:node_parent(N),
    ArgCount = symbolic_ts:node_named_child_count(CommandNode) - 1,
    {calls, caller_name(N, Src), undefined,
     {local, to_atom(symbolic_ts:node_text(N, Src)), ArgCount},
     PathAtom, line(N)}.

%% One branch/5 fact per decision point (see ?BRANCH_QUERIES), attributed
%% to its enclosing function via caller_name/2 — the exact same walk-up
%% local_call_fact/3 uses for calls/5's Caller. CallerArity is always
%% `undefined`, same reason defines/5's Arity always is: Bash functions
%% have no parameter-list grammar node at all.
branches(Lang, Root, Src, PathAtom) ->
    lists:flatmap(
        fun({Kind, Query}) -> branch_facts(Lang, Root, Src, PathAtom, Kind, Query) end,
        ?BRANCH_QUERIES).

branch_facts(Lang, Root, Src, PathAtom, Kind, Query) ->
    {Q, _, _} = symbolic_ts:query_new(Lang, Query),
    Caps = symbolic_ts:query_capture(Root, Q),
    lists:usort([branch_fact(N, Src, PathAtom, Kind) || {"b", N} <- Caps]).

branch_fact(N, Src, PathAtom, Kind) ->
    {branch, caller_name(N, Src), undefined, Kind, PathAtom, line(N)}.

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
        Name ->
            {true, {doc, Name, undefined, PathAtom, line(Target), clean_join(Texts)}}
    end.

definition_name(Node, Src) ->
    case symbolic_ts:node_type(Node) of
        "function_definition" ->
            NameNode = symbolic_ts:node_child_by_field_name(Node, "name"),
            to_atom(symbolic_ts:node_text(NameNode, Src));
        _ ->
            false
    end.

%% Walk up to the nearest enclosing function_definition to attribute a
%% call site to the function it appears in.
caller_name(Node, Src) ->
    case symbolic_ts:node_type(Node) of
        "function_definition" ->
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

%% Comment text cleaning: strip leading `#` and join a run into one
%% line — same reasoning as ts_extract_erlang.erl's equivalent. Rendered
%% as a binary (ts_extract_text:to_text/1), not an atom — see that
%% module's identical clean_join/1 for why.
clean_join(Texts) ->
    Lines = lists:flatmap(fun to_lines/1, Texts),
    Cleaned = [clean_line(L) || L <- Lines],
    NonEmpty = [L || L <- Cleaned, L =/= ""],
    to_text(lists:flatten(lists:join(" ", NonEmpty))).

to_lines(Text) when is_binary(Text) -> to_lines(binary_to_list(Text));
to_lines(Text) when is_list(Text) -> string:split(Text, "\n", all).

clean_line(Line) ->
    string:trim(string:trim(Line, leading, "#")).
