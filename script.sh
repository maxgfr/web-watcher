#!/bin/bash

# ==============================================================================
#  web-watcher
#  Watch APIs & Websites for changes — Get notified instantly from your terminal
# ==============================================================================

set -euo pipefail

# --- Configuration & Defaults ---
VERSION="1.2.1"
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
IGNORE_PATTERNS=()
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
FULL_PAGE=false
HAS_DIFF=false
BASELINE_FILE=""
SLACK_WEBHOOK=""
DISCORD_WEBHOOK=""
TELEGRAM_TOKEN=""
TELEGRAM_CHAT_ID=""

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
        printf "${DIM}[DEBUG] %s${NC}\n" "$1" >&2
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
        osascript -e "display notification \"$(applescript_escape "$message")\" with title \"$(applescript_escape "$title")\" sound name \"Glass\"" 2>/dev/null || true
    elif command -v notify-send &>/dev/null; then
        notify-send "$title" "$message" 2>/dev/null || true
    fi

    # Webhook notifications
    [ -n "$SLACK_WEBHOOK" ] && send_slack "$title" "$message"
    [ -n "$DISCORD_WEBHOOK" ] && send_discord "$title" "$message"
    [ -n "$TELEGRAM_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ] && send_telegram "$title" "$message"

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

# --- Webhook Notifications ---

# Escape a string for use inside a double-quoted AppleScript literal.
applescript_escape() {
    local s="$1"
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    printf '%s' "$s"
}

# Print $1 as a JSON string literal (quotes included).
json_escape() {
    local LC_ALL=C s="$1" i ch hex
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}
    s=${s//$'\r'/\\r}
    s=${s//$'\t'/\\t}
    # Escape the remaining C0 bytes; Bash strings cannot contain NUL.
    for ((i = 1; i <= 31; i++)); do
        case "$i" in 9|10|13) continue ;; esac
        printf -v ch '%03o' "$i"
        printf -v ch '%b' "\\$ch"
        printf -v hex '%02x' "$i"
        s=${s//"$ch"/\\u00$hex}
    done
    printf '"%s"' "$s"
}

# POST a JSON document to a webhook. -f makes HTTP 4xx/5xx a failure so the
# caller can report it instead of silently losing the notification.
post_json() {
    local url="$1" payload="$2"
    curl -fs -X POST -H 'Content-Type: application/json' --max-time "$TIMEOUT" \
        -d "$payload" -- "$url" >/dev/null 2>&1
}

send_slack() {
    local title="$1" message="$2" text
    text=$(json_escape "*${title}*"$'\n'"${message}"$'\n'"${URL}")
    post_json "$SLACK_WEBHOOK" "{\"text\":${text}}" || log_warn "Slack notification failed"
}

send_discord() {
    local title="$1" message="$2" text
    text=$(json_escape "**${title}**"$'\n'"${message}"$'\n'"${URL}")
    post_json "$DISCORD_WEBHOOK" "{\"content\":${text}}" || log_warn "Discord notification failed"
}

send_telegram() {
    local title="$1" message="$2"
    local api="${WW_TELEGRAM_API:-https://api.telegram.org}"
    # Fields are url-encoded (a "&" in the URL would otherwise start a new
    # parameter) and sent as plain text: no parse_mode, so "_" and "*" in URLs
    # need no escaping.
    curl -fs -X POST --max-time "$TIMEOUT" \
        --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
        --data-urlencode "text=${title}"$'\n'"${message}"$'\n'"${URL}" \
        -- "${api}/bot${TELEGRAM_TOKEN}/sendMessage" >/dev/null 2>&1 || log_warn "Telegram notification failed"
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
    echo "  --full-page                 Keep navigation, header, footer, aside and cookie-banner text (website mode)"
    echo "  --ignore <regex>            Drop lines matching this pattern before comparing (repeatable)"
    echo ""
    echo "Notification Options:"
    echo "  --slack <url>               Slack incoming webhook URL"
    echo "  --discord <url>             Discord webhook URL"
    echo "  --telegram-token <token>    Telegram bot token"
    echo "  --telegram-chat <chat_id>   Telegram chat ID"
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
    echo ""
    echo "  # Watch Hacker News, ignoring the lines that always move"
    echo "  web-watcher --once -m website --ignore 'ago|points' --baseline-file /tmp/hn.txt https://news.ycombinator.com/"
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

# require_int <option> <value> <min> — require an integer >= min, at most 9 digits
require_int() {
    local option="$1" value="$2" min="$3"
    if ! [[ "$value" =~ ^[0-9]{1,9}$ ]] || [ "$value" -lt "$min" ]; then
        log_error "$option must be an integer >= $min (at most 9 digits) (got '$value')"
        exit 1
    fi
}

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
                require_int "--timeout" "$TIMEOUT" 1
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
                require_int "--interval" "$INTERVAL" 1
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
                require_int "--max-runs" "$MAX_RUNS" 0
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
                require_int "--retries" "$RETRIES" 1
                shift 2
                ;;
            --retry-delay)
                RETRY_DELAY="${2:?'--retry-delay requires a value'}"
                require_int "--retry-delay" "$RETRY_DELAY" 0
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
            --full-page)
                FULL_PAGE=true
                shift
                ;;
            --ignore)
                local pattern="${2:?'--ignore requires a value'}" rc=0
                printf '' | LC_ALL=C grep -aE -e "$pattern" >/dev/null 2>&1 || rc=$?
                if [ "$rc" -gt 1 ]; then
                    log_error "--ignore: invalid regular expression '$pattern'"
                    exit 1
                fi
                IGNORE_PATTERNS+=("$pattern")
                shift 2
                ;;
            --slack)
                SLACK_WEBHOOK="${2:?'--slack requires a value'}"
                shift 2
                ;;
            --discord)
                DISCORD_WEBHOOK="${2:?'--discord requires a value'}"
                shift 2
                ;;
            --telegram-token)
                TELEGRAM_TOKEN="${2:?'--telegram-token requires a value'}"
                shift 2
                ;;
            --telegram-chat)
                TELEGRAM_CHAT_ID="${2:?'--telegram-chat requires a value'}"
                shift 2
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

        # grep -a: a body with bytes that are not valid in the current locale
        # would otherwise be reported as "Binary file" instead of passed through.
        http_code=$(printf '%s\n' "$raw_output" | grep -a "^${RESPONSE_DELIM}HTTP_CODE:" | sed "s/^${RESPONSE_DELIM}HTTP_CODE://")
        content_type=$(printf '%s\n' "$raw_output" | grep -a "^${RESPONSE_DELIM}CONTENT_TYPE:" | sed "s/^${RESPONSE_DELIM}CONTENT_TYPE://")
        response=$(printf '%s\n' "$raw_output" | grep -av "^${RESPONSE_DELIM}")

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

# Decode the HTML entities that commonly appear in page text (byte-oriented,
# so it is safe on any input encoding). Used by the sed/awk fallback only.
decode_html_entities() {
    sed 's/&nbsp;/ /g; s/&lt;/</g; s/&gt;/>/g; s/&quot;/"/g; s/&#39;/'"'"'/g; s/&#x27;/'"'"'/g; s/&apos;/'"'"'/g;
         s/&euro;/€/g; s/&copy;/©/g; s/&reg;/®/g; s/&amp;/\&/g'
}

# Perl stripper: remove comments and raw blocks in opening order,
# then tags. Decode named and numeric entities once to UTF-8 bytes, preserving
# invalid code points and leaving the original page bytes untouched.
strip_html_tags_perl() {
    perl -0777 -MEncode -pe '
        my $raw = "script|style|noscript|svg|template|title";
        $raw .= "|nav|header|footer|aside" unless ($ENV{WW_FULL_PAGE} // "false") eq "true";
        # Raw blocks end at their first closing tag; nested nav blocks are
        # deliberately cut at the first </nav>, without balancing nesting.
        s/<!--.*?-->|<head\b[^>]*>.*?(?:<\/head\s*>|(?=<body\b))|<($raw)\b[^>]*>.*?<\/\1\s*>/ /gis;
        s/<!--.*\z/ /gs;
        s/[\r\n]+/ /g;
        # Tags, quote-aware: a ">" inside a quoted attribute value does not
        # end the tag, so the rest of the attribute cannot leak into the text.
        s/<[a-zA-Z!\/?][^>"'"'"']*(?:(?:"[^"]*"|'"'"'[^'"'"']*'"'"')[^>"'"'"']*)*>/
            $& =~ m{^<\/?(?:p|div|section|article|main|li|tr|td|th|ul|ol|dl|dt|dd|h[1-6]|pre|blockquote|table|br|hr|form|figure|option)(?=[\s\/>])}i
                ? "\n" : " ";
        /ge;
        # Anything left that still looks like a tag (unbalanced quotes).
        s/<[a-zA-Z!\/?][^>]*>/ /gs;
        my %named = (
            nbsp => 32, lt => 60, gt => 62, quot => 34, apos => 39,
            amp => 38, euro => 0x20AC, copy => 0xA9, reg => 0xAE
        );
        s/&(?:#(\d+)|#[xX]([0-9a-fA-F]+)|(nbsp|lt|gt|quot|apos|amp|euro|copy|reg));/
            my $n = defined($1) ? 0 + $1 : defined($2) ? hex($2) : $named{$3};
            $n == 0 || $n >= 0x110000 || ($n >= 0xD800 && $n <= 0xDFFF)
                ? $& : Encode::encode_utf8(chr($n));
        /ge;
    '
}

# Streaming, byte-oriented awk fallback: skip comments/raw blocks in opening
# order, scan quoted tags, and separate blocks. Use the limited sed entity
# decoder; the caller normalizes each output line. Search windows stay bounded
# so even a minified document does not repeatedly copy/lowercase its suffix.
strip_html_tags_sed() {
    awk -v full="$( [ "${WW_FULL_PAGE:-false}" = true ] && echo 1 || echo 0 )" '
        BEGIN { state = "TEXT" }
        {
            size = length($0)
            offset = 1
            while (offset <= size) {
                window = substr($0, offset, 4096)
                limit = length(window)
                # Keep lookahead for TEXT classification and skipped delimiters.
                if (offset + limit <= size) limit -= 16
                pos = 1
                while (pos <= limit) {
                    rest = substr(window, pos)
                    width = length(rest)
                    if (state == "TEXT") {
                        at = index(rest, "<")
                        if (!at) {
                            printf "%s", rest
                            pos += width
                            continue
                        }
                        if (pos + at - 1 > limit) {
                            printf "%s", substr(rest, 1, limit - pos + 1)
                            pos = limit + 1
                            continue
                        }
                        printf "%s", substr(rest, 1, at - 1)
                        pos += at - 1
                        # Look ahead in the record, including across a window edge.
                        if (substr(window, pos, 4) == "<!--") {
                            state = "COMMENT"
                            pos += 4
                            printf " "
                        } else if (substr(window, pos + 1, 1) ~ /^[a-zA-Z\/!?]$/) {
                            state = "TAG"
                            closing = (substr(window, pos + 1, 1) == "/")
                            pos += 1 + closing
                            name = quote = ""
                            naming = 1
                            selfclosing = 0
                        } else {
                            printf "<"
                            pos++
                        }
                    } else if (state == "TAG") {
                        for (i = 1; i <= width; i++) {
                            c = substr(rest, i, 1)
                            if (quote == "" && c != ">" && c !~ /^[[:space:]]$/) {
                                selfclosing = (c == "/")
                            }
                            if (quote != "") {
                                if (c == quote) quote = ""
                            } else if (c == "\"" || c == "'"'"'") {
                                quote = c
                                naming = 0
                            } else if (c == ">") {
                                state = "TEXT"
                                if (!closing && !selfclosing && (name ~ /^(script|style|noscript|svg|template|head|title)$/ ||
                                    (full != 1 && name ~ /^(nav|header|footer|aside)$/))) {
                                    state = "RAW"
                                    raw_close = "</" name
                                    raw_end = 0
                                    printf " "
                                } else if (name ~ /^(p|div|section|article|main|li|tr|td|th|ul|ol|dl|dt|dd|h[1-6]|pre|blockquote|table|br|hr|form|figure|option)$/) {
                                    printf "\n"
                                } else {
                                    printf " "
                                }
                                i++
                                break
                            } else if (c ~ /^[[:space:]\/]$/) {
                                naming = 0
                            } else if (naming && length(name) <= 10) {
                                # No recognized name exceeds ten bytes. Cap unknown
                                # names too, avoiding growing-string concatenation.
                                name = name tolower(c)
                            }
                        }
                        pos += i - 1
                    } else {
                        # COMMENT and RAW skip chunks with index(), never per byte.
                        needle = (state == "COMMENT" ? "-->" : (raw_end ? ">" : raw_close))
                        search = (state == "RAW" && !raw_end ? tolower(rest) : rest)
                        at = index(search, needle)
                        if (state == "RAW" && !raw_end && raw_close == "</head") {
                            body_at = match(search, /<body([[:space:]\/>]|$)/)
                            # A window edge is not a tag-name boundary; a record end is.
                            if (body_at && body_at + 4 == width && offset + pos + width - 1 <= size) body_at = 0
                            if (body_at && (!at || body_at < at)) {
                                pos += body_at - 1
                                state = "TEXT"
                                printf " "
                                continue
                            }
                        }
                        if (at) {
                            pos += at - 1 + length(needle)
                            if (state == "RAW" && !raw_end) {
                                raw_end = 1
                            } else {
                                state = "TEXT"
                                printf " "
                            }
                        } else if (offset + pos + width - 1 <= size) {
                            # Retain enough overlap for a delimiter crossing windows.
                            pos += width - length(needle) + 1
                        } else {
                            pos += width
                        }
                    }
                }
                offset += pos - 1
            }
            if (state == "TEXT") printf " "
            # A record separator is whitespace, including inside an open tag.
            if (state == "TAG") naming = 0
        }
        END { printf "\n" }
    ' |
    decode_html_entities
}

drop_consent_lines() {
    awk '
        {
            line = tolower($0)
            hits = (line ~ /(^|[^a-z])cookies?([^a-z]|$)/)
            hits += (line ~ /consent/)
            hits += (line ~ /gdpr/)
            hits += (line ~ /ccpa/)
            hits += (line ~ /accept all/)
            hits += (line ~ /reject all/)
            hits += (line ~ /manage (preferences|choices|cookies|settings)/)
            hits += (line ~ /privacy (policy|preferences|choices)/)
            hits += (line ~ /tracking technolog/)
            hits += (line ~ /advertising partners/)
            hits += (line ~ /legitimate interest/)
            action = (line ~ /accept|reject|decline|agree|allow|manage|preferences|settings|choices|opt[ -]out|we use cookies|this (site|website) uses cookies|by continuing|learn more|privacy policy|cookie policy/)
            if (hits >= 2 || (hits == 1 && length($0) < 120 && action)) next
            print
        }
    '
}

resolve_html_stripper() {
    if [ -n "${WW_HTML_STRIPPER:-}" ]; then
        printf '%s\n' "$WW_HTML_STRIPPER"
    elif command -v webindex >/dev/null 2>&1; then
        echo webindex
    elif command -v perl >/dev/null 2>&1; then
        echo perl
    else
        echo sed
    fi
}

strip_html_tags_webindex() {
    local tmp output rc=0 fallback=perl
    tmp=$(mktemp "${TMPDIR:-/tmp}/ww.XXXXXX") || return $?
    mv "$tmp" "$tmp.html" || { rc=$?; rm -f "$tmp"; return "$rc"; }
    tmp="$tmp.html"
    cat > "$tmp" || { rc=$?; rm -f "$tmp"; return "$rc"; }
    if [ "$FULL_PAGE" = true ]; then
        output=$(webindex extract "$tmp" --full-page) || rc=$?
    else
        output=$(webindex extract "$tmp") || rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
        if ! command -v perl >/dev/null 2>&1; then fallback="sed"; fi
        log_warn "webindex extract failed (exit $rc), falling back to $fallback"
        rc=0
        if [ "$fallback" = perl ]; then
            output=$(strip_html_tags_perl < "$tmp") || rc=$?
        else
            output=$(strip_html_tags_sed < "$tmp") || rc=$?
        fi
        # The outer filter is skipped for webindex, so apply the legacy
        # consent policy here only when a legacy backend actually ran.
        if [ "$FULL_PAGE" = false ]; then
            output=$(printf '%s\n' "$output" |
                sed -e 's/[[:space:]][[:space:]]*/ /g' \
                    -e 's/^ //' -e 's/ $//' -e '/^$/d' |
                drop_consent_lines) || rc=$?
        fi
    fi
    if [ "$rc" -eq 0 ]; then
        printf '%s\n' "$output" || rc=$?
    fi
    rm -f "$tmp"
    return "$rc"
}

strip_html_tags() {
    # Remove comments, raw blocks and tags, decode entities, then
    # normalize whitespace within each line. WW_HTML_STRIPPER=webindex|perl|sed
    # forces an implementation; auto prefers webindex, then perl, then sed.
    local stripper
    stripper=$(resolve_html_stripper)
    log_verbose "HTML stripper: $stripper"

    # Under LC_ALL=C every tool works on bytes, never rejecting or
    # reinterpreting multibyte sequences. webindex handles input decoding;
    # the other backends preserve input bytes and emit UTF-8 for entities.
    (
        export LC_ALL=C
        export WW_FULL_PAGE="$FULL_PAGE"
        if [ "$stripper" = webindex ]; then
            strip_html_tags_webindex
        elif [ "$stripper" = perl ]; then
            strip_html_tags_perl
        else
            strip_html_tags_sed
        fi |
        sed -e 's/[[:space:]][[:space:]]*/ /g' \
            -e 's/^ //' -e 's/ $//' -e '/^$/d' |
        if [ "$FULL_PAGE" = true ] || [ "$stripper" = webindex ]; then
            cat
        else
            drop_consent_lines
        fi
    )
}

apply_ignore_patterns() {
    if [ ${#IGNORE_PATTERNS[@]} -gt 0 ]; then
        local args=() pattern rc=0
        for pattern in "${IGNORE_PATTERNS[@]}"; do
            args+=(-e "$pattern")
        done
        LC_ALL=C grep -avE "${args[@]}" || rc=$?
        if [ "$rc" -gt 1 ]; then
            log_error "ignore filter failed (grep exit $rc)"
            return 1
        fi
    else
        cat
    fi
}

process_content() {
    local content="$1"
    local resolved_mode="$2"
    local fallback=false

    # Apply jq filter for JSON
    # printf rather than echo throughout: a response consisting of "-n" or
    # "-e" would otherwise be swallowed as an echo option.
    if [ -n "$JQ_FILTER" ]; then
        local filtered
        if filtered=$(printf '%s\n' "$content" | jq -r "$JQ_FILTER" 2>/dev/null); then
            content="$filtered"
        else
            log_warn "jq filter failed, using raw content"
            fallback=true
        fi
    fi

    # Apply grep selector
    if [ "$fallback" = false ] && [ -n "$SELECTOR" ]; then
        local selected
        if selected=$(printf '%s\n' "$content" | grep -ai "$SELECTOR" 2>/dev/null); then
            content="$selected"
        else
            log_warn "Selector pattern not found, using full content"
            fallback=true
        fi
    fi

    # Strip HTML if website mode or forced
    if [ "$fallback" = false ] && { [ "$resolved_mode" = "website" ] || [ "$STRIP_HTML" = true ]; }; then
        content=$(printf '%s\n' "$content" | strip_html_tags)
    fi

    printf '%s\n' "$content" | apply_ignore_patterns
}

# --- Change Detection ---

diff_lines() {
    diff -a <(printf '%s\n' "$1") <(printf '%s\n' "$2") 2>/dev/null || true
}

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
    old_lines=$(printf '%s\n' "$old" | wc -l | tr -d ' ')
    new_lines=$(printf '%s\n' "$new" | wc -l | tr -d ' ')

    if [ "$old_lines" -eq 0 ]; then
        old_lines=1
    fi

    # Count differing lines (each side separately to avoid double-counting)
    local diff_output removed_count added_count
    diff_output=$(diff_lines "$old" "$new")
    removed_count=$(printf '%s\n' "$diff_output" | grep -ac '^<' || true)
    added_count=$(printf '%s\n' "$diff_output" | grep -ac '^>' || true)
    if [ "$removed_count" -gt "$added_count" ]; then
        changed_lines="$removed_count"
    else
        changed_lines="$added_count"
    fi

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

    # Use awk for floating point. LC_ALL=C forces a decimal point: under a
    # locale with a decimal comma (fr_FR, de_DE, ...) awk would print "9,09",
    # which then breaks every numeric comparison made on the result.
    LC_ALL=C awk -v c="$changed_lines" -v t="$total_lines" 'BEGIN { printf "%.2f", (c / t) * 100 }'
}

# 0 (true) if change percentage $1 reaches threshold $2.
# Anything that is not a number is treated as a change: never swallow one.
exceeds_threshold() {
    local pct="$1" threshold="$2"
    if ! [[ "$pct" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        log_warn "Unexpected change percentage '$pct', treating as a change"
        return 0
    fi
    [ "$(LC_ALL=C awk -v p="$pct" -v t="$threshold" 'BEGIN { print (p >= t) ? 1 : 0 }')" = "1" ]
}

show_diff() {
    local old="$1"
    local new="$2"

    if [ "$HAS_DIFF" = true ]; then
        echo -e "${DIM}--- previous${NC}"
        echo -e "${DIM}+++ current${NC}"
        # Only unified diffs have two file headers to replace with our labels.
        # Keep diff_lines in normal format for the change-percentage counters.
        diff -au <(printf '%s\n' "$old") <(printf '%s\n' "$new") 2>/dev/null | tail -n +3 || true
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

    printf '%s\n' "$content" > "$filename"
    log_verbose "Snapshot saved: $filename"
}

# --- Progress / Status ---

print_watch_config() {
    [ "$QUIET" = true ] && return

    echo -e "${BOLD}Configuration:${NC}"
    echo -e "  ${CYAN}URL:${NC}        $URL"
    echo -e "  ${CYAN}Method:${NC}     $METHOD"
    echo -e "  ${CYAN}Mode:${NC}       $MODE"
    if [ "$MODE" = website ] || [ "$MODE" = auto ]; then
        echo -e "  ${CYAN}Stripper:${NC}   $(resolve_html_stripper)"
        if [ "$FULL_PAGE" = true ]; then
            echo -e "  ${CYAN}Page:${NC}       full page"
        else
            echo -e "  ${CYAN}Page:${NC}       main content (use --full-page to keep chrome)"
        fi
    fi
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
    if [ ${#IGNORE_PATTERNS[@]} -gt 0 ]; then
        echo -e "  ${CYAN}Ignore:${NC}     ${#IGNORE_PATTERNS[@]} pattern(s)"
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
    # Notification channels
    local channels=()
    [ -n "$SLACK_WEBHOOK" ] && channels+=("Slack")
    [ -n "$DISCORD_WEBHOOK" ] && channels+=("Discord")
    [ -n "$TELEGRAM_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ] && channels+=("Telegram")
    if [ ${#channels[@]} -gt 0 ]; then
        local joined="" c
        for c in "${channels[@]}"; do
            joined="${joined:+$joined, }$c"
        done
        echo -e "  ${CYAN}Notify:${NC}     $joined"
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

# persist_baseline <content> — write the current baseline to --baseline-file
persist_baseline() {
    if [ -n "$BASELINE_FILE" ]; then
        printf '%s\n' "$1" > "$BASELINE_FILE"
        log_verbose "Baseline saved to $BASELINE_FILE"
    fi
}

# check_max_runs <run_count> <change_count> <success_count> — stop at --max-runs;
# exit 1 if every fetch failed, otherwise exit 0
check_max_runs() {
    local run_count="$1" change_count="$2" success_count="$3"
    if [ "$MAX_RUNS" -gt 0 ] && [ "$run_count" -ge "$MAX_RUNS" ]; then
        echo ""
        log_info "Reached max runs ($MAX_RUNS). Stopping."
        log_info "Total changes detected: $change_count"
        log_to_file "STOP — Reached $MAX_RUNS runs, $change_count changes detected"
        if [ "$success_count" -eq 0 ]; then
            log_error "No successful fetch in $run_count runs"
            log_to_file "No successful fetch in $run_count runs"
            exit 1
        fi
        exit 0
    fi
}

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
    local success_count=0
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
            check_max_runs "$run_count" "$change_count" "$success_count"
            print_countdown "$INTERVAL"
            continue
        fi
        success_count=$((success_count + 1))

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
                persist_baseline "$current_content"

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
            if exceeds_threshold "$change_pct" "$THRESHOLD"; then
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
                persist_baseline "$current_content"
            else
                local ts
                ts=$(date '+%H:%M:%S')
                [ "$QUIET" = false ] && printf "  ${DIM}[%s] Check #%d — Minor change (%s%% < %s%% threshold)${NC}\n" \
                    "$ts" "$run_count" "$change_pct" "$THRESHOLD"
            fi
        fi

        # Single run mode
        if [ "$ONCE" = true ]; then
            # Keep the baseline on minor changes so drift accumulates across runs.
            if [ "$change_count" -gt 0 ]; then
                exit 2  # Exit code 2 = change detected
            fi
            exit 0
        fi

        check_max_runs "$run_count" "$change_count" "$success_count"

        # Countdown
        print_countdown "$INTERVAL"
    done
}

# --- Entry Point ---
main "$@"
