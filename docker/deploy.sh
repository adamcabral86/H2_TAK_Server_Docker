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

if [[ "${SKIP_IMAGE_PULL:-false}" == "true" ]]; then
  echo "[tak-deploy] Using locally loaded images; skipping registry pull."
else
  docker compose --env-file "$ENV_FILE" -f "$ROOT/docker-compose.yml" pull
fi
docker compose --env-file "$ENV_FILE" -f "$ROOT/docker-compose.yml" up -d
echo "[tak-deploy] Containers started. Waiting for TAK messaging and API services to become ready; first startup can take a few minutes..."
bash "$ROOT/scripts/post-start.sh"
