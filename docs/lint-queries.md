# Lint-style Prolog Queries

A small library of reusable Prolog rules for exploring a fact base like
a linter would — duplication, fan-in/fan-out, dead-code candidates,
undocumented pieces, risky calls — instead of asking "what does this
one function do" the way `docs/agent-examples.md` does. Same "hand-edit
the fact file" workflow the readme already establishes: append these
rules once, then query them like any other predicate.

Written and verified against this project's own `src/` directory —
every count and example below is real, captured output from actually
running the queries, not hand-written.

## A real bug this surfaced, worth knowing before you run these

`symbolic parse src` currently fails to `consult` back in:
`{6,erlog_scan,{illegal,"\`"}}`. Root cause, confirmed directly:
`erlog_io:writeq1/1` (used by both `symbolic_parse.erl` and
`symbolic_serve.erl` to print every fact) does not escape an embedded
single quote when quoting an atom —

```erlang
1> erlog_io:writeq1('it''s a test').
"'it's a test'"        %% invalid — the atom ends at the second '
```

Every prior test fixture in this project happened to avoid apostrophes,
so this never surfaced until pointed at this project's own prose
comments ("it's", "session's", "caller's" — ordinary English, all
through `src/`). Until this is fixed at the source
(`symbolic_parse.erl`/`symbolic_serve.erl` need to stop relying on
`erlog_io:writeq1/1`'s unescaped output for text containing quotes),
generating the numbers below required a corrected printer — same
logic `erlog_io` should have, just with proper `\'` escaping matching
what `erlog_scan.xrl`'s lexer actually accepts. Keep this in mind if
you run `symbolic parse` against a real codebase with ordinary prose
comments and hit the same parse error — it's not something you did
wrong.

## The rules

```prolog
%% Same function name defined in more than one file — a duplication or
%% naming-collision candidate.
duplicate_name(Fun, Files) :-
    defines(Fun, _, _),
    findall(File, defines(Fun, File, _), AllFiles),
    sort(AllFiles, Files),
    length(Files, N),
    N > 1.

all_duplicate_names(Pairs) :-
    findall(Fun-Files, duplicate_name(Fun, Files), Raw),
    sort(Raw, Pairs).

%% A function that calls itself directly by name. Caveat: this fact
%% base doesn't track arity, so Erlang overloads (query/2 calling
%% query/3) show up here too — a real, known limitation, not a bug in
%% this rule.
self_recursive(Fun, File) :-
    defines(Fun, File, _),
    calls(Fun, local(Fun), File, _).

%% Fan-out: how many distinct things a function calls.
fan_out(Fun, File, Count) :-
    defines(Fun, File, _),
    findall(Callee, calls(Fun, Callee, File, _), Callees),
    sort(Callees, Unique),
    length(Unique, Count).

top_fan_out(N, Top) :-
    findall(Count-Fun-File, fan_out(Fun, File, Count), Raw),
    sort(Raw, Sorted),
    reverse(Sorted, Ranked),
    take(N, Ranked, Top).

%% Fan-in: how many distinct local callers a function has.
fan_in(Fun, Count) :-
    defines(Fun, _, _),
    findall(Caller, calls(Caller, local(Fun), _, _), Callers),
    sort(Callers, Unique),
    length(Unique, Count).

top_fan_in(N, Top) :-
    findall(Count-Fun, fan_in(Fun, Count), Raw),
    sort(Raw, Sorted),
    reverse(Sorted, Ranked),
    take(N, Ranked, Top).

%% Defined but never called locally within this same parse. Caveat: a
%% real caller in a different directory (test/, or another module via
%% a *remote* call) won't show up here — this only sees local(...)
%% calls captured in the same parse run.
no_local_callers(Fun, File) :-
    defines(Fun, File, _),
    \+ calls(_, local(Fun), _, _).

all_no_local_callers(Pairs) :-
    findall(Fun-File, no_local_callers(Fun, File), Raw),
    sort(Raw, Pairs).

%% A comment not immediately followed by a recognized definition —
%% section headers, module-doc headers, inline explanations, etc.
undocumented_comment(File, Line, Text) :-
    comment(File, Line, Text),
    \+ doc(_, File, Line, _).

%% Calls into modules worth a second look in review (process control,
%% the filesystem, NIF loading, env vars).
risky_call(Caller, Module, Fun) :-
    calls(Caller, remote(Module, Fun), _, _),
    member(Module, [os, erlang, file, init]).

all_risky_calls(Triples) :-
    findall(Caller-Module-Fun, risky_call(Caller, Module, Fun), Raw),
    sort(Raw, Triples).

%% First N elements of a list — used to keep ranked results readable.
take(0, _, []) :- !.
take(_, [], []) :- !.
take(N, [H|T], [H|Rest]) :- N > 0, N1 is N - 1, take(N1, T, Rest).
```

## Running them against this repo's own `src/`

For scale: 223 `defines/3`, 711 `calls/4`, 423 `comment/3`, and 23
`doc/4` facts.

### Duplicate function names across modules

```sh
$ symbolic query -file facts.pl 'all_duplicate_names(Pairs)'
Pairs = [caller_name - ['src/ts_extract_bash.erl','src/ts_extract_erlang.erl','src/ts_extract_typescript.erl'],clean_join - ['src/ts_extract_bash.erl','src/ts_extract_erlang.erl','src/ts_extract_typescript.erl'],clean_line - ['src/ts_extract_bash.erl','src/ts_extract_erlang.erl','src/ts_extract_typescript.erl'],code_change - ['src/prolog_session.erl','src/prolog_session_registry.erl'],collect_run - ['src/ts_extract_bash.erl','src/ts_extract_erlang.erl','src/ts_extract_typescript.erl'],comment_nodes - ['src/ts_extract_bash.erl','src/ts_extract_erlang.erl','src/ts_extract_typescript.erl'],comments - ['src/ts_extract_bash.erl','src/ts_extract_erlang.erl','src/ts_extract_typescript.erl'],defines - ['src/ts_extract_bash.erl','src/ts_extract_erlang.erl','src/ts_extract_typescript.erl'],definition_name - ['src/ts_extract_bash.erl','src/ts_extract_erlang.erl','src/ts_extract_typescript.erl'],doc_fact - ['src/ts_extract_bash.erl','src/ts_extract_erlang.erl','src/ts_extract_typescript.erl'],docs - ['src/ts_extract_bash.erl','src/ts_extract_erlang.erl','src/ts_extract_typescript.erl'],file - ['src/ts_extract.erl','src/ts_extract_bash.erl','src/ts_extract_erlang.erl','src/ts_extract_json.erl','src/ts_extract_markdown.erl','src/ts_extract_toml.erl','src/ts_extract_typescript.erl'],find_named_child_by_type - ['src/ts_extract_json.erl','src/ts_extract_markdown.erl'],handle_call - ['src/prolog_session.erl','src/prolog_session_registry.erl'],handle_cast - ['src/prolog_session.erl','src/prolog_session_registry.erl'],handle_query - ['src/symbolic_query.erl','src/symbolic_serve.erl'],init - ['src/prolog_session.erl','src/prolog_session_registry.erl','src/prolog_session_sup.erl','src/symbolic_ts.erl'],is_run_start - ['src/ts_extract_bash.erl','src/ts_extract_erlang.erl','src/ts_extract_typescript.erl'],join_path - ['src/ts_extract_json.erl','src/ts_extract_toml.erl'],leaf_value - ['src/ts_extract_json.erl','src/ts_extract_toml.erl'],line - ['src/ts_extract_bash.erl','src/ts_extract_erlang.erl','src/ts_extract_json.erl','src/ts_extract_markdown.erl','src/ts_extract_toml.erl','src/ts_extract_typescript.erl'],local_calls - ['src/ts_extract_bash.erl','src/ts_extract_erlang.erl','src/ts_extract_typescript.erl'],name_to_list - ['src/symbolic_query.erl','src/symbolic_serve.erl'],run - ['src/symbolic_parse.erl','src/symbolic_query.erl','src/symbolic_serve.erl'],start_link - ['src/prolog_session.erl','src/prolog_session_registry.erl','src/prolog_session_sup.erl'],terminate - ['src/prolog_session.erl','src/prolog_session_registry.erl'],text - ['src/ts_extract_bash.erl','src/ts_extract_erlang.erl','src/ts_extract_typescript.erl'],to_atom - ['src/ts_extract_bash.erl','src/ts_extract_erlang.erl','src/ts_extract_json.erl','src/ts_extract_markdown.erl','src/ts_extract_toml.erl','src/ts_extract_typescript.erl'],to_lines - ['src/ts_extract_bash.erl','src/ts_extract_erlang.erl','src/ts_extract_typescript.erl'],truncate - ['src/ts_extract_bash.erl','src/ts_extract_erlang.erl','src/ts_extract_json.erl','src/ts_extract_markdown.erl','src/ts_extract_toml.erl','src/ts_extract_typescript.erl'],walk_pair - ['src/ts_extract_json.erl','src/ts_extract_toml.erl']]
```

`to_atom`/`truncate`/`line` are defined identically in all six
`ts_extract_*` modules; `clean_join`/`collect_run`/`comment_nodes`/
`is_run_start`/`caller_name`/`definition_name`/`defines`/`local_calls`/
`comments`/`docs`/`doc_fact`/`text`/`to_lines`/`clean_line` identically
across the three "code" extractors (erlang/typescript/bash);
`find_named_child_by_type`/`join_path`/`leaf_value`/`walk_pair`
identically across the "data" extractors (toml/json). This is a
**deliberate** tradeoff, not an oversight — several of these modules'
own header comments explicitly justify not sharing code between
per-language extractors — but this is the first time the scale of it
has been counted rather than eyeballed.

### Fan-out and fan-in

```sh
$ symbolic query -file facts.pl 'top_fan_out(5, X)'
X = [14 - file - 'src/ts_extract_toml.erl',13 - file - 'src/ts_extract_markdown.erl',12 - text - 'src/ts_extract_typescript.erl',12 - text - 'src/ts_extract_erlang.erl',12 - file - 'src/ts_extract_json.erl']

$ symbolic query -file facts.pl 'top_fan_in(5, X)'
X = [13 - to_atom,11 - line,4 - walk_pair,4 - render_caught,4 - find_named_child_by_type]
```

The highest fan-out functions are exactly the top-level per-language
entry points (`file/1`, `text/2`) that orchestrate everything else in
their module — unsurprising, and a good sanity check that the ranking
works. `to_atom/1` is the single most relied-upon function in the
codebase (13 distinct callers).

### Self-recursive functions (and a real limitation this reveals)

```sh
$ symbolic query -file facts.pl 'findall(F-Fl, self_recursive(F, Fl), Xs)'
F = _0
Fl = _1
Xs = [caller_name - 'src/ts_extract_bash.erl',caller_name - 'src/ts_extract_erlang.erl',caller_name - 'src/ts_extract_typescript.erl',collect_run - 'src/ts_extract_bash.erl',collect_run - 'src/ts_extract_erlang.erl',collect_run - 'src/ts_extract_typescript.erl',find_named_child_by_type - 'src/ts_extract_json.erl',find_named_child_by_type - 'src/ts_extract_json.erl',find_named_child_by_type - 'src/ts_extract_json.erl',find_named_child_by_type - 'src/ts_extract_json.erl',find_named_child_by_type - 'src/ts_extract_json.erl',find_named_child_by_type - 'src/ts_extract_json.erl',find_named_child_by_type - 'src/ts_extract_markdown.erl',find_named_child_by_type - 'src/ts_extract_markdown.erl',find_named_child_by_type - 'src/ts_extract_markdown.erl',find_named_child_by_type - 'src/ts_extract_markdown.erl',find_named_child_by_type - 'src/ts_extract_markdown.erl',find_named_child_by_type - 'src/ts_extract_markdown.erl',query - 'src/prolog_session.erl',query - 'src/prolog_session.erl',to_atom - 'src/ts_extract_bash.erl',to_atom - 'src/ts_extract_bash.erl',to_atom - 'src/ts_extract_erlang.erl',to_atom - 'src/ts_extract_erlang.erl',to_atom - 'src/ts_extract_json.erl',to_atom - 'src/ts_extract_json.erl',to_atom - 'src/ts_extract_markdown.erl',to_atom - 'src/ts_extract_markdown.erl',to_atom - 'src/ts_extract_toml.erl',to_atom - 'src/ts_extract_toml.erl',to_atom - 'src/ts_extract_typescript.erl',to_atom - 'src/ts_extract_typescript.erl',to_lines - 'src/ts_extract_bash.erl',to_lines - 'src/ts_extract_bash.erl',to_lines - 'src/ts_extract_erlang.erl',to_lines - 'src/ts_extract_erlang.erl',to_lines - 'src/ts_extract_typescript.erl',to_lines - 'src/ts_extract_typescript.erl',walk_pair - 'src/ts_extract_toml.erl']
```

Most of these are genuinely, deliberately recursive (`caller_name`/
`collect_run` walk the tree; `find_named_child_by_type` scans siblings;
`to_atom`/`to_lines` dispatch on binary-vs-list via a second clause that
calls itself once). `query - 'src/prolog_session.erl'` is **not**
actually recursive, though — `query/2` calls `query/3`. This fact base
doesn't track arity (documented from early in the project as "no module
name or arity yet"), so same-named functions of different arity are
indistinguishable from real recursion. Worth knowing before trusting
this query's output at face value.

### Risky calls (process control, filesystem, NIF loading)

```sh
$ symbolic query -file facts.pl 'all_risky_calls(Triples)'
Triples = [file - file - read_file,handle_call - erlang - monitor,handle_call - file - delete,handle_call - file - write_file,init - erlang - load_nif,node_child_by_field_name - erlang - nif_error,node_end_byte - erlang - nif_error,node_is_null - erlang - nif_error,node_named_child - erlang - nif_error,node_named_child_count - erlang - nif_error,node_next_sibling - erlang - nif_error,node_parent - erlang - nif_error,node_prev_sibling - erlang - nif_error,node_start_byte - erlang - nif_error,node_start_point - erlang - nif_error,node_type - erlang - nif_error,parser_new - erlang - nif_error,parser_parse_string - erlang - nif_error,parser_set_language - erlang - nif_error,prove_with_timeout - erlang - demonitor,query_capture - erlang - nif_error,query_new - erlang - nif_error,tmp_dir - os - getenv,tmp_path - erlang - unique_integer,tree_root_node - erlang - nif_error,tree_sitter_bash - erlang - nif_error,tree_sitter_erlang - erlang - nif_error,tree_sitter_json - erlang - nif_error,tree_sitter_markdown - erlang - nif_error,tree_sitter_toml - erlang - nif_error,tree_sitter_typescript - erlang - nif_error,undefined - file - filename]
```

Mostly legitimate, load-bearing glue — `erlang:nif_error` in every NIF
stub, `erlang:load_nif` in `symbolic_ts:init/0`, `file:read_file/
write_file/delete` for the session's temp-file consult trick,
`os:getenv` for `TMPDIR`, `erlang:monitor/demonitor` for process
supervision. Nothing here looked concerning on inspection — but that
last entry, `undefined - file - filename`, is a second real finding:

**`-spec` type annotations get extracted as fake `calls/4` facts.**
`-spec file(file:filename()) -> [tuple()].` (`src/ts_extract.erl` and
several others) produces `calls(undefined, remote(file, filename),
File, Line)` — `file:filename()` there is a **type** reference, not a
call, but tree-sitter-erlang's grammar shapes a `-spec`'s contents
identically to a real function call, and `ts_extract_erlang.erl`'s
`(call expr: (remote) @call)` query doesn't distinguish the two.
`Caller = undefined` in every case is the tell — a `-spec` lives
outside any `function_clause`, so the caller-attribution walk-up finds
nothing. Low severity (nothing crashes), but real noise in `calls/4`
for any `-spec`-heavy Erlang code, which is all of it here — a
"exclude `-spec`/`-type` attribute bodies" fix belongs in
`ts_extract_erlang.erl`'s query, not in this rule file.

### "No local callers" — mostly false positives, and why

```sh
$ symbolic query -file facts.pl 'all_no_local_callers(Pairs)'
```

27 functions matched (OTP callbacks like `handle_call`/`handle_cast`/
`init`/`terminate`, every extractor's `file/1`, every `symbolic_ts`
NIF stub, and a handful more). Almost none of this is actually dead
code: OTP callbacks are invoked by the framework, never by name from
application code, and every extractor's `file/1` is called
**remotely** (`ts_extract_erlang:file/1` from `ts_extract.erl`'s
dispatcher), not locally — `no_local_callers/2` only checks
`local(...)` call sites, so it's structurally blind to cross-module
wiring. A rule that actually found dead code would need to check both
`local` and `remote` call shapes before concluding "nothing calls
this."

## References

- [`agent-examples.md`](agent-examples.md) — the narrative version of
  this same idea (an agent asking one question at a time, with
  narrower helper rules like `callers/2`/`callees/2`).
- [`../readme.md`](../readme.md) — the "hand-edit the fact file"
  pattern (`contains/2`, `stale_doc_example/3`) these rules extend.
