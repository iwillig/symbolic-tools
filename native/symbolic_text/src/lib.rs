//! symbolic_text — the Rustler NIF implementing symbolic-tools' full-text
//! search tier: a purpose-built inverted index (BM25) over UAX #29 word
//! tokens, zero-model and deterministic by construction. The stack
//! decision and its alternatives (tantivy, charabia, stemming) are
//! recorded in docs/full-text-search.md; the landscape survey that
//! motivated them is docs/rust-nlp-landscape.md.
//!
//! Design notes, contrasted with this repo's other NIF (symbolic_ts):
//!
//! 1. **No unsafe.** symbolic_ts wraps raw tree-sitter C pointers and
//!    needs `unsafe impl Send/Sync` plus a single-owner-process
//!    discipline. This crate is plain data: the resource is
//!    `Mutex<Index>`, genuinely `Send + Sync`, safe from any process —
//!    the lock serializes writers, and readers see a consistent snapshot
//!    of the maps because every NIF takes the lock for its whole call.
//! 2. **Dirty schedulers.** index_add_doc and index_search do unbounded
//!    CPU work (a fact database's whole prose corpus can be megabytes of
//!    text) → DirtyCpu. index_save/index_load do file I/O → DirtyIo.
//!    tokenize is cheap, normal-scheduled.
//! 3. **Errors are terms, not raises.** Every fallible entry point
//!    returns `{error, Reason}` tuples (invalid_utf8, io_error,
//!    bad_snapshot) rather than raising, so the Erlang wrapper's callers
//!    (symbolic_search, tests) pattern-match one shape — same contract
//!    style as the rest of this repo's CLI modules.
//!
//! Inputs are UTF-8 binaries; invalid UTF-8 is rejected loudly
//! (`invalid_utf8`), never guessed at — the same "unrecognized, not
//! silently wrong" stance symbolic_extract takes with its grammar.

use std::sync::Mutex;

use rustler::{atoms, Binary, Env, Encoder, Resource, ResourceArc, Term};

mod index;
mod snapshot;
mod tokenizer;

use index::Index;

atoms! {
    ok,
    error,
    invalid_utf8,
    io_error,
    bad_snapshot,
}

// ---------------------------------------------------------------------------
// Resource
// ---------------------------------------------------------------------------

/// A live index. `Mutex` (not symbolic_ts's unsafe Send/Sync) is the
/// whole concurrency story: any process may hold the resource term, the
/// lock serializes access, and a poisoned lock can only happen if a NIF
/// panicked mid-update — which would be a bug here, not a caller error,
/// so `expect` (loud panic) is the right response.
struct IndexRes {
    index: Mutex<Index>,
}
impl Resource for IndexRes {}

fn lock(index: &ResourceArc<IndexRes>) -> std::sync::MutexGuard<'_, Index> {
    index
        .index
        .lock()
        .expect("index mutex poisoned — a NIF panicked mid-update")
}

// ---------------------------------------------------------------------------
// NIFs
// ---------------------------------------------------------------------------

#[rustler::nif]
fn index_new() -> ResourceArc<IndexRes> {
    ResourceArc::new(IndexRes {
        index: Mutex::new(Index::new()),
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn index_add_doc<'a>(env: Env<'a>, index: ResourceArc<IndexRes>, doc_id: u64, text: Binary<'a>) -> Term<'a> {
    match std::str::from_utf8(text.as_slice()) {
        Ok(s) => {
            lock(&index).add_doc(doc_id, &tokenizer::tokenize(s));
            ok().encode(env)
        }
        Err(_) => (error(), invalid_utf8()).encode(env),
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn index_search<'a>(
    env: Env<'a>,
    index: ResourceArc<IndexRes>,
    query: Binary<'a>,
    limit: u64,
) -> Term<'a> {
    match std::str::from_utf8(query.as_slice()) {
        Ok(s) => {
            let results = lock(&index).search(&tokenizer::tokenize(s), limit as usize);
            (ok(), results).encode(env)
        }
        Err(_) => (error(), invalid_utf8()).encode(env),
    }
}

#[rustler::nif]
fn index_stats(env: Env<'_>, index: ResourceArc<IndexRes>) -> Term<'_> {
    let (docs, terms) = lock(&index).stats();
    (ok(), (docs as u64, terms as u64)).encode(env)
}

#[rustler::nif(schedule = "DirtyIo")]
fn index_save(env: Env<'_>, index: ResourceArc<IndexRes>, path: String) -> Term<'_> {
    match snapshot::write(&path, &lock(&index)) {
        Ok(()) => ok().encode(env),
        Err(_) => (error(), io_error()).encode(env),
    }
}

/// The same deterministic snapshot bytes index_save/2 writes, handed
/// back as a binary instead of a file — so the Erlang side can embed
/// the index in its own container format (the `symbolic parse --db`
/// sidecar pairs these bytes with its doc metadata; see
/// symbolic_search). Byte-identical to index_save's file contents for
/// the same index.
#[rustler::nif(schedule = "DirtyCpu")]
fn index_snapshot(env: Env<'_>, index: ResourceArc<IndexRes>) -> Term<'_> {
    let bytes = snapshot::encode(&lock(&index));
    let mut bin = rustler::OwnedBinary::new(bytes.len())
        .expect("binary term allocation failed");
    bin.as_mut_slice().copy_from_slice(&bytes);
    (ok(), bin.release(env)).encode(env)
}

/// Decode snapshot bytes (from index_snapshot/1, or an index_save/2
/// file read by the caller) back into a live index — the inverse of
/// index_snapshot/1. A whole corpus' postings can ride in one binary,
/// hence DirtyCpu.
#[rustler::nif(schedule = "DirtyCpu")]
fn index_load_binary<'a>(env: Env<'a>, bytes: Binary<'a>) -> Term<'a> {
    match snapshot::decode(bytes.as_slice()) {
        Some(index) => (
            ok(),
            ResourceArc::new(IndexRes {
                index: Mutex::new(index),
            }),
        )
            .encode(env),
        None => (error(), bad_snapshot()).encode(env),
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn index_load(env: Env<'_>, path: String) -> Term<'_> {
    match snapshot::read(&path) {
        Ok(index) => (
            ok(),
            ResourceArc::new(IndexRes {
                index: Mutex::new(index),
            }),
        )
            .encode(env),
        Err(snapshot::ReadError::Io(_)) => (error(), io_error()).encode(env),
        Err(snapshot::ReadError::Bad) => (error(), bad_snapshot()).encode(env),
    }
}

/// The tokenizer, exposed for tests and for pinning the UAX #29
/// contract from the Erlang side — search results are only as
/// deterministic as tokenization is.
#[rustler::nif]
fn tokenize<'a>(env: Env<'a>, text: Binary<'a>) -> Term<'a> {
    match std::str::from_utf8(text.as_slice()) {
        Ok(s) => (ok(), tokenizer::tokenize(s)).encode(env),
        Err(_) => (error(), invalid_utf8()).encode(env),
    }
}

// ---------------------------------------------------------------------------
// Init
// ---------------------------------------------------------------------------

fn load(env: Env, _info: Term) -> bool {
    env.register::<IndexRes>().is_ok()
}

// Rustler 0.38: every #[rustler::nif] registers itself via inventory;
// init! takes only the module name plus options.
rustler::init!("symbolic_text", load = load);
