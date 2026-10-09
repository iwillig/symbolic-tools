Title: CLI and MCP parity
Slug: interfaces
Save_as: interfaces.html
Subtitle: Run the same codebase analysis from a terminal or an MCP client.

The CLI stores facts in a `.dets` file. The MCP server stores facts in memory.
Both interfaces support parse, query, ask, overview, extract, check, and search.

## Parse

```sh
symbolic parse . -db facts.dets
```

MCP: call `parse` with `path: "."`.

## Query

```sh
symbolic query -db facts.dets "defines(F, A, _, _, _")
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
