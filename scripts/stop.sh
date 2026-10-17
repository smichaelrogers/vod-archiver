#!/usr/bin/env bash
# Stop the archiver containers (data and archives are kept).
# Warning: stopping during a live recording ends that recording.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_cmd docker
load_config
touch "$SECRETS_FILE"

state="$("$PROJECT_DIR/scripts/keep-awake.sh" --check 2>/dev/null || echo idle)"
if [[ "$state" != "idle" && "${1:-}" != "--force" ]]; then
  die "Ganymede is currently $state. Re-run with --force to stop anyway."
fi
compose down
log "Stopped. Start again with: ./scripts/compose.sh up -d"
