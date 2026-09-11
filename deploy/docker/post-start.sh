#!/usr/bin/env bash
# After compose is up: wait for TAK, ensure enrollment in CoreConfig, promote admin,
# optional Let's Encrypt, copy certs/files into the deploying user's home.
#
# Usage (from deploy/docker/):
#   docker compose --env-file .env up -d --build
#   ./post-start.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

# Avoid interactive-style history expansion if this script is run from a login shell
# (passwords with '!' would otherwise break when expanding ${ADMIN_PASSWORD}).
set +H

if [[ -f .env ]]; then
  # shellcheck disable=SC1091
  set -a
  # shellcheck source=/dev/null
  source .env
  set +a
fi

TAK_CONTAINER="${TAK_CONTAINER:-takserver}"
if [[ -z "${TAK_RELEASE:-}" ]]; then
  echo "[post-start] ERROR: TAK_RELEASE is not set — check .env" >&2
  exit 1
fi
TAK_DIR="${TAK_DIR:-$ROOT/staging/$TAK_RELEASE/tak}"
CERTS_SRC="$TAK_DIR/certs/files"
CONFIG="$TAK_DIR/CoreConfig.xml"
ADMIN_CN="${CERT_ADMIN_CN:-admin}"
CA_CN="${CERT_CA_CN:-TAK-CA-01}"
CERT_PASS="${CERT_PASS:-atakatak}"
ORGANIZATION="${CERT_ORGANIZATION:-TAK}"
ORGANIZATIONAL_UNIT="${CERT_ORGANIZATIONAL_UNIT:-Lab}"
ENABLE_CERT_ENROLLMENT="${ENABLE_CERT_ENROLLMENT:-true}"
ENABLE_STORE_FORWARD_CHAT="${ENABLE_STORE_FORWARD_CHAT:-true}"
ENABLE_FEDERATION="${ENABLE_FEDERATION:-true}"
ENABLE_TLS="${ENABLE_TLS:-true}"
ENABLE_PLAINTEXT_TAK="${ENABLE_PLAINTEXT_TAK:-false}"
ENABLE_SERVICE_ACCOUNT="${ENABLE_SERVICE_ACCOUNT:-true}"
SERVICE_CN="${CERT_SERVICE_CN:-gateway-svc}"
ADMIN_USER="${ADMIN_USER:-${CERT_ADMIN_CN:-admin}}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
LE_ENABLE="${LE_ENABLE:-false}"
LE_FQDN="${LE_FQDN:-}"
FED_WEB_BASE_FQDN="${FED_WEB_BASE_FQDN:-}"
# Empty CERTS_HOME_DIR= in .env must not win over the default
if [[ -z "${CERTS_HOME_DIR:-}" ]]; then
  CERTS_HOME_DIR="$HOME/takserver-certs"
fi
WAIT_TIMEOUT_SEC="${WAIT_TIMEOUT_SEC:-300}"

CONFIG_CHANGED=0

log() { echo "[post-start] $*"; }

restart_tak() {
  log "Restarting TAK..."
  docker compose --env-file .env restart tak 2>/dev/null \
    || docker restart "$TAK_CONTAINER"
}

wait_for_container() {
  local deadline=$((SECONDS + WAIT_TIMEOUT_SEC))
  log "Waiting for container $TAK_CONTAINER to be running..."
  while (( SECONDS < deadline )); do
    if docker inspect -f '{{.State.Running}}' "$TAK_CONTAINER" 2>/dev/null | grep -q true; then
      return 0
    fi
    sleep 2
  done
  log "ERROR: $TAK_CONTAINER not running within ${WAIT_TIMEOUT_SEC}s"
  exit 1
}

wait_for_tak_ready() {
  local deadline=$((SECONDS + WAIT_TIMEOUT_SEC))
  log "Waiting for TAK messaging server to start (up to ${WAIT_TIMEOUT_SEC}s)..."
  while (( SECONDS < deadline )); do
    if docker exec "$TAK_CONTAINER" bash -c \
      "grep -q 'com.bbn.marti.nio.server.NioServer - Server started' /opt/tak/logs/takserver-messaging.log 2>/dev/null \
       || grep -q 'Server started' /logs/takserver-messaging.log 2>/dev/null"; then
      log "TAK messaging reports Server started"
      return 0
    fi
    if docker exec "$TAK_CONTAINER" bash -c "exec 3<>/dev/tcp/127.0.0.1/8443" 2>/dev/null; then
      log "Port 8443 is open — treating as ready"
      return 0
    fi
    sleep 5
  done
  log "WARN: timed out waiting for ready signal — continuing anyway"
}

ensure_enrollment() {
  if [[ "$ENABLE_CERT_ENROLLMENT" != "true" ]]; then
    log "ENABLE_CERT_ENROLLMENT!=true — skipping CoreConfig enrollment block"
    return 0
  fi
  if [[ ! -f "$CERTS_SRC/${CA_CN}-signing.jks" ]]; then
    log "Creating intermediate CA $CA_CN for enrollment..."
    docker exec "$TAK_CONTAINER" bash -c "
      export STATE='${CERT_STATE:-CO}' CITY='${CERT_CITY:-Denver}' \
        ORGANIZATION='${ORGANIZATION}' ORGANIZATIONAL_UNIT='${ORGANIZATIONAL_UNIT}' \
        CAPASS='${CERT_PASS}' PASS='${CERT_PASS}'
      cd /opt/tak/certs && printf 'n\n' | ./makeCert.sh ca '${CA_CN}'
    "
  fi
  if [[ ! -f "$CERTS_SRC/${CA_CN}-signing.jks" ]]; then
    log "WARN: still missing ${CA_CN}-signing.jks — enrollment not wired"
    return 0
  fi
  if [[ ! -f "$CONFIG" ]]; then
    log "ERROR: missing $CONFIG"
    exit 1
  fi
  if grep -qE '<certificateSigning[[:space:]]+CA="TAKServer">' "$CONFIG"; then
    log "CoreConfig already has active certificateSigning"
  else
    log "Adding certificateSigning (CA=$CA_CN) to CoreConfig.xml"
    ENROLL_TMP="$(mktemp)"
    cat > "$ENROLL_TMP" <<EOF
    <certificateSigning CA="TAKServer">
        <certificateConfig>
            <nameEntries>
                <nameEntry name="O" value="${ORGANIZATION}"/>
                <nameEntry name="OU" value="${ORGANIZATIONAL_UNIT}"/>
            </nameEntries>
        </certificateConfig>
        <TAKServerCAConfig keystore="JKS" keystoreFile="certs/files/${CA_CN}-signing.jks" keystorePass="${CERT_PASS}" validityDays="30" signatureAlg="SHA256WithRSA" CAkey="/opt/tak/certs/files/${CA_CN}" CAcertificate="/opt/tak/certs/files/${CA_CN}"/>
    </certificateSigning>
EOF
    {
      head -n -1 "$CONFIG"
      cat "$ENROLL_TMP"
      echo "</Configuration>"
    } > "${CONFIG}.new"
    \mv -f "${CONFIG}.new" "$CONFIG"
    rm -f "$ENROLL_TMP"
    CONFIG_CHANGED=1
  fi
}

# Enrollment / admin certs signed by ${CA_CN} need the intermediate in truststore-root.jks
# or 8089 handshake fails with "peer not verified" (WinTAK sends leaf only).
ensure_issuing_ca_trusted() {
  if [[ ! -f "$CERTS_SRC/${CA_CN}.pem" || ! -f "$CERTS_SRC/truststore-root.jks" ]]; then
    return 0
  fi
  if docker exec "$TAK_CONTAINER" bash -c \
    "keytool -list -keystore /opt/tak/certs/files/truststore-root.jks -storepass '${CERT_PASS}' -alias '${CA_CN}'" \
    >/dev/null 2>&1; then
    log "truststore-root.jks already trusts $CA_CN"
    return 0
  fi
  log "Importing $CA_CN into truststore-root.jks (8089 client auth)"
  docker exec "$TAK_CONTAINER" bash -c "
    keytool -import -trustcacerts -file /opt/tak/certs/files/${CA_CN}.pem \
      -keystore /opt/tak/certs/files/truststore-root.jks -alias '${CA_CN}' \
      -storepass '${CERT_PASS}' -noprompt
    if [[ -f /opt/tak/certs/files/fed-truststore.jks ]]; then
      keytool -import -trustcacerts -file /opt/tak/certs/files/${CA_CN}.pem \
        -keystore /opt/tak/certs/files/fed-truststore.jks -alias '${CA_CN}' \
        -storepass '${CERT_PASS}' -noprompt 2>/dev/null || true
    fi
  "
  CONFIG_CHANGED=1
}

ensure_store_forward_chat() {
  if [[ "$ENABLE_STORE_FORWARD_CHAT" != "true" ]]; then
    log "ENABLE_STORE_FORWARD_CHAT!=true — skipping"
    return 0
  fi
  if [[ ! -f "$CONFIG" ]]; then
    return 0
  fi
  if grep -q 'enableStoreForwardChat="true"' "$CONFIG"; then
    log "Store-and-forward chat already enabled"
    return 0
  fi
  log "Enabling store-and-forward chat in CoreConfig.xml"
  if grep -q 'enableStoreForwardChat=' "$CONFIG"; then
    sed -i -E 's/enableStoreForwardChat="[^"]*"/enableStoreForwardChat="true"/' "$CONFIG"
  elif grep -qE '<queue[[:space:]]*/>' "$CONFIG"; then
    sed -i -E 's|<queue[[:space:]]*/>|<queue enableStoreForwardChat="true"><priority/></queue>|' "$CONFIG"
  elif grep -q '<queue>' "$CONFIG"; then
    sed -i 's/<queue>/<queue enableStoreForwardChat="true">/' "$CONFIG"
  elif grep -qE '<queue[[:space:]]' "$CONFIG"; then
    sed -i -E 's/<queue([[:space:]]+)/<queue enableStoreForwardChat="true"\1/' "$CONFIG"
  else
    log "WARN: no <queue> element — set Store and Forward in the Marti UI"
    return 0
  fi
  CONFIG_CHANGED=1
}

ensure_federation_server() {
  if [[ "$ENABLE_FEDERATION" != "true" ]]; then
    log "ENABLE_FEDERATION!=true — skipping federation server setup"
    return 0
  fi
  if [[ ! -f "$CONFIG" ]]; then
    return 0
  fi
  if ! grep -qE '<federation-server[[:space:]]' "$CONFIG"; then
    if [[ ! -f "$CERTS_SRC/takserver.jks" ]]; then
      log "WARN: takserver.jks missing — cannot enable federation server yet"
      return 0
    fi
    log "Enabling federation server (ports 9000/9001, 8444)..."
    if [[ ! -f "$CERTS_SRC/fed-truststore.jks" && -f "$CERTS_SRC/truststore-root.jks" ]]; then
      cp -f "$CERTS_SRC/truststore-root.jks" "$CERTS_SRC/fed-truststore.jks"
    fi
    FED_TMP="$(mktemp)"
    cat > "$FED_TMP" <<EOF
    <federation enableFederation="true" allowMissionFederation="true" allowDataFeedFederation="true">
      <federation-server port="9000" coreVersion="2" v1enabled="true" v2port="9001" v2enabled="true" webBaseUrl="">
        <tls context="TLSv1.2"
         keymanager="SunX509"
         keystore="JKS" keystoreFile="certs/files/takserver.jks" keystorePass="${CERT_PASS}"
         truststore="JKS" truststoreFile="certs/files/fed-truststore.jks" truststorePass="${CERT_PASS}"/>
      </federation-server>
    </federation>
EOF
    {
      head -n -1 "$CONFIG"
      cat "$FED_TMP"
      echo "</Configuration>"
    } > "${CONFIG}.new"
    \mv -f "${CONFIG}.new" "$CONFIG"
    rm -f "$FED_TMP"
    CONFIG_CHANGED=1
  fi

  # Retrofit: a <federation-server> element existing is not enough — TAK only
  # actually activates federation when enableFederation="true" is set on the
  # parent <federation> tag, and v1enabled/v2enabled/port are set on
  # <federation-server> itself. Deployments set up before this was understood
  # (or where the admin UI toggle was later turned back off) have the element
  # present but inert. Patch the attributes in place so re-running this script
  # fixes it, regardless of how the block originally got there.
  if ! grep -q 'enableFederation="true"' "$CONFIG"; then
    log "Federation block present but not actually enabled — patching attributes"
    if grep -qE '<federation[[:space:]][^>]*enableFederation="[^"]*"' "$CONFIG"; then
      sed -i -E 's/(<federation[[:space:]][^>]*)enableFederation="[^"]*"/\1enableFederation="true"/' "$CONFIG"
    elif grep -q '<federation>' "$CONFIG"; then
      sed -i -E 's/<federation>/<federation enableFederation="true">/' "$CONFIG"
    else
      sed -i -E 's/<federation([[:space:]])/<federation enableFederation="true"\1/' "$CONFIG"
    fi
    CONFIG_CHANGED=1
  fi
  if grep -qE '<federation-server[[:space:]]' "$CONFIG" && ! grep -qE '<federation-server[[:space:]][^>]*v1enabled=' "$CONFIG"; then
    sed -i -E 's/<federation-server([[:space:]])/<federation-server coreVersion="2" v1enabled="true" v2port="9001" v2enabled="true"\1/' "$CONFIG"
    CONFIG_CHANGED=1
  fi
  # NOTE: requires an extra [[:space:]] before "port=" beyond the tag's own
  # mandatory leading space, so it never matches when port="..." is the
  # *first* attribute (as it always is, both here and in init-tak-config.sh's
  # creation block) — that blind spot let this fire on every run and insert
  # a second, duplicate port="9000" attribute, producing invalid XML that
  # TAK Server can't parse (server fails to start). Matching "port=" as
  # either the first attribute or a later one.
  if grep -qE '<federation-server[[:space:]]' "$CONFIG" && ! grep -qE '<federation-server[[:space:]](port=|[^>]*[[:space:]]port=)' "$CONFIG"; then
    sed -i -E 's/<federation-server([[:space:]])/<federation-server port="9000"\1/' "$CONFIG"
    CONFIG_CHANGED=1
  fi
}

ensure_tls_mode() {
  if [[ ! -f "$CONFIG" ]]; then
    return 0
  fi
  # ENABLE_TLS and ENABLE_PLAINTEXT_TAK are independent — both <input>
  # lines can exist at once (e.g. normal clients on 8089, a test client on
  # 8087 for a Wireshark capture). Each just adds/removes its own line.
  #
  # The plaintext input must be protocol="stcp" (streaming, bidirectional),
  # not protocol="tcp". Plain "tcp" is publish-only in TAK Server —
  # clients can submit CoT (so it still shows up in WebTAK/the DB) but the
  # server never creates a Subscription for them, so they never receive
  # anything back and never see each other. "stcp" is the documented
  # unencrypted equivalent of the TLS streaming input. See TAK Server
  # Configuration Guide §9.1/9.3.
  #
  # Matched by _name="..." only (not full attribute order): TAK Server
  # rewrites CoreConfig.xml on boot and reorders attributes, which breaks
  # an exact-string match on later runs. Anchored to the whole line so it
  # can't touch the vendor template's commented-out example <input> lines.
  local tls_re='^[[:space:]]*<input[^>]*_name="stdssl"[^>]*/>[[:space:]]*$'
  local plaintext_re='^[[:space:]]*<input[^>]*_name="streamtcp"[^>]*/>[[:space:]]*$'
  local network_open_re='(<network[^>]*>)'

  if [[ "$ENABLE_TLS" == "true" ]]; then
    if ! grep -qE "$tls_re" "$CONFIG"; then
      log "ENABLE_TLS=true — adding TLS CoT input (8089)"
      sed -i -E "s#${network_open_re}#\1\n        <input _name=\"stdssl\" protocol=\"tls\" port=\"8089\" coreVersion=\"2\"/>#" "$CONFIG"
      CONFIG_CHANGED=1
    fi
  else
    if grep -qE "$tls_re" "$CONFIG"; then
      log "ENABLE_TLS=false — removing TLS CoT input (8089)"
      sed -i -E "\\#${tls_re}#d" "$CONFIG"
      CONFIG_CHANGED=1
    fi
  fi

  if [[ "$ENABLE_PLAINTEXT_TAK" == "true" ]]; then
    if ! grep -qE "$plaintext_re" "$CONFIG"; then
      log "ENABLE_PLAINTEXT_TAK=true — adding plaintext streaming CoT input (8087, for Wireshark captures)"
      sed -i -E "s#${network_open_re}#\1\n        <input _name=\"streamtcp\" protocol=\"stcp\" port=\"8087\" auth=\"anonymous\"/>#" "$CONFIG"
      CONFIG_CHANGED=1
    fi
  else
    if grep -qE "$plaintext_re" "$CONFIG"; then
      log "ENABLE_PLAINTEXT_TAK=false — removing plaintext streaming CoT input (8087)"
      sed -i -E "\\#${plaintext_re}#d" "$CONFIG"
      CONFIG_CHANGED=1
    fi
  fi

  if [[ "$ENABLE_TLS" != "true" && "$ENABLE_PLAINTEXT_TAK" != "true" ]]; then
    log "WARN: both ENABLE_TLS and ENABLE_PLAINTEXT_TAK are false — no CoT input is configured"
  fi
}

ensure_federation_web_base_url() {
  local fqdn="${FED_WEB_BASE_FQDN:-${LE_FQDN:-}}"
  if [[ -z "$fqdn" ]]; then
    log "LE_FQDN/FED_WEB_BASE_FQDN not set — skipping federation webBaseUrl patch"
    return 0
  fi
  if [[ ! -f "$CONFIG" ]]; then
    log "WARN: missing $CONFIG — cannot set federation webBaseUrl"
    return 0
  fi
  if ! grep -q 'webBaseUrl=' "$CONFIG"; then
    log "WARN: no webBaseUrl in CoreConfig — skipping federation webBaseUrl patch"
    return 0
  fi
  local expected="https://${fqdn}:8443/Marti"
  if grep -q "webBaseUrl=\"${expected}\"" "$CONFIG"; then
    log "Federation webBaseUrl already set to $expected"
    return 0
  fi
  log "Setting federation webBaseUrl -> $expected"
  sed -i -E "s|webBaseUrl=\"[^\"]*\"|webBaseUrl=\"${expected}\"|" "$CONFIG"
  CONFIG_CHANGED=1
}

verify_coreconfig_features() {
  local missing=0
  if [[ "$ENABLE_CERT_ENROLLMENT" == "true" ]]; then
    if grep -qE '<certificateSigning[[:space:]]+CA="TAKServer">' "$CONFIG"; then
      log "Verified certificate enrollment in CoreConfig"
    else
      log "ERROR: certificate enrollment block missing from CoreConfig"
      missing=1
    fi
  fi
  if [[ "$ENABLE_STORE_FORWARD_CHAT" == "true" ]]; then
    if grep -q 'enableStoreForwardChat="true"' "$CONFIG"; then
      log "Verified store-and-forward chat in CoreConfig"
    else
      log "ERROR: enableStoreForwardChat=\"true\" missing from CoreConfig"
      missing=1
    fi
  fi
  if [[ "$ENABLE_FEDERATION" == "true" ]]; then
    if grep -qE '<federation-server[[:space:]]' "$CONFIG" && grep -q 'enableFederation="true"' "$CONFIG"; then
      log "Verified federation server is present AND actually enabled in CoreConfig"
    elif grep -qE '<federation-server[[:space:]]' "$CONFIG"; then
      log "ERROR: <federation-server> present but enableFederation=\"true\" missing — federation is inert"
      missing=1
    else
      log "ERROR: <federation-server> missing from CoreConfig"
      missing=1
    fi
  fi
  # ENABLE_TLS and ENABLE_PLAINTEXT_TAK are independent, so check each
  # <input>'s presence/absence separately. Anchored to the whole line (not
  # just a substring) so this can't match one of the vendor template's
  # commented-out example <input> lines.
  if [[ "$ENABLE_TLS" == "true" ]]; then
    if grep -qE '^[[:space:]]*<input[^>]*_name="stdssl"[^>]*/>[[:space:]]*$' "$CONFIG"; then
      log "Verified CoT input is TLS (8089)"
    else
      log "ERROR: expected TLS CoT <input> (stdssl/8089) not found in CoreConfig"
      missing=1
    fi
  fi
  if [[ "$ENABLE_PLAINTEXT_TAK" == "true" ]]; then
    if grep -qE '^[[:space:]]*<input[^>]*_name="streamtcp"[^>]*/>[[:space:]]*$' "$CONFIG"; then
      log "Verified CoT input is plaintext streaming (8087) — ENABLE_PLAINTEXT_TAK=true"
    else
      log "ERROR: expected plaintext streaming CoT <input> (streamtcp/8087) not found in CoreConfig"
      missing=1
    fi
  fi
  if [[ "$ENABLE_SERVICE_ACCOUNT" == "true" ]]; then
    if docker exec "$TAK_CONTAINER" test -f "/opt/tak/certs/files/${SERVICE_CN}.p12"; then
      log "Verified service account certificate present ($SERVICE_CN)"
    else
      log "ERROR: service account certificate missing ($SERVICE_CN)"
      missing=1
    fi
  fi
  if [[ "$missing" -ne 0 ]]; then
    exit 1
  fi
}

promote_admin() {
  local pem="certs/files/admin.pem"
  if ! docker exec "$TAK_CONTAINER" test -f "/opt/tak/$pem"; then
    if docker exec "$TAK_CONTAINER" test -f "/opt/tak/certs/files/${ADMIN_CN}.pem"; then
      pem="certs/files/${ADMIN_CN}.pem"
    else
      log "ERROR: admin.pem not found in container"
      exit 1
    fi
  fi
  log "Promoting admin certificate ($pem)..."
  local deadline=$((SECONDS + WAIT_TIMEOUT_SEC))
  until docker exec "$TAK_CONTAINER" bash -c \
    "cd /opt/tak && java -jar utils/UserManager.jar certmod -A $pem" >/tmp/tak-certmod.out 2>&1; do
    if (( SECONDS >= deadline )); then
      log "ERROR: admin promote failed within ${WAIT_TIMEOUT_SEC}s"
      cat /tmp/tak-certmod.out 2>/dev/null || true
      exit 1
    fi
    log "UserManager not ready yet — retrying in 5s..."
    sleep 5
  done
  # Show success lines only
  grep -E 'New User Added|Username:|ROLE_ADMIN|Already' /tmp/tak-certmod.out 2>/dev/null || true
  log "Admin certificate promoted"
}

# Non-interactive client identity for code talking to TAK Server directly
# (Marti REST API on 8443, or mTLS on the CoT stream on 8089) — separate
# from the human `admin` cert above so a service credential can be rotated
# or revoked without touching anyone's personal login. The cert itself is
# generated in init-tak-config.sh (idempotent, no DB needed); promoting it
# to ROLE_ADMIN happens here because UserManager.jar needs the database up,
# same reason promote_admin() retries against it above.
ensure_service_account() {
  if [[ "$ENABLE_SERVICE_ACCOUNT" != "true" ]]; then
    log "ENABLE_SERVICE_ACCOUNT!=true — skipping service account"
    return 0
  fi
  local pem="certs/files/${SERVICE_CN}.pem"
  if ! docker exec "$TAK_CONTAINER" test -f "/opt/tak/$pem"; then
    log "Service account certificate ($SERVICE_CN) not found — generating..."
    docker exec "$TAK_CONTAINER" bash -c "cd /opt/tak/certs && ./makeCert.sh client '${SERVICE_CN}'"
  fi
  if ! docker exec "$TAK_CONTAINER" test -f "/opt/tak/$pem"; then
    log "ERROR: failed to create service account certificate ($SERVICE_CN)"
    exit 1
  fi
  log "Promoting service account certificate ($pem) to ROLE_ADMIN..."
  local deadline=$((SECONDS + WAIT_TIMEOUT_SEC))
  until docker exec "$TAK_CONTAINER" bash -c \
    "cd /opt/tak && java -jar utils/UserManager.jar certmod -A $pem" >/tmp/tak-certmod-svc.out 2>&1; do
    if (( SECONDS >= deadline )); then
      log "ERROR: service account promote failed within ${WAIT_TIMEOUT_SEC}s"
      cat /tmp/tak-certmod-svc.out 2>/dev/null || true
      exit 1
    fi
    log "UserManager not ready yet — retrying in 5s..."
    sleep 5
  done
  grep -E 'New User Added|Username:|ROLE_ADMIN|Already' /tmp/tak-certmod-svc.out 2>/dev/null || true
  log "Service account certificate promoted ($SERVICE_CN)"
}

set_admin_password() {
  if [[ -z "${ADMIN_PASSWORD}" ]]; then
    log "ADMIN_PASSWORD not set — skipping username/password admin (8446 File auth)"
    return 0
  fi
  log "Setting password for File-auth user '${ADMIN_USER}' (8446 login)..."
  local deadline=$((SECONDS + WAIT_TIMEOUT_SEC))
  # Pass secrets via env into the container so '!' / '$' / quotes are not re-parsed by the shell
  until docker exec \
    -e "TAK_ADMIN_USER=${ADMIN_USER}" \
    -e "TAK_ADMIN_PASSWORD=${ADMIN_PASSWORD}" \
    "$TAK_CONTAINER" bash -c \
    'cd /opt/tak && java -jar utils/UserManager.jar usermod -A -p "$TAK_ADMIN_PASSWORD" "$TAK_ADMIN_USER"' \
    >/tmp/tak-usermod.out 2>&1; do
    if (( SECONDS >= deadline )); then
      log "ERROR: usermod failed within ${WAIT_TIMEOUT_SEC}s"
      cat /tmp/tak-usermod.out 2>/dev/null || true
      exit 1
    fi
    log "UserManager not ready for usermod — retrying in 5s..."
    sleep 5
  done
  grep -E 'Username:|ROLE_ADMIN|password|Updated|Added' /tmp/tak-usermod.out 2>/dev/null || true
  log "Admin password set for user '${ADMIN_USER}' (use on :8446)"
}

apply_letsencrypt_if_enabled() {
  if [[ "$LE_ENABLE" != "true" ]]; then
    log "LE_ENABLE is not true — skipping Let's Encrypt"
    return 0
  fi
  log "Running apply-letsencrypt.sh..."
  chmod +x "$ROOT/apply-letsencrypt.sh"
  "$ROOT/apply-letsencrypt.sh"
}

copy_certs_home() {
  if [[ ! -d "$CERTS_SRC" ]]; then
    log "ERROR: certs source missing: $CERTS_SRC"
    exit 1
  fi
  local dest="$CERTS_HOME_DIR"
  if [[ -z "$dest" || "$dest" == "$HOME" || "$dest" == "/" ]]; then
    dest="$HOME/takserver-certs"
  fi
  # Private keys / p12s are often mode 400 root:root from openssl/makeCert in Docker
  log "Fixing ownership on $CERTS_SRC"
  sudo chown -R "$(id -u):$(id -g)" "$CERTS_SRC"
  sudo chmod -R u+rwX,go+rX "$CERTS_SRC" 2>/dev/null || true
  find "$CERTS_SRC" -type f \( -name '*.key' -o -name '*-do-not-share*' \) \
    -exec chmod 600 {} \; 2>/dev/null || true

  log "Copying $CERTS_SRC -> $dest"
  mkdir -p "$dest"
  # Use sudo so nothing is skipped if ownership races with the container
  if command -v rsync >/dev/null; then
    sudo rsync -a "$CERTS_SRC/" "$dest/"
  else
    sudo cp -a "$CERTS_SRC/." "$dest/"
  fi
  sudo chown -R "$(id -u):$(id -g)" "$dest"
  if [[ ! -f "$dest/admin.p12" ]]; then
    log "ERROR: admin.p12 missing after copy — check $CERTS_SRC"
    ls -la "$CERTS_SRC"/admin.p12 "$CERTS_SRC"/*.p12 2>/dev/null || true
    exit 1
  fi
  log "Certs ready at: $dest (admin.p12 present)"
  log "  Import admin.p12 into your browser (password: ${CERT_PASS})"
  log "  Admin UI (mTLS): https://<host>:8443/Marti/"
  if [[ -n "${ADMIN_PASSWORD}" ]]; then
    log "  Admin login (password): https://<host>:8446  user=${ADMIN_USER}"
  fi
  if [[ "$LE_ENABLE" == "true" && -n "${LE_FQDN:-}" ]]; then
    log "  Public/enrollment: https://${LE_FQDN}:8446"
  fi
  if [[ "$ENABLE_SERVICE_ACCOUNT" == "true" && -f "$dest/${SERVICE_CN}.p12" ]]; then
    log "  Service/API account (ROLE_ADMIN, mTLS): $dest/${SERVICE_CN}.p12 (password: ${CERT_PASS})"
    log "    Marti REST API: https://<host>:8443/Marti/  |  CoT stream: <host>:8089"
  fi
}

# --- main ---
wait_for_container
# Let's Encrypt runs first because apply-letsencrypt.sh does its own
# unconditional `docker compose restart tak`, independent of this script's
# CONFIG_CHANGED-triggered restart below. TAK Server re-normalizes
# CoreConfig.xml on every boot and silently drops attributes it doesn't
# recognize as "set" (observed with <federation>'s enableFederation="true"
# and <federation-server>'s port/v1enabled/v2enabled) — so if LE's restart
# ran *after* the retrofit checks below, whatever it stripped would never
# get re-patched before verify_coreconfig_features checks it at the end.
# Running LE first means its restart lands before the retrofits, which
# always run and always re-patch (and restart again) if anything's missing.
apply_letsencrypt_if_enabled
wait_for_container
ensure_enrollment
ensure_issuing_ca_trusted
ensure_store_forward_chat
ensure_federation_server
ensure_federation_web_base_url
ensure_tls_mode
if [[ "$CONFIG_CHANGED" -eq 1 ]]; then
  restart_tak
  sleep 5
  wait_for_container
fi
wait_for_tak_ready
promote_admin
ensure_service_account
set_admin_password
copy_certs_home
verify_coreconfig_features
log "Done."
