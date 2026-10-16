# Symbolic fact-base workflow

This repository has a Symbolic MCP server, which scans source and docs into facts and answers relational Prolog queries. Use its tools for repository/codebase questions rather than relying only on language-model recollection or shell searches. ECA exposes MCP tools as `server__tool`; for this server use `symbolic__parse`, `symbolic__query`, `symbolic__overview`, `symbolic__search`, `symbolic__search_functions`, `symbolic__analyze_text`, `symbolic__extract`, and `symbolic__check`.

## Cache and tool selection

- On a fresh cache, call `symbolic__parse` before `query`, `search`, or `check`.
- Use `symbolic__overview` for cache state, fact counts, schema/predicate availability, or an unfamiliar predicate.
- Use `symbolic__search_functions` to find function definitions by name or identifier terms. It searches parsed `defines/5` facts and returns only definitions with function name, arity, file, line, and score. Exact normalized names rank before prefixes, substrings, and token matches; `name/N` requires an exact name and arity. It can match snake_case/camelCase variants and split identifier words.
- Use `symbolic__search` for documentation wording, comments, Markdown, and other indexed prose. Prose search is separate and does not return function-definition results.
- Use `symbolic__query` for relational questions about definitions, callers/callees, dependencies, complexity, dead code, and lint results; search is for discovery, while query is for structured relationships.
- For claim validation, analyze the exact claim with `symbolic__analyze_text`, map its bounded frames to known predicates, then construct a goal yourself and query it. Frames are suggestions, not proof. Do not run arbitrary model-generated Prolog. Use `symbolic__check` only when specifically asked for its built-in extract-and-check operation.
- `symbolic__ask` is compatibility-only; use direct queries for ordinary code questions and do not use `ask` in claim validation.

## Query correctness

- Use one conjunctive goal for a compound claim. Bind every named function, arity, module, and file.
- A successful query with zero solutions is not proof of the opposite; report that no solutions were returned. An error is not a zero-result proof. Quote tool errors exactly.
- `overview` is authoritative for loaded predicates and their arities. If a predicate family is absent, do not query it or claim an empty result. If a listed predicate errors, quote the error and investigate its exact schema rather than guessing another arity.
- Bind fact arguments exactly by position. Core shapes:
  - `defines(Function, Arity, Params, File, Line)`
  - `calls(Caller, CallerArity, CallSpec, File, Line)`
  - `doc(Function, Arity, File, Line, Text)`
  - `comment(File, Line, Text)`
  - `heading(File, Level, Title, Line)`
  - `branch(Function, Arity, Kind, File, Line)`
- `CallSpec` is `local(Name, Arity)`, `remote(Module, Name, Arity)`, `member(Object, Method, Arity)`, or `new(Constructor, Arity)`.
- File paths are absolute atoms; use single quotes. To filter under a directory use an anchored absolute prefix, e.g. `sub_atom(File, 0, _, _, '/absolute/repo/src/')`.
- Text values in `doc/5`, `comment/3`, `heading/4`, and `paragraph/3` are binaries and require `sub_text/5`; path atoms require `sub_atom/5`.
- Both substring predicates require an already-bound haystack; they do not generate bindings. Select facts first. A double-quoted text needle is appropriate for `sub_text/5`; a single-quoted atom needle is appropriate for `sub_atom/5`.
- `all_*` audit predicates take exactly one argument: a list. Use their plain per-row predicate when you need rows and it exists.
- Derived predicates such as `callers/3`, `undocumented/4`, and `all_*` are available only when parsing reports a rules file; otherwise write a goal using loaded raw facts.

## Response format

For codebase answers, state the result and include the exact query goal plus returned JSON evidence. Keep it concise and distinguish facts returned by the tools from inferences. For non-codebase questions, answer directly.
