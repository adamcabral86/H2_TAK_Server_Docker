# TAK Server — Automated Upgrade Guide

How to move this Docker Compose deployment to a newer TAK Server release using `upgrade-tak-docker.sh`, which automates the backup/check/stage/cutover/verify procedure without losing your database, certificates, or configuration.

Because `docker-compose.yml` is version-agnostic (it reads which release to run from `TAK_RELEASE` in `.env`), the script's job is simpler than it sounds: stage the new release into its own subfolder, edit two variables in `.env`, bring the stack back up.

> **Want to do it by hand instead, or understand what this script is actually doing?** See [MANUAL_UPGRADE.md](MANUAL_UPGRADE.md) — same procedure, spelled out as manual commands. Also the place to look if the script gets stuck partway through and you need to finish or recover manually.

## Contents

1. [What it does](#1-what-it-does)
2. [What it deliberately doesn't automate](#2-what-it-deliberately-doesnt-automate)
3. [Usage](#3-usage)
4. [Safety guarantees](#4-safety-guarantees)
5. [Rolling back](#5-rolling-back)
6. [Troubleshooting](#6-troubleshooting)

---

## 1. What it does

1. **Reads your current deployment straight from `.env`** — `TAK_RELEASE` and `DB_VOLUME`, no guessing or file-name parsing needed. Reads the new release's version straight out of the new zip you point it at.
2. **Backs up first, always** — `pg_dump` of the database, your certs, `UserAuthenticationFile.xml` (File-auth accounts — e.g. WebTAK users with no client cert; this lives outside Postgres entirely), your current `CoreConfig.xml`, and a copy of `.env` itself, into a timestamped `backups/<timestamp>/` directory. This happens before anything else, no flag required.
3. **Checks Postgres compatibility** — compares the *actual running* Postgres major version against the new release's `Dockerfile.takserver-db`. If they differ, it stops and tells you to re-run with `--migrate-db` rather than guessing.
4. **Stages the new release** by calling `prepare-tak-docker.sh`, which only touches the new release's own subfolder under `staging/` — the currently-running release's tree is never touched. Certs and `UserAuthenticationFile.xml` are restored into the new tree *before* any container starts, so the existing `init-tak-config.sh` logic builds a fresh, version-correct `CoreConfig.xml` around them using your `.env` values, instead of needing a hand-written config merge.
5. **Updates `.env` in place** — `TAK_RELEASE` always, and `DB_VOLUME` only when migrating databases (pointed at a new, unique volume name so it can't collide with the old one).
6. **Cuts over**:
   - **Same Postgres major version:** stop the stack, update `.env`, bring it back up with `docker compose --env-file .env up -d --build` — same volume, new release.
   - **Different major version (`--migrate-db`):** stop the stack, update `.env` (new release + new volume name), bring up `db`+`init` against the fresh volume, restore the `pg_dump`, then bring up `tak`.
7. **Verifies every table, not just `cot_router`, and auto-heals anything missing.** Reusing the same Postgres volume does *not* guarantee nothing was touched — TAK's own `SchemaManager.jar` migration (which runs on every `db` container start) has been observed to silently drop rows from a table and reset its sequence. This step does a whole-row comparison of every table against the pre-upgrade dump, restores anything missing (retrying across passes to handle foreign-key ordering), and re-syncs any serial primary-key sequence it touches. If something still can't be auto-restored after retries, the script warns loudly and points at exactly which rows and table need manual review — it does not silently continue.
8. **Runs `post-start.sh`** against the new release — reusing its existing, idempotent logic for enrollment, store-and-forward chat, admin cert promotion, admin password, Let's Encrypt, and copying certs to `~/takserver-certs`. No path overrides needed — it reads `TAK_RELEASE` from the now-updated `.env` itself.
9. **Leaves everything reversible** — the old release's `staging/` subfolder and (in a DB migration) the old volume are never deleted. Rolling back is just restoring the backed-up `.env`.

---

## 2. What it deliberately doesn't automate

- **`CoreConfig.xml` customizations beyond `.env`.** If you'd hand-edited things like custom inputs, auth backends, or extra connectors, the script won't guess how to merge those into the newly-generated config. It prints the exact `diff` command to compare your old config against the new one at the end — you re-apply anything custom yourself.
- **Declaring success.** It checks containers are running, ports are listening, and does a full row-by-row verification (and auto-heal) of every table against the pre-upgrade dump — but it can't confirm your missions/users/data all *look* correct to you. Log into the admin UI and check before you delete anything the script left behind.

---

## 3. Usage

First, get the new release zip into `vendor/` and make the script executable (`chmod +x` is one-time; you'll repeat the `cp` for each future upgrade):

```bash
cp /path/to/takserver-docker-<new-version>.zip vendor/
chmod +x upgrade-tak-docker.sh
```

Then run **one** of the following, depending on what you're doing:

**Not sure if the Postgres major version changes?** Just run the standard upgrade first — the script checks for you and tells you to re-run with `--migrate-db` if it's needed. It won't proceed with an incompatible migration silently.

### Standard upgrade (same Postgres major version)
```bash
bash upgrade-tak-docker.sh vendor/takserver-docker-<new-version>.zip
```

### Upgrade that changes Postgres major version (e.g. 5.7 → 5.8)
```bash
bash upgrade-tak-docker.sh vendor/takserver-docker-<new-version>.zip --migrate-db
```

### Preview only — nothing is changed
```bash
bash upgrade-tak-docker.sh vendor/takserver-docker-<new-version>.zip --dry-run
```

### Undo the most recent upgrade
```bash
bash upgrade-tak-docker.sh --rollback
```

The script will:
1. Print the current release (from `.env`), the new release, and both Postgres versions.
2. Back up the database, certs, `UserAuthenticationFile.xml`, `CoreConfig.xml`, and `.env`, then ask you to confirm before continuing.
3. Stage the new release into its own `staging/` subfolder and restore certs and `UserAuthenticationFile.xml` into it.
4. Ask you to confirm before stopping the current stack.
5. Stop the stack, update `TAK_RELEASE` (and `DB_VOLUME`, if `--migrate-db`) in `.env`, and bring the new release up.
6. Verify every table against the pre-upgrade dump and auto-heal anything missing.
7. Run `post-start.sh` against it.
8. Print where your backup lives, the `diff` command for `CoreConfig.xml`, and how to roll back if needed.

If you added `--migrate-db`, step 5 differs slightly: the script brings up `db`+`init` against the fresh volume first, restores the database dump, then brings up `tak` — step 6 (verify/heal) runs the same way either way.

---

## 4. Safety guarantees

- **Backups happen unconditionally**, before any prompt or destructive action, and are never skipped by `--yes`.
- **`docker compose down -v` is never used** — the database volume is never destroyed by this script.
- **The old release's `staging/` subfolder is never touched or deleted** — `prepare-tak-docker.sh` only clears the specific subfolder it's staging.
- **A fresh volume is used for `--migrate-db`**, so the old volume is untouched and available as a fallback even after a successful migration.
- **Nothing is cleaned up automatically.** You decide when to delete the old staging subfolder or old volume, after you've verified the new stack yourself.

---

## 5. Rolling back

```bash
bash upgrade-tak-docker.sh --rollback
```

This reads `.last-upgrade-state` (written at the start of the most recent upgrade run), stops the current stack, restores the backed-up `.env` (putting `TAK_RELEASE` and `DB_VOLUME` back to what they were), and brings the old release back up. The failed upgrade's staged release is left in place under `staging/` for you to inspect rather than deleted.

If you migrated to a new database volume and need to roll back, restoring `.env` is all that's needed — the old volume was never touched, so nothing has to be moved back.

---

## 6. Troubleshooting

- **"TAK_RELEASE is not set in .env"** — this deployment hasn't been through the new `.env`-driven setup yet, or `.env` is missing/misconfigured. Check `.env` against `env.example`.
- **"Postgres major version changes... re-run with --migrate-db"** — expected safety stop, not an error. Re-run with the flag.
- **`init` container hangs during `--migrate-db`** — check `docker compose --env-file .env logs init`; usually a `CoreConfig.xml` issue from a cert restore problem.
- **"Table 'X' STILL has N row(s) missing after retries — needs manual review"** — the automatic verify/heal step (step 6) couldn't fully restore that table on its own, usually because of a foreign-key dependency it couldn't resolve across passes. Check the referenced file under `backups/<timestamp>/heal/` and restore those rows manually with `psql`/`COPY` before trusting the upgrade — don't delete the old release's `staging/` tree or the backup until you've confirmed this.
- **Script exits partway through** — nothing before the "About to stop the current stack" confirmation touches your running deployment. If it fails after that point, use `--rollback`, or fall back to [MANUAL_UPGRADE.md](MANUAL_UPGRADE.md) to finish the specific step it was on.
