#!/bin/bash

# ==============================================================================
#  web-watcher
#  Watch APIs & Websites for changes — Get notified instantly from your terminal
# ==============================================================================

set -euo pipefail

# --- Configuration & Defaults ---
VERSION="1.0.1"
DEFAULT_INTERVAL=30
DEFAULT_THRESHOLD=0
DEFAULT_METHOD="GET"
DEFAULT_TIMEOUT=15
DEFAULT_RETRIES=3
DEFAULT_RETRY_DELAY=5
DEFAULT_MODE="auto"
DEFAULT_USER_AGENT="web-watcher/$VERSION"

# --- Runtime State ---
INTERVAL="$DEFAULT_INTERVAL"
THRESHOLD="$DEFAULT_THRESHOLD"
METHOD="$DEFAULT_METHOD"
TIMEOUT="$DEFAULT_TIMEOUT"
RETRIES="$DEFAULT_RETRIES"
RETRY_DELAY="$DEFAULT_RETRY_DELAY"
MODE="$DEFAULT_MODE"
USER_AGENT="$DEFAULT_USER_AGENT"
URL=""
BODY=""
JQ_FILTER=""
SELECTOR=""
HEADERS=()
COOKIES=""
AUTH=""
LOG_FILE=""
SNAPSHOT_DIR=""
VERBOSE=false
QUIET=false
SOUND=true
NO_COLOR=false
FOLLOW_REDIRECTS=true
INSECURE=false
SHOW_DIFF=false
ONCE=false
MAX_RUNS=0
STRIP_HTML=false
HAS_DIFF=false
BASELINE_FILE=""

# --- Colors ---
setup_colors() {
    if [ -t 1 ] && [ "$NO_COLOR" = false ]; then
        RED='\033[0;31m'
        GREEN='\033[0;32m'
        BLUE='\033[0;34m'
        YELLOW='\033[1;33m'
        MAGENTA='\033[0;35m'
        CYAN='\033[0;36m'
        BOLD='\033[1m'
        DIM='\033[2m'
        NC='\033[0m'
    else
        RED='' GREEN='' BLUE='' YELLOW='' MAGENTA='' CYAN='' BOLD='' DIM='' NC=''
    fi
}

# --- Helper Functions ---

log_info() {
    [ "$QUIET" = true ] && return
    printf "${BLUE}[INFO]${NC} %s\n" "$1"
}

log_success() {
    printf "${GREEN}[OK]${NC} %s\n" "$1"
}

log_warn() {
    printf "${YELLOW}[WARN]${NC} %s\n" "$1" >&2
}

log_error() {
    printf "${RED}[ERROR]${NC} %s\n" "$1" >&2
}

log_change() {
    printf "${MAGENTA}[CHANGE]${NC} %s\n" "$1"
}

log_verbose() {
    if [ "$VERBOSE" = true ]; then
        printf "${DIM}[DEBUG] %s${NC}\n" "$1"
    fi
}

log_to_file() {
    if [ -n "$LOG_FILE" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
    fi
}

# --- Notification ---

send_notification() {
    local title="$1"
    local message="$2"

    # Terminal bell
    if [ "$SOUND" = true ]; then
        printf '\a'
    fi

    # OS-level notification
    if [[ "$OSTYPE" == "darwin"* ]]; then
        osascript -e "display notification \"$message\" with title \"$title\" sound name \"Glass\"" 2>/dev/null || true
    elif command -v notify-send &>/dev/null; then
        notify-send "$title" "$message" 2>/dev/null || true
    fi

    # Always print to terminal
    echo ""
    echo -e "${RED}${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}${BOLD}║  🔔  CHANGE DETECTED                                        ║${NC}"
    echo -e "${RED}${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo -e "  ${BOLD}URL:${NC}  $URL"
    echo -e "  ${BOLD}Time:${NC} $(date '+%Y-%m-%d %H:%M:%S')"
    echo -e "  ${BOLD}Info:${NC} $message"
    echo ""
}

# --- Banner ---

print_banner() {
    [ "$QUIET" = true ] && return
    echo -e "${CYAN}"
    echo " ██╗    ██╗███████╗██████╗       ██╗    ██╗ █████╗ ████████╗ ██████╗██╗  ██╗███████╗██████╗ "
    echo " ██║    ██║██╔════╝██╔══██╗      ██║    ██║██╔══██╗╚══██╔══╝██╔════╝██║  ██║██╔════╝██╔══██╗"
    echo " ██║ █╗ ██║█████╗  ██████╔╝█████╗██║ █╗ ██║███████║   ██║   ██║     ███████║█████╗  ██████╔╝"
    echo " ██║███╗██║██╔══╝  ██╔══██╗╚════╝██║███╗██║██╔══██║   ██║   ██║     ██╔══██║██╔══╝  ██╔══██╗"
    echo " ╚███╔███╔╝███████╗██████╔╝      ╚███╔███╔╝██║  ██║   ██║   ╚██████╗██║  ██║███████╗██║  ██║"
    echo "  ╚══╝╚══╝ ╚══════╝╚═════╝        ╚══╝╚══╝ ╚═╝  ╚═╝   ╚═╝    ╚═════╝╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝"
    echo -e "${NC}"
    echo -e "                     Watch APIs & Websites for changes  v$VERSION"
    echo ""
}

# --- Usage ---

print_usage() {
    echo "Usage: web-watcher [options] <url>"
    echo ""
    echo "Arguments:"
    echo "  url                         URL to watch (API endpoint or website)"
    echo ""
    echo "Request Options:"
    echo "  -X, --method <METHOD>       HTTP method: GET, POST, PUT, etc. (default: GET)"
    echo "  -H, --header <header>       Add a custom header (repeatable)"
    echo "                              Example: -H 'Authorization: Bearer token123'"
    echo "  -d, --data <body>           Request body for POST/PUT requests"
    echo "  -C, --cookie <cookie>       Cookie string or file path"
    echo "  -A, --user-agent <ua>       Custom User-Agent string"
    echo "  --auth <user:pass>          Basic authentication credentials"
    echo "  --timeout <secs>            Request timeout in seconds (default: 15)"
    echo "  --no-follow                 Do not follow redirects"
    echo "  --insecure                  Allow insecure SSL connections"
    echo ""
    echo "Watch Options:"
    echo "  -i, --interval <secs>       Seconds between checks (default: 30)"
    echo "  -p, --threshold <percent>   Min change % to trigger notification (default: 0 = any change)"
    echo "  -n, --max-runs <num>        Stop after N checks (0 = unlimited, default: 0)"
    echo "  --once                      Run a single check then exit (useful for cron)"
    echo "  --baseline-file <file>      Persist baseline to disk (required for --once to detect changes)"
    echo "  --retries <num>             Number of retries on failure (default: 3)"
    echo "  --retry-delay <secs>        Delay between retries in seconds (default: 5)"
    echo ""
    echo "Content Options:"
    echo "  -m, --mode <mode>           Watch mode: api, website, auto (default: auto)"
    echo "                              api     = compare raw response (JSON, XML, etc.)"
    echo "                              website = extract text content, strip HTML tags"
    echo "                              auto    = detect from Content-Type header"
    echo "  -f, --filter <jq_expr>      jq filter for JSON responses (e.g., '.data.price')"
    echo "  -s, --selector <pattern>    Grep pattern to extract specific content from HTML"
    echo "  --strip-html                Force HTML tag stripping (useful with --mode api)"
    echo ""
    echo "Output Options:"
    echo "  -l, --log <file>            Log changes to a file"
    echo "  --snapshot-dir <dir>        Save snapshots of each response"
    echo "  --diff                      Show unified diff of changes"
    echo "  --no-sound                  Disable terminal bell on change"
    echo "  -q, --quiet                 Suppress info output (only show changes)"
    echo "  -v, --verbose               Verbose debug output"
    echo "  --no-color                  Disable colored output"
    echo "  -h, --help                  Show this help message"
    echo "  --version                   Show version"
    echo ""
    echo "Examples:"
    echo "  # Watch a JSON API for any change, check every 60s"
    echo "  web-watcher -i 60 https://api.example.com/products"
    echo ""
    echo "  # Watch sneaker stock API with auth header, filter price field"
    echo "  web-watcher -i 10 -H 'Authorization: Bearer mytoken' \\"
    echo "    -f '.products[].price' https://api.sneakers.com/v1/stock"
    echo ""
    echo "  # Watch a website, notify if more than 5% content changes"
    echo "  web-watcher -m website -p 5 -i 120 https://www.nike.com/launches"
    echo ""
    echo "  # Watch with POST request and custom body"
    echo "  web-watcher -X POST -H 'Content-Type: application/json' \\"
    echo "    -d '{\"query\": \"jordan 1\"}' https://api.shop.com/search"
    echo ""
    echo "  # Watch and log changes, save snapshots"
    echo "  web-watcher -i 30 -l changes.log --snapshot-dir ./snapshots \\"
    echo "    https://api.example.com/data"
    echo ""
    echo "  # Watch specific part of a webpage"
    echo "  web-watcher -m website -s 'class=\"product-price\"' -i 60 \\"
    echo "    https://www.shop.com/product/123"
    echo ""
    echo "  # Single check with persistent baseline (for cron jobs)"
    echo "  web-watcher --once --baseline-file /tmp/ww_status.txt https://api.example.com/status"
}

# --- Dependency Check ---

check_dependencies() {
    local missing=()

    if ! command -v curl &>/dev/null; then
        missing+=("curl")
    fi

    if [ -n "$JQ_FILTER" ] && ! command -v jq &>/dev/null; then
        missing+=("jq (required for --filter)")
    fi

    if command -v diff &>/dev/null; then
        HAS_DIFF=true
    else
        HAS_DIFF=false
    fi

    if [ ${#missing[@]} -gt 0 ]; then
        log_error "Missing required dependencies: ${missing[*]}"
        echo ""
        echo "Install them with:"
        if [[ "$OSTYPE" == "darwin"* ]]; then
            echo "  brew install ${missing[*]}"
        elif command -v apt-get &>/dev/null; then
            echo "  sudo apt-get install ${missing[*]}"
        elif command -v dnf &>/dev/null; then
            echo "  sudo dnf install ${missing[*]}"
        elif command -v pacman &>/dev/null; then
            echo "  sudo pacman -S ${missing[*]}"
        fi
        exit 1
    fi
}

# --- Argument Parsing ---

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -X|--method)
                METHOD="${2:?'--method requires a value'}"
                shift 2
                ;;
            -H|--header)
                HEADERS+=("${2:?'--header requires a value'}")
                shift 2
                ;;
            -d|--data)
                BODY="${2:?'--data requires a value'}"
                shift 2
                ;;
            -C|--cookie)
                COOKIES="${2:?'--cookie requires a value'}"
                shift 2
                ;;
            -A|--user-agent)
                USER_AGENT="${2:?'--user-agent requires a value'}"
                shift 2
                ;;
            --auth)
                AUTH="${2:?'--auth requires a value'}"
                shift 2
                ;;
            --timeout)
                TIMEOUT="${2:?'--timeout requires a value'}"
                shift 2
                ;;
            --no-follow)
                FOLLOW_REDIRECTS=false
                shift
                ;;
            --insecure)
                INSECURE=true
                shift
                ;;
            -i|--interval)
                INTERVAL="${2:?'--interval requires a value'}"
                if ! [[ "$INTERVAL" =~ ^[0-9]+$ ]] || [ "$INTERVAL" -lt 1 ]; then
                    log_error "Interval must be a positive integer (seconds)"
                    exit 1
                fi
                shift 2
                ;;
            -p|--threshold)
                THRESHOLD="${2:?'--threshold requires a value'}"
                if ! [[ "$THRESHOLD" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
                    log_error "Threshold must be a number (percentage)"
                    exit 1
                fi
                shift 2
                ;;
            -n|--max-runs)
                MAX_RUNS="${2:?'--max-runs requires a value'}"
                shift 2
                ;;
            --once)
                ONCE=true
                shift
                ;;
            --baseline-file)
                BASELINE_FILE="${2:?'--baseline-file requires a value'}"
                shift 2
                ;;
            --retries)
                RETRIES="${2:?'--retries requires a value'}"
                shift 2
                ;;
            --retry-delay)
                RETRY_DELAY="${2:?'--retry-delay requires a value'}"
                shift 2
                ;;
            -m|--mode)
                MODE="${2:?'--mode requires a value'}"
                if [[ ! "$MODE" =~ ^(api|website|auto)$ ]]; then
                    log_error "Mode must be one of: api, website, auto"
                    exit 1
                fi
                shift 2
                ;;
            -f|--filter)
                JQ_FILTER="${2:?'--filter requires a value'}"
                shift 2
                ;;
            -s|--selector)
                SELECTOR="${2:?'--selector requires a value'}"
                shift 2
                ;;
            --strip-html)
                STRIP_HTML=true
                shift
                ;;
            -l|--log)
                LOG_FILE="${2:?'--log requires a value'}"
                shift 2
                ;;
            --snapshot-dir)
                SNAPSHOT_DIR="${2:?'--snapshot-dir requires a value'}"
                shift 2
                ;;
            --diff)
                SHOW_DIFF=true
                shift
                ;;
            --no-sound)
                SOUND=false
                shift
                ;;
            -q|--quiet)
                QUIET=true
                shift
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            --no-color)
                NO_COLOR=true
                shift
                ;;
            -h|--help)
                print_banner
                print_usage
                exit 0
                ;;
            --version)
                echo "web-watcher v$VERSION"
                exit 0
                ;;
            -*)
                log_error "Unknown option: $1"
                echo "Use --help for usage information."
                exit 1
                ;;
            *)
                if [ -z "$URL" ]; then
                    URL="$1"
                else
                    log_error "Unexpected argument: $1"
                    exit 1
                fi
                shift
                ;;
        esac
    done

    if [ -z "$URL" ]; then
        log_error "No URL provided."
        echo "Use --help for usage information."
        exit 1
    fi

    # Validate URL scheme
    if [[ ! "$URL" =~ ^https?:// ]]; then
        log_error "Invalid URL: '$URL' — must start with http:// or https://"
        exit 1
    fi
}

# --- Build curl command ---

# Response delimiter — unlikely to appear in real content
RESPONSE_DELIM="__WW_DELIM_7f3a9e__"

build_curl_cmd() {
    CURL_CMD=(curl -s -w "\n${RESPONSE_DELIM}HTTP_CODE:%{http_code}\n${RESPONSE_DELIM}CONTENT_TYPE:%{content_type}" --max-time "$TIMEOUT")

    # Method
    CURL_CMD+=(-X "$METHOD")

    # Headers
    if [ ${#HEADERS[@]} -gt 0 ]; then
        for h in "${HEADERS[@]}"; do
            CURL_CMD+=(-H "$h")
        done
    fi

    # User-Agent
    CURL_CMD+=(-A "$USER_AGENT")

    # Body
    if [ -n "$BODY" ]; then
        CURL_CMD+=(-d "$BODY")
    fi

    # Cookies
    if [ -n "$COOKIES" ]; then
        CURL_CMD+=(--cookie "$COOKIES")
    fi

    # Auth
    if [ -n "$AUTH" ]; then
        CURL_CMD+=(-u "$AUTH")
    fi

    # Follow redirects
    if [ "$FOLLOW_REDIRECTS" = true ]; then
        CURL_CMD+=(-L)
    fi

    # Insecure
    if [ "$INSECURE" = true ]; then
        CURL_CMD+=(-k)
    fi

    # -- separates options from URL (prevents URL starting with - being treated as flag)
    CURL_CMD+=(-- "$URL")
}

# --- Fetch URL ---

fetch_url() {
    local attempt=1

    build_curl_cmd

    while [ "$attempt" -le "$RETRIES" ]; do
        log_verbose "Attempt $attempt/$RETRIES — fetching $URL"

        local raw_output
        raw_output=$("${CURL_CMD[@]}" 2>/dev/null) || {
            log_warn "Request failed (attempt $attempt/$RETRIES)"
            if [ "$attempt" -lt "$RETRIES" ]; then
                log_verbose "Retrying in ${RETRY_DELAY}s..."
                sleep "$RETRY_DELAY"
            fi
            attempt=$((attempt + 1))
            continue
        }

        # Parse response using our custom delimiters
        local http_code content_type response

        http_code=$(echo "$raw_output" | grep "^${RESPONSE_DELIM}HTTP_CODE:" | sed "s/^${RESPONSE_DELIM}HTTP_CODE://")
        content_type=$(echo "$raw_output" | grep "^${RESPONSE_DELIM}CONTENT_TYPE:" | sed "s/^${RESPONSE_DELIM}CONTENT_TYPE://")
        response=$(echo "$raw_output" | grep -v "^${RESPONSE_DELIM}")

        # Check HTTP status
        if [[ "$http_code" =~ ^[45] ]]; then
            log_warn "HTTP $http_code received (attempt $attempt/$RETRIES)"
            if [ "$attempt" -lt "$RETRIES" ]; then
                sleep "$RETRY_DELAY"
            fi
            attempt=$((attempt + 1))
            continue
        fi

        log_verbose "HTTP $http_code — Content-Type: $content_type"

        # Return results via global variables
        LAST_RESPONSE="$response"
        LAST_HTTP_CODE="$http_code"
        LAST_CONTENT_TYPE="$content_type"
        return 0
    done

    log_error "All $RETRIES attempts failed for $URL"
    log_to_file "FETCH_FAILED — All $RETRIES attempts failed"
    return 1
}

# --- Content Processing ---

detect_mode() {
    local content_type="$1"

    if [ "$MODE" != "auto" ]; then
        echo "$MODE"
        return
    fi

    if echo "$content_type" | grep -qi 'application/json\|text/json\|application/.*+json'; then
        echo "api"
    elif echo "$content_type" | grep -qi 'text/html\|application/xhtml'; then
        echo "website"
    else
        echo "api"
    fi
}

strip_html_tags() {
    # Remove script/style blocks, then HTML tags, then normalize whitespace
    # Use character classes [Ss] for portability (BSD sed has no case-insensitive flag)
    sed -E 's/<[Ss][Cc][Rr][Ii][Pp][Tt][^>]*>[^<]*<\/[Ss][Cc][Rr][Ii][Pp][Tt]>//g' |
    sed -E 's/<[Ss][Tt][Yy][Ll][Ee][^>]*>[^<]*<\/[Ss][Tt][Yy][Ll][Ee]>//g' |
    sed -E 's/<[^>]+>//g' |
    sed 's/&nbsp;/ /g; s/&amp;/\&/g; s/&lt;/</g; s/&gt;/>/g; s/&quot;/"/g' |
    tr -s '[:space:]' '\n' |
    sed '/^$/d'
}

process_content() {
    local content="$1"
    local resolved_mode="$2"

    # Apply jq filter for JSON
    if [ -n "$JQ_FILTER" ]; then
        local filtered
        filtered=$(echo "$content" | jq -r "$JQ_FILTER" 2>/dev/null) || {
            log_warn "jq filter failed, using raw content"
            echo "$content"
            return
        }
        content="$filtered"
    fi

    # Apply grep selector
    if [ -n "$SELECTOR" ]; then
        local selected
        selected=$(echo "$content" | grep -i "$SELECTOR" 2>/dev/null) || {
            log_warn "Selector pattern not found, using full content"
            echo "$content"
            return
        }
        content="$selected"
    fi

    # Strip HTML if website mode or forced
    if [ "$resolved_mode" = "website" ] || [ "$STRIP_HTML" = true ]; then
        content=$(echo "$content" | strip_html_tags)
    fi

    echo "$content"
}

# --- Change Detection ---

calculate_change_percent() {
    local old="$1"
    local new="$2"

    local old_len=${#old}
    local new_len=${#new}

    if [ "$old_len" -eq 0 ] && [ "$new_len" -eq 0 ]; then
        echo "0"
        return
    fi

    if [ "$old_len" -eq 0 ]; then
        echo "100"
        return
    fi

    # Use diff to count changed lines
    local old_lines new_lines changed_lines
    old_lines=$(echo "$old" | wc -l | tr -d ' ')
    new_lines=$(echo "$new" | wc -l | tr -d ' ')

    if [ "$old_lines" -eq 0 ]; then
        old_lines=1
    fi

    # Count differing lines
    changed_lines=$(diff <(echo "$old") <(echo "$new") 2>/dev/null | grep -c '^[<>]' || true)

    # Percentage relative to total lines
    local total_lines
    if [ "$old_lines" -gt "$new_lines" ]; then
        total_lines="$old_lines"
    else
        total_lines="$new_lines"
    fi
    if [ "$total_lines" -eq 0 ]; then
        total_lines=1
    fi

    # Use awk for floating point
    awk "BEGIN { printf \"%.2f\", ($changed_lines / $total_lines) * 100 }"
}

show_diff() {
    local old="$1"
    local new="$2"

    if [ "$HAS_DIFF" = true ]; then
        echo -e "${DIM}--- previous${NC}"
        echo -e "${DIM}+++ current${NC}"
        diff <(echo "$old") <(echo "$new") 2>/dev/null | tail -n +3 || true
    else
        echo -e "${YELLOW}(diff not available — install diffutils)${NC}"
    fi
}

# --- Snapshot ---

save_snapshot() {
    local content="$1"
    local label="$2"

    if [ -z "$SNAPSHOT_DIR" ]; then
        return
    fi

    mkdir -p "$SNAPSHOT_DIR"

    local timestamp
    timestamp=$(date '+%Y%m%d_%H%M%S')
    local filename="${SNAPSHOT_DIR}/snapshot_${timestamp}_${label}.txt"

    echo "$content" > "$filename"
    log_verbose "Snapshot saved: $filename"
}

# --- Progress / Status ---

print_watch_config() {
    [ "$QUIET" = true ] && return

    echo -e "${BOLD}Configuration:${NC}"
    echo -e "  ${CYAN}URL:${NC}        $URL"
    echo -e "  ${CYAN}Method:${NC}     $METHOD"
    echo -e "  ${CYAN}Mode:${NC}       $MODE"
    echo -e "  ${CYAN}Interval:${NC}   ${INTERVAL}s"
    if [ "$THRESHOLD" != "0" ]; then
        echo -e "  ${CYAN}Threshold:${NC}  ${THRESHOLD}%"
    else
        echo -e "  ${CYAN}Threshold:${NC}  any change"
    fi
    if [ ${#HEADERS[@]} -gt 0 ]; then
        echo -e "  ${CYAN}Headers:${NC}    ${#HEADERS[@]} custom header(s)"
    fi
    if [ -n "$JQ_FILTER" ]; then
        echo -e "  ${CYAN}Filter:${NC}     $JQ_FILTER"
    fi
    if [ -n "$SELECTOR" ]; then
        echo -e "  ${CYAN}Selector:${NC}   $SELECTOR"
    fi
    if [ -n "$BODY" ]; then
        echo -e "  ${CYAN}Body:${NC}       (${#BODY} bytes)"
    fi
    if [ -n "$LOG_FILE" ]; then
        echo -e "  ${CYAN}Log:${NC}        $LOG_FILE"
    fi
    if [ -n "$SNAPSHOT_DIR" ]; then
        echo -e "  ${CYAN}Snapshots:${NC}  $SNAPSHOT_DIR"
    fi
    if [ -n "$BASELINE_FILE" ]; then
        echo -e "  ${CYAN}Baseline:${NC}   $BASELINE_FILE"
    fi
    if [ "$MAX_RUNS" -gt 0 ]; then
        echo -e "  ${CYAN}Max runs:${NC}   $MAX_RUNS"
    fi
    echo ""
}

print_countdown() {
    local remaining="$1"
    if [ "$QUIET" = true ]; then
        sleep "$remaining"
        return
    fi
    while [ "$remaining" -gt 0 ]; do
        printf "\r${DIM}  ⏳ Next check in %ds...  ${NC}" "$remaining"
        sleep 1
        remaining=$((remaining - 1))
    done
    printf "\r                                        \r"
}

# --- Cleanup ---

cleanup() {
    echo ""
    log_info "Stopped watching. Goodbye!"
    exit 0
}

# --- Main Watch Loop ---

main() {
    setup_colors
    parse_args "$@"

    # Re-setup colors in case --no-color was set
    setup_colors

    print_banner
    check_dependencies
    print_watch_config

    # Setup cleanup trap
    trap cleanup SIGINT SIGTERM

    local previous_content=""
    local run_count=0
    local change_count=0
    local first_run=true
    local resolved_mode=""
    local start_time
    start_time=$(date +%s)

    log_info "Starting watch on $URL"
    log_info "Press Ctrl+C to stop"
    echo ""
    log_to_file "START — Watching $URL (interval=${INTERVAL}s, threshold=${THRESHOLD}%)"

    while true; do
        run_count=$((run_count + 1))

        # Fetch
        if ! fetch_url; then
            if [ "$ONCE" = true ]; then
                exit 1
            fi
            print_countdown "$INTERVAL"
            continue
        fi

        # Detect mode on first successful response
        if [ -z "$resolved_mode" ]; then
            resolved_mode=$(detect_mode "$LAST_CONTENT_TYPE")
            log_verbose "Resolved mode: $resolved_mode"
        fi

        # Process content
        local current_content
        current_content=$(process_content "$LAST_RESPONSE" "$resolved_mode")

        if [ "$first_run" = true ]; then
            first_run=false

            # In --once mode, try to load previous baseline from file
            if [ "$ONCE" = true ] && [ -n "$BASELINE_FILE" ] && [ -f "$BASELINE_FILE" ]; then
                previous_content=$(cat "$BASELINE_FILE")
                log_verbose "Loaded baseline from $BASELINE_FILE (${#previous_content} bytes)"
                # Don't skip comparison — fall through to compare
            else
                previous_content="$current_content"
                save_snapshot "$current_content" "initial"
                log_success "Baseline captured (HTTP $LAST_HTTP_CODE, ${#current_content} bytes, mode: $resolved_mode)"
                log_to_file "BASELINE — HTTP $LAST_HTTP_CODE, ${#current_content} bytes"

                # Save baseline to file for future --once runs
                if [ -n "$BASELINE_FILE" ]; then
                    echo "$current_content" > "$BASELINE_FILE"
                    log_verbose "Baseline saved to $BASELINE_FILE"
                fi

                if [ "$ONCE" = true ]; then
                    log_info "Baseline saved. Next --once run will compare against it."
                    exit 0
                fi

                print_countdown "$INTERVAL"
                continue
            fi
        fi

        # Compare
        if [ "$current_content" = "$previous_content" ]; then
            local ts
            ts=$(date '+%H:%M:%S')
            local elapsed=$(( $(date +%s) - start_time ))
            local elapsed_fmt
            elapsed_fmt=$(printf '%02d:%02d:%02d' $((elapsed/3600)) $((elapsed%3600/60)) $((elapsed%60)))
            [ "$QUIET" = false ] && printf "\r  ${DIM}[%s] Check #%d — No change (uptime: %s)${NC}\n" "$ts" "$run_count" "$elapsed_fmt"
            log_verbose "No change (${#current_content} bytes)"
        else
            # Calculate change percentage
            local change_pct
            change_pct=$(calculate_change_percent "$previous_content" "$current_content")

            log_verbose "Change detected: ${change_pct}% (threshold: ${THRESHOLD}%)"

            # Check threshold
            local exceeds_threshold
            exceeds_threshold=$(awk "BEGIN { print ($change_pct >= $THRESHOLD) ? 1 : 0 }")

            if [ "$exceeds_threshold" -eq 1 ]; then
                change_count=$((change_count + 1))

                send_notification "Web Watcher — Change Detected" \
                    "Change of ${change_pct}% detected on ${URL}"

                log_to_file "CHANGE #${change_count} — ${change_pct}% change (HTTP $LAST_HTTP_CODE)"

                # Show diff
                if [ "$SHOW_DIFF" = true ]; then
                    show_diff "$previous_content" "$current_content"
                fi

                # Save snapshot
                save_snapshot "$current_content" "change_${change_count}"

                # Update baseline to current
                previous_content="$current_content"
            else
                local ts
                ts=$(date '+%H:%M:%S')
                [ "$QUIET" = false ] && printf "  ${DIM}[%s] Check #%d — Minor change (%.2f%% < %s%% threshold)${NC}\n" \
                    "$ts" "$run_count" "$change_pct" "$THRESHOLD"
            fi
        fi

        # Check max runs
        if [ "$MAX_RUNS" -gt 0 ] && [ "$run_count" -ge "$MAX_RUNS" ]; then
            echo ""
            log_info "Reached max runs ($MAX_RUNS). Stopping."
            log_info "Total changes detected: $change_count"
            log_to_file "STOP — Reached $MAX_RUNS runs, $change_count changes detected"
            exit 0
        fi

        # Single run mode
        if [ "$ONCE" = true ]; then
            # Update baseline file with latest content
            if [ -n "$BASELINE_FILE" ]; then
                echo "$current_content" > "$BASELINE_FILE"
            fi
            if [ "$change_count" -gt 0 ]; then
                exit 2  # Exit code 2 = change detected
            fi
            exit 0
        fi

        # Countdown
        print_countdown "$INTERVAL"
    done
}

# --- Entry Point ---
main "$@"
