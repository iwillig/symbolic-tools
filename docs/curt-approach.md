# Design: Parsing Natural Language Into Prolog Facts (the Curt Approach)

This document answers a specific question: how would `symbolic-tools` parse
natural language *with* Prolog — not parse it elsewhere and hand a result
to Prolog — and use the result to grow a fact base the LLM agent can query.
It follows up on [`nlp-tooling.md`](nlp-tooling.md) §2 (which sketched a
single DCG) and grounds the answer in a real, complete worked system:
**Curt**, built incrementally across Blackburn & Bos, *Representation and
Inference for Natural Language* (CSLI, 2004),
[PDF](https://www.let.rug.nl/bos/pubs/BlackburnBos2005CSLI.pdf). A
design/research document only — nothing here is implemented.

**Recommendation up front:**

- **Prolog is the parser, not a downstream consumer of one.** A DCG rule
  (`phrase(sentence(Fact), Words)`) parses a word list *and* builds the
  result term in a single Prolog proof — there is no separate "parse, then
  hand off" stage. The only pre-Prolog step is tokenizing a string into a
  word list (§2).
- **Scope to ground facts, not general first-order logic.** Curt's full
  architecture handles arbitrary natural language, including universally
  quantified and negated sentences — which are *not* expressible as
  ordinary Horn-clause Prolog facts, and which is why Curt eventually needs
  external theorem provers (§4). `symbolic-tools`' actual target — simple
  declarative statements about code relationships ("X depends on Y") — is
  the ground-fact case, which stays inside plain Prolog resolution and
  needs none of that machinery.
- **Reuse Curt's `readings`/`history` pattern**: a dynamic Prolog predicate
  that `assert`/`retract` grows as sentences come in, exactly the "natural
  language database of facts" being asked for — mapped onto the existing
  `prolog_session` from [`erlang-mcp-design.md`](erlang-mcp-design.md).
- **Open verification item, first**: confirm `erlog` supports `assert/1`,
  `assertz/1`, and `retract/1` on dynamic predicates before committing to
  this — `erlang-mcp-design.md` §6's predicate-coverage table doesn't list
  them explicitly (see §5).

## 1. The actual pipeline

The one genuinely separate step is **tokenization** — splitting a raw
sentence string into a list of words. Everything after that is a single
Prolog computation, not a hand-off between stages:

```
"module_a depends on module_b."
        │  tokenize (outside the grammar — see §2)
        ▼
[module_a, depends, on, module_b]
        │  phrase(sentence(Fact), Words)
        │  — parsing structure AND building the result term happen
        │    together, inside one Prolog proof
        ▼
depends_on(module_a, module_b)
        │  assert/1 (§3)
        ▼
depends_on(module_a, module_b).   — now a fact in the erlog session
```

A DCG rule is an ordinary Prolog clause (`-->` is syntactic sugar over a
difference-list clause). There is no external parser producing a tree that
Prolog then reads — `phrase/2` *is* the parse.

## 2. Tokenization — the one real pre-Prolog step

Tokenizing a bounded, simple sentence is not "NLP" in any deep sense — it's
splitting on whitespace/punctuation. Two equally valid places to do it,
consistent with [`nlp-tooling.md`](nlp-tooling.md) §3:

- **Erlang binary pattern matching**, before the string ever reaches
  `erlog` — the tokenizer sketch already given in `nlp-tooling.md` §3
  applies directly here.
- **Inside Prolog itself**, using `erlog`'s own double-quoted-string
  handling (`erlang-mcp-design.md` §4 confirms `"..."` becomes a code
  list) plus a small split-on-space helper — keeping the entire pipeline
  in one engine, at the cost of writing that helper in Tier-1-style Prolog
  (`erlang-mcp-design.md` §7).

Either is fine; which one to pick is an implementation detail, not a design
decision — pick whichever keeps the fact-extraction code in one place.

## 3. A grounded example, scoped to ground facts

A minimal grammar for the kind of sentence `symbolic-tools` actually needs
to extract facts from — declarative statements about code relationships,
not open natural language:

```prolog
sentence(depends_on(A, B)) --> [A], [depends, on], [B].
sentence(calls(A, B))      --> [A], [calls], [B].
sentence(defines(A, B))    --> [A], [defines], [B].
```

```prolog
?- phrase(sentence(Fact), [module_a, depends, on, module_b]).
Fact = depends_on(module_a, module_b).
```

`assert(Fact)` turns that into a queryable fact in the current session.
This is deliberately the simple end of what Chapter 6 of Blackburn & Bos
builds — no lambda calculus, no scope-ambiguity storage, no quantifiers —
because the target sentences don't need them. Extending the grammar to
more sentence shapes is adding more `sentence/1` clauses, not a different
mechanism.

## 4. Curt — the fuller architecture, and where it stops applying

Curt ("Clever Use of Reasoning Tools") is a dialogue agent built across
seven increasingly capable versions, each in the book's example code:

| Version | Adds |
|---|---|
| **Baby Curt** | Parses each sentence via a DCG + lambda-calculus semantic construction (handling scope ambiguity via Keller storage), and **stores every resulting formula in a dynamic predicate, `readings/1`, via `assert`/`retract`** — plus a raw sentence log in `history/1`. Reserved commands (`readings`, `history`, `select`, `new`, `bye`) inspect or reset that state mid-dialogue. This *is* "a natural-language database of facts," already built. |
| **Rugrat Curt** | Adds consistency checking — Baby Curt happily stores "Mia smokes." then "Mia does not smoke."; Rugrat Curt rejects the second as inconsistent with the first. |
| **Clever / Sensitive / Scrupulous Curt** | Progressively better inference over the accumulated formulas. |
| **Knowledgeable Curt** | Integrates the off-the-shelf theorem provers (Otter, Bliksem) and model builders (Mace, Paradox) from Chapter 5 for harder consistency/informativity checks. |
| **Helpful Curt** | The full querying task — ask Curt a yes/no question against everything it's been told. |

**Where this stops fitting `symbolic-tools`:**

- Baby/Rugrat/Clever Curt run entirely inside Prolog's own resolution —
  consistent with `erlang-mcp-design.md`'s in-process-on-BEAM design.
- **Knowledgeable Curt is not.** Its theorem provers and model builders are
  invoked via **Perl scripts shelling out to separate binaries** — exactly
  the OS-boundary `erlang-mcp-design.md` was written to reject for the
  Prolog engine itself. If a future need requires reasoning about general
  first-order sentences (quantifiers, negation) rather than ground facts,
  that need collides with the no-subprocess design and has to be resolved
  explicitly, not inherited by accident.
- This is also why §3 stays deliberately at ground facts: "Every module
  that imports `foo` also imports `bar`" is a universally quantified
  statement that cannot be represented as an ordinary Horn-clause fact —
  it needs exactly the machinery `symbolic-tools` doesn't want to adopt.
  "X depends on Y" has no such problem.

## 5. Open question: does `erlog` support `assert`/`retract`?

Curt's core mechanism — a dynamic predicate grown with `assert`/`retract`
as the dialogue proceeds — is load-bearing for the whole approach. `erlog`
is confirmed to have DCGs and `findall/3` (`erlang-mcp-design.md` §6), but
that table does not explicitly confirm `assert/2`/`assertz/1`/`retract/1`.
**Verify this before committing to this architecture** — if missing, it's
likely Tier 1 or Tier 2 work (`erlang-mcp-design.md` §7) to add, but that's
unverified.

## 6. Suggested path

1. Confirm `erlog` supports `assert`/`retract` on dynamic predicates (§5).
2. Prototype the tokenizer + grounded grammar from §3 against a handful of
   real sentences drawn from this repo's own `docs/*.md` prose (dogfooding,
   same idea as [`tree-sitter-markdown.md`](tree-sitter-markdown.md)'s
   `broken_link/2` check) — confirm the grammar covers the sentence shapes
   that actually occur before generalizing it.
3. Add Baby Curt's `readings`/`history`-style dynamic predicates to
   `prolog_session` (`erlang-mcp-design.md` §3) as the accumulating fact
   store, exposed through the existing four-tool MCP surface rather than a
   new dialogue protocol.
4. Add Rugrat Curt's consistency check only once ground-fact contradictions
   are an actual observed problem — plain `depends_on(A,B)`-shaped facts
   are far less prone to the "Mia smokes / Mia does not smoke" class of
   contradiction than open natural language is.
5. Treat Knowledgeable/Helpful Curt's external-theorem-prover integration
   as explicitly out of scope unless a future need requires reasoning over
   non-ground, quantified statements (§4).

## References

- [Blackburn & Bos, *Representation and Inference for Natural
  Language*](https://www.let.rug.nl/bos/pubs/BlackburnBos2005CSLI.pdf)
  (CSLI, 2004) — Chapter 6 ("Putting It All Together") is Curt; Chapter 2
  (lambda calculus/semantic construction) and Chapter 5 (first-order
  inference, off-the-shelf provers) are what the later Curt versions build
  on.
- [Blackburn & Striegnitz, *Natural Language Processing Techniques in
  Prolog*](https://cs.union.edu/~striegnk/courses/nlp-with-prolog/html/toc.html)
  — the syntax half (DCGs, chart parsing, gap-threading) this document's
  §3 grammar is the simple end of.
- [`nlp-tooling.md`](nlp-tooling.md) §2 — the original DCG sketch this
  document expands into a full architecture.
- [`erlang-mcp-design.md`](erlang-mcp-design.md) §3 (session model), §4
  (double-quoted-string handling), §6 (predicate coverage — the
  `assert`/`retract` open question), §7 (Tier 1/2/3 extension effort), §8
  (no-subprocess design — why Knowledgeable Curt doesn't fit).
- [`lorp-approach.md`](lorp-approach.md) · [`grpo-prolog-tool.md`](grpo-prolog-tool.md)
  — the other NL-to-Prolog translation approaches already reviewed;
  Curt's DCG-plus-semantics pipeline is a third, complementary approach
  specifically for *growing* a fact base rather than *querying* an
  existing one.
- [`tree-sitter-markdown.md`](tree-sitter-markdown.md) — the dogfooding
  precedent (`broken_link/2`) §6 proposes reusing for grammar validation.
