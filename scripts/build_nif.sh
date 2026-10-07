#!/usr/bin/env bash
# Builds the Rustler NIFs and installs them under priv/ — the exact
# paths each wrapper's erlang:load_nif("priv/<crate>", 0) dlopens:
#
#   native/symbolic_ts   -> priv/symbolic_ts.so    (tree-sitter binding)
#   native/symbolic_text -> priv/symbolic_text.so   (full-text search)
#
# Called by rebar3's {pre_hooks, compile} (see rebar.config), so every
# rebar3 compile, eunit, shell, release, and cover run picks up freshly
# built NIFs before any .beam loads them.
#
# Cargo compiles the vendored tree-sitter core + grammars itself
# (native/symbolic_ts/build.rs, cc crate) — the same c_src/ sources the
# old `pc` plugin build compiled — so this script only builds cargo and
# copies the artifacts.
set -euo pipefail

cd "$(dirname "$0")/.."

for crate in symbolic_ts symbolic_text; do
    (cd "native/$crate" && cargo build --release)

case "$(uname -s)" in
    Darwin)
        artifact="native/$crate/target/release/lib$crate.dylib"
        ;;
    *)
        artifact="native/$crate/target/release/lib$crate.so"
        ;;
esac

mkdir -p priv
cp "$artifact" "priv/$crate.so"
echo "$crate NIF: $artifact -> priv/$crate.so"
done
