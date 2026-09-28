# Setting up a real model for `symbolic_extract_llm`

`symbolic_extract_llm` (`src/symbolic_extract_llm.erl`) is the
open-vocabulary tier of `docs/reviewing-llm-output.md` §4 — it needs a
real GGUF model on disk to do anything. This is that setup step,
§4.2's Phase 2: never automated, never committed, because model weights
are a different scale from anything else this project vendors (a
multi-gigabyte binary file, not a compiled artifact `rebar3` can
regenerate).

## 1. Get a model

Any instruct-tuned GGUF with a tool-calling-capable chat template
works — `erllama`'s chat auto-parser (`llama.cpp`'s own) recognizes the
Qwen family natively. Verified directly against this exact model, not
assumed:

```sh
mkdir -p ~/.cache/symbolic-tools/models
curl -L -o ~/.cache/symbolic-tools/models/qwen2.5-3b-instruct-q4_k_m.gguf \
  "https://huggingface.co/Qwen/Qwen2.5-3B-Instruct-GGUF/resolve/main/qwen2.5-3b-instruct-q4_k_m.gguf"
```

~2.0 GB download, official `Qwen/Qwen2.5-3B-Instruct-GGUF` repo,
`Q4_K_M` quantization. Loads in ~6 seconds on Metal (Apple M-series,
`n_gpu_layers => 99`); CPU-only load is slower but still works.

Any location is fine — `erllama:load_model/1`'s `model_path` takes an
absolute path, and nothing here assumes `~/.cache/symbolic-tools/`
specifically. Keep it out of the repo either way; there is nowhere in
`.gitignore` or the Homebrew formula that expects a model file to
exist.

## 2. Compute its fingerprint

`erllama` keys its KV cache on a SHA-256 of the model file — always
pass a real one (see the `erllama` `loading.md` guide's own "Common
pitfalls": without it, renaming the file invalidates every cached row):

```sh
shasum -a 256 ~/.cache/symbolic-tools/models/qwen2.5-3b-instruct-q4_k_m.gguf
```

## 3. Point the gated tests at it

`test/symbolic_extract_llm_manual_tests.erl` is skipped by default —
`rebar3 eunit` with no arguments shows every case in it as
`{skip, ...}`, never silently absent and never blocking ordinary CI on
a download nobody asked for. Run it for real:

```sh
SYMBOLIC_LLM_MODEL_PATH=~/.cache/symbolic-tools/models/qwen2.5-3b-instruct-q4_k_m.gguf \
  rebar3 eunit --module=symbolic_extract_llm_manual_tests
```

## 4. What these tests actually check, and what they don't

These are **accuracy** checks against real sentences (some drawn from
this repo's own code, the same dogfooding pattern `stale_doc_example/4`
already established), not plumbing-correctness checks —
`symbolic_extract_llm_tests.erl` (meck-mocked, no model, runs in every
ordinary test cycle) already owns that. Every case in the manual suite
was run for real against Qwen2.5-3B-Instruct before being written down,
including two it deliberately does **not** claim to have solved:

- A sentence using prose instead of `Function/Arity` form ("the parser
  calls the scanner") is correctly *rejected*, not guessed at —
  `decode_call/1`'s own validation catches it.
- A sentence that names a real-shaped function but describes neither
  known relation ("foo/2 improves performance") can be confidently
  misclassified rather than declined — the same "structured tool call,
  still wrong" ceiling `docs/reviewing-llm-output.md` §5 already names
  in the abstract, now observed with a real model rather than only
  argued. More surprising: repeating this exact call across separate
  real runs — same sentence, same `temperature => 0.0` — produced
  **both** outcomes, sometimes a wrong `{ok, {svo, foo/2, removed,
  none}}`, sometimes a correct `unrecognized`. Not test flakiness — a
  genuinely observed non-determinism, most likely `erllama`'s own
  byte-exact KV cache taking a warm-restored path on a repeat load of
  the same fingerprint versus a cold prefill on a fresh one, with a
  floating-point computation-order difference between the two that a
  temperature-0 sampler can't fully paper over. The gated test for this
  asserts only what's actually stable across every observed run (the
  call completes, `ok` or `unrecognized`, never a crash) — asserting
  either specific outcome would overstate what this model, run this
  way, is actually known to do.

Two rounds of real, evidence-based schema iteration already happened
getting here (`tools/0`'s `subject`/`object` field descriptions) — a
first version swapped subject and object for a plain "foo/2 calls
bar/1" sentence; fixing that then regressed the `removed` case (subject
left blank). Both are fixed in the current schema. A model this size
should not be expected to reach 100% on every future sentence; the
gated suite exists to notice drift, not to assert perfection.
