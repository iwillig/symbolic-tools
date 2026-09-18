# Design: Logging & Metrics (`logger` + OTEL)

This document covers two observability concerns for the `symbolic` tool and its
MCP server: **logging** and **metrics** (including OpenTelemetry). It
complements the front end in [`cli-erlang.md`](cli-erlang.md), the MCP server in
[`erlang-mcp-design.md`](erlang-mcp-design.md), and the extraction layer in
[`tree-sitter-erlang.md`](tree-sitter-erlang.md). A design/research document
only — nothing is implemented here.

**Recommendation up front:**

- **Logging:** use the stdlib **`logger`** (structured, metadata map) and add a
  small JSON-to-`stdout` handler. Do **not** adopt `lager` (unmaintained).
- **Metrics:** pick by backend. Target **OTLP** → the official
  [`opentelemetry`](https://github.com/open-telemetry/opentelemetry-erlang) SDK
  (note: **traces are stable; metrics are still experimental**). Target
  **Prometheus** → `recon` + `prometheus` (the most mature Erlang path).
- Framing: the `symbolic` CLI is **short-lived** — per-run counters/timings are
  fine as `logger` events. The long-running **MCP server** is where real
  metrics (and OTEL) matter.

## 1. Logging

### 1.1 Options

| Option | Status | Notes |
|---|---|---|
| **`logger` (stdlib)** | ✅ recommended, zero deps | OTP 21+ front-end. Structured: a message + a **metadata map**. Levels `emergency … debug`. Pluggable handlers, filters, per-module/app levels. |
| **`error_logger` (stdlib)** | ⚠️ deprecated | Legacy API; OTP 26+ deprecates it in favor of `logger`. Don't use in new code. |
| **[`lager`](https://github.com/erlang-lager/lager)** | ⚠️ effectively unmaintained | Apache-2.0; structured JSON/text/term handlers, per-app levels. But **last release 3.9.2, May 2021** (~4 yrs stale; still ~18k dl/wk). Only if joining an existing lager codebase. |

### 1.2 Using `logger`

Log functions: `logger:emergency/1,2,3`, `alert`, `critical`, `error`,
`warning`, `notice`, `info`, `debug`, plus the generic `logger:log/2,3,4`. The
level is `emergency | alert | critical | error | warning | notice | info | debug`
(default `info`). Each takes a message (string, `io` format string + args, a
**report** map, or a **fun**) and an optional **metadata** map:

```erlang
-include_lib("kernel/include/logger.hrl").

?LOG_INFO("parsed ~b files", [N], #{domain => [extract], ms => Elapsed}).
%% or, lazily — the fun only runs if the level is enabled:
logger:debug(fun([]) -> {"expensive detail", #{detail => expensive()}} end, []).
```

`logger` auto-attaches `pid`, `gl` (group leader), and `time` (µs) to every
event; the `?LOG_*` macros also attach `mfa`, `file`, `line`. You add your own
keys via the metadata map, via `logger:set_process_metadata/1` /
`update_process_metadata/1`, or via the `kernel` `logger_metadata` config.
Configure levels per module/app with `set_module_level/2` /
`set_application_level/2`.

### 1.3 Structured JSON output (the `lager` replacement)

The modern "structured JSON logs" path is a tiny `logger` **handler** that emits
one JSON line per event to `stdout`. A handler implements the
[`logger_handler`](https://www.erlang.org/doc/man/logger_handler.html) behaviour;
the one required callback is `log(LogEvent, Config)` where `LogEvent` is a map
`#{level := L, msg := Msg, meta := Meta}`. Install with
`logger:add_handler(Id, Module, Config)`:

```erlang
-module(json_log_h).
-behaviour(logger_handler).
-export([log/2]).

%% LogEvent = #{level := Level, msg := Msg, meta := Meta}
log(#{level := Level, msg := Msg, meta := Meta}, _Config) ->
  J = #{level => Level,
        time  => maps:get(time, Meta),
        msg   => render_msg(Msg),
        meta  => normalize(Meta)},           %% pids etc. -> encodable terms
  io:put_chars(stdout, [jiffy:encode(J), $\n]),
  ok.

%% `msg` is one of: {Format, Args} | {string, Chardata} | {report, Report}
render_msg({Format, Args})   -> unicode:characters_to_binary(io_lib:format(Format, Args)),
render_msg({string, S})      -> unicode:characters_to_binary(S),
render_msg({report, Report}) -> {F, A} = logger:format_report(Report),
                                unicode:characters_to_binary(io_lib:format(F, A)).
```

```erlang
% runtime:
logger:add_handler(json, json_log_h, #{level => info}).
```

or from `sys.config` (the `logger` parameter on the `kernel` app; the built-in
`logger_std_h` handler can also write to a file via
`#{config => #{file => "..."}}`, and `logger_disk_log_h` adds rotation):

```erlang
[{kernel,
  [{logger,
    [{handler, json, json_log_h, #{level => info}}]}]}].
```

Notes: `meta` may contain PIDs / binaries that a JSON encoder can't emit directly —
normalize them (the skeleton's `normalize/1`). Use any JSON encoder (`jiffy` is the
common choice). This gives you container-friendly structured logs with **no
third-party logging dependency**.

## 2. Metrics

### 2.1 Options

| Option | Status | Notes |
|---|---|---|
| **CNCF [`opentelemetry-erlang`](https://github.com/open-telemetry/opentelemetry-erlang)** | ✅ official SDK | 402★, Apache-2.0, implements **OTel spec 1.8.0**, very active (maintainers at Simplebet/VMware/Splunk; approvers ferd/Honeycomb + Adobe). **Traces = stable; metrics = experimental.** |
| **[`recon`](https://github.com/ferd/recon)** | ✅ mature | BSD-3, **2.5.6 (Aug 2024)**, ~242k dl/wk, 102M total. The battle-tested Erlang observability suite (metrics + process tracking + dashboard). Prometheus-oriented, not OTEL-native. |
| **[`prometheus`](https://github.com/prometheus-erl/prometheus.erl)** | ✅ active | MIT, **6.1.3 (2026)**, 87M total. The Prometheus client; the backend `recon` pairs with. |

### 2.2 OpenTelemetry Erlang SDK

The SDK splits into Hex packages (verified from the repo layout and README):

| Hex package | Role | Stability |
|---|---|---|
| `opentelemetry_api` | API — depend on this **only** in instrumented code (no-op if no SDK present) | stable (tracing) |
| `opentelemetry` | SDK implementation (spans, propagators) — **tracing only** | stable (tracing) |
| `opentelemetry_exporter` | **OTLP exporter** (package name is `opentelemetry_exporter`, not `..._otlp`) | stable (traces) |
| `opentelemetry_api_experimental` / `opentelemetry_experimental` | **metrics API + SDK** (incl. `otel_exporter_metrics_otlp`) | **experimental** |
| `opentelemetry_semantic_conventions`, `opentelemetry_zipkin` | semconv constants; Zipkin exporter | — |

**Traces are stable; the metrics signal lives in the `_experimental` apps.** That
is the key caveat for "OTEL metrics in Erlang": you can adopt it, but pin the
version and re-check as metrics graduate to stable.

Verified **metrics** API (from the `_experimental` source):

```erlang
Meter   = otel_meter_provider:get_meter(InstrumentationScope),   % get_meter/1
Counter = otel_meter:create_counter(Meter, "requests_total",
                                    [{unit, "1"}, {description, "Requests handled"}]),
%% record a value (also create_histogram/3, create_updown_counter/3,
%% create_observable_gauge/3, ...):
otel_counter:add(Ctx, Meter, "requests_total", 1, #{}).
```

Release wiring (from the README): list `opentelemetry_exporter` **before**
`opentelemetry` so its deps boot first, and mark `opentelemetry` `temporary` so an
OTEL crash doesn't take down the rest of the release:

```erlang
{relx, [{release, {symbolic, "0.1.0"},
          [opentelemetry_exporter,
           {opentelemetry, temporary},
           symbolic_tools]}]}.
```

Library instrumentation (cowboy, etc.) lives in the separate
[`opentelemetry-erlang-contrib`](https://github.com/open-telemetry/opentelemetry-erlang-contrib)
repo.

### 2.3 `recon` + `prometheus`

[`recon`](https://github.com/ferd/recon) is the de-facto Erlang observability
suite: it samples metrics (via a pluggable collector — commonly
[`prometheus`](https://github.com/prometheus-erl/prometheus.erl)), tracks
processes/schedulers, and ships a web dashboard. It is not OTEL-native, but for a
**Prometheus/Grafana** backend it is the most mature, lowest-risk choice and pairs
naturally with a `symbolic` release that exposes a `/metrics` scrape endpoint.

## 3. Recommended for `symbolic`

1. **Logging:** `logger` + a JSON-to-`stdout` handler (§1.3). Skip `lager`.
2. **Metrics — pick one backend, don't hand-roll:**
   - **OTLP** (Tempo/Jaeger/Grafana/cloud APM) → official `opentelemetry` SDK;
     accept that metrics are experimental.
   - **Prometheus/Grafana** (the common Erlang default) → `recon` + `prometheus`.
3. **Where it lands:** the CLI (`symbolic parse` / `symbolic query`) is
   short-lived — emit per-run counters/timings as `logger` events. Stand up real
   metrics (and OTEL) for the long-running **MCP server**
   ([`erlang-mcp-design.md`](erlang-mcp-design.md)).

## References

- [`cli-erlang.md`](cli-erlang.md) — the `symbolic` CLI (short-lived; log-based
  metrics suffice).
- [`erlang-mcp-design.md`](erlang-mcp-design.md) — the long-running MCP server
  (where OTEL/metrics apply).
- [`tree-sitter-erlang.md`](tree-sitter-erlang.md) — the extraction the CLI drives.
- [`logger`](https://www.erlang.org/doc/man/logger.html) ·
  [`logger_handler`](https://www.erlang.org/doc/man/logger_handler.html) —
  stdlib logging.
- [`lager`](https://github.com/erlang-lager/lager) — the (unmaintained)
  alternative.
- [`open-telemetry/opentelemetry-erlang`](https://github.com/open-telemetry/opentelemetry-erlang)
  ·
  [`opentelemetry-erlang-contrib`](https://github.com/open-telemetry/opentelemetry-erlang-contrib)
  — the official OTEL SDK and its instrumentation libraries.
- [`ferd/recon`](https://github.com/ferd/recon) ·
  [`prometheus-erl/prometheus.erl`](https://github.com/prometheus-erl/prometheus.erl)
  — the Prometheus-oriented alternative.
