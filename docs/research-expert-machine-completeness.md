# Research: completeness for a Prolog expert machine used by LLM agents

## Question and scope

What should `symbolic ask` guarantee if the project goal is an expert machine in Prolog for an LLM agent, and where does the current system fall short? This is a research synthesis, not an implementation plan. It focuses on answer behavior and completeness.

## Findings

### 1. Separate interpretation from proof

Neurosymbolic reasoning systems separate natural-language formulation, symbolic inference, and answer interpretation. Logic-LM describes these as three stages and adds bounded self-refinement when the solver reports a formulation error. It stresses that deterministic inference only guarantees correctness *with respect to the formalization*; the natural-language-to-logic step remains a separate source of error. [Pan et al., *Logic-LM* (2023), §§3–3.4](https://arxiv.org/abs/2305.12295).

LINC makes the same distinction: the LLM acts as a semantic parser, then a theorem prover reasons over its output. It identifies syntactic errors, lost explicit meaning, and missing implicit assumptions as separate failure modes. [Olausson et al., *LINC* (2023), §§2, 5](https://arxiv.org/abs/2310.15164).

**Implication:** distinguish parse/formulation status from proof status in user-visible answers. A successful Prolog proof must not be presented as proof that the question was translated correctly.

### 2. “Unknown” is not the same as “false”

FOLIO labels conclusions `True`, `False`, or `Unknown`, and uses paired natural-language and first-order-logic examples. Its authors automatically verify the logical labels against an inference engine. This gives a useful model for testing the semantic interpretation layer, not only the solver. [Han et al., *FOLIO* (2022; revised 2024)](https://arxiv.org/abs/2209.00840).

The current `ask` design intentionally uses a closed-world assumption for structural facts: no recorded call means “false,” while no prose-search hit means only “not found in this corpus.” The `unverifiable` result covers unsupported questions and entity/arity problems. This is a sound boundary for a complete, correctly scoped scan, but a missing fact can also reflect a partial scan or an extraction failure.

**Implication:** preserve the current structural/prose distinction, and make scan scope/completeness visible wherever a negative answer relies on absence. Do not collapse `unverifiable`, `unknown`, and `false` into one outcome.

### 3. Coverage of question meaning is more important than question grammar size

ASK is broader than the original v1 research note describes. The current implementation handles calls, definitions, callers/counts, prose search, uses, returns, literal handling, file scan checks, configuration checks, and call/definition locations. It also has a statistical fallback. However, supported operations are spread across the question grammar, statistical mapper, relation builder, gate, and answer clauses rather than represented in one authoritative operation catalog. Some questions return source locations; most yes/no answers do not return supporting facts.

The project's question-to-Prolog design correctly calls out two dangerous failures: guessing the wrong schema and producing a plausible answer from the wrong arity. Its gate checks entities before proof and treats prose retrieval as evidence, not a verdict. See [`research-questions-to-prolog.md`](research-questions-to-prolog.md) §§1–5 and [`symbolic_ask.erl`](../src/symbolic_ask.erl).

**Implication:** make the existing capabilities explicit in a typed, tested catalog before growing the vocabulary further. Keep execution restricted to catalogued operations, and add evidence contracts operation by operation—not arbitrary generated Prolog as the default. Derived predicates can provide useful expert behavior, but they need declared argument roles and input validation.

### 4. MCP can return validated structured results

The MCP tools specification supports optional output schemas; when supplied, servers must return structured results that conform to them. It recommends including serialized text as a backwards-compatible representation. Tool errors are distinct from successful tool results with `isError: true`. [MCP specification, Server Tools (2025-06-18)](https://modelcontextprotocol.io/specification/2025-06-18/server/tools).

**Implication:** an expert-machine response should have a stable result shape that exposes answer kind, status, and evidence, rather than relying on prose for epistemic distinctions. The CLI can use the same underlying result contract while retaining exit codes.

## Current ASK against those findings

The code implements a meaningful safety-first core:

- A bounded grammar and statistical fallback produce typed relation templates.
- A pre-proof gate rejects unsupported subjects and wrong arities instead of returning plausible zero/false answers.
- Prose questions return ranked evidence, never a claim that absence is false.
- The shared pipeline serves both CLI and MCP entry points.
- Tests cover several relation families, true/false, enumeration/count, prose evidence, wrong arity, unresolved subjects, and unrecognized wording.

These are good foundations, but they do not yet make ASK a complete expert machine. The operation set has no single runtime catalog; the contract for closed-world negatives and scan completeness is not consistently surfaced; and most answers do not expose supporting facts or a proof/explanation trace. The solver can be deterministic while the formulation remains uncertain.

## Candidate completeness criteria to test

1. **Correct relation:** supported intent maps to the intended predicate and argument positions.
2. **Grounded entities:** names, arities, and aliases resolve against the active schema; ambiguous matches produce clarification or an explicit ambiguity result.
3. **Honest epistemics:** separate proved, disproved-under-declared-closed-world, unknown/not-found, unrecognized, and infrastructure-error cases.
4. **Scope-aware negatives:** a negative answer reports the dataset/project scope and any incomplete extraction state relevant to absence.
5. **Evidence:** structural answers identify the facts/rules and source locations that support them; prose answers retain source excerpts and locations.
6. **Safe execution:** only validated goals from an allowlisted relation/schema are executed; execution cost and result count have limits.
7. **Measurable formulation quality:** evaluate intent/slot extraction separately from proof correctness and end-to-end answers. Include paraphrases, wrong arities, ambiguous names, missing facts, partial scans, and adversarially similar identifiers.

These criteria are proposals for evaluation, not claims that existing sources mandate one architecture.

## Suggested research direction

Build a small, expert-reviewed ASK benchmark from actual repository questions. Each case should record the intended operation, entities/arity, expected epistemic status, and expected evidence locations. Score three stages separately: interpretation/grounding, Prolog result, and final structured response. Include paraphrases for each supported intent and explicit negative/unknown cases. This follows Logic-LM's stage separation and FOLIO's use of expert annotations plus solver-checked labels.

A next design discussion should decide whether ASK is intended to be (a) a natural-language front end for a fixed catalog of expert predicates, or (b) a general Prolog query planner. The first is easier to validate and safer; the second offers more reach but needs stronger query controls, termination limits, explanation support, and a policy for ambiguity.

## Sources

- Internal: [`research-questions-to-prolog.md`](research-questions-to-prolog.md), [`symbolic_ask.erl`](../src/symbolic_ask.erl), [`symbolic_ask_catalog.erl`](../src/symbolic_ask_catalog.erl), [`question_grammar.pl`](../priv/question_grammar.pl), [`symbolic_ask_tests.erl`](../test/symbolic_ask_tests.erl).
- Han et al. 2022/2024, [FOLIO: Natural Language Reasoning with First-Order Logic](https://arxiv.org/abs/2209.00840).
- Pan et al. 2023, [Logic-LM: Empowering Large Language Models with Symbolic Solvers for Faithful Logical Reasoning](https://arxiv.org/abs/2305.12295).
- Olausson et al. 2023, [LINC: A Neurosymbolic Approach for Logical Reasoning by Combining Language Models with First-Order Logic Provers](https://arxiv.org/abs/2310.15164).
- [Model Context Protocol, Server Tools specification (2025-06-18)](https://modelcontextprotocol.io/specification/2025-06-18/server/tools).
