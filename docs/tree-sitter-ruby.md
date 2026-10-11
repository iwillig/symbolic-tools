# Ruby Tree-sitter integration

The `.rb` extractor uses the generated C parser from
[`tree-sitter/tree-sitter-ruby`](https://github.com/tree-sitter/tree-sitter-ruby),
revision `ad907a69da0c8a4f7a943a7fe012712208da6dee` (Tree-sitter language ABI
14, MIT). The parser, external scanner, and grammar headers are vendored under
`c_src/grammars/ruby/`; see its `LICENSE` file.

The extractor emits `defines/5` facts for instance and singleton methods,
`calls/5` for recognized calls with a syntactically enclosing method, and
`comment/3` for comments. Calls without an enclosing method are ignored.
Method arity is the number of named parameter nodes, so optional and rest
parameters each count as one; this is not equivalent to Ruby's runtime
`Method#arity`. Receiver calls use the common `member/3`-style CallSpec.

This is syntax-level extraction. It does not resolve constants, determine
dynamic dispatch, or model runtime method lookup. Grammar updates must be
pinned and tested against representative Ruby source and the project's
Tree-sitter ABI.
