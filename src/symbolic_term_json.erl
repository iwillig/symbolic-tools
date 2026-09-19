%%% Converts a Prolog term (an Erlang tuple whose first element is the
%%% functor atom — e.g. `{defines, foo, 'file.erl', 3}` for a fact, or
%%% `{local, bar}` for a nested CallSpec) into a jsx-encodable value.
%%% This is the replacement for `erlog_io:writeq1/1` in every place this
%%% project prints a term to a human or another process: `symbolic
%%% parse`'s stdout (symbolic_parse.erl), `symbolic query`'s printed
%%% bindings (symbolic_query.erl), and the MCP server's tool results
%%% (symbolic_serve.erl).
%%%
%%% `writeq1/1` doesn't escape an atom's embedded single quotes at all
%%% (confirmed by reading erlog_io.erl's own `%Very naive as yet.`
%%% comment on its atom-quoting clause) — real, ordinary text this
%%% project's own source comments are full of (contractions,
%%% possessives) breaks it. jsx's JSON string encoding has no such gap.
%%% See docs/prolog-store.md.
%%%
%%% A compound term becomes a JSON array: `[Functor, Arg1, Arg2, ...]`
%%% — both a whole fact (`["defines","foo","file.erl",3]`) and a nested
%%% term (`["local","bar"]`, `["remote","io","format"]`) render the same
%%% way, recursively. An atom becomes a JSON string. A binary (the free
%%% text produced by ts_extract_text:to_text/1 — comment/doc bodies,
%%% headings, paragraphs, config values) becomes a JSON string directly,
%%% with no length limit and no quoting ambiguity. An integer stays a
%%% JSON number.
-module(symbolic_term_json).
-export([encode_term/1]).

encode_term(T) when is_tuple(T) ->
    [encode_term(E) || E <- tuple_to_list(T)];
encode_term(A) when is_atom(A) -> atom_to_binary(A, utf8);
encode_term(B) when is_binary(B) -> B;
encode_term(N) when is_integer(N) -> N;
encode_term(L) when is_list(L) -> [encode_term(E) || E <- L].
