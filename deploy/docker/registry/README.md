# GitHub Container Registry deployment

This is a self-contained pulled-image deployment path. It keeps the official
TAK installer out of Git and out of the target host: a trusted builder stages
the official release, builds two public images, and pushes them to GHCR. Each
target host then needs only this `registry/` directory, Docker Compose, and a
private `.env`.

## Publish images (trusted builder)

1. Put the official TAK ZIP in `vendor/` and run `bash prepare-tak-docker.sh`.
2. Copy `env.example` to `.env` in this `registry/` directory; keep `TAK_RELEASE` aligned with the
   staged directory and update image tags as appropriate.
3. Create a GitHub classic personal access token with `write:packages`. Do not
   put this token in `.env` or Git.
4. Publish:

   ```bash
   export GHCR_TOKEN='github-token-with-write-packages'
   bash registry/publish.sh
   unset GHCR_TOKEN
   ```

The first push creates `ghcr.io/adamcabral86/takserver` and
`ghcr.io/adamcabral86/takserver-db`. They are public, so anyone may pull them;
only publish TAK content where its license permits it.

## Deploy images (target host)

1. Copy `env.example` to `.env` in this `registry/` directory and replace every `CHANGE_ME` value.
2. Start and provision the stack. No GHCR token or `docker login` is required
   to pull these public images:

   ```bash
   bash registry/deploy.sh
   ```

`tak_config` holds `CoreConfig.xml` and the deployment CA/certificates;
`tak_db_data` holds PostgreSQL data. Neither is in the image or should be
copied between environments. A full reset removes both named volumes and
requires all clients to enroll again.

## Optional Let's Encrypt and federation URL

Set `LE_ENABLE=true`, `LE_FQDN`, and `LE_EMAIL` in `.env` to request a public
certificate for the 8446 enrollment/password endpoint during `deploy.sh`.
The FQDN needs public DNS pointing to this host and TCP 80 reachable for the
HTTP-01 challenge. TLS CoT on 8089 and the mTLS admin endpoint on 8443 continue
to use the deployment's TAK CA. `FED_WEB_BASE_FQDN` optionally overrides the
federation URL; otherwise `LE_FQDN` is used.

Deployment installs `/etc/cron.d/certbot-tak-registry`, which runs certbot
renewal checks twice daily and uses `renew-letsencrypt.sh` as the deploy hook.
The hook imports a renewed certificate into the named TAK config volume and
restarts TAK.

## Reset and internal certificate export

The post-start step copies internal admin/service certificates to
`~/takserver-certs` by default, or to `CERTS_HOME_DIR` when set. These are for
server administration/integration only, not for end users; users enroll on
8446 with their credentials.

To reset this registry deployment completely, stop it and remove exactly its
named volumes, then deploy again:

```bash
docker compose --env-file registry/.env -f registry/docker-compose.yml down
docker volume rm tak_config tak_db_data
```

If you changed `TAK_CONFIG_VOLUME` or `DB_VOLUME`, use those exact names
instead. Resetting invalidates all enrolled client certificates.

## Ports

| Port | Purpose |
|---|---|
| 8089 | TLS CoT streaming for TAK clients |
| 8446 | Certificate enrollment/admin endpoint |
| 8444, 9000, 9001 | Federation, when enabled |

Do not distribute the internal `admin` or `gateway-svc` certificates to users.
They are generated only to bootstrap server administration and service-to-server
integration. Users should use the enrollment flow on 8446.
