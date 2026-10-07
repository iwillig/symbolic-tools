//! On-disk snapshot format for a saved index — hand-rolled, like the
//! index itself: a magic-and-version header, then lengths, terms, and
//! postings as little-endian fixed-width fields, everything iterated in
//! sorted order so the same index always serializes to the same bytes
//! (deterministic in, deterministic out — the whole stack's promise).
//! serde/bincode would do this in fewer lines at the cost of a second
//! dependency surface for a format only this crate ever reads or
//! writes; the byte layout is pinned in docs/full-text-search.md.

use std::collections::HashMap;

use super::index::Index;

/// Magic + format version in one 8-byte tag. Bump the version byte for
/// any layout change and reject older files.
const MAGIC: &[u8] = b"SYMTEXT1";

pub enum ReadError {
    /// Filesystem failure (missing file, permissions, ...). The
    /// underlying io::Error is kept for debugging but deliberately
    /// matched away at the NIF boundary — callers only need the
    /// io_error/bad_snapshot distinction.
    #[allow(dead_code)]
    Io(std::io::Error),
    /// File exists but isn't a snapshot this version understands —
    /// wrong magic, truncated, or counts that overrun the buffer.
    Bad,
}

pub fn write(path: &str, index: &Index) -> Result<(), std::io::Error> {
    std::fs::write(path, encode(index))
}

pub fn read(path: &str) -> Result<Index, ReadError> {
    let bytes = std::fs::read(path).map_err(ReadError::Io)?;
    decode(&bytes).ok_or(ReadError::Bad)
}

/// Serialize in sorted order: docs by id, terms lexicographically,
/// postings by doc id — byte-identical output for identical indexes.
pub fn encode(index: &Index) -> Vec<u8> {
    let mut out = Vec::new();
    out.extend_from_slice(MAGIC);

    let mut doc_ids: Vec<u64> = index.doc_lens.keys().copied().collect();
    doc_ids.sort_unstable();
    put_u32(&mut out, doc_ids.len() as u32);
    for id in doc_ids {
        put_u64(&mut out, id);
        put_u32(&mut out, index.doc_lens[&id]);
    }

    let mut terms: Vec<&String> = index.postings.keys().collect();
    terms.sort_unstable();
    put_u32(&mut out, terms.len() as u32);
    for term in terms {
        let bytes = term.as_bytes();
        put_u32(&mut out, bytes.len() as u32);
        out.extend_from_slice(bytes);
        let posting = &index.postings[term];
        put_u32(&mut out, posting.len() as u32);
        let mut doc_ids: Vec<u64> = posting.keys().copied().collect();
        doc_ids.sort_unstable();
        for doc in doc_ids {
            put_u64(&mut out, doc);
            put_u32(&mut out, posting[&doc]);
        }
    }
    out
}

/// Returns None on any malformation — every read is bounds-checked
/// against the remaining buffer, and counts that would overrun reject
/// the whole file rather than trusting garbage.
pub fn decode(bytes: &[u8]) -> Option<Index> {
    let mut cursor = Cursor { bytes, pos: 0 };
    if cursor.take(MAGIC.len())? != MAGIC {
        return None;
    }

    let mut index = Index::new();

    let doc_entries = cursor.take_u32()? as usize;
    for _ in 0..doc_entries {
        let id = cursor.take_u64()?;
        let len = cursor.take_u32()?;
        if len == 0 {
            return None; // zero-token docs never enter the index
        }
        index.doc_lens.insert(id, len);
        index.total_tokens += len as u64;
    }

    let term_entries = cursor.take_u32()? as usize;
    for _ in 0..term_entries {
        let term_len = cursor.take_u32()? as usize;
        let term_bytes = cursor.take(term_len)?;
        let term = std::str::from_utf8(term_bytes).ok()?.to_string();
        let posting_entries = cursor.take_u32()? as usize;
        let mut posting = HashMap::new();
        for _ in 0..posting_entries {
            let doc = cursor.take_u64()?;
            let tf = cursor.take_u32()?;
            if tf == 0 {
                return None; // postings with zero tf are never written
            }
            posting.insert(doc, tf);
        }
        index.postings.insert(term, posting);
    }

    if cursor.pos != cursor.bytes.len() {
        return None; // trailing bytes = wrong format or corrupt tail
    }
    Some(index)
}

fn put_u32(out: &mut Vec<u8>, value: u32) {
    out.extend_from_slice(&value.to_le_bytes());
}

fn put_u64(out: &mut Vec<u8>, value: u64) {
    out.extend_from_slice(&value.to_le_bytes());
}

struct Cursor<'a> {
    bytes: &'a [u8],
    pos: usize,
}

impl Cursor<'_> {
    fn take(&mut self, len: usize) -> Option<&[u8]> {
        let end = self.pos.checked_add(len)?;
        let slice = self.bytes.get(self.pos..end)?;
        self.pos = end;
        Some(slice)
    }

    fn take_u32(&mut self) -> Option<u32> {
        Some(u32::from_le_bytes(self.take(4)?.try_into().ok()?))
    }

    fn take_u64(&mut self) -> Option<u64> {
        Some(u64::from_le_bytes(self.take(8)?.try_into().ok()?))
    }
}

#[cfg(test)]
mod tests {
    use super::{decode, encode};
    use crate::index::Index;
    use crate::tokenizer::tokenize;

    fn sample() -> Index {
        let mut index = Index::new();
        for (id, text) in [(1, "alpha beta beta"), (2, "gamma alpha"), (3, "delta")] {
            index.add_doc(id, &tokenize(text));
        }
        index
    }

    #[test]
    fn round_trip_is_exact() {
        let index = sample();
        let restored = decode(&encode(&index)).expect("valid snapshot");
        assert_eq!(restored.stats(), index.stats());
        assert_eq!(
            restored.search(&tokenize("alpha"), 10),
            index.search(&tokenize("alpha"), 10)
        );
    }

    #[test]
    fn encode_is_deterministic() {
        assert_eq!(encode(&sample()), encode(&sample()));
    }

    #[test]
    fn rejects_wrong_magic_truncation_and_trailing_bytes() {
        assert!(decode(b"NOTMAGIC").is_none());

        let good = encode(&sample());
        assert!(decode(&good[..good.len() - 1]).is_none()); // truncated

        let mut trailing = good.clone();
        trailing.push(0);
        assert!(decode(&trailing).is_none());
    }
}
