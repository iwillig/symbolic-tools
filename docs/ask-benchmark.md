# ASK quality benchmark

`test/fixtures/ask-benchmark.json` is a small, manually curated, source-checked regression set. Each case records its intended catalog operation, typed slots, expected status and answer, and expected source citations. It uses the real `sample.ts` fixture and scans `src/` for project examples, plus small synthetic fact sets for overloaded names and relation-word identifiers.

Run it with:

```sh
rebar3 eunit --module=symbolic_ask_benchmark_tests
```

The benchmark reports four independent checks per case:

- **Intent:** the interpreter's selected catalog operation matches the label. `symbolic_ask:ask_detailed/3` exposes this trace only to benchmark and diagnostic callers; normal CLI/MCP answer maps are unchanged.
- **Slots:** returned fact witnesses agree with the labelled entities, or an ambiguity response returns the labelled function candidates. Cases with no witness (for example a negative answer) and prose-query spans are marked not applicable for this check.
- **Answer:** status, answer type, and value match the expected result. The suite includes false, unknown, unverifiable, ambiguous, and unrecognized outcomes.
- **Evidence:** source fact kinds, file names, and lines match the curated citations exactly; an empty expected citation list remains distinct from a false claim's semantic meaning.

The set is intentionally small and reviewable, not a statistical accuracy claim or a substitute for independent expert review. Add cases only with a human-verified expected operation, slot assignment, answer state, and citation. Include paraphrases, overloads, wrong arities, absent facts, incomplete scans, and similar identifiers when they expose a regression.
