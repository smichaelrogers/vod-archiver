#!/usr/bin/env bash
# Quick overview: containers, watched channels, active work, sleep inhibitor, disk.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_cmd docker curl jq
load_config
touch "$SECRETS_FILE"

echo "== Containers =="
compose ps --format 'table {{.Name}}\t{{.Status}}' || true
docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}' ganymede ganymede-db 2>/dev/null || true

echo; echo "== Watched channels =="
if live="$(api GET /live 2>/dev/null)"; then
  jq -r '.[] | "  \(.edges.channel.name // "?")\tlive=\(.watch_live) vods=\(.watch_vod) quality=\(.resolution) is_live=\(.is_live)"' <<< "$live"
else
  echo "  (API unavailable)"
fi

echo; echo "== Activity =="
echo "  $("$PROJECT_DIR/scripts/keep-awake.sh" --check 2>/dev/null || echo unknown)"

echo; echo "== Sleep inhibitors (twitch-vod-archiver) =="
systemd-inhibit --list --no-pager 2>/dev/null | grep -i twitch || echo "  none (PC may sleep normally)"
systemctl is-active twitch-keep-awake.service >/dev/null 2>&1 \
  && echo "  keep-awake service: active" \
  || echo "  keep-awake service: NOT running (sudo ./scripts/install-service.sh)"

echo; echo "== Archive storage =="
df -h "$ARCHIVE_DIR" 2>/dev/null | sed 's/^/  /'
