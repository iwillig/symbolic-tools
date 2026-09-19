%%% `symbolic serve` — the MCP server. Exposes the same `prolog_session`
%%% engine `query`/`parse` already use, over the Model Context Protocol,
%%% via `erlmcp`. See docs/erlang-mcp-design.md.
%%%
%%% Uses `erlmcp_stdio` (not the lower-level `erlmcp_server:start_link/2`
%%% from erlmcp's own README example) — confirmed by testing: the README's
%%% API starts a process that isn't wired into the app's real stdin/stdout
%%% loop unless the `erlmcp` OTP application itself is started first.
%%% `erlmcp_stdio:start/0` goes through `erlmcp_sup` (erlmcp's actual
%%% top-level supervisor) and is the API that works.
%%%
%%% Four tools, one session per prolog_start_session call
%%% (prolog_session_registry maps an opaque session id to its
%%% prolog_session pid). Results are plain text, with each bound value
%%% rendered as JSON via symbolic_term_json.erl (the same fix applied to
%%% symbolic_query.erl's CLI output — erlog_io:writeq1/1 doesn't escape
%%% an atom's embedded single quotes at all) — full structured
%%% erlog<->JSON marshalling (docs/erlang-mcp-design.md §4) is
%%% deliberately deferred.
%%%
%%% Confirmed by reading erlmcp_stdio_server.erl: it already wraps every
%%% handler call in try/catch and turns a crash into a proper JSON-RPC
%%% error response — but each handler here still catches everything
%%% itself and always returns a binary anyway, the same "structured
%%% result, never crash" discipline prolog_session.erl already follows,
%%% so behavior doesn't depend on relying on that erlmcp-side detail.
-module(symbolic_serve).
-export([run/0]).

run() ->
    {ok, _} = application:ensure_all_started(erlmcp),
    {ok, _SupPid} = prolog_session_sup:start_link(),
    {ok, _RegPid} = prolog_session_registry:start_link(),
    ok = erlmcp_stdio:start(),
    ok = register_tools(),
    receive after infinity -> ok end.

register_tools() ->
    ok = erlmcp_stdio:add_tool(<<"prolog_start_session">>,
        <<"Start a new Prolog session, returns a session_id">>,
        fun handle_start_session/1,
        #{<<"type">> => <<"object">>, <<"properties">> => #{}}),
    ok = erlmcp_stdio:add_tool(<<"prolog_consult">>,
        <<"Load Prolog program text into a session">>,
        fun handle_consult/1,
        #{<<"type">> => <<"object">>,
          <<"properties">> => #{
              <<"session_id">> => #{<<"type">> => <<"string">>},
              <<"program">> => #{<<"type">> => <<"string">>}},
          <<"required">> => [<<"session_id">>, <<"program">>]}),
    ok = erlmcp_stdio:add_tool(<<"prolog_query">>,
        <<"Prove a goal against a session and return its bindings">>,
        fun handle_query/1,
        #{<<"type">> => <<"object">>,
          <<"properties">> => #{
              <<"session_id">> => #{<<"type">> => <<"string">>},
              <<"goal">> => #{<<"type">> => <<"string">>}},
          <<"required">> => [<<"session_id">>, <<"goal">>]}),
    ok = erlmcp_stdio:add_tool(<<"prolog_end_session">>,
        <<"End a Prolog session">>,
        fun handle_end_session/1,
        #{<<"type">> => <<"object">>,
          <<"properties">> => #{<<"session_id">> => #{<<"type">> => <<"string">>}},
          <<"required">> => [<<"session_id">>]}),
    ok.

%% Tool handlers

handle_start_session(_Params) ->
    try
        {ok, SessionId} = prolog_session_registry:start_session(),
        SessionId
    catch
        Class:Reason -> render_caught(Class, Reason)
    end.

handle_consult(#{<<"session_id">> := SessionId, <<"program">> := Program}) ->
    try
        with_session(SessionId, fun(Pid) ->
            case prolog_session:consult_string(Pid, to_list(Program)) of
                ok -> <<"ok">>;
                {error, Reason} -> render_error(Reason)
            end
        end)
    catch
        Class:Reason -> render_caught(Class, Reason)
    end.

handle_query(#{<<"session_id">> := SessionId, <<"goal">> := Goal}) ->
    try
        with_session(SessionId, fun(Pid) ->
            case prolog_session:query(Pid, to_list(Goal)) of
                {ok, Bindings} -> render_bindings(Bindings);
                no_solution -> <<"No.">>;
                {error, Reason} -> render_error(Reason)
            end
        end)
    catch
        Class:Reason -> render_caught(Class, Reason)
    end.

handle_end_session(#{<<"session_id">> := SessionId}) ->
    try
        case prolog_session_registry:end_session(SessionId) of
            ok -> <<"ok">>;
            error -> <<"error: unknown session_id">>
        end
    catch
        Class:Reason -> render_caught(Class, Reason)
    end.

%% Internal

with_session(SessionId, Fun) ->
    case prolog_session_registry:lookup(SessionId) of
        {ok, Pid} -> Fun(Pid);
        error -> <<"error: unknown session_id">>
    end.

render_bindings([]) ->
    <<"Yes.">>;
render_bindings(Bindings) ->
    %% ~ts, not ~s, for the JSON value — see symbolic_parse.erl's
    %% print_fact/1 for why (a plain ~s mangles a binary's non-ASCII
    %% UTF-8 bytes).
    Lines = [
        io_lib:format("~s = ~ts",
            [name_to_list(Name), jsx:encode(symbolic_term_json:encode_term(Value))])
     || {Name, Value} <- Bindings
    ],
    iolist_to_binary(lists:join("\n", Lines)).

render_error(Reason) ->
    iolist_to_binary(io_lib:format("error: ~p", [Reason])).

render_caught(Class, Reason) ->
    iolist_to_binary(io_lib:format("error: ~p:~p", [Class, Reason])).

name_to_list(Name) when is_atom(Name) -> atom_to_list(Name);
name_to_list(Name) when is_integer(Name) -> "_" ++ integer_to_list(Name).

to_list(B) when is_binary(B) -> binary_to_list(B);
to_list(L) when is_list(L) -> L.
