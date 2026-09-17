#!/usr/bin/env bash
# Starts a GHCR/ECR-style pulled-image deployment. Configuration and generated
# certificates are retained in named Docker volumes, not in the image.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

ENV_FILE="$ROOT/.env"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE not found. Copy env.example to .env in the docker directory and set secure values." >&2
  exit 1
fi

docker compose --env-file "$ENV_FILE" -f "$ROOT/docker-compose.yml" pull
docker compose --env-file "$ENV_FILE" -f "$ROOT/docker-compose.yml" up -d
bash "$ROOT/scripts/post-start.sh"
