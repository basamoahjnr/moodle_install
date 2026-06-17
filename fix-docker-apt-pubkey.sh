#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  exec sudo -E bash "$0" "$@"
fi

if [[ ! -r /etc/os-release ]]; then
  echo "Cannot read /etc/os-release; this script expects Ubuntu." >&2
  exit 1
fi

# shellcheck disable=SC1091
. /etc/os-release

if [[ "${ID:-}" != "ubuntu" ]]; then
  echo "This Docker apt key repair script expects Ubuntu. Detected: ${ID:-unknown}" >&2
  exit 1
fi

apt update
apt install -y ca-certificates curl gnupg

install -m 0755 -d /etc/apt/keyrings
rm -f /etc/apt/keyrings/docker.gpg

curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

cat > /etc/apt/sources.list.d/docker.list <<EOF_DOCKER_REPO
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable
EOF_DOCKER_REPO

apt update

cat <<'DONE'

Docker apt keyring repaired.

You can now install Docker with:
  sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

DONE
