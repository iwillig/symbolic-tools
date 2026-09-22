%%% `symbolic serve` — the MCP server. Exposes the in-memory codebase
%%% cache (symbolic_codebase) over the Model Context Protocol via `erlmcp`.
%%% See docs/erlang-mcp-design.md.
%%%
%%% Three tools, refocused on "an LLM asks about a codebase":
%%%   parse     scan a directory, extract facts, cache them in memory
%%%   query     prove a Prolog goal against the cache, all solutions (capped)
%%%   overview  report the current state of the cached fact base
%%%
%%% Uses `erlmcp_stdio` (not the lower-level `erlmcp_server:start_link/2`
%%% from erlmcp's README) — confirmed by testing: the README's API starts a
%%% process that isn't wired into the app's real stdin/stdout loop unless the
%%% `erlmcp` OTP application itself is started first; `erlmcp_stdio:start/0`
%%% goes through `erlmcp_sup` (erlmcp's actual top-level supervisor) and is
%%% the API that works.
%%%
%%% Tool handlers are stateless (Params -> Result); the stateful cache lives
%%% in the separately-started, registered symbolic_codebase process. Handlers
%%% catch everything and always return a JSON binary — they never crash, so
%%% behavior doesn't depend on erlmcp's own handler wrapping.
%%%
%%% Logging goes through Erlang's `logger` to a file, never to standard
%%% output: stdout is the MCP JSON-RPC transport (see the smoke test in
%%% docs/erlang-mcp-design.md), and any log line written there would
%%% corrupt the stream from the client's point of view.
-module(symbolic_serve).
-include_lib("kernel/include/logger.hrl").
-export([run/0]).
%% Exported for symbolic_serve_tests.erl only — exercising these three
%% directly also exercises every rendering/error helper below them
%% (json/1, query_result/3, solution_to_map/1, meta_to_json/1,
%% parse_error_str/1, error_str/1, caught_str/3, limit_of/1, jstr/1,
%% to_list/1), so nothing else needs a separate export. run/0,
%% setup_logging/0, register_tools/0 stay untested by EUnit — they touch
%% global logger/erlmcp state (removing the default logger handler,
%% starting the erlmcp application) that a unit test shouldn't mutate;
%% verified instead by the manual stdio smoke tests (see
%% docs/erlang-mcp-design.md).
-export([handle_parse/1, handle_query/1, handle_overview/1]).

run() ->
    ok = setup_logging(),
    ?LOG_INFO("symbolic serve starting"),
    {ok, _} = application:ensure_all_started(erlmcp),
    {ok, _CachePid} = symbolic_codebase:start_link(),
    ok = erlmcp_stdio:start(),
    ok = register_tools(),
    ?LOG_INFO("symbolic serve ready: tools parse, query, overview registered"),
    receive after infinity -> ok end.

%% A file under the platform's standard log directory (e.g. ~/Library/Logs
%% on macOS, $XDG_STATE_HOME or ~/.local/state on Linux), independent of
%% the cwd `symbolic serve` happens to be launched from.
%%
%% The kernel's own `default` logger handler targets standard_io (real
%% stdout) and can't be pointed elsewhere at runtime (logger_std_h raises
%% illegal_config_change on a type change) — confirmed by raising the
%% primary log level to `info` and watching application/supervisor
%% PROGRESS REPORTs land on stdout, right in the JSON-RPC stream. So it's
%% removed outright rather than merely reconfigured, and our own handler
%% (unfiltered, so it also captures those same OTP/SASL reports) replaces
%% it as the only sink.
setup_logging() ->
    LogDir = filename:basedir(user_log, "symbolic"),
    ok = filelib:ensure_path(LogDir),
    LogFile = filename:join(LogDir, "serve.log"),
    ok = logger:set_primary_config(level, info),
    ok = logger:remove_handler(default),
    ok = logger:add_handler(symbolic_serve_file, logger_std_h,
             #{config => #{type => {file, LogFile}},
               formatter => {logger_formatter, #{}}}),
    ?LOG_INFO("logging to ~s", [LogFile]),
    ok.

register_tools() ->
    ok = erlmcp_stdio:add_tool(<<"parse">>,
        <<"Scan a directory, extract codebase facts, and cache them in "
          "memory. Replaces any previously cached codebase. Also "
          "auto-consults that project's `.symbolic/rules.pl` derived-"
          "predicate library, if one is found by walking up from the "
          "scanned directory (pass `rules` to use a specific file "
          "instead). Returns a summary of what was loaded (files, "
          "languages, fact counts, and which rules file - if any - was "
          "consulted, as `rules_file`); check `rules_file` before relying "
          "on a derived predicate. A bad rules file fails the whole call "
          "and leaves any previously cached codebase untouched.">>,
        fun handle_parse/1,
        #{<<"type">> => <<"object">>,
          <<"properties">> => #{
              <<"path">> => #{<<"type">> => <<"string">>,
                             <<"description">> =>
                                 <<"Directory to scan for source files">>},
              <<"rules">> => #{<<"type">> => <<"string">>,
                             <<"description">> =>
                                 <<"Prolog rules file to consult instead of "
                                   "auto-discovering .symbolic/rules.pl">>}},
          <<"required">> => [<<"path">>]}),
    ok = erlmcp_stdio:add_tool(<<"query">>,
        <<"Prove a Prolog goal against the cached codebase and return all "
          "solutions (capped). Raw facts, from `overview`: "
          "defines(Function, Arity, Params, File, Line), "
          "calls(Caller, CallerArity, CallSpec, File, Line) where CallSpec "
          "is local(Callee, ArgCount)/remote(Module, Function, ArgCount)/"
          "member(Object, Method, ArgCount), doc(Function, Arity, File, "
          "Line, Text), branch(Function, Arity, Kind, File, Line) - a "
          "decision point, for real complexity, "
          "expr(Id, Function, Arity, Kind, File, Line)/expr_operator(Id, Op)/"
          "expr_operand(Id, Role, ChildId)/literal(Id, Function, Arity, "
          "LitKind, Value, File, Line)/expr_ref(Id, Function, Arity, Name, "
          "File, Line) - what a decision point actually compares (Erlang/"
          "TypeScript only; Id is a byte span, not Function/Arity/File/"
          "Line), scope(ScopeId, Kind, ParentScopeId, File)/"
          "var_decl(Id, Name, Kind, ScopeId, File, Line)/"
          "var_ref(Id, Name, ScopeId, RefKind, File, Line)/"
          "resolves_to(RefId, DeclId) - variables and scope (TypeScript "
          "only; var_decl's Kind is var/let/const/param/import; "
          "resolves_to(_, undefined) means not declared in "
          "anything tracked, not necessarily a bug - no globals "
          "allowlist), import_decl(Module, File, Line)/"
          "export_decl(Name, Kind, File, Line) - imports/exports "
          "(TypeScript only), "
          "stmt_block(BlockId, Function, Arity, Kind, File, Line)/"
          "stmt(Id, BlockId, Index, Kind, File, Line)/"
          "last_switch_case(BlockId)/"
          "braceless_body(Function, Arity, Kind, File, Line)/"
          "return_stmt(Function, Arity, HasValue, File, Line) - "
          "statement/block structure (TypeScript only; stmt_block's Kind "
          "is block/switch_case/switch_default; stmt's Index is the "
          "child's raw position among ALL a block's named children, not "
          "renumbered after excluding comments/a switch_case's own "
          "value), comment/3, heading/4, "
          "paragraph/3, code_block/3, config_value/4, config_section/3. "
          "Prefer an existing derived "
          "predicate over reinventing it inline, when `parse`'s "
          "`rules_file` shows a library was consulted: callees/2, "
          "callers/3, undocumented/4, calls_object/2, stale_doc_example/4, "
          "duplicate_name/3 (+all_duplicate_names/1), self_recursive/3, "
          "fan_out/3, fan_in/3, top_fan_out/2, top_fan_in/2, "
          "no_local_callers/3 (+all_no_local_callers/1), "
          "undocumented_comment/3, risky_call/3 (+all_risky_calls/1), "
          "module_dependency/2 (+all_module_dependencies/1), reaches/2, "
          "take/3, plus ESLint-style checks: too_many_params/4, "
          "too_complex/3, mutual_recursion/2 (+all_mutual_recursion/1 - "
          "bind at least one side, both unbound can time out), "
          "truly_uncalled/3 (+all_truly_uncalled/1), banned_call/4 "
          "(+all_banned_calls/1 - edit banned_target/2 for this "
          "project), god_file/2 (+all_god_files/1), real_complexity/4 "
          "(+too_complex_real/4, +all_too_complex_real/1 - real McCabe-"
          "style branch counting on branch/5, more accurate than "
          "too_complex/3's fan-out proxy), short_name/4 "
          "(+all_short_names/1 - edit allow_short_name/1 for names like "
          "ok/id that should stay unflagged), self_compare/4 "
          "(+all_self_compares/1) and yoda_condition/5 "
          "(+all_yoda_conditions/1) - both on top of expr/6, "
          "unused_var/4 (+all_unused_vars/1) and shadowed_var/5 "
          "(+all_shadowed_vars/1) - both on top of scope/4, plus "
          "prefer_const/4 (+all_prefer_const/1), redeclared_var/5 "
          "(+all_redeclared_vars/1), shadows_restricted_name/4 "
          "(+all_restricted_name_shadows/1 - edit restricted_name/1), "
          "use_before_define/5 (+all_use_before_define/1), and "
          "undeclared_var/4 (+all_undeclared_vars/1 - edit "
          "known_global/1 for this runtime's own globals; that's what "
          "makes it a real no-undef check). `new X(...)` is calls/5's "
          "new(Constructor, ArgCount) shape (TypeScript only), plus "
          "bare_new/5 (Caller, Arity, Constructor, File, Line - a `new "
          "X()` whose value is discarded outright) for no_new/4 "
          "(+all_no_new/1) specifically; also no_new_wrapper/5 "
          "(+all_no_new_wrappers/1), no_new_func/4 (+all_no_new_func/1), "
          "no_object_constructor/4 (+all_no_object_constructors/1 - "
          "checks new Object() and bare Object()), "
          "prefer_regex_literal/4 (+all_prefer_regex_literals/1 - "
          "checks new RegExp(...) and bare RegExp(...)), and "
          "lowercase_constructor/5 (+all_lowercase_constructors/1). "
          "An import binding is itself a var_decl/6 (Kind=import, "
          "TypeScript only) so unused_var/4/shadowed_var/5 apply for "
          "free; plus import_decl(Module, File, Line)/"
          "export_decl(Name, Kind, File, Line) for duplicate_import/4 "
          "(+all_duplicate_imports/1), restricted_import/3 "
          "(+all_restricted_imports/1 - edit restricted_module/1, no "
          "universal default exists), and restricted_export/4 "
          "(+all_restricted_exports/1 - edit restricted_export_name/1). "
          "On top of stmt_block/6+stmt/6+last_switch_case/1+"
          "braceless_body/5+return_stmt/5 (TypeScript only): "
          "no_empty_block/5 (+all_no_empty_blocks/1 - {} blocks only, "
          "not a function's own empty body), unreachable_stmt/4 "
          "(+all_unreachable_stmts/1 - anything after a "
          "return/throw/break/continue in the same block), "
          "no_fallthrough_case/5 (+all_no_fallthrough_cases/1 - a "
          "non-empty switch_case/switch_default whose last statement "
          "isn't a terminator and isn't the last clause; an empty case "
          "stacking into the next, e.g. `case 1: case 2: ...`, is "
          "exempt), curly_violation/5 (+all_curly_violations/1 - an "
          "if/else/for/while body that isn't a real {} block), and "
          "inconsistent_return/3 (+all_inconsistent_returns/1 - one "
          "function with both a valued and a bare return; no "
          "control-flow-path analysis, just whole-function agreement). "
          "Docs: docs/lint-queries.md.">>,
        fun handle_query/1,
        #{<<"type">> => <<"object">>,
          <<"properties">> => #{
              <<"goal">> => #{<<"type">> => <<"string">>,
                             <<"description">> =>
                                 <<"Prolog goal, e.g. calls(X, local(foo), _, _)">>},
              <<"limit">> => #{<<"type">> => <<"integer">>,
                              <<"description">> =>
                                  <<"Max solutions to return (default 50)">>}},
          <<"required">> => [<<"goal">>]}),
    ok = erlmcp_stdio:add_tool(<<"overview">>,
        <<"Report the current state of the cached fact base: whether a "
          "codebase is loaded, how many files/languages, and fact counts by "
          "predicate. Call it after `parse`, or to check state before "
          "`query`.">>,
        fun handle_overview/1,
        #{<<"type">> => <<"object">>, <<"properties">> => #{}}),
    ok.

%% Tool handlers — each returns a JSON binary and never crashes.

handle_parse(#{<<"path">> := Path} = Params) ->
    try
        PathStr = to_list(Path),
        RulesOverride = case maps:find(<<"rules">>, Params) of
            {ok, R} -> to_list(R);
            error -> undefined
        end,
        ?LOG_INFO("parse: path=~s rules=~p", [PathStr, RulesOverride]),
        case symbolic_codebase:parse(PathStr, RulesOverride) of
            {ok, Meta} ->
                ?LOG_INFO("parse: ok files=~p total_facts=~p",
                          [maps:get(files, Meta), maps:get(total_facts, Meta)]),
                json(#{ok => meta_to_json(Meta)});
            {error, ParseErr} ->
                ?LOG_ERROR("parse: error=~p", [ParseErr]),
                json(#{error => parse_error_str(ParseErr)})
        end
    catch
        Class:Crash:ST ->
            ?LOG_ERROR("parse: crashed ~p:~p~n~p", [Class, Crash, ST]),
            json(#{error => caught_str(Class, Crash, ST)})
    end.

handle_query(Params) ->
    try
        Goal = to_list(maps:get(<<"goal">>, Params)),
        Limit = limit_of(Params),
        ?LOG_INFO("query: goal=~s limit=~p", [Goal, Limit]),
        Result = symbolic_codebase:query(Goal, Limit),
        log_query_result(Result),
        render_query(Result, Limit)
    catch
        Class:Crash:ST ->
            ?LOG_ERROR("query: crashed ~p:~p~n~p", [Class, Crash, ST]),
            json(#{error => caught_str(Class, Crash, ST)})
    end.

log_query_result({ok, Solutions}) ->
    ?LOG_INFO("query: ok count=~p", [length(Solutions)]);
log_query_result({truncated, Solutions}) ->
    ?LOG_INFO("query: truncated count=~p", [length(Solutions)]);
log_query_result({error, QueryErr}) ->
    ?LOG_ERROR("query: error=~p", [QueryErr]).

render_query({ok, Solutions}, Limit) ->
    json(query_result(Solutions, false, Limit));
render_query({truncated, Solutions}, Limit) ->
    json(query_result(Solutions, true, Limit));
render_query({error, QueryErr}, _Limit) ->
    json(#{error => error_str(QueryErr)}).

handle_overview(_Params) ->
    ?LOG_INFO("overview"),
    try
        case symbolic_codebase:overview() of
            {ok, Meta} -> json(#{ok => meta_to_json(Meta)});
            {not_parsed, NotParsed} -> json(#{ok => NotParsed})
        end
    catch
        Class:Crash:ST ->
            ?LOG_ERROR("overview: crashed ~p:~p~n~p", [Class, Crash, ST]),
            json(#{error => caught_str(Class, Crash, ST)})
    end.

%% Rendering — everything out the door is a JSON binary via jsx.

json(Term) ->
    jsx:encode(Term).

%% {solutions: [VarMap], count: N, truncated: Bool} — uniform, LLM-friendly.
query_result(Solutions, Truncated, Limit) ->
    #{solutions => [solution_to_map(S) || S <- Solutions],
      count => length(Solutions),
      truncated => Truncated,
      limit => Limit}.

%% One solution (a [{Name, Value}] binding list) -> a JSON object mapping
%% variable names to their JSON-encoded values.
solution_to_map(Bindings) ->
    maps:from_list(
        [{var_name_key(Name), symbolic_term_json:encode_term(Value)}
         || {Name, Value} <- Bindings]).

%% erlog names user variables as atoms and its own internal/anonymous
%% variables as integers; render both as readable JSON keys. Must be binaries
%% (not charlists): jsx only encodes map keys that are atom/binary/integer, and
%% a bare list of ints would hit a function_clause in jsx_encoder:unpack/3.
var_name_key(A) when is_atom(A) -> atom_to_binary(A, utf8);
var_name_key(N) when is_integer(N) -> <<"_">> ++ integer_to_binary(N).

meta_to_json(Meta) ->
    #{
        loaded => maps:get(loaded, Meta),
        files => maps:get(files, Meta),
        file_list => [jstr(F) || F <- maps:get(file_list, Meta)],
        %% languages are Erlang charlists; jsx encodes a bare int-list as a
        %% number-array, so convert to binaries so they render as JSON strings.
        languages => [jstr(L) || L <- maps:get(languages, Meta)],
        facts_by_predicate =>
            #{atom_to_binary(K, utf8) => V
              || {K, V} <- maps:to_list(maps:get(facts_by_predicate, Meta))},
        total_facts => maps:get(total_facts, Meta),
        %% undefined -> null when no rules file was found/given, so an
        %% agent can tell "no derived predicates loaded" from "loaded but
        %% path unknown" apart at a glance, without guessing from count.
        rules_file => case maps:get(rules_file, Meta, undefined) of
            undefined -> null;
            RulesPath -> jstr(RulesPath)
        end
    }.

%% Error strings — JSON-safe (always a binary), human/LLM-readable.
%%
%% Plain ASCII only in these literals, deliberately: a `<<"...">>` binary
%% literal's characters are packed as plain 8-bit integer segments unless
%% each is marked `/utf8`, so a non-ASCII codepoint like an em dash (U+2014)
%% silently truncates to a bogus single byte (0x14, a control character)
%% instead of raising an error — found via the friendly-error smoke test
%% for a non-existent predicate coming back corrupted rather than crashing.
parse_error_str({no_such_directory, Dir}) ->
    <<"no such directory: ", (jstr(Dir))/binary>>;
parse_error_str({nif_not_loadable, _Reason}) ->
    <<"the tree-sitter NIF (symbolic_ts) isn't loadable in this build - "
      "run via a `rebar3 release`; see docs/cli-erlang.md">>;
parse_error_str({rules_error, RulesPath, Reason}) ->
    iolist_to_binary([<<"cannot consult rules ">>, jstr(RulesPath), <<": ">>,
                       jstr(io_lib:format("~p", [Reason])),
                       <<" - parse failed, any previously cached codebase "
                         "is unchanged">>]);
parse_error_str(Reason) ->
    error_str(Reason).

error_str(not_parsed) ->
    <<"no codebase is cached - call `parse` first, then `query`">>;
error_str({existence_error, procedure, {'/', F, A}}) ->
    iolist_to_binary([<<"no such predicate: ">>, atom_to_binary(F, utf8),
                       <<"/">>, integer_to_binary(A),
                       <<" - see `overview` for available predicates">>]);
error_str(timeout) ->
    <<"query timed out - the goal may be cyclic or unbounded; try a more "
      "specific goal">>;
error_str(Reason) ->
    jstr(io_lib:format("~p", [Reason])).

caught_str(Class, Reason, ST) ->
    jstr(io_lib:format("caught ~p: ~p ~p", [Class, Reason, ST])).

limit_of(Params) ->
    case maps:find(<<"limit">>, Params) of
        {ok, N} when is_integer(N) -> N;
        _ -> 50
    end.

%% unicode:characters_to_binary, not list_to_binary: io_lib:format can return
%% deep/nested iodata (e.g. it nests a literal sub-string for some ~p args),
%% which list_to_binary rejects with badarg since it requires a flat list.
jstr(B) when is_binary(B) -> B;
jstr(S) when is_list(S) -> unicode:characters_to_binary(S).

to_list(B) when is_binary(B) -> binary_to_list(B);
to_list(L) when is_list(L) -> L.
