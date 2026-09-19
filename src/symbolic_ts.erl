%%% Thin NIF wrapper around symbolic_ts_nif.c — the ~20 tree-sitter C API
%%% functions this project actually uses, ported from (and replacing)
%%% the vendored `erl_ts` fork. See docs/tree-sitter-erlang.md.
%%%
%%% Same names/arities as the erl_ts functions this replaces, so
%%% ts_extract_erlang.erl / ts_extract_typescript.erl / ts_extract_markdown.erl
%%% only needed a module-name swap (`erl_ts:` -> `symbolic_ts:`), not a
%%% rewrite.
%%%
%%% Don't call init/0 yourself — it's the -on_load hook, invoked
%%% automatically the first time this module is referenced. Calling it
%%% again crashes with a boot-time `undef` (this was a real, confusing
%%% pitfall with erl_ts's own equivalent; same rule applies here).
-module(symbolic_ts).

-export([
    tree_sitter_erlang/0,
    tree_sitter_typescript/0,
    tree_sitter_markdown/0,
    tree_sitter_toml/0,
    tree_sitter_json/0,
    parser_new/0,
    parser_set_language/2,
    parser_parse_string/2,
    tree_root_node/1,
    node_type/1,
    node_start_byte/1,
    node_end_byte/1,
    node_start_point/1,
    node_text/2,
    node_is_null/1,
    node_parent/1,
    node_named_child/2,
    node_named_child_count/1,
    node_child_by_field_name/2,
    node_next_sibling/1,
    node_prev_sibling/1,
    query_new/2,
    query_capture/2
]).

-on_load(init/0).

-define(APPNAME, symbolic_tools).
-define(LIBNAME, symbolic_ts).

init() ->
    SoFile =
        case code:priv_dir(?APPNAME) of
            {error, bad_name} ->
                filename:join(["priv", atom_to_list(?LIBNAME)]);
            Dir ->
                filename:join(Dir, atom_to_list(?LIBNAME))
        end,
    ok = erlang:load_nif(SoFile, 0).

tree_sitter_erlang() -> erlang:nif_error(nif_not_loaded).
tree_sitter_typescript() -> erlang:nif_error(nif_not_loaded).
tree_sitter_markdown() -> erlang:nif_error(nif_not_loaded).
tree_sitter_toml() -> erlang:nif_error(nif_not_loaded).
tree_sitter_json() -> erlang:nif_error(nif_not_loaded).
parser_new() -> erlang:nif_error(nif_not_loaded).
parser_set_language(_Parser, _Language) -> erlang:nif_error(nif_not_loaded).
parser_parse_string(_Parser, _Source) -> erlang:nif_error(nif_not_loaded).
tree_root_node(_Tree) -> erlang:nif_error(nif_not_loaded).
node_type(_Node) -> erlang:nif_error(nif_not_loaded).
node_start_byte(_Node) -> erlang:nif_error(nif_not_loaded).
node_end_byte(_Node) -> erlang:nif_error(nif_not_loaded).
node_start_point(_Node) -> erlang:nif_error(nif_not_loaded).
node_is_null(_Node) -> erlang:nif_error(nif_not_loaded).
node_parent(_Node) -> erlang:nif_error(nif_not_loaded).
node_named_child(_Node, _Index) -> erlang:nif_error(nif_not_loaded).
node_named_child_count(_Node) -> erlang:nif_error(nif_not_loaded).
node_child_by_field_name(_Node, _Name) -> erlang:nif_error(nif_not_loaded).
node_next_sibling(_Node) -> erlang:nif_error(nif_not_loaded).
node_prev_sibling(_Node) -> erlang:nif_error(nif_not_loaded).
query_new(_Language, _Source) -> erlang:nif_error(nif_not_loaded).
query_capture(_Node, _Query) -> erlang:nif_error(nif_not_loaded).

%% Not a NIF — a node is a (start_byte, end_byte) span into the source
%% it was parsed from, not owned text, so slicing it out needs the
%% original source string. Ported as-is from erl_ts.erl's equivalent.
node_text(Node, SourceCode) ->
    case node_is_null(Node) of
        true ->
            undefined;
        false ->
            Start = node_start_byte(Node),
            End = node_end_byte(Node),
            string:sub_string(SourceCode, Start + 1, End)
    end.
