# Lint-style Prolog Queries

A small library of reusable Prolog rules for exploring a fact base like
a linter would — duplication, fan-in/fan-out, dead-code candidates,
undocumented pieces, risky calls — instead of asking "what does this
one function do" the way `docs/agent-examples.md` does. Save these
rules to a `.pl` file once, then load them alongside a fact database:

```sh
$ symbolic parse src -db facts.dets
$ symbolic query -db facts.dets -rules lint-rules.pl 'all_duplicate_names(Pairs)'
```

Written and verified against this project's own `src/` directory —
every count and example below is real, captured output from actually
running the queries, not hand-written.

## A real bug this used to surface — now fixed

Facts used to round-trip through raw Prolog text
(`erlog_io:writeq1/1` printed them, `erlog:consult/2` re-parsed them),
and that printer didn't escape an embedded single quote when quoting an
atom at all:

```erlang
1> erlog_io:writeq1('it''s a test').
"'it's a test'"        %% invalid — the atom ends at the second '
```

Every prior test fixture in this project happened to avoid apostrophes,
so this never surfaced until pointed at this project's own prose
comments ("it's", "session's", "caller's" — ordinary English, all
through `src/`) — `symbolic parse src` would fail to `consult` its own
output back in.

**Fixed at the source, not worked around**: free-text fact fields
(`comment/3`/`doc/5`'s `Text`, and friends — see
[`prolog-schema.md`](prolog-schema.md)) are now Erlang binaries instead
of atoms (`ts_extract_text.erl`), and facts move as JSON
(`symbolic_term_json.erl`, via `jsx`) or as raw Erlang terms asserted
directly into erlog (`prolog_session:load_facts/2`) — never as printed-
and-reparsed Prolog text. See [`prolog-store.md`](prolog-store.md) §7
for the full story. The numbers below are real output from the current,
fixed pipeline.

## The rules

```prolog
%% Same function/arity defined in more than one file — a duplication or
%% naming-collision candidate. Keyed on Fun+Arity (not bare Fun): a
%% function of one name but two arities in the same file, like Erlang's
%% query/2 and query/3, is two overloads, not a duplicate.
duplicate_name(Fun, Arity, Files) :-
    defines(Fun, Arity, _, _, _),
    findall(File, defines(Fun, Arity, _, File, _), AllFiles),
    sort(AllFiles, Files),
    length(Files, N),
    N > 1.

all_duplicate_names(Triples) :-
    findall(Fun-Arity-Files, duplicate_name(Fun, Arity, Files), Raw),
    sort(Raw, Triples).

%% A function that calls itself directly by name AND arity — fully
%% precise on both sides: CallerArity = Arity requires the call site to
%% be textually inside THIS exact clause, and local(Fun, Arity) requires
%% the call target to be this exact arity too. Closes both halves of the
%% old bare-name gap (query/2-vs-query/3 on the target side, and
%% query/1-calls-query/2 on the caller side).
self_recursive(Fun, Arity, File) :-
    defines(Fun, Arity, _, File, _),
    calls(Fun, Arity, local(Fun, Arity), File, _).

%% Fan-out: how many distinct things a function calls.
fan_out(Fun, File, Count) :-
    defines(Fun, _Arity, _, File, _),
    findall(Callee, calls(Fun, _CallerArity, Callee, File, _), Callees),
    sort(Callees, Unique),
    length(Unique, Count).

top_fan_out(N, Top) :-
    findall(Count-Fun-File, fan_out(Fun, File, Count), Raw),
    sort(Raw, Sorted),
    reverse(Sorted, Ranked),
    take(N, Ranked, Top).

%% Fan-in: how many distinct local callers a function/arity has.
fan_in(Fun, Arity, Count) :-
    defines(Fun, Arity, _, _, _),
    findall(Caller, calls(Caller, _CallerArity, local(Fun, Arity), _, _), Callers),
    sort(Callers, Unique),
    length(Unique, Count).

top_fan_in(N, Top) :-
    findall(Count-Fun-Arity, fan_in(Fun, Arity, Count), Raw),
    sort(Raw, Sorted),
    reverse(Sorted, Ranked),
    take(N, Ranked, Top).

%% Defined but never called locally (by name+arity) within this same
%% parse. Caveat: a real caller in a different directory (test/, or
%% another module via a *remote* call) won't show up here — this only
%% sees local(...) calls captured in the same parse run.
no_local_callers(Fun, Arity, File) :-
    defines(Fun, Arity, _, File, _),
    \+ calls(_, _CallerArity, local(Fun, Arity), _, _).

all_no_local_callers(Triples) :-
    findall(Fun-Arity-File, no_local_callers(Fun, Arity, File), Raw),
    sort(Raw, Triples).

%% A comment not immediately followed by a recognized definition —
%% section headers, module-doc headers, inline explanations, etc.
undocumented_comment(File, Line, Text) :-
    comment(File, Line, Text),
    \+ doc(_, _, File, Line, _).

%% Calls into modules worth a second look in review (process control,
%% the filesystem, NIF loading, env vars).
risky_call(Caller, Module, Fun) :-
    calls(Caller, _CallerArity, remote(Module, Fun, _ArgCount), _, _),
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

For scale (at the time this section was captured): 222 `defines/3`, 723
`calls/4`, 524 `comment/3`, and 23 `doc/4` facts.

**Everything below this point predates two things**: this project's own
`src/` growing since the numbers were captured, and two schema changes
(`docs/prolog-schema.md`) — `defines`/`doc` gaining `Arity`/`Params`, and
`calls` gaining `CallerArity` plus an `ArgCount` on every `local`/
`remote`/`member` term. The query *syntax* below (`duplicate_name/3` etc., already updated above)
still runs; the *captured output* (counts, JSON blobs) will differ from
a fresh `symbolic parse src -db facts.dets` run today — regenerate
rather than trust these numbers at face value.

**A visible side effect of the JSON output format** (`prolog-store.md`
§7): a bound `Key - Value` pair — the `-/2` infix operator, a plain
Prolog compound term — renders as a 3-element array `["-", Key, Value]`,
not as `Key - Value` text. Every array below whose first element is
`"-"` is one of these pairs; read `["-", A, B]` as `A - B`.

### Duplicate function names across modules

```sh
$ symbolic query -db facts.dets -rules lint-rules.pl 'all_duplicate_names(Triples)'
Triples = [["-","caller_name",["src/ts_extract_bash.erl","src/ts_extract_erlang.erl","src/ts_extract_typescript.erl"]],["-","clean_join",["src/ts_extract_bash.erl","src/ts_extract_erlang.erl","src/ts_extract_typescript.erl"]],["-","clean_line",["src/ts_extract_bash.erl","src/ts_extract_erlang.erl","src/ts_extract_typescript.erl"]],["-","code_change",["src/prolog_session.erl","src/prolog_session_registry.erl"]],["-","collect_run",["src/ts_extract_bash.erl","src/ts_extract_erlang.erl","src/ts_extract_typescript.erl"]],["-","comment_nodes",["src/ts_extract_bash.erl","src/ts_extract_erlang.erl","src/ts_extract_typescript.erl"]],["-","comments",["src/ts_extract_bash.erl","src/ts_extract_erlang.erl","src/ts_extract_typescript.erl"]],["-","defines",["src/ts_extract_bash.erl","src/ts_extract_erlang.erl","src/ts_extract_typescript.erl"]],["-","definition_name",["src/ts_extract_bash.erl","src/ts_extract_erlang.erl","src/ts_extract_typescript.erl"]],["-","doc_fact",["src/ts_extract_bash.erl","src/ts_extract_erlang.erl","src/ts_extract_typescript.erl"]],["-","docs",["src/ts_extract_bash.erl","src/ts_extract_erlang.erl","src/ts_extract_typescript.erl"]],["-","file",["src/ts_extract.erl","src/ts_extract_bash.erl","src/ts_extract_erlang.erl","src/ts_extract_json.erl","src/ts_extract_markdown.erl","src/ts_extract_toml.erl","src/ts_extract_typescript.erl"]],["-","find_named_child_by_type",["src/ts_extract_json.erl","src/ts_extract_markdown.erl"]],["-","handle_call",["src/prolog_session.erl","src/prolog_session_registry.erl"]],["-","handle_cast",["src/prolog_session.erl","src/prolog_session_registry.erl"]],["-","handle_query",["src/symbolic_query.erl","src/symbolic_serve.erl"]],["-","init",["src/prolog_session.erl","src/prolog_session_registry.erl","src/prolog_session_sup.erl","src/symbolic_ts.erl"]],["-","is_run_start",["src/ts_extract_bash.erl","src/ts_extract_erlang.erl","src/ts_extract_typescript.erl"]],["-","join_path",["src/ts_extract_json.erl","src/ts_extract_toml.erl"]],["-","leaf_value",["src/ts_extract_json.erl","src/ts_extract_toml.erl"]],["-","line",["src/ts_extract_bash.erl","src/ts_extract_erlang.erl","src/ts_extract_json.erl","src/ts_extract_markdown.erl","src/ts_extract_toml.erl","src/ts_extract_typescript.erl"]],["-","local_calls",["src/ts_extract_bash.erl","src/ts_extract_erlang.erl","src/ts_extract_typescript.erl"]],["-","name_to_list",["src/symbolic_query.erl","src/symbolic_serve.erl"]],["-","run",["src/symbolic_parse.erl","src/symbolic_query.erl","src/symbolic_serve.erl"]],["-","run_checked",["src/symbolic_parse.erl","src/symbolic_query.erl"]],["-","start_link",["src/prolog_session.erl","src/prolog_session_registry.erl","src/prolog_session_sup.erl"]],["-","terminate",["src/prolog_session.erl","src/prolog_session_registry.erl"]],["-","text",["src/ts_extract_bash.erl","src/ts_extract_erlang.erl","src/ts_extract_typescript.erl"]],["-","to_lines",["src/ts_extract_bash.erl","src/ts_extract_erlang.erl","src/ts_extract_typescript.erl"]],["-","walk_pair",["src/ts_extract_json.erl","src/ts_extract_toml.erl"]]]
```

`line` is still defined identically in all six `ts_extract_*` modules
(never consolidated — it's a one-liner reading a query node's own start
position, different node per module); `clean_join`/`collect_run`/
`comment_nodes`/`is_run_start`/`caller_name`/`definition_name`/
`defines`/`local_calls`/`comments`/`docs`/`doc_fact`/`text`/`to_lines`/
`clean_line` identically across the three "code" extractors (erlang/
typescript/bash); `find_named_child_by_type`/`join_path`/`leaf_value`/
`walk_pair` identically across the "data" extractors (toml/json). This
is a **deliberate** tradeoff, not an oversight — several of these
modules' own header comments explicitly justify not sharing code
between per-language extractors. `to_atom`/`truncate`, previously
duplicated in all six modules the same way, are gone from this list now
— consolidated into `ts_extract_text.erl` (`prolog-store.md` §7) as
part of fixing the escaping/truncation bug above.

### Fan-out and fan-in

```sh
$ symbolic query -db facts.dets -rules lint-rules.pl 'top_fan_out(5, X)'
X = [["-",["-",14,"file"],"src/ts_extract_toml.erl"],["-",["-",13,"file"],"src/ts_extract_markdown.erl"],["-",["-",12,"walk_pair"],"src/ts_extract_toml.erl"],["-",["-",12,"text"],"src/ts_extract_typescript.erl"],["-",["-",12,"text"],"src/ts_extract_erlang.erl"]]

$ symbolic query -db facts.dets -rules lint-rules.pl 'top_fan_in(5, X)'
X = [["-",11,"line"],["-",10,"to_atom"],["-",4,"walk_pair"],["-",4,"to_text"],["-",4,"render_caught"]]
```

The highest fan-out functions are exactly the top-level per-language
entry points (`file/1`, `text/2`) that orchestrate everything else in
their module — unsurprising, and a good sanity check that the ranking
works. `to_atom/1` (now `ts_extract_text:to_atom/1`, imported
unqualified into all six extractors — see `prolog-store.md` §7) is
still the single most relied-upon function in the codebase (10 distinct
callers); its sibling `to_text/1` already has 4.

### Self-recursive functions (and a limitation that used to be here)

```sh
$ symbolic query -db facts.dets -rules lint-rules.pl 'findall(F-A-Fl, self_recursive(F, A, Fl), Xs)'
F = [0]
A = [2]
Fl = [1]
Xs = [["-","caller_name","src/ts_extract_bash.erl"],["-","caller_name","src/ts_extract_erlang.erl"],["-","caller_name","src/ts_extract_typescript.erl"],["-","collect_run","src/ts_extract_bash.erl"],["-","collect_run","src/ts_extract_erlang.erl"],["-","collect_run","src/ts_extract_typescript.erl"],["-","encode_term","src/symbolic_term_json.erl"],["-","encode_term","src/symbolic_term_json.erl"],["-","encode_term","src/symbolic_term_json.erl"],["-","encode_term","src/symbolic_term_json.erl"],["-","encode_term","src/symbolic_term_json.erl"],["-","encode_term","src/symbolic_term_json.erl"],["-","encode_term","src/symbolic_term_json.erl"],["-","encode_term","src/symbolic_term_json.erl"],["-","encode_term","src/symbolic_term_json.erl"],["-","encode_term","src/symbolic_term_json.erl"],["-","find_named_child_by_type","src/ts_extract_json.erl"],["-","find_named_child_by_type","src/ts_extract_json.erl"],["-","find_named_child_by_type","src/ts_extract_json.erl"],["-","find_named_child_by_type","src/ts_extract_json.erl"],["-","find_named_child_by_type","src/ts_extract_json.erl"],["-","find_named_child_by_type","src/ts_extract_json.erl"],["-","find_named_child_by_type","src/ts_extract_markdown.erl"],["-","find_named_child_by_type","src/ts_extract_markdown.erl"],["-","find_named_child_by_type","src/ts_extract_markdown.erl"],["-","find_named_child_by_type","src/ts_extract_markdown.erl"],["-","find_named_child_by_type","src/ts_extract_markdown.erl"],["-","find_named_child_by_type","src/ts_extract_markdown.erl"],["-","query","src/prolog_session.erl"],["-","query","src/prolog_session.erl"],["-","run","src/symbolic_parse.erl"],["-","run","src/symbolic_parse.erl"],["-","run","src/symbolic_query.erl"],["-","run","src/symbolic_query.erl"],["-","to_atom","src/ts_extract_text.erl"],["-","to_atom","src/ts_extract_text.erl"],["-","to_lines","src/ts_extract_bash.erl"],["-","to_lines","src/ts_extract_bash.erl"],["-","to_lines","src/ts_extract_erlang.erl"],["-","to_lines","src/ts_extract_erlang.erl"],["-","to_lines","src/ts_extract_typescript.erl"],["-","to_lines","src/ts_extract_typescript.erl"],["-","walk_pair","src/ts_extract_toml.erl"]]
```

`F = [0]` / `Fl = [1]` are the query's own top-level variables, unbound
outside the `findall/3` (its template variables don't get bound in the
surrounding scope — a real Prolog semantics quirk, not a bug). erlog
represents an unbound variable internally as a 1-tuple, `{Name}` (its
own `erlog.erl` header: "Variables - {Name} where Name is an atom or
integer") — `symbolic_term_json.erl` renders any tuple as an array, so
these show up as `[0]`/`[1]` rather than the `_0`/`_1` a Prolog-text
printer would use. Harmless, just a different spelling of "unbound."

Most of the real matches are genuinely, deliberately recursive
(`caller_name`/`collect_run` walk the tree; `find_named_child_by_type`
scans siblings; `to_atom`/`to_lines`/`encode_term` dispatch on their
argument's shape via a second clause that calls itself once).

**A real limitation this query used to have, now fixed in two stages**:
the captured output above (from before `defines`/`calls` tracked arity
at all) included `["-","query","src/prolog_session.erl"]` and
`["-","run","src/symbolic_parse.erl"]` as false positives — any
same-named call looked recursive when only the bare name was checked.

- **Stage 1** (target-side): `defines`/`calls` gained `Arity`, and
  `self_recursive/3` started requiring `local(Fun, Arity)` to match the
  definition's own arity. This closed the "`query/2` looks recursive
  because it calls `query/3`" shape of false positive — but a *subtler*
  one survived: `symbolic_codebase:query/1`'s body calls `query/2`
  (`query(Goal) -> query(Goal, ?DEFAULT_LIMIT)`), and since the caller
  attribution was still bare-name, that call site — really inside
  `query/1` — got attributed to plain `query`, indistinguishable from a
  call genuinely inside `query/2`. `self_recursive(query, 2, File)`
  matched: `defines(query, 2, ...)` exists, and *some* `calls(query,
  local(query, 2), ...)` fact existed too, just not one that actually
  came from query/2's own body.
- **Stage 2** (caller-side): `calls` gained `CallerArity` — the
  enclosing clause's own arity, not just its name. `self_recursive/3`
  now binds `CallerArity = Arity`, requiring the call site to be
  textually inside *that exact* clause. `query/1`'s call to `query/2`
  has `CallerArity` 1, which no longer unifies with `query/2`'s
  `Arity` 2 check.

Re-running the query above against a fresh parse should no longer
include either `query` or `run`.

### Risky calls (process control, filesystem, NIF loading)

```sh
$ symbolic query -db facts.dets -rules lint-rules.pl 'all_risky_calls(Triples)'
Triples = [["-",["-","file","file"],"read_file"],["-",["-","handle_call","erlang"],"monitor"],["-",["-","handle_call","file"],"delete"],["-",["-","handle_call","file"],"write_file"],["-",["-","init","erlang"],"load_nif"],["-",["-","node_child_by_field_name","erlang"],"nif_error"],["-",["-","node_end_byte","erlang"],"nif_error"],["-",["-","node_is_null","erlang"],"nif_error"],["-",["-","node_named_child","erlang"],"nif_error"],["-",["-","node_named_child_count","erlang"],"nif_error"],["-",["-","node_next_sibling","erlang"],"nif_error"],["-",["-","node_parent","erlang"],"nif_error"],["-",["-","node_prev_sibling","erlang"],"nif_error"],["-",["-","node_start_byte","erlang"],"nif_error"],["-",["-","node_start_point","erlang"],"nif_error"],["-",["-","node_type","erlang"],"nif_error"],["-",["-","parser_new","erlang"],"nif_error"],["-",["-","parser_parse_string","erlang"],"nif_error"],["-",["-","parser_set_language","erlang"],"nif_error"],["-",["-","prove_with_timeout","erlang"],"demonitor"],["-",["-","query_capture","erlang"],"nif_error"],["-",["-","query_new","erlang"],"nif_error"],["-",["-","table_name","erlang"],"phash2"],["-",["-","tmp_dir","os"],"getenv"],["-",["-","tmp_path","erlang"],"unique_integer"],["-",["-","tree_root_node","erlang"],"nif_error"],["-",["-","tree_sitter_bash","erlang"],"nif_error"],["-",["-","tree_sitter_erlang","erlang"],"nif_error"],["-",["-","tree_sitter_json","erlang"],"nif_error"],["-",["-","tree_sitter_markdown","erlang"],"nif_error"],["-",["-","tree_sitter_toml","erlang"],"nif_error"],["-",["-","tree_sitter_typescript","erlang"],"nif_error"],["-",["-","undefined","file"],"filename"]]
```

Mostly legitimate, load-bearing glue — `erlang:nif_error` in every NIF
stub, `erlang:load_nif` in `symbolic_ts:init/0`, `file:read_file/
write_file/delete` for the session's temp-file consult trick and the
new fact-store's DETS file, `os:getenv` for `TMPDIR`,
`erlang:monitor/demonitor` for process supervision, `erlang:phash2` in
`symbolic_fact_store.erl`'s DETS table-name derivation. Nothing here
looked concerning on inspection — but that last entry,
`["-",["-","undefined","file"],"filename"]`, is a second real finding:

**`-spec` type annotations get extracted as fake `calls/5` facts.**
`-spec file(file:filename()) -> [tuple()].` (`src/ts_extract.erl` and
several others) produces `calls(undefined, undefined, remote(file,
filename, ArgCount), File, Line)` — `file:filename()` there is a
**type** reference, not a call, but tree-sitter-erlang's grammar shapes
a `-spec`'s contents identically to a real function call, and
`ts_extract_erlang.erl`'s `(call expr: (remote) @call)` query doesn't
distinguish the two. `Caller = undefined` (and now `CallerArity =
undefined` too) in every case is the tell — a `-spec` lives outside any
`function_clause`, so the caller-attribution walk-up finds nothing. Low
severity (nothing crashes), but real noise in `calls/5` for any
`-spec`-heavy Erlang code, which is all of it here — a "exclude
`-spec`/`-type` attribute bodies" fix belongs in
`ts_extract_erlang.erl`'s query, not in this rule file.

### "No local callers" — mostly false positives, and why

```sh
$ symbolic query -db facts.dets -rules lint-rules.pl 'all_no_local_callers(Triples), length(Triples, N)'
N = 59
```

59 functions matched (OTP callbacks like `handle_call`/`handle_cast`/
`init`/`terminate`, every extractor's `file/1`, every `symbolic_ts`/
`symbolic_fact_store` entry point, and a handful more — up from 27
before this session's `symbolic_fact_store.erl`/`symbolic_term_json.erl`/
`ts_extract_text.erl` additions, each of which adds more
remotely-called-only entry points). Almost none of this is actually
dead code: OTP callbacks are invoked by the framework, never by name
from application code, and every extractor's `file/1` (same for
`symbolic_fact_store:read/1`/`write/2`) is called **remotely**
(`ts_extract_erlang:file/1` from `ts_extract.erl`'s dispatcher, say),
not locally — `no_local_callers/2` only checks `local(...)` call sites,
so it's structurally blind to cross-module wiring. A rule that actually
found dead code would need to check both `local` and `remote` call
shapes before concluding "nothing calls this."

## References

- [`agent-examples.md`](agent-examples.md) — the narrative version of
  this same idea (an agent asking one question at a time, with
  narrower helper rules like `callers/2`/`callees/2`).
- [`prolog-store.md`](prolog-store.md) §7 — how facts move now (DETS +
  JSON, no Prolog text) and why `-rules` still uses plain text.
- [`prolog-schema.md`](prolog-schema.md) — what every fact predicate's
  arguments mean, including which are binaries vs. atoms.
- [`../readme.md`](../readme.md) — the `-db`/`-rules` pattern
  (`contains/2`, `stale_doc_example/3`) these rules extend.
