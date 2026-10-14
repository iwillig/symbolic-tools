Title: Using ask
Slug: ask
Save_as: ask.html
Subtitle: Every question shape the ask tool answers, and a plan it can grade.

<nav class="quicknav" aria-label="On this page">
<a href="#grammar">The question grammar</a>
<a href="#pipeline">How a question becomes an answer</a>
<a href="#examples">Try it</a>
<a href="#plan">Grading a plan</a>
<a href="#refusals">What it refuses to do</a>
</nav>

`ask` answers plain-English questions against a parsed codebase and
returns proven answers — not snippets. This page lists every question
shape it covers, shows how the pipeline works, and grades a real plan
claim by claim.

## The question grammar {: #grammar }

Two tiers sit behind one tool. A deterministic grammar parses the
fixed shapes first; anything it cannot parse falls to a statistical
tier (a rust-bert POS/NER tagger plus a relation mapper), which absorbs
phrasing variation. Both tiers land on the same gate, the same proof,
and the same answer shapes.

| Question | Answer | Proves against |
|---|---|---|
| `does X/N call Y/M?` | yes_no | calls/5 — local, remote, and member (`obj.method`) shapes |
| `does X/N call maps.get/2?` | yes_no | dotted names resolve as method or Erlang remote calls |
| `does X/N call Y?` (no arity) | yes_no | any arity; a known name with several arities is `unverifiable` |
| `is X/N called by Y/M?` | yes_no | passive phrasing, subject and object swapped |
| `which functions call X/N?` / `who` / `what` | enumerate | distinct callers, sorted |
| `how many functions call X/N?` | count | same proof, counted |
| `is X/N defined?` / `does X/N exist?` | yes_no | defines/5 — `false` is an answer, not an error |
| `does X/N use W?` / `does file F use W?` | yes_no | expr_ref/6 — any mention in the function or file |
| `does X/N return W?` | yes_no | a valued return with a same-line mention, or an object key structurally inside it; syntax-level mention, not value flow |
| `does X/N handle W?` | yes_no | branch-level literal equal to W, case-insensitive |
| `where is X/N called?` / `defined?` | sites | `{caller, file, line}` for every site, all call shapes merged |
| `where is ... documented?` / `discussed?` | prose | BM25-ranked evidence over comments, headings, paragraphs |
| `is file F scanned?` | yes_no | a matching fact has that file; inputs accept a basename, relative path suffix, or exact absolute path |
| `is config K defined?` | yes_no | exact dotted key against config_value/4 |

Every identifier is a `Name/Arity` term; dotted paths
(`supabase.auth.verifyOtp/2`) and file names (`JoinAccountModal.ts`)
are accepted where they make sense.

## How a question becomes an answer {: #pipeline }

The pipeline is deliberately narrow, and every stage can refuse
loudly:

1. The grammar parses fixed shapes; a miss falls to the tagger.
2. The tagger turns the sentence into (word, tag) pairs.
3. The mapper turns tag sequences into a bounded relation — the verb
   table is data, and a token whose stem is a known relation verb is
   the main verb whatever tag the model gave it.
4. Entity reconstruction rejoins what the tagger splits
   (`optional` `_` `path` → `optional_path`,
   `supabase` `.` `auth` → `supabase.auth`), with arities read off
   `/N` tails or resolved against defines/5.
5. The gate verifies every entity before proving: unknown subjects are
   `unverifiable`, wrong arities are `wrong_arity`, and a question the
   mapper cannot express is `unrecognized`. Nothing is ever guessed.

## Try it {: #examples }

Parse the configured paths once, then inspect the supported operations:

```sh
symbolic parse
symbolic ask -catalog
```

The catalog describes each operation's inputs, answer shape, evidence, limits,
and example questions. MCP exposes the same catalog as `ask_catalog` (no
arguments) and accepts the same question through `ask`. Output excerpts below
shorten absolute file paths to repository-relative paths; full CLI responses
include scan scope and other fields where applicable.

### Find definitions and call sites

```sh
symbolic ask "where is ask/3 defined?"
symbolic ask "where is ask/3 called?"
```

The first returns a `sites` answer with the exact function and definition
location. The second lists call sites with caller, file, and line. For example,
the definition answer includes `ask/3` at `src/symbolic_ask.erl:120`:

```json
{"type":"sites","answer":[{"function":"ask/3","file":"src/symbolic_ask.erl","line":120}]}
```

### Check a call, including within one file

```sh
symbolic ask "does file src/symbolic_ask.erl call to_bin/1?"
```

This returns `true` with a `calls` witness: `scope_from_metadata/1` calls
`to_bin/1` at line 187. An abbreviated response looks like:

```json
{"type":"yes_no","answer":true,"evidence":[{"predicate":"calls","file":"src/symbolic_ask.erl","line":187,"fact":{"caller":"scope_from_metadata/1","call":{"kind":"local","name":"to_bin","arity":1}}}]}
```

The evidence identifies an extracted call site; it does not prove transitive
calls or runtime behavior. File questions accept a basename, relative path
suffix, or exact absolute path.

### Explore callers and counts

```sh
symbolic ask "how many functions call to_bin/1?"
```

For this scan the answer is `25`, with `evidence_complete: true`:

```json
{"type":"count","answer":25,"evidence_complete":true}
```

The full response also includes source witnesses. Caller-list responses use the
same evidence cap; `evidence_complete` tells you when citations were truncated.

### Read a negative answer carefully

```sh
symbolic ask "does ask/3 call to_bin/1?"
```

This returns `false` with an empty evidence array and a complete-scan scope:

```json
{"type":"yes_no","answer":false,"evidence":[]}
```

It means no matching direct-call fact was found in that scope—not that the
functions are unrelated at runtime. An incomplete scan can produce `unknown`
instead. A question outside ASK's supported relations or with unresolved names
can be `unrecognized` or `unverifiable`, rather than `false`.

### Find relevant documentation

```sh
symbolic ask "where is the CLI release documented?"
```

This returns ranked prose evidence. The first hits in this scan are the
`docs/cli-erlang.md` heading at line 1 and a passage in `docs/releasing.md` at
line 128. The excerpt shows the top two hits:

```json
{"type":"prose","evidence":[{"file":"docs/cli-erlang.md","kind":"heading","line":1,"score":13.40},{"file":"docs/releasing.md","kind":"paragraph","line":128,"score":12.27}]}
```

Higher scores rank as more relevant. Prose search is discovery, not a truth
verdict: no matching passages do not prove a claim false.

MCP calls use the same questions, for example `ask` with
`{"question":"does file src/symbolic_ask.erl call to_bin/1?"}`. MCP wraps the
shared answer under `ok`; the CLI prints the answer directly.

## Grading a plan {: #plan }

Here is a plan for this project, and the questions that grade it.
The plan is real in shape and imaginary in status: the defect it
describes is live in the tree today, which is exactly what makes the
before-state checkable.

> **Give the query tool a friendly missing-goal error**
>
> **Context.** An agent calls `query` without `goal`. `handle_query`
> reads the parameter with an unguarded `maps:get`, the throw lands in
> the catch-all, and the agent sees `caught error: {badkey,...}` —
> while every other failure (unknown predicate, unknown path, timeout)
> gets a tailored, repairable message.
>
> **Changes.** `handle_query` reads `goal` with a default and routes
> the failure through the existing friendly-error path as `goal is
> required`. A test pins the message.
>
> **Verification.** The claims below run against the parsed repository
> before the fix. Claim 6 flips to true after it.

The claims below were answered by `ask` against this repository's fact base.
For readability, their JSON snippets show the key answer fields; full responses
also include evidence and scan scope where applicable:

**1. The defect is where the plan says it is.**

```
"does handle_query/1 call maps.get/2?"
```

```json
{ "answer": true, "type": "yes_no" }
```

The unguarded `maps:get` sits inside `handle_query/1`, exactly where
the plan's context claims.

**2. The surrounding machinery matches the plan's description.**

```
"does handle_query/1 call limit_of/1?"
"does render_query/2 call error_str/1?"
```

```json
{ "answer": true, "type": "yes_no" }
{ "answer": true, "type": "yes_no" }
```

The limit parsing and the friendly-error renderer the plan wants to
reuse both exist and are already wired.

**3. The blast radius is what the plan assumes.**

```
"which functions call caught_str/3?"
```

```json
{
  "answer": [
    "handle_ask/1",
    "handle_overview/1",
    "handle_parse/1",
    "handle_query/1"
  ],
  "type": "enumerate"
}
```

All four tool handlers share the one catch-all — fixing the message in
`handle_query` changes nothing for the other three.

**4. The friendly paths that already exist are findable, with
locations.**

```
"where is error_str/1 called?"
```

```json
{
  "answer": [
    { "caller": "handle_overview/1", "file": "src/symbolic_serve.erl", "line": 436 },
    { "caller": "parse_error_str/1", "file": "src/symbolic_serve.erl", "line": 539 },
    { "caller": "render_ask/1",      "file": "src/symbolic_serve.erl", "line": 408 },
    { "caller": "render_query/2",    "file": "src/symbolic_serve.erl", "line": 422 }
  ],
  "type": "sites"
}
```

The plan's fix routes through this exact seam.

**5. The new helper does not exist yet — provably.**

```
"does handle_query/1 call goal_required/1?"
"is file symbolic_serve.erl scanned?"
```

```json
{ "answer": false, "type": "yes_no" }
{ "answer": true, "type": "yes_no" }
```

`false` is the closed-world answer for this fact base, and the scan
check confirms the base is the right one. After the fix, the first
claim flips to true — the flip is the verification.

**6. Where the design rationale lives, ranked by relevance rather than
string match.**

```
"where is the arity gate documented?"
```

```json
{
  "evidence": [
    { "file": "src/symbolic_ask.erl", "kind": "comment", "line": 12, "score": 11.21 },
    { "file": "src/symbolic_ask.erl", "kind": "comment", "line": 1069, "score": 8.19 },
    { "file": "docs/research-questions-to-prolog.md", "kind": "paragraph", "line": 122, "score": 7.94 }
  ],
  "type": "prose"
}
```

No hit contains the literal phrase "arity gate" — they rank by
relevance across the whole corpus.

Eight questions, one plan: the defect located, the machinery
confirmed, the blast radius bounded, the seam named with file and line,
the new helper proven absent, and the documentation surfaced. All of it
ran against the fact base — no model wrote these answers.

## What it refuses to do {: #refusals }

ASK keeps distinct outcomes distinct:

- `unrecognized` — the phrasing is outside the grammar and the mapper
  will not invent a relation.
- `unverifiable` — the question parses but names something the fact
  base cannot resolve (`no_such_function`, `wrong_arity`,
  `ambiguous_arity`, `no_such_file`). The asker repairs the question.
- `unknown` — an absence-based answer cannot be trusted because scan
  metadata is missing or extraction failed.
- `false` / `0` / `[]` — answers, not errors. The proof ran and found no
  matching fact in the complete indexed scope; positive answers carry
  source witnesses.

Multi-word synonyms ("the auth hook") are the known open gap: the
plans that cover this are honest about it, and the gate reports them
`unverifiable` rather than guessing.
