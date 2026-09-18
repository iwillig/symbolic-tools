# Symbolic Tools

A set of tools designed to help LLM agents work with logic programming.
They build a Prolog database from your codebase and let the agent reason
over it.

The Prolog engine is [erlog](https://github.com/rvirding/erlog), an
implementation of Prolog written in Erlang. It runs **in-process on the
BEAM** — there is no separate Prolog compiler or subprocess; session
isolation comes from Erlang process isolation, not an OS boundary.

Inspired by the [Chiasmus MCP Server](https://github.com/yogthos/chiasmus).

## Tools

- **MCP server** — exposes the code-graph and Prolog reasoning tools over
  the Model Context Protocol, so an LLM agent can consult the Prolog
  database and query it.

## Usage

```sh
symbolic --help
symbolic mcp
symbolic mcp --help
```


## Install

Symbolic tools is written in Erlang and built with rebar3.

```sh
brew install erlang rebar3
rebar3 compile
```

## Development

Dependencies:

- [rebar3](https://rebar3.org/) — build tool
- [erlog](https://github.com/rvirding/erlog) — the Prolog engine (runs in-process on the BEAM)
- [erl_mcp](https://github.com/otakup0pe/erl_mcp) — MCP server framework
