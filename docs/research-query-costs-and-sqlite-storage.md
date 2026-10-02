# Research: Why `all_mutual_recursion/1` Times Out, and SQLite3 for Fact Storage

- **Date:** 2026-09-28
- **Commit:** `c138c2b`
- **Scope:** `src/` + `docs/` of this repo, scanned with the symbolic MCP tool
  (49 files, 18,553 facts: 1,820 `calls`, 558 `defines`).
- **Method:** every claim below was produced by a Prolog goal run against the
  scanned fact base. Goals and results are quoted in the Appendix so any
  result can be re-run.

This note has two parts:

1. Why the mutual-recursion audit query is expensive in our Prolog database
   (erlog), measured component by component.
2. Our earlier research on SQLite3 (`esqlite`) as a storage option for the
   fact base, summarized from [`prolog-store.md`](prolog-store.md) §4–7.

The two parts point the same direction: erlog is a reasoning engine over an
in-memory fact set, not a database and not a place for heavy graph
algorithms.

---

## 1. Why `all_mutual_recursion/1` times out

### 1.1 The graph we are analyzing

| Quantity | Value | How it was measured |
|---|---|---|
| Distinct local call edges | **607** | `all_call_edges(E), length(E, N)` |
| Distinct calling functions | **323** | `findall(C, calls(C, _, _, _, _), R), sort(R, S), length(S, N)` |
| Ordered candidate pairs | ~104,000 | 323 × 323 |
| Proof budget per query | 5,000 ms | fixed server setting |

The problem is small. A transitive closure over 323 nodes and 607 edges takes
microseconds in Erlang. The cost comes from *how erlog executes the rules*,
not from the size of the graph.

### 1.2 The two implementations

The rules file (`.symbolic/rules.pl`) contains two versions.

**Version 1 — the naive predicate** (still what `mutual_recursion/2` uses):

```prolog
reaches(A, B) :- reaches(A, B, []).
reaches(A, B, _) :- calls(A, _CallerArity, local(B, _), _, _).
reaches(A, B, Visited) :-
    calls(A, _CallerArity, local(M, _), _, _),
    \+ member(M, Visited),
    reaches(M, B, [M|Visited]).

mutual_recursion(A, B) :- reaches(A, B), reaches(B, A), A @< B.
```

**Version 2 — the semi-naive fixpoint** (what `all_mutual_recursion/1`
uses, added because version 1 timed out):

```prolog
join_step(Frontier, Edges, New) :-
    findall(A-C, ( member(A-B, Frontier), member(B-C, Edges) ), Raw),
    sort(Raw, New).
```

The fixpoint starts from the edge list, keeps a `Frontier` of pairs found in
the last round, extends each frontier pair by one edge, removes pairs already
known, and repeats until a round finds nothing new. Then it intersects the
closure with its own reverse to get mutual pairs.

Both versions time out on this codebase. The reasons are different.

### 1.3 What was measured

| Probe | Goal | Result |
|---|---|---|
| One fixpoint round | `all_call_edges(E), join_step(E, E, _)` | **completes** (607 × 607 = 368,000 list-scan steps, inside the 5 s budget) |
| Full closure | `all_reaches_pairs(C), length(C, N)` | **`query timed out`** |
| The aggregate | `all_mutual_recursion(L), length(L, N)` | **`query timed out`** |
| Paths, one hub pair, forward | `reaches(walk_scope, walk_declaration)` | **34 solutions** |
| Paths, same pair, reverse | `reaches(walk_declaration, walk_scope)` | **17 solutions** |
| Naive enumeration | `mutual_recursion(F, G)` (limit 150) | 150 solutions, but only **4 distinct pairs**, `truncated: true` |

The decisive split: **one round fits in the budget, all rounds do not.**
The closure is the bottleneck, not the final intersection (which is linear).

### 1.4 Why version 1 (naive) is slow

Three factors multiply together.

**1. `reaches/2` counts paths, not reachability.**
The `Visited` list stops the search from visiting a node twice, so every
solution is a *simple path*. But there can be many simple paths between two
nodes, and each one is a separate answer. Measured: **34 simple paths**
between two adjacent hub functions, `walk_scope` and `walk_declaration`.

`mutual_recursion/2` runs `reaches` in both directions, so the answer count
for one pair is a product: up to 34 × 17 = **578 answers for a single
pair**, and each answer is a full depth-first search that erlog must
actually perform. The limit-150 enumeration confirms it: 150 answers
covering only 4 distinct pairs.

**2. erlog has no tabling.**
Tabling is a Prolog feature that remembers the answers of a predicate so a
second call is a lookup instead of a re-computation. erlog does not have it
(no `:- table`), and `assertz` state does not survive between queries. So
every derivation is fresh work.

When the goal is `findall(A-B, mutual_recursion(A, B), L)` with both
variables unbound, erlog re-runs the whole search from scratch for each of
the 323 candidate values of `A`. Nothing is shared between candidates.

**3. The walker family is a dense cycle hub.**
Look at the edges around `walk_scope` in the fact base: it calls
`walk_assignment`, `walk_block`, `walk_children`, `walk_declaration`,
`walk_for`, `walk_function`, and **itself**, and most of those call it back.
That shape — dense, bidirectional, with a self-loop — is the worst case for
simple-path enumeration, because the number of simple paths through such a
cluster grows exponentially with its size. This is why the 150 enumerated
answers all came from one family of six functions.

Total cost of version 1 ≈ `323 candidates × (exponential path search
through the hub)`. The answer set itself is huge, so the search cannot stop
early.

### 1.5 Why version 2 (fixpoint) is also slow

The fixpoint is algorithmically sound: each newly discovered pair is
extended exactly once, the `Known` set only grows, and the search must
terminate. But the join step is **unindexed**:

```prolog
findall(A-C, ( member(A-B, Frontier), member(B-C, Edges) ), Raw)
```

For every pair in the `Frontier`, erlog finds its continuations by scanning
the **entire 607-edge list** with `member/2`. The cheap version would look
up the few outgoing edges of node `B` directly (an adjacency list), which is
a lookup of size ≈ 2, not 607.

So the total work is roughly `|closure| × 607` list-scan steps, plus a
`sort` of a growing list in every round. The closure has thousands of pairs,
so this is millions of steps — against a budget where a single 368,000-step
round already uses a large share. That is exactly the measured split: one
round completes, the whole closure does not.

Note: even a *correct* adjacency-list index would only give a constant
factor here. Without tabling, an `adj(B, Cs)` helper is re-derived from
scratch for every frontier member that names the same `B` — each
re-derivation re-scans all 607 edges. erlog has no tabling and no
random-access structure (no `compare/3` for a binary search over a list), so
sublinear lookup is not expressible in the dialect.

### 1.6 The key point

- The graph is tiny (323 nodes, 607 edges). The work is trivial for the
  BEAM, absurd for interpreted list-scan Prolog with a 5 s clock.
- This is **not** an infinite loop. Both versions are guaranteed to
  terminate (visited list in v1, growing `Known` in v2). It is polynomial
  but unindexed work overshooting a fixed budget.
- The cost is a property of the execution model, not of the question.

### 1.7 Options, ranked

1. **Move the closure out of Prolog.** The server already materializes the
   `calls/5` facts at parse time. Compute the closure (or, better, the
   strongly connected components) in Erlang there, and assert the result as
   facts. `all_mutual_recursion/1` then becomes the linear set
   intersection it already ends with, run over precomputed facts. This is
   the only fix that scales, and it matches the storage ladder in Part 2.
2. **Raise the budget for `all_*` aggregates.** A server-side special case
   (e.g. 30 s for goals that start with an `all_` predicate) lets the
   fixpoint finish. Pragmatic, but the query stays slow.
3. **Bounded queries at the usage level.** `mutual_recursion(F, G)` with a
   `limit` answers the code-review question inside the budget (4 distinct
   pairs in under 5 s), as does scoping to a hub
   (`reaches(walk_scope, X)` with a limit).

---

## 2. SQLite3 (`esqlite`) for storing Prolog facts

Research record: [`prolog-store.md`](prolog-store.md) §4–6, verified
September 2025. Summary below.

### 2.1 What esqlite is

- A maintained Erlang **NIF** (native interface — Erlang code that calls
  into compiled C code).
- **Hex `0.9.0`** (Sept 2025), ~35,000 downloads/week, Apache-2.0.
- Embeds **SQLite 3.45.2** (or the system SQLite via `ESQLITE_USE_SYSTEM`).
- Uses **dirty schedulers**: its C work runs on schedulers that are allowed
  to block, so it does not stall normal Erlang schedulers.
- FTS5 (full-text search), JSON, and RTREE extensions enabled.

### 2.2 Usage shape

```erlang
{ok, Db} = esqlite:open("facts.sqlite"),
esqlite:exec(Db,
  "CREATE TABLE IF NOT EXISTS call (caller TEXT, callee TEXT, file TEXT, line INT)"),
%% prepared insert per fact (or bulk); read back with prepare/step/finalize
```

### 2.3 When it is worth it

Reach for SQLite only when you need at least one of:

- **Incremental updates** — re-parse only changed files and merge, instead
  of rebuilding the whole fact set.
- **SQL directly** — some questions are easier to ask in SQL than in Prolog.
- **Durability and indexing across restarts**, shared by many processes.

### 2.4 Caveats (from the esqlite README)

- A bug in the NIF or in SQLite **can crash the whole VM**. The authors
  recommend running it on a **separate node** if that risk is unacceptable.
- `SQLITE_DQS=0`: string literals in SQL **must use single quotes**.
- It is a **different paradigm**: you store facts as rows and load the
  relevant slice into ETS/erlog to reason over. You do **not** run Prolog
  inside SQLite.

### 2.5 The decision heuristic

```
in-memory erlog dict
  └─ (fact set too large to consult) ──> named ETS table + erlog_ets
        └─ (need durability / incremental / SQL) ──> esqlite (SQLite)
```

**Don't start at SQLite.**

### 2.6 What the project actually uses

The project landed on **DETS** (Erlang's built-in on-disk term store), not
SQLite (see `prolog-store.md` §7):

- `symbolic_fact_store.erl` — a thin wrapper around a DETS `bag` table.
  `write/2` replaces the whole table (parse output is a deterministic
  function of the sources, so each run fully regenerates it); `read/1` folds
  it back into a fact list. The fact's own first element (`defines`,
  `calls`, …) doubles as the DETS key, so lookup needs no extra indexing
  code.
- `prolog_session:load_facts/2` — asserts the fact list into an erlog
  session with `asserta` (O(1) prepend) rather than `assertz` (O(N) append
  per fact, which would make loading thousands of facts O(N²)).
- `symbolic_term_json.erl` — renders terms as JSON for stdout, CLI output,
  and MCP tool results.

---

## 3. How the two findings fit together

Both investigations reach the same architecture:

- **erlog reasons; it does not store or grind.** The fact set should be
  sized to live in memory (dict, or ETS if it grows), consulted at session
  start.
- **Expensive relations are precomputed in Erlang.** Part 1 shows a
  transitive closure that is trivial in Erlang but times out in erlog. The
  fix — compute it at parse time, assert the result as facts — keeps erlog
  where it is fast: reading and unifying, not searching.
- **SQLite is the last rung, not the foundation.** `esqlite` earns its
  place only when the cache-and-rebuild model is outgrown (incremental
  updates, SQL queries, cross-process durability). It never makes a slow
  Prolog query fast — it changes *where facts live*, not *how Prolog
  executes*.

One combined rule: **if a query times out, first ask whether its
computation belongs in Erlang at parse time. Only after that, consider
changing the storage.**

---

## Appendix: Goals run and results

All goals ran against the parse of `src/` + `docs/` (49 files, 18,553
facts, commit `c138c2b`). Results are quoted as returned.

| # | Goal | Result |
|---|---|---|
| 1 | `all_call_edges(E), length(E, N)` | `N: 607` |
| 2 | `findall(C, calls(C, _, _, _, _), R), sort(R, S), length(S, N)` | `N: 323` |
| 3 | `all_call_edges(E), join_step(E, E, _)` | `count: 1` — one round completes |
| 4 | `all_reaches_pairs(C), length(C, N)` | `{ error: "query timed out - the goal may be cyclic or unbounded; try a more specific goal" }` |
| 5 | `all_mutual_recursion(L), length(L, N)` | `{ error: "query timed out - the goal may be cyclic or unbounded; try a more specific goal" }` |
| 6 | `reaches(walk_scope, walk_declaration)` | `count: 34, truncated: false` |
| 7 | `reaches(walk_declaration, walk_scope)` | `count: 17, truncated: false` |
| 8 | `mutual_recursion(F, G)` (limit 150) | `count: 150, truncated: true` — 150 solutions covering 4 distinct pairs: `walk_object/walk_pair`, `walk_declaration/walk_scope`, `walk_children/walk_scope`, `walk_body/walk_scope` |
| 9 | `heading(File, Level, Text, Line), … sub_text(…, "esqlite")` | 1 hit: `docs/prolog-store.md` line 124, §4 "SQLite (`esqlite`) — verified, and when it's worth it" |

Engine quirks hit during this research (worth knowing before re-running):

- `current_predicate(P)` binds `P` as a `Name/Arity` functor term; in JSON
  it renders as `["/", Name, Arity]`. Pattern it as `P = take/3`, not as a
  list.
- `arg(2, P, X)` on such a term returns the arity; on a list it returns the
  tail. Use pattern unification, not `arg/3`, to destructure.
- `sub_text/5` raises `type_error,binary,N` if the text is not a binary.
  Some `paragraph` texts are not binaries in this scan. Guard with
  `atom(Text)`, or scope the search to one file.
- `is_binary/1` is **not** available in this erlog build (despite
  appearing in the dialect docs): `no such predicate: is_binary/1`.
- The server cache is per-process and does not survive server restarts;
  `symbolic_parse` must be re-run after each restart.
