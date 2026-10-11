# Clojure Tree-sitter integration

The `.clj` extractor uses the generated C parser from
[`sogaiu/tree-sitter-clojure`](https://github.com/sogaiu/tree-sitter-clojure),
revision `e43eff80d17cf34852dcd92ca5e6986d23a7040f` (Tree-sitter language ABI
14). Its generated parser and `tree_sitter/parser.h` are vendored under
`c_src/grammars/clojure/`; the upstream `COPYING.txt` is included there
(CC0-1.0).

The grammar deliberately handles reader-level primitives rather than
higher-level constructs such as `defn`. Accordingly, `ts_extract_clojure`
emits only shared `comment/3` facts. It does not infer `defines/5`, `doc/5`,
or `calls/5` from lists or symbols. The comment text retains its leading
semicolon; a trailing line ending is removed. `.cljs` and `.cljc` are not
currently dispatched.

The upstream grammar documents limitations around template files, custom
reader behavior, some older/ClojureCLR syntax, and zero-byte files. This
integration does not claim complete compatibility with every Clojure reader
extension. Grammar updates must be pinned and checked against both the
Tree-sitter ABI and representative real-world source before adoption.
