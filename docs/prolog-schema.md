# Reference: The Prolog Fact Schema

Every other doc in this project explains *how* one extractor works, or
walks through *one* worked example. This one is different: it's the
complete data dictionary — every fact predicate `symbolic parse` can
produce, across every supported language, in one place. If you're
writing a query and need to know exactly what a predicate's arguments
mean, or what's deliberately *not* captured, start here.

For how these facts are stored and cached (not what they mean), see
[`prolog-store.md`](prolog-store.md). For worked examples of *using*
these facts, see [`agent-examples.md`](agent-examples.md) and
[`lint-queries.md`](lint-queries.md).

## At a glance

| Predicate | Produced by | Meaning |
|---|---|---|
| `defines/5` | Erlang, TypeScript, Bash | A named function/definition exists |
| `calls/5` | Erlang, TypeScript, Bash | A call site, shape varies per language |
| `comment/3` | Erlang, TypeScript, Bash | Every comment, unconditionally |
| `doc/5` | Erlang, TypeScript, Bash | A comment run immediately preceding a definition |
| `branch/5` | Erlang, TypeScript, Bash | A decision point inside a definition, for real complexity |
| `expr/6` | Erlang, TypeScript | A binary/unary expression, keyed on real node identity |
| `expr_operator/2` | Erlang, TypeScript | That expression's operator |
| `expr_operand/3` | Erlang, TypeScript | One operand's role and which node fills it |
| `literal/7` | Erlang, TypeScript | A literal value used as an operand |
| `expr_ref/6` | Erlang, TypeScript | A bare identifier used as an operand |
| `scope/4` | TypeScript | A function/block/module scope exists |
| `var_decl/6` | TypeScript | A variable/parameter is declared |
| `var_ref/6` | TypeScript | A variable is read and/or written |
| `resolves_to/2` | TypeScript | Which declaration a reference actually binds to |
| `var_decl_initialized/1` | TypeScript | That declaration has a "value" (an initializer) |
| `bare_new/5` | TypeScript | A `new X()` whose constructed value is discarded outright |
| `import_decl/4` | TypeScript | An `import` statement's raw module path |
| `export_decl/4` | TypeScript | A name a file makes public, and how |
| `stmt_block/6` | TypeScript | A `{}` block, `switch_case`, or `switch_default` exists |
| `stmt/6` | TypeScript | One direct statement inside a `stmt_block/6`, with its position |
| `last_switch_case/1` | TypeScript | That `switch_case`/`switch_default` has no case/default after it |
| `braceless_body/5` | TypeScript | An `if`/`else`/`for`/`while` whose body is a single bare statement |
| `return_stmt/5` | TypeScript | A `return`, and whether it specifies a value |
| `heading/4` | Markdown | An ATX (`#`) heading |
| `code_block/3` | Markdown | A fenced code block and its declared language |
| `paragraph/3` | Markdown | A paragraph (or list-item) of body text |
| `example_defines/5` | Markdown | A `defines/5`-equivalent, but from inside a fenced code sample |
| `example_calls/5` | Markdown | A `calls/5`-equivalent, but from inside a fenced code sample |
| `config_value/4` | TOML, JSON | A dotted key path resolving to a scalar value |
| `config_section/3` | TOML, JSON | A named table/object container exists |

Three genuinely different *shapes* of fact live in this one schema:
**code facts** (something with named definitions and call sites),
**Markdown structural facts** (a document's own headings/prose/fences),
and **config facts** (a key path resolving to a value) — see
`docs/tree-sitter-erlang.md` §5.1 for why config data needed a
different shape than code, and why Markdown needed a third one again.

There's also a cross-cutting **type** split, orthogonal to the three
shapes above: every predicate's short, query-literal-matched arguments
(function/module/callee names, file paths, config key paths, language
tags) are Erlang **atoms**; every predicate's free-text argument
(`comment/3`/`doc/5`/`heading/4`/`paragraph/3`'s `Text`,
`config_value/4`'s `Value`) is an Erlang **binary** instead — called out
at each predicate below, with the reasoning under `doc/5`. `defines/5`'s
`Params` is also free text, same reasoning, called out under `defines/5`
itself.

## Code facts: `defines/5`, `calls/5`, `comment/3`, `doc/5`

Produced by `src/ts_extract_erlang.erl`, `src/ts_extract_typescript.erl`,
and `src/ts_extract_bash.erl` — one query set per language (no shared
extraction code between them, a deliberate choice explained in each
module's own header), but the same four predicate names and arities
across all three, so a query written against one language's facts
reads the same way against another's.

### `defines(Function, Arity, Params, File, Line)`

- **`Function`** — the defined name, as an atom (`charge`, `deploy`).
- **`Arity`** — integer, from the definition node's own argument-list
  field (`function_clause`'s `"args"` field in Erlang,
  `function_declaration`'s `"parameters"` field in TypeScript) — that
  field's *named-child count*. A destructured pattern like `{Y,Z}` or
  `[H|T]` is still one named child, so one argument (confirmed
  empirically: `baz(X, {Y,Z}, [H|T])` → arity 3), matching real
  language semantics, not a naive token count. **`undefined` for Bash**
  — bash functions have no parameter-list grammar node at all; there is
  no arity to report.
- **`Params`** — binary, the argument-list field's own raw source text
  (e.g. `<<"(A, B)">>`, `<<"(word: string)">>`), so a query result shows
  not just how many arguments a function takes but what they are.
  **`undefined` for Bash**, same reason as `Arity`.
- **`File`** — the source file path, as an atom.
- **`Line`** — 1-based line number of the definition.

Module name is still not tracked (`Function` alone, not
`Module:Function/Arity`) — that part of the original Phase 1
simplification remains. Arity **is** now tracked (added after dogfooding
via `docs/lint-queries.md` found the gap): two same-named functions of
*different* arity in the same file (Erlang's `query/2` and `query/3`,
say) used to be indistinguishable from true recursion or genuine
duplication in any query that only looked at `Function` — `.symbolic/rules.pl`'s
`duplicate_name/3`, `self_recursive/3`, `fan_in/3`, `no_local_callers/3`
now key on `Fun`+`Arity` to avoid that.

### `calls(Caller, CallerArity, CallSpec, File, Line)`

- **`Caller`** — the enclosing definition's name, found by walking
  `node_parent/1` up from the call site to the nearest recognized
  definition node. The atom `undefined` if the call isn't inside any
  recognized definition (e.g. a bare top-level statement, or — a real
  quirk found via dogfooding — Erlang's `-spec` attributes: their type
  references parse identically to real calls, and always come back with
  `Caller = undefined` since a `-spec` lives outside any function
  clause; see `docs/lint-queries.md`).
- **`CallerArity`** — that same enclosing clause's arity (same source and
  same semantics as `defines/5`'s `Arity`, including `undefined` for
  Bash and wherever `Caller` itself is `undefined`). This is what a call
  site inside `query/1`'s body (which calls `query/2`) needs to stop
  being indistinguishable from a call site genuinely inside `query/2` —
  the other half of the arity-conflation gap `defines/5` alone didn't
  close. `.symbolic/rules.pl`'s `self_recursive/3` is the rule that actually
  needs this: it binds `CallerArity` equal to the definition's own
  `Arity`, requiring the call site to be textually inside *that exact*
  clause, not merely inside some same-named overload.
- **`CallSpec`** — the actual call's shape, and this is where the three
  languages genuinely differ (same pattern `config_value`'s `Path`
  takes per-format, just for a different reason — see below). Every
  shape's last argument is an `ArgCount` (integer): the call site's own
  argument-list field's named-child count — the number of arguments
  actually *passed*, not a validated arity (nothing here confirms it
  matches the callee's `defines` arity; that's a query you can now write
  yourself, joining on `Callee`/`Arity`).

  | Language | `CallSpec` shapes | Example |
  |---|---|---|
  | Erlang | `local(Callee, ArgCount)`, `remote(Module, Function, ArgCount)` | `local(bar, 1)`, `remote(io, format, 2)` |
  | TypeScript | `local(Callee, ArgCount)`, `member(Object, Method, ArgCount)`, `new(Constructor, ArgCount)` | `local(bar, 1)`, `member(console, log, 1)`, `new(RegExp, 1)` |
  | Bash | `local(Command, ArgCount)` only | `local(build, 0)` |

  Bash has no qualified-call syntax (nothing like `mod:fun()` or
  `obj.method()`) to tell a call to a same-script function apart from a
  call to an external program or a shell builtin — so it doesn't
  pretend to know the difference; `local(build, 0)` and `local(rsync, 3)`
  look exactly alike on purpose. Bash's `ArgCount` is also different in
  kind from the other two languages': it's a **word count** following
  the command name (`scp a b c` → `ArgCount` 3), not anything bash
  itself validates against a declared parameter list — bash functions
  accept any number of arguments always.

  `new(Constructor, ArgCount)` — `new X(...)`, modeled as one more
  `CallSpec` shape rather than a separate fact family, since it's
  conceptually a call, just spelled with `new`. Only a bare-identifier
  `Constructor` is tracked (`new foo.Bar()`'s qualified constructor is
  skipped, not mis-tracked). `new Baz` (no parens at all — real, legal
  TypeScript) gets `ArgCount` 0, same as `new Baz()` — its `arguments`
  field is null, and `symbolic_ts:node_named_child_count/1` on a null
  node **segfaults the whole BEAM process**, not a catchable Erlang
  error, confirmed the hard way; `ts_extract_typescript.erl`'s
  `new_expr_arg_count/1` checks `node_is_null/1` first specifically
  because of this. A bare call with no `new` at all (`RegExp(...)`)
  needs no special handling — it's already `local(RegExp, ArgCount)`
  via the existing `call_expression` query, unchanged.
- **`File`**, **`Line`** — same meaning as in `defines/5`, `Line` is the
  call site's own line.

### `bare_new(Caller, CallerArity, Constructor, File, Line)`

Only when a `new X()`'s constructed value is discarded outright — its
immediate parent is an `expression_statement`, e.g. `new Logger();` as
its own statement, not `const x = new Logger();` or `if (new Foo())`.
The one thing about a `new` expression that `calls/5`'s `new(...)`
shape alone can't answer: whether the constructed value goes anywhere.
Powers `.symbolic/rules.pl`'s `no_new/4` specifically — every other
`new`-expression rule (`no_new_wrapper/5`, `no_new_func/4`,
`no_object_constructor/4`, `prefer_regex_literal/4`,
`lowercase_constructor/5`) needs nothing beyond `calls/5`'s existing
shape. TypeScript only.

### `comment(File, Line, Text)`

Every comment node, unconditionally — whether or not it documents
anything. `Text` is the comment's content with its language's own
comment-marker syntax stripped (`%`/`%%` for Erlang, `//`/`/** */` for
TypeScript, `#` for Bash) and, for a multi-line run (consecutive `//`
lines, or a multi-line `/** ... */` block), joined into a single space-
separated line — legally a JSON string (and a quoted Prolog atom) *can*
contain a raw newline, but nothing else this project emits does, and
there's no benefit to being the exception.

`Text` is an Erlang **binary**, not an atom — see the shared caveat
below.

### `doc(Function, Arity, File, Line, Text)`

Only emitted when a comment (or a contiguous *run* of them) sits
immediately before a recognized definition node — found via sibling
navigation (`node_next_sibling/1`/`node_prev_sibling/1`), not the
`node_parent/1` walk `calls/5` uses, since a comment is a *sibling* of
what it documents, not a child of it. `Arity` has the same meaning and
the same `undefined`-for-Bash exception as `defines/5`'s — a doc
comment has the identical same-name-different-arity ambiguity, fixed
the same way. `Line` is the **definition's** line (so it joins cleanly
with that function's own `defines/5` fact), not the comment's own line.
A comment with nothing recognizable following it (the last thing in a
file, or followed by something that isn't a function) gets a
`comment/3` fact and no `doc/5` fact at all. `Text` is a binary, same
as `comment/3`.

**Shared caveat across all three languages, worth knowing before
walking siblings yourself:** `node_next_sibling/1`/`node_prev_sibling/1`
return the bare atom `undefined` when there's no such sibling — *not* a
null resource checked via `node_is_null/1`, unlike `node_parent/1`.
Calling `node_is_null/1` on `undefined` raises `badarg`. See
`docs/tree-sitter-erlang.md` §6.

**Shared caveat on `Text`'s type: binary, not atom, and unbounded.**
`comment/3` and `doc/5`'s `Text` — and `heading/4`/`paragraph/3`'s
`Text` and `config_value/4`'s `Value` below — are Erlang **binaries**
(`ts_extract_text:to_text/1`), not atoms. Free text like this is never
unified against a literal a person types in a query, unlike an
identifier atom (a function name, a file path), so there's no reason to
force it through `list_to_atom/1` at all. That used to truncate at 200
characters (Erlang atoms are capped at 255 bytes, hit for real during
dogfooding on a long doc-comment run) — as a binary it no longer needs
to. **Identifier-like atoms elsewhere in this schema are still
truncated at 200 characters** the same way (`ts_extract_text:to_atom/1`)
— that's a genuinely different helper, kept separate for exactly this
reason.

### `branch(Function, Arity, Kind, File, Line)`

A decision point (an `if`, a loop, a `case`/`switch` arm, a
short-circuit `&&`/`||`, ...) inside `Function` — the raw material for
real, McCabe-style complexity (`.symbolic/rules.pl`'s `real_complexity/4`),
as opposed to `too_complex/3`'s fan-out-based proxy. `Function`/`Arity`
have the same meaning as `defines/5`'s (including `undefined` for
Bash's `Arity`), found via the same caller-attribution walk-up `calls/5`
uses. `Kind` is the raw, language-specific construct name (an atom) —
deliberately not forced into one shared cross-language taxonomy, the
same reasoning `calls/5`'s per-language `CallSpec` shapes above aren't
unified either:

| Language | `Kind` values | Notes |
|---|---|---|
| Erlang | `cr_clause`, `if_clause`, `receive_after` | `cr_clause` covers **both** `case ... of` arms and `receive` arms (confirmed: same grammar node for both). `andalso`/`orelse` aren't captured yet — unverified whether the grammar exposes an addressable operator field the way TypeScript's does. |
| TypeScript | `'if'`, `'for'`, `'while'`, `ternary`, `switch_case`, `'catch'`, `'and'`, `'or'` | `if` alone covers `else if` too — tree-sitter nests it as another `if_statement` inside an `else_clause`, so a plain trailing `else` correctly adds nothing. `switch_case`, not `switch_default`, for the same reason. `'and'`/`'or'` come from `binary_expression`'s addressable `operator` field, isolating `&&`/`||` from every other binary operator. |
| Bash | `'if'`, `elif`, `'for'`, `'while'`, `case_item` | `elif_clause` needs its **own** query: unlike TypeScript, an entire `if`/`elif`/`elif`/`else` chain is *one* `if_statement` node, with each `elif` a sibling clause inside it, not a nested `if_statement` — `if_statement` alone would only ever count the first `if`. `case_item` includes the `*)` wildcard/default arm too, since Bash's grammar doesn't structurally distinguish it. `&&`/`||` chaining (a `list` node) isn't captured yet — the operator isn't a named child or an addressable field the way TypeScript's `operator` field is. |

**A real, documented limitation, not a bug**: facts in this schema
dedupe by tuple equality (`lists:usort/1` in every extractor), keyed on
`Line`, not on a per-node byte offset — two decision points that land
on the exact same source line (e.g. `if a -> x; true -> y end` written
all on one line) collapse into a single `branch/5` fact, undercounting
`real_complexity/4` by one in that case. Rare in normally-formatted
code.

**Also worth knowing**: `real_complexity/4` calls `branch/5` even for a
function with zero real decision points, and erlog raises
`existence_error` — not a clean empty result — for a predicate with no
clauses *at all* in the whole database (not per-function; per-database).
A source tree that happens to have no `if`/`for`/`case`/etc. anywhere
would hit this on every query. `.symbolic/rules.pl` works around it with
one sentinel clause, `branch(none, 0, none, none, 0) :- fail.` — always
present, never satisfiable by a real query (its `Fun` is the atom
`none`, and its body is unconditionally `fail` regardless), whose only
job is to make `branch/5` "exist" so `findall/3` over it fails cleanly
instead of erroring. The exact same issue already existed for
`stale_doc_example/4` below (`example_defines/5` has zero clauses
whenever no Markdown got parsed alongside the code) — pre-existing,
left unfixed here, since it's a separate predicate outside this change.

### `expr/6`, `expr_operator/2`, `expr_operand/3`, `literal/7`, `expr_ref/6`

`branch/5` says a decision point *exists* — this family says what it
actually compares. `Function`/`Arity` mean the same as everywhere else
in this schema (found via the same caller-attribution walk-up
`calls/5`/`branch/5` use); Erlang and TypeScript only for now (Bash's
`test_command`/`binary_expression` shape, seen while building
`branch/5`, needs its own research pass).

- **`expr(Id, Function, Arity, Kind, File, Line)`** — `Kind` is
  `binary` or `unary`.
- **`expr_operator(Id, Op)`** — the actual operator, an atom
  (`'=='`, `'&&'`, `'-'`, `'andalso'`, ...). TypeScript reads this
  directly off `binary_expression`'s addressable `operator` field —
  one generic query captures every operator at once. Erlang's
  `binary_op_expr` has **no such field** (confirmed: `node_child_by_field_name`
  returns null for `"left"`/`"right"`/`"operator"` there) — one
  literal-token query per known operator instead (confirmed working:
  `(binary_op_expr "andalso") @b` matches correctly), scoped today to
  comparisons (`==`, `/=`, `=:=`, `=/=`, `<`, `>`, `>=`, `=<`) and
  logical operators (`and`, `or`, `andalso`, `orelse`) — arithmetic is
  the same mechanism, just unbuilt.
- **`expr_operand(Id, Role, ChildId)`** — `Role` is `left`/`right` for
  a binary expression, `operand` for a unary one. `ChildId` may itself
  be another `expr/6`'s `Id` (a nested expression — no special handling
  needed, since the top-level query already matches every occurrence
  regardless of nesting depth), a `literal/7`'s `Id`, or an
  `expr_ref/6`'s `Id`.
- **`literal(Id, Function, Arity, LitKind, Value, File, Line)`** —
  `LitKind` is `number`/`string`/`boolean`/`null` for TypeScript,
  `integer`/`float`/`atom` for Erlang (Erlang's `true`/`false` are
  ordinary atoms, not a distinct boolean type, so they come back as
  `LitKind = atom`, not invented as `boolean`). `Value` for a number is
  a real Erlang number (arithmetic-ready in Prolog); for a string it's
  a binary, same reasoning as `comment/3`'s `Text` — no prefix/pattern
  matching on a string literal's content yet, a real, deliberate limit,
  not an oversight (revisiting it means reopening the atom-truncation
  risk this project already resolved once for identifiers).
- **`expr_ref(Id, Function, Arity, Name, File, Line)`** — a bare
  identifier (`identifier` in TypeScript, `var` in Erlang) used as an
  operand. Not scope/binding resolution — just "this position holds a
  reference to this name," nothing about which declaration it resolves
  to.

**`Id` is new: a `{File, StartByte, EndByte}` byte span, not
`(Function, Arity, File, Line)`.** Every other fact in this schema gets
away with that as its natural key; this family can't, because a rule
needs to reference *one specific operand of one specific expression*,
and two of them routinely share a `Line`. It also can't be `{File,
StartByte}` alone — **a real bug found by actually running this**, not
a hypothetical: a binary expression and its own leftmost operand
routinely start at the *same* byte (`x == x` — the expression and its
left `x` both start where `x` starts), so start-byte alone collided
until `EndByte` was added to disambiguate. No two distinct nodes in one
parse occupy the identical byte range, so the span can't collide.

**Same `existence_error`-on-zero-clauses caveat as `branch/5`** (see
that section above) applies to all five predicates here — a codebase
with no expressions of some kind has zero clauses for that predicate,
and erlog errors rather than failing cleanly. `.symbolic/rules.pl` has
one sentinel clause per predicate in this family, the same fix.

### `scope/4`, `var_decl/6`, `var_ref/6`, `resolves_to/2`

The biggest structural gap in this schema until now: every other fact
family is about *functions* — a definition, a call, a decision point,
an expression inside one. This family is about *variables*, and it's
**TypeScript-only** — Erlang's variable model (single-assignment,
pattern-bound, no `var`/`let`/`const` distinction, no mutation) is
different enough to need its own separate design, not guessed at here.

- **`scope(ScopeId, Kind, ParentScopeId, File)`** — `Kind` is
  `function` (a `function_declaration`/`function_expression`/arrow
  function's own parameters + body, as one unit — no extra scope layer
  for a function's *immediate* body block), `block` (any other
  `statement_block`, or a `for_statement`'s own header), or `module`
  (the file's top level). `ParentScopeId` is the atom `none` only for
  the module scope.
- **`var_decl(Id, Name, Kind, ScopeId, File, Line)`** — `Kind` is
  `` 'var' ``, `` 'let' `` (a reserved word in Erlang, so always the
  quoted atom), `const`, `param`, or `import` (an import binding — see
  `import_decl/4` below; deliberately the same fact shape, not a
  parallel one, so `unused_var/4`/`shadowed_var/5`/etc. in
  `.symbolic/rules.pl` already apply to an unused or shadowed import
  with no extra rule needed). A `var` declaration's `ScopeId` is
  the nearest enclosing **function**-or-module scope (hoisting past any
  block boundaries in between); `` 'let' ``/`const`/`param` stay in the
  immediate enclosing scope; `import` is always the **module** scope,
  since ES imports are always top-level. Only a plain-identifier
  declaration name — a destructured one (`let {a, b} = x`) is silently
  not tracked, not mis-tracked.
- **`var_ref(Id, Name, ScopeId, RefKind, File, Line)`** — `RefKind` is
  `read` (the default — includes a call's own callee identifier, e.g.
  `foo()`, since that's a legitimate use of a locally-declared `foo`
  for this purpose, alongside whatever `calls/5` separately records),
  `write` (a plain assignment's left side), or `read_write` (`+=` and
  friends — it reads the old value too). Only a plain-identifier
  assignment target is tracked, same destructuring exclusion as
  `var_decl/6`.
- **`resolves_to(RefId, DeclId)`** — which declaration a reference
  actually binds to, or the atom `undefined` if none does. **Computed
  once by the extractor at parse time** (a real scope-chain walk over
  the tree it just built), not left for a query to re-derive — the same
  design choice `calls/5`'s `caller_info/2` walk-up already makes for
  attribution, just for a harder question. Verified against a
  deliberately tricky real snippet (not a toy case): a block-scoped
  `let x` correctly shadowed by a nested block's own `let x` (a
  reference *inside* that block resolves to the *inner* one, one
  *outside* it to the outer one), and a `var`/`` 'let' `` each read from
  two scope levels down inside a `for`-loop's own nested body block,
  both correctly walking up through the loop's scope to the declaration
  beyond it.

**`resolves_to(Ref, undefined)` alone is not proof of a bug.** It means
"not declared in anything this walk tracked" — which includes every
real global (`console`, `Math`, `window`, ...), not just a genuine
undeclared-variable mistake. `.symbolic/rules.pl`'s `undeclared_var/4`
is what actually turns this into a trustworthy `no-undef`-style check,
by excluding everything in its own `known_global/1` allowlist first —
query `resolves_to/2` directly and you'll see every real global listed
as `undefined` too.

- **`var_decl_initialized(Id)`** — that a `var_decl/6` (of `var`/`` 'let' ``/
  `const`, never `param`) has a "value" — present only when the
  declarator was actually initialized (`let x = 1`, not a bare `let x;`).
  Exists specifically so `.symbolic/rules.pl`'s `prefer_const/4` never
  suggests `const x;` for a declaration that has no initializer to
  give it, which isn't valid syntax.

Same `existence_error`-on-zero-clauses guard as `branch/5`/`expr/6` —
one sentinel clause per predicate in `.symbolic/rules.pl`.

### `import_decl(Module, File, Line)`, `export_decl(Name, Kind, File, Line)`

An import binding itself is a `var_decl/6` (`Kind = import`, above) —
these two facts exist for what that alone can't answer: which
**module** a name came from, and what a file makes **public**.
TypeScript only.

- **`import_decl`** — one fact per `import_statement`, regardless of
  how many (if any) bindings it introduces: a default import, one or
  more named imports (with or without an alias), a namespace import
  (`* as ns`), and a side-effect-only import (`import "./x";`, no
  binding at all) all still produce exactly one `import_decl/4`.
  `Module` is the raw source string, as an atom (`lodash`, `./bar`).
- **`export_decl`** — `Kind` is `named` (a wrapped declaration, e.g.
  `export const x = 1` — one fact per declarator, so `export const a =
  1, b = 2;` is two; or a re-export specifier, e.g. `export { a, b as
  d };` — `Name` is `a` for the first, `d` for the second, since the
  **alias**, not the original local name, is what's actually made
  public), `default` (`Name` is always the literal atom `` 'default' ``
  — the export *slot's* own reserved name in ES module semantics, not
  whatever expression happens to fill it), or `wildcard`
  (`export * from "...";` — `Name` is `undefined`, there's no specific
  name at all). A wrapped declaration (`export function f() {}`)
  produces no special attribution walk of its own — its `declaration`
  field is a real `function_declaration`/`lexical_declaration` node,
  already walked normally, so its `defines/5`/`var_decl/6` facts exist
  exactly as if `export` weren't there at all.

**A real bug found by actually running this against a file that both
imports and later references a name, not a hypothetical**: import
bindings used to be computed *after* `resolve_refs/3` already ran, so
no reference to an imported name resolved to anything anywhere in the
file — every one came back `resolves_to(_, undefined)`, indistinguishable
from a genuinely undeclared name. Fixed by computing import bindings
first and folding them into the same declaration set the resolver
consults.

A re-export specifier's alias (`export { b as d }`'s `d`) is
deliberately never visited as a reference by the scope walk — it isn't
one; `d` is just the chosen public name, not a local variable named
`d`. Only the specifier's *first* name (`b`, a real reference to an
existing local binding) is walked normally.

`sort-imports` is deliberately not built on top of these — it needs
each binding tied back to *which import statement* introduced it, a
per-statement grouping key `var_decl/6` alone doesn't give cheaply, and
it's the most purely stylistic rule in this group. A reasoned skip, not
an oversight.

### `stmt_block/6`, `stmt/6`, `last_switch_case/1`, `braceless_body/5`, `return_stmt/5`

Statement/block *structure*, as opposed to expression content
(`expr/6`, above) — **TypeScript only**, same reasoning as `scope/4`:
Erlang has no brace-optional `if`/`for`/`while`, and no separate
`return` statement at all.

- **`stmt_block(BlockId, Fun, Arity, Kind, File, Line)`** — `Kind` is
  `block` (a real `{}` `statement_block`), `switch_case`, or
  `switch_default` — the latter two have no wrapping block node at all;
  their own children *are* their statement list directly, confirmed
  empirically. A flat query matches every block at every nesting depth
  independently, same as `branch/5`'s `if_statement` matching both an
  outer and a nested `else if` on its own.
- **`stmt(Id, BlockId, Index, Kind, File, Line)`** — one fact per direct
  statement inside a `stmt_block/6`, in source order. `Index` is the
  statement's raw position among *all* the block's named children,
  **not renumbered** after any exclusion below — a `switch_case` whose
  own case-value expression sits at index 0 has its first real
  statement at index 1, not 0. `Kind` is the statement's raw node type
  as an atom (`return_statement`, `expression_statement`, ...) — no
  curated allow-list, since the rules built on this only ever check
  whether a `Kind` is one of the four *terminator* kinds
  (`return_statement`/`throw_statement`/`break_statement`/
  `continue_statement`, `terminator_kind/1` in `.symbolic/rules.pl`).
  Two exclusions, both found as real bugs while building this rather
  than guessed in advance: a **comment** is an ordinary named child of
  its enclosing block (same fact this module's doc-comment code already
  relies on), so a trailing comment after a `return` would otherwise
  look like unreachable code; a `switch_case`'s own **case-value**
  expression (the `1` in `case 1:`, its own addressable `"value"`
  field, matched by byte-span identity rather than position) would
  otherwise count as a "statement," permanently defeating the
  empty-case-stacking exemption below.
- **`last_switch_case(BlockId)`** — present only when nothing
  case/default-shaped follows this `switch_case`/`switch_default` —
  checked via its own next sibling, not by assuming only the literal
  last clause in source needs it: a real `switch` can have `default`
  anywhere, not just last.
- **`braceless_body(Fun, Arity, Kind, File, Line)`** — `Kind` is `if`,
  `else`, `for`, or `while`. One fact per construct whose body is a
  single bare statement rather than a real `{}` block.
  `if_statement`'s `consequence` field holds its statement directly,
  but its `alternative` field is always wrapped in an `else_clause`
  node first (confirmed empirically, unlike `consequence`) — unwrapped
  before the same brace check applies. An `else if` chain (the
  `else_clause`'s own child is itself an `if_statement`) is never
  reported for the `else` branch itself — that's ordinary chaining, and
  the nested `if` is checked independently for its own
  `consequence`/`alternative`.
- **`return_stmt(Fun, Arity, HasValue, File, Line)`** — `HasValue` is
  `true` for `return x;`, `false` for a bare `return;` (zero named
  children, confirmed empirically). Deliberately flat, no
  control-flow-path analysis: real `consistent-return` semantics just
  check whether every `return` in *one function* agrees on whether it
  specifies a value, not whether every code path returns one.

Same `existence_error`-on-zero-clauses guard as every other fact family
above — one sentinel clause per predicate in `.symbolic/rules.pl`.

An empty `case`/`default` (no `stmt/6` facts at all) immediately
stacking into the next one (`case 1: case 2: foo(); break;`) is
idiomatic, not a bug — `no_fallthrough_case/5` in `.symbolic/rules.pl`
only flags a clause that *has* statements whose last one isn't a
terminator, never a genuinely empty one. An empty function **body**
specifically is deliberately not flagged by anything here either —
`no-empty-function` needs the function's own emptiness, a different
judgment call than a `{}` block being empty, and isn't built.

## Markdown structural facts

Produced by `src/ts_extract_markdown.erl`, using tree-sitter-markdown's
**block** grammar only (see `docs/tree-sitter-markdown.md` for the
still-open inline-grammar/`link/4` work this doesn't cover).

### `heading(File, Level, Text, Line)`

- **`Level`** — 1–6, from the number of `#` characters.
- **`Text`** — the heading's own text, trimmed. A binary, not an atom —
  see the shared caveat under `doc/5` above.

**ATX (`#`) headings only** — the underline (setext) style isn't
handled. A real, not hypothetical, scope limit: this repo's own docs
never use setext headings.

### `code_block(File, Lang, Line)`

- **`Lang`** — the fence's declared language tag as an atom (`erlang`,
  `sh`, `ts`), or the atom `none` for a bare ``` fence with no tag.
- **`Line`** — the fence's own opening line.

### `paragraph(File, Text, Line)`

- **`Text`** — the paragraph's text (a binary, not an atom — see the
  shared caveat under `doc/5` above). A soft-wrapped paragraph (multiple
  source lines, no blank line between them) is still *one* fact, its
  embedded newline collapsed into a single space, the same cleaning
  `comment/3`'s multi-line runs get.

**Real quirk, not filtered out:** this grammar also parses a list
item's own content as a `paragraph` node, so list-item text shows up as
`paragraph/3` facts too — extracted as the grammar actually names
things, not a hand-picked notion of "real" paragraphs.

## Markdown example facts: re-extracting fenced code

### `example_defines(Function, Arity, Params, File, Line)` / `example_calls(Caller, CallerArity, CallSpec, File, Line)`

For a fenced code block tagged `erlang`, `ts`, `typescript`, `sh`, or
`bash`, the block's own text is re-parsed by the *real* language
extractor (`text/2`, the same entry point `ts_extract_erlang.erl` etc.
expose for this purpose), with `File` set to the **Markdown file**
(not a synthetic path) and `Line` offset back to that file's real line
numbers.

**Deliberately different predicate names than `defines/5`/`calls/5`**,
not the same predicates reused with an `.md` `File` — this project's
whole value proposition is a fact base worth trusting ("a real fact
base, not a grep result"), and conflating "this function really exists
in the codebase" with "a doc's example happened to show a function of
this name" would undercut that directly. The split makes the actual
motivating check trivial:

```prolog
stale_doc_example(Fun, Arity, DocFile, Line) :-
    example_defines(Fun, Arity, _Params, DocFile, Line),
    \+ defines(Fun, Arity, _, _, _).
```

`comment/3`/`doc/5` are **not** extracted from embedded snippets — a
fragment's own comments aren't the point, and doc-comment attribution
inside an illustrative example adds noise without answering the
question this feature exists for (see `docs/agent-examples.md` for the
full worked scenario).

## Config facts: `config_value/4`, `config_section/3`

Produced by `src/ts_extract_toml.erl` and `src/ts_extract_json.erl` —
**shared predicate names on purpose**, the config-format analogue of
`defines`/`calls` being shared across three programming languages: "a
dotted key path resolves to this value" is the same question regardless
of whether the file is a `Cargo.toml` or a `package.json`.

### `config_value(File, Path, Value, Line)`

- **`Path`** — the fully dotted key path as one atom
  (`'dependencies.serde'`), built by real recursive descent through
  nested tables/objects — there's no flat tree-sitter query that could
  produce a multi-level path directly, unlike every code-fact predicate
  above.
- **`Value`** — the leaf's raw text (quotes stripped for strings) as a
  binary, not an atom — see the shared caveat under `doc/5` above.
  **Array values are captured whole, as one opaque leaf** — the array's
  own raw source text, not walked element-by-element. A real, deliberate
  scope limit for both formats, not a missing case.

### `config_section(File, Path, Line)`

A named container was opened along the way: a TOML `table`,
`table_array_element`, or `inline_table`; a JSON `object`. The
anonymous document root doesn't get a fact (it has no path worth
naming). A repeated TOML `[[section]]` (array-of-tables) or a JSON
array of objects produces multiple `config_section`/`config_value`
facts **sharing the same `Path`**, each with its own `Line` — the
correct shape for "list every host across all `[[servers]]` blocks,"
since this pass doesn't do numeric array indexing.

## What's deliberately not here yet

- **YAML** — investigated, not vendored. Its grammar needs a real C++
  scanner; this project's build is pure C with no C++ toolchain wired
  in. See `docs/tree-sitter-erlang.md` §5.1.
- **Markdown links (`link/4`)** — needs the separate *inline* grammar
  plus a NIF function (`ts_parser_set_included_ranges`) not yet wrapped
  by `symbolic_ts`. See `docs/tree-sitter-markdown.md` §3.
- **Array-element recursion** for `config_value`/`config_section` — see
  above.
- **Module name tracking** for `defines`/`calls` — arity is now tracked
  on both `Function`/`Arity` and `Caller`/`CallerArity` (see `defines/5`
  and `calls/5` above); module name is not.

## References

- [`tree-sitter-erlang.md`](tree-sitter-erlang.md) — how each
  extractor is built, including §5.1/§5.2's per-language case studies
  and §6's pitfalls (the sibling-navigation `undefined` quirk, the
  `query_capture/2` duplication quirk).
- [`tree-sitter-markdown.md`](tree-sitter-markdown.md) — the Markdown
  grammar split and the deferred `link/4` work.
- [`prolog-store.md`](prolog-store.md) — where these facts live at
  runtime and on disk, not what they mean.
- [`agent-examples.md`](agent-examples.md) — narrative worked examples
  of an agent using several of these predicates together.
- [`lint-queries.md`](lint-queries.md) — a reusable rule library over
  `defines`/`calls`/`comment`/`doc`, including a real quirk (`-spec`
  noise in `calls/5`) found by running it against this project's own
  `src/` — the arity-conflation false positive that doc also used to
  describe is fixed now that `defines`/`doc` carry `Arity`.
- [`../readme.md`](../readme.md) — the CLI-level introduction to all of
  the above, with one real worked example per language.
