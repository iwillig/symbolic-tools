//! symbolic_nlp — SPIKE. Proves the statistical NL tier's riskiest
//! unknowns (PLAN-statistical-nlp-tier.md Stage 1) in one build:
//!
//! 1. does rust-bert (libtorch via tch-rs) compile and link inside this
//!    repo's existing build_nif.sh Rustler-crate loop;
//! 2. does the resulting .so load and answer under erlang:load_nif;
//! 3. what is real per-question POS-tag latency.
//!
//! Scope: POS tagging (tag/1) and NER (ner/1), each over rust-bert's
//! turnkey default model. Model weights come from rust-bert's default
//! remote resource into its standard cache; pinning them by checksum
//! (the plan's determinism requirement) is a post-spike step, not a
//! spike question.
//!
//! POS returns (word, label, score) tuples — token/tag alignment is
//! built in; Stage 2's Erlang relation mapper consumes the pairs.
//!
//! The spike returns the tag sequence only. Token/tag alignment needs
//! the tokenizer-level API and is deliberately deferred — the spike's
//! questions are build, load, latency.

use std::sync::{Mutex, OnceLock};

use rustler::{atoms, Binary, Env, Encoder, Term};

atoms! {
    ok,
    error,
    invalid_utf8,
    model_load_failed,
    tag_failed,
}

static NER: OnceLock<Result<Mutex<rust_bert::pipelines::ner::NERModel>, String>> =
    OnceLock::new();

/// Same load-and-lock pattern as pos_model/0 — see its comment.
fn ner_model() -> Result<
    std::sync::MutexGuard<'static, rust_bert::pipelines::ner::NERModel>,
    String,
> {
    NER
        .get_or_init(|| {
            // ner::NERConfig is a private alias for TokenClassificationConfig.
            rust_bert::pipelines::ner::NERModel::new(
                rust_bert::pipelines::token_classification::TokenClassificationConfig::default(),
            )
            .map(Mutex::new)
            .map_err(|e| e.to_string())
        })
        .as_ref()
        .map_err(|e| e.clone())
        .map(|m| m.lock().expect("ner model mutex poisoned"))
}

/// ner("does verifyPhoneCode call verifyOtp?") ->
///   {ok, [{word, label, score}, ...]} — CoNLL-style labels (B-PER,
///   I-ORG, ...); a code identifier is unlikely to be an entity at all,
///   which is itself useful signal: entities the model knows are the
///   ones the entity normalizer must NOT treat as code names.
#[rustler::nif(schedule = "DirtyCpu")]
fn ner<'a>(env: Env<'a>, text: Binary<'a>) -> Term<'a> {
    let sentence = match std::str::from_utf8(text.as_slice()) {
        Ok(s) => s,
        Err(_) => return (error(), invalid_utf8()).encode(env),
    };

    let model = match ner_model() {
        Ok(m) => m,
        Err(reason) => return (error(), (model_load_failed(), reason.encode(env))).encode(env),
    };

    // Entity { word, label, score } — fields are public, so encode the
    // tuple directly rather than round-tripping through Debug like the
    // POS spike does.
    let entities: Vec<(String, String, f64)> = model
        .predict(&[sentence])
        .into_iter()
        .next()
        .unwrap_or_default()
        .into_iter()
        .map(|e| (e.word, e.label, e.score))
        .collect();
    (ok(), entities.encode(env)).encode(env)
}

static POS: OnceLock<Result<Mutex<rust_bert::pipelines::pos_tagging::POSModel>, String>> =
    OnceLock::new();

fn pos_model() -> Result<
    std::sync::MutexGuard<'static, rust_bert::pipelines::pos_tagging::POSModel>,
    String,
> {
    // OnceLock<Result<..>>: a failed load is cached too — a broken setup
    // answers {error, ...} on every call at NIF speed, never re-attempts
    // a multi-second download mid-session. The Mutex is load-bearing:
    // tch's Tensor is Send but not Sync (raw pointers), so the model can
    // be shared across NIF threads only behind a lock. That serializes
    // tagging — fine for one-question-at-a-time v1, revisited if the
    // benchmark demands concurrency.
    POS
        .get_or_init(|| {
            rust_bert::pipelines::pos_tagging::POSModel::new(
                rust_bert::pipelines::pos_tagging::POSConfig::default(),
            )
            .map(Mutex::new)
            .map_err(|e| e.to_string())
        })
        .as_ref()
        .map_err(|e| e.clone())
        .map(|m| m.lock().expect("pos model mutex poisoned"))
}

/// tag("does verifyPhoneCode call verifyOtp?") ->
///   {ok, [{word, label, score}, ...]} — one tuple per token, aligned
///   to the question's word order. Stage 2's relation mapper consumes
///   the (word, label) pairs; score is informational.
#[rustler::nif(schedule = "DirtyCpu")]
fn tag<'a>(env: Env<'a>, text: Binary<'a>) -> Term<'a> {
    let sentence = match std::str::from_utf8(text.as_slice()) {
        Ok(s) => s,
        Err(_) => return (error(), invalid_utf8()).encode(env),
    };

    let model = match pos_model() {
        Ok(m) => m,
        Err(reason) => return (error(), (model_load_failed(), reason.encode(env))).encode(env),
    };

    // predict is infallible and returns one tag sequence per input
    // sentence; the spike passes exactly one sentence. POSTag's fields
    // are public, so encode tuples directly — Stage 2 needs (word, tag)
    // alignment, not bare labels.
    let tags: Vec<(String, String, f64)> = model
        .predict(&[sentence])
        .into_iter()
        .next()
        .unwrap_or_default()
        .into_iter()
        .map(|t| (t.word, t.label, t.score))
        .collect();
    (ok(), tags.encode(env)).encode(env)
}

fn load(_env: rustler::Env, _info: Term) -> bool {
    true
}

rustler::init!("symbolic_nlp", load = load);
