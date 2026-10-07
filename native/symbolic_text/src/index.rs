//! The inverted index itself — hand-built, deliberately, in the Riak
//! Search tradition this repo's own docs/nlp-tooling.md §3 sketches: a
//! term → (doc → term-frequency) postings map plus per-doc lengths,
//! scored with classic Okapi BM25. No tantivy, no engine, no threads:
//! a search over a fact base's prose is exactly the bounded problem a
//! screenful of code solves. See docs/full-text-search.md for why buy
//! (tantivy) lost to build here.

use std::collections::HashMap;

/// Okapi BM25 parameters — the standard Robertson/Sparck-Jones values;
/// nothing in this corpus tune-worthy yet, and changing them changes
/// ranking, so they live here as named constants, not magic numbers.
const K1: f64 = 1.2;
const B: f64 = 0.75;

/// An in-memory inverted index.
///
/// All maps are plain `HashMap` — the NIF wraps the whole thing in one
/// `Mutex` (see lib.rs), so this needs no interior synchronization.
/// Fields are `pub(crate)` so snapshot.rs can (de)serialize them
/// directly, without inventing an iterator dance for one caller.
pub struct Index {
    pub(crate) postings: HashMap<String, HashMap<u64, u32>>,
    /// doc_id → token count (docs with zero tokens are absent — they can
    /// never match anything, so they never enter the index).
    pub(crate) doc_lens: HashMap<u64, u32>,
    pub(crate) total_tokens: u64,
}

impl Index {
    pub fn new() -> Self {
        Index {
            postings: HashMap::new(),
            doc_lens: HashMap::new(),
            total_tokens: 0,
        }
    }

    /// Index one document's tokens under `doc_id`. Re-adding an existing
    /// doc_id replaces its previous contribution first, so a re-extracted
    /// fact database never double-counts a document.
    pub fn add_doc(&mut self, doc_id: u64, tokens: &[String]) {
        self.remove_doc(doc_id);

        let mut per_doc: HashMap<&str, u32> = HashMap::new();
        for token in tokens {
            *per_doc.entry(token.as_str()).or_insert(0) += 1;
        }
        for (term, tf) in per_doc {
            self.postings
                .entry(term.to_string())
                .or_default()
                .insert(doc_id, tf);
        }
        if !tokens.is_empty() {
            self.doc_lens.insert(doc_id, tokens.len() as u32);
            self.total_tokens += tokens.len() as u64;
        }
    }

    /// Drop a doc's entire previous contribution (postings, length,
    /// total). No-op for an unknown doc_id.
    fn remove_doc(&mut self, doc_id: u64) {
        if let Some(old_len) = self.doc_lens.remove(&doc_id) {
            for posting in self.postings.values_mut() {
                posting.remove(&doc_id);
            }
            self.postings.retain(|_, posting| !posting.is_empty());
            self.total_tokens = self.total_tokens.saturating_sub(old_len as u64);
        }
    }

    /// Rank documents against a query's tokens with BM25.
    ///
    /// Deterministic by construction: scores sort descending, ties break
    /// ascending by doc_id — the same query against the same index always
    /// returns the same order, which is what "zero-model, deterministic"
    /// promised (and what the eunit suite pins).
    pub fn search(&self, query_tokens: &[String], limit: usize) -> Vec<(u64, f64)> {
        let doc_count = self.doc_lens.len() as f64;
        if doc_count == 0.0 {
            return Vec::new();
        }
        let avgdl = self.total_tokens as f64 / doc_count;

        let mut scores: HashMap<u64, f64> = HashMap::new();
        for term in query_tokens {
            let Some(posting) = self.postings.get(term) else {
                continue;
            };
            let df = posting.len() as f64;
            let idf = (1.0 + (doc_count - df + 0.5) / (df + 0.5)).ln();
            for (&doc_id, &tf) in posting {
                let dl = *self.doc_lens.get(&doc_id).unwrap_or(&1) as f64;
                let norm = tf as f64 + K1 * (1.0 - B + B * dl / avgdl);
                *scores.entry(doc_id).or_insert(0.0) += idf * tf as f64 * (K1 + 1.0) / norm;
            }
        }

        let mut ranked: Vec<(u64, f64)> = scores.into_iter().collect();
        ranked.sort_by(|a, b| {
            b.1.partial_cmp(&a.1)
                .unwrap_or(std::cmp::Ordering::Equal)
                .then(a.0.cmp(&b.0))
        });
        ranked.truncate(limit);
        ranked
    }

    /// (document count, distinct term count).
    pub fn stats(&self) -> (usize, usize) {
        (self.doc_lens.len(), self.postings.len())
    }
}

#[cfg(test)]
mod tests {
    use super::Index;
    use crate::tokenizer::tokenize;

    fn toks(text: &str) -> Vec<String> {
        tokenize(text)
    }

    fn index_of(docs: &[(u64, &str)]) -> Index {
        let mut index = Index::new();
        for (id, text) in docs {
            index.add_doc(*id, &toks(text));
        }
        index
    }

    #[test]
    fn empty_index_and_no_hit_terms_return_nothing() {
        assert!(Index::new().search(&toks("anything"), 10).is_empty());
        let index = index_of(&[(1, "alpha beta")]);
        assert!(index.search(&toks("gamma"), 10).is_empty());
    }

    #[test]
    fn higher_term_frequency_ranks_higher() {
        let index = index_of(&[(1, "alpha beta"), (2, "alpha alpha alpha")]);
        assert_eq!(index.search(&toks("alpha"), 10)[0].0, 2);
    }

    #[test]
    fn rarer_term_outranks_common_one() {
        // "rare" appears in one doc, "common" in both — a doc holding the
        // rare term must outscore a doc holding only the common one.
        let index = index_of(&[
            (1, "common rare"),
            (2, "common common common"),
        ]);
        assert_eq!(index.search(&toks("common rare"), 10)[0].0, 1);
    }

    #[test]
    fn limit_truncates_and_ties_break_by_doc_id() {
        let index = index_of(&[(3, "same"), (1, "same"), (2, "same")]);
        let results = index.search(&toks("same"), 2);
        assert_eq!(
            results.iter().map(|(id, _)| *id).collect::<Vec<_>>(),
            vec![1, 2]
        );
    }

    #[test]
    fn re_adding_a_doc_replaces_not_doubles() {
        let mut index = index_of(&[(1, "alpha alpha alpha")]);
        index.add_doc(1, &toks("beta"));
        let (docs, terms) = index.stats();
        assert_eq!((docs, terms), (1, 1));
        assert_eq!(index.search(&toks("alpha"), 10), vec![]);
        assert_eq!(index.search(&toks("beta"), 10)[0].0, 1);
    }

    #[test]
    fn zero_token_doc_never_enters_the_index() {
        let index = index_of(&[(1, "!!! ..."), (2, "real words")]);
        let (docs, _) = index.stats();
        assert_eq!(docs, 1);
    }

    #[test]
    fn score_is_positive_and_float() {
        let index = index_of(&[(1, "alpha")]);
        let results = index.search(&toks("alpha"), 1);
        assert_eq!(results.len(), 1);
        assert!(results[0].1 > 0.0);
    }
}
