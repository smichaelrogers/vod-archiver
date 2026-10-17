#!/usr/bin/env bash
# Shared helpers for twitch-vod-archiver scripts. Source, don't execute.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$PROJECT_DIR/config.env}"
SECRETS_FILE="$PROJECT_DIR/.secrets.env"

log()  { printf '\033[1;36m[archiver]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[archiver] WARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[archiver] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# Parse KEY=VALUE env files literally (no shell evaluation), so values may
# contain spaces/semicolons and stay compatible with `docker compose --env-file`.
load_env_file() {
  local file="$1" line key value
  [[ -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    # Strip inline comments ( " # ...") from unquoted values, then trim.
    if [[ ! "$value" =~ ^[\"\'] ]]; then
      value="${value%%[[:space:]]#*}"
    fi
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    # Remove matching surrounding quotes.
    if [[ "$value" =~ ^\"(.*)\"$ || "$value" =~ ^\'(.*)\'$ ]]; then
      value="${BASH_REMATCH[1]}"
    fi
    printf -v "$key" '%s' "$value"
    export "${key?}"
  done < "$file"
}

load_config() {
  [[ -f "$CONFIG_FILE" ]] || die "Missing $CONFIG_FILE — run: cp config.env.example config.env"
  load_env_file "$CONFIG_FILE"
  load_env_file "$SECRETS_FILE"
  : "${WEB_PORT:=4800}"
  GANYMEDE_URL="${GANYMEDE_URL:-http://127.0.0.1:${WEB_PORT}}"
  API="$GANYMEDE_URL/api/v1"
}

# Set/replace KEY=VALUE in .secrets.env (mode 600).
save_secret() {
  local key="$1" value="$2" tmp
  touch "$SECRETS_FILE"; chmod 600 "$SECRETS_FILE"
  tmp="$(mktemp)"
  grep -v "^${key}=" "$SECRETS_FILE" > "$tmp" || true
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  cat "$tmp" > "$SECRETS_FILE"; rm -f "$tmp"
  printf -v "$key" '%s' "$value"; export "${key?}"
}

is_true() { [[ "${1,,}" =~ ^(1|true|yes|on)$ ]]; }

require_cmd() {
  local c; for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "Required command not found: $c"
  done
}

compose() {
  docker compose --project-directory "$PROJECT_DIR" \
    -f "$PROJECT_DIR/docker-compose.yml" \
    --env-file "$CONFIG_FILE" --env-file "$SECRETS_FILE" "$@"
}

# Authenticated API call with the stored API key.
#   api METHOD PATH [JSON_BODY]   -> prints body, fails on HTTP >= 400
api() {
  local method="$1" path="$2" body="${3:-}"
  [[ -n "${GANYMEDE_API_KEY:-}" ]] || die "No GANYMEDE_API_KEY in .secrets.env — run ./scripts/setup.sh"
  local args=(-sS --fail-with-body -X "$method" -H "Authorization: Bearer $GANYMEDE_API_KEY"
              -H "Accept: application/json")
  [[ -n "$body" ]] && args+=(-H "Content-Type: application/json" --data "$body")
  curl "${args[@]}" "$API$path"
}

wait_for_health() {
  local tries="${1:-60}"
  log "Waiting for Ganymede at $GANYMEDE_URL ..."
  for ((i = 0; i < tries; i++)); do
    if curl -sf "$GANYMEDE_URL/health" >/dev/null 2>&1; then log "Ganymede is up."; return 0; fi
    sleep 5
  done
  die "Ganymede did not become healthy. Check: ./scripts/compose.sh logs ganymede"
}

# Extract a channel login from a Twitch URL or bare name.
channel_from_url() {
  local u="$1"
  u="${u#"${u%%[![:space:]]*}"}"; u="${u%"${u##*[![:space:]]}"}"
  if [[ "$u" =~ twitch\.tv/([A-Za-z0-9_]+) ]]; then
    printf '%s' "${BASH_REMATCH[1],,}"
  elif [[ "$u" =~ ^[A-Za-z0-9_]+$ ]]; then
    printf '%s' "${u,,}"
  else
    return 1
  fi
}
