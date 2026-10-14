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

For yes/no structural answers, `true` carries one deterministic matching witness. A `false` answer carries `"evidence": []` and, when scan metadata is available, a `scope` object describing the scanned paths, file count, completeness, and failed files. It means no matching fact was found in that complete scope. If any in-scope extraction failed—or the database predates scan metadata—absence-based structural answers are `unknown`, not `false`. Positive structural yes/no answers remain positive when a scan is incomplete because they have a matching witness. Incomplete scans also make list, count, and site answers `unknown`, since their results may be partial. A question the catalog cannot verify remains `unverifiable`, not `false`.

`callers` and `callers_count` keep their complete answer list or count when caller identities are available. Their evidence contains up to 50 call witnesses, one per distinct caller. `evidence_complete` is `true` when every returned caller has a citation and `false` when citations were capped; it does not change the answer completeness. A known caller name with unknown arity is shown as `name/?`. If a call fact has no caller name, both operations return `unknown` rather than a partial list or count.

`call_sites` and `definition_sites` return source locations in their `answer` arrays rather than a separate `evidence` field. Prose search returns ranked prose hits and is not changed by structural scan completeness. No prose hits mean only that the indexed corpus had no match, not that a claim is false. Catalog discovery exposes `incomplete_scan_answer_shape` for the `unknown` response.

Evidence supports the operation's stated fact-level meaning only. In particular, `returns_mention` joins a valued return with a same-line mention, or uses `return_object_key/6` to show that an object key is structurally inside that return expression. It does not establish value flow, control flow, or runtime behavior. File-scoped questions match a basename, a relative path suffix, or an exact absolute path.
