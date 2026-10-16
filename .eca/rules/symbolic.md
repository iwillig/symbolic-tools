# Symbolic fact-base workflow

This repository has a Symbolic MCP server, which scans source and docs into facts and answers relational Prolog queries. Use its tools for repository/codebase questions rather than relying only on language-model recollection or shell searches. ECA exposes MCP tools as `server__tool`; for this server use `symbolic__parse`, `symbolic__query`, `symbolic__overview`, `symbolic__search`, `symbolic__search_functions`, `symbolic__analyze_text`, `symbolic__extract`, and `symbolic__check`.

## Cache and tool selection

- On a fresh cache, call `symbolic__parse` before `query`, `search`, or `check`.
- Use `symbolic__overview` for cache state, fact counts, schema/predicate availability, or an unfamiliar predicate.
- Use `symbolic__search_functions` to discover function definitions by name or identifier terms. It searches parsed `defines/5` facts and returns function name, arity, file, line, and score. Exact normalized names rank before prefixes, substrings, and token matches; a query ending in `/N` (for example, `handle_event/2`) requires an exact name and arity. It supports snake_case/camelCase variants and split identifier words. Prefer this tool for ordinary function-name discovery; use the returned location in `symbolic__query` when you need relational facts.
- Inside a Prolog goal, use `text_search(Query, Hits)` or `text_search(Query, Limit, Hits)` to search function names together with prose. Function matches are case-insensitive normalized substring matches and have shape `hit(function, Name, Arity, File, Line, Score)`; prose hits have shape `hit(Kind, File, Line, Score)`. Do not enumerate `defines/5` and use `sub_atom/5` just to search names. `text_search` is a discovery/search result, not proof of a relationship; use structural predicates such as `defines/5`, `calls/5`, or appropriate derived predicates to verify relationships. Use `symbolic__search_functions` when you need its richer ranking/token matching or exact `/N` name+arity search.
- Use `symbolic__search` for documentation wording, comments, Markdown, and other indexed prose. The standalone prose search tool does not return function-definition results.
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
- Text values in `doc/5`, `comment/3`, `heading/4`, and `paragraph/3` are binaries and require `sub_text/5`; path atoms require `sub_atom/5`. Use `text_search/2,3` (or `symbolic__search_functions`) for function-name search instead of using `sub_atom/5` over function names.
- `sub_text/5` and `sub_atom/5` require an already-bound haystack; they do not generate bindings. Select facts first. A double-quoted text needle is appropriate for `sub_text/5`; a single-quoted atom needle is appropriate for `sub_atom/5`.

Example Prolog function-name search: `text_search("parse", Hits)`. This returns matching function and prose hits; inspect the `hit(function, Name, Arity, File, Line, Score)` entries for definitions, then query structural facts if needed.
- `all_*` audit predicates take exactly one argument: a list. Use their plain per-row predicate when you need rows and it exists.
- Derived predicates such as `callers/3`, `undocumented/4`, and `all_*` are available only when parsing reports a rules file; otherwise write a goal using loaded raw facts.

## Response format

For codebase answers, state the result and include the exact query goal plus returned JSON evidence. Keep it concise and distinguish facts returned by the tools from inferences. For non-codebase questions, answer directly.
