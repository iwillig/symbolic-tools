//! Tokenization for the full-text index — the one place the "zero-model,
//! deterministic" stack decision shows up as code: UAX #29 word
//! segmentation (the same standard unicode-segmentation gives the whole
//! Rust ecosystem), lowercased, nothing statistical, nothing trained.
//! See docs/full-text-search.md.

/// Split text into lowercase word tokens.
///
/// `unicode_words` yields the UAX #29 word segments that contain
/// alphanumeric characters, so whitespace and pure-punctuation segments
/// are already dropped and `foo/2` becomes `foo` and `2` — exactly the
/// shape a search over code prose wants (`"foo"` finds the docstring
/// that mentions `foo/2`, and a bare `2` is too common to matter).
/// Lowercasing is Unicode-aware (`to_lowercase`), so `İ` matches `i̇`
/// the way a searcher expects.
pub fn tokenize(text: &str) -> Vec<String> {
    use unicode_segmentation::UnicodeSegmentation;
    text.unicode_words().map(|word| word.to_lowercase()).collect()
}

#[cfg(test)]
mod tests {
    use super::tokenize;

    #[test]
    fn words_only_no_punctuation_or_whitespace() {
        assert_eq!(
            tokenize("Hello, World!"),
            vec!["hello".to_string(), "world".to_string()]
        );
    }

    #[test]
    fn slash_terms_split_into_name_and_arity() {
        assert_eq!(
            tokenize("foo/2 calls bar/1"),
            vec![
                "foo".to_string(),
                "2".to_string(),
                "calls".to_string(),
                "bar".to_string(),
                "1".to_string()
            ]
        );
    }

    #[test]
    fn lowercases_unicode() {
        assert_eq!(tokenize("ÉTÉ"), vec!["été".to_string()]);
    }

    #[test]
    fn empty_and_punctuation_only_text_yield_nothing() {
        assert!(tokenize("").is_empty());
        assert!(tokenize("!!! ... ;;;").is_empty());
    }

    /// UAX #29 has no dictionary, so Han/Hiragana text segments per
    /// character — the honest zero-model behavior (dictionary-based CJK
    /// morphology is the lindera/vaporetto niche docs/rust-nlp-landscape.md
    /// describes, deliberately out of scope here). A query still matches,
    /// character-for-character.
    #[test]
    fn cjk_segments_per_character_no_dictionary() {
        assert_eq!(
            tokenize("check 呼び出す code"),
            vec!["check".to_string(), "呼".to_string(), "び".to_string(),
                 "出".to_string(), "す".to_string(), "code".to_string()]
        );
    }
}
