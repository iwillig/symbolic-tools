# Worked Examples: Guiding an LLM Agent with the Fact Base

`readme.md` explains *why* a Prolog fact base beats free-text reasoning
for a codebase, and shows a few CLI query examples. This document works
through several more, framed as an agent actually **using** the fact
base to do a task — not just running a query in isolation — over the
same MCP interface `symbolic serve` exposes, not just the CLI.

Every fact, query, and response below is real, captured output from
running the built `symbolic` release against a real small codebase (a
`payments.ts` module and a `guide.md` doc that documents it) — not
hand-written. See `docs/erlang-mcp-design.md` for the MCP server design
these tool calls are described against, and `readme.md`'s Examples
section for the CLI-only versions of this same idea.

## The example codebase

```ts
// Charges a card for the given amount, delegating to the Stripe API.
function charge(cardToken: string, amountCents: number): void {
  validateCard(cardToken);
  stripeClient.createCharge(cardToken, amountCents);
}

// Refunds a previous charge by its Stripe charge id.
function refund(chargeId: string, amountCents: number): void {
  stripeClient.createRefund(chargeId, amountCents);
}

function validateCard(cardToken: string): boolean {
  return cardToken.length > 0;
}
```

````md
# Payments Module

`charge` takes a card token and an amount in cents:

```ts
function charge(cardToken: string, amountCents: number): void {
  stripeClient.createCharge(cardToken, amountCents);
}
```

Call `authorize` first if you need a separate authorization step
before charging the card:

```ts
function authorize(cardToken: string, amountCents: number): void {
  stripeClient.createAuthorization(cardToken, amountCents);
}
```
````

`authorize` is shown in the doc but was never actually added to
`payments.ts` — planned, then forgotten, exactly the kind of drift that
accumulates silently in real docs. Nothing about that is obvious from
reading either file in isolation; it only shows up once both are facts
in the same base.

```sh
$ symbolic parse . -db facts.dets
["code_block","guide.md","ts",5]
["code_block","guide.md","ts",14]
["comment","payments.ts",1,"Charges a card for the given amount, delegating to the Stripe API."]
["comment","payments.ts",7,"Refunds a previous charge by its Stripe charge id."]
["defines","charge",2,"(cardToken: string, amountCents: number)","payments.ts",2]
["defines","refund",2,"(chargeId: string, amountCents: number)","payments.ts",8]
["defines","validateCard",1,"(cardToken: string)","payments.ts",12]
["example_defines","authorize",2,"(cardToken: string, amountCents: number)","guide.md",15]
["example_defines","charge",2,"(cardToken: string, amountCents: number)","guide.md",6]
["paragraph","guide.md","Call `authorize` first if you need a separate authorization step before charging the card:",11]
["paragraph","guide.md","`charge` takes a card token and an amount in cents:",3]
["calls","charge",2,["local","validateCard",1],"payments.ts",3]
["calls","charge",2,["member","stripeClient","createCharge",2],"payments.ts",4]
["calls","refund",2,["member","stripeClient","createRefund",2],"payments.ts",9]
["doc","charge",2,"payments.ts",2,"Charges a card for the given amount, delegating to the Stripe API."]
["doc","refund",2,"payments.ts",8,"Refunds a previous charge by its Stripe charge id."]
["example_calls","authorize",2,["member","stripeClient","createAuthorization",2],"guide.md",16]
["example_calls","charge",2,["member","stripeClient","createCharge",2],"guide.md",7]
["heading","guide.md",1,"Payments Module",1]
```

Facts print as JSON Lines, not raw Prolog text (`docs/prolog-store.md`
§7) — one JSON array per fact. `parse -db` also writes the same facts
into a DETS database (`facts.dets`); write a few small helper rules to
their own file and load it alongside that database to unlock every
scenario below —

```prolog
callees(Fun, Callees) :-
    findall(C, calls(Fun, _CallerArity, C, _, _), Callees).

callers(Fun, Arity, Callers) :-
    findall(Caller, calls(Caller, _CallerArity, local(Fun, Arity), _, _), Callers).

undocumented(Fun, Arity, File, Line) :-
    defines(Fun, Arity, _Params, File, Line),
    \+ doc(Fun, Arity, _, _, _).

calls_object(Fun, Object) :-
    calls(Fun, _CallerArity, member(Object, _, _), _, _).

stale_doc_example(Fun, Arity, DocFile, Line) :-
    example_defines(Fun, Arity, _Params, DocFile, Line),
    \+ defines(Fun, Arity, _, _, _).
```

Note `calls_object/2` here, not `calls_module/2` — a TypeScript method
call (`stripeClient.createCharge(...)`) becomes `member(stripeClient,
createCharge, ArgCount)`, not the `remote(Module, Function, ArgCount)`
shape a qualified Erlang call (`stripe_client:create_charge(...)`)
would produce. Same underlying question ("what does this call into"),
different fact shape per language — see `docs/tree-sitter-erlang.md`
§3.

## Five things an agent would otherwise have to grep and re-read for

### 1. Orientation: "What does `charge` do, and what does it touch?"

An agent dropped into an unfamiliar codebase and asked to change
`charge` needs two things before touching it: what it's *for*, and
what it *does* underneath. Both are one query each, no file open needed:

```sh
$ symbolic query -db facts.dets -rules rules.pl 'doc(charge, Arity, File, Line, Text)'
Arity = 2
File = "payments.ts"
Line = 2
Text = "Charges a card for the given amount, delegating to the Stripe API."

$ symbolic query -db facts.dets -rules rules.pl 'callees(charge, Callees)'
Callees = [["local","validateCard",1],["member","stripeClient","createCharge",2]]
```

`callees/2` (defined above) uses `findall/3` to collect every call site
in one answer instead of one-at-a-time — worth reaching for whenever the
question is "all of X," not "the first X."

### 2. Impact analysis: "Is it safe to rename `validateCard`?"

Before an agent renames or changes the signature of a function, "who
calls this" is the question that actually matters — and it's exactly
the kind of thing a text search gets wrong the moment there's a second
function with a similar name, or the call is qualified differently.

```sh
$ symbolic query -db facts.dets -rules rules.pl 'callers(validateCard, 1, Callers)'
Callers = ["charge"]
```

One caller, so a rename is a two-file — well, two-*call-site* — change,
known for certain rather than inferred from a grep that could easily
have missed a qualified call or over-matched a substring.

### 3. Risk audit: "Which functions talk to Stripe directly?"

A realistic agent task: "before we add a retry wrapper around all
Stripe calls, show me every function that calls into `stripeClient`
directly." This is a structural question about the call graph, not a
text pattern — `member(stripeClient, _)` call sites, not any line
containing the word "stripe":

```sh
$ symbolic query -db facts.dets -rules rules.pl 'findall(F, calls_object(F, stripeClient), Fs)'
F = [0]
Fs = ["charge","refund"]
```

`F = [0]` here is an honest artifact worth understanding rather than
hiding: `F` is only bound *inside* each solution `findall/3` collects
into `Fs`, not in the surrounding query itself — standard Prolog
semantics, not a bug in this project. erlog represents an unbound
variable internally as a 1-tuple (its own `erlog.erl` header: "Variables
- {Name} where Name is an atom or integer"), which prints as the
1-element JSON array `[0]` rather than the `_0` a Prolog-text printer
would show (`docs/prolog-store.md` §7) — `Fs` is the answer that
matters either way.

### 4. Coverage check: "Which functions have no doc comment?"

Useful both for an agent auditing its own generated code before a PR,
and for a human deciding where to spend documentation effort:

```sh
$ symbolic query -db facts.dets -rules rules.pl 'findall(F, undocumented(F, _, _, _), Fs)'
F = [0]
Fs = ["validateCard"]
```

`charge` and `refund` both have doc comments (see `doc/5` in the fact
dump above); `validateCard` doesn't. This is `defines/5` minus `doc/5`,
expressed once as a rule and reused instead of re-derived by eye every
time.

### 5. Documentation drift: "Does `guide.md` still match the code?"

The motivating example for `example_defines/5` (see
`docs/tree-sitter-markdown.md` §4) — `guide.md`'s `authorize` code
sample was never actually added to `payments.ts`:

```sh
$ symbolic query -db facts.dets -rules rules.pl 'stale_doc_example(Fun, Arity, DocFile, Line)'
Arity = 2
DocFile = "guide.md"
Fun = "authorize"
Line = 15
```

An agent asked to "update the docs to match the code" (or the reverse —
"implement whatever the docs promise") now has a precise, structural
answer instead of a wish to "please read both files carefully."

## Wiring this into an actual agent session, over MCP

Everything above used the CLI (`symbolic query -db facts.dets -rules
rules.pl ...`) for readability, but an LLM agent talks to a **live,
persistent session** over MCP (`symbolic serve`), not a fresh CLI
process per question — see `docs/erlang-mcp-design.md`. Same facts,
same rules, same answers; the difference is the transport. This is a
real, captured JSON-RPC exchange against a running `symbolic serve`
process — driven by a small script issuing exactly the four tool calls
`symbolic_serve.erl` exposes (`docs/erlang-mcp-design.md` §3), not
hand-typed. `prolog_query`'s bound results print as JSON now too
(`DocFile = "guide.md"`, not `DocFile = 'guide.md'`) — the same
`symbolic_term_json.erl` fix `symbolic query`'s CLI output got (see
`docs/prolog-store.md` §7).

**1. Handshake** (`initialize`) — once per connection:

```json
{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "agent", "version": "0.1"}}}
```
```json
{
  "id": 1,
  "jsonrpc": "2.0",
  "result": {
    "capabilities": {
      "prompts": { "listChanged": false },
      "resources": { "listChanged": false, "subscribe": false },
      "tools": { "listChanged": false }
    },
    "protocolVersion": "2025-06-18",
    "serverInfo": { "name": "erlmcp-stdio", "version": "1.0.0" }
  }
}
```

**2. Start a session** (`prolog_start_session`) — returns an opaque
session id the agent threads through every later call:

```json
{"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "prolog_start_session", "arguments": {}}}
```
```json
{"id": 2, "jsonrpc": "2.0", "result": {"content": [{"text": "et91vScnjmg7DOSL6uCqUasy", "type": "text"}]}}
```

**3. Load the facts** (`prolog_consult`) — `prolog_consult` takes real
Prolog **text**, consulted via the ordinary, unchanged
`prolog_session:consult_string/2` path, so this demonstrates that raw
MCP capability directly: the agent sends a hand-written Prolog program
(the facts above, written out as literal Prolog syntax, plus the five
helper rules) as one string. This is **not** how the CLI's `symbolic
parse -db` pipeline loads facts anymore, though — that writes/reads a
DETS database and asserts terms directly, with no Prolog text involved
at all (`docs/prolog-store.md` §7). An agent driving `symbolic serve`
today would more naturally send just the five rules this way (real,
short, hand-written Prolog) and get the extracted facts into the same
session some other way — a `prolog_consult` call per fact, or a future
tool that loads a DETS file directly — rather than reconstructing a
`.pl`-text version of a fact base that isn't produced anywhere in this
form any more:

```json
{"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "prolog_consult", "arguments": {"session_id": "et91vScnjmg7DOSL6uCqUasy", "program": "<the facts + rules, as literal Prolog text>"}}}
```
```json
{"id": 3, "jsonrpc": "2.0", "result": {"content": [{"text": "ok", "type": "text"}]}}
```

**4. Ask a question** (`prolog_query`) — the "documentation drift"
scenario from above, asked the same way an agent would:

```json
{"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "prolog_query", "arguments": {"session_id": "et91vScnjmg7DOSL6uCqUasy", "goal": "stale_doc_example(Fun, DocFile, Line)"}}}
```
```json
{
  "id": 4,
  "jsonrpc": "2.0",
  "result": {
    "content": [{"text": "DocFile = \"guide.md\"\nFun = \"authorize\"\nLine = 15", "type": "text"}]
  }
}
```

Same answer as the CLI version — the session stays alive for as many
follow-up `prolog_query` calls as the agent needs (each of the five
scenarios above, asked in sequence, against the one loaded session) —
and the agent closes it with `prolog_end_session` when the task is
done.

## Why this matters more than it might look like

Every one of these five scenarios is a question a capable agent could
*eventually* answer by reading both files carefully and reasoning in
free text — the research this project is built on
(`docs/grpo-prolog-tool.md`, `docs/lorp-approach.md`) found that
delegating the actual multi-step logical resolution to a real Prolog
interpreter, rather than asking a model to simulate it in prose,
produces both more accurate answers and answers that don't degrade as
the question gets one hop harder ("who calls this" vs. "who calls
something that calls this"). `callers/3` above already gets that for
free — `findall(GrandCaller, (calls(GrandCaller, _, local(Caller, _), _, _),
member(Caller, Callers)), GrandCallers)` is a small extension of the
same rule, not a harder prompt.

## References

- [`readme.md`](../readme.md) — the CLI-focused version of these same
  examples, and the project's overall pitch.
- [`erlang-mcp-design.md`](erlang-mcp-design.md) — the MCP server design
  §3's four tools are shown against above.
- [`tree-sitter-markdown.md`](tree-sitter-markdown.md) §4 —
  `example_defines/5`/`example_calls/5`, the facts behind scenario 5.
- [`grpo-prolog-tool.md`](grpo-prolog-tool.md),
  [`lorp-approach.md`](lorp-approach.md) — the research on delegating
  logical reasoning to a real Prolog interpreter this project applies to
  codebases.
