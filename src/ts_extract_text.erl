%%% Shared text-normalization helpers for the tree-sitter extractors
%%% (ts_extract_erlang.erl and friends) — previously duplicated
%%% byte-for-byte in all six extractor modules.
%%%
%%%   to_atom/1 — identifier-like text (function/module/callee names,
%%%               file paths, config key paths, code-block language
%%%               tags): short, and unified against hand-typed query
%%%               literals (e.g. `calls(X, local(bar), _, _)`), so it
%%%               stays an Erlang atom. Truncated at 255 bytes — Erlang's
%%%               own atom cap, hit for real on a long identifier-shaped
%%%               value once (see docs/prolog-schema.md).
%%%   to_text/1 — free text (comment/doc bodies, headings, paragraphs,
%%%               config leaf values): never unified against a literal
%%%               a human would type, so there's no reason to force it
%%%               into an atom at all. Stored as a binary instead —
%%%               unbounded length (no truncation, no atom-table
%%%               pressure from list_to_atom/1 on arbitrarily long
%%%               extracted prose) and it round-trips through JSON
%%%               (symbolic_term_json.erl) as a native string with no
%%%               quoting ambiguity, unlike erlog_io:writeq1/1's
%%%               unescaped Prolog-atom quoting. See docs/prolog-store.md.
-module(ts_extract_text).
-export([to_atom/1, to_text/1]).

-define(MAX_ATOM_TEXT, 200).

to_atom(Text) when is_binary(Text) -> to_atom(binary_to_list(Text));
to_atom(Text) when is_list(Text) -> list_to_atom(truncate(Text)).

truncate(Text) when length(Text) > ?MAX_ATOM_TEXT ->
    lists:sublist(Text, ?MAX_ATOM_TEXT) ++ "...";
truncate(Text) ->
    Text.

%% list_to_binary/1, not unicode:characters_to_binary/1 — node_text/2
%% already returns raw UTF-8 bytes as a flat list of integers (the same
%% thing to_atom/1 above passes straight through to list_to_atom/1,
%% byte-for-byte, no interpretation). unicode:characters_to_binary/1
%% instead treats each integer as its OWN Unicode codepoint and
%% re-encodes it — for any byte above 127 (e.g. one byte of a
%% multi-byte UTF-8 em dash) that mangles it into mojibake. Confirmed by
%% hitting it for real: dogfooding `symbolic parse` against this
%% project's own em-dash-heavy comments before this fix.
to_text(Text) when is_binary(Text) -> Text;
to_text(Text) when is_list(Text) -> list_to_binary(Text).
