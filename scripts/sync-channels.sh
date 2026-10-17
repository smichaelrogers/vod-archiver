#!/usr/bin/env bash
# Make Ganymede's watched channels match STREAM_URLS in config.env.
#   ./scripts/sync-channels.sh           add/update channels from config
#   ./scripts/sync-channels.sh --prune   also stop watching channels not in config
#                                        (already-archived videos are kept)
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_cmd curl jq
load_config

PRUNE=false
[[ "${1:-}" == "--prune" ]] && PRUNE=true

bool() { is_true "${1:-false}" && echo true || echo false; }

QUALITY="${QUALITY:-best}"
case "$QUALITY" in best|1440p|1080p|720p|480p|360p|160p|audio) ;; *) die "Invalid QUALITY '$QUALITY'";; esac

settings="$(jq -nc \
  --arg q "$QUALITY" \
  --argjson live "$(bool "${ARCHIVE_LIVE:-true}")" \
  --argjson vod "$(bool "${ARCHIVE_VODS:-true}")" \
  --argjson chat "$(bool "${ARCHIVE_CHAT:-true}")" \
  --argjson render "$(bool "${RENDER_CHAT:-false}")" \
  --argjson age "${VOD_MAX_AGE_DAYS:-7}" '
  {
    resolution: $q,
    vod_resolution: $q,
    watch_live: $live,
    watch_vod: $vod,
    download_archives: true,
    download_highlights: false,
    download_uploads: false,
    download_sub_only: false,
    watch_clips: false,
    archive_chat: $chat,
    render_chat: $render,
    video_age: $age,
    categories: [],
    regex: []
  }')"

watched="$(api GET /live)"
wanted=()

IFS=',' read -ra urls <<< "$STREAM_URLS"
for u in "${urls[@]}"; do
  [[ -z "${u// /}" ]] && continue
  name="$(channel_from_url "$u")" || die "Can't parse a Twitch channel from '$u'."
  wanted+=("$name")

  # 1) Ensure the channel exists in Ganymede.
  if ch="$(api GET "/channel/name/$name" 2>/dev/null)" && [[ -n "$(jq -r '.id // empty' <<< "$ch")" ]]; then
    :
  else
    log "Adding channel '$name'"
    ch="$(api POST /archive/channel "$(jq -nc --arg n "$name" '{channel_name:$n}')")" \
      || die "Could not add channel '$name' (check the name and your Twitch app credentials)."
  fi
  channel_id="$(jq -r '.id' <<< "$ch")"

  # 2) Create or update the watched-channel entry.
  live_id="$(jq -r --arg cid "$channel_id" --arg n "$name" \
    '[.[] | select(.edges.channel.id == $cid or ((.edges.channel.name // "") | ascii_downcase) == $n)][0].id // empty' \
    <<< "$watched")"

  if [[ -n "$live_id" ]]; then
    log "Updating watched channel '$name'"
    api PUT "/live/$live_id" "$settings" >/dev/null
  else
    log "Watching channel '$name'"
    api POST /live "$(jq -c --arg cid "$channel_id" '. + {channel_id: $cid}' <<< "$settings")" >/dev/null
  fi
done

if $PRUNE; then
  wanted_json="$(printf '%s\n' "${wanted[@]}" | jq -R . | jq -sc .)"
  jq -r --argjson w "$wanted_json" \
    '.[] | select((.edges.channel.name // "" | ascii_downcase) as $n | ($w | index($n)) | not) | "\(.id) \(.edges.channel.name)"' \
    <<< "$watched" | while read -r id name; do
      log "Unwatching '$name' (not in config; archives kept)"
      api DELETE "/live/$id" >/dev/null || warn "Failed to remove watched channel '$name'"
    done
fi

# Kick an immediate live check so a stream that's already live starts now.
api GET /live/check >/dev/null 2>&1 || true
log "Channels synced: ${wanted[*]}"
