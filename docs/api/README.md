# API documentation

`modules/` holds one Markdown file per Erlang module.

`functions/<module>/` holds one Markdown file per exported function.

Erlang source files reference these documents with `-moduledoc({file, Path})`
and `-doc({file, Path})`.
