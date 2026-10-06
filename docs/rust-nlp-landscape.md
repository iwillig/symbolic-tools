# The NLP-in-Rust landscape: a research note

What exists, what is maintained, and what to reach for — gathered against
primary sources (the crates.io API, the crates' own READMEs/docs, and GitHub
repos), not secondary write-ups. Metadata snapshot taken October 2026;
`recent_downloads` is crates.io's 90-day window.

This continues the `rnltk` review (see the conversation history / its own
docs at <https://docs.rs/rnltk>): `rnltk` is a ~1.5k-LOC lexicon toolkit,
last released 0.4.0 in April 2023, effectively dormant, with a broken
stem-key lookup. The question here is what the *rest* of the ecosystem
offers.

## TL;DR

Rust has excellent NLP **infrastructure** — tokenizers, inference runtimes,
Unicode segmentation, search — and effectively **no NLTK/spaCy equivalent**
for the classical pipeline (POS tagging, dependency parsing, lemmatization).
The practical choices:

| Want | Reach for | Why |
|---|---|---|
| Ready-made NER/POS/QA pipelines | `rust-bert` (or `ort` + HF ONNX models) | Only crate with turnkey pipelines; heavy (libtorch or ONNX) |
| Run HF models yourself, light deps | `candle` (+ `tokenizers`, `hf-hub`) | Pure Rust, GPU (CUDA/Metal), active, first-party HF |
| General ML framework with NLP examples | `burn` | Very active; `text-classification`/`text-generation` examples |
| Just tokenize/segment (fast, correct) | `unicode-segmentation`, `tokenizers`, `charabia` | UAX #29 / HF tokenizers / search-grade tokenizer |
| Language detection | `lingua` (accuracy) or `whatlang` (speed) | Both active; lingua better on short text |
| Stemming / stop words | `rust-stemmers`, `stop-words` | Snowball ports; stable, feature-complete |
| Local LLM inference in Rust | `mistral.rs` | Active, GGUF support, quantization |
| Full-text search engine | `tantivy` | Lucene-like, mature |
| Japanese/CJK morphology | `lindera`, `vaporetto`, `charabia` | The mature CJK niche |
| "NLTK in Rust" | **gap** — no good answer | See below |

## The layers, with data

All numbers below from `https://crates.io/api/v1/crates/<name>` on the
snapshot date.

### Foundations (text hygiene)

| Crate | Version | Last update | Recent DLs | Notes |
|---|---|---|---|---|
| `unicode-segmentation` | 1.13.3 | 2026-06 | 140.4M | Grapheme/word/sentence boundaries per UAX #29. The base layer everything else builds on |
| `rust-stemmers` | 1.2.0 | **2019-11** | 11.3M | Snowball algorithm ports. Dormant but complete — Snowball hasn't changed |
| `stop-words` | 0.10.1 | 2026-09 | 5.4M | Multi-language stop word lists |
| `text-splitter` | 0.33.0 | 2026-09 | 670k | Semantic chunking by chars or tokens; active |

`rust-stemmers` being unmaintained-since-2019 with 11M recent downloads is
the pattern for this layer: the algorithms are frozen, so the crates are too.

### Language identification

`lingua` 1.8.0 (2026-03, 790k recent) — n-gram-based, accurate on short and
mixed-language text. `whatlang` 0.18.0 (2025-10, 1.3M recent) — trigram
script/heuristic detection, lighter and faster. Both healthy; pick lingua
for accuracy on short text, whatlang for speed.

### Tokenization

- `tokenizers` (Hugging Face) — **1.0.0-rc.2**, 15.2M recent downloads, the
  de facto standard: BPE/WordPiece/Unigram in Rust, used by the Python
  transformers stack itself. Source: <https://github.com/huggingface/tokenizers>
- `sentencepiece` 0.14.0 (2026-07) — bindings to the SentencePiece
  tokenizer.
- `charabia` 0.10.0 (2026-08) — Meilisearch's production tokenizer:
  language detection + segmentation + normalization in one pass. Best
  "search-grade" option for messy multilingual text.
- CJK: `lindera` 6.2.0 (2026-09, 1.0M recent) morphological analyzer
  (Kuromoji lineage) and `vaporetto` 0.6.5 (2025-03, 72k recent) pointwise
  tokenizer. This is the one classical-NLP niche where Rust is genuinely
  mature — driven by Japanese search engines.

### Ready-to-use NLP pipelines (the `rust-bert` tier)

`rust-bert` 0.23.0 — a port of Hugging Face Transformers to Rust using
`tch-rs` (libtorch) or `onnxruntime` bindings, with `rust-tokenizers` for
preprocessing and GPU inference. Ready pipelines: translation,
summarization, zero-shot classification, sentiment, NER, **POS tagging**,
question answering, text generation, sentence embeddings, keyword
extraction; models BERT/RoBERTa/DeBERTa/GPT-2/GPT-J/BART/Marian/M2M100
among others. Source: README at
<https://github.com/guillaume-be/rust-bert>.

Caveats: the last crates.io release is **September 2024** (repo pushed
January 2026) — it trails the HF ecosystem, and it drags in libtorch or
ONNX Runtime, which are heavyweight, non-Rust-native dependencies. It is
the closest thing to spaCy-in-Rust that exists, and it is showing its age.

The modern alternative is assembling the same pipelines yourself from
active parts: `ort` 2.0.0-rc.13 (ONNX Runtime wrapper, 8.0M recent) or
`candle` (below) plus `tokenizers` + `hf-hub` — more work, current models.

### ML frameworks you'd build NLP on

- `candle` 0.11.0 — Hugging Face's minimalist pure-Rust ML framework,
  CUDA/Metal/WASM, 3.5M recent downloads, very active. Ships BERT-family
  examples (repo `candle-examples/examples/`: `bert`, `distilbert`,
  `debertav2`, `modernbert`, `quantized-t5`, …). Source:
  <https://github.com/huggingface/candle>
- `burn` 0.22.0-pre — general DL framework, 16k GitHub stars, repo pushed
  2026-10, with `text-classification` and `text-generation` examples.
  Source: <https://github.com/tracel-ai/burn>
- `tch` 0.26.0 — libtorch (PyTorch C++) bindings, 2.2M recent; mature but
  ties you to a C++ toolchain.
- `ort` 2.0.0-rc.13 — ONNX Runtime bindings, 8.0M recent; the pragmatic
  "run the same ONNX export Python uses" path.

### LLM inference in Rust

- `mistral.rs` 0.8.1 (2026-04, 138k recent) — fast local LLM inference
  engine; supports **GGUF loading** (`-f` / `--quant`), ISQ quantization,
  paged attention, prefix caching. Source:
  <https://github.com/EricLBuehler/mistral.rs>
- `hf-hub` 1.0.0 (2026-07, 8.2M recent) — first-party HF Hub client for
  pulling models/tokenizers.
- `llm` 1.3.8 (2026-04) — unifying API-client library for hosted LLM
  backends (not local inference).
- `kalosm` 0.4.0 (2025-02, ~2k recent) — Floneum's "simple interface for
  pretrained models"; stalled since early 2025.

### Search, embeddings, vectors

- `tantivy` 0.26.2 (2026-09, 4.3M recent) — the Lucene-of-Rust full-text
  search library. Mature and active.
- `fasttext` 0.8.0 (2026-04, 1.2M recent) — messense's pure-Rust fastText
  (classification + embeddings).
- `finalfrontier` 0.9.4 — word embeddings with subword units; **dead since
  2020** (111 recent downloads). The word2vec/fastText training niche in
  pure Rust has largely evaporated; use `fasttext` or run inference via
  `candle`/`ort` instead.

## The gap: "NLTK/spaCy for Rust" still does not exist

Checked directly (all primary sources):

| Candidate | Verdict |
|---|---|
| `rnltk` | Dormant (0.4.0, Apr 2023); lexicon lookups only; stem-key bug |
| `natural` (rs-natural) | Dead — last release Feb 2020, 65k lifetime downloads |
| `nlp` | Dead — 2016, 8.5k lifetime downloads |
| `crfsuite` (crfsuite-rs) | Active wrapper (2026-01) of C++ crfsuite — a sequence-labelling engine, not a toolkit |
| native POS taggers / dependency parsers | None of note on crates.io as of the snapshot |

So the classical pipeline (tokenize → POS tag → parse dependencies →
lemmatize) has no maintained pure-Rust implementation. The realistic
options are (a) `rust-bert`/`candle`/`ort` with a neural tagger, (b)
wrapping an established engine (spaCy/CoreNLP) through FFI/IPC, or (c)
skipping the pipeline — which is what this repo does.

## Relation to symbolic-tools

- The open-vocabulary tier (`symbolic_extract_llm`, per
  `docs/symbolic-extract-llm-setup.md`) already runs a local Qwen2.5-3B
  GGUF through `erllama` (an Erlang llama.cpp-family binding) — the
  llama.cpp ecosystem, not Rust crates. `mistral.rs` is the closest
  Rust-native equivalent and would only matter if that tier were ever
  rewritten in Rust.
- The bounded-grammar tier (`check_claim/2`'s DCG sentence extractor) needs
  none of this: it is a hand-written grammar, and nothing in the Rust
  ecosystem would replace it — there is no maintained natural-language
  *parser* crate to reach for, which is itself the headline finding.
- `tree-sitter` (43.4M recent downloads) — already this repo's parsing
  layer — is for *code* grammars; it has no natural-language role.

## Sources

- crates.io API responses (per-crate metadata above), fetched October 2026
- `rust-bert` README: <https://github.com/guillaume-be/rust-bert>
- `candle` README and `candle-examples/examples/` listing:
  <https://github.com/huggingface/candle>
- `burn` examples listing: <https://github.com/tracel-ai/burn>
- `mistral.rs` README: <https://github.com/EricLBuehler/mistral.rs>
- `rnltk` docs and source: <https://docs.rs/rnltk/latest/rnltk/> (reviewed
  in conversation; see above for the specific bugs found)
- GitHub repo API (`api.github.com/repos/...`) for star counts and push dates
