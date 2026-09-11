#!/usr/bin/env bash
# Obtain a Let's Encrypt cert (host certbot) and wire it into TAK CoreConfig
# for the password/enrollment HTTPS connector (8446), same approach as installTAK.
#
# Prerequisites:
#   - Public DNS A/AAAA for LE_FQDN pointing at this host
#   - Port 80 reachable from the internet (certbot standalone)
#   - TAK stack already running (or at least tak/ tree prepared)
#   - certbot + openssl installed on the host
#
# Usage (from deploy/docker/):
#   cp env.example .env   # set LE_ENABLE=true LE_FQDN=... LE_EMAIL=...
#   ./apply-letsencrypt.sh
#   # renewals: certbot renew uses renew-tak-le.sh deploy-hook
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

if [[ -f .env ]]; then
  # shellcheck disable=SC1091
  set -a
  # shellcheck source=/dev/null
  source .env
  set +a
fi

LE_ENABLE="${LE_ENABLE:-false}"
LE_FQDN="${LE_FQDN:-}"
LE_EMAIL="${LE_EMAIL:-}"
CERT_PASS="${CERT_PASS:-atakatak}"
TAK_CONTAINER="${TAK_CONTAINER:-takserver}"
if [[ -z "${TAK_RELEASE:-}" ]]; then
  echo "ERROR: TAK_RELEASE is not set — check .env" >&2
  exit 1
fi
TAK_DIR="${TAK_DIR:-$ROOT/staging/$TAK_RELEASE/tak}"
CERTS="$TAK_DIR/certs/files"
CONFIG="$TAK_DIR/CoreConfig.xml"
LEdir="/etc/letsencrypt"
JKS_NAME="takserver-le.jks"
P12_NAME="takserver-le.p12"

if [[ "$LE_ENABLE" != "true" && "${1:-}" != "--force" ]]; then
  echo "LE_ENABLE is not true in .env — set LE_ENABLE=true LE_FQDN=... LE_EMAIL=... or pass --force"
  exit 1
fi

if [[ -z "$LE_FQDN" || -z "$LE_EMAIL" ]]; then
  echo "ERROR: LE_FQDN and LE_EMAIL must be set in .env"
  exit 1
fi

if [[ ! -f "$CONFIG" ]]; then
  echo "ERROR: missing $CONFIG — run compose init / setup first"
  exit 1
fi

if ! command -v certbot >/dev/null; then
  echo "Installing certbot..."
  if command -v apt-get >/dev/null; then
    sudo apt-get update -qq && sudo apt-get install -y certbot
  else
    echo "Install certbot manually, then re-run."
    exit 1
  fi
fi

command -v openssl >/dev/null || { echo "openssl required"; exit 1; }

echo "[le] Requesting certificate for $LE_FQDN (standalone — needs port 80 free)..."
sudo certbot certonly \
  -d "$LE_FQDN" \
  -m "$LE_EMAIL" \
  --standalone \
  --agree-tos \
  --no-eff-email \
  --non-interactive

LIVE="$LEdir/live/$LE_FQDN"
# live/ is root-only (0700); non-root -f checks fail even when certs exist
if ! sudo test -f "$LIVE/fullchain.pem" || ! sudo test -f "$LIVE/privkey.pem"; then
  echo "ERROR: expected PEMs under $LIVE"
  sudo ls -la "$LEdir/live/$LE_FQDN" 2>/dev/null || sudo ls -la "$LEdir/live" 2>/dev/null || true
  exit 1
fi

mkdir -p "$CERTS"
echo "[le] Building $P12_NAME / $JKS_NAME in $CERTS ..."

# Prefer host openssl + container keytool (temurin image has keytool)
sudo openssl pkcs12 -export \
  -in "$LIVE/fullchain.pem" \
  -inkey "$LIVE/privkey.pem" \
  -out "$CERTS/$P12_NAME" \
  -name "$LE_FQDN" \
  -passout "pass:${CERT_PASS}"
sudo chown "$(id -u):$(id -g)" "$CERTS/$P12_NAME"

# keytool may need to overwrite existing. $CERTS is typically root-owned —
# the init container (which runs as root) created it when it generated the
# original certs — so both this and the keytool call below need sudo, same
# as the openssl call above; the chown afterward hands it back to the
# invoking user.
sudo rm -f "$CERTS/$JKS_NAME"
if command -v keytool >/dev/null; then
  sudo keytool -importkeystore \
    -destkeystore "$CERTS/$JKS_NAME" \
    -srckeystore "$CERTS/$P12_NAME" \
    -srcstoretype pkcs12 \
    -deststorepass "$CERT_PASS" \
    -destkeypass "$CERT_PASS" \
    -srcstorepass "$CERT_PASS" \
    -noprompt
else
  docker exec "$TAK_CONTAINER" bash -c \
    "keytool -importkeystore -destkeystore /opt/tak/certs/files/$JKS_NAME \
      -srckeystore /opt/tak/certs/files/$P12_NAME -srcstoretype pkcs12 \
      -deststorepass '$CERT_PASS' -destkeypass '$CERT_PASS' -srcstorepass '$CERT_PASS' -noprompt"
fi
# Ensure JKS is readable by compose/user if created via docker as root
if [[ -f "$CERTS/$JKS_NAME" ]]; then
  sudo chown "$(id -u):$(id -g)" "$CERTS/$JKS_NAME" 2>/dev/null || true
fi

# Wire 8446 connector to LE keystore (installTAK pattern). Keep 8443 on TAK CA + client auth.
if grep -q 'cert_https_LE' "$CONFIG"; then
  echo "[le] CoreConfig already has cert_https_LE — updating keystore path/pass"
  sed -i -E "s#keystoreFile=\"certs/files/[^\"]*-le\.jks\"#keystoreFile=\"certs/files/${JKS_NAME}\"#" "$CONFIG"
  sed -i -E "s#(cert_https_LE[^>]*keystorePass=\")[^\"]*(\")#\1${CERT_PASS}\2#" "$CONFIG"
elif grep -q '_name="cert_https"' "$CONFIG"; then
  echo "[le] Patching CoreConfig.xml connector 8446 -> LE keystore"
  sed -i "s#connector port=\"8446\" clientAuth=\"false\" _name=\"cert_https\"#connector port=\"8446\" clientAuth=\"false\" _name=\"cert_https_LE\" keystore=\"JKS\" keystoreFile=\"certs/files/${JKS_NAME}\" keystorePass=\"${CERT_PASS}\"#" "$CONFIG"
else
  echo "[le] WARN: could not find cert_https connector — add manually:"
  echo "  <connector port=\"8446\" clientAuth=\"false\" _name=\"cert_https_LE\" keystore=\"JKS\" keystoreFile=\"certs/files/${JKS_NAME}\" keystorePass=\"${CERT_PASS}\"/>"
fi

# Deploy-hook script for renewals (paths absolute for cron)
RENEW="$ROOT/renew-tak-le.sh"
cat > "$RENEW" <<EOF
#!/usr/bin/env bash
set -euo pipefail
ROOT="$ROOT"
TAK_DIR="$TAK_DIR"
CERTS="\$TAK_DIR/certs/files"
LIVE="$LIVE"
CERT_PASS="$CERT_PASS"
JKS_NAME="$JKS_NAME"
P12_NAME="$P12_NAME"
LE_FQDN="$LE_FQDN"
TAK_CONTAINER="$TAK_CONTAINER"

sudo openssl pkcs12 -export \\
  -in "\$LIVE/fullchain.pem" \\
  -inkey "\$LIVE/privkey.pem" \\
  -out "\$CERTS/\$P12_NAME" \\
  -name "\$LE_FQDN" \\
  -passout "pass:\${CERT_PASS}"
sudo chown "\$(id -u):\$(id -g)" "\$CERTS/\$P12_NAME"

# \$CERTS is root-owned (the init container runs as root) — sudo needed to
# create/replace files there, same as apply-letsencrypt.sh's first run.
sudo rm -f "\$CERTS/\$JKS_NAME"
if command -v keytool >/dev/null; then
  sudo keytool -importkeystore \\
    -destkeystore "\$CERTS/\$JKS_NAME" \\
    -srckeystore "\$CERTS/\$P12_NAME" \\
    -srcstoretype pkcs12 \\
    -deststorepass "\$CERT_PASS" \\
    -destkeypass "\$CERT_PASS" \\
    -srcstorepass "\$CERT_PASS" \\
    -noprompt
else
  docker exec "\$TAK_CONTAINER" bash -c \\
    "keytool -importkeystore -destkeystore /opt/tak/certs/files/\$JKS_NAME \\
      -srckeystore /opt/tak/certs/files/\$P12_NAME -srcstoretype pkcs12 \\
      -deststorepass '\$CERT_PASS' -destkeypass '\$CERT_PASS' -srcstorepass '\$CERT_PASS' -noprompt"
fi
if [[ -f "\$CERTS/\$JKS_NAME" ]]; then
  sudo chown "\$(id -u):\$(id -g)" "\$CERTS/\$JKS_NAME" 2>/dev/null || true
fi

cd "\$ROOT"
docker compose --env-file .env restart tak || docker restart "\$TAK_CONTAINER"
EOF
chmod +x "$RENEW"

# Install cron deploy-hook if possible
if [[ -f /etc/cron.d/certbot ]]; then
  if ! grep -q renew-tak-le /etc/cron.d/certbot 2>/dev/null; then
    echo "[le] Adding deploy-hook to /etc/cron.d/certbot (requires sudo)"
    sudo sed -i "s#certbot -q renew#certbot -q renew --deploy-hook $RENEW#g" /etc/cron.d/certbot || true
  fi
else
  CRON_FILE="$ROOT/certbot-tak-le.cron"
  cat > "$CRON_FILE" <<EOF
SHELL=/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
0 */12 * * * root certbot -q renew --deploy-hook $RENEW
EOF
  echo "[le] Wrote $CRON_FILE — install with:"
  echo "  sudo cp $CRON_FILE /etc/cron.d/certbot-tak-le && sudo chmod 644 /etc/cron.d/certbot-tak-le"
fi

echo "[le] Restarting TAK to apply LE keystore on 8446..."
docker compose --env-file .env restart tak 2>/dev/null \
  || docker restart "$TAK_CONTAINER"

echo
echo "Let's Encrypt applied."
echo "  Public HTTPS (no client cert):  https://${LE_FQDN}:8446"
echo "  Admin mTLS (TAK CA):            https://${LE_FQDN}:8443  (still needs admin.p12)"
echo "  ATAK/WinTAK SSL:                ${LE_FQDN}:8089         (still TAK CA)"
echo
echo "Renewal hook: $RENEW"
