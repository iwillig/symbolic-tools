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
%%% with no length limit and no quoting ambiguity. An integer or float
%%% stays a JSON number.
%%%
%%% An *unbound* variable is the one term shape here that is neither data
%%% nor a name. `erlog_int:dderef/2` returns a free variable as the
%%% one-element tuple `{V}` — `_build/default/lib/erlog/src/erlog_int.erl:1275`,
%%% where `V` is erlog's integer variable number (`IS_CONSTANT/1` is "not a
%%% tuple and not a list", `erlog_int.hrl:22`). The generic tuple clause
%%% turned that into `[V]`, i.e. `A = 0` in CLI output — indistinguishable
%%% from "the number 0", a line number, or an arity, which is exactly the
%%% ambiguity an agent reads as noise and then stops trusting the tool over.
%%% Worse, `tuple_to_list({V})` is the *integer* `V`, not `[V]`, so the
%%% comprehension in the list clause got a non-list to iterate:
%%% `{bad_generator,{3}}`, a crash whose payload is the variable itself.
%%% And a multi-slot tuple `{A,B}` encoded as a charlist, so `{1,2}` rendered
%%% as `","`.
%%% A `{V}` now renders as the distinct string `_G<V>`; a variable bound to a
%%% real integer is still indistinguishable from an unbound one at this layer
%%% (that needs the binding pair, so it belongs to the callers) — but nothing
%%% crashes, and no unsolved variable pretends to be data any more.
-module(symbolic_term_json).
-export([encode_term/1]).

%% Unbound Prolog variable — see the dderef/2 note above. Must precede the
%% generic tuple clause, which is what used to match it.
encode_term({V}) when is_integer(V) ->
    <<"_G", (integer_to_binary(V))/binary>>;
encode_term(T) when is_tuple(T) ->
    [encode_term(E) || E <- tuple_to_list(T)];
encode_term(A) when is_atom(A) -> atom_to_binary(A, utf8);
encode_term(B) when is_binary(B) -> B;
encode_term(N) when is_integer(N) -> N;
encode_term(N) when is_float(N) -> N;
encode_term(L) when is_list(L) -> [encode_term(E) || E <- L].
