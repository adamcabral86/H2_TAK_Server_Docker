# TAK Server — Manual Upgrade Guide

How to move this Docker Compose deployment to a newer TAK Server release by hand, without losing your database, certificates, or configuration.

Because `docker-compose.yml` is version-agnostic (it reads which release to run from `TAK_RELEASE` in `.env`), upgrading is fundamentally simple: stage the new release into its own subfolder under `staging/` — alongside the current one, not replacing it — then change `TAK_RELEASE` (and `DB_VOLUME`, only if the Postgres major version changed) in `.env` and bring the stack back up.

> **Prefer not to do this by hand?** See [AUTO_UPGRADE.md](AUTO_UPGRADE.md) — `upgrade-tak-docker.sh` automates every step below. This document is also the reference for what that script is doing at each stage, and how to recover manually if it ever gets stuck partway through.

## Contents

1. [Before you start](#1-before-you-start)
2. [Back everything up](#2-back-everything-up)
3. [Check Postgres compatibility](#3-check-postgres-compatibility)
4. [Stage the new version](#4-stage-the-new-version)
5. [Case A: same Postgres major version](#5-case-a-same-postgres-major-version)
6. [Case B: different Postgres major version](#6-case-b-different-postgres-major-version)
7. [Restore certs and CoreConfig](#7-restore-certs-and-coreconfig)
8. [Bring it up and verify](#8-bring-it-up-and-verify)
9. [Roll back if something goes wrong](#9-roll-back-if-something-goes-wrong)
10. [Troubleshooting](#10-troubleshooting)

---

## 1. Before you start

Three things live outside your control here, and they behave differently:

| What | Where it lives | Survives a normal upgrade? |
|---|---|---|
| PostgreSQL data | Named Docker volume (`DB_VOLUME` in `.env`, default `tak_db_data`) | Yes — untouched by `docker compose down` (no `-v`), rebuilds, or `prepare-tak-docker.sh` |
| Certs, `CoreConfig.xml`, `conf/` | `staging/<release>/tak/`, one subfolder per release | Yes for the *current* release's folder — `prepare-tak-docker.sh` only clears the specific release subfolder it's staging, never the others |
| `.env` | This folder | Yes, but the upgrade changes `TAK_RELEASE` (and possibly `DB_VOLUME`) in place — back it up before editing |

The database survives by default, and so does each release's staged tree — they coexist side by side under `staging/`. Additionally: **never run `docker compose down -v`** during an upgrade — the `-v` flag deletes the active `DB_VOLUME` along with everything else.

---

## 2. Back everything up

Do this before touching anything, regardless of which version you're moving to.

```bash
# Database dump (portable across Postgres versions, unlike the raw volume)
docker exec tak-database pg_dump -U martiuser cot > ~/cot-backup-$(date +%F).sql

# Certs, config, and .env — read TAK_RELEASE from .env first
source .env
cp -a "staging/$TAK_RELEASE/tak/certs/files" ~/tak-certs-backup
cp "staging/$TAK_RELEASE/tak/CoreConfig.xml" ~/CoreConfig-backup.xml
cp .env ~/env-backup
```

---

## 3. Check Postgres compatibility

Postgres data directories are **not** compatible across major versions. Before deploying a new release, check what Postgres version its Docker image uses and compare it to what you're running now:

```bash
# What you're running now (peek inside the currently-staged release's own copy)
grep FROM "staging/$TAK_RELEASE/docker/Dockerfile.takserver-db"

# What the new release uses (don't extract yet — just peek inside the new zip)
unzip -p vendor/takserver-docker-<new-version>.zip \
  takserver-docker-<new-version>/docker/Dockerfile.takserver-db | grep FROM
```

- **Same major version** (e.g. `postgres:15.1` → `postgres:15.4`) → go to [Case A](#5-case-a-same-postgres-major-version).
- **Different major version** (e.g. `postgres:15.1` → `postgres:18.x` — this is the case for 5.7 → 5.8) → go to [Case B](#6-case-b-different-postgres-major-version). Reusing the same `DB_VOLUME` directly against a new major version **will fail to start**.

---

## 4. Stage the new version

Put the new vendor zip in `vendor/`, then stage it — this only touches its own subfolder under `staging/`, leaving the currently-running release's tree alone:

```bash
bash prepare-tak-docker.sh vendor/takserver-docker-<new-version>.zip
```

It prints the exact `TAK_RELEASE=...` value for the new release — note it down, you'll set it in `.env` shortly.

Restore your certs into the new release's tree before starting anything, so `init-tak-config.sh` treats certificates as already-present and builds a fresh, version-correct `CoreConfig.xml` around them:

```bash
cp -a ~/tak-certs-backup/* "staging/takserver-docker-<new-version>/tak/certs/files/"
```

---

## 5. Case A: same Postgres major version

No database migration needed — just point `.env` at the new release and bring the stack back up. The volume name doesn't need to change:

```bash
docker compose --env-file .env down          # no -v
sed -i -E 's#^TAK_RELEASE=.*#TAK_RELEASE=takserver-docker-<new-version>#' .env
docker compose --env-file .env up -d --build
```

Then go to [Restore certs and CoreConfig](#7-restore-certs-and-coreconfig).

---

## 6. Case B: different Postgres major version

You cannot attach the existing volume to the new Postgres major version. Point `.env` at a **new, empty** volume name, then migrate via the SQL dump:

```bash
# Stop the old stack (its volume is untouched — DB_VOLUME still points at it for now)
docker compose --env-file .env down          # no -v

# Point .env at the new release AND a fresh volume
sed -i -E 's#^TAK_RELEASE=.*#TAK_RELEASE=takserver-docker-<new-version>#' .env
sed -i -E 's#^DB_VOLUME=.*#DB_VOLUME=tak_db_data_new#' .env

# Bring up db + init against that fresh volume
docker compose --env-file .env up -d db init

# Wait for init to finish, then restore your data into the new database
docker exec -i tak-database psql -U martiuser cot < ~/cot-backup-$(date +%F).sql

# Now bring up the tak service
docker compose --env-file .env up -d
```

The old volume (whatever `DB_VOLUME` pointed at before you changed it) is untouched and still exists — leave it alone as a safety net until you're confident the new database is good, then `docker volume rm` it if you want to reclaim the space.

---

## 7. Restore certs and CoreConfig

If you followed [step 4](#4-stage-the-new-version), your certificates are already copied into the new release's `certs/files/`. For `CoreConfig.xml`, don't blindly overwrite the new release's version — new releases sometimes add required attributes or elements. Instead, diff your backup against what `init-tak-config.sh` actually generated and manually carry over anything beyond what `.env` already drives (custom inputs, auth backends, federation settings you set by hand):

```bash
diff ~/CoreConfig-backup.xml "staging/takserver-docker-<new-version>/tak/CoreConfig.xml"
```

Then restart the `tak` service to pick up any changes:

```bash
docker compose --env-file .env restart tak
```

---

## 8. Bring it up and verify

```bash
docker compose --env-file .env ps
docker exec takserver tail -50 /opt/tak/logs/takserver-messaging.log
```

It's also worth running `bash post-start.sh` again — it's idempotent, and re-applies enrollment/store-and-forward/admin-promotion/Let's Encrypt against whichever release `.env` now points at.

Log into the admin UI (`https://<host>:8443/Marti/`) and confirm your existing users, missions, and data are all present. Once you're confident everything's good, you can remove the old release's `staging/<old-release>/` directory and, if you migrated to a new volume in Case B, the old volume.

---

## 9. Roll back if something goes wrong

Because the old release's `staging/` subfolder and volume were never deleted, rolling back is just restoring your backed-up `.env` and bringing the old release back up:

```bash
docker compose --env-file .env down   # no -v
cp ~/env-backup .env
docker compose --env-file .env up -d --build
```

Since `.env` again points at the old `TAK_RELEASE` (and old `DB_VOLUME`, if you'd changed it), this brings back exactly what was running before — nothing needs to be moved or renamed.

---

## 10. Troubleshooting

- **New `db` container exits immediately after upgrade:** check `docker compose logs db` — a `FATAL: database files are incompatible with server` error confirms you skipped the Postgres major-version check in [step 3](#3-check-postgres-compatibility) and need [Case B](#6-case-b-different-postgres-major-version) instead.
- **`init` container fails:** check `docker compose logs init` — usually a missing/incompatible `CoreConfig.xml` from restoring the wrong file, or `TAK_RELEASE` in `.env` not matching an actual `staging/` subfolder.
- **Admin login fails after upgrade:** re-run `bash post-start.sh` — see [README.md](README.md#6-deploy) step 6.
- **Not sure what changed between releases:** check `tak/version.txt` in both the old and new `staging/` subfolders, and see [wiki.tak.gov](https://wiki.tak.gov/display/DEV/TAK+Server+Change+Log) for the changelog.
