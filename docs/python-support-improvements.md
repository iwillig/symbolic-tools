# Python support: recommended next steps

The shipped extractor is deliberately syntax-only. Its current contract is in [Python Tree-sitter integration](tree-sitter-python.md). Stage 1 below is now implemented as additive `py_definition/9` and `py_call_site/11` facts; stages 2–5 remain proposals. Recommendations are ordered by usefulness and risk.

## 1. Fix identity and preserve honest call-site evidence (highest priority)

The extractor emits `defines/5` for methods and nested functions, but a name plus declared-parameter count does not distinguish `A.run` from `B.run`, nor two nested `run` functions. It emits `calls/5` only within a unique top-level function and drops calls with keywords, unpacking, complex callees, or no suitable caller. As a result, graph and dead-code queries are particularly easy to overinterpret for Python. Python's call syntax distinguishes positional, keyword, `*` and `**` arguments; counting all of them as a fixed arity would be misleading ([Python AST: `Call`](https://docs.python.org/3.13/library/ast.html#ast.Call)).

**Implemented:** `py_definition/9` has a file-and-span ID, lexical qualified name, kind and declared arity; `py_call_site/11` has a source-span ID, optional lexical caller ID, source-written callee form/text, positional count, keyword names and unpacking flags. `calls/5` remains conservative, and no existing reachability or dead-code rule consumes the new facts. Identifiers are snapshot-local: edits moving a definition change its ID. Definitions conditional on control flow and reassignment are not stable runtime bindings. See [the exact schema](tree-sitter-python.md).

**Tests:** Two classes with same method name, nested functions with same name, repeated top-level definitions, module-level calls, decorators, default expressions, lambdas, keyword-only calls, `*args` / `**kwargs`, chained calls, and sites on the same line. Assert no invented resolved edges and stable file-scoped identifiers across unchanged scans.

## 2. Expose Python's most useful source-written metadata

**Proposal:** Add dedicated syntax facts for imports (including alias, relative level, and star import), decorators, and parameter/return/variable annotations. Add module/class/function docstrings as prose or a **separate** Python-specific doc fact; do not reclassify them as `#` comments or silently feed them into `doc/5` if its function identity is ambiguous. Store annotation text, location and role; never call it an inferred type. Python's AST distinguishes `ImportFrom.level`, annotations, and function decorators; its `get_docstring` supports module, class and function docstrings ([AST grammar and imports](https://docs.python.org/3.13/library/ast.html#abstract-grammar), [AST docstrings](https://docs.python.org/3.13/library/ast.html#ast.get_docstring)).

**Tests:** `from ..pkg import x as y`, `from . import x`, `from x import *`, nested/decorated async methods, multiline docstrings and annotations, string forward references, `#` adjacent to docstrings. Keep imported-module *spellings* separate from resolved dependencies: namespace packages and import hooks make path inference environment-dependent ([Python import system](https://docs.python.org/3.13/reference/import.html)).

## 3. Add stub-file scanning as a separate source kind

**Proposal:** Scan `.pyi` using the same parser, but label facts as stub declarations; do not merge a `.pyi` declaration into the corresponding `.py` implementation or produce implementation call edges from it. A stub can describe an API without implementation; type-checker lookup prefers stubs over the corresponding source, but this syntax scanner is not a type checker ([Python typing specification: stub files and resolution order](https://typing.python.org/en/latest/spec/distributing.html#stub-files)).

**Tests:** Paired `pkg/mod.py` and `pkg/mod.pyi`, overloads with identical names, ellipsis bodies, standalone stubs, and incremental removal / modification. Verify that file and source-kind remain visible in every answer.

## 4. Improve parse completeness and diagnosability

The current extractor accepts UTF-8 only and rejects syntax errors for the whole file. This is safe but narrower than Python, which honors a UTF-8 BOM and encoding declarations in the first two physical lines. Python's `tokenize.detect_encoding` defines BOM/cookie handling and default UTF-8 ([tokenize documentation](https://docs.python.org/3.13/library/tokenize.html#tokenize.detect_encoding)).

**Proposal:** First publish explicit per-file status/reason and syntax provenance (grammar version, source kind, encoding policy). Then consider correct BOM and declared non-UTF-8 decoding with an offset map back to the original file. Do not simply decode then use UTF-8 Tree-sitter byte offsets as original-byte locations. Keep malformed or unsupported files fail-closed and do not report a complete scan when any file fails. Tree-sitter's Python grammar is a parser for source structure, not a CPython compile-time semantic validator ([pinned grammar](https://github.com/tree-sitter/tree-sitter-python/blob/v0.25.0/grammar.js)).

**Tests:** UTF-8 BOM, valid/invalid first- and second-line cookies, BOM/cookie disagreement, non-UTF-8 source, malformed Unicode, syntax errors, and cache invalidation after fixing a failed file. Compare acceptance and locations with CPython for a pinned version; document intentional divergences.

## 5. Defer resolution and inference until there is a separate, opt-in contract

Import resolution, callable binding, inferred types, and dead-code claims need environment and analysis policy; they cannot be reliably derived by renaming syntax facts. Python imports can be changed by finders and hooks, and typing information can come from stubs, typed packages and configured paths ([import system](https://docs.python.org/3.13/reference/import.html), [typing distribution specification](https://typing.python.org/en/latest/spec/distributing.html)). If semantic analysis becomes a requirement, use a separate opt-in checker with explicit interpreter/environment, dependency coverage, provenance, limits, freshness and failure states. On incomplete input, do not reuse old results or silently substitute syntax evidence for checker conclusions.

## Rollout and measurement

Stage 1 is additive and documented without changing the existing `calls/5` schema. Next implement (2), then (3) and (4), reviewing schema/version compatibility before each expansion. Benchmark cold scan, warm scan, memory and fact-store size on a few pinned Python projects, and report both coverage (sites/definitions found) and precision (false resolved edges: target zero). Use explicit user questions before designing the exact public schema or committing to semantic analysis.
