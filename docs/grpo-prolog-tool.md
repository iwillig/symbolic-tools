# Research: Training Language Models to Use Prolog as a Tool (GRPO)

Summary and design implications of a source paper cited by
[`erlang-mcp-design.md`](erlang-mcp-design.md) (§5, on the risk of a
"coherent-but-wrong translation" from an LLM-generated Prolog rule). This is
a research summary, not an implementation design — nothing here is built.

**Source:** Mellgren, Schneider-Kamp, Galke Poech (University of Southern
Denmark), ["Training Language Models to Use Prolog as a
Tool"](https://arxiv.org/abs/2512.07407), arXiv:2512.07407v1.

## 1. What the paper does

Fine-tunes Qwen2.5-3B-Instruct with **GRPO** (Group Relative Policy
Optimization, an RL method) to generate Prolog (CLP(Q)) programs that are
executed by an external **SWI-Prolog** interpreter, on a cleaned
GSM8K-Prolog dataset. The model is never asked to "reason" in free text —
it writes a program, the program is run, and the numeric result is the
answer. This is the same "delegate reasoning to an external interpreter"
shape as `symbolic-tools` itself, just with SWI-Prolog instead of erlog.

The authors sweep three independent axes and measure the interaction:

- **System prompt style** — from a bare `<reasoning>`/`<answer>` template up
  to one that requires named predicates and a built-in self-check loop.
- **Reward suite** — execution correctness + syntax validity; adding
  semantic-similarity/predicate-overlap rewards; adding a curriculum
  schedule that shifts reward weight from "looks right" early in training to
  "is right" later.
- **Inference protocol** — single-shot; best-of-N ("Multiple-Try") with
  external verification; two "agentic" loops that let the model see an
  execution error and retry, either within one session or across bounded,
  context-reset attempts.

## 2. Results that matter here

- GRPO beats supervised fine-tuning on the same data by a wide margin (up to
  90% vs. 21.6% validation accuracy); RL against a verifiable
  execution-correctness reward, not imitation, is what makes the generated
  Prolog reliable.
- **Best-of-N with external verification wins in-distribution**; the
  **agentic self-repair loop generalizes better out-of-distribution**
  (zero-shot MMLU) than either single-shot or best-of-N. Neither single-shot
  generation nor "just sample more" is the strongest choice in general —
  which protocol wins depends on whether the target query looks like
  training data.
- Even the best configuration does not reach 100%: 89.87% in-distribution,
  ~80% on held-out GSM8K. A meaningful fraction of generated programs are
  syntactically valid, execute without error, and still return the wrong
  answer — a program can look reasoned and still be wrong, with nothing in
  its shape to flag that.
- A 12-trial Bayesian hyperparameter search could not beat the reported
  baseline, suggesting this GRPO setup is near a ceiling rather than one
  more sweep away from closing the remaining gap.

## 3. Implications for `symbolic-tools`

- **The winning inference shape is a repair loop, not one-shot generation.**
  The paper's "agentic-internal" protocol — generate, execute, observe the
  error, retry within the same session — is exactly the shape an MCP client
  should drive against `prolog_consult`/`prolog_query`
  ([`erlang-mcp-design.md`](erlang-mcp-design.md) §3): a session that
  persists across calls so a failed `consult` or a wrong-shaped query result
  can be corrected without starting over. This is a reason to make sure the
  session stays alive and usable after a failed call, not just after a
  successful one.
- **Execution errors must be structured, not swallowed.** The repair loop
  only works if the caller can see *why* a goal failed. This reinforces
  `erlang-mcp-design.md` §4's requirement to map `erlog:prove/2`'s
  `{error, Error}` result to a structured MCP tool error rather than a bare
  failure — an agent doing this paper's self-repair pattern needs that
  detail to correct the next attempt.
- **"Runs without error" is not "correct."** The paper's residual ~10-20%
  wrong-but-executable rate is the general-purpose version of
  `erlang-mcp-design.md` §5's specific cyclic-graph case: an LLM-generated
  recursive rule with a forgotten cycle guard is syntactically fine, executes
  without erroring, and simply never terminates (or, on a non-cyclic input,
  quietly returns a wrong answer). Neither erlog nor a bigger model closes
  this gap by itself — the session-level timeout/kill safety net in
  `erlang-mcp-design.md` §8 is required regardless of how good the
  generating model is.
- **Best-of-N is a usable client-side pattern.** Nothing about "generate a
  few candidate goals, keep the one erlog accepts, prefer a
  majority-agreeing answer if more than one succeeds" needs to live in the
  MCP server — it is a strategy the *calling agent* can apply on top of the
  existing four-tool surface. Worth documenting as recommended usage rather
  than building it in.

## 4. Open question

The paper only evaluates math word problems (GSM8K) against SWI-Prolog.
There is no evidence here — one way or the other — about how well
GRPO-style training transfers to the kind of query `symbolic-tools`
actually needs (call-graph reachability, definition lookup) or to erlog's
smaller predicate set ([`erlang-mcp-design.md`](erlang-mcp-design.md) §6).
Treat the inference-protocol conclusions (§3 above) as transferable; treat
the specific accuracy numbers as not.

## References

- [arXiv:2512.07407](https://arxiv.org/abs/2512.07407) — "Training Language
  Models to Use Prolog as a Tool."
- [`erlang-mcp-design.md`](erlang-mcp-design.md) — the session model,
  error-shape requirement, and cyclic-graph timeout this paper's findings
  bear on.
- [`lorp-approach.md`](lorp-approach.md) — a second paper reaching a related
  conclusion (multi-attempt voting, explicit pre-execution validation) from
  a different architecture.
