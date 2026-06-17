#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  exec sudo bash "$0" "$@"
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

backup_dir="/etc/apt/sources.list.d/docker-backup-$(date +%Y%m%d%H%M%S)"
mkdir -p "${backup_dir}"

for source_file in /etc/apt/sources.list.d/docker.list /etc/apt/sources.list.d/docker.sources /etc/apt/sources.list.d/download_docker_com_linux_ubuntu.list; do
  [[ -e "${source_file}" ]] || continue
  mv "${source_file}" "${backup_dir}/"
done

apt update
apt install -y ca-certificates curl

install -m 0755 -d /etc/apt/keyrings
rm -f /etc/apt/keyrings/docker.asc /etc/apt/keyrings/docker.gpg

curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

docker_suite="${UBUNTU_CODENAME:-${VERSION_CODENAME}}"

cat > /etc/apt/sources.list.d/docker.sources <<EOF_DOCKER_REPO
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${docker_suite}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF_DOCKER_REPO

apt update

cat <<'DONE'

Docker apt keyring repaired.

Old Docker apt source files were moved to:
DONE
printf '  %s\n\n' "${backup_dir}"
cat <<'DONE'

You can now install Docker with:
  sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

DONE
