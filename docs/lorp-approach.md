# Research: LoRP — LLM-based Logical Reasoning via Prolog

Summary and design implications of a second source paper cited by
[`erlang-mcp-design.md`](erlang-mcp-design.md) (§5, alongside
[`grpo-prolog-tool.md`](grpo-prolog-tool.md), on the risk of a
"coherent-but-wrong translation" from an LLM-generated Prolog rule). This is
a research summary, not an implementation design — nothing here is built.

**Source:** ["LoRP: LLM-based Logical Reasoning via
Prolog"](https://www.sciencedirect.com/science/article/abs/pii/S0950705125011815),
*Knowledge-Based Systems* (Elsevier), July 2025.

**Access caveat.** The publisher page is paywalled (fetch returns HTTP 403).
This summary is reconstructed from the public abstract, a ResearchGate
listing, and secondary write-ups, not the full text — treat the mechanism
description below as reliable and any numeric results as approximate. Get
the full text before relying on specific figures.

## 1. What the paper does

LoRP converts a natural-language reasoning task into a Prolog program and
delegates the actual inference to an **external SWI-Prolog interpreter**,
rather than having the LLM reason in free text — the same "the LLM writes,
the engine proves" split `symbolic-tools` is built around. It runs the
conversion as four explicit stages:

1. **Translation** — map the natural-language query into Prolog, including
   a translation mechanism from first-order logic into Prolog's Horn-clause
   subset, aimed at expressing more of FOL than a naive translation would.
2. **Validation** — check the generated program before it is executed.
3. **Proving** — run the validated program through SWI-Prolog.
4. **Voting** — aggregate across multiple attempts to pick a final answer.

Evaluated across five datasets and seven different LLMs against three other
reasoning strategies, reported as state-of-the-art accuracy with good
stability across model architectures.

## 2. Implications for `symbolic-tools`

- **Validation is a pipeline stage, not an afterthought.** LoRP checks a
  generated program *before* execution as a named step in the architecture.
  `symbolic-tools`' equivalent boundary is `prolog_consult`
  ([`erlang-mcp-design.md`](erlang-mcp-design.md) §3): treat structural
  validation of incoming clauses (known predicates, arity, no attempt to
  load a file path or invoke a shell-adjacent builtin) as a distinct step
  before `erlog:consult/2` runs, not folded silently into "try it and see if
  it errors."
- **Voting corroborates the GRPO paper's best-of-N finding independently.**
  Two unrelated papers, two different architectures, converge on the same
  answer: don't trust a single LLM-generated Prolog program, generate
  several and combine or select. See
  [`grpo-prolog-tool.md`](grpo-prolog-tool.md) §3 for the client-side
  pattern this suggests for MCP callers of `prolog_query`.
- **The translation gap is a different problem from erlog's coverage gap.**
  LoRP's FOL-to-Prolog mechanism is about the *target language's*
  expressiveness — Prolog's Horn-clause subset cannot directly state
  arbitrary first-order formulas, so the translation step has to work around
  that. `erlang-mcp-design.md` §6's predicate gap is about the *engine's*
  completeness relative to a full Prolog implementation (missing
  `catch/throw`, `maplist`, etc.). Keep these distinct: closing §6's gap
  (more builtins) does not address expressiveness, and a richer translation
  layer does not substitute for missing builtins.
- **Confirms the overall architecture, not just a detail.** LoRP delegating
  proof search entirely to an external interpreter, with the LLM confined to
  translation and voting, is direct precedent for `symbolic-tools`'
  premise — erlog does the reasoning, the LLM only ever produces or
  consumes facts and goals around it.

## 3. Open question

Without the full text, it's unclear exactly what LoRP's "validation" stage
checks (syntax only? type/arity checking? something closer to a linter?).
Worth revisiting once full-text access is available, since that stage is the
most directly reusable piece for `prolog_consult`'s design.

## References

- [ScienceDirect
  S0950705125011815](https://www.sciencedirect.com/science/article/abs/pii/S0950705125011815)
  — "LoRP: LLM-based Logical Reasoning via Prolog" (paywalled; abstract
  only).
- [`erlang-mcp-design.md`](erlang-mcp-design.md) — the `prolog_consult`
  boundary and predicate-coverage gap this paper's findings bear on.
- [`grpo-prolog-tool.md`](grpo-prolog-tool.md) — a first paper reaching a
  related conclusion (multi-attempt sampling, structured error feedback)
  from a different architecture.
