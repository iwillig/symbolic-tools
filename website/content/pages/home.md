Title: symbolic-tools
Slug: home
Save_as: index.html
URL:

## Introduction

symbolic-tools builds a Prolog database from your codebase. An LLM agent,
or a person, can query it and get an answer proven by resolution.

It parses a source tree with tree-sitter. It extracts facts: function
definitions, call sites, comments, decision points. It loads those facts
into an in-process Prolog engine ([erlog](https://github.com/rvirding/erlog),
running on the BEAM). You can then ask it a real question and get an
answer proven by resolution, not guessed from a snippet.

The examples below are live queries against this project's own source
tree, not made up — the same JSON an agent gets back from a real tool
call. Several are things an ESLint-style, per-file AST rule has no way
to express at all, not just a rule nobody wrote yet. Every fact family
in [the schema](#schema) has a query of its own.

## Get started

```sh
brew tap iwillig/symbolic-tools https://github.com/iwillig/symbolic-tools
brew trust iwillig/symbolic-tools
brew install symbolic-tools
```

```sh
claude mcp add symbolic -- symbolic serve
```

`/mcp` inside Claude Code shows `symbolic` connected, with its three
tools: `parse`, `query`, `overview`. Building from source instead, or
wiring a project-shared `.mcp.json` for a whole team? See
`docs/claude-code-mcp-setup.md` in the
[GitHub repository](https://github.com/iwillig/symbolic-tools).

## Why Prolog

Research on pairing language models with a symbolic reasoner has found
large accuracy gains on problems that need multi-step logical
correctness. symbolic-tools applies this to codebases. Build the fact
base once. Let a query prove the answer against it.

## How it works

<p>A rules library sits on top of the raw facts. It finds dead code,
duplicate names, mutual recursion, undocumented functions, and
oversized or overly complex definitions. Each rule is a few more Prolog
clauses over the same facts. The full fact schema — every predicate,
and a real, live example of each — is <a href="#schema">below</a>.</p>

<div>
  <img class="diagram-light" src="theme/img/architecture-light.svg" alt="Architecture: source files are parsed by a tree-sitter extractor into facts, loaded into a Prolog session (erlog), queried by an MCP server or the symbolic CLI">
  <img class="diagram-dark" src="theme/img/architecture-dark.svg" alt="Architecture: source files are parsed by a tree-sitter extractor into facts, loaded into a Prolog session (erlog), queried by an MCP server or the symbolic CLI">
</div>

## What it can answer

### What calls this function

```prolog
?- calls(Caller, CallerArity, local(git_sha, 0), File, Line).
```

```json
{
  "count": 1,
  "limit": 50,
  "solutions": [
    {
      "Caller": "info",
      "CallerArity": 0,
      "File": "src/symbolic_version.erl",
      "Line": 22
    }
  ],
  "truncated": false
}
```

### Which functions have no doc comment

```prolog
?- undocumented(walk_pair, Arity, File, Line).
```

```json
{
  "count": 2,
  "limit": 50,
  "solutions": [
    { "Arity": 4, "File": "src/ts_extract_toml.erl", "Line": 85 },
    { "Arity": 4, "File": "src/ts_extract_json.erl", "Line": 69 }
  ],
  "truncated": false
}
```

`walk_pair` is defined once in the JSON extractor and once in the TOML
extractor. Both come back, because the query doesn't care which file
it's in. (`undocumented/4` is a rule, not a raw fact — two clauses over
`defines/5` and `doc/5`.)

### Is this pair mutually recursive and undocumented

Combined with a mutual-recursion check, one goal proves both halves of
the claim at once:

```prolog
?- once((mutual_recursion(walk_object, walk_pair),
         undocumented(walk_object, Arity, File, Line))).
```

```json
{
  "count": 1,
  "limit": 50,
  "solutions": [
    { "Arity": 4, "File": "src/ts_extract_json.erl", "Line": 64 }
  ],
  "truncated": false
}
```

`walk_object` and `walk_pair` call each other, and `walk_object` has no
doc comment. The engine performs the join. Nothing here was pieced
together from two separate lookups. (`once/1` here only trims duplicate
solutions from the same fact appearing on more than one call site — not
hiding a different answer.)

### Does this function eventually touch the filesystem or the shell

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
a rule applied one file at a time — the kind of question a separate
whole-program tool (madge, dependency-cruiser) exists to bolt on
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

`line/1` — a small line-number helper — is called from 53 distinct
places across the codebase. Ranking every function in the project by
how many places call it is one goal, not a separate static-analysis
pass. `Top`'s own shape is real too, not simplified for this page:
erlog keeps Prolog's `-` as an ordinary 2-argument functor, so
`53-line/1` prints as nested `["-", ...]` arrays, the same way every
other `-`-joined result would if shown raw.

### Did the implementation match the plan

A plan is a claim about code that doesn't exist yet. Once the code
exists, it's exactly as checkable as any other claim.

Before writing `atom_from_binary/2` (a small addition bridging free
text back to a real function name — free text like `doc/5`'s `Text` is
a binary, and a function name is an atom, so the two can never unify
without a bridge), the plan named six specific things the new
code would do, including one written in on purpose to be wrong:

```
atom_from_binary_2/3 calls unify/3
atom_from_binary_2/3 calls binary_to_existing_atom/2
atom_from_binary_2/3 calls binary_to_atom/2      <- written in wrong, on purpose
```

After writing the code, each line became a real check against it, not a
re-reading of the diff:

```sh
$ symbolic check "atom_from_binary_2/3 calls unify/3" -db facts.dets
```

```json
{
  "fact": ["svo", ["/", "atom_from_binary_2", 3], "calls", ["/", "unify", 3]],
  "verdict": "true"
}
```

```sh
$ symbolic check "atom_from_binary_2/3 calls binary_to_atom/2" -db facts.dets
```

```json
{
  "fact": ["svo", ["/", "atom_from_binary_2", 3], "calls", ["/", "binary_to_atom", 2]],
  "verdict": "false"
}
```

The second one is the point. Written into the plan deliberately wrong,
before any code existed, to check that this catches a bad prediction
and not just confirms good ones. It did. Every other claim in the plan
matched what actually shipped.

<a id="schema"></a>

## The fact schema

Every fact `symbolic-tools` extracts is a plain Prolog term — no ID to
generate, no join to write by hand. A shared `(Function, Arity, File)`
(or `File` alone, for free text and Markdown) is what lets two families
be queried together at all: `calls/5` and `doc/5` both key on it, so a
variable shared across two goals *is* the join.

Every example below is a real, live query, shown exactly as the MCP
server returns it. The Erlang and Markdown examples run against this
project's own `src/` and `docs/`; the TypeScript and config examples
run against the small, committed fixtures in
[`website/examples/`](https://github.com/iwillig/symbolic-tools/tree/main/website/examples),
so any reader with the repository can reproduce every single one. Long
solution lists are trimmed with the real `count` kept, and the note
says so. Nothing here is illustrative pseudocode.

Where a result prints as nested `["-", ...]` arrays (or `["/", ...]`),
that is raw erlog too: it keeps Prolog's `-` and `/` as ordinary
functors, so `45-line/1` prints as it resolves.

### Code facts

#### `defines(Function, Arity, Params, File, Line)`

A function or method definition. `Params` is the raw parameter-list
text, not parsed further.

```prolog
?- defines(git_sha, 0, Params, File, Line).
```

```json
{
  "count": 1,
  "limit": 50,
  "solutions": [
    {
      "File": "src/symbolic_version.erl",
      "Line": 46,
      "Params": "()"
    }
  ],
  "truncated": false
}
```

#### `calls(Caller, CallerArity, CallSpec, File, Line)`

One call site, inside `Caller`. `CallSpec` is a nested term, not a
string, so a goal can match *part* of it and leave the rest wild:

```prolog
local(Name, ArgCount)               % bar()
remote(Module, Function, ArgCount)  % mod:fun(), or Module.fun() in TS
member(Object, Method, ArgCount)    % obj.method()
new(Constructor, ArgCount)          % new Ctor()   — TypeScript only
```

One goal, all four shapes, against a five-line fixture:

```prolog
?- calls(foo, 1, Spec, File, Line).
```

```json
{
  "count": 4,
  "limit": 50,
  "solutions": [
    {
      "File": "website/examples/calls.ts",
      "Line": 4,
      "Spec": ["member", "this.baz", "qux", 2]
    },
    {
      "File": "website/examples/calls.ts",
      "Line": 3,
      "Spec": ["member", "file", "read", 1]
    },
    {
      "File": "website/examples/calls.ts",
      "Line": 5,
      "Spec": ["new", "Error", 1]
    },
    {
      "File": "website/examples/calls.ts",
      "Line": 2,
      "Spec": ["local", "bar", 1]
    }
  ],
  "truncated": false
}
```

`calls(_, _, member(Object, hasOwnProperty, _), _, _)` finds every call
to a method named `hasOwnProperty`, on any object, in one goal —
matching regardless of which extractor produced the call site, because
every extractor emits the same `CallSpec` shapes.

#### `fun_ref(Function, Arity, File, Line)`

Erlang only. One fact per `fun Name/Arity` reference — a real
reference to a local function that is **never a `call` node**, so the
`calls/5` family cannot see it.

```prolog
?- fun_ref(scan_one, 1, File, Line).
```

```json
{
  "count": 1,
  "limit": 50,
  "solutions": [
    {
      "File": "src/symbolic_parse.erl",
      "Line": 167
    }
  ],
  "truncated": false
}
```

That fact is the one that saved `scan_one/1`'s life: `scan_paths/1`
calls it as `parallel_map(fun scan_one/1, Paths)`, no `calls/5` fact
ever existed for it, and the dead-code rule once reported this
codebase's own live function as dead. A `fun Name/Arity` reference is
a reference; now the rules know it.

#### `export(Function, Arity, File, Line)`

An Erlang `-export` list entry.

```prolog
?- export(git_sha, Arity, File, Line).
```

```json
{
  "count": 1,
  "limit": 50,
  "solutions": [
    { "Arity": 0, "File": "src/symbolic_version.erl", "Line": 14 }
  ],
  "truncated": false
}
```

#### `doc(Function, Arity, File, Line, Text)`

The comment immediately before a definition, flattened to one line.
`Text` is a binary, not an atom — free text is never unified against a
literal the way an identifier is, so there's no reason to force it
through `list_to_atom/1` (and every reason not to — see `comment/3`
below). TypeScript first, then Erlang — one family, both extractors:

```prolog
?- doc(add, Arity, File, Line, Text).
```

```json
{
  "count": 1,
  "limit": 50,
  "solutions": [
    {
      "Arity": 2,
      "File": "website/examples/doc.ts",
      "Line": 6,
      "Text": "Adds two numbers together. @param x - the first number @param y - the second number"
    }
  ],
  "truncated": false
}
```

(against the four-line JSDoc comment in
`website/examples/doc.ts` — `doc/5` flattens it to one, which is why
`Text` runs on past where a person would have put a line break.)

```prolog
?- doc(prove_reply, 3, File, Line, Text).
```

```json
{
  "count": 1,
  "limit": 50,
  "solutions": [
    {
      "File": "src/prolog_session.erl",
      "Line": 151,
      "Text": "The proof outcome ladder, extracted from handle_call/3 so the dispatcher reads as dispatch: one line per outcome, no triple-nested case. Every outcome pairs with the session state it leaves behind — a successful proof advances Erl to Erl1; every failure (including timeout and a killed worker) returns the state UNCHANGED, the \"a killed query never advances or corrupts the session\" guarantee prove_with_timeout/3 already makes (§8)."
    }
  ],
  "truncated": false
}
```

#### `doc_tag(Function, Arity, TagName, Type, Name, Description, File, Line)`

A JSDoc comment's own `@`-tags, structured — `doc/5` says a comment
documents a function and gives its flattened text; this says what the
comment's `@param`/`@returns`/etc. tags actually structured.

```prolog
?- doc_tag(add, Arity, Tag, Type, Name, Desc, File, Line).
```

```json
{
  "count": 2,
  "limit": 50,
  "solutions": [
    { "Arity": 2, "Desc": "- the first number",  "File": "website/examples/doc.ts", "Line": 3, "Name": "x", "Tag": "@param", "Type": "none" },
    { "Arity": 2, "Desc": "- the second number", "File": "website/examples/doc.ts", "Line": 4, "Name": "y", "Tag": "@param", "Type": "none" }
  ],
  "truncated": false
}
```

#### `comment(File, Line, Text)`

Every comment, attributed to a definition or not — one fact per raw
comment line, distinct from `doc/5`'s flattened multi-line association.

```prolog
?- comment('src/symbolic_version.erl', 1, Text).
```

```json
{
  "count": 1,
  "limit": 50,
  "solutions": [
    { "Text": "@doc Build identity of the *running* symbolic_tools code itself —" }
  ],
  "truncated": false
}
```

#### `branch(Function, Arity, Kind, File, Line)`

One decision point — a `case`/`if`/`&&`/`||`/etc. `Kind` is the
specific construct.

```prolog
?- branch(scan, 1, Kind, File, Line).
```

```json
{
  "count": 4,
  "limit": 50,
  "solutions": [
    { "File": "src/symbolic_parse.erl", "Kind": "cr_clause", "Line": 46 },
    { "File": "src/symbolic_parse.erl", "Kind": "cr_clause", "Line": 43 },
    { "File": "src/symbolic_parse.erl", "Kind": "cr_clause", "Line": 34 },
    { "File": "src/symbolic_parse.erl", "Kind": "cr_clause", "Line": 32 }
  ],
  "truncated": false
}
```

`scan/1` has four separate case-clause branch points — this is the raw
material `too_complex/3`/`real_complexity/4` in the rules library turn
into a single complexity count.

### Expression facts (Erlang and TypeScript)

`expr(Id, Function, Arity, Kind, File, Line)` — what a decision point
actually *compares*, not just that one exists. `Id` is a
`{File, StartByte, EndByte}` span, shared with `expr_operator/2` (which
operator: `==`, `<`, `&&`, ...), `expr_operand/3` (`left`/`right`/
`operand`, or a 0-based argument index for a call), and `literal/8` (a
literal value — `number`/`string`/`boolean`/`null` for TypeScript,
`integer`/`float`/`atom`/`string` for Erlang). This is what lets
`.symbolic/rules.pl` express `self_compare/5` ("`x == x`", always true
or always false) and `yoda_condition/5` ("`1 == x`" instead of
"`x == 1`") as a few lines of Prolog over facts, not a special-cased
AST visitor per rule.

The shared `Id` is the join — one goal reaches across the family:

```prolog
?- expr(Id, foo, 1, binary, 'website/examples/expr.ts', Line),
   expr_operator(Id, Op).
```

```json
{
  "count": 1,
  "limit": 50,
  "solutions": [
    {
      "Id": ["website/examples/expr.ts", 27, 33],
      "Line": 2,
      "Op": "=="
    }
  ],
  "truncated": false
}
```

The same `Id` carries the operands and literals of that one `==`
expression. Every literal in the fixture, with what each one actually
is — not just that a value appears:

```prolog
?- literal(Id, Fun, Arity, Kind, Value, 'website/examples/expr.ts', Line, Text).
```

```json
{
  "count": 4,
  "limit": 50,
  "solutions": [
    {
      "Arity": 1, "Fun": "shout",
      "Id": ["website/examples/expr.ts", 213, 216],
      "Kind": "string", "Line": 14, "Text": "\"!\"", "Value": "!"
    },
    {
      "Arity": 1, "Fun": "greet",
      "Id": ["website/examples/expr.ts", 146, 151],
      "Kind": "string", "Line": 11, "Text": "\"hi \"", "Value": "hi "
    },
    {
      "Arity": 0, "Fun": "other",
      "Id": ["website/examples/expr.ts", 69, 70],
      "Kind": "number", "Line": 5, "Text": "1", "Value": 1
    },
    {
      "Arity": 1, "Fun": "foo",
      "Id": ["website/examples/expr.ts", 27, 33],
      "Kind": "number", "Line": 2, "Text": "1", "Value": 1
    }
  ],
  "truncated": false
}
```

### Scope facts (TypeScript only)

Every other family above is about *functions*. This one is about
*variables* — deliberately TypeScript-only, since Erlang's
single-assignment, pattern-bound variable model has no `var`/`let`/
`const` distinction and no mutation to track in the first place.

- **`scope(ScopeId, Kind, ParentScopeId, File)`** — `function`, `block`,
  or `module`.
- **`var_decl(Id, Name, Kind, ScopeId, File, Line)`** — `Kind` is
  `` 'var' ``, `` 'let' ``, `const`, `param`, or `import`.
- **`var_ref(Id, Name, ScopeId, RefKind, File, Line)`** — `read`,
  `write`, or `read_write` (`+=` and friends).
- **`resolves_to(RefId, DeclId)`** — which declaration a reference
  actually binds to, computed once by the extractor's own scope-chain
  walk, not left for a query to re-derive.

A three-way join across the family — every `read` of a variable in the
fixture, each resolved back to the declaration it actually binds to:

```prolog
?- var_ref(Id, Name, _, read, 'website/examples/scope.ts', Line),
   resolves_to(Id, DeclId),
   var_decl(DeclId, Name, DeclKind, _, _, DeclLine).
```

```json
{
  "count": 2,
  "limit": 50,
  "solutions": [
    {
      "DeclId": ["website/examples/scope.ts", 31, 38],
      "DeclKind": "const",
      "DeclLine": 2,
      "Id": ["website/examples/scope.ts", 64, 71],
      "Line": 3,
      "Name": "message"
    },
    {
      "DeclId": ["website/examples/scope.ts", 15, 19],
      "DeclKind": "param",
      "DeclLine": 1,
      "Id": ["website/examples/scope.ts", 49, 53],
      "Line": 2,
      "Name": "name"
    }
  ],
  "truncated": false
}
```

Against `function greet(name) { const message = "hi " + name; return
message; }` — each reference correctly walks back to its own
declaration, not just any variable of the same name. `unused_var/4`,
`shadowed_var/5`, `prefer_const/4`, and four more rules in
`.symbolic/rules.pl` all sit directly on these four facts — no new
extraction needed to add another scope-shaped lint check.

### Statement facts (TypeScript only)

`stmt_block(Id, Function, Arity, Kind, File, Line)` / `stmt(...)` /
`return_stmt(Function, Arity, HasValue, File, Line)` — statement
position within a block.

```prolog
?- return_stmt(shout, Arity, HasValue, File, Line).
```

```json
{
  "count": 2,
  "limit": 50,
  "solutions": [
    { "Arity": 1, "File": "website/examples/stmt.ts",   "HasValue": "true", "Line": 4 },
    { "Arity": 1, "File": "website/examples/expr.ts",   "HasValue": "true", "Line": 14 }
  ],
  "truncated": false
}
```

Two solutions because two different files in the examples directory
each define a `shout/1` that returns a value — the query has no `File`
bound, so both come back, exactly as `walk_pair` did on the homepage.

`import_decl(Module, File, Line)` / `export_decl(Name, Kind, File,
Line)`:

```prolog
?- import_decl(Module, File, Line).
```

```json
{
  "count": 3,
  "limit": 50,
  "solutions": [
    { "Module": "lodash", "File": "website/examples/importexport.ts", "Line": 1 },
    { "Module": "./ns",   "File": "website/examples/importexport.ts", "Line": 3 },
    { "Module": "./bar",  "File": "website/examples/importexport.ts", "Line": 2 }
  ],
  "truncated": false
}
```

```prolog
?- export_decl(Name, Kind, File, Line).
```

```json
{
  "count": 5,
  "limit": 50,
  "solutions": [
    { "Name": "x",       "Kind": "named",   "File": "website/examples/importexport.ts", "Line": 9 },
    { "Name": "x",       "Kind": "named",   "File": "website/examples/importexport.ts", "Line": 5 },
    { "Name": "g",       "Kind": "named",   "File": "website/examples/importexport.ts", "Line": 9 },
    { "Name": "f",       "Kind": "named",   "File": "website/examples/importexport.ts", "Line": 7 },
    { "Name": "default", "Kind": "default", "File": "website/examples/importexport.ts", "Line": 10 }
  ],
  "truncated": false
}
```

An import binding is stored as an ordinary `var_decl/6` with
`Kind = import` — deliberately the same fact shape as any other
declaration, not a parallel one, so `unused_var/4` already applies to
an unused import with no extra rule.

### Markdown facts

The block-grammar structure of a `.md` file — headings, sections, code
blocks, paragraphs, lists, tables, blockquotes, and reference-style
link definitions.

#### `heading(File, Level, Text, Line)` and `section(File, Level, StartLine, EndLine)`

ATX (`# Title`) and setext (`Title` + `===`/`---`) headings both. A
`section` is a heading plus everything under it, nested by level
exactly like a real document outline — the only fact in this family
that relates anything to *which heading it's under*.

Every level-2 heading of this project's own schema reference doc:

```prolog
?- heading('docs/prolog-schema.md', 2, Text, Line).
```

```json
{
  "count": 7,
  "limit": 50,
  "solutions": [
    { "Line": 796, "Text": "What's deliberately not here yet" },
    { "Line": 810, "Text": "References" }
  ],
  "truncated": false
}
```

(two of the seven real solutions shown.)

And the whole document, as one span:

```prolog
?- section('docs/prolog-schema.md', 1, Start, End).
```

```json
{
  "count": 1,
  "limit": 50,
  "solutions": [
    { "End": 830, "Start": 1 }
  ],
  "truncated": false
}
```

#### `code_block(File, Lang, Line)`

Fenced and indented code blocks both; `Lang` is `none` for a bare
fence or an indented block, which never declares one. Both Prolog
blocks in another of this project's own docs:

```prolog
?- code_block('docs/tree-sitter-markdown.md', Lang, Line).
```

```json
{
  "count": 2,
  "limit": 50,
  "solutions": [
    { "Lang": "prolog", "Line": 229 },
    { "Lang": "prolog", "Line": 213 }
  ],
  "truncated": false
}
```

#### `paragraph(File, Text, Line)`

One fact per prose block, `Text` flattened to one line:

```prolog
?- paragraph('docs/cli-erlang.md', Text, 3).
```

```json
{
  "count": 1,
  "limit": 50,
  "solutions": [
    {
      "Text": "This document covers how the symbolic-tools **command-line tool** (`symbolic`) is structured, built, and shipped. It is the Erlang counterpart to the MCP server in [`erlang-mcp-design.md`](erlang-mcp-design.md) and the extraction layer in [`tree-sitter-erlang.md`](tree-sitter-erlang.md): the CLI and the MCP server share the same core modules and differ only in the front end (argv vs. MCP messages). A design/research document only — no CLI is implemented here."
    }
  ],
  "truncated": false
}
```

#### `list_item(File, Ordered, Checked, Line)`

`Ordered` is `ordered`/`unordered`; `Checked` is `checked`/`unchecked`
for a GFM task item, or `none`. Every list item in the benchmarking
doc:

```prolog
?- list_item('docs/benchmarking.md', Ord, Checked, Line).
```

```json
{
  "count": 4,
  "limit": 50,
  "solutions": [
    { "Checked": "none", "Line": 98, "Ord": "unordered" },
    { "Checked": "none", "Line": 95, "Ord": "unordered" },
    { "Checked": "none", "Line": 48, "Ord": "unordered" },
    { "Checked": "none", "Line": 46, "Ord": "unordered" }
  ],
  "truncated": false
}
```

#### `table(File, Line)` / `table_row(File, TableLine, RowIndex, Line)` / `table_cell(File, TableLine, Row, Col, Text, Line)`

A GFM pipe table; row 0 is always the header, the alignment row is
skipped entirely. This project's CLI doc has two; the header row of
the first, cell by cell:

```prolog
?- table_cell('docs/cli-erlang.md', 22, 0, Col, Text, Line).
```

```json
{
  "count": 3,
  "limit": 50,
  "solutions": [
    { "Col": 2, "Line": 22, "Text": "Use when" },
    { "Col": 1, "Line": 22, "Text": "What it is" },
    { "Col": 0, "Line": 22, "Text": "Model" }
  ],
  "truncated": false
}
```

#### `blockquote(File, Text, Line)`

A real one, quoting the rule this very engine learned the hard way:

```prolog
?- blockquote('docs/erlang-mcp-design.md', Text, 132).
```

```json
{
  "count": 1,
  "limit": 50,
  "solutions": [
    {
      "Text": "Recursive predicates over possibly-cyclic graphs MUST be tabled: `:- table pred/arity.`"
    }
  ],
  "truncated": false
}
```

#### `link_definition(File, Label, Destination, Title, Line)`

A reference-style link *definition* (`[label]: url "title"`), not a
*use* — an inline `[text](url)` link still needs a second, undone
parse pass over tree-sitter-markdown's separate inline grammar. This
project's docs use inline links throughout, so no live instance exists
in the examples' base; the fact shape is exactly as above with `Label`,
`Destination` and `Title` as binaries, like every other free-text
field.

### Markdown example facts

The strongest fact family for documentation drift: a fenced block
tagged `erlang`/`ts`/`typescript`/`sh`/`bash` inside a `.md` file is
re-parsed by the real language extractor, with `File` set to the
Markdown file itself — code that appears only in prose becomes
queryable facts like any other.

#### `example_defines(Function, Arity, Params, File, Line)`

Every function the TypeScript lint-rule examples in
`docs/lint-queries.md` define, as facts:

```prolog
?- example_defines(F, A, Params, 'docs/lint-queries.md', Line).
```

```json
{
  "count": 5,
  "limit": 50,
  "solutions": [
    { "A": 1, "F": "validate",    "Line": 953,  "Params": "(count: number)" },
    { "A": 1, "F": "total",       "Line": 894,  "Params": "(items: number[])" },
    { "A": 1, "F": "f",           "Line": 1104, "Params": "(a: number)" },
    { "A": 2, "F": "checkAccess", "Line": 847,  "Params": "(userId: number, allowedId: number)" },
    { "A": 1, "F": "buildClient", "Line": 1002, "Params": "(pattern: string)" }
  ],
  "truncated": false
}
```

#### `example_calls(Caller, CallerArity, CallSpec, File, Line)`

Same shape as `calls/5`, but for the code inside a doc example:

```prolog
?- example_calls(validate, 1, Spec, 'docs/lint-queries.md', Line).
```

```json
{
  "count": 1,
  "limit": 50,
  "solutions": [
    { "Line": 957, "Spec": ["member", "console", "log", 1] }
  ],
  "truncated": false
}
```

#### `stale_doc_example/4` — the rule built on both

An `example_defines` fact whose function exists nowhere in the real
code: shown in an example, never implemented. One rule joins the two
families across a whole parse:

```prolog
stale_doc_example(Fun, Arity, DocFile, Line) :-
    example_defines(Fun, Arity, _, DocFile, Line),
    \+ defines(Fun, Arity, _, _, _).
```

```prolog
?- stale_doc_example(charge, 2, DocFile, Line).
```

```json
{
  "count": 1,
  "limit": 50,
  "solutions": [
    { "DocFile": "/Users/iwillig/dev/symbolic-tools/docs/agent-examples.md", "Line": 20 }
  ],
  "truncated": false
}
```

`charge/2` is the illustrative "risky call" function in the
agent-examples doc — real enough to have facts, fictional enough that
no code implements it, and the query says exactly which and where.
(The absolute path is raw output too: a config-driven parse normalizes
project paths to absolute, while a direct directory parse keeps the
path as given — the `src/...` and `docs/...` paths above are from
direct directory parses.)

### Config facts (TOML and JSON — same two predicates for both)

- **`config_value(File, Path, Value, Line)`**
- **`config_section(File, Path, Line)`**

One dotted `Path` atom for either format — a TOML `[[servers]]` array
of tables and a JSON nested object both flatten to the same
`section.field`-shaped key, so a query written against one format works
unchanged against the other. Both fixtures at once, one goal:

```prolog
?- config_value(File, Path, Value, Line).
```

```json
{
  "count": 6,
  "limit": 50,
  "solutions": [
    { "File": "website/examples/package.json", "Line": 3, "Path": "version",            "Value": "1.0.0" },
    { "File": "website/examples/package.json", "Line": 2, "Path": "name",                "Value": "widget" },
    { "File": "website/examples/package.json", "Line": 5, "Path": "dependencies.rebar3", "Value": "^3.24" },
    { "File": "website/examples/config.toml",  "Line": 1, "Path": "title",               "Value": "My Project" },
    { "File": "website/examples/config.toml",   "Line": 7, "Path": "servers.host",        "Value": "alpha" },
    { "File": "website/examples/config.toml",  "Line": 4, "Path": "owner.name",           "Value": "Tom" }
  ],
  "truncated": false
}
```

```prolog
?- config_section(File, Path, Line).
```

```json
{
  "count": 3,
  "limit": 50,
  "solutions": [
    { "File": "website/examples/package.json", "Line": 4, "Path": "dependencies" },
    { "File": "website/examples/config.toml",  "Line": 6, "Path": "servers" }
  ],
  "truncated": false
}
```

(two of the three real solutions shown.)

## Status

Early implementation. Under active development. See the
[GitHub repository](https://github.com/iwillig/symbolic-tools) for the
full README, the Prolog fact schema, and the rules library.
