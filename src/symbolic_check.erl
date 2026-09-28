%%% `symbolic check "<sentence>" -db <facts.dets> [-rules <rules.pl>]
%%% [-no-rules] [-model <path>]` — extract a claim from a sentence and
%%% check it against a real fact database in one call, instead of
%%% `symbolic extract` followed by a separate, hand-typed `symbolic
%%% query ... "check_claim(...)"`. See
%%% docs/reviewing-llm-output.md §3.2/§7 step 3's "convenience wire-up".
%%%
%%% Extraction (symbolic_extract, falling back to symbolic_extract_llm
%%% when `-model` is given and the DCG can't parse the sentence) and
%%% checking (check_claim/2, .symbolic/rules.pl, proved against a real
%%% fact database via symbolic_query) are both already-built, separately
%%% tested pieces — this module is pure composition, no new Prolog and
%%% no new extraction logic of its own.
%%%
%%% The one genuinely new piece: the extracted term never needs to
%%% round-trip through erlog's surface syntax on the way IN (tokenize/1
%%% builds goal text directly; the LLM tier's tool-call arguments come
%%% back as an already-decoded Erlang term) — but checking it against a
%%% SEPARATE fact-base session needs exactly that round-trip on the way
%%% OUT, to embed it in one `check_claim/2` goal string.
%%% `erlog_io:writeq1/1` (a real, existing erlog function already
%%% vendored by this project, the reverse of `read_string/1` used
%%% everywhere else here) does this — verified directly, not assumed:
%%% `erlog_io:writeq1({'/', foo, 2})` renders `"foo / 2"` (spaced, not
%%% `"foo/2"` tight), confirmed live against this project's own real
%%% fact base that the extra whitespace around an infix operator is
%%% insignificant and the term still parses back correctly.
-module(symbolic_check).
-export([run/5]).
%% Exported for symbolic_check_tests.erl — run_result/4 is the halt-free
%% core.
-export([run_result/4]).

%% halt() belongs only here, at the CLI's edge — see symbolic_query.erl's
%% own run/4 doc comment for why.
-spec run(file:filename(), file:filename() | undefined, boolean(), string(),
    file:filename() | undefined) -> no_return().
run(DbPath, RulesPath, NoRules, Sentence, ModelPath) ->
    %% Same rules-file auto-discovery symbolic_query's own CLI edge
    %% already uses — reused directly rather than duplicated, so
    %% `symbolic check` and `symbolic query` agree on which
    %% .symbolic/rules.pl a bare -db resolves to.
    Resolved = symbolic_query:resolve_rules(DbPath, RulesPath, NoRules),
    case run_result(DbPath, Resolved, Sentence, ModelPath) of
        {ok, Fact, Verdict} ->
            io:format("~ts~n", [jsx:encode(#{
                fact => symbolic_term_json:encode_term(Fact),
                verdict => symbolic_term_json:encode_term(Verdict)
            })]),
            halt(0);
        unrecognized ->
            io:format("Unrecognized.~n"),
            halt(1);
        {error, Reason} ->
            fail("cannot check claim: ~p", [Reason])
    end.

%% The halt-free core: extract, then (only on a real extracted claim)
%% render it back to Prolog text and check it via symbolic_query's own
%% run_result/3 — no separate fact-loading/rules-consulting logic here
%% at all, all of it already lives in and is tested by
%% symbolic_query_tests.erl. `RulesPath` here is the same strict
%% "undefined means consult nothing" contract symbolic_query:run_result/3
%% itself uses — auto-discovery, if wanted, is resolved once at the
%% run/5 CLI edge above, exactly where symbolic_query's own run/4 does
%% it.
-spec run_result(file:filename(), file:filename() | undefined, unicode:chardata(),
    file:filename() | undefined) ->
    {ok, term(), term()} | unrecognized | {error, term()}.
run_result(DbPath, RulesPath, Sentence, ModelPath) ->
    case symbolic_extract:run_result(Sentence, ModelPath) of
        {ok, Fact} -> check(DbPath, RulesPath, Fact);
        unrecognized -> unrecognized;
        {error, Reason} -> {error, {extract_error, Reason}}
    end.

check(DbPath, RulesPath, Fact) ->
    Goal = "check_claim(" ++ erlog_io:writeq1(Fact) ++ ", Verdict)",
    case symbolic_query:run_result(DbPath, RulesPath, Goal) of
        {solutions, [{'Verdict', Verdict}]} -> {ok, Fact, Verdict};
        {solutions, Other} -> {error, {unexpected_bindings, Other}};
        %% check_claim/2's own catch-all clause means every well-formed
        %% svo/3 term always has a verdict (true/false/unverifiable) —
        %% a real no_solution here means the rules file lacks
        %% check_claim/2 entirely, not a claim it declined to judge.
        no_solution -> {error, {no_check_claim_rule, Fact}};
        {error, Reason} -> {error, {check_error, Reason}}
    end.

fail(Fmt, Args) ->
    io:put_chars(standard_error, io_lib:format(Fmt ++ "~n", Args)),
    halt(1).
