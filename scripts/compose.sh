#!/usr/bin/env bash
# `docker compose` wrapper that loads config.env + .secrets.env.
#   ./scripts/compose.sh ps | logs -f ganymede | pull | up -d | down
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_cmd docker
load_config
touch "$SECRETS_FILE"
compose "$@"
