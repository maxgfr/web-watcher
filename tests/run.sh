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

# Extract and call a pure script.sh function without HTTP, in a subshell under
# the current shell/locale so unit tests exercise the same matrix as ww.
ww_fn() {
    local fn="$1"
    shift
    LC_ALL="$LOC" "$SH" -c '
        set -euo pipefail
        eval "$1"
        shift
        "$@"
    ' ww_fn "$(sed -n "/^${fn}() {/,/^}/p" "$SCRIPT")" "$fn" "$@"
}

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
    assert_contains "$OUT" "--ignore"
    assert_contains "$OUT" "--full-page"
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

t_once_with_max_runs_keeps_exit_code() {
    ww --once -n 1 --baseline-file "$TMP/baseline" "$BASE/a.json"
    assert_rc 0

    sed 's/"price": 10/"price": 12/' "$FIXTURES/a.json" > "$SERVE/a.json"
    ww --once -n 1 --baseline-file "$TMP/baseline" "$BASE/a.json"
    assert_rc 2
    assert_contains "$OUT" "CHANGE DETECTED"
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

t_once_threshold_keeps_baseline_until_notified() {
    ww --once --baseline-file "$TMP/baseline" "$BASE/a.json"
    assert_rc 0

    sed 's/"price": 10/"price": 12/' "$FIXTURES/a.json" > "$SERVE/a.json"
    ww --once -p 50 --baseline-file "$TMP/baseline" "$BASE/a.json"
    assert_rc 0
    assert_contains "$OUT" "Minor change"
    assert_eq "$(cat "$TMP/baseline")" "$(cat "$FIXTURES/a.json")"

    ww --once -p 50 --baseline-file "$TMP/baseline" "$BASE/a.json"
    assert_rc 0
    assert_contains "$OUT" "Minor change"

    printf '{"totally": "different"}\n' > "$SERVE/a.json"
    ww --once -p 50 --baseline-file "$TMP/baseline" "$BASE/a.json"
    assert_rc 2
    assert_eq "$(cat "$TMP/baseline")" "$(cat "$SERVE/a.json")"
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
    assert_rc 1
    assert_contains "$OUT" "Reached max runs (2)"
    assert_contains "$OUT" "No successful fetch in 2 runs"
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

t_webindex_backend() {
    if ! command -v webindex >/dev/null 2>&1; then
        echo "  SKIP t_webindex_backend (webindex not installed)"
        return
    fi
    ww --once -m website --baseline-file "$TMP/baseline" "$BASE/blocks.html"
    assert_rc 0
    assert_contains "$OUT" "Stripper:   webindex"
    local text
    text=$(cat "$TMP/baseline")
    assert_contains "$text" "Title"
    assert_contains "$text" "Item A"
    assert_not_contains "$text" "NavWord"
    assert_not_contains "$text" "Accept all cookies"

    rm -f "$TMP/baseline"
    ww --once -m website --full-page --baseline-file "$TMP/baseline" "$BASE/blocks.html"
    assert_rc 0
    assert_contains "$(cat "$TMP/baseline")" "NavWord"
    assert_contains "$(cat "$TMP/baseline")" "Accept all cookies"
}

t_webindex_fallback_when_missing() {
    mkdir -p "$TMP/shim" "$TMP/extract-tmp"
    cat > "$TMP/shim/webindex" <<'EOF'
#!/bin/sh
echo 'partial failed extraction'
echo 'unknown flag' >&2
exit 2
EOF
    chmod +x "$TMP/shim/webindex"
    local before after text
    before=$(find "$TMP/extract-tmp" -name 'ww.*' | wc -l)
    WW_HTML_STRIPPER=webindex PATH="$TMP/shim:$PATH" TMPDIR="$TMP/extract-tmp" \
        ww --once -m website --baseline-file "$TMP/baseline" "$BASE/page.html"
    assert_rc 0
    assert_contains "$OUT" "[WARN] webindex extract failed (exit 2), falling back to perl"
    text=$(cat "$TMP/baseline")
    assert_contains "$text" "Hello"
    assert_contains "$text" "Product"
    assert_not_contains "$text" "partial failed extraction"
    after=$(find "$TMP/extract-tmp" -name 'ww.*' | wc -l)
    assert_eq "$after" "$before"

    rm -f "$TMP/baseline"
    WW_HTML_STRIPPER=webindex PATH="$TMP/shim:$PATH" TMPDIR="$TMP/extract-tmp" \
        ww --once -m website --baseline-file "$TMP/baseline" "$BASE/blocks.html"
    assert_rc 0
    assert_not_contains "$(cat "$TMP/baseline")" "Accept all cookies"

    rm -f "$TMP/baseline"
    WW_HTML_STRIPPER=webindex PATH="$TMP/shim:$PATH" TMPDIR="$TMP/extract-tmp" \
        ww --once -m website --full-page --baseline-file "$TMP/baseline" "$BASE/blocks.html"
    assert_rc 0
    assert_contains "$OUT" "[WARN] webindex extract failed"
    assert_contains "$(cat "$TMP/baseline")" "NavWord"
    assert_contains "$(cat "$TMP/baseline")" "Accept all cookies"
    after=$(find "$TMP/extract-tmp" -name 'ww.*' | wc -l)
    assert_eq "$after" "$before"
    rm -f "$TMP/shim/webindex"
}

t_webindex_forced_when_present() {
    if ! command -v webindex >/dev/null 2>&1; then
        echo "  SKIP t_webindex_forced_when_present (webindex not installed)"
        return
    fi
    WW_HTML_STRIPPER=webindex ww --once -m website --baseline-file "$TMP/baseline" "$BASE/blocks.html"
    assert_rc 0
    assert_contains "$OUT" "Stripper:   webindex"
    assert_contains "$(cat "$TMP/baseline")" "# Title"
}

t_webindex_fallback_without_perl() {
    mkdir -p "$TMP/nopath" "$TMP/extract-tmp"
    local tool text
    # Exercise a genuinely missing webindex and perl, keeping only the
    # commands needed by the CLI (and the shell used by the test matrix).
    for tool in bash curl sed grep awk tr cat mktemp rm mv date sleep diff wc mkdir jq; do
        ln -sf "$(command -v "$tool")" "$TMP/nopath/$tool"
    done
    WW_HTML_STRIPPER=webindex PATH="$TMP/nopath" TMPDIR="$TMP/extract-tmp" \
        ww --once -m website --baseline-file "$TMP/baseline" "$BASE/page.html"
    assert_rc 0
    assert_contains "$OUT" "[WARN] webindex extract failed (exit 127), falling back to sed"
    text=$(cat "$TMP/baseline")
    assert_contains "$text" "Hello"
    assert_contains "$text" "Product"
    assert_eq "$(find "$TMP/extract-tmp" -name 'ww.*' | wc -l | tr -d ' ')" "0"
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

t_ignore_drops_lines_in_website_mode() {
    ww --once -m website --ignore 'ago|points' --baseline-file "$TMP/baseline" "$BASE/blocks.html"
    assert_rc 0
    local text
    text=$(cat "$TMP/baseline")
    assert_not_contains "$text" "minutes ago"
    assert_contains "$text" "Item A"
}

t_ignore_applies_in_api_mode() {
    ww --once --ignore '"rating"' --baseline-file "$TMP/baseline" "$BASE/a.json"
    assert_rc 0
    local text
    text=$(cat "$TMP/baseline")
    assert_not_contains "$text" "rating"
    assert_contains "$text" '"price": 10'
}

t_ignore_applies_when_jq_fails() {
    ww --once -f '.[' --ignore '"rating"' --baseline-file "$TMP/baseline" "$BASE/a.json"
    assert_rc 0
    assert_contains "$OUT" "jq filter failed"
    local text
    text=$(cat "$TMP/baseline")
    assert_not_contains "$text" "rating"
    assert_contains "$text" "price"
}

t_ignore_changes_not_notified() {
    ww --once -m website --ignore 'ago' --baseline-file "$TMP/baseline" "$BASE/blocks.html"
    assert_rc 0
    sed 's/posted 3 minutes ago/posted 9 minutes ago/' "$FIXTURES/blocks.html" > "$SERVE/blocks.html"
    ww --once -m website --ignore 'ago' --baseline-file "$TMP/baseline" "$BASE/blocks.html"
    assert_rc 0
    assert_contains "$OUT" "No change"

    sed -e 's/posted 3 minutes ago/posted 9 minutes ago/' -e 's/Item A/Item Z/' "$FIXTURES/blocks.html" > "$SERVE/blocks.html"
    ww --once -m website --ignore 'ago' --baseline-file "$TMP/baseline" "$BASE/blocks.html"
    assert_rc 2
}

t_ignore_shown_in_config() {
    ww --once --ignore a --ignore b "$BASE/a.json"
    assert_rc 0
    assert_contains "$OUT" "Ignore:     2 pattern(s)"
}

t_ignore_applies_when_selector_not_found() {
    ww --once -m website -s 'missing-selector' --ignore 'ago' --baseline-file "$TMP/baseline" "$BASE/blocks.html"
    assert_rc 0
    assert_contains "$OUT" "Selector pattern not found"
    local text
    text=$(cat "$TMP/baseline")
    assert_not_contains "$text" "minutes ago"
    assert_contains "$text" "Item A"
    # The selector fallback still returns HTML, without later stripping.
    assert_contains "$text" "<html>"
}

t_ignore_multiple_patterns_keep_non_utf8_content() {
    printf 'abc\377\376def\ndrop one\n-drop two\nKeep\n' > "$SERVE/bin.dat"
    ww --once --ignore '^drop' --ignore '-drop' --baseline-file "$TMP/baseline" "$BASE/bin.dat"
    assert_rc 0
    assert_eq "$(cat "$TMP/baseline")" "$(printf 'abc\377\376def\nKeep')"
}

t_ignore_can_drop_all_lines() {
    ww --once --ignore '.*' --baseline-file "$TMP/baseline" "$BASE/a.json"
    assert_rc 0
    assert_eq "$(cat "$TMP/baseline")" ""
    ww --once --ignore '.*' --baseline-file "$TMP/baseline" "$BASE/a.json"
    assert_rc 0
    assert_contains "$OUT" "No change"
}

t_website_mode_one_line_per_block() {
    # This exact plain-heading format belongs to the legacy stripper.
    WW_HTML_STRIPPER=perl ww --once -m website --baseline-file "$TMP/baseline" "$BASE/page.html"
    assert_rc 0
    local expected
    expected=$(cat <<'EOF'
Hello
Price: 10 € © 'quoted'
Product
Visible
EOF
)
    assert_eq "$(cat "$TMP/baseline")" "$expected"
}

t_chrome_blocks_removed_by_default() {
    # Legacy stripping removes every header/aside; webindex isolates main
    # content using its own policy (covered by t_webindex_backend).
    WW_HTML_STRIPPER="${WW_HTML_STRIPPER:-perl}" ww --once -m website --baseline-file "$TMP/baseline" "$BASE/blocks.html"
    assert_rc 0
    assert_contains "$OUT" "Page:       main content (use --full-page to keep chrome)"
    local text
    text=$(cat "$TMP/baseline")
    assert_contains "$text" "Title"
    assert_contains "$text" "Item A"
    assert_not_contains "$text" "NavWord"
    assert_not_contains "$text" "HeaderWord"
    assert_not_contains "$text" "FooterWord"
    assert_not_contains "$text" "AsideWord"
    assert_not_contains "$text" "Accept all cookies"
}

t_full_page_keeps_chrome() {
    ww --once -m website --full-page --baseline-file "$TMP/baseline" "$BASE/blocks.html"
    assert_rc 0
    assert_contains "$OUT" "Page:       full page"
    local text
    text=$(cat "$TMP/baseline")
    assert_contains "$text" "Title"
    assert_contains "$text" "Item A"
    assert_contains "$text" "NavWord"
    assert_contains "$text" "HeaderWord"
    assert_contains "$text" "FooterWord"
    assert_contains "$text" "AsideWord"
    assert_contains "$text" "Accept all cookies"
}

t_sed_fallback_chrome_blocks_removed_by_default() {
    WW_HTML_STRIPPER="sed" t_chrome_blocks_removed_by_default
}

t_sed_fallback_full_page_keeps_chrome() {
    WW_HTML_STRIPPER="sed" t_full_page_keeps_chrome
}

t_website_mode_blocks_fixture() {
    # Shared legacy expectation; the sed wrapper can still select sed.
    WW_HTML_STRIPPER="${WW_HTML_STRIPPER:-perl}" ww --once -m website --baseline-file "$TMP/baseline" "$BASE/blocks.html"
    assert_rc 0
    local expected
    expected=$(cat <<'EOF'
Title
Paragraph one continues here and ends.
Item A
Item B
second line
Row 1 Cell A
Row 1 Cell B
Row 2 Cell A
Row 2 Cell B
posted 3 minutes ago
See the link now
EOF
)
    assert_eq "$(cat "$TMP/baseline")" "$expected"
    assert_eq "$(LC_ALL=C grep -c "$(printf '\t')" "$TMP/baseline")" "0"
    assert_eq "$(LC_ALL=C grep -c '^ \| $' "$TMP/baseline")" "0"
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

t_perl_stripper_script_containing_comment_opener() {
    WW_HTML_STRIPPER=perl ww --once -m website --baseline-file "$TMP/baseline" "$BASE/tricky.html"
    assert_rc 0
    local text
    text=$(cat "$TMP/baseline")
    assert_contains "$text" "Price"
    assert_contains "$text" "Important"
    assert_contains "$text" "Tail"
    assert_not_contains "$text" "x()"
    assert_not_contains "$text" "<!--"
    assert_not_contains "$(tr '\n' ' ' < "$TMP/baseline")" "1 < 2"
}

t_entities_decoded_once() {
    # Perl preserves invalid numeric entities; webindex replaces them.
    WW_HTML_STRIPPER=perl ww --once -m website --baseline-file "$TMP/baseline" "$BASE/tricky.html"
    assert_rc 0
    local text
    text=$(cat "$TMP/baseline")
    assert_contains "$text" "&lt;"
    assert_contains "$(tr '\n' ' ' < "$TMP/baseline")" "Price: 5 &lt; 10"
    assert_not_contains "$(tr '\n' ' ' < "$TMP/baseline")" "Price: 5 < 10"
    assert_contains "$text" "$(printf '\360\237\230\200')"
    assert_contains "$text" "&#1114112;"
    assert_contains "$text" "&#xD800;"
    assert_contains "$text" "&#57343;"
}

t_website_mode_sed_fallback_strips_scripts_styles_and_tags() {
    WW_HTML_STRIPPER="sed" ww --once -m website --baseline-file "$TMP/baseline" "$BASE/page.html"
    assert_rc 0
    check_stripped_page "$(cat "$TMP/baseline")"
}

t_sed_fallback_one_line_per_block() {
    # The fallback decoder supports &copy;, but not arbitrary numeric entities.
    sed 's/&#169;/\&copy;/g' "$FIXTURES/page.html" > "$SERVE/page.html"
    WW_HTML_STRIPPER="sed" ww --once -m website --baseline-file "$TMP/baseline" "$BASE/page.html"
    assert_rc 0
    local expected
    expected=$(cat <<'EOF'
Hello
Price: 10 € © 'quoted'
Product
Visible
EOF
)
    assert_eq "$(cat "$TMP/baseline")" "$expected"
}

t_sed_fallback_unclosed_comment_keeps_text() {
    WW_HTML_STRIPPER="sed" ww --once -m website --baseline-file "$TMP/baseline" "$BASE/tricky.html"
    assert_rc 0
    local text
    text=$(cat "$TMP/baseline")
    assert_contains "$text" "Tail"
    assert_not_contains "$text" "<!--"
}

t_sed_fallback_blocks_fixture() {
    WW_HTML_STRIPPER="sed" t_website_mode_blocks_fixture
}

t_sed_fallback_record_and_window_boundaries() {
    # Move each delimiter through a window edge; quoted tags, comments and
    # raw closing tags must also keep their state across input records.
    "$PYTHON" - "$SERVE/boundaries.html" <<'PY'
import sys
with open(sys.argv[1], "wb") as page:
    for padding in range(4070, 4100):
        page.write(b' ' * padding + b'<p>1 < 2 <a\n title="a > b">Caf\xe9</a>\n'
                   b'continues</p><!--' + b'x' * padding + b'-->\n'
                   b'<ScRiPt>' + b'x' * padding + b'</sCrIpT\n>\n'
                   b'<div data-note=\'' + b'x' * padding + b'>\nquoted\'>Tail</div>\n')
PY
    WW_HTML_STRIPPER="sed" ww --once -m website --baseline-file "$TMP/baseline" "$BASE/boundaries.html"
    assert_rc 0
    local expected i
    expected=$(
        i=0
        while [ "$i" -lt 30 ]; do
            printf '1 < 2 Caf\351 continues\nTail\n'
            i=$((i + 1))
        done
    )
    assert_eq "$(cat "$TMP/baseline")" "$expected"
}

t_sed_fallback_script_with_comment_opener() {
    WW_HTML_STRIPPER="sed" ww --once -m website --baseline-file "$TMP/baseline" "$BASE/tricky.html"
    assert_rc 0
    local text
    text=$(cat "$TMP/baseline")
    assert_contains "$text" "Price"
    assert_contains "$text" "Important"
    assert_not_contains "$text" "x()"
    assert_not_contains "$(tr '\n' ' ' < "$TMP/baseline")" "1 < 2"
}

t_sed_fallback_is_linear_on_large_page() {
    # One long record also catches repeated copying/scanning of its suffix.
    "$PYTHON" - "$SERVE/big.html" <<'PY'
import sys
with open(sys.argv[1], "w") as page:
    for n in range(20000):
        page.write('<div class="row"><a href="/i/{0}">Item {0}</a> '
                   '<script>var x = {0};</script><p>Text {0} &amp; more</p></div>'.format(n))
    page.write('\n')
PY
    local start elapsed text
    start=$(date +%s)
    WW_HTML_STRIPPER="sed" WW_TEST_TIMEOUT=60 ww --once -m website --baseline-file "$TMP/baseline" "$BASE/big.html"
    elapsed=$(($(date +%s) - start))
    assert_rc 0
    text=$(cat "$TMP/baseline")
    assert_contains "$text" "Item 19999"
    assert_not_contains "$text" "var x"
    printf '  Large sed page [%s | %s]: %s s\n' "$SH" "$LOC" "$elapsed"
    if [ "$elapsed" -lt 15 ]; then pass; else fail "large sed page took ${elapsed}s (expected < 15s)"; fi
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

t_json_escape_control_chars() {
    local input escaped
    input=$(printf 'a\033b\010c\001d\ttab\nnl"q\\bs')
    escaped=$(ww_fn json_escape "$input")
    if printf '%s' "$escaped" | "$PYTHON" -c '
import json,sys
v = json.loads(sys.stdin.read())
assert v == sys.argv[1], repr(v)
' "$input"; then pass; else fail "control characters did not round-trip through JSON"; fi
    assert_contains "$escaped" '\u001b'
    assert_contains "$escaped" '\u0008'

    # Include every non-NUL C0 character, with a suffix to preserve newlines.
    input=$(printf '\001\002\003\004\005\006\007\010\011\012\013\014\015\016\017\020\021\022\023\024\025\026\027\030\031\032\033\034\035\036\037end')
    escaped=$(ww_fn json_escape "$input")
    if printf '%s' "$escaped" | "$PYTHON" -c '
import json,sys
v = json.loads(sys.stdin.read())
assert v == sys.argv[1], repr(v)
' "$input"; then pass; else fail "full C0 range did not round-trip through JSON"; fi

    # High bytes must remain untouched, even when invalid in the active locale.
    input=$(printf '\200\303\251\377')
    assert_eq "$(ww_fn json_escape "$input")" "\"$input\""
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
