# Design: Natural Language Processing Tooling for Erlang

This document covers what fits `symbolic-tools`' in-process-on-the-BEAM,
no-subprocess design ([`erlang-mcp-design.md`](erlang-mcp-design.md)) for
natural language processing (NLP), in case a future need arises beyond what
the calling LLM already does. A design/research document only — nothing
here is implemented, and nothing in the current design requires it (see
§1). This is written against a specific correction to an earlier draft:
the platform this project is already built on has a native answer for a
large part of "NLP" before reaching for anything external.

**Recommendation up front:**

- **Grammar-shaped natural language → the Prolog engine itself.**
  `erlog` already implements DCGs (`erlog_lib_dcg.erl`, confirmed in
  [`erlang-mcp-design.md`](erlang-mcp-design.md) §6) — Prolog's native
  grammar-parsing mechanism, and historically the reason Prolog exists at
  all (it grew out of 1970s natural-language systems in Marseille and
  Edinburgh). For a constrained/controlled vocabulary, a DCG parses
  natural language directly into a Prolog goal or fact, in the same
  engine, with **no new dependency and no model**. See §2 — this is the
  primary answer, not the C-library/Elixir survey below.
- **Free tokenization, n-grams, or indexing, not grammar parsing:**
  **Erlang's binary pattern matching** — zero-copy, clause-based, the same
  mechanism that makes Erlang good at parsing telecom protocols. See §3,
  including **Riak Search** as real, shipped precedent for a full-text
  search engine built this way natively in Erlang, no ML involved.
- **Only once a genuine trained/statistical model is needed** (embeddings,
  classification, open-ended NER, generation) — something neither a DCG
  nor hand-written pattern matching can express — fall back to §4: Elixir
  libraries callable directly from Erlang (Bumblebee/Nx, Ortex, Penelope),
  small C libraries as direct NIF targets (`libstemmer_c`, CRFsuite), or
  the existing native-Erlang NIF binding to `llama.cpp` (`erllama`/
  `barrel_inference`).
- **Not viable at all**: spaCy, NLTK, CoreNLP — Python/Cython or Java, no C
  surface to bind to; the only path in is a subprocess, the exact boundary
  `erlang-mcp-design.md` was written to avoid.

## 1. Where this fits — and whether it's needed yet

`symbolic-tools`' premise is a division of labor: the **LLM** handles
open-ended natural-language understanding, the **Prolog engine** (`erlog`)
handles formal reasoning ([`erlang-mcp-design.md`](erlang-mcp-design.md),
[`lorp-approach.md`](lorp-approach.md), [`grpo-prolog-tool.md`](grpo-prolog-tool.md)).
What this document adds is that the boundary between those two isn't as
sharp as "LLM does all language, Prolog does none" — a meaningful slice of
"natural language processing," specifically anything expressible as a
grammar over a constrained vocabulary, sits naturally inside the Prolog
engine you already run, via DCGs (§2). Treat the trained-model survey (§4)
as the tier to reach for only once a need falls outside both §2 and §3.

## 2. DCGs in `erlog` — the primary answer

Definite Clause Grammars are Prolog's built-in mechanism for expressing a
grammar as ordinary clauses over a **difference list**: a DCG rule like

```prolog
sentence --> subject, verb, object.
subject  --> [the], noun.
verb     --> [depends_on].
object   --> [Module], { atom(Module) }.
```

compiles directly into standard Prolog and is invoked with `phrase/2` or
`phrase/3` — no external parser generator, no separate grammar tool. This
is not a workaround grafted onto Prolog; DCGs are *why* Prolog was built —
the language's early history is inseparable from natural-language-parsing
research, and a built-in parsing mechanism that preserves Prolog's logical
semantics was one of its founding design goals.

`erlang-mcp-design.md` §6 already confirms `erlog_lib_dcg.erl` ships with
`erlog:new/0` — DCG support is not a gap that needs Tier 1/2/3 work
(`erlang-mcp-design.md` §7); it's already there.

See [`curt-approach.md`](curt-approach.md) for the full worked-out version
of this: how tokenization and parsing actually divide (Prolog parses, it
isn't handed an already-parsed result), a grounded example grammar for
extracting `depends_on`/`calls`/`defines`-shaped facts, and how to grow an
accumulating fact store the same way Blackburn & Bos's "Curt" system does.

**What this buys, concretely:** for a constrained/controlled-vocabulary
query — the kind of translation step both [`lorp-approach.md`](lorp-approach.md)
and [`grpo-prolog-tool.md`](grpo-prolog-tool.md) describe an LLM doing with
a full trained model — a DCG can do the same translation deterministically,
in-engine, for free, whenever the input actually fits the grammar. This
doesn't replace the LLM for genuinely open-ended input; it means the
"translate structured-enough natural language into a goal" step doesn't
have to round-trip to a model at all when the vocabulary is bounded (e.g. a
fixed set of relations like `depends_on`/`calls`/`defines` over identifiers
already known to the fact base).

**Scope limit:** a DCG is only as good as its grammar — genuinely
open-vocabulary, ambiguous natural language is still the LLM's job. The
choice is the same as any grammar-vs-model tradeoff: bounded vocabulary and
a known set of relations → DCG; anything else → the LLM, as already
designed.

## 3. Binary pattern matching — native tokenization and indexing

For text work that isn't grammar-shaped — tokenizing, splitting into
n-grams, building a lookup index — Erlang's **binary pattern matching** is
a genuinely strong, idiomatic fit, not a fallback: matching a binary
doesn't copy the underlying data, and a tokenizer is routinely a screenful
of pattern-matching clauses, e.g.

```erlang
tokenize(<<C, Rest/binary>>, Acc, Word) when C =:= $\s; C =:= $\n ->
    tokenize(Rest, maybe_push(Word, Acc), <<>>);
tokenize(<<C, Rest/binary>>, Acc, Word) ->
    tokenize(Rest, Acc, <<Word/binary, C>>);
tokenize(<<>>, Acc, Word) ->
    lists:reverse(maybe_push(Word, Acc)).
```

This is the same mechanism Erlang uses for parsing telecom protocol
frames — it exists in the language specifically because pulling structure
out of a stream of bytes efficiently was a founding requirement, which is
exactly what tokenization is.

**Real precedent, not a hypothetical:** [Riak Search](https://github.com/basho/riak_search)
(Basho) built a full Lucene-style full-text search engine natively in
Erlang — no JVM, no subprocess — specifically to avoid the Erlang↔Java hop.
Its pieces:

- **`merge_index`** — a pure-Erlang LSM-tree-style storage backend for
  postings (the inverted-index entries), inspired by SSTables/Bitcask.
- **`qilr`** — parses search queries into execution plans (and documents
  into indexable terms).
- **Erlang-reimplemented Lucene analyzers** for tokenization, again to cut
  out a cross-language hop at index time.

It's not actively maintained today, but it's proof this is not a
hypothetical: a production-grade, non-ML, native-Erlang text-search system
existed and shipped. If `symbolic-tools` ever needs full-text search or
retrieval over extracted comments/docstrings ([`tree-sitter-erlang.md`](tree-sitter-erlang.md))
without a trained embedding model, this — hand-written binary-matching
tokenization plus a simple inverted index — is the idiomatic BEAM answer,
not an imported ML stack.

## 4. Fallback tier — only for a genuine trained/statistical model

Reach here only once a need falls outside both §2 (grammar-shaped) and §3
(tokenization/indexing without a model) — e.g. embeddings, open-vocabulary
classification/NER, or generation.

### 4.1 Elixir-ecosystem libraries, callable directly from Erlang

Elixir modules are ordinary BEAM modules, callable from Erlang with
`'Elixir.Module':function(Args)` — no port, no subprocess, no extra NIF
boundary beyond what the library itself already uses:

| Library | What it is |
|---|---|
| **[Bumblebee](https://github.com/elixir-nx/bumblebee)** | Pure-Elixir reimplementation of Hugging Face Transformers (Axon models), loads pretrained checkpoints from the HF Hub, GPU-accelerated via the EXLA NIF backend. Actively maintained, backed by an official Hugging Face collaboration. |
| **[`tokenizers`](https://github.com/elixir-nx/tokenizers)** | Rustler NIF binding to Hugging Face's Rust `tokenizers` crate (BPE/WordPiece/etc.) — the tokenization half of the Bumblebee stack; usable standalone too. |
| **[Ortex](https://github.com/elixir-nx/ortex)** | Rustler NIF wrapping ONNX Runtime's C API — runs any exported BERT/DistilBERT-class ONNX model (embeddings, classification, NER) with CUDA/TensorRT/CoreML backends available. |
| **[Penelope](https://github.com/pylon/penelope)** | scikit-learn-style wrapper around LIBSVM/LIBLINEAR/CRFsuite: tokenizer (incl. a BERT wordpiece tokenizer), POS tagger, CRF-based NER/intent classifier, pretrained-embedding vectorizers. Check current activity before depending on it. |

### 4.2 Small C libraries — direct NIF candidates

The same "one small C library, one thin NIF" shape
[`tree-sitter-erlang.md`](tree-sitter-erlang.md) uses for `libtree-sitter`:

| Library | License | What it does |
|---|---|---|
| **[`libstemmer_c`](https://github.com/indexdata/libstemmer_c)** (Snowball) | BSD-style | Stemming for ~20 languages. Tiny surface area — a direct, low-effort NIF target. |
| **[CRFsuite](https://github.com/chokkan/crfsuite)** | BSD | Conditional Random Fields for sequence labeling (POS tagging, NER). C core (`crfsuite.h`/`libcrfsuite`); Penelope already wraps this if the NIF work isn't worth it standalone. |
| **ICU (ICU4C)** | Unicode License | Not NLP modeling, but the standard C/C++ library for Unicode-aware text segmentation, script detection, transliteration. |

### 4.3 C/C++ inference engines with existing Erlang precedent

- **[llama.cpp](https://github.com/ggml-org/llama.cpp)** (C/C++, `ggml`
  tensor library) — LLM inference. **[`erllama`](https://hex.pm/packages/erllama)**,
  continued as **`barrel_inference`**, is a genuine native **Erlang**/OTP
  NIF runtime for it — the closest existing thing to "the `erl_ts` pattern,
  applied to an LLM."
- **ONNX Runtime** (C API) — see Ortex in §4.1; no direct Erlang NIF found,
  but the Elixir one is callable the same way as anything else in §4.1.

## 5. Not viable

spaCy (Cython + Python), NLTK (Python), CoreNLP (Java) — none expose a C
API to bind to. The only integration path is a subprocess, reintroducing
exactly the OS-boundary problem [`erlang-mcp-design.md`](erlang-mcp-design.md)
rejects for the Prolog engine itself.

## 6. Decision heuristic

```
need NL understanding at all?
  └─ no  ──> stop — the calling LLM already does this
  └─ yes
       └─ grammar-shaped / constrained vocabulary?
             └─ yes ──> DCG in erlog, phrase/2,3 (§2) — no new dependency
       └─ tokenization / n-grams / indexing, not parsing?
             └─ yes ──> hand-written binary pattern matching (§3),
                         inverted index if needed (Riak Search precedent)
       └─ genuinely needs a trained/statistical model (embeddings,
          open-vocabulary classification/NER, generation)?
             └─ yes ──> fallback tier (§4): Bumblebee/Nx/tokenizers or
                         Ortex for a model; llama.cpp via erllama/
                         barrel_inference for LLM inference;
                         libstemmer_c/CRFsuite or Penelope for classical
                         stats without a full model
```

## References

- [`erlang-mcp-design.md`](erlang-mcp-design.md) §6 — confirms
  `erlog_lib_dcg.erl` (DCG support) already ships with `erlog:new/0`; also
  the in-process-on-BEAM, no-subprocess philosophy this whole document is
  scoped by.
- [`lorp-approach.md`](lorp-approach.md) · [`grpo-prolog-tool.md`](grpo-prolog-tool.md)
  — the NL-to-Prolog translation step §2's DCG approach complements.
- [`curt-approach.md`](curt-approach.md) — the full worked-out architecture
  §2 sketches: tokenization vs. parsing, a grounded example grammar, and
  growing an accumulating fact store Curt-style.
- [`tree-sitter-erlang.md`](tree-sitter-erlang.md) — the NIF-over-a-C-library
  pattern §4.2/§4.3 reuse; also the extracted-comment/docstring text §3's
  indexing approach would apply to.
- [Definite clause grammar](https://en.wikipedia.org/wiki/Definite_clause_grammar) ·
  [Prolog DCG primer](https://www.metalevel.at/prolog/dcg)
- [`basho/riak_search`](https://github.com/basho/riak_search) — native
  Erlang full-text search (`merge_index`, `qilr`), the precedent behind §3.
- [`elixir-nx/bumblebee`](https://github.com/elixir-nx/bumblebee) ·
  [`elixir-nx/tokenizers`](https://github.com/elixir-nx/tokenizers) ·
  [`elixir-nx/ortex`](https://github.com/elixir-nx/ortex)
- [`pylon/penelope`](https://github.com/pylon/penelope)
- [`indexdata/libstemmer_c`](https://github.com/indexdata/libstemmer_c) ·
  [`chokkan/crfsuite`](https://github.com/chokkan/crfsuite)
- [`ggml-org/llama.cpp`](https://github.com/ggml-org/llama.cpp) ·
  [`erllama`](https://hex.pm/packages/erllama) / `barrel_inference`
