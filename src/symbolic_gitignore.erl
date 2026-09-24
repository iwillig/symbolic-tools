%%% `.gitignore`-style path exclusion for `symbolic parse`'s directory
%%% walk (symbolic_parse.erl). Two things this deliberately is NOT:
%%%
%%% - A full git implementation. Only a single, top-level `.gitignore` at
%%%   the SCANNED directory's own root is read — real git additionally
%%%   honors a `.gitignore` nested in every subdirectory, each scoped to
%%%   its own subtree, `.git/info/exclude`, and a user's global
%%%   `core.excludesFile`. None of those are consulted here. The common
%%%   case (one project-root `.gitignore`, this project's own included)
%%%   is what's actually built.
%%% - A byte-for-byte glob translator. `*`, `?`, `**`, a leading `/`
%%%   (root-anchored), a trailing `/` (directory-only), an internal `/`
%%%   (also anchors, per real gitignore semantics), and a leading `!`
%%%   (negate) are all handled; an escaped `\#`/`\!` at the start of a
%%%   line, or a pattern with escaped wildcard characters inside it, is
%%%   not — those are rare enough in practice not to hold up the common
%%%   case.
%%%
%%% `node_modules/` and `.git/` are ignored UNCONDITIONALLY, regardless
%%% of what (if anything) a project's own `.gitignore` says — the
%%% motivating case is a JS/TS project where `node_modules` alone can
%%% hold tens of thousands of files this tool has no reason to ever look
%%% inside, and walking into it is a real cost (see symbolic_parse's own
%%% directory-pruning walk, not a post-hoc filter over an already-
%%% completed scan), not just noise in the eventual result.
-module(symbolic_gitignore).
-export([load/1, ignored/3, parse_line/1]).

%% {CompiledRegex, Negate, DirOnly}. Rules apply in order with
%% later-wins precedence, same as real git: a later `!` un-ignores what
%% an earlier, broader rule ignored.
-type rule() :: {re:mp(), boolean(), boolean()}.

%% Modeled as ordinary (dir-only, unanchored) rules — first in the list,
%% same as a real .gitignore's own line order — so a real, later
%% `!node_modules/keep-this/` line can still override them.
default_rules() ->
    [R || {ok, R} <- [parse_line(<<"node_modules/">>), parse_line(<<".git/">>)]].

%% Compiled default rules plus Dir's own top-level `.gitignore`, if any.
-spec load(file:name()) -> [rule()].
load(Dir) ->
    Defaults = default_rules(),
    Path = filename:join(Dir, ".gitignore"),
    case file:read_file(Path) of
        {ok, Bin} ->
            Lines = binary:split(Bin, [<<"\n">>, <<"\r\n">>], [global]),
            Defaults ++ [R || Line <- Lines, {ok, R} <- [parse_line(Line)]];
        {error, _} ->
            Defaults
    end.

%% One `.gitignore` line -> `{ok, Rule}`, or `skip` for a blank/comment
%% line. Exported (not hidden in a fun) so it's unit-testable on its own
%% — a malformed glob turning into the WRONG rule silently is exactly the
%% kind of bug that would only ever show up as "why did parse skip a
%% file I never asked it to skip", far from this function.
-spec parse_line(binary()) -> {ok, rule()} | skip.
parse_line(RawLine) ->
    Trimmed = string:trim(RawLine, trailing, "\r\n \t"),
    case Trimmed of
        <<>> -> skip;
        <<"#", _/binary>> -> skip;
        <<"!", Rest/binary>> when Rest =/= <<>> -> {ok, build_rule(Rest, true)};
        _ -> {ok, build_rule(Trimmed, false)}
    end.

build_rule(Pattern0, Negate) ->
    {Pattern1, DirOnly} =
        case binary:last(Pattern0) of
            $/ -> {binary:part(Pattern0, 0, byte_size(Pattern0) - 1), true};
            _ -> {Pattern0, false}
        end,
    {Body, Anchored} =
        case Pattern1 of
            <<"/", Rest/binary>> ->
                {Rest, true};
            _ ->
                %% Any OTHER "/" (the trailing one, if any, already
                %% stripped above) anchors the pattern to the scan root
                %% too — only a pattern with no "/" at all matches a
                %% basename at any depth.
                case binary:match(Pattern1, <<"/">>) of
                    nomatch -> {Pattern1, false};
                    _ -> {Pattern1, true}
                end
        end,
    RegexBody = glob_to_regex(unicode:characters_to_list(Body)),
    FullRegex = case Anchored of
        true -> "^" ++ RegexBody ++ "$";
        false -> "(?:^|.*/)" ++ RegexBody ++ "$"
    end,
    {ok, Compiled} = re:compile(FullRegex),
    {Compiled, Negate, DirOnly}.

%% Gitignore's own glob dialect -> PCRE regex source, one token at a
%% time. `**/` consumes the slash too (zero or more WHOLE path segments,
%% so `a/**/b` matches `a/b` as well as `a/x/y/b`); a bare `**` elsewhere
%% matches anything, slashes included; `*` and `?` both stop at a `/`,
%% the way a shell glob does.
glob_to_regex(Chars) -> glob_to_regex(Chars, []).

glob_to_regex([], Acc) -> lists:flatten(lists:reverse(Acc));
glob_to_regex([$*, $*, $/ | Rest], Acc) ->
    glob_to_regex(Rest, ["(?:.*/)?" | Acc]);
glob_to_regex([$*, $* | Rest], Acc) ->
    glob_to_regex(Rest, [".*" | Acc]);
glob_to_regex([$* | Rest], Acc) ->
    glob_to_regex(Rest, ["[^/]*" | Acc]);
glob_to_regex([$? | Rest], Acc) ->
    glob_to_regex(Rest, ["[^/]" | Acc]);
glob_to_regex([C | Rest], Acc) when C =:= $.; C =:= $^; C =:= $$; C =:= $+;
                                     C =:= $(; C =:= $); C =:= $[; C =:= $];
                                     C =:= ${; C =:= $}; C =:= $|; C =:= $\\ ->
    glob_to_regex(Rest, [[$\\, C] | Acc]);
glob_to_regex([C | Rest], Acc) ->
    glob_to_regex(Rest, [C | Acc]).

%% Whether RelPath (forward-slash separated, relative to the scanned
%% root, no leading "/") should be skipped. IsDir says whether RelPath
%% names a directory — only then do dir-only rules apply — or a file.
-spec ignored(string(), boolean(), [rule()]) -> boolean().
ignored(RelPath, IsDir, Rules) ->
    lists:foldl(
        fun({Regex, Negate, DirOnly}, Acc) ->
            case DirOnly andalso not IsDir of
                true -> Acc;
                false ->
                    case re:run(RelPath, Regex) of
                        {match, _} -> not Negate;
                        nomatch -> Acc
                    end
            end
        end, false, Rules).
