# Design: Reviewing LLM-Generated Content with the Fact Base

This document ties together three separate research threads from the same
session into one throughline: could this project's own fact base — the
same one that answers "what calls this function" — also review content an
LLM produces *about* a codebase, rather than only answering questions
about the codebase itself? A design/research document only — nothing here
beyond §1's `stale_doc_example/4` is implemented.

**Recommendation up front:**

- **The core technique already exists and already works.**
  `stale_doc_example/4` (`.symbolic/rules.pl`) parses a doc's own fenced
  code samples as if they were real source, then checks whether the
  functions they show still exist. Run live against this project's own
  `docs/` + `src/` (§1): **26 real hits**, including illustrative
  pseudocode this project's own earlier design-doc work wrote by hand.
  Everything below is a generalization of that one proven idea, not a
  different mechanism.
- **Structural claims (does X exist, does X call Y, is X documented) are
  mechanically checkable today or with a small addition. Behavioral
  claims (does X do what was claimed, is this actually a fix) are not,
  and never will be from syntax facts alone** — the same ceiling this
  project has operated under since `lorp-approach.md`/
  `grpo-prolog-tool.md`, now specifically relevant to reviewing LLM
  prose rather than answering questions about code.
- **Extracting a checkable claim from open-ended LLM prose is better done
  by an LLM than by a grammar.** A DCG (`nlp-tooling.md` §2) only covers
  bounded, anticipated vocabulary — confirmed still true, and confirmed
  DCGs themselves only translate at `consult` time, not at `assertz`
  time (§3, a real operational detail neither `nlp-tooling.md` nor
  `curt-approach.md` mentions). An LLM doing subject/verb/object
  extraction sidesteps the vocabulary wall entirely — see §3 for why,
  and §5 for the new risk this specific choice introduces.
- **Running that extraction model in-process is real, precedented, and
  not free.** `erllama` (`github.com/benoitc/erllama`) is a genuine
  native-Erlang runtime for `llama.cpp`, the same "one small C library,
  one thin NIF" shape as `symbolic_ts`. Naming correction, verified
  directly against both repos rather than repeating an earlier
  assumption: `barrel_inference` (`barrel-platform/barrel_inference`) is
  now **archived** (its own description: "the runtime continues as
  erllama") — the reverse of what this document said before. `erllama`'s
  public API still doesn't expose `llama.cpp`'s own grammar-constrained
  decoding (confirmed by grepping its raw README directly), but it does
  expose OpenAI-style tool calling with schema-typed, pre-parsed
  arguments — a real third path neither this document nor the earlier
  sizing discussion had found yet. See §4 for what's actually available
  today versus what would need new work.
- **Model size changes which of §4's three paths is the default, not
  whether the design works.** At 135M–3B, grammar-constrained decoding
  is load-bearing — a model that small can't reliably emit well-formed
  output on its own, so an `erllama` NIF extension for real grammar
  support is a prerequisite. At 8B and up — and especially a
  ~30–35B-total, ~3B-active MoE (the `Qwen3-30B-A3B` shape), which real
  hardware here runs at ~60 tok/s — the tool-calling path (§4) is
  credible enough to prototype *first*, no new C code
  required. See §4.1.
- **The same technique reviews an agent's plan/action sequence, not only
  its prose** — a `gen_statem`-shaped observer checking a tool-call
  trajectory against the protocol `.pi/SYSTEM.md` already documents is
  the identical "check a claim against real structure" idea, applied to
  actions instead of sentences. See §6.

## 1. The core technique, already proven

`.symbolic/rules.pl`:

```prolog
stale_doc_example(Fun, Arity, DocFile, Line) :-
    example_defines(Fun, Arity, _Params, DocFile, Line),
    \+ defines(Fun, Arity, _, _, _).
```

`example_defines/5` re-parses a fenced code block's own contents as real
source (`ts_extract_markdown.erl`); `stale_doc_example/4` checks whether
what it shows is still real. Run live, parsing `src` + `test` + `docs`
together (via a temporary widen of `.symbolic/config.json`'s `paths`,
reverted after):

```prolog
?- findall(Fun/Arity-DocFile-Line, stale_doc_example(Fun, Arity, DocFile, Line), L), length(L, N).
N = 26
```

The hits include `idle/3`, `proving/3`, `callback_mode/0` —
`docs/gen-statem-design.md`'s own illustrative `gen_statem` sketch,
written earlier the same session, never meant to compile — correctly
flagged as "shown in an example, not real code," without being told
which file to look at. This is the whole idea in miniature: **parse the
codebase and the LLM's own output into one fact base, then write a rule
that checks a claim made in the output against the structural facts
extracted from the code.** Every section below is that same move,
generalized to a different *kind* of claim.

## 2. What's checkable, by claim shape

| Claim shape | Mechanism | Status |
|---|---|---|
| "This example defines/calls X" | `stale_doc_example/4` (exists); `stale_doc_call/4`, the `calls/5` mirror, one line, doesn't exist yet | **Proven, live** |
| "X was removed / no longer exists" | `\+ defines(X, _, _, _, _)` | Trivial |
| "All public functions are documented" | `undocumented/4` against `export/4` | Exists |
| A generated reference table claims `Function=foo, Arity=2` | Cross-check each `table_cell/6` row against `defines/5` | Needs a binary→atom bridge (§2.1) |
| "See the Configuration section" (reference-style link) | `link_definition/5` against `heading/4` | Partial — reference-style only, inline `[text](url)` still blocked on the undone inline grammar (`tree-sitter-markdown.md`) |
| Free-prose claims ("the retry logic lives in `backoff/2`") | Needs extraction first — see §3 | Not directly checkable |
| "This is a bug fix" / "this improves performance" / "this is correct now" | — | **Not checkable, ever, from syntax facts** — see §5 |

### 2.1 A real, verified gap: no binary→atom bridge

Cross-checking a markdown table's claimed function name (a binary,
`table_cell/6`) against `defines/5`'s real `Function` (an atom) needs a
type bridge that doesn't exist. Confirmed directly against `erlog`'s own
source, not assumed: `erlog_bips.erl`'s `atom_codes/2` hard-requires
`is_atom` on its first argument and raises `type_error(atom, ...)`
otherwise — there is no built-in path from a binary to an atom or a code
list anywhere in `erlog`. Closing it is the same technique already used
twice (`sub_atom_5`/`sub_text_5`, `src/symbolic_prolog_lib.erl`) — a
small native `add_compiled_proc/4` addition, no fork — but it doesn't
exist yet.

## 3. Extracting a claim from free prose

### 3.1 A DCG — real, but only for bounded vocabulary

**Now built, not just sketched**: `symbolic extract "<sentence>"`
(`src/symbolic_extract.erl`, grammar in `priv/nlp_grammar.pl`, tests in
`test/symbolic_extract_tests.erl`, built TDD — tests written and
confirmed failing before any implementation existed). It tokenizes a
sentence into Prolog list-literal text, consults the bundled bounded
grammar into a fresh `prolog_session`, and attempts
`phrase(sentence(Fact), Tokens)`. It covers exactly the two claim shapes
§3.2's `check_claim/1` sketch below already knows how to check —
`calls` and `removed` — deliberately no further, and reports a sentence
outside that vocabulary as `unrecognized` rather than guessing. Smoke
tested against the real released binary:

```sh
$ symbolic extract "foo/2 calls bar/1"
["svo",["/","foo",2],"calls",["/","bar",1]]
$ symbolic extract "foo/2 was removed"
["svo",["/","foo",2],"removed","none"]
$ symbolic extract "foo/2 improves performance"
Unrecognized.
```

`erlog` genuinely ships DCGs (`erlog_lib_dcg.erl`), and `phrase/2` works.
Verified live:

```prolog
sentence(calls_claim(A,B)) --> [A], [calls], [B].

?- phrase(sentence(Fact), [foo, calls, bar]).
Fact = calls_claim(foo, bar).
```

But this only worked once the rule was loaded via `consult` (the MCP
`parse` tool's `rules` parameter, pointed at a scratch file) — a first
attempt to `assertz((sentence(...) --> ...))` directly inside a query
*silently succeeded* without actually registering `sentence/3`; `phrase`
then failed with `existence_error`. DCG translation (`-->` into a real
difference-list clause) happens at consult time, not at `assertz` time.
Not a blocker — it fits exactly how this project already works
(`.symbolic/rules.pl` is consulted, not built dynamically) — but it does
mean a claim-grammar has to live in a committed rules file, never
something built on the fly from an LLM-supplied grammar mid-session.
Worth adding to `curt-approach.md` §5, which asks "does erlog support
assert/retract" as an open question without this DCG-specific nuance.

The real limit is unchanged from `nlp-tooling.md`'s own stated scope:
a grammar has to anticipate every phrasing. "Calls," "delegates to," and
"is handled by" mean the same thing and parse completely differently —
genuinely open-vocabulary prose is still the LLM's job, not a grammar's,
exactly as already documented.

### 3.2 An LLM doing subject/verb/object extraction — the better fit

If an LLM extracts the claim's structure instead of a grammar, the
open-vocabulary wall disappears: the LLM absorbs the phrasing variation,
and what reaches Prolog is already a small, fixed vocabulary of
relations, regardless of the original wording. The LLM can emit the term
directly in Prolog-readable syntax — no tokenizer, no DCG, no bridge
predicate needed for the extraction step itself, since `erlog_io:
read_string/1` already reads any goal string.

**Who does the extraction is an architectural fork, and it matters which
side gets picked:**

- **The calling agent does it inline**, as part of using the tool —
  zero new infrastructure. This is not a new capability; it's
  `lorp-approach.md`/`grpo-prolog-tool.md`'s existing premise ("LLM
  translates natural language into a goal, Prolog proves it"), pointed
  at a documentation sentence instead of a user question. The only real
  work is a workflow/prompt addition, not code.
- **A dedicated in-process model does it unattended** — real new work,
  covered in §4.

A small dispatch library is the concrete, buildable piece either way —
a normalized `svo(Subject, Verb, Object)` term routed to the right real
check, so extraction logic and validation logic stay separate:

```prolog
check_claim(svo(F/A, calls, G/B), true)  :- calls(F, A, local(G, B), _, _), !.
check_claim(svo(F/A, calls, G/B), false) :- \+ calls(F, A, local(G, B), _, _), !.
check_claim(svo(F, calls, G), unverifiable) :-   % arity elided by the prose
    \+ (F = _/_), !.
check_claim(svo(F/A, removed, _), true)  :- \+ defines(F, A, _, _, _), !.
check_claim(svo(F/A, removed, _), false) :- defines(F, A, _, _, _), !.
check_claim(_, unverifiable).            % no relation we know how to check
```

Three-valued on purpose — `true`/`false`/`unverifiable`, not just
pass/fail. This mirrors a distinction this project already insists on
everywhere else (`SYSTEM.md`'s `<errors>`: `count:0` and an error are not
the same answer). A verb with no matching clause ("improves," "is
elegant") must come back `unverifiable`, loudly — silently returning
`false` for a claim nobody built a check for would be indistinguishable
from a real defect.

## 4. Running the extraction model in-process

**Naming correction, verified directly via `gh repo view` on both repos
rather than repeated from an earlier assumption**: `barrel-platform/
barrel_inference` is now archived (pushed 2026-08-23; its own
description: "Archived. The runtime continues as erllama"). The
maintained project is `erllama` (`github.com/benoitc/erllama`, active,
Hex `erllama ~> 0.11`, requires Erlang/OTP 28+, rebar3 3.25+, a C++17
toolchain and cmake ≥3.20 — the first compile builds the vendored
`llama.cpp`, no separate system install needed). Same shape as before:
supervised model processes, an OpenAI-shaped completion API, GGUF models
only, a byte-exact KV cache for repeated prompt prefixes — the same "one
small C library, one thin NIF" precedent `symbolic_ts` already
established for tree-sitter.

`llama.cpp` itself has real, mature GBNF grammar-constrained decoding —
a formal grammar restricts the model's output token-by-token, so it's
*structurally incapable* of emitting anything outside the grammar.
Exactly what you'd want: force the model to only ever emit something
shaped like `svo(foo/2, calls, bar/1).`, never a stray sentence
fragment.

**Checked directly against `erllama`'s raw README text (grepped, not
summarized) rather than assumed**: it still doesn't expose this.
`erllama:complete/2,3` takes `response_tokens` and `parent_key` — no
`grammar`, `json_schema`, or `response_format` sampling-level option
anywhere. The underlying C library can do it; the Erlang wrapper doesn't
let a caller reach it today.

**But `erllama:chat/3` has OpenAI-style tool calling, and that changes
which path is best — found this session, not in the earlier research**:

```erlang
Tools = [#{name => <<"extract_svo">>,
           description => <<"Extract a subject-verb-object code claim">>,
           parameters => #{type => object,
                            properties => #{
                                subject => #{type => string},
                                verb => #{type => string,
                                           'enum' => [<<"calls">>, <<"removed">>]},
                                object => #{type => string}},
                            required => [subject, verb, object]}}],
{ok, #{message := #{tool_calls := Calls}}} =
    erllama:chat(Model, [#{role => user, content => Sentence}], #{tools => Tools}).
%% Calls = [#{name => <<"extract_svo">>,
%%           arguments => #{<<"subject">> => <<"foo/2">>, <<"verb">> => <<"calls">>,
%%                          <<"object">> => <<"bar/1">>}, id => _}]
```

`arguments` comes back as an already-decoded Erlang map, schema-typed by
the tool definition — no re-parsing free text as Prolog syntax and
hoping, and no dependence on the model choosing to emit exactly
`svo(...).` and nothing else. Three real paths now, not two:

- **Tool calling (`chat/3` + `tools`), the one to prototype first**: no
  new C code, structured output typed by the JSON schema rather than
  free text, and a closed `enum` on `verb` keeps the relation vocabulary
  as narrow as `check_claim/1` itself, by construction.
- **Direct prompt + parse (`complete/2,3` + `erlog_io:read_string/1`)**:
  still available, still zero new C code, but strictly worse than tool
  calling now that tool calling exists — kept only as a fallback for a
  model/backend that doesn't support tool calling at all.
- **Grammar-constrained, a real guarantee, real additional work**:
  extend `erllama`'s own NIF to pass a grammar through to `llama.cpp`'s
  real sampling API — the same *kind* of small, mechanical NIF addition
  as `node_end_point/1` (`c_src/symbolic_ts_nif.c`), except touching
  another project's C/NIF boundary, so a fork or an upstream
  contribution, not a self-contained change.

**What none of these three solve, even the best one**: syntactic/schema
validity, never semantic fidelity. The model can fill `extract_svo`'s
schema flawlessly — a well-typed, perfectly valid tool call — and still
have transcribed the sentence wrong, e.g. naming the wrong callee. The
exact "true claim, mis-extracted" risk in §5, completely unaffected by
how well-formed the output is.

**A genuine, no-model-needed testing win, found alongside the above**:
`erllama_model_stub` is an official deterministic backend — no NIF, no
GGUF — for exercising the whole API in unit tests
(`backend => erllama_model_stub`). This is the answer to "how do you TDD
something that calls an LLM": integration-test the real marshaling code
against the stub in every normal test run, and reserve an actual GGUF
model for a small number of separately-gated accuracy checks (§4.2).

**Costs genuinely new to this project, worth being honest about:**

- *Resource and failure footprint.* Every other dependency here is a
  compiled artifact that's either present or not. A model is weights on
  disk, RAM for inference, a load step that can OOM or simply be
  missing — a new category of failure, not a bigger version of an old
  one.
- *Determinism.* A tree-sitter parse and a DCG parse are both exactly
  reproducible; an LLM's output varies run to run unless temperature is
  pinned to 0 *and* the exact model/quantization is pinned too.
- *Maturity.* `erllama` is pre-1.0 (Hex `~> 0.11`) but active and
  currently maintained — a healthier footing than the "pre-release"
  label this document previously repeated for the now-archived
  `barrel_inference`, though still less established than `erlog`/`jsx`/
  `erlmcp`.

**Sizing, the very-small end**: `grpo-prolog-tool.md`'s own cited
research (a 3B model, RL-trained specifically for Prolog-tool-use,
beating supervised fine-tuning by a wide margin) is a reasonable anchor
— and this task is narrower than general tool-use (one sentence in, one
`svo/3` term out), so a 1–3B instruct model, GGUF-quantized, CPU-only,
is a plausible starting point. At this size, grammar-constrained
decoding (the second bullet below) is not optional — a model this small
is not reliable enough to trust with free-form output, closed
vocabulary or not. Unverified until actually tried against real
sentences from this repo's own docs.

### 4.1 A bigger model changes which path is the default

The two paths above assume a model too weak to trust unconstrained.
That assumption doesn't hold once the model is capable enough to follow
"extract subject/verb/object, emit `svo(foo/2, calls, bar/1).`" reliably
from a prompt alone — real for an 8B instruct model, and more so for a
mixture-of-experts model in the ~30–35B-total, ~3B-active shape
(`Qwen3-30B-A3B` is the concrete precedent; real local hardware here
measured ~60 tok/s on a model of that shape). At that size:

- **The tool-calling path (§4, first bullet) is the one to prototype
  first, not a stopgap while waiting on a NIF extension.** A capable
  instruct model is genuinely good at filling a typed JSON-schema tool
  call zero- or few-shot — Qwen3-class models specifically are trained
  for exactly this — and a malformed/missing tool call is still a loud,
  distinct signal, same shape as before. This reorders §7's suggested
  path: extending `erllama` for real grammar support becomes a later
  hardening step, not a prerequisite.
- **Throughput is not the constraint.** A `svo/3` term is ~15–30 output
  tokens; at 60 tok/s that's well under a second per claim, including
  prefill — fast enough to run inline, per-claim, in an interactive
  review loop rather than batched offline.
- **MoE buys inference speed, not memory.** A ~30–35B-total MoE model
  still keeps every expert resident in RAM/VRAM — footprint tracks the
  *total* parameter count (~17–20GB at Q4), not the ~3B active count.
  This is no longer "very small" in the footprint sense the original
  framing meant; it's a real model on real hardware that happens to
  infer at small-model speed.
- **GGUF/MoE support maturity is a fact to check, not assume.**
  `erllama` wraps a specific vendored `llama.cpp`; whether that vendored
  version correctly supports whatever exact Qwen3-MoE GGUF is in hand is
  a one-completion smoke test away from verified, not something to infer
  from the dense-model precedent above.
- **The semantic-fidelity ceiling (§5) is completely unchanged.** A
  bigger model is far less likely to emit malformed syntax, but it can
  still confidently mis-transcribe a true sentence into a wrong `svo/3`
  term. Model size buys syntactic reliability, never the semantic
  guarantee — `check_claim/1` stays three-valued and the raw sentence
  stays attached to every result regardless of which model produced the
  term.

### 4.2 Implementation plan: `symbolic_extract_llm`

Same `svo(Subject, Verb, Object)` output shape as the already-built,
bounded-vocabulary `symbolic_extract` (§3.1) — a different module, same
contract, so a downstream `check_claim/1` never needs to know which tier
produced a given claim.

- **Phase 0 — dependency + build, no feature code.** Add
  `{erllama, "~> 0.11"}` to `rebar.config`. Checkpoint: `rebar3 compile`
  succeeds and `application:ensure_all_started(erllama)` returns
  `{ok, _}`. This is a new *build*-time dependency (C++17, cmake ≥3.20),
  worth its own line in `docs/cli-erlang.md` alongside the existing
  tree-sitter NIF build notes — isolate "does the vendored `llama.cpp`
  build here" before anything depends on it.
- **Phase 1 — done.** `src/symbolic_extract_llm.erl`, halt-free
  `run_result/2` core, same output shape as
  `symbolic_extract:run_result/1`. One tool schema, `extract_svo`, with
  a closed `enum` on `verb` matching `check_claim/1`'s own known
  relations, `object` not required (a `removed` claim has none). Built
  TDD, tests written and confirmed failing first
  (`test/symbolic_extract_llm_tests.erl`).

  **A real spike overturned the original plan before any test was
  written**: `erllama_model_stub` cannot exercise `chat/3` + tools at
  all — verified directly, not assumed. `erllama_model.erl`'s
  `do_chat_apply/2` gates the whole chat path on the backend module
  exporting `get_model_ref/1`, which only the real llama.cpp backend
  does; against the stub, `erllama:chat/3` deterministically returns
  `{error, chat_not_supported}`, every time, regardless of input. So the
  test suite ended up in three tiers instead of one: pure unit tests for
  the decoding helpers (`parse_ident/1`, `parse_verb/1`, `decode_call/1`
  — no erllama call at all); one real integration test against the real
  stub, which can only ever reach the `chat_not_supported` branch but
  does exercise the actual `load_model`/`chat`/`unload` call path
  end-to-end; and `meck`-mocked `erllama:chat/3` for every other response
  shape (well-formed call, declined call, backend error) — the same
  "mock the impure boundary" pattern `symbolic_cli_tests.erl` already
  uses for `symbolic_query`/`symbolic_parse`/`symbolic_serve`. 15/15
  passing, 453/453 across the full suite.
- **Phase 2 — a real model, gated and manual.** Model acquisition is
  documented (a new file, e.g. `docs/symbolic-extract-llm-setup.md`),
  never automated or committed — multi-gigabyte GGUF weights are a
  different scale from anything Homebrew's formula currently vendors. A
  small number of real-model tests gated behind an env var (e.g.
  `SYMBOLIC_LLM_MODEL_PATH`), skipped by default, run explicitly — these
  are accuracy checks against real sentences from this repo's own
  docs/PRs (the `stale_doc_example/4` dogfooding pattern again), not
  plumbing-correctness checks, which Phase 1 already owns.
- **Phase 3 — fallback chaining.** `symbolic extract` tries the bounded
  DCG (§3.1) first — free, deterministic, always available. Only on
  `unrecognized`, and only when a model path is configured (an optional
  `--model <path>` flag), fall through to `symbolic_extract_llm`. Exactly
  the two-tier design §3.1 already states in words, now actual fallback
  logic.
- **What no phase changes**: the semantic-fidelity ceiling (§5) and the
  three-valued `check_claim/1` requirement are unaffected by any of this
  — a schema-typed tool call is a syntax guarantee, never a truth one.

## 5. The ceiling that doesn't move: structural truth only

Everything above checks *does X exist, does X call Y, does X have this
shape* — never *does X do what was claimed*. "This handles retries,"
"this fixes the race condition," "this is O(n) now" are not checkable
against syntax facts at all, full stop. Not a gap to close later — the
same boundary this whole project has operated inside since
`lorp-approach.md`/`grpo-prolog-tool.md`: logical/structural
correctness, not program correctness. A review built on this catches
"you described a function that isn't real" with total confidence, and
has nothing to say about "you described what a real function does,
incorrectly." Silence there could read as a pass if that boundary isn't
communicated to whoever consumes the review.

A second, narrower risk specific to §3.2's design choice: every checked
claim now depends on *two* things being right, not one — the underlying
code claim, and the LLM's own transcription of it into `svo/3`. A true
claim, mis-extracted, produces a term that's wrong even though the
sentence wasn't, and `check_claim/1` will correctly report `false`
against real facts — which reads as "the doc is wrong" when the
*extractor* was wrong. Keeping the raw sentence attached to every result
alongside the extracted term (never just the verdict) is what makes that
traceable rather than silent.

## 6. The same technique, applied to plans and actions, not only prose

Nothing about "parse a claim, check it against real structure" is
specific to markdown. `docs/gen-statem-design.md` §8 already sketches
the same move applied to an agent's own tool-call trajectory: a
session-scoped observer tracking which of `.pi/SYSTEM.md`'s documented
workflow states a session is actually in, from the sequence of
`parse`/`query`/`overview` calls `symbolic_serve.erl` already logs —
flagging a transition the workflow doesn't allow (e.g., re-running an
unchanged goal after a `query timed out` event) mechanically instead of
only by a reviewer reading a transcript by hand. A plan or an action
sequence is exactly as "checkable" as a doc's claim once it's expressed
as a structured term — the extraction question (who turns a step into a
checkable term: the DCG, the agent, or a dedicated model) is the
identical §3 question, not a new one.

## 7. Suggested path

0. ~~Build the bounded-vocabulary DCG extractor as a CLI tool.~~ **Done**
   — `symbolic extract`, §3.1.
1. Build `stale_doc_call/4` — one line, the same proven pattern as
   `stale_doc_example/4`, no new capability required.
2. Build the binary→atom bridge (§2.1), unlocking table-cell
   cross-checks against `table_cell/6`.
3. Wire §3.2's `check_claim/1` dispatch to `symbolic extract`'s own
   output — the extraction half is done; only the checking half (proving
   the resulting `svo/3` term against `calls/5`/`defines/5`) remains.
4. In parallel with, not strictly after, step 3: build
   `symbolic_extract_llm` per §4.2's phased plan — Phase 0 (dependency +
   build), Phase 1 (TDD against `erllama_model_stub`, no model needed),
   Phase 2 (a real model, gated, manual), Phase 3 (fallback chaining onto
   `symbolic extract`). Needs no new C code through Phase 2, so it
   doesn't have to wait behind anything.
5. Only revisit extending `erllama` for real grammar-constrained decoding
   once §4.2's Phase 2 is running and its failure rate is an actual
   observed problem worth hardening against — not a prerequisite to
   starting, and most load-bearing at the very-small (135M–3B) end of
   §4.1's sizing range, where tool calling alone is not reliable enough.

## References

- [`nlp-tooling.md`](nlp-tooling.md) — the DCG-as-primary-answer
  recommendation §3.1 reverifies and adds the consult-vs-assertz nuance
  to.
- [`curt-approach.md`](curt-approach.md) — the fuller DCG/Curt
  architecture; §5's open question about `assert`/`retract` is answered
  more precisely by this document's §3.1 (works for facts within one
  query; DCG rules specifically need `consult`; nothing survives across
  separate MCP calls either way, per `SYSTEM.md`'s `<dialect>` trap 4).
- [`tree-sitter-markdown.md`](tree-sitter-markdown.md) — `example_defines/5`,
  `table_cell/6`, and the still-undone inline-grammar work §2's table
  depends on.
- [`erlog-missing-builtins.md`](erlog-missing-builtins.md) — `sub_atom/5`/
  `sub_text/5`, the precedent §2.1's proposed bridge predicate would
  follow.
- [`lorp-approach.md`](lorp-approach.md) ·
  [`grpo-prolog-tool.md`](grpo-prolog-tool.md) — the
  logical-not-program-correctness ceiling §5 restates for this specific
  use case, and the model-sizing precedent §4 anchors on.
- [`gen-statem-design.md`](gen-statem-design.md) §8 — the plan/action
  observer §6 generalizes to.
- [`benoitc/erllama`](https://github.com/benoitc/erllama) — verified
  directly (`gh repo view`, raw README grep): the maintained native
  Erlang runtime for `llama.cpp`, GGUF only, no grammar-constrained
  decoding, but real OpenAI-style tool calling (`chat/3` + `tools`) and
  an official no-model test backend (`erllama_model_stub`). Supersedes
  `barrel-platform/barrel_inference`, now archived.
- [`ggml-org/llama.cpp` grammars](https://github.com/ggml-org/llama.cpp/blob/master/grammars/README.md)
  — GBNF grammar-constrained decoding, real and current in the
  underlying C library.
