#!/usr/bin/env bash
# Disable the site-wide messaging system ($CFG->messaging = 0). This turns off
# the messaging drawer, message sending, and related notifications UI.

set -Eeuo pipefail
MOODLE_DIR="/var/www/moodle"
PHP_VERSION="${PHP_VERSION:-8.3}"
PHP_CLI_BIN="php${PHP_VERSION}"

log() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\n\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
[[ "${EUID}" -ne 0 ]] && exec sudo bash "$0" "$@"
[[ -f "${MOODLE_DIR}/config.php" ]] || die "Moodle not found at ${MOODLE_DIR}"

set_cfg() { sudo -u www-data "${PHP_CLI_BIN}" "${MOODLE_DIR}/admin/cli/cfg.php" --name="$1" --set="$2"; }

log "Disabling the messaging system"
set_cfg messaging 0

log "Purging caches"
sudo -u www-data "${PHP_CLI_BIN}" "${MOODLE_DIR}/admin/cli/purge_caches.php"
log "Done."
