# Research: using Pi traces to improve natural-language `ask`

**Status:** research and an offline frame-extraction prototype; production `ask` behavior is unchanged.
**Reviewed:** 2026-10-10.

## Finding

Pi's local session traces are a useful source of *candidate examples* for an NL-to-Prolog extractor, but they are not a gold training set. They record what the agent tried, not whether the user intended that goal or whether the resulting answer was correct. Use them to discover phrasing and coverage gaps, then curate and verify examples before adding them to tests or rules.

The current `ask` path already translates a bounded set of questions and has a statistical fallback. The fallback calls `symbolic_nlp:tag/1`, maps tags to bounded relation templates, resolves identifiers, applies the verifiability gate, and reuses the existing proof/answer path (`src/symbolic_ask.erl`; see also [`research-questions-to-prolog.md`](research-questions-to-prolog.md) and [`PLAN-statistical-nlp-tier.md`](../PLAN-statistical-nlp-tier.md)). The new nlprule analyzer is **not currently part of that path**. Its POS alternatives and chunks could be evaluated as additional features, but they do not independently provide semantic relations or arbitrary Prolog goals.

## Trace review

I reviewed the active branches of the local Pi sessions for this repository only, using `SessionManager.getBranch()` from the installed `@earendil-works/pi-coding-agent` 1.1.0 package. The scope was 34 JSONL session files (2026-09-18 through 2026-10-09), with 270 user messages on active branches. No raw conversation text, identifiers, or tool arguments are reproduced here.

Aggregate observations:

| Signal | Count | What it says (and does not say) |
|---|---:|---|
| `mcp__symbolic__query` calls | 229 | A large pool of candidate goals; many are exploratory/code-investigation queries, not direct NL translations. |
| `mcp__symbolic__ask` calls | 35 | Existing bounded question handling is used in real sessions. |
| Ask results with answer/evidence shapes | 24 | 7 yes/no, 7 enumerate, 4 count, 6 prose. Shape success is not proof of semantic correctness. |
| Ask results marked unverifiable | 3 | The gate surfaced entity/claim uncertainty rather than returning a confident proof. |
| Ask errors | 8 | 7 were unrecognized phrasing; one was another error. These are useful coverage-review candidates, not proof that the parser should accept every phrase. |

Among the 35 ask inputs, 24 contained a form of “call”; 5 contained “how many”; 6 used prose-location wording; and 3 asked whether something was defined. These categories overlap. The error sample included call-related and return-related wording, which suggests reviewing relation/phrase coverage, but the sample is too small to justify a grammar change by itself.

### Reliability limits

- An assistant's `toolCall.arguments.goal` is a weak label: the agent may have guessed the wrong predicate, arity, or answer variable.
- A successful Prolog call only proves that the goal executed. It does not prove that the goal represents the user's question.
- A non-error answer, including `false` or an empty list, is not evidence that the translation is right.
- Follow-up user corrections or explicit confirmations are stronger labels, but silence is not confirmation.
- Tool calls made while implementing/debugging Symbolic must not be mistaken for user-facing NL-to-goal examples.
- Counts above describe one project-specific local trace slice. They are not population-level usage statistics.

## Pi trace format and safe extraction

Pi stores sessions as JSONL under `~/.pi/agent/sessions/--<encoded-cwd>--/`. Entries form a tree through `id` and `parentId`; branches can preserve abandoned turns. Assistant message content can contain `toolCall` blocks, while `toolResult` entries correlate by `toolCallId`. Compaction, context edits, and branch summaries can change which history is active or model-visible.

For repeatable review:

1. Use Pi's `SessionManager` (`getBranch()` / `buildSessionProjection()`) to select a branch; do not treat file order as one linear conversation.
2. Pair each assistant tool call with its `toolResult` by ID. Keep the preceding user request and intervening assistant/tool events as provenance.
3. Limit discovery to an explicitly selected project/session directory. Do not scan all of `~/.pi/agent/sessions` by default.
4. Keep raw traces local and out of Git. They can contain source text, paths, secrets, or personal data. Redact or replace identifiers in any examples; check in only deliberately curated, approved fixtures.
5. Store provenance IDs/hashes locally if needed for audit, not complete private prompts or tool output in a public corpus.

A later mining script should emit counts and a redacted review queue by default. Any command that exports raw examples should require an explicit opt-in and destination.

## Recommended extractor development path

1. **Build a trace review set, not a training dump.** Select user turns that clearly ask a question about the scanned codebase. Exclude turns whose goal is implementation, debugging, or an exploratory follow-up unless they are explicitly labeled as such.
2. **Label the meaning, not just the generated goal.** For each curated case record: normalized question, requested answer kind (yes/no, enumerate, count, prose/evidence), relation, subject/object entity spans, explicit arities, expected gate result, and a verified Prolog AST. Mark provenance separately as `user-confirmed`, `manually-verified`, or `agent-proposed`.
3. **Keep extraction schema-bounded.** Map utterances to a small frame such as `question(Type, Relation, Subject, Object, Arity)`; map that frame to known predicate templates and fact arities. Do not evaluate model- or user-generated Prolog text directly.
4. **Preserve the existing trust boundary.** Run entity resolution and the existing strict/loose arity and relation gates before proof. Return `unrecognized` or `unverifiable` when the relation, entity, or arity cannot be resolved. Do not turn absence from prose search into a false structural claim.
5. **Evaluate nlprule as a feature, not as a semantic parser.** Compare the current tagger-only path with an adapter that supplies nlprule POS alternatives/chunks. Keep ambiguous tags as alternatives rather than blindly choosing the first. Measure whether chunk boundaries improve entity extraction or relation mapping on the curated set.
6. **Use session-level held-out evaluation.** Split train/dev/test by session, not by individual message, to avoid near-duplicate turns leaking across splits. Compare exact relation/frame accuracy, entity+arity accuracy, answer-type accuracy, gate/abstention correctness, and coverage. Report false-answer rate separately from parse coverage.
7. **Add only curated regressions.** Put approved synthetic or anonymized examples in EUnit fixtures. Keep private raw traces outside the repository.

A sensible first milestone is a read-only trace miner plus a small hand-reviewed scorecard for the question shapes already covered by `ask`. Only after that baseline should nlprule be wired into the fallback. If the traces show requests outside the current fact schema, add explicit relation/schema support first; better NLP cannot make unavailable facts answerable.

## Offline prototype

The approved prototype lives in `symbolic_ask_nlprule:extract_frames/1` and `extract_json_frames/1`. It accepts the decoded map returned by `symbolic_analyze:run_result/1`, invokes the existing bounded frame mapper per sentence, and returns recognized frames with the source sentence index and original token-analysis records. `extract_json_frames/1` serializes each candidate as a JSON-ready object with `answer_type`, `relation`, `arguments`, optional `answer_slot`, source sentence text, sentence index, and annotated tokens. These are candidate frames only: no Prolog string is constructed, no query is executed, and `symbolic_ask` is not wired to this module. Unknown shapes return no candidates.

The first sample-based smoke run generated `yes_no/calls`, `enumerate/callers_of`, and `prose` frames from nlprule output, and abstained on an unsupported `why ... cause ...` question. The JSON adapter emits ordinary binary-key Erlang maps accepted by `jsx:encode/1`. It preserves POS alternatives, chunk labels, and spans for inspection, but relation recognition still comes from the existing closed lexical mapper; this prototype does **not yet establish** that nlprule POS/chunk features improve accuracy. That is the next comparison to make against the current `symbolic_nlp` fallback using the curated trace scorecard. An LLM may consume these objects to propose a schema-bounded goal, but its output must still pass entity/arity checks and validation before proof.

## Primary sources

- Pi, **Session File Format**: JSONL entry tree, branch/compaction behavior, and active-context construction: <https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/session-format.md>
- Pi, **Message Types**: `ToolCall` arguments and `ToolResult` fields: <https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/message-types.md>
- Pi, **SessionManager source**: branch traversal and context projection API: <https://github.com/earendil-works/pi/blob/main/packages/coding-agent/src/core/session-manager.ts>
- This repository's [`symbolic_ask.erl`](../src/symbolic_ask.erl), [`question_grammar.pl`](../priv/question_grammar.pl), [`research-questions-to-prolog.md`](research-questions-to-prolog.md), and [`PLAN-statistical-nlp-tier.md`](../PLAN-statistical-nlp-tier.md) define the current extractor and its validation boundary.
