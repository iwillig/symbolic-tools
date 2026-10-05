brew "swi-prolog"
brew "erlang"
brew "rebar3"
# Required to build the vendored llama.cpp inside the erllama dependency
# (src/symbolic_extract_llm.erl) — see docs/reviewing-llm-output.md §4.2
# Phase 0.
brew "cmake"
# Builds the symbolic_ts Rustler NIF (native/symbolic_ts, the tree-sitter
# binding priv/symbolic_ts.so) — scripts/build_nif.sh runs cargo, invoked
# by rebar3's compile pre-hook (rebar.config).
brew "rust"
