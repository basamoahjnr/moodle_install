#!/usr/bin/env bash
# Apply recommended production security + performance settings to a fresh
# Moodle 4.5 install. All values are written via the supported admin/cli/cfg.php
# so they persist in the DB config and are safe to re-run (idempotent).
#
# Review the values below before running – a few are policy choices:
#   allowindexing=2  -> hide the site from search engines (private LMS). Set 0
#                       if this is a public site that SHOULD be indexed.
#   sessiontimeout   -> 8h; lower it for stricter sessions.
# Password policy + lockout values are sensible defaults; tune to taste.

set -Eeuo pipefail
MOODLE_DIR="/var/www/moodle"
PHP_VERSION="${PHP_VERSION:-8.3}"
PHP_CLI_BIN="php${PHP_VERSION}"

log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
[[ "${EUID}" -ne 0 ]] && exec sudo bash "$0" "$@"
[[ -f "${MOODLE_DIR}/config.php" ]] || die "Moodle not found at ${MOODLE_DIR}"

set_cfg() { sudo -u www-data "${PHP_CLI_BIN}" "${MOODLE_DIR}/admin/cli/cfg.php" --name="$1" --set="$2"; }

# name=value pairs. Ordered roughly: security, then performance.
declare -a SETTINGS=(
  # --- Security ---
  "cronclionly=1"            # run cron only from CLI (we use the systemd timer)
  "cookiehttponly=1"         # session cookie not exposed to JavaScript
  "cookiesecure=1"           # session cookie only sent over HTTPS
  "regenloginsession=1"      # new session id on login (anti session-fixation)
  "preventexecpath=1"        # block setting executable paths via the web UI
  "protectusernames=1"       # don't reveal whether a username/email exists
  "autologinguests=0"        # never silently log visitors in as guest
  "opentowebcrawlers=0"      # require login; don't expose content to crawlers
  "allowindexing=2"          # 0=everywhere 1=front page 2=nowhere (private LMS)
  "extendedusernamechars=0"  # restrict username characters
  "sessiontimeout=28800"     # 8 hours
  # Password policy
  "passwordpolicy=1"
  "minpasswordlength=8"
  "minpassworddigits=1"
  "minpasswordlower=1"
  "minpasswordupper=1"
  "minpasswordnonalphanum=1"
  # Account lockout (brute-force protection)
  "lockoutthreshold=10"
  "lockoutwindow=1800"
  "lockoutduration=1800"
  # --- Performance / production ---
  "debug=0"                  # no developer debug output
  "debugdisplay=0"           # never display errors to users
  "themedesignermode=0"      # cache theme CSS (big performance win)
  "cachejs=1"                # cache/minify JavaScript
  "langstringcache=1"        # cache language strings
  "slasharguments=1"         # required for /pluginfile.php/... asset URLs
  "enablestats=0"            # disable legacy stats processing (heavy)
)

log "Applying ${#SETTINGS[@]} recommended settings"
for pair in "${SETTINGS[@]}"; do
  name="${pair%%=*}"
  value="${pair#*=}"
  set_cfg "${name}" "${value}"
  printf '  + %s = %s\n' "${name}" "${value}"
done

log "Purging caches"
sudo -u www-data "${PHP_CLI_BIN}" "${MOODLE_DIR}/admin/cli/purge_caches.php"

log "Done. Review remaining items in Site administration -> Reports -> Security checks."
