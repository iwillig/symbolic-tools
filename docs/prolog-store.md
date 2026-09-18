# Design: Storing the Prolog Database

This document covers where the Prolog **facts** produced by the extraction
layer ([`tree-sitter-erlang.md`](tree-sitter-erlang.md)) live — both at
**runtime** (how [erlog](https://github.com/rvirding/erlog) sees them while
proving) and on **disk** (how they survive between runs). It is the data-store
half of the design in [`erlang-mcp-design.md`](erlang-mcp-design.md), consumed
by the `symbolic parse` / `symbolic query` subcommands
([`cli-erlang.md`](cli-erlang.md)). A design/research document only — no store
is implemented here.

**Recommendation up front:** keep the erlog state in a `gen_server`; for large
fact sets move the facts into a **named ETS table** and query through erlog's
built-in **`erlog_ets`** bridge (no new dependency); treat the on-disk artifact
as a **derived build cache** — a consultable `.pl` and/or a binary snapshot keyed
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
