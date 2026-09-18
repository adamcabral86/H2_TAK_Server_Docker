#!/usr/bin/env bash
# Creates the initial TAK configuration and deployment certificate authority.
set -euo pipefail

TAK_ROOT="${TAK_ROOT:-/opt/tak}"
CERTS="$TAK_ROOT/certs"
FILES="$CERTS/files"
export STATE="${CERT_STATE:-CO}" CITY="${CERT_CITY:-Denver}"
export ORGANIZATION="${CERT_ORGANIZATION:-TAK}" ORGANIZATIONAL_UNIT="${CERT_ORGANIZATIONAL_UNIT:-Lab}"
export COUNTRY="${CERT_COUNTRY:-US}" CAPASS="${CERT_PASS:-atakatak}" PASS="${CERT_PASS:-atakatak}"
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
ENABLE_SERVICE_ACCOUNT="${ENABLE_SERVICE_ACCOUNT:-true}"
SERVICE_CN="${CERT_SERVICE_CN:-gateway-svc}"

cd "$CERTS"
chmod +x *.sh 2>/dev/null || true
if [[ ! -f "$FILES/takserver.jks" ]]; then
  ./makeRootCa.sh --ca-name "root-${CA_CN}"
  printf 'n\n' | ./makeCert.sh ca "$CA_CN"
  ./makeCert.sh server "$SERVER_CN"
  [[ -f "$FILES/takserver.jks" || ! -f "$FILES/${SERVER_CN}.jks" ]] || cp -f "$FILES/${SERVER_CN}.jks" "$FILES/takserver.jks"
  ./makeCert.sh client "$ADMIN_CN"
  [[ -f "$FILES/admin.pem" || ! -f "$FILES/${ADMIN_CN}.pem" ]] || cp -f "$FILES/${ADMIN_CN}.pem" "$FILES/admin.pem"
  [[ -f "$FILES/admin.p12" || ! -f "$FILES/${ADMIN_CN}.p12" ]] || cp -f "$FILES/${ADMIN_CN}.p12" "$FILES/admin.p12"
elif [[ ! -f "$FILES/${CA_CN}-signing.jks" ]]; then
  printf 'n\n' | ./makeCert.sh ca "$CA_CN"
fi

if [[ "$ENABLE_SERVICE_ACCOUNT" == "true" && ! -f "$FILES/${SERVICE_CN}.p12" ]]; then
  ./makeCert.sh client "$SERVICE_CN"
fi

if [[ -f "$FILES/${CA_CN}.pem" && -f "$FILES/truststore-root.jks" ]] \
  && ! keytool -list -keystore "$FILES/truststore-root.jks" -storepass "$CERT_PASS" -alias "$CA_CN" >/dev/null 2>&1; then
  keytool -import -trustcacerts -file "$FILES/${CA_CN}.pem" -keystore "$FILES/truststore-root.jks" \
    -alias "$CA_CN" -storepass "$CERT_PASS" -noprompt
  [[ ! -f "$FILES/fed-truststore.jks" ]] || keytool -import -trustcacerts -file "$FILES/${CA_CN}.pem" \
    -keystore "$FILES/fed-truststore.jks" -alias "$CA_CN" -storepass "$CERT_PASS" -noprompt 2>/dev/null || true
fi

[[ -f "$TAK_ROOT/CoreConfig.xml" ]] || cp "$TAK_ROOT/CoreConfig.example.xml" "$TAK_ROOT/CoreConfig.xml"
CONFIG="$TAK_ROOT/CoreConfig.xml"

# TAK 5.7 starts several JVMs at once. Each lazily copies this example file
# when it is missing, using a non-atomic exists-then-copy sequence. Seed it
# during this single init service so concurrent JVM startup cannot race.
IGNITE_CONFIG="$TAK_ROOT/TAKIgniteConfig.xml"
IGNITE_CONFIG_EXAMPLE="$TAK_ROOT/TAKIgniteConfig.example.xml"
if [[ ! -e "$IGNITE_CONFIG" ]]; then
  [[ -f "$IGNITE_CONFIG_EXAMPLE" ]] || {
    echo "ERROR: $IGNITE_CONFIG_EXAMPLE not found." >&2
    exit 1
  }
  cp "$IGNITE_CONFIG_EXAMPLE" "$IGNITE_CONFIG"
fi

grep -q 'password="' "$CONFIG" && sed -i -E "s/(<connection[^>]*password=\")[^\"]*(\")/\1${DB_PASS}\2/" "$CONFIG"
sed -i -E "s/keystorePass=\"[^\"]*\"/keystorePass=\"${CERT_PASS}\"/" "$CONFIG" || true
sed -i -E "s/truststorePass=\"[^\"]*\"/truststorePass=\"${CERT_PASS}\"/" "$CONFIG" || true
sed -i -E 's#jdbc:postgresql://[^:/]+:5432/cot#jdbc:postgresql://tak-database:5432/cot#' "$CONFIG"

TLS_RE='^[[:space:]]*<input[^>]*_name="stdssl"[^>]*/>[[:space:]]*$'
PLAIN_RE='^[[:space:]]*<input[^>]*_name="streamtcp"[^>]*/>[[:space:]]*$'
NETWORK_RE='(<network[^>]*>)'
if [[ "$ENABLE_TLS" == "true" ]]; then
  grep -qE "$TLS_RE" "$CONFIG" || sed -i -E "s#${NETWORK_RE}#\1\n        <input _name=\"stdssl\" protocol=\"tls\" port=\"8089\" coreVersion=\"2\"/>#" "$CONFIG"
else
  if grep -qE "$TLS_RE" "$CONFIG"; then
    sed -i -E "\\#${TLS_RE}#d" "$CONFIG"
  fi
fi
if [[ "$ENABLE_PLAINTEXT_TAK" == "true" ]]; then
  grep -qE "$PLAIN_RE" "$CONFIG" || sed -i -E "s#${NETWORK_RE}#\1\n        <input _name=\"streamtcp\" protocol=\"stcp\" port=\"8087\" auth=\"anonymous\"/>#" "$CONFIG"
else
  if grep -qE "$PLAIN_RE" "$CONFIG"; then
    sed -i -E "\\#${PLAIN_RE}#d" "$CONFIG"
  fi
fi

if [[ "$ENABLE_STORE_FORWARD_CHAT" == "true" ]] && ! grep -q 'enableStoreForwardChat="true"' "$CONFIG"; then
  if grep -q 'enableStoreForwardChat=' "$CONFIG"; then
    sed -i -E 's/enableStoreForwardChat="[^"]*"/enableStoreForwardChat="true"/' "$CONFIG"
  elif grep -qE '<queue[[:space:]]*/>' "$CONFIG"; then
    sed -i -E 's|<queue[[:space:]]*/>|<queue enableStoreForwardChat="true"><priority/></queue>|' "$CONFIG"
  elif grep -q '<queue>' "$CONFIG"; then
    sed -i 's/<queue>/<queue enableStoreForwardChat="true">/' "$CONFIG"
  elif grep -qE '<queue[[:space:]]' "$CONFIG"; then
    sed -i -E 's/<queue([[:space:]]+)/<queue enableStoreForwardChat="true"\1/' "$CONFIG"
  fi
fi

if [[ "$ENABLE_CERT_ENROLLMENT" == "true" && -f "$FILES/${CA_CN}-signing.jks" ]] \
  && ! grep -qE '<certificateSigning[[:space:]]+CA="TAKServer">' "$CONFIG"; then
  tmp="$(mktemp)"
  cat > "$tmp" <<EOF
    <certificateSigning CA="TAKServer">
        <certificateConfig><nameEntries>
            <nameEntry name="O" value="${ORGANIZATION}"/>
            <nameEntry name="OU" value="${ORGANIZATIONAL_UNIT}"/>
        </nameEntries></certificateConfig>
        <TAKServerCAConfig keystore="JKS" keystoreFile="certs/files/${CA_CN}-signing.jks" keystorePass="${CERT_PASS}" validityDays="30" signatureAlg="SHA256WithRSA" CAkey="/opt/tak/certs/files/${CA_CN}" CAcertificate="/opt/tak/certs/files/${CA_CN}"/>
    </certificateSigning>
EOF
  { head -n -1 "$CONFIG"; cat "$tmp"; echo '</Configuration>'; } > "$CONFIG.new"
  mv -f "$CONFIG.new" "$CONFIG"; rm -f "$tmp"
fi

if [[ "$ENABLE_FEDERATION" == "true" && -f "$FILES/takserver.jks" ]] \
  && ! grep -qE '<federation-server[[:space:]]' "$CONFIG"; then
  [[ -f "$FILES/fed-truststore.jks" || ! -f "$FILES/truststore-root.jks" ]] || cp -f "$FILES/truststore-root.jks" "$FILES/fed-truststore.jks"
  tmp="$(mktemp)"
  cat > "$tmp" <<EOF
    <federation enableFederation="true" allowMissionFederation="true" allowDataFeedFederation="true">
      <federation-server port="9000" coreVersion="2" v1enabled="true" v2port="9001" v2enabled="true" webBaseUrl="">
        <tls context="TLSv1.2" keymanager="SunX509" keystore="JKS" keystoreFile="certs/files/takserver.jks" keystorePass="${CERT_PASS}" truststore="JKS" truststoreFile="certs/files/fed-truststore.jks" truststorePass="${CERT_PASS}"/>
      </federation-server>
    </federation>
EOF
  { head -n -1 "$CONFIG"; cat "$tmp"; echo '</Configuration>'; } > "$CONFIG.new"
  mv -f "$CONFIG.new" "$CONFIG"; rm -f "$tmp"
fi

if grep -qE '<federation-server[[:space:]]' "$CONFIG" && ! grep -q 'enableFederation="true"' "$CONFIG"; then
  if grep -qE '<federation[[:space:]][^>]*enableFederation="[^"]*"' "$CONFIG"; then
    sed -i -E 's/(<federation[[:space:]][^>]*)enableFederation="[^"]*"/\1enableFederation="true"/' "$CONFIG"
  elif grep -q '<federation>' "$CONFIG"; then
    sed -i -E 's/<federation>/<federation enableFederation="true">/' "$CONFIG"
  else
    sed -i -E 's/<federation([[:space:]])/<federation enableFederation="true"\1/' "$CONFIG"
  fi
fi
if grep -qE '<federation-server[[:space:]]' "$CONFIG" && ! grep -qE '<federation-server[[:space:]][^>]*v1enabled=' "$CONFIG"; then
  sed -i -E 's/<federation-server([[:space:]])/<federation-server coreVersion="2" v1enabled="true" v2port="9001" v2enabled="true"\1/' "$CONFIG"
fi
if grep -qE '<federation-server[[:space:]]' "$CONFIG" && ! grep -qE '<federation-server[[:space:]](port=|[^>]*[[:space:]]port=)' "$CONFIG"; then
  sed -i -E 's/<federation-server([[:space:]])/<federation-server port="9000"\1/' "$CONFIG"
fi

FED_FQDN="${FED_WEB_BASE_FQDN:-${LE_FQDN:-}}"
if [[ -n "$FED_FQDN" ]] && grep -q 'webBaseUrl=' "$CONFIG"; then
  sed -i -E "s|webBaseUrl=\"[^\"]*\"|webBaseUrl=\"https://${FED_FQDN}:8443/Marti\"|" "$CONFIG"
fi
echo '[tak-init] Done.'
