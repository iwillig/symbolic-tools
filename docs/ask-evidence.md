# Evidence in ASK answers

ASK results keep their existing answer type and value. When a result can be tied to extracted source facts, the catalog describes how the result carries evidence. Discover the exact operations and schemas with `symbolic ask -catalog` or the MCP `ask_catalog` tool. The CLI emits the answer as JSON; MCP wraps the same answer map in its `ok` field.

## Source witnesses

A structural evidence item has this shape:

```json
{
  "predicate": "calls",
  "file": "src/example.ts",
  "line": 12,
  "fact": {
    "caller": "foo/2",
    "call": {"kind": "local", "name": "bar", "arity": 1}
  }
}
```

- `predicate` names the extracted fact family.
- `file` and `line` locate that fact in source.
- `fact` contains the normalized fields used to match the question. Call evidence preserves call kind and its module or receiver/method where relevant.

For yes/no structural answers, `true` carries one deterministic matching witness; `false` carries `"evidence": []`. The empty array means no matching fact was found within the loaded fact base and operation scope. It does not prove that every source file was scanned or extracted successfully. A question the catalog cannot verify remains `unverifiable`, not `false`.

`callers` and `callers_count` keep their complete answer list or count. Their evidence contains up to 50 call witnesses, one per distinct caller. `evidence_complete` is `true` when every returned caller has a citation and `false` when citations were capped; it does not change the answer completeness.

`call_sites` and `definition_sites` return source locations in their `answer` arrays rather than a separate `evidence` field. Prose search returns ranked prose hits. No prose hits mean only that the indexed corpus had no match, not that a claim is false.

Evidence supports the operation's stated fact-level meaning only. In particular, `returns_mention` joins a valued return statement with a same-line mention; it does not establish value flow, control flow, or runtime behavior. File-scoped questions use the file matching behavior described by their catalog operation.
