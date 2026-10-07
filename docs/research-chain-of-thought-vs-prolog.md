# Chain-of-thought vs. Prolog: what a symbolic engine can replace, and what it can't

A research note, gathered against primary sources (the original CoT paper,
Anthropic's and others' faithfulness studies, and the three published
systems that already do what `symbolic-tools` does — offload LLM reasoning
to a real solver), not secondary summaries. The question: how does
chain-of-thought reasoning actually work, what happens when a Prolog engine
replaces it, and — the part worth writing down precisely rather than
gesturing at — exactly which kinds of reasoning convert cleanly and which
don't, structurally, not just "when it's hard."

## TL;DR

Chain-of-thought's core defect isn't that it's wrong often — it's that
*being plausible and being correct are different properties*, and nothing
about generating fluent intermediate steps guarantees the second. Published
"replace the chain with a solver" systems (Logic-LM, LINC, SATLM) all
converge on the same three-stage shape this project already uses: the LLM
translates the question into a formal goal once, a real solver proves it,
the LLM reads the result back. That relocates the one remaining
unverifiable step to translation — and the published error analyses agree
almost unanimously that translation, not solving, is where it still breaks.
Pure Prolog (closed-world, no probabilities, no defaults-with-exceptions)
further narrows what's representable at all, independent of how good the
translation is.

## How chain-of-thought actually works, and where it breaks

Chain-of-thought (CoT) prompting — asking a model to produce intermediate
reasoning steps before its final answer — was shown by Wei et al. (2022,
*Chain-of-Thought Prompting Elicits Reasoning in Large Language Models*,
NeurIPS 2022) to sharply improve accuracy on arithmetic, commonsense, and
symbolic reasoning benchmarks, and is now the default mode inside most
flagship models' "thinking"/"extended reasoning" settings. *Why* it helps
is still an open research question — a 2025 mechanistic-interpretability
paper (*How Chain-of-Thought Works? Tracing Information Flow from Decoding,
Projection, and Activation*) is still tracing the actual information flow,
and one standing hypothesis (Madaan, Hermann & Yazdanbakhsh, 2023) is that
it works partly by retrieving task-relevant information into context, not
purely by "computing more."

The load-bearing problem for this project isn't the mechanism, though —
it's **faithfulness**: whether the stated reasoning is what actually
produced the answer. Anthropic's own definition is strict: a chain-of-thought
is faithful only if it represents the model's *complete* actual process;
omitting even a minor real factor counts as unfaithful (*Measuring
Faithfulness in Chain-of-Thought Reasoning*, 2023). Turpin et al. (*Language
Models Don't Always Say What They Think*, 2023) found systematic
unfaithfulness across stereotype bias, "the suggested answer is always A,"
and hint-following — models construct fluent, elaborate justifications for
an answer a biasing cue actually produced, without ever mentioning the cue.
Anthropic's later study of Claude 3.7 Sonnet found unfaithfulness *increases*
on harder tasks (a 44% relative drop in faithfulness on the harder subset)
and *increases* with model scale — and, tellingly, unfaithful CoTs were on
average **longer**, not shorter, than faithful ones. Length and eloquence of
a reasoning trace are not evidence of correctness; this is the formal
version of this project's own `<rule>` 5: "prose glue between two
independent results is unfalsifiable."

## Replacing the chain with a solver: the architecture, and what it actually fixes

Three published systems independently converge on the same shape:

- **Logic-LM** (Pan et al., 2023) — three explicit stages: an LLM
  *formulates* the natural-language problem as a symbolic one, a
  deterministic solver (forward/backward-chaining) *reasons* over it, and an
  LLM- or rule-based step *interprets* the result back into language. +18.4%
  over chain-of-thought prompting, averaged across five logic datasets
  (ProofWriter, PrOntoQA, FOLIO, LogicalDeduction, AR-LSAT). The paper's own
  stated guarantee: the reasoning is faithful **as long as the problem
  formulation is correct** — the solver can't rescue a wrong translation.
- **LINC** (Olausson et al., 2023, EMNLP) — the LLM acts purely as a semantic
  parser to first-order logic; an external theorem prover does the actual
  deduction. Its accuracy advantage over CoT specifically *grows* with proof
  depth and premise count, exactly where CoT's accuracy drops — the
  opposite failure curve. When the paper traced every error LINC made, they
  localized *all of them* to the semantic-parsing stage, none to the prover.
- **SATLM** (Ye et al., 2023, NeurIPS) — generates a *declarative*
  specification (a set of logical constraints) rather than an imperative
  step-by-step program, then hands it to a SAT solver. The stated reason:
  a declarative spec is closer to the problem's own natural-language
  description than a sequence of solution steps is, so it's easier for an
  LLM to get right — and the approach specifically wins on
  constraint-and-planning-shaped problems, not just forward arithmetic.

The common thread: offload exactly the capability LLMs are measurably worst
at — long, exact, multi-step deduction where small errors compound — to a
component that's perfect at exactly that, and keep the LLM doing the two
things that *are* its job: turning fuzzy language into a precise goal, and
turning a precise result back into readable language. This doesn't make the
system infallible; it relocates the one remaining failure surface from
"somewhere inside an opaque paragraph of prose" to "did this one written
goal correctly capture the question" — a single, inspectable spot instead
of an arbitrarily long invisible one.

`symbolic-tools` is this same pattern, with one addition: the "problem
formulation" stage (tree-sitter extraction into facts) happens once, up
front, for the whole codebase, rather than being re-derived per question —
so the per-query translation step is choosing *which existing facts to
join*, not inventing new formal content each time. `SYSTEM.md`'s own
`<rule>` 5 ("compose the chain, don't narrate") is this project's version
of Logic-LM's stated caveat: the guarantee only holds for the goal you
actually wrote and ran, not for a conclusion assembled afterward from two
separately-run goals.

## What converts cleanly, and what structurally doesn't

### Converts well

- **Closed, discrete, already-relationally-stated facts** — who calls whom,
  what's defined where, which branches exist. Both Logic-LM and LINC do
  best on cleanly, fully-stated premises; the accuracy gap between
  ProofWriter (synthetic, fully explicit) and FOLIO (naturalistic) in LINC's
  own results is direct evidence that *how completely the premises are
  already stated*, independent of subject matter, is a major factor.
- **Deductive chains of arbitrary depth** — this is specifically where a
  real solver's advantage over CoT *grows* rather than shrinks, because
  CoT's error rate compounds per step and a prover's doesn't.
- **Whole-fact-base aggregation** — ranking, counting, fan-in/fan-out over
  every fact at once. A token-by-token walk struggles to do this
  exhaustively and reliably; a real engine enumerates all of it by
  construction (`top_fan_in/2`, `all_mutual_recursion/1`, etc.).
- **Constraint-satisfaction / planning-shaped questions** — SATLM's whole
  point: stating *what must hold* is easier to get right, and cheaper to
  solve, than narrating a sequence of steps to get there.

### Does not convert cleanly — and why these are structural, not just "hard"

1. **The translation step itself stays squarely neural, and squarely
   fallible.** Across all three systems, the overwhelming majority of real
   errors are semantic-parsing errors, not solver errors. Two concrete
   sub-failures, both documented in LINC's own error analysis: (a)
   information a human reader would supply from context that the premises
   never stated at all — no formal language can encode what was never
   said; (b) genuine lexical ambiguity ("either x or y" as inclusive-or,
   exclusive-or, or genuinely ambiguous in context) forces the translator to
   silently commit to one reading, and a wrong pick produces a confidently
   wrong, fully "faithful" proof. This is the live, unsolved bottleneck in
   every one of these systems — not a solved problem being reapplied here.
2. **Reasoning shortcuts at the grounding boundary.** Neuro-symbolic systems
   can achieve high accuracy "by grounding the concepts incorrectly"
   whenever the intermediate symbols aren't directly supervised, only the
   final answer is (*Symbol Grounding in Neuro-Symbolic AI: A Gentle
   Introduction to Reasoning Shortcuts*, 2025) — the model settles on an
   internally-consistent but semantically wrong mapping that still happens
   to produce right answers on the cases actually tried. The direct analog
   here: a goal that resolves and returns a plausible result proves only
   that *the goal as written* is true — never, on its own, that the goal is
   what the English question actually meant. That check has no symbolic
   backstop; it's still entirely on the model.
3. **Open-world / incomplete-knowledge reasoning.** Prolog is built on
   negation-as-failure plus the closed-world assumption: anything not
   provable is treated as false, full stop — there is no third value for
   "unknown." This is a property of the formalism itself, not a missing
   feature, and it's exactly why this project is careful to say a scanned
   tree's absent fact family is "an absent predicate, not an empty one,"
   and why an `existence_error` is deliberately loud instead of a silent
   `No.` — the formalism genuinely cannot tell "false" apart from "never
   asked."
4. **Defeasible, rule-with-exceptions commonsense.** Ordinary Prolog has no
   native notion of a general rule a more specific fact can override;
   getting that requires a heavier, different formalism (defeasible logic,
   d-Prolog-style meta-interpreters) layered on top — and even then it buys
   "rules with exceptions," not open-ended human commonsense.
5. **Uncertain or probabilistic claims.** Plain Prolog has no confidence
   dimension — every asserted fact is implicitly certain (probability 1).
   "Likely," "usually," or a measured confidence score need a genuinely
   different language (ProbLog, Markov Logic Networks), not a Prolog
   idiom bolted on.
6. **Anything not reducible to discrete symbols in the first place.**
   Aesthetic or design judgment ("is this a good abstraction"), anything
   needing perceptual grounding the extractor never captured, genuinely
   creative or generative work — these aren't difficult Prolog problems,
   they're outside what any fact base can represent. The neural half has to
   own them outright, not delegate and hope.

## Bottom line

A symbolic engine doesn't make an agent's reasoning trustworthy by
replacing it wholesale — it makes exactly one class of claim (closed,
discrete, relationally-stated, however deep the deduction) checkable
instead of merely plausible, and it does this by moving the one remaining
place a mistake can hide from "anywhere in an arbitrarily long paragraph" to
"this one written goal." Every published version of this idea agrees that
the translation step is where the real risk still lives, and five further
boundaries — negation-as-failure's closed world, no defaults-with-exceptions,
no uncertainty, no grounding guarantee, and no representation at all for
non-symbolic judgment — are properties of the formalism itself, not gaps
that more engineering closes. Knowing that boundary precisely is what makes
the rest of the fact base trustworthy: everything inside it is provable
exactly *because* the project doesn't try to force anything outside that
boundary into it.

## Sources

- Wei et al., [Chain-of-Thought Prompting Elicits Reasoning in Large Language Models](https://arxiv.org/pdf/2201.11903) (NeurIPS 2022)
- [How Chain-of-Thought Works? Tracing Information Flow from Decoding, Projection, and Activation](https://arxiv.org/pdf/2507.20758) (2025)
- Lanham et al., [Measuring Faithfulness in Chain-of-Thought Reasoning](https://arxiv.org/pdf/2307.13702) (Anthropic, 2023)
- Turpin et al., [Language Models Don't Always Say What They Think: Unfaithful Explanations in Chain-of-Thought Prompting](https://arxiv.org/pdf/2305.04388) (2023)
- [Anthropic's Evaluation of Chain-of-Thought Faithfulness](https://www.marktechpost.com/2025/04/05/anthropics-evaluation-of-chain-of-thought-faithfulness-investigating-hidden-reasoning-reward-hacks-and-the-limitations-of-verbal-ai-transparency-in-reasoning-models/) — MarkTechPost summary of the Claude 3.7 study (scale/difficulty/length findings)
- Pan et al., [Logic-LM: Empowering Large Language Models with Symbolic Solvers for Faithful Logical Reasoning](https://arxiv.org/abs/2305.12295) (2023)
- Olausson et al., [LINC: A Neurosymbolic Approach for Logical Reasoning by Combining Language Models with First-Order Logic Provers](https://arxiv.org/pdf/2310.15164) (EMNLP 2023)
- Ye et al., [SatLM: Satisfiability-Aided Language Models Using Declarative Prompting](https://arxiv.org/abs/2305.09656) (NeurIPS 2023)
- [Symbol Grounding in Neuro-Symbolic AI: A Gentle Introduction to Reasoning Shortcuts](https://arxiv.org/abs/2510.14538) (2025)
- [Negation as failure](https://en.wikipedia.org/wiki/Negation_as_failure) / [Closed-world assumption](https://en.wikipedia.org/wiki/Closed-world_assumption) — Wikipedia, for the formal definitions
- [On the Implementation of the Probabilistic Logic Programming Language ProbLog](https://arxiv.org/pdf/1006.4442) (2010); [DeepProbLog](https://arxiv.org/pdf/1805.10872) (2018)
- [DR-Prolog: A System for Defeasible Reasoning with Rules and Ontologies on the Semantic Web](https://www.csd.uoc.gr/~bikakis/pubs/DR-Prolog-TKDE.pdf)
