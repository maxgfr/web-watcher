# web-watcher

> A lightweight bash script to watch APIs and websites for changes — get instant notifications from your terminal.

![License](https://img.shields.io/badge/license-MIT-green)
![Shell](https://img.shields.io/badge/shell-bash-blue)
![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux-lightgrey)
![CI](https://github.com/maxgfr/web-watcher/actions/workflows/ci.yml/badge.svg)

`web-watcher` polls any URL at a configurable interval, compares responses, and sends you a desktop notification + terminal alert when something changes. Built for monitoring sneaker drops, stock APIs, price changes, website updates — anything with a URL.

## Features

- **API & Website monitoring** — watch JSON APIs or full web pages
- **Auto-detection** — automatically detects JSON vs HTML from `Content-Type`
- **Change threshold** — set a minimum % of change to trigger alerts (ignore noise)
- **Desktop notifications** — native macOS (`osascript`) and Linux (`notify-send`) support
- **jq filtering** — target specific JSON fields (e.g. `.products[].price`)
- **HTML selector** — grep patterns to monitor specific parts of a page
- **Custom headers & auth** — Bearer tokens, cookies, Basic auth, custom User-Agent
- **POST support** — watch API search endpoints with custom request bodies
- **Retry logic** — configurable retries with backoff on failure
- **Snapshots** — save every response to disk for later analysis
- **Diff output** — see exactly what changed between checks
- **Logging** — timestamped log file of all changes
- **Cron-friendly** — `--once` mode for single checks with exit codes

## Installation

### Homebrew

If you use Homebrew, you can install `web-watcher` via the tap:

```bash
brew tap maxgfr/tap
brew install maxgfr/tap/web-watcher
web-watcher --help
```

### Manual

```bash
git clone https://github.com/maxgfr/web-watcher.git
cd web-watcher
chmod +x script.sh
```

Optionally, add it to your PATH:

```bash
sudo ln -s "$(pwd)/script.sh" /usr/local/bin/web-watcher
```

### Dependencies

Only `curl` is required. `jq` is needed if you use the `--filter` option.

**macOS:**
```bash
brew install curl jq
```

**Ubuntu/Debian:**
```bash
sudo apt-get install curl jq
```

**Arch:**
```bash
sudo pacman -S curl jq
```

## Quick Start

```bash
# Watch a JSON API every 30 seconds
./script.sh https://api.example.com/products

# Watch a sneaker stock page, check every 10 seconds
./script.sh -i 10 -m website https://www.nike.com/launches

# Watch a JSON API with auth, filter on price
./script.sh -i 15 \
  -H 'Authorization: Bearer mytoken' \
  -f '.products[].price' \
  https://api.sneakers.com/v1/stock
```

## Usage

```bash
web-watcher [options] <url>
```

### Request Options

| Option | Description | Default |
|---|---|---|
| `-X, --method <METHOD>` | HTTP method (GET, POST, PUT...) | `GET` |
| `-H, --header <header>` | Custom header (repeatable) | — |
| `-d, --data <body>` | Request body for POST/PUT | — |
| `-C, --cookie <cookie>` | Cookie string or file path | — |
| `-A, --user-agent <ua>` | Custom User-Agent | `web-watcher/1.0.0` |
| `--auth <user:pass>` | Basic auth credentials | — |
| `--timeout <secs>` | Request timeout | `15` |
| `--no-follow` | Don't follow redirects | follows |
| `--insecure` | Allow insecure SSL | disabled |

### Watch Options

| Option | Description | Default |
|---|---|---|
| `-i, --interval <secs>` | Seconds between checks | `30` |
| `-p, --threshold <percent>` | Min change % to trigger alert | `0` (any) |
| `-n, --max-runs <num>` | Stop after N checks (0 = unlimited) | `0` |
| `--once` | Run single check then exit | disabled |
| `--baseline-file <file>` | Persist baseline to disk (for `--once`) | — |
| `--retries <num>` | Retries on failure | `3` |
| `--retry-delay <secs>` | Delay between retries | `5` |

### Content Options

| Option | Description | Default |
|---|---|---|
| `-m, --mode <mode>` | `api`, `website`, or `auto` | `auto` |
| `-f, --filter <jq>` | jq filter for JSON (e.g. `.data.price`) | — |
| `-s, --selector <pattern>` | Grep pattern for HTML content | — |
| `--strip-html` | Force strip HTML tags | disabled |

### Output Options

| Option | Description | Default |
|---|---|---|
| `-l, --log <file>` | Log changes to file | — |
| `--snapshot-dir <dir>` | Save response snapshots | — |
| `--diff` | Show unified diff on change | disabled |
| `--no-sound` | Disable terminal bell | enabled |
| `-q, --quiet` | Only show changes | disabled |
| `-v, --verbose` | Debug output | disabled |
| `--no-color` | Disable colors | enabled |

### Modes Explained

| Mode | Behavior |
|---|---|
| `auto` | Looks at `Content-Type` header: JSON → `api`, HTML → `website` |
| `api` | Compares raw response body (JSON, XML, plain text) |
| `website` | Strips HTML tags, normalizes whitespace, compares text content |

## Examples

### Watch a sneaker API for stock changes

```bash
./script.sh -i 10 \
  -H 'Authorization: Bearer mytoken' \
  -H 'Accept: application/json' \
  -f '.products[] | {name, price, available}' \
  https://api.sneakers.com/v1/stock
```

### Watch a website for content changes (5% threshold)

```bash
./script.sh -m website -p 5 -i 120 \
  https://www.nike.com/launches
```

### Watch a specific section of a webpage

```bash
./script.sh -m website \
  -s 'class="product-price"' \
  -i 60 \
  https://www.shop.com/product/air-jordan-1
```

### POST request to a search API

```bash
./script.sh -X POST \
  -H 'Content-Type: application/json' \
  -d '{"query": "jordan 1", "size": "42"}' \
  -f '.results[].price' \
  -i 30 \
  https://api.shop.com/search
```

### Log everything + save snapshots

```bash
./script.sh -i 60 \
  -l changes.log \
  --snapshot-dir ./snapshots \
  --diff \
  https://api.example.com/data
```

### Use with cron (check every 5 minutes)

```bash
# crontab -e
*/5 * * * * /path/to/script.sh --once --baseline-file /tmp/ww_status.txt -q -l /var/log/web-watcher.log https://api.example.com/status
```

The `--baseline-file` flag persists the previous response to disk so `--once` can compare across cron runs.

Exit codes for `--once` mode:
- `0` — No change detected (or first run)
- `1` — Fetch error
- `2` — Change detected

### Watch with cookie and Basic auth

```bash
./script.sh \
  --auth admin:secret123 \
  -C "session=abc123; token=xyz" \
  -i 45 \
  https://internal.company.com/api/dashboard
```

### Quiet mode for background monitoring

```bash
./script.sh -q --no-sound -l watch.log -i 30 https://api.example.com/prices &
```

## How It Works

```
┌─────────────────┐
│   Fetch URL     │ ← curl with headers, auth, cookies, retries
└────────┬────────┘
         │
┌────────▼────────┐
│  Detect Mode    │ ← auto / api / website (from Content-Type)
└────────┬────────┘
         │
┌────────▼────────┐
│ Process Content │ ← jq filter → grep selector → strip HTML
└────────┬────────┘
         │
┌────────▼────────┐
│ Compare with    │ ← diff-based change % calculation
│ Previous        │
└────────┬────────┘
         │
    ┌────▼────┐
    │ Changed?│
    └────┬────┘
     No  │  Yes
     │   │
     │   ├── Check threshold
     │   ├── Send notification (desktop + terminal)
     │   ├── Log to file
     │   ├── Save snapshot
     │   └── Show diff
     │
     ▼
   Sleep interval → Loop
```

## Notifications

| Platform | Method |
|---|---|
| macOS | `osascript` — native Notification Center with sound |
| Linux | `notify-send` — standard desktop notification |
| All | Terminal bell (`\a`) + colored terminal output |

## Tips

- **Start with short intervals** for testing (`-i 5`), then increase for production
- **Use `--verbose`** to debug header/response issues
- **Combine `--diff` with `--log`** to keep full audit trails
- **Use `--threshold`** to avoid false positives on dynamic sites (ads, timestamps, etc.)
- **Use `--snapshot-dir`** to build a history of responses you can analyze later
- **JSON API?** Always use `-f` to target the fields you care about — avoids noise from metadata changes

## License

[MIT](LICENSE)
