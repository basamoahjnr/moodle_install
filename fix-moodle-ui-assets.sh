#!/usr/bin/env bash
# Fix missing Moodle icons/images/fonts ("UI components not showing").
#
# Cause: the nginx static-asset location matches any URL ending in
# .woff2/.svg/.png/etc and serves it with `try_files $uri =404`. But Moodle
# serves fonts/images THROUGH PHP via slash-argument URLs such as
#   /theme/font.php/boost/core/1/fontawesome-webfont.woff2
#   /theme/image.php/.../icon.svg
#   /pluginfile.php/.../picture.png
# Those end in a static extension, so nginx 404s them instead of passing them
# to PHP-FPM. This patches the static location to ignore any path containing
# .php, then reloads nginx and purges Moodle caches. Safe to re-run.

set -Eeuo pipefail
NGINX_SITE_FILE="/etc/nginx/sites-available/moodle"
MOODLE_DIR="/var/www/moodle"
PHP_VERSION="${PHP_VERSION:-8.3}"
PHP_CLI_BIN="php${PHP_VERSION}"

log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\n\033[1;33mWARN:\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
[[ "${EUID}" -ne 0 ]] && exec sudo bash "$0" "$@"
[[ -f "${NGINX_SITE_FILE}" ]] || die "nginx site not found: ${NGINX_SITE_FILE}"

if grep -q 'location ~\* \^(?!.\*\\.php' "${NGINX_SITE_FILE}"; then
  log "nginx static-asset rule already patched"
elif grep -Eq 'location ~\* \\\.\(js\|css' "${NGINX_SITE_FILE}"; then
  log "Patching nginx static-asset location to skip PHP-served assets"
  cp -a "${NGINX_SITE_FILE}" "${NGINX_SITE_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  # Replace the static location opener line with a negative-lookahead version
  # that excludes any path containing .php.
  perl -0pi -e 's/^\s*location ~\* \\?\.\(js[^\n]*\{/    location ~* ^(?!.*\\.php(\/|\$)).+\\.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2)\$ {/m' "${NGINX_SITE_FILE}"
  grep -q 'location ~\* \^(?!.\*\\.php' "${NGINX_SITE_FILE}" \
    || die "Patch did not apply – inspect ${NGINX_SITE_FILE} manually"
else
  warn "Could not find the expected static-asset location block; leaving nginx config unchanged."
fi

log "Testing and reloading nginx"
nginx -t || die "nginx config test failed – check ${NGINX_SITE_FILE} (a .bak was saved)"
systemctl reload nginx

if [[ -f "${MOODLE_DIR}/config.php" ]]; then
  log "Purging Moodle caches"
  sudo -u www-data "${PHP_CLI_BIN}" "${MOODLE_DIR}/admin/cli/purge_caches.php" \
    || warn "Cache purge failed (non-fatal)"
fi

log "Done. Hard-refresh the browser (Ctrl/Cmd-Shift-R) to clear cached 404s."
