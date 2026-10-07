# Full-text search: the `symbolic search` tier

**Status: implemented** — `native/symbolic_text` (Rustler NIF),
`src/symbolic_text.erl` (wrapper), `src/symbolic_search.erl` + the
`symbolic search` CLI command, the `text_search/2,3` Prolog predicate
(`src/symbolic_prolog_lib.erl`), and the `symbolic parse --db` sidecar
cache. This document records what was built, the stack decision behind
it, and the rejected alternatives.

## What it does

`symbolic parse --db` extracts prose as facts — `comment/3` from code,
`paragraph/3`, `heading/5`, `blockquote/3` from markdown — alongside
the structural facts. `symbolic search -db <facts.dets> "query"`
indexes every prose fact and returns BM25-ranked results as JSON:

```
$ symbolic search -db facts.dets -limit 3 "inverted index postings"
[{"file":".../symbolic_search_tests.erl","kind":"comment","line":33,
  "score":24.011,"text":"..."}]
```

The index is built fresh per invocation from the fact database alone —
the same one-shot "start fresh, do work, tear down" shape as
`symbolic query`'s prolog_session and `symbolic extract`'s model load —
**except** when `symbolic parse --db` already wrote the sidecar cache
(below), in which case search loads the prebuilt index instead.

## The stack, and why

The decisions were made against
[`rust-nlp-landscape.md`](rust-nlp-landscape.md) and
[`nlp-tooling.md`](nlp-tooling.md):

| Layer | Choice | Why |
|---|---|---|
| Tokenization | `unicode-segmentation` (UAX #29 `unicode_words`) + Unicode lowercase | The standard word-boundary rule; deterministic; zero model files |
| Index | Hand-built inverted index: term → (doc → tf), per-doc lengths | The Riak Search precedent `nlp-tooling.md` §3 sketches; a screenful of code for this bounded problem |
| Scoring | Okapi BM25 (k1=1.2, b=0.75) | Standard, well-understood; parameters are named constants, not tuned magic |
| Persistence | Hand-rolled binary snapshot (magic `SYMTEXT1`, sorted LE fields) | Same index → same bytes; no serde/bincode dependency surface |
| Integration | Rustler NIF, in-process (`priv/symbolic_text.so`) | Respects [`erlang-mcp-design.md`](erlang-mcp-design.md)'s no-subprocess rule; mirrors `native/symbolic_ts` |

Determinism is the contract, pinned by tests on both sides of the NIF:
the same query against the same index returns the same order — scores
descending, ties ascending by doc id. UAX #29 has no dictionary, so CJK
text segments per character — the honest zero-model behavior; the
dictionary-based CJK morphology (`lindera`, `vaporetto`) that
`rust-nlp-landscape.md` describes is deliberately out of scope.

### Rejected: tantivy (buy)

`tantivy` is mature and excellent, but the wrong fit here: it drags a
large dependency tree into a cdylib, runs its own thread pools and mmap
directories (friction inside a NIF), and solves problems this repo
doesn't have — concurrent multi-writer indexing, segment merging —
while this tier indexes a fact database's bounded prose corpus once per
invocation. If ranking quality ever matters more than the dependency
surface, revisit this decision here.

### Rejected: stemming (`rust-stemmers`)

Snowball stemming would improve recall (`parsing` ↔ `parsed`) at the
cost of index-time vocabulary decisions. Deferred, not banned: it slots
in behind the same tokenizer seam, and the snapshot format versions
itself (bump `SYMTEXT1`) when it lands.

### Supersedes: `nlp-tooling.md` §3's pure-Erlang sketch

`nlp-tooling.md` §3 originally argued for hand-written **Erlang**
binary matching plus a hand-built inverted index as "the idiomatic BEAM
answer". This tier keeps that section's *architecture* (hand-built
inverted index, no imported engine) but moves it to Rust, because:
correct UAX #29 segmentation is a crate import instead of a
reimplementation; the Rustler pattern is already proven here
(`native/symbolic_ts`); and the dirty schedulers keep unbounded text
work off the normal BEAM schedulers. `nlp-tooling.md` §3 now points
here.

## The NIF contract

`symbolic_text.erl` exposes:

| Function | Behavior | Scheduling |
|---|---|---|
| `index_new/0` | fresh index resource | normal |
| `index_add_doc/3` | index one doc (id, utf8 binary) → `ok` | DirtyCpu |
| `index_search/3` | query, limit → `{ok, [{Id, Score}]}` | DirtyCpu |
| `index_stats/1` | `{ok, {DocCount, TermCount}}` | normal |
| `index_save/2` | snapshot to path (utf8 binary) → `ok` | DirtyIo |
| `index_load/1` | snapshot from path → `{ok, Index}` | DirtyIo |
| `tokenize/1` | text → `{ok, [Token]}` (contract pinning) | normal |
| `index_snapshot/1` | index → `{ok, Bytes}` (the same bytes `index_save/2` writes) | DirtyCpu |
| `index_load_binary/1` | snapshot bytes → `{ok, Index}` | DirtyCpu |

## The parse-time cache

`symbolic parse --db X.dets` also writes `X.dets.text_idx` — one
`term_to_binary` container holding the BM25 snapshot bytes plus the doc
metadata — from the same fact list as the DETS store itself
(`symbolic_parse:maybe_store/2`, best-effort: a failed sidecar write
never fails a parse). `symbolic search` loads it when the sidecar
exists, decodes, and is at least as new as the DETS store; every other
state (missing, stale mtime, corrupt, wrong shape) degrades silently
to the build-from-facts path, never an error.

One caveat the tests pin: filesystem mtimes have second granularity, so
an index re-written in the same second as the database is
indistinguishable from a fresh one — `parse` writes both files together,
which is the case that matters.

## The Prolog surface: `text_search/2,3`

The same index is reachable from inside erlog, on every query
surface (CLI `symbolic query -db`, the MCP server's `query` tool):

```prolog
?- text_search("inverted index postings", Hits).
Hits = [hit(comment, test/symbolic_search_tests.erl, 33, 22.81),
        hit(paragraph, docs/nlp-tooling.md, 125, 18.02), ...]
```

`text_search/2` binds `Hits` to a BM25-ranked list of
`hit(Kind, File, Line, Score)` terms, best first, limit 10;
`text_search/3` takes an explicit positive-integer limit. It is a
compiled procedure registered by `symbolic_prolog_lib` — the same
`add_compiled_proc` mechanism `count_pairs/2` uses — and it enumerates
the prose facts (comment/3, paragraph/3, heading/4, blockquote/3)
straight out of the erlog database the goal is being proved against, so
whatever base the session holds IS the corpus: no file, no sidecar, no
plumbing. Query accepts a double-quoted code list (the natural literal
under erlog's `double_quotes(codes)`), an atom, or a binary; error
modes follow the module's mode discipline (unbound →
instantiation_error, wrong type → type_error).

No per-session index cache is possible: `prolog_session` proves in a
spawned worker process (`prove_with_timeout/3`), so nothing a callback
stashes survives a query and the erlog state never flows back. The
index is built once per goal evaluation — measured well under the 5s
proof budget for this repo's own corpus. An MCP query therefore builds
fresh per query; the CLI's fact-database path has the sidecar instead.

Fallible calls return `{error, Reason}` tuples, never raise:
`invalid_utf8`, `io_error`, `bad_snapshot`. Text and path arguments are
UTF-8 **binaries** — rustler's `String` decoder rejects plain lists
loudly. The resource is `Mutex<Index>`: genuinely thread-safe, no
`unsafe` (unlike `symbolic_ts`, whose raw tree-sitter pointers require
it), so any process may hold an index term.

## Testing

- `cargo test` (in `native/symbolic_text`): tokenizer, BM25 ordering,
  snapshot round-trip and corruption rejection.
- `test/symbolic_text_tests.erl`: the Erlang-visible NIF contract —
  determinism, tie-breaking, error tuples, save/load and the
  snapshot-bytes pair.
- `test/symbolic_text_search_tests.erl`: `text_search/2,3` proved
  through real prolog_sessions — ranking, every prose kind, the
  accepted query types, error modes, bound-Hits unification.
- `test/symbolic_search_tests.erl`: `run_result/3` against real DETS
  databases — prose-fact selection (including `comment/3` vs
  `paragraph/3`'s differing argument orders), JSON shape, error paths,
  and the sidecar cache (round trip, staleness, corruption).
- `test/symbolic_cli_tests.erl`: the command tree includes `search`.

## Future work, explicitly not promised

- Query-time stemming or a `stem` flag (see above).
- A cross-query index cache for the MCP server (each MCP query builds
  fresh per goal evaluation — fine at measured cost, but a per-project
  index held in `symbolic_codebase`'s state would skip the rebuild if
  profiling ever shows it matters).
