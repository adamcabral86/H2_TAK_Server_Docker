#!/usr/bin/env bash
# Upgrade this TAK Server Docker Compose deployment to a new vendor release
# without losing the database, certificates, or configuration.
#
# Because docker-compose.yml and env.example are version-agnostic (driven by
# TAK_RELEASE / DB_VOLUME in .env), upgrading is: stage the new release
# alongside the current one, update those two variables, and bring the stack
# back up. The old release's staging tree and (in a DB migration) the old
# volume are never deleted, so this is always reversible with --rollback.
#
# See AUTO_UPGRADE.md for usage, or MANUAL_UPGRADE.md for the manual procedure this automates.
#
# Usage:
#   ./upgrade-tak-docker.sh <path-to-new-vendor-zip> [--migrate-db] [--yes] [--dry-run]
#   ./upgrade-tak-docker.sh --rollback
set -euo pipefail

# Use Compose's classic builder instead of Bake — avoids requiring the
# separate buildx plugin to be installed.
export COMPOSE_BAKE=false

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

STATE_FILE="$ROOT/.last-upgrade-state"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$ROOT/backups/$TIMESTAMP"

NEW_ZIP=""
MIGRATE_DB=0
ASSUME_YES=0
DRY_RUN=0
ROLLBACK=0

log() { echo "[upgrade] $*"; }
err() { echo "[upgrade] ERROR: $*" >&2; }
run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[dry-run] $*"
  else
    eval "$@"
  fi
}
confirm() {
  local prompt="$1"
  if [[ "$ASSUME_YES" -eq 1 ]]; then
    return 0
  fi
  read -r -p "[upgrade] $prompt [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

# Compares every table's rows against the pre-upgrade dump and restores anything
# missing. This exists because TAK's own SchemaManager.jar migration (which runs
# on every 'db' container start, regardless of --migrate-db) has been observed to
# silently drop rows from a table AND reset its serial sequence — reusing the same
# Postgres volume (Case A) is not by itself a guarantee nothing was touched.
# Whole-row comparison, not just counts, so a table with the same row count but
# different specific rows is still caught. Runs after every upgrade, not just
# --migrate-db. Costs real time on a large database (dumps + sorts every table);
# that's the accepted trade-off for zero tolerated data loss.
verify_and_heal_all_tables() {
  log "Verifying every table's data against the pre-upgrade snapshot (this can take a moment)..."

  local deadline=$((SECONDS + WAIT_TIMEOUT_SEC))
  until docker exec -u postgres "$DB_CONTAINER" psql -U postgres -d "$DB_NAME" -tAc "SELECT 1;" >/dev/null 2>&1; do
    if (( SECONDS >= deadline )); then
      err "Database did not become ready within ${WAIT_TIMEOUT_SEC}s — cannot verify table data"
      return 1
    fi
    sleep 3
  done

  local heal_dir="$BACKUP_DIR/heal"
  mkdir -p "$heal_dir"
  local tables
  tables="$(docker exec -u postgres "$DB_CONTAINER" psql -U postgres -d "$DB_NAME" -tAc \
    "SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename;")"

  local any_missing_ever=0 pass tbl old_file live_file missing_file old_count missing_count collist

  for pass in 1 2 3; do
    local missing_this_pass=0
    for tbl in $tables; do
      old_file="$heal_dir/${tbl}.old.tsv"
      # Extract once — identical across passes, the dump itself never changes.
      if [[ ! -f "$old_file" ]]; then
        awk -v pat="^COPY public\\.${tbl} " '$0 ~ pat{flag=1; next} /^\\\.$/{flag=0} flag' "$BACKUP_DIR/db-dump.sql" \
          | sort > "$old_file"
      fi
      old_count=$(wc -l < "$old_file")
      [[ "$old_count" -eq 0 ]] && continue   # table was empty or didn't exist pre-upgrade

      live_file="$heal_dir/${tbl}.live.tsv"
      docker exec -u postgres "$DB_CONTAINER" psql -U postgres -d "$DB_NAME" -c "COPY \"$tbl\" TO STDOUT" 2>/dev/null \
        | sort > "$live_file"

      missing_file="$heal_dir/${tbl}.missing.tsv"
      comm -23 "$old_file" "$live_file" > "$missing_file"
      if [[ -s "$missing_file" ]]; then
        any_missing_ever=1
        missing_this_pass=1
        err "Table '$tbl': $(wc -l < "$missing_file") row(s) from before the upgrade are missing now — restoring..."
        collist="$(grep "^COPY public.${tbl} " "$BACKUP_DIR/db-dump.sql" | head -1 | sed -E "s/^COPY public\.${tbl} \((.*)\) FROM stdin;\$/\1/")"
        if docker exec -i -u postgres "$DB_CONTAINER" psql -U postgres -d "$DB_NAME" -c \
          "COPY \"$tbl\" ($collist) FROM STDIN" < "$missing_file" 2>"$heal_dir/${tbl}.err"; then
          log "  restored into '$tbl'"
        else
          log "  WARN: restore into '$tbl' failed this pass (likely a foreign-key dependency not yet restored) — will retry"
        fi
      fi
    done
    [[ "$missing_this_pass" -eq 0 ]] && break
  done

  # Re-sync any single-column serial primary key's sequence for tables we touched,
  # so future inserts can't collide with the ids we just restored.
  for tbl in $tables; do
    [[ -s "$heal_dir/${tbl}.missing.tsv" ]] || continue
    local pkcols npk pkcol
    pkcols="$(docker exec -u postgres "$DB_CONTAINER" psql -U postgres -d "$DB_NAME" -tAc "
      SELECT a.attname FROM pg_index i
      JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
      WHERE i.indrelid = '\"${tbl}\"'::regclass AND i.indisprimary;")"
    npk="$(printf '%s\n' "$pkcols" | grep -c . || true)"
    if [[ "$npk" -eq 1 ]]; then
      pkcol="$pkcols"
      docker exec -u postgres "$DB_CONTAINER" psql -U postgres -d "$DB_NAME" -c "
        DO \$\$
        DECLARE seqname text;
        BEGIN
          seqname := pg_get_serial_sequence('${tbl}', '${pkcol}');
          IF seqname IS NOT NULL THEN
            PERFORM setval(seqname, GREATEST((SELECT COALESCE(max(\"${pkcol}\"),0) FROM \"${tbl}\"), 1), true);
          END IF;
        END \$\$;" >/dev/null 2>&1 || true
    fi
  done

  # Final pass — confirm nothing is still missing after retries.
  local still_missing=0
  for tbl in $tables; do
    missing_file="$heal_dir/${tbl}.missing.tsv"
    [[ -f "$missing_file" ]] || continue
    live_file="$heal_dir/${tbl}.live.tsv"
    docker exec -u postgres "$DB_CONTAINER" psql -U postgres -d "$DB_NAME" -c "COPY \"$tbl\" TO STDOUT" 2>/dev/null \
      | sort > "$live_file"
    comm -23 "$heal_dir/${tbl}.old.tsv" "$live_file" > "$heal_dir/${tbl}.still-missing.tsv"
    if [[ -s "$heal_dir/${tbl}.still-missing.tsv" ]]; then
      still_missing=1
      err "Table '$tbl' STILL has $(wc -l < "$heal_dir/${tbl}.still-missing.tsv") row(s) missing after retries — needs manual review: $heal_dir/${tbl}.still-missing.tsv"
    fi
  done

  if [[ "$still_missing" -eq 1 ]]; then
    err "Data verification found rows that could NOT be auto-restored. Do not trust this upgrade until you review the files above."
    return 1
  elif [[ "$any_missing_ever" -eq 1 ]]; then
    log "All missing rows were found and restored successfully."
  else
    log "Verified: every table matches its pre-upgrade state — no rows lost."
  fi
}

# --- argument parsing ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --migrate-db) MIGRATE_DB=1; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --rollback) ROLLBACK=1; shift ;;
    -h|--help)
      sed -n '2,15p' "$0"
      exit 0
      ;;
    *)
      if [[ -z "$NEW_ZIP" ]]; then
        NEW_ZIP="$1"
      else
        err "Unexpected argument: $1"
        exit 1
      fi
      shift
      ;;
  esac
done

if [[ ! -f .env ]]; then
  err ".env not found — run this from deploy/docker/ with an existing deployment."
  exit 1
fi
set -a
# shellcheck disable=SC1091
source .env
set +a

TAK_CONTAINER="${TAK_CONTAINER:-takserver}"
DB_CONTAINER="${DB_CONTAINER:-tak-database}"
DB_NAME="${DB_NAME:-cot}"
WAIT_TIMEOUT_SEC="${WAIT_TIMEOUT_SEC:-300}"
CURRENT_RELEASE_DIR="${TAK_RELEASE:-}"
CURRENT_DB_VOLUME="${DB_VOLUME:-tak_db_data}"

if [[ -z "$CURRENT_RELEASE_DIR" ]]; then
  err "TAK_RELEASE is not set in .env"
  exit 1
fi

# --- rollback path ---
if [[ "$ROLLBACK" -eq 1 ]]; then
  if [[ ! -f "$STATE_FILE" ]]; then
    err "No $STATE_FILE found — nothing to roll back to."
    exit 1
  fi
  # shellcheck disable=SC1090
  source "$STATE_FILE"
  log "Rolling back: TAK_RELEASE $CURRENT_RELEASE_DIR -> $PREV_TAK_RELEASE (DB_VOLUME $CURRENT_DB_VOLUME -> $PREV_DB_VOLUME)"
  if ! confirm "Stop the current stack and restore the previous .env / release?"; then
    log "Aborted."
    exit 1
  fi
  run "docker compose --env-file .env down"
  run "cp '$ENV_BACKUP' .env"
  # TAK_RELEASE/DB_VOLUME were exported into this script's own environment by the
  # 'source .env' near the top — an exported shell var takes precedence over
  # --env-file for docker compose's variable substitution, so without re-sourcing
  # here 'up --build' would silently use the pre-rollback values instead of what
  # was just restored into .env.
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
  run "docker compose --env-file .env up -d --build"
  log "Rolled back. The failed upgrade's staging tree (staging/$CURRENT_RELEASE_DIR) was left in place for inspection."
  exit 0
fi

# --- normal upgrade path ---
if [[ -z "$NEW_ZIP" ]]; then
  err "Usage: $0 <path-to-new-vendor-zip> [--migrate-db] [--yes] [--dry-run]"
  err "       $0 --rollback"
  exit 1
fi
if [[ ! -f "$NEW_ZIP" ]]; then
  err "Zip not found: $NEW_ZIP"
  exit 1
fi

log "Current release: $CURRENT_RELEASE_DIR (from .env)"

NEW_RELEASE_DIR="$(unzip -Z1 "$NEW_ZIP" | head -n1 | cut -d/ -f1)" || true
if [[ -z "$NEW_RELEASE_DIR" ]]; then
  err "Could not determine the release folder name inside $NEW_ZIP"
  exit 1
fi
NEW_RELEASE="$(unzip -p "$NEW_ZIP" "$NEW_RELEASE_DIR/tak/version.txt" 2>/dev/null || true)"
log "New release: ${NEW_RELEASE:-unknown} (staging/$NEW_RELEASE_DIR)"

if [[ "$CURRENT_RELEASE_DIR" == "$NEW_RELEASE_DIR" ]]; then
  err "New release matches the current one ($CURRENT_RELEASE_DIR) — nothing to do."
  exit 1
fi

CURRENT_TAK_ROOT="$ROOT/staging/$CURRENT_RELEASE_DIR/tak"
if [[ ! -d "$CURRENT_TAK_ROOT" ]]; then
  err "Current release not found at staging/$CURRENT_RELEASE_DIR — is the stack actually staged?"
  exit 1
fi

# --- Postgres compatibility check ---
log "Checking Postgres compatibility..."
# docker exec runs as root by default, which doesn't match any Postgres role under
# peer auth (this image's pg_hba.conf requires the OS user and role to match for
# local socket connections) — run as the postgres OS user/role instead, which
# always exists on a Debian-packaged Postgres install and is always a superuser.
OLD_PG_MAJOR="$(docker exec -u postgres "$DB_CONTAINER" psql -U postgres -d "$DB_NAME" -tAc "SHOW server_version;" 2>/dev/null \
  | grep -oE '^[0-9]+' || true)"
if [[ -z "$OLD_PG_MAJOR" ]]; then
  err "Could not read the running Postgres version from $DB_CONTAINER. Is it running?"
  exit 1
fi
NEW_PG_MAJOR="$(unzip -p "$NEW_ZIP" "$NEW_RELEASE_DIR/docker/Dockerfile.takserver-db" 2>/dev/null \
  | grep -oE 'FROM postgres:[0-9]+' | grep -oE '[0-9]+$' || true)"
if [[ -z "$NEW_PG_MAJOR" ]]; then
  err "Could not read the Postgres version from the new zip's Dockerfile.takserver-db"
  exit 1
fi
log "Running Postgres: $OLD_PG_MAJOR  |  New release's Postgres: $NEW_PG_MAJOR"

if [[ "$OLD_PG_MAJOR" != "$NEW_PG_MAJOR" ]]; then
  if [[ "$MIGRATE_DB" -ne 1 ]]; then
    err "Postgres major version changes ($OLD_PG_MAJOR -> $NEW_PG_MAJOR)."
    err "The existing database volume CANNOT be reused directly against the new version."
    err "Re-run with --migrate-db to dump/restore the database into a fresh volume."
    exit 1
  fi
  log "Postgres major version differs — will dump/restore into a fresh volume (Case B)."
else
  log "Postgres major version matches — reusing the existing volume (Case A)."
fi

# --- backup ---
log "Backing up to $BACKUP_DIR ..."
run "mkdir -p '$BACKUP_DIR'"
if [[ "$DRY_RUN" -ne 1 ]]; then
  log "Dumping database ($DB_NAME)..."
  docker exec -u postgres "$DB_CONTAINER" pg_dump -U postgres "$DB_NAME" > "$BACKUP_DIR/db-dump.sql"

  log "Copying certs, CoreConfig.xml, UserAuthenticationFile.xml, and .env..."
  cp -a "$CURRENT_TAK_ROOT/certs/files" "$BACKUP_DIR/certs-files"
  [[ -f "$CURRENT_TAK_ROOT/CoreConfig.xml" ]] && cp "$CURRENT_TAK_ROOT/CoreConfig.xml" "$BACKUP_DIR/CoreConfig.xml.old"
  # File-auth accounts (e.g. WebTAK users with no client cert) live entirely in this
  # flat file, not Postgres — without backing it up here, a fresh-staged release gets
  # the vendor's empty default and every such account silently disappears.
  [[ -f "$CURRENT_TAK_ROOT/UserAuthenticationFile.xml" ]] && cp "$CURRENT_TAK_ROOT/UserAuthenticationFile.xml" "$BACKUP_DIR/UserAuthenticationFile.xml.old"
  cp .env "$BACKUP_DIR/env.old"
fi
ENV_BACKUP="$BACKUP_DIR/env.old"
log "Backup complete: $BACKUP_DIR"

if ! confirm "Backup complete. Proceed with staging and deploying $NEW_RELEASE_DIR?"; then
  log "Aborted after backup — nothing else was changed. Your backup is at $BACKUP_DIR"
  exit 1
fi

# --- stage the new release (leaves the current release's staging dir untouched) ---
log "Staging new release..."
run "bash '$ROOT/prepare-tak-docker.sh' '$NEW_ZIP'"
NEW_TAK_ROOT="staging/$NEW_RELEASE_DIR/tak"

# Restore certs into the new tree BEFORE the init container runs, so
# init-tak-config.sh treats certs as already-present and builds a fresh,
# version-correct CoreConfig.xml around them using this deployment's .env values.
log "Restoring certificates into the new release..."
run "mkdir -p '$ROOT/$NEW_TAK_ROOT/certs/files'"
run "cp -a '$BACKUP_DIR/certs-files/.' '$ROOT/$NEW_TAK_ROOT/certs/files/'"

if [[ -f "$BACKUP_DIR/UserAuthenticationFile.xml.old" ]]; then
  log "Restoring UserAuthenticationFile.xml (File-auth accounts) into the new release..."
  run "cp '$BACKUP_DIR/UserAuthenticationFile.xml.old' '$ROOT/$NEW_TAK_ROOT/UserAuthenticationFile.xml'"
fi

# --- record rollback state before touching .env or the running stack ---
NEW_DB_VOLUME="$CURRENT_DB_VOLUME"
if [[ "$MIGRATE_DB" -eq 1 ]]; then
  NEW_DB_VOLUME="tak_db_data_${TIMESTAMP}"
fi
cat > "$STATE_FILE" <<EOF
TIMESTAMP=$TIMESTAMP
PREV_TAK_RELEASE=$CURRENT_RELEASE_DIR
PREV_DB_VOLUME=$CURRENT_DB_VOLUME
NEW_TAK_RELEASE=$NEW_RELEASE_DIR
NEW_DB_VOLUME=$NEW_DB_VOLUME
ENV_BACKUP=$ENV_BACKUP
BACKUP_DIR=$BACKUP_DIR
MIGRATED_DB=$MIGRATE_DB
EOF

if ! confirm "About to stop the current stack and switch .env to TAK_RELEASE=$NEW_RELEASE_DIR. Continue?"; then
  log "Aborted before cutover — nothing was changed. Backup remains at $BACKUP_DIR"
  exit 1
fi

# --- cutover ---
log "Stopping current stack (database volume is preserved)..."
run "docker compose --env-file .env down"

log "Updating .env (TAK_RELEASE, DB_VOLUME)..."
run "sed -i -E 's#^TAK_RELEASE=.*#TAK_RELEASE=${NEW_RELEASE_DIR}#' .env"
run "sed -i -E 's#^DB_VOLUME=.*#DB_VOLUME=${NEW_DB_VOLUME}#' .env"

# TAK_RELEASE/DB_VOLUME were exported into this script's own environment by the
# 'source .env' near the top — an exported shell var takes precedence over
# --env-file for docker compose's variable substitution, so without re-sourcing
# here every 'docker compose ... --build' below would silently keep using the
# OLD release/volume despite the file edit above (the build would even tag
# images with the old release name, and init would mount the old release's
# staging tree instead of the new one).
if [[ "$DRY_RUN" -ne 1 ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

if [[ "$MIGRATE_DB" -eq 1 ]]; then
  log "Bringing up db + init against a fresh volume ($NEW_DB_VOLUME)..."
  run "docker compose --env-file .env up -d db init"
  if [[ "$DRY_RUN" -ne 1 ]]; then
    log "Waiting for init to finish..."
    deadline=$((SECONDS + WAIT_TIMEOUT_SEC))
    while docker compose --env-file .env ps init 2>/dev/null | grep -q "Up\|running"; do
      if (( SECONDS >= deadline )); then
        err "init container did not finish within ${WAIT_TIMEOUT_SEC}s"
        exit 1
      fi
      sleep 3
    done
    log "Restoring database dump into the new volume..."
    docker exec -i -u postgres "$DB_CONTAINER" psql -U postgres "$DB_NAME" < "$BACKUP_DIR/db-dump.sql"
  fi
  log "Bringing up the tak service..."
  run "docker compose --env-file .env up -d"
else
  log "Bringing up the full new stack (reusing the existing database volume)..."
  run "docker compose --env-file .env up -d --build"
fi

# --- verify no rows were lost across ANY table, and heal anything that was ---
if [[ "$DRY_RUN" -ne 1 ]]; then
  verify_and_heal_all_tables || \
    log "WARN: table verification reported unresolved data loss — see errors above before trusting this upgrade"
fi

# --- post-start (enrollment, store-forward, admin promote/password, LE, cert copy) ---
if [[ "$DRY_RUN" -ne 1 ]]; then
  log "Running post-start.sh against the new release..."
  "$ROOT/post-start.sh" || \
    log "WARN: post-start.sh reported an issue — review its output above before trusting this upgrade"
fi

echo
log "Upgrade to $NEW_RELEASE_DIR complete."
log "Old staging tree preserved at: staging/$CURRENT_RELEASE_DIR"
if [[ "$MIGRATE_DB" -eq 1 ]]; then
  log "Old database volume preserved: $CURRENT_DB_VOLUME (untouched)"
fi
log "Backup (dump + certs + old .env): $BACKUP_DIR"
echo
log "If your CoreConfig.xml had customizations beyond what .env drives (custom inputs, auth backends, etc.),"
log "diff and re-apply them manually:"
log "  diff '$BACKUP_DIR/CoreConfig.xml.old' '$NEW_TAK_ROOT/CoreConfig.xml'"
echo
log "If something looks wrong, roll back with: $0 --rollback"
