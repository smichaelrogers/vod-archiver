#!/usr/bin/env bash
# Run by twitch-wake.service after the PC is woken by twitch-wake.timer.
# Triggers an immediate live check and keeps the PC awake for WAKE_HOLD_MINUTES
# so the stream has time to start. Once recording begins, keep-awake.service
# takes over and holds the PC awake until the recording is done.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_cmd curl systemd-inhibit
load_config

hold_secs=$(( ${WAKE_HOLD_MINUTES:-30} * 60 ))
log "Scheduled wake: staying awake ${WAKE_HOLD_MINUTES:-30} min waiting for a stream."

# Give the network/containers a moment after resume, then poll for live streams.
(
  sleep 20
  end=$((SECONDS + hold_secs))
  while (( SECONDS < end )); do
    api GET /live/check >/dev/null 2>&1 || true
    sleep 120
  done
) &

exec systemd-inhibit --what=sleep:idle --mode=block \
  --who="twitch-vod-archiver" --why="Waiting for scheduled Twitch stream" \
  sleep "$hold_secs"
