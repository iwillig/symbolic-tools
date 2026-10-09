-module(ts_extract_rust_tests).
-include_lib("eunit/include/eunit.hrl").

extracts_free_functions_and_method_signatures_test() ->
    Source = <<"fn top(a: i32, b: bool) {}\n"
               "impl Widget { fn make() {} fn method(&self, x: i32) {} }\n"
               "trait Convert { fn convert(&self, x: i32) -> i64; }\n">>,
    Facts = ts_extract_rust:text("sample.rs", Source),
    Path = 'sample.rs',
    ?assert(lists:member({defines, top, 2, <<"(a: i32, b: bool)">>, Path, 1}, Facts)),
    ?assert(lists:member({defines, make, 0, <<"()">>, Path, 2}, Facts)),
    ?assert(lists:member({defines, method, 2, <<"(&self, x: i32)">>, Path, 2}, Facts)),
    ?assert(lists:member({defines, convert, 2, <<"(&self, x: i32)">>, Path, 3}, Facts)),
    ?assert(lists:any(
        fun({rust_function, _, make, 0, <<"()">>, method, <<"impl Widget">>, private, P, 2}) -> P =:= Path;
           (_) -> false
        end, Facts)),
    ?assertMatch(
        {rust_function, _, convert, 2, _, trait_signature, <<"trait Convert">>, private, Path, 3},
        only_fact(fun({rust_function, _, convert, _, _, _, _, _, _, _}) -> true; (_) -> false end, Facts)).

extracts_nested_modules_visibility_and_uses_test() ->
    Source = <<"pub mod api {\n"
               "  pub(crate) fn helper() {}\n"
               "  pub(in crate::api) fn guarded() {}\n"
               "  mod internal;\n"
               "}\n"
               "pub use std::io::{self, Read};\n">>,
    Facts = ts_extract_rust:text("modules.rs", Source),
    Path = 'modules.rs',
    ?assert(lists:member({rust_module, api, <<>>, inline, public, Path, 1}, Facts)),
    ?assert(lists:member({rust_module, internal, <<"mod api">>, external, private, Path, 4}, Facts)),
    ?assert(lists:member({rust_use, <<"std::io::{self, Read}">>, <<>>, Path, 6}, Facts)),
    ?assert(lists:any(
        fun({rust_function, _, helper, 0, <<"()">>, function, <<"mod api">>,
             {public, crate}, P, 2}) -> P =:= Path;
           (_) -> false
        end, Facts)),
    ?assert(lists:any(
        fun({rust_visibility, _, function_item, {public, crate}, Path0, 2}) -> Path0 =:= Path;
           (_) -> false
        end, Facts)),
    ?assert(lists:any(
        fun({rust_function, _, guarded, 0, <<"()">>, function, <<"mod api">>,
             {public_in, <<"crate::api">>}, Path0, 3}) -> Path0 =:= Path;
           (_) -> false
        end, Facts)).

extracts_calls_with_syntax_shape_and_nearest_function_test() ->
    Source = <<"fn run(x: i32) {\n"
               "  direct(x);\n"
               "  self.update(x);\n"
               "  crate::util::save(x);\n"
               "}\n"
               "direct(0);\n">>,
    Facts = ts_extract_rust:text("calls.rs", Source),
    Path = 'calls.rs',
    ?assert(lists:member({calls, run, 1, {path, direct, 1}, Path, 2}, Facts)),
    ?assert(lists:member({calls, run, 1, {member, self, update, 1}, Path, 3}, Facts)),
    ?assert(lists:member({calls, run, 1, {path, 'crate::util::save', 1}, Path, 4}, Facts)),
    RunId = element(2, only_fact(fun({rust_function, _, run, _, _, _, _, _, _, _}) -> true; (_) -> false end, Facts)),
    ?assertEqual(3, length([F || {rust_call, _, RunId0, _, Path0, _} = F <- Facts,
                                 RunId0 =:= RunId, Path0 =:= Path])),
    ?assertEqual([], [F || {calls, undefined, undefined, _, _, _} = F <- Facts]),
    ?assertEqual(lists:sort(Facts), lists:usort(Facts)).

only_fact(Pred, Facts) ->
    case [F || F <- Facts, Pred(F)] of
        [Fact] -> Fact;
        Other -> erlang:error({expected_one_fact, Other})
    end.
