%%% Per-language dispatcher: picks the right tree-sitter extraction
%%% module by file extension. See docs/tree-sitter-erlang.md §5.
-module(ts_extract).
-export([file/1]).

-spec file(file:filename()) -> [tuple()].
file(Path) ->
    case filename:extension(Path) of
        ".erl" -> ts_extract_erlang:file(Path);
        ".ts" -> ts_extract_typescript:file(Path);
        ".md" -> ts_extract_markdown:file(Path)
    end.
