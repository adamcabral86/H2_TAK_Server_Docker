#!/usr/bin/env bash
# Runs once (or when volumes are empty) to create certs and CoreConfig
# from environment variables. Intended as a Compose "init" service.
set -euo pipefail

TAK_ROOT="${TAK_ROOT:-/opt/tak}"
CERTS="$TAK_ROOT/certs"
FILES="$CERTS/files"

export STATE="${CERT_STATE:-CO}"
export CITY="${CERT_CITY:-Denver}"
export ORGANIZATION="${CERT_ORGANIZATION:-TAK}"
export ORGANIZATIONAL_UNIT="${CERT_ORGANIZATIONAL_UNIT:-Lab}"
export COUNTRY="${CERT_COUNTRY:-US}"
export CAPASS="${CERT_PASS:-atakatak}"
export PASS="${CERT_PASS:-atakatak}"

SERVER_CN="${CERT_SERVER_CN:-takserver}"
ADMIN_CN="${CERT_ADMIN_CN:-admin}"
CA_CN="${CERT_CA_CN:-TAK-CA-01}"
DB_PASS="${DB_PASS:-TakDbPass123}"
CERT_PASS="${CERT_PASS:-atakatak}"
ENABLE_CERT_ENROLLMENT="${ENABLE_CERT_ENROLLMENT:-true}"
ENABLE_STORE_FORWARD_CHAT="${ENABLE_STORE_FORWARD_CHAT:-true}"
ENABLE_FEDERATION="${ENABLE_FEDERATION:-true}"
ENABLE_TLS="${ENABLE_TLS:-true}"
ENABLE_PLAINTEXT_TAK="${ENABLE_PLAINTEXT_TAK:-false}"

echo "[init] TAK_ROOT=$TAK_ROOT"

cd "$CERTS"
chmod +x *.sh 2>/dev/null || true

if [[ ! -f "$FILES/takserver.jks" ]]; then
  echo "[init] Generating certificates (server=$SERVER_CN admin=$ADMIN_CN ca=$CA_CN)..."
  # makeRootCa prompts for CA name when run interactively; supply via --ca-name
  ./makeRootCa.sh --ca-name "root-${CA_CN}"
  # Intermediate issuing CA (creates ${CA_CN}-signing.jks for enrollment)
  printf 'n\n' | ./makeCert.sh ca "$CA_CN"
  ./makeCert.sh server "$SERVER_CN"
  # makeCert names server files from CN; TAK expects takserver.jks — copy if needed
  if [[ ! -f "$FILES/takserver.jks" && -f "$FILES/${SERVER_CN}.jks" ]]; then
    cp -f "$FILES/${SERVER_CN}.jks" "$FILES/takserver.jks"
  fi
  ./makeCert.sh client "$ADMIN_CN"
  if [[ ! -f "$FILES/admin.pem" && -f "$FILES/${ADMIN_CN}.pem" ]]; then
    cp -f "$FILES/${ADMIN_CN}.pem" "$FILES/admin.pem"
  fi
  if [[ ! -f "$FILES/admin.p12" && -f "$FILES/${ADMIN_CN}.p12" ]]; then
    cp -f "$FILES/${ADMIN_CN}.p12" "$FILES/admin.p12"
  fi
else
  echo "[init] Certificates already exist — skipping generation"
  # Ensure intermediate signing keystore exists (needed for enrollment)
  if [[ ! -f "$FILES/${CA_CN}-signing.jks" ]]; then
    echo "[init] Creating intermediate CA $CA_CN for certificate enrollment..."
    printf 'n\n' | ./makeCert.sh ca "$CA_CN"
  fi
fi

# Enrollment clients are signed by ${CA_CN}; WinTAK often sends only the leaf cert,
# so the server truststore must contain the intermediate (not only the root).
ensure_issuing_ca_in_truststore() {
  local pem="$FILES/${CA_CN}.pem"
  local jks="$FILES/truststore-root.jks"
  if [[ ! -f "$pem" || ! -f "$jks" ]]; then
    return 0
  fi
  if keytool -list -keystore "$jks" -storepass "$CERT_PASS" -alias "$CA_CN" >/dev/null 2>&1; then
    echo "[init] truststore-root.jks already trusts $CA_CN"
    return 0
  fi
  echo "[init] Importing $CA_CN into truststore-root.jks (fixes 8089 peer not verified)"
  keytool -import -trustcacerts -file "$pem" -keystore "$jks" \
    -alias "$CA_CN" -storepass "$CERT_PASS" -noprompt
  if [[ -f "$FILES/fed-truststore.jks" ]]; then
    keytool -import -trustcacerts -file "$pem" -keystore "$FILES/fed-truststore.jks" \
      -alias "$CA_CN" -storepass "$CERT_PASS" -noprompt 2>/dev/null || true
  fi
}
ensure_issuing_ca_in_truststore

if [[ ! -f "$TAK_ROOT/CoreConfig.xml" ]]; then
  echo "[init] Writing CoreConfig.xml..."
  cp "$TAK_ROOT/CoreConfig.example.xml" "$TAK_ROOT/CoreConfig.xml"
fi

# Always refresh DB password from env (idempotent)
if grep -q 'password="' "$TAK_ROOT/CoreConfig.xml"; then
  sed -i -E "s/(<connection[^>]*password=\")[^\"]*(\")/\1${DB_PASS}\2/" "$TAK_ROOT/CoreConfig.xml"
fi
# Ensure keystore passwords match CERT_PASS
sed -i -E "s/keystorePass=\"[^\"]*\"/keystorePass=\"${CERT_PASS}\"/" "$TAK_ROOT/CoreConfig.xml" || true
sed -i -E "s/truststorePass=\"[^\"]*\"/truststorePass=\"${CERT_PASS}\"/" "$TAK_ROOT/CoreConfig.xml" || true

# Ensure JDBC host is the compose service alias
sed -i -E 's#jdbc:postgresql://[^:/]+:5432/cot#jdbc:postgresql://tak-database:5432/cot#' \
  "$TAK_ROOT/CoreConfig.xml"

# CoT inputs: TLS (stdssl/8089) and/or plaintext streaming (streamtcp/8087).
# ENABLE_TLS and ENABLE_PLAINTEXT_TAK are independent — both can be on at
# once (e.g. normal clients on 8089, a test client on 8087 for a Wireshark
# capture) — each just adds/removes its own <input> line. Always applied
# so re-running with a changed .env converges an existing CoreConfig.xml
# to match. Web UI (8443/8444/8446) is unaffected either way.
#
# The plaintext input must be protocol="stcp" (streaming, bidirectional),
# not protocol="tcp". Plain "tcp" is publish-only in TAK Server — it
# accepts and stores CoT (so it still shows up in WebTAK/the DB) but never
# creates a Subscription, so connected clients never receive anything back
# and never see each other. "stcp" is the documented unencrypted
# equivalent of the TLS streaming input. See TAK Server Configuration
# Guide §9.1/9.3.
#
# Matched by _name="..." only (not full attribute order): TAK Server
# rewrites CoreConfig.xml on boot and reorders attributes (observed
# "auth=... _name=streamtcp protocol=... port=..." instead of the order
# this script writes), which would break an exact-string match on later
# runs. Anchored to the whole line so it can't touch the vendor template's
# commented-out example <input> lines elsewhere in the file.
TLS_INPUT_RE='^[[:space:]]*<input[^>]*_name="stdssl"[^>]*/>[[:space:]]*$'
PLAINTEXT_INPUT_RE='^[[:space:]]*<input[^>]*_name="streamtcp"[^>]*/>[[:space:]]*$'
NETWORK_OPEN_RE='(<network[^>]*>)'

if [[ "$ENABLE_TLS" == "true" ]]; then
  if ! grep -qE "$TLS_INPUT_RE" "$TAK_ROOT/CoreConfig.xml"; then
    echo "[init] ENABLE_TLS=true — adding TLS CoT input (8089)"
    sed -i -E "s#${NETWORK_OPEN_RE}#\1\n        <input _name=\"stdssl\" protocol=\"tls\" port=\"8089\" coreVersion=\"2\"/>#" \
      "$TAK_ROOT/CoreConfig.xml"
  fi
else
  if grep -qE "$TLS_INPUT_RE" "$TAK_ROOT/CoreConfig.xml"; then
    echo "[init] ENABLE_TLS=false — removing TLS CoT input (8089)"
    sed -i -E "\\#${TLS_INPUT_RE}#d" "$TAK_ROOT/CoreConfig.xml"
  fi
fi

if [[ "$ENABLE_PLAINTEXT_TAK" == "true" ]]; then
  if ! grep -qE "$PLAINTEXT_INPUT_RE" "$TAK_ROOT/CoreConfig.xml"; then
    echo "[init] ENABLE_PLAINTEXT_TAK=true — adding plaintext streaming CoT input (8087, for Wireshark captures)"
    sed -i -E "s#${NETWORK_OPEN_RE}#\1\n        <input _name=\"streamtcp\" protocol=\"stcp\" port=\"8087\" auth=\"anonymous\"/>#" \
      "$TAK_ROOT/CoreConfig.xml"
  fi
else
  if grep -qE "$PLAINTEXT_INPUT_RE" "$TAK_ROOT/CoreConfig.xml"; then
    echo "[init] ENABLE_PLAINTEXT_TAK=false — removing plaintext streaming CoT input (8087)"
    sed -i -E "\\#${PLAINTEXT_INPUT_RE}#d" "$TAK_ROOT/CoreConfig.xml"
  fi
fi

if [[ "$ENABLE_TLS" != "true" && "$ENABLE_PLAINTEXT_TAK" != "true" ]]; then
  echo "[init] WARN: both ENABLE_TLS and ENABLE_PLAINTEXT_TAK are false — no CoT input is configured"
fi

# Store-and-forward for chat (Marti UI toggle / buffer queue attr)
if [[ "$ENABLE_STORE_FORWARD_CHAT" == "true" ]]; then
  if grep -q 'enableStoreForwardChat="true"' "$TAK_ROOT/CoreConfig.xml"; then
    echo "[init] Store-and-forward chat already enabled"
  elif grep -q 'enableStoreForwardChat=' "$TAK_ROOT/CoreConfig.xml"; then
    sed -i -E 's/enableStoreForwardChat="[^"]*"/enableStoreForwardChat="true"/' "$TAK_ROOT/CoreConfig.xml"
  elif grep -qE '<queue[[:space:]]*/>' "$TAK_ROOT/CoreConfig.xml"; then
    echo "[init] Enabling store-and-forward chat..."
    sed -i -E 's|<queue[[:space:]]*/>|<queue enableStoreForwardChat="true"><priority/></queue>|' \
      "$TAK_ROOT/CoreConfig.xml"
  elif grep -q '<queue>' "$TAK_ROOT/CoreConfig.xml"; then
    echo "[init] Enabling store-and-forward chat..."
    sed -i 's/<queue>/<queue enableStoreForwardChat="true">/' "$TAK_ROOT/CoreConfig.xml"
  elif grep -qE '<queue[[:space:]]' "$TAK_ROOT/CoreConfig.xml"; then
    echo "[init] Enabling store-and-forward chat..."
    sed -i -E 's/<queue([[:space:]]+)/<queue enableStoreForwardChat="true"\1/' "$TAK_ROOT/CoreConfig.xml"
  else
    echo "[init] WARN: no <queue> element — cannot set enableStoreForwardChat"
  fi
fi

# Enable TAK Server CA certificate enrollment (8446) if missing.
# Do not grep for bare "<certificateSigning" — the vendor example has a commented block.
if [[ "$ENABLE_CERT_ENROLLMENT" == "true" ]] \
  && [[ -f "$FILES/${CA_CN}-signing.jks" ]] \
  && ! grep -qE '<certificateSigning[[:space:]]+CA="TAKServer">' "$TAK_ROOT/CoreConfig.xml"; then
  echo "[init] Enabling certificate enrollment (CA=$CA_CN)..."
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
    head -n -1 "$TAK_ROOT/CoreConfig.xml"
    cat "$ENROLL_TMP"
    echo "</Configuration>"
  } > "${TAK_ROOT/CoreConfig.xml}.new"
  \mv -f "${TAK_ROOT/CoreConfig.xml}.new" "$TAK_ROOT/CoreConfig.xml"
  rm -f "$ENROLL_TMP"
fi

# Enable the federation server (accepts incoming federation connections on
# 9000/9001, published by docker-compose.yml along with 8444). The vendor's
# CoreConfig.example.xml ships this whole block commented out and it has no
# webBaseUrl attribute, so without inserting it federation can never actually
# come up regardless of FED_WEB_BASE_FQDN/LE_FQDN — those only patch an
# existing webBaseUrl, they never create one. webBaseUrl is left empty here
# (matches the CoreConfig.xsd default) if inserted before a FQDN is known;
# the section below (and post-start.sh, on later runs) fills it in once set.
if [[ "$ENABLE_FEDERATION" == "true" ]] \
  && [[ -f "$FILES/takserver.jks" ]] \
  && ! grep -qE '<federation-server[[:space:]]' "$TAK_ROOT/CoreConfig.xml"; then
  echo "[init] Enabling federation server (ports 9000/9001, 8444)..."
  if [[ ! -f "$FILES/fed-truststore.jks" && -f "$FILES/truststore-root.jks" ]]; then
    cp -f "$FILES/truststore-root.jks" "$FILES/fed-truststore.jks"
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
    head -n -1 "$TAK_ROOT/CoreConfig.xml"
    cat "$FED_TMP"
    echo "</Configuration>"
  } > "$TAK_ROOT/CoreConfig.xml.new"
  \mv -f "$TAK_ROOT/CoreConfig.xml.new" "$TAK_ROOT/CoreConfig.xml"
  rm -f "$FED_TMP"
fi

# Retrofit for a config that already has a <federation-server> block but is
# missing the actual on-switch: the element existing is not enough, TAK only
# activates federation when enableFederation="true" is set on the parent
# <federation> tag (and v1enabled/v2enabled/port on <federation-server>
# itself) — confirmed by diffing a CoreConfig.xml before/after toggling
# "Enable Federation" in the admin UI. Patch in place if this block predates
# that attribute set, whichever script originally inserted it.
if [[ -f "$TAK_ROOT/CoreConfig.xml" ]] && grep -qE '<federation-server[[:space:]]' "$TAK_ROOT/CoreConfig.xml" \
  && ! grep -q 'enableFederation="true"' "$TAK_ROOT/CoreConfig.xml"; then
  echo "[init] Federation block present but not actually enabled — patching attributes"
  if grep -qE '<federation[[:space:]][^>]*enableFederation="[^"]*"' "$TAK_ROOT/CoreConfig.xml"; then
    sed -i -E 's/(<federation[[:space:]][^>]*)enableFederation="[^"]*"/\1enableFederation="true"/' "$TAK_ROOT/CoreConfig.xml"
  elif grep -q '<federation>' "$TAK_ROOT/CoreConfig.xml"; then
    sed -i -E 's/<federation>/<federation enableFederation="true">/' "$TAK_ROOT/CoreConfig.xml"
  else
    sed -i -E 's/<federation([[:space:]])/<federation enableFederation="true"\1/' "$TAK_ROOT/CoreConfig.xml"
  fi
  if ! grep -qE '<federation-server[[:space:]][^>]*v1enabled=' "$TAK_ROOT/CoreConfig.xml"; then
    sed -i -E 's/<federation-server([[:space:]])/<federation-server coreVersion="2" v1enabled="true" v2port="9001" v2enabled="true"\1/' "$TAK_ROOT/CoreConfig.xml"
  fi
  # NOTE: requires an extra [[:space:]] before "port=" beyond the tag's own
  # mandatory leading space, so it never matches when port="..." is the
  # *first* attribute (as it always is in the template above and in
  # post-start.sh's own creation block) — that blind spot let this fire on
  # every run and insert a second, duplicate port="9000" attribute,
  # producing invalid XML that TAK Server can't parse (server fails to
  # start). Matching "port=" as either the first attribute or a later one.
  if ! grep -qE '<federation-server[[:space:]](port=|[^>]*[[:space:]]port=)' "$TAK_ROOT/CoreConfig.xml"; then
    sed -i -E 's/<federation-server([[:space:]])/<federation-server port="9000"\1/' "$TAK_ROOT/CoreConfig.xml"
  fi
fi

# Federation webBaseUrl: vendor default is often a Docker internal IP; use public FQDN from .env.
FED_FQDN="${FED_WEB_BASE_FQDN:-${LE_FQDN:-}}"
if [[ -n "$FED_FQDN" && -f "$TAK_ROOT/CoreConfig.xml" ]] && grep -q 'webBaseUrl=' "$TAK_ROOT/CoreConfig.xml"; then
  expected="https://${FED_FQDN}:8443/Marti"
  echo "[init] Setting federation webBaseUrl -> $expected"
  sed -i -E "s|webBaseUrl=\"[^\"]*\"|webBaseUrl=\"${expected}\"|" "$TAK_ROOT/CoreConfig.xml"
fi

echo "[init] Done."
