#!/usr/bin/env bash
# One-shot setup / re-apply: validates config, starts Ganymede, bootstraps an
# API key, applies low-resource settings and syncs watched channels.
# Safe to re-run any time after editing config.env.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_cmd docker curl jq
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 plugin is required (docker compose ...)."
load_config

# ---------------------------------------------------------------- validation
[[ "${ARCHIVE_DIR:-}" == /* ]] || die "ARCHIVE_DIR must be an absolute path (got '${ARCHIVE_DIR:-}')."
[[ -n "${TWITCH_CLIENT_ID:-}" && -n "${TWITCH_CLIENT_SECRET:-}" ]] \
  || die "Set TWITCH_CLIENT_ID and TWITCH_CLIENT_SECRET in config.env (https://dev.twitch.tv/console/apps/create)."
[[ -n "${STREAM_URLS:-}" && "$STREAM_URLS" != *CHANNEL_NAME* ]] || die "Set STREAM_URLS in config.env."
IFS=',' read -ra _urls <<< "$STREAM_URLS"
for u in "${_urls[@]}"; do
  [[ -z "${u// /}" ]] && continue
  channel_from_url "$u" >/dev/null || die "Can't parse a Twitch channel from '$u'."
done

# --------------------------------------------------------------- directories
if [[ ! -d "$ARCHIVE_DIR" ]]; then
  log "Creating $ARCHIVE_DIR"
  mkdir -p "$ARCHIVE_DIR" 2>/dev/null || sudo mkdir -p "$ARCHIVE_DIR"
fi
[[ -w "$ARCHIVE_DIR" ]] || warn "$ARCHIVE_DIR is not writable by $USER (the container runs as root, so this is usually fine)."
mkdir -p "$PROJECT_DIR/data/logs" "$PROJECT_DIR/data/config" "$PROJECT_DIR/data/db"

# ------------------------------------------------------------------- secrets
if [[ -z "${DB_PASSWORD:-}" ]]; then
  log "Generating database password (.secrets.env)"
  save_secret DB_PASSWORD "$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
fi
touch "$SECRETS_FILE"; chmod 600 "$SECRETS_FILE"

# ------------------------------------------------------------------- start
log "Starting containers ..."
compose pull --quiet || warn "Image pull failed; using local images if present."
compose up -d --remove-orphans
wait_for_health 60

# ----------------------------------------------------------------- bootstrap
JAR="$(mktemp)"; trap 'rm -f "$JAR"' EXIT

# Session-authenticated call (needed for endpoints that refuse API keys).
sess() {
  local method="$1" path="$2" body="${3:-}"
  local args=(-sS --fail-with-body -b "$JAR" -c "$JAR" -X "$method" -H "Accept: application/json")
  [[ -n "$body" ]] && args+=(-H "Content-Type: application/json" --data "$body")
  curl "${args[@]}" "$API$path"
}

api_key_works() {
  [[ -n "${GANYMEDE_API_KEY:-}" ]] && api GET /config >/dev/null 2>&1
}

manual_key_help() {
  cat >&2 <<EOF

Automatic API-key creation failed. Create one manually:
  1. Open $GANYMEDE_URL and log in.
  2. Admin > Settings: enable "API keys".
  3. Admin > API Keys: create a key named "twitch-vod-archiver" with admin scope.
  4. Add this line to $SECRETS_FILE:
       GANYMEDE_API_KEY=gym_xxxxxxxx_xxxxxxxxxxxxxxxx
  5. Re-run ./scripts/setup.sh
EOF
  exit 1
}

if ! api_key_works; then
  log "Bootstrapping Ganymede admin account and API key ..."
  user="admin"; pass="ganymede"; default_pw=true
  if ! sess POST /auth/login "$(jq -nc --arg u "$user" --arg p "$pass" '{username:$u,password:$p}')" >/dev/null 2>&1; then
    default_pw=false
    read -rp "Ganymede admin username: " user
    read -rsp "Ganymede admin password: " pass; echo
    sess POST /auth/login "$(jq -nc --arg u "$user" --arg p "$pass" '{username:$u,password:$p}')" >/dev/null \
      || die "Login failed."
  fi

  if $default_pw; then
    log "The default admin password (admin/ganymede) must be changed."
    while :; do
      read -rsp "New admin password (min 8 chars): " np; echo
      read -rsp "Confirm new password: " np2; echo
      [[ "$np" == "$np2" && ${#np} -ge 8 ]] && break
      warn "Passwords didn't match or were too short."
    done
    sess POST /auth/change-password "$(jq -nc --arg o "$pass" --arg n "$np" \
      '{old_password:$o,new_password:$n,confirm_new_password:$n}')" >/dev/null \
      || warn "Could not change password via API — change it in the web UI!"
    pass="$np"
    sess POST /auth/login "$(jq -nc --arg u "$user" --arg p "$pass" '{username:$u,password:$p}')" >/dev/null || true
  fi

  # API keys must be enabled in Ganymede's config before they can be used.
  cfg="$(sess GET /config)" || manual_key_help
  sess PUT /config "$(jq -c '.api_keys_enabled = true' <<< "$cfg")" >/dev/null || manual_key_help

  resp="$(sess POST /admin/api-keys \
    '{"name":"twitch-vod-archiver","description":"Used by twitch-vod-archiver scripts (channel sync, keep-awake).","scopes":["*:admin"]}')" \
    || manual_key_help
  secret="$(jq -r '.secret // empty' <<< "$resp")"
  prefix="$(jq -r '.api_key.prefix // empty' <<< "$resp")"
  [[ -n "$secret" ]] || manual_key_help
  [[ "$secret" == gym_* ]] || secret="gym_${prefix}_${secret}"
  save_secret GANYMEDE_API_KEY "$secret"
  api_key_works || manual_key_help
  log "API key created and saved to .secrets.env"
fi

# --------------------------------------------------------- apply settings
log "Applying low-resource Ganymede settings ..."
cfg="$(api GET /config)"
new_cfg="$(jq -c --argjson iv "${LIVE_CHECK_INTERVAL:-300}" '
  .api_keys_enabled = true
  | .live_check_interval_seconds = $iv
  | .log_retention_days = 7
  | .archive = ((.archive // {}) + {generate_sprite_thumbnails: false})
' <<< "$cfg")"
api PUT /config "$new_cfg" >/dev/null || warn "Could not update Ganymede config; adjust it in Admin > Settings."

# ------------------------------------------------------------ channels
"$PROJECT_DIR/scripts/sync-channels.sh"

cat <<EOF

$(log "Setup complete.")
  Web UI:        $GANYMEDE_URL
  Archive dir:   $ARCHIVE_DIR
  Status:        ./scripts/status.sh

Next: install the keep-awake service (one-time, needs sudo):
  sudo ./scripts/install-service.sh
EOF
