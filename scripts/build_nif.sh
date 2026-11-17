#!/usr/bin/env bash
# Builds the Rustler NIFs and installs them under priv/ — the exact
# paths each wrapper's erlang:load_nif("priv/<crate>", 0) dlopens:
#
#   native/symbolic_ts   -> priv/symbolic_ts.so    (tree-sitter binding)
#   native/symbolic_text -> priv/symbolic_text.so   (full-text search)
#   native/symbolic_nlp  -> priv/symbolic_nlp.so   (statistical NL tier)
#   native/symbolic_nlprule -> priv/symbolic_nlprule.so (English NLP)
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

crates="symbolic_ts symbolic_text symbolic_nlprule"
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
# Never truncate a library that a running BEAM may have mapped. Prepare the
# complete file in the destination directory and atomically replace its name.
staged=$(mktemp "priv/.$crate.XXXXXXXX")
trap 'rm -f "$staged"' EXIT
# mktemp starts at 0600; preserve the artifact's mode for other runtime users.
cp -p "$artifact" "$staged"

if [ "$crate" = "symbolic_nlp" ]; then
    # Locate libtorch by its actual shared object instead of a layout glob:
    # torch-sys's build-dir hash and nesting shift with toolchain updates,
    # and a silent miss here leaves the NIF without an rpath — it builds
    # fine but cannot dlopen libtorch at load time (the ubuntu-26.04
    # runner migration surfaced exactly this in CI).
    libdir=$(dirname "$(find native/symbolic_nlp/target/release/build -type f -name libtorch_cpu.so 2>/dev/null | head -1)" 2>/dev/null || true)
    if [ -n "$libdir" ] && [ -d "$libdir" ]; then
        case "$(uname -s)" in
            Darwin)
                # macOS: post-link surgery, because a link-time rpath
                # cannot know the libdir before torch-sys has downloaded
                # libtorch mid-build (and headerpad is already baked via
                # RUSTFLAGS above so the edit fits).
                if ! otool -l "$staged" | grep -q "$libdir"; then
                    install_name_tool -add_rpath "$libdir" "$staged"
                fi
                ;;
            *)
                # Linux: same goal, different tool — patchelf, which CI
                # installs. Without it, the NIF builds but dlopen cannot
                # find libtorch at test time and the statistical tier's
                # tests would silently degrade to skipping.
                if command -v patchelf >/dev/null 2>&1; then
                    if ! patchelf --set-rpath "$libdir" "$staged"; then
                        echo "ERROR: failed to set libtorch rpath on $crate NIF" >&2
                        exit 1
                    fi
                else
                    echo "WARNING: patchelf not found; priv/symbolic_nlp.so carries no libtorch rpath (install patchelf, or set LD_LIBRARY_PATH to $libdir at load time)." >&2
                fi
                ;;
        esac
    else
        echo "WARNING: libtorch shared objects not found under native/symbolic_nlp/target; priv/symbolic_nlp.so carries no libtorch rpath, so the statistical tier will degrade at load time (set LIBTORCH or install patchelf and rebuild)." >&2
    fi
fi

mv -f "$staged" "priv/$crate.so"
trap - EXIT
echo "$crate NIF: $artifact -> priv/$crate.so"
done

# A skipped tier must also be absent in a reused workspace. Unlinking an
# old NIF leaves any already-loaded mapping intact until that VM exits.
if [ -n "$SKIP_NLP" ]; then
    rm -f priv/symbolic_nlp.so
    for profile_priv in _build/*/lib/symbolic_tools/priv; do
        [ -d "$profile_priv" ] || continue
        rm -f "$profile_priv/symbolic_nlp.so"
    done
fi

# code:priv_dir/1 resolves into _build/<profile>/lib/symbolic_tools/priv —
# a copy rebar3 syncs unreliably (observed missing files entirely and
# holding stale builds, e.g. after a cache restore or a runner-image
# migration). Sync every fresh .so into each existing profile copy so
# priv_dir never resolves to a stale artifact; the NIF wrappers also fall
# back to this repo's priv/ when a copy lacks the file.
for profile_priv in _build/*/lib/symbolic_tools/priv; do
    [ -d "$profile_priv" ] || continue
    for source in priv/*.so; do
        [ -f "$source" ] || continue
        target="$profile_priv/$(basename "$source")"
        [ "$source" -ef "$target" ] && continue
        staged=$(mktemp "$profile_priv/.nif.XXXXXXXX")
        trap 'rm -f "$staged"' EXIT
        cp -p "$source" "$staged"
        mv -f "$staged" "$target"
        trap - EXIT
    done
done
