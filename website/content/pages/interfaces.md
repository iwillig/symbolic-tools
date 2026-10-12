Title: CLI and MCP interfaces
Slug: interfaces
Save_as: interfaces.html
Subtitle: Compare codebase analysis from the CLI and an MCP client.

The CLI can persist facts in a `.dets` file; the MCP server keeps parsed facts
in memory. They share several capabilities, but their command and tool sets
are not identical.

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
symbolic parse . -db facts.dets
```

MCP: call `parse` with `path: "."`.

## Query

```sh
symbolic query -db facts.dets "defines(F, A, _, _, _)"
```

MCP: call `query` with the same `goal`.

## Ask

```sh
symbolic ask -db facts.dets "who calls capitalize/1?"
```

MCP: call `ask` with the same `question`.

## Overview

```sh
symbolic overview -db facts.dets
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
symbolic check -db facts.dets "foo/1 calls bar/2"
```

MCP: call `check` with the same `sentence` after `parse`.

## Search

```sh
symbolic search -db facts.dets "error handling"
```

MCP: call `search` with the same `query` after `parse`.
