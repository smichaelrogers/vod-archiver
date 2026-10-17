#!/usr/bin/env bash
# Install (or update) the systemd units:
#   - twitch-keep-awake.service : holds a sleep inhibitor only while recording
#   - twitch-wake.timer         : optional scheduled wake-from-suspend (WAKE_SCHEDULE)
#
#   sudo ./scripts/install-service.sh              install / update
#   sudo ./scripts/install-service.sh --uninstall  remove units
# Re-run after changing WAKE_SCHEDULE in config.env.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[[ $EUID -eq 0 ]] || die "Run with sudo: sudo $0 $*"
UNIT_DIR=/etc/systemd/system

if [[ "${1:-}" == "--uninstall" ]]; then
  systemctl disable --now twitch-keep-awake.service twitch-wake.timer 2>/dev/null || true
  rm -f "$UNIT_DIR"/twitch-keep-awake.service "$UNIT_DIR"/twitch-wake.service "$UNIT_DIR"/twitch-wake.timer
  systemctl daemon-reload
  log "Units removed."
  exit 0
fi

load_config
chmod +x "$PROJECT_DIR"/scripts/*.sh

render() { sed "s|@PROJECT_DIR@|$PROJECT_DIR|g" "$PROJECT_DIR/systemd/$1" > "$UNIT_DIR/$1"; }

render twitch-keep-awake.service
render twitch-wake.service

if [[ -n "${WAKE_SCHEDULE:-}" ]]; then
  {
    echo "[Unit]"
    echo "Description=Twitch VOD Archiver - scheduled wake from suspend"
    echo
    echo "[Timer]"
    IFS=';' read -ra entries <<< "$WAKE_SCHEDULE"
    for e in "${entries[@]}"; do
      e="${e#"${e%%[![:space:]]*}"}"; e="${e%"${e##*[![:space:]]}"}"
      [[ -z "$e" ]] && continue
      systemd-analyze calendar "$e" >/dev/null 2>&1 || die "Invalid WAKE_SCHEDULE entry: '$e'"
      echo "OnCalendar=$e"
    done
    echo "WakeSystem=true"
    echo "Persistent=false"
    echo "AccuracySec=1min"
    echo
    echo "[Install]"
    echo "WantedBy=timers.target"
  } > "$UNIT_DIR/twitch-wake.timer"
else
  systemctl disable --now twitch-wake.timer 2>/dev/null || true
  rm -f "$UNIT_DIR/twitch-wake.timer"
fi

systemctl daemon-reload
systemctl enable --now twitch-keep-awake.service
systemctl restart twitch-keep-awake.service
log "twitch-keep-awake.service enabled."

if [[ -f "$UNIT_DIR/twitch-wake.timer" ]]; then
  systemctl enable --now twitch-wake.timer
  log "twitch-wake.timer enabled. Next wake:"
  systemctl list-timers twitch-wake.timer --no-pager | sed -n '1,2p'
fi

# Docker must start at boot so containers come back after reboots.
systemctl is-enabled docker.service >/dev/null 2>&1 || {
  warn "docker.service is not enabled at boot — enabling it."
  systemctl enable docker.service
}
