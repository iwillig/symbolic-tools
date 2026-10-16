%%% Eval-only bounded-verification benchmark bridge.
%%% Model output is data: this module validates catalogued operations and
%%% constructs the only Prolog templates the benchmark is allowed to run.
-module(symbolic_eval).
-export([main/0, evaluate/3, validate_request/1, goal/1, score/3]).

-define(IDENT, "^[a-z][A-Za-z0-9_]*$").

main() ->
    case io:get_line("") of
        eof -> emit(#{<<"status">> => <<"infrastructure_error">>,
                      <<"error">> => <<"missing_input">>});
        Line ->
            try
                Input = jsx:decode(unicode:characters_to_binary(string:trim(Line)),
                                   [return_maps]),
                Fixture = maps:get(<<"fixture_path">>, Input),
                RawRequest = maps:get(<<"raw_request">>, Input),
                Expected = maps:get(<<"expected">>, Input, #{}),
                emit(evaluate(binary_to_list(Fixture), RawRequest, Expected))
            catch Class:Reason:Stack ->
                _ = Stack,
                emit(#{<<"status">> => <<"infrastructure_error">>,
                       <<"error">> => atom_to_binary(Class),
                       <<"reason">> => printable(Reason)})
            end
    end.

emit(Value) ->
    io:format("~ts~n", [jsx:encode(Value)]).

-spec evaluate(file:filename(), binary() | map(), map()) -> map().
evaluate(FixtureDir, RawRequest, Expected) ->
    try
        RequestJson = case is_binary(RawRequest) of
            true -> jsx:decode(RawRequest, [return_maps]);
            false -> RawRequest
        end,
        case validate_request(RequestJson) of
            {error, Why} ->
                Result = #{<<"status">> => <<"protocol_error">>,
                           <<"error">> => Why},
                output(RequestJson, Result, Expected, FixtureDir, undefined);
            {abstain, Decision, Reason} ->
                Result = #{<<"status">> => Decision, <<"reason">> => Reason},
                output(RequestJson, Result, Expected, FixtureDir, undefined);
            {ok, Operation, Slots} ->
                ok = verify_manifest(FixtureDir),
                SourceDir = filename:join(FixtureDir, "src"),
                {ok, Report} = symbolic_parse:scan_report(SourceDir),
                Facts = maps:get(facts, Report),
                Complete = maps:get(failed_files, Report) =:= [],
                Symbols = sets:from_list([{atom_to_binary(Name), Arity} ||
                    {defines, Name, Arity, _Params, _File, _Line} <- Facts]),
                Required = maps:values(Slots),
                case lists:all(fun(Id) -> sets:is_element(Id, Symbols) end, Required) of
                    false ->
                        Result = #{<<"status">> => <<"unknown">>,
                                   <<"reason">> => <<"unresolved_identity">>},
                        output(RequestJson, Result, Expected, FixtureDir, Report);
                    true when not Complete ->
                        Result = #{<<"status">> => <<"unknown">>,
                                   <<"reason">> => <<"incomplete_scan">>},
                        output(RequestJson, Result, Expected, FixtureDir, Report);
                    true ->
                        Goal = goal({Operation, Slots}),
                        case prove(Facts, Goal) of
                            {ok, Rows} ->
                                Result = shape_result(Operation, Rows, Goal),
                                output(RequestJson, Result, Expected, FixtureDir, Report);
                            {error, Reason} ->
                                Result = #{<<"status">> => <<"infrastructure_error">>,
                                    <<"error">> => <<"prover_error">>,
                                    <<"reason">> => printable(Reason)},
                                output(RequestJson, Result, Expected, FixtureDir, Report)
                        end
                end
        end
    catch
        Class:CatchReason:Stack ->
            _ = Stack,
            #{<<"status">> => <<"infrastructure_error">>,
              <<"error">> => atom_to_binary(Class),
              <<"reason">> => printable(CatchReason)}
    end.

validate_request(#{<<"decision">> := <<"unsupported">>,
                   <<"reason">> := Reason} = Request)
        when is_binary(Reason), byte_size(Reason) > 0 ->
    case only_keys(Request, [<<"decision">>, <<"reason">>]) of
        true -> {abstain, <<"unsupported">>, Reason};
        false -> {error, <<"invalid_abstention_shape">>}
    end;
validate_request(#{<<"decision">> := <<"needs_clarification">>,
                   <<"reason">> := Reason} = Request)
        when is_binary(Reason), byte_size(Reason) > 0 ->
    case only_keys(Request, [<<"decision">>, <<"reason">>]) of
        true -> {abstain, <<"needs_clarification">>, Reason};
        false -> {error, <<"invalid_abstention_shape">>}
    end;
validate_request(#{<<"decision">> := <<"supported">>,
                   <<"operation">> := OpBin, <<"slots">> := Slots} = Request) ->
    case only_keys(Request, [<<"decision">>, <<"operation">>, <<"slots">>]) of
        false -> {error, <<"invalid_shape">>};
        true -> validate_supported(OpBin, Slots)
    end;
validate_request(_) -> {error, <<"invalid_shape">>}.

validate_supported(<<"defines">>, Slots) -> validate_slots(defines, Slots, [<<"function">>]);
validate_supported(<<"calls">>, Slots) -> validate_slots(calls, Slots, [<<"caller">>, <<"callee">>]);
validate_supported(<<"callers_count">>, Slots) -> validate_slots(callers_count, Slots, [<<"function">>]);
validate_supported(_, _) -> {error, <<"unknown_operation">>}.

validate_slots(Operation, Slots, ExpectedKeys) when is_map(Slots) ->
    case lists:sort(maps:keys(Slots)) =:= lists:sort(ExpectedKeys) of
        false -> {error, <<"invalid_slots">>};
        true ->
            Parsed = [{Key, parse_identity(maps:get(Key, Slots))} || Key <- ExpectedKeys],
            case lists:all(fun({_Key, Value}) -> Value =/= error end, Parsed) of
                true -> {ok, Operation, maps:from_list(Parsed)};
                false -> {error, <<"invalid_function_identity">>}
            end
    end;
validate_slots(_Operation, _Slots, _ExpectedKeys) -> {error, <<"invalid_slots">>}.

parse_identity(Value) when is_binary(Value) ->
    case binary:split(Value, <<"/">>) of
        [NameBin, ArityBin] ->
            Name = binary_to_list(NameBin),
            case re:run(Name, ?IDENT, [{capture, none}]) of
                match ->
                    try
                        Arity = binary_to_integer(ArityBin),
                        case Arity >= 0 andalso integer_to_binary(Arity) =:= ArityBin of
                            true -> {NameBin, Arity};
                            false -> error
                        end
                    catch _:_ -> error end;
                nomatch -> error
            end;
        _ -> error
    end;
parse_identity(_) -> error.

only_keys(Map, Allowed) ->
    lists:all(fun(Key) -> lists:member(Key, Allowed) end, maps:keys(Map)).

goal({defines, #{<<"function">> := {Name, Arity}}}) ->
    lists:flatten(io_lib:format(
        "findall(row(File, Line), defines(~s, ~B, _, File, Line), Rows)",
        [binary_to_list(Name), Arity]));
goal({calls, #{<<"caller">> := {Caller, CallerArity},
               <<"callee">> := {Callee, CalleeArity}}}) ->
    lists:flatten(io_lib:format(
        "findall(row(File, Line), calls(~s, ~B, local(~s, ~B), File, Line), Rows)",
        [binary_to_list(Caller), CallerArity, binary_to_list(Callee), CalleeArity]));
goal({callers_count, #{<<"function">> := {Name, Arity}}}) ->
    lists:flatten(io_lib:format(
        "findall(row(Caller, CallerArity, File, Line), calls(Caller, CallerArity, local(~s, ~B), File, Line), Rows)",
        [binary_to_list(Name), Arity])).

prove(Facts, Goal) ->
    case prolog_session:start_link() of
        {ok, Pid} ->
            try
                ok = prolog_session:load_facts(Pid, Facts),
                case prolog_session:query(Pid, Goal) of
                    {ok, Bindings} ->
                        Rows = proplists:get_value('Rows', Bindings, undefined),
                        case Rows of
                            undefined -> {error, missing_rows_binding};
                            _ -> {ok, Rows}
                        end;
                    no_solution -> {error, findall_goal_failed};
                    {error, Reason} -> {error, Reason}
                end
            after prolog_session:stop(Pid) end;
        {error, Reason} -> {error, Reason}
    end.

shape_result(callers_count, Rows, Goal) ->
    CallerRows = unique_caller_rows(Rows),
    #{<<"status">> => <<"answer">>, <<"type">> => <<"count">>,
      <<"answer">> => length(CallerRows), <<"evidence">> => encode_evidence(CallerRows),
      <<"goal">> => list_to_binary(Goal)};
shape_result(_Operation, Rows, Goal) ->
    #{<<"status">> => <<"answer">>, <<"type">> => <<"yes_no">>,
      <<"answer">> => Rows =/= [], <<"evidence">> => encode_evidence(Rows),
      <<"goal">> => list_to_binary(Goal)}.

unique_caller_rows(Rows) ->
    {_Seen, Reversed} = lists:foldl(fun
        ({row, Name, Arity, _File, _Line} = Row, {Seen, Acc}) ->
            Identity = {Name, Arity},
            case sets:is_element(Identity, Seen) of
                true -> {Seen, Acc};
                false -> {sets:add_element(Identity, Seen), [Row | Acc]}
            end
    end, {sets:new(), []}, Rows),
    lists:reverse(Reversed).

encode_evidence(Rows) ->
    [case Row of
        {row, File, Line} -> #{<<"File">> => file_binary(File), <<"Line">> => Line};
        {row, Caller, CallerArity, File, Line} ->
            #{<<"Caller">> => atom_to_binary(Caller), <<"CallerArity">> => CallerArity,
              <<"File">> => file_binary(File), <<"Line">> => Line}
    end || Row <- Rows].

file_binary(File) when is_atom(File) -> unicode:characters_to_binary(atom_to_list(File));
file_binary(File) when is_binary(File) -> File;
file_binary(File) when is_list(File) -> unicode:characters_to_binary(File);
file_binary(File) -> printable(File).

output(Request, Result, Expected, Fixture, Report) ->
    RequestBin = case is_binary(Request) of true -> Request; false -> jsx:encode(Request) end,
    Base = #{<<"raw_request">> => RequestBin, <<"result">> => Result,
             <<"fixture">> => unicode:characters_to_binary(filename:basename(Fixture)),
             <<"scores">> => score(Request, Result, Expected)},
    WithScan = case Report of
        undefined -> Base;
        _ -> Base#{<<"scan_complete">> => maps:get(failed_files, Report) =:= [],
                   <<"scanned_files">> => length(maps:get(files, Report))}
    end,
    WithScan.

score(Request, ActualResult, Expected) when is_map(Expected), map_size(Expected) > 0 ->
    Decision = maps:get(<<"decision">>, Expected, <<>>),
    ActualDecision = maps:get(<<"decision">>, Request, <<>>),
    Admission = Decision =:= ActualDecision,
    case Decision of
        <<"supported">> -> score_supported(Request, ActualResult, Expected, Admission);
        _ ->
            AnswerOk = maps:get(<<"status">>, ActualResult, <<>>) =:= Decision,
            ProtocolOk = maps:get(<<"status">>, ActualResult, <<>>) =/= <<"protocol_error">>,
            #{<<"admission">> => Admission,
              <<"operation">> => true, <<"slots">> => true,
              <<"verifier_answer">> => AnswerOk, <<"evidence">> => AnswerOk,
              <<"protocol">> => ProtocolOk,
              <<"end_to_end">> => Admission andalso AnswerOk}
    end;
score(_Request, _ActualResult, _Expected) -> #{}.

score_supported(Request, ActualResult, Expected, Admission) ->
    OpOk = maps:get(<<"operation">>, Request, undefined) =:=
           maps:get(<<"operation">>, Expected, undefined),
    SlotsOk = maps:get(<<"slots">>, Request, undefined) =:=
              maps:get(<<"slots">>, Expected, undefined),
    AnswerOk = maps:get(<<"status">>, ActualResult, <<>>) =:= <<"answer">> andalso
        maps:get(<<"answer">>, ActualResult, '$missing') =:= maps:get(<<"answer">>, Expected, '$missing'),
    EvidenceOk = evidence_matches(maps:get(<<"evidence">>, ActualResult, []),
                                  maps:get(<<"evidence">>, Expected, [])),
    ProtocolOk = maps:get(<<"status">>, ActualResult, <<>>) =/= <<"protocol_error">>,
    #{<<"admission">> => Admission, <<"operation">> => OpOk,
      <<"slots">> => SlotsOk, <<"verifier_answer">> => AnswerOk,
      <<"evidence">> => EvidenceOk, <<"protocol">> => ProtocolOk,
      <<"end_to_end">> => Admission andalso OpOk andalso SlotsOk andalso
                            AnswerOk andalso EvidenceOk}.

evidence_matches(Actual, Expected) when is_list(Actual), is_list(Expected) ->
    Normalize = fun(E) ->
        File = filename:basename(binary_to_list(maps:get(<<"File">>, E,
            maps:get(<<"file">>, E, <<>>)))),
        {File, maps:get(<<"Line">>, E, maps:get(<<"line">>, E, -1))}
    end,
    lists:sort([Normalize(E) || E <- Actual]) =:=
    lists:sort([Normalize(E) || E <- Expected]);
evidence_matches(_, _) -> false.

verify_manifest(FixtureDir) ->
    ManifestPath = filename:join(FixtureDir, "manifest.json"),
    {ok, Json} = file:read_file(ManifestPath),
    Manifest = jsx:decode(Json, [return_maps]),
    Files = maps:get(<<"files">>, Manifest),
    true = map_size(Files) > 0,
    maps:foreach(fun(Relative, ExpectedHash) ->
        Path = filename:join(FixtureDir, binary_to_list(Relative)),
        {ok, Contents} = file:read_file(Path),
        ActualHash = hex(crypto:hash(sha256, Contents)),
        true = ActualHash =:= ExpectedHash
    end, Files),
    ok.

hex(Binary) ->
    << <<(hex_digit(Byte bsr 4)), (hex_digit(Byte band 15))>> || <<Byte>> <= Binary >>.

hex_digit(N) when N < 10 -> $0 + N;
hex_digit(N) -> $a + N - 10.

printable(Value) ->
    try unicode:characters_to_binary(io_lib:format("~tp", [Value]))
    catch _:_ -> <<"unprintable">> end.
