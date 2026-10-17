#!/bin/zsh

# ============================================================================
# Pushover Notifier
# ============================================================================
# Sends short status pushes to a personal Pushover account so long-running
# LLM sessions can report progress while you are away from the desk.
#
# Credentials live in the login Keychain (service "pushover"), never on disk.
# Sends are throttled and screened for secrets before leaving the machine.
#
# API: https://pushover.net/api
#
# Requirements:
#   macOS (zsh, curl, and the security CLI for Keychain access ship with it)
#   jq   (brew install jq)
#   rg   (brew install ripgrep)
#   A Pushover account and an application token from https://pushover.net/apps/build
#
# Config (optional):
#   Override any of the limits below, or TITLE_PREFIX, in
#   ~/.config/pushover/config (or $XDG_CONFIG_HOME/pushover/config), e.g.
#     TITLE_PREFIX="Claude"
#     MAX_PER_WINDOW=20
#   The file is sourced as zsh, so use plain KEY=value lines.
#
# Usage:
#   One-time setup:  ./pushover.sh --setup
#   Check creds:     ./pushover.sh --test
#   Usage and rules: ./pushover.sh --help
#   Send status:     ./pushover.sh -t "ABC-123 DB Retry" "Retry fix is in and tests pass. Ready for review."
# ============================================================================

# Configuration
KEYCHAIN_SERVICE="pushover"
KEYCHAIN_TOKEN_ACCOUNT="app-token"
KEYCHAIN_USER_ACCOUNT="user-key"
API_MESSAGES="https://api.pushover.net/1/messages.json"
API_VALIDATE="https://api.pushover.net/1/users/validate.json"
STATE_DIR="${PUSHOVER_STATE_DIR:-$HOME/.local/state/pushover}"
SENT_LOG="$STATE_DIR/sent.log"
LOCK_DIR="$STATE_DIR/lock"
# Keep the path as invoked (not symlink-resolved) so printed examples match the caller's allow rule
SCRIPT="${0:a}"

# Limits (Pushover caps title at 250, message at 1024, url at 512 characters)
MAX_TITLE_CHARS=40
MAX_MESSAGE_CHARS=1024
MAX_URL_CHARS=512
MIN_GAP_SECONDS=3
WINDOW_SECONDS=300
MAX_PER_WINDOW=10
TITLE_PREFIX="Agent"

CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/pushover/config"
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

SECRET_PATTERNS=(
  'AKIA[0-9A-Z]{16}'
  'ASIA[0-9A-Z]{16}'
  'gh[pousr]_[A-Za-z0-9]{20,}'
  'github_pat_[A-Za-z0-9_]{20,}'
  'xox[abprs]-[A-Za-z0-9-]{10,}'
  'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}'
  '-----BEGIN [A-Z ]*PRIVATE KEY'
  'sk-ant-[A-Za-z0-9_-]{10,}'
  'npm_[A-Za-z0-9]{30,}'
  '(?i)(password|passwd|secret|api[_-]?key|token)[[:space:]]*[:=][[:space:]]*[A-Za-z0-9_/+=-]{16,}'
)

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color
if [[ ! -t 1 || ! -t 2 ]]; then
  RED='' GREEN='' YELLOW='' BLUE='' NC=''
fi

show_help() {
  echo "Pushover Notifier"
  echo ""
  echo "Usage: $SCRIPT [OPTIONS] MESSAGE"
  echo ""
  echo "Options:"
  echo "  -t, --title LABEL    Session label, sent as \"${TITLE_PREFIX}: LABEL\" (default: just \"${TITLE_PREFIX}\")"
  echo "  -u, --url URL        Supplementary URL shown with the message"
  echo "  -q, --quiet          Deliver silently (Pushover priority -1); for routine check-ins"
  echo "  --dry-run            Run all checks and print the payload without sending"
  echo "  --setup              Store app token and user key in the login Keychain"
  echo "  --test               Validate stored credentials without sending a push"
  echo "  --help               Show this help, including limits and message rules; read before the first push"
  echo ""
  print_guide
}

# ============================================================================
# Helper Functions
# ============================================================================

print_success() {
  echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
  echo -e "${RED}✗ Error: $1${NC}" >&2
}

print_info() {
  echo -e "${BLUE}ℹ $1${NC}"
}

print_warning() {
  echo -e "${YELLOW}⚠ $1${NC}" >&2
}

keychain_read() {
  security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$1" -w 2>/dev/null
}

load_credentials() {
  APP_TOKEN=$(keychain_read "$KEYCHAIN_TOKEN_ACCOUNT")
  USER_KEY=$(keychain_read "$KEYCHAIN_USER_ACCOUNT")
  if [[ -z "$APP_TOKEN" || -z "$USER_KEY" ]]; then
    print_error "Pushover credentials not found in Keychain (or Keychain is locked). Run: $SCRIPT --setup"
    exit 2
  fi
}

check_secrets() {
  local text="$1" pattern
  for pattern in "${SECRET_PATTERNS[@]}"; do
    if print -r -- "$text" | rg -q -e "$pattern"; then
      print_error "Message looks like it contains a secret (matched: $pattern). Not sent."
      exit 4
    fi
  done
}

acquire_lock() {
  local attempts=0
  mkdir -p "$STATE_DIR"
  until mkdir "$LOCK_DIR" 2>/dev/null; do
    # A send holds the lock for at most curl's 15s timeout, so anything older was left by a killed run
    if [[ -d "$LOCK_DIR" ]] && (( $(date +%s) - $(stat -f %m "$LOCK_DIR") > 60 )); then
      rmdir "$LOCK_DIR" 2>/dev/null
    fi
    (( attempts++ ))
    if (( attempts > 50 )); then
      print_error "Could not acquire lock at $LOCK_DIR. Remove it if no send is running."
      exit 5
    fi
    sleep 0.1
  done
}

check_throttle() {
  local now=$(date +%s) last=0 ts
  local -a window_ts
  [[ -f "$SENT_LOG" ]] || return 0
  while read -r ts; do
    [[ "$ts" == <-> ]] || continue
    (( now - ts < WINDOW_SECONDS )) && window_ts+=($ts)
    (( ts > last )) && last=$ts
  done < "$SENT_LOG"
  window_ts=(${(on)window_ts})

  local reason="" wait=0
  if (( ${#window_ts} >= MAX_PER_WINDOW )); then
    reason="${#window_ts} pushes in the last $(( WINDOW_SECONDS / 60 )) minutes"
    wait=$(( window_ts[${#window_ts} - MAX_PER_WINDOW + 1] + WINDOW_SECONDS - now ))
  elif (( now - last < MIN_GAP_SECONDS )); then
    reason="last push was $(( now - last ))s ago (minimum ${MIN_GAP_SECONDS}s)"
    wait=$(( last + MIN_GAP_SECONDS - now ))
  fi
  if [[ -n "$reason" ]]; then
    print_warning "Throttled: ${reason}. Next send allowed in ${wait}s. Not sent; do not wait for it. Include this update in your next push, or retry once if it is the final push."
    exit 3
  fi
}

record_send() {
  local cutoff=$(( $(date +%s) - WINDOW_SECONDS ))
  date +%s >> "$SENT_LOG"
  awk -v c="$cutoff" '$1 >= c' "$SENT_LOG" > "$SENT_LOG.tmp" && mv "$SENT_LOG.tmp" "$SENT_LOG"
}

# ============================================================================
# Commands
# ============================================================================

remaining_sends() {
  local used=0
  [[ -f "$SENT_LOG" ]] && used=$(awk -v c="$(( $(date +%s) - WINDOW_SECONDS ))" '$1 >= c' "$SENT_LOG" | wc -l | tr -d ' ')
  print -r -- $(( MAX_PER_WINDOW - used ))
}

print_guide() {
  echo "Example:   $SCRIPT -t \"Pushover Script\" \"Nothing blocking. Tests pass, starting the docs update.\""
  echo "Title:     Pass -t with a 1 to 3 word session label, or the ticket key, e.g. \"Pushover Script\" or \"ABC-123\"."
  echo "           Sent as \"${TITLE_PREFIX}: <label>\", ${MAX_TITLE_CHARS} chars max. Pick it on the first push and reuse it all session."
  echo "           No folder names or paths; it only needs to tell parallel sessions apart."
  echo "Message:   ${MAX_MESSAGE_CHARS} chars max, as the trailing argument. Over the limit or containing backticks is rejected and nothing is sent."
  echo "Secrets:   AWS, GitHub, Slack, npm, or Anthropic keys, JWTs, private keys, or long password/token values are rejected."
  echo "Rate:      ${MIN_GAP_SECONDS}s apart, ${MAX_PER_WINDOW} per $(( WINDOW_SECONDS / 60 )) minutes, shared across all sessions."
  echo "Remaining: $(remaining_sends) of ${MAX_PER_WINDOW} in the current window, across all sessions."
  echo "Style:     A status update in plain, full sentences, as a teammate would write it. No shorthand or clipped fragments."
  echo "           Lead with the action needed. If there is none, say nothing is blocking. Lock screens show only the first 100 to 150 chars."
  echo "           Aim for a sentence or two. Go longer only when the detail is needed to understand or act."
  echo "           Prefer one push over several. Put the main point first and any detail after it."
  echo "           Good: \"Done, the branch is ready for review.\" Bad: the same line followed by a summary of every step."
  echo "           Summarize or describe; never paste raw code, logs, stack traces, file paths, or command output."
  echo "Check-ins: On long tasks, send an occasional --quiet \"still working\" push, at most every ~10 minutes or per phase."
  echo "           Give progress (phase, or N of M) and an ETA only when measured, e.g. 40 of 120 at ~2 min each."
  echo "Exit:      0 sent. 3 throttled: don't wait, fold into the next push, retry only a final push once."
  echo "           6 too long or has code: rewrite, send once. 4 looks like a secret: rephrase once. 1 failed: don't retry."
  echo "           2 no creds: stop pushing and tell me when I'm back."
}

run_setup() {
  print_info "Paste values when prompted. They go straight to the login Keychain."
  print_info "App token: create an application at https://pushover.net/apps/build"
  security add-generic-password -U -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_TOKEN_ACCOUNT" -w || exit 1
  print_info "User key: shown on your https://pushover.net dashboard"
  security add-generic-password -U -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_USER_ACCOUNT" -w || exit 1
  print_success "Stored. Run $SCRIPT --test to validate."
}

run_test() {
  load_credentials
  local response
  response=$(curl -sS --max-time 15 -w '\n%{http_code}' \
    --form-string "token=$APP_TOKEN" \
    --form-string "user=$USER_KEY" \
    "$API_VALIDATE") || { print_error "Request to Pushover failed"; exit 1; }
  local http_code="${response##*$'\n'}" body="${response%$'\n'*}"
  if [[ "$http_code" == "200" && "$(echo "$body" | jq -r '.status')" == "1" ]]; then
    print_success "Credentials valid. Devices: $(echo "$body" | jq -r '.devices | join(", ")')"
  else
    print_error "Validation failed (HTTP $http_code): $(echo "$body" | jq -r '.errors // [] | join("; ")')"
    exit 1
  fi
}

# ============================================================================
# Main
# ============================================================================

LABEL=""
URL=""
PRIORITY=0
DRY_RUN="false"
MESSAGE_PARTS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--title) LABEL="$2"; shift 2 ;;
    -u|--url) URL="$2"; shift 2 ;;
    -q|--quiet) PRIORITY=-1; shift ;;
    --dry-run) DRY_RUN="true"; shift ;;
    --setup) run_setup; exit 0 ;;
    --test) run_test; exit 0 ;;
    --help|-h) show_help; exit 0 ;;
    --) shift; MESSAGE_PARTS+=("$@"); break ;;
    -*) print_error "Unknown option: $1"; show_help; exit 1 ;;
    *) MESSAGE_PARTS+=("$1"); shift ;;
  esac
done

MESSAGE="${MESSAGE_PARTS[*]}"
if [[ -z "${MESSAGE//[[:space:]]/}" ]]; then
  print_error "Message is required"
  exit 1
fi

TITLE="${TITLE_PREFIX}${LABEL:+: $LABEL}"

check_secrets "$TITLE"$'\n'"$MESSAGE"$'\n'"$URL"

if (( ${#TITLE} > MAX_TITLE_CHARS )); then
  print_error "Title is ${#TITLE} chars (max ${MAX_TITLE_CHARS}). Not sent; shorten it and send once."
  exit 6
fi
if (( ${#MESSAGE} > MAX_MESSAGE_CHARS )); then
  print_error "Message is ${#MESSAGE} chars (max ${MAX_MESSAGE_CHARS}). Not sent; rewrite it shorter and send once."
  exit 6
fi
if [[ "$TITLE$MESSAGE" == *'`'* ]]; then
  print_error "Title or message contains backticks. Not sent; rewrite it as plain prose without code and send once."
  exit 6
fi
if (( ${#URL} > MAX_URL_CHARS )); then
  print_error "URL is ${#URL} chars (max ${MAX_URL_CHARS}). Not sent; drop or shorten it and send once."
  exit 6
fi

acquire_lock
trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT
trap 'exit 130' INT TERM HUP PIPE
check_throttle

if [[ "$DRY_RUN" == "true" ]]; then
  print_info "Dry run, not sent:"
  echo "  title:    $TITLE"
  [[ -n "$URL" ]] && echo "  url:      $URL"
  echo "  priority: $PRIORITY"
  echo "  message:  $MESSAGE"
  exit 0
fi

load_credentials

CURL_ARGS=(
  --form-string "token=$APP_TOKEN"
  --form-string "user=$USER_KEY"
  --form-string "title=$TITLE"
  --form-string "message=$MESSAGE"
  --form-string "priority=$PRIORITY"
)
[[ -n "$URL" ]] && CURL_ARGS+=(--form-string "url=$URL")

RESPONSE=$(curl -sS --max-time 15 -w '\n%{http_code}' "${CURL_ARGS[@]}" "$API_MESSAGES") \
  || { print_error "Request to Pushover failed"; exit 1; }
HTTP_CODE="${RESPONSE##*$'\n'}"
BODY="${RESPONSE%$'\n'*}"

if [[ "$HTTP_CODE" == "200" && "$(echo "$BODY" | jq -r '.status')" == "1" ]]; then
  record_send
  print_success "Sent. $(remaining_sends) of ${MAX_PER_WINDOW} left in the next $(( WINDOW_SECONDS / 60 )) minutes."
else
  print_error "Pushover rejected the push (HTTP $HTTP_CODE): $(echo "$BODY" | jq -r '.errors // [] | join("; ")')"
  exit 1
fi
