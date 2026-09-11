# TAK Server — Docker Deployment

Get a single-server TAK Server deployment running on Ubuntu with Docker Compose. This works with any official TAK Server release — the version you run is set once in `.env`, not baked into these files.

For the bare command sequence with no explanation, see [QUICKSTART.md](QUICKSTART.md). This document covers the same steps with the reasoning, the full `.env` reference, optional steps, and troubleshooting.

## Contents

1. [Prerequisites](#1-prerequisites)
2. [Install Docker](#2-install-docker)
3. [Unpack the deployment package](#3-unpack-the-deployment-package)
4. [Stage the TAK Server files](#4-stage-the-tak-server-files)
5. [Configure the environment](#5-configure-the-environment)
6. [Deploy](#6-deploy)
7. [Log in](#7-log-in)
8. [Service/API account for programmatic access](#8-serviceapi-account-for-programmatic-access)
9. [Optional: add another admin account](#9-optional-add-another-admin-account)
10. [Optional: federation](#10-optional-federation)
11. [Optional: re-run or renew Let's Encrypt](#11-optional-re-run-or-renew-lets-encrypt)
12. [Optional: plaintext CoT for packet captures](#12-optional-plaintext-cot-for-packet-captures)
13. [Tear down](#13-tear-down)
14. [Troubleshooting](#14-troubleshooting)

---

## 1. Prerequisites

- [ ] Ubuntu Server (22.04 LTS or 24.04 LTS)
- [ ] `sudo` access
- [ ] Internet connection
- [ ] 8 GB RAM minimum (12 GB+ recommended)
- [ ] 50 GB+ free disk space
- [ ] An official `takserver-docker-<version>-RELEASE-*.zip` from [tak.gov](https://tak.gov/) (TAK Product Center) — not included in this folder, you provide it

---

## 2. Install Docker

```bash
sudo apt update
sudo apt install -y docker.io docker-compose-v2 unzip
sudo usermod -aG docker "$USER"
newgrp docker
```

`newgrp docker` refreshes your current shell's group membership so you can run `docker` without `sudo`. If you open a new terminal later, you won't need to run it again.

Recent Compose versions default to building with **Bake**, which requires the separate `docker-buildx-plugin` package. `deploy.sh` and `upgrade-tak-docker.sh` (used from [step 6](#6-deploy) onward) already set `COMPOSE_BAKE=false` themselves, so you don't need to set it yourself — this only matters if you ever run a bare `docker compose ... --build` by hand instead:

```bash
export COMPOSE_BAKE=false
```

---

## 3. Unpack the deployment package

Copy the deployment zip (e.g. `H2_TAK_Server_Docker-deploy-<date>.zip`, built from this
repo — see the root [`README.md`](../../README.md)) to the server, then:

```bash
unzip H2_TAK_Server_Docker-deploy-*.zip -d H2_TAK_Server_Docker
cd H2_TAK_Server_Docker/deploy/docker
```

Everything else in this guide is run from inside `deploy/docker/`, and every
script here is invoked as `bash <script>.sh` rather than `./<script>.sh` —
zip doesn't preserve Unix executable bits, and `bash` doesn't need them, so
there's no chmod step to remember.

---

## 4. Stage the TAK Server files

Place the vendor zip in `vendor/` if it isn't already there:

```bash
cp /path/to/takserver-docker-<version>-RELEASE-*.zip vendor/
```

Then unpack it:

```bash
bash prepare-tak-docker.sh
```

If `vendor/` contains more than one non-hardened zip, you'll need to say which one: `bash prepare-tak-docker.sh vendor/takserver-docker-<version>-RELEASE-*.zip`.

This extracts the zip into `staging/<release>/` and prints the exact `TAK_RELEASE=...` line to put in `.env` in the next step — copy it down.

---

## 5. Configure the environment

```bash
cp env.example .env
nano .env
```

Key values to review:

| Variable | Purpose |
|---|---|
| `TAK_RELEASE` | Which staged release to run — set this to what `prepare-tak-docker.sh` printed in step 4 |
| `CERT_STATE`, `CERT_CITY`, `CERT_ORGANIZATION`, `CERT_ORGANIZATIONAL_UNIT`, `CERT_COUNTRY` | Certificate subject fields |
| `CERT_PASS` | Password for generated keystores/`admin.p12` (default `atakatak`) |
| `DB_PASS` | PostgreSQL password written into `CoreConfig.xml` |
| `ADMIN_USER` / `ADMIN_PASSWORD` | Optional username/password login on port 8446. Leave `ADMIN_PASSWORD` blank to skip; quote it if it contains `!`, `$`, etc. |
| `HOST_PORT_*` | Host-side port mappings (change only if you have conflicts) |
| `DB_VOLUME` | Name of the Docker volume PostgreSQL data lives in — leave as-is unless you're upgrading across a Postgres major version (see [AUTO_UPGRADE.md](AUTO_UPGRADE.md)) |
| `LE_ENABLE`, `LE_FQDN`, `LE_EMAIL` | Set `LE_ENABLE=true` and fill in your domain/email to get a Let's Encrypt certificate on port 8446 automatically |
| `ENABLE_FEDERATION` | Wires `<federation>` into CoreConfig so ports 9000/9001/8444 actually work (default `true`) — see [step 10](#10-optional-federation) |
| `ENABLE_TLS` / `ENABLE_PLAINTEXT_TAK` | Independent CoT listener toggles — `ENABLE_TLS=true` (default) keeps 8089/TLS, `ENABLE_PLAINTEXT_TAK=true` adds 8087 plaintext. Both can be on at once — see [step 12](#12-optional-plaintext-cot-for-packet-captures) |

> **Why this matters:** unlike a bare-metal install, setting `ADMIN_PASSWORD` here means [step 6](#6-deploy) sets the password for you automatically — no manual `UserManager.jar` command needed afterward.

---

## 6. Deploy

```bash
bash deploy.sh
```

Builds and starts the stack (`docker compose --env-file .env up -d --build`,
with `COMPOSE_BAKE=false` set automatically so it doesn't need the buildx
plugin), then waits for TAK Server to come up and runs post-start setup:

- Enables certificate enrollment and trusts the issuing CA (fixes WinTAK "peer not verified" on 8089)
- Enables store-and-forward chat
- Sets the federation `webBaseUrl` from `LE_FQDN` (if set)
- Promotes the generated `admin` certificate to administrator
- Sets the `ADMIN_PASSWORD` for port-8446 login (if you set one)
- Requests a Let's Encrypt certificate (if `LE_ENABLE=true`)
- Copies your certificates to `~/takserver-certs`

It's safe to re-run — each step checks whether it's already done before
making changes. `docker compose --env-file .env up -d --build` and
`bash post-start.sh` still work fine as separate commands too, if you'd
rather run them individually.

---

## 7. Log in

| Step | URL | Credential |
|---|---|---|
| Admin UI (mTLS) | `https://<host>:8443/Marti/` | Import `~/takserver-certs/admin.p12` into your browser (password = `CERT_PASS`, default `atakatak`) |
| Admin / enrollment (password) | `https://<host>:8446` | Username `ADMIN_USER` + `ADMIN_PASSWORD` from `.env` |
| Public / enrollment (Let's Encrypt) | `https://<LE_FQDN>:8446` | Only if `LE_ENABLE=true` |
| ATAK / WinTAK | `<host>:8089` | TAK CA (uses the same certs) |

### Ports

| Port | Use |
|---|---|
| 8089 | TAK client SSL |
| 8087 | TAK client plaintext (only live when `ENABLE_PLAINTEXT_TAK=true`) |
| 8443 | Admin HTTPS (client cert) |
| 8444 | Federation HTTPS |
| 9000 | Federation v1 |
| 9001 | Federation v2 |
| 8446 | Enrollment / public HTTPS (password or Let's Encrypt) |
| 80 | Only needed during Let's Encrypt issuance/renewal |

---

## 8. Service/API account for programmatic access

Deploy automatically creates a second, non-human client certificate for code
that talks to TAK Server directly — the Marti REST API on 8443, or the CoT
stream on 8089 (both mTLS) — separate from the `admin` cert above so a
service credential can be rotated or revoked without touching anyone's
personal login. Controlled by two `.env` vars:

| Variable | Purpose |
|---|---|
| `ENABLE_SERVICE_ACCOUNT` | Create it at all (default `true`) |
| `CERT_SERVICE_CN` | Its common name / file basename (default `gateway-svc`) |

It's promoted to **ROLE_ADMIN** — the same privilege the human `admin`
account has — because it needs full Marti API access. Once [step 6](#6-deploy)
finishes, you'll find:

```
~/takserver-certs/gateway-svc.p12   # cert + key, password = CERT_PASS
~/takserver-certs/gateway-svc.pem   # cert only
```

Hand `gateway-svc.p12` (and `CERT_PASS`) to whatever service needs it — most
TLS libraries can load a `.p12`/PKCS12 bundle directly as a client cert. It
authenticates the same way `admin.p12` does at `https://<host>:8443/Marti/`
or on the CoT stream at `<host>:8089`.

**If it turns out full admin is more than the integration actually needs**,
scope it down after the fact in the admin UI (Users → find the cert → adjust
role) rather than at generation time — `certmod -A` here is just "grant admin
now," and TAK's permission model isn't re-run automatically on every login.

Re-running `bash post-start.sh` (or `bash deploy.sh`) is safe if you change
`CERT_SERVICE_CN` or re-enable this on an existing deployment — it only
creates/promotes what's missing, same as the admin account and CoT-input
toggles elsewhere in this doc.

---

## 9. Optional: add another admin account

```bash
docker exec takserver bash -c "cd /opt/tak/certs && ./makeCert.sh client admin2"
docker exec takserver bash -c "cd /opt/tak && java -jar utils/UserManager.jar certmod -A certs/files/admin2.pem"
```

(Replace `admin2` with the actual username.) To also give this account a port-8446 username/password login:

```bash
docker exec -e TAK_ADMIN_USER=admin2 -e TAK_ADMIN_PASSWORD='YourStrongPassword123!' takserver \
  bash -c 'cd /opt/tak && java -jar utils/UserManager.jar usermod -A -p "$TAK_ADMIN_PASSWORD" "$TAK_ADMIN_USER"'
```

---

## 10. Optional: federation

Federation ports (`8444`, `9000`, `9001`) are published by default, and `ENABLE_FEDERATION=true` (the default) wires the `<federation>` block into CoreConfig at install time — open the ports in your firewall/security group to peer TAK servers.

1. In the admin dashboard: **Configuration → Federation**
2. Exchange CA certificates with your federation partner (yours is at `~/takserver-certs/ca.pem` after step 6)
3. Upload their CA under **Federate Certificate Authorities**
4. Go to **Federation → Create Outgoing Connection**, enter their address and port `9001`, then **Save**

---

## 11. Optional: re-run or renew Let's Encrypt

If you didn't set `LE_ENABLE=true` initially, or need to re-issue a certificate later:

```bash
bash apply-letsencrypt.sh --force
```

Requires `LE_FQDN` and `LE_EMAIL` set in `.env`, a public DNS record pointing at this host, and port 80 reachable from the internet. This also installs a renewal cron hook, so you shouldn't need to run it again unless something changes.

---

## 12. Optional: plaintext CoT for packet captures

By default the CoT listener on 8089 uses TLS, so a Wireshark capture just shows encrypted bytes. `ENABLE_TLS` and `ENABLE_PLAINTEXT_TAK` are independent switches, so you can add a plaintext listener on 8087 alongside 8089 rather than replacing it — normal clients keep using 8089, and a test client on 8087 gives you readable CoT XML in the capture. ATAK/WinTAK connected to 8087 still see each other normally (it uses TAK's `protocol="stcp"` bidirectional streaming input, not plain `protocol="tcp"` — the latter is publish-only in TAK Server and won't broadcast CoT between clients).

```bash
# in .env — add the plaintext listener alongside the normal TLS one
ENABLE_TLS=true
ENABLE_PLAINTEXT_TAK=true
```

```bash
bash post-start.sh
```

Re-running `post-start.sh` after the edit adds/removes the CoreConfig `<input>` line(s) and restarts `tak` automatically. Point your test client at `<host>:8087`; other clients keep using `<host>:8089` as normal. Set `ENABLE_PLAINTEXT_TAK=false` (or `ENABLE_TLS=false` to drop 8089 instead) and re-run `post-start.sh` to remove a listener. Neither setting affects the admin/web ports (8443/8444/8446), which stay HTTPS regardless.

---

## 13. Tear down

```bash
docker compose --env-file .env down
```

Stops and removes the containers. Nothing is deleted — certs, `UserAuthenticationFile.xml`, `CoreConfig.xml`, and the database are all untouched, so `bash deploy.sh` (or `docker compose --env-file .env up -d --build`) brings you right back to where you left off.

### Deleting the database

```bash
docker compose --env-file .env down -v
```

**WARNING — this permanently deletes the PostgreSQL database.** That means:

- All CoT/location data (unit positions, track history — the map data)
- Missions (data packages, mission layers, mission changes)
- Store-and-forward chat history
- Database-stored user role/permission assignments (who's an admin, what each account can do)

**What `-v` does *not* delete** — accounts and config live on disk under `staging/`, not in the database, so they survive `-v` untouched:

- Certificates (`staging/<release>/tak/certs/`)
- File-auth accounts (`staging/<release>/tak/UserAuthenticationFile.xml` — e.g. WebTAK/password logins)
- `CoreConfig.xml`
- `.env`

This means `-v` alone is **not** a full reset — the admin UI will still list accounts afterward, but with their database-side role/permission grants gone, since those lived in the database that was just wiped. Log in and re-check admin rights after a `-v` teardown before assuming everything is back to normal.

### Deleting everything (true clean slate — accounts, certs, config, database)

```bash
docker compose --env-file .env down -v
rm -rf "staging/${TAK_RELEASE}"
bash prepare-tak-docker.sh
```

This also removes certs and `UserAuthenticationFile.xml`, so the next `bash deploy.sh` generates a brand-new CA, certs, and config from scratch — no prior accounts will exist.

---

## 14. Troubleshooting

- **Container status:** `docker compose --env-file .env ps`
- **TAK logs:** `docker exec takserver tail -f /opt/tak/logs/takserver-messaging.log /opt/tak/logs/takserver-api.log`
- **Init container failed:** `docker compose --env-file .env logs init`
- **Re-run setup:** `bash post-start.sh` is safe to run again if something didn't complete
- **Start over:** [tear down](#13-tear-down), then repeat from [step 6](#6-deploy)
- **Build fails with `unable to prepare context: path "staging/<release>" not found`:** the staged release directory exists but your user can't read it — either it's owned by a different user (e.g. root, from a `sudo bash prepare-tak-docker.sh` run) or, less commonly, the vendor zip stored it without the execute/traverse bit. `prepare-tak-docker.sh` normalizes this automatically as of this package; if you're still hitting it, fix it directly and retry:
  ```bash
  sudo chown -R "$(id -un):$(id -gn)" staging/<release>
  sudo chmod -R u+rwX,go+rX staging/<release>
  bash deploy.sh
  ```
  Never run `prepare-tak-docker.sh` with `sudo` — it doesn't need root, and doing so recreates this exact problem.
- **Build fails with `unable to prepare context: path ... not found` right after a `Bake` warning:** Compose tried to build with Bake, which needs the `docker-buildx-plugin` package. `deploy.sh` already sets `export COMPOSE_BAKE=false` for you; if you're running `docker compose` by hand instead, set that yourself (see [step 2](#2-install-docker)) and retry, or install `docker-buildx-plugin` if you'd rather use Bake.
- **`keytool error: ... Permission denied` writing a `.jks` file during Let's Encrypt setup:** `certs/files` is root-owned (the init container that generates the original certs runs as root); `apply-letsencrypt.sh` runs its own cert-writing commands under `sudo` to handle this, but if you're on an older copy of this package that predates that fix, `sudo chown -R "$(id -u):$(id -g)" staging/<release>/tak/certs/files` and re-run `bash post-start.sh`.
- **Upgrading to a newer release later?** See [AUTO_UPGRADE.md](AUTO_UPGRADE.md) — it's just a `TAK_RELEASE` change in `.env`, handled safely without losing your database.
