# Symbolic Tools

[![CI](https://github.com/iwillig/symbolic-tools/actions/workflows/ci.yml/badge.svg)](https://github.com/iwillig/symbolic-tools/actions/workflows/ci.yml)

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
source files ──tree-sitter (symbolic_ts NIF)──> facts (defs, calls, imports)
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
- **tree-sitter**, via a NIF (`symbolic_ts`, this project's own — see
  `docs/tree-sitter-erlang.md` §2), extracts facts from source files
  in-process as well — no subprocess per parse. See
  `docs/tree-sitter-erlang.md`.
- Extracted facts are written into a DETS database (Erlang's own
  on-disk term store) between runs — no Prolog text parsing involved in
  either direction. See `docs/prolog-store.md` §7.

Inspired by the [Chiasmus MCP Server](https://github.com/yogthos/chiasmus).

## Supported languages

**TypeScript, Erlang, and Bash**, all real today via `symbolic parse` —
`defines`, `calls` (distinguishing plain calls from method calls in
TypeScript, local from remote calls in Erlang, and just `local` calls
in Bash, which has no qualified-call syntax to tell apart from a bare
one), `comment`, and `doc` facts (every comment, plus which ones
document a specific function), dogfooded against this repo's own
source and a real-world-style `.ts` file. **Markdown** is real too, for
`.md` files — `heading`, `code_block`, and `paragraph` facts, so
`readme.md`/`docs/*.md` become queryable the same way; a fenced
`erlang`/`ts`/`typescript`/`sh`/`bash` block also gets re-parsed into
`example_defines`/`example_calls` facts, so a query can catch a doc's
code sample showing a function the real codebase doesn't (or no
longer) have. See `docs/tree-sitter-markdown.md` for what's implemented
(block structure) versus deferred (`link/4`, which needs a second,
currently unimplemented grammar pass). **TOML and JSON** are real too —
config formats, not code, so instead of `defines`/`calls` they get
`config_value(File, Path, Value, Line)` and `config_section(File, Path,
Line)`, `Path` a dotted key path (`'dependencies.serde'`). Both formats
emit the *same* two predicates, so `config_value(File, name, Value, _)`
finds a `name` key the same way in a `Cargo.toml` or a `package.json`.
YAML was investigated and deliberately skipped — its grammar needs a
real C++ scanner this project's (all-C) build has no toolchain for; see
`docs/tree-sitter-erlang.md` §5.1. More tree-sitter
grammars (Python, Go, Rust) can slot in the same way; see
`docs/tree-sitter-erlang.md` §5 for the actual recipe (not hypothetical —
what adding TypeScript really took, including two vendored-fork
Makefiles).

## Tools

- **CLI** — `symbolic parse` walks a folder, prints facts as JSON, and
  optionally writes them into a fact database (`-db`); `symbolic query`
  loads that database and runs a query against it, with an optional
  hand-written rule file (`-rules`) consulted alongside the facts. See
  `docs/cli-erlang.md`.
- **MCP server** — `symbolic serve` exposes the same Prolog session and
  fact base over the Model Context Protocol, so an LLM agent can consult
  and query it directly. See `docs/erlang-mcp-design.md`.

## Usage

```sh
symbolic                                              # prints usage
symbolic parse ./src -db facts.dets                   # extract facts, print JSON, write a fact database
symbolic query -db facts.dets 'depends_on(X, Y)'      # ask a question about the codebase
symbolic serve                                        # start the MCP server (stdio transport)
```

All three work end-to-end, run via a `rebar3 release` (see Install)
rather than `rebar3 escriptize` — `parse` and `serve` both need real
files on disk at runtime (`parse` for `symbolic_ts`'s NIF, `serve` for
`erlmcp`'s supervision tree), and neither works from inside an escript's
zip archive (a real limitation found while building this, not a bug; see
`docs/cli-erlang.md` §1/§1.1). Flags use a single dash (`-db`, `-rules`,
not `--db`/`--rules`) — that's [stdlib `argparse`](https://www.erlang.org/doc/apps/stdlib/argparse.html)'s
own convention, which `symbolic_cli` uses for all argument parsing and
usage/help text.

## Examples

### Parsing TypeScript

```ts
// greeter.ts
// Formats a full name from its parts.
function formatName(first: string, last: string): string {
  return capitalize(first) + " " + capitalize(last);
}

function greet(name: string): void {
  const formatted = formatName(name, "user");
  console.log(formatted);
  this.logger.info(formatted);
}

// Capitalizes the first letter of a word.
function capitalize(word: string): string {
  return word.toUpperCase();
}

// TODO: handle names with a middle name too
```

```sh
$ symbolic parse .
["comment","greeter.ts",1,"Formats a full name from its parts."]
["comment","greeter.ts",12,"Capitalizes the first letter of a word."]
["comment","greeter.ts",17,"TODO: handle names with a middle name too"]
["defines","capitalize","greeter.ts",13]
["defines","formatName","greeter.ts",2]
["defines","greet","greeter.ts",6]
["calls","capitalize",["member","word","toUpperCase"],"greeter.ts",14]
["calls","formatName",["local","capitalize"],"greeter.ts",3]
["calls","greet",["local","formatName"],"greeter.ts",7]
["calls","greet",["member","console","log"],"greeter.ts",8]
["calls","greet",["member","this.logger","info"],"greeter.ts",9]
["doc","capitalize","greeter.ts",13,"Capitalizes the first letter of a word."]
["doc","formatName","greeter.ts",2,"Formats a full name from its parts."]
```

Facts print as JSON Lines — one JSON array per fact, `[Functor, Arg1,
Arg2, ...]` — instead of Prolog text, fixing a real bug the old
Prolog-text printer had: it didn't escape an atom's embedded single
quote at all, corrupting ordinary prose ("it's", "doesn't") in
`comment`/`doc` text. See `docs/prolog-store.md` §7.

A plain call (`bar()`) becomes `local(bar)`; a method call (`obj.method()`)
becomes `member(obj, method)` — so a query can tell "calls that function
directly" apart from "calls a method on something." Every comment becomes a
`comment(File, Line, Text)` fact, unconditionally; a comment (or run of
consecutive `//` lines) that sits immediately before a function also
becomes a `doc(Function, File, Line, Text)` fact, attributed to that
function at its own definition line — `greet` has no `doc/4` fact because
nothing precedes it, and the trailing `// TODO: ...` line has a `comment/3`
fact but no `doc/4`, because nothing follows it. Finding this attribution
needed a part of the tree-sitter API this project hadn't used before: a
comment is a **sibling** of the code it documents, not a parent/child of
it, so extracting `doc/4` walks `node_next_sibling/1`/`node_prev_sibling/1`
rather than the `node_parent/1` walk `calls/4` uses for caller attribution
— see `docs/tree-sitter-erlang.md` §6 for a real inconsistency this
uncovered in that part of the API (`node_is_null/1` doesn't apply to a
missing sibling the way it does to a missing parent).

### Querying the facts

`parse -db` writes a fact database; `query -db` reads it back and asserts
the facts directly (no text parsing either way — see
`docs/prolog-store.md` §7):

```sh
$ symbolic parse . -db facts.dets

$ symbolic query -db facts.dets 'calls(X, local(capitalize), _, _)'
X = "formatName"                    # the only caller of capitalize

$ symbolic query -db facts.dets 'defines(formatName, File, Line)'
File = "greeter.ts"
Line = 2

$ symbolic query -db facts.dets 'calls(X, member(console, _), _, _)'
X = "greet"                         # who calls a method on console

$ symbolic query -db facts.dets 'calls(greet, X, _, Line)'
Line = 7
X = ["local","formatName"]          # greet's first call — one solution at a time

$ symbolic query -db facts.dets 'calls(capitalize, member(_, missingMethod), _, _)'
No.                                 # capitalize never calls a method by that name

$ symbolic query -db facts.dets 'doc(formatName, File, Line, Text)'
File = "greeter.ts"
Line = 2
Text = "Formats a full name from its parts."

$ symbolic query -db facts.dets 'defines(F, _, _), \+ doc(F, _, _, _)'
F = "greet"                         # which functions have no doc comment

$ symbolic query -db facts.dets 'comment(File, Line, Text), \+ doc(_, _, _, Text)'
File = "greeter.ts"
Line = 17
Text = "TODO: handle names with a middle name too"   # comments not attached to any definition
```

A bound value prints as JSON (`docs/prolog-store.md` §7) — a plain atom
or binary prints the same way (`"formatName"`), so the type distinction
between an identifier and free text (`docs/prolog-schema.md`) only
matters when *writing* a rule, not when reading a query's answer.
Because it's a real fact base, not a grep result, this composes: point
`-rules` at a file of hand-written derived predicates (below), or ask
something no text search could answer directly — "what calls a method on
`console`" is just `calls(X, member(console, _), _, _)`, and "which
functions are undocumented" is just `defines(F, _, _), \+ doc(F, _, _, _)`.

### Deriving your own rules with `-rules`

Any hand-written Prolog belongs in its own `.pl` file, consulted
alongside the fact database — the facts and the rules are two different
kinds of thing (extracted data vs. logic you wrote), and only the rules
are ever real Prolog *text* on disk:

```sh
$ cat > rules.pl << 'EOF'
undocumented(Fun, File, Line) :-
    defines(Fun, File, Line),
    \+ doc(Fun, _, _, _).
EOF

$ symbolic query -db facts.dets -rules rules.pl 'findall(F, undocumented(F, _, _), Fs)'
F = [0]
Fs = ["greet"]
```

`F = [0]` is `findall/3`'s own template variable, unbound outside the
call (standard Prolog semantics, not a bug) — erlog represents an
unbound variable as a 1-tuple internally, which prints as a 1-element
JSON array rather than the `_0` a Prolog-text printer would show; `Fs`
is the answer that matters. See `docs/lint-queries.md` for a much larger
rule library built the same way.

**A real limitation, not glossed over:** free-text fields like `Text`
above are Erlang binaries, not atoms (`docs/prolog-schema.md`) — the fix
for the old printer's quote-escaping bug and its 200-character
truncation. erlog's only text-inspection builtin, `atom_codes/2`,
requires an actual atom and raises `type_error(atom, ...)` on a binary,
so a substring-search rule over `Text` (e.g. "find the doc comment that
mentions X") can't currently be written in pure Prolog against this
fact base. A real fix needs a binary-aware string builtin in erlog, or
an Erlang-side helper exposed to it — not yet done.

### Parsing Markdown

````md
# Getting Started

A short intro paragraph
that wraps onto a second line.

## Installation

```sh
brew bundle
rebar3 release
```

## Configuration

No config needed yet.
````

```sh
$ symbolic parse . -db facts.dets
["code_block","notes.md","sh",8]
["paragraph","notes.md","A short intro paragraph that wraps onto a second line.",3]
["paragraph","notes.md","No config needed yet.",15]
["example_calls","undefined",["local","brew"],"notes.md",9]
["example_calls","undefined",["local","rebar3"],"notes.md",10]
["heading","notes.md",1,"Getting Started",1]
["heading","notes.md",2,"Configuration",13]
["heading","notes.md",2,"Installation",6]

$ symbolic query -db facts.dets 'heading(File, 2, Text, Line)'
File = "notes.md"
Line = 13
Text = "Configuration"              # one solution — ask again for the next

$ symbolic query -db facts.dets 'code_block(File, Lang, Line)'
File = "notes.md"
Lang = "sh"
Line = 8

$ symbolic query -db facts.dets 'paragraph(File, Text, Line)'
File = "notes.md"
Line = 3
Text = "A short intro paragraph that wraps onto a second line."
```

The `example_calls` facts come from the `sh`-tagged fence being
re-parsed as Bash (`Caller = "undefined"` since `brew bundle`/`rebar3
release` are bare top-level commands, not inside any function) — see
"Parsing Bash" below.

A paragraph that wraps onto a second source line with no blank line in
between is still one fact, not two — `paragraph/3` collapses the embedded
newline into a single space the same way multi-line doc comments already
do for code. This only uses tree-sitter-markdown's **block** grammar —
headings, paragraph text, and fenced-code-block languages are enough to
check things like "does every doc have a heading structure" or "which
fenced blocks have no declared language" without opening an editor. It
deliberately does not extract links yet: a Markdown link is only a
structured node in a *second*, separate inline grammar, requiring a
re-parse scoped to the byte ranges
the block parse marks as inline content — and the NIF function for that
(`ts_parser_set_included_ranges`) isn't wrapped by this project's own
tree-sitter NIF (`symbolic_ts`) yet, since nothing has needed it so far.
See `docs/tree-sitter-markdown.md` §3 for what implementing it for real
would take.

### Parsing TOML and JSON

```toml
[package]
name = "example"
version = "0.1.0"

[dependencies]
serde = "1.0"

[[bin]]
name = "cli"
path = "src/main.rs"
```

```json
{
  "name": "example",
  "version": "0.1.0",
  "dependencies": {
    "left-pad": "^1.3.0"
  }
}
```

```sh
$ symbolic parse .
["config_section","Cargo.toml","bin",8]
["config_section","Cargo.toml","dependencies",5]
["config_section","Cargo.toml","package",1]
["config_section","package.json","dependencies",4]
["config_value","Cargo.toml","bin.name","cli",9]
["config_value","Cargo.toml","bin.path","src/main.rs",10]
["config_value","Cargo.toml","dependencies.serde","1.0",6]
["config_value","Cargo.toml","package.name","example",2]
["config_value","Cargo.toml","package.version","0.1.0",3]
["config_value","package.json","dependencies.left-pad","^1.3.0",5]
["config_value","package.json","name","example",2]
["config_value","package.json","version","0.1.0",3]
```

Both files produce the *same* two predicates — `config_value`/
`config_section` — so a query doesn't need to know or care which config
format it's asking about:

```sh
$ symbolic parse . -db facts.dets

$ symbolic query -db facts.dets 'config_value(File, name, Value, _)'
File = "package.json"
Value = "example"

$ symbolic query -db facts.dets 'config_section(File, dependencies, Line)'
File = "Cargo.toml"
Line = 5
```

Array *values* (a JSON `["a", "b"]`, a TOML `[1, 2, 3]`) are captured as
one opaque leaf — the array's whole raw source text becomes its
`Value`, not walked element-by-element. A real, deliberate scope limit
for this first pass, not a missing case — see
`docs/tree-sitter-erlang.md` §5.1. TOML's `[[bin]]` above is a different
thing entirely (an array-*of-tables* header, not an array value) and is
walked normally, as the `config_section`/`config_value` facts above
show.

### Parsing Bash

```sh
# Deploys the app to the given environment.
deploy() {
  build
  rsync -avz dist/ "$1":/srv/app
}

# Builds the release artifact.
build() {
  npm run build
}
```

```sh
$ symbolic parse . -db facts.dets
["comment","deploy.sh",1,"Deploys the app to the given environment."]
["comment","deploy.sh",7,"Builds the release artifact."]
["defines","build","deploy.sh",8]
["defines","deploy","deploy.sh",2]
["calls","build",["local","npm"],"deploy.sh",9]
["calls","deploy",["local","build"],"deploy.sh",3]
["calls","deploy",["local","rsync"],"deploy.sh",4]
["doc","build","deploy.sh",8,"Builds the release artifact."]
["doc","deploy","deploy.sh",2,"Deploys the app to the given environment."]

$ symbolic query -db facts.dets 'calls(deploy, X, _, Line)'
Line = 3
X = ["local","build"]
```

Every `calls/4` fact is `local(...)` — Bash has no qualified-call
syntax (nothing like Erlang's `mod:fun()` or TypeScript's `obj.method()`)
to tell a call to a function defined in this same script apart from a
call to an external program or a builtin, so this project doesn't
pretend to know the difference either; `local(build)` and
`local(rsync)` look exactly alike, on purpose. A fenced `sh`/`bash`
block in a Markdown doc gets the same `example_defines`/`example_calls`
re-extraction TypeScript/Erlang blocks already get — see "Catching
stale doc examples" below, which works identically for a shell snippet.

### Catching stale doc examples

A fenced code block tagged `erlang`, `ts`, `typescript`, `sh`, or `bash`
gets re-parsed by the same real extractors that parse actual source — the code a doc
*shows* becomes `example_defines`/`example_calls` facts, a deliberately
different predicate than `defines`/`calls` so a query can ask "does the
codebase still actually have this" without conflating the two. Parse a
doc alongside the real source it documents:

```ts
// greeter.ts
function formatName(first: string, last: string): string {
  return capitalize(first) + " " + capitalize(last);
}

function capitalize(word: string): string {
  return word.toUpperCase();
}
```

````md
<!-- guide.md -->
# Formatting Names

Use `capitalize` to fix casing, and `shout` for emphasis:

```ts
function shout(word: string): string {
  return capitalize(word) + "!";
}
```
````

```sh
$ symbolic parse . -db facts.dets
["code_block","guide.md","ts",5]
["defines","capitalize","greeter.ts",5]
["defines","formatName","greeter.ts",1]
["example_defines","shout","guide.md",6]
["paragraph","guide.md","Use `capitalize` to fix casing, and `shout` for emphasis:",3]
["calls","capitalize",["member","word","toUpperCase"],"greeter.ts",6]
["calls","formatName",["local","capitalize"],"greeter.ts",2]
["example_calls","shout",["local","capitalize"],"guide.md",7]
["heading","guide.md",1,"Formatting Names",1]
```

`guide.md`'s sample defines `shout` — a function that was never actually
added to `greeter.ts`. Write the check to its own rules file and load
it alongside the facts:

```sh
$ cat > rules.pl << 'EOF'
stale_doc_example(Fun, DocFile, Line) :-
    example_defines(Fun, DocFile, Line),
    \+ defines(Fun, _, _).
EOF

$ symbolic query -db facts.dets -rules rules.pl 'stale_doc_example(Fun, DocFile, Line)'
DocFile = "guide.md"
Fun = "shout"
Line = 6
```

`capitalize` — shown in the same doc and *does* exist in `greeter.ts` —
correctly does not show up: `stale_doc_example/3` only surfaces the one
function the doc claims exists but doesn't.

## Install

### Via Homebrew

```sh
brew tap iwillig/symbolic-tools https://github.com/iwillig/symbolic-tools
brew trust iwillig/symbolic-tools
brew install symbolic-tools
```

The explicit URL on `brew tap` matters — `brew tap iwillig/symbolic-tools`
on its own guesses a repo named `homebrew-symbolic-tools`, which doesn't
exist, and fails with a confusing `could not read Username` error rather
than a clear "not found" (git's response to a nonexistent repo and a
private one it can't see look identical over HTTPS). `brew trust` is
required too — Homebrew doesn't run formulae from a third-party tap
until it's explicitly trusted, and skipping this step will fail (or
silently no-op) the install.

This builds a real, relocatable release — `dev_mode` is off specifically
so the release doesn't depend on this repo's checkout still existing
afterward (confirmed by testing: with `dev_mode` on, the release's `lib/`
entries are symlinks back into the build tree, which breaks the moment
Homebrew's own temporary build sandbox is cleaned up). `Formula/symbolic-
tools.rb` is the actual formula, verified end-to-end with a real local
`brew install --build-from-source`, and builds from the tagged `v0.1.0`
release.

### From source

For development on this repo itself — the Homebrew install above is the
right choice otherwise, and doesn't need any of this.

Symbolic Tools is written in Erlang and built with rebar3.

```sh
brew bundle
rebar3 release
```

One command, one run — the tree-sitter NIF (`symbolic_ts`) is built
in-tree via the standard rebar3 `pc` plugin (see
`docs/tree-sitter-erlang.md` §2), not a separately vendored dependency
with its own build quirks to work around. The built CLI is at
`_build/default/rel/symbolic_tools/bin/symbolic` — run it directly from
there, or from wherever you copy the whole release tree to (`dev_mode`
is off, so it's relocatable; see `docs/cli-erlang.md` §4).

## Development

Dependencies:

- [rebar3](https://rebar3.org/) — build tool
- [erlog](https://github.com/rvirding/erlog) — the Prolog engine (runs in-process on the BEAM)
- [erlmcp](https://github.com/erlsci/erlmcp) — MCP server framework
- [pc](https://hex.pm/packages/pc) — rebar3 port-compiler plugin, builds
  `symbolic_ts` (this project's own tree-sitter NIF — see
  `docs/tree-sitter-erlang.md`)

## Documentation

`docs/` holds the full design for this project — start with
`erlang-mcp-design.md` for the overall architecture, or
`prolog-schema.md` if you just want to know what a query can ask about,
then follow either's cross-references. Grouped by concern:

- **Reference** — `prolog-schema.md` (the complete data dictionary —
  every fact predicate `symbolic parse` produces, across every
  language, in one place).
- **Architecture** — `erlang-mcp-design.md` (MCP server, Prolog sessions),
  `cli-erlang.md` (the CLI), `prolog-store.md` (fact storage/caching).
- **Extraction** — `tree-sitter-erlang.md` (code, via `symbolic_ts`),
  `tree-sitter-markdown.md` (docs).
- **Usage** — `agent-examples.md` (worked, verified examples of an LLM
  agent using the fact base over MCP — orientation, impact analysis, a
  risk audit, a doc-coverage check, and catching documentation drift),
  `lint-queries.md` (a reusable rule library — duplication, fan-in/
  fan-out, dead-code candidates — verified against this repo's own
  `src/`, including a real bug it surfaced in fact-printing itself).
- **Natural language** — `nlp-tooling.md` (survey of what's available on
  the BEAM), `curt-approach.md` (parsing NL into Prolog facts),
  `lorp-approach.md`, `grpo-prolog-tool.md` (the research this project is
  based on).
- **Ops** — `testing-erlang.md` (EUnit/Common Test/PropEr/coverage/mocking),
  `logging-and-metrics.md` (`logger`, OpenTelemetry).
