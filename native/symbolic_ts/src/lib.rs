//! symbolic_ts — the Rustler NIF that replaced c_src/symbolic_ts_nif.c.
//!
//! A small, purpose-built tree-sitter binding exposing exactly the ~25
//! functions the `ts_extract_*.erl` extractors call. See
//! docs/tree-sitter-erlang.md for the behavioral contract; this crate's
//! job is to preserve it byte-for-byte while fixing what the C NIF
//! couldn't:
//!
//! 1. **Tree/node lifetime.** The C NIF's free_tree was a deliberate no-op
//!    leak: TSNode resources held raw pointers into their TSTree with no
//!    ownership, and actually freeing a tree was reproduced as a SIGSEGV
//!    (the BEAM GCs the tree resource while node resources still point
//!    into it). Here `NodeRes` holds a `ResourceArc<TreeRes>` of the tree
//!    it was parsed from, so the tree cannot be freed while any node
//!    resource lives — `TreeRes`'s Drop impl really calls `ts_tree_delete`,
//!    no leak, no use-after-free.
//! 2. **Null nodes.** Every accessor returns `undefined` for a null input
//!    node (the contract symbolic_ts_tests.erl pins), guarded here in one
//!    place instead of sprinkled C macros. A null result is still a
//!    null-node resource term for parent/named_child/child_by_field_name
//!    (so node_is_null/1 distinguishes), and the bare `undefined` atom for
//!    sibling navigation — the asymmetry the extractors depend on.
//! 3. **Dirty schedulers.** parser_parse_string and query_capture do
//!    unbounded CPU work and are scheduled DirtyCpu, off the normal
//!    scheduler threads.
//! 4. **UTF-8.** Source input is a binary handed to tree-sitter as raw
//!    bytes; the C NIF decoded Erlang code lists via enif_get_string with
//!    ERL_NIF_LATIN1, silently truncating codepoints > 255 and misaligning
//!    every byte offset for non-Latin-1 files. Binary input is the file's
//!    actual bytes, so node byte offsets index the real source.
//!
//! Outputs (node_type, query capture names) are still returned as Erlang
//! char lists, exactly as the C NIF returned them (enif_make_string
//! ERL_NIF_LATIN1 built list terms): node types and capture names are
//! ASCII, so a list-vs-binary change would be pure representation churn
//! across dozens of extractor call sites for no correctness gain.
//!
//! Concurrency contract (same as the C NIF, now stated out loud): a
//! parser/tree/query resource may be used from only one process at a
//! time. Rustler requires resources to be Send+Sync to sit in a shared
//! resource table, and tree-sitter objects are not internally
//! synchronized — the unsafe Send/Sync impls below rely on the
//! single-owner-process discipline every caller in this repo already
//! follows.

use std::ffi::{c_char, CStr};

use rustler::{atoms, Binary, Env, NifResult, Resource, ResourceArc, Term};

mod ffi;

atoms! {
    ok,
    error,
    // stringify! of a raw-ident would produce "r#true" — the explicit
    // strings below are the actual Erlang atom names.
    r#true = "true",
    r#false = "false",
    undefined,
    row,
    column,
    error_none,
    error_syntax,
    error_node_type,
    error_field,
    error_capture,
    error_structure,
    error_language,
    parse_failed,
    unable_to_create_new_parser,
    unable_to_create_language_erlang,
    unable_to_create_language_typescript,
    unable_to_create_language_markdown,
    unable_to_create_language_toml,
    unable_to_create_language_json,
    unable_to_create_language_bash,
    unable_to_create_language_jsdoc,
    unable_to_create_language_rust,
}

// ---------------------------------------------------------------------------
// Resources
// ---------------------------------------------------------------------------

/// Languages are static singletons owned by the grammar objects compiled
/// into this crate — nothing to free (the C NIF's ts_language_delete call
/// was a no-op for static languages).
struct LanguageRes {
    lang: *const ffi::TSLanguage,
}
unsafe impl Send for LanguageRes {}
unsafe impl Sync for LanguageRes {}
impl Resource for LanguageRes {}

struct ParserRes {
    parser: *mut ffi::TSParser,
}
unsafe impl Send for ParserRes {}
unsafe impl Sync for ParserRes {}
impl Drop for ParserRes {
    fn drop(&mut self) {
        if !self.parser.is_null() {
            unsafe { ffi::ts_parser_delete(self.parser) };
        }
    }
}
impl Resource for ParserRes {}

struct TreeRes {
    tree: *mut ffi::TSTree,
}
unsafe impl Send for TreeRes {}
unsafe impl Sync for TreeRes {}
impl Drop for TreeRes {
    // The C NIF deliberately leaked here (free_tree was a no-op) because
    // nothing tied a Node resource to the tree it pointed into. NodeRes
    // below holds a ResourceArc<TreeRes> of that tree, so this Drop now
    // really runs — and can only run once no NodeRes referencing this
    // tree remains.
    fn drop(&mut self) {
        if !self.tree.is_null() {
            unsafe { ffi::ts_tree_delete(self.tree) };
        }
    }
}
impl Resource for TreeRes {}

struct QueryRes {
    query: *mut ffi::TSQuery,
}
unsafe impl Send for QueryRes {}
unsafe impl Sync for QueryRes {}
impl Drop for QueryRes {
    fn drop(&mut self) {
        if !self.query.is_null() {
            unsafe { ffi::ts_query_delete(self.query) };
        }
    }
}
impl Resource for QueryRes {}

/// A TSNode is a plain value (indexes into its tree), not a pointer — but
/// those indexes dangle the moment the TSTree is freed, which is why this
/// struct pins the owning tree's resource and why TreeRes::drop is safe to
/// actually delete. The tree is the only field with drop consequences;
/// node itself is a Copy of the C struct.
struct NodeRes {
    tree: ResourceArc<TreeRes>,
    node: ffi::TSNode,
}
unsafe impl Send for NodeRes {}
unsafe impl Sync for NodeRes {}
impl Resource for NodeRes {}

// ---------------------------------------------------------------------------
// Term-building helpers
// ---------------------------------------------------------------------------

/// Rebuilds the C NIF's list-of-codepoints return terms
/// (enif_make_string ERL_NIF_LATIN1). Bytes map to codepoints 0-255;
/// node types and capture names are ASCII, so this is exact.
fn byte_string_to_list<'a>(env: Env<'a>, bytes: &[u8]) -> Term<'a> {
    let mut list = Term::list_new_empty(env);
    // prepend walks bytes back-to-front so the result comes out in order
    // without needing a reverse pass.
    for &b in bytes.iter().rev() {
        list = list.list_prepend(b as u32);
    }
    list
}

fn query_error_atom(code: u32) -> rustler::Atom {
    match code {
        0 => error_none(),
        1 => error_syntax(),
        2 => error_node_type(),
        3 => error_field(),
        4 => error_capture(),
        5 => error_structure(),
        6 => error_language(),
        _ => undefined(),
    }
}

fn make_language(env: Env<'_>, lang: *const ffi::TSLanguage, err: rustler::Atom) -> Term<'_> {
    use rustler::Encoder;
    if lang.is_null() {
        (error(), err).encode(env)
    } else {
        (ok(), ResourceArc::new(LanguageRes { lang })).encode(env)
    }
}

/// Wraps a (possibly null) node as a NodeRes term pinned to its tree — the
/// make_node_term_always behavior: parent/named_child/child_by_field_name
/// return a null-node resource so callers can node_is_null/1 it themselves.
fn make_node_always<'a>(env: Env<'a>, tree: &ResourceArc<TreeRes>, node: ffi::TSNode) -> Term<'a> {
    use rustler::Encoder;
    ResourceArc::new(NodeRes {
        tree: tree.clone(),
        node,
    })
    .encode(env)
}

/// The NULL_NODE_IF_NULL guard: a null INPUT node makes every accessor
/// return `undefined` without reaching tree-sitter (whose API contract is
/// that null nodes must never be dereferenced — ts_node__subtree is
/// literally `*(Subtree *)self.id`).
fn null_guard<'a>(env: Env<'a>, node: &ResourceArc<NodeRes>) -> Option<Term<'a>> {
    use rustler::Encoder;
    if unsafe { ffi::ts_node_is_null(node.node) } {
        Some(undefined().encode(env))
    } else {
        None
    }
}

// ---------------------------------------------------------------------------
// NIFs
// ---------------------------------------------------------------------------

// ---- language loaders ----

#[rustler::nif]
fn tree_sitter_erlang(env: Env) -> Term {
    make_language(
        env,
        unsafe { ffi::tree_sitter_erlang() },
        unable_to_create_language_erlang(),
    )
}

#[rustler::nif]
fn tree_sitter_typescript(env: Env) -> Term {
    make_language(
        env,
        unsafe { ffi::tree_sitter_typescript() },
        unable_to_create_language_typescript(),
    )
}

#[rustler::nif]
fn tree_sitter_markdown(env: Env) -> Term {
    make_language(
        env,
        unsafe { ffi::tree_sitter_markdown() },
        unable_to_create_language_markdown(),
    )
}

#[rustler::nif]
fn tree_sitter_toml(env: Env) -> Term {
    make_language(
        env,
        unsafe { ffi::tree_sitter_toml() },
        unable_to_create_language_toml(),
    )
}

#[rustler::nif]
fn tree_sitter_json(env: Env) -> Term {
    make_language(
        env,
        unsafe { ffi::tree_sitter_json() },
        unable_to_create_language_json(),
    )
}

#[rustler::nif]
fn tree_sitter_bash(env: Env) -> Term {
    make_language(
        env,
        unsafe { ffi::tree_sitter_bash() },
        unable_to_create_language_bash(),
    )
}

#[rustler::nif]
fn tree_sitter_jsdoc(env: Env) -> Term {
    make_language(
        env,
        unsafe { ffi::tree_sitter_jsdoc() },
        unable_to_create_language_jsdoc(),
    )
}

#[rustler::nif]
fn tree_sitter_rust(env: Env) -> Term {
    make_language(
        env,
        unsafe { ffi::tree_sitter_rust() },
        unable_to_create_language_rust(),
    )
}

// ---- parser ----

#[rustler::nif]
fn parser_new(env: Env) -> Term {
    use rustler::Encoder;
    let parser = unsafe { ffi::ts_parser_new() };
    if parser.is_null() {
        (error(), unable_to_create_new_parser()).encode(env)
    } else {
        (ok(), ResourceArc::new(ParserRes { parser })).encode(env)
    }
}

#[rustler::nif]
fn parser_set_language(
    parser: ResourceArc<ParserRes>,
    language: ResourceArc<LanguageRes>,
) -> rustler::Atom {
    if unsafe { ffi::ts_parser_set_language(parser.parser, language.lang) } {
        r#true()
    } else {
        r#false()
    }
}

/// Source is a binary: the file's actual UTF-8 bytes, handed to
/// tree-sitter as-is. (The C NIF decoded an Erlang code list via
/// enif_get_string ERL_NIF_LATIN1, truncating codepoints > 255 and
/// misaligning byte offsets for non-Latin-1 sources.) Parsing is
/// unbounded CPU work → DirtyCpu, keeping it off the normal schedulers
/// the whole VM shares.
#[rustler::nif(schedule = "DirtyCpu")]
fn parser_parse_string<'a>(env: Env<'a>, parser: ResourceArc<ParserRes>, source: Binary<'_>) -> Term<'a> {
    use rustler::Encoder;
    let slice = source.as_slice();
    let tree = unsafe {
        ffi::ts_parser_parse_string(
            parser.parser,
            std::ptr::null(),
            slice.as_ptr() as *const c_char,
            slice.len() as u32,
        )
    };
    if tree.is_null() {
        // ts_parser_parse_string can fail (its docs: "on failure, returns
        // NULL"). The C NIF wrapped the NULL pointer in a resource term,
        // so a later tree_root_node crashed the whole VM. A tuple an
        // Erlang caller can catch is the whole point.
        (error(), parse_failed()).encode(env)
    } else {
        ResourceArc::new(TreeRes { tree }).encode(env)
    }
}

// ---- tree ----

#[rustler::nif]
fn tree_root_node<'a>(env: Env<'a>, tree: ResourceArc<TreeRes>) -> Term<'a> {
    let node = unsafe { ffi::ts_tree_root_node(tree.tree) };
    make_node_always(env, &tree, node)
}

// ---- node ----

#[rustler::nif]
fn node_type<'a>(env: Env<'a>, node: ResourceArc<NodeRes>) -> Term<'a> {
    if let Some(t) = null_guard(env, &node) {
        return t;
    }
    let ptr = unsafe { ffi::ts_node_type(node.node) };
    let bytes = unsafe { CStr::from_ptr(ptr) }.to_bytes();
    byte_string_to_list(env, bytes)
}

#[rustler::nif]
fn node_start_byte<'a>(env: Env<'a>, node: ResourceArc<NodeRes>) -> Term<'a> {
    use rustler::Encoder;
    if let Some(t) = null_guard(env, &node) {
        return t;
    }
    unsafe { ffi::ts_node_start_byte(node.node) }.encode(env)
}

#[rustler::nif]
fn node_end_byte<'a>(env: Env<'a>, node: ResourceArc<NodeRes>) -> Term<'a> {
    use rustler::Encoder;
    if let Some(t) = null_guard(env, &node) {
        return t;
    }
    unsafe { ffi::ts_node_end_byte(node.node) }.encode(env)
}

fn point_map<'a>(env: Env<'a>, point: ffi::TSPoint) -> NifResult<Term<'a>> {
    Term::map_from_arrays(
        env,
        &[row(), column()],
        &[point.row, point.column],
    )
}

#[rustler::nif]
fn node_start_point<'a>(env: Env<'a>, node: ResourceArc<NodeRes>) -> NifResult<Term<'a>> {
    if let Some(t) = null_guard(env, &node) {
        return Ok(t);
    }
    point_map(env, unsafe { ffi::ts_node_start_point(node.node) })
}

#[rustler::nif]
fn node_end_point<'a>(env: Env<'a>, node: ResourceArc<NodeRes>) -> NifResult<Term<'a>> {
    if let Some(t) = null_guard(env, &node) {
        return Ok(t);
    }
    point_map(env, unsafe { ffi::ts_node_end_point(node.node) })
}

#[rustler::nif]
fn node_is_null(node: ResourceArc<NodeRes>) -> bool {
    unsafe { ffi::ts_node_is_null(node.node) }
}

#[rustler::nif]
fn node_parent<'a>(env: Env<'a>, node: ResourceArc<NodeRes>) -> Term<'a> {
    if let Some(t) = null_guard(env, &node) {
        return t;
    }
    let parent = unsafe { ffi::ts_node_parent(node.node) };
    make_node_always(env, &node.tree, parent)
}

#[rustler::nif]
fn node_named_child<'a>(env: Env<'a>, node: ResourceArc<NodeRes>, index: u32) -> Term<'a> {
    if let Some(t) = null_guard(env, &node) {
        return t;
    }
    let child = unsafe { ffi::ts_node_named_child(node.node, index) };
    make_node_always(env, &node.tree, child)
}

#[rustler::nif]
fn node_named_child_count<'a>(env: Env<'a>, node: ResourceArc<NodeRes>) -> Term<'a> {
    use rustler::Encoder;
    if let Some(t) = null_guard(env, &node) {
        return t;
    }
    unsafe { ffi::ts_node_named_child_count(node.node) }.encode(env)
}

#[rustler::nif]
fn node_child_by_field_name<'a>(env: Env<'a>, node: ResourceArc<NodeRes>, name: Binary<'_>) -> Term<'a> {
    if let Some(t) = null_guard(env, &node) {
        return t;
    }
    let slice = name.as_slice();
    let child = unsafe {
        ffi::ts_node_child_by_field_name(
            node.node,
            slice.as_ptr() as *const c_char,
            slice.len() as u32,
        )
    };
    make_node_always(env, &node.tree, child)
}

/// Sibling navigation deliberately returns the bare atom `undefined` for
/// "no such sibling", not a null-node resource — the asymmetry the
/// extractors depend on (docs/tree-sitter-erlang.md §6).
#[rustler::nif]
fn node_next_sibling<'a>(env: Env<'a>, node: ResourceArc<NodeRes>) -> Term<'a> {
    use rustler::Encoder;
    if let Some(t) = null_guard(env, &node) {
        return t;
    }
    let sib = unsafe { ffi::ts_node_next_sibling(node.node) };
    if unsafe { ffi::ts_node_is_null(sib) } {
        undefined().encode(env)
    } else {
        make_node_always(env, &node.tree, sib)
    }
}

#[rustler::nif]
fn node_prev_sibling<'a>(env: Env<'a>, node: ResourceArc<NodeRes>) -> Term<'a> {
    use rustler::Encoder;
    if let Some(t) = null_guard(env, &node) {
        return t;
    }
    let sib = unsafe { ffi::ts_node_prev_sibling(node.node) };
    if unsafe { ffi::ts_node_is_null(sib) } {
        undefined().encode(env)
    } else {
        make_node_always(env, &node.tree, sib)
    }
}

// ---- query ----

/// Source is a binary (query strings were char lists before; ASCII, so
/// byte-identical).
#[rustler::nif]
fn query_new<'a>(env: Env<'a>, language: ResourceArc<LanguageRes>, source: Binary<'_>) -> Term<'a> {
    use rustler::Encoder;
    let slice = source.as_slice();
    let mut error_offset: u32 = 0;
    let mut error_type: u32 = 0;
    let query = unsafe {
        ffi::ts_query_new(
            language.lang,
            slice.as_ptr() as *const c_char,
            slice.len() as u32,
            &mut error_offset,
            &mut error_type,
        )
    };
    if query.is_null() {
        // The C NIF wrapped the NULL query in a resource term, deferring
        // the crash to the first query_capture call. `undefined` here makes
        // that first use a catchable badarg instead of a VM crash.
        (
            undefined(),
            error_offset,
            query_error_atom(error_type),
        )
            .encode(env)
    } else {
        (
            ResourceArc::new(QueryRes { query }),
            error_offset,
            query_error_atom(error_type),
        )
            .encode(env)
    }
}

/// Runs Query over Node's whole subtree and returns every capture as a
/// flat [{CaptureName, Node}] list — duplicated once per named capture in
/// the pattern (a tree-sitter behavior, not a bug here; see
/// docs/tree-sitter-erlang.md §6 for how the extractors work around it).
/// Same iteration shape as the C NIF: next_capture, then every capture of
/// the match. Unbounded CPU work → DirtyCpu.
#[rustler::nif(schedule = "DirtyCpu")]
fn query_capture<'a>(env: Env<'a>, node: ResourceArc<NodeRes>, query: ResourceArc<QueryRes>) -> Term<'a> {
    let cursor = unsafe { ffi::ts_query_cursor_new() };
    unsafe { ffi::ts_query_cursor_exec(cursor, query.query, node.node) };

    // Prepend, then reverse — the same shape as the C NIF's
    // enif_make_list_cell loop plus enif_make_reverse_list.
    let mut list = Term::list_new_empty(env);
    let mut count = 0usize;
    loop {
        let mut matched: ffi::TSQueryMatch = unsafe { std::mem::zeroed() };
        let mut capture_index: u32 = 0;
        if !unsafe {
            ffi::ts_query_cursor_next_capture(cursor, &mut matched, &mut capture_index)
        } {
            break;
        }
        for i in 0..matched.capture_count as usize {
            let capture = unsafe { *matched.captures.add(i) };
            let mut name_len: u32 = 0;
            let name_ptr = unsafe {
                ffi::ts_query_capture_name_for_id(query.query, capture.index, &mut name_len)
            };
            let name_bytes =
                unsafe { std::slice::from_raw_parts(name_ptr as *const u8, name_len as usize) };
            let name_term = byte_string_to_list(env, name_bytes);
            let node_term = make_node_always(env, &node.tree, capture.node);
            list = list.list_prepend((name_term, node_term));
            count += 1;
        }
    }
    unsafe { ffi::ts_query_cursor_delete(cursor) };

    let reversed = list.list_reverse().expect("list_reverse of a list we just built");
    debug_assert_eq!(count, reversed.list_length().unwrap_or(0));
    reversed
}

// ---------------------------------------------------------------------------
// Init
// ---------------------------------------------------------------------------

fn load(env: Env, _info: Term) -> bool {
    env.register::<LanguageRes>().is_ok()
        && env.register::<ParserRes>().is_ok()
        && env.register::<TreeRes>().is_ok()
        && env.register::<QueryRes>().is_ok()
        && env.register::<NodeRes>().is_ok()
}

// In Rustler 0.38 the NIF list is no longer passed to init! — every
// #[rustler::nif] function above registers itself via the `inventory`
// crate, and init! only takes the module name plus options.
rustler::init!("symbolic_ts", load = load);
