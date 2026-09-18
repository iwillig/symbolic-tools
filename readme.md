# Symbolic Tools

A command-line tool (and MCP server) that gives LLM agents — and humans —
a **Prolog database and query interpreter for a software codebase**,
instead of a chat log full of grep results and re-read files.

`symbolic` walks your source tree, extracts facts about it (function and
type definitions, call sites, imports) with [tree-sitter](https://tree-sitter.github.io/tree-sitter/),
and loads those facts into an in-process Prolog engine. From there, an
agent — or you — can ask a real logical question ("what calls this
function," "what does this module depend on") and get an answer produced
by unification and resolution, not by pattern-matching over text.

**Status: early implementation.** The core Prolog engine (`prolog_session`,
over `erlog`), both CLI commands (`query`, `parse` — tree-sitter
extraction for Erlang and TypeScript), and the MCP server (`serve`, over
`erlmcp`) all work end-to-end, via `rebar3 release` (see Install) —
verified for `serve` with a real stdio JSON-RPC round trip: start a
session, consult a program, query it, get bindings back.

## Why

Recent research shows that giving a small LLM a **Prolog database and
interpreter as a tool** — rather than asking it to reason step-by-step in
free text — produces large, measurable accuracy gains on problems that
need multi-step logical correctness, even for math word problems the model
is otherwise mediocre at:

- ["Training Language Models to Use Prolog as a
  Tool"](https://arxiv.org/abs/2512.07407) (Mellgren, Schneider-Kamp,
  Galke Poech) — RL-training a 3B model to write Prolog and delegate
  execution to a real interpreter beats supervised fine-tuning by a wide
  margin, and the resulting agentic repair loop generalizes better than
  single-shot generation.
- ["LoRP: LLM-based Logical Reasoning via
  Prolog"](https://www.sciencedirect.com/science/article/abs/pii/S0950705125011815)
  (*Knowledge-Based Systems*, 2025) — translating a natural-language query
  into Prolog and delegating the actual proof to SWI-Prolog outperforms
  having the LLM reason in free text, across multiple model architectures.

`symbolic-tools` applies the same idea to **software codebases** instead
of math word problems: build the Prolog fact base ahead of time from the
actual source, and let both an LLM agent and a human ask it questions with
the same logical rigor those papers found for arithmetic. See
`docs/grpo-prolog-tool.md` and `docs/lorp-approach.md` for the full
write-ups, and `docs/curt-approach.md` for how the same Prolog-native
approach extends to parsing natural language itself into facts.

## How it works

```
source files ──tree-sitter (erl_ts NIF)──> facts (defs, calls, imports)
                                                │
                                          consult into a
                                          Prolog session (erlog)
                                                │
                              ┌─────────────────┴─────────────────┐
                              │                                   │
                        MCP server                          symbolic CLI
                    (LLM agent, over MCP)               (human, over argv)
```

- **[erlog](https://github.com/rvirding/erlog)** is the Prolog engine —
  pure Erlang, running **in-process on the BEAM**. There's no separate
  Prolog compiler or subprocess; session isolation comes from Erlang
  process isolation, not an OS boundary. See `docs/erlang-mcp-design.md`.
- **tree-sitter**, via a NIF (`erl_ts`), extracts facts from source files
  in-process as well — no subprocess per parse. See
  `docs/tree-sitter-erlang.md`.
- Extracted facts are cached as a content-hashed, consultable `.pl` file
  between runs. See `docs/prolog-store.md`.

Inspired by the [Chiasmus MCP Server](https://github.com/yogthos/chiasmus).

## Supported languages

**TypeScript and Erlang**, both real today via `symbolic parse` — `defines`
and `calls` facts (including distinguishing plain calls from method calls
in TypeScript, and local from remote calls in Erlang), dogfooded against
this repo's own source and a real-world-style `.ts` file. More tree-sitter
grammars (Python, Go, Rust) can slot in the same way; see
`docs/tree-sitter-erlang.md` §5 for the actual recipe (not hypothetical —
what adding TypeScript really took, including two vendored-fork
Makefiles). Parsing Markdown itself (so the project's own docs become
queryable facts too) is designed separately in
`docs/tree-sitter-markdown.md`.

## Tools

- **CLI** — `symbolic parse` walks a folder and emits Prolog facts;
  `symbolic query` loads a fact file and runs a query against it. See
  `docs/cli-erlang.md`.
- **MCP server** — `symbolic serve` exposes the same Prolog session and
  fact base over the Model Context Protocol, so an LLM agent can consult
  and query it directly. See `docs/erlang-mcp-design.md`.

## Usage

```sh
symbolic                                          # prints usage
symbolic parse ./src                              # extract Prolog facts from a folder
symbolic query -file facts.pl 'depends_on(X, Y)'  # ask a question about the codebase
symbolic serve                                    # start the MCP server (stdio transport)
```

All three work end-to-end, run via a `rebar3 release` (see Install)
rather than `rebar3 escriptize` — `parse` and `serve` both need real
files on disk at runtime (`parse` for `erl_ts`'s NIF, `serve` for
`erlmcp`'s supervision tree), and neither works from inside an escript's
zip archive (a real limitation found while building this, not a bug; see
`docs/cli-erlang.md` §1/§1.1). Flags use a single dash (`-file`, not
`--file`) — that's [stdlib `argparse`](https://www.erlang.org/doc/apps/stdlib/argparse.html)'s
own convention, which `symbolic_cli` uses for all argument parsing and
usage/help text.

## Examples

### Parsing TypeScript

```ts
// greeter.ts
function formatName(first: string, last: string): string {
  return capitalize(first) + " " + capitalize(last);
}

function greet(name: string): void {
  const formatted = formatName(name, "user");
  console.log(formatted);
  this.logger.info(formatted);
}

function capitalize(word: string): string {
  return word.toUpperCase();
}
```

```sh
$ symbolic parse .
defines(capitalize,'greeter.ts',11).
defines(formatName,'greeter.ts',1).
defines(greet,'greeter.ts',5).
calls(capitalize,member(word,toUpperCase),'greeter.ts',12).
calls(formatName,local(capitalize),'greeter.ts',2).
calls(greet,local(formatName),'greeter.ts',6).
calls(greet,member(console,log),'greeter.ts',7).
calls(greet,member('this.logger',info),'greeter.ts',8).
```

A plain call (`bar()`) becomes `local(bar)`; a method call (`obj.method()`)
becomes `member(obj, method)` — so a query can tell "calls that function
directly" apart from "calls a method on something."

### Querying the facts

`parse` and `query` are separate steps around an ordinary `.pl` file, so
save the output and start asking it things:

```sh
$ symbolic parse . > facts.pl

$ symbolic query -file facts.pl 'calls(X, local(capitalize), _, _)'
X = formatName                      # the only caller of capitalize

$ symbolic query -file facts.pl 'defines(formatName, File, Line)'
File = 'greeter.ts'
Line = 1

$ symbolic query -file facts.pl 'calls(X, member(console, _), _, _)'
X = greet                           # who calls a method on console

$ symbolic query -file facts.pl 'calls(greet, X, _, Line)'
Line = 6
X = local(formatName)               # greet's first call — one solution at a time

$ symbolic query -file facts.pl 'calls(capitalize, member(_, missingMethod), _, _)'
No.                                 # capitalize never calls a method by that name
```

Because it's a real fact base, not a grep result, this composes: combine
facts from multiple `parse` runs into one file, hand-edit it, or ask
something no text search could answer directly — "what calls a method on
`console`" is just `calls(X, member(console, _), _, _)`.

## Install

Symbolic Tools is written in Erlang and built with rebar3.

```sh
brew bundle
ERL_TS_LINKING=dynamic rebar3 release
```

`ERL_TS_LINKING=dynamic` is required on macOS — `erl_ts`'s default static
link uses linker flags Apple's `ld` rejects (see `docs/tree-sitter-erlang.md`
§6.1). One command, one run — `erl_ts` is a vendored local fork
(`_checkouts/erl_ts`, §6.2), not a git dependency re-fetched on every
clean build, so the submodule-init race that used to require running this
twice no longer applies. The built CLI is at
`_build/default/rel/symbolic_tools/bin/symbolic`.

To run `symbolic` from anywhere on this machine, symlink it onto your
`PATH` (e.g. `/opt/homebrew/bin` on an Apple Silicon Homebrew install):

```sh
ln -sf "$(pwd)/_build/default/rel/symbolic_tools/bin/symbolic" /opt/homebrew/bin/symbolic
```

A plain symlink works because `scripts/symbolic` resolves through
symlinks itself before locating the release's `lib/` directory — don't
`cp` the script elsewhere instead, that breaks it. This keeps the actual
files inside this checkout (don't move or delete the repo afterward); for
a build that's relocatable on its own, see `docs/cli-erlang.md` §4
(`dev_mode`/`include_erts`).

## Development

Dependencies:

- [rebar3](https://rebar3.org/) — build tool
- [erlog](https://github.com/rvirding/erlog) — the Prolog engine (runs in-process on the BEAM)
- [erlmcp](https://github.com/erlsci/erlmcp) — MCP server framework
- [erl_ts](https://github.com/cfclavijo/erl_ts) — tree-sitter, via a NIF

## Documentation

`docs/` holds the full design for this project — start with
`erlang-mcp-design.md` for the overall architecture, then follow its
cross-references. Grouped by concern:

- **Architecture** — `erlang-mcp-design.md` (MCP server, Prolog sessions),
  `cli-erlang.md` (the CLI), `prolog-store.md` (fact storage/caching).
- **Extraction** — `tree-sitter-erlang.md` (code, via `erl_ts`),
  `tree-sitter-markdown.md` (docs).
- **Natural language** — `nlp-tooling.md` (survey of what's available on
  the BEAM), `curt-approach.md` (parsing NL into Prolog facts),
  `lorp-approach.md`, `grpo-prolog-tool.md` (the research this project is
  based on).
- **Ops** — `testing-erlang.md` (EUnit/Common Test/PropEr/coverage/mocking),
  `logging-and-metrics.md` (`logger`, OpenTelemetry).
