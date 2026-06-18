#!/usr/bin/env bash
# Make the login page the entry point: force all visitors to log in before
# they can see any page (so anonymous users land on /login instead of the
# site front page). Sets $CFG->forcelogin = 1.

set -Eeuo pipefail
MOODLE_DIR="/var/www/moodle"
PHP_VERSION="${PHP_VERSION:-8.3}"
PHP_CLI_BIN="php${PHP_VERSION}"

log() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\n\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
[[ "${EUID}" -ne 0 ]] && exec sudo bash "$0" "$@"
[[ -f "${MOODLE_DIR}/config.php" ]] || die "Moodle not found at ${MOODLE_DIR}"

set_cfg() { sudo -u www-data "${PHP_CLI_BIN}" "${MOODLE_DIR}/admin/cli/cfg.php" --name="$1" --set="$2"; }

log "Forcing login (login page becomes the default landing page)"
set_cfg forcelogin 1

log "Purging caches"
sudo -u www-data "${PHP_CLI_BIN}" "${MOODLE_DIR}/admin/cli/purge_caches.php"
log "Done."
