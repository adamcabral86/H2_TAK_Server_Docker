#!/usr/bin/env bash
# Request a public certificate for :8446, then import it into the named TAK volume.
set -euo pipefail

SCRIPT_ROOT="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_ROOT/.." && pwd)"
ENV_FILE="$ROOT/.env"
set -a
source "$ENV_FILE"
set +a

if [[ "${LE_ENABLE:-false}" != "true" && "${1:-}" != "--force" ]]; then
  echo "LE_ENABLE is not true; set it in $ENV_FILE or pass --force" >&2
  exit 1
fi
: "${LE_FQDN:?LE_FQDN must be set in $ENV_FILE}"
: "${LE_EMAIL:?LE_EMAIL must be set in $ENV_FILE}"

if ! command -v certbot >/dev/null; then
  echo "Installing certbot..."
  sudo apt-get update -qq && sudo apt-get install -y certbot
fi

echo "[tak-le] Requesting certificate for $LE_FQDN (TCP 80 must be publicly reachable)..."
sudo certbot certonly --standalone -d "$LE_FQDN" -m "$LE_EMAIL" \
  --agree-tos --no-eff-email --non-interactive
bash "$SCRIPT_ROOT/renew-letsencrypt.sh"

# Certbot's packaged timer normally renews twice daily. Install a separate
# deploy-hook schedule so a renewed certificate is also imported into TAK's
# named volume. This never requests a certificate unless renewal is due.
CRON_FILE="/etc/cron.d/certbot-tak-docker"
printf '%s\n' \
  'SHELL=/bin/sh' \
  'PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin' \
  "0 */12 * * * root certbot -q renew --deploy-hook $SCRIPT_ROOT/renew-letsencrypt.sh" \
  | sudo tee "$CRON_FILE" >/dev/null
sudo chmod 644 "$CRON_FILE"
echo "[tak-le] Renewal deploy hook installed at $CRON_FILE"
