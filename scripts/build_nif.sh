#!/usr/bin/env bash
# Builds the Rustler NIFs and installs them under priv/ — the exact
# paths each wrapper's erlang:load_nif("priv/<crate>", 0) dlopens:
#
#   native/symbolic_ts   -> priv/symbolic_ts.so    (tree-sitter binding)
#   native/symbolic_text -> priv/symbolic_text.so   (full-text search)
#   native/symbolic_nlp  -> priv/symbolic_nlp.so   (statistical NL tier)
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

# SYMBOLIC_SKIP_NLP=1 excludes the statistical tier's NIF (native/
# symbolic_nlp). Its build downloads a ~500MB libtorch and its runtime
# rpath points into the build cache, which dies outside a dev checkout
# — e.g. a Homebrew build sandbox. The tier degrades gracefully when
# the NIF is absent (symbolic_nlp.erl swallows the load failure), so
# packaged builds skip it until libtorch is packaged properly.
SKIP_NLP="${SYMBOLIC_SKIP_NLP:-}"

crates="symbolic_ts symbolic_text"
if [ -z "$SKIP_NLP" ]; then
    crates="$crates symbolic_nlp"
fi

for crate in $crates; do
    if [ "$crate" = "symbolic_nlp" ]; then
        # Three spike findings (PLAN-statistical-nlp-tier.md Stage 1):
        # 1. libtorch's strong_type.h specializes std::is_arithmetic,
        #    which current macOS SDKs raise as a hard C++ error —
        #    suppress that diagnostic group for the torch-sys bridge.
        # 2. headerpad so install_name_tool can add an rpath below
        #    without relinking.
        # 3. libtorch dylibs are NOT copied into priv/ yet (production
        #    must ship them with an @loader_path rpath); for now the
        #    NIF carries an absolute rpath into cargo's torch-sys build
        #    cache, added post-link below.
        (cd "native/$crate" && \
            CXXFLAGS="-Wno-invalid-specialization" \
            RUSTFLAGS="-C link-arg=-Wl,-headerpad_max_install_names" \
            cargo build --release)
    else
        (cd "native/$crate" && cargo build --release)
    fi

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

if [ "$crate" = "symbolic_nlp" ]; then
    libdir=$(ls -d "$PWD"/native/symbolic_nlp/target/release/build/torch-sys-*/out/libtorch/libtorch/lib 2>/dev/null | head -1 || true)
    if [ -n "$libdir" ] && ! otool -l "priv/$crate.so" | grep -q "$libdir"; then
        install_name_tool -add_rpath "$libdir" "priv/$crate.so"
    fi
fi

echo "$crate NIF: $artifact -> priv/$crate.so"
done
