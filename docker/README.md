# TAK Server Docker deployment

This directory contains the normal TAK Server deployment. It pulls published
images and creates per-environment configuration, a TAK CA, and certificates
in named Docker volumes.

## Deploy

Prerequisites: Docker Engine with the Compose plugin. Public GHCR images do
not require a GitHub token or `docker login`.

On a fresh Ubuntu 22.04, 24.04, or 26.04 server, install the prerequisites
once using Docker's official APT repository setup:

```bash
cd H2_TAK_Server_Docker/docker
bash bootstrap-ubuntu.sh
# Log out and back in before continuing, so Docker-group membership applies.
```

The bootstrap deliberately does not run `apt upgrade` and refuses to replace
an existing Docker installation or conflicting packages. Review and handle an
existing Docker host separately.

```bash
cd H2_TAK_Server_Docker/docker
cp env.example .env
nano .env
# Set secure CERT_PASS, DB_PASS, and ADMIN_PASSWORD values.
bash deploy.sh
```

`deploy.sh` pulls the images, starts the stack, then provisions internal
administrator and service accounts. The first launch may show brief
connection-refused readiness checks while TAK finishes starting; wait for its
final `Done` message.

Open `https://<host>:8443/Marti/` for administration or
`https://<host>:8446/` for enrollment.

## Client enrollment

Users receive enrollment credentials, not pre-generated client certificates.
Set `ENABLE_CERT_ENROLLMENT=true` (the default). For local testing without
Let's Encrypt, import the deployment's public TAK CA into the Windows/WinTAK
trust store, then enroll using the host LAN IP or DNS name on port 8446.
`localhost` works only on the same computer.

After deployment, the startup instructions use `LE_FQDN` when set. Otherwise
they try the AWS EC2 IMDSv2 public IPv4 address, the host's primary
route-interface IP, and finally `checkip.amazonaws.com`. The final external
lookup reports the outbound NAT address and may not be client-reachable. Set
`PUBLIC_IP` to override the display value when a proxy, load balancer, or NAT
makes automatic discovery unsuitable.

For an internet-facing enrollment endpoint, set `LE_ENABLE=true`, `LE_FQDN`,
and `LE_EMAIL` in `.env`. The FQDN must resolve publicly to this host and TCP
80 must be reachable for the HTTP-01 challenge. This only provides a public
certificate for enrollment; TLS CoT uses the deployment TAK CA.

## Standard client certificate bundle

On first deployment, `CLIENT_USER` creates a standard, non-administrator
client identity. Its certificate is exported as
`docker/tak-certs/<CLIENT_USER>.p12`; for example,
`docker/tak-certs/takuser1.p12`. The `.p12` password is `CERT_PASS`. This
provides a repeatable ATAK/WinTAK smoke-test identity and a generated client
certificate bundle for local demos.

`CLIENT_PASSWORD` provisions the same username for certificate enrollment.
Use a password of at least 15 characters containing uppercase, lowercase,
number, and special characters. The standard certificate is a shared test
credential: do not distribute it to real users. Real users should enroll with
their own username/password and receive their own certificate.

To create an additional normal client certificate after deployment, run from
the `docker/` directory:

```bash
set -a; source .env; set +a
CLIENT_USER=takuser2
read -rsp "Client password: " CLIENT_PASSWORD; echo

docker exec -e TAK_CLIENT_USER="$CLIENT_USER" -e STATE="$CERT_STATE" -e CITY="$CERT_CITY" \
  -e ORGANIZATION="$CERT_ORGANIZATION" -e ORGANIZATIONAL_UNIT="$CERT_ORGANIZATIONAL_UNIT" \
  -e COUNTRY="$CERT_COUNTRY" -e CAPASS="$CERT_PASS" -e PASS="$CERT_PASS" takserver bash -lc \
  'cd /opt/tak/certs && ./makeCert.sh client "$TAK_CLIENT_USER"'
docker exec -e TAK_CLIENT_USER="$CLIENT_USER" takserver bash -lc \
  'cd /opt/tak && java -jar utils/UserManager.jar certmod "certs/files/${TAK_CLIENT_USER}.pem"'
docker exec -e TAK_CLIENT_USER="$CLIENT_USER" -e TAK_CLIENT_PASSWORD="$CLIENT_PASSWORD" takserver bash -lc \
  'cd /opt/tak && java -jar utils/UserManager.jar usermod -c "certs/files/${TAK_CLIENT_USER}.pem" -p "$TAK_CLIENT_PASSWORD" "$TAK_CLIENT_USER"'
docker cp "takserver:/opt/tak/certs/files/${CLIENT_USER}.p12" "tak-certs/${CLIENT_USER}.p12"
chmod 600 "tak-certs/${CLIENT_USER}.p12"
```

Use the client `.p12` with `ca.pem` or `truststore-root.p12`. The client
certificate password is `CERT_PASS`; the separate `CLIENT_PASSWORD` is for
certificate enrollment.

## Ports

| Port | Purpose |
|---|---|
| 8089 | TCP/TLS CoT streaming for TAK clients |
| 8443 | TAK Web admin endpoint (mTLS) |
| 8446 | Certificate enrollment and password endpoint |
| 8444, 9000, 9001 | Federation, if enabled |

Change host-side mappings with the `HOST_PORT_*` values in `.env`.

## Stop or reset

A normal shutdown retains configuration and database data:

```bash
docker compose --env-file .env -f docker-compose.yml down
```

To fully reset the deployment, including the TAK CA, client enrollments, and
database data:

```bash
docker compose --env-file .env -f docker-compose.yml down
docker volume rm tak_config tak_db_data
```

Use the configured `TAK_CONFIG_VOLUME` and `DB_VOLUME` names if you changed
them. A reset requires every client to enroll again.

After startup, the deployment exports `admin.p12`, `ca.pem`, and
`truststore-root.p12` to `docker/tak-certs/` by default (or `CERTS_HOME_DIR`).
`admin.p12` is for server administration only; never give it to end users.
Use `ca.pem` or `truststore-root.p12` to establish client trust for the
deployment TAK CA; the truststore password is `CERT_PASS`.

## Publishing images

Trusted-builder-only files live in [publish/](publish/). They are not needed
on a normal server. See the repository README for the publishing workflow.

The `scripts/` directory contains internal deployment helpers. Run
`deploy.sh` rather than invoking those helpers directly.
