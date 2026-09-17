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
cd docker
bash bootstrap-ubuntu.sh
# Log out and back in before continuing, so Docker-group membership applies.
```

The bootstrap deliberately does not run `apt upgrade` and refuses to replace
an existing Docker installation or conflicting packages. Review and handle an
existing Docker host separately.

```bash
cd docker
cp env.example .env
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

For an internet-facing enrollment endpoint, set `LE_ENABLE=true`, `LE_FQDN`,
and `LE_EMAIL` in `.env`. The FQDN must resolve publicly to this host and TCP
80 must be reachable for the HTTP-01 challenge. This only provides a public
certificate for enrollment; TLS CoT uses the deployment TAK CA.

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

The deployment exports internal `admin` and `gateway-svc` certificates to
`~/takserver-certs` by default (or `CERTS_HOME_DIR`). They are only for server
administration and integrations; never give them to end users.

## Publishing images

Trusted-builder-only files live in [publish/](publish/). They are not needed
on a normal server. See the repository README for the publishing workflow.

The `scripts/` directory contains internal deployment helpers. Run
`deploy.sh` rather than invoking those helpers directly.
