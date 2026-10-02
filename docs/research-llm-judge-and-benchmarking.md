# Research: A General-Purpose LLM Judge and Benchmarking System for `symbolic-tools`

What it would take to judge LLM output (claims about code, extracted `svo/3` terms,
generated Prolog goals, agent tool-call trajectories) with the fact base as the
oracle wherever it can answer and an LLM-as-judge only for the residual — and to
benchmark models, extractors and agents on those tasks with defensible statistics,
reproducibly, from Erlang. Research only; nothing below is built.

- **Date:** 2026-09-29 / 2026-09-30
- **Commit:** `c138c2b` (working tree: `.symbolic/config.json` modified, `docs/symbolic-agent.md` untracked)
- **Scope:** the existing `symbolic check` / `symbolic extract` / `symbolic_extract_llm` path, `check_claim/2`, the test and bench profiles, vendored `erllama` 0.11.0, `symbolic serve` logging; and the primary literature on LLM judging, atomic-claim verification, eval-harness data models, eval statistics and NL→logic benchmarks.
- **Method:** local claims were proved with `symbolic_query` where a fact family can answer (Appendix) and otherwise read from source with `path:line` citations; external claims were read from the arXiv PDFs and official docs/source, never from secondary write-ups. Every external claim carries its URL; what could not be verified is listed in §13.

**Recommendation up front:**

- The judge is *oracle first, LLM second*. `check_claim/2` already is a deterministic judge for two relations; an LLM judge belongs only past the structural ceiling `reviewing-llm-output.md` §5 draws, and must itself be benchmarked against oracle-labelled pairs before its verdicts steer anything (§10.4).
- The benchmark scores three stages separately — extraction parse-rate, verdict accuracy given a parse, end-to-end — and reports `unverifiable` as its own bucket, never folded into `false` (§10.1–10.2).
- Statistics per Miller 2024: a standard error next to every mean, clustered by source module, paired differences between systems on the same sample ids, K repetitions reduced per item, and an honest minimum-detectable-effect statement — a 50-sentence set only detects large effects (§6, §10.10–10.13).
- No BEAM library does any of this; build from the primary sources (§9). Mirror Inspect's run log for reproducibility and `claude plugin eval`'s gating rule for CI (§10.14, §10.16).
- Three prerequisite fixes before any benchmark is meaningful: carry the raw sentence in `symbolic_check:run_result/4`, move the labelled sentences out of `test/`, and capture erllama's `stats()` instead of discarding it (§11).

---

## 1. What exists today

### 1.1 The judge half, in embryo

`symbolic check` chains extraction and checking into one call. Proved over `src/`:

- `symbolic_check.erl` exports `run/5` and `run_result/4` and calls `symbolic_query:run_result/3` and `erlog_io:writeq1/1` (Appendix #2, #3).
- `symbolic_extract_llm.erl` exports `run/2`, `run_result/2`, `tools/0`, `decode_call/1`, `parse_verb/1`, `parse_ident/1`, `model_opts/1` and calls `erllama:load_model/1`, `erllama:chat/3`, `erllama:unload/1` (Appendix #2, #4).
- `check_claim/2` has exactly six clauses: `calls→true|false|unverifiable`, `removed→true|false`, and a catch-all `unverifiable` (Appendix #11). Two checkable relations, three verdicts.

Shapes, from source (`src/symbolic_check.erl:67-88`):

```
run_result(DbPath, RulesPath | undefined, Sentence, ModelPath | undefined)
  -> {ok, Fact, Verdict} | unrecognized | {error, term()}
Fact    = {svo, {'/',F,A}, calls, {'/',G,B}} | {svo, {'/',F,A}, removed, none}
Verdict = true | false | unverifiable          % the erlog atom, verbatim
```

`check/3` builds `"check_claim(" ++ erlog_io:writeq1(Fact) ++ ", Verdict)"` and runs it through `symbolic_query:run_result/3` (`:77-79`); `no_solution` means the rules file lacks `check_claim/2` and is returned as `{error, {no_check_claim_rule, Fact}}` (`:82-86`). CLI: JSON `{fact, verdict}` + exit 0; `Unrecognized.` + exit 1; stderr + exit 1 — exit 1 is ambiguous between "unrecognized" and "error" (`:45-55`).

The `-model` fallback fires only when the DCG returns `unrecognized` *and* a model path is given (`src/symbolic_extract.erl:70-76`); a DCG success or a tokenize error never falls through. The DCG's tokenizer accepts only `^[a-z][a-zA-Z0-9_]*(/[0-9]+)?$` words (`:150`).

The LLM tier (`src/symbolic_extract_llm.erl`): one tool `extract_svo` with `verb` closed to `[calls, removed]` (`:35, :152`) and `object` forced required because a real Qwen2.5-3B omitted it otherwise (`:126-134`); `temperature => 0.0`, `tool_choice` left at `auto` so the model can decline (`:106-110`); `tool_calls := []` → `unrecognized` (`:111-112`). **One `load_model` and one `unload` per call** (`:78-87`), and erllama's `stats` map is pattern-matched away (`:104-119`).

### 1.2 The benchmark half — absent

`bench/symbolic_bench.erl` measures `ts_extract:file/1` throughput with erlperf (`qps`, `us_per_call`, `mb_per_sec`, `lines_per_sec`; `:82-88`), prints a stdout table (`:97-107`), persists nothing. Invocation is `rebar3 as bench compile` then `erl -pa _build/bench/lib/*/ebin -pa _build/bench/lib/symbolic_tools/bench -noshell -eval 'symbolic_bench:run(), init:stop().'` (`docs/benchmarking.md:12-27`). The `bench` profile compiles `bench/`, not `test/` (`rebar.config:159-177`).

The only accuracy signal is `test/symbolic_extract_llm_manual_tests.erl`: gated on `SYMBOLIC_LLM_MODEL_PATH` (unset → generators return `[]`, `:31-57`), written against Qwen2.5-3B-Instruct Q4_K_M on Metal (`:24-26`), **four cases**, per-case `assertEqual`, no aggregate, no threshold, no persistence, one model load per case:

| # | Sentence | Expected | Lines |
|---|---|---|---|
| 1 | `run_result/2 calls chat_result/2` | `{ok, {svo, run_result/2, calls, chat_result/2}}` | `:64-68` |
| 2 | `frobnicate_widget/9 was removed` | `{ok, {svo, frobnicate_widget/9, removed, none}}` | `:70-74` |
| 3 | `the parser calls the scanner` | `{error, {malformed_arguments, _}}` | `:80-84` |
| 4 | `foo/2 improves performance` | *completes* — `unrecognized` or any `{ok, svo/3}` | `:105-113` |

Case 4's weak assertion records observed **non-determinism at temperature 0**: the same call produced a wrong `{ok, {svo, foo/2, removed, none}}` and a correct `unrecognized` across runs, attributed to warm-restored vs cold-prefill KV paths (`:86-104`). Plus 4 `symbolic_check` cases against a synthetic fact base built with `symbolic_fact_store:write/2` (`test/symbolic_check_tests.erl:10-48`) and 5 DCG cases (`test/symbolic_extract_tests.erl:46-66`). That is the entire labelled dataset, and it lives as literals inside EUnit modules.

`docs/symbolic-extract-llm-setup.md:93-94` states the intent: "the gated suite exists to notice drift, not to assert perfection." There is no numeric target anywhere.

### 1.3 Trajectory raw material

`symbolic serve` logs to `filename:basedir(user_log, "symbolic")/serve.log` via the default `logger_formatter` (`src/symbolic_serve.erl:63-72`). Lines are free-text format strings — `"query: goal=~s limit=~p path=~p"`, `"query: ok count=~p"`, `"parse: ok ... elapsed_ms=~p"`, `"overview: path=~p"` (`:289-346`) — with **no session/request id and no query timing**. The JSON-line handler sketched in `docs/logging-and-metrics.md:55-103` and the five-state workflow observer in `docs/gen-statem-design.md` §8 (`:252-350`) are both unbuilt. `docs/symbolic-agent.md` (untracked) step 4 — "Another LLM is used to review the results of the prolog query" — is the only place in the repo naming a reviewer-LLM role.

### 1.4 Small inconsistencies found on the way

- `-no-rules` help says every claim becomes `unverifiable` (`src/symbolic_cli.erl:108-111`); the code returns `{error, {no_check_claim_rule, _}}` (`src/symbolic_check.erl:86`).
- `docs/symbolic-extract-llm-setup.md:46-49` says gated cases show as `{skip, ...}`; the test file says EUnit has no first-class skip and returns `[]` (`:10-16`).
- `removed` is `true` for anything never defined, not only things that once existed (`.symbolic/rules.pl:1662-1663`; `test/symbolic_check_tests.erl:32-36` asserts `ghost/3 was removed` → `true` against a fixture that never had it).

---

## 2. What erllama 0.11.0 can actually do

Read from the vendored source under `_build/default/lib/erllama/` (version at `src/erllama.app.src:3`, matching `rebar.config:25`).

**Request options.** `chat_opts()` (`src/erllama.erl:346-370`): `tools`, `tool_choice => auto|required|none`, `json_schema`, `response_tokens` (the max-tokens knob — not `n_predict`), `stop_sequences`, `temperature`, `top_p`, `top_k`, `min_p`, `repetition_penalty`, `seed`, `grammar` (GBNF binary), `enable_thinking`, `middleware`. Unknown keys are rejected as `{unknown_option, Key}` (`:1094-1104`). `seed` is a **no-op under greedy sampling** ("honoured only with temperature > 0", `src/erllama_nif.erl:349`; `guides/configuration.md:224-225`).

**Constraints.** `grammar` and `json_schema` are each **rejected together with tools** — `{invalid_option, grammar, conflicts_with_tools}` (`src/erllama_chat.erl:123-127`; `guides/tool-calls.md:56-59, 132-136`). `tool_choice => required` constrains the whole reply to a tool call (`guides/tool-calls.md:129-131`). A judge cannot offer tools *and* schema-constrain free content in one call.

**What comes back.** `chat_result() = #{message, prompt, reply, stats}` (`src/erllama.erl:372-377`). `stats()` (`:253-289`): `prompt_tokens`, `completion_tokens`, `prefill_ms`, `generation_ms`, `cache_hit_kind`, `finish_reason :: stop|length|cancelled`, `cache_delta`. **No tokens/s** (derive `completion_tokens / generation_ms`), **no load time** (`load_model/1` blocks; only a `progress_to => Pid` stream, `:632-637`). **Logprobs exist only on `complete/2,3` and `stream/3`** (`:224-227, :396`); `chat/3`'s result has no `logprobs` key and `erllama_chat:chat_collect/3` keeps only `reply` and `stats` (`src/erllama_chat.erl:195-200`). The documented workaround is `chat_apply/3 → tokenize/3 → stream/3 (logprobs => N) → chat_parse/3` (`guides/tool-calls.md:101-125`).

**Lifecycle.** Each loaded model is a supervised `gen_statem` that lives until `unload/1` (`README.md:20-22`; `src/erllama.erl:665-674`); nothing auto-unloads it by default (`guides/configuration.md:43-53`). `load_model(ModelId, Config)` with explicit ids supports **many models in one BEAM** (`:643-656`; `README.md:185-198`) — an extractor and a local judge can be resident together. `n_seq_max` enables co-batched concurrency within one model (`guides/configuration.md:183-194`); there is no batch chat API.

**Fingerprint.** The project reads the whole GGUF and passes `fingerprint => crypto:hash(sha256, Bin)` (`src/symbolic_extract_llm.erl:95-99`); erllama's default `fingerprint_mode => safe` re-hashes at load (`guides/configuration.md:85-93`) — the file is read twice per call today.

**Observability.** Per-call `middleware => fun(Request, Next)` with `Request = #{op, model, args}` wraps `load_model`, `chat`, `chat_apply`, `chat_parse` (`guides/middleware.md:1-58`); the guide gives a wall-clock recipe (`:76-92`). This is where load time and per-call latency belong.

**Offline.** The stub backend cannot do `chat/3` at all — `do_chat_apply/2` returns `chat_not_supported` unless the backend exports `get_model_ref/1` (`src/erllama_model.erl:2330-2338`). meck is the only offline path (`test/symbolic_extract_llm_tests.erl:96-101`).

**Stale claims in our own docs.** `docs/reviewing-llm-output.md:43-44` and `:393-399` say erllama exposes "no `grammar`, `json_schema`, or `response_format` sampling-level option". 0.11.0 has `grammar` (`src/erllama.erl:367, 517`), `json_schema` (`:350`) and `tool_choice => required` (`src/erllama_opts.erl:334`). §7 item 5 of that doc ("extend erllama for real grammar-constrained decoding") is already satisfied upstream. Correcting those lines is a follow-up to this note, not part of it.

---

## 3. LLM-as-a-judge foundations

### 3.1 Zheng et al. 2023, "Judging LLM-as-a-Judge with MT-Bench and Chatbot Arena" — [arXiv:2306.05685](https://arxiv.org/abs/2306.05685)

Three judge variants (§3.1): *pairwise comparison*, *single-answer grading*, *reference-guided grading*. Trade-off in their words: pairwise "may lack scalability when the number of players increases ... grows quadratically"; single-answer "may be unable to discern subtle differences ... absolute scores are likely to fluctuate more than relative pairwise results if the judge model changes."

Documented biases (§3.3), with numbers:

- **Position bias** — consistency under order swap, default prompt (Table 2): Claude-v1 23.8%, GPT-3.5 46.2%, GPT-4 65.0%. "Most LLM judges favor the first position."
- **Verbosity bias** — the "repetitive list" attack (a rephrased list prepended, no new information); failure rate (Table 3): Claude-v1 91.3%, GPT-3.5 91.3%, GPT-4 8.7%.
- **Self-enhancement bias** — GPT-4 favours itself by 10%, Claude-v1 by 25%, but "our study cannot determine whether the models exhibit a self-enhancement bias."
- **Limited math/reasoning grading** — GPT-4 solves the problem when asked separately yet "was misled by the provided answers."

Mitigations (§3.4): swap positions and "only declare a win when an answer is preferred in both orders", else tie; few-shot lifts GPT-4 consistency 65.0→77.5% at 4× cost; chain-of-thought alone still makes "exactly the same mistake as the given answers"; **reference-guided** grading cut math failure from 14/20 (70%) to 3/20 (15%).

Agreement (§4): raw probability that two randomly chosen judges agree, against a random baseline — S2 (non-tie) GPT-4–human 85%, human–human 81%. Not kappa.

### 3.2 G-Eval — [arXiv:2303.16634](https://arxiv.org/abs/2303.16634)

Auto-generated evaluation steps (auto chain-of-thought) plus a form-filling score; probability-weighted score `Σ p(sᵢ)·sᵢ` to break integer-score ties (estimated by sampling 20 times at temperature 1 when logprobs are unavailable). SummEval Spearman 0.514 vs UniEval 0.474. Documents a **preference for LLM-generated text** over human-written summaries humans preferred — a self-reinforcement risk if the score becomes a reward.

### 3.3 Prometheus — [arXiv:2310.08491](https://arxiv.org/abs/2310.08491)

A 13B open-weight judge fine-tuned on GPT-4 feedback. Prompt has four components — instruction, response, a **customised score rubric with a description of each 1–5 level**, and a **reference answer** "that would receive a score of 5". Output is feedback then `[RESULT] N`. Pearson 0.897 with humans vs GPT-4's 0.882. What it adds: anchored pointwise scoring becomes workable when each level is described and a reference is supplied.

### 3.4 JudgeBench — [arXiv:2410.12784](https://arxiv.org/abs/2410.12784)

Judges should follow the hierarchy "(1) faithfully follow instructions, (2) factually and logically correct, (3) style" — style only when (1) and (2) are met. Pairs are built by sampling k responses from one strong model against datasets that **have verification algorithms**, keeping only questions with at least one correct and one incorrect response (350 pairs). Scoring: judge twice with swapped order; consistent preference (or one preference plus one tie) counts; inconsistent or double-tie is wrong. Results vs 50% random: GPT-4o 56.6%, Claude-3.5-Sonnet 64.3%, o3-mini (high) 80.9%; "many of the fine-tuned judges we evaluate score below the random guessing baseline."

### 3.5 When to use which

Pairwise when comparing systems with no reference (needs swap, scales quadratically). Pointwise when an absolute per-case number is needed (anchor every level, supply a reference). Reference-guided is the only variant that fixed math grading and is the shape of OpenAI evals `fact` and Inspect `model_graded_fact` (§5). **When ground truth is checkable by execution, don't ask an LLM at all** — that is JudgeBench's and FacTool's conclusion, and it is this project's premise.

---

## 4. Atomic-claim verification — the closest analogues to `symbolic check`

### 4.1 FActScore — [arXiv:2305.14251](https://arxiv.org/abs/2305.14251)

`f(y) = (1/|A_y|) Σ_{a∈A_y} I[a is supported by C]`; `FActScore(M) = E[f(M_x) | M_x responds]`. An atomic fact is "a short sentence conveying one piece of information"; justification: "even a single sentence is a mix of supported and unsupported facts, e.g., in 40% of the cases with ChatGPT." Three stated assumptions: support is undebatable; every fact has equal weight; the knowledge source doesn't conflict with itself. **Precision only** — abstaining or saying less scores higher. Labels are **Supported / Not-supported / Irrelevant** plus an abstention filter; Table 1 reports all four rates separately. Human agreement 88–96%; $4 per generation; best automated estimator within 2% of humans on the aggregate.

### 4.2 SAFE / LongFact — [arXiv:2403.18802](https://arxiv.org/abs/2403.18802)

Four steps: split into individual facts; revise each to be self-contained (replace pronouns); check relevance in the context of the response; rate via iterative search. Output is three counts — supported, irrelevant, not-supported. Metric: `Prec = S/(S+N)`, `R_K = min(S/K, 1)`, `F1@K` (0 if S=0), with K the user's preferred response length. **Irrelevant facts are excluded from F1@K** because they "measure instruction-following ability", diverging from FActScore (App. A.5). 72% agreement with humans on 16,011 facts; on 100 adjudicated disagreements SAFE was right 76%, humans 19%; 20× cheaper.

### 4.3 FacTool — [arXiv:2307.13528](https://arxiv.org/abs/2307.13528)

Five components: claim extraction, query generation, tool querying, evidence collection, agreement verification. Per-task claim definitions (KB-QA: ≤15 words, coreference resolved; code: each snippet is one claim; math: each arithmetic operation). **Code claims are verified by execution**: synthesise test inputs and candidate solutions, majority-vote a "pseudo-golden output", compare. Metrics at claim and response level (P/R/F1).

---

## 5. Eval-framework data models

Read from official docs and raw source, not blog posts.

- **OpenAI Evals** ([repo](https://github.com/openai/evals)): JSONL samples with `input` and `ideal`; registry YAML `<eval>.<split>.<version>`; `Eval(completion_fns, seed=20220722, samples_jsonl)` with per-sample RNG keyed on `f"{sample_id}:{seed}"`; `RunSpec(run_id, completion_fns, eval_name, run_config, created_at)` and `Event(run_id, sample_id, type, data)` logs. Model-graded `fact.yaml`: choices **A subset / B superset / C same / D disagree / E differ but immaterial**; `closedqa.yaml`: CoT then a single `Y`/`N`.
- **Inspect AI** ([inspect.aisi.org.uk](https://inspect.aisi.org.uk)): `Task(dataset, solver, scorer, epochs, metrics)`; `Sample(input, target, id, choices, metadata)`; scorers `match`, `includes`, `exact`, `f1`, `model_graded_qa`, `model_graded_fact` (literally the OpenAI `fact` prompt; grades parsed as `GRADE: C|P|I`; list of grader models → majority reducer); metrics `accuracy`, `stderr`, `stderr(cluster="…")`, `bootstrap_stderr`; epoch reducers `mean`, `at_least_k`, `pass_at_k`. **The `.eval` log's `EvalSpec` records** `task_version`, `task_args`, `dataset.{location, sample_ids, shuffled}`, `model`, `model_args`, `model_generate_config`, `revision.{type: git, commit}`, `packages`, `epochs` — the only framework that logs a git commit and package versions.
- **lm-evaluation-harness** ([repo](https://github.com/EleutherAI/lm-evaluation-harness)): task YAML with `doc_to_text`/`doc_to_target`, `output_type`, `metric_list[{metric, aggregation, higher_is_better}]`, `repeats`, `metadata.version`; CLI `--seed` is a 4-tuple `python,numpy,torch,fewshot`; `--log_samples`.
- **promptfoo** ([docs](https://www.promptfoo.dev/docs)): assertions `{type, value, threshold, weight, metric, provider}`; score = weighted average; model-graded `llm-rubric`, `factuality` (the A–E scheme), `select-best`; `--repeat`.
- **HELM** ([docs](https://crfm-helm.readthedocs.io)): `Scenario → Instance(input, references[tags])`, `Adapter`, `Metric → Stat`; outputs `run_spec.json`, `scenario_state.json` (every request/response), `per_instance_stats.json`, `stats.json`.

**Common schema** (intersection): task/recipe with a version → sample `(id, input, target, tags/metadata)` → generation record (full messages) → scorer → per-sample score with explanation → aggregate with SE → run identity (model + generate config + seed + dataset identity + code revision + repeats). Fields every one of them treats as essential for reproducibility: model id and args, temperature, task/prompt version, seed, dataset identity, repeats.

---

## 6. Statistics for evals

### 6.1 Miller 2024, "Adding Error Bars to Evals" (Anthropic) — [arXiv:2411.00640](https://arxiv.org/abs/2411.00640)

Five recommendations, verbatim: "1. Computing standard errors of the mean using the Central Limit Theorem 2. When questions are drawn in related groups, computing clustered standard errors 3. Reducing variance by resampling answers and by analyzing next-token probabilities 4. When two models are being compared, conducting statistical inference on the question-level paired differences, rather than the population-level summary statistics 5. Using power analysis to determine whether an eval (or a random subsample) is capable of testing a hypothesis of interest."

- `SE_CLT = sqrt(Var(s)/n)`; binary `SE = sqrt(s̄(1−s̄)/n)`; `CI₉₅ = s̄ ± 1.96·SE`. Bootstrap "unnecessary unless a complicated sampling scheme or estimator is being used."
- **Clustered SE** adds within-cluster covariance; on real Anthropic data it was "over 3X larger than naive." Report cluster count with question count.
- Resample each item K times; `Var(sᵢ) = σᵢ²/K`; stop when `E[σᵢ²]/K ≪ Var(x)`; never pool the K·N answers as independent; "in neither case should the sampling temperature be adjusted for the sake of reducing variance."
- **Paired comparison**: `SE_{A−B} = sqrt(SE_A² + SE_B² − 2·SE_A·SE_B·Corr)` — "a 'free' reduction in estimator variance" when both systems answer the same items.
- **Power**: `n = (z_{α/2}+z_β)²(ω² + σ_A²/K_A + σ_B²/K_B)/δ²`; for δ=0.03, α=0.05, power 0.8, n ≈ 969 — "new evals should contain at least 1,000 questions." Invert for the minimum detectable effect at fixed n.

### 6.2 pass@k — Codex, [arXiv:2107.03374](https://arxiv.org/abs/2107.03374)

Unbiased estimator `pass@k = E[1 − C(n−c,k)/C(n,k)]` from n ≥ k samples with c correct; `1−(1−p̂)^k` "is biased." Numerically stable: `1 − ∏_{i=n−c+1..n}(1 − k/i)`, returning 1 when `n−c < k`.

### 6.3 Agreement metrics

Cohen's κ = `(p_o − p_e)/(1 − p_e)`, two raters ([scikit-learn docs](https://scikit-learn.org/stable/modules/generated/sklearn.metrics.cohen_kappa_score.html)); Krippendorff's α = `1 − D_o/D_e`, any number of raters, any level of measurement, missing data allowed ([Krippendorff 2011](https://www.asc.upenn.edu/sites/default/files/2021-03/Computing%20Krippendorff%27s%20Alpha-Reliability.pdf)). **None of the judge papers use kappa** — they report raw agreement against a random baseline (Zheng), accuracy against objective labels (JudgeBench), Spearman/Kendall (G-Eval) or Pearson (Prometheus).

---

## 7. Anthropic's published eval guidance

- **Define success** ([platform.claude.com](https://platform.claude.com/docs/en/test-and-evaluate/define-success)): criteria are specific, measurable, achievable, relevant; "most use cases need multidimensional evaluation."
- **Develop tests** ([platform.claude.com](https://platform.claude.com/docs/en/test-and-evaluate/develop-tests)): "Be task-specific ... Automate when possible ... Prioritize volume over quality: More questions with slightly lower signal automated grading is better than fewer questions with high-quality human hand-graded evals." Grader prompts anchor scale ends, wrap the artifact in tags, constrain output to a number or yes/no; "use a different model to evaluate than the model used to generate."
- **`claude plugin eval`** ([code.claude.com](https://code.claude.com/docs/en/plugin-evals)): a case is a prompt plus pass/fail graders; six grader types — `regex`, `tool_used` (count bounds; `min: 0, max: 0` asserts never called), `tool_order`, `file_exists`, `llm` (2-of-3 votes on a rubric), `baseline` (compare to a reference transcript); 3 runs per case; with-plugin vs no-plugin arms; **Δ is reported but "never changes the exit code"**; JSON report `schemaVersion: 1`, additive camelCase.
- **Eval-audit checklist** (bundled with the `claude-api` skill, `shared/evals/eval-audit.md`): infra failures go to an `errors.jsonl` sidecar with a failure class, never scored as 0; "no answer" ≠ "negative answer"; `status: truncated` on `max_tokens`; read `model` from the *response* and assert it; oracle and null-baseline smoke runs before the first full pass; multiple reps with intervals; full per-case trajectories saved; judge calibrated against a few dozen human labels (~90% on clear-cut cases); judge tested on known negatives (empty string, "I don't know", confident wrong answer). Grading-method ladder: programmatic check → pairwise blind judge → pointwise rubric judge → human spot-check, preferring the leftmost that applies.

---

## 8. NL → logic-program benchmarks

- **FOLIO** ([arXiv:2209.00840](https://arxiv.org/abs/2209.00840)): 1,430 expert-written examples with parallel FOL, labels True/False/Unknown. Translation metrics: **SynV** (syntactic validity) and **ExcAcc** (execution accuracy through an inference engine). GPT-4 few-shot: SynV 93.9, ExcAcc 63.8 — "good at generating syntactically valid FOL formulas ... not yet good at translating an NL story to a logically or semantically similar FOL counterpart."
- **Logic-LM** ([arXiv:2305.12295](https://arxiv.org/abs/2305.12295)): formulator → symbolic solver (Pyke, Prover9, python-constraint, Z3) → interpreter. **Self-refinement** feeds "the erroneous logic form, the solver's error message, and a set of demonstrations" back until executable or a revision cap. Two numbers: `Exe_Rate` and `Exe_Acc`; FOLIO GPT-3.5 Exe_Rate 66.7% → 84.3% with refinement; CoT fallback for non-executable output.
- **LINC** ([arXiv:2310.15164](https://arxiv.org/abs/2310.15164)): LLM as semantic parser; Prover9 raises on bad syntax; syntax errors filtered before 10-way majority vote; syntax-error rates 38% StarCoderPlus, 24% GPT-3.5, 13% GPT-4 ("the same symbol is used with multiple arities"). Failure taxonomy L1 (implicit info missed) / L2 (explicit info lost to representation) / L3 (syntax). "Worse recall but better precision on True/False."
- **LogicBench** ([arXiv:2404.15522](https://arxiv.org/abs/2404.15522)): 25 inference patterns; scores yes/no *answers* (A(Yes), A(No)), not generated programs.
- **ProofWriter**: secondhand only (§13).

All three program-scoring benchmarks agree: syntactic validity ≈ 90%+ for a strong model while semantic fidelity is far lower, so **syntactic validity alone is not an accuracy proxy** — the general form of `docs/grpo-prolog-tool.md`'s "runs without error ≠ correct."

---

## 9. BEAM ecosystem

Searched hex.pm and GitHub on 2026-09-29. **No Erlang LLM-eval harness exists.** Elixir: [`tribunal`](https://hex.pm/packages/tribunal) 3.0.1 (ExUnit macros, deterministic asserts, `req_llm` judge asserts, `repeat:` with `pass_rule`, JSON output — no pairwise, no swap, no rubric anchoring, no SE); [`aludel`](https://hex.pm/packages/aludel) 0.8.1 (Phoenix/Ecto/Postgres platform); several tiny early packages. Elixir [`langchain`](https://github.com/brainlid/langchain) ships `LangChain.Trajectory` — tool-call-sequence assertions with strict/unordered/subset matching and golden files — the one BEAM idiom relevant to §10.15. `instructor_ex` and `bumblebee` have no eval facilities; erllama's author has no eval harness. Erlang proper has only perf tools (`erlperf`, `eministat`, `bmark`). None implements paired SE, clustered SE, position-swapped pairwise judging or pass@k. A `symbolic-tools` harness is built from the primary sources above, not wrapped around a library.

---

## 10. Design implications for `symbolic-tools`

1. **Three verdict buckets end-to-end; report the third separately.** `unverifiable` is our Irrelevant. Aggregate `true`/`false` into precision; report the `unverifiable` rate on its own; never fold it into `false`. (FActScore, SAFE A.5.)
2. **Score extractor and oracle as separate stages.** (a) parse/extraction success rate for `svo/3` or a generated goal, (b) verdict accuracy conditional on a parse, (c) end-to-end. FOLIO's SynV/ExcAcc gap is the reason. (FOLIO, Logic-LM.)
3. **Solver/extractor errors are first-class outcomes.** Log `{error, Reason}` per attempt and a repair-round counter; a repair loop against erlog's own error text is Logic-LM's self-refinement and `grpo-prolog-tool.md` §3's recommended inference shape. (Logic-LM, LINC.)
4. **Benchmark the judge itself on oracle-labelled pairs.** We have a verification algorithm — erlog over facts. Build pairs where `check_claim/2` gives `true` and `false`, judge twice with swapped order, count consistent-correct only, report against 50%. (JudgeBench.)
5. **Oracle over judge wherever the fact base can answer.** JudgeBench's hierarchy puts factual/logical correctness above style, and frontier judges scored 56–64% on objective pairs. The LLM judge is for what `reviewing-llm-output.md` §5 calls beyond the ceiling. (JudgeBench.)
6. **If an LLM judge is used: reference-guided, CoT-then-letter, standard output shape.** Bindings from the fact base are the reference. Adopt OpenAI `fact`'s A–E or Inspect's `GRADE: C|P|I` so results are comparable with those ecosystems. With erllama, `tool_choice => required` gives a typed verdict; `json_schema` is available when no tools are offered. (Zheng, fact.yaml, Inspect `_model.py`, §2.)
7. **Position-swap every pairwise call; record consistency as a metric.** (Zheng §3.4, JudgeBench §4.)
8. **Controls for verbosity and self-preference.** A "repetitive list" control (same content, longer), a ties-on-identical control, and the generating model logged on every judged text. (Zheng, G-Eval.)
9. **Mine hard cases JudgeBench-style.** Sample k extractions per sentence from the local model; keep sentences where at least one `svo` proves and one doesn't. Those are the discriminative items. (JudgeBench.)
10. **SE_CLT next to every mean, clustered by source module.** Claims about one module are not independent. Put `cluster` in sample metadata exactly as Inspect's `stderr(cluster=…)` expects. No bootstrap by default. (Miller, Inspect.)
11. **Paired differences on stable sample ids.** Extractor A vs B, model A vs B, prompt v1 vs v2 — same items, paired SE. The dataset therefore needs stable ids. (Miller.)
12. **K reps per item, reduced per item, then aggregated.** Especially given the observed temperature-0 flip (§1.2). Inspect's `epochs` + reducers (`mean`, `at_least_k`, `pass_at_k`) is the model; pass@k uses the Codex estimator. Don't lower temperature to "reduce variance". (Miller, Codex.)
13. **State the minimum detectable effect.** With Miller's parameters a 3-point difference needs ~969 items; a 50-sentence set detects only large effects, and the report should say so. (Miller.)
14. **Run log mirrors Inspect's `EvalSpec`/`EvalSample`.** Per run: task name+version, task args, dataset location + sample ids + shuffled flag, model id **and GGUF sha256**, generate config (temperature, seed, `response_tokens`), git revision of `.symbolic/rules.pl` and the fact base, erlog/tree-sitter versions, epochs + reducer. Per sample: id, epoch, raw sentence, extracted term, goal, verdict, explanation, error class, `stats()` timings. Versioned JSON, additive fields, like `claude plugin eval`'s `schemaVersion: 1`. (Inspect, plugin-evals.)
15. **Agent trajectories (design doc §6): process and outcome separately.** Outcome by execution (FacTool's code path; our fact base for a claimed edit); process by `tool_used`/`tool_order`/`file_exists`-style graders over the transcript — which, once `serve.log` is structured, are erlog rules over trajectory facts, the same technique as `check_claim/2`. Elixir LangChain's `Trajectory` shows sequence matching is already a BEAM idiom. (FacTool, plugin-evals, langchain.)
16. **Aggregate plugin-evals-style for CI, Miller-style for humans.** Threshold on the primary metric gates the exit code; Δ vs a frozen baseline and SE/CI are reported, never gating. (plugin-evals, Miller.)

---

## 11. Proposed shape, and what has to change first

**Judge — oracle first, LLM second.**
Tier 0: `check_claim/2` over facts. Tier 1: an LLM judge, reference-guided with fact-base bindings, `tool_choice => required` for a typed verdict, swapped orders when pairwise, loaded as a second erllama model alongside the extractor (§2) or a hosted model of a different family than the one under test. Tier 1 ships only with its own JudgeBench-style accuracy number against oracle-labelled pairs.

**Benchmark — three stages × statistics.**
Metrics: extraction parse-rate; verdict accuracy given parse; end-to-end; `unverifiable` rate. Per run: SE clustered by module, paired Δ vs a frozen baseline, K reps per item, pass@k where a repair loop runs, MDE stated. Dataset: JSONL with stable ids, `tags` (relation, source module, difficulty), provenance (human-written / oracle-derived / model-derived and which model), out of `test/`. Harness: `errors.jsonl` sidecar with failure class; per-case trace; `stats()` captured; model loaded once per run via named `load_model/2`; served-model fingerprint asserted; Inspect-style run header. Entry point: a second `bench/` module or a `symbolic bench` CLI command; threshold gates, Δ/SE informational; oracle and null-baseline smoke runs wired in.

**Prerequisite fixes** (small, each independently useful):

1. Carry the raw sentence in `symbolic_check:run_result/4`'s result and JSON — `reviewing-llm-output.md:645-652` already calls this load-bearing (§1.1).
2. Distinguish `unrecognized` from `error` in the CLI exit code, and fix the `-no-rules` help text (§1.4).
3. Stop discarding erllama `stats()`; time `load_model` via middleware (§2).
4. Move the labelled sentences into a data file reachable from the `bench` profile (§1.2).
5. Correct `reviewing-llm-output.md:43-44, 393-399` on erllama's grammar/json_schema support (§2).

**Trajectory judging** waits on structured, id-stamped `serve.log` records (`logging-and-metrics.md`'s JSON handler) — the §8 observer and any `tool_order`-style grader consume those, not free text.

---

## 12. Open decisions

1. **Scope of "general purpose"**: (a) claims about code only; (b) + generated Prolog goals; (c) + agent trajectories. Recommendation: design for all three, build (a) first — (b) reuses the same harness with `Exe_Rate`/`Exe_Acc`, (c) needs the logging prerequisite.
2. **Judge model**: local-only via erllama (offline, free, two resident models) vs. optionally a hosted Claude judge (different family than the model under test). Recommendation: both behind one behaviour, local default.
3. **Dataset home**: `priv/bench/*.jsonl` (ships in the release, reachable from every profile) vs. `bench/data/` (bench profile only). Recommendation: `priv/`, since `symbolic check` itself could consume the same cases as a self-test.
4. **Where the CLI surface lands**: a `symbolic bench` subcommand (release binary, one incantation) vs. staying in the `bench` profile alongside erlperf (keeps model deps out of the hot path). Undecided.

---

## 13. Unverified / not accessed

- Krippendorff's α thresholds (.800 reliable / .667 tentative) come from his *Content Analysis* textbook, not the 2011 paper read here.
- Cohen 1960 not accessed; κ cited via scikit-learn's documentation.
- ProofWriter (Tafjord et al. 2021) described only via Logic-LM and LINC.
- LINC's tie-breaking rule in K-way voting was cut by a figure in the PDF text.
- FOLIO's example count: abstract says 1,430, Table 1 says 1,435.
- lm-evaluation-harness and promptfoo result-JSON field lists are not enumerated in the docs fetched; HELM's `AdapterSpec` fields not confirmed verbatim.
- Prometheus per-benchmark tables beyond the 0.897/0.882/0.392 headline not extracted.
- No standalone Anthropic "Claude as a grader" page exists; the guidance is inside "develop tests".
- Elixir LangChain `Trajectory` known from its README only.
- erlperf `report => full` field shape (already flagged in `docs/benchmarking.md` §5).

---

## References

Project:

- [`reviewing-llm-output.md`](reviewing-llm-output.md) — the design this note extends: §3.2 (`svo/3` extraction), §4.1–4.2 (`symbolic_extract_llm`), §5 (structural ceiling), §6 (plans and trajectories), §7 (suggested path).
- [`benchmarking.md`](benchmarking.md) — the erlperf throughput bench and its invocation.
- [`symbolic-extract-llm-setup.md`](symbolic-extract-llm-setup.md) — the gated real-model tests and what they do and don't check.
- [`grpo-prolog-tool.md`](grpo-prolog-tool.md) — repair loops, best-of-N, "runs without error ≠ correct".
- [`logging-and-metrics.md`](logging-and-metrics.md), [`gen-statem-design.md`](gen-statem-design.md) §8 — the unbuilt structured logger and workflow observer trajectory judging depends on.
- [`research-query-costs-and-sqlite-storage.md`](research-query-costs-and-sqlite-storage.md) — the research-note convention this follows.

External:

- Zheng et al. 2023, *Judging LLM-as-a-Judge with MT-Bench and Chatbot Arena* — https://arxiv.org/abs/2306.05685
- Liu et al. 2023, *G-Eval* — https://arxiv.org/abs/2303.16634
- Kim et al. 2023, *Prometheus* — https://arxiv.org/abs/2310.08491
- Tan et al. 2025, *JudgeBench* — https://arxiv.org/abs/2410.12784
- Min et al. 2023, *FActScore* — https://arxiv.org/abs/2305.14251
- Wei et al. 2024, *Long-form factuality in LLMs* (SAFE / LongFact) — https://arxiv.org/abs/2403.18802
- Chern et al. 2023, *FacTool* — https://arxiv.org/abs/2307.13528
- Miller 2024, *Adding Error Bars to Evals* — https://arxiv.org/abs/2411.00640
- Chen et al. 2021, *Evaluating Large Language Models Trained on Code* (pass@k) — https://arxiv.org/abs/2107.03374
- Han et al. 2022, *FOLIO* — https://arxiv.org/abs/2209.00840
- Pan et al. 2023, *Logic-LM* — https://arxiv.org/abs/2305.12295
- Olausson et al. 2023, *LINC* — https://arxiv.org/abs/2310.15164
- Parmar et al. 2024, *LogicBench* — https://arxiv.org/abs/2404.15522
- OpenAI Evals — https://github.com/openai/evals (`docs/build-eval.md`, `docs/eval-templates.md`, `evals/registry/modelgraded/fact.yaml`, `evals/eval.py`, `evals/record.py`)
- Inspect AI — https://inspect.aisi.org.uk (tasks, datasets, scorers, metrics, eval-logs, options; `src/inspect_ai/scorer/_model.py`)
- lm-evaluation-harness — https://github.com/EleutherAI/lm-evaluation-harness (`docs/task_guide.md`, `docs/interface.md`)
- promptfoo — https://www.promptfoo.dev/docs (expected-outputs, model-graded, command-line)
- HELM — https://crfm-helm.readthedocs.io (code, tutorial)
- Anthropic, *Define success criteria* — https://platform.claude.com/docs/en/test-and-evaluate/define-success
- Anthropic, *Develop test cases* — https://platform.claude.com/docs/en/test-and-evaluate/develop-tests
- Claude Code, *Plugin evals* — https://code.claude.com/docs/en/plugin-evals
- scikit-learn, `cohen_kappa_score` — https://scikit-learn.org/stable/modules/generated/sklearn.metrics.cohen_kappa_score.html
- Krippendorff 2011, *Computing Krippendorff's Alpha-Reliability* — https://www.asc.upenn.edu/sites/default/files/2021-03/Computing%20Krippendorff%27s%20Alpha-Reliability.pdf
- erllama 0.11.0 — https://hex.pm/packages/erllama (vendored under `_build/default/lib/erllama/`: `src/erllama.erl`, `src/erllama_chat.erl`, `src/erllama_opts.erl`, `src/erllama_model.erl`, `guides/tool-calls.md`, `guides/configuration.md`, `guides/middleware.md`, `guides/loading.md`, `README.md`)
- tribunal — https://hex.pm/packages/tribunal · aludel — https://hex.pm/packages/aludel · Elixir LangChain — https://github.com/brainlid/langchain

---

## Appendix: Goals run and results

All against the MCP server, `.symbolic/rules.pl` consulted. #1–#10 with `src/` cached (27 files, 15,772 facts); #11–#17 with `docs/` cached (23 files, 3,009 facts). Results quoted as returned; lists elided where long.

| # | Goal | Result |
|---|---|---|
| 1 | `findall(F/A-File, (defines(F,A,_,File,_), (sub_atom(F,_,_,_,llm) ; sub_atom(F,_,_,_,judge) ; sub_atom(F,_,_,_,review) ; sub_atom(F,_,_,_,check) ; sub_atom(F,_,_,_,bench) ; sub_atom(F,_,_,_,eval))), R), sort(R,S), length(S,N)` | `N: 7` — `check/3` (`symbolic_check.erl`), `check_cmd/0` (`symbolic_cli.erl`), `check_tokens/1,2`, `run_checked/1` (`symbolic_extract.erl`), `run_checked/3` (`symbolic_query.erl`), `list_item_checked/1` (`ts_extract_markdown.erl`). No function named `*judge*`, `*bench*`, `*eval*` or `*llm*` in `src/` |
| 2 | `findall(F/A-Line, (export(F,A,File,Line), sub_atom(File,_,_,_,symbolic_check)), Ex), findall(F2/A2-Txt, (doc(F2,A2,File2,_,Txt), sub_atom(File2,_,_,_,symbolic_check)), Docs)` | `Ex: [run_result/4-32, run/5-29]`, `Docs: []` |
| 3 | same shape for `symbolic_extract_llm` | `Ex: [tools/0, run_result/2, run/2, parse_verb/1, parse_ident/1, model_opts/1, decode_call/1]`, `Docs: []` |
| 4 | `findall(Caller/CA-Spec, (calls(Caller,CA,Spec,File,_), sub_atom(File,_,_,_,symbolic_check), Spec = remote(_,_,_)), R), sort(R,S), length(S,N)` | `N: 10` — includes `check/3 → symbolic_query:run_result/3`, `check/3 → erlog_io:writeq1/1`, `run/5 → symbolic_query:resolve_rules/3`, `run/5 → jsx:encode/1`, `run_result/4 → symbolic_extract:run_result/2` |
| 5 | `findall(Caller/CA-Spec, (calls(Caller,CA,Spec,File,_), sub_atom(File,_,_,_,symbolic_extract_llm), Spec = remote(M,_,_), M \== lists, M \== maps, M \== erlang, M \== unicode, M \== binary, M \== string, M \== io_lib), R), sort(R,S), length(S,N)` | `N: 12` — `run_result/2 → erllama:load_model/1`, `run_result/2 → erllama:unload/1`, `run_result/2 → application:ensure_all_started/1`, `chat_result/2 → erllama:chat/3`, `model_opts/1 → file:read_file/1`, `model_opts/1 → crypto:hash/2`, `parse_ident/1 → re:run/3` |
| 6 | `findall(Line-Text, (comment(File,Line,Text), sub_atom(File,_,_,_,symbolic_extract_llm)), R), length(R,N)` | `N: 91` — header comment cites `docs/reviewing-llm-output.md` §3.2/§4/§4.2, erllama `guides/tool-calls.md`, Qwen2.5-3B-Instruct, three test tiers |
| 7 | `findall(File, defines(_,_,_,File,_), R), sort(R,S), length(S,N)` | `N: 27` source files (bound `R` unnecessarily — 558 items echoed; bind only what you read) |
| 8 | `findall(F/A-Line-Text, (doc(F,A,File,Line,Text), sub_atom(File,_,_,_,check)), R), length(R,N)` | `N: 0` — `symbolic_check.erl` has no `doc/5` facts |
| 9 | `findall(L-T, (heading(File,L,Lvl,T), …, Lvl =< 3), R)` | `{error: "{type_error,evaluable,<<\"4.2 Implementation plan: …\">>}"}` — wrong argument order; the schema is `heading(File, Level, Text, Line)` |
| 10 | `findall(Line-T, (paragraph(File,Line,T), …), R)` | `{error: "{type_error,evaluable,<<…>>}"}` — wrong argument order; the schema is `paragraph(File, Text, Line)` |
| 11 | `current_predicate(check_claim/2), findall(Rel-V, clause(check_claim(svo(_,Rel,_),V), _), L), length(L,N)` | `N: 6`, `L: [calls-true, calls-false, calls-unverifiable, removed-true, removed-false, _-unverifiable]` |
| 12 | `findall(Line-T, (heading(File,Lvl,T,Line), sub_atom(File,_,_,_,'reviewing-llm-output'), Lvl =< 3), R), length(R,N)` | `N: 15` — §1 core technique, §2 checkable by shape, §3 extracting a claim (3.1 DCG, 3.2 LLM SVO), §4 in-process model (4.1 bigger model, 4.2 implementation plan), §5 ceiling, §6 plans and actions, §7 suggested path, References |
| 13 | same for `'benchmarking.md'` | `[1-"Benchmarking the Extraction Layer", 10-"1. Run it", 33-"2. Reading the report", 62-"3. Why these four inputs, specifically", 80-"4. sample_duration and precision", 93-"5. Extending it"]` |
| 14 | same for `'grpo-prolog-tool'` | `[1-"Research: Training Language Models to Use Prolog as a Tool (GRPO)", 12-"1. What the paper does", 35-"2. Results that matter here", 56-"3. Implications for symbolic-tools", 89-"4. Open question", 99-"References"]` |
| 15 | same for `'symbolic-extract-llm-setup'` | `[1-"Setting up a real model for symbolic_extract_llm", 11-"1. Get a model", 34-"2. Compute its fingerprint", 44-"3. Point the gated tests at it", 56-"4. What these tests actually check, and what they don't"]` |
| 16 | `findall(Line-T, (paragraph(File,T,Line), sub_atom(File,_,_,_,'reviewing-llm-output'), Line >= 630, Line < 720), R)` | 14 paragraphs — §5 "structural truth only … never *does X do what was claimed*"; the two-things-must-be-right risk and "keeping the raw sentence attached to every result"; §6 trajectory observer; §7 items struck through as **Done**: `symbolic extract`, `stale_doc_call/4`, `check_claim/2` + `symbolic check`, `symbolic_extract_llm` Phases 0–3 |
| 17 | `findall(Line-T, (paragraph(File,T,Line), sub_atom(File,_,_,_,'benchmarking.md'), Line >= 1, Line < 100), R)` | 12 paragraphs — erlperf runner on `ts_extract:file/1`; `rebar3 as bench shell --eval` doesn't work (TTY); `sample_duration` default 2000 ms doubled QPS vs erlperf's 1 s default; TypeScript side is one 22-line fixture, "a real gap"; `report => full` unverified |

Engine quirks hit: the markdown families' argument order differs from the code families' (`heading(File, Level, Text, Line)`, `paragraph(File, Text, Line)` — Text before Line), and a `type_error, evaluable` on a binary is how a misplaced arithmetic comparison over `Text` surfaces; `sub_atom/5` on atoms and `sub_text/5` on binaries remain two predicates; binding a large `R` you won't read echoes it back in full (#7).
