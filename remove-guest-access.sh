#!/usr/bin/env bash
# Remove guest access from the site:
#   - hide the "Log in as a guest" button   ($CFG->guestloginbutton = 0)
#   - never auto-login visitors as guest     ($CFG->autologinguests = 0)
#   - disable the guest enrolment plugin      (remove 'guest' from enrol_plugins_enabled)

set -Eeuo pipefail
MOODLE_DIR="/var/www/moodle"
PHP_VERSION="${PHP_VERSION:-8.3}"
PHP_CLI_BIN="php${PHP_VERSION}"

log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
[[ "${EUID}" -ne 0 ]] && exec sudo bash "$0" "$@"
[[ -f "${MOODLE_DIR}/config.php" ]] || die "Moodle not found at ${MOODLE_DIR}"

cfg() { sudo -u www-data "${PHP_CLI_BIN}" "${MOODLE_DIR}/admin/cli/cfg.php" "$@"; }
set_cfg() { cfg --name="$1" --set="$2"; }
get_cfg() { cfg --name="$1"; }

log "Hiding guest login button and disabling guest auto-login"
set_cfg guestloginbutton 0
set_cfg autologinguests 0

log "Disabling the guest enrolment plugin"
current="$(get_cfg enrol_plugins_enabled | tr -d '[:space:]')"
if [[ ",${current}," == *",guest,"* ]]; then
  new="$(printf '%s' "${current}" | tr ',' '\n' | grep -vx 'guest' | paste -sd, -)"
  set_cfg enrol_plugins_enabled "${new}"
  log "enrol_plugins_enabled: ${current} -> ${new}"
else
  log "guest enrolment already disabled (${current:-none})"
fi

log "Purging caches"
sudo -u www-data "${PHP_CLI_BIN}" "${MOODLE_DIR}/admin/cli/purge_caches.php"
log "Done."
