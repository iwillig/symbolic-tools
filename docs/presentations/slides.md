---
title: symbolic-tools
subtitle: A Prolog database for your codebase
---

## The problem

- LLMs (Deep Learning) branch of AI is good at ambiguous tasks
- GenAI is only LLM
- Symbolic AI branch is better at query
- Chain of reasoning uses natural language (NL) for its reasoning.
- Could we build a system that uses a mixture of Prolog and NL
- Reasoning outside of Vector Space

- Why this matters?
- Smaller and cheaper models
- More accountability
- Symbolic AI (Prolog) is very cheap to run. Normal database issues scaling issues.

## What it is

A command line tool and MCP server that gives agents and humans a
Prolog database over a software codebase.

- tree-sitter scans the source tree and extracts facts
- the facts load into erlog, a Prolog engine written in Erlang
- you write goals; the engine answers by unification and resolution

## What is Prolog

Prolog is a language where you state facts and rules, then ask
questions. You describe what is true, not how to find it.

```prolog
parent(alice, bob).
parent(bob, carol).

grandparent(X, Z) :- parent(X, Y), parent(Y, Z).

?- grandparent(alice, Who).
Who = carol
```

Other languages run instructions in the order you wrote them. Prolog
searches for an answer: it tries the facts and rules, unifies
variables, and returns every way the question can be true. The engine
does the searching; you wrote none of it.

## Why Prolog for a codebase

An ESLint-style rule sees one file, one node at a time.

- "does this call chain reach the shell?" needs a call graph and a
  walk over arbitrary depth
- "which function does the whole project rely on?" needs every call
  site in every file at once

A per-file rule cannot express either question — not just one nobody
wrote yet. Prolog over a shared fact base answers both in one goal.
Research on pairing language models with a symbolic reasoner reports
large accuracy gains on exactly this kind of multi-step question:
build the fact base once, let queries prove the answers.

## How it works

```plantuml
!include docs/diagrams/slides.plantuml
```

## What is in the fact base

Parsed from this repo's `src/`: 27 files, 15,772 facts.

- `defines/5` — 558 function definitions
- `calls/5` — 1,820 call edges
- `export/4` — 133 exported functions
- `branch/5`, `expr/6`, `doc/5`, `comment/3` — control flow, expressions, docs

## An example

"One goal, the engine performs the join": which files carry the most
definitions, over the god-file threshold?

```prolog
all_god_files(L)
```

Answer: 8 files, led by `ts_extract_typescript.erl` with 110
definitions. The result came from a Prolog proof, not from reading
source.

## What calls this function

A raw fact query — no rule, just `calls/5`:

```prolog
?- calls(Caller, CallerArity, local(git_sha, 0), File, Line).
```

Answer: `info/0`, in `symbolic_version.erl`, line 18.

`local(Name, Arity)` is a nested term, not a string, so a goal can
match part of a call and leave the rest wild.

## Every call is a term

`calls/5` stores one nested term per call shape, whatever the
language produced it:

```prolog
local(Name, ArgCount)               % bar()
remote(Module, Function, ArgCount)  % mod:fun() or Module.fun()
member(Object, Method, ArgCount)    % obj.method()
new(Constructor, ArgCount)          % new Ctor() — TypeScript
```

One goal finds every call to a method named `hasOwnProperty`, on any
object, in any language the walker can see:

```prolog
?- calls(_, _, member(_, hasOwnProperty, _), _, _).
```

## Two rules joined in one goal

`undocumented/4` is two lines over `defines/5` and `doc/5`:

```prolog
undocumented(Fun, Arity, File, Line) :-
    defines(Fun, Arity, _, File, Line),
    \+ doc(Fun, Arity, _, _, _).
```

Ask it together with mutual recursion:

```prolog
?- once((mutual_recursion(walk_object, walk_pair),
         undocumented(walk_object, Arity, File, Line))).
```

One answer: `walk_object/4` in `ts_extract_json.erl`, line 64. The
pair call each other, and `walk_object` has no doc comment. The
engine performed the join — nothing was pieced together from two
separate lookups.

## The reach no per-file rule can see

```prolog
hidden_risky_call(Fun, Module, Target) :-
    reaches(Fun, RiskyCaller),
    risky_call(RiskyCaller, Module, Target),
    \+ risky_call(Fun, Module, Target).
```

```prolog
?- hidden_risky_call(scan, Module, Target).
```

Three answers today, among them `file:list_dir`. `scan/1` never
calls it. It calls `walk/3`, which calls functions that do. A
reviewer reading `scan/1` alone would never see it.

## Claims about code are checkable

A plan is a claim about code that does not exist yet. Once the code
exists, each line becomes a query:

```sh
symbolic check "atom_from_binary_2/3 calls binary_to_atom/2"
```

```
{"verdict": "false"}
```

That claim was written into the plan wrong on purpose, before any
code existed, to check that this catches a bad prediction and not
just confirms good ones. It did.

## A linter whose config is Prolog

`.symbolic/rules.pl` ships 255 queryable predicates; 88 of them are
`all_*` checks that return their whole finding list in one goal.

A check is a small clause over facts, so it reads like the rule it is:

```prolog
short_name(F, A, File, Line) :-
    defines(F, A, _, File, Line),
    atom_length(F, N), N < 3,
    \+ allow_short_name(F).
```

`all_short_names(L)` on this tree: 0 findings.

## Dead code is one clause

Defined, never called, never exported:

```prolog
truly_uncalled(F, A, File) :-
    defines(F, A, _, File, _),
    \+ calls(_, _, local(F, A), _, _),
    \+ calls(_, _, remote(_, F, A), _, _),
    \+ entry_point(F, A, File).
```

`entry_point/3` is the escape hatch: everything exported counts, plus
whatever `runtime_entry_point/2` names. On this tree the check finds
one thing: `scan_one/1` in `symbolic_parse.erl`.

## Banned calls are facts plus one join

The rule never changes; the ban list does:

```prolog
banned_call(F, A, M, C) :-
    calls(F, _, member(M, C, _), _, _),
    banned_target(M, C).

banned_target(console, log).
banned_target(console, debug).
banned_target(console, warn).
```

`all_banned_calls(L)` on this tree: 0 findings. An Erlang codebase
calls no `console.*` — an adopted rule at rest, ready when the first
JavaScript lands.

## Docs that lie

A fenced example in Markdown that shows code which no longer exists:

```prolog
stale_doc_example(F, A, DocFile, Line) :-
    example_defines(F, A, _, DocFile, Line),
    \+ defines(F, A, _, _, _).
```

A missing file fails the include, and a stale example fails this
check. It needs a parse that spans docs and code, so it shows nothing
in this src-only snapshot — the fact family is simply absent.

## Recursion is a two-line rule

```prolog
self_recursive(F, A, File) :-
    defines(F, A, _, File, _),
    calls(F, A, local(F, A), _, _).
```

`all_self_recursive(L)` on this tree: 93 findings. In Erlang,
recursion is how you write a loop, so the count is information, not
failure. A rule reports; you decide what is normal for your language.

## Complexity is clauses plus branches

The whole rule, straight from `.symbolic/rules.pl` — McCabe
complexity, clause count plus branch count per function, the ESLint
complexity definition:

```prolog
real_complexity(Fun, Arity, File, Count) :-
    findall(F-A-Fl, defines(F, A, _, Fl, _), AllDefs),
    sort(AllDefs, Defs),
    member(Fun-Arity-File, Defs),
    findall(L, defines(Fun, Arity, _, File, L), Lines),
    length(Lines, Clauses),
    findall(_, branch(Fun, Arity, _, File, _), Bs),
    length(Bs, BranchCount),
    Count is Clauses + BranchCount.

too_complex_real(Fun, Arity, File, Count) :-
    real_complexity(Fun, Arity, File, Count),
    Count > 10.
```

The file's own caveat: two decision points on the same source line
collapse into one `branch/5` fact, so the score can undercount.

## What the complexity rule finds

`all_too_complex_real(L)` on this tree: 4 findings.

- `handle_call/3` in `symbolic_codebase`, score 20
- `walk_scope/5` in `ts_extract_typescript`, score 17
- `handle_call/3` in `prolog_session`, score 16
- `error_message/1` in `symbolic_parse`, score 11

The library also carries a cheap fan-out proxy, `too_complex/3`:
`fan_out(F, A, N), N > 10`. Fine for a quick sort; gate on the real
score.

## Expressions are facts too

`branch/5` says a decision point exists. `expr/6` says what it
actually compares: operator, operands, literals. Rules over those
facts are a few lines each:

- `self_compare/5` — `x == x`, always true or always false: a binary
  expression whose operator is an equality and whose two operands
  resolve to the same variable
- `yoda_condition/5` — `1 == x` instead of `x == 1`

Both count 0 on this tree: two more rules at rest, same as the
banned calls.

## Facts beyond functions

Not everything in the base is about a function.

- Scope, TypeScript only: `scope/4`, `var_decl/6`, `var_ref/6`, and
  `resolves_to/2` — which declaration a reference actually binds
  to, computed once by the extractor, not re-derived per query.
  Erlang's single-assignment variables give this family nothing to
  track.
- Markdown: headings, sections, code blocks, tables — and fenced
  examples re-parsed as real code (`example_defines/5`), which is
  what `stale_doc_example/4` stands on. The schema page counts 26
  stale examples against this project's own docs.
- Config: `config_value/4` and `config_section/3` for TOML and JSON
  alike — one dotted `Path` atom either way, so a query written
  against one format works unchanged against the other.

## Architecture is queryable

This tree has 977 raw dependency edges. `component_dependency/3`
classifies the ones worth drawing: 43 internal, 12 external, the
standard-library noise dropped.

The heaviest functions by fan-in — who gets called most:

- `line/1`, 52 callers
- `to_atom/1`, 34 callers
- `caller_info/2`, 19 callers

Change a hot function and you want to know this before you edit, not
after.

## A finding is a question, not a verdict

`truly_uncalled` flags `scan_one/1` in `symbolic_parse.erl`. Ask the
same fact base whether that is true:

```prolog
?- callers(scan_one, 1, Cs).
Cs = []

?- export(scan_one, 1, _, _).
false
```

No callers, not exported: a dead-code candidate, checked with two
goals and no source reading. Any finding the linter produces can be
interrogated the same way.

## Counts move, so treat them as a ratchet

Today's snapshot of this tree:

- 8 god files, led by `ts_extract_typescript.erl` (110 definitions)
- 1 uncalled function; 364 of 558 definitions undocumented
- 162 duplicate names — expected in Erlang, so that rule waits

Adopt a rule only when its count is one you accept. The exceptions
are facts, not code: `allow_short_name(ok).`,
`banned_target(console, log).`, `runtime_entry_point(mymod, init).`
Gate CI on the clean rules and shrink the exceptions over time.

## Why this approach is powerful

- The engine answers relational questions — what calls this, what
  reaches that — with proof, not text matching
- One rule file covers seven languages: TypeScript, JavaScript,
  Erlang, Bash, Markdown, TOML, JSON
- Humans and agents run the same rules: the CLI for CI, the MCP
  server for an agent that can then explain a finding from the
  same facts
- It checks things grep cannot: doc examples that no longer match
  the code (`stale_doc_example/4`), fan-in and fan-out, mutual
  recursion, god files

## Two front ends

One engine, two doors.

- `symbolic serve` — MCP over stdio, for agents. Connect one with
  `claude mcp add symbolic -- symbolic serve`
- `symbolic parse` / `symbolic query` — argv, for people
- both consult the same rules library, `.symbolic/rules.pl`

## How an agent uses it

```plantuml
!include docs/diagrams/agent-architecture.plantuml
```

- The system prompt is the discipline: parse before query, one goal
  per question, every claim carries the goal and the bindings it
  returned, and a failure is reported as an answer, never guessed
  around
- The MCP server is the hands: exactly three tools — parse, overview,
  query — JSON over stdio, nothing else for the agent to misuse
- The rules file is shared judgment: the same 88 lint checks answer
  CI and the agent, so a finding and its explanation come from one
  fact base
- The agent never reads source to answer a codebase question; it
  writes a goal and the engine proves it
