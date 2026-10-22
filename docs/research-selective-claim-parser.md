# Research: a selective parser for LLM-written plans — keep only what the fact base can check

An LLM-written plan is free prose: headings, bullets, checkboxes, and sentences
that mix intent ("we should refactor"), prediction ("the helper will call"),
evaluation ("this makes it faster"), and the occasional present-tense structural
statement about named code ("`write/2` calls `delete_metadata/1`"). Only the last
kind maps onto this project's fact schema. This document researches how to build
a parser that scans such a plan, keeps exactly the mechanically checkable
sentences, turns each into a Prolog goal, and says *nothing* about the rest —
never a `false` for a sentence it merely could not parse. It builds on the
checkable/behavioral split in [`reviewing-llm-output.md`](reviewing-llm-output.md)
§2/§5 and the three-stage parts → verifiability → execution decomposition in
[`research-questions-to-prolog.md`](research-questions-to-prolog.md) §1. Research
only; nothing here is built.

- **Date:** 2026-10-21
- **Scope:** `analyze_text` → `query_frames`, the `symbolic extract`/`check`/`ask`
  pipelines, `priv/nlp_grammar.pl`, `priv/question_grammar.pl`,
  `check_claim/2`, and the claim-extraction, factuality, hedge-detection,
  chunking/partial-parsing, OpenIE, and Markdown primary literature.
- **Method:** repo claims cite `path:line` and were exercised live against this
  repo's own cached fact base (`.symbolic/facts.dets`) and the released binary;
  external claims were read from the papers' PDFs or official spec/docs pages
  and carry a URL. Two primary PDFs could not be fetched (HTTP 403) and are
  marked as such in §10.

**Primary sources** (external; the repo's own are cited inline):
[FActScore](https://arxiv.org/abs/2305.14251) (Min et al. 2023) ·
[SAFE / "Long-form factuality"](https://arxiv.org/abs/2403.18802) (Wei et al. 2024) ·
[WiCE](https://arxiv.org/abs/2303.01432) (Kamoi et al. 2023) ·
[Claimify](https://arxiv.org/abs/2502.10855) (Metropolitansky & Larson 2025) ·
[VeriScore](https://arxiv.org/abs/2406.19276) (Song et al. 2024) ·
[FacTool](https://arxiv.org/abs/2307.13528) (Chern et al. 2023) ·
[Core](https://arxiv.org/abs/2407.03572) (Jiang et al. 2024) ·
[Decontextualization](https://arxiv.org/abs/2102.05169) (Choi et al. 2021) ·
[ClaimBuster](https://doi.org/10.1145/3097983.3098131) (Hassan et al. KDD 2017) ·
[CLEF-2021 CheckThat! Task 1](https://ceur-ws.org/Vol-2936/paper-28.pdf) (Shaar et al. 2021) ·
[CoNLL-2010 hedge shared task](https://aclanthology.org/W10-3001.pdf) (Farkas et al. 2010) ·
[FactBank](https://www.cs.brandeis.edu/~roser/pubs/sauriPustejovsky_lrec08_2.pdf) (Saurí & Pustejovsky, LREC 2008) ·
["Neural models of factuality"](https://arxiv.org/abs/1804.02472) (Rudinger, White, Van Durme 2018) ·
[Penn Treebank tagging guidelines](https://catalog.ldc.upenn.edu/docs/LDC99T42/tagguid1.pdf) (Santorini 1990) ·
[CommonMark 0.31.2](https://spec.commonmark.org/0.31.2/) · [GFM spec](https://github.github.com/gfm/) ·
[ACE 6.7 construction rules](http://attempto.ifi.uzh.ch/site/docs/ace/6.7/ace_constructionrules.html) ·
[GF tutorial](https://www.grammaticalframework.org/doc/tutorial/gf-tutorial.html) ·
[CHAT-80 source](https://github.com/JanWielemaker/chat80) ·
[Stanford OpenIE](https://aclanthology.org/P15-1034.pdf) (Angeli et al. 2015) ·
[TextRunner](https://www.ijcai.org/Proceedings/07/Papers/429.pdf) (Banko et al. 2007) ·
[ClausIE project page](https://www.mpi-inf.mpg.de/departments/databases-and-information-systems/software/clausie) ·
[Island parsing](https://aclanthology.org/E83-1017.pdf) (Carroll 1983).

**Recommendation up front:**

- **Entity grounding is the first filter, not grammar.** Every paper in §2
  that selects claims well starts by asking "does this sentence contain a
  verifiable element?" (Claimify's Selection stage, VeriScore's "verifiable
  claims", ClaimBuster's NFS/UFS/CFS). For code the operational form is
  stricter and cheaper: a sentence with no token that resolves to a
  `Name/Arity`, `Mod:Name/Arity`, or `path/file.ext` is dropped before any
  grammar runs. nlprule cannot do this for us — it tags `handle_call` as
  `UNKNOWN` with no chunk (§3, verified live) — so the grounder is an Erlang
  regex/rejoin pass, reusing `symbolic_ask:ident_candidates/1`'s rejoining of
  `/`, `:` and `.`-split tokens (§1.4).
- **Drop by modality before parsing by relation.** The factuality literature
  (FactBank's CT/PR/PS × polarity, Rudinger's `[-3, 3]`, the CoNLL-2010 cue
  lists) and the Penn tag set agree on cheap discriminators: an `MD` in the
  verb phrase (`should`, `will`, `could`), a sentence-initial base-form `VB`
  (the imperative), a question, a hedge cue, or a comparative/evaluative
  predicate (`JJR`/`RBR`: "faster", "easier") means the sentence is not a
  present-tense assertion about structure. Those are discarded with a reason,
  not proved (§3).
- **The DCG belongs *after* normalization, not before.** `priv/nlp_grammar.pl`
  fails today on "Then", on `dets:insert/2`, and on "will call" — all verified
  live (§1.5) — because `symbolic_extract:tokenize/1` hands it raw words. Feed
  it a normalized stream instead (`ident(fun, write/2)`, lemma `call`,
  negation flag, purpose clause stripped) and the bounded grammar is finally
  operating on the bounded vocabulary it was designed for (§6, stage 4).
- **Abstain loudly, never guess.** FActScore's `Irrelevant`, SAFE's
  "should not be rated", VeriScore's "ignored", Claimify's "Cannot be
  disambiguated", and this repo's own `unverifiable` are the same verdict:
  a sentence the pipeline cannot ground gets *no* truth value. The output is a
  per-claim verdict list with the raw sentence attached (§5, §6), not a
  percentage — Core shows a percentage can be gamed by trivial sub-claims.
- **An LLM tier is optional and narrowly scoped**: only for sentences that
  passed grounding and modality but no DCG shape matched — the exact
  `symbolic_extract_llm` fallback that exists today, with the same closed verb
  enum (§6, stage 7). Claimify's ablation is the evidence that *checking
  verifiability before extracting* is where the gain is, not in the LLM.

---

## 1. What already exists in this repo, and its precise gaps

### 1.1 `analyze_text` → `query_frames`

`symbolic_serve:handle_analyze_text/1` (`src/symbolic_serve.erl:350-363`) calls
`symbolic_analyze:run_result/1` and then `symbolic_ask_nlprule:extract_json_frames/1`,
returning the raw analysis with a `query_frames` key. `symbolic_analyze:run_result/1`
(`src/symbolic_analyze.erl:17-29`) is a thin wrapper over the `symbolic_nlprule:analyze/1`
NIF. The NIF (`native/symbolic_nlprule/src/lib.rs:82-108`) emits, per sentence,
`text`, `span`, and per token `text`, `span`, `has_space_before`, `tags`
(every `{lemma, pos}` alternative nlprule keeps, minus empty POS), and `chunks`.
It never corrects or disambiguates; a token can carry four POS alternatives
(`test` → `JJ,NN,VB,VBP`, §3).

`symbolic_ask_nlprule:extract_frames/1` (`src/symbolic_ask_nlprule.erl:61-78`)
runs each sentence through `symbolic_ask:map_tags/1` and drops it on
`unrecognized` (line 73). `map_tags/1` (`src/symbolic_ask.erl:306-317`) only
recognizes a sentence whose first token is `does`, `is`, `are`, `where is`,
`which`, `who`, `what`, or `how many`. **Every declarative sentence is therefore
`unrecognized`** — the frame mapper is a *question* classifier reused as-is.
The frames it can emit (`src/symbolic_ask_nlprule.erl:121-153`) are
`calls|uses|returns|handles` (yes/no), `defines`, `file_scanned`,
`config_defined`, `callers_of` (enumerate/count), `text_search` (prose), and
`call_sites_of`/`definition_site_of`. For a multi-sentence plan today,
`query_frames` is `[]` for every sentence that is not a question, and the
docs say so: "An empty list means the bounded frame mapper did not recognize a
candidate" ([`nlprule-analysis.md`](nlprule-analysis.md) "Use").

What the question mapper gets right, and this design keeps: it is
**vocabulary-driven, not tag-driven** — `find_verb/2`
(`src/symbolic_ask.erl:341-365`) picks the relation verb from a closed table
(`relation_of/1`: `call|invoke|hit|run|reach|delegate|depend → calls`, and so
on) because "the tagger mis-tags code-adjacent verbs (spike: `call` came back
NN between two camelCase identifiers)" (comment at lines 345-349). And
`ident_candidates/1` (lines 492-523) with `segments/4` (lines 525-565) rejoins
identifiers the tokenizer split on `_`, `.`, and `/` — the exact repair §4 needs.

### 1.2 `symbolic extract` — the bounded DCG

`priv/nlp_grammar.pl` has three rules: `X calls Y`, `X was removed`, `X no
longer exists`. `symbolic_extract:tokenize/1` (`src/symbolic_extract.erl:125-150`)
splits on whitespace, strips only trailing `.!?` (line 136), and rejects any
word that does not match `^[a-z][a-zA-Z0-9_]*(/[0-9]+)?$` (line 150) with
`{bad_token, Word}`. Consequences, all reproduced live against the released
binary this session:

```sh
$ symbolic check "Then write/2 calls delete_metadata/1 to clear the stale entry."
cannot check claim: {extract_error,{tokenize_error,{bad_token,"Then"}}}
$ symbolic check "write/2 calls dets:insert/2"
cannot check claim: {extract_error,{tokenize_error,{bad_token,"dets:insert/2"}}}
$ symbolic check "write/2 will call normalize_key/1"
Unrecognized.
$ symbolic check "write/2 calls delete_metadata/1"
{"fact":["svo",["/","write",2],"calls",["/","delete_metadata",1]],"verdict":"true"}
```

A capitalized sentence-initial word, a remote callee, backticks, a trailing
comma, and any modal all fail *before* the grammar runs. The grammar itself
is fine; its input contract is the gap.

### 1.3 `symbolic_extract_llm` — the open-phrasing tier

`src/symbolic_extract_llm.erl:35` fixes `KNOWN_VERBS` to `calls`/`removed`;
`chat_result/2` (lines 107-122) leaves `tool_choice` at `auto` so the model may
decline, which maps to `unrecognized` (line 115); `parse_ident/1` (lines 210-222)
enforces the same `name/N` regex as the DCG tokenizer, so `Mod:fun/N` is lost
here too. The documented accuracy limit — "foo/2 improves performance" was
confidently misclassified as `removed`
([`reviewing-llm-output.md`](reviewing-llm-output.md) §4.2 Phase 2) — is a
modality/evaluation failure that a pre-filter (§3) catches deterministically
before a model is ever consulted.

### 1.4 `check_claim/2` and the question gate

`.symbolic/rules.pl:1820-1833`: `calls` proves against `local(G,B)` *or*
`remote(_,G,B)`; `removed` proves `\+ defines`; everything else is
`unverifiable`. The `symbolic ask` gate
([`research-questions-to-prolog.md`](research-questions-to-prolog.md) §4) adds
the three rules this parser inherits unchanged: **vocabulary** (relation word
must map to a held predicate), **scoped closed world** (absence of a `calls/5`
fact is evidence of absence within one scan; absence of a text hit is not),
and **arity** (`Name/Arity` must resolve against `defines/5` or the goal proves
a plausible wrong answer).

### 1.5 The gap, stated once

Today there is no component that takes a *paragraph* and returns the subset of
sentences worth checking. `analyze_text` segments and tags but recognizes only
questions; `extract` parses one pre-sanitized sentence; `check` chains the two.
Nothing filters by modality, strips purpose clauses, resolves "it", handles
remote callees in prose, or uses the plan's own Markdown structure. Those are
the stages in §6.

## 2. What the claim-extraction literature says about *selecting* checkable claims

Every system below has an explicit selection step. The table pulls the
inclusion and exclusion rules verbatim where the source states them.

| Source | Unit | Inclusion rule (quoted) | Exclusion rule (quoted) | What it means here |
|---|---|---|---|---|
| FActScore §3.1, §3.3 | atomic fact | "we define an atomic fact as a short sentence conveying one piece of information" | "If the atomic fact is clearly not related to the prompt … they assign `Irrelevant`"; domain chosen because "Biographies are objective (not subjective or debatable)" | One relation per claim; `Irrelevant` is a third label, never folded into `Not-supported`. 8–15% of facts were `Irrelevant` (Table 1). |
| SAFE §3 | individual fact | "(a) split a long-form response into individual self-contained facts, (b) determine whether each individual fact is relevant … (c) for each relevant fact, iteratively issue Google Search queries"; "revise each individual fact to be self-contained by … replac[ing] vague references (e.g., pronouns) with the proper entities" | fn. 5: relevance "identifies statements that should not be rated (e.g., 'I don't know the answer to that')"; fn. 7: irrelevant facts "should not be considered when evaluating factuality" | Pronoun replacement is a named stage (→ §7 decontextualization). |
| VeriScore §2.1.2, §3.1 | verifiable claim | "Verifiable claims describe a single event or state with all necessary modifiers (e.g., spatial, temporal, or relative clauses) that help denote entities or events in the real world." | "Unverifiable content such as advice, fictional stories, or subjective opinions are ignored." Annotators faulted SAFE for extracting "subjective content (2a) and personal experience (2b)" ("I am 1000% better."), "trivial (4a)" ("3.2 is a number.") and "vague (4b)" claims | Advice ("we should…") is excluded by definition. Trivial claims ("`write/2` exists" from every mention) are noise. Uses a sliding window of 0–3 preceding sentences for context. |
| Claimify §2.1, §3.2–3.4, §6 | factual claim | Adopts Ni et al.: a fact is "a statement or assertion that can be objectively verified as true or false based on empirical evidence or reality"; **Coverage**: "extracted claims should capture the verifiable information in the source text without explicitly including the unverifiable information" | Selection: the LLM may "(1) state that the sentence does not contain any verifiable content, (2) return a modified version of the sentence that retains only verifiable content, or (3) return the original sentence"; Disambiguation: "If any ambiguity is unresolvable, the sentence is labeled 'Cannot be disambiguated' and excluded … even if it has unambiguous, verifiable components." | Two discard reasons, both kept as explicit labels. Ablation: "Removing the Selection stage caused the largest performance drop, indicating the benefit of checking verifiability prior to extracting claims." §7: "check-worthiness is subjective" — select by verifiability, not importance. |
| WiCE §2.1–2.3 | sub-claim | Claim-Split prompt: "Segment the following sentence into individual facts."; labels `{SUPPORTED, PARTIALLY-SUPPORTED, NOT-SUPPORTED}` | Claims that split into one or more than six sub-claims are filtered (§2.3) | A sentence can be *partially* checkable — one sub-claim provable, the rest not. |
| FacTool §3.1, §4.1, Table 2 | claim | "Claim (c) a statement inferred from the model response, whose granularity is defined by a natural language text"; code domain: "We consider each generated code snippet within the response as a single claim to be verified. We extract all such code snippets that are enclosed with brackets, in other words, within a code block." | KB-QA claims must "not exceed 15 words" and "clearly describe a fact" | In the code domain the *structure* (a fenced block) is the claim detector — exactly `example_calls/5`/`stale_doc_call/4`. Verification is execution against generated tests, i.e. behavioral; this project's syntax facts stop short of that (`reviewing-llm-output.md` §5). |
| Core (abstract) | sub-claim | selects "according to their uniqueness and informativeness" | "popular metrics using the Decompose-Then-Verify framework, such as FActScore, can be manipulated by adding obvious or repetitive subclaims to artificially inflate scores" | Do not report a score; report verdicts. Dedupe identical goals. |
| ClaimBuster §3.1, §3.3 | sentence | CFS: "They contain factual claims and the general public will be interested in knowing whether the claims are true." | NFS: "Subjective sentences (opinions, beliefs, declarations) and many questions fall under this category. These sentences do not contain any factual claim." ("But I think it's time to talk about the future.") | Features were POS counts, sentiment, length, words, entity types; "the most discriminating feature is the POS tag VBD" and second "the POS tag CD (Cardinal Number)". For code, `CD` is the arity digit — the grounding signal. |
| CheckThat! 2021 Task 1 §3 | tweet/sentence | annotators "answer several auxiliary questions … such as 'does it contain a verifiable factual claim?', 'is it harmful?' and 'is it of general interest?', before deciding on the final check-worthiness label" | — | "Contains a verifiable factual claim?" is the first question and is separable from importance. This parser answers only that question. |
| Decontextualization (Choi et al.) Def. 1, §3 | sentence | "a sentence s′ is a valid decontextualization of s if: (1) the sentence s′ is interpretable in the empty context; and (2) the truth-conditional meaning of s′ in the empty context is the same as the truth-conditional meaning of s in context c." Edits: NAME COMPLETION, PRONOUN/NP SWAP, DM REMOVAL, BRIDGING, GLOBAL SCOPING, ADDITION | "When it is too challenging to decontextualize, it is classified into the INFEASIBLE category." | "DM REMOVAL involves removal of discourse markers (DMs) such as 'therefore'" licenses stripping "Then", "Next", "Also". INFEASIBLE → unchecked. |

Two cross-cutting findings. First, **selection precedes decomposition in every
recent system** (Claimify, VeriScore) and the older ones that skip it
(FActScore, SAFE) are criticized precisely for extracting "everything"
(VeriScore §2.1.1: "it extracts *everything* instead of just verifiable
claims, an issue that is inherited by SAFE"). Second, **all of them keep an
explicit "not rated" bucket** — §5.

## 3. Linguistic filters, tied to the tags nlprule actually emits

A realistic seven-sentence excerpt was run through the released binary
(`symbolic analyze`, nlprule 0.6.4 English tokenizer) this session. The
relevant tokens:

| Token (sentence) | nlprule `tags` (lemma/POS) | `chunks` |
|---|---|---|
| `We` (S1) | `we/PRP` | `B-NP-singular, E-NP-singular` |
| `should` (S1) | `should/MD` | `B-VP` |
| `refactor` (S1) | `refactor/VB, refactor/VBP` | `I-VP` |
| `easier` (S1) | `easy/JJR` | `B-ADJP` |
| `to` `test` (S1) | `to/IN, to/TO` · `test/JJ, test/NN, test/VB, test/VBP` | `B-VP`, `I-VP` |
| `Then` (S2) | `then/JJ, then/NN, then/RB` | `B-NP-plural` |
| `handle_call` (S2) | `handle_call/UNKNOWN` | `[]` |
| `/` · `3` (S2) | `//UNKNOWN` · `3/CD` | `[]` |
| `calls` (S2) | `call/NNS, call/VBZ` | `E-NP-plural` |
| `to` `validate` (S2) | `to/TO` · `validate/VB` | `I-VP`, `I-VP` |
| `will` `call` (S3) | `will/MD` · `call/VB` | `B-VP`, `I-VP` |
| `is` `defined` (S4) | `be/VBZ` · `define/VBN` | `B-VP`, `I-VP` |
| `src` `/` `symbolic_fact_store` `.` `erl` (S4) | `src/NN:U` · `//UNKNOWN` · `symbolic_fact_store/UNKNOWN` · `./PCT` · `erl/UNKNOWN` | `[]` |
| `It` (S5) | `it/PRP` | `B-NP-singular, E-NP-singular` |
| `no` `longer` (S5) | `no/DT` · `long/JJR` | `B-ADVP`, `I-ADVP` |
| `dets` `:` `lookup` `/` `2` (S5) | `dets/UNKNOWN` · `:/PCT` · `lookup/NN` · `//UNKNOWN` · `2/CD` | NP then `[]` |
| `This` `makes` … `faster` (S6) | `this/DT` · `make/NNS, make/VBZ` · `fast/JJR, faster/RBR` | NP, `B-VP`, `I-ADVP` |
| `is` `documented` (S7) | `be/VBZ` · `document/VBN` | `B-VP`, `I-VP` |

Three facts about this output drive the design. (1) **Code identifiers are
`UNKNOWN` with no chunk, and are split on `/`, `:`, `.`** — the tagger gives
nothing to work with except the fact that it gave up, which is itself a
reliable "this is code" signal when combined with a regex. (2) **The relation
verb next to an identifier is mis-chunked**: `calls` in S2 carries both `NNS`
and `VBZ` and sits inside an NP chunk (`E-NP-plural`), confirming the
`symbolic_ask.erl:345-349` finding; the verb must come from the closed
relation table, not the tag. (3) **The non-structural signals are clean**:
`MD` for modality, `PRP`/`DT` for pronoun subjects, `JJR`/`RBR` for
comparatives, `TO`+`VB` for infinitival purpose clauses, `VBZ`+`VBN` for the
passive present ("is defined", "is documented").

The Penn tag definitions behind those signals (Santorini 1990, §2):

- `MD`: "all verbs that don't take an -s ending in the third person singular
  present: can, could, (dare), may, might, must, ought, shall, should, will,
  would."
- `VB`: "This tag subsumes imperatives, infinitives and subjunctives."
  Examples: "Imperative: Do/VB it." "Infinitive: You should do/VB it."
- `VBD` past tense; `VBN` past participle; `VBZ` "Verb, 3rd person singular
  present"; `VBP` "Verb, non-3rd person singular present".
- `PRP`: "the personal pronouns proper … (I, me, you, he, him, etc.)".
- `JJR`: "Adjectives with the comparative ending -er and a comparative
  meaning"; `RBR` comparative adverb.
- `TO`: "To is tagged TO, regardless of whether it is a preposition or an
  infinitival marker."
- `CD`: cardinal number.

The factuality literature's cue inventories, from the primary sources:

- FactBank (Saurí & Pustejovsky 2008) §2.2 Table 1: values `CT+` (fact),
  `CT-` (counterfact), `PR+`/`PR-` (probable / not probable), `PS+`/`PS-`
  (possible / not certain), `CTu` ("certain but unknown output"), `Uu`
  ("unknown or uncommitted"); §2.4.1 "Modal Particles. These include modal
  auxiliaries (could, may, must), but also clausal and sentential adverbial
  modifiers (maybe, likely, possibly)"; "Polarity Particles … adverbs (not,
  until), quantifiers (no, none), pronouns (nobody)"; §2.4.2 "the event
  denoted by the embedded clause is intensional in nature; e.g. purpose
  clauses (21) and conditional constructions (22)" — the purpose clause
  example is "must adopt regulations to *ensure* people are not exposed".
- Rudinger et al. 2018 §1: factuality is "whether an event happened or not";
  §2.1: "negation (2a), modal auxiliaries (2b), determiners (2c), adverbs (2d),
  verbs (2e), adjectives (2f), and nouns (2g) can all convey that a particular
  event … did not happen" ("Jo might leave", "Jo failed to leave", "Jo's
  leaving was fake"); §2.2: the UW scale is "[−3, 3] (certainly did not happen
  to certainly did)"; FactBank's annotations are "an epistemic modal {certain,
  probable, possible} and a polarity {+, −}".
- CoNLL-2010 (Farkas et al.) §3.1 hedge cue categories: "auxiliaries: may,
  might, can, would, should, could"; "verbs of hedging or verbs with
  speculative content: suggest, question, presume, suspect, indicate, suppose,
  seem, appear, favor"; "adjectives or adverbs: probable, likely, possible,
  unsure"; "conjunctions: or, and/or, either…or". §3.2 weasel categories add
  "qualifiers and superlatives: global, superior, excellent, immensely,
  legendary, best" and "elements expressing obviousness: clearly, obviously,
  arguably". The annotation strategy is the one this parser copies: "if we
  simply disregard the marked text span, the rest of the sentence can usually
  be used for extracting factual information (if there is any)".

Putting it together — signals → verdict. "Drop" means the sentence is reported
as *not checked* with the reason; "keep" means it proceeds to grounding.

| Signal (what to look for in `tags`/`chunks`/lexicon) | Verdict | Why (source) |
|---|---|---|
| Any `MD` inside a `VP` chunk (`should`, `will`, `could`, `might`, `must`) | **drop: modality/future** | PTB `MD`; FactBank modal particles → `PR`/`PS`, not `CT`; CoNLL-2010 auxiliaries list |
| Sentence-initial `VB` with no subject NP before it ("Add…", "Remove…", "Refactor…"), or `let's`/`we need to` | **drop: imperative/deontic** — but **queue as a post-change check** if it names a bound entity (§7) | PTB: `VB` "subsumes imperatives"; Claimify's baseline Factcheck-GPT labels "imperative statements" as non-claims |
| Sentence ends `?` or starts with a wh-word | **route to `symbolic ask`** | already a separate pipeline (`priv/question_grammar.pl`) |
| Hedge cue lexicon hit (`might`, `probably`, `likely`, `seems`, `appears`, `I think`, `possibly`) | **drop: hedged** | CoNLL-2010 §3.1 cue lists; FactBank `PS`/`PR` |
| Predicate is a comparative/evaluative (`JJR`/`RBR`/`JJS` as the complement of `is`/`makes`: "faster", "easier", "cleaner", "elegant") with no relation verb | **drop: evaluative** | ClaimBuster NFS ("opinions, beliefs"); CoNLL weasel "qualifiers and superlatives"; `reviewing-llm-output.md` §5 behavioral ceiling |
| Subject is `PRP` (`it`, `they`) or demonstrative `DT` (`this`, `that`) with no code entity in the subject NP | **needs decontextualization**: resolve against the previous *kept* sentence's single subject entity; if 0 or >1 candidates → **drop: ambiguous** | SAFE step 2; Choi PRONOUN/NP SWAP; Claimify referential ambiguity → "Cannot be disambiguated" |
| First-person `PRP` subject (`we`, `I`) | **drop: intent** | VeriScore excludes "advice … or subjective opinions"; ClaimBuster NFS |
| Sentence-initial discourse marker (`Then`, `Next`, `Also`, `First`, `Finally`; nlprule tags `then` as `RB`/`JJ`/`NN`) | **strip, keep rest** | Choi DM REMOVAL |
| Infinitival purpose clause `TO` + `VB` … after the main verb ("to validate the key") | **strip, keep rest** | FactBank §2.4.2 purpose clauses are intensional — the purpose is not asserted to have happened |
| Negation: `no longer` (nlprule: `DT` + `JJR`, chunk `ADVP`), `not`/`never`/`n't` (`RB`), `no` (`DT`) scoping the relation verb | **keep with polarity −** | FactBank polarity particles; `check_claim` already proves `\+ defines` for `removed` |
| Main verb is a lemma in the closed relation table (`call`, `invoke`, `delegate`, `depend`, `define`, `export`, `document`, `remove`, `exist`), present tense (`VBZ`/`VBP`) or passive present (`VBZ be` + `VBN`) | **keep** | this is the only shape the schema can answer; `symbolic_ask:relation_of/1` is the existing table |
| Main verb present-tense but *not* in the table ("handles retries", "validates input", "improves") | **drop: behavioral** — or hand to the optional LLM tier **only if** two bound entities are present | `reviewing-llm-output.md` §5; `check_claim` catch-all `unverifiable` |
| Past tense `VBD` ("we removed `foo/1`", "this broke") | **keep only** the `removed`/`no longer exists` shape (present-state consequence); otherwise **drop: narrative** | ClaimBuster found `VBD` the strongest *check-worthy* feature in debates, but a plan's past tense is a changelog, and only the resulting state is in the facts |
| `CD` immediately after `/` following an `UNKNOWN`/`NN` token | **arity marker → grounding** (§4) | the one `CD` that matters here; cf. ClaimBuster's `CD` feature |

## 4. Code-entity grounding and Markdown structure as the first filter

### 4.1 What counts as a code entity

The repo's rule is already strict: a function must be `Name/Arity`
(`priv/nlp_grammar.pl` `ident/1`; `symbolic_extract_llm:parse_ident/1`), and
the arity must resolve against `defines/5` (gate rule 3). The grounder's job
is to recover those shapes from nlprule's split tokens, using `has_space_before`
(`lib.rs:98`) to know which adjacent tokens were one surface word:

| Surface form | Tokens nlprule emits | Rejoin rule | Entity term |
|---|---|---|---|
| `write/2` | `write` `/` `2` (no spaces) | `NAME '/' CD` | `fun(write, 2)` |
| `dets:lookup/2` | `dets` `:` `lookup` `/` `2` | `NAME ':' NAME '/' CD` | `fun(dets, lookup, 2)` → `remote(dets, lookup, 2)` |
| `src/symbolic_fact_store.erl` | `src` `/` `symbolic_fact_store` `.` `erl` | `(NAME '/')* NAME '.' EXT` | `file('src/symbolic_fact_store.erl')` — matched by suffix, because `defines/5` stores absolute paths (`File = "/Users/…/src/symbolic_fact_store.erl"`, verified live) |
| `` `handle_call/3` `` | backtick, `handle_call`, `/`, `3`, backtick | code span (§4.2) takes priority over POS | `fun(handle_call, 3)` |
| `verifyPhoneCode`, `handle_query` | one `UNKNOWN` token / `handle` `_` `query` | `symbolic_ask:segments/4` (`src/symbolic_ask.erl:525-565`) | `name(verifyPhoneCode)` — **arity unbound → not provable** unless exactly one `defines/5` arity exists (the `resolve_strict` rule, lines 677-702) |

OpenIE systems make the same move with weaker tools. TextRunner (Banko et al.
2007 §2.2) tags "each word in each sentence with its most probable
part-of-speech … entities are found by identifying noun phrases using a
lightweight noun phrase chunker", and its learner rejects a tuple when
"Neither e_i nor e_j consist solely of a pronoun" (§2.1) — the same pronoun
rule as §3. Stanford OpenIE (Angeli et al. 2015) first produces "self-contained
clauses from longer sentences" and then applies "a small set of 14 hand-crafted
patterns … to segment an utterance into an open IE triple", stripping
modifiers only "when it is warranted" (Fig. 1: "Heinz Fischer of Austria visits
the US" → `(Heinz Fischer; visits; US)`; "No house cats have rabies should not
entail that cats have rabies"). On "Then `handle_call/3` calls `lookup/2` to
validate the key" an OpenIE-style extractor would yield a verb-centred triple
`(handle_call/3; calls; lookup/2)` plus a purpose triple `(handle_call/3; calls
… to validate; the key)`; the second has no schema target and is dropped. The
difference in this design is that the argument slots are typed by regex, not
by NP chunks — the chunker emits nothing for code tokens, so NP-chunk-based
argument finding would silently find no arguments. ClausIE's project page
states the same two-step shape ("first detects 'useful' pieces of information
expressed in a sentence, and then represents this information in terms of one
or more extractions"); the WWW'13 PDF was not reachable (§10).

### 4.2 Markdown structure before grammar

CommonMark §3: "We can think of a document as a sequence of blocks—structural
elements like paragraphs, block quotations, lists, headings, rules, and code
blocks … others (like headings and paragraphs) contain inline content—text,
links, emphasized text, images, code spans, and so on." Its parsing strategy is
two-phase: "first, the block structure of the document can be discerned;
second, text lines inside paragraphs, headings, and other block constructs
can be parsed for inline structure." The units that matter for a plan:

- **ATX heading** (§4.2): "a string of characters, parsed as inline content,
  between an opening sequence of 1–6 unescaped # characters". Headings name
  sections, not claims — they scope the pronoun-resolution window (§7) and
  are themselves never claims.
- **List item** (§5.2) and GFM **task list item** (GFM §5.3): "a list item
  where the first block in it is a paragraph which begins with a task list
  item marker"; the marker is "a left bracket ([), either a whitespace
  character or the letter x in either lowercase or uppercase, and then a right
  bracket (])". A checkbox is a *plan step*: imperative by construction, so it
  is never a present-tense claim, but it is the natural unit for a deferred
  post-change check (§7).
- **Fenced code block** (§4.5): "A code fence is a sequence of at least three
  consecutive backtick characters (`) or tildes (~)". FacTool's code domain
  treats exactly this as the claim unit, and this repo already re-parses it:
  `example_defines/5`/`example_calls/5` → `stale_doc_example/4`/`stale_doc_call/4`
  (`reviewing-llm-output.md` §1, §2.2). The parser should *not* run NLP over
  fence contents.
- **Code span** (§6.1; GFM §6.3): "A backtick string is a string of one or
  more backtick characters (`) that is neither preceded nor followed by a
  backtick"; a code span is delimited by matching-length backtick strings. An
  inline code span is the single strongest "this is a code entity" signal in
  LLM-written prose, stronger than any POS tag.
- **Paragraph** (§4.8): "A sequence of non-blank lines that cannot be
  interpreted as other kinds of blocks forms a paragraph."

The repo already has the block layer: `heading/4`, `section/4`, `paragraph/3`,
`list_item/4` (with `checked|unchecked|none`), `code_block/3`
([`prolog-schema.md`](prolog-schema.md) "Markdown structural facts"), and
`paragraph/3` deliberately includes list-item text. Live counts against this
repo's own docs: 2,207 `paragraph/3` facts and 6 checked task-list items. What
it does **not** have is the inline layer — code spans — because the
tree-sitter inline grammar is still undone
([`tree-sitter-markdown.md`](tree-sitter-markdown.md)). A code-span scanner is
a screenful of binary pattern matching, the §3 tier of
[`nlp-tooling.md`](nlp-tooling.md), and should run on each `paragraph/3` text
*before* nlprule so that a span's contents bypass tagging entirely.

So the first filter is structural and costs no model: take `paragraph/3`
texts (which already cover list items), skip `code_block/3` contents (handled
by `example_*`), note `list_item/4`'s `Checked`, and only then sentence-split.

## 5. Mapping kept claims onto the fact schema

The repo rule from `research-questions-to-prolog.md` §4: every function, arity
and file in the goal must be bound; relation words outside the inventory are
`unverifiable`. Per predicate (schema per [`prolog-schema.md`](prolog-schema.md),
derived rules per `.symbolic/rules.pl`):

| Schema target | English relation words (lemmas) | Arguments that must be bound | Goal shape | Polarity − |
|---|---|---|---|---|
| `defines/5` | `exist`, `be defined`, `be declared`, `live in`, `there is a function` | `F/A`; `File` optional qualifier | `defines(F, A, _, File, _)` (+ `sub_atom(File, _, _, 0, Suffix)` when a path is named) | `\+ defines(F, A, _, _, _)` — the existing `removed` shape |
| `export/4` (Erlang) | `be exported`, `be public` | `F/A` | `export(F, A, _, _)` | `\+ export(…)` |
| `calls/5` | `call`, `invoke`, `delegate to`, `depend on`, `run`, `hit`, `reach` (the `relation_of/1` table; `use` is a separate, looser relation there) | caller `F/A`, callee `G/B`; module optional | `calls(F, A, local(G,B), _, _) ; calls(F, A, remote(_,G,B), _, _)`; with module bound: `remote(M,G,B)` | `\+` both — scoped closed world |
| `doc/5` | `be documented`, `have a doc comment`, `have docs` | `F/A` | `doc(F, A, _, _, _)` | `undocumented/4` (exists in `rules.pl:40`) |
| `comment/3` | "a comment mentions X" | file + text | `comment(File, _, T), sub_text(T, …)` | evidence only |
| `heading/4`, `section/4` | "the X section", "under heading Y", "docs/foo.md has a section Y" | file + heading text | `heading(File, _, T, _), sub_text(T, …)` | evidence only — prose is not closed-world |
| `branch/5`, `real_complexity/4` | "X has N branches / decision points" | `F/A`, `N` | `real_complexity(F, A, _, N)` | — ("too complex" is evaluative → drop) |
| `callers/3`, `callees/2`, `fan_in/3`, `fan_out/3` | "N functions call X", "nothing calls X", "X is dead" | `F/A` (+ `N`) | `findall … length` | `fan_in(F, A, 0)` |
| `self_recursive/3` | "X is recursive" | `F/A` | `self_recursive(F, A, _)` | `\+` |
| `config_value/4` | "key K is set to V", "config K is V" | key path, value | `config_value(_, K, V, _)` | `\+` |
| `example_calls/5`, `example_defines/5` | (no words — a fenced block in the plan) | — | `stale_doc_call/4`, `stale_doc_example/4` | — |
| `text_search/2` | `be discussed`, `be mentioned`, `be covered` | word span | `text_search(Words, Hits)` | never a verdict (`ask` gate rule 2) |

Things the words can say that the schema cannot bind, which the mapper must
report as **unchecked residue** rather than silently drop: a location qualifier
without a predicate ("in the module header"), a callee named without arity
(`check_claim`'s own "arity elided by the prose" clause), a module without a
function ("calls into `dets`"), and any verb not in the table. WiCE's
`PARTIALLY-SUPPORTED` is the precedent for a claim that is half provable — the
output carries the proven part and the residue separately.

## 6. Proposed pipeline

Each stage states input → output and which engine runs it. Stages 0–3 and 5–6
are deterministic; stage 4 is the DCG; stage 7 is the only model.

```
plan.md
  │
  ▼ 0. BLOCKS   — tree-sitter-markdown (exists) + Erlang code-span scanner (new)
  │   out: unit(File, Line, Kind, Text, Spans)   Kind ∈ {paragraph, list_item(Checked), heading}
  │        code_block contents routed to example_calls/5 instead
  ▼ 1. SENTENCES — nlprule NIF (exists): sentence split + tags + chunks
  │   out: sent(Unit, Idx, Text, [token{text, tags, chunks, has_space_before, span}])
  ▼ 2. GROUND   — Erlang (reuse symbolic_ask:ident_candidates/segments): rejoin
  │   `/` `:` `.` splits; code spans override tags; regex-type each mention
  │   out: sent + [entity{kind ∈ {fun(Name,A), fun(M,Name,A), name(Name), file(Path)}, span}]
  │   drop if entities = []            → reason: no_code_entity
  ▼ 3. FACTUALITY GATE — Erlang, pure; the §3 table
  │   strip: discourse markers, TO+VB purpose clause
  │   drop:  MD in VP · imperative VB-initial · question (→ ask) · hedge cue ·
  │          evaluative predicate · first-person subject
  │   resolve: PRP/DT subject → previous kept sentence's single subject entity in the
  │          same block, else drop (ambiguous)
  │   out: norm(Entities, Lemmas, Polarity, Residue)  — a *normalized token stream*
  ▼ 4. RELATION — erlog DCG (priv/claim_grammar.pl, consulted, not asserted)
  │   grammar over normalized tokens: ident(_) lemma ident(_) | ident(_) be VBN-lemma (in file(_))? |
  │   ident(_) no_longer lemma ident(_) | …   (one rule per row of §5)
  │   out: claim(Rel, Args, Polarity, Residue, Sentence)   or unrecognized → stage 7 / unchecked
  ▼ 5. BIND     — erlog: the symbolic_ask gate (vocabulary · scoped closed world · arity)
  │   every fun/arity resolved against defines/5 (callees loosely, as ask does); file by suffix
  │   out: goal(Claim, PrologGoal)   or unchecked(reason)
  ▼ 6. PROVE    — erlog: check_claim/2 extended with the §5 rows
  │   out: verdict(Claim, true | false | unchecked(Reason), Evidence)
  ▼ 7. (optional) LLM — symbolic_extract_llm, closed verb enum, only for sentences that
      passed 2–3 and failed 4; its output re-enters at stage 5, never at 6
```

Why the DCG moves to stage 4: [`nlp-tooling.md`](nlp-tooling.md) §2 scopes DCGs
to "bounded vocabulary and a known set of relations". Raw English is not that;
the stage-3 output is. ACE makes the same bargain explicitly — "every ACE
sentence is a syntactically acceptable English sentence, but not every English
sentence is an ACE sentence", with function words fixed and content words from
a lexicon, and counter-examples "prefixed with `*` … not part of ACE" — and GF
states it bluntly: "Parsing takes a string into an abstract syntax tree.
Parsing something that is not in grammar will fail." CHAT-80 does it at the
word level: `check_word/2` (`prolog/chat80/chattop.pl`) prompts
`? ~w -> (!. to abort)` for any word not in the lexicon, and an unparseable
sentence falls through `process/1` to `failure :- format('I don''t
understand!~n')`. Island parsing (Carroll 1983) is the one classical technique
that *starts* from the reliable tokens — "can start at any point in the
transition network with a word match from anywhere in the input string …
working outwards to the left and right, adding words to each end of the
'island'" — which is exactly stage 2 → 4: the islands are the grounded
identifiers, and the grammar grows outward from them to the relation verb.
(Abney's 1991 chunking paper is the usual citation for "parse the easy pieces
first"; its PDF was not reachable, §10.)

### 6.1 Worked example

Input (a list item from a plan; functions are real, in
`src/symbolic_fact_store.erl`):

> We should refactor the write path so it is easier to test. Then `write/2`
> calls `delete_metadata/1` to clear stale metadata. The new helper will call
> `normalize_key/1` before storing anything. `write/2` is defined in
> `src/symbolic_fact_store.erl`. It no longer calls `dets:lookup/2` directly.
> This makes the hot path much faster. `write/2` is documented in the module
> header.
>
> - [ ] Remove `write_bundle/3`.

| # | Sentence | Stage that decides | Outcome | Prolog goal / reason |
|---|---|---|---|---|
| 1 | We should refactor the write path so it is easier to test. | 2 | **drop** | no code entity (`write path` is `NN NN`); also `should/MD`, `We/PRP`, `easier/JJR` |
| 2 | Then `write/2` calls `delete_metadata/1` to clear stale metadata. | 3 → 4 → 6 | **true** | strip `Then` (DM), strip `to clear …` (TO+VB purpose); `check_claim(svo(write/2, calls, delete_metadata/1), V)` — live: `V = true` (`calls/5` at line 34) |
| 3 | The new helper will call `normalize_key/1` before storing anything. | 3 | **drop: future** | `will/MD`; subject `The new helper` ungrounded; `normalize_key/1` has no `defines/5` fact, which is *expected* for a plan, not a finding |
| 4 | `write/2` is defined in `src/symbolic_fact_store.erl`. | 4 → 5 → 6 | **true** | `be/VBZ` + `define/VBN` + `in/IN` + `file(…)`; `defines(write, 2, _, File, _), sub_atom(File, _, _, 0, 'src/symbolic_fact_store.erl')` — live: line 21 |
| 5 | It no longer calls `dets:lookup/2` directly. | 3 → 4 → 6 | **true (polarity −)** | `It/PRP` → previous kept sentence (#4) has exactly one subject entity → `write/2`; `no/DT longer/JJR` (ADVP) → polarity −; remote callee; `\+ calls(write, 2, remote(dets, lookup, 2), _, _)` — live: no such fact (write/2's `dets` calls are `open_file/2`, `delete_all_objects/1`, `insert/2`, `sync/1`, `close/1`). Residue: "no longer" also asserts a *past* state that one scan cannot see (§7) |
| 6 | This makes the hot path much faster. | 2/3 | **drop: evaluative** | `This/DT` subject, no entity; `faster/JJR,RBR` complement |
| 7 | `write/2` is documented in the module header. | 4 → 6 | **false, with residue** | `doc(write, 2, _, _, _)` — live: **no fact**. Residue "in the module header" is unbound. Caveat for the reviewer: a comment run sits at lines 17–19 but a `-spec` on line 20 separates it from the definition, and `doc/5` requires the comment "immediately before a recognized definition node" (`prolog-schema.md`, `doc/5`); the verdict is "not in the facts", which the report must say rather than "undocumented" |
| 8 | `- [ ] Remove `write_bundle/3`.` | 0 → 3 | **drop now, queue** | `list_item(…, unchecked, …)` + imperative `Remove/VB`; records a deferred `removed(write_bundle/3)` to check after the change (§7) |

Output is the eight rows, not "5/8 = 62.5%": three verdicts (two true, one
false-with-residue), one negative-polarity true, four drops each with a
reason. Row 7 is the case §5 and `reviewing-llm-output.md` §5 both warn about
— a `false` that reads as "the doc is wrong" when the *fact base's* attribution
is the limit — and is why every verdict must carry its evidence and residue.

## 7. Open questions and risks

- **Decontextualization is the weakest link.** Claimify reports that 2.4–5.4%
  of sentences were "Cannot be disambiguated" even with an LLM; a
  one-sentence-back pronoun rule will refuse more. Rule proposed: a `PRP`/`DT`
  subject resolves only to the single subject entity of the immediately
  preceding *kept* sentence in the same block; headings and list-item
  boundaries reset the window (Claimify builds context from "p preceding
  sentences … and optional metadata (e.g., the header hierarchy in a
  Markdown-style answer)" §3.1). Anything else is `unchecked(ambiguous)`.
- **Coordination.** "`foo/1` and `bar/2` call `baz/0`" — nlprule gives `CC`;
  distribute only when every conjunct is a grounded entity of the same kind
  (WiCE's "Segment … into individual facts"; Claimify's structural ambiguity
  example "AI has advanced renewable energy and sustainable agriculture at
  Company A and Company B" shows why mixed-kind coordination must not be
  guessed). "`foo/1` calls `bar/2` and `baz/0`" distributes over the object.
- **Negation and change-of-state.** "no longer calls" asserts two things: a
  past call (unknowable from one scan) and a present absence (provable by
  `\+`). Keep the present half, mark the past half residue. FactBank's `CT-`
  is the target value; the scoped-closed-world rule says `\+ calls` is sound
  only for scanned files, so the verdict must name the scan scope
  (`symbolic_ask`'s `scope_answer/2`, `src/symbolic_ask.erl:171-200`, already
  degrades a negative yes/no to "unknown" when the scan is incomplete).
- **Future tense vs. present.** "will call" is dropped (§3). But plan documents
  are *mostly* future tense, so the useful product may be the **deferred
  claim set**: every dropped future/imperative sentence that names bound
  entities becomes a goal to run after the change lands ("the helper will call
  `normalize_key/1`" → `calls(_, _, local(normalize_key, 1), _, _)` later). That
  is `reviewing-llm-output.md` §6's plan/action observer, one claim at a time.
- **Arity-less names.** `lookup` tags as `NN`; without `/N` the gate cannot
  bind it unless `defines/5` holds exactly one arity. `symbolic_ask`'s
  `resolve_strict`/`resolve_loose` split (strict subjects, loose callees) is the
  right default; anything else is `unchecked(arity_unbound)`.
- **The tagger's ambiguity is not a bug to fix.** nlprule returns all
  alternatives (`calls` → `NNS, VBZ`). The design never needs the verb's tag;
  it needs the verb's *lemma* (`call`) — which nlprule also returns — and the
  presence/absence of `MD`, `PRP`, `JJR`, `TO`, which were unambiguous in the
  live run. If a later tagger version changes chunking, only §3's table rows
  that mention chunks need re-checking.
- **`doc/5` attribution** (row 7) is a schema limit the parser inherits; a
  "documented" claim that comes back `false` needs the evidence line "no
  `doc/5` fact; nearest preceding comment at line N" to be reviewable.
- **Scoring.** Core's finding that "obvious or repetitive subclaims"
  inflate FActScore applies directly: a plan that says "`write/2` exists" five
  times must not look five times more correct. Dedupe goals; never report a
  ratio.

## 8. Precision over recall: why abstaining is the correct output

The evidence that "unchecked" must be a first-class verdict, from the sources:

- FActScore §3.1: "FActScore considers precision but not recall, e.g., a model
  that abstains from answering too often or generates text with fewer facts
  may have a higher FActScore"; §3.3: `Irrelevant` is assigned "without a
  validation step" — the fact is never rated.
- SAFE §3 fn. 5: the relevance step "identifies statements that should not be
  rated"; fn. 7: irrelevant facts "should not be considered when evaluating
  factuality".
- VeriScore §2.3 combines `contradicted` and `inconclusive` into one
  `unsupported` bucket only *after* finding "very few claims directly
  contradicted" (§3.3: 2.8% contradicted vs 40% inconclusive) — i.e. most
  non-support is "could not tell", not "wrong". §3.1: "Unverifiable content …
  are ignored."
- Claimify §3.3: "If any ambiguity is unresolvable, the sentence is labeled
  'Cannot be disambiguated' and excluded … even if it has unambiguous,
  verifiable components." §6: removing Selection "caused the largest
  performance drop".
- Choi et al. §3.1: "When it is too challenging to decontextualize, it is
  classified into the INFEASIBLE category."
- This repo: `check_claim/2`'s catch-all `unverifiable`
  (`.symbolic/rules.pl:1833`) and the benchmarking doc's rule that the
  benchmark "reports `unverifiable` as its own bucket, never folded into
  `false`" ([`research-llm-judge-and-benchmarking.md`](research-llm-judge-and-benchmarking.md),
  recommendation bullets).

The asymmetry for a plan reviewer is the practical argument: a dropped
sentence costs nothing (the human reads it anyway), a wrong `false` costs
trust in every other verdict.

## 9. Relation to the existing tiers

| Piece | Today | In this design |
|---|---|---|
| `symbolic_analyze` / nlprule NIF | sentence split + tags | stage 1, unchanged |
| `symbolic_ask_nlprule:extract_frames/1` | question frames only | keep for questions; declaratives go to stages 2–6 |
| `symbolic_ask:ident_candidates/1`, `segments/4` | question entity rejoin | reused as stage 2 |
| `symbolic_extract:tokenize/1` | regex-reject raw words | replaced by stage 3's normalized stream for the plan path; the one-sentence CLI keeps working |
| `priv/nlp_grammar.pl` | 3 rules over raw words | superseded by a `claim_grammar.pl` over `ident(_)`/lemma tokens, one rule per §5 row; consulted, never asserted (`reviewing-llm-output.md` §3.1) |
| `symbolic_extract_llm` | fallback after DCG | stage 7, gated by stages 2–3 |
| `check_claim/2` | `calls`, `removed` | plus `defined_in`, `exported`, `documented`, remote callees, polarity |
| `ts_extract_markdown` facts | `paragraph/3`, `list_item/4`, `code_block/3` | stage 0 input; code spans added by a binary scanner |

## 10. What could not be verified (and is not claimed)

- Abney 1991, "Parsing by Chunks" — `vinartus.net/spa/90e.pdf` returned HTTP
  403 twice; no quote is used from it.
- ClausIE (Del Corro & Gemulla, WWW 2013) — the MPI PDF returned HTTP 403; only
  the project page's one-sentence description is quoted.
- FactBank is cited from the LREC 2008 paper (readable PDF) rather than the
  2009 *Language Resources and Evaluation* article, which is behind a login;
  the value table is the same eight values.
- BioScope's own paper was not fetched; its cue categories are taken from the
  CoNLL-2010 overview, which annotated on it.
- TextRunner: a secondary summary claimed a "more than five words" relation
  filter; it is not in the pages read and is not used.
- Nothing here was benchmarked. The seven-sentence run in §3 and the eight
  live goals in §6.1 are the only executions.

## References

- Min et al., "FActScore: Fine-grained Atomic Evaluation of Factual Precision
  in Long Form Text Generation", EMNLP 2023 — <https://arxiv.org/abs/2305.14251>
  (quotes from §3.1, §3.3, Table 1)
- Wei et al., "Long-form factuality in large language models", NeurIPS 2024 —
  <https://arxiv.org/abs/2403.18802> (§3, footnotes 5 and 7)
- Song, Kim, Iyyer, "VeriScore: Evaluating the factuality of verifiable claims
  in long-form text generation", 2024 — <https://arxiv.org/abs/2406.19276>
  (§2.1.1, §2.1.2, §2.3, §3.1, §3.3)
- Metropolitansky & Larson, "Towards Effective Extraction and Evaluation of
  Factual Claims" (Claimify), 2025 — <https://arxiv.org/abs/2502.10855>
  (§2.1, §3.1–3.4, §6, §7)
- Kamoi et al., "WiCE: Real-World Entailment for Claims in Wikipedia", EMNLP
  2023 — <https://arxiv.org/abs/2303.01432> (§2.1–2.3)
- Chern et al., "FacTool: Factuality Detection in Generative AI", 2023 —
  <https://arxiv.org/abs/2307.13528> (§3.1, §4.1, §4.2, §4.4, Table 2)
- Jiang et al., "Core: Robust Factual Precision with Informative Sub-Claim
  Identification", 2024 — <https://arxiv.org/abs/2407.03572> (abstract)
- Choi et al., "Decontextualization: Making Sentences Stand-Alone", TACL 2021
  — <https://arxiv.org/abs/2102.05169> (Def. 1, §3.1, §3.2)
- Hassan et al., "Toward Automated Fact-Checking: Detecting Check-worthy
  Factual Claims by ClaimBuster", KDD 2017 —
  <https://doi.org/10.1145/3097983.3098131> (§3.1, §3.3)
- Shaar et al., "Overview of the CLEF-2021 CheckThat! Lab Task 1 on
  Check-Worthiness Estimation in Tweets and Political Debates", CEUR-WS 2936 —
  <https://ceur-ws.org/Vol-2936/paper-28.pdf> (§2, §3)
- Farkas et al., "The CoNLL-2010 Shared Task: Learning to Detect Hedges and
  their Scope in Natural Language Text" — <https://aclanthology.org/W10-3001.pdf>
  (§1, §3.1, §3.2)
- Saurí & Pustejovsky, "From structure to interpretation: A double-layered
  annotation for event factuality" (FactBank), LREC 2008 —
  <https://www.cs.brandeis.edu/~roser/pubs/sauriPustejovsky_lrec08_2.pdf>
  (§2.1, §2.2 Table 1, §2.4.1, §2.4.2, §3.2)
- Rudinger, White, Van Durme, "Neural models of factuality", NAACL 2018 —
  <https://arxiv.org/abs/1804.02472> (§1, §2.1, §2.2, §3)
- Santorini, "Part-of-Speech Tagging Guidelines for the Penn Treebank Project",
  1990 — <https://catalog.ldc.upenn.edu/docs/LDC99T42/tagguid1.pdf> (§2)
- CommonMark Spec 0.31.2 — <https://spec.commonmark.org/0.31.2/> (§3, §4.2,
  §4.5, §4.8, §5.2, §6.1, Appendix "A parsing strategy")
- GitHub Flavored Markdown Spec — <https://github.github.com/gfm/> (§5.3, §6.3)
- Attempto Controlled English 6.7 construction rules —
  <http://attempto.ifi.uzh.ch/site/docs/ace/6.7/ace_constructionrules.html>
- Grammatical Framework tutorial —
  <https://www.grammaticalframework.org/doc/tutorial/gf-tutorial.html>
- CHAT-80 (Pereira & Warren; Wielemaker's packaging) —
  <https://github.com/JanWielemaker/chat80>, `prolog/chat80/chattop.pl`
  (`check_word/2`, `process/1`, `failure/0`)
- Angeli, Johnson Premkumar, Manning, "Leveraging Linguistic Structure For
  Open Domain Information Extraction", ACL 2015 —
  <https://aclanthology.org/P15-1034.pdf> (abstract, §1, Fig. 1, §3, §4)
- Banko et al., "Open Information Extraction from the Web", IJCAI 2007 —
  <https://www.ijcai.org/Proceedings/07/Papers/429.pdf> (§2.1, §2.2)
- ClausIE project page —
  <https://www.mpi-inf.mpg.de/departments/databases-and-information-systems/software/clausie>
- Carroll, "An Island Parsing Interpreter for the Full Augmented Transition
  Network Formalism", EACL 1983 — <https://aclanthology.org/E83-1017.pdf> (§I.A)
- Repo: [`reviewing-llm-output.md`](reviewing-llm-output.md),
  [`research-questions-to-prolog.md`](research-questions-to-prolog.md),
  [`nlp-tooling.md`](nlp-tooling.md), [`nlprule-analysis.md`](nlprule-analysis.md),
  [`rust-nlp-landscape.md`](rust-nlp-landscape.md),
  [`prolog-schema.md`](prolog-schema.md),
  [`research-llm-judge-and-benchmarking.md`](research-llm-judge-and-benchmarking.md),
  `src/symbolic_serve.erl`, `src/symbolic_analyze.erl`,
  `src/symbolic_ask_nlprule.erl`, `src/symbolic_ask.erl`,
  `src/symbolic_extract.erl`, `src/symbolic_extract_llm.erl`,
  `native/symbolic_nlprule/src/lib.rs`, `priv/nlp_grammar.pl`,
  `priv/question_grammar.pl`, `.symbolic/rules.pl`
