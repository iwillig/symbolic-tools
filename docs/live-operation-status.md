# Live parse and query status

The MCP `status` tool takes no arguments. It reports the active operation in
this server process and the last completed operation, so a second MCP request
can observe progress while `parse` or `query` is still running. Calling it
only after `parse` or `query` returns shows the final outcome instead.

The response has `ok.state` (`idle` or `running`), `ok.active` (an operation
object or `null`), and `ok.last` (an operation object or `null`). Each
operation has `kind` (`parse` or `query`), `phase`, `path` (absolute project
path when known, otherwise `null`), `started_ms`, and `elapsed_ms`. The last
operation also has `outcome.status` (`succeeded`, `failed`, or `crashed`) and,
for failures, a short `error` string. Times are Unix epoch milliseconds
except `elapsed_ms`, which is a duration.

Parse phases: `starting`, `discovering`, `extracting`, `analyzing`, `loading`,
`persisting`, `publishing`. Query phases: `starting`, `validating`, `proving`.
These are coarse phases, not per-file counters. A failed scan never replaces
the previous cache; `status` reports the failed attempt while `overview`
keeps reporting the last good snapshot.

## How the concurrency works

Two pieces make live status possible:

- `symbolic_operation_status` is a separate `gen_statem` that observes the
  cache process. The cache sends phase events without waiting for replies,
  and the tracker monitors that process and records a crash if it dies
  mid-operation. `status` never calls the cache process, so it is answered
  even while the cache is blocked inside a parse or query call.
- `symbolic_stdio` is the MCP stdio transport (replacing the pinned erlmcp
  0.5.1 stdio server, whose request loop ran tool handlers inline, so a
  `status` request could not be dispatched while `parse` or `query` blocked
  that loop). The adapter dispatches each `tools/call` in a monitored worker
  and serializes all responses through one writer; each response keeps its
  request's ID. `parse` and `query` replies stay synchronous — their callers
  wait for the real result, unchanged.

Limits: the adapter allows 16 concurrent requests and rejects further ones
with a "too many active requests" error; a request ID already in flight is
rejected as a duplicate. `status` reports only the active operation and the
single last outcome — no persistent history and no cancellation. `last` is
reset when the server restarts. A query queued behind another operation in
the cache shows as `running` only when the cache actually begins it.
