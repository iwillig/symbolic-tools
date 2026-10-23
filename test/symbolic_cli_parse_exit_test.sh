#!/bin/sh
# Run with: sh test/symbolic_cli_parse_exit_test.sh
# A fake erl provides a fast SIGKILL-style exit without parsing a project.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
cat > "$TMP/erl" <<'EOF'
#!/bin/sh
printf 'partial diagnostic\n' >&2
exit 137
EOF
chmod +x "$TMP/erl"
set +e
PATH="$TMP:$PATH" SYMBOLIC_PARSE_LOG="$TMP/parse.log" \
    "$ROOT/scripts/symbolic" parse > "$TMP/stdout" 2> "$TMP/stderr"
RC=$?
set -e
[ "$RC" -eq 137 ] || { echo "expected exit 137, got $RC" >&2; exit 1; }
[ ! -s "$TMP/stdout" ] || { echo 'unexpected stdout' >&2; exit 1; }
grep -q 'partial diagnostic' "$TMP/stderr" || { echo 'stderr lost' >&2; exit 1; }
grep -q 'exit_status=137 signal=SIGKILL' "$TMP/parse.log" || {
    echo 'missing SIGKILL diagnostic in CLI parse log' >&2
    exit 1
}
printf 'CLI parse abnormal exit logged with status 137\n'
