#!/bin/bash
# ==============================================================================
#  web-watcher — local test suite
#
#  Runs script.sh against a local HTTP server (tests/server.py) so the tests
#  need no network access. Requires python3 and curl.
#
#  Usage: tests/run.sh [test_name ...]
#
#  Every test runs under each shell in $WW_TEST_SHELLS (default: bash from
#  PATH plus /bin/bash when it is a different binary) and each locale in
#  $WW_TEST_LOCALES (default: C).
# ==============================================================================

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/script.sh"
FIXTURES="$ROOT/tests/fixtures"

TMP=$(mktemp -d)
SERVE="$TMP/www"
HOOKS="$TMP/hooks"
mkdir -p "$SERVE" "$HOOKS"

SERVER_PID=""
cleanup() {
    if [ -n "$SERVER_PID" ]; then
        kill "$SERVER_PID" 2>/dev/null
        wait "$SERVER_PID" 2>/dev/null
    fi
    rm -rf "$TMP"
}
trap cleanup EXIT

# --- Local server -------------------------------------------------------------

python3 "$ROOT/tests/server.py" "$SERVE" "$HOOKS" > "$TMP/port" 2> "$TMP/server.err" &
SERVER_PID=$!
for _ in $(seq 1 50); do
    [ -s "$TMP/port" ] && break
    sleep 0.1
done
if [ ! -s "$TMP/port" ]; then
    echo "FATAL: test server did not start" >&2
    cat "$TMP/server.err" >&2
    exit 1
fi
PORT=$(cat "$TMP/port")
BASE="http://127.0.0.1:$PORT"

# --- Matrix -------------------------------------------------------------------

if [ -z "${WW_TEST_SHELLS:-}" ]; then
    WW_TEST_SHELLS="bash"
    if [ -x /bin/bash ] && [ "$(command -v bash)" != "/bin/bash" ]; then
        WW_TEST_SHELLS="bash /bin/bash"
    fi
fi
WW_TEST_LOCALES="${WW_TEST_LOCALES:-C}"

# --- Assertions ---------------------------------------------------------------

PASS=0
FAIL=0
CURRENT=""
OUT=""
RC=0

pass() { PASS=$((PASS + 1)); }

fail() {
    FAIL=$((FAIL + 1))
    printf '  FAIL [%s | %s] %s: %s\n' "$SH" "$LOC" "$CURRENT" "$1"
    if [ -n "$OUT" ]; then
        printf '%s\n' "$OUT" | head -30 | sed 's/^/      | /'
    fi
}

assert_rc() {
    if [ "$RC" -eq "$1" ]; then pass; else fail "expected exit code $1, got $RC"; fi
}

assert_eq() {
    if [ "$1" = "$2" ]; then pass; else fail "expected '$2', got '$1'"; fi
}

assert_contains() {
    case "$1" in
        *"$2"*) pass ;;
        *) fail "expected to contain: $2" ;;
    esac
}

assert_not_contains() {
    case "$1" in
        *"$2"*) fail "expected NOT to contain: $2" ;;
        *) pass ;;
    esac
}

# --- Helpers ------------------------------------------------------------------

# Run script.sh under the current shell/locale; sets OUT (stdout+stderr) and RC.
ww() {
    OUT=$(LC_ALL="$LOC" "$SH" "$SCRIPT" --no-color --no-sound "$@" 2>&1 < /dev/null)
    RC=$?
}

# Run script.sh in the background; wait_bg collects OUT/RC (RC=124 on timeout).
BG_PID=""
run_bg() {
    LC_ALL="$LOC" "$SH" "$SCRIPT" --no-color --no-sound "$@" > "$TMP/bg.out" 2>&1 < /dev/null &
    BG_PID=$!
}

wait_bg() {
    local max_seconds="$1" i=0
    while kill -0 "$BG_PID" 2>/dev/null; do
        if [ "$i" -ge $((max_seconds * 10)) ]; then
            kill "$BG_PID" 2>/dev/null
            wait "$BG_PID" 2>/dev/null
            RC=124
            OUT=$(cat "$TMP/bg.out")
            return
        fi
        sleep 0.1
        i=$((i + 1))
    done
    wait "$BG_PID"
    RC=$?
    OUT=$(cat "$TMP/bg.out")
}

# Wait (up to N seconds) for a file to exist and be non-empty.
wait_for_file() {
    local file="$1" max_seconds="$2" i=0
    while [ ! -s "$file" ]; do
        if [ "$i" -ge $((max_seconds * 10)) ]; then return 1; fi
        sleep 0.1
        i=$((i + 1))
    done
    return 0
}

# Number of webhook requests recorded by the server.
hook_count() {
    find "$HOOKS" -name '*.json' | wc -l | tr -d ' '
}

# JSON field of the last recorded webhook request.
last_hook() {
    local latest
    latest=$(ls "$HOOKS"/*.json 2>/dev/null | tail -1)
    [ -n "$latest" ] || return 1
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$latest" "$1"
}

# 0 if the last recorded webhook body is valid JSON.
last_hook_body_is_json() {
    local latest
    latest=$(ls "$HOOKS"/*.json 2>/dev/null | tail -1)
    [ -n "$latest" ] || return 1
    python3 -c 'import json,sys; json.loads(json.load(open(sys.argv[1]))["body"])' "$latest" 2>/dev/null
}

reset_fixtures() {
    rm -f "$SERVE"/* "$HOOKS"/* "$TMP/baseline"
    cp "$FIXTURES"/* "$SERVE/"
}

# --- Tests --------------------------------------------------------------------

t_help_shows_usage() {
    ww --help
    assert_rc 0
    assert_contains "$OUT" "Usage:"
    assert_contains "$OUT" "--once"
    assert_contains "$OUT" "--baseline-file"
}

t_missing_url_fails() {
    ww
    assert_rc 1
    assert_contains "$OUT" "No URL provided"
}

t_invalid_url_scheme_rejected() {
    ww ftp://example.com
    assert_rc 1
    assert_contains "$OUT" "must start with http"
}

t_unknown_option_rejected() {
    ww --bogus "$BASE/a.json"
    assert_rc 1
    assert_contains "$OUT" "Unknown option"
}

t_invalid_interval_rejected() {
    ww -i 0 "$BASE/a.json"
    assert_rc 1
    assert_contains "$OUT" "positive integer"
}

t_invalid_mode_rejected() {
    ww -m invalid "$BASE/a.json"
    assert_rc 1
    assert_contains "$OUT" "must be one of"
}

t_once_captures_baseline() {
    ww --once "$BASE/a.json"
    assert_rc 0
    assert_contains "$OUT" "Baseline captured"
}

t_once_with_jq_filter() {
    ww --once -f '.price' --baseline-file "$TMP/baseline" "$BASE/a.json"
    assert_rc 0
    assert_eq "$(cat "$TMP/baseline")" "10"
}

t_once_detects_change_and_updates_baseline() {
    ww --once --baseline-file "$TMP/baseline" "$BASE/a.json"
    assert_rc 0
    [ -s "$TMP/baseline" ] || fail "baseline file not written"

    sed 's/"price": 10/"price": 12/' "$FIXTURES/a.json" > "$SERVE/a.json"
    ww --once --baseline-file "$TMP/baseline" "$BASE/a.json"
    assert_rc 2
    assert_contains "$OUT" "CHANGE DETECTED"
    assert_not_contains "$OUT" "syntax error"
    assert_eq "$(cat "$TMP/baseline")" "$(cat "$SERVE/a.json")"
}

t_once_no_change_exits_zero() {
    ww --once --baseline-file "$TMP/baseline" "$BASE/a.json"
    ww --once --baseline-file "$TMP/baseline" "$BASE/a.json"
    assert_rc 0
    assert_contains "$OUT" "No change"
}

t_max_runs_stops_after_n_checks() {
    ww -i 1 -n 2 "$BASE/a.json"
    assert_rc 0
    assert_contains "$OUT" "Reached max runs (2)"
}

# --- Runner -------------------------------------------------------------------

ALL_TESTS=$(declare -F | awk '{print $3}' | grep '^t_')
if [ $# -gt 0 ]; then
    TESTS="$*"
else
    TESTS="$ALL_TESTS"
fi

for SH in $WW_TEST_SHELLS; do
    if ! command -v "$SH" > /dev/null 2>&1; then
        echo "SKIP shell $SH (not found)"
        continue
    fi
    for LOC in $WW_TEST_LOCALES; do
        printf '== %s (%s) | LC_ALL=%s\n' "$SH" "$("$SH" -c 'echo "$BASH_VERSION"')" "$LOC"
        for CURRENT in $TESTS; do
            reset_fixtures
            OUT=""
            "$CURRENT"
        done
    done
done

echo ""
echo "Passed: $PASS   Failed: $FAIL"
[ "$FAIL" -eq 0 ]
