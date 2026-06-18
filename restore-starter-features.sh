#!/usr/bin/env bash
# Partially undo Moodle's "Starter" admin preset: re-enable the advanced
# feature flags and the activity modules it hid.
#
# NOTE: For a COMPLETE reversal (blocks, question types, repositories, the
# TinyMCE editor, filters, etc.) use the supported route instead:
#   Site administration -> Site admin presets -> Apply "Full"
# There is no core CLI to apply a preset, and those plugin-visibility changes
# are not covered here. This script handles only the $CFG toggles + modules.
#
# Enrolments are intentionally NOT touched: the Starter preset disabled guest
# enrolment and you removed guest access on purpose, so it stays disabled.

set -Eeuo pipefail
MOODLE_DIR="/var/www/moodle"
MOODLE_ENV_FILE="/opt/moodle/.env"
PHP_VERSION="${PHP_VERSION:-8.3}"
PHP_CLI_BIN="php${PHP_VERSION}"

log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
[[ "${EUID}" -ne 0 ]] && exec sudo bash "$0" "$@"
[[ -f "${MOODLE_DIR}/config.php" ]] || die "Moodle not found at ${MOODLE_DIR}"

# Core $CFG feature flags (name -> value). Names verified against MOODLE_405_STABLE.
declare -a FEATURES=(
  usecomments
  usetags
  enablenotes
  enableblogs
  enablebadges
  enableanalytics
  enableoutcomes
  enableportfolios
)

# Activity modules the Starter preset hides (mdl_modules.visible = 0). Edit this
# list if you do NOT want all of them back.
MODULES=(chat data lti imscp lesson scorm survey wiki workshop)

set_cfg() { sudo -u www-data "${PHP_CLI_BIN}" "${MOODLE_DIR}/admin/cli/cfg.php" "$@"; }

log "Re-enabling advanced feature flags"
for name in "${FEATURES[@]}"; do
  set_cfg --name="${name}" --set=1
  printf '  + %s = 1\n' "${name}"
done

log "Re-enabling competencies (plugin-scoped setting)"
set_cfg --component=core_competency --name=enabled --set=1

log "Re-enabling hidden activity modules"
[[ -f "${MOODLE_ENV_FILE}" ]] || die "Cannot read ${MOODLE_ENV_FILE} to find the DB name"
MOODLE_DB="$( . "${MOODLE_ENV_FILE}"; printf '%s' "${MOODLE_DB:-}" )"
[[ -n "${MOODLE_DB}" ]] || die "MOODLE_DB not set in ${MOODLE_ENV_FILE}"

# Build a quoted IN (...) list: 'chat','data',...
in_list=""
for m in "${MODULES[@]}"; do in_list+="'${m}',"; done
in_list="${in_list%,}"
sudo -u postgres psql -v ON_ERROR_STOP=1 -d "${MOODLE_DB}" \
  -c "UPDATE mdl_modules SET visible = 1 WHERE name IN (${in_list});"
printf '  + enabled: %s\n' "${MODULES[*]}"

log "Purging caches"
sudo -u www-data "${PHP_CLI_BIN}" "${MOODLE_DIR}/admin/cli/purge_caches.php"
log "Done. For blocks/question types/repositories/editor, apply the Full preset in the UI."
