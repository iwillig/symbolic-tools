# Rust support: schema audit and scope

This is Task 1 of adding Rust source support. It inventories the current
code-fact model and sets the questions the Rust extractor must answer. It
is not a Rust parser implementation or a commitment to model every
Tree-sitter node. The authoritative predicate definitions remain in
[`prolog-schema.md`](prolog-schema.md).

## Current model

Tree-sitter produces a language-specific concrete syntax tree. Extractors
in `src/ts_extract_*.erl` emit selected facts; the tree itself is not
serialized into the Prolog database. The current NIF exposes individual
grammar loaders and a small common tree/query API. `ts_extract:file/1`
dispatches by extension.

| Concept/fact family | Erlang | TypeScript | Current interpretation / audit note |
|---|---:|---:|---|
| `defines/5` | yes | yes | Named function definitions with name, arity, raw parameter text, file, line. Function identity is not module-qualified. |
| `calls/5` | yes | yes | Caller name/arity plus language-shaped `CallSpec`; syntax-level call sites, not resolved targets. |
| `comment/3`, `doc/5` | yes | yes | All comments vs. a preceding comment run attributed as documentation. |
| `branch/5` | yes | yes | Extractor-selected decision points, not a complete control-flow graph. |
| `expr/6`, `expr_operator/2`, `expr_operand/3`, `literal/8`, `expr_ref/6` | yes | yes | Selected expressions and operands; IDs are byte-span-derived and scoped to a file parse, not stable entity identities. |
| Function references | `fun_ref/4` | not currently emitted | Erlang internal `fun Name/Arity` references, distinct from calls. |
| Public interface | `export/4` | `export_decl/4` | Different shapes and semantics; Erlang exports are function/arity entries, TypeScript exports are names/kinds. |
| Imports | not listed as a common family | `import_decl/4` plus binding facts | TypeScript records module paths and import bindings; no corresponding Erlang import fact is listed in the schema. |
| Scopes, declarations, references, resolution | not emitted | `scope/4`, `var_decl/6`, `var_ref/6`, `resolves_to/2`, `var_decl_initialized/1` | TypeScript-specific; Erlang's single-assignment/pattern-binding model needs distinct semantics, not a direct copy. |
| Statements and returns | not emitted | `stmt_block/6`, `stmt/6`, `last_switch_case/1`, `braceless_body/5`, `return_stmt/5` | TypeScript-specific constructs and rule inputs. Erlang has no separate `return` statement. |
| Async/generator/await/yield | not emitted | TypeScript-only facts | Language-specific execution constructs. |
| Markdown examples/config facts | n/a | n/a | Separate document/config fact shapes; outside this Rust code-model audit. |

Bash also emits a subset of the shared code facts (`defines`, `calls`,
comments/docs, branches); its function arity is `undefined`. The full
availability table and predicate contracts are in `prolog-schema.md`.

## Semantic gaps to resolve for Rust

Rust has constructs that do not map one-to-one to either existing code
model. During extraction design, explicitly decide:

- **Definition kinds:** free functions, methods, associated functions,
  trait declarations/method signatures, closures, and macro-generated
  items. Which count as `defines` and which need a kind-specific fact?
- **Identity and scope:** a bare function name is insufficient to
  distinguish same-named items in separate modules or `impl` blocks.
  Decide whether normalized identities are introduced, without silently
  changing the meaning of existing `defines/5` or rule joins.
- **Calls:** distinguish direct calls, method calls, and constructor-like
  syntax only where the grammar supports that distinction. Calls remain
  syntactic unless resolution is separately implemented; do not label a
  call `local` merely because it resembles a same-file definition.
- **Visibility/API:** Rust `pub`, `pub(crate)`, `pub(super)`, and private
  visibility are not equivalent to Erlang's module export list or
  TypeScript's export declarations. Preserve the visibility scope.
- **Declarations and types:** structs, enums, traits, type aliases,
  constants/statics, modules, `use` declarations, and generic/type
  relationships are candidates for useful facts, but should be selected
  against concrete query needs.
- **Control flow and references:** Rust pattern bindings, match arms,
  `?`, `return`, closures, and macro/token-tree contents need explicit
  coverage rules. Tree-sitter syntax alone does not provide name
  resolution, macro expansion, or type checking.
- **Locations and IDs:** define source-location conventions and identity
  lifetime. Byte-span IDs are useful for joining facts extracted from one
  parse, but are not persistent identities across edits.

## Candidate first queries

Use these to test the model before broadening extraction:

1. Which functions and methods are declared in a Rust file/module?
2. Which items are public, and at what visibility scope?
3. Which syntactic call sites occur inside a given function or method?
4. Which struct/enum/trait/type declarations exist, and what module
   contains them?
5. Which `use` declarations occur, without claiming they resolve to an
   in-repository definition?
6. Which decisions (for example `if`, `match` arms, loops) are counted by
   the complexity rules, and how does that definition compare to Erlang
   and TypeScript?

The first three should be enough to validate the parser/extractor seam;
items 4–6 are schema design probes, not a requirement to implement every
one in the first Rust release.

## First normalized slice: `function_decl/7`

Task 4 adds `function_decl(Id, Language, Name, Arity, Kind, File, Line)`
for selected named callable syntax in Erlang, TypeScript, and Rust. This is
a common tuple shape and query surface, not a claim that the languages
share one declaration model. `Kind` keeps the relevant grammar distinction
visible; `Id` is a parse-local source span; existing `defines/5` and
Rust-specific context/visibility facts remain available and unchanged.

This is the first slice because all three extractors already identify
named callable syntax, but their current `defines/5` facts lack a common
identity and declaration-kind field. Other candidates—especially
visibility and calls—have materially different semantics across the
languages and need more design before normalization. For example, a Rust
bare identifier in call position is not necessarily a local function
reference, so it remains a Rust `path(...)` CallSpec rather than being
forced into Erlang/TypeScript's `local(...)` vocabulary.

Coverage is intentionally bounded: Erlang emits one record per function
clause; TypeScript currently covers function and generator declarations,
not class methods; Rust covers function items, methods, and signatures.
These limits are explicit and can expand as extractor evidence and query
needs justify it.

## Derived-rule review (Task 5)

No `.symbolic/rules.pl` rule is migrated to `function_decl/7` in this
step. The current derived rules intentionally use `defines/5`: many need
its parameter text and line behavior, or depend on related facts keyed by
name/arity (`calls/5`, `doc/5`, `export/4`, and `fun_ref/4`). The normalized
fact omits parameter text, is bounded to three languages, and gives each
language's declaration form a different granularity. Replacing the source
would either drop Bash coverage or silently alter existing query results.

`function_decl/7` is therefore the common discovery/identity surface for
cross-language queries; `defines/5` remains the compatibility source for
existing rules and clients. Extractor tests now compare the name/arity
projection of both fact families for representative Erlang, TypeScript,
and Rust input, ensuring the additive view does not displace legacy facts.
Reconsider migration after coverage and linked call/entry-point facts have
a common contract, and only with rule-level compatibility tests.

## Rust syntax coverage review (Task 6)

| Area | Current extraction | Deliberate gap / limit |
|---|---|---|
| Callable declarations | `function_item` and `function_signature_item`; emits legacy and Rust-specific facts | Closures and macro-generated declarations are not enumerated; no name resolution |
| Modules | `mod_item`, with inline/external form and parent context | An external `mod name;` is recorded but its referenced file is not traversed |
| Imports | One `rust_use/4` with raw path text and context | Imports are not resolved or expanded into individual bindings |
| Visibility | Explicit visibility on selected functions, signatures, modules, and type/value items; private is retained on function/module facts where applicable | No general declaration fact for fields or enum variants; `rust_visibility/5` omits implicit private visibility |
| Calls | Call expressions with identifier, field, scoped, and generic/turbofish callees; nearest named `function_item` attribution | Macro invocations remain separate from calls; unsupported callee shapes are skipped; calls outside named functions are skipped |
| Macro invocations | One `rust_macro/6` fact with macro path, source span, and enclosing function span when present | Token-tree contents are not parsed; macros are not expanded or resolved; no `calls/5` facts are inferred |
| Control flow, bindings, types | Not emitted as Rust-specific families | Match arms, pattern bindings, `?`, return flow, and type relationships remain future candidates |

Task 6 selected generic/turbofish calls as the first high-value coverage
fix: generic calls are common Rust syntax, and the existing call-expression
query already finds them, but the extractor previously discarded their
`generic_function` callee node. The extractor now records generic free/path
calls with their raw callee text and generic methods with the existing
`member(Receiver, Method, Arity)` shape. Tests cover both forms. This is
still syntax-only; type arguments and paths are not resolved.

Task 7 adds macro invocation-site coverage with `rust_macro/6`. The fact
records only the written macro path, source span, and enclosing function
span when one exists. Macro token trees are not ordinary call expressions,
so the extractor does not inspect them, expand macros, or infer calls from
them. Tests cover an unqualified macro, a scoped macro, and a module-scope
macro.

## Acceptance criteria for Task 1

- Predicate semantics and language availability are checked against the
  actual extractors and `prolog-schema.md`.
- Every proposed shared predicate has a stated cross-language meaning
  and documented exclusions.
- Rust-specific syntax is represented honestly where no shared meaning
  exists.
- The choice to add normalized facts without breaking existing facts is
  recorded in [`adr/0001-additive-cross-language-fact-schema.md`](adr/0001-additive-cross-language-fact-schema.md).
- Task 2 can proceed by adding the Rust grammar/NIF loader and `.rs`
  dispatch without deciding the entire future schema in advance.
