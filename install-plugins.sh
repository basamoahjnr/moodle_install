#!/usr/bin/env bash
# Install Moodle add-on plugins from CLI using the supported method: place the
# plugin code in its frankenstyle directory, then run admin/cli/upgrade.php.
# Moodle has no core "install plugin by name" CLI, so we git-clone each plugin
# into the right path. upgrade.php validates version compatibility and refuses
# anything that doesn't support this Moodle, so the install fails safe.
#
# HOW TO USE
#   1. Edit the PLUGINS list below. Each entry is:  "relpath|git_url|branch"
#      - relpath : path under the Moodle root, e.g. blocks/xp, mod/attendance,
#                  theme/moove, filter/multilang2  (must be the correct type dir)
#      - git_url : the plugin's git repository
#      - branch  : a branch/tag that supports YOUR Moodle version. CHECK the
#                  plugin's page on https://moodle.org/plugins for the right one.
#   2. Run: sudo ./install-plugins.sh
#
# A few popular, actively-maintained free plugins are listed (commented out).
# Verify the branch on each plugin page before enabling – branch names differ
# per plugin and per Moodle release.

set -Eeuo pipefail
MOODLE_DIR="/var/www/moodle"
PHP_VERSION="${PHP_VERSION:-8.3}"
PHP_CLI_BIN="php${PHP_VERSION}"

log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\n\033[1;33mWARN:\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
[[ "${EUID}" -ne 0 ]] && exec sudo bash "$0" "$@"
[[ -f "${MOODLE_DIR}/config.php" ]] || die "Moodle not found at ${MOODLE_DIR}"
command -v git >/dev/null 2>&1 || die "git is required"

# relpath | git_url | branch    (uncomment / edit as needed)
PLUGINS=(
  # "blocks/xp|https://github.com/FMCorz/moodle-block_xp.git|MOODLE_405_STABLE"
  # "mod/attendance|https://github.com/danmarsden/moodle-mod_attendance.git|MOODLE_405_STABLE"
  # "filter/multilang2|https://github.com/iarenaza/moodle-filter_multilang2.git|master"
  # "theme/moove|https://github.com/willianmano/moodle-theme_moove.git|MOODLE_405_STABLE"
)

if [[ ${#PLUGINS[@]} -eq 0 ]]; then
  die "No plugins configured. Edit the PLUGINS list in $0 first."
fi

cloned_any=false
for entry in "${PLUGINS[@]}"; do
  relpath="${entry%%|*}"; rest="${entry#*|}"
  repo="${rest%%|*}"; branch="${rest##*|}"
  dest="${MOODLE_DIR}/${relpath}"

  if [[ -e "${dest}" ]]; then
    log "Already present, skipping: ${relpath}"
    continue
  fi

  log "Cloning ${relpath} (${branch})"
  if git clone --depth 1 --branch "${branch}" "${repo}" "${dest}"; then
    rm -rf "${dest}/.git"
    chown -R root:www-data "${dest}"
    cloned_any=true
  else
    warn "Clone failed for ${relpath} – check the repo URL and branch"
    rm -rf "${dest}"
  fi
done

if [[ "${cloned_any}" != "true" ]]; then
  log "Nothing new to install."
  exit 0
fi

log "Enabling maintenance mode"
sudo -u www-data "${PHP_CLI_BIN}" "${MOODLE_DIR}/admin/cli/maintenance.php" --enable || true

log "Running plugin upgrade (validates version compatibility)"
if ! sudo -u www-data "${PHP_CLI_BIN}" "${MOODLE_DIR}/admin/cli/upgrade.php" --non-interactive; then
  warn "upgrade.php reported a problem – a plugin may be incompatible with this Moodle version."
fi

log "Disabling maintenance mode"
sudo -u www-data "${PHP_CLI_BIN}" "${MOODLE_DIR}/admin/cli/maintenance.php" --disable || true

log "Purging caches"
sudo -u www-data "${PHP_CLI_BIN}" "${MOODLE_DIR}/admin/cli/purge_caches.php" || true
log "Done. Verify under Site administration -> Plugins -> Plugins overview."
