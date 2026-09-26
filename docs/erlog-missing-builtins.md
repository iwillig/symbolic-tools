# Reference: Missing Prolog Builtins in erlog

erlog (the pure-Erlang Prolog engine this project embeds — see
[`prolog-schema.md`](prolog-schema.md) for the fact schema it proves
goals against) implements a small subset of ISO/SWI-Prolog. This doc
surveys what's missing, verified by actually invoking each candidate
predicate against a live session — not by reading a spec — and, for
each gap, whether it's something *we* can add as an ordinary
`.symbolic/rules.pl` predicate, or something that needs a change to
erlog itself.

**Error handling (`catch/3`, `throw/1`) is out of scope for this doc on
purpose** — it's absent too, but fixing it is a different kind of
project (it changes how every existing query's failure mode works) and
isn't covered here.

## Methodology note: `current_predicate/1` lies about builtins

The obvious way to survey "what's missing" is to loop
`current_predicate/1` over a candidate list. **Don't** — it only
reports predicates with real *clauses* (asserted facts, or something
`.symbolic/rules.pl` defines), not erlog's own natively-compiled
builtins. Proof:

```
goal: current_predicate(member/2)  →  count: 0   (says "missing")
goal: member(1, [1,2])             →  succeeds   (works fine)
goal: predicate_property(member(_,_), P)  →  P = compiled
```

The only reliable test is direct invocation: call the predicate with a
plausible argument and see whether the result is a real solution/clean
failure (present) or `{"error": "no such predicate: .../N ..."}`
(genuinely absent — erlog's `existence_error` is loud by design). Every
claim below was checked this way.

## Tier 1 — implement now: pure Prolog, verified working

These need **no new capability at all** — they're expressible using
builtins erlog already has, and each snippet below was actually run
against a live session, not just written down:

| Missing predicate | Pure-Prolog implementation | Built from |
|---|---|---|
| `is_list/1` | `is_list([]). is_list([_\|T]) :- is_list(T).` | recursion |
| `ground/1` | `ground(T) :- term_variables(T, []).` | `term_variables/2` (present) |
| `callable/1` | `callable(X) :- atom(X) ; compound(X).` | `atom/1`, `compound/1` (present) |
| `compare/3` | `compare(O,A,B) :- (A @< B -> O = (<) ; A @> B -> O = (>) ; O = (=)).` | `@</2`, `@>/2` (present) |
| `forall/2` | `forall(Cond,Action) :- \+ (call(Cond), \+ call(Action)).` | `\+/1`, `call/1` (present) |
| `ignore/1` | `ignore(Goal) :- (call(Goal) -> true ; true).` | if-then-else, `call/1` |
| `aggregate_all(count, Goal, N)` | `aggregate_all(count,Goal,N) :- findall(x,Goal,L), length(L,N).` | `findall/3`, `length/2` |
| `between/3` | `between(L,H,L) :- L =< H. between(L,H,X) :- L < H, L1 is L+1, between(L1,H,X).` | `is/2`, `=</2` |
| `succ/2`, `plus/3` | same recursive-arithmetic shape as `between/3` | `is/2` |
| `numlist/3` | `findall(X, between(L,H,X), List)` once `between/3` above exists | — |
| `nth0/3`, `nth1/3` | positional recursion, or `append/3` + `length/2` to split | `append/3`, `length/2` |
| `sum_list/2`, `max_list/2`, `min_list/2` | fold-style recursion with `is/2` | `is/2` |
| `msort/2`, `keysort/2` | merge sort (don't reuse `sort/2` — it dedupes, `msort` must not) | recursion, `@=</2` |
| `subtract/3`, `intersection/3`, `union/3` | `member/2` + negation-as-failure over a list | `member/2`, `\+/1` |
| `flatten/2` | recursive list-of-lists walk with `append/3` | `append/3` |
| `permutation/2` | classic select-and-recurse | `append/3` |
| `atom_concat/3` | `atom_concat(A,B,C) :- atom_codes(A,X), atom_codes(B,Y), append(X,Y,Z), atom_codes(C,Z).` | `atom_codes/2`, `append/3` |
| `sub_atom/5` | **shipped** — as a real native Erlang builtin, `src/symbolic_prolog_lib.erl`, not a `.symbolic/rules.pl` shim (see "A better tier: extend erlog itself, no fork needed" below for why that turned out to be possible at all). Verified live with `defines(Name, _, _, _, _), sub_atom(Name, _, _, _, session)` against this repo's own source. Covers ATOM fields only (function/module/file names, ...); a binary argument raises `type_error(atom, ...)` — see `sub_text/5` below for the free-text equivalent. | `erlog_int:unify/3`, `add_compiled_proc/4` — no Prolog-level builtins needed at all |
| `sub_text/5` | **shipped** — same file, same `add_compiled_proc/4` registration, same search, over a binary instead of an atom: `comment/3`, `doc/5`, and `paragraph/3`'s free-text `Text` field. `Sub` comes back as a code list, not a binary — a double-quoted goal literal is always a code list under erlog's `double_quotes(codes)` default (verified against `erlog_scan.xrl`/`erlog_parse.erl`), so a binary `Sub` could never unify against a needle a caller can actually type. Verified live with `comment(_, _, Text), sub_text(Text, Before, Length, After, "comment")` against this repo's own `test/symbolic_query_tests.erl` fixture. | `erlog_int:unify/3`, `add_compiled_proc/4` — no Prolog-level builtins needed at all |
| `char_code/2` | `char_code(Char,Code) :- atom_codes(Char,[Code]).` | `atom_codes/2` |
| `upcase_atom/2`, `downcase_atom/2` | map each code: `C2 is C - 32` when `C` is in `0'a..0'z` (and the mirror for downcase) | `atom_codes/2`, `is/2` |
| `atomic_list_concat/2,3` | fold `atom_concat/3` (above) over the list, inserting the separator for the 3-arg form | the `atom_concat/3` shim above |
| `dynamic/1` | `dynamic(_).` — a pure no-op; `assertz/1` already works without prior declaration | — |

**Verified, not assumed** — every one of `my_forall`, `my_ignore`,
`my_is_list`, `my_ground`, `my_compare`, `my_between`,
`my_atom_concat`, and `my_aggregate_count` (throwaway names, asserted
and exercised directly in-session) ran and produced the expected
bindings before this table was written.

## Tier 2 — needs one extra idiom: `call/1` + `=..`, not `call/N`

`call/2`, `call/3`, etc. (the convenient "apply extra arguments"
family) are **absent** — confirmed directly:

```
goal: call(atom, abc)   →   {"error": "no such predicate: call/2 ..."}
```

But the two primitives underneath it are both present and compose:
`Goal =.. [F|Args]` builds a callable term, and `call/1` runs it —
verified with a real recursive `my_maplist/2`:

```
goal: assertz((my_maplist(_,[]))),
      assertz((my_maplist(P,[H|T]) :-
                 P =.. L, append(L,[H],L2), G =.. L2, call(G),
                 my_maplist(P,T))),
      my_maplist(atom, [a,b,c])
→ succeeds
```

That one idiom (`P =.. L, append(L, [ExtraArg], L2), G =.. L2, call(G)`
in place of `call(P, ExtraArg)`) is enough to implement the whole
higher-order family the same way SWI's own library does, just with one
extra line per call site:

- `maplist/2,3,4,5`
- `foldl/4,5,6`
- `include/3`, `exclude/3`, `partition/4`

`bagof/3` and `setof/3` are also Tier 2, but only in a **reduced**
form: a real implementation needs free-variable grouping (the `^/2`
existential-quantification operator over which variables *don't*
partition the results), which is more design work than a one-line
shim. A `findall/3` + `sort/2` (for `setof`'s dedup-and-order) or
`findall/3` alone (for `bagof`'s no-dedup) covers the common case
where nothing needs grouping — which is most of how this project's own
queries already use them in spirit.

`format/2` (`~w`/`~n`/`~p` directives only, not the full SWI spec) is
also Tier 2: `atom_codes/2` exposes the format string's own codes, and
`write/1` + `nl/0` can produce the output — a small recursive directive
interpreter over the codes list, not a built-in.

## A better tier: extend erlog itself, no fork needed

`sub_atom/5` turned out not to belong in Tier 1 at all. It's now a real
native Erlang builtin — `src/symbolic_prolog_lib.erl` — executed inside
erlog's own resolution engine, exactly like `append/3`/`member/2` are,
and erlog's own dependency in `rebar.config` is untouched: no fork, no
vendored copy.

The mechanism was already public, just not documented as an extension
point: `erlog.erl` builds a fresh session's database by folding
`Mod:load(Db)` over its own bundled library modules (`erlog_bips`,
`erlog_lib_dcg`, `erlog_lib_lists`) — and exports `erlog:load/2` as the
exact same fold, for exactly one more module. This project's own
`prolog_session:init/1` and `symbolic_codebase:build_state/2` (its two
session constructors) each call `erlog:load(symbolic_prolog_lib, Erl)`
right after `erlog:new/0`, registering `sub_atom/5` via
`erlog_int:add_compiled_proc/4` (also exported) the identical way
`erlog_lib_lists:load/1` registers `append/3`.

The one real coupling: a compiled-procedure callback is handed erlog's
own `#est{}`/`#cp{}` records and has to pattern-match on them, and
those records live in `erlog_int.hrl` under erlog's `src/`, not
`include/` — not published as a stable public API. `-include_lib/1`
doesn't actually require an `include/` path, though (it's just
`AppName/SomePath`), so `-include_lib("erlog/src/erlog_int.hrl")`
reaches the real header directly. A future erlog release changing
`#est{}`'s fields would fail this module at **compile** time — the same
exposure erlog's own `erlog_bips.erl`/`erlog_lib_lists.erl` already
carry, not a new risk this project introduced.

This closes any gap that's merely *unimplemented*, the way `sub_atom/5`
was. It does **not** help with a gap that's *reserved* or
*structural* — `retractall/1` below is reserved at the same
`add_built_in`/`add_compiled_proc` layer this technique goes through,
and `op/3` acts on the reader, before resolution ever starts — so Tier
3 below is still real, just smaller than it looked before this was
tried.

## Tier 3 — needs an erlog engine change, not a `rules.pl` addition

The remaining gaps can't be closed from user-level Prolog OR from a
`erlog:load/2` native module, each for a different reason — confirmed
by reading erlog's own vendored source (fetched via `rebar.config`'s
`{erlog, {git, "https://github.com/rvirding/erlog.git", {branch,
"develop"}}}` — a real upstream dependency, not code this repo owns):

- **`retractall/1` is declared but never implemented.**
  `erlog_int.erl` lists `{retractall,1}` in its table of reserved
  built-in indicators (blocking a user-level redefinition of the same
  name), but `erlog_bips.erl`'s dispatch `case` has no clause for it —
  it falls through to the generic `error({illegal_bip,Goal})` at line
  235. Confirmed directly:
  ```
  goal: assertz(f(1)), assertz(f(2)), retractall(f(_))
  → {"error": "{exit,{{illegal_bip,{retractall,{f,{0}}}}, ...
      erlog_bips.erl:235 ..."}
  ```
  This is a real upstream bug/gap, not a missing feature we can shim —
  the name is reserved, so `.symbolic/rules.pl` can't define its own
  `retractall/1` to fill the hole.
- **`op/3` / `current_op/3`** change how the *reader* parses subsequent
  text — that's a property of the parser, not something a Prolog
  clause can hook into from inside a query.
- **`term_to_atom/2` and any real `format/3`-to-a-sink** need an
  output-capture primitive (SWI's `with_output_to/2`) that erlog
  doesn't expose to Prolog code at all — `write/1` only goes to real
  stdout, there's no way to redirect it into a term from user code.

## Priority recommendation

If we're picking a first slice rather than doing all of Tier 1 at
once: `sub_atom/5` is **done** — as a native `erlog:load/2` module
(`src/symbolic_prolog_lib.erl`), not a `.symbolic/rules.pl` shim; it was
the single most common thing an LLM agent reached for, confirmed by
repeated real `sub_atom(Name, _, _, _, '...')` attempts against a live
codebase before this fix. `sub_text/5` is **also done**, the same file
and mechanism, closing the free-text half of the same gap (`comment`/
`doc`/`paragraph`'s `Text`, a binary `sub_atom/5` itself can't touch).
`atom_concat/3` is the natural next
candidate for the same treatment (same `erlog:load/2` mechanism, same
`unify/3`/`add_compiled_proc/4` shape sub_atom_5/3 already
demonstrates), followed by `between/3`/`numlist/3` (generating a range
is a recurring need once any counting/limit logic shows up in a rule)
and `is_list/1`/`ground/1`/`callable/1` (cheap, general-purpose guards
worth having for defensive rule-writing) — either as pure-Prolog Tier 1
shims or the same native treatment, whichever is less code.
