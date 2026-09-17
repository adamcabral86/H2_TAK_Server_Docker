#!/usr/bin/env bash
# Build images from a locally staged, licensed TAK release and push them to
# private GitHub Container Registry repositories. GHCR_TOKEN needs packages:write.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

if [[ ! -f .env ]]; then
  echo "ERROR: .env not found. Copy env.registry.example or env.example to .env first." >&2
  exit 1
fi
set -a
source .env
set +a

: "${TAK_RELEASE:?TAK_RELEASE must identify the locally staged vendor release}"
: "${TAK_IMAGE:?TAK_IMAGE must be the full GHCR image name}"
: "${TAK_DB_IMAGE:?TAK_DB_IMAGE must be the full GHCR database image name}"
: "${GHCR_TOKEN:?Set GHCR_TOKEN to a GitHub token with packages:write}"

if [[ ! -d "staging/$TAK_RELEASE/tak" ]]; then
  echo "ERROR: staging/$TAK_RELEASE/tak is missing. Run prepare-tak-docker.sh first." >&2
  exit 1
fi

echo "$GHCR_TOKEN" | docker login ghcr.io -u adamcabral86 --password-stdin
docker compose --env-file .env -f docker-compose.registry-build.yml build
docker push "$TAK_IMAGE"
docker push "$TAK_DB_IMAGE"
