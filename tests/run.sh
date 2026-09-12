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
#  $WW_TEST_LOCALES (default: C fr_FR.UTF-8; missing fr_FR.UTF-8 is fatal).
#  Set WW_TEST_LOCALES=C to explicitly run without the decimal-comma locale.
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

PYTHON="${WW_TEST_PYTHON:-}"
if [ -z "$PYTHON" ]; then
    for candidate in python3 python; do
        if command -v "$candidate" > /dev/null 2>&1; then
            PYTHON="$candidate"
            break
        fi
    done
fi
if [ -z "$PYTHON" ]; then
    echo "FATAL: python3 is required to run the test suite" >&2
    exit 1
fi

"$PYTHON" "$ROOT/tests/server.py" "$SERVE" "$HOOKS" > "$TMP/port" 2> "$TMP/server.err" &
SERVER_PID=$!

# Wait for the server to print its port. A cold interpreter on a CI runner can
# take several seconds, so allow 30s, but give up at once if the process dies.
waited=0
while [ ! -s "$TMP/port" ]; do
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        echo "FATAL: test server exited before printing its port" >&2
        echo "  interpreter: $PYTHON ($("$PYTHON" --version 2>&1))" >&2
        sed 's/^/  stderr: /' "$TMP/server.err" >&2
        exit 1
    fi
    if [ "$waited" -ge 300 ]; then
        echo "FATAL: test server did not print its port within 30s" >&2
        echo "  interpreter: $PYTHON ($("$PYTHON" --version 2>&1))" >&2
        sed 's/^/  stderr: /' "$TMP/server.err" >&2
        exit 1
    fi
    sleep 0.1
    waited=$((waited + 1))
done
PORT=$(cat "$TMP/port")
BASE="http://127.0.0.1:$PORT"

# --- Matrix -------------------------------------------------------------------

if [ -z "${WW_TEST_SHELLS:-}" ]; then
    WW_TEST_SHELLS="bash"
    if [ -x /bin/bash ] && [ "$(command -v bash)" != "/bin/bash" ]; then
        WW_TEST_SHELLS="bash /bin/bash"
    fi
fi
if [ -z "${WW_TEST_LOCALES:-}" ]; then
    # A locale with a decimal comma catches number-formatting bugs (awk/printf).
    if locale -a 2>/dev/null | grep -qi '^fr_FR\.utf-\{0,1\}8$'; then
        WW_TEST_LOCALES="C fr_FR.UTF-8"
    else
        echo "FATAL: locale fr_FR.UTF-8 not installed; set WW_TEST_LOCALES=C to explicitly skip decimal-comma tests" >&2
        exit 1
    fi
fi

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
# Killed after $WW_TEST_TIMEOUT seconds (RC=124) so a runaway loop fails
# instead of hanging the suite.
ww() {
    run_bg "$@"
    wait_bg "${WW_TEST_TIMEOUT:-20}"
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
    "$PYTHON" -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$latest" "$1"
}

# 0 if the last recorded webhook body is valid JSON.
last_hook_body_is_json() {
    local latest
    latest=$(ls "$HOOKS"/*.json 2>/dev/null | tail -1)
    [ -n "$latest" ] || return 1
    "$PYTHON" -c 'import json,sys; json.loads(json.load(open(sys.argv[1]))["body"])' "$latest" 2>/dev/null
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
    assert_contains "$OUT" "--interval must be an integer >= 1"
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

t_change_percent_uses_decimal_point() {
    ww --once --baseline-file "$TMP/baseline" "$BASE/a.json"
    sed 's/"price": 10/"price": 12/' "$FIXTURES/a.json" > "$SERVE/a.json"
    ww --once --baseline-file "$TMP/baseline" "$BASE/a.json"
    assert_rc 2
    assert_contains "$OUT" "Change of 9.09% detected"
}

t_threshold_minor_change_not_notified() {
    ww --once --baseline-file "$TMP/baseline" "$BASE/a.json"
    sed 's/"price": 10/"price": 12/' "$FIXTURES/a.json" > "$SERVE/a.json"
    ww --once -p 50 --baseline-file "$TMP/baseline" "$BASE/a.json"
    assert_rc 0
    assert_contains "$OUT" "Minor change (9.09% < 50% threshold)"
    assert_not_contains "$OUT" "CHANGE DETECTED"
}

t_threshold_major_change_notified() {
    ww --once --baseline-file "$TMP/baseline" "$BASE/a.json"
    printf '{"totally": "different"}\n' > "$SERVE/a.json"
    ww --once -p 50 --baseline-file "$TMP/baseline" "$BASE/a.json"
    assert_rc 2
    assert_contains "$OUT" "CHANGE DETECTED"
}

t_continuous_mode_survives_a_change() {
    run_bg -i 1 -n 3 "$BASE/a.json"
    sleep 1.5
    sed 's/"price": 10/"price": 12/' "$FIXTURES/a.json" > "$SERVE/a.json"
    wait_bg 10
    assert_rc 0
    assert_contains "$OUT" "CHANGE DETECTED"
    assert_contains "$OUT" "Reached max runs (3)"
}

t_max_runs_stops_after_n_checks() {
    ww -i 1 -n 2 "$BASE/a.json"
    assert_rc 0
    assert_contains "$OUT" "Reached max runs (2)"
}

t_max_runs_counts_failed_fetches() {
    # Port 1 refuses connections: every fetch fails, -n must still stop the loop.
    run_bg -i 1 -n 2 --retries 1 --retry-delay 0 http://127.0.0.1:1/
    wait_bg 8
    assert_rc 0
    assert_contains "$OUT" "Reached max runs (2)"
}

t_retries_zero_rejected() {
    ww --retries 0 "$BASE/a.json"
    assert_rc 1
    assert_contains "$OUT" "--retries must be an integer >= 1"
}

t_huge_integer_option_rejected() {
    ww -i 99999999999999999999 "$BASE/a.json"
    assert_rc 1
    assert_contains "$OUT" "--interval must be an integer >= 1"
    assert_not_contains "$OUT" "integer expression expected"

    ww -n 99999999999999999999 "$BASE/a.json"
    assert_rc 1
    assert_contains "$OUT" "--max-runs must be an integer >= 0"
    assert_not_contains "$OUT" "integer expression expected"

    ww --once -i 999999999 "$BASE/a.json"
    assert_rc 0
    assert_contains "$OUT" "Baseline captured"
}

t_non_integer_options_rejected() {
    ww --retries abc "$BASE/a.json"
    assert_rc 1
    assert_contains "$OUT" "--retries must be an integer >= 1"
    ww -n abc "$BASE/a.json"
    assert_rc 1
    assert_contains "$OUT" "--max-runs must be an integer >= 0"
    ww --timeout 0 "$BASE/a.json"
    assert_rc 1
    assert_contains "$OUT" "--timeout must be an integer >= 1"
    ww --retry-delay -1 "$BASE/a.json"
    assert_rc 1
    assert_contains "$OUT" "--retry-delay must be an integer >= 0"
}

# Assertions shared by the HTML stripper tests: $1 is the extracted text.
check_stripped_page() {
    assert_contains "$1" "Hello"
    assert_contains "$1" "Product"
    assert_contains "$1" "€"
    assert_contains "$1" "'quoted'"
    assert_not_contains "$1" "<"
    assert_not_contains "$1" "var"
    assert_not_contains "$1" "Date.now"
    assert_not_contains "$1" "nonce"
    assert_not_contains "$1" "href"
    assert_not_contains "$1" "color:"
    assert_not_contains "$1" "comment"
    assert_not_contains "$1" "&euro;"
    assert_not_contains "$1" "&#x27;"
}

t_verbose_does_not_pollute_baseline() {
    ww --once -v -m website --baseline-file "$TMP/baseline" "$BASE/page.html"
    assert_rc 0
    local text
    text=$(cat "$TMP/baseline")
    assert_not_contains "$text" "[DEBUG]"
    assert_not_contains "$text" "stripper"
    assert_contains "$OUT" "[DEBUG] HTML stripper"
}

t_website_mode_strips_scripts_styles_and_tags() {
    ww --once -m website --baseline-file "$TMP/baseline" "$BASE/page.html"
    assert_rc 0
    local text
    text=$(cat "$TMP/baseline")
    check_stripped_page "$text"
    assert_contains "$text" "©"          # numeric entity &#169;
    assert_not_contains "$text" "&#"
}

t_website_mode_strips_tags_with_quoted_angle_brackets() {
    # A ">" inside a quoted attribute value must not end the tag early,
    # otherwise the rest of the attribute leaks into the compared text.
    ww --once -m website --baseline-file "$TMP/baseline" "$BASE/page.html"
    assert_rc 0
    local text
    text=$(cat "$TMP/baseline")
    assert_contains "$text" "Visible"
    assert_not_contains "$text" "parts"
    assert_not_contains "$text" "template"
    assert_not_contains "$text" "meta"
}

t_website_mode_sed_fallback_strips_scripts_styles_and_tags() {
    WW_HTML_STRIPPER="sed" ww --once -m website --baseline-file "$TMP/baseline" "$BASE/page.html"
    assert_rc 0
    check_stripped_page "$(cat "$TMP/baseline")"
}

t_website_mode_ignores_script_only_changes() {
    ww --once -m website --baseline-file "$TMP/baseline" "$BASE/page.html"
    sed 's/abc123/zzz999/' "$FIXTURES/page.html" > "$SERVE/page.html"
    ww --once -m website --baseline-file "$TMP/baseline" "$BASE/page.html"
    assert_rc 0
    assert_contains "$OUT" "No change"
}

# Run a --once baseline then a changed --once with the given extra options,
# so a notification is sent on the second run.
trigger_change() {
    ww --once --baseline-file "$TMP/baseline" "$@"
    sed 's/"price": 10/"price": 12/' "$FIXTURES/a.json" > "$SERVE/a.json"
    ww --once --baseline-file "$TMP/baseline" "$@"
}

t_slack_webhook_sends_valid_json() {
    # A URL with quotes and a backslash must not break the JSON payload.
    trigger_change --slack "$BASE/hook/slack" "$BASE/a.json?q=\"x\"\\y"
    assert_rc 2
    assert_eq "$(hook_count)" "1"
    assert_contains "$(last_hook path)" "/hook/slack"
    assert_contains "$(last_hook content_type)" "application/json"
    if last_hook_body_is_json; then pass; else fail "Slack body is not valid JSON: $(last_hook body)"; fi
    assert_contains "$(last_hook body)" "Change Detected"
    assert_contains "$(last_hook body)" "a.json?q="
    assert_not_contains "$OUT" "[WARN]"
}

t_discord_webhook_sends_valid_json() {
    trigger_change --discord "$BASE/hook/discord" "$BASE/a.json?q=\"x\"\\y"
    assert_rc 2
    assert_eq "$(hook_count)" "1"
    assert_contains "$(last_hook path)" "/hook/discord"
    if last_hook_body_is_json; then pass; else fail "Discord body is not valid JSON: $(last_hook body)"; fi
    assert_contains "$(last_hook body)" "Change Detected"
    assert_not_contains "$OUT" "[WARN]"
}

t_webhook_http_error_is_reported() {
    trigger_change --slack "$BASE/hook/fail-slack" --discord "$BASE/hook/fail-discord" "$BASE/a.json"
    assert_rc 2
    assert_eq "$(hook_count)" "2"
    assert_contains "$OUT" "[WARN] Slack notification failed"
    assert_contains "$OUT" "[WARN] Discord notification failed"
}

t_telegram_sends_full_message_urlencoded() {
    # "&" in the URL must stay inside the text field, "_" must not need escaping.
    WW_TELEGRAM_API="$BASE" trigger_change --telegram-token "123:abc" --telegram-chat "42" \
        "$BASE/a.json?x=1&y=my_value"
    assert_rc 2
    assert_eq "$(hook_count)" "1"
    assert_contains "$(last_hook path)" "/bot123:abc/sendMessage"
    local text
    text=$("$PYTHON" -c 'import sys,urllib.parse; q=urllib.parse.parse_qs(sys.stdin.read()); print(q["chat_id"][0]); print(q["text"][0])' <<< "$(last_hook body)")
    assert_contains "$text" "42"
    assert_contains "$text" "Change Detected"
    assert_contains "$text" "a.json?x=1&y=my_value"
    assert_not_contains "$OUT" "[WARN]"
}

t_telegram_http_error_is_reported() {
    WW_TELEGRAM_API="$BASE" trigger_change --telegram-token "fail" --telegram-chat "42" "$BASE/a.json"
    assert_rc 2
    assert_contains "$OUT" "[WARN] Telegram notification failed"
}

# Build an ISO-8859-1 page (bytes that are invalid in a UTF-8 locale).
write_latin1_page() {
    printf '<html><body><h1>Caf\351 du Commerce</h1>\n<p>Pr\350s de la gare \340 c\364t\351 &euro;</p>\n<script>var x = 1 < 2;</script>\n</body></html>\n' > "$SERVE/latin1.html"
}

t_website_mode_keeps_non_utf8_content() {
    write_latin1_page
    ww --once -m website --baseline-file "$TMP/baseline" "$BASE/latin1.html"
    assert_rc 0
    local text
    text=$(cat "$TMP/baseline")
    assert_contains "$text" "Commerce"
    assert_contains "$text" "gare"
    assert_contains "$text" "Caf"
    assert_not_contains "$text" "var"
    assert_not_contains "$text" "<"
}

t_website_mode_sed_fallback_keeps_non_utf8_content() {
    write_latin1_page
    WW_HTML_STRIPPER="sed" ww --once -m website --baseline-file "$TMP/baseline" "$BASE/latin1.html"
    assert_rc 0
    local text
    text=$(cat "$TMP/baseline")
    assert_contains "$text" "Commerce"
    assert_contains "$text" "gare"
    assert_not_contains "$text" "var"
    assert_not_contains "$text" "<"
}

t_non_utf8_content_is_kept() {
    # Invalid UTF-8 bytes must not make grep treat the response as binary.
    printf 'abc\377\376def\nghi\n' > "$SERVE/bin.dat"
    ww --once --baseline-file "$TMP/baseline" "$BASE/bin.dat"
    assert_rc 0
    local text
    text=$(cat "$TMP/baseline")
    assert_contains "$text" "abc"
    assert_contains "$text" "def"
    assert_contains "$text" "ghi"
    assert_not_contains "$text" "Binary file"
}

t_continuous_mode_updates_baseline_file_on_change() {
    run_bg -i 1 -n 3 --baseline-file "$TMP/baseline" "$BASE/a.json"
    wait_for_file "$TMP/baseline" 5 || fail "baseline file not written on first run"
    sed 's/"price": 10/"price": 12/' "$FIXTURES/a.json" > "$SERVE/a.json"
    wait_bg 10
    assert_rc 0
    assert_contains "$OUT" "CHANGE DETECTED"
    assert_eq "$(cat "$TMP/baseline")" "$(cat "$SERVE/a.json")"
}

t_notify_channels_listed_with_separator() {
    ww --once --slack "$BASE/hook/slack" --discord "$BASE/hook/discord" "$BASE/a.json"
    assert_rc 0
    assert_contains "$OUT" "Notify:     Slack, Discord"
}

t_content_looking_like_echo_option_is_kept() {
    ww --once --baseline-file "$TMP/baseline" "$BASE/dash.txt"
    assert_rc 0
    assert_eq "$(cat "$TMP/baseline")" "-n"
}

t_retry_delay_zero_accepted() {
    ww --once --retry-delay 0 "$BASE/a.json"
    assert_rc 0
    assert_contains "$OUT" "Baseline captured"
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
