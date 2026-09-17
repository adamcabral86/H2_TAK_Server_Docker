#!/usr/bin/env bash
# Build images from a locally staged, licensed TAK release and push them to
# GitHub Container Registry repositories. GHCR_TOKEN needs packages:write.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
DEPLOY_ROOT="$(cd "$ROOT/.." && pwd)"
cd "$DEPLOY_ROOT"

ENV_FILE="$DEPLOY_ROOT/.env"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE not found. Copy docker/env.example to docker/.env first." >&2
  exit 1
fi
set -a
source "$ENV_FILE"
set +a

: "${TAK_RELEASE:?TAK_RELEASE must identify the locally staged vendor release}"
: "${TAK_IMAGE:?TAK_IMAGE must be the full GHCR image name}"
: "${TAK_DB_IMAGE:?TAK_DB_IMAGE must be the full GHCR database image name}"
: "${GHCR_TOKEN:?Set GHCR_TOKEN to a GitHub token with packages:write}"

if [[ ! -d "$ROOT/staging/$TAK_RELEASE/tak" ]]; then
  echo "ERROR: $ROOT/staging/$TAK_RELEASE/tak is missing. Run prepare-release.sh first." >&2
  exit 1
fi

echo "$GHCR_TOKEN" | docker login ghcr.io -u adamcabral86 --password-stdin
docker compose --env-file "$ENV_FILE" -f "$ROOT/docker-compose.build.yml" build
docker push "$TAK_IMAGE"
docker push "$TAK_DB_IMAGE"
