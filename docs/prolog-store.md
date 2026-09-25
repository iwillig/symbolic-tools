# Design: Storing the Prolog Database

This document covers where the Prolog **facts** produced by the extraction
layer ([`tree-sitter-erlang.md`](tree-sitter-erlang.md)) live — both at
**runtime** (how [erlog](https://github.com/rvirding/erlog) sees them while
proving) and on **disk** (how they survive between runs). It is the data-store
half of the design in [`erlang-mcp-design.md`](erlang-mcp-design.md), consumed
by the `symbolic parse` / `symbolic query` subcommands
([`cli-erlang.md`](cli-erlang.md)).

**Implemented, not just designed:** §1–§2 below described the plan; it's now
real. `symbolic parse -db <path>` writes facts into a **DETS table**
(`symbolic_fact_store.erl`) — the "erlang style database" this doc's original
recommendation pointed at — and `symbolic query -db <path>` reads them back
and asserts them directly into a fresh erlog session
(`prolog_session:load_facts/2`), entirely as Erlang terms. **No Prolog text is
parsed or printed anywhere on this path.**

That's a deliberate change from the original plan below, which assumed facts
would be cached as a **consultable `.pl` file** and round-tripped through
Prolog text (`erlog_io:writeq1/1` to write, `erlog:consult/2` to read). That
round trip turned out to be genuinely broken, not just unfinished:
`erlog_io:writeq1/1` doesn't escape an atom's embedded single quote at all —
real prose (`it's`, `doesn't`, `codebase's`) is exactly what a `comment/3` or
`doc/4` fact's `Text` argument is full of, since this project dogfoods itself
against its own source. Free-text fields (`comment/3`, `doc/4`'s `Text`;
`heading/4`, `paragraph/3`'s `Text`; `config_value/4`'s `Value`) were also
capped at 200 characters and force-cast into Erlang atoms (255-byte hard
limit), truncating real content. See `ts_extract_text.erl` and
`symbolic_term_json.erl`.

The fix has two independent parts:

1. **Those free-text fields are now Erlang binaries, not atoms**
   (`ts_extract_text:to_text/1`) — unbounded length, no truncation, and no
   pressure on Erlang's atom table from `list_to_atom/1` on arbitrarily long
   extracted prose. Identifier-like fields (function/module names, file
   paths, config key paths) stay atoms, since those genuinely are unified
   against literals a person types in a query.
2. **Facts move between processes as JSON or as raw Erlang terms — never as
   printed-and-reparsed Prolog text.** `symbolic parse`'s stdout is now JSON
   Lines (`symbolic_term_json.erl`, using `jsx`), one JSON array per fact,
   fixing the escaping bug directly (JSON's string escaping has no such
   gap). `symbolic query`'s printed bindings and the MCP server's tool
   results (`symbolic_serve.erl`) use the same JSON encoding. The actual
   fact **database** facts get persisted into (`symbolic_fact_store.erl`,
   DETS) never touches text at all in either direction — see §7.

The rest of this document (§1–§6) is the original research and reasoning that
led here; still accurate as background on *why* DETS and JSON were the right
choices, not SQLite or hand-rolled text.

**Recommendation up front:** keep the erlog state in a `gen_server`; for large
fact sets move the facts into a **named ETS table** and query through erlog's
built-in **`erlog_ets`** bridge (no new dependency); treat the on-disk artifact
as a **derived build cache** — a DETS table and/or a binary snapshot keyed
by a **content hash** of the source. Reach for **SQLite via
[`esqlite`](https://github.com/mmzeeman/esqlite)** only when you outgrow that
model and need durability + incremental updates + SQL.

## 1. What erlog actually gives us

From the erlog source (`src/erlog.erl`):

- A state is `#erlog{vs=[], est}`; `est` holds a **`db`** field — an
  **abstract, pluggable store** `#db{mod = DbMod, ref = Ref}`. The default
  backend is **`erlog_db_dict`** (in-memory). `new/2` takes a custom `DbModule`;
  `get_db/1` / `set_db/2,3` read/replace the underlying `ref`.
- **There is no disk persistence.** The database is an in-memory term.
- **Facts are just Erlang terms.** The tuple `{foo,1,2,3}` *is* the fact
  `foo(1,2,3)`. A "Prolog database" is therefore a list of tuples — trivially
  serializable and storable anywhere.
- **Built-in ETS bridge.** `erlog:load(erlog_ets, State)` lets a goal unify
  against the rows of an ETS table via `ets_match(TableId, Value)`. This is the
  native answer to "store a *big* fact set."
- `erlog:consult(File, State)` loads clauses from a `.pl` file; `reconsult/2`
  reloads.

The design doc's "compute closure in Erlang, not Prolog"
([`erlang-mcp-design.md`](erlang-mcp-design.md) §5) already keeps the *Prolog*
database bounded — it is a queryable fact sheet over a pre-computed graph, not a
massive data lake. That keeps most cases in the simplest row below.

## 2. Runtime: how erlog sees the facts

| Option | Mechanism | Use when |
|---|---|---|
| **Default `erlog_db_dict`** | consult facts into the in-memory dict; hold the state in a `gen_server` (`prolog_session`) | ✅ small–medium sets (up to ~tens of thousands). Simplest. |
| **ETS bridge (`erlog_ets`)** | store facts in a **named ETS table**, key by `{Pred, FirstArg}`, query via `ets_match` | large sets you want Prolog to reason over without the dict getting slow. **No new deps.** |
| **Custom DB module** | `new/2` with your own `erlog_db_*` implementing the store interface (see `erlog_db_dict` as the reference impl) | only if neither of the above suffices. More work. |

For the ETS route, the fact set lives off the erlog dict and on-heap in a named
table that any process can reach; key rows by `{Predicate, FirstArg}` so
Erlang-side lookups are O(1) (mirrors how real Prolog indexes clauses), and let
Prolog reach them through `ets_match/2`.

## 3. Persistence: the facts are a *derived build artifact*

Because facts are deterministically derived from source, **cache** them rather
than maintain a live database:

| Option | What | Tradeoff |
|---|---|---|
| **Consultable `.pl` file** | `symbolic parse` writes facts as Prolog text; `erlog:consult/2` loads | ✅ human-readable, diff-able, versionable, debug-friendly. Natural primary artifact (`project-facts.pl`). |
| **`term_to_binary` snapshot** | serialize the fact list / `get_db` `ref`; `binary_to_term` to restore | fastest reload, compact, no deps; opaque, version-fragile. |
| **Dets** (OTP, on-disk B-tree) | facts keyed by `{Pred, FirstArg}` | durability + random access, still in the Erlang world, no external process. |
| **Mnesia** (OTP) | tables, transactions, `qlc` | overkill unless you need distribution/transactions. |
| **SQLite via [`esqlite`](https://github.com/mmzeeman/esqlite)** | facts as rows; SQL; disk + indexes + ACID | the "real database" option — see §4. |

**Cache by content hash.** Key the artifact on a hash of the input file set so a
re-run with unchanged sources skips re-parsing entirely (the same build-cache
idea as chiasmus's `save_snapshot`):

```erlang
Hash  = lib:hash_fileset(Files),
Case file:read_file("cache/" ++ Hash ++ ".pl") of
  {ok, _} -> ok;                                   % hit: consult directly
  {error, enoent} ->
    Facts = extract:from_files(Files),             % tree-sitter + Erlang closure
    file:write_file("cache/" ++ Hash ++ ".pl", prolog:render(Facts))
end.
```

## 4. SQLite (`esqlite`) — verified, and when it's worth it

`esqlite` (Hex **0.9.0**, Sept 2025, ~35k downloads/week, Apache-2.0) is a
maintained NIF with **embedded SQLite 3.45.2** (or system SQLite via
`ESQLITE_USE_SYSTEM`), **dirty schedulers** (won't block normal schedulers), and
FTS5 / JSON / RTREE enabled. Usage shape:

```erlang
{ok, Db} = esqlite:open("facts.sqlite"),
esqlite:exec(Db,
  "CREATE TABLE IF NOT EXISTS call (caller TEXT, callee TEXT, file TEXT, line INT)"),
%% prepared insert per fact (or bulk); read back with prepare/step/finalize
```

Reach for it **only** when you need one or more of:

- **Incremental updates** — re-parse only changed files and merge, instead of a
  full rebuild.
- **SQL directly** — some questions are easier as SQL than Prolog.
- **Durability + indexing across restarts**, shared across many processes.

Caveats (from its README):

- A bug in the NIF/SQLite **can crash the VM** — the authors recommend running
  it on a **separate node** if that risk is unacceptable.
- `SQLITE_DQS=0` means **string literals must use single quotes**.
- It is a **different paradigm**: store facts as rows and load the relevant
  slice into ETS/erlog to reason — you do not run Prolog inside SQLite.

## 5. Recommended flow for `symbolic`

1. **Runtime:** hold the erlog state in `prolog_session`
   ([`erlang-mcp-design.md`](erlang-mcp-design.md)). Consult facts into the
   default dict. If a codebase's fact set grows large, move facts into a **named
   ETS table** and use `erlog_ets` — still zero external deps.
2. **Persistence:** `symbolic parse` emits a **`.pl`** (primary, versionable)
   **and/or a binary snapshot**, cached by **content hash** (§3); `symbolic
   query` consults it into a fresh state.
3. **SQLite (`esqlite`) later** — only if you outgrow the cache-and-rebuild
   model and need incremental, SQL-backed storage.

## 6. Decision heuristic

```
in-memory erlog dict
  └─ (fact set too large to consult) ──> named ETS table + erlog_ets
        └─ (need durability / incremental / SQL) ──> esqlite (SQLite)
```

Don't start at SQLite.

## 7. What's actually implemented

The row this project landed on, and why it's a slightly different shape
than "consult a `.pl`" (§3) even though DETS was always the recommended
on-disk option:

- **`symbolic_fact_store.erl`** — a thin wrapper around a **DETS `bag`
  table**. `write/2` replaces the whole table's contents (parse output is
  a deterministic function of the source files, so each run fully
  regenerates it, not an incremental merge); `read/1` folds the table back
  into a plain fact list. Facts are stored **as-is** — a fact tuple's own
  first element (`defines`, `calls`, `comment`, ...) doubles as its DETS
  key, so `dets:lookup(Table, defines)` already returns every `defines/5`
  fact with no extra indexing code — generic over the fact's own arity,
  so the `defines`/`doc` schema growing an `Arity`/`Params` field (see
  `docs/prolog-schema.md`) needed no change here.
- **`prolog_session:load_facts/2`** — asserts a fact list directly into an
  erlog session via `erlog:prove({asserta, Fact}, State)`, entirely in
  Erlang-term space. `asserta`, not `assertz`: order doesn't matter for
  pure facts (it only affects backtracking order), and
  `erlog_db_dict:assertz_clause/4` appends via `Cs ++ [_]` — O(N) per call,
  so `assertz`-ing thousands of facts sharing one predicate would be
  O(N²); `asserta` prepends in O(1) (confirmed by reading
  `erlog_int.erl`/`erlog_db_dict.erl` directly).
- **`symbolic_term_json.erl`** — the replacement for `erlog_io:writeq1/1`
  everywhere a term is printed to a human or another process: `symbolic
  parse`'s stdout (JSON Lines, one fact per line — still greppable/
  pipeable the same way one-fact-per-line Prolog text was), `symbolic
  query`'s printed bindings, and the MCP server's tool results
  (`symbolic_serve.erl`). Uses `jsx` (already a transitive dependency via
  `erlmcp` → `jesse`, now declared directly). A compound term becomes a
  JSON array (`["local","bar"]`, `["defines","foo","file.erl",3]`); an
  atom becomes a JSON string; a binary (free text — see
  `ts_extract_text.erl`) becomes a JSON string directly, with no length
  cap and no quoting ambiguity.
- **Rule text hasn't gone away** — `symbolic query -db <facts.dets>
  -rules <rules.pl>` still consults a hand-written Prolog file (real
  syntax someone typed, e.g. [`lint-queries.md`](lint-queries.md)'s rule
  library, kept in this project's `.symbolic/rules.pl`) via the ordinary
  text-based `erlog:consult/2`/`prolog_session:consult/2`. That path was
  never the buggy one — it's arbitrary *extracted* text (comment/doc
  bodies full of contractions and possessives) that broke `writeq1`'s
  naive atom-quoting, not short hand-written rule clauses. Omitting
  `-rules` doesn't skip consulting either: `symbolic_query:resolve_rules/3`
  finds the project's own `.symbolic/rules.pl` by walking up from the
  database and then the cwd, so shared rules are a committed file rather
  than a flag every caller has to remember. `-rules <file>` replaces that
  default (it doesn't layer on top of it), and `-no-rules` turns the
  lookup off.

One real, non-obvious pitfall hit while building this, worth recording
here rather than only in a commit message: `io:format("~s", [Binary])`
treats a binary argument as a flat list of **Latin-1** codepoints, not as
already-encoded UTF-8 bytes — for any byte above 127 (part of a
multi-byte UTF-8 sequence, like this project's own em dashes) it
re-encodes each byte as its own separate character, producing mojibake.
Every place this project prints a `jsx:encode/1` result uses `~ts`
(Unicode-aware) instead, or `io:put_chars/1`, which never reinterprets
binary contents at all.

## 8. Multiple scan roots, one fact set: `.symbolic/config.json`

Everything in §7 above still describes ONE scan: `symbolic parse <dir>`
walks exactly one directory tree, and `write/2` replaces the whole DETS
table with that one walk's output. That was a real limitation for any
project where the interesting facts don't all live under one root —
`src/` and `test/` are two different directories in this project itself,
and a config file (`package.json`, `Cargo.toml`) worth querying usually
sits at the project root, alongside `src/`, not inside it.

`.symbolic/config.json` closes that gap without touching the "one write
replaces the table" model at all — it just changes what goes into the
list of facts *before* that one write happens:

```json
{ "paths": ["src", "test", "package.json"] }
```

- **Discovery** is the identical walk-up algorithm `.symbolic/rules.pl`
  already uses (`symbolic_query:discover_up/2` — the two now share one
  implementation; see `symbolic_query:discover_rules_from_dir/1`'s own
  doc comment), so `.symbolic/config.json` is found from any
  subdirectory the same way `.git` is.
- **`symbolic_config:read/1`** decodes the JSON (via `jsx`, already a
  dependency — see §7's `symbolic_term_json.erl` entry) and resolves
  every listed path against the config file's own directory (its
  `.symbolic/` parent, i.e. the project root) — `filename:join/2`
  leaves an already-absolute entry untouched, so an absolute path in
  `paths` works too.
- **`symbolic_parse:scan_paths/1`** is `scan/1` generalized over a LIST
  of paths instead of one directory: each entry is either walked (a
  directory — gitignore rules loaded fresh per root, since
  `symbolic_gitignore:load/1` only ever reads one root's own
  `.gitignore`) or extracted directly (a single file — no
  gitignore/extension pruning the way a directory walk gets, since an
  explicitly named file always wins, the same way an explicit `-rules`
  always wins over discovery). Every path's facts are combined with one
  shared `lists:usort/1` at the end — still exactly one write, just fed
  by N scans instead of one.
- **Every one of those N scans runs concurrently**, one Erlang process
  per path (`symbolic_parse:parallel_map/2`) — and each directory's own
  files are, in turn, extracted one process per file
  (`parallel_extract/1`), so `scan/1` (the plain single-directory case)
  gets the same speedup. Safe because every extractor calls
  `symbolic_ts:parser_new/0` fresh per file — no shared mutable parser
  state across concurrent NIF calls (confirmed against
  `c_src/symbolic_ts_nif.c`: its own globals are read-only atoms/
  resource-type handles set once at NIF load time). A crash in any one
  file's extraction is re-raised in the caller (`error({parse_worker_crashed,
  Reason})`) rather than silently dropped, so parallelizing the common
  case doesn't quietly change what happens on the uncommon one.
- `symbolic parse` with **no directory argument** triggers this path
  (`-config <file>` overrides discovery, the same way `-rules` does);
  the MCP server's `parse` tool does too, when called with no `path` —
  see `docs/cli-erlang.md` §2 and `docs/erlang-mcp-design.md`.
- **The MCP server's discovery has one extra wrinkle a fresh CLI
  invocation doesn't**: it's one long-lived process, so "walk up from
  the current directory" means the SERVER's own cwd, fixed for its
  whole lifetime — there's no per-call `cd`. That's what the MCP
  `parse` tool's `config` parameter is for (`symbolic_codebase:parse/3`):
  an explicit `.symbolic/config.json` path, exactly like `-config`,
  which is what actually lets one running server hold cache entries for
  *several* projects at once via config mode — two `parse` calls with
  two different `config` values land in two different cache entries
  (each keyed by its own project root), the same way two different
  `path` directories already do for single-directory mode.

Two things this does NOT do, on purpose: it doesn't merge with a
*previous* `write/2` call (§7's replace-not-append model is unchanged —
`.symbolic/config.json` just builds a bigger fact list up front, in
memory, before the one write) and it doesn't share a `.gitignore`
context across roots (a file ignored under `src/`'s own `.gitignore`
stays ignored; there's no *cross*-root ignore rule).

## References

- [`erlang-mcp-design.md`](erlang-mcp-design.md) — the in-process BEAM design
  and the `prolog_session` this plugs into.
- [`tree-sitter-erlang.md`](tree-sitter-erlang.md) — the extraction that
  produces the facts.
- [`cli-erlang.md`](cli-erlang.md) — the `symbolic parse` / `symbolic query`
  front end.
- [`rvirding/erlog`](https://github.com/rvirding/erlog) — engine; see
  `src/erlog.erl` for the `#db{mod, ref}` store, `erlog_ets`, and `consult/2`.
- [`mmzeeman/esqlite`](https://github.com/mmzeeman/esqlite) — SQLite3 NIF.
- [`ets`](https://www.erlang.org/doc/man/ets.html),
  [`dets`](https://www.erlang.org/doc/man/dets.html),
  [`mnesia`](https://www.erlang.org/doc/apps/mnesia/mnesia.html) — OTP stores.
- `symbolic_fact_store.erl`, `symbolic_term_json.erl`,
  `ts_extract_text.erl` — the modules §7 describes.
- [`prolog-schema.md`](prolog-schema.md) — the fact predicates themselves
  (what each argument means), including which are now binaries rather
  than atoms.
- [`lint-queries.md`](lint-queries.md) — the rule library
  `.symbolic/rules.pl` implements (and which `symbolic query` consults
  automatically when no `-rules` is given).
