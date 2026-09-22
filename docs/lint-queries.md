# Lint-style Prolog Queries

A small library of reusable Prolog rules for exploring a fact base like
a linter would — duplication, fan-in/fan-out, dead-code candidates,
undocumented pieces, risky calls — instead of asking "what does this
one function do" the way `docs/agent-examples.md` does.

**The canonical, runnable copy of this library is
[`../.symbolic/rules.pl`](../.symbolic/rules.pl)**, and `symbolic query`
consults it automatically (see [`cli-erlang.md`](cli-erlang.md) §2) — no
`-rules` flag needed for anything below:

```sh
$ symbolic parse src -db facts.dets
$ symbolic query -db facts.dets 'all_duplicate_names(Pairs)'
```

The listing further down is this library explained, not a copy you have
to install; `symbolic_query_tests:default_rules_library_over_fixture_test`
runs every predicate here against a known fixture, so a rule can't go
missing from the file while still being advertised by this doc — the exact
drift (`top_fan_out/2`, `all_risky_calls/1` and friends, referenced below
but absent from the library) that test was written to catch.

Written and verified against this project's own `src/` directory —
every count and example below is real, captured output from actually
running the queries, not hand-written. They were all captured against
*one* particular tree, though, and every one of them moves when the
source does (a new exported entry point is another `no_local_callers`
match; a new call site is another risky call and another module edge), so
treat a number here as a snapshot of when it was written, not a property
of the current checkout. Re-running the command above it is the way to
tell the difference.

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

What [`../.symbolic/rules.pl`](../.symbolic/rules.pl) contains, one
comment per predicate:

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

%% Component-level (C4 L3) dependency edges: which file calls into which
%% named module. remote(...) only — local(...) is same-file, intra-
%% component detail (C4 Code/L4), not a component boundary. See the
%% "Module dependency graph" section below for the internal-vs-noise
%% filtering this needs to actually diagram, and a real blind spot.
module_dependency(CallerFile, CalleeModule) :-
    calls(_, _, remote(CalleeModule, _, _), CallerFile, _).

all_module_dependencies(Edges) :-
    findall(CallerFile-CalleeModule, module_dependency(CallerFile, CalleeModule), Raw),
    sort(Raw, Edges).

%% More parameters than a human can comfortably track at a call site.
%% Arity already *is* the parameter count, so this needs no new fact —
%% just a threshold, matching ESLint's `max-params` default (4).
too_many_params(Fun, Arity, File, Line) :-
    defines(Fun, Arity, _Params, File, Line),
    Arity > 4.

all_too_many_params(Triples) :-
    findall(Fun-Arity-File, too_many_params(Fun, Arity, File, _Line), Raw),
    sort(Raw, Triples).

%% A rough complexity signal on top of fan_out/3 — not real branch
%% counting (no control-flow facts exist to count), just "this function
%% orchestrates a lot of distinct calls," the shape of concern ESLint's
%% `complexity` rule flags via cyclomatic branch count instead.
too_complex(Fun, File, Count) :-
    fan_out(Fun, File, Count),
    Count > 10.

all_too_complex(Ranked) :-
    findall(Count-Fun-File, too_complex(Fun, File, Count), Raw),
    sort(Raw, Sorted),
    reverse(Sorted, Ranked).

%% Two functions each reachable from the other's call chain — the
%% function-level analogue of eslint-plugin-import's `no-cycle`, built on
%% reaches/2. `A @< B` keeps each pair to one entry.
mutual_recursion(A, B) :-
    reaches(A, B),
    reaches(B, A),
    A @< B.

all_mutual_recursion(Pairs) :-
    findall(A-B, mutual_recursion(A, B), Raw),
    sort(Raw, Pairs).

%% Never called at all — local OR remote — closing the exact blind spot
%% no_local_callers/3 has (below): that one only checks local(...) call
%% sites, so a remotely-called entry point shows up there as a false
%% positive. Still blind to member(...) calls and callers outside this
%% same parse — a stronger dead-code signal, not a perfect one.
truly_uncalled(Fun, Arity, File) :-
    defines(Fun, Arity, _, File, _),
    \+ calls(_, _, local(Fun, Arity), _, _),
    \+ calls(_, _, remote(_, Fun, Arity), _, _).

all_truly_uncalled(Triples) :-
    findall(Fun-Arity-File, truly_uncalled(Fun, Arity, File), Raw),
    sort(Raw, Triples).

%% A method call worth flagging outright, the shape ESLint's `no-console`
%% checks — edit banned_target/2 for this project's own conventions.
banned_target(console, log).
banned_target(console, debug).
banned_target(console, warn).

banned_call(Caller, Method, File, Line) :-
    calls(Caller, _CallerArity, member(Object, Method, _ArgCount), File, Line),
    banned_target(Object, Method).

all_banned_calls(Triples) :-
    findall(Caller-Method-File, banned_call(Caller, Method, File, _Line), Raw),
    sort(Raw, Triples).

%% Too many functions crammed into one file — max-lines-per-file's shape,
%% approximated by function count since line spans aren't tracked.
file_define_count(File, Count) :-
    findall(Fun, defines(Fun, _Arity, _, File, _), Funs),
    length(Funs, Count).

god_file(File, Count) :-
    file_define_count(File, Count),
    Count > 20.

all_god_files(Ranked) :-
    findall(Count-File, god_file(File, Count), Raw),
    sort(Raw, Sorted),
    reverse(Sorted, Ranked).
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
$ symbolic query -db facts.dets 'all_duplicate_names(Triples)'
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
$ symbolic query -db facts.dets 'top_fan_out(5, X)'
X = [["-",["-",14,"file"],"src/ts_extract_toml.erl"],["-",["-",13,"file"],"src/ts_extract_markdown.erl"],["-",["-",12,"walk_pair"],"src/ts_extract_toml.erl"],["-",["-",12,"text"],"src/ts_extract_typescript.erl"],["-",["-",12,"text"],"src/ts_extract_erlang.erl"]]

$ symbolic query -db facts.dets 'top_fan_in(5, X)'
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
$ symbolic query -db facts.dets 'findall(F-A-Fl, self_recursive(F, A, Fl), Xs)'
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
$ symbolic query -db facts.dets 'all_risky_calls(Triples)'
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
$ symbolic query -db facts.dets 'all_no_local_callers(Triples), length(Triples, N)'
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

### Module dependency graph — a C4 "Component" (L3) view

The C4 model's four levels — Context, Container, **Component**, Code —
zoom in one step at a time; a Component diagram shows the pieces inside
one container (here, this one Erlang release) and which ones depend on
which, without the call-by-call detail a Code-level diagram would need.
That maps directly onto this fact base: a `remote(Module, _, _)` call
is by definition a cross-module edge, and `calls/5`'s own `File`
argument is already the calling component — no join needed. `local(...)`
calls are deliberately excluded: those are same-file, intra-component
detail (C4 Code/L4), not a component boundary.

```sh
$ symbolic query -db facts.dets 'all_module_dependencies(Edges), length(Edges, N)'
N = 108
Edges = [["-","src/prolog_session.erl","erlang"], ...]
```

Every edge in `Edges` is `File-Module`, printed the JSON way `["-",
File, Module]` (`prolog-store.md` §7). Two kinds of filtering turn this
raw edge list into an actual diagram, and erlog can't do either one
itself (no `atom_concat`/`sub_atom` to classify an atom by its text —
`docs/erlang-mcp-design.md` §6) — both belong in whatever consumes the
result, not the query:

1. **Drop OTP/stdlib noise.** Most edges are calls into `lists`, `maps`,
   `io`, `erlang`, `gen_server`, `filename`, and the like — real, but
   not "components" in any useful sense for this diagram.
2. **Split what's left into two groups**: `Module` values that are
   themselves one of this project's own source files (`symbolic_*`,
   `prolog_session*`, `ts_extract*`) are internal components; the
   handful of named library dependencies left over (`jsx`, `erlog`,
   `erlmcp_stdio`, `argparse`) are external boxes worth keeping, not
   noise.

The internal-to-internal edges, filtered by hand from a real run:

```
symbolic_cli -> symbolic_parse, symbolic_query, symbolic_serve
symbolic_codebase -> symbolic_parse
symbolic_parse -> symbolic_fact_store, symbolic_term_json
symbolic_query -> symbolic_fact_store, symbolic_term_json, prolog_session
symbolic_serve -> symbolic_codebase, symbolic_term_json
ts_extract -> ts_extract_{bash,erlang,json,markdown,toml,typescript}
ts_extract_{bash,erlang,json,markdown,toml,typescript} -> symbolic_ts
prolog_session_registry -> prolog_session, prolog_session_sup
```

**A real blind spot, not a bug in the rule**: `ts_extract_markdown.erl`
actually calls into `ts_extract_erlang`/`typescript`/`bash` too (to
re-extract a fenced code block — see `docs/tree-sitter-markdown.md`
§4), but that edge is missing above. `extractor_for_lang/1` returns
`fun ts_extract_erlang:text/2` — a **fun reference** — which the
caller then invokes through a variable (`ExtractorFun(Path, Snippet)`).
Tree-sitter's grammar shapes `fun Mod:Fun/Arity` and a later call
through the bound variable completely differently from a direct
`Mod:Fun(Args)` call site, so `ts_extract_erlang.erl`'s `(call expr:
(remote) @call)` query — same as every other extractor's — never
matches either half of it. Static analysis over source text has no way
to see through that dispatch; add the edge back by hand if you're
diagramming this project specifically, and don't trust
`all_module_dependencies/1` alone for a codebase that leans on this
pattern more heavily.

### ESLint-style structural checks

Six more rules, added on top of the library above to cover the shapes of
question an ESLint config typically encodes — everything here is still
derived from `defines/5`/`calls/5` alone, no new fact type. Real output
below, from the same `symbolic parse src -db facts.dets` run as above.

```sh
$ symbolic query -db facts.dets 'all_too_many_params(X)'
X = []

$ symbolic query -db facts.dets 'all_too_complex(X)'
X = [["-",["-",14,"file"],"src/ts_extract_toml.erl"],["-",["-",13,"file"],"src/ts_extract_markdown.erl"],["-",["-",12,"walk_pair"],"src/ts_extract_toml.erl"],["-",["-",12,"text"],"src/ts_extract_typescript.erl"],["-",["-",12,"text"],"src/ts_extract_erlang.erl"],["-",["-",12,"file"],"src/ts_extract_json.erl"],["-",["-",11,"text"],"src/ts_extract_bash.erl"]]

$ symbolic query -db facts.dets 'all_god_files(X)'
X = [["-",37,"src/symbolic_codebase.erl"],["-",32,"src/symbolic_serve.erl"],["-",30,"src/ts_extract_markdown.erl"],["-",25,"src/ts_extract_typescript.erl"],["-",25,"src/symbolic_ts.erl"],["-",22,"src/ts_extract_erlang.erl"]]
```

`too_many_params/4` finds nothing here — no function in this project
takes more than 4 arguments — which is itself a useful "clean" result,
not an empty/broken query. `too_complex/3` and `god_file/2` line up with
`top_fan_out/2` above: the same per-language `file/1`/`text/2` orchestrator
functions and the same handful of files (`symbolic_codebase.erl`,
`symbolic_serve.erl`) that already showed up as high fan-out/fan-in
elsewhere in this doc.

**`god_file/2` is worth a specific warning, because an earlier version of
`file_define_count/2` had a real bug here**: `File` isn't in the inner
`findall/3`'s own template, so leaving it unbound before that `findall`
let it vary freely across *every* `defines/5` fact in the whole codebase
instead of grouping by one file — `all_god_files/1` would have silently
reported one giant count against an unbound `File` rather than one count
per real file. Fixed by generating the distinct file list first
(`findall`+`sort`) and backtracking over it with `member/2` before the
per-file `findall` runs — the same "bind the grouping key via a sibling
conjunct before the findall that uses it" shape `fan_out/3` above already
gets right by starting from `defines(Fun, _, _, File, _)`. The regression
test (`test/symbolic_query_tests.erl`) deliberately queries with `File`
left unbound, the exact shape that exposed the bug — a test that only
ever passed a bound `File` in would not have caught it.

```sh
$ symbolic query -db facts.dets 'all_mutual_recursion(X)'
query failed: timeout
```

**A real, verified limitation, not a bug**: `mutual_recursion/2` calls
`reaches/2` — which is already guarded against infinite loops on a cyclic
graph (a `Visited` list) — but with *both* arguments unbound, it still has
to try every `calls/5` fact as a candidate pair and run a full reachability
search from each one, and erlog has no tabling/memoization
(`docs/erlang-mcp-design.md` §5) to avoid repeating that work. On this
project's own `src/` (~700 `calls/5` facts at the time this was captured)
that's enough to hit the query timeout. Bind at least one side —
`mutual_recursion(some_fun, B)` — to check one function at a time instead
of asking "is there any cycle anywhere" in one shot.

```sh
$ symbolic query -db facts.dets 'all_truly_uncalled(X), length(X, N)'
N = 30
```

Compare against `all_no_local_callers/1`'s 59 matches on the same tree
(above): `truly_uncalled/3` additionally excludes every function that's
only ever called *remotely* — OTP callbacks aside, this is the closer
approximation of "actually unreferenced," at the cost of still being
blind to `member(...)` (method/dynamic-dispatch) calls, same as every
other rule here that keys on `local`/`remote`.

`banned_call/4` isn't demonstrated against this project's own `src/` —
it's Erlang, and `banned_target/2`'s default table
(`console.log`/`debug`/`warn`) is a JS/TS convention with no equivalent
call shape here. See the fixture-based test
(`banned_call_flags_a_console_log_call_test` in
`test/symbolic_query_tests.erl`) for a worked TS-shaped example instead,
and edit `banned_target/2` for whatever this project's own conventions
should ban.

### Real complexity, on top of `branch/5`

`too_complex/3` above is fan-out — distinct callees — not actual
branching, and says so in its own doc comment. `branch/5` (one fact per
`if`/`for`/`while`/`switch_case`/`ternary`/`catch`/`and`/`or` in
TypeScript, `cr_clause`/`if_clause`/`receive_after` in Erlang,
`if`/`elif`/`for`/`while`/`case_item` in Bash — see
`docs/prolog-schema.md` for the exact `Kind` values per language and how
they were confirmed against the real grammars) makes McCabe's actual
"decision points + 1" computable. Erlang's multi-clause functions
already give the "+1" for free: a 3-clause function produces three
`defines/5` facts (one per clause), so `real_complexity/4` counts
`defines/5` rows per function as the "clause" term — 1 for TypeScript/
Bash, the real clause count for Erlang.

```sh
$ symbolic query -db facts.dets 'real_complexity(handle_call, 3, File, Count)'
Count = 16
File = "src/prolog_session.erl"

$ symbolic query -db facts.dets 'all_too_complex_real(X)'
X = [["-",["-",["-",16,"handle_call"],3],"src/symbolic_codebase.erl"],["-",["-",["-",16,"handle_call"],3],"src/prolog_session.erl"]]
```

Both `handle_call/3` gen_server callbacks — a multi-clause dispatch
function pattern-matching on the message shape — are exactly the kind of
function real branch-counting should flag that fan-out-based
`too_complex/3` has no way to see (a `handle_call/3` with many clauses
doesn't necessarily call many *distinct* things).

**Two things worth knowing before trusting a number here to the last
integer, both found by actually running this against a real codebase
rather than trusting hand-built test fixtures alone**:

1. **A real bug in an earlier version of `real_complexity/4`**, the same
   class `god_file/2` above already had: with `Fun`/`Arity`/`File` left
   unbound going into the rule's own inner `findall`s (exactly what
   `all_too_complex_real/1` does), nothing grounded them first, so they
   varied freely across *every* `defines/5` fact in the database —
   `all_too_complex_real(X)` against this project's own `src/` returned
   one bogus `Count = 486` (the total number of `defines/5` facts in the
   whole codebase) against an unbound `Fun`/`Arity`/`File`, not one real
   count per function. Fixed the same way `file_define_count/2` was:
   generate the distinct `(Fun, Arity, File)` groups first
   (`findall`+`sort`), then `member/2` over them before the per-function
   `findall`s run.
2. **A predicate with zero clauses anywhere raises `existence_error`
   in erlog, not a clean empty result** — confirmed this already
   affects `stale_doc_example/4` above too, whenever `example_defines/5`
   has zero clauses (an Erlang-only tree with no Markdown parsed
   alongside it) — and erlog has neither `catch/3` nor `dynamic/1` to
   recover from it query-side. `.symbolic/rules.pl` works around it for
   `branch/5` specifically with one sentinel clause,
   `branch(none, 0, none, none, 0) :- fail.` — always present, never
   satisfiable by a real query, whose only job is to make `branch/5`
   "exist" so a source tree with zero decision points anywhere still
   gets a clean `Count` (1, or the real clause count) instead of an
   error. `stale_doc_example/4`'s own version of this is still unfixed —
   a separate predicate, out of scope for this change.

### Naming convention: id-length

ESLint's `id-length` — a name short enough to hurt readability (`f`,
`x1`), not a deliberate, idiomatic abbreviation. `atom_length/2` works
directly on the `Fun` atoms `defines/5` already gives us — no new fact
needed, unlike `branch/5` above. `allow_short_name/1` is the escape
hatch (`ok`/`id` are fine in most codebases) — edit it for this
project's own conventions, same pattern as `banned_target/2`'s table.

```sh
$ symbolic query -db facts.dets 'all_short_names(X)'
X = []
```

Clean on this project's own `src/` — Erlang convention doesn't favor
single/double-letter top-level function names the way some JS/TS
codebases do (`f`, `id` as a throwaway helper). A quick TS-shaped
fixture (`f`, `id`, `ok`, `process`, one function each) shows the
positive case instead:

```sh
$ symbolic query -db facts.dets 'all_short_names(X)'
X = [["-",["-","f",1],"sample.ts"]]
```

— `f` flagged, `process` not (5+ characters), `id`/`ok` excluded by
`allow_short_name/1` even though both are under the 3-character
threshold too.

### Expression content, on top of `expr/6`

Every rule above stops at "a decision point exists" (`branch/5`) — none
of them can see what a condition actually *compares*. `expr/6` +
`literal/7` + `expr_operand/3` + `expr_ref/6` (Erlang and TypeScript
only for now — see `docs/prolog-schema.md`) make that visible, and
`self_compare/4`/`yoda_condition/5` are two small, real proofs of it:

```sh
$ symbolic query -db facts.dets 'all_self_compares(X)'
X = [["-",["-","checkAccess",2],"sample.ts"]]

$ symbolic query -db facts.dets 'all_yoda_conditions(X)'
X = [["-",["-","checkAccess",2],"sample.ts"]]
```

Both against

```ts
function checkAccess(userId: number, allowedId: number) {
  if (userId == userId) {       // self_compare: same name both sides
    return true;
  }
  if (0 === userId) {           // yoda_condition: literal on the left
    return false;
  }
  return userId == allowedId;   // neither — different names, normal order
}
```

`self_compare/4` is scoped to the simple case (both operands a bare
reference to the *same name*) — not full structural equality of two
arbitrary sub-expressions (`f(x) == f(x)`), which would need recursive
term comparison across the whole operand tree.

**A real bug found by actually running this, not a hypothetical, and
the reason this fact family needs a byte-*span* identity rather than
just a start byte**: a binary expression and its own leftmost operand
routinely start at the exact same byte — `x == x`, the expression and
its left `x`, both start where `x` starts. `{File, StartByte}` alone
collided (the left operand's `Id` came back identical to its parent
expression's `Id`) until `EndByte` was added: no two distinct nodes in
one parse occupy the identical byte range, so the span can't collide
the same way.

## References

- [`agent-examples.md`](agent-examples.md) — the narrative version of
  this same idea (an agent asking one question at a time, with
  narrower helper rules like `callers/2`/`callees/2`).
- [`prolog-store.md`](prolog-store.md) §7 — how facts move now (DETS +
  JSON, no Prolog text) and why `-rules` still uses plain text.
- [`prolog-schema.md`](prolog-schema.md) — what every fact predicate's
  arguments mean, including which are binaries vs. atoms.
- [`../.symbolic/rules.pl`](../.symbolic/rules.pl) — the canonical,
  auto-consulted copy of the library documented above.
- [`../readme.md`](../readme.md) — the `-db`/`-rules` pattern these rules
  extend, and how the default library gets found.
- [C4 model](https://c4model.com/) — the Context/Container/Component/Code
  levels `module_dependency/2` produces the Component (L3) view for.
- [`tree-sitter-markdown.md`](tree-sitter-markdown.md) §4 — the
  fenced-code-block re-extraction whose `fun Mod:Fun/Arity` dispatch is
  `module_dependency/2`'s blind spot.
- [`erlang-mcp-design.md`](erlang-mcp-design.md) §6 — erlog's missing
  `atom_concat`/`sub_atom`, why the internal-vs-noise filtering can't
  happen inside the query itself.
