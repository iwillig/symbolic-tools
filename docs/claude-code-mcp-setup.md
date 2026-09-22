# Registering `symbolic serve` with Claude Code

How to make the `symbolic` MCP server (`src/symbolic_serve.erl`, see
[`erlang-mcp-design.md`](erlang-mcp-design.md)) available to Claude Code
whenever this repo is opened, for every teammate who clones it.

## 1. Prerequisite: build the release

The registered command points at the release binary, not the raw source, so
build it first (and any time `src/*.erl` changes):

```bash
rebar3 release
```

This produces `_build/default/rel/symbolic_tools/bin/symbolic` — the wrapper
script that puts the release's `lib/*/ebin` on the code path and runs
`symbolic_cli:main/1` (see `scripts/symbolic`; running that script directly
from the repo root instead of from inside the built release fails with
`{undef, ...}` — there's no top-level `lib/` here, only under `_build/`).

## 2. Register the server

```bash
claude mcp add symbolic -s project -- '${CLAUDE_PROJECT_DIR}/_build/default/rel/symbolic_tools/bin/symbolic' serve
```

Two things matter about this exact command:

- **`-s project`** writes to `.mcp.json` at the repo root instead of your
  personal, machine-local config — `.mcp.json` is meant to be committed, so
  every teammate who clones the repo and opens it in Claude Code gets this
  server automatically (after a one-time approval prompt — see §4).
- **The single quotes around the path are required.** `${CLAUDE_PROJECT_DIR}`
  must reach `claude mcp add` as a literal string, not get expanded by your
  shell first (it isn't a real shell variable — it's a placeholder Claude
  Code substitutes at server-launch time, resolving to this repo's root
  regardless of whose machine it's cloned onto or what directory `claude` was
  started from). Without the quotes, an empty/wrong path gets written instead.

This writes:

```json
{
  "mcpServers": {
    "symbolic": {
      "type": "stdio",
      "command": "${CLAUDE_PROJECT_DIR}/_build/default/rel/symbolic_tools/bin/symbolic",
      "args": ["serve"],
      "env": {}
    }
  }
}
```

Commit `.mcp.json`.

## 3. Verify

```bash
claude mcp get symbolic
```

`claude mcp list`'s health check, run from a plain shell, warns
`Missing environment variables: CLAUDE_PROJECT_DIR` — expected outside a live
session, since that variable is only injected into the spawned server's
environment by Claude Code itself, at launch, inside a project it's actually
running against. It resolves once you actually open this project (§4).

## 4. Approve it inside Claude Code

A project-scoped `.mcp.json` server needs one-time approval per machine. Run
`claude` from this repo, then `/mcp` to see `symbolic` connect and list its
three tools (`parse`, `query`, `overview`).

## 5. Debugging

`serve`'s stdout is the MCP JSON-RPC transport — nothing is ever printed
there. All logging goes to
`~/Library/Logs/symbolic/serve.log` (macOS; XDG-based path on Linux, via
`filename:basedir(user_log, "symbolic")`) — tail that file if a tool call
misbehaves.

## 6. Removing it

```bash
claude mcp remove symbolic -s project
```
