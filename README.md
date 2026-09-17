# H2 TAK Server Docker

A Docker deployment for TAK Server 5.7/5.8, supporting TLS CoT streaming,
certificate enrollment, local development, integration testing, and demos.

## Run a TAK Server

The normal server workflow only needs Docker Compose. It pulls the published
images and does not need the official TAK installer ZIP or a GitHub token.

On a fresh supported Ubuntu host, first run the one-time prerequisite setup:

```bash
cd docker
bash bootstrap-ubuntu.sh
# Log out and back in so your user receives Docker-group membership.
```

```bash
cd docker
cp env.example .env
# Edit .env and replace every CHANGE_ME value.
bash deploy.sh
```

See [docker/README.md](docker/README.md) for enrollment, ports, reset,
optional Let's Encrypt, and validation details.

## Publish updated images

Only a trusted builder with an authorized official TAK Server release needs
the publishing files:

```bash
cd docker/publish
# Put the official takserver-docker-*.zip in vendor/.
bash prepare-release.sh

# Set TAK_RELEASE and versioned image tags in ../.env.
export GHCR_TOKEN='github-token-with-write-packages'
bash publish.sh
unset GHCR_TOKEN
```

The installer ZIP and staging tree are ignored by Git. A normal server never
needs `docker/publish/`.

## Layout

```
docker/          Runtime deployment configuration and scripts
docker/scripts/  Internal initialization, provisioning, and certificate helpers
docker/publish/  Trusted-builder scripts, Dockerfiles, vendor ZIP, and staging
```
