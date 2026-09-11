# TAK Server — Docker Quick Start

Bare commands to get TAK Server running. For explanations, the full `.env`
reference, optional steps, and troubleshooting, see [README.md](README.md).

```bash
# 1. Install Docker
sudo apt update
sudo apt install -y docker.io docker-compose-v2 unzip
sudo usermod -aG docker "$USER"
newgrp docker

# 2. Unpack the deployment package (copy the zip to the server first)
unzip H2_TAK_Server_Docker-deploy-*.zip -d H2_TAK_Server_Docker
cd H2_TAK_Server_Docker/deploy/docker

# 3. Put the official takserver-docker-<version>-RELEASE-*.zip in vendor/
#    (from tak.gov / TAK Product Center) if it isn't already there:
# cp /path/to/takserver-docker-<version>-RELEASE-*.zip vendor/

# 4. Stage TAK Server
bash prepare-tak-docker.sh
# ^ copy the printed TAK_RELEASE=... value for the next step

# 5. Configure
cp env.example .env
nano .env   # set TAK_RELEASE from above; review CERT_*, LE_*, ADMIN_PASSWORD

# 6. Deploy (docker compose up -d --build + post-start.sh)
bash deploy.sh
```

Log in at `https://<host>:8446` — username and password in the .env.

Every script here runs as `bash <script>.sh`, not `./<script>.sh` — zip
doesn't preserve Unix executable bits, and `bash` doesn't need them.

**Tear down:** `docker compose --env-file .env down` (add `-v` to also delete
the database — see [README.md](README.md#12-tear-down) before doing that).
