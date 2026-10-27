-module(ts_extract_python_tests).
-include_lib("eunit/include/eunit.hrl").

basic_definition_call_and_comments_test() ->
    Source = <<"# heading\n"
               "def run(a, b):\n"
               "    # inner\n"
               "    send(a, b)\n"
               "    client.post(a)\n"
               "send(1)\n">>,
    Facts = ts_extract_python:text("sample.py", Source),
    ?assert(lists:member({defines, run, 2, <<"(a, b)">>, 'sample.py', 2}, Facts)),
    ?assert(lists:member({calls, run, 2, {local, send, 2}, 'sample.py', 4}, Facts)),
    ?assert(lists:member({calls, run, 2, {member, client, post, 1}, 'sample.py', 5}, Facts)),
    ?assertEqual(2, length([F || F = {calls, _, _, _, _, _} <- Facts])),
    ?assert(lists:member({comment, 'sample.py', 1, <<"# heading">>}, Facts)),
    ?assert(lists:member({comment, 'sample.py', 3, <<"# inner">>}, Facts)).

decorated_async_and_separators_test() ->
    Source = <<"@cache\nasync def run(a, /, b=1, *, c=None, **kw):\n"
               "    work(a)\n">>,
    Facts = ts_extract_python:text("async.py", Source),
    ?assert(lists:member({defines, run, 4, <<"(a, /, b=1, *, c=None, **kw)">>, 'async.py', 2}, Facts)),
    ?assert(lists:member({calls, run, 4, {local, work, 1}, 'async.py', 3}, Facts)).

ambiguous_caller_and_dynamic_argument_test() ->
    Source = <<"class A:\n"
               "    def go(self):\n        target()\n"
               "class B:\n"
               "    def go(self):\n        target()\n"
               "def outer():\n"
               "    def go():\n        target()\n"
               "    (lambda: target())()\n"
               "    target(x=1)\n    target(*args)\n    target(**kw)\n"
               "    target(1)\n    obj.attr(1)\n    (factory()).method()\n">>,
    Facts = ts_extract_python:text("ambiguous.py", Source),
    ?assert(lists:member({defines, go, 1, <<"(self)">>, 'ambiguous.py', 2}, Facts)),
    ?assert(lists:member({defines, go, 0, <<"()">>, 'ambiguous.py', 8}, Facts)),
    ?assertEqual([{calls, outer, 0, {local, factory, 0}, 'ambiguous.py', 16},
                  {calls, outer, 0, {local, target, 1}, 'ambiguous.py', 14},
                  {calls, outer, 0, {member, obj, attr, 1}, 'ambiguous.py', 15}],
                 [F || F = {calls, _, _, _, _, _} <- Facts]).

duplicate_top_level_identity_skips_calls_test() ->
    Facts = ts_extract_python:text("dup.py", <<"def f():\n    x()\ndef f():\n    y()\n">>),
    ?assertEqual([], [F || F = {calls, _, _, _, _, _} <- Facts]).

docstrings_are_not_comments_test() ->
    Facts = ts_extract_python:text("doc.py", <<"def f():\n    \"\"\"hello\"\"\"\n    # real\n">>),
    ?assertEqual([{comment, 'doc.py', 3, <<"# real">>}],
                 [F || F = {comment, _, _, _} <- Facts]).

non_utf8_source_fails_closed_test() ->
    ?assertError(unsupported_python_encoding,
                 ts_extract_python:text("latin.py", <<"# coding: latin-1\nx='\xE9'\n">>)),
    ?assertError(unsupported_python_encoding,
                 ts_extract_python:text("latin.py", <<"# coding: latin-1\nx=1\n">>)).

f_string_and_match_calls_test() ->
    Facts = ts_extract_python:text("modern.py",
        <<"def render(x):\n"
          "    match x:\n"
          "        case 1:\n"
          "            return f\"{format(x)}\"\n">>),
    ?assert(lists:member({calls, render, 1, {local, format, 1}, 'modern.py', 4}, Facts)).

definition_time_calls_are_not_body_calls_test() ->
    Facts = ts_extract_python:text("defaults.py",
        <<"@decorate(factory())\ndef run(x=setup()) -> result(check()):\n"
          "    execute()\n">>),
    ?assertEqual([{calls, run, 1, {local, execute, 0}, 'defaults.py', 3}],
                 [F || F = {calls, _, _, _, _, _} <- Facts]).

invalid_syntax_fails_closed_test() ->
    ?assertError(invalid_python_syntax,
                 ts_extract_python:text("bad.py", <<"def broken(:\n    pass\n">>)).

scan_and_cache_refresh_test() ->
    Root = filename:absname(filename:join("_build", "python_scan_scratch")),
    Source = filename:join(Root, "app.py"),
    Ignored = filename:join(Root, "ignored.py"),
    _ = file:del_dir_r(Root),
    ok = filelib:ensure_dir(Source),
    ok = file:write_file(filename:join(Root, ".gitignore"), <<"ignored.py\n">>),
    ok = file:write_file(Source, <<"def old():\n    pass\n">>),
    ok = file:write_file(Ignored, <<"def ignored():\n    pass\n">>),
    try
        {ok, First} = symbolic_parse:scan_report(Root),
        ?assertEqual([Source], maps:get(files, First)),
        ?assertEqual([], maps:get(failed_files, First)),
        ?assertEqual(true, maps:get(complete, First)),
        ?assertEqual([<<"python">>], maps:get(languages,
            symbolic_parse:summary(maps:get(files, First), maps:get(facts, First)))),
        ?assert(lists:member({defines, old, 0, <<"()">>, list_to_atom(Source), 1},
                             maps:get(facts, First))),
        {ok, Explicit} = symbolic_parse:scan_paths_report([Ignored]),
        ?assert(lists:member({defines, ignored, 0, <<"()">>, list_to_atom(Ignored), 1},
                             maps:get(facts, Explicit))),
        ok = file:write_file(Source, <<"def new():\n    pass\n">>),
        {ok, Changed} = symbolic_parse:scan_report(Root, maps:get(file_cache, First)),
        ?assert(lists:member({defines, new, 0, <<"()">>, list_to_atom(Source), 1},
                             maps:get(facts, Changed))),
        ?assertNot(lists:member({defines, old, 0, <<"()">>, list_to_atom(Source), 1},
                                maps:get(facts, Changed))),
        ok = file:write_file(Source, <<"# coding: latin-1\nx='\xE9'\n">>),
        {ok, Failed} = symbolic_parse:scan_report(Root, maps:get(file_cache, Changed)),
        ?assertEqual([Source], maps:get(failed_files, Failed)),
        ?assertEqual(false, maps:get(complete, Failed))
    after
        _ = file:del_dir_r(Root)
    end.

unicode_identifier_test() ->
    Facts = ts_extract_python:text("utf8.py", <<"def caf\xC3\xA9():\n    run()\n">>),
    ?assert(lists:member({defines, 'café', 0, <<"()">>, 'utf8.py', 1}, Facts)).
