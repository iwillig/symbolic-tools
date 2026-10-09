Title: symbolic-tools
Slug: home
Save_as: index.html
URL:
Subtitle: Turn a codebase into a Prolog fact base an agent can query and get proven answers from.

## Introduction

Symbolic Tools is a collection of tools designed to help humans
improve and manage LLMs. It does this by combining elements of
Symbolic AI and Natural Language Processing to give human users of LLM
agents more deterministic and reliable ways of verifying LLMs and LLM
assumptions.

Symbolic Tools is designed only to work with code bases with a focus
on TypeScript, Erlang and Rust. Symbolic Tools also supports markdown
files and can parse the code blocks in those markdown files.

Symbolic Tools is implemented as a MCP server and a collection of
system prompts/skills designed to help LLM’s use that MCP Server
correctly.

## Get started {: #get-started }

### Install via homebrew

```sh
brew tap iwillig/symbolic-tools https://github.com/iwillig/symbolic-tools
brew trust iwillig/symbolic-tools
brew install symbolic-tools
```

### Install in claude code

```sh
claude mcp add symbolic -- symbolic serve
```

`/mcp` inside Claude Code shows `symbolic` connected. It provides
`parse`, `query`, `ask`, `overview`, `extract`, `check`, and `search`.


### Run Claude Custom System Prompt

```sh
claude --system-prompt-file SYSTEM.md
```

### Configuration

Create `.symbolic/config.json` to define the project paths.

```json
{
  "paths": ["src", "test", "docs"]
}
```

Symbolic scans Erlang, Rust, TypeScript, Bash, Markdown, TOML, and JSON.

## Basic usage

The CLI stores facts in `facts.dets`. The MCP server keeps the same facts
in memory. Each CLI command below has an MCP equivalent.

### Parse a project

```sh
symbolic parse . -db facts.dets
```

The CLI and MCP `parse` return a summary.

```json
{
  "ok": {
    "files": 14,
    "languages": ["bash", "json", "markdown", "rust", "toml", "typescript"],
    "total_facts": 386
  }
}
```

### Prove a code relationship

```sh
symbolic query -db facts.dets "calls(shout, 1, local(capitalize, 1), File, Line)"
```

The CLI prints `Yes.` when the goal succeeds. MCP `query` returns bindings.

```json
{
  "count": 1,
  "limit": 50,
  "truncated": false,
  "solutions": [
    {
      "File": "/absolute/path/test/fixtures/sample.ts",
      "Line": 19
    }
  ]
}
```

### Search code and documentation text

```sh
symbolic search -db facts.dets "exclamation"
```

The command returns ranked JSON results.

```json
[
  {
    "file": "test/fixtures/sample.ts",
    "kind": "comment",
    "line": 15,
    "score": 1.945006415699314,
    "text": "Shouts a word by capitalizing it and adding an exclamation mark."
  }
]
```

MCP `search` uses the same query after MCP `parse`.

### Ask without writing Prolog

```sh
symbolic ask -db facts.dets "who calls capitalize/1?"
```

MCP `ask` returns shaped JSON for the same question.

```json
{
  "ok": {
    "type": "enumerate",
    "answer": ["shout/1"]
  }
}
```

See [CLI and MCP parity](interfaces.html) for all paired commands.

## Status {: #status }

Early implementation. Under active development. See the
[GitHub repository](https://github.com/iwillig/symbolic-tools) for the
full README, the Prolog fact schema, and the rules library.
