#!/usr/bin/env bash
# Builds the symbolic_ts Rustler NIF (native/symbolic_ts) and installs it
# as priv/symbolic_ts.so — the exact path symbolic_ts.erl:init/0's
# erlang:load_nif("priv/symbolic_ts", 0) dlopens. Called by rebar3's
# {pre_hooks, compile} (see rebar.config), so every rebar3 compile, eunit,
# shell, release, and cover run picks up a freshly built NIF before any
# .beam loads it.
#
# Cargo compiles the vendored tree-sitter core + grammars itself
# (native/symbolic_ts/build.rs, cc crate) — the same c_src/ sources the
# old `pc` plugin build compiled — so this script only builds cargo and
# copies the artifact.
set -euo pipefail

cd "$(dirname "$0")/.."

(cd native/symbolic_ts && cargo build --release)

case "$(uname -s)" in
    Darwin)
        artifact=native/symbolic_ts/target/release/libsymbolic_ts.dylib
        ;;
    *)
        artifact=native/symbolic_ts/target/release/libsymbolic_ts.so
        ;;
esac

mkdir -p priv
cp "$artifact" priv/symbolic_ts.so
echo "symbolic_ts NIF: $artifact -> priv/symbolic_ts.so"
