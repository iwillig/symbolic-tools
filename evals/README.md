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
is HuggingFace's OpenAI-compatible chat endpoint (inference provider
pinned to `novita`); auth comes from the `HF_TOKEN` environment variable.

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
- `prompts/symbolic_mcp_cached.json` — system prompt: codebase already cached
- `prompts/symbolic_mcp_fresh.json` — system prompt: fresh session, load first

## Keeping it honest

The tool descriptions in `promptfooconfig.yaml` mirror the real MCP tool
schemas (see `docs/prolog-schema.md` and the tool descriptions in the
server's own prompt). When those change, update the descriptions here or
the eval measures routing against a schema the server no longer has.
