# Cold query startup benchmark

The full `~/oneproject/common/.symbolic/facts.dets` snapshot was 505 MB and
contained 1,461,222 facts during this run. Each CLI measurement used a fresh
Erlang VM and this absent-needle goal (the `string` constraint matters because
`literal/8` has numeric values too):

```sh
/usr/bin/time -l scripts/symbolic query -db "$HOME/oneproject/common/.symbolic/facts.dets" \
  'literal(_,_,_,string,V,_,_,_), sub_text(V,_,_,_,"InsteadAction")'
```

Both versions returned `No.`. Before bulk loading, a representative run took
8.95 s and peaked at 2.98 GB RSS. After bulk loading, three runs took
3.82–4.06 s and peaked at 2.22–2.26 GB RSS. These are local measurements,
not CI thresholds or cold disk-cache measurements.

An Erlang `timer:tc/1` harness measured each stage in a fresh VM. It timed
`symbolic_fact_store:read/1`, `prolog_session:start_link/0`,
`prolog_session:load_facts/2`, `prolog_session:consult/2`, and
`prolog_session:query/2` separately. The pre-change run measured DETS read
0.90 s, session start 0.05 s, fact load 5.44 s, rules 0.27 s, and proof
1.11 s. After the change, two runs measured read 0.90–0.91 s, start
0.05 s, load 0.33–0.34 s, rules 0.25–0.26 s, and proof 0.98–1.00 s.
These stages do not sum exactly to CLI wall time because VM startup, shutdown,
and reporting are outside the timed spans.

Erlang `eprof` on 25,000 facts showed 1.35 million calls to
`erlog_int:dderef/2` (40% of sampled load time) and 525,000 calls to
`erlog_int:initial_goal/3` (16%). The old loader proved an `asserta/1`
goal for every extracted fact. The direct loader uses erlog's default dict
backend for ground facts, retaining `asserta` order, tags, and static
procedure checks. For non-ground facts it keeps the old evaluator path so
per-clause variable renaming is unchanged. All 1,461,222 sampled project
facts had no Prolog variables (`erlog:vars_in/1`).

The remaining costs are about one second each for DETS read and the absent
proof. Changing storage or adding a literal index would be a separate design
decision, not implied by this benchmark.
