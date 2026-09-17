#!/usr/bin/env bash
# One-time prerequisite setup for a fresh supported Ubuntu host.
# Run as a normal sudo-capable user: bash bootstrap-ubuntu.sh
set -euo pipefail

if [[ "${EUID}" -eq 0 ]]; then
  echo "Run this script as a normal sudo-capable user, not directly as root." >&2
  exit 1
fi

if [[ ! -r /etc/os-release ]]; then
  echo "ERROR: cannot identify the operating system." >&2
  exit 1
fi

# shellcheck disable=SC1091
source /etc/os-release
if [[ "${ID:-}" != "ubuntu" ]]; then
  echo "ERROR: this bootstrap supports Ubuntu only (detected: ${ID:-unknown})." >&2
  exit 1
fi

case "${VERSION_ID:-}" in
  22.04|24.04|26.04) ;;
  *)
    echo "ERROR: Ubuntu ${VERSION_ID:-unknown} is not a supported target for this script." >&2
    exit 1
    ;;
esac

if command -v docker >/dev/null 2>&1; then
  if docker compose version >/dev/null 2>&1 || sudo docker compose version >/dev/null 2>&1; then
    echo "Docker Engine and the Compose plugin are already available; nothing to install."
    exit 0
  fi
  echo "ERROR: Docker is already installed but the Compose plugin is unavailable." >&2
  echo "Resolve the existing Docker installation before running this bootstrap." >&2
  exit 1
fi

# Do not remove potentially in-use packages automatically. Docker documents
# these as conflicts with its official packages.
CONFLICTS=(docker.io docker-compose docker-compose-v2 docker-doc docker-buildx podman-docker containerd runc)
INSTALLED=()
for package in "${CONFLICTS[@]}"; do
  if dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null | grep -qx installed; then
    INSTALLED+=("$package")
  fi
done
if (( ${#INSTALLED[@]} > 0 )); then
  echo "ERROR: conflicting packages are installed: ${INSTALLED[*]}" >&2
  echo "Do not remove Docker-related packages automatically on a host that may have workloads." >&2
  echo "Review Docker's Ubuntu installation guidance, remove or migrate them deliberately, then retry." >&2
  exit 1
fi

sudo -v
echo "Installing Docker Engine and Docker Compose plugin from Docker's official APT repository..."
sudo apt-get update
sudo apt-get install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${UBUNTU_CODENAME:-$VERSION_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl enable --now docker
sudo usermod -aG docker "$USER"

echo
echo "Docker installation complete."
sudo docker version --format 'Server: {{.Server.Version}}'
sudo docker compose version
echo
echo "Log out and back in before using Docker without sudo, then run:"
echo "  cd docker"
echo "  cp env.example .env"
echo "  bash deploy.sh"
echo
echo "The docker group grants root-equivalent access; add only trusted users."
