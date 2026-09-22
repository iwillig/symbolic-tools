%%% `symbolic query --db <facts.dets> [--rules <rules.pl>] [--no-rules] <goal>` —
%%% load a fact database, consult a Prolog rule file alongside it, and
%%% prove a goal. See docs/cli-erlang.md, docs/erlang-mcp-design.md,
%%% docs/prolog-store.md.
%%%
%%% Facts used to be consulted from a `.pl` text file the same way rules
%%% are; now they come from a DETS-backed symbolic_fact_store.erl
%%% database instead, asserted directly as Erlang terms
%%% (prolog_session:load_facts/2) with no text parsing involved. `--rules`
%%% keeps the door open for hand-written derived rules (e.g.
%%% docs/lint-queries.md's rule library) via the ordinary text-based
%%% prolog_session:consult/2 — that path isn't buggy (it's real Prolog
%%% syntax a person wrote, not arbitrary extracted prose), so there's no
%%% reason to move it off text.
%%%
%%% When no `-rules` is given, a project's own rule library is found
%%% automatically rather than required on every invocation (see
%%% resolve_rules/3): a hand-written `-rules` path is passed straight
%%% through — it *replaces* the default rather than layering on top of it,
%%% since consulting the same predicate names twice would silently shadow
%%% one library with another — otherwise `.symbolic/rules.pl` is searched
%%% for by walking up the directory tree. run_result/3 — the halt-free
%%% core, and what the tests and any library caller use — stays strict:
%%% `undefined` there always means "consult nothing", never "go looking".
-module(symbolic_query).
-export([run/2, run/3, run/4]).
%% Exported for symbolic_query_tests.erl — run_result/3 is the halt-free
%% core (see its own doc comment); resolve_rules/3, maybe_consult_rules/2,
%% print_bindings/1 and name_to_list/1 are its remaining halt-free pieces.
-export([run_result/3, resolve_rules/3, maybe_consult_rules/2, print_bindings/1,
    name_to_list/1, discover_rules_from_dir/1]).

%% The project-relative default rule library: <project root>/.symbolic/rules.pl
-define(DEFAULT_RULES_DIR, ".symbolic").
-define(DEFAULT_RULES_FILE, "rules.pl").

run(DbPath, Goal) ->
    run(DbPath, undefined, false, Goal).

%% `undefined` RulesPath now means "auto-discover the project default"
%% (see resolve_rules/3) rather than "consult nothing" — that stricter
%% meaning belongs to run_result/3, below.
run(DbPath, RulesPath, Goal) ->
    run(DbPath, RulesPath, false, Goal).

%% The CLI's actual shape: an explicitly-given rules path, plus the
%% -no-rules switch. halt() belongs only here, at the CLI's edge —
%% everything that decides the outcome lives in run_result/3, which
%% returns a plain term instead of halting, precisely so EUnit can
%% exercise it directly. See docs/testing-erlang.md — using
%% erlang:halt/0,1 anywhere else (deep in business logic) is a well-known
%% Erlang anti-pattern: it kills the entire runtime, not just "the
%% current operation", which is exactly why run_result/3 couldn't be unit
%% tested before this split existed.
-spec run(file:filename(), file:filename() | undefined, boolean(), string()) -> no_return().
run(DbPath, RulesPath, NoRules, Goal) ->
    case run_result(DbPath, resolve_rules(DbPath, RulesPath, NoRules), Goal) of
        {solutions, Bindings} ->
            print_bindings(Bindings),
            halt(0);
        no_solution ->
            io:format("No.~n"),
            halt(1);
        {error, {no_such_db, Path}} ->
            fail("cannot read fact database: ~s", [Path]);
        {error, {rules_error, RulesPath1, Reason}} ->
            fail("cannot consult rules ~s: ~p", [RulesPath1, Reason]);
        {error, {query_failed, Reason}} ->
            fail("query failed: ~p", [Reason])
    end.

%% The halt-free core: load the fact database, optionally consult a
%% rules file, prove Goal, and report what happened as a plain term.
%% Starts (and always stops) its own prolog_session — a caller gets a
%% clean session either way, never one left running after this returns.
-spec run_result(file:filename(), file:filename() | undefined, string()) ->
    {solutions, [{atom(), term()}]} | no_solution
    | {error, {no_such_db, file:filename()}}
    | {error, {rules_error, file:filename() | undefined, term()}}
    | {error, {query_failed, term()}}.
run_result(DbPath, RulesPath, Goal) ->
    case filelib:is_regular(DbPath) of
        true -> run_checked(DbPath, RulesPath, Goal);
        false -> {error, {no_such_db, DbPath}}
    end.

run_checked(DbPath, RulesPath, Goal) ->
    Facts = symbolic_fact_store:read(DbPath),
    {ok, Pid} = prolog_session:start_link(),
    ok = prolog_session:load_facts(Pid, Facts),
    Result =
        case maybe_consult_rules(Pid, RulesPath) of
            ok -> query_result(Pid, Goal);
            {error, Reason} -> {error, {rules_error, RulesPath, Reason}}
        end,
    prolog_session:stop(Pid),
    Result.

maybe_consult_rules(_Pid, undefined) -> ok;
maybe_consult_rules(Pid, RulesPath) -> prolog_session:consult(Pid, RulesPath).

%% Which rules file (if any) to consult for this query.
%%   * an explicit path wins outright — discovery never second-guesses it
%%   * NoRules (the -no-rules switch) suppresses discovery, nothing consulted
%%   * otherwise look for the project's own .symbolic/rules.pl
-spec resolve_rules(file:filename(), file:filename() | undefined, boolean()) ->
    file:filename() | undefined.
resolve_rules(_DbPath, RulesPath, _NoRules) when RulesPath =/= undefined -> RulesPath;
resolve_rules(_DbPath, _RulesPath, true) -> undefined;
resolve_rules(DbPath, undefined, false) -> discover_rules(DbPath).

%% The database's own directory is the first search root, because a fact
%% database lives with the project it describes — that's what makes
%% `symbolic query -db .pi/facts.dets ...` from anywhere pick up the right
%% library. The rest of the walk (up from there, then the cwd as a second
%% starting point) is shared with `symbolic_codebase` (the MCP server's
%% in-memory cache, which has a scan directory instead of a db path) via
%% discover_rules_from_dir/1.
discover_rules(DbPath) ->
    discover_rules_from_dir(filename:dirname(filename:absname(DbPath))).

%% Two starting points, first hit wins: StartDir first (walked upwards —
%% the same "find the project root" rule git applies to `.git`, so this
%% works from a subdirectory too), then the current directory, for a
%% caller standing in the project while its target lives elsewhere (e.g.
%% a db kept outside the tree, under /tmp).
-spec discover_rules_from_dir(file:filename()) -> file:filename() | undefined.
discover_rules_from_dir(StartDir) ->
    case search_up(filename:absname(StartDir)) of
        Found when is_list(Found) -> Found;
        undefined ->
            case file:get_cwd() of
                {ok, Cwd} -> search_up(Cwd);
                {error, _Reason} -> undefined
            end
    end.

search_up(Dir) ->
    Candidate = filename:join([Dir, ?DEFAULT_RULES_DIR, ?DEFAULT_RULES_FILE]),
    case filelib:is_regular(Candidate) of
        true -> Candidate;
        false ->
            %% filename:dirname/1 of a root is that same root — the stop
            %% condition, so this terminates at "/" instead of looping.
            case filename:dirname(Dir) of
                Dir -> undefined;
                Parent -> search_up(Parent)
            end
    end.

query_result(Pid, Goal) ->
    case prolog_session:query(Pid, Goal) of
        {ok, Bindings} -> {solutions, Bindings};
        no_solution -> no_solution;
        {error, Reason} -> {error, {query_failed, Reason}}
    end.

print_bindings([]) ->
    io:format("Yes.~n");
print_bindings(Bindings) ->
    %% ~ts, not ~s, for the JSON value — see symbolic_parse.erl's
    %% print_fact/1 for why (a plain ~s mangles a binary's non-ASCII
    %% UTF-8 bytes).
    lists:foreach(
        fun({Name, Value}) ->
            io:format("~s = ~ts~n",
                [name_to_list(Name), jsx:encode(symbolic_term_json:encode_term(Value))])
        end,
        Bindings
    ).

fail(Fmt, Args) ->
    io:put_chars(standard_error, io_lib:format(Fmt ++ "~n", Args)),
    halt(1).

name_to_list(Name) when is_atom(Name) -> atom_to_list(Name);
name_to_list(Name) when is_integer(Name) -> "_" ++ integer_to_list(Name).
