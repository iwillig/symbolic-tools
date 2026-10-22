# Query schema and preflight

The MCP `schema` tool reports ordered argument names, value types, binding modes,
and examples for selected high-use Prolog predicates. Call `schema` with no
arguments to see its documented subset, or with `name: "paragraph/3"` for
one contract. The catalog is deliberately **not** exhaustive. `overview`
reports raw fact predicate counts and the consulted `rules_file`, not a list
of every derived predicate. `schema` itself needs no parse.

For an agent composing a structural goal: first parse the project, then use
`overview` to check raw fact counts and `rules_file`, use `schema` to check a
documented argument order/type, and only then call `query`. If `schema` does
not document a name, that is **not** evidence that the predicate is absent;
consult the query tool's broader fact catalog or project documentation. For
function-name discovery, use `search_functions` rather than a broad Prolog
name scan. Use `search` for prose; it does not index literal values.

The `query` tool rejects two provably malformed patterns before running erlog:

- A wrong arity for a documented predicate, such as `paragraph(F,T,L,X)`.
- An incompatible first argument to `sub_text/5` or `sub_atom/5`, either a
  literal of the wrong type or a variable bound by an earlier known fact in a
  simple conjunction. For example, `paragraph(F, Line, Text),
  sub_text(Text, _, _, _, "query")` uses the integer line number as binary
  text. The correction is `paragraph(F, Text, Line)`.

Preflight **does not** interpret arbitrary Prolog, expand rules, or guess the
types of mixed-value facts such as `literal/8`. Unknown predicates, nested
proofs, and genuinely unbound variables still go to erlog; normal runtime
errors and no-solution answers retain their existing meaning. No coercion
from atoms or numbers to binary text is performed. The two filters require
an already-bound haystack; `sub_text/5` takes a binary and `sub_atom/5` takes
an atom. Double-quoted goal strings are code lists, not binary literals.
