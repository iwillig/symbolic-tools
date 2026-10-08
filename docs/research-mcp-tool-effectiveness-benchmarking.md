# Research: Measuring the Effectiveness of MCP Tool Calls by an LLM Agent

What exists today, outside this repo, to answer: given an agent calling
`prolog_start_session` / `prolog_consult` / `prolog_query` /
`prolog_end_session` in sequence, did it pick the right tool at the right
time, call it correctly, get a useful result, and complete the task? This
picks up exactly where
[`research-llm-judge-and-benchmarking.md`](research-llm-judge-and-benchmarking.md)
§1.3 and §10 item 15 leave off — agent-trajectory evaluation, specifically
for MCP tool calls — and does not re-cover that document's general
eval-framework survey (OpenAI Evals, Inspect AI, lm-evaluation-harness,
promptfoo's *general* grading schema, HELM) or its LLM-as-judge literature
(Zheng/MT-Bench, G-Eval, Prometheus, JudgeBench), both already settled
there. This note is about a practical, adoptable tool to point at a local
MCP server today, not primarily a literature survey — the detailed
numbered sections below exist for anyone who wants the full landscape, but
the point of this note is the recommendation in the next section. Research
only; nothing below is built.

- **Date:** 2026-10-07
- **Commit:** `d10d431`
- **Scope:** [`erlang-mcp-design.md`](erlang-mcp-design.md)'s four-tool
  surface (§3), erlog↔JSON marshalling (§4), known risks (§5), timeout/
  isolation (§8); and the external landscape of MCP-native eval tools
  (promptfoo, MCP Inspector, MCP-specific benchmark suites), general
  tool-use benchmarks, PostHog's MCP analytics product, open-source MCP
  eval harnesses, and the BEAM ecosystem's trajectory-matching tooling.
- **Method:** WebSearch to find candidates, WebFetch against each
  project's own README/docs/paper page — never a secondary write-up — for
  every claim below. MCP-specific benchmarking is a 2025–2026 research
  area; most benchmark sources are arXiv preprints or HuggingFace paper
  pages dated within the last twelve months, several have no peer review
  yet, and two (MCP-AgentBench, LiveMCPBench) were read only via their
  abstract/summary page, not the full PDF — flagged inline and in §8.

---

## Recommendation up front — what to actually try, in order

**1. Try `promptfoo`'s native MCP provider first.** It is a mature,
vendor-maintained, widely-used eval/red-team tool (already known to this
project's eval-framework research as a general grading engine) that as of
its current docs (fetched 2026-10-07) ships a **built-in MCP provider** —
no custom provider script, no SDK dependency on this project's side. Point
it at `symbolic serve` directly:

```yaml
providers:
  - id: mcp
    config:
      enabled: true
      server:
        command: /path/to/symbolic
        args: ['serve']
        name: symbolic-tools
```

This works against **any** stdio-launchable binary regardless of
implementation language — `command`/`args` just exec a process, so
Erlang/BEAM is no different from Node or Python here. The provider
auto-discovers the four tools (`tools/list` under the hood), and test
cases are plain YAML with `vars`/`assert` blocks — `contains`, `is-json`,
custom JavaScript, or an `llm-rubric` judge for response quality,
plus purpose-built MCP red-team plugins (tool-poisoning,
`mcp:tool-response-poisoning`, BOLA/BFLA-style authorization probes) if
misuse/security is also in scope. For the full four-tool agent flow (not
just one direct tool call), attach the MCP server's tools to a real
chat/LLM provider (`mcp` config on an OpenAI/Anthropic-style provider
block) and let that model choose which of the four tools to call across
a multi-turn conversation — this is the shape that actually answers "did
the agent pick the right tool at the right time." **This is the single
best fit found in this research for "a tool I can point at my local MCP
server today without building anything."** Caveat, confirmed from the
docs: scoring tool-*selection* and tool-*argument* correctness in that
multi-turn mode depends on inspecting the provider's tool-call metadata
in a custom assertion — the MCP provider itself scores response content/
success, not a trajectory-shaped `tool_used`/`tool_order` grade out of the
box. §1 below has the full detail and what's still unconfirmed about the
stateful, session-id-threading case this project's four tools specifically
need.

**2. If promptfoo's assertion vocabulary is too shallow for trajectory
scoring specifically, try `lastmile-ai/mcp-eval` next.** It is the one
project found here purpose-built for exactly the (a)/(b)/(c)/(d) breakdown
in the task — `Expect.tools.was_called(name, args)`, call-sequence/
path-efficiency assertions, content matching, and LLM-judge rubrics — over
real OpenTelemetry traces of an agent driving a real MCP server over
stdio, confirmed language-agnostic on the server side (§6.1). It is a
smaller, less battle-tested project (~39 stars) than promptfoo and
requires writing Python test functions from scratch, but its assertion
surface is the closest existing match to the trajectory-grading shape
`research-llm-judge-and-benchmarking.md` §10.15 already wants.

**Everything else surveyed — MCP Inspector, PostHog MCP analytics, the
MCP-native benchmark suites (MCPBench/MCPMark/MCP-Universe/etc.),
general agent benchmarks (τ-bench, BFCL), and Elixir LangChain
`Trajectory` — is either not an evaluation tool at all (Inspector is
explicitly a debugger), requires integration work this project can't do
yet (PostHog needs an SDK that doesn't exist for Erlang), requires
reimplementing the tool surface in a foreign format (τ-bench, BFCL), or
is a benchmark suite you'd run once for a paper, not a tool you adopt for
ongoing CI (§2–§7).** None of them beat trying promptfoo first.

**Direct answer to "is there an existing tool I can point at my local MCP
server today, or does it require building something":** **Yes, with
promptfoo's MCP provider** — zero new code to connect it, YAML to write
the test cases. It gets weaker (needs custom JS assertions) the more the
question is specifically about tool-*selection* ordering across the
stateful four-call session this project cares about; for that narrower
question, building on `lastmile-ai/mcp-eval`'s assertion model, or the
in-house erlog-rules-over-`serve.log` approach this repo's own prior
research already points to, is still the more direct fit. Both are viable
starting points; neither requires inventing the underlying plumbing from
zero.

---

## 1. `promptfoo`'s native MCP support

**Primary sources:** [`promptfoo.dev/docs/providers/mcp/`](https://www.promptfoo.dev/docs/providers/mcp/), [`promptfoo.dev/docs/integrations/mcp/`](https://www.promptfoo.dev/docs/integrations/mcp/), [`promptfoo.dev/docs/red-team/mcp-security-testing/`](https://www.promptfoo.dev/docs/red-team/mcp-security-testing/).

promptfoo's own docs describe the MCP provider as making "an MCP server
the target of an eval or red team" — this is a first-class provider type,
not a bolted-on example script. Confirmed from the docs:

**Pointing it at an arbitrary local/custom server.** Configuration is
a `server` block with `command`/`args` (or `path` for a `.js`/`.py`
script), e.g.:

```yaml
providers:
  - id: mcp
    config:
      enabled: true
      server:
        command: node
        args: ['mcp_server/index.js']
        name: test-server
```

Nothing in this shape is Node-specific — `command` execs an arbitrary
binary, so pointing it at `symbolic serve` (an Erlang/BEAM binary over
stdio) requires no more than supplying the right `command`/`args`, exactly
as the recommendation above shows. The red-team guide's own worked
scenarios use `path: ./path/to/your/mcp-server` for a generic local
server, confirming this is a documented, intended usage pattern and not
an inference.

**Tool enumeration.** Automatic — debug-mode logging shows "Available
tools from connected servers," and tools can be allow/deny-listed with
`tools: [...]`/`exclude_tools: [...]`. No manual schema entry is required
for a new server.

**What it scores.** Two distinct modes, and this distinction matters for
the four-tool question:

1. **Direct MCP-provider mode** — promptfoo invokes a tool call itself
   (the "prompt" *is* the tool call, formatted as JSON: `{"tool":
   "process_payment", "args": {...}}`), and assertions (`contains`,
   `is-json`, custom JS, `llm-rubric`) score the *response*. This tests
   "does calling this tool with this argument shape return a sane result"
   — useful for `prolog_query`/`prolog_consult` argument-handling and
   response-shape checks, but it is promptfoo choosing the tool and
   arguments, not an LLM agent — there's no tool-*selection* question
   being tested in this mode.
2. **Attached-to-a-chat-provider mode** — the docs confirm "you can
   connect a Promptfoo provider to an external MCP server... to give it
   tools," meaning a real chat/LLM provider block can have the MCP
   server's tools attached and a real model chooses which to call,
   across a multi-turn conversation, exactly the shape needed to test
   "did the agent pick the right tool at the right time." This is the
   mode that actually drives an agent through something like
   `prolog_start_session → prolog_consult → prolog_query →
   prolog_end_session`.

**What's confirmed vs. not, on the stateful four-call case specifically.**
WebFetch against promptfoo's own integration docs did **not** surface
explicit guidance for threading a session id returned by one tool call
into the arguments of the next, or an assertion keyed on tool call
*order* (no `metadata.toolCalls`-based ordering assertion was found
verbatim in the fetched pages, despite a search-result snippet suggesting
one exists). The practical read: this should work in the attached-chat-
provider mode because the conversation *history* naturally carries the
session id forward (the model sees the previous tool result containing
`session_id` and includes it in the next call, which is exactly how a
real agent would use these four tools) — but scoring "was the id threaded
correctly, in the right order" would likely require a **custom JavaScript
assertion** inspecting the provider's returned tool-call trace, not a
built-in one-line assertion. Treat this specific gap as the most
actionable open question from this whole research pass (§9).

**Red-team-specific plugins.** `mcp:tool-response-poisoning` ("executes
benign tool calls against a real MCP server and grades the returned
content for response-side prompt injection") and a general MCP security
guide covering tool poisoning, authorization flaws (BOLA/BFLA-style), and
data exfiltration. Relevant if misuse/security of `prolog_consult`
(arbitrary-Prolog-text injection) is ever in scope, separate from the
effectiveness question this note is primarily about.

**Maturity.** Comprehensive, current documentation (local/remote servers,
multiple servers, OAuth/Bearer/API-key/basic auth, tool filtering,
response transforms, timeout controls including a `resetTimeoutOnProgress`
option the docs flag as a recent addition), worked quickstart
(`npx promptfoo@latest init --example redteam-mcp-agent`), and an active
GitHub repo shipping new MCP-specific red-team plugins recently (e.g.
PR #9983, `mcp:tool-response-poisoning`). This is a maintained, growing
feature area in an established tool, not a one-off experiment — the
strongest maturity signal of anything surveyed in this document.

**Net assessment.** promptfoo is the best "adopt today" answer found in
this research precisely because it needs zero new code to connect (unlike
`mcp-eval`'s Python test functions or PostHog's missing Erlang SDK) and is
backed by a team actively shipping MCP-specific features, not a small
research-adjacent repo. Its limitation for this project's specific
question is that its trajectory/sequence-assertion story is thinner and
less explicit than `lastmile-ai/mcp-eval`'s purpose-built
`Expect.tools.*`/path-efficiency surface (§6.1) — promptfoo scores
response content and (with custom JS) tool-call metadata; `mcp-eval`
scores the trajectory shape directly as a first-class concept.

---

## 2. Anthropic's MCP Inspector

**Primary sources:** [`modelcontextprotocol.io/.../tools/inspector`](https://modelcontextprotocol.io/legacy/tools/inspector) (official docs, fetched at the `2026-07-28` doc revision) and [`github.com/modelcontextprotocol/inspector`](https://github.com/modelcontextprotocol/inspector).

The official docs state it plainly: Inspector is "**the reference developer
tool for testing and debugging MCP servers**," not an evaluation tool. It
ships as one package, three clients behind one binary:

| Client | Invocation | Purpose, verbatim |
|---|---|---|
| Web | `npx @modelcontextprotocol/inspector` | "A full graphical inspector in the browser. The default, and the richest surface." |
| CLI | `npx @modelcontextprotocol/inspector --cli` | "A scriptable, machine-readable client for CI, shell pipelines, and coding agents." |
| TUI | `npx @modelcontextprotocol/inspector --tui` | "An interactive terminal UI, for when a browser isn't available or wanted." |

All three share one core — same transports, same config files, same OAuth
state — so behavior is identical across them. `mcp-inspector` itself is a
"thin launcher" owning only the mode flag (`--web`/`--cli`/`--tui`) and
`--help`; every other flag (`--catalog`, `--config`, `--server-url`,
`--transport`, `--method`, `--tool-name`, `--tool-arg`, `--format`) belongs
to the chosen client.

**What the CLI actually does.** The documented workflow is "connect → list
→ call → assert": `tools/list` to enumerate, `tools/call --tool-name X
--tool-arg k=v --format json` to invoke and pipe into `jq`, with documented
exit codes for CI. This is single-call, single-assertion testing of one
server at a time — a human or a script picks one tool, one argument set,
and checks the response shape. There is no multi-step trajectory concept
in the CLI (no "run this prompt, observe which tools get called in what
order"), no scoring rubric, no aggregate pass rate across a task set, and
no LLM-judge integration anywhere in the tool.

**Precise verdict on the "debugging vs. automated evaluation" distinction
the task asked for:** Inspector CLI is a debugging/CI-smoke tool. It is
not an automated *agent* evaluation tool — it never drives an LLM through a
prompt and observes/scores the resulting tool-call trajectory. Using it to
check that `prolog_start_session` → `prolog_consult` → `prolog_query` are
individually well-formed and return sane shapes is a legitimate, low-effort
use, cheap enough to run alongside whichever of §1/§6 is adopted; using it
to answer "did the agent pick the right tool at the right time" is outside
its design.

---

## 3. PostHog's MCP analytics product

**Primary sources:** [`posthog.com/docs/mcp-analytics`](https://posthog.com/docs/mcp-analytics), [`posthog.com/docs/mcp-analytics/installation`](https://posthog.com/docs/mcp-analytics/installation), [`posthog.com/docs/mcp-analytics/custom-servers`](https://posthog.com/docs/mcp-analytics/custom-servers).

**What it measures.** MCP Analytics "shows how AI agents use your MCP
tools. It records tool calls, agent intent, reported models, failures, and
requests for missing capabilities." The core event is `$mcp_tool_call`
(tool name, client, latency, errors, session); `$exception` covers
failures; there's also an adoption signal from `$mcp_initialize` /
`$mcp_tools_list` handshakes, and a `get_more_tools` virtual-tool mechanism
for agents to report missing capabilities. This directly matches three of
the four things this project wants to measure — which tool, with what
latency, did it fail — but says nothing by itself about *correctness* of
the query or the arguments; that's a `properties` payload the server has
to choose to send, not something PostHog infers.

**Instrumentation requirement — the load-bearing fact for this repo.**
There are exactly two paths:

1. **`instrument(server, posthog, options?)`** — wraps an
   `@modelcontextprotocol/sdk` `Server`/`McpServer` object by patching its
   request handlers. This requires the official TypeScript/Python MCP SDK.
2. **`PostHogMCP`** — "a subclass of the posthog-node client," a drop-in
   replacement for custom HTTP dispatchers (Hono, Express, Cloudflare
   Workers, Vercel edge functions) that speak MCP without going through
   the SDK's server abstraction.

Both paths are still JS/Python/Go/Ruby only. The installation page lists
exactly **four SDKs** — TypeScript (beta), Python (beta), Go (beta), Ruby
(experimental) — with a feature-coverage table showing even those four
diverge (Go, for instance, "sends neither `$mcp_initialize` nor
`$mcp_tools_list`"). The only zero-code path, the `npx @posthog/wizard
mcp-analytics` auto-instrumenter, "only works for TypeScript and Python
servers." **There is no Erlang/BEAM SDK, and the docs give no
language-agnostic integration guide** — WebFetch against the custom-servers
page specifically for this could not surface one; what's documented stops
at "see the language-specific installation page."

**Is this specific to Claude/Claude Code's own MCP usage, or any MCP
server?** Any MCP server, by design — PostHog's docs frame this as a
product for people operating their own MCP servers, not as a
Claude-Code-only feature. The restriction is purely on implementation
language, not on which LLM client calls the server.

**Could `erlmcp`/`symbolic serve` realistically emit this data?** Not via
an official SDK — none exists for Erlang. The realistic path, and this is
an inference from how `posthog-node`/PostHogMCP are described (a thin
wrapper library around PostHog's REST capture endpoint), not something
directly documented for this case: write a small Erlang module in
`prolog_session`/`symbolic_serve.erl` that POSTs a JSON body shaped like
PostHog's generic event-capture call (`event`, `distinct_id`, `properties`
with the `$mcp_tool_call` property names observed in the docs) to
PostHog's capture endpoint after each tool call. This is a nontrivial
integration — nothing enforces staying in sync with PostHog's actual
property schema as it evolves, and it would be the project's only
non-SDK-based emitter in a product line that supports four languages — but
it is not blocked by anything structural; PostHog's event model is just
JSON over HTTP. **Treat "PostHog could ingest our events" as plausible but
unverified**; the four-language SDK list and the absence of a documented
generic schema are the two facts actually confirmed, not the viability of
a hand-rolled emitter. This is why PostHog is not in the "try first" list
above — it is strictly more integration work than promptfoo or
`mcp-eval`, for a narrower slice (latency/failure telemetry, not
correctness) of the question asked.

---

## 4. MCP-specific benchmark suites

All read from their own paper/HuggingFace page or GitHub README, not
third-party coverage. All are 2025-dated preprints; treat accuracy numbers
as provisional and methodology as the more durable part of each finding.

| Benchmark | Source | Scope | Metrics | Custom-server fit |
|---|---|---|---|---|
| **MCPBench** | [github.com/modelscope/MCPBench](https://github.com/modelscope/MCPBench) | 28 live MCP servers, 250 tools, 3 domains (web search, DB query, GAIA) | Task completion accuracy, latency, token consumption | **Best fit of the benchmark suites.** Explicitly supports arbitrary servers, remote (SSE) or local (stdio via `npx`), via a JSON config; "the code will automatically detect the tools and parameters in the Server, so you don't need to configure them manually." No code changes to add a server — only a task/query set, which this project would still have to write. |
| **MCPMark** | [github.com/eval-sys/mcpmark](https://github.com/eval-sys/mcpmark), paper [HuggingFace 2509.24002](https://huggingface.co/papers/2509.24002) | 127 CRUD-heavy tasks, 5 environments (filesystem, Notion, Playwright, GitHub, PostgreSQL), 38 curated initial states | Task completion (pass@1/pass@4/pass^4), tool-usage efficiency (fewer/more-targeted calls vs. repetitive exploration), execution stability across repeated runs | Ships "MCPMark-Agent," described as a "lightweight and general-purpose agent framework," built on the MCP Python SDK — plausibly extensible to a new server, but the paper page doesn't spell out the integration steps for an arbitrary stdio server the way MCPBench's README does. Best model result: 52.56% pass@1 / 33.86% pass^4 — these are *hard* tasks even for strong models. |
| **MCP-Universe** | [arXiv:2508.14704](https://arxiv.org/abs/2508.14704) | 11 MCP servers, 6 domains (location nav, repo management, financial analysis, 3D design, browser automation, web search) | Execution-based: format compliance, static content matching, dynamic (real-time ground-truth) matching | Authors "open-source our extensible evaluation framework with UI support, enabling researchers and practitioners to seamlessly integrate new agents and MCP servers" — extensibility is a stated design goal, but the abstract-level read here didn't surface the concrete steps. |
| **LiveMCPBench** | [arXiv:2508.01780](https://arxiv.org/abs/2508.01780) | 70 MCP servers, 527 tools, 95 real-world tasks | LLM-as-judge outcome verification (handles multiple valid solution paths); retrieval accuracy specifically — "retrieval errors accounted for nearly half of all failures" | Code and data "publicly available," but the fetched page gives no stated mechanism for adding a new server to the fixed 70-server suite. **Thin source** — read only via the arXiv abstract page, not the full PDF. |
| **MCP-AgentBench** | [arXiv:2509.09734](https://arxiv.org/abs/2509.09734) | 33 servers, 188 tools, 600 queries across 6 complexity categories | "MCP-Eval," described as "a novel outcome-oriented evaluation methodology prioritizing real-world task success" (explicitly *not* tool-selection/argument-correctness as the primary signal) | Not established — the abstract-level fetch didn't surface whether an open-source harness exists or whether a custom server can be added beyond the 33-server testbed. **Thin source**, same caveat as LiveMCPBench. |
| **MCP-Bench** | [arXiv:2508.20453](https://arxiv.org/abs/2508.20453) | 28 MCP servers, 250 tools, 11 domains | Tool use, cross-tool coordination, parameter precision, planning/reasoning over complex real-world tasks | Not independently verified beyond the search summary; listed for completeness since it recurred across multiple queries. |
| **MCPToolBench++** | [arXiv:2508.07575](https://arxiv.org/abs/2508.07575) | "Large-scale AI agent MCP tool use benchmark" | Not independently verified | Listed for completeness; not fetched in depth. |

**Net assessment for this project.** MCPBench is the one benchmark whose
own documentation makes "point it at your own local/custom MCP server"
explicit and low-effort (JSON config, auto tool discovery, stdio launch
via a shell command — exactly how `symbolic serve` would be launched).
Using it against `symbolic serve` would still require writing the task
set (prompts + expected outcomes for the Prolog-session tools) from
scratch — none of these benchmarks know anything about Prolog, sessions,
or this project's four tools — but the harness plumbing (launch server,
enumerate tools, drive an agent, score task completion, measure latency)
would not need to be rebuilt. Compared to promptfoo (§1), these are
heavier to adopt (research-paper harnesses, not maintained products) for
a narrower payoff (task-completion only, mostly) — they're listed here
for completeness and because the maintainer asked specifically about
them, not because any beats trying promptfoo first.

**Calibration note, per the task's instruction to flag thin sources
explicitly:** every benchmark above postdates `research-llm-judge-and-
benchmarking.md`'s September 2026 literature cut and is a 2025-dated
preprint or HuggingFace paper page with no evidence of peer review found
in this pass. Two (LiveMCPBench, MCP-AgentBench) were read only via their
abstract page, not the full PDF, because WebFetch against the arXiv
abstract URL returned a model-generated summary of the abstract text
rather than the paper body — treat the mechanism descriptions above as
indicative, not verbatim-sourced, for those two specifically, the same
caution `lorp-approach.md` already applies to its own paywalled source.

---

## 5. General agent/tool-use benchmarks, MCP-applicable or not

**τ-bench (Sierra)** — [github.com/sierra-research/tau-bench](https://github.com/sierra-research/tau-bench) (superseded by [tau2-bench](https://github.com/sierra-research/tau2-bench)). Simulates a user (LM-played) and an agent across domain-specific environments (airline, retail, now banking) with Python-native tool/API implementations and policy documents; reports `pass^k` across repeated attempts, specifically to measure *consistency*, not just one-shot success. **No MCP integration found** in the fetched README. Tools are "Env"-format Python functions, not MCP servers — pointing τ-bench at `symbolic serve` would mean reimplementing `prolog_query` etc. as a τ-bench `Env`/tool, discarding the actual MCP transport and session-id bridging this project's design doc (§3, §8) is about. Not a fit without that reimplementation.

**BFCL — Berkeley Function-Calling Leaderboard** — [gorilla.cs.berkeley.edu/leaderboard.html](https://gorilla.cs.berkeley.edu/leaderboard.html). Current version is **BFCL v4** (April 2026), which "shifted to a holistic agentic evaluation model" — Agentic (40% weight, multi-step tasks), Multi-Turn (30%, context across dialogue rounds), plus pre-existing categories (enterprise/OSS functions since v2, format-sensitivity for prompt-based models). **Confirmed: no MCP-specific track exists**, in v4 or otherwise. BFCL evaluates a model's raw function-call *output* against a fixed schema offline, not a live MCP session — no transport-level concept at all, so there's nothing to "point at" a local server.

**ToolBench, AgentBench** — not independently re-researched here (out of scope: they're already-known general tool-use/agent benchmarks per the task's framing, and neither surfaced any MCP-specific development in the searches run for §4's benchmarks). Same structural issue as τ-bench applies on priors: both predate MCP and define their own tool-calling format.

**Conclusion for this section:** none of the pre-MCP agent/tool-use benchmarks speak MCP as a transport. Using any of them against `symbolic serve` means writing an adapter that reimplements the four-tool surface in that benchmark's own format — which defeats the purpose of testing the actual MCP session/marshalling boundary (`erlang-mcp-design.md` §3–§4) that is the thing most likely to have MCP-specific bugs (session-id bridging, erlog↔JSON marshalling, the timeout-vs-kill distinction in §8).

---

## 6. Open-source "mcp-eval"-style harnesses

Searched GitHub/PyPI for small, test-case-driven harnesses, as a
complement to promptfoo's general-purpose offering. Two real candidates
surfaced, plus a scattering of early/thin projects.

### 6.1 `lastmile-ai/mcp-eval` — the strongest purpose-built fit found

[github.com/lastmile-ai/mcp-eval](https://github.com/lastmile-ai/mcp-eval), built on `mcp-agent`. Python 3.10+, Apache 2.0, ~39 stars / 9 forks / 163 commits at the time of this research — small but real, actively documented (quickstart, API reference, CLI).

**How a test case looks** (decorator-based, read directly from the README):

```python
@task("Test name")
async def test_example(agent, session):
    response = await agent.generate_str("user prompt")
    await session.assert_that(Expect.tools.was_called("tool_name"))
    await session.assert_that(Expect.content.contains("expected text"))
```

**Mechanism.** It runs the agent in a real session against the real MCP
server (not a mock) and captures the full interaction as **OpenTelemetry
traces**, then asserts over those traces. This is directly the "prompt →
observed tool-call sequence → expected result" shape the task described,
and a more explicit trajectory-assertion vocabulary than promptfoo ships
natively (§1).

**Server compatibility — confirmed against a custom local server.** The
docs state it works with "any MCP server" regardless of implementation
language (Python, TypeScript, Go, Rust, Java listed explicitly) and
connects over stdio using the standard MCP protocol — i.e., exactly how
`symbolic serve` would be launched and connected to, with no requirement
that the server be written in a particular language or use a particular
SDK.

**Assertion/metric surface:** tool call counts, call sequences, success
rates, output matching; content substring/regex matching; performance
gates (response-time limits, iteration counts); **LLM judges** with
rubric-based scoring; and specifically a **"path efficiency"** assertion
that "validates tool sequences and prevents backtracking" — close to a
direct, built-in answer to "did the agent use the right tool at the right
time," expressed as an assertion rather than a learned score.

**What it would take to use against `symbolic serve`:** write Python test
functions, each launching `symbolic serve` as a subprocess (stdio) and
driving a real agent/LLM call against it, then asserting on the
`prolog_start_session → prolog_consult → prolog_query → prolog_end_session`
sequence and on the query result content. No changes to `symbolic serve`
itself are implied by the tool's own requirements; the work is entirely in
writing the test suite.

### 6.2 `modelscope/MCPBench` — already covered in §4

Functions simultaneously as a benchmark and as a generic harness (config +
auto-tool-detection), so it is cross-referenced here rather than
duplicated.

### 6.3 Early/thin projects found, not recommended

- `allenai/mcp-tool-eval` ([github.com/allenai/mcp-tool-eval](https://github.com/allenai/mcp-tool-eval)) — built for AllenAI's own Olmo 3 development against two specific benchmarks (LitQA2, SimpleQA) and specific servers; 4 stars / 1 fork / 10 commits, a research-internal tool, not a general-purpose harness.
- `thebharathkumar`'s `mcp-eval` (surfaced in search, distinct from `lastmile-ai/mcp-eval` despite the identical name) — YAML task format, synthetic Postgres mock server, provider-stub adapters; appears to be a from-scratch, recently-started project per the search summary, not independently verified beyond that summary. Flag as unverified and likely thin.
- `reaatech/agent-eval-harness`, `Vii1nonly/mcp-eval-harness`, `Nishant-Chaudhari-Dev/MCP-Eval`, `CH-JASWANTH-KUMAR/agentic-evolution-harness` (an open feature request for `MCPToolTrajectoryEvaluator`, not a shipped feature) — all surfaced only in search-result titles/snippets, none fetched in depth; listed here only so a future pass knows they exist, not as recommendations.

**Package-registry search.** `mcp-use` was named in the original task
prompt as a thing to check but did not surface as evaluation tooling in
any of the searches run here — it appears (based on the searches'
silence, not a direct check) to be an MCP *client* library, not an eval
harness; treat as unconfirmed rather than ruled out.

---

## 7. Elixir LangChain `Trajectory` — anything new, or BEAM alternatives

**Source:** [`langchain.hexdocs.pm/LangChain.Trajectory.html`](https://langchain.hexdocs.pm/LangChain.Trajectory.html), LangChain for Elixir v0.15.0 (current as of this research).

Confirmed functions: `from_chain/1`, `from_messages/2`, `from_map/1`,
`to_map/1` (extract/serialize a trajectory from an `LLMChain` run or a
message list), `matches?/3` (the comparator — modes `:strict` default/
`:unordered`/`:superset` for call-sequence shape, `:exact` default/
`:subset` for argument matching), `called_before?/4` (relative-ordering
assertion between two named calls), `calls_by_name/2`, `calls_by_turn/1`.
Tool arguments use string keys (`%{"city" => "Paris"}`).

**No MCP-specific extension exists.** This is unchanged from what
`research-llm-judge-and-benchmarking.md` §9/§10.15 already found: general
LangChain tool-call trajectory matching, with no awareness that a tool
call might have come from an MCP session, no session-id concept, and no
MCP transport integration. Searching hex.pm and GitHub for anything newer
or MCP-specific turned up nothing beyond this — no new BEAM package
combining MCP + trajectory scoring was found.

**What this means for `symbolic-tools`:** `Trajectory.matches?/3`'s three
match modes (strict/unordered/superset) remain a reasonable *design
template* to imitate directly in Prolog/erlog rules over structured
trajectory facts (the same point `research-llm-judge-and-benchmarking.md`
§10.15 already made) — but there is nothing here to depend on or wrap;
`Trajectory` is Elixir-struct-shaped with no serialization format this
project's Erlang code would consume without writing a converter anyway.

---

## 8. Honesty check on source quality

Per the task's instruction to flag thin/early sources the way
`lorp-approach.md` flags its paywalled source:

- **LiveMCPBench and MCP-AgentBench** (§4) were read only via WebFetch
  against their arXiv abstract pages, which returned AI-generated
  summaries of the abstract text, not the full paper body. Treat the
  mechanism claims for these two as lower-confidence than the others in
  §4, which were read from GitHub READMEs with concrete code/config
  examples.
- **MCP-Bench and MCPToolBench++** (§4) are listed from search-result
  summaries only; neither was independently fetched and read in this
  pass.
- **`thebharathkumar/mcp-eval`** (§6.3) is named only from a WebSearch
  snippet, is not the same project as `lastmile-ai/mcp-eval`, and was not
  independently verified — do not conflate the two in any later citation
  of this doc.
- **promptfoo's stateful-session/tool-ordering story (§1)** is the one
  place in this document where a WebFetch-summarized page ("the
  documentation does not explicitly detail multi-turn... stateful
  workflows") reported an *absence*, which is weaker evidence than a
  confirmed presence — it may exist in docs pages not fetched in this
  pass, not necessarily evidence of a real gap. Flagged as an open
  question (§9), not a confirmed limitation.
- **The PostHog "any language could POST to the capture endpoint
  directly" claim in §3 is this researcher's inference** from how
  PostHog's SDKs are described (thin wrappers over a REST capture call),
  not a directly documented statement that Erlang integration is
  supported or recommended. PostHog's own docs stop at four named SDKs
  and give no generic/protocol-level integration guide for unsupported
  languages.
- All seven MCP-native benchmarks in §4 are within roughly the last
  twelve months of arXiv/HuggingFace activity (2508.xxxx–2512.xxxx-range
  identifiers) — no source found here predates mid-2025, and none has an
  established, multi-year track record the way BFCL or τ-bench do for
  general tool-calling, or the way promptfoo does as a maintained
  product.

---

## 9. Implications for `symbolic-tools`

Mapped onto the actual four-tool surface
(`prolog_start_session`/`prolog_consult`/`prolog_query`/
`prolog_end_session`, `erlang-mcp-design.md` §3) and the unbuilt
prerequisites `research-llm-judge-and-benchmarking.md` §1.3/§11 already
named (structured `serve.log`, session/request ids, query timing):

1. **The (a)/(b)/(c)/(d) breakdown the maintainer asked for maps cleanly
   onto existing tool vocabulary:**
   - (a) *right tool at the right time* — promptfoo's attached-chat-
     provider mode (§1) with a custom JS assertion over tool-call
     metadata, or `mcp-eval`'s path-efficiency/call-sequence assertions
     (§6.1), or a `tool_order`/`tool_used`-style grader in the same shape
     `claude plugin eval`'s graders and `Trajectory.matches?/3`'s
     `:strict`/`:unordered` modes already use (§7; cross-ref
     `research-llm-judge-and-benchmarking.md` §7, §10.15).
   - (b) *used it correctly* — promptfoo's direct-provider mode scoring a
     single tool call's response shape (§1), `mcp-eval`'s
     `Expect.tools.was_called(name, args)` (§6.1), or MCP Inspector's
     single-call `--tool-arg` check for a quick manual smoke test (§2) —
     e.g., does a `prolog_query` call actually carry a syntactically
     valid goal string, not an empty or malformed one.
   - (c) *useful/correct result* — this is squarely where this project's
     own oracle-first philosophy
     (`research-llm-judge-and-benchmarking.md` §10.5, "oracle over judge
     wherever the fact base can answer") already beats every generic tool
     surveyed here: none of promptfoo, MCP Inspector, PostHog, or the
     MCP-native benchmarks know what a *correct* erlog binding looks like
     for a given goal — only this project's own fact base /
     `check_claim/2`-style oracle can score that, same as it already does
     for extracted `svo/3` terms. promptfoo's `llm-rubric` or `mcp-eval`'s
     LLM judge could wrap that oracle as a custom assertion/grader, but
     neither substitutes for it.
   - (d) *task success* — outcome-level scoring, the thing MCP-AgentBench's
     "MCP-Eval" methodology and LiveMCPBench's LLM-judge explicitly
     prioritize over step-level correctness (§4) — directly analogous to
     this project's own "oracle for outcome, judge for process" split.

2. **`serve.log` is still the actual blocker for anything trajectory-
   shaped, confirmed from the outside.** Every trajectory-capable tool
   found here — `mcp-eval`'s OTEL traces, MCPBench's per-task logs,
   PostHog's `$mcp_tool_call` events, even promptfoo's custom-JS
   tool-call-metadata assertions — depends on a structured, per-call
   record with at minimum a session/request id and timing. `symbolic
   serve`'s current free-text `logger_formatter` lines
   (`research-llm-judge-and-benchmarking.md` §1.3) cannot feed *any* of
   these tools without the same JSON-line rework `logging-and-metrics.md`
   already specifies — this research adds no new prerequisite, it
   independently confirms the one already identified, from a wider set
   of outside tools than before.

3. **The practical near-term path: adopt promptfoo now for (b)/(c)-style
   smoke coverage, keep building the in-house erlog-rules-over-logs
   grader for (a)/(d).** promptfoo needs no server-side changes and can
   start providing value (argument/response-shape checks, an `llm-rubric`
   wrapping manual spot-checks) before `serve.log` is restructured. The
   deeper trajectory question — did the agent pick the four tools in the
   right order with the session id threaded correctly — still routes
   through either `mcp-eval`'s assertion model or, more in line with this
   project's existing direction, erlog rules over `serve.log`-derived
   facts once that prerequisite lands, scored with the same
   `Trajectory.matches?/3`-style strict/unordered/subset logic already
   identified as the right design template (§7).

4. **MCP Inspector is worth adopting narrowly, now, independent of any
   bigger harness decision.** Since it needs zero integration work — it's
   a generic MCP client — `npx @modelcontextprotocol/inspector --cli`
   against `symbolic serve`'s stdio transport gives an immediate,
   zero-build smoke check that `tools/list` and each of the four tools'
   `tools/call` shapes are well-formed, which is a reasonable thing to run
   in CI today, separate from and prior to any trajectory-scoring work.

5. **PostHog is not worth pursuing before the SDK gap is resolved or an
   emitter is hand-built**, and even then it answers a different question
   than (b)/(c) above — it would give latency/failure/adoption telemetry
   (closer to this project's own unbuilt query-timing prerequisite) but
   nothing about argument *correctness* or query *usefulness*, which
   PostHog's docs never claim to infer either. It is also strictly more
   integration effort than promptfoo for a narrower payoff.

6. **No MCP-native benchmark suite in §4, nor τ-bench/BFCL in §5, is worth
   adopting wholesale.** All require writing this project's task set from
   scratch regardless of which one is chosen (none of them know Prolog,
   sessions, or this project's predicates), and MCPBench — the most
   directly pluggable of them — would still only exercise the
   *task-completion* dimension, not (a)/(b) above, with far less
   tooling maturity than promptfoo.

---

## 10. Open questions

- **The single most actionable follow-up:** hands-on, does promptfoo's
  attached-chat-provider MCP mode actually thread a `session_id` returned
  by `prolog_start_session` into the arguments of a subsequent
  `prolog_consult`/`prolog_query` call correctly when a real model drives
  the conversation, and is there a built-in (not hand-written-JS) way to
  assert on tool-call *order*? §1/§8 flag this as unconfirmed from docs
  alone — worth a short spike before investing further in either
  direction.
- Whether `lastmile-ai/mcp-eval`'s OTEL-trace capture works cleanly against
  a BEAM stdio server with no OTEL instrumentation on the server side, or
  whether it only captures what the *client*/agent side emits — the
  fetched README describes capturing "agent-to-server interactions" but
  this research did not verify whether server-side spans are required for
  any of its assertions to work. Needs a hands-on trial, not more reading.
- Whether PostHog's capture-endpoint schema for `$mcp_tool_call` is stable
  and documented well enough to hand-roll an Erlang emitter against
  without a brittle, single-vendor reverse-engineering exercise — §3's
  answer is an inference, not a confirmed integration path.
- Whether any of the seven MCP-native benchmarks in §4 or promptfoo's own
  red-team examples has been run against a *Prolog* or logic-programming
  MCP server specifically (none of their domain lists — filesystem,
  Notion, GitHub, web search, finance, 3D design — suggest they have); if
  none do, this project's tool surface is a genuinely novel benchmarking
  target, not merely an unexercised one.
- Whether BFCL's v4 "Agentic" category (40% weight) will eventually grow
  an MCP-transport mode given how fast the MCP benchmark literature in §4
  is moving — worth a re-check in a few months rather than assuming the
  current "no MCP track" answer is durable.

---

## References

Project:

- [`erlang-mcp-design.md`](erlang-mcp-design.md) — the four-tool surface
  (§3), erlog↔JSON marshalling (§4), known risks (§5), process model and
  timeouts (§8) this note maps findings onto.
- [`research-llm-judge-and-benchmarking.md`](research-llm-judge-and-benchmarking.md) —
  the general eval-framework/LLM-judge survey this note does not
  duplicate; specifically §1.3 (unbuilt `serve.log` trajectory raw
  material), §10 item 15 (process/outcome split, `tool_used`/`tool_order`/
  `file_exists` graders, LangChain `Trajectory` as a BEAM idiom), §11
  (prerequisite fixes), §5/§7 (promptfoo's and `claude plugin eval`'s
  general grading schemas, not re-covered here).
- [`grpo-prolog-tool.md`](grpo-prolog-tool.md), [`lorp-approach.md`](lorp-approach.md) —
  style precedent for this note's structure and for flagging thin/
  paywalled sources explicitly.

External:

- promptfoo MCP provider — [promptfoo.dev/docs/providers/mcp/](https://www.promptfoo.dev/docs/providers/mcp/), [promptfoo.dev/docs/integrations/mcp/](https://www.promptfoo.dev/docs/integrations/mcp/), [promptfoo.dev/docs/red-team/mcp-security-testing/](https://www.promptfoo.dev/docs/red-team/mcp-security-testing/)
- MCP Inspector — official docs: [modelcontextprotocol.io/legacy/tools/inspector](https://modelcontextprotocol.io/legacy/tools/inspector); repo: [github.com/modelcontextprotocol/inspector](https://github.com/modelcontextprotocol/inspector)
- PostHog MCP Analytics — [posthog.com/docs/mcp-analytics](https://posthog.com/docs/mcp-analytics), [posthog.com/docs/mcp-analytics/installation](https://posthog.com/docs/mcp-analytics/installation), [posthog.com/docs/mcp-analytics/custom-servers](https://posthog.com/docs/mcp-analytics/custom-servers)
- MCPBench — [github.com/modelscope/MCPBench](https://github.com/modelscope/MCPBench)
- MCPMark — [github.com/eval-sys/mcpmark](https://github.com/eval-sys/mcpmark); paper page [huggingface.co/papers/2509.24002](https://huggingface.co/papers/2509.24002)
- MCP-Universe — [arXiv:2508.14704](https://arxiv.org/abs/2508.14704)
- LiveMCPBench — [arXiv:2508.01780](https://arxiv.org/abs/2508.01780) (abstract-page read only; §8)
- MCP-AgentBench — [arXiv:2509.09734](https://arxiv.org/abs/2509.09734) (abstract-page read only; §8)
- MCP-Bench — [arXiv:2508.20453](https://arxiv.org/abs/2508.20453) (search-summary only; §8)
- MCPToolBench++ — [arXiv:2508.07575](https://arxiv.org/abs/2508.07575) (search-summary only; §8)
- τ-bench / τ²-bench (Sierra) — [github.com/sierra-research/tau-bench](https://github.com/sierra-research/tau-bench), [github.com/sierra-research/tau2-bench](https://github.com/sierra-research/tau2-bench)
- Berkeley Function-Calling Leaderboard (BFCL) v4 — [gorilla.cs.berkeley.edu/leaderboard.html](https://gorilla.cs.berkeley.edu/leaderboard.html)
- `lastmile-ai/mcp-eval` — [github.com/lastmile-ai/mcp-eval](https://github.com/lastmile-ai/mcp-eval)
- `allenai/mcp-tool-eval` — [github.com/allenai/mcp-tool-eval](https://github.com/allenai/mcp-tool-eval)
- Elixir LangChain `Trajectory` — [langchain.hexdocs.pm/LangChain.Trajectory.html](https://langchain.hexdocs.pm/LangChain.Trajectory.html) (v0.15.0)
- `claude plugin eval` — [code.claude.com/docs/en/plugin-evals](https://code.claude.com/docs/en/plugin-evals) (cited for its grader taxonomy, already covered in full in `research-llm-judge-and-benchmarking.md` §7)
