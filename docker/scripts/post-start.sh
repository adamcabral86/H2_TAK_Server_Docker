#!/usr/bin/env bash
# Post-start account provisioning for the pulled-image deployment.
# Configuration/certificates remain inside the named tak_config volume.
set -euo pipefail

SCRIPT_ROOT="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_ROOT/.." && pwd)"
cd "$ROOT"
ENV_FILE="$ROOT/.env"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE not found. Copy env.example to .env in the docker directory first." >&2
  exit 1
fi
set -a
source "$ENV_FILE"
set +a

TAK_CONTAINER="${TAK_CONTAINER:-takserver}"
ADMIN_CN="${CERT_ADMIN_CN:-admin}"
SERVICE_CN="${CERT_SERVICE_CN:-gateway-svc}"
ADMIN_USER="${ADMIN_USER:-$ADMIN_CN}"
CLIENT_USER="${CLIENT_USER:-takuser1}"
WAIT_TIMEOUT_SEC="${WAIT_TIMEOUT_SEC:-300}"

deadline=$((SECONDS + WAIT_TIMEOUT_SEC))
until docker exec "$TAK_CONTAINER" bash -c "grep -q 'Server started' /opt/tak/logs/takserver-messaging.log 2>/dev/null || exec 3<>/dev/tcp/127.0.0.1/8443"; do
  if (( SECONDS >= deadline )); then
    echo "ERROR: TAK did not become ready within ${WAIT_TIMEOUT_SEC}s" >&2
    exit 1
  fi
  sleep 5
done

if [[ "${LE_ENABLE:-false}" == "true" ]]; then
  bash "$SCRIPT_ROOT/apply-letsencrypt.sh"
  deadline=$((SECONDS + WAIT_TIMEOUT_SEC))
  until docker exec "$TAK_CONTAINER" bash -c "grep -q 'Server started' /opt/tak/logs/takserver-messaging.log 2>/dev/null || exec 3<>/dev/tcp/127.0.0.1/8443"; do
    if (( SECONDS >= deadline )); then
      echo "ERROR: TAK did not become ready after Let's Encrypt restart" >&2
      exit 1
    fi
    sleep 5
  done
fi

promote_cert() {
  local cn="$1"
  docker exec "$TAK_CONTAINER" bash -c \
    "cd /opt/tak && java -jar utils/UserManager.jar certmod -A certs/files/${cn}.pem"
}

promote_standard_client_cert() {
  local cn="$1"
  docker exec "$TAK_CONTAINER" bash -c \
    "cd /opt/tak && java -jar utils/UserManager.jar certmod certs/files/${cn}.pem"
}

ensure_standard_client_cert() {
  local cn="$1"
  docker exec -e TAK_CLIENT_CN="$cn" "$TAK_CONTAINER" bash -c \
    'test -f "/opt/tak/certs/files/${TAK_CLIENT_CN}.p12" || (cd /opt/tak/certs && ./makeCert.sh client "$TAK_CLIENT_CN")'
}

echo "[tak-post-start] Promoting internal administrator certificate..."
promote_cert "$ADMIN_CN"

if [[ "${ENABLE_SERVICE_ACCOUNT:-true}" == "true" ]]; then
  echo "[tak-post-start] Promoting internal service certificate..."
  promote_cert "$SERVICE_CN"
fi

if [[ -n "${ADMIN_PASSWORD:-}" ]]; then
  echo "[tak-post-start] Setting password for ${ADMIN_USER}..."
  docker exec \
    -e "TAK_ADMIN_USER=${ADMIN_USER}" \
    -e "TAK_ADMIN_PASSWORD=${ADMIN_PASSWORD}" \
    "$TAK_CONTAINER" bash -c \
    'cd /opt/tak && java -jar utils/UserManager.jar usermod -A -p "$TAK_ADMIN_PASSWORD" "$TAK_ADMIN_USER"'
fi

echo "[tak-post-start] Provisioning standard client '${CLIENT_USER}'..."
ensure_standard_client_cert "$CLIENT_USER"
promote_standard_client_cert "$CLIENT_USER"
if [[ -n "${CLIENT_PASSWORD:-}" ]]; then
  docker exec \
    -e "TAK_CLIENT_USER=${CLIENT_USER}" \
    -e "TAK_CLIENT_PASSWORD=${CLIENT_PASSWORD}" \
    "$TAK_CONTAINER" bash -c \
    'cd /opt/tak && java -jar utils/UserManager.jar usermod -c "certs/files/${TAK_CLIENT_USER}.pem" -p "$TAK_CLIENT_PASSWORD" "$TAK_CLIENT_USER"'
else
  echo "WARNING: CLIENT_PASSWORD is empty; the standard client certificate works, but enrollment credentials were not set." >&2
fi

CERTS_DEST="${CERTS_HOME_DIR:-$ROOT/tak-certs}"
umask 077
mkdir -p "$CERTS_DEST"
chmod 700 "$CERTS_DEST"

copy_certificate() {
  local source="$1"
  local destination="$2"
  docker cp "$TAK_CONTAINER:/opt/tak/certs/files/$source" "$CERTS_DEST/$destination"
}

# Export only the administrator identity and client trust material. The service
# identity remains in the container/volume and is never copied to the host.
copy_certificate "admin.p12" "admin.p12"
copy_certificate "${CERT_CA_CN:-TAK-CA-01}.pem" "ca.pem"

copy_certificate "truststore-root.p12" "truststore-root.p12"
copy_certificate "${CLIENT_USER}.p12" "${CLIENT_USER}.p12"

chmod 600 "$CERTS_DEST/admin.p12" "$CERTS_DEST/truststore-root.p12"
chmod 600 "$CERTS_DEST/${CLIENT_USER}.p12"
chmod 644 "$CERTS_DEST/ca.pem"

discover_aws_public_ip() {
  command -v curl >/dev/null 2>&1 || return

  # AWS IMDSv2 is link-local and does not leave the instance. Short timeouts
  # keep this best-effort display helper from delaying deployment elsewhere.
  local imds_token imds_ip
  imds_token="$(curl -fsS --connect-timeout 1 --max-time 2 \
    -X PUT http://169.254.169.254/latest/api/token \
    -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' 2>/dev/null || true)"
  if [[ -n "$imds_token" ]]; then
    imds_ip="$(curl -fsS --connect-timeout 1 --max-time 2 \
      -H "X-aws-ec2-metadata-token: $imds_token" \
      http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || true)"
    if [[ -n "$imds_ip" ]]; then
      printf '%s\n' "$imds_ip"
      return
    fi
  fi
}

discover_local_ip() {
  local route_ip
  if command -v ip >/dev/null 2>&1; then
    route_ip="$(ip route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit }}' || true)"
    [[ -n "$route_ip" ]] && printf '%s\n' "$route_ip" && return
  fi

  command -v hostname >/dev/null 2>&1 || return
  hostname -I 2>/dev/null | awk '{print $1}'
}

discover_external_ip() {
  command -v curl >/dev/null 2>&1 || return
  local external_ip
  external_ip="$(curl -fsS --connect-timeout 2 --max-time 5 \
    https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]' || true)"
  [[ -n "$external_ip" ]] && printf '%s\n' "$external_ip"
}

if [[ -n "${LE_FQDN:-}" ]]; then
  TAK_HOST_DISPLAY="$LE_FQDN"
elif [[ -n "${PUBLIC_IP:-}" ]]; then
  TAK_HOST_DISPLAY="$PUBLIC_IP"
else
  TAK_HOST_DISPLAY="$(discover_aws_public_ip || true)"
  TAK_HOST_DISPLAY="${TAK_HOST_DISPLAY:-$(discover_local_ip || true)}"
  TAK_HOST_DISPLAY="${TAK_HOST_DISPLAY:-$(discover_external_ip || true)}"
  TAK_HOST_DISPLAY="${TAK_HOST_DISPLAY:-<public-IP>}"
fi
echo "----------------------------------------------------------------"
echo
echo "[tak-post-start] Connection material exported to $CERTS_DEST"
echo
echo "TAK Server is ready:"
echo "  Certificate enrollment: https://${TAK_HOST_DISPLAY}:${HOST_PORT_CERT_HTTPS:-8446}"
echo "  Sign in as '${ADMIN_USER}' with the ADMIN_PASSWORD from .env."
echo
echo "  Same-host testing:      https://localhost:${HOST_PORT_CERT_HTTPS:-8446}"

echo "  Web administration:    https://${TAK_HOST_DISPLAY}:${HOST_PORT_HTTPS:-8443}"
echo "  Import admin.p12 in your browser; its password is CERT_PASS from .env."

echo "  Client trust material:"  
echo "  ca.pem and truststore-root.p12"
echo "  truststore-root.p12 uses CERT_PASS from .env."
echo
echo "  Standard TAK client:    ${CLIENT_USER}.p12 (password: CERT_PASS from .env)"
echo "  Enrollment username:   '${CLIENT_USER}' (password: CLIENT_PASSWORD from .env)."
