#!/usr/bin/env bash
# Keep the PC awake ONLY while Ganymede is recording (and, optionally,
# post-processing). Holds a systemd-logind "block" inhibitor for sleep/idle
# while work is active and releases it as soon as work finishes.
#
#   ./scripts/keep-awake.sh           run the watcher loop (used by systemd)
#   ./scripts/keep-awake.sh --check   print current activity once and exit
#
# Cost: one tiny HTTP request every KEEP_AWAKE_POLL_SECONDS; ~0% CPU.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_cmd curl jq systemd-inhibit
load_config

POLL="${KEEP_AWAKE_POLL_SECONDS:-30}"
INHIBIT_PID=""

# Prints: "recording", "processing", or "" (idle).
activity() {
  local items
  if [[ -n "${GANYMEDE_API_KEY:-}" ]] && items="$(api GET '/queue?processing=true' 2>/dev/null)"; then
    if jq -e 'any(.[]?; .live_archive == true and (.task_video_download == "running" or .task_chat_download == "running"))' \
         <<< "$items" >/dev/null; then
      echo recording; return
    fi
    if jq -e 'any(.[]?; .processing == true and (.on_hold // false) == false)' <<< "$items" >/dev/null; then
      echo processing; return
    fi
    echo ""; return
  fi
  # Fallback (API unavailable): inspect processes inside the container.
  if command -v docker >/dev/null 2>&1; then
    local procs
    procs="$(docker top ganymede -eo args 2>/dev/null || true)"
    if grep -qE 'streamlink' <<< "$procs"; then echo recording; return; fi
    if grep -qE 'ffmpeg|TwitchDownloaderCLI' <<< "$procs"; then echo processing; return; fi
  fi
  echo ""
}

should_hold() {
  case "$1" in
    recording) return 0 ;;
    processing) is_true "${KEEP_AWAKE_DURING_PROCESSING:-true}" ;;
    *) return 1 ;;
  esac
}

hold() {
  [[ -n "$INHIBIT_PID" ]] && kill -0 "$INHIBIT_PID" 2>/dev/null && return
  systemd-inhibit --what=sleep:idle --mode=block \
    --who="twitch-vod-archiver" --why="$1 Twitch stream" \
    sleep infinity &
  INHIBIT_PID=$!
  log "Sleep inhibited ($1)."
}

release() {
  if [[ -n "$INHIBIT_PID" ]]; then
    pkill -P "$INHIBIT_PID" 2>/dev/null || true
    kill "$INHIBIT_PID" 2>/dev/null || true
    wait "$INHIBIT_PID" 2>/dev/null || true
    INHIBIT_PID=""
    log "Sleep allowed again."
  fi
}

if [[ "${1:-}" == "--check" ]]; then
  a="$(activity)"; echo "${a:-idle}"; exit 0
fi

trap 'release; exit 0' INT TERM
trap 'release' EXIT

log "Keep-awake watcher started (poll ${POLL}s, processing=${KEEP_AWAKE_DURING_PROCESSING:-true})."
idle_streak=0
while :; do
  state="$(activity)"
  if should_hold "$state"; then
    idle_streak=0
    hold "$state"
  else
    # Require two consecutive idle polls to avoid flapping between
    # the end of a download and the start of the next task.
    idle_streak=$((idle_streak + 1))
    (( idle_streak >= 2 )) && release
  fi
  # `sleep & wait` keeps the loop responsive to SIGTERM.
  sleep "$POLL" & wait $! || true
done
