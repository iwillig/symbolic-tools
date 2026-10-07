# Research: translating a user's question into something the Prolog database answers

How to take an English question, break it into parts, decide which parts
the fact base can verify, and run the result as a Prolog goal. A research
summary with a concrete pipeline — **the v1 pipeline is now implemented**
(`priv/question_grammar.pl`, `src/symbolic_ask.erl`, the `symbolic ask`
CLI command), covering the minimal vocabulary this doc's §6 sketches:
calls, defines, discussed; DCG-only, JSON-only. The LLM phrasing tier,
derived-predicate questions, and aggregation beyond count remain v2.

Primary sources, with the repo's own prior research:
[CHAT-80](https://github.com/JanWielemaker/chat80) (Pereira & Warren,
MIT-licensed),
[Spider](https://arxiv.org/abs/1809.08887) (Yu et al., EMNLP 2018),
[`curt-approach.md`](curt-approach.md) (Blackburn & Bos),
[`lorp-approach.md`](lorp-approach.md),
[`grpo-prolog-tool.md`](grpo-prolog-tool.md),
[`reviewing-llm-output.md`](reviewing-llm-output.md).

## 1. The problem, decomposed

Three stages, and the middle one is the one research keeps re-learning:

1. **Parts** — classify the question and extract its subject/relation/
   object: a yes/no question reduces to a goal; a wh-question ("which
   functions call X") marks the answer position as a Prolog *variable*;
   "how many" adds an aggregation; "where is X discussed" is not a
   structural question at all.
2. **Verifiability** — decide, *before* proving, whether the fact base can
   even in principle answer: does the relation word map to a predicate the
   base knows? Do the entities resolve to constants the base holds? Is the
   question about syntax facts, or about prose, or about intent?
3. **Execution** — build the goal, prove it, shape the answer back into
   the register the question asked in (one binding, a list, a count, a
   yes/no, a set of document references).

CHAT-80 is the whole shape in one system, in the primary source's own
words: "parsing the question, translate the parse to a Prolog query and
run this against its database." What CHAT-80 had that most modern systems
lost, and Spider measured: the translator *knew its schema*, because the
grammar and the database were written together.

## 2. What the prior art says

| System | Mechanism | The lesson it contributes |
|---|---|---|
| CHAT-80 (1980s) | DCG question grammar → quantified Prolog goal over a fixed world DB | Wh-words become variables; determiners drive quantifier scope; grammar and schema co-designed |
| Curt (Blackburn & Bos) | DCG + semantic construction, ground facts, `readings` accumulation | Ground declarative statements are the tractable core; quantifiers/negation need machinery beyond Horn clauses (see [`curt-approach.md`](curt-approach.md) §4) |
| Spider / text-to-SQL (2018–) | Learn NL → SQL *across* schemas | Schema generalization is the hard part: on unseen database schemas the then-best model hit **12.4% exact match** — never let the translator guess the schema it targets |
| LoRP (2025) | LLM translates NL → Prolog; named **validation** stage; SWI-Prolog proves; vote over attempts | Validation before execution is a *pipeline stage*, not an afterthought (see [`lorp-approach.md`](lorp-approach.md)) |
| GRPO-prolog (2025) | RL-trained 3B model emits Prolog; agentic **repair loop** wins | Even a trained model produces syntactically valid, executing, *wrong* programs ~10% of the time — verify, never trust shape (see [`grpo-prolog-tool.md`](grpo-prolog-tool.md)) |

The two failures these converge on: **wrong schema assumptions** (Spider)
and **coherent-but-wrong translation** (GRPO/LoRP). Every design decision
below exists to make one of those two failures loud instead of silent.

## 3. Breaking the question into parts

Question type determines the Prolog shape, not the wording:

| Question shape | Example | Prolog shape |
|---|---|---|
| Yes/no | "does `foo/2` call `bar/1`?" | prove the ground goal; `true`/`no_solution` |
| Wh (enumerative) | "which functions call `query_binary/2`?" | goal with a variable answer position + `findall/3` |
| Count | "how many functions define arity 2?" | `findall/3` + `length/2` |
| Where-in-prose | "where is dirty scheduling documented?" | `text_search/2` — evidence list, **not** a proof |
| Meta/opinion | "is the design good?" | not answerable by a fact base, ever — the class [`reviewing-llm-output.md`](reviewing-llm-output.md) §5 already excludes |

Entity resolution is part-of-speech work the repo's tokenizer already
does for one case: `foo/2` is a `Name/Arity` term, the shape `defines/5`'s
own values take. The open gap: "the tree-sitter NIF" → `symbolic_ts`
requires a synonym table or an LLM tier that names real constants — and
whatever it names must be *checked* against `defines/5`/`calls/5` before
the goal runs, or the question silently answers about a function that
does not exist.

## 4. Determining what is verifiable

The verifiability gate runs between extraction and proof, and it has
three rules:

1. **Vocabulary rule** — every relation word must bind to a predicate the
   session actually holds: structural (`calls/5`, `defines/5`),
   derived (`god_file/2`, `undocumented/4`, ...), prose (`text_search/2,3`),
   or claim-checking (`check_claim/2`). A relation outside that inventory
   is `unverifiable`, loudly, never guessed at — the exact discipline
   `symbolic_extract_llm`'s `KNOWN_VERBS` and `check_claim/2`'s catch-all
   already enforce for statements. `current_predicate/1` exists in erlog
   (verified in [`curt-approach.md`](curt-approach.md) §5), so the gate can
   check the *live session's* inventory, not a hardcoded list.
2. **Closed-world rule, scoped** — for structural facts within one scan,
   absence is evidence of absence (no `calls` fact = no call recorded in
   scanned files), so yes/no questions may use negation-as-failure. For
   prose it is NOT: `text_search` returning no hits means "not found in
   the corpus," never "the docs don't say that." Two world rules, one
   system — `check_claim/2`'s three verdicts (`true`/`false`/
   `unverifiable`) are already exactly this boundary for statements.
3. **Arity rule** — the schema's arity is part of the claim. Found live
   while writing this doc: asking "how many functions call
   `query_binary/1`" proves happily — **N = 0** — because the real
   predicate is `query_binary/2`; the correct question answers
   **N = 1** (`text_search_run`). A wrong-arity translation produces a
   *plausible wrong answer*, not an error. The gate must resolve
   `Name/Arity` against `defines/5` before proving — this is
   LoRP's validation stage, demonstrated.

## 5. Running it, and what already exists

Engine capabilities verified live against this repo's own cached base:

| Piece | Status |
|---|---|
| Bounded-grammar statement extraction (DCG, `svo/3`) | **shipped** — `priv/nlp_grammar.pl`, `symbolic extract` |
| Open-vocabulary statement extraction (LLM tool-call, closed verbs) | **shipped** — `symbolic_extract_llm` |
| Statement checking, three verdicts | **shipped** — `check_claim/2` in `.symbolic/rules.pl`, `symbolic check` |
| Prose evidence | **shipped** — `text_search/2,3` |
| Enumeration + counting | **verified** — `findall/3` and `length/2` prove in erlog |
| Question grammar (wh → variable) | **shipped (v1)** — `priv/question_grammar.pl`, five shapes |
| Question classifier + verifiability gate | **shipped (v1)** — `symbolic_ask`'s gate (§4's rules, incl. the arity rule) |
| `symbolic ask` wire-up | **shipped (v1)** — CLI, JSON answers, exit-code epistemics |

v1 gate refinement, found while implementing: subjects gate strictly
against `defines/5`; callees gate loosely (arity checked only when the
name is known to the base — a stdlib callee like `halt/1` has no
`defines/5` fact and must pass); `is zzz/9 defined?` answering `false`
has no gate at all, because non-existence IS the answer to a
definition question. Also: `current_predicate/1` cannot see compiled
procedures (`text_search/2` answers count: 0), so the gate checks a
static closed inventory, not the live session — which is also exactly
what the grammar can emit.

Execution sketch, once parts are extracted: build the goal string, prove
against the session, shape by question type (the answer to a count is a
number; to a wh-question, a list; to a yes/no, a verdict). The wire-up
mirrors `symbolic_check`'s shape — extraction tier first, gate second,
proof third, all in one `symbolic ask "<question>"` command.

## 6. The pipeline, end to end

```
"how many functions call query_binary/2?"
   1. classify        → count question
   2. extract parts   → subject: variable; relation: calls; object: query_binary/2
                        (DCG if the grammar covers the shape, LLM tool-call
                        with a CLOSED predicate schema otherwise — same
                        two-tier fallback as symbolic extract)
   3. gate            → calls/5 is in the vocabulary ✓
                        query_binary/2 resolves against defines/5 ✓
                        (arity wrong → reject loudly, not N=0)
   4. build + prove   → findall(C, calls(C, _, local(query_binary, 2), _, _), L),
                        length(L, N)   → N = 1
   5. shape           → "1 function: text_search_run"
```

Unverifiable outcomes are answers, not failures: report *what* was
unverifiable (unknown relation, unresolvable entity, wrong arity) so the
asker can repair the question — GRPO's repair-loop finding, in miniature.

## References

- CHAT-80, Pereira & Warren (source at
  <https://github.com/JanWielemaker/chat80>, MIT; README quoted in §1)
- Yu et al., "Spider: A Large-Scale Human-Labeled Dataset for Complex and
  Cross-Domain Semantic Parsing and Text-to-SQL Task", EMNLP 2018,
  <https://arxiv.org/abs/1809.08887> (12.4% figure from the abstract)
- Blackburn & Bos, *Representation and Inference for Natural Language* —
  via [`curt-approach.md`](curt-approach.md)
- LoRP and GRPO-prolog — via [`lorp-approach.md`](lorp-approach.md) and
  [`grpo-prolog-tool.md`](grpo-prolog-tool.md)
- Engine facts in §4–5 verified live against this repo's cached base this
  session: `findall/3`, `length/2`, the arity lesson (§4 rule 3)
