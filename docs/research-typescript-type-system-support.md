# Research: TypeScript type information in the Prolog fact base

## Question

What TypeScript type information does `symbolic parse` already extract, what would be required to add richer type support, and how could ASK use it safely?

## Summary

The current TypeScript grammar parses type syntax, but the extractor does **not** build a TypeScript type model or run type checking. It preserves some raw type text: `defines/5` stores the source text of a function's parameter list, and the JSDoc extractor stores raw types from `@param` and `@returns` tags. These facts support syntax-level discovery, not questions about inferred types, symbol resolution, assignability, or compiler diagnostics.

There are two distinct levels of support:

1. **Declared-type syntax facts**, extracted with the existing Tree-sitter grammar. This is a bounded extension and needs no new parser runtime.
2. **Compiler-resolved type facts**, computed by the TypeScript compiler's `Program` and `TypeChecker`. This is a larger integration: it needs the project's TypeScript version, `tsconfig` options, module resolution, project references, and a stable bridge into the Erlang fact store.

Recommendation: start with explicit, source-located syntax facts; then prototype a checker-backed sidecar on one configured TypeScript project. Do not describe syntax-only facts as resolved types, and do not treat missing compiler output as a negative answer.

## What the repository does today

- `ts_extract_typescript` selects the vendored TypeScript or TSX Tree-Sitter grammar and emits facts for definitions, calls, scopes, references, returns, expressions, and related syntax. It does not query type nodes or emit type relations. See [`ts_extract_typescript.erl`](../src/ts_extract_typescript.erl) and the grammar inventory in [`build.rs`](../native/symbolic_ts/build.rs).
- `defines/5` stores `Params` as the raw text of a recognized function declaration's parameter-list node. The fresh Symbolic query `defines(shout, 1, Params, '/Users/iwillig/dev/symbolic-tools/test/fixtures/sample.ts', Line)` returned `Params = "(word: string)"`, `Line = 18`. This preserves an annotation, but does not interpret it.
- `function_decl/7` records a function's name, arity, syntactic kind, file, line, and parse-local identity. It does not record parameter or return types.
- JSDoc is a limited exception: [`ts_extract_jsdoc.erl`](../src/ts_extract_jsdoc.erl) emits `doc_tag/8` with the raw text inside a tag's braces, or `none`. The schema documents this as documentation metadata, not a compiler-resolved type; see [`prolog-schema.md`](prolog-schema.md) and its [`@param`/`@returns` test](../test/ts_extract_typescript_tests.erl).
- The refreshed Symbolic overview has no declared-, inferred-, or compiler-type fact family. The schema's TypeScript entries likewise contain no facts for type declarations, assignability, or compiler diagnostics. `doc_tag/8` is the narrow documentation-metadata exception above. The generated parser contains grammar symbols such as `type_annotation`, `interface_declaration`, `type_alias_declaration`, `type_parameters`, and `type_arguments`; that establishes syntax support in the parser, not semantic checking.

The distinction is important: Tree-Sitter builds a syntax tree. TypeScript's compiler API supplies symbols and types through a `Program` and its `TypeChecker`. The TypeScript wiki describes `getTypeAtLocation`, `getTypeOfSymbolAtLocation`, and `typeToString` as checker operations ([Using the Compiler API: Type Checker APIs](https://github.com/microsoft/TypeScript/wiki/Using-the-Compiler-API#type-checker-apis)).

## What a syntax-only extension could provide

Reuse the existing grammar and emit source-located facts for constructs the extractor currently ignores, for example:

- parameter and return annotations;
- variable and property annotations;
- `type` aliases, `interface` declarations, generic parameters and constraints;
- `as` and `satisfies` syntax, kept distinct from inferred or checked results.

Keep the raw source spelling as binary text and link facts to declarations by source span, not only by name and arity. This can answer questions such as “what type was declared for this parameter?” or “where is this interface declared?” It cannot reliably answer “what type does the compiler infer here?”, “is this value assignable?”, or “which overload resolves for this call?”

A syntax-only phase is comparatively small, but it should include tests for unions, intersections, generics, optional/rest parameters, overloads, type predicates, TSX, and malformed or partially typed files. It should also expand coverage beyond the current named function-declaration set: methods, constructors, accessors, function-valued properties, and arrow functions need explicit scope decisions.

## What semantic type support requires

Use the TypeScript compiler for semantic questions rather than reimplementing the type system in Prolog. The compiler API builds a `Program` from root files and compiler options; the `Program` supplies a `TypeChecker` for symbol lookup and types ([Compiler API wiki](https://github.com/microsoft/TypeScript/wiki/Using-the-Compiler-API)). A call to `transpileModule` alone is not enough: the same official guide presents it as a source-to-source transpilation helper, while semantic type queries use a `Program` and `TypeChecker`.

The hard part is matching the compiler's project context:

- Find and parse each relevant `tsconfig.json`, including `extends`, `files`/`include`, compiler options, and project references. The [TSConfig reference](https://www.typescriptlang.org/tsconfig/) shows that options such as `strictNullChecks`, `strictFunctionTypes`, `paths`, module resolution, and references affect type-checking behavior.
- Use the TypeScript version and dependencies intended by that project. TypeScript's official Compiler API wiki warns that its documented API through 6.0 changes in 7.1, so pin and record the compiler version rather than treating the API as version-neutral.
- Preserve checker status and diagnostics. A project that cannot load its config, dependencies, declaration files, or compiler version must produce `unknown`/unavailable type results, not empty facts interpreted as “no type” or “not assignable.”
- Bound cost. Large monorepos may have several TypeScript projects and project references. Measure project construction, memory, and serialization; investigate incremental `Program`/builder APIs only after a correct full-build prototype.

The repository currently compiles vendored C Tree-Sitter grammars through a Rustler NIF; `native/symbolic_ts/Cargo.toml` has Rustler and `cc` dependencies, not the TypeScript compiler. The root project also has no TypeScript package manifest. A checker-backed implementation therefore adds a runtime/dependency boundary. A small Node/TypeScript worker that reads project configuration and emits a versioned JSON stream is a reasonable prototype; Erlang can validate and store the resulting facts. Avoid embedding an independent approximation of TypeScript's checker in the NIF or Prolog rules.

## Fact and ASK design

Keep syntax and semantic results separate. Candidate fact families (names and arities are sketches, not a committed schema) include:

```prolog
% Syntax-level: source text and exact source span
ts_declared_type(SymbolId, TypeText, File, StartByte, EndByte).
ts_type_decl(SymbolId, Name, Kind, File, StartByte, EndByte).

% Checker-level: scoped to a project/configuration and compiler run
ts_project(ProjectId, ConfigFile, TypeScriptVersion, OptionsHash, Status).
ts_effective_type(ProjectId, SymbolId, LocationId, TypeId, Origin).
ts_type_node(ProjectId, TypeId, Kind, DisplayText).
ts_type_edge(ProjectId, TypeId, Role, ChildTypeId).
ts_type_diagnostic(ProjectId, Code, File, StartByte, Length, Category).
```

Use parse-local or project-run IDs for compiler objects; do not assume compiler-internal object IDs are stable across runs. Preserve source spans and declaration links as the durable provenance. Represent recursive types as a bounded graph rather than recursively expanding them into enormous terms. Keep a human-readable type string for display, but do not use it as the only semantic identity: the compiler API describes `typeToString` as a human-readable rendering.

The AI-facing layer should expose only catalogued operations, not arbitrary generated Prolog or arbitrary TypeScript evaluation. High-value first operations are:

1. **Declared type at a declaration** — return the raw annotation and its source location.
2. **Effective type at a location** — return declared or inferred type, explicitly labeled, with project/config/compiler provenance.
3. **Type-check diagnostic at a call, assignment, or return** — return the compiler diagnostic and exact source span.
4. **Assignable under project configuration?** — invoke the checker in that program context and return `yes`, `no`, or `unknown`, with compiler version/options and relevant diagnostic evidence.

TypeScript is structurally typed, and its compatibility rules include documented unsound cases; compiler options also change behavior ([Type Compatibility](https://www.typescriptlang.org/docs/handbook/type-compatibility.html), [TSConfig reference](https://www.typescriptlang.org/tsconfig/)). Therefore an answer must say “assignable under project X's TypeScript version/options,” not make a universal claim about runtime safety. Keep existing syntax-level claims—calls, object keys, return structure—separate from compiler-type claims and runtime behavior.

## Suggested staged plan

1. **Inventory and contracts:** identify TypeScript projects/configs in target repositories; choose exact ASK questions and define `unknown` behavior for missing or failed checker runs.
2. **Syntax facts:** add annotation/type-declaration extraction with spans and tests; update the schema and catalog for declared-type questions only.
3. **One-project compiler prototype:** run the project's own TypeScript compiler API, collect a small set of effective types and diagnostics, and compare sampled answers with `tsc`/editor results.
4. **Persistent semantic facts:** define project/version/options provenance, graph encoding, refresh/invalidation, resource limits, and error status before broad indexing.
5. **Curated ASK operations and benchmark:** add typed slots, witness citations, incomplete-project cases, option-sensitive cases, and independent review. Do not mark a case false because the compiler worker returned no data.

## Sources

### Internal implementation and schema

- [`src/ts_extract_typescript.erl`](../src/ts_extract_typescript.erl) — TypeScript/TSX fact extraction and current syntax coverage.
- [`src/ts_extract_jsdoc.erl`](../src/ts_extract_jsdoc.erl) — raw structured JSDoc tag extraction.
- [`docs/prolog-schema.md`](prolog-schema.md) — current predicate contracts and explicit boundaries.
- [`test/ts_extract_typescript_tests.erl`](../test/ts_extract_typescript_tests.erl) — current typed-parameter and JSDoc examples.
- [`native/symbolic_ts/Cargo.toml`](../native/symbolic_ts/Cargo.toml), [`native/symbolic_ts/build.rs`](../native/symbolic_ts/build.rs) — current Tree-Sitter NIF dependencies and grammar compilation.

### Primary external sources

- Microsoft TypeScript, [Using the Compiler API](https://github.com/microsoft/TypeScript/wiki/Using-the-Compiler-API) — `Program`, `CompilerHost`, `TypeChecker`, type queries, and API-version warning.
- Microsoft TypeScript, [TSConfig Reference](https://www.typescriptlang.org/tsconfig/) — project roots, compiler options, module resolution, and project references.
- Microsoft TypeScript Handbook, [Type Compatibility](https://www.typescriptlang.org/docs/handbook/type-compatibility.html) — structural compatibility and soundness caveats.
- Tree-sitter, [tree-sitter-typescript](https://github.com/tree-sitter/tree-sitter-typescript) — syntax grammar; documents TypeScript and TSX as separate grammars.
