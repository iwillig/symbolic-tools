//! Sentence and token analysis through nlprule's English tokenizer.
//!
//! The tokenizer binary is supplied by the operator in
//! `SYMBOLIC_NLPRULE_DATA`; it is not downloaded or bundled by this crate.
//! `Tokenizer::pipe` provides sentence segmentation, spans, POS/lemma tags,
//! and chunks. Grammar correction is intentionally outside this interface.

use std::{
    path::PathBuf,
    sync::{Mutex, OnceLock},
};

use rustler::{atoms, Binary, Encoder, Env, Term};
use serde_json::{json, Value};

atoms! {
    ok,
    error,
    invalid_utf8,
    missing_data,
    tokenizer_load_failed,
}

static TOKENIZER: OnceLock<Mutex<Option<nlprule::Tokenizer>>> = OnceLock::new();

enum TokenizerError {
    MissingData(String),
    Load(String),
}

fn tokenizer_path() -> Result<PathBuf, TokenizerError> {
    let dir = match std::env::var_os("SYMBOLIC_NLPRULE_DATA").filter(|value| !value.is_empty()) {
        Some(path) => PathBuf::from(path),
        None => {
            let data_home = std::env::var_os("XDG_DATA_HOME")
                .map(PathBuf::from)
                .or_else(|| {
                    std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".local/share"))
                })
                .ok_or_else(|| {
                    TokenizerError::MissingData(
                        "cannot determine a user data directory; set SYMBOLIC_NLPRULE_DATA"
                            .to_owned(),
                    )
                })?;
            data_home.join("symbolic/nlprule")
        }
    };
    let path = dir.join(nlprule::tokenizer_filename("en"));
    if !path.is_file() {
        return Err(TokenizerError::MissingData(format!(
            "English tokenizer not found at {}. Run `just install-nlprule-data` or set SYMBOLIC_NLPRULE_DATA to its directory",
            path.display()
        )));
    }
    Ok(path)
}

fn tokenizer() -> Result<std::sync::MutexGuard<'static, Option<nlprule::Tokenizer>>, TokenizerError>
{
    let path = tokenizer_path()?;
    let mut slot = TOKENIZER
        .get_or_init(|| Mutex::new(None))
        .lock()
        .expect("nlprule tokenizer mutex poisoned");
    if slot.is_none() {
        *slot =
            Some(nlprule::Tokenizer::new(path).map_err(|e| TokenizerError::Load(e.to_string()))?);
    }
    Ok(slot)
}

fn position(span: &nlprule::types::Span) -> Value {
    let byte = span.byte();
    let chars = span.char();
    json!({
        "byte": {"start": byte.start, "end": byte.end},
        "char": {"start": chars.start, "end": chars.end}
    })
}

fn analyze_json(text: &str, tokenizer: &nlprule::Tokenizer) -> Value {
    let sentences: Vec<Value> = tokenizer
        .pipe(text)
        .map(|sentence| {
            let tokens: Vec<Value> =
                sentence
                    .tokens()
                    .iter()
                    .map(|token| {
                        let tags: Vec<Value> = token.word().tags().iter()
                .filter(|tag| !tag.pos().as_str().is_empty())
                .map(|tag| json!({"lemma": tag.lemma().as_str(), "pos": tag.pos().as_str()}))
                .collect();
                        json!({
                            "text": token.word().as_str(),
                            "span": position(token.span()),
                            "has_space_before": token.has_space_before(),
                            "tags": tags,
                            "chunks": token.chunks(),
                        })
                    })
                    .collect();
            json!({"text": sentence.text(), "span": position(sentence.span()), "tokens": tokens})
        })
        .collect();
    json!({"language": "en", "sentences": sentences})
}

#[rustler::nif(schedule = "DirtyCpu")]
fn analyze<'a>(env: Env<'a>, text: Binary<'a>) -> Term<'a> {
    let text = match std::str::from_utf8(text.as_slice()) {
        Ok(text) => text,
        Err(_) => return (error(), invalid_utf8()).encode(env),
    };
    let tokenizer = match tokenizer() {
        Ok(tokenizer) => tokenizer,
        Err(TokenizerError::MissingData(reason)) => {
            return (error(), (missing_data(), reason.encode(env))).encode(env);
        }
        Err(TokenizerError::Load(reason)) => {
            return (error(), (tokenizer_load_failed(), reason.encode(env))).encode(env);
        }
    };
    let result = analyze_json(text, tokenizer.as_ref().expect("tokenizer initialized"));
    match serde_json::to_string(&result) {
        Ok(json) => (ok(), json).encode(env),
        Err(reason) => (
            error(),
            (tokenizer_load_failed(), reason.to_string()).encode(env),
        )
            .encode(env),
    }
}

fn load(_env: Env, _info: Term) -> bool {
    true
}

rustler::init!("symbolic_nlprule", load = load);
