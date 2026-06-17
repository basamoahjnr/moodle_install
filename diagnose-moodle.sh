#!/usr/bin/env bash
set -Eeuo pipefail

MOODLE_DIR="${MOODLE_DIR:-/var/www/moodle}"
MOODLE_ENV_FILE="${MOODLE_ENV_FILE:-/opt/moodle/.env}"
PHP_VERSION="${PHP_VERSION:-8.4}"
MOODLE_HOST="${MOODLE_HOST:-}"

if [[ "${EUID}" -ne 0 ]]; then
  exec sudo bash "$0" "$@"
fi

if [[ -z "${MOODLE_HOST}" && -f "${MOODLE_ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${MOODLE_ENV_FILE}"
fi

if [[ -z "${MOODLE_HOST}" ]]; then
  printf 'MOODLE_HOST is unknown. Set MOODLE_HOST or ensure %s exists.\n' "${MOODLE_ENV_FILE}" >&2
  exit 1
fi

section() {
  printf '\n==> %s\n' "$*"
}

run_check() {
  local description="$1"
  shift
  printf '\n# %s\n' "${description}"
  "$@" || true
}

curl_status() {
  curl -skL --connect-timeout 5 --max-time 20 -o /dev/null -w '%{http_code} %{url_effective}\n' "$@" 2>/dev/null || printf '000 curl failed\n'
}

section "Service Status"
run_check "nginx" systemctl --no-pager --full status nginx
run_check "php${PHP_VERSION}-fpm" systemctl --no-pager --full status "php${PHP_VERSION}-fpm"
run_check "postgresql" systemctl --no-pager --full status postgresql
run_check "redis-server" systemctl --no-pager --full status redis-server

section "Sockets and Config"
run_check "PHP-FPM Moodle socket" ls -l "/run/php/php${PHP_VERSION}-fpm-moodle.sock"
run_check "Nginx config test" nginx -t
run_check "Moodle config.php" ls -l "${MOODLE_DIR}/config.php"
run_check "Moodle dataroot" ls -ld /var/moodledata

section "HTTP Probes"
run_check "Direct URL" curl_status "https://${MOODLE_HOST}/login/index.php"
run_check "Local Nginx with Host/SNI override" curl_status --resolve "${MOODLE_HOST}:443:127.0.0.1" "https://${MOODLE_HOST}/login/index.php"
run_check "Localhost HTTPS" curl_status "https://127.0.0.1/login/index.php"

section "Recent Logs"
run_check "Nginx error log" tail -n 80 /var/log/nginx/error.log
run_check "PHP-FPM log" tail -n 80 "/var/log/php${PHP_VERSION}-fpm.log"
run_check "Moodle cron timer" systemctl --no-pager --full status moodle-cron.timer

section "Moodle CLI"
if [[ -f "${MOODLE_DIR}/admin/cli/checks.php" ]]; then
  run_check "Moodle environment checks" sudo -u www-data "php${PHP_VERSION}" "${MOODLE_DIR}/admin/cli/checks.php"
else
  printf 'Moodle checks.php not found; skipping.\n'
fi
