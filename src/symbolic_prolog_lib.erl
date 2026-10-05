%%% Extends the erlog Prolog engine with sub_atom/5 (ISO's substring
%%% predicate), sub_text/5 (the same shape, over a binary instead of an
%%% atom), and atom_from_binary/2 (a binary->atom bridge, §2.1 below),
%%% implemented as real Erlang code, executed inside erlog's own
%%% resolution engine — not a `.symbolic/rules.pl` shim.
%%%
%%% erlog has no `sub_atom/5` natively (docs/erlog-missing-builtins.md),
%%% and it is the single most common thing an LLM agent reaches for that
%%% erlog doesn't provide: `sub_atom(Name, _, _, _, foo)` to check
%%% whether Name contains "foo" — the ISO idiom, no new predicate name to
%%% learn.
%%%
%%% `sub_atom/5` only ever accepts an atom (a `type_error` otherwise), so
%%% it does nothing for `comment/3`, `doc/5`, or `paragraph/3`'s free-text
%%% `Text` field — those are binaries, deliberately never atoms (an
%%% arbitrary-length comment/paragraph interned as an atom would leak into
%%% the BEAM's atom table forever; see `docs/prolog-schema.md`). `sub_text/5`
%%% is the same predicate, the same call shape, over a binary: `sub_text(
%%% Text, _, _, _, "prolog")` to check whether Text contains "prolog".
%%%
%%% `sub_atom/5`'s `Sub` comes back as an atom because that's what a caller
%%% naturally writes for it (`oo`, unquoted). `sub_text/5`'s `Sub` comes
%%% back as a plain code list, NOT a binary — verified against erlog's own
%%% scanner/parser (`erlog_scan.xrl`, `erlog_parse.erl`), not assumed: a
%%% double-quoted goal literal like `"prolog"` is a code list under erlog's
%%% ISO-default `double_quotes(codes)` behavior, never a binary (there is
%%% no Prolog syntax for a binary literal at all here) — so `Sub` has to be
%%% a code list too, or it could never unify against anything a caller can
%%% actually type. Both predicates share one internal search
%%% (`sub_chars_search/11` below); the only difference is what each does
%%% with a matched character range — `list_to_atom/1` for `sub_atom/5`,
%%% nothing at all for `sub_text/5`.
%%%
%%% No fork of erlog, no vendored copy: this uses erlog's own real
%%% extension mechanism, the one it already uses on itself. `erlog.erl`'s
%%% `new/2` builds its initial database by folding `Mod:load(Db)` over
%%% its own bundled library modules (`erlog_bips`, `erlog_lib_dcg`,
%%% `erlog_lib_lists`); `erlog:load/2` is the SAME fold exposed publicly
%%% for exactly one more module: `Db1 = Mod:load(St#est.db), {ok,
%%% Erl#erlog{est=St#est{db=Db1}}}`. `prolog_session:init/1` calls
%%% `erlog:load(symbolic_prolog_lib, Erl)` right after `erlog:new/0` to
%%% register this module the identical way.
%%%
%%% `-include_lib("erlog/src/erlog_int.hrl")` reaches directly into the
%%% erlog dependency's own header for the `#est{}`/`#cp{}` record shapes
%%% a compiled-procedure callback is handed and must pattern-match on —
%%% the exact same records `erlog_bips.erl` and `erlog_lib_lists.erl`
%%% match on to implement `atom_length/2`, `append/3`, `member/2`, etc.
%%% `-include_lib/1` only requires "AppName/SomePath" — it does not
%%% require SomePath to start with "include/" — so this reaches
%%% erlog's real header without erlog needing to publish one. This *is*
%%% a real coupling to erlog's internals rather than a documented,
%%% version-guaranteed API: a future erlog release that changes
%%% `#est{}`'s field names or arity would fail this module at COMPILE
%%% time (a record field/arity mismatch is a compile error, not a
%%% silent runtime misbehaviour), which is the same exposure
%%% `erlog_bips.erl`/`erlog_lib_lists.erl` already carry as erlog's own
%%% code — we are not more exposed than erlog's own library modules are.
-module(symbolic_prolog_lib).

-include_lib("erlog/src/erlog_int.hrl").

-export([load/1]).
-export([sub_atom_5/3, sub_text_5/3, atom_from_binary_2/3, count_pairs_2/3]).

-import(erlog_int, [prove_body/2, fail/1, unify/3, add_compiled_proc/4]).

%% load(Database) -> Database.
%%  Register sub_atom/5, sub_text/5 and atom_from_binary/2 as compiled
%%  procedures — same shape as erlog_lib_lists:load/1.
load(Db0) ->
    Db1 = add_compiled_proc({sub_atom, 5}, ?MODULE, sub_atom_5, Db0),
    Db2 = add_compiled_proc({sub_text, 5}, ?MODULE, sub_text_5, Db1),
    Db3 = add_compiled_proc({atom_from_binary, 2}, ?MODULE, atom_from_binary_2, Db2),
    add_compiled_proc({count_pairs, 2}, ?MODULE, count_pairs_2, Db3).

%% count_pairs_2(Head, NextGoal, State) -> void.
%%
%% count_pairs(Pairs, Counts) — one Key-N term per distinct key, N = the
%% number of `Key-Value` pairs sharing that Key, sorted by standard term
%% order. Native Erlang (a map fold + one sort), because every pure-Prolog
%% shape of grouped counting — an interpreted run-length over a sorted
%% list, a member scan per key, a findall per key — is quadratic or
%% choice-point-per-element in erlog's interpreter (measured against this
%% project's own real base: 3.2s interpreted for a 3200-pair list that
%% costs microseconds here). The .symbolic/rules.pl fan-out/fan-in
%% rankings (top_fan_out/2, top_fan_in/2) are built on it; any grouped
%% count over a usorted Key-Value list is its use case.
%%
%% Pairs must be bound; Counts is always output (the only mode the
%% library needs — same restriction sub_atom/5 makes on its Atom).
%% Elements must be Key-Value terms; anything else is a type error
%% rather than a silent skip, so a mis-shaped pipeline fails loudly.
%% Input order is irrelevant (the map groups, the sort orders), but
%% feeding it the usorted output of sort/2 is the intended shape.
count_pairs_2({count_pairs, Pairs0, Counts0}, Next, #est{bs = Bs} = St) ->
    case deref(Pairs0, Bs) of
        Pairs when is_list(Pairs) ->
            L1 = erlog_int:dderef_list(Pairs, Bs),
            Counts = count_pairs_1(L1, #{}),
            erlog_int:unify_prove_body(Counts0, Counts, Next, St);
        {_} ->
            erlog_int:instantiation_error(St);
        Other ->
            erlog_int:type_error(list, Other, St)
    end.

count_pairs_1([], Counts) ->
    lists:sort([{'-', K, N} || {K, N} <- maps:to_list(Counts)]);
count_pairs_1([{'-', K, _} | Rest], Counts) ->
    count_pairs_1(Rest, maps:update_with(K, fun(N) -> N + 1 end, 1, Counts));
count_pairs_1([Bad | _], _Counts) ->
    error({count_pairs_bad_element, Bad}).

%% sub_atom_5(Head, NextGoal, State) -> void.
%%
%% sub_atom(Atom, Before, Length, After, Sub) — ISO sub_atom/5, restricted
%% to Atom bound (the only mode this project ever needs: "does this atom
%% contain X", or "list every substring of this atom"). Before, Length,
%% After and Sub may each be bound or unbound in any combination; every
%% (Before,Length) split of Atom's characters is generated in
%% increasing-Before-then-increasing-Length order (the same order
%% SWI-Prolog uses) and unified against whatever the caller already
%% bound, backtracking to the next split on request — exactly the
%% choice-point pattern erlog_lib_lists:append_3/3 already uses for
%% append/3, just walking character-index splits instead of list cells.
sub_atom_5({sub_atom, A0, B0, L0, Af0, S0}, Next, #est{bs = Bs} = St) ->
    case deref(A0, Bs) of
        A when is_atom(A) ->
            Codes = atom_to_list(A),
            Total = length(Codes),
            sub_chars_search(Codes, Total, 0, 0, B0, L0, Af0, S0, Next, St, fun list_to_atom/1);
        {_} ->
            erlog_int:instantiation_error(St);
        Other ->
            erlog_int:type_error(atom, Other, St)
    end.

%% sub_text_5(Head, NextGoal, State) -> void.
%%
%% sub_text(Text, Before, Length, After, Sub) — the same predicate as
%% sub_atom/5 above, restricted to Text bound the same way, over a binary
%% instead of an atom: the type `comment/3`, `doc/5`, and `paragraph/3`
%% actually store their free text as (see this module's header comment).
%%
%% `Sub` comes back as a plain code list (an Erlang string), NOT a
%% binary — verified against erlog's own vendored source
%% (`erlog_scan.xrl`'s string rule: `{token,{string,TokenLine,chars(S)}}`;
%% `erlog_parse.erl`'s `term/3` passes that list straight through with no
%% conversion), not assumed: a double-quoted goal literal like `"prolog"`
%% is erlog's ISO default `double_quotes(codes)` behavior, a code list,
%% not a binary. `sub_atom/5`'s `Sub` is an atom because that's what a
%% caller naturally writes unquoted (`oo`); the equivalent "what a caller
%% naturally writes" for free text is a double-quoted literal, so `Sub`
%% has to come back as a code list to unify against one at all — wrapping
%% it in `list_to_binary/1` instead (this module's first attempt, caught
%% by its own EUnit case rather than shipped) would make `Sub` permanently
%% unable to unify against anything a caller can actually type.
sub_text_5({sub_text, T0, B0, L0, Af0, S0}, Next, #est{bs = Bs} = St) ->
    case deref(T0, Bs) of
        T when is_binary(T) ->
            Codes = binary_to_list(T),
            Total = length(Codes),
            sub_chars_search(Codes, Total, 0, 0, B0, L0, Af0, S0, Next, St, fun(Cs) -> Cs end);
        {_} ->
            erlog_int:instantiation_error(St);
        Other ->
            erlog_int:type_error(binary, Other, St)
    end.

%% Walk (Before,Length) candidates starting at the given position, shared
%% by sub_atom_5/3 and sub_text_5/3 — identical search either way, the
%% only difference being ToTerm, which rebuilds a matched character range
%% back into the caller's own type (list_to_atom/1 or list_to_binary/1)
%% before unifying it against Sub. On the first candidate that unifies
%% against the caller's own Before/Length/After/Sub arguments, install a
%% choice point that resumes the walk from the NEXT candidate on
%% backtrack, then prove Next. Exhausting every split with no match fails
%% outright.
sub_chars_search(Codes, Total, Before, Length, B0, L0, Af0, S0, Next,
        #est{cps = Cps, bs = Bs0} = St, ToTerm) when Before =< Total ->
    After = Total - Before - Length,
    Sub = ToTerm(lists:sublist(Codes, Before + 1, Length)),
    case try_unify4(B0, Before, L0, Length, Af0, After, S0, Sub, Bs0) of
        {succeed, Bs1} ->
            case next_split(Before, Length, Total) of
                done ->
                    prove_body(Next, St#est{bs = Bs1});
                {NBefore, NLength} ->
                    FailFun = fun(LCp, LCps, Lst) ->
                        fail_sub_chars(LCp, LCps, Lst, Codes, Total, NBefore, NLength, B0, L0, Af0, S0, ToTerm)
                    end,
                    Cp = #cp{type = compiled, data = FailFun, next = Next, bs = Bs0, vn = St#est.vn},
                    prove_body(Next, St#est{cps = [Cp | Cps], bs = Bs1})
            end;
        fail ->
            case next_split(Before, Length, Total) of
                done -> fail(St);
                {NBefore, NLength} ->
                    sub_chars_search(Codes, Total, NBefore, NLength, B0, L0, Af0, S0, Next, St, ToTerm)
            end
    end;
sub_chars_search(_Codes, _Total, _Before, _Length, _B0, _L0, _Af0, _S0, _Next, St, _ToTerm) ->
    fail(St).

%% Resumed on backtrack: #cp{}'s own saved bs/vn are the bindings from
%% BEFORE the candidate that just succeeded, exactly like
%% erlog_lib_lists:fail_append_3/6 restores Bs0/Vn from the choice point
%% rather than trusting whatever St carries at backtrack time.
fail_sub_chars(#cp{next = Next, bs = Bs0, vn = Vn}, Cps, St, Codes, Total, Before, Length, B0, L0, Af0, S0, ToTerm) ->
    sub_chars_search(Codes, Total, Before, Length, B0, L0, Af0, S0, Next, St#est{cps = Cps, bs = Bs0, vn = Vn}, ToTerm).

%% next_split(Before, Length, Total) -> {NBefore,NLength} | done.
%%  Enumeration order: Before 0..Total, and for each Before, Length
%%  0..(Total-Before).
next_split(Before, Length, Total) when Length < Total - Before ->
    {Before, Length + 1};
next_split(Before, _Length, Total) when Before < Total ->
    {Before + 1, 0};
next_split(_Before, _Length, _Total) ->
    done.

%% try_unify4(...) -> {succeed,Bs} | fail.
%%  Chain four unifications against one growing binding set, short-
%%  circuiting on the first failure.
try_unify4(B0, Before, L0, Length, Af0, After, S0, Sub, Bs0) ->
    case unify(B0, Before, Bs0) of
        {succeed, Bs1} ->
            case unify(L0, Length, Bs1) of
                {succeed, Bs2} ->
                    case unify(Af0, After, Bs2) of
                        {succeed, Bs3} -> unify(S0, Sub, Bs3);
                        fail -> fail
                    end;
                fail -> fail
            end;
        fail -> fail
    end.

%% atom_from_binary_2(Head, NextGoal, State) -> void.
%%
%% atom_from_binary(Binary, Atom) — the docs/reviewing-llm-output.md §2.1
%% binary->atom bridge: converts a binary (e.g. a Markdown table_cell/6's
%% claimed function-name text) to the atom defines/5's own Function
%% values already are, so a claim like "the reference table says
%% Function=foo" can finally be cross-checked against real defines/5
%% facts at all — erlog has no built-in path from a binary to an atom
%% (docs/erlog-missing-builtins.md), the same gap sub_atom/5 left open
%% for atoms alone.
%%
%% Deliberately `binary_to_existing_atom/2`, never `binary_to_atom/2`:
%% this project already stores free text (comment/3, doc/5, paragraph/3)
%% as binaries specifically so an arbitrary-length string never leaks
%% into the BEAM's atom table (this module's own header comment).
%% `binary_to_existing_atom/2` only ever succeeds for a binary that
%% names an atom ALREADY interned — which a real defines/5 Function
%% value already is, by virtue of being a fact — and fails cleanly, not
%% a crash, for any binary that never named a real atom anywhere. That
%% makes this predicate structurally incapable of growing the atom
%% table itself, no matter what text is fed to it: Binary bound to
%% Atom, only mode this project needs (the direction table_cell/6's own
%% claimed text actually flows).
atom_from_binary_2({atom_from_binary, Bin0, Atom0}, Next, #est{bs = Bs} = St) ->
    case deref(Bin0, Bs) of
        Bin when is_binary(Bin) ->
            case catch binary_to_existing_atom(Bin, utf8) of
                {'EXIT', _} ->
                    fail(St);
                A ->
                    case unify(Atom0, A, Bs) of
                        {succeed, Bs1} -> prove_body(Next, St#est{bs = Bs1});
                        fail -> fail(St)
                    end
            end;
        {_} ->
            erlog_int:instantiation_error(St);
        Other ->
            erlog_int:type_error(binary, Other, St)
    end.

%% deref/2 is exported from erlog_int but only needed right at entry, once
%% each in sub_atom_5/3, sub_text_5/3 and atom_from_binary_2/3 — imported
%% narrowly here rather than in the top-level -import to keep that list
%% matching what's used more than twice.
deref(Term, Bs) -> erlog_int:deref(Term, Bs).
