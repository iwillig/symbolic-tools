Title: CLI and MCP interfaces
Slug: interfaces
Save_as: interfaces.html
Subtitle: Compare codebase analysis from the CLI and an MCP client.

CLI and MCP `parse` take no arguments. They scan the paths in the project
`.symbolic/config.json`; when it sets `database`, both write to the same
`.dets` file. CLI query commands use that configured database by default; an
explicit `-db` overrides it. MCP queries use the in-memory snapshot from the
last successful `parse`, so parse again after a CLI update to refresh MCP.
Start one MCP server from each project directory. The interfaces share
capabilities, but their command and tool sets are not identical.

| Capability | CLI | MCP |
|---|---|---|
| Parse a codebase | `parse` | `parse` |
| Prove a Prolog goal | `query` | `query` |
| Ask a bounded English question | `ask` | `ask` |
| Inspect fact counts/cache state | `overview` | `overview` |
| Extract a claim | `extract` | `extract` |
| Check a claim against facts | `check` | `check` |
| Search prose facts | `search` | `search` |
| Analyze English text | `analyze` | `analyze_text` |
| Start the MCP server | `serve` | — |

The CLI's `analyze` command returns sentence and token analysis. MCP's
`analyze_text` also returns bounded query-frame suggestions; these are
candidates, not verified claims. `serve` is a CLI launcher for the MCP server,
not an MCP tool.

## Parse

```sh
symbolic parse
```

MCP: call `parse` with no arguments. Start the server from the project directory.

## Query

```sh
symbolic query "defines(F, A, _, _, _)"
```

MCP: call `query` with the same `goal`.

## Ask

```sh
symbolic ask "who calls capitalize/1?"
symbolic ask -catalog
```

MCP: call `ask` with the same `question`; use `ask_catalog` (no arguments) to
discover the supported operations and their evidence contracts. See [Using
ask](ask.html) for examples of source citations, file-scoped questions, counts,
and incomplete-scan outcomes.

## Overview

```sh
symbolic overview
```

MCP: call `overview` after `parse`.

The CLI reports persisted fact counts. MCP reports its current cache state.

## Extract

```sh
symbolic extract "foo/1 calls bar/2"
```

MCP: call `extract` with the same `sentence`.

## Check

```sh
symbolic check "foo/1 calls bar/2"
```

MCP: call `check` with the same `sentence` after `parse`.

## Search

```sh
symbolic search "error handling"
```

MCP: call `search` with the same `query` after `parse`.
