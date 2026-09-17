#!/usr/bin/env bash
# Import the current Let's Encrypt certificate into the named TAK config volume.
# Intended as certbot's --deploy-hook; it does not request or renew a certificate.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$ROOT/.env"
set -a
source "$ENV_FILE"
set +a

: "${LE_FQDN:?LE_FQDN must be set in $ENV_FILE}"
: "${CERT_PASS:?CERT_PASS must be set in $ENV_FILE}"
TAK_CONTAINER="${TAK_CONTAINER:-takserver}"
LIVE="/etc/letsencrypt/live/$LE_FQDN"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

sudo test -f "$LIVE/fullchain.pem"
sudo test -f "$LIVE/privkey.pem"
sudo openssl pkcs12 -export -in "$LIVE/fullchain.pem" -inkey "$LIVE/privkey.pem" \
  -out "$TMP_DIR/takserver-le.p12" -name "$LE_FQDN" -passout "pass:$CERT_PASS"
sudo chown "$(id -u):$(id -g)" "$TMP_DIR/takserver-le.p12"

docker cp "$TMP_DIR/takserver-le.p12" "$TAK_CONTAINER:/opt/tak/certs/files/takserver-le.p12"
docker exec -e TAK_CERT_PASS="$CERT_PASS" "$TAK_CONTAINER" bash -c '
  rm -f /opt/tak/certs/files/takserver-le.jks
  keytool -importkeystore -destkeystore /opt/tak/certs/files/takserver-le.jks \
    -srckeystore /opt/tak/certs/files/takserver-le.p12 -srcstoretype pkcs12 \
    -deststorepass "$TAK_CERT_PASS" -destkeypass "$TAK_CERT_PASS" \
    -srcstorepass "$TAK_CERT_PASS" -noprompt
'
docker exec -e TAK_CERT_PASS="$CERT_PASS" "$TAK_CONTAINER" bash -c '
  config=/opt/tak/CoreConfig.xml
  if grep -q "cert_https_LE" "$config"; then
    sed -i -E "s#keystoreFile=\"certs/files/[^\"]*-le\\.jks\"#keystoreFile=\"certs/files/takserver-le.jks\"#" "$config"
  elif grep -q "_name=\"cert_https\"" "$config"; then
    sed -i "s#connector port=\"8446\" clientAuth=\"false\" _name=\"cert_https\"#connector port=\"8446\" clientAuth=\"false\" _name=\"cert_https_LE\" keystore=\"JKS\" keystoreFile=\"certs/files/takserver-le.jks\" keystorePass=\"$TAK_CERT_PASS\"#" "$config"
  else
    echo "ERROR: cert_https connector not found in CoreConfig.xml" >&2; exit 1
  fi
'
docker compose --env-file "$ENV_FILE" -f "$ROOT/docker-compose.yml" restart tak
echo "[registry-le] Installed current Let's Encrypt certificate for $LE_FQDN"
