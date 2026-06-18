#!/usr/bin/env bash
set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
LOCAL_ENV_FILE="${SCRIPT_DIR}/.env"
MOODLE_DIR="/var/www/moodle"
MOODLE_DATA_DIR="/var/moodledata"
MOODLE_OPT_DIR="/opt/moodle"
MOODLE_ENV_FILE="${MOODLE_OPT_DIR}/.env"
MOODLE_ENV_EXAMPLE="${MOODLE_OPT_DIR}/.env.example"
MOODLE_SENTINEL="${MOODLE_DATA_DIR}/.moodle_installed"
NGINX_SSL_DIR="/etc/nginx/ssl"
NGINX_CERT_FILE="${NGINX_SSL_DIR}/fullchain.pem"
NGINX_KEY_FILE="${NGINX_SSL_DIR}/privkey.pem"

PHP_VERSION="${PHP_VERSION:-8.3}"
MOODLE_BRANCH="${MOODLE_BRANCH:-MOODLE_405_STABLE}"
PHP_CLI_BIN="php${PHP_VERSION}"
PHP_FPM_SOCKET="/run/php/php${PHP_VERSION}-fpm-moodle.sock"
PHP_FPM_POOL_FILE="/etc/php/${PHP_VERSION}/fpm/pool.d/moodle.conf"
PHP_INI_FILE="/etc/php/${PHP_VERSION}/fpm/php.ini"
PHP_CLI_INI_FILE="/etc/php/${PHP_VERSION}/cli/php.ini"

NGINX_SITE_FILE="/etc/nginx/sites-available/moodle"
SYSTEMD_SERVICE_FILE="/etc/systemd/system/moodle-cron.service"
SYSTEMD_TIMER_FILE="/etc/systemd/system/moodle-cron.timer"

MOODLE_HOST=""
MOODLE_SITE_NAME=""
MOODLE_ADMIN_USER=""
MOODLE_ADMIN_PASS=""
MOODLE_ADMIN_EMAIL=""
MOODLE_DB=""
MOODLE_DB_USER=""
MOODLE_DB_PASS=""
CERT_VALID_DAYS=""

log() {
  printf '\n\033[1;34m==>\033[0m %s\n' "$*"
}

warn() {
  printf '\n\033[1;33mWARN:\033[0m %s\n' "$*"
}

die() {
  printf '\n\033[1;31mERROR:\033[0m %s\n' "$*" >&2
  exit 1
}

if [[ "${EUID}" -ne 0 ]]; then
  exec sudo bash "$0" "$@"
fi

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

is_ipv4() {
  local ip="$1"
  [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local IFS='.'
  local -a octets
  read -r -a octets <<< "${ip}"
  local octet
  for octet in "${octets[@]}"; do
    [[ "${octet}" =~ ^[0-9]+$ ]] || return 1
    (( octet >= 0 && octet <= 255 )) || return 1
  done
}

is_pg_identifier() {
  [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]
}

read_required() {
  local var_name="$1"
  local label="$2"
  local help_text="$3"
  local default_value="${4:-}"
  local validator="${5:-}"
  local value

  while true; do
    printf '\n%s\n%s\n' "${label}" "${help_text}"
    if [[ -n "${default_value}" ]]; then
      printf 'Enter value [%s]: ' "${default_value}"
    else
      printf 'Enter value: '
    fi
    read -r value
    value="${value:-${default_value}}"

    if [[ -z "${value}" ]]; then
      printf 'This value is required.\n'
      continue
    fi

    case "${validator}" in
      host)
        if [[ "${value}" =~ [[:space:]/] ]]; then
          printf 'Use a hostname or IP address only, without spaces or URL paths.\n'
          continue
        fi
        ;;
      pg_identifier)
        if ! is_pg_identifier "${value}"; then
          printf 'Use letters, numbers, and underscores only; the first character must be a letter or underscore.\n'
          continue
        fi
        ;;
      positive_integer)
        if ! [[ "${value}" =~ ^[1-9][0-9]*$ ]]; then
          printf 'Use a positive whole number.\n'
          continue
        fi
        ;;
      email)
        if ! [[ "${value}" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then
          printf 'Use a valid email address.\n'
          continue
        fi
        ;;
    esac

    printf -v "${var_name}" '%s' "${value}"
    break
  done
}

password_meets_moodle_policy() {
  local password="$1"
  [[ ${#password} -ge 8 ]] || return 1
  [[ "${password}" =~ [[:lower:]] ]] || return 1
  [[ "${password}" =~ [[:upper:]] ]] || return 1
  [[ "${password}" =~ [0-9] ]] || return 1
  [[ "${password}" =~ [^A-Za-z0-9] ]] || return 1
}

read_secret_confirm() {
  local var_name="$1"
  local label="$2"
  local help_text="$3"
  local enforce_moodle_policy="${4:-false}"
  local first second

  while true; do
    printf '\n%s\n%s\n' "${label}" "${help_text}"
    printf 'Enter password: '
    read -r -s first
    printf '\nConfirm password: '
    read -r -s second
    printf '\n'

    if [[ -z "${first}" ]]; then
      printf 'This password is required.\n'
      continue
    fi
    if [[ "${first}" != "${second}" ]]; then
      printf 'Passwords did not match.\n'
      continue
    fi
    if [[ "${enforce_moodle_policy}" == "true" ]] && ! password_meets_moodle_policy "${first}"; then
      printf 'Moodle admin passwords must be at least 8 characters and include uppercase, lowercase, number, and symbol characters.\n'
      continue
    fi

    printf -v "${var_name}" '%s' "${first}"
    break
  done
}

escape_env_value() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//\$/\\$}"
  value="${value//\`/\\\`}"
  printf '"%s"' "${value}"
}

sql_quote_literal() {
  local value="$1"
  value="${value//\'/\'\'}"
  printf "'%s'" "${value}"
}

set_php_ini_value() {
  local file="$1"
  local key="$2"
  local value="$3"
  if grep -Eq "^[;[:space:]]*${key}[[:space:]]*=" "${file}"; then
    sed -i -E "s|^[;[:space:]]*${key}[[:space:]]*=.*|${key} = ${value}|" "${file}"
  else
    printf '%s = %s\n' "${key}" "${value}" >> "${file}"
  fi
}

# ---------- Input collection ----------
load_local_env_if_present() {
  if [[ ! -f "${LOCAL_ENV_FILE}" ]]; then
    return
  fi
  log "Loading settings from ${LOCAL_ENV_FILE}"
  set -a
  # shellcheck disable=SC1090
  source "${LOCAL_ENV_FILE}"
  set +a
}

validate_existing_inputs() {
  local valid=true
  if [[ -n "${MOODLE_HOST}" && "${MOODLE_HOST}" =~ [[:space:]/] ]]; then
    warn "MOODLE_HOST in ${LOCAL_ENV_FILE} must be a hostname or IP address without spaces or URL paths."
    MOODLE_HOST=""; valid=false
  fi
  if [[ -n "${MOODLE_DB}" ]] && ! is_pg_identifier "${MOODLE_DB}"; then
    warn "MOODLE_DB in ${LOCAL_ENV_FILE} must be a PostgreSQL identifier."
    MOODLE_DB=""; valid=false
  fi
  if [[ -n "${MOODLE_DB_USER}" ]] && ! is_pg_identifier "${MOODLE_DB_USER}"; then
    warn "MOODLE_DB_USER in ${LOCAL_ENV_FILE} must be a PostgreSQL identifier."
    MOODLE_DB_USER=""; valid=false
  fi
  if [[ -n "${CERT_VALID_DAYS}" ]] && ! [[ "${CERT_VALID_DAYS}" =~ ^[1-9][0-9]*$ ]]; then
    warn "CERT_VALID_DAYS must be a positive whole number."
    CERT_VALID_DAYS=""; valid=false
  fi
  if [[ -n "${MOODLE_ADMIN_EMAIL}" ]] && ! [[ "${MOODLE_ADMIN_EMAIL}" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then
    warn "MOODLE_ADMIN_EMAIL is not a valid email."
    MOODLE_ADMIN_EMAIL=""; valid=false
  fi
  if [[ -n "${MOODLE_ADMIN_PASS}" ]] && ! password_meets_moodle_policy "${MOODLE_ADMIN_PASS}"; then
    warn "MOODLE_ADMIN_PASS does not meet Moodle's password policy."
    MOODLE_ADMIN_PASS=""; valid=false
  fi
  [[ "${valid}" == "true" ]]
}

collect_inputs() {
  load_local_env_if_present
  validate_existing_inputs || true

  if [[ -n "${MOODLE_HOST}" && -n "${MOODLE_SITE_NAME}" && -n "${MOODLE_ADMIN_USER}" && -n "${MOODLE_ADMIN_PASS}" && -n "${MOODLE_ADMIN_EMAIL}" && -n "${MOODLE_DB}" && -n "${MOODLE_DB_USER}" && -n "${MOODLE_DB_PASS}" && -n "${CERT_VALID_DAYS}" ]]; then
    log "Using complete settings from ${LOCAL_ENV_FILE}"
    return
  fi

  log "Collecting Moodle deployment settings"
  [[ -n "${MOODLE_HOST}" ]] || read_required "MOODLE_HOST" "Server IP or hostname" "The IP or hostname clients use to reach Moodle." "" "host"
  [[ -n "${MOODLE_SITE_NAME}" ]] || read_required "MOODLE_SITE_NAME" "Moodle site name" "Display name in the LMS." "My Moodle Site"
  [[ -n "${MOODLE_ADMIN_USER}" ]] || read_required "MOODLE_ADMIN_USER" "Admin username" "Administrator account name." "admin"
  [[ -n "${MOODLE_ADMIN_PASS}" ]] || read_secret_confirm "MOODLE_ADMIN_PASS" "Admin password" "Must satisfy Moodle's policy." "true"
  [[ -n "${MOODLE_ADMIN_EMAIL}" ]] || read_required "MOODLE_ADMIN_EMAIL" "Admin email" "Email for the initial admin." "" "email"
  [[ -n "${MOODLE_DB}" ]] || read_required "MOODLE_DB" "PostgreSQL DB name" "Database name." "moodle" "pg_identifier"
  [[ -n "${MOODLE_DB_USER}" ]] || read_required "MOODLE_DB_USER" "PostgreSQL username" "Database role." "moodle" "pg_identifier"
  [[ -n "${MOODLE_DB_PASS}" ]] || read_secret_confirm "MOODLE_DB_PASS" "PostgreSQL password" "Password for the role."
  [[ -n "${CERT_VALID_DAYS}" ]] || read_required "CERT_VALID_DAYS" "Certificate validity days" "Number of days for the self-signed cert." "3650" "positive_integer"
}

write_env_files() {
  log "Writing ${MOODLE_ENV_FILE}"
  install -d -m 0750 -o root -g www-data "${MOODLE_OPT_DIR}"
  umask 027
  {
    printf 'MOODLE_HOST=%s\n' "$(escape_env_value "${MOODLE_HOST}")"
    printf 'MOODLE_SITE_NAME=%s\n' "$(escape_env_value "${MOODLE_SITE_NAME}")"
    printf 'MOODLE_ADMIN_USER=%s\n' "$(escape_env_value "${MOODLE_ADMIN_USER}")"
    printf 'MOODLE_ADMIN_PASS=%s\n' "$(escape_env_value "${MOODLE_ADMIN_PASS}")"
    printf 'MOODLE_ADMIN_EMAIL=%s\n' "$(escape_env_value "${MOODLE_ADMIN_EMAIL}")"
    printf 'MOODLE_DB=%s\n' "$(escape_env_value "${MOODLE_DB}")"
    printf 'MOODLE_DB_USER=%s\n' "$(escape_env_value "${MOODLE_DB_USER}")"
    printf 'MOODLE_DB_PASS=%s\n' "$(escape_env_value "${MOODLE_DB_PASS}")"
    printf 'CERT_VALID_DAYS=%s\n' "$(escape_env_value "${CERT_VALID_DAYS}")"
  } > "${MOODLE_ENV_FILE}"
  chown root:www-data "${MOODLE_ENV_FILE}"
  chmod 0640 "${MOODLE_ENV_FILE}"
  umask 022

  cat > "${MOODLE_ENV_EXAMPLE}" <<'ENV_EXAMPLE'
# Server IP or hostname
MOODLE_HOST="192.168.1.50"
# Display name
MOODLE_SITE_NAME="My Moodle Site"
# Admin credentials
MOODLE_ADMIN_USER="admin"
MOODLE_ADMIN_PASS="ChangeMe-With-A-Strong-Password1!"
MOODLE_ADMIN_EMAIL="admin@example.local"
# PostgreSQL
MOODLE_DB="moodle"
MOODLE_DB_USER="moodle"
MOODLE_DB_PASS="ChangeMe-With-A-Strong-Database-Password1!"
# Certificate
CERT_VALID_DAYS="3650"
ENV_EXAMPLE
  chown root:root "${MOODLE_ENV_EXAMPLE}"
  chmod 0644 "${MOODLE_ENV_EXAMPLE}"
}

load_env() {
  # shellcheck disable=SC1090
  source "${MOODLE_ENV_FILE}"
}

# ---------- System prep ----------
system_prep() {
  log "Preparing system"
  apt update
  apt upgrade -y
  apt install -y curl git ca-certificates gnupg ufw fail2ban htop unzip openssl wget sudo \
    software-properties-common lsb-release apt-transport-https
}

# ---------- PHP ----------
php_pkg_available() {
  apt-cache show "php${PHP_VERSION}-fpm" 2>/dev/null | grep -q '^Package:'
}

php_extension_loaded() {
  local extension="$1"
  # OPcache registers itself as the Zend module "Zend OPcache", so it never
  # shows up as a plain "opcache" line in `php -m`. Match that name too.
  if [[ "${extension}" == "opcache" ]]; then
    "${PHP_CLI_BIN}" -m 2>/dev/null | grep -Eiq "^(opcache|zend opcache)$"
    return
  fi
  "${PHP_CLI_BIN}" -m 2>/dev/null | grep -Eiq "^${extension}$"
}

# Ensures opcache is present for CLI and FPM (not just FPM)
ensure_opcache_both_sapis() {
  local cli_conf="/etc/php/${PHP_VERSION}/cli/conf.d"
  local fpm_ini="/etc/php/${PHP_VERSION}/fpm/conf.d/10-opcache.ini"

  if php_extension_loaded "opcache"; then
    log "opcache already loaded"
    return
  fi

  log "Enabling opcache for both CLI and FPM"
  # Install package if needed
  apt install -y "php${PHP_VERSION}-opcache" 2>/dev/null || true

  # Enable via phpenmod (should create symlinks in both SAPI conf.d)
  phpenmod -v "${PHP_VERSION}" opcache

  # If CLI still doesn't see it, manually copy the FPM ini if available.
  # On Debian/Ubuntu these are symlinks into mods-available, so the FPM and
  # CLI inis can resolve to the same file – skip the copy in that case.
  if ! php_extension_loaded "opcache"; then
    local cli_ini="${cli_conf}/10-opcache.ini"
    if [[ -f "${fpm_ini}" && ! "${fpm_ini}" -ef "${cli_ini}" ]]; then
      cp "${fpm_ini}" "${cli_conf}/"
      log "Copied opcache INI from FPM to CLI"
    elif [[ ! -e "${cli_ini}" ]]; then
      # Last resort: create a minimal ini
      echo "extension=opcache.so" > "${cli_conf}/20-opcache.ini"
    fi
  fi

  # Restart FPM so that both SAPIs are consistent
  systemctl restart "php${PHP_VERSION}-fpm" || true
  if php_extension_loaded "opcache"; then
    log "opcache is now loaded"
  else
    warn "Could not load opcache for CLI – this is not critical for Moodle"
  fi
}

install_php() {
  log "Installing PHP ${PHP_VERSION} + Moodle extensions"

  if ! php_pkg_available; then
    die "PHP ${PHP_VERSION} packages not available. Ubuntu 24.04 should provide them."
  fi

  # Required packages (sodium, json, etc. are built-in)
  local required_packages=(
    "php${PHP_VERSION}-cli"
    "php${PHP_VERSION}-fpm"
    "php${PHP_VERSION}-curl"
    "php${PHP_VERSION}-xml"
    "php${PHP_VERSION}-gd"
    "php${PHP_VERSION}-intl"
    "php${PHP_VERSION}-mbstring"
    "php${PHP_VERSION}-pgsql"
    "php${PHP_VERSION}-zip"
  )

  # Recommended packages (opcache handled separately)
  local recommended_packages=(
    "php${PHP_VERSION}-bcmath"
    "php${PHP_VERSION}-redis"
    "php${PHP_VERSION}-soap"
    "php${PHP_VERSION}-xmlrpc"
  )

  log "Installing required packages..."
  apt install -y "${required_packages[@]}"

  log "Installing recommended packages..."
  for pkg in "${recommended_packages[@]}"; do
    if apt-cache show "$pkg" >/dev/null 2>&1; then
      apt install -y "$pkg" || warn "Failed to install $pkg"
    else
      warn "Package $pkg not available (may be built-in or unnecessary)"
    fi
  done

  # Handle opcache specifically – must work for CLI checks
  ensure_opcache_both_sapis

  # Verify required extensions
  log "Verifying required extensions for Moodle 4.5"
  local required_ext=(
    curl dom gd intl json mbstring openssl pcre pgsql
    SimpleXML sodium tokenizer xml xmlreader zip
  )
  local builtin_ext=(
    dom json openssl pcre SimpleXML sodium tokenizer xml xmlreader
  )

  local missing_required=()
  for ext in "${required_ext[@]}"; do
    if php_extension_loaded "${ext}"; then
      local tag="✓"
      for b in "${builtin_ext[@]}"; do
        [[ "${ext}" == "${b}" ]] && tag="✓ (built-in)" && break
      done
      printf '  %s Required: %s\n' "${tag}" "${ext}"
    else
      printf '  ✗ MISSING Required: %s\n' "${ext}"
      missing_required+=("${ext}")
    fi
  done
  [[ ${#missing_required[@]} -gt 0 ]] && die "Missing required extensions: ${missing_required[*]}"

  # Verify recommended extensions
  log "Checking recommended extensions"
  local recommended_ext=(
    bcmath fileinfo iconv opcache redis soap xmlrpc
  )
  local builtin_rec=(
    fileinfo iconv
  )

  local missing_rec=()
  for ext in "${recommended_ext[@]}"; do
    if php_extension_loaded "${ext}"; then
      local tag="✓"
      for b in "${builtin_rec[@]}"; do
        [[ "${ext}" == "${b}" ]] && tag="✓ (built-in)" && break
      done
      printf '  %s Recommended: %s\n' "${tag}" "${ext}"
    else
      printf '  ○ Missing Recommended: %s\n' "${ext}"
      missing_rec+=("${ext}")
    fi
  done
  [[ ${#missing_rec[@]} -gt 0 ]] && warn "Missing recommended extensions: ${missing_rec[*]}"

  log "PHP ${PHP_VERSION} installation complete"
}

# ---------- PostgreSQL ----------
postgresql_installed_version() {
  # Return empty (success) when psql is absent so callers under `set -e`
  # don't abort on the non-zero exit from `command -v`.
  command -v psql >/dev/null 2>&1 || return 0
  psql --version | awk '{print $3}' | cut -d. -f1
}

install_postgresql() {
  local pg_version
  pg_version="$(postgresql_installed_version)"
  if [[ -n "${pg_version}" && "${pg_version}" -ge 12 ]]; then
    log "PostgreSQL ${pg_version} already installed (Moodle requires >=12)"
    return
  fi
  log "Installing PostgreSQL"
  apt install -y postgresql postgresql-contrib
  pg_version="$(postgresql_installed_version)"
  [[ -z "${pg_version}" || "${pg_version}" -lt 12 ]] && die "PostgreSQL 12+ required"
  systemctl enable --now postgresql
}

configure_postgresql() {
  log "Configuring PostgreSQL role & database"
  local quoted_password
  quoted_password="$(sql_quote_literal "${MOODLE_DB_PASS}")"

  if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname = '${MOODLE_DB_USER}'" | grep -q 1; then
    sudo -u postgres psql -c "ALTER ROLE \"${MOODLE_DB_USER}\" WITH LOGIN PASSWORD ${quoted_password};"
  else
    sudo -u postgres psql -c "CREATE ROLE \"${MOODLE_DB_USER}\" WITH LOGIN PASSWORD ${quoted_password};"
  fi

  if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname = '${MOODLE_DB}'" | grep -q 1; then
    sudo -u postgres createdb -O "${MOODLE_DB_USER}" -E UTF8 "${MOODLE_DB}"
  fi

  sudo -u postgres psql -d "${MOODLE_DB}" -c "ALTER DATABASE \"${MOODLE_DB}\" OWNER TO \"${MOODLE_DB_USER}\";"
  sudo -u postgres psql -d "${MOODLE_DB}" -c "SELECT 1;" >/dev/null || die "Cannot connect to database ${MOODLE_DB}"
}

# ---------- Redis ----------
install_and_configure_redis() {
  log "Setting up Redis"
  apt install -y redis-server 2>/dev/null || true
  sed -i '/^[[:space:]]*maxmemory /d; /^[[:space:]]*maxmemory-policy /d; /^[[:space:]]*save /d; /^[[:space:]]*bind /d' /etc/redis/redis.conf
  cat >> /etc/redis/redis.conf <<'REDIS_CONF'
bind 127.0.0.1
protected-mode yes
maxmemory 4gb
maxmemory-policy allkeys-lru
save ""
REDIS_CONF
  systemctl enable --now redis-server
  systemctl restart redis-server
  redis-cli ping | grep -q PONG || die "Redis not responding"
}

# ---------- Nginx ----------
install_nginx() {
  log "Installing Nginx"
  apt install -y nginx 2>/dev/null || true
  systemctl enable --now nginx
  # Test before reload
  nginx -t || die "Nginx configuration is broken (before Moodle site added)"
  systemctl reload nginx
}

# ---------- Moodle code ----------
setup_moodle_code() {
  log "Setting up Moodle code & data directories"
  if [[ -d "${MOODLE_DIR}/.git" ]]; then
    log "Moodle git repository already present"
  elif [[ -e "${MOODLE_DIR}" ]]; then
    die "${MOODLE_DIR} exists but is not a Moodle checkout – remove it first"
  else
    git clone --depth 1 --branch "${MOODLE_BRANCH}" https://github.com/moodle/moodle.git "${MOODLE_DIR}"
  fi

  install -d -m 0770 -o www-data -g www-data "${MOODLE_DATA_DIR}"
  chown -R www-data:www-data "${MOODLE_DIR}" "${MOODLE_DATA_DIR}"
  chmod 0755 "${MOODLE_DIR}"
  chmod 0770 "${MOODLE_DATA_DIR}"

  if [[ -f "${MOODLE_DIR}/version.php" ]]; then
    local ver; ver=$(grep '$release' "${MOODLE_DIR}/version.php" | awk -F"'" '{print $2}')
    log "Moodle version: ${ver}"
  fi
}

# ---------- PHP-FPM pool (tuned for 16GB RAM) ----------
write_php_fpm_pool() {
  log "Writing PHP-FPM Moodle pool (16GB server tuned)"
  install -d -m 0755 "$(dirname "${PHP_FPM_POOL_FILE}")"
  cat > "${PHP_FPM_POOL_FILE}" <<PHP_FPM_POOL
[moodle]
user = www-data
group = www-data

listen = ${PHP_FPM_SOCKET}
listen.owner = www-data
listen.group = www-data
listen.mode = 0660

pm = dynamic
pm.max_children = 100
pm.start_servers = 20
pm.min_spare_servers = 10
pm.max_spare_servers = 30
pm.max_requests = 500

php_admin_value[memory_limit] = 1024M
php_admin_value[upload_max_filesize] = 512M
php_admin_value[post_max_size] = 512M
php_admin_value[max_execution_time] = 300
php_admin_value[max_input_vars] = 5000
php_admin_value[opcache.enable] = 1
php_admin_value[opcache.memory_consumption] = 512
php_admin_value[opcache.max_accelerated_files] = 20000
php_admin_value[opcache.revalidate_freq] = 60
PHP_FPM_POOL

  for ini_file in "${PHP_INI_FILE}" "${PHP_CLI_INI_FILE}"; do
    set_php_ini_value "${ini_file}" "expose_php" "Off"
    set_php_ini_value "${ini_file}" "memory_limit" "1024M"
    set_php_ini_value "${ini_file}" "upload_max_filesize" "512M"
    set_php_ini_value "${ini_file}" "post_max_size" "512M"
    set_php_ini_value "${ini_file}" "max_execution_time" "300"
    set_php_ini_value "${ini_file}" "max_input_vars" "5000"
    set_php_ini_value "${ini_file}" "opcache.enable" "1"
    set_php_ini_value "${ini_file}" "opcache.memory_consumption" "512"
    set_php_ini_value "${ini_file}" "opcache.max_accelerated_files" "20000"
  done

  systemctl restart "php${PHP_VERSION}-fpm"
  systemctl is-active --quiet "php${PHP_VERSION}-fpm" || die "PHP-FPM failed to start"
}

# ---------- Moodle config.php ----------
write_moodle_config_php() {
  log "Writing Moodle config.php"
  cat > "${MOODLE_DIR}/config.php" <<'PHP_CONFIG'
<?php
unset($CFG);
global $CFG;
$CFG = new stdClass();

$envfile = '/opt/moodle/.env';
if (!is_readable($envfile)) {
    throw new RuntimeException('Moodle environment file not readable: ' . $envfile);
}
$env = [];
foreach (file($envfile, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) as $line) {
    $line = trim($line);
    if ($line === '' || str_starts_with($line, '#') || !str_contains($line, '=')) continue;
    [$key, $value] = explode('=', $line, 2);
    $key = trim($key);
    $value = trim($value);
    if ($value !== '' && $value[0] === '"' && substr($value, -1) === '"') {
        $value = stripcslashes(substr($value, 1, -1));
    }
    $env[$key] = $value;
}
foreach (['MOODLE_HOST','MOODLE_DB','MOODLE_DB_USER','MOODLE_DB_PASS'] as $req) {
    if (empty($env[$req])) throw new RuntimeException('Missing env: ' . $req);
}
$CFG->dbtype    = 'pgsql';
$CFG->dblibrary = 'native';
$CFG->dbhost    = '127.0.0.1';
$CFG->dbname    = $env['MOODLE_DB'];
$CFG->dbuser    = $env['MOODLE_DB_USER'];
$CFG->dbpass    = $env['MOODLE_DB_PASS'];
$CFG->prefix    = 'mdl_';
$CFG->dboptions = ['dbpersist' => false, 'dbsocket' => false, 'dbport' => ''];
$CFG->wwwroot   = 'https://' . $env['MOODLE_HOST'];
$CFG->dataroot  = '/var/moodledata';
$CFG->admin     = 'admin';
$CFG->session_handler_class = '\core\session\redis';
$CFG->session_redis_host = '127.0.0.1';
$CFG->session_redis_port = 6379;
$CFG->session_redis_database = 0;
$CFG->session_redis_acquire_lock_timeout = 120;
$CFG->session_redis_lock_expire = 7200;
$CFG->directorypermissions = 0770;
require_once(__DIR__ . '/lib/setup.php');
PHP_CONFIG
  chown www-data:www-data "${MOODLE_DIR}/config.php"
  chmod 0640 "${MOODLE_DIR}/config.php"
}

# ---------- CLI install ----------
moodle_db_has_config_table() {
  sudo -u postgres psql -d "${MOODLE_DB}" -tAc "SELECT to_regclass('public.mdl_config')" 2>/dev/null | grep -q 'mdl_config'
}

moodle_is_installed() {
  [[ -f "${MOODLE_SENTINEL}" ]] || moodle_db_has_config_table
}

run_moodle_cli_install() {
  log "Running Moodle CLI installer"
  if moodle_is_installed; then
    log "Moodle already installed – skipping CLI install"
    write_moodle_config_php
    install -o www-data -g www-data -m 0640 /dev/null "${MOODLE_SENTINEL}"
    return
  fi

  if [[ -f "${MOODLE_DIR}/config.php" ]]; then
    cp -a "${MOODLE_DIR}/config.php" "${MOODLE_DIR}/config.php.preinstall.$(date +%Y%m%d%H%M%S)"
    rm -f "${MOODLE_DIR}/config.php"
  fi

  cd "${MOODLE_DIR}"
  sudo -u www-data "${PHP_CLI_BIN}" admin/cli/install.php \
    --wwwroot="https://${MOODLE_HOST}" \
    --dataroot="${MOODLE_DATA_DIR}" \
    --dbtype=pgsql \
    --dbhost=127.0.0.1 \
    --dbname="${MOODLE_DB}" \
    --dbuser="${MOODLE_DB_USER}" \
    --dbpass="${MOODLE_DB_PASS}" \
    --adminuser="${MOODLE_ADMIN_USER}" \
    --adminpass="${MOODLE_ADMIN_PASS}" \
    --adminemail="${MOODLE_ADMIN_EMAIL}" \
    --fullname="${MOODLE_SITE_NAME}" \
    --shortname=moodle \
    --agree-license \
    --non-interactive

  write_moodle_config_php
  install -o www-data -g www-data -m 0640 /dev/null "${MOODLE_SENTINEL}"
  moodle_db_has_config_table || die "Installation failed – config table missing"
}

# ---------- Cron timer (clean service unit) ----------
write_systemd_cron() {
  log "Creating Moodle cron timer"

  cat > "${SYSTEMD_SERVICE_FILE}" <<SYSTEMD_SERVICE
[Unit]
Description=Moodle cron job
After=network.target postgresql.service redis-server.service

[Service]
Type=oneshot
User=www-data
Group=www-data
ExecStart=/usr/bin/${PHP_CLI_BIN} /var/www/moodle/admin/cli/cron.php
Nice=10
IOSchedulingClass=idle
SYSTEMD_SERVICE

  cat > "${SYSTEMD_TIMER_FILE}" <<'SYSTEMD_TIMER'
[Unit]
Description=Run Moodle cron every minute

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
AccuracySec=10s
Unit=moodle-cron.service

[Install]
WantedBy=timers.target
SYSTEMD_TIMER

  systemctl daemon-reload
  systemctl enable --now moodle-cron.timer

  sleep 2
  if systemctl is-active --quiet moodle-cron.timer; then
    log "Moodle cron timer is active"
  else
    warn "Moodle cron timer did not start – check 'systemctl status moodle-cron.timer'"
  fi
}

# ---------- Comprehensive feature check ----------
parse_fpm_pool_value() {
  local key="$1"
  grep -E "^\s*php_admin_value\[${key}\]" "${PHP_FPM_POOL_FILE}" | \
    sed -E 's/.*=\s*//; s/\s*$//' | tail -1
}

check_moodle_features() {
  log "Verifying Moodle 4.5 features (16GB server tuned)"

  local all_ok=true
  local warnings=()

  log "1. PHP version"
  local php_ver=$("${PHP_CLI_BIN}" -v | head -1 | grep -oP 'PHP \K[0-9]+\.[0-9]+')
  if [[ "${php_ver}" == "8.3" ]]; then
    printf '  ✓ PHP %s\n' "${php_ver}"
  else
    printf '  ✗ PHP %s (required 8.3)\n' "${php_ver}"
    all_ok=false
  fi

  log "2. Required PHP extensions"
  local req_ext=( curl dom gd intl json mbstring openssl pcre pgsql SimpleXML sodium tokenizer xml xmlreader zip )
  local missing_req=()
  for ext in "${req_ext[@]}"; do
    if php_extension_loaded "${ext}"; then
      printf '  ✓ %s\n' "${ext}"
    else
      printf '  ✗ MISSING %s\n' "${ext}"
      missing_req+=("${ext}")
      all_ok=false
    fi
  done
  [[ ${#missing_req[@]} -gt 0 ]] && die "Critical: missing required extensions: ${missing_req[*]}"

  log "3. Recommended extensions"
  local rec_ext=( bcmath fileinfo iconv opcache redis soap xmlrpc )
  for ext in "${rec_ext[@]}"; do
    if php_extension_loaded "${ext}"; then
      printf '  ✓ %s\n' "${ext}"
    else
      printf '  ○ Missing %s\n' "${ext}"
      warnings+=("Missing recommended extension: ${ext}")
    fi
  done

  log "4. PHP-FPM pool configuration"
  declare -A expected_pool=(
    [memory_limit]=1024M
    [upload_max_filesize]=512M
    [post_max_size]=512M
    [max_execution_time]=300
    [max_input_vars]=5000
    [opcache.enable]=1
    [opcache.memory_consumption]=512
  )
  for key in "${!expected_pool[@]}"; do
    local actual
    actual=$(parse_fpm_pool_value "${key}")
    local expect="${expected_pool[$key]}"
    if [[ "${actual}" == "${expect}" ]] || \
       ( [[ "${actual}" =~ ^[0-9]+$ ]] && [[ "${expect}" =~ ^[0-9]+$ ]] && (( actual >= expect )) ); then
      printf '  ✓ %s = %s\n' "${key}" "${actual}"
    else
      printf '  ✗ %s = %s (expected %s)\n' "${key}" "${actual}" "${expect}"
      all_ok=false
    fi
  done

  log "5. PostgreSQL"
  local pg_ver; pg_ver=$(sudo -u postgres psql -tAc "SHOW server_version;" | cut -d. -f1)
  if [[ "${pg_ver}" -ge 12 ]]; then
    printf '  ✓ PostgreSQL %s\n' "${pg_ver}"
  else
    printf '  ✗ PostgreSQL %s (need >=12)\n' "${pg_ver}"
    all_ok=false
  fi
  if sudo -u postgres psql -d "${MOODLE_DB}" -c "SELECT 1;" >/dev/null 2>&1; then
    printf '  ✓ Database connection OK\n'
  else
    printf '  ✗ Database connection failed\n'
    all_ok=false
  fi

  log "6. Services"
  local svc_list=(
    "postgresql:PostgreSQL"
    "redis-server:Redis"
    "nginx:Nginx"
    "php${PHP_VERSION}-fpm:PHP-FPM"
    "moodle-cron.timer:Moodle Cron"
  )
  for svc in "${svc_list[@]}"; do
    local name="${svc%%:*}"
    local label="${svc##*:}"
    if systemctl is-active --quiet "${name}" 2>/dev/null; then
      printf '  ✓ %s running\n' "${label}"
    else
      printf '  ✗ %s NOT running\n' "${label}"
      all_ok=false
    fi
  done

  log "7. Disk space"
  local avail; avail=$(df -BG "${MOODLE_DATA_DIR}" 2>/dev/null | awk 'NR==2{print $4}' | sed 's/G//')
  if [[ -n "${avail}" && "${avail}" -ge 10 ]]; then
    printf '  ✓ %s GB free (plenty for 500GB storage)\n' "${avail}"
  elif [[ -n "${avail}" && "${avail}" -ge 5 ]]; then
    printf '  ○ %s GB free (minimum 5 GB, consider expanding)\n' "${avail}"
    warnings+=("Low disk space for moodledata")
  else
    printf '  ✗ Unable to check or insufficient space\n'
    all_ok=false
  fi

  log "8. Moodle installation"
  if moodle_is_installed; then
    printf '  ✓ Moodle installed\n'
  else
    printf '  ✗ Moodle not installed\n'
    all_ok=false
  fi

  log "9. Redis connectivity"
  if redis-cli ping | grep -q PONG; then
    printf '  ✓ Redis responds\n'
  else
    printf '  ✗ Redis not reachable\n'
    all_ok=false
  fi

  echo
  if [[ "${all_ok}" == "true" ]]; then
    log "✓ All critical checks passed"
  else
    die "✗ Critical checks failed – see above"
  fi
  if [[ ${#warnings[@]} -gt 0 ]]; then
    warn "Warnings:"
    printf '  • %s\n' "${warnings[@]}"
  fi
}

# ---------- TLS certificate ----------
generate_self_signed_cert() {
  log "Generating self-signed certificate"
  install -d -m 0755 "${NGINX_SSL_DIR}"
  if [[ -f "${NGINX_CERT_FILE}" && -f "${NGINX_KEY_FILE}" ]]; then
    log "Certificate already exists – skipping"
    return
  fi
  local san="DNS:${MOODLE_HOST}"
  is_ipv4 "${MOODLE_HOST}" && san="${san},IP:${MOODLE_HOST}"
  openssl req -x509 -nodes -newkey rsa:4096 -sha256 \
    -days "${CERT_VALID_DAYS}" \
    -keyout "${NGINX_KEY_FILE}" \
    -out "${NGINX_CERT_FILE}" \
    -subj "/CN=${MOODLE_HOST}" \
    -addext "subjectAltName=${san}"
  chmod 0600 "${NGINX_KEY_FILE}"
  chmod 0644 "${NGINX_CERT_FILE}"
  openssl x509 -in "${NGINX_CERT_FILE}" -noout -subject >/dev/null || die "Invalid certificate"
}

# ---------- Nginx site (old file deleted, recreated correctly) ----------
write_nginx_site() {
  log "Writing Nginx site (old configuration deleted)"
  # Remove any previous Moodle site files
  rm -f "${NGINX_SITE_FILE}" /etc/nginx/sites-enabled/moodle /etc/nginx/sites-enabled/default

  cat > "${NGINX_SITE_FILE}" <<NGINX_SITE
server {
    listen 80;
    listen [::]:80;
    server_name ${MOODLE_HOST};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${MOODLE_HOST};

    ssl_certificate /etc/nginx/ssl/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    client_max_body_size 512M;
    root /var/www/moodle;
    index index.php;

    add_header X-Frame-Options SAMEORIGIN always;
    add_header X-Content-Type-Options nosniff always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy strict-origin-when-cross-origin always;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ^~ /moodledata/ { deny all; }
    location ~ /\.(?!well-known).* { deny all; }
    location ~* ^/(vendor/|composer\.(json|lock)$|config\.php$) { deny all; }

    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2)$ {
        expires 30d;
        access_log off;
        try_files \$uri =404;
    }

    location ~ [^/]\.php(/|$) {
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param PATH_INFO \$fastcgi_path_info;
        fastcgi_param HTTPS on;
        fastcgi_param HTTP_PROXY "";
        fastcgi_read_timeout 300;
        fastcgi_pass unix:${PHP_FPM_SOCKET};
    }
}
NGINX_SITE

  ln -sfn "${NGINX_SITE_FILE}" /etc/nginx/sites-enabled/moodle

  # Hide Nginx version
  if ! grep -q 'server_tokens off;' /etc/nginx/nginx.conf; then
    sed -i '/http {/a\        server_tokens off;' /etc/nginx/nginx.conf
  fi

  nginx -t
  systemctl reload nginx
  log "Nginx configuration applied successfully"
}

# ---------- Firewall ----------
configure_firewall() {
  log "Configuring UFW"
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow 22/tcp comment 'SSH'
  ufw allow 80/tcp comment 'HTTP'
  ufw allow 443/tcp comment 'HTTPS'
  ufw --force enable
}

# ---------- Hardening ----------
post_install_hardening() {
  log "Applying hardening"
  if [[ -f /etc/ssh/sshd_config ]]; then
    if grep -Eq '^[#[:space:]]*PermitRootLogin[[:space:]]+' /etc/ssh/sshd_config; then
      sed -i -E 's/^[#[:space:]]*PermitRootLogin[[:space:]]+.*/PermitRootLogin no/' /etc/ssh/sshd_config
    else
      printf '\nPermitRootLogin no\n' >> /etc/ssh/sshd_config
    fi
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || warn "Could not reload SSH"
  fi

  cat > /etc/fail2ban/jail.d/sshd.local <<'FAIL2BAN'
[sshd]
enabled = true
port = ssh
filter = sshd
logpath = %(sshd_log)s
backend = systemd
maxretry = 5
findtime = 10m
bantime = 1h
FAIL2BAN
  systemctl enable --now fail2ban
  systemctl restart fail2ban
}

# ---------- Health check ----------
health_check() {
  log "Waiting for Moodle login page"
  local url="https://${MOODLE_HOST}/login/index.php"
  local deadline=$((SECONDS + 600))
  local ok=false
  curl_http_status() {
    curl -skL --connect-timeout 5 --max-time 20 -o /dev/null -w '%{http_code}' "$@" 2>/dev/null || printf '000'
  }
  status_is_ready() { [[ "$1" =~ ^[23][0-9][0-9]$ ]]; }

  while (( SECONDS < deadline )); do
    if status_is_ready "$(curl_http_status "${url}")"; then ok=true; break; fi
    if status_is_ready "$(curl_http_status --resolve "${MOODLE_HOST}:443:127.0.0.1" "${url}")"; then ok=true; break; fi
    printf 'Moodle not ready yet – retrying in 15s...\n'
    sleep 15
  done
  [[ "${ok}" == "true" ]] || warn "Moodle did not respond within 10 minutes"
}

# ---------- Summary ----------
print_success_summary() {
  cat <<SUMMARY

============================================================
Moodle 4.5 on Ubuntu 24.04 – deployment complete
============================================================

URL:            https://${MOODLE_HOST}
Admin user:     ${MOODLE_ADMIN_USER}
PHP:            ${PHP_VERSION} (native)
Moodle branch:  ${MOODLE_BRANCH}
Memory / disk:  tuned for 16GB RAM / 500GB storage

Logs:
  Nginx:    /var/log/nginx/
  PHP-FPM:  /var/log/php${PHP_VERSION}-fpm.log

Cron timer:
  systemctl status moodle-cron.timer

Environment:
  ${MOODLE_ENV_FILE}

All features verified – if any warnings appeared above, review them.
============================================================
SUMMARY
}

# ---------- Main (order corrected) ----------
main() {
  require_command apt
  collect_inputs
  system_prep
  install_php
  install_postgresql
  install_and_configure_redis
  install_nginx
  write_env_files
  load_env
  configure_postgresql
  setup_moodle_code
  write_php_fpm_pool
  run_moodle_cli_install
  write_systemd_cron
  check_moodle_features
  generate_self_signed_cert
  write_nginx_site
  configure_firewall
  post_install_hardening
  health_check
  print_success_summary
}

main "$@"