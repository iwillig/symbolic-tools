# Python Tree-sitter integration

`.py` files are scanned through the vendored `tree-sitter-python` grammar,
release [v0.25.0](https://github.com/tree-sitter/tree-sitter-python/releases/tag/v0.25.0)
(language ABI 15, MIT). The release archive SHA-256 is
`7bce887eb2f33e94bf74a69645cf5138d4096720e54fd3269a6124c06b93c584`.
The generated parser, scanner, headers, node types and LICENSE live under
`c_src/grammars/python/`. The Rust NIF uses the same grammar/core build
pipeline as the other languages. Grammar upgrades must be pinned and tested
against the emitted fact shapes.

This is **syntax-only** extraction, not Python execution, name resolution,
import resolution, inferred types, or a complete call graph. Two additive
Python-only facts preserve scoped definitions and all parsed call sites,
without changing the legacy cross-language facts:

- `py_definition(Id, Name, Qualified, Kind, Arity, File, Line, StartByte, EndByte)`
  records every named `def`/`async def`. `Id` is the compound
  `(File, StartByte, EndByte)`, unique within a snapshot; it changes when
  source offsets change. `Qualified` is a binary of **lexical** class and
  function names joined by `.` (for example, `<<"Outer.run">>`), not a
  resolved Python `__qualname__`. `Kind` is `module_function`,
  `nested_function`, or `method`, based on the nearest containing definition
  or class. `Arity` has the same declared-parameter meaning as `defines/5`.
  Two definitions with identical names and arities still have distinct IDs.
- `py_call_site(Id, CallerId, Callee, Form, Positional, Keywords, Unpacks,
  File, Line, StartByte, EndByte)` records each parsed call expression.
  `Id` uses the same file-and-byte-span convention. `CallerId` joins to a
  `py_definition/9` only when the call is inside that definition's body;
  it is `undefined` in module/class bodies, decorators, defaults and lambdas.
  `Callee` is a binary containing its source spelling. `Form` is `name`,
  `attribute` or `computed`. `Positional` counts explicit positional
  arguments; `Keywords` is an ordered list of binary keyword names;
  `Unpacks` lists `star_args` / `star_kwargs` where used. A bare generator
  argument has `Positional=1` and `Unpacks=[bare_generator]` to preserve its
  syntax. `CallerId` identifies a lexical container, **not** a callee.
  Neither `py_call_site/11` nor `py_definition/9` is used by existing
  reachability or dead-code rules. Byte offsets refer to the accepted UTF-8
  source, with an exclusive end offset.

For example, `py_definition(Id, _, _, _, _, File, _, _, _),
py_call_site(_, Id, _, _, _, _, _, File, Line, _, _)` lists sites in a
specific lexical definition. Inspect `Callee`, `Keywords`, and `Unpacks`
without interpreting the site as a resolved edge.

The original shared predicates remain deliberately limited:

- `defines(Name, Arity, Params, File, Line)` is emitted for named `def` and
  `async def`, including nested functions and class methods. `Arity` is the
  number of declared parameter nodes excluding bare `/` and `*` separators.
  Defaults, `*args` and `**kwargs` each count as one parameter. `self`/`cls`
  are counted too. It is **not** the number of arguments accepted by a
  callable, and class/nested qualifiers are not part of `Name`; definitions
  in different scopes may share one `Name/Arity` identity. `Params` is the
  source-written parameter list as a binary.
- `comment(File, Line, Text)` records `#` comments with the `#` marker,
  including shebang and encoding comments. Docstrings are strings, not
  `comment/3` or `doc/5` facts.
- `calls(Caller, CallerArity, CallSpec, File, Line)` is emitted only for calls
  syntactically inside a **unique top-level** `def`/`async def`. `foo(a)`
  gives `local(foo, 1)`; `obj.foo(a)` gives `member(obj, foo, 1)` if `obj`
  is a bare identifier. These are *spellings of call sites*, not resolved
  callee identities: `foo` may be rebound, imported or a callable instance,
  and `obj` may refer to anything. Top-level calls, calls in class/nested
  definitions, class bodies or lambdas, and calls with a keyword argument, `*args`,
  `**kwargs`, a generator argument without parentheses, or a complex callee
  are omitted. Calls in decorators, defaults and annotations are omitted
  rather than assigned to a function body. Nested simple calls still appear
  separately when enclosed by an eligible top-level definition. Do not interpret the absence of
  `calls/5` as proof that no call occurs, or use `truly_uncalled/3` as a
  reliable Python dead-code detector.

Files must contain UTF-8 source and may declare `coding: utf-8`/`utf8` in
one of the first two lines. Other declared encodings, undecodable bytes and
Tree-sitter syntax errors fail that file's extraction; the scan reports it
in `failed_files` and `scan_complete: false`, rather than publishing partial
facts for that file. This is a conservative parser policy, not a Python
interpreter's exact acceptance test. Relative imports, annotations,
`*.pyi` and semantic checking are outside this initial scope.

See [the fact schema](prolog-schema.md) and the
[research note](python-support-research.md) for the rationale and follow-up
options.
