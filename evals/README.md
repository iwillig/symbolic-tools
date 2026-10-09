# Symbolic MCP promptfoo evals

Evaluates whether an LLM routes questions correctly to the `symbolic` MCP
server's four tools (`mcp__symbolic__parse`, `mcp__symbolic__query`,
`mcp__symbolic__overview`, `mcp__symbolic__ask`).

The tools are never executed. The eval checks, in a single turn, which tool
the model *requests* and whether its arguments are well-formed:

- codebase questions must produce a symbolic tool call
  (call-graph and definition questions must carry a Prolog goal over the
  real fact schemas — `calls/5`, `defines/5` — not a hallucinated predicate),
- cache-state questions must produce `overview`,
- a fresh session must load the codebase with `parse` before querying,
- general knowledge questions must produce no tool call at all.

## Setup

promptfoo is installed via Homebrew (`brew install promptfoo`). The provider
is a local OpenAI-compatible server (llama.cpp `llama-server`) at
`http://localhost:8080/v1`. No API key is needed; the configs pass a
`apiKeyRequired: false` flag. Start the server with `--jinja` so it
accepts the `tools` field:

```sh
llama-server -m <model.gguf> --jinja -c 16384 --port 8080
```

If the server runs on another port, edit `apiBaseUrl` in each config.
The provider id `openai:chat:local` names the model `local`; llama-server
ignores the model name in single-model mode.

## System prompt

Every eval loads `../QWEN-SYSTEM.md` into the first system message
(`defaultTest.vars.system: file://../QWEN-SYSTEM.md` in each config; the
prompt files reference it as `{{system}}`). Each prompt file adds a second
system message with the scenario state (`<session>`: cached or fresh;
`<task>` for claims). The eval loop:

1. Run an eval. Read the failing row's tool call.
2. Add or change one rule in `QWEN-SYSTEM.md`. Bump `<version>`.
3. Rerun. Keep the rule if the row passes and nothing else regresses.

## Run

```sh
cd evals
promptfoo eval -c promptfooconfig.yaml --no-cache --output mcp-output.json
```

## Layout

- `promptfooconfig.yaml` — the eval (two scenario prompts x 7 test cases)
- `promptfooconfig-iterate.yaml` — A/B/C/D experiment over the query tool's doc
  string (no schema / fixed example only / condensed schema / server text);
  run with `--repeat 3` for signal
- `promptfooconfig-claims.yaml` — claim-verification eval: 10 codebase claims
  mined from real Claude Code session traces, each with provenance (trace file
  + line) and ground truth proven against the current fact base before the
  config was written; run the same way, output `claims-output.json`
- `../QWEN-SYSTEM.md` — the shared system prompt under iteration
- `prompts/symbolic_mcp_cached.json` — scenario: codebase already cached
- `prompts/symbolic_mcp_fresh.json` — scenario: fresh session, load first
- `prompts/symbolic_mcp_claims.json` — scenario: verify a past-session claim
  by translating it into one goal

## Claim-verification eval

`promptfooconfig-claims.yaml` replays claims an LLM made about this repository
in past sessions (`~/.claude/projects/<slug>/*.jsonl`), several of which have
gone stale or were wrong when re-proved today (the ground-truth ledger is in
the config's header comments). The eval checks that the model picks the
predicate that could decide each claim - `defines`, `callers`,
`truly_uncalled`, `duplicate_name`, `real_complexity`, `heading` - and names
the claim's entities in the goal. It does not yet execute the goals; the next
tier is to run them against the live cache and compare the bound answers to
the ledger.

## First-run findings (Qwen 3.8-27B, 2026-10-09: 9/10)

Two failure modes showed up on the first run of `promptfooconfig-claims.yaml`.
Both are properties of goal *writing*, not routing - the model picked the
right tool all ten times - and both mark the exact line where the routing
tier stops being able to score a goal.

### Finding 1: an unbound schema probe is not verification

For the doc-structure claim ("sections '5. Eval-framework data models' and
'9. BEAM ecosystem' exist in docs/research-llm-judge-and-benchmarking.md"),
the model emitted a fully unbound goal:

```
heading(File, A, B, C)
```

That is a schema-discovery probe. It proves nothing about the claim: it
succeeds for any document with any heading, so its solution set cannot
confirm or refute the named sections. The javascript assertion rejected it
because the goal named no entity from the claim (`BEAM` / `Eval-framework`).
This is the same distinction the system prompt's rules draw - a verification
goal must bind the claim's entities, because the proof must fail when the
claim is false. A goal that succeeds regardless of the claim's truth is not
a check.

Scoring rule this sets: for each claim test, the goal must mention the
claim's named functions/arities or its distinctive literals, not just the
right predicate functor. All ten javascript assertions in the config encode
this rule; finding 1 is the first observed miss.

### Finding 2: argument order is invisible to shape checks

For the handle_call/3 complexity claim, the model emitted:

```
real_complexity(handle_call, 3, Complexity, File)
```

The real predicate is `real_complexity(Name, Arity, File, Complexity)` - the
last two arguments are swapped. With both variables unbound the goal still
proves correctly (unification binds them to the right values regardless of
the variable names), so the shape check passes and nothing is wrong *yet*.
The hazard is one step away: the moment a model binds the claimed value to
check the trace's number - `real_complexity(handle_call, 3, 16, File)` -
the swapped order turns a true claim into a silent refutation (the engine
looks for a file named `16`), and the routing tier has no way to see it.

Verified ground truth for that specific goal, from the current fact base:
`real_complexity(handle_call, 3, File, C)` binds prolog_session.erl to 10,
prolog_session_registry.erl to 4, and symbolic_codebase.erl to 18 - the
trace's "16" was already stale, which is exactly the kind of number a
bound-goal tier would catch.

Both findings point at the same next tier: execute the goals against the
live cache and score the bound answers against the ground-truth ledger.
Finding 1 disappears at that tier automatically (an unbound probe returns
noise, not the ledger's answer); finding 2 only becomes *visible* there,
because a swapped-argument goal with a bound value fails to prove or binds
absurd values.

## Keeping it honest

The tool descriptions in `promptfooconfig.yaml` mirror the real MCP tool
schemas (see `docs/prolog-schema.md` and the tool descriptions in the
server's own prompt). When those change, update the descriptions here or
the eval measures routing against a schema the server no longer has.
