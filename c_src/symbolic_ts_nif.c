/* symbolic_ts_nif.c
 *
 * A small, purpose-built tree-sitter NIF for symbolic-tools — not a
 * general-purpose binding. Exposes exactly the ~20 tree-sitter C API
 * functions src/ts_extract_{erlang,typescript,markdown}.erl actually
 * call, ported from (and replacing) the vendored `erl_ts` fork this
 * project used earlier. See docs/tree-sitter-erlang.md.
 *
 * One real bug in the code this was ported from is fixed here rather
 * than carried forward: parser_parse_string_nif leaked its copied input
 * string on every call (never enif_free'd). A second one — free_TSTree
 * being a no-op, leaking every parsed tree — is deliberately NOT fixed:
 * see the comment on free_tree/2 below for why actually calling
 * ts_tree_delete there is a real use-after-free, not a safe cleanup.
 */

#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include <erl_nif.h>
#include <tree_sitter/api.h>

extern const TSLanguage *tree_sitter_erlang(void);
extern const TSLanguage *tree_sitter_typescript(void);
extern const TSLanguage *tree_sitter_markdown(void);

#define NIF(f) static ERL_NIF_TERM f(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
#define NIF_ENTRY(f, a) { #f, a, f }
#define NIF_ENTRY_AS(erl_name, a, f) { erl_name, a, f }
#define BADARG_IF(p) if (p) return enif_make_badarg(env)

static ERL_NIF_TERM atom_ok;
static ERL_NIF_TERM atom_error;
static ERL_NIF_TERM atom_true;
static ERL_NIF_TERM atom_false;
static ERL_NIF_TERM atom_undefined;
static ERL_NIF_TERM atom_row;
static ERL_NIF_TERM atom_column;
static ERL_NIF_TERM atom_query_error_none;
static ERL_NIF_TERM atom_query_error_syntax;
static ERL_NIF_TERM atom_query_error_node_type;
static ERL_NIF_TERM atom_query_error_field;
static ERL_NIF_TERM atom_query_error_capture;
static ERL_NIF_TERM atom_query_error_structure;
static ERL_NIF_TERM atom_query_error_language;

static ERL_NIF_TERM mk_atom(ErlNifEnv *env, const char *name) {
    ERL_NIF_TERM ret;
    if (!enif_make_existing_atom(env, name, &ret, ERL_NIF_LATIN1)) {
        return enif_make_atom(env, name);
    }
    return ret;
}

static ERL_NIF_TERM mk_error(ErlNifEnv *env, const char *msg) {
    return enif_make_tuple2(env, atom_error, mk_atom(env, msg));
}

/* Resource types — one per tree-sitter handle this project touches. */

static ErlNifResourceType *res_language = NULL;
static ErlNifResourceType *res_parser = NULL;
static ErlNifResourceType *res_tree = NULL;
static ErlNifResourceType *res_query = NULL;
static ErlNifResourceType *res_node = NULL;

typedef struct { const TSLanguage *val; } language_res_t;
typedef struct { TSParser *val; } parser_res_t;
typedef struct { TSTree *val; } tree_res_t;
typedef struct { TSQuery *val; } query_res_t;
typedef struct { TSNode val; } node_res_t;

static void free_language(ErlNifEnv *env, void *obj) {
    (void)env;
    const TSLanguage *lang = ((language_res_t *)obj)->val;
    if (lang) ts_language_delete(lang);
}

static void free_parser(ErlNifEnv *env, void *obj) {
    (void)env;
    TSParser *parser = ((parser_res_t *)obj)->val;
    if (parser) ts_parser_delete(parser);
}

static void free_tree(ErlNifEnv *env, void *obj) {
    /* Deliberately NOT calling ts_tree_delete here, matching erl_ts's
       original (leaky but safe) behavior — confirmed by hitting the
       alternative directly: a TSNode holds a raw pointer into its
       TSTree with no reference counting of its own, and the BEAM can
       (and does) garbage-collect a Tree resource term as soon as the
       compiler's liveness analysis sees the last use of the `Tree`
       variable, even while Node resources derived from
       tree_root_node/1 are still very much alive — actually freeing
       the tree here is a real use-after-free, reproduced as a
       consistent SIGSEGV in ts_extract_markdown:file/1 (which computes
       Root once and never references Tree again). Properly fixing this
       would mean each Node resource keeping its owning Tree resource
       term alive (e.g. via enif_keep_resource) — real, separable work,
       not worth doing under time pressure when "leak one tree per
       parse" is what every one-shot `symbolic parse`/`query` process
       already did before this rewrite, and is harmless there. Matters
       more for a long-running session (the MCP server); revisit then. */
    (void)env;
    (void)obj;
}

static void free_query(ErlNifEnv *env, void *obj) {
    (void)env;
    TSQuery *query = ((query_res_t *)obj)->val;
    if (query) ts_query_delete(query);
}

static void free_node(ErlNifEnv *env, void *obj) {
    /* TSNode is a plain value (indexes into its tree), not a pointer —
       nothing to free. */
    (void)env;
    (void)obj;
}

static ERL_NIF_TERM tspoint_to_map(ErlNifEnv *env, TSPoint p) {
    ERL_NIF_TERM map = enif_make_new_map(env);
    enif_make_map_put(env, map, atom_row, enif_make_uint(env, p.row), &map);
    enif_make_map_put(env, map, atom_column, enif_make_uint(env, p.column), &map);
    return map;
}

static ERL_NIF_TERM query_error_to_atom(TSQueryError e) {
    switch (e) {
        case TSQueryErrorNone: return atom_query_error_none;
        case TSQueryErrorSyntax: return atom_query_error_syntax;
        case TSQueryErrorNodeType: return atom_query_error_node_type;
        case TSQueryErrorField: return atom_query_error_field;
        case TSQueryErrorCapture: return atom_query_error_capture;
        case TSQueryErrorStructure: return atom_query_error_structure;
        case TSQueryErrorLanguage: return atom_query_error_language;
        default: return atom_undefined;
    }
}

/* Read an Erlang string term (a list of char codes) into a fresh,
   NUL-terminated, caller-owned buffer. Caller must enif_free() it. */
static bool get_owned_string(ErlNifEnv *env, ERL_NIF_TERM term, char **out, unsigned int *out_len) {
    unsigned int len;
    if (!enif_get_list_length(env, term, &len)) return false;
    char *buf = (char *)enif_alloc(len + 1);
    if (!enif_get_string(env, term, buf, len + 1, ERL_NIF_LATIN1)) {
        enif_free(buf);
        return false;
    }
    *out = buf;
    *out_len = len;
    return true;
}

static ERL_NIF_TERM make_language_term(ErlNifEnv *env, const TSLanguage *lang, const char *err_msg) {
    if (!lang) return mk_error(env, err_msg);
    language_res_t *res = enif_alloc_resource(res_language, sizeof(language_res_t));
    res->val = lang;
    ERL_NIF_TERM term = enif_make_resource(env, res);
    enif_release_resource(res);
    return enif_make_tuple2(env, atom_ok, term);
}

static ERL_NIF_TERM make_node_term(ErlNifEnv *env, TSNode node) {
    if (ts_node_is_null(node)) return atom_undefined;
    node_res_t *res = enif_alloc_resource(res_node, sizeof(node_res_t));
    res->val = node;
    ERL_NIF_TERM term = enif_make_resource(env, res);
    enif_release_resource(res);
    return term;
}

/* Same as make_node_term/2, but never collapses a null node to
   `undefined` — some callers (e.g. node_parent/1) need to distinguish
   "no such node" from a genuinely absent one via node_is_null/1
   themselves. See docs/tree-sitter-erlang.md §6 for why sibling
   navigation and parent navigation intentionally behave differently
   here, matching what this project already depended on from erl_ts. */
static ERL_NIF_TERM make_node_term_always(ErlNifEnv *env, TSNode node) {
    node_res_t *res = enif_alloc_resource(res_node, sizeof(node_res_t));
    res->val = node;
    ERL_NIF_TERM term = enif_make_resource(env, res);
    enif_release_resource(res);
    return term;
}

static bool get_node(ErlNifEnv *env, ERL_NIF_TERM term, TSNode *out) {
    void *res;
    if (!enif_get_resource(env, term, res_node, &res)) return false;
    *out = ((node_res_t *)res)->val;
    return true;
}

/* ---- language loaders ---- */

/* Named nif_tree_sitter_* rather than tree_sitter_* — the latter would
   collide with the grammars' own extern C entry points declared above. */
NIF(nif_tree_sitter_erlang) {
    (void)argc; (void)argv;
    return make_language_term(env, tree_sitter_erlang(), "unable_to_create_language_erlang");
}

NIF(nif_tree_sitter_typescript) {
    (void)argc; (void)argv;
    return make_language_term(env, tree_sitter_typescript(), "unable_to_create_language_typescript");
}

NIF(nif_tree_sitter_markdown) {
    (void)argc; (void)argv;
    return make_language_term(env, tree_sitter_markdown(), "unable_to_create_language_markdown");
}

/* ---- parser ---- */

NIF(parser_new) {
    (void)argc; (void)argv;
    TSParser *parser = ts_parser_new();
    if (!parser) return mk_error(env, "unable_to_create_new_parser");
    parser_res_t *res = enif_alloc_resource(res_parser, sizeof(parser_res_t));
    res->val = parser;
    ERL_NIF_TERM term = enif_make_resource(env, res);
    enif_release_resource(res);
    return enif_make_tuple2(env, atom_ok, term);
}

NIF(parser_set_language) {
    BADARG_IF(argc != 2);
    void *res_p, *res_l;
    BADARG_IF(!enif_get_resource(env, argv[0], res_parser, &res_p));
    BADARG_IF(!enif_get_resource(env, argv[1], res_language, &res_l));
    TSParser *parser = ((parser_res_t *)res_p)->val;
    const TSLanguage *lang = ((language_res_t *)res_l)->val;
    return ts_parser_set_language(parser, lang) ? atom_true : atom_false;
}

NIF(parser_parse_string) {
    BADARG_IF(argc != 2);
    void *res_p;
    BADARG_IF(!enif_get_resource(env, argv[0], res_parser, &res_p));
    TSParser *parser = ((parser_res_t *)res_p)->val;

    char *src = NULL;
    unsigned int src_len;
    BADARG_IF(!get_owned_string(env, argv[1], &src, &src_len));

    TSTree *tree = ts_parser_parse_string(parser, NULL, src, src_len);
    enif_free(src); /* fixed: erl_ts's equivalent leaked this every call */

    tree_res_t *res = enif_alloc_resource(res_tree, sizeof(tree_res_t));
    res->val = tree;
    ERL_NIF_TERM term = enif_make_resource(env, res);
    enif_release_resource(res);
    return term;
}

/* ---- tree ---- */

NIF(tree_root_node) {
    BADARG_IF(argc != 1);
    void *res_t;
    BADARG_IF(!enif_get_resource(env, argv[0], res_tree, &res_t));
    TSTree *tree = ((tree_res_t *)res_t)->val;
    return make_node_term_always(env, ts_tree_root_node(tree));
}

/* ---- node ---- */

NIF(node_type) {
    BADARG_IF(argc != 1);
    TSNode node;
    BADARG_IF(!get_node(env, argv[0], &node));
    return enif_make_string(env, ts_node_type(node), ERL_NIF_LATIN1);
}

NIF(node_start_byte) {
    BADARG_IF(argc != 1);
    TSNode node;
    BADARG_IF(!get_node(env, argv[0], &node));
    return enif_make_uint(env, ts_node_start_byte(node));
}

NIF(node_end_byte) {
    BADARG_IF(argc != 1);
    TSNode node;
    BADARG_IF(!get_node(env, argv[0], &node));
    return enif_make_uint(env, ts_node_end_byte(node));
}

NIF(node_start_point) {
    BADARG_IF(argc != 1);
    TSNode node;
    BADARG_IF(!get_node(env, argv[0], &node));
    return tspoint_to_map(env, ts_node_start_point(node));
}

NIF(node_is_null) {
    BADARG_IF(argc != 1);
    TSNode node;
    BADARG_IF(!get_node(env, argv[0], &node));
    return ts_node_is_null(node) ? atom_true : atom_false;
}

NIF(node_parent) {
    BADARG_IF(argc != 1);
    TSNode node;
    BADARG_IF(!get_node(env, argv[0], &node));
    return make_node_term_always(env, ts_node_parent(node));
}

NIF(node_named_child) {
    BADARG_IF(argc != 2);
    TSNode node;
    BADARG_IF(!get_node(env, argv[0], &node));
    unsigned int index;
    BADARG_IF(!enif_get_uint(env, argv[1], &index));
    return make_node_term_always(env, ts_node_named_child(node, index));
}

NIF(node_named_child_count) {
    BADARG_IF(argc != 1);
    TSNode node;
    BADARG_IF(!get_node(env, argv[0], &node));
    return enif_make_uint(env, ts_node_named_child_count(node));
}

NIF(node_child_by_field_name) {
    BADARG_IF(argc != 2);
    TSNode node;
    BADARG_IF(!get_node(env, argv[0], &node));
    char *name = NULL;
    unsigned int name_len;
    BADARG_IF(!get_owned_string(env, argv[1], &name, &name_len));
    TSNode result = ts_node_child_by_field_name(node, name, name_len);
    enif_free(name);
    return make_node_term_always(env, result);
}

/* Sibling navigation deliberately returns the bare atom `undefined` for
   "no such sibling", not a null-resource node — confirmed against
   erl_ts's own behavior and documented in docs/tree-sitter-erlang.md §6
   (node_is_null/1 does NOT apply here, unlike node_parent/1). Kept
   identical here so ts_extract_*.erl's sibling-walk code needs no
   changes. */
NIF(node_next_sibling) {
    BADARG_IF(argc != 1);
    TSNode node;
    BADARG_IF(!get_node(env, argv[0], &node));
    return make_node_term(env, ts_node_next_sibling(node));
}

NIF(node_prev_sibling) {
    BADARG_IF(argc != 1);
    TSNode node;
    BADARG_IF(!get_node(env, argv[0], &node));
    return make_node_term(env, ts_node_prev_sibling(node));
}

/* ---- query ---- */

NIF(query_new) {
    BADARG_IF(argc != 2);
    void *res_l;
    BADARG_IF(!enif_get_resource(env, argv[0], res_language, &res_l));
    const TSLanguage *lang = ((language_res_t *)res_l)->val;

    char *src = NULL;
    unsigned int src_len;
    BADARG_IF(!get_owned_string(env, argv[1], &src, &src_len));

    uint32_t error_offset;
    TSQueryError error_type;
    TSQuery *q = ts_query_new(lang, src, src_len, &error_offset, &error_type);
    enif_free(src);

    query_res_t *res = enif_alloc_resource(res_query, sizeof(query_res_t));
    res->val = q;
    ERL_NIF_TERM term = enif_make_resource(env, res);
    enif_release_resource(res);

    return enif_make_tuple3(env, term, enif_make_uint(env, error_offset),
                             query_error_to_atom(error_type));
}

/* Runs Query over Node's whole subtree and returns every capture as a
   flat [{CaptureNameString, NodeResource}] list — duplicated once per
   named capture in the pattern (a tree-sitter behavior, not a bug here;
   see docs/tree-sitter-erlang.md §6 for how the extractors work around
   it). */
NIF(query_capture) {
    BADARG_IF(argc != 2);
    TSNode node;
    BADARG_IF(!get_node(env, argv[0], &node));
    void *res_q;
    BADARG_IF(!enif_get_resource(env, argv[1], res_query, &res_q));
    TSQuery *query = ((query_res_t *)res_q)->val;

    TSQueryCursor *cursor = ts_query_cursor_new();
    ts_query_cursor_exec(cursor, query, node);

    TSQueryMatch match;
    uint32_t capture_index;
    ERL_NIF_TERM list = enif_make_list(env, 0);
    while (ts_query_cursor_next_capture(cursor, &match, &capture_index)) {
        for (uint16_t i = 0; i < match.capture_count; i++) {
            TSQueryCapture qc = match.captures[i];
            uint32_t name_len;
            const char *name = ts_query_capture_name_for_id(query, qc.index, &name_len);
            ERL_NIF_TERM name_term = enif_make_string(env, name, ERL_NIF_LATIN1);
            ERL_NIF_TERM node_term = make_node_term_always(env, qc.node);
            ERL_NIF_TERM entry = enif_make_tuple2(env, name_term, node_term);
            list = enif_make_list_cell(env, entry, list);
        }
    }
    ts_query_cursor_delete(cursor);

    ERL_NIF_TERM reversed;
    enif_make_reverse_list(env, list, &reversed);
    return reversed;
}

/* ---- NIF registration ---- */

static ErlNifFunc nif_funcs[] = {
    NIF_ENTRY_AS("tree_sitter_erlang", 0, nif_tree_sitter_erlang),
    NIF_ENTRY_AS("tree_sitter_typescript", 0, nif_tree_sitter_typescript),
    NIF_ENTRY_AS("tree_sitter_markdown", 0, nif_tree_sitter_markdown),
    NIF_ENTRY(parser_new, 0),
    NIF_ENTRY(parser_set_language, 2),
    NIF_ENTRY(parser_parse_string, 2),
    NIF_ENTRY(tree_root_node, 1),
    NIF_ENTRY(node_type, 1),
    NIF_ENTRY(node_start_byte, 1),
    NIF_ENTRY(node_end_byte, 1),
    NIF_ENTRY(node_start_point, 1),
    NIF_ENTRY(node_is_null, 1),
    NIF_ENTRY(node_parent, 1),
    NIF_ENTRY(node_named_child, 2),
    NIF_ENTRY(node_named_child_count, 1),
    NIF_ENTRY(node_child_by_field_name, 2),
    NIF_ENTRY(node_next_sibling, 1),
    NIF_ENTRY(node_prev_sibling, 1),
    NIF_ENTRY(query_new, 2),
    NIF_ENTRY(query_capture, 2),
};

static int load(ErlNifEnv *env, void **priv_data, ERL_NIF_TERM load_info) {
    (void)priv_data; (void)load_info;

    res_language = enif_open_resource_type(env, NULL, "symbolic_ts_language", free_language, ERL_NIF_RT_CREATE, NULL);
    res_parser = enif_open_resource_type(env, NULL, "symbolic_ts_parser", free_parser, ERL_NIF_RT_CREATE, NULL);
    res_tree = enif_open_resource_type(env, NULL, "symbolic_ts_tree", free_tree, ERL_NIF_RT_CREATE, NULL);
    res_query = enif_open_resource_type(env, NULL, "symbolic_ts_query", free_query, ERL_NIF_RT_CREATE, NULL);
    res_node = enif_open_resource_type(env, NULL, "symbolic_ts_node", free_node, ERL_NIF_RT_CREATE, NULL);
    if (!res_language || !res_parser || !res_tree || !res_query || !res_node) return -1;

    atom_ok = mk_atom(env, "ok");
    atom_error = mk_atom(env, "error");
    atom_true = mk_atom(env, "true");
    atom_false = mk_atom(env, "false");
    atom_undefined = mk_atom(env, "undefined");
    atom_row = mk_atom(env, "row");
    atom_column = mk_atom(env, "column");
    atom_query_error_none = mk_atom(env, "error_none");
    atom_query_error_syntax = mk_atom(env, "error_syntax");
    atom_query_error_node_type = mk_atom(env, "error_node_type");
    atom_query_error_field = mk_atom(env, "error_field");
    atom_query_error_capture = mk_atom(env, "error_capture");
    atom_query_error_structure = mk_atom(env, "error_structure");
    atom_query_error_language = mk_atom(env, "error_language");

    return 0;
}

static int upgrade(ErlNifEnv *env, void **priv_data, void **old_priv_data, ERL_NIF_TERM load_info) {
    (void)env; (void)load_info;
    *priv_data = *old_priv_data;
    return 0;
}

ERL_NIF_INIT(symbolic_ts, nif_funcs, load, NULL, upgrade, NULL)
