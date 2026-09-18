# Deployment handover

## Use the supplied image archive

Place `takserver-images-5.7-43.tar` beside the repository on the receiving
Docker host, then load it:

```bash
docker load -i takserver-images-5.7-43.tar
docker image ls --format '{{.Repository}}:{{.Tag}}' | grep 'takserver.*5.7-43'
```

The command should show both source image names listed above. Create a fresh
`docker/.env` from `docker/env.example`, configure its secrets and host values,
then deploy without contacting GHCR:

```bash
cd H2_TAK_Server_Docker/docker
cp env.example .env
nano .env
SKIP_IMAGE_PULL=true bash deploy.sh
```

`SKIP_IMAGE_PULL=true` requires that the loaded image tags exactly match
`TAK_IMAGE` and `TAK_DB_IMAGE` in `.env`.

## Host images in another registry

To host the supplied images in the recipient's own OCI-compatible registry,
load the archive, authenticate, retag both images, and push them:

```bash
docker load -i takserver-images-5.7-43.tar
docker login registry.example.com
docker tag ghcr.io/adamcabral86/takserver:5.7-43 \
  registry.example.com/tak/takserver:5.7-43
docker tag ghcr.io/adamcabral86/takserver-db:5.7-43 \
  registry.example.com/tak/takserver-db:5.7-43
docker push registry.example.com/tak/takserver:5.7-43
docker push registry.example.com/tak/takserver-db:5.7-43
```

Set these names in `docker/.env` before a normal `bash deploy.sh`:

```bash
TAK_IMAGE=registry.example.com/tak/takserver:5.7-43
TAK_DB_IMAGE=registry.example.com/tak/takserver-db:5.7-43
```