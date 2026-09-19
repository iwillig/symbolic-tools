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
$ symbolic parse . > facts.pl
$ cat facts.pl
code_block('guide.md',ts,5).
code_block('guide.md',ts,14).
comment('payments.ts',1,'Charges a card for the given amount, delegating to the Stripe API.').
comment('payments.ts',7,'Refunds a previous charge by its Stripe charge id.').
defines(charge,'payments.ts',2).
defines(refund,'payments.ts',8).
defines(validateCard,'payments.ts',12).
example_defines(authorize,'guide.md',15).
example_defines(charge,'guide.md',6).
paragraph('guide.md','Call `authorize` first if you need a separate authorization step before charging the card:',11).
paragraph('guide.md','`charge` takes a card token and an amount in cents:',3).
calls(charge,local(validateCard),'payments.ts',3).
calls(charge,member(stripeClient,createCharge),'payments.ts',4).
calls(refund,member(stripeClient,createRefund),'payments.ts',9).
doc(charge,'payments.ts',2,'Charges a card for the given amount, delegating to the Stripe API.').
doc(refund,'payments.ts',8,'Refunds a previous charge by its Stripe charge id.').
example_calls(authorize,member(stripeClient,createAuthorization),'guide.md',16).
example_calls(charge,member(stripeClient,createCharge),'guide.md',7).
heading('guide.md',1,'Payments Module',1).
```

Same "hand-edit the fact file" workflow the readme already establishes:
a few small helper rules, appended once, unlock every scenario below —

```prolog
callees(Fun, Callees) :-
    findall(C, calls(Fun, C, _, _), Callees).

callers(Fun, Callers) :-
    findall(Caller, calls(Caller, local(Fun), _, _), Callers).

undocumented(Fun, File, Line) :-
    defines(Fun, File, Line),
    \+ doc(Fun, _, _, _).

calls_object(Fun, Object) :-
    calls(Fun, member(Object, _), _, _).

stale_doc_example(Fun, DocFile, Line) :-
    example_defines(Fun, DocFile, Line),
    \+ defines(Fun, _, _).
```

Note `calls_object/2` here, not `calls_module/2` — a TypeScript method
call (`stripeClient.createCharge(...)`) becomes `member(stripeClient,
createCharge)`, not the `remote(Module, Function)` shape a qualified
Erlang call (`stripe_client:create_charge(...)`) would produce. Same
underlying question ("what does this call into"), different fact shape
per language — see `docs/tree-sitter-erlang.md` §3.

## Five things an agent would otherwise have to grep and re-read for

### 1. Orientation: "What does `charge` do, and what does it touch?"

An agent dropped into an unfamiliar codebase and asked to change
`charge` needs two things before touching it: what it's *for*, and
what it *does* underneath. Both are one query each, no file open needed:

```sh
$ symbolic query -file facts.pl 'doc(charge, File, Line, Text)'
File = 'payments.ts'
Line = 2
Text = 'Charges a card for the given amount, delegating to the Stripe API.'

$ symbolic query -file facts.pl 'callees(charge, Callees)'
Callees = [local(validateCard),member(stripeClient,createCharge)]
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
$ symbolic query -file facts.pl 'callers(validateCard, Callers)'
Callers = [charge]
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
$ symbolic query -file facts.pl 'findall(F, calls_object(F, stripeClient), Fs)'
F = _0
Fs = [charge,refund]
```

`F = _0` here is an honest artifact worth understanding rather than
hiding: `F` is only bound *inside* each solution `findall/3` collects
into `Fs`, not in the surrounding query itself — standard Prolog
semantics, not a bug in this project. `Fs` is the answer that matters.

### 4. Coverage check: "Which functions have no doc comment?"

Useful both for an agent auditing its own generated code before a PR,
and for a human deciding where to spend documentation effort:

```sh
$ symbolic query -file facts.pl 'findall(F, undocumented(F, _, _), Fs)'
F = _0
Fs = [validateCard]
```

`charge` and `refund` both have doc comments (see `doc/4` in the fact
dump above); `validateCard` doesn't. This is `defines/3` minus `doc/4`,
expressed once as a rule and reused instead of re-derived by eye every
time.

### 5. Documentation drift: "Does `guide.md` still match the code?"

The motivating example for `example_defines/3` (see
`docs/tree-sitter-markdown.md` §4) — `guide.md`'s `authorize` code
sample was never actually added to `payments.ts`:

```sh
$ symbolic query -file facts.pl 'stale_doc_example(Fun, DocFile, Line)'
DocFile = 'guide.md'
Fun = authorize
Line = 15
```

An agent asked to "update the docs to match the code" (or the reverse —
"implement whatever the docs promise") now has a precise, structural
answer instead of a wish to "please read both files carefully."

## Wiring this into an actual agent session, over MCP

Everything above used the CLI (`symbolic query -file facts.pl ...`) for
readability, but an LLM agent talks to a **live, persistent session**
over MCP (`symbolic serve`), not a fresh CLI process per question — see
`docs/erlang-mcp-design.md`. Same facts, same rules, same answers; the
difference is the transport. This is a real, captured JSON-RPC exchange
against a running `symbolic serve` process — driven by a small script
issuing exactly the four tool calls `symbolic_serve.erl` exposes
(`docs/erlang-mcp-design.md` §3), not hand-typed:

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
{"id": 2, "jsonrpc": "2.0", "result": {"content": [{"text": "2uSBxIe92Gq6lwog92bL3bWQ", "type": "text"}]}}
```

**3. Load the facts** (`prolog_consult`) — the agent sends the whole
`facts.pl` content (parsed facts plus the five helper rules above) as
one string; a real `symbolic parse` run would produce this text, an
agent would just pass it straight through instead of round-tripping it
through a file:

```json
{"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "prolog_consult", "arguments": {"session_id": "2uSBxIe92Gq6lwog92bL3bWQ", "program": "<facts.pl text>"}}}
```
```json
{"id": 3, "jsonrpc": "2.0", "result": {"content": [{"text": "ok", "type": "text"}]}}
```

**4. Ask a question** (`prolog_query`) — the "documentation drift"
scenario from above, asked the same way an agent would:

```json
{"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "prolog_query", "arguments": {"session_id": "2uSBxIe92Gq6lwog92bL3bWQ", "goal": "stale_doc_example(Fun, DocFile, Line)"}}}
```
```json
{
  "id": 4,
  "jsonrpc": "2.0",
  "result": {
    "content": [{"text": "DocFile = 'guide.md'\nFun = authorize\nLine = 15", "type": "text"}]
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
something that calls this"). `callers/2` above already gets that for
free — `findall(GrandCaller, (calls(GrandCaller, local(Caller), _, _),
member(Caller, Callers)), GrandCallers)` is a small extension of the
same rule, not a harder prompt.

## References

- [`readme.md`](../readme.md) — the CLI-focused version of these same
  examples, and the project's overall pitch.
- [`erlang-mcp-design.md`](erlang-mcp-design.md) — the MCP server design
  §3's four tools are shown against above.
- [`tree-sitter-markdown.md`](tree-sitter-markdown.md) §4 —
  `example_defines/3`/`example_calls/4`, the facts behind scenario 5.
- [`grpo-prolog-tool.md`](grpo-prolog-tool.md),
  [`lorp-approach.md`](lorp-approach.md) — the research on delegating
  logical reasoning to a real Prolog interpreter this project applies to
  codebases.
