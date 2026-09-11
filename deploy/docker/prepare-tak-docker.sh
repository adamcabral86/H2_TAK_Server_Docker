#!/usr/bin/env bash
# Unpack an official takserver-docker zip into staging/, without disturbing
# any other release already staged there. Usage:
#   ./prepare-tak-docker.sh [path-to-zip]
# If omitted, uses the zip in vendor/ — but only if exactly one non-hardened
# one exists there. With more than one, you must specify which.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
VENDOR="$ROOT/vendor"
STAGING="$ROOT/staging"

cd "$ROOT"
if [[ -f .env ]]; then
  # shellcheck disable=SC1091
  set -a
  # shellcheck source=/dev/null
  source .env
  set +a
fi

mkdir -p "$VENDOR" "$STAGING"

# The deployment zip may have been built on a non-Unix system (e.g. Windows),
# which typically doesn't store real Unix permission bits in zip entries.
# unzip can then extract empty directory entries (like staging/) with unusable
# permissions (sometimes even mode 000). chmod only requires ownership, not
# existing permission, so this repairs it unconditionally regardless of what
# unzip left behind.
chmod u+rwx,go+rx "$VENDOR" "$STAGING"

ZIP="${1:-}"
if [[ -z "$ZIP" ]]; then
  mapfile -t CANDIDATES < <(ls -1 "$VENDOR"/takserver-docker-[0-9]*.zip 2>/dev/null | grep -v hardened || true)
  if [[ "${#CANDIDATES[@]}" -eq 0 ]]; then
    echo "ERROR: Place a takserver-docker-*.zip in:"
    echo "  $VENDOR"
    echo "Examples: takserver-docker-5.7-RELEASE-*.zip"
    echo "Download from https://tak.gov/ (TAK Product Center)."
    exit 1
  elif [[ "${#CANDIDATES[@]}" -gt 1 ]]; then
    echo "ERROR: multiple vendor zips found — specify which one to stage:"
    printf '  %s\n' "${CANDIDATES[@]}"
    echo "Usage: $0 <path-to-zip>"
    exit 1
  fi
  ZIP="${CANDIDATES[0]}"
fi

if [[ ! -f "$ZIP" ]]; then
  echo "ERROR: zip not found: $ZIP"
  exit 1
fi

RELEASE_DIR="$(unzip -Z1 "$ZIP" | head -n1 | cut -d/ -f1)" || true
if [[ -z "$RELEASE_DIR" ]]; then
  echo "ERROR: could not determine the release folder name inside $ZIP"
  exit 1
fi

echo "Using zip: $ZIP"
echo "Release:   $RELEASE_DIR"

# Only clear this release's own subfolder — other staged releases are left alone.
if ! rm -rf "${STAGING:?}/${RELEASE_DIR:?}" 2>/tmp/prepare-tak-docker.rm-err; then
  echo "ERROR: could not remove existing staging/$RELEASE_DIR:"
  cat /tmp/prepare-tak-docker.rm-err >&2
  echo
  echo "This almost always means it's owned by a different user (e.g. root, from a"
  echo "previous 'sudo ./prepare-tak-docker.sh' run) or has its execute/traverse bit"
  echo "stripped. Fix it and re-run WITHOUT sudo — re-running this script with sudo"
  echo "just recreates the same problem and will make 'docker compose ... --build'"
  echo "fail later with a confusing 'unable to prepare context: path ... not found'"
  echo "error, even after chown, if only ownership (not the execute bit) is fixed:"
  echo "  sudo chown -R \"\$(id -un):\$(id -gn)\" '$STAGING/$RELEASE_DIR'"
  echo "  sudo chmod -R u+rwX,go+rX '$STAGING/$RELEASE_DIR'"
  echo "  $0 $ZIP"
  rm -f /tmp/prepare-tak-docker.rm-err
  exit 1
fi
rm -f /tmp/prepare-tak-docker.rm-err
unzip -q "$ZIP" -d "$STAGING"

# Vendor zips sometimes store restrictive permissions on directories (occasionally
# even missing the execute/traverse bit entirely). Normalize so the staged tree is
# always readable/traversable by whoever runs this — otherwise 'docker compose
# ... --build' can fail later with a confusing "path ... not found" even though
# the directory clearly exists.
chmod -R u+rwX,go+rX "$STAGING/$RELEASE_DIR"

TAK_ROOT="$STAGING/$RELEASE_DIR/tak"
if [[ ! -d "$TAK_ROOT" ]]; then
  # Vendor layouts vary — fall back to a search within this release's own tree.
  FOUND="$(find "$STAGING/$RELEASE_DIR" -maxdepth 3 -type d -name tak 2>/dev/null | head -n1 || true)"
  if [[ -z "$FOUND" ]]; then
    echo "ERROR: could not find tak/ inside the zip. Contents:"
    find "$STAGING/$RELEASE_DIR" -maxdepth 3 -type d | head -50
    exit 1
  fi
  TAK_ROOT="$FOUND"
fi

echo
echo "Staged TAK Server tree at:"
echo "  $TAK_ROOT"
echo
echo "Set this in your .env:"
echo "  TAK_RELEASE=$RELEASE_DIR"
echo
echo "Next:"
echo "  1. cp env.example .env   # set TAK_RELEASE (above), LE_*, CERT_* as needed"
echo "  2. export COMPOSE_BAKE=false   # classic builder, no buildx plugin needed"
echo "  3. docker compose --env-file .env up -d --build"
echo "  4. ./post-start.sh"
echo "  5. Log in at https://localhost:8443/Marti/"
echo
echo "Staged releases under staging/:"
find "$STAGING" -maxdepth 1 -mindepth 1 -type d -printf '  %f\n' 2>/dev/null | sort
