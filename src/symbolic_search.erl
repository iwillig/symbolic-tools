%%% `symbolic search -db <facts.dets> [-limit N] "<query>"` — full-text
%%% search over the prose facts in a fact database: every comment/3
%%% (Erlang, bash, jsdoc, ...), paragraph/3, heading/4, and blockquote/3
%%% fact the extraction layer wrote, indexed and scored by the
%%% symbolic_text NIF (BM25, see docs/full-text-search.md). Results come
%%% back as JSON: file, line, kind, score, and a text excerpt.
%%%
%%% The whole index is built per invocation, from the fact database alone
%%% — the same "start fresh, do work, tear down" one-shot shape as
%%% symbolic_query:run_result/3 (a prolog_session) and
%%% symbolic_extract_llm:run_result/2 (a model load). A fact database is
%%% a deterministic function of the source tree, so there is nothing to
%%% keep warm across calls: re-running `symbolic parse` plus this
%%% command is the cache strategy.
%%%
%%% No Prolog engine is involved on this path at all — prose facts are
%%% plain Erlang tuples in DETS (see docs/prolog-store.md), matched
%%% directly, because text retrieval isn't goal proving and dragging a
%%% prolog_session in to `findall` tuples Erlang can match in one guard
%%% would be ceremony, not use.
-module(symbolic_search).

%% #file_info.mtime — the sidecar freshness check (cached_index/1).
-include_lib("kernel/include/file.hrl").

-export([run/3, run_functions/3]).
%% Exported for symbolic_search_tests.erl — run_result/3 is the
%% halt-free core — and for symbolic_parse:maybe_store/2, which writes
%% the sidecar alongside the configured DETS store on every `symbolic parse`.
-export([run_result/3, run_facts/3, run_functions_result/3, run_functions_facts/3,
    write_index_cache/2]).

%% The prose-fact kinds this tier indexes, with their argument shapes
%% (the extraction layer's own contracts — see ts_extract.erl's and
%% ts_extract_markdown.erl's headers). Arity alone is NOT a safe
%% discriminator here: comment/3 and paragraph/3 both have a file, a
%% line, and a text but in DIFFERENT argument orders, so each functor is
%% matched by name below, never by a shared shape.

%% halt() belongs only here, at the CLI's edge — same rule as
%% symbolic_query, symbolic_extract, and symbolic_check.
-spec run(file:filename(), string(), pos_integer()) -> no_return().
run(DbPath, Query, Limit) ->
    case run_result(DbPath, Query, Limit) of
        {ok, Results} ->
            io:format("~ts~n", [jsx:encode(Results)]),
            halt(0);
        {error, Reason} ->
            fail("cannot search: ~p", [Reason])
    end.

run_functions(DbPath, Query, Limit) ->
    case run_functions_result(DbPath, Query, Limit) of
        {ok, Results} ->
            io:format("~ts~n", [jsx:encode(Results)]),
            halt(0);
        {error, Reason} ->
            fail("cannot search functions: ~p", [Reason])
    end.

%% Read the fact database, index every prose fact, search, and map the
%% winning doc ids back to their {Kind, File, Line, Text} metadata.
%% Doc ids are the 1-based positions in Docs — the NIF only ever sees
%% u64 ids; the mapping back to metadata stays Erlang-side, so the Rust
%% side never learns file paths or line numbers.
-spec run_result(file:filename(), string(), pos_integer()) ->
    {ok, [map()]} | {error, term()}.
run_result(DbPath, Query, Limit) ->
    case filelib:is_regular(DbPath) of
        false ->
            {error, {no_such_db, DbPath}};
        true ->
            case cached_index(DbPath) of
                {ok, Index, Docs} ->
                    search_with(Index, Docs, Query, Limit);
                miss ->
                    Docs = text_docs(symbolic_fact_store:read(DbPath)),
                    search_docs(Docs, Query, Limit)
            end
    end.

-spec run_functions_result(file:filename(), string(), pos_integer()) ->
    {ok, [map()]} | {error, term()}.
run_functions_result(DbPath, Query, Limit) ->
    case filelib:is_regular(DbPath) of
        false ->
            {error, {no_such_db, DbPath}};
        true ->
            case cached_function_index(DbPath) of
                {ok, Index, Docs} ->
                    search_functions_with(Index, Docs, Query, Limit);
                miss ->
                    run_functions_facts(symbolic_fact_store:read(DbPath), Query, Limit)
            end
    end.

-spec run_functions_facts([tuple()], string(), pos_integer()) ->
    {ok, [map()]} | {error, term()}.
run_functions_facts(Facts, Query, Limit) ->
    Docs = function_docs(Facts),
    case Docs of
        [] -> {ok, []};
        _ -> search_functions_with(build_function_index(Docs), Docs, Query, Limit)
    end.

%% The parse-time cache: `symbolic parse` writes `<database>.text_idx` —
%% the BM25 snapshot bytes plus the doc metadata — right after the
%% DETS store, both from the same fact list (see symbolic_parse:
%% maybe_store/2). One container, term_to_binary, so the fast path
%% needs neither a DETS read nor a re-tokenization: load the snapshot,
%% map ids back to metadata. Any failure here is best-effort — parse
%% callers wrap it in a catch, and the search side degrades to the
%% slow path silently on a missing, stale, corrupt, or unreadable
%% sidecar, never an error.
-spec write_index_cache(file:filename(), [tuple()]) -> ok.
write_index_cache(DbPath, Facts) ->
    Docs = text_docs(Facts),
    Index = build_index(Docs),
    {ok, Snapshot} = symbolic_text:index_snapshot(Index),
    FunctionDocs = function_docs(Facts),
    FunctionIndex = build_function_index(FunctionDocs),
    {ok, FunctionSnapshot} = symbolic_text:index_snapshot(FunctionIndex),
    ok = file:write_file(sidecar_path(DbPath),
        term_to_binary(#{docs => Docs, snapshot => Snapshot,
            function_docs => FunctionDocs, function_snapshot => FunctionSnapshot,
            function_schema => 1})).

%% The fast-path probe: a sidecar exists, is at least as new as the
%% DETS store it describes, decodes safely, and its snapshot loads —
%% or the caller rebuilds from facts. mtime is the freshness rule:
%% parse writes both files together, so an older sidecar means the db
%% was re-written by something that didn't refresh it.
cached_index(DbPath) ->
    Sidecar = sidecar_path(DbPath),
    case {file:read_file_info(DbPath), file:read_file_info(Sidecar)} of
        {{ok, DbInfo}, {ok, IdxInfo}} when IdxInfo#file_info.mtime >= DbInfo#file_info.mtime ->
            case file:read_file(Sidecar) of
                {ok, Bin} -> cached_index_decode(Bin);
                _ -> miss
            end;
        _ ->
            miss
    end.

cached_index_decode(Bin) ->
    try binary_to_term(Bin, [safe]) of
        #{docs := Docs, snapshot := Snapshot} when is_list(Docs), is_binary(Snapshot) ->
            case symbolic_text:index_load_binary(Snapshot) of
                {ok, Index} -> {ok, Index, Docs};
                {error, _} -> miss
            end;
        _ -> miss
    catch
        _:_ -> miss
    end.

cached_function_index(DbPath) ->
    Sidecar = sidecar_path(DbPath),
    case {file:read_file_info(DbPath), file:read_file_info(Sidecar)} of
        {{ok, DbInfo}, {ok, IdxInfo}} when IdxInfo#file_info.mtime >= DbInfo#file_info.mtime ->
            case file:read_file(Sidecar) of
                {ok, Bin} -> cached_function_index_decode(Bin);
                _ -> miss
            end;
        _ -> miss
    end.

cached_function_index_decode(Bin) ->
    try binary_to_term(Bin, [safe]) of
        #{function_schema := 1, function_docs := Docs, function_snapshot := Snapshot}
                when is_list(Docs), is_binary(Snapshot) ->
            case symbolic_text:index_load_binary(Snapshot) of
                {ok, Index} -> {ok, Index, Docs};
                {error, _} -> miss
            end;
        _ -> miss
    catch
        _:_ -> miss
    end.

sidecar_path(DbPath) -> DbPath ++ ".text_idx".

%% MCP keeps facts in memory rather than in a DETS file. Reuse the same
%% document selection and BM25 search without a sidecar.
-spec run_facts([tuple()], string(), pos_integer()) -> {ok, [map()]} | {error, term()}.
run_facts(Facts, Query, Limit) ->
    search_docs(text_docs(Facts), Query, Limit).

search_docs([], _Query, _Limit) ->
    %% An empty corpus is a valid answer, not an error — the same stance
    %% as an empty `symbolic query` result set.
    {ok, []};
search_docs(Docs, Query, Limit) ->
    search_with(build_index(Docs), Docs, Query, Limit).

build_index(Docs) ->
    Index = symbolic_text:index_new(),
    ok = add_docs(Index, Docs, 1),
    Index.

build_function_index(Docs) ->
    Index = symbolic_text:index_new(),
    ok = add_function_docs(Index, Docs, 1),
    Index.

search_functions_with(Index, Docs, Query, Limit) ->
    QueryBin = unicode:characters_to_binary(function_query_text(Query)),
    RetrievalLimit = min(1000, max(100, Limit * 20)),
    case symbolic_text:index_search(Index, QueryBin, RetrievalLimit) of
        {ok, Ranked} ->
            Candidates0 = lists:foldl(fun({Id, Score}, Acc) ->
                maps:put(Id, Score, Acc)
            end, #{}, Ranked),
            Candidates = add_direct_function_matches(Docs, Query, Candidates0, 1),
            Scored = lists:filtermap(fun({Id, Score}) ->
                case function_rank(Docs, Id, Score, Query) of
                    skip -> false;
                    RankResult -> {true, RankResult}
                end
            end, maps:to_list(Candidates)),
            Sorted = lists:sort(fun({KeyA, _, _}, {KeyB, _, _}) -> KeyA < KeyB end, Scored),
            {ok, [function_result(Docs, Id, RankScore) || {_Key, Id, RankScore} <-
                lists:sublist(Sorted, Limit)]};
        {error, Reason} ->
            {error, Reason}
    end.

function_rank(Docs, Id, TextScore, Query) ->
    {Name, Arity, File, Line, _SearchText} = lists:nth(Id, Docs),
    QueryParts = parse_function_query(Query),
    NameNorm = normalize_identifier(to_list(to_bin(Name))),
    QueryNorm = maps:get(name, QueryParts),
    ArityMatch = case maps:get(arity, QueryParts) of
        undefined -> true;
        RequestedArity -> Arity =:= RequestedArity andalso NameNorm =:= QueryNorm
    end,
    case ArityMatch of
        false -> skip;
        true ->
            MatchClass = case {NameNorm, QueryNorm} of
                {_N, []} -> 0;
                {N, Q} when N =:= Q -> 3;
                {N, Q} ->
                    case lists:prefix(Q, N) of
                        true -> 2;
                        false -> case string:str(N, Q) of 0 -> 0; _ -> 1 end
                    end
            end,
            Priority = case MatchClass of 3 -> 1.0e9; 2 -> 1.0e6; 1 -> 1.0e3; _ -> 0 end,
            SortKey = {-MatchClass, -(Priority + TextScore), to_bin(Name), Arity,
                to_bin(File), Line},
            {SortKey, Id, Priority + TextScore}
    end.

add_direct_function_matches(_Docs, _Query, Acc, _Id) when map_size(Acc) >= 100000 -> Acc;
add_direct_function_matches([], _Query, Acc, _Id) -> Acc;
add_direct_function_matches([Doc | Rest], Query, Acc, Id) ->
    {Name, Arity, _File, _Line, _SearchText} = Doc,
    QueryParts = parse_function_query(Query),
    QueryNorm = maps:get(name, QueryParts),
    NameNorm = normalize_identifier(to_list(to_bin(Name))),
    ArityOk = case maps:get(arity, QueryParts) of
        undefined -> true;
        RequestedArity -> RequestedArity =:= Arity andalso NameNorm =:= QueryNorm
    end,
    Direct = ArityOk andalso QueryNorm =/= [] andalso
        (NameNorm =:= QueryNorm orelse lists:prefix(QueryNorm, NameNorm) orelse
            string:str(NameNorm, QueryNorm) > 0),
    Acc1 = case Direct andalso not maps:is_key(Id, Acc) of
        true -> maps:put(Id, 0.0, Acc);
        false -> Acc
    end,
    add_direct_function_matches(Rest, Query, Acc1, Id + 1).

function_result(Docs, Id, Score) ->
    {Name, Arity, File, Line, _SearchText} = lists:nth(Id, Docs),
    #{<<"kind">> => <<"function">>,
      <<"function">> => to_bin(Name),
      <<"arity">> => Arity,
      <<"file">> => to_bin(File),
      <<"line">> => Line,
      <<"score">> => Score}.

%% The shared search-and-map step: the fast path (sidecar) and the slow
%% path (build-from-facts) differ only in where {Index, Docs} came from.
search_with(Index, Docs, Query, Limit) ->
    case symbolic_text:index_search(Index, unicode:characters_to_binary(Query), Limit) of
        {ok, Ranked} ->
            {ok, [result(Docs, Id, Score) || {Id, Score} <- Ranked]};
        {error, Reason} ->
            {error, Reason}
    end.

result(Docs, Id, Score) ->
    {Kind, File, Line, Text} = lists:nth(Id, Docs),
    #{
        <<"kind">> => atom_to_binary(Kind, utf8),
        <<"file">> => to_bin(File),
        <<"line">> => Line,
        <<"score">> => Score,
        <<"text">> => excerpt(Text)
    }.

text_docs(Facts) ->
    lists:filtermap(fun text_doc/1, Facts).

function_docs(Facts) ->
    lists:filtermap(fun function_doc/1, Facts).

function_doc({defines, Name, Arity, _Params, File, Line})
        when is_integer(Arity), is_integer(Line) ->
    NameBin = to_bin(Name),
    SearchText = function_search_text(NameBin, Arity),
    {true, {Name, Arity, File, Line, SearchText}};
function_doc(_) ->
    false.

function_search_text(NameBin, Arity) ->
    NameList = binary_to_list(NameBin),
    WordText = re:replace(split_camel_case(NameList), "[^A-Za-z0-9]+", " ",
        [global, {return, list}]),
    iolist_to_binary([NameBin, " ", WordText, " ", integer_to_list(Arity)]).

function_query_text(Query) ->
    Parts = parse_function_query(Query),
    Name = to_list(to_bin(maps:get(name, Parts))),
    [Query, " ", split_camel_case(Name)].

split_camel_case(Text) ->
    lists:reverse(split_camel_case(Text, none, [])).

split_camel_case([], _Previous, Acc) -> Acc;
split_camel_case([C | Rest], Previous, Acc) ->
    Boundary = is_upper(C) andalso (is_lower(Previous) orelse is_digit(Previous)),
    Acc1 = case Boundary of
        true -> [C, $  | Acc];
        false -> [C | Acc]
    end,
    split_camel_case(Rest, C, Acc1).

is_upper(C) when C >= $A, C =< $Z -> true;
is_upper(_) -> false.
is_lower(C) when C >= $a, C =< $z -> true;
is_lower(_) -> false.
is_digit(C) when C >= $0, C =< $9 -> true;
is_digit(_) -> false.

parse_function_query(Query) ->
    QueryList = to_list(to_bin(Query)),
    case re:run(QueryList, "^(.*)/([0-9]+)$", [{capture, [1, 2], list}]) of
        {match, [Name, ArityText]} ->
            #{name => normalize_identifier(Name), arity => list_to_integer(ArityText)};
        nomatch ->
            #{name => normalize_identifier(QueryList), arity => undefined}
    end.

normalize_identifier(Text) ->
    Lower = string:lowercase(Text),
    [C || C <- Lower, (C >= $a andalso C =< $z) orelse
        (C >= $0 andalso C =< $9) orelse C > 127].

to_list(Bin) when is_binary(Bin) -> unicode:characters_to_list(Bin);
to_list(List) when is_list(List) -> List.

%% Each prose-fact functor by NAME, per the argument-order warning above.
text_doc({comment, File, Line, Text}) ->
    {true, {comment, File, Line, Text}};
text_doc({paragraph, File, Text, Line}) ->
    {true, {paragraph, File, Line, Text}};
text_doc({heading, File, _Level, Text, Line}) ->
    {true, {heading, File, Line, Text}};
text_doc({blockquote, File, Text, Line}) ->
    {true, {blockquote, File, Line, Text}};
text_doc(_) ->
    false.

add_docs(_Index, [], _Id) ->
    ok;
add_docs(Index, [{_Kind, _File, _Line, Text} | Rest], Id) ->
    case symbolic_text:index_add_doc(Index, Id, to_bin(Text)) of
        ok -> add_docs(Index, Rest, Id + 1);
        {error, Reason} -> erlang:error({bad_text, Reason})
    end.

add_function_docs(_Index, [], _Id) ->
    ok;
add_function_docs(Index, [{_Name, _Arity, _File, _Line, SearchText} | Rest], Id) ->
    case symbolic_text:index_add_doc(Index, Id, SearchText) of
        ok -> add_function_docs(Index, Rest, Id + 1);
        {error, Reason} -> erlang:error({bad_function_text, Reason})
    end.

%% The extraction layer's text arguments are binaries (node_text/2 over a
%% binary source) but call sites and older paths may hand over lists;
%% paths may be atoms (PathAtom in the extractors). Normalize to a UTF-8
%% binary — the NIF requires one.
to_bin(Text) when is_binary(Text) -> Text;
to_bin(Text) when is_list(Text) -> unicode:characters_to_binary(Text);
to_bin(Text) when is_atom(Text) -> atom_to_binary(Text, utf8).

%% First 200 characters (not bytes — never split a codepoint) for the
%% JSON output; full texts can be whole doc-comments long.
excerpt(Text) ->
    unicode:characters_to_binary(
        lists:sublist(unicode:characters_to_list(to_bin(Text)), 200)).

fail(Fmt, Args) ->
    io:put_chars(standard_error, io_lib:format(Fmt ++ "~n", Args)),
    halt(1).
