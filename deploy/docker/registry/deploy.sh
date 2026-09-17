#!/usr/bin/env bash
# Starts a GHCR/ECR-style pulled-image deployment. Configuration and generated
# certificates are retained in named Docker volumes, not in the image.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
DOCKER_ROOT="$(cd "$ROOT/.." && pwd)"
cd "$DOCKER_ROOT"

if [[ ! -f .env ]]; then
  echo "ERROR: .env not found. Copy registry/env.example to .env and set secure values." >&2
  exit 1
fi

docker compose --env-file .env -f "$ROOT/docker-compose.yml" pull
docker compose --env-file .env -f "$ROOT/docker-compose.yml" up -d
bash "$ROOT/post-start.sh"
