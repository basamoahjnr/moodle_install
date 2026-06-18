#!/usr/bin/env bash
# Re-apply changed .env settings to an already-installed Moodle instance.
#
# Edit the project .env (next to this script), then run ./reapply-env.sh.
# config.php reads /opt/moodle/.env on every request, so rewriting that file
# already updates wwwroot (host) and DB credentials at runtime. This script
# additionally re-applies the settings that do NOT pick themselves up:
#   - PostgreSQL role password (must match MOODLE_DB_PASS)
#   - admin password / email
#   - site display name
#   - TLS certificate + nginx server_name (when the host changed)
#
# NOT supported (would orphan or wipe data – change these manually):
#   - MOODLE_DB / MOODLE_DB_USER (renaming the DB or role)
#   - MOODLE_ADMIN_USER (renaming the admin account)

set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
LOCAL_ENV_FILE="${SCRIPT_DIR}/.env"
MOODLE_DIR="/var/www/moodle"
MOODLE_OPT_DIR="/opt/moodle"
MOODLE_ENV_FILE="${MOODLE_OPT_DIR}/.env"
NGINX_SSL_DIR="/etc/nginx/ssl"
NGINX_CERT_FILE="${NGINX_SSL_DIR}/fullchain.pem"
NGINX_KEY_FILE="${NGINX_SSL_DIR}/privkey.pem"
NGINX_SITE_FILE="/etc/nginx/sites-available/moodle"

PHP_VERSION="${PHP_VERSION:-8.3}"
PHP_CLI_BIN="php${PHP_VERSION}"

log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\n\033[1;33mWARN:\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

if [[ "${EUID}" -ne 0 ]]; then
  exec sudo bash "$0" "$@"
fi

is_ipv4() {
  local ip="$1"
  [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local IFS='.'; local -a o; read -r -a o <<< "${ip}"
  local x; for x in "${o[@]}"; do (( x >= 0 && x <= 255 )) || return 1; done
}

escape_env_value() {
  local v="$1"
  v="${v//\\/\\\\}"; v="${v//\"/\\\"}"; v="${v//\$/\\$}"; v="${v//\`/\\\`}"
  printf '"%s"' "${v}"
}

sql_quote_literal() {
  local v="$1"; v="${v//\'/\'\'}"; printf "'%s'" "${v}"
}

psql_admin() { sudo -u postgres psql -v ON_ERROR_STOP=1 "$@"; }

# ---- Load settings ----------------------------------------------------------
[[ -f "${LOCAL_ENV_FILE}" ]] || die "No .env found at ${LOCAL_ENV_FILE}"
[[ -d "${MOODLE_DIR}" ]] || die "Moodle not found at ${MOODLE_DIR} – run install.sh first"

# Capture the previously-deployed host (in a subshell so it can't clobber ours).
OLD_HOST=""
OLD_DB=""
OLD_DB_USER=""
if [[ -f "${MOODLE_ENV_FILE}" ]]; then
  OLD_HOST="$( . "${MOODLE_ENV_FILE}"; printf '%s' "${MOODLE_HOST:-}" )"
  OLD_DB="$( . "${MOODLE_ENV_FILE}"; printf '%s' "${MOODLE_DB:-}" )"
  OLD_DB_USER="$( . "${MOODLE_ENV_FILE}"; printf '%s' "${MOODLE_DB_USER:-}" )"
fi

set -a
# shellcheck disable=SC1090
source "${LOCAL_ENV_FILE}"
set +a

for req in MOODLE_HOST MOODLE_SITE_NAME MOODLE_ADMIN_USER MOODLE_ADMIN_PASS \
           MOODLE_ADMIN_EMAIL MOODLE_DB MOODLE_DB_USER MOODLE_DB_PASS CERT_VALID_DAYS; do
  [[ -n "${!req:-}" ]] || die "Missing required setting in .env: ${req}"
done

# Refuse the unsafe renames rather than silently breaking the install.
if [[ -n "${OLD_DB}" && "${OLD_DB}" != "${MOODLE_DB}" ]]; then
  die "MOODLE_DB changed (${OLD_DB} -> ${MOODLE_DB}); renaming the database is not supported here."
fi
if [[ -n "${OLD_DB_USER}" && "${OLD_DB_USER}" != "${MOODLE_DB_USER}" ]]; then
  die "MOODLE_DB_USER changed (${OLD_DB_USER} -> ${MOODLE_DB_USER}); renaming the role is not supported here."
fi

# ---- 1. Rewrite /opt/moodle/.env (updates wwwroot + DB creds at runtime) -----
log "Rewriting ${MOODLE_ENV_FILE}"
install -d -m 0750 -o root -g www-data "${MOODLE_OPT_DIR}"
umask 027
{
  printf 'MOODLE_HOST=%s\n'        "$(escape_env_value "${MOODLE_HOST}")"
  printf 'MOODLE_SITE_NAME=%s\n'   "$(escape_env_value "${MOODLE_SITE_NAME}")"
  printf 'MOODLE_ADMIN_USER=%s\n'  "$(escape_env_value "${MOODLE_ADMIN_USER}")"
  printf 'MOODLE_ADMIN_PASS=%s\n'  "$(escape_env_value "${MOODLE_ADMIN_PASS}")"
  printf 'MOODLE_ADMIN_EMAIL=%s\n' "$(escape_env_value "${MOODLE_ADMIN_EMAIL}")"
  printf 'MOODLE_DB=%s\n'          "$(escape_env_value "${MOODLE_DB}")"
  printf 'MOODLE_DB_USER=%s\n'     "$(escape_env_value "${MOODLE_DB_USER}")"
  printf 'MOODLE_DB_PASS=%s\n'     "$(escape_env_value "${MOODLE_DB_PASS}")"
  printf 'CERT_VALID_DAYS=%s\n'    "$(escape_env_value "${CERT_VALID_DAYS}")"
} > "${MOODLE_ENV_FILE}"
chown root:www-data "${MOODLE_ENV_FILE}"
chmod 0640 "${MOODLE_ENV_FILE}"
umask 022

# ---- 2. PostgreSQL role password --------------------------------------------
log "Updating PostgreSQL role password"
psql_admin -c "ALTER ROLE \"${MOODLE_DB_USER}\" WITH LOGIN PASSWORD $(sql_quote_literal "${MOODLE_DB_PASS}");"

# ---- 3. Admin password ------------------------------------------------------
log "Resetting Moodle admin password for '${MOODLE_ADMIN_USER}'"
( cd "${MOODLE_DIR}" && sudo -u www-data "${PHP_CLI_BIN}" admin/cli/reset_password.php \
    --username="${MOODLE_ADMIN_USER}" \
    --password="${MOODLE_ADMIN_PASS}" \
    --ignore-password-policy ) \
  || warn "Could not reset admin password via CLI – set it manually with admin/cli/reset_password.php"

# ---- 4. Admin email + site name (direct DB update) --------------------------
log "Updating admin email and site name"
psql_admin -d "${MOODLE_DB}" \
  -c "UPDATE mdl_user SET email = $(sql_quote_literal "${MOODLE_ADMIN_EMAIL}") WHERE username = $(sql_quote_literal "${MOODLE_ADMIN_USER}") AND deleted = 0;"
psql_admin -d "${MOODLE_DB}" \
  -c "UPDATE mdl_course SET fullname = $(sql_quote_literal "${MOODLE_SITE_NAME}") WHERE id = 1;"

# ---- 5. TLS cert + nginx (only when the host changed or cert missing) --------
if [[ "${OLD_HOST}" != "${MOODLE_HOST}" || ! -f "${NGINX_CERT_FILE}" || ! -f "${NGINX_KEY_FILE}" ]]; then
  log "Regenerating self-signed certificate for ${MOODLE_HOST}"
  install -d -m 0755 "${NGINX_SSL_DIR}"
  local_san="DNS:${MOODLE_HOST}"
  is_ipv4 "${MOODLE_HOST}" && local_san="${local_san},IP:${MOODLE_HOST}"
  openssl req -x509 -nodes -newkey rsa:4096 -sha256 \
    -days "${CERT_VALID_DAYS}" \
    -keyout "${NGINX_KEY_FILE}" -out "${NGINX_CERT_FILE}" \
    -subj "/CN=${MOODLE_HOST}" -addext "subjectAltName=${local_san}"
  chmod 0600 "${NGINX_KEY_FILE}"; chmod 0644 "${NGINX_CERT_FILE}"

  if [[ -f "${NGINX_SITE_FILE}" ]]; then
    log "Updating nginx server_name to ${MOODLE_HOST}"
    sed -i -E "s/^(\s*server_name\s+).*;/\1${MOODLE_HOST};/" "${NGINX_SITE_FILE}"
  fi
else
  log "Host unchanged and certificate present – leaving cert/nginx as-is"
fi

if nginx -t 2>/dev/null; then
  systemctl reload nginx
else
  warn "nginx config test failed – not reloading; run 'nginx -t' to inspect"
fi

# ---- 6. Purge Moodle caches so changes show immediately ---------------------
log "Purging Moodle caches"
( cd "${MOODLE_DIR}" && sudo -u www-data "${PHP_CLI_BIN}" admin/cli/purge_caches.php ) \
  || warn "Cache purge failed (non-fatal)"

log "Done. Re-applied settings from ${LOCAL_ENV_FILE}"
