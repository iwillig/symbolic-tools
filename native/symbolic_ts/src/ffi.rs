//! Raw extern "C" bindings over the vendored tree-sitter core
//! (c_src/tree-sitter), compiled by build.rs into this same cdylib.
//! Struct layouts are #[repr(C)] mirrors of include/tree_sitter/api.h —
//! field order matters (TSNode is context, id, tree) and structs cross
//! the FFI boundary by value, so these must match exactly.

#![allow(non_camel_case_types)]

use std::ffi::{c_char, c_void};

#[repr(C)]
#[derive(Clone, Copy)]
pub struct TSPoint {
    pub row: u32,
    pub column: u32,
}

/// A TSNode is a plain value (a span + indexes into its TSTree), not a
/// heap pointer — Copy, no drop.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct TSNode {
    pub context: [u32; 4],
    pub id: *const c_void,
    pub tree: *const c_void,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct TSQueryCapture {
    pub node: TSNode,
    pub index: u32,
}

#[repr(C)]
pub struct TSQueryMatch {
    pub id: u32,
    pub pattern_index: u16,
    pub capture_count: u16,
    pub captures: *const TSQueryCapture,
}

// Opaque handles.
pub type TSLanguage = c_void;
pub type TSParser = c_void;
pub type TSTree = c_void;
pub type TSQuery = c_void;
pub type TSQueryCursor = c_void;

extern "C" {
    // Grammar entry points (compiled from c_src/grammars/*/parser.c).
    pub fn tree_sitter_erlang() -> *const TSLanguage;
    pub fn tree_sitter_typescript() -> *const TSLanguage;
    pub fn tree_sitter_markdown() -> *const TSLanguage;
    pub fn tree_sitter_toml() -> *const TSLanguage;
    pub fn tree_sitter_json() -> *const TSLanguage;
    pub fn tree_sitter_bash() -> *const TSLanguage;
    pub fn tree_sitter_jsdoc() -> *const TSLanguage;
    pub fn tree_sitter_rust() -> *const TSLanguage;

    // Parser.
    pub fn ts_parser_new() -> *mut TSParser;
    pub fn ts_parser_delete(parser: *mut TSParser);
    pub fn ts_parser_set_language(parser: *mut TSParser, language: *const TSLanguage) -> bool;
    pub fn ts_parser_parse_string(
        parser: *mut TSParser,
        old_tree: *const TSTree,
        string: *const c_char,
        length: u32,
    ) -> *mut TSTree;

    // Tree.
    pub fn ts_tree_delete(tree: *mut TSTree);
    pub fn ts_tree_root_node(tree: *const TSTree) -> TSNode;

    // Node.
    pub fn ts_node_is_null(node: TSNode) -> bool;
    pub fn ts_node_type(node: TSNode) -> *const c_char;
    pub fn ts_node_start_byte(node: TSNode) -> u32;
    pub fn ts_node_end_byte(node: TSNode) -> u32;
    pub fn ts_node_start_point(node: TSNode) -> TSPoint;
    pub fn ts_node_end_point(node: TSNode) -> TSPoint;
    pub fn ts_node_parent(node: TSNode) -> TSNode;
    pub fn ts_node_named_child(node: TSNode, index: u32) -> TSNode;
    pub fn ts_node_named_child_count(node: TSNode) -> u32;
    pub fn ts_node_child_by_field_name(
        node: TSNode,
        name: *const c_char,
        name_length: u32,
    ) -> TSNode;
    pub fn ts_node_next_sibling(node: TSNode) -> TSNode;
    pub fn ts_node_prev_sibling(node: TSNode) -> TSNode;

    // Query.
    pub fn ts_query_new(
        language: *const TSLanguage,
        source: *const c_char,
        source_len: u32,
        error_offset: *mut u32,
        error_type: *mut u32,
    ) -> *mut TSQuery;
    pub fn ts_query_delete(query: *mut TSQuery);
    pub fn ts_query_capture_name_for_id(
        query: *const TSQuery,
        id: u32,
        len: *mut u32,
    ) -> *const c_char;
    pub fn ts_query_cursor_new() -> *mut TSQueryCursor;
    pub fn ts_query_cursor_delete(cursor: *mut TSQueryCursor);
    pub fn ts_query_cursor_exec(cursor: *mut TSQueryCursor, query: *const TSQuery, node: TSNode);
    pub fn ts_query_cursor_next_capture(
        cursor: *mut TSQueryCursor,
        match_: *mut TSQueryMatch,
        capture_index: *mut u32,
    ) -> bool;
}
