Title: symbolic-tools
Slug: home
Save_as: index.html
URL:
Subtitle: Turn a codebase into a Prolog fact base an agent can query and get proven answers from.

<nav class="quicknav" aria-label="On this page">
<a href="#get-started">Get started</a>
<a href="#why-prolog">Why Prolog</a>
<a href="#how-it-works">How it works</a>
<a href="#what-it-can-answer">What it can answer</a>
<a href="ask.html">Using ask</a>
<a href="fact-schema.html">The fact schema</a>
<a href="#status">Status</a>
</nav>

## Introduction

symbolic-tools builds a Prolog database from your codebase. An LLM
agent, or a person, can query it and get an answer proven by
resolution, not guessed from a snippet.

It works by parsing a source tree with tree-sitter, extracting facts
(function definitions, call sites, comments, decision points), and
loading them into an in-process Prolog engine
([erlog](https://github.com/rvirding/erlog), running on the BEAM).

## Get started {: #get-started }

```sh
brew tap iwillig/symbolic-tools https://github.com/iwillig/symbolic-tools
brew trust iwillig/symbolic-tools
brew install symbolic-tools
```

```sh
claude mcp add symbolic -- symbolic serve
```

`/mcp` inside Claude Code shows `symbolic` connected, with its four
tools: `parse`, `query`, `ask`, `overview`.

## Why Prolog {: #why-prolog }

Research on pairing language models with a symbolic reasoner has found
large accuracy gains on problems that need multi-step logical
correctness. symbolic-tools applies this to codebases. Build the fact
base once. Let a query prove the answer against it.

## How it works {: #how-it-works }

<p>A rules library sits on top of the raw facts. It finds dead code,
duplicate names, mutual recursion, undocumented functions, and
oversized or overly complex definitions. Each rule is a few more Prolog
clauses over the same facts. The full fact schema — every predicate,
with a live example of each — has <a href="fact-schema.html">its own
page</a>.</p>

<div>
  <img class="diagram-light" src="theme/img/architecture-light.svg" alt="Architecture: source files are parsed by a tree-sitter extractor into facts, loaded into a Prolog session (erlog), queried by an MCP server or the symbolic CLI">
  <img class="diagram-dark" src="theme/img/architecture-dark.svg" alt="Architecture: source files are parsed by a tree-sitter extractor into facts, loaded into a Prolog session (erlog), queried by an MCP server or the symbolic CLI">
</div>

## What it can answer {: #what-it-can-answer }

A linter checks one file against one pattern at a time. These four
examples are things that model cannot do at any price: follow a call
chain to arbitrary depth, aggregate across every file in the project
at once, rank free-text documentation by relevance instead of exact
match, and answer a plain English question instead of flagging a
pattern.

### A call chain a per-file linter cannot see

An ESLint visitor only ever sees the one function it's standing inside.
It has no notion of "reachable" — a risky call three functions away,
behind a name that gives no hint of it, is invisible to a per-node rule
by construction. Answering "does this function's call chain eventually
reach `os:cmd`, `file:*`, or similar" needs a real call graph and a walk
over arbitrary-depth chains, which is two lines here:

```prolog
hidden_risky_call(Fun, Module, Target) :-
    reaches(Fun, RiskyCaller),
    risky_call(RiskyCaller, Module, Target),
    \+ risky_call(Fun, Module, Target).
```

```prolog
?- hidden_risky_call(scan, Module, Target).
```

```json
{
  "count": 3,
  "limit": 50,
  "solutions": [
    { "Module": "file", "Target": "list_dir" },
    { "Module": "file", "Target": "list_dir" },
    { "Module": "erlang", "Target": "demonitor" }
  ],
  "truncated": false
}
```

`scan/1` never calls any of those itself. It calls `walk/3`, which
calls further functions that eventually do — two distinct call chains
reach `file:list_dir`, and one reaches `erlang:demonitor`. A reviewer
auditing `scan/1` by reading its body alone would never see any of it.
(The duplicate is real, not a typo: two different proof paths, same
target.)

### Which function does the whole project rely on most

This needs an aggregate over every call site in every file at once, not
a rule applied one file at a time. It's the kind of question a separate
whole-program tool (madge, dependency-cruiser) exists to bolt on,
because a linter's rule model can't ask it:

```prolog
?- top_fan_in(3, Top).
```

```json
{
  "count": 1,
  "limit": 50,
  "solutions": [
    {
      "Top": [
        ["-", ["-", 53, "line"], 1],
        ["-", ["-", 35, "to_atom"], 1],
        ["-", ["-", 19, "caller_info"], 2]
      ]
    }
  ],
  "truncated": false
}
```

`line/1`, a small line-number helper, is called from 53 distinct
places across the codebase. Ranking every function in the project by
how many places call it is one goal, not a separate static-analysis
pass. `Top`'s shape is real too: erlog keeps Prolog's `-` as an
ordinary 2-argument functor, so
`53-line/1` prints as nested `["-", ...]` arrays, the same way every
other `-`-joined result would if shown raw.

### Ranked search over comments and docs, not exact match

A linter's "find in files" is substring or regex — it has no notion of
*relevance*, so "which comment explains ranked search" only works if
you already know to type the exact words the author used. `text_search/2,3`
indexes every comment, docstring, and Markdown paragraph with BM25 and
ranks them, cached at parse time so it doesn't re-tokenize megabytes
per query:

```prolog
?- text_search("BM25 ranked search", 3, Hits).
```

```json
{
  "count": 1,
  "limit": 50,
  "solutions": [
    {
      "Hits": [
        ["hit", "comment", "src/symbolic_prolog_lib.erl", 292, 12.218732475981529],
        ["hit", "comment", "src/symbolic_parse.erl", 348, 6.039122446746265],
        ["hit", "comment", "src/symbolic_search.erl", 5, 5.910758123629731]
      ]
    }
  ],
  "truncated": false
}
```

None of the three highest-ranked comments contain the literal phrase
"BM25 ranked search" — they're ranked by relevance across the whole
corpus, best first, not matched by exact string. A linter's grep-based
search can't rank at all; it can only say yes or no.

### Ask in English, gated so a wrong arity can't lie

A wrong arity answers a different question with full confidence: `calls/5`
has no opinion on whether `query_binary/1` was the function meant, only on
whether it exists. `symbolic ask` resolves every entity against the fact
base **before** proving, so a wrong arity comes back `unverifiable`
instead of a silent, plausible wrong answer:

```
"how many functions call query_binary/1?"
```

```json
{ "type": "unverifiable", "reason": "{wrong_arity,query_binary,1}" }
```

```
"how many functions call query_binary/2?"
```

```json
{ "type": "count", "answer": 1 }
```

`query_binary/1` doesn't exist; `query_binary/2` does, and one function
calls it. The first question gets caught and named, not answered with a
confident `0`. The same gate runs whether the question comes from the
CLI (`symbolic ask -db facts.dets "<question>"`) or the MCP `ask` tool —
one pipeline, two entry points.

The grammar covers far more than calls and existence now: returned
fields, branch literals, call sites with file and line, file and config
questions — and it grades a plan claim by claim before and after a fix.
The full question grammar, the pipeline behind it, and a plan graded
live against this repository are on <a href="ask.html">the ask page</a>.

### The ask grammar, shape by shape

The grammar covers five question shapes, and every answer below ran
live against this repository's own fact base. Together they show the
three states the tool can return: an answer, `unverifiable` (shown
above), and `unrecognized`.

Yes/no — both values are answers, never errors. `false` says the proof
failed, not that the tool broke:

```
"does render_query/2 call error_str/1?"
```

```json
{ "type": "yes_no", "answer": true }
```

```
"does handle_ask/1 call error_str/1?"
```

```json
{ "type": "yes_no", "answer": false }
```

`handle_ask/1` calls `render_ask/1`, which calls `error_str/1` — one
hop away is still no. The tool answers the question asked, not a
nearby one.

Enumeration and count — the same gate and the same proof, shaped two
ways. `optional_path/1` is the tiny helper every tool handler shares:

```
"which functions call optional_path/1?"
```

```json
{
  "type": "enumerate",
  "answer": [
    "handle_ask/1",
    "handle_overview/1",
    "handle_parse/1",
    "handle_query/1"
  ]
}
```

```
"how many functions call optional_path/1?"
```

```json
{ "type": "count", "answer": 4 }
```

Prose — evidence, never a verdict. Absence in free text proves
nothing, so "where is X documented" returns ranked hits and refuses to
say yes or no:

```
"where is the question grammar documented?"
```

```json
{
  "type": "prose",
  "evidence": [
    { "kind": "comment",  "file": "src/symbolic_codebase.erl", "line": 429, "score": 11.23 },
    { "kind": "comment",  "file": "src/symbolic_ask.erl",       "line": 79,  "score": 10.57 },
    { "kind": "comment",  "file": "src/symbolic_ask.erl",       "line": 132, "score": 7.94 },
    { "kind": "comment",  "file": "src/symbolic_ask.erl",       "line": 2,   "score": 7.49 },
    { "kind": "comment",  "file": "src/symbolic_ask.erl",       "line": 133, "score": 7.44 },
    { "kind": "heading",  "file": "docs/research-questions-to-prolog.md", "line": 57, "score": 6.95 },
    { "kind": "heading",  "file": "docs/tree-sitter-markdown.md", "line": 52, "score": 6.89 },
    { "kind": "comment",  "file": "src/symbolic_ask.erl",       "line": 67,  "score": 6.72 },
    { "kind": "comment",  "file": "test/ts_extract_markdown_tests.erl", "line": 96, "score": 6.64 },
    { "kind": "comment",  "file": "src/symbolic_serve.erl",     "line": 390, "score": 6.61 }
  ]
}
```

Three kinds of text — comments, headings, paragraphs — ranked by BM25
score across the whole corpus, best first. The top hits name the exact
files where the grammar's contract is written.

Unrecognized — the third state, one rung below `unverifiable`. A
missing arity cannot even parse (`render_ask` is not a `Name/Arity`
term); a wrong arity parses but cannot verify. Both refuse loudly
before any proof runs, and neither pretends to answer:

```
"which functions call render_ask?"
```

```json
{ "error": "unrecognized question shape - the grammar covers: does
X/N call Y/M? / which functions call X/N? / who calls X/N? / how many
functions call X/N? / is X/N defined? / does X/N exist? / where is ...
documented? / where is ... discussed? (lowercase words only). Write a
`query` goal for anything else." }
```

The error names every phrasing the grammar does cover, so the caller
can repair the question without reading the source.

## The fact schema

Every fact above is pulled from a plain Prolog term — `defines/5`,
`calls/5`, `doc/5`, and the rest — with no ID to generate and no join
to write by hand, because a shared `(Function, Arity, File)` is what
lets two families be queried together at all. The full schema, every
predicate with a live example of its own, is on
<a href="fact-schema.html">its own page</a>.

## Status {: #status }

Early implementation. Under active development. See the
[GitHub repository](https://github.com/iwillig/symbolic-tools) for the
full README, the Prolog fact schema, and the rules library.
