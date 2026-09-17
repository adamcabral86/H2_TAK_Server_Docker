#!/usr/bin/env bash
# Registry equivalent of the account-provisioning portion of post-start.sh.
# Configuration/certificates remain inside the named tak_config volume.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
DOCKER_ROOT="$(cd "$ROOT/.." && pwd)"
cd "$DOCKER_ROOT"
set -a
source .env
set +a

TAK_CONTAINER="${TAK_CONTAINER:-takserver}"
ADMIN_CN="${CERT_ADMIN_CN:-admin}"
SERVICE_CN="${CERT_SERVICE_CN:-gateway-svc}"
ADMIN_USER="${ADMIN_USER:-$ADMIN_CN}"
WAIT_TIMEOUT_SEC="${WAIT_TIMEOUT_SEC:-300}"

deadline=$((SECONDS + WAIT_TIMEOUT_SEC))
until docker exec "$TAK_CONTAINER" bash -c "grep -q 'Server started' /opt/tak/logs/takserver-messaging.log 2>/dev/null || exec 3<>/dev/tcp/127.0.0.1/8443"; do
  if (( SECONDS >= deadline )); then
    echo "ERROR: TAK did not become ready within ${WAIT_TIMEOUT_SEC}s" >&2
    exit 1
  fi
  sleep 5
done

promote_cert() {
  local cn="$1"
  docker exec "$TAK_CONTAINER" bash -c \
    "cd /opt/tak && java -jar utils/UserManager.jar certmod -A certs/files/${cn}.pem"
}

echo "[registry-post-start] Promoting internal administrator certificate..."
promote_cert "$ADMIN_CN"

if [[ "${ENABLE_SERVICE_ACCOUNT:-true}" == "true" ]]; then
  echo "[registry-post-start] Promoting internal service certificate..."
  promote_cert "$SERVICE_CN"
fi

if [[ -n "${ADMIN_PASSWORD:-}" ]]; then
  echo "[registry-post-start] Setting password for ${ADMIN_USER}..."
  docker exec \
    -e "TAK_ADMIN_USER=${ADMIN_USER}" \
    -e "TAK_ADMIN_PASSWORD=${ADMIN_PASSWORD}" \
    "$TAK_CONTAINER" bash -c \
    'cd /opt/tak && java -jar utils/UserManager.jar usermod -A -p "$TAK_ADMIN_PASSWORD" "$TAK_ADMIN_USER"'
fi

echo "[registry-post-start] Done. Admin/enrollment endpoint: https://<host>:${HOST_PORT_CERT_HTTPS:-8446}"
