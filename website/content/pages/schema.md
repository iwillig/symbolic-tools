Title: The Fact Schema
Slug: schema

Every fact `symbolic-tools` extracts is a plain Prolog term — no ID to
generate, no join to write by hand. A shared `(Function, Arity, File)`
(or `File` alone, for free text and Markdown) is what lets two families
be queried together at all: `calls/5` and `doc/5` both key on it, so a
variable shared across two goals *is* the join.

Every example below is a real, live query, shown exactly as the MCP
server returns it — either against this project's own `src/`, or
against a small fixture written to exercise one specific shape. Nothing
here is illustrative pseudocode.

## Code facts

### `defines(Function, Arity, Params, File, Line)`

A function or method definition. `Params` is the raw parameter-list
text, not parsed further.

### `calls(Caller, CallerArity, CallSpec, File, Line)`

One call site, inside `Caller`. `CallSpec` is a nested term, not a
string, so a goal can match *part* of it and leave the rest wild:

```prolog
local(Name, ArgCount)               % bar()
remote(Module, Function, ArgCount)  % mod:fun(), or Module.fun() in TS
member(Object, Method, ArgCount)    % obj.method()
new(Constructor, ArgCount)          % new Ctor()   — TypeScript only
```

Real examples of each shape, from this project's own source and a
small TypeScript fixture:

```prolog
?- calls(Caller, CallerArity, local(git_sha, 0), File, Line).
```

```json
{
  "count": 1,
  "limit": 50,
  "truncated": false,
  "solutions": [
    {
      "Caller": "info",
      "CallerArity": 0,
      "File": "src/symbolic_version.erl",
      "Line": 18
    }
  ]
}
```

```prolog
?- calls(foo, 1, member(Object, Method, N), File, Line).
```

```json
{
  "count": 1,
  "limit": 50,
  "truncated": false,
  "solutions": [
    {
      "File": "calls.ts",
      "Line": 2,
      "Method": "qux",
      "N": 2,
      "Object": "this.baz"
    }
  ]
}
```

(against `function foo(a) { this.baz.qux(a, a); }`.)

`calls(_, _, member(Object, hasOwnProperty, _), _, _)` finds every call
to a method named `hasOwnProperty`, on any object, in one goal —
matching regardless of which extractor produced the call site, because
every extractor emits the same `CallSpec` shapes.

### `export(Function, Arity, File, Line)`

An Erlang `-export` list entry.

```prolog
?- export(git_sha, Arity, File, Line).
```

```json
{
  "count": 1,
  "limit": 50,
  "truncated": false,
  "solutions": [
    { "Arity": 0, "File": "src/symbolic_version.erl", "Line": 14 }
  ]
}
```

### `doc(Function, Arity, File, Line, Text)`

The comment immediately before a definition, flattened to one line.
`Text` is a binary, not an atom — free text is never unified against a
literal the way an identifier is, so there's no reason to force it
through `list_to_atom/1` (and every reason not to — see `comment/3`
below).

```prolog
?- doc(add, Arity, File, Line, Text).
```

```json
{
  "count": 1,
  "limit": 50,
  "truncated": false,
  "solutions": [
    {
      "Arity": 2,
      "File": "doc.ts",
      "Line": 6,
      "Text": "Adds two numbers together. @param x - the first number @param y - the second number"
    }
  ]
}
```

(against a JSDoc comment written across four source lines — `doc/5`
flattens it to one, which is why `Text` runs on past where a person
would have put a line break.)

### `comment(File, Line, Text)`

Every comment, attributed to a definition or not — one fact per raw
comment line, distinct from `doc/5`'s flattened multi-line association.

### `branch(Function, Arity, Kind, File, Line)`

One decision point — a `case`/`if`/`&&`/`||`/etc. `Kind` is the specific
construct.

```prolog
?- findall(Kind, branch(scan, 1, Kind, _, _), L), length(L, N).
```

```json
{
  "count": 1,
  "limit": 50,
  "truncated": false,
  "solutions": [
    { "N": 4 }
  ]
}
```

`scan/1` has four separate case-clause branch points — this is the raw
material `too_complex/3`/`real_complexity/4` in the rules library turn
into a single complexity count.

## Expression facts (Erlang and TypeScript)

`expr(Id, Function, Arity, Kind, File, Line)` — what a decision point
actually *compares*, not just that one exists. `Id` is a `{File,
StartByte, EndByte}` span, shared with `expr_operator/2` (which operator:
`==`, `<`, `&&`, ...), `expr_operand/3` (`left`/`right`/`operand`, or a
0-based argument index for a call), and `literal/8` (a literal value —
`number`/`string`/`boolean`/`null` for TypeScript, `integer`/`float`/
`atom`/`string` for Erlang). This is what lets `.symbolic/rules.pl`
express `self_compare/5` ("`x == x`", always true or always false) and
`yoda_condition/5` ("`1 == x`" instead of "`x == 1`") as a few lines of
Prolog over facts, not a special-cased AST visitor per rule.

```prolog
?- findall(Fun/Arity-Kind, expr(_, Fun, Arity, Kind, _, _), L).
```

```json
{
  "count": 1,
  "limit": 50,
  "truncated": false,
  "solutions": [
    {
      "L": [
        ["-", ["/", "shout", 1], "binary"],
        ["-", ["/", "shout", 1], "call"],
        ["-", ["/", "greet", 1], "binary"],
        ["-", ["/", "other", 0], "call"],
        ["-", ["/", "add", 2], "binary"],
        ["-", ["/", "foo", 1], "call"]
      ]
    }
  ]
}
```

(against a small fixture with `foo`, `other`, `add`, `greet`, and
`shout` functions — `shout`'s own `capitalize(word) + "!"` is both a
`call` and a `binary` expression at once, exactly as written. `L`'s own
shape is raw too: erlog keeps `/` and `-` as ordinary functors, so
`shout/1-binary` prints as nested `["-", ["/", ...], ...]` arrays, the
same quirk as `top_fan_in/2`'s result on the [homepage](/).)

## Scope facts (TypeScript only)

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

```prolog
?- var_ref(Id, Name, _, read, File, Line),
   resolves_to(Id, DeclId),
   var_decl(DeclId, Name, DeclKind, _, _, DeclLine).
```

```json
{
  "count": 13,
  "limit": 50,
  "truncated": false,
  "solutions": [
    { "File": "scope.ts", "Name": "message", "Line": 3, "DeclKind": "const", "DeclLine": 2 },
    { "File": "scope.ts", "Name": "name",    "Line": 2, "DeclKind": "param", "DeclLine": 1 }
  ]
}
```

(two of the 13 real solutions shown — against `function greet(name) {
const message = "hi " + name; return message; }` — each reference
correctly walks back to its own declaration, not just any variable of
the same name; the other 11 are the same shape, one per parameter or
`const` read across the rest of this fixture directory.)

`unused_var/4`, `shadowed_var/5`, `prefer_const/4`, and four more rules
in `.symbolic/rules.pl` all sit directly on these four facts — no new
extraction needed to add another scope-shaped lint check.

## Statement and import/export facts (TypeScript only)

`stmt_block(Id, Function, Arity, Kind, File, Line)` / `stmt(...)` /
`return_stmt(Function, Arity, HasValue, File, Line)` — statement
position within a block.

```prolog
?- return_stmt(shout, Arity, HasValue, File, Line).
```

```json
{
  "count": 1,
  "limit": 50,
  "truncated": false,
  "solutions": [
    { "Arity": 1, "File": "stmt.ts", "HasValue": "true", "Line": 5 }
  ]
}
```

`import_decl(Module, File, Line)` / `export_decl(Name, Kind, File,
Line)`:

```prolog
?- import_decl(Module, File, Line).
```

```json
{
  "count": 3,
  "limit": 50,
  "truncated": false,
  "solutions": [
    { "Module": "lodash", "File": "importexport.ts", "Line": 1 },
    { "Module": "./bar",  "File": "importexport.ts", "Line": 2 },
    { "Module": "./ns",   "File": "importexport.ts", "Line": 3 }
  ]
}
```

```prolog
?- export_decl(Name, Kind, File, Line).
```

```json
{
  "count": 4,
  "limit": 50,
  "truncated": false,
  "solutions": [
    { "Name": "x",       "Kind": "named",   "File": "importexport.ts", "Line": 5 },
    { "Name": "x",       "Kind": "named",   "File": "importexport.ts", "Line": 11 },
    { "Name": "g",       "Kind": "named",   "File": "importexport.ts", "Line": 11 },
    { "Name": "default", "Kind": "default", "File": "importexport.ts", "Line": 12 }
  ]
}
```

(against `export const x = 1;` on line 5, then `export { x, f as g };`
and `export default f;` further down the same file.)

An import binding is stored as an ordinary `var_decl/6` with
`Kind = import` — deliberately the same fact shape as any other
declaration, not a parallel one, so `unused_var/4` already applies to an
unused import with no extra rule.

### `doc_tag(Function, Arity, TagName, Type, Name, Description, File, Line)`

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
  "truncated": false,
  "solutions": [
    { "Arity": 2, "Tag": "@param", "Type": "none", "Name": "x", "Desc": "- the first number",  "File": "doc.ts", "Line": 3 },
    { "Arity": 2, "Tag": "@param", "Type": "none", "Name": "y", "Desc": "- the second number", "File": "doc.ts", "Line": 4 }
  ]
}
```

## Markdown facts

The block-grammar structure of a `.md` file — headings, sections, code
blocks, lists, tables, blockquotes, and reference-style link
definitions. See the [homepage](/) for the live example of
`stale_doc_example/4` (a fenced code sample re-parsed as real code, then
checked against `defines/5`); the fact shapes underneath are:

- **`heading(File, Level, Text, Line)`** — ATX (`# Title`) and setext
  (`Title` + `===`/`---`) headings both.
- **`section(File, Level, StartLine, EndLine)`** — a heading plus
  everything under it, nested by level exactly like a real document
  outline. The only fact here that relates anything to *which heading
  it's under* — every other fact in this family is otherwise flat.
- **`code_block(File, Lang, Line)`** — fenced and indented code blocks
  both; `Lang` is `none` for a bare fence or an indented block, which
  never declares one.
- **`paragraph(File, Text, Line)`**
- **`list_item(File, Ordered, Checked, Line)`** — `Ordered` is
  `ordered`/`unordered`; `Checked` is `checked`/`unchecked` for a GFM
  task item, or `none`.
- **`table(File, Line)` / `table_row(File, TableLine, RowIndex, Line)` /
  `table_cell(File, TableLine, Row, Col, Text, Line)`** — a GFM pipe
  table; row 0 is always the header, the alignment row is skipped
  entirely.
- **`blockquote(File, Text, Line)`**
- **`link_definition(File, Label, Destination, Title, Line)`** — a
  reference-style link *definition* (`[label]: url "title"`), not a
  *use* — an inline `[text](url)` link still needs a second, undone
  parse pass over tree-sitter-markdown's separate inline grammar.
- **`example_defines/5` / `example_calls/5`** — a fenced block tagged
  `erlang`/`ts`/`typescript`/`sh`/`bash` re-parsed by the real language
  extractor, `File` set to the Markdown file itself.

```prolog
?- findall(Fun/Arity, stale_doc_example(Fun, Arity, _, _), L), length(L, N).
```

```json
{
  "count": 1,
  "limit": 50,
  "truncated": false,
  "solutions": [
    { "N": 26 }
  ]
}
```

Run against this project's own docs — 26 real cases, mostly
illustrative pseudocode a design note wrote by hand, correctly flagged
as "shown in an example, not real code."

## Config facts (TOML and JSON — same two predicates for both)

- **`config_value(File, Path, Value, Line)`**
- **`config_section(File, Path, Line)`**

```prolog
?- config_value(File, Path, Value, Line).
```

```json
{
  "count": 6,
  "limit": 50,
  "truncated": false,
  "solutions": [
    { "File": "config.toml",  "Path": "title",               "Value": "My Project", "Line": 1 },
    { "File": "config.toml",  "Path": "owner.name",           "Value": "Tom",        "Line": 4 },
    { "File": "config.toml",  "Path": "servers.host",         "Value": "alpha",      "Line": 7 },
    { "File": "package.json", "Path": "name",                 "Value": "widget",     "Line": 2 },
    { "File": "package.json", "Path": "version",               "Value": "1.0.0",     "Line": 3 },
    { "File": "package.json", "Path": "dependencies.rebar3",   "Value": "^3.24",     "Line": 5 }
  ]
}
```

One dotted `Path` atom either format — a TOML `[[servers]]` array of
tables and a JSON nested object both flatten to the same
`section.field`-shaped key, so a query written against one format works
unchanged against the other.
