#!/usr/bin/env bash
# Bundles the two commands that follow staging + .env setup in QUICKSTART.md:
# bring the stack up, then run post-start provisioning. Safe to re-run.
#
# Usage (from deploy/docker/):
#   bash deploy.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

if [[ ! -f .env ]]; then
  echo "ERROR: .env not found — cp env.example .env and edit it first." >&2
  exit 1
fi

# Avoids requiring the separate docker-buildx-plugin package that Compose's
# default Bake builder needs.
export COMPOSE_BAKE=false

echo "[deploy] docker compose --env-file .env up -d --build"
docker compose --env-file .env up -d --build

echo "[deploy] Running post-start.sh..."
bash "$ROOT/post-start.sh"
