# H2 TAK Server Docker

TAK Server 5.7/5.8 deployed via Docker Compose. This is a fork of
[H2TAK_Server](../H2TAK_Server) moving in a different direction — see
[`STANDALONE_GATEWAY_SCOPE.md`](STANDALONE_GATEWAY_SCOPE.md) for the reasoning
behind that split. Unlike the parent repo, there is **no in-process TAK
Server plugin here** — this repo runs bare TAK Server only. DIS ingestion and
CoT reconciliation are being scoped as a separate, standalone service (see
the scope doc); nothing here depends on it yet.

## Repo layout

```
H2_TAK_Server_Docker/
├── STANDALONE_GATEWAY_SCOPE.md   # Scoping notes for the future standalone gateway service
├── scripts/
│   ├── test_tak_connection.py   # mTLS connection test — sends one CoT via the service account cert
│   └── requirements.txt         # pip install -r scripts/requirements.txt (just `cryptography`)
└── deploy/
    └── docker/
        ├── docker-compose.yml    # Generic — version driven entirely by TAK_RELEASE in .env
        ├── env.example           # Copy to .env and edit
        ├── prepare-tak-docker.sh # Unpack the vendor zip into staging/
        ├── init-tak-config.sh    # Runs once in the init container: certs + CoreConfig.xml
        ├── post-start.sh         # Post-up provisioning (certs, admin, service account, Let's Encrypt)
        ├── deploy.sh             # docker compose up -d --build + post-start.sh, one step
        ├── upgrade-tak-docker.sh # Automated in-place upgrade to a newer TAK release
        ├── apply-letsencrypt.sh  # Let's Encrypt for the :8446 password/enrollment port
        ├── QUICKSTART.md         # Bare commands
        ├── README.md             # Same steps, explained, plus optional steps/troubleshooting
        ├── AUTO_UPGRADE.md / MANUAL_UPGRADE.md
        ├── vendor/               # Put an official takserver-docker-*.zip here (not tracked)
        └── staging/              # Extracted/staged TAK tree, regenerated on demand (not tracked)
```

## Quick start

Bare commands: [`deploy/docker/QUICKSTART.md`](deploy/docker/QUICKSTART.md). Full
walkthrough with explanations, optional steps, and troubleshooting:
[`deploy/docker/README.md`](deploy/docker/README.md).

```bash
# 1. Get an official takserver-docker-<version>-RELEASE-*.zip from tak.gov
#    (TAK Product Center) and place it in deploy/docker/vendor/

cd deploy/docker
sudo apt update && sudo apt install -y docker.io docker-compose-v2 unzip
sudo usermod -aG docker "$USER" && newgrp docker

bash prepare-tak-docker.sh       # unpacks TAK Server into staging/
cp env.example .env              # edit TAK_RELEASE, CERT_*, LE_*, ADMIN_PASSWORD as needed
bash deploy.sh                    # docker compose up -d --build + post-start.sh, one step
```

Scripts here run as `bash <script>.sh` rather than `./<script>.sh` — zip
doesn't preserve Unix executable bits, and `bash` doesn't need them, so
there's no chmod step.

Log in at `https://<host>:8443/Marti/` (import `~/takserver-certs/admin.p12`,
password = `CERT_PASS`, default `atakatak`).

## What's next

See [`STANDALONE_GATEWAY_SCOPE.md`](STANDALONE_GATEWAY_SCOPE.md) for the
planned DIS-to-CoT reconciliation service (sim entities matched to authored
EASE entities, pushed into TAK for role players; role-player CoT pulled back
into the simulation) and the TAK group model (EXCON vs. PTA) that will sit on
top of this deployment once that work starts. Nothing in this repo depends
on it yet — the TAK Server deployment above stands on its own.
