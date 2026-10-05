#!/usr/bin/env bash
# The fact-parity gate for the symbolic_ts NIF: dumps the extracted fact
# base over three corpora (the repo's own Erlang src/, the markdown docs
# tree, and test/fixtures) with the CURRENTLY BUILT NIF, and compares the
# result with a previously saved baseline dump. Zero diff = the NIF
# change (e.g. the C -> Rustler port, or a tree-sitter grammar bump)
# provably did not change a single extracted fact.
#
# Usage:
#   scripts/parity_check.sh save <baseline-dir>   # record a baseline
#   scripts/parity_check.sh check <baseline-dir>  # compare against one
#
# The baseline is plain `symbolic parse` JSON output — one file per
# corpus. Because the dumps embed the paths they were parsed from, this
# script always parses via the SAME absolute path (/tmp/parity-src,
# /tmp/parity-docs, /tmp/parity-fixtures, refreshed from the same
# sources each run) so byte diffs can't be faked or masked by different
# path spellings. Corpus roots:
#   - Erlang:   a pristine git export of src/ (git archive HEAD), so a
#               dirty working tree can't contaminate the gate
#   - Markdown: docs/ as-is
#   - Fixtures: test/fixtures/ as-is (covers TS, jsdoc via .ts comments,
#               markdown, toml, json, bash)
set -euo pipefail

cd "$(dirname "$0")/.."

MODE="${1:?usage: parity_check.sh save|check <baseline-dir>}"
DIR="${2:?usage: parity_check.sh save|check <baseline-dir>}"

BIN=_build/default/rel/symbolic_tools/bin/symbolic
[ -x "$BIN" ] || { echo "no release at $BIN — run: rebar3 release" >&2; exit 1; }

# Stable corpus paths (see header comment).
rm -rf /tmp/parity-src && mkdir -p /tmp/parity-src
git archive HEAD src | tar -x -C /tmp/parity-src

dump() {
    local out="$1"; shift
    : > "$out"
    for corpus in "/tmp/parity-src/src" "docs" "test/fixtures"; do
        "$BIN" parse "$corpus" >> "$out"
    done
}

mkdir -p "$DIR"
case "$MODE" in
    save)
        dump "$DIR/facts.json"
        echo "baseline saved: $DIR/facts.json ($(wc -l < "$DIR/facts.json") facts)"
        ;;
    check)
        dump /tmp/parity-current.json
        if diff -u "$DIR/facts.json" /tmp/parity-current.json > /tmp/parity.diff; then
            echo "PARITY OK: $(wc -l < /tmp/parity-current.json) facts, zero diff"
        else
            echo "PARITY FAILED — fact drift:"
            head -40 /tmp/parity.diff
            exit 1
        fi
        ;;
    *)
        echo "unknown mode: $MODE" >&2; exit 1 ;;
esac
