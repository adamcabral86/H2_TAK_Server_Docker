# GitHub Container Registry deployment

This is the pulled-image deployment path. It keeps the official TAK installer
out of Git and out of the target host: a trusted builder stages the official
release, builds two public images, and pushes them to GHCR. Each target host
then needs only this deployment directory, Docker Compose, and a private `.env`.

## Publish images (trusted builder)

1. Put the official TAK ZIP in `vendor/` and run `bash prepare-tak-docker.sh`.
2. Copy `env.registry.example` to `.env`; keep `TAK_RELEASE` aligned with the
   staged directory and update image tags as appropriate.
3. Create a GitHub classic personal access token with `write:packages`. Do not
   put this token in `.env` or Git.
4. Publish:

   ```bash
   export GHCR_TOKEN='github-token-with-write-packages'
   bash publish-ghcr.sh
   unset GHCR_TOKEN
   ```

The first push creates `ghcr.io/adamcabral86/takserver` and
`ghcr.io/adamcabral86/takserver-db`. They are public, so anyone may pull them;
only publish TAK content where its license permits it.

## Deploy images (target host)

1. Copy `env.registry.example` to `.env` and replace every `CHANGE_ME` value.
2. Start and provision the stack. No GHCR token or `docker login` is required
   to pull these public images:

   ```bash
   bash deploy-registry.sh
   ```

`tak_config` holds `CoreConfig.xml` and the deployment CA/certificates;
`tak_db_data` holds PostgreSQL data. Neither is in the image or should be
copied between environments. A full reset removes both named volumes and
requires all clients to enroll again.

## Ports

| Port | Purpose |
|---|---|
| 8089 | TLS CoT streaming for TAK clients |
| 8446 | Certificate enrollment/admin endpoint |
| 8444, 9000, 9001 | Federation, when enabled |

Do not distribute the internal `admin` or `gateway-svc` certificates to users.
They are generated only to bootstrap server administration and service-to-server
integration. Users should use the enrollment flow on 8446.
