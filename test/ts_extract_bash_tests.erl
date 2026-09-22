-module(ts_extract_bash_tests).
-include_lib("eunit/include/eunit.hrl").

-define(FIXTURE, "test/fixtures/sample.sh").

extracts_defines_test() ->
    Facts = ts_extract_bash:file(?FIXTURE),
    Path = list_to_atom(?FIXTURE),
    %% Arity/Params are always `undefined` — bash has no parameter-list
    %% grammar node to derive them from.
    ?assert(lists:member({defines, deploy, undefined, undefined, Path, 2}, Facts)),
    ?assert(lists:member({defines, build, undefined, undefined, Path, 7}, Facts)).

extracts_local_call_test() ->
    Facts = ts_extract_bash:file(?FIXTURE),
    Path = list_to_atom(?FIXTURE),
    %% CallerArity (the 2nd calls/5 field) is always `undefined` — same
    %% reason as defines/5's.
    ?assert(lists:member({calls, deploy, undefined, {local, build, 0}, Path, 3}, Facts)),
    ?assert(lists:member({calls, deploy, undefined, {local, scp, 2}, Path, 4}, Facts)),
    ?assert(lists:member({calls, build, undefined, {local, echo, 1}, Path, 8}, Facts)).

extracts_comment_test() ->
    Facts = ts_extract_bash:file(?FIXTURE),
    Path = list_to_atom(?FIXTURE),
    ?assert(lists:member(
        {comment, Path, 1, <<"Deploys the app to the given environment.">>}, Facts)),
    ?assert(lists:member(
        {comment, Path, 11, <<"standalone comment, not attached to anything">>}, Facts)).

extracts_doc_test() ->
    Facts = ts_extract_bash:file(?FIXTURE),
    Path = list_to_atom(?FIXTURE),
    ?assert(lists:member(
        {doc, deploy, undefined, Path, 2, <<"Deploys the app to the given environment.">>},
        Facts)).

standalone_comment_has_no_doc_test() ->
    Facts = ts_extract_bash:file(?FIXTURE),
    ?assertEqual(
        [], [F || {doc, _, _, _, 11, _} = F <- Facts]).

no_duplicate_facts_test() ->
    Facts = ts_extract_bash:file(?FIXTURE),
    ?assertEqual(lists:usort(Facts), lists:sort(Facts)).

%% Inline snippet, not the shared fixture — none of ?BRANCH_QUERIES'
%% constructs appear in sample.sh. `elif_clause` is required in addition
%% to `if_statement`: unlike TypeScript, the whole if/elif/else chain is
%% ONE if_statement node (confirmed empirically) — elif is a sibling
%% clause inside it, not a nested if_statement, so it needs its own
%% query or every elif goes uncounted. case_item includes the `*)`
%% wildcard arm too (a documented simplification, not a bug).
extracts_branch_facts_test() ->
    Src =
        "f() {\n"                        %% 1
        "  if [ \"$1\" -gt 0 ]; then\n"  %% 2
        "    echo pos\n"                 %% 3
        "  elif [ \"$1\" -lt 0 ]; then\n" %% 4
        "    echo neg\n"                 %% 5
        "  else\n"                       %% 6
        "    echo zero\n"                %% 7
        "  fi\n"                         %% 8
        "  for i in 1 2 3; do\n"         %% 9
        "    echo \"$i\"\n"              %% 10
        "  done\n"                       %% 11
        "  while true; do\n"             %% 12
        "    break\n"                    %% 13
        "  done\n"                       %% 14
        "  case \"$1\" in\n"             %% 15
        "    1) echo one ;;\n"           %% 16
        "    2) echo two ;;\n"           %% 17
        "    *) echo other ;;\n"        %% 18
        "  esac\n"                        %% 19
        "}\n",                            %% 20
    Facts = ts_extract_bash:text("scratch_branch.sh", Src),
    Path = 'scratch_branch.sh',
    Branches = [{K, L} || {branch, f, undefined, K, P, L} <- Facts, P =:= Path],
    ?assertEqual(
        lists:sort([{'if', 2}, {elif, 4}, {'for', 9}, {'while', 12},
                    {case_item, 16}, {case_item, 17}, {case_item, 18}]),
        lists:sort(Branches)).
