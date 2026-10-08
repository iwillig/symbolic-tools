# Research: A Jev-Style System-1 Translator for symbolic-tools

Summary of research into a fourth architectural shape for the NL↔Prolog
boundary, alongside [`grpo-prolog-tool.md`](grpo-prolog-tool.md),
[`lorp-approach.md`](lorp-approach.md), and [`curt-approach.md`](curt-approach.md).
This is a research summary, not an implementation design — nothing here is
built. All three existing docs still let the LLM participate in *reasoning*
about the logic: GRPO's agentic loop has the LLM read an execution error and
decide how to fix the program; LoRP's voting stage implicitly weighs several
reasoning attempts against each other; Curt's semantic construction (lambda
calculus, scope-ambiguity storage) is itself a reasoning step the LLM/DCG
performs before Prolog ever runs. This document investigates a stricter
split — modeled on TypeSafe AI's blog post ["Introducing System One Models
and Jev"](https://typesafe.ai/blog/introducing-system-one-models-and-jev) —
where a small model is confined to three non-reasoning jobs (translate NL to
a structured query, orchestrate which query/tool runs next, turn a result
back into fluent text) and Prolog (erlog, per
[`erlang-mcp-design.md`](erlang-mcp-design.md)) does 100% of the actual
inference, with zero LLM involvement in evaluating or repairing the logic
itself.

**Primary source:** Diogo Almeida, TypeSafe AI, ["Introducing System One
Models and Jev"](https://typesafe.ai/blog/introducing-system-one-models-and-jev)
(blog, Sept. 15 2026).

**Recommendation up front:**

- **Jev itself is not adoptable — it's a closed, hosted API with no
  published weights, training paper, or open-source model**, so the actual
  reusable idea is the *shape* (translate → orchestrate → narrate, zero LLM
  reasoning about the logic), not the product. §1 covers the sourcing
  caveats in full before anything here is relied on.
- **A real, if partial, precedent for the "zero reasoning" split already
  exists in the literature: LINC** (§5) — sample several NL→FOL
  translations, discard the ones that fail to parse/prove, majority-vote
  the rest, never show the LLM the prover's error to repair. This is
  different from, and stricter than, Logic-LM's otherwise similar pipeline,
  which *does* feed solver error messages back to the LLM for
  "self-refinement" — the same reasoning-in-the-loop shape
  [`grpo-prolog-tool.md`](grpo-prolog-tool.md) and
  [`lorp-approach.md`](lorp-approach.md) already document. No paper found
  implements all three Jev-style roles (translate, orchestrate, narrate)
  end-to-end with zero LLM reasoning — LINC covers only the translate role.
- **The three roles map onto three different, more mature bodies of
  work**, not one: constrained/fine-tuned semantic parsing (§2) for
  translation, function-calling/tool-use models (§3) for orchestration, and
  data-to-text fine-tuning (§4) for narration. Treat this as three small
  specialist models (or three LoRA adapters on one base), not one model
  trying to be Jev.
- **Calibrated confidence is not a free hallucination-proof** — both
  TypeSafe's own critics and an unrelated benchmark paper found the same
  thing: schema-valid output can still be semantically wrong (§1, §6). Any
  confidence score surfaced to an agent calling `prolog_query` needs the
  same "coherent-but-wrong" skepticism
  [`erlang-mcp-design.md`](erlang-mcp-design.md) §5 already applies to
  LLM-generated Prolog.

## 1. What Jev and RLCD actually claim — and the sourcing caveat

**Access caveat, applied rigorously.** The only primary source for Jev and
"RLCD" is one company blog post, fetched directly for this document. There
is no technical paper, model card, or open weights. TypeSafe's own docs site
(`docs.typesafe.ai/introduction`) adds API shape but no architecture or
training detail. A GitHub repo
([`typesafe-ai/system-one-adapter-python`](https://github.com/typesafe-ai/system-one-adapter-python))
is a thin client wrapper around their hosted API, not model code. Treat
every claim below as a vendor's unverified self-report unless marked
otherwise.

**The claims, as stated in the blog post:**

- Jev is "a frontier-intelligence function call: unstructured state in,
  typed probabilistic decisions out." It "gives up string generation" —
  output is never free text, only typed values (`choice`, `score`, or
  `noul`, a 0–1 truth judgment) plus a calibrated probability/confidence,
  per `docs.typesafe.ai/introduction`.
- Architecturally, it is described as a "parallel sampler" that "generates
  all outputs in a single query," explicitly contrasted with sequential,
  autoregressive token generation — this is the one concrete architectural
  claim in the post, and it is asserted, not demonstrated with code or
  weights.
- Trained with **"Reinforcement Learning for Calibrated Decisions
  (RLCD)"** — TypeSafe's own coined term. **Disambiguation, stated
  explicitly because the acronym collides:** this is *not* the same
  "RLCD" as "Reinforcement Learning from Contrastive Distillation" (an
  older RL-from-AI-feedback technique in the unrelated alignment
  literature). TypeSafe's blog post gives no training objective, loss
  function, or dataset detail beyond the one sentence "optimizes for …
  calibrated decisions: answers with epistemically honest probabilities on
  System One tasks."
- Speed/cost: "70ms–500ms" end-to-end response time, "40x–200x faster" than
  frontier LLMs for the same task class, $0.042/MTok input with free
  output tokens; the company's homepage separately claims "193.6x faster,
  444.6x cheaper" on one specific comparison, which the blog post itself
  flags as "on the higher end."
- "Can't hallucinate": justified purely as "schema matching is guaranteed"
  — a claim about output *structure* (it will always be a value from the
  declared option set, in range), not about factual or logical
  *correctness* of which value is chosen. The post's own hallucination
  chart assigns Jev "0%," which the authors concede is "not empirical" —
  it is asserted from the architecture, not measured.

**What independent (non-TypeSafe) sources add:**

- A Hacker News launch thread (reported at ~1,900 points / ~500 comments)
  raised exactly the gap above as its most contentious point: Jev "cannot
  make a type error," but "it can select the wrong category or assign a
  high probability to an incorrect answer" — the guarantee is structural,
  not epistemic. This is the one piece of real technical pushback found
  outside TypeSafe's own materials, though it is a forum discussion, not a
  citable paper.
- [arXiv:2609.30216](https://arxiv.org/abs/2609.30216) ("Jev in the Wild")
  is a real paper, but it is an *ecosystem survey* — 2,170 public GitHub
  projects using Jev, analyzed for adoption patterns — not a technical
  analysis of Jev's internals. It adds no architecture or training
  evidence.
- [arXiv:2609.24052](https://arxiv.org/abs/2609.24052) (Rafe & Das) is the
  one genuinely independent *empirical* evaluation found: Jev applied to
  coding 195,857 Texas police-crash narratives against a 27-question
  schema, audited against 2,416 blinded human labels. Reported result:
  F1 = 0.908 against human labels, within 0.06 F1 of two frontier LLMs
  benchmarked on the same records, but "calibration varies by model rather
  than by paradigm, so each model must be audited" — recalibration on held-
  out labels cut calibration error by 3.3x. This is real third-party
  evidence that the *approach* (typed decisions + calibration) can work
  for a narrow classification task, and equally real evidence that the raw
  calibration claim needs per-deployment correction, not blind trust.
- [arXiv:2609.23742](https://arxiv.org/abs/2609.23742) does not mention
  Jev or TypeSafe at all, but directly undercuts the "schema-constrained ⇒
  can't hallucinate" framing in general: benchmarking constrained decoding
  (Outlines, XGrammar) on 0.6B–4B models across 14 structured-output tasks,
  it finds constrained decoding drives schema validity to 100% but leaves
  "a persistent semantic gap that is scale-dependent" — "schema conformance
  is necessary but not sufficient for semantic correctness." This is the
  general-case version of the Hacker News critique above, from an
  unrelated benchmark with real numbers.

**Bottom line on sourcing:** the *shape* Jev describes (parallel,
non-reasoning, schema-constrained, calibrated) is a reasonable design
target; the *specific* claims about RLCD's mechanism and the "can't
hallucinate" framing are vendor marketing with one blog post behind them,
one real independent evaluation that is narrower and more hedged than the
headline claims, and one unrelated paper's data suggesting the headline
framing doesn't hold in general. Nothing here should be cited as "Jev
proves X" — only "Jev's blog post claims X; independent evidence is thin
and mixed."

## 2. Small models for translation (NL → structured Prolog query/fact)

This is Jev's "state + typed questions → typed answer" role, retargeted at
"NL → Prolog goal/fact," and it is the best-studied of the three roles.

- **Grammar-constrained decoding (GCD) measurably helps smaller models
  more than larger ones.** ["Grammar-Constrained Decoding Makes Large
  Language Models Better Logical
  Parsers"](https://aclanthology.org/2025.acl-industry.34/) (ACL 2025
  Industry Track) reports that constraining decoding to a target grammar
  improves both syntactic and semantic accuracy on logical-parsing tasks,
  with the improvement *larger* for smaller models, especially at 0-shot —
  the opposite of "constraints only help when the model is already good."
  ["Grammar-Constrained Decoding for Structured NLP Tasks without
  Finetuning"](https://arxiv.org/pdf/2305.13971) and the
  GRAMMAR-LLM framework
  ([2025.findings-acl.177](https://aclanthology.org/2025.findings-acl.177/))
  are the same idea generalized across semantic-parsing tasks, with and
  without fine-tuning.
- **LOGICPO** fine-tunes **Phi-3.5** (a genuinely small, open model) with
  DPO and KTO preference optimization specifically for NL→FOL translation,
  reporting "10% more logically correct and 14% less syntax errors" than
  8-shot GPT-3.5-turbo
  ([arXiv:2506.18383](https://arxiv.org/pdf/2506.18383)). This is the
  clearest existing precedent for "a small, openly fine-tunable model beats
  a much larger few-shot-prompted one at this exact translation task."
- ["Improving Symbolic Translation of Language Models for Logical
  Reasoning"](https://arxiv.org/html/2601.09446) fine-tunes small LMs on
  data synthesized by larger LMs, splits inference into predicate
  generation then FOL translation, and adds "a verification module" that
  targets **predicate-arity errors** specifically — i.e., a syntax/shape
  check, not a semantic-correctness check, applied before the prover ever
  runs. This is the right granularity to borrow: a predicate-arity/arity-
  mismatch check against erlog's actual predicate table
  ([`erlang-mcp-design.md`](erlang-mcp-design.md) §6) is exactly the kind
  of pre-execution structural validation `lorp-approach.md` §2 already
  recommends for `prolog_consult`, and it stays on the translation side of
  the strict split — it never asks the model to reason about whether the
  resulting proof will be *correct*, only whether the term is well-formed.
- None of these papers target Prolog specifically (FOL/Prover9 is the
  common target language); translating their recipe to Prolog's
  Horn-clause subset, and specifically to erlog's smaller predicate set
  rather than full SWI, is unverified extrapolation, not a tested result.

## 3. Small models for orchestration (which query/tool to run next)

This is Jev's role repurposed as "decide which Prolog predicate, canned
query template, or MCP tool fires next" — a tool-use/function-calling
problem, not a reasoning problem, which is the right framing for the strict
split.

- The **Berkeley Function-Calling Leaderboard (BFCL)** is the standard
  benchmark for this exact capability and already shows that, with an
  explicit tool schema and a validator, small models "frequently match or
  even surpass larger LLMs in function-calling reliability and speed" —
  tool-use accuracy tracks argument correctness and schema adherence more
  than raw parameter count.
- **Salesforce xLAM / xLAM-2** is the most directly relevant family: models
  as small as 1B parameters (`xLAM-2-1b-fc-r`) trained with function
  calling as the *entire* objective, not a side capability. Reported BFCL
  results: `xLAM-7b-fc-r` at 88.24% overall accuracy (3rd on the
  leaderboard at time of its release), `xLAM-1b-fc-r` at 78.94% as "the
  only model under 2B on the leaderboard"
  ([GitHub](https://github.com/SalesforceAIResearch/xLAM),
  [arXiv:2409.03215](https://arxiv.org/pdf/2409.03215)). A 1B
  purpose-built function-calling model reportedly scores "nearly three
  times a general-purpose 1B model" on the same task.
- **NexusRaven-13B** matches GPT-3.5's zero-shot function-calling accuracy
  and reports a 60% higher success rate than Gorilla in its target domain,
  without training on the target functions at all
  ([OpenReview](https://openreview.net/pdf?id=5lcPe6DqfI)) — evidence that
  function-calling models generalize reasonably to unseen tool schemas,
  relevant since symbolic-tools' four-tool MCP surface plus whatever query
  templates exist is a small, fixed, fully-specifiable schema.
- **IBM Granite-20B-FunctionCalling**, trained via multi-task learning over
  seven sub-tasks (nested calls, chaining, parallel calls, next-best-
  function, etc.), reportedly performs as well as or better than
  Llama-3-70B despite being a third the size, and was the best open model
  on BFCL at release
  ([arXiv:2407.00121](https://arxiv.org/html/2407.00121v1)). The seven
  sub-tasks are a reasonable checklist for what "orchestrate Prolog/MCP
  calls" needs: this repo's actual sequence is
  `prolog_start_session → prolog_consult → prolog_query[s] → prolog_end_session`
  ([`erlang-mcp-design.md`](erlang-mcp-design.md) §3), which is function
  chaining plus parallel/repeated calls, not nested calls — a narrower
  target than Granite's full task suite.
- **Fit assessment, and its limit:** this repo's actual decision space
  (four MCP tools, plus however many canned Prolog query templates exist)
  is far smaller and more fixed than BFCL's general multi-API corpus, which
  is reason to expect an even smaller model could do this reliably — but
  that is inference, not evidence. No benchmark reviewed here tests
  "orchestrate calls to a logic engine" specifically; all of §3's evidence
  is about general REST/Python-style API calling.

## 4. Small models for narration (structured Prolog output → fluent text)

This is the Jev-reversed role: structured data in, fluent text out — the
"smoothing" stage, and data-to-text generation is the existing literature
most directly analogous to erlog's own output shape (bindings, or
`{functor, args}` compound terms, per
[`erlang-mcp-design.md`](erlang-mcp-design.md) §4).

- Fine-tuned **BART/T5** on **WebNLG** (47k RDF-graph/text pairs from
  DBPedia subgraphs) and **ToTTo** (120k+ Wikipedia table/text pairs) are
  the standard small-model baselines for structured-to-text, consistently
  reported as the strongest practical approach once pre-trained and
  fine-tuned, ahead of zero/few-shot prompting a larger model, per the data-
  to-text survey literature (["A Survey on Neural Data-to-Text
  Generation"](https://openreview.net/pdf/95a9cde4b2ba8b9088c2f65824b6f3899a4bce7d.pdf)).
  RDF triples (`subject, predicate, object`) are structurally the closest
  existing analog to an erlog binding list or compound term, which is
  useful: the input shape this stage needs to handle already has a mature
  fine-tuning recipe, unlike §2 and §3.
  [arXiv:2409.16707](https://arxiv.org/pdf/2409.16707) ("Probing Omissions
  and Distortions in Transformer-based RDF-to-Text Models") is the
  relevant caution — these models can drop or distort facts from the input
  triples, i.e., the narration stage has its own small hallucination risk
  even though it never touches the logic.
- A real scale limitation, flagged directly in the survey literature: "the
  performance of the task is still limited by the small scale of the
  training dataset" — WebNLG/ToTTo are tens of thousands of examples, not
  millions, so a from-scratch fine-tune for symbolic-tools' own output
  shapes would likely need either synthetic data generation (mirroring
  ["Improving Symbolic Translation..."](https://arxiv.org/html/2601.09446)'s
  use of a larger LM to synthesize training data for a smaller one, §2) or
  reuse of an existing WebNLG/ToTTo-tuned checkpoint with light domain
  adaptation, not a large bespoke corpus.
- This is the lowest-risk of the three roles to adopt early: unlike §2/§3,
  getting it wrong produces a disfluent or mildly inaccurate sentence, not
  a malformed query or a wrong tool call — the failure mode doesn't
  compromise the "Prolog does 100% of the reasoning" guarantee the way a
  bad translation or bad orchestration decision would.

## 5. The strict "zero reasoning" split: LINC is a real precedent, Logic-LM is not

This is the single most valuable thing requested, so it's worth stating
plainly: **a close precedent exists — LINC — but it covers only the
translation role, and the closest *comparable* architecture, Logic-LM,
explicitly fails the strict test.**

- **LINC** (["A Neurosymbolic Approach for Logical Reasoning by Combining
  Language Models with First-Order Logic
  Provers"](https://arxiv.org/abs/2310.15164), EMNLP 2023) translates
  premises/conclusion to FOL, offloads all inference to an external
  theorem prover, and uses **K-way majority voting** (K=10 in their
  experiments): sample K candidate translations, run each through the
  prover, **discard the ones that fail to parse or prove — without ever
  showing the LLM the error** — and take the majority vote of the
  remaining results. The paper reports syntax-error rates per model (38%
  for StarCoderPlus, 24% for GPT-3.5, 13% for GPT-4) that are simply
  dropped as failed samples, not fed back for repair. LINC with
  StarCoder+ reportedly beats GPT-3.5/GPT-4 with chain-of-thought by 38%
  and 10% absolute. **This is a genuine, published, benchmarked instance
  of "LLM translates once per sample, prover reasons, failures are
  filtered not repaired, selection is by vote not by re-reasoning"** — the
  exact discipline the maintainer is asking for, for the translation role.
- **Logic-LM** (["Empowering Large Language Models with Symbolic Solvers
  for Faithful Logical Reasoning"](https://arxiv.org/abs/2305.12295),
  EMNLP 2023 Findings) looks superficially identical — problem formulator
  (LLM) → symbolic reasoner (Pyke/Prover9/Z3/python-constraint) → result
  interpreter — but it adds a **self-refinement module that "uses the
  symbolic solver's error messages to revise symbolic formalizations."**
  That is exactly the agentic-repair shape
  [`grpo-prolog-tool.md`](grpo-prolog-tool.md) §1 and §3 already document
  (LLM sees an execution error, reasons about why, retries) and exactly
  what the maintainer wants to rule out. **Logic-LM does not satisfy the
  strict split** — it is architecturally a third instance of the same
  "LLM participates in reasoning about the logic" family as GRPO's repair
  loop and (implicitly) LoRP's voting, not a fourth, stricter one.
- **Gap, stated plainly:** no paper found implements all three Jev-style
  roles — translate, orchestrate, narrate — in one pipeline with zero LLM
  reasoning throughout. LINC is a precedent for role 1 only (translation,
  with filter-don't-repair discipline), applied to classification-style
  True/False/Uncertain answers, not to generating/running arbitrary
  queries against a live fact base, and with no orchestration or NLG stage
  at all (its output *is* the final answer, not something handed to a
  narration step). Treat "LINC-style filtering + voting for translation,
  bolted onto a separately-trained function-calling model for
  orchestration and a separately-trained data-to-text model for
  narration" as this document's own synthesis/recommendation, not as a
  single system anyone has published.

## 6. Implications for `symbolic-tools`

A fourth perspective on the NL↔Prolog boundary, alongside
[`grpo-prolog-tool.md`](grpo-prolog-tool.md) §3,
[`lorp-approach.md`](lorp-approach.md) §2, and
[`curt-approach.md`](curt-approach.md)'s own implications, concretely
against the actual four-tool MCP surface
(`prolog_start_session`/`prolog_consult`/`prolog_query`/`prolog_end_session`,
[`erlang-mcp-design.md`](erlang-mcp-design.md) §3):

- **Translation stage → what gets passed to `prolog_consult`/
  `prolog_query`.** Use a small fine-tuned model with grammar-constrained
  decoding against erlog's *actual* grammar (`erlog_scan.xrl`'s tokens,
  the Tier-1/2 predicate set documented in
  [`erlang-mcp-design.md`](erlang-mcp-design.md) §6–7), not SWI's full
  grammar — §2's GCD findings show the constraint helps small models more,
  and a constrained decoder trained against erlog's narrower predicate set
  sidesteps the "LLM generates a call to `maplist/3`, which erlog doesn't
  have" failure mode before it ever reaches `prolog_consult`. Apply LINC's
  filter-don't-repair discipline (§5): if constrained decoding still
  produces a term that fails `prolog_consult`'s structural validation
  (`lorp-approach.md` §2's pre-execution check), discard that candidate
  and try another independently-sampled one — never show the model the
  validation error and ask it to fix its own output, which would reopen
  exactly the reasoning-participation gap this document exists to avoid.
- **Orchestration stage → the session lifecycle and query sequencing.**
  Frame "which of {start_session, consult, query, end_session} fires next,
  with which arguments" as a function-calling problem over a fixed
  four-tool schema plus whatever canned Prolog query templates this repo
  ships (§3). This is a narrower, more fixed decision space than BFCL's
  general API corpus — a 1–3B function-calling model in the xLAM/Granite
  family is a plausible starting point (§3), but no cited benchmark tests
  this specific narrow case, so this is a recommendation to prototype and
  measure, not a result to cite.
- **Narration stage → turning `prolog_query`'s bindings or `"No."` into
  prose.** Treat erlog's binding list / `{"functor": ..., "args": [...]}`
  compound-term JSON (`erlang-mcp-design.md` §4) as the structured input to
  a WebNLG/ToTTo-style fine-tuned small model (§4) — this is the stage
  with the most mature existing recipe and the lowest blast radius if it
  under-performs, since a disfluent sentence doesn't corrupt the proof the
  way a bad translation or orchestration decision would.
- **Don't inherit "schema-valid ⇒ can't hallucinate" as a design
  assumption.** §1 and §6's arXiv:2609.23742 both show schema/grammar
  conformance does not imply semantic correctness — a syntactically valid,
  erlog-acceptable goal can still be the *wrong* goal for what the user
  asked, which is a restatement of
  [`erlang-mcp-design.md`](erlang-mcp-design.md) §5's "coherent-but-wrong
  translation" risk from the translation-model's output side rather than
  the rule-writing side. If any confidence score is surfaced to a calling
  agent for any of the three stages, treat it the way
  [arXiv:2609.24052](https://arxiv.org/abs/2609.24052) treats Jev's own
  calibration — auditable and model-specific, not a trust primitive on its
  own.
- **This is a client-side/LLM-side architecture question, not an erlog
  engine question.** Nothing in §2–§4 touches the tabling gap
  ([`erlang-mcp-design.md`](erlang-mcp-design.md) §5), the predicate
  coverage gap (§6), or the timeout/isolation model (§8) — a Jev-style
  three-model split sits entirely on the MCP-client side of the boundary
  those sections already describe, same as the best-of-N pattern
  [`grpo-prolog-tool.md`](grpo-prolog-tool.md) §3 already scopes as
  "something the calling agent does, not something the server builds in."

## 7. Open questions

- Whether one small (<7B) model can be multi-task fine-tuned to play all
  three roles (translate/orchestrate/narrate) acceptably, or whether three
  separately specialized small models (or three LoRA adapters on a shared
  base) is the more realistic path — no evidence either way was found;
  IBM's Granite-20B-FunctionCalling multi-task recipe (§3) is the closest
  existing proof that multi-task small-model training works for at least
  one of the three roles, but nothing combines translation + orchestration
  + narration in one fine-tune.
- Whether LINC's filter-and-vote discipline (§5), applied to erlog's
  smaller and stricter predicate set rather than full-FOL/Prover9, holds up
  accuracy-wise — erlog's narrower grammar could make translation *easier*
  (fewer valid programs to hit) or *harder* (fewer built-ins to fall back
  on); untested.
- Whether TypeSafe's RLCD training recipe is replicable at all outside
  TypeSafe — no training paper, loss function, or open checkpoint exists
  (§1); it is plausible that "parallel, schema-constrained, calibrated"
  can be approximated with ordinary constrained decoding (§2's GCD
  results) plus a calibration-focused fine-tune (e.g., temperature scaling
  or a Platt-style recalibration layer, the technique
  [arXiv:2609.24052](https://arxiv.org/abs/2609.24052) used to cut Jev's
  own calibration error by 3.3x), without needing TypeSafe's specific
  (undisclosed) method — but this is speculation, not a tested claim.
- Whether the "schema-valid ≠ semantically correct" gap
  ([arXiv:2609.23742](https://arxiv.org/abs/2609.23742)) scales the same
  way for Prolog-goal generation as it does for JSON/function-calling —
  plausible by analogy, not demonstrated for this specific target
  language.

## References

- [Introducing System One Models and
  Jev](https://typesafe.ai/blog/introducing-system-one-models-and-jev) —
  TypeSafe AI blog post, the sole primary source for Jev/RLCD's
  architecture and training claims (§1).
- [TypeSafe AI docs: Introduction](https://docs.typesafe.ai/introduction) —
  API shape (state + typed questions → choice/score/noul + probability),
  no architecture/training detail.
- [typesafe-ai/system-one-adapter-python](https://github.com/typesafe-ai/system-one-adapter-python)
  — thin client SDK, not model code.
- [arXiv:2609.30216 — "Jev in the Wild: A Data-Driven Analysis of the Jev
  Model's Functionality, Applications and
  Ecosystem"](https://arxiv.org/abs/2609.30216) — independent but
  descriptive ecosystem survey, no architecture evidence.
- [arXiv:2609.24052 — "Calibrated Decisions at Scale: Converting Police
  Crash Narratives into Probabilistic Crash Variables with a System One
  Model (Jev)"](https://arxiv.org/abs/2609.24052) (Rafe & Das) — the one
  independent empirical evaluation found; F1 = 0.908 vs. human labels,
  calibration-error reduced 3.3x after recalibration.
- [arXiv:2609.23742 — "Constrained Decoding Eliminates Structural Failures
  in Small LLMs but Reveals a Scale-Dependent Semantic
  Gap"](https://arxiv.org/abs/2609.23742) — unrelated to Jev, but directly
  evidences the "schema-valid ≠ semantically correct" critique in general.
- [LINC: A Neurosymbolic Approach for Logical Reasoning by Combining
  Language Models with First-Order Logic
  Provers](https://arxiv.org/abs/2310.15164) (EMNLP 2023) — the closest
  found precedent for a strict "LLM translates, prover reasons, failures
  filtered not repaired" split (§5).
- [Logic-LM: Empowering Large Language Models with Symbolic Solvers for
  Faithful Logical Reasoning](https://arxiv.org/abs/2305.12295) (EMNLP
  2023 Findings) — superficially similar architecture that fails the
  strict split via its solver-error-driven self-refinement module (§5).
- [Grammar-Constrained Decoding Makes Large Language Models Better Logical
  Parsers](https://aclanthology.org/2025.acl-industry.34/) (ACL 2025
  Industry) — GCD helps small models more than large ones (§2).
- [Grammar-Constrained Decoding for Structured NLP Tasks without
  Finetuning](https://arxiv.org/pdf/2305.13971) and [GRAMMAR-LLM: Grammar-
  Constrained Natural Language
  Generation](https://aclanthology.org/2025.findings-acl.177/) — further
  GCD background (§2).
- [LOGICPO: Efficient Translation of NL-based Logical Problems to FOL using
  LLMs and Preference Optimization](https://arxiv.org/pdf/2506.18383) —
  Phi-3.5 fine-tuned via DPO/KTO beats 8-shot GPT-3.5-turbo at NL→FOL (§2).
- [Improving Symbolic Translation of Language Models for Logical
  Reasoning](https://arxiv.org/html/2601.09446) — small-LM fine-tuning +
  predicate-arity verification module, syntax-only feedback (§2).
- [Berkeley Function-Calling Leaderboard (BFCL)](https://gorilla.cs.berkeley.edu/leaderboard.html)
  — standard benchmark for the orchestration role (§3).
- [xLAM: A Family of Large Action Models to Empower AI Agent
  Systems](https://arxiv.org/pdf/2409.03215) and
  [SalesforceAIResearch/xLAM](https://github.com/SalesforceAIResearch/xLAM)
  — 1B–8B function-calling-specialist models, top-tier BFCL results (§3).
- [NexusRaven: a Commercially-Permissive Language Model for Function
  Calling](https://openreview.net/pdf?id=5lcPe6DqfI) (§3).
- [Granite-Function Calling Model: Introducing Function Calling Abilities
  via Multi-task Learning of Granular
  Tasks](https://arxiv.org/html/2407.00121v1) (EMNLP 2024 Industry) — 20B
  model reportedly matching/beating Llama-3-70B (§3).
- [A Survey on Neural Data-to-Text
  Generation](https://openreview.net/pdf/95a9cde4b2ba8b9088c2f65824b6f3899a4bce7d.pdf)
  — WebNLG/ToTTo, BART/T5 fine-tuning baselines for the narration role
  (§4).
- [Probing Omissions and Distortions in Transformer-based RDF-to-Text
  Models](https://arxiv.org/pdf/2409.16707) — fact-dropping/distortion
  risk in the narration stage itself (§4).
- [`erlang-mcp-design.md`](erlang-mcp-design.md) — the four-tool MCP
  surface (§3), erlog↔JSON marshalling (§4), tabling gap (§5), predicate
  coverage (§6) this document's §6 maps the three roles onto.
- [`grpo-prolog-tool.md`](grpo-prolog-tool.md) — the agentic repair loop
  this document's split is explicitly stricter than.
- [`lorp-approach.md`](lorp-approach.md) — the validate/prove/vote
  pipeline this document's translation-stage recommendation (§6) builds
  on, substituting LINC's filter-not-repair discipline (§5) for an
  error-shown-to-the-model repair step.
- [`curt-approach.md`](curt-approach.md) — the DCG/semantic-construction
  approach to NL→Prolog fact extraction this document's translation role
  (§2, §6) is an alternative to, for the specific case of generating
  queries/facts via a fine-tuned model rather than a hand-written grammar.
