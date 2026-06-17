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
# Moodle 5.0 targets Ubuntu 26.04 LTS and its native PHP 8.4 (Moodle 5.0
# supports PHP 8.2-8.4). Override PHP_VERSION/MOODLE_BRANCH here if your release
# ships a different default PHP.
PHP_VERSION="${PHP_VERSION:-8.4}"
MOODLE_BRANCH="${MOODLE_BRANCH:-MOODLE_500_STABLE}"
PHP_FPM_SOCKET="/run/php/php${PHP_VERSION}-fpm-moodle.sock"
PHP_FPM_POOL_FILE="/etc/php/${PHP_VERSION}/fpm/pool.d/moodle.conf"
PHP_INI_FILE="/etc/php/${PHP_VERSION}/fpm/php.ini"

# ondrej/php PPA (manual setup, used only as a fallback when the distro does not
# ship the required PHP version). Falls back to the newest codename ondrej builds
# for when the running release is unsupported.
ONDREJ_PHP_FALLBACK_CODENAME="noble"
ONDREJ_PHP_KEY_ID="B8DC7E53946656EFBCE4C1DD71DAEAAB4AD4CAB6"
ONDREJ_PHP_KEYRING="/usr/share/keyrings/ondrej-php.gpg"
ONDREJ_PHP_SOURCE_FILE="/etc/apt/sources.list.d/ondrej-php.list"

# PostgreSQL apt repository fallback codename, used when the running release has
# no -pgdg release published yet.
PGDG_FALLBACK_CODENAME="noble"
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

ensure_line() {
  local file="$1"
  local pattern="$2"
  local line="$3"
  if grep -Eq "${pattern}" "${file}"; then
    sed -i -E "s|${pattern}|${line}|" "${file}"
  else
    printf '%s\n' "${line}" >> "${file}"
  fi
}

is_supported_ondrej_php_codename() {
  case "$1" in
    jammy|noble)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

ondrej_php_repo_codename() {
  # Echo a codename that the ondrej/php PPA actually publishes packages for.
  local codename="$1"
  if is_supported_ondrej_php_codename "${codename}"; then
    printf '%s' "${codename}"
  else
    printf '%s' "${ONDREJ_PHP_FALLBACK_CODENAME}"
  fi
}

setup_ondrej_php_repo() {
  # Configure the ondrej/php PPA manually with a signed keyring. add-apt-repository
  # refuses codenames the PPA has not published for, so we do it by hand and fall
  # back to the newest supported codename when needed.
  local codename="$1"
  local repo_codename
  repo_codename="$(ondrej_php_repo_codename "${codename}")"

  if [[ "${repo_codename}" != "${codename}" ]]; then
    warn "Ubuntu ${codename} has no ondrej/php release yet; using ondrej/php packages built for ${repo_codename}. PHP ${PHP_VERSION} is required by this Moodle installer."
  fi

  if [[ ! -s "${ONDREJ_PHP_KEYRING}" ]]; then
    log "Importing ondrej/php signing key"
    curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x${ONDREJ_PHP_KEY_ID}" \
      | gpg --dearmor -o "${ONDREJ_PHP_KEYRING}"
    chmod 0644 "${ONDREJ_PHP_KEYRING}"
  fi

  cat > "${ONDREJ_PHP_SOURCE_FILE}" <<EOF_ONDREJ
deb [signed-by=${ONDREJ_PHP_KEYRING}] https://ppa.launchpadcontent.net/ondrej/php/ubuntu ${repo_codename} main
EOF_ONDREJ
}

ubuntu_codename() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    printf '%s' "${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
    return
  fi
  lsb_release -cs 2>/dev/null || true
}

disable_unsupported_ondrej_php_ppa() {
  local codename="$1"
  local source_file
  local backup_dir

  is_supported_ondrej_php_codename "${codename}" && return 0

  backup_dir="/etc/apt/sources.list.d/disabled-ondrej-php-$(date +%Y%m%d%H%M%S)"
  for source_file in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
    [[ -e "${source_file}" ]] || continue
    if grep -Eiq 'ppa\.launchpadcontent\.net/ondrej/php|ppa:ondrej/php|ondrej.*php' "${source_file}"; then
      install -d -m 0755 "${backup_dir}"
      mv "${source_file}" "${backup_dir}/"
    fi
  done
}

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
    MOODLE_HOST=""
    valid=false
  fi
  if [[ -n "${MOODLE_DB}" ]] && ! is_pg_identifier "${MOODLE_DB}"; then
    warn "MOODLE_DB in ${LOCAL_ENV_FILE} must be a PostgreSQL identifier."
    MOODLE_DB=""
    valid=false
  fi
  if [[ -n "${MOODLE_DB_USER}" ]] && ! is_pg_identifier "${MOODLE_DB_USER}"; then
    warn "MOODLE_DB_USER in ${LOCAL_ENV_FILE} must be a PostgreSQL identifier."
    MOODLE_DB_USER=""
    valid=false
  fi
  if [[ -n "${CERT_VALID_DAYS}" ]] && ! [[ "${CERT_VALID_DAYS}" =~ ^[1-9][0-9]*$ ]]; then
    warn "CERT_VALID_DAYS in ${LOCAL_ENV_FILE} must be a positive whole number."
    CERT_VALID_DAYS=""
    valid=false
  fi
  if [[ -n "${MOODLE_ADMIN_EMAIL}" ]] && ! [[ "${MOODLE_ADMIN_EMAIL}" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then
    warn "MOODLE_ADMIN_EMAIL in ${LOCAL_ENV_FILE} is not a valid email address."
    MOODLE_ADMIN_EMAIL=""
    valid=false
  fi
  if [[ -n "${MOODLE_ADMIN_PASS}" ]] && ! password_meets_moodle_policy "${MOODLE_ADMIN_PASS}"; then
    warn "MOODLE_ADMIN_PASS in ${LOCAL_ENV_FILE} does not satisfy Moodle's default password policy."
    MOODLE_ADMIN_PASS=""
    valid=false
  fi

  [[ "${valid}" == "true" ]]
}

collect_inputs() {
  load_local_env_if_present
  validate_existing_inputs || true

  if [[ -n "${MOODLE_HOST}" && -n "${MOODLE_SITE_NAME}" && -n "${MOODLE_ADMIN_USER}" && -n "${MOODLE_ADMIN_PASS}" && -n "${MOODLE_ADMIN_EMAIL}" && -n "${MOODLE_DB}" && -n "${MOODLE_DB_USER}" && -n "${MOODLE_DB_PASS}" && -n "${CERT_VALID_DAYS}" ]]; then
    log "Using complete Moodle settings from ${LOCAL_ENV_FILE}"
    return
  fi

  log "Collecting missing Moodle deployment settings"
  [[ -n "${MOODLE_HOST}" ]] || read_required "MOODLE_HOST" "Server IP or hostname" "The local IP address or hostname clients will use, for example 192.168.1.50 or moodle.local. This is used for Moodle wwwroot and the self-signed certificate." "" "host"
  [[ -n "${MOODLE_SITE_NAME}" ]] || read_required "MOODLE_SITE_NAME" "Moodle site name" "The display name shown in the Moodle LMS interface." "My Moodle Site"
  [[ -n "${MOODLE_ADMIN_USER}" ]] || read_required "MOODLE_ADMIN_USER" "Moodle admin username" "The administrator account name created by Moodle's installer." "admin"
  [[ -n "${MOODLE_ADMIN_PASS}" ]] || read_secret_confirm "MOODLE_ADMIN_PASS" "Moodle admin password" "The initial administrator password. It must satisfy Moodle's default password policy." "true"
  [[ -n "${MOODLE_ADMIN_EMAIL}" ]] || read_required "MOODLE_ADMIN_EMAIL" "Moodle admin email" "The administrator email address Moodle stores for the initial admin account." "" "email"
  [[ -n "${MOODLE_DB}" ]] || read_required "MOODLE_DB" "PostgreSQL database name" "The database that will store Moodle data." "moodle" "pg_identifier"
  [[ -n "${MOODLE_DB_USER}" ]] || read_required "MOODLE_DB_USER" "PostgreSQL username" "The PostgreSQL role Moodle will use to connect to the database." "moodle" "pg_identifier"
  [[ -n "${MOODLE_DB_PASS}" ]] || read_secret_confirm "MOODLE_DB_PASS" "PostgreSQL password" "The password for Moodle's PostgreSQL role."
  [[ -n "${CERT_VALID_DAYS}" ]] || read_required "CERT_VALID_DAYS" "Self-signed certificate validity days" "The number of days the locally generated TLS certificate remains valid." "3650" "positive_integer"
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
# Server IP address or local hostname clients use to reach Moodle.
MOODLE_HOST="192.168.1.50"

# Display name shown in the Moodle LMS interface.
MOODLE_SITE_NAME="My Moodle Site"

# Initial Moodle administrator username.
MOODLE_ADMIN_USER="admin"

# Initial Moodle administrator password. Do not use this example value.
MOODLE_ADMIN_PASS="ChangeMe-With-A-Strong-Password1!"

# Initial Moodle administrator email address.
MOODLE_ADMIN_EMAIL="admin@example.local"

# PostgreSQL database name for Moodle.
MOODLE_DB="moodle"

# PostgreSQL role Moodle uses to connect to the database.
MOODLE_DB_USER="moodle"

# PostgreSQL password for MOODLE_DB_USER. Do not use this example value.
MOODLE_DB_PASS="ChangeMe-With-A-Strong-Database-Password1!"

# Self-signed TLS certificate validity period in days.
CERT_VALID_DAYS="3650"
ENV_EXAMPLE
  chown root:root "${MOODLE_ENV_EXAMPLE}"
  chmod 0644 "${MOODLE_ENV_EXAMPLE}"
}

load_env() {
  # shellcheck disable=SC1090
  source "${MOODLE_ENV_FILE}"
}

system_prep() {
  log "Preparing Ubuntu packages"
  local codename
  codename="$(ubuntu_codename)"
  disable_unsupported_ondrej_php_ppa "${codename}"
  apt update
  apt upgrade -y
  apt install -y curl git ca-certificates gnupg ufw fail2ban htop unzip openssl wget sudo software-properties-common lsb-release apt-transport-https
}

install_php() {
  log "Installing PHP ${PHP_VERSION} and Moodle extensions"
  local codename
  codename="$(ubuntu_codename)"

  # Prefer packages already visible (distro repo or a previously configured PPA);
  # otherwise add the ondrej/php PPA, using a fallback codename on releases the
  # PPA has not published for yet (e.g. Ubuntu 26.04).
  if apt-cache show "php${PHP_VERSION}-fpm" >/dev/null 2>&1; then
    log "PHP ${PHP_VERSION} packages already available from configured repositories"
  else
    setup_ondrej_php_repo "${codename}"
    apt update
  fi

  if ! apt-cache show "php${PHP_VERSION}-fpm" >/dev/null 2>&1; then
    die "Unable to locate php${PHP_VERSION} packages even after configuring the ondrej/php repository for Ubuntu ${codename}. Check network access to ppa.launchpadcontent.net and that the ondrej/php fallback codename (${ONDREJ_PHP_FALLBACK_CODENAME}) is reachable."
  fi

  if command -v "php${PHP_VERSION}" >/dev/null 2>&1; then
    log "PHP ${PHP_VERSION} already installed; ensuring required extensions are present"
  fi
  apt install -y \
    "php${PHP_VERSION}-fpm" "php${PHP_VERSION}-pgsql" "php${PHP_VERSION}-xml" \
    "php${PHP_VERSION}-mbstring" "php${PHP_VERSION}-curl" "php${PHP_VERSION}-zip" \
    "php${PHP_VERSION}-gd" "php${PHP_VERSION}-intl" "php${PHP_VERSION}-soap" \
    "php${PHP_VERSION}-xmlrpc" "php${PHP_VERSION}-redis" "php${PHP_VERSION}-opcache" \
    "php${PHP_VERSION}-bcmath"
}

pgdg_repo_codename() {
  # Echo a codename the PostgreSQL apt repository actually publishes, or nothing
  # if neither the running release nor the fallback is available.
  local codename="$1"
  local candidate
  for candidate in "${codename}" "${PGDG_FALLBACK_CODENAME}"; do
    [[ -n "${candidate}" ]] || continue
    if curl -fsSL --head "https://apt.postgresql.org/pub/repos/apt/dists/${candidate}-pgdg/Release" >/dev/null 2>&1; then
      printf '%s' "${candidate}"
      return 0
    fi
  done
  return 1
}

install_postgresql() {
  local codename repo_codename
  codename="$(lsb_release -cs)"

  if repo_codename="$(pgdg_repo_codename "${codename}")"; then
    log "Installing PostgreSQL from the official PostgreSQL apt repository (${repo_codename}-pgdg)"
    if [[ "${repo_codename}" != "${codename}" ]]; then
      warn "PostgreSQL apt repository has no ${codename}-pgdg release yet; using ${repo_codename}-pgdg packages."
    fi
    install -d -m 0755 /usr/share/postgresql-common/pgdg
    if [[ ! -f /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc ]]; then
      curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc
    fi
    cat > /etc/apt/sources.list.d/pgdg.list <<EOF_PGDG
deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt ${repo_codename}-pgdg main
EOF_PGDG
    apt update
  else
    warn "PostgreSQL apt repository is unavailable for ${codename}; using Ubuntu's bundled PostgreSQL packages."
    rm -f /etc/apt/sources.list.d/pgdg.list
  fi

  apt install -y postgresql postgresql-contrib
  systemctl enable --now postgresql
}

configure_postgresql() {
  log "Configuring PostgreSQL role and database"
  local quoted_password
  quoted_password="$(sql_quote_literal "${MOODLE_DB_PASS}")"

  if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname = '${MOODLE_DB_USER}'" | grep -q 1; then
    log "PostgreSQL role ${MOODLE_DB_USER} already exists; updating password to match ${MOODLE_ENV_FILE}"
    sudo -u postgres psql -v ON_ERROR_STOP=1 -c "ALTER ROLE \"${MOODLE_DB_USER}\" WITH LOGIN PASSWORD ${quoted_password};"
  else
    sudo -u postgres psql -v ON_ERROR_STOP=1 -c "CREATE ROLE \"${MOODLE_DB_USER}\" WITH LOGIN PASSWORD ${quoted_password};"
  fi

  if sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname = '${MOODLE_DB}'" | grep -q 1; then
    log "PostgreSQL database ${MOODLE_DB} already exists"
  else
    sudo -u postgres createdb -O "${MOODLE_DB_USER}" -E UTF8 "${MOODLE_DB}"
  fi

  sudo -u postgres psql -v ON_ERROR_STOP=1 -d "${MOODLE_DB}" -c "ALTER DATABASE \"${MOODLE_DB}\" OWNER TO \"${MOODLE_DB_USER}\";"
}

install_and_configure_redis() {
  log "Installing and configuring Redis"
  apt install -y redis-server
  sed -i -E '/^[[:space:]]*maxmemory[[:space:]]+/d' /etc/redis/redis.conf
  sed -i -E '/^[[:space:]]*maxmemory-policy[[:space:]]+/d' /etc/redis/redis.conf
  sed -i -E '/^[[:space:]]*save[[:space:]]+/d' /etc/redis/redis.conf
  sed -i -E '/^[[:space:]]*bind[[:space:]]+/d' /etc/redis/redis.conf
  cat >> /etc/redis/redis.conf <<'REDIS_CONF'

bind 127.0.0.1
protected-mode yes
maxmemory 2gb
maxmemory-policy allkeys-lru
save ""
REDIS_CONF
  systemctl enable --now redis-server
  systemctl restart redis-server
}

install_nginx() {
  log "Installing Nginx"
  apt install -y nginx
  systemctl enable --now nginx
}

setup_moodle_code() {
  log "Setting up Moodle code and data directories"
  if [[ -d "${MOODLE_DIR}/.git" ]]; then
    log "${MOODLE_DIR} already exists; skipping Moodle git clone"
  elif [[ -e "${MOODLE_DIR}" ]]; then
    die "${MOODLE_DIR} exists but is not a Moodle git checkout. Move it aside before rerunning."
  else
    git clone --depth 1 --branch "${MOODLE_BRANCH}" https://github.com/moodle/moodle.git "${MOODLE_DIR}"
  fi

  install -d -m 0770 -o www-data -g www-data "${MOODLE_DATA_DIR}"
  chown -R www-data:www-data "${MOODLE_DIR}" "${MOODLE_DATA_DIR}"
  chmod 0755 "${MOODLE_DIR}"
  chmod 0770 "${MOODLE_DATA_DIR}"
}

write_php_fpm_pool() {
  log "Writing PHP-FPM Moodle pool"
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
pm.max_children = 50
pm.start_servers = 10
pm.min_spare_servers = 5
pm.max_spare_servers = 20
pm.max_requests = 500

php_admin_value[memory_limit] = 512M
php_admin_value[upload_max_filesize] = 256M
php_admin_value[post_max_size] = 256M
php_admin_value[max_execution_time] = 300
php_admin_value[max_input_vars] = 5000
php_admin_value[opcache.enable] = 1
php_admin_value[opcache.memory_consumption] = 256
php_admin_value[opcache.max_accelerated_files] = 10000
php_admin_value[opcache.revalidate_freq] = 60
PHP_FPM_POOL

  sed -i -E 's/^[;[:space:]]*expose_php[[:space:]]*=.*/expose_php = Off/' "${PHP_INI_FILE}"
  systemctl restart "php${PHP_VERSION}-fpm"
}

write_moodle_config_php() {
  log "Writing Moodle config.php"
  cat > "${MOODLE_DIR}/config.php" <<'PHP_CONFIG'
<?php  // Moodle configuration file.
unset($CFG);
global $CFG;
$CFG = new stdClass();

$envfile = '/opt/moodle/.env';
if (!is_readable($envfile)) {
    throw new RuntimeException('Moodle environment file is not readable: ' . $envfile);
}

$env = [];
foreach (file($envfile, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) as $line) {
    $line = trim($line);
    if ($line === '' || str_starts_with($line, '#') || !str_contains($line, '=')) {
        continue;
    }
    [$key, $value] = explode('=', $line, 2);
    $key = trim($key);
    $value = trim($value);
    if ($value !== '' && $value[0] === '"' && substr($value, -1) === '"') {
        $value = stripcslashes(substr($value, 1, -1));
    }
    $env[$key] = $value;
}

foreach (['MOODLE_HOST', 'MOODLE_DB', 'MOODLE_DB_USER', 'MOODLE_DB_PASS'] as $required) {
    if (!array_key_exists($required, $env) || $env[$required] === '') {
        throw new RuntimeException('Missing required Moodle environment value: ' . $required);
    }
}

$CFG->dbtype    = 'pgsql';
$CFG->dblibrary = 'native';
$CFG->dbhost    = '127.0.0.1';
$CFG->dbname    = $env['MOODLE_DB'];
$CFG->dbuser    = $env['MOODLE_DB_USER'];
$CFG->dbpass    = $env['MOODLE_DB_PASS'];
$CFG->prefix    = 'mdl_';
$CFG->dboptions = [
    'dbpersist' => false,
    'dbsocket'  => false,
    'dbport'    => '',
];

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

moodle_db_has_config_table() {
  sudo -u postgres psql -d "${MOODLE_DB}" -tAc "SELECT to_regclass('public.mdl_config')" 2>/dev/null | grep -q 'mdl_config'
}

moodle_is_installed() {
  [[ -f "${MOODLE_SENTINEL}" ]] || moodle_db_has_config_table
}

run_moodle_cli_install() {
  log "Running Moodle CLI installer if needed"
  if moodle_is_installed; then
    log "Moodle already appears installed; skipping CLI install"
    write_moodle_config_php
    install -o www-data -g www-data -m 0640 /dev/null "${MOODLE_SENTINEL}"
    return
  fi

  if [[ -f "${MOODLE_DIR}/config.php" ]]; then
    local backup_timestamp
    local backup
    backup_timestamp="$(date +%Y%m%d%H%M%S)"
    backup="${MOODLE_DIR}/config.php.preinstall.${backup_timestamp}"
    warn "Existing config.php found before database install; backing it up to ${backup}"
    cp -a "${MOODLE_DIR}/config.php" "${backup}"
    rm -f "${MOODLE_DIR}/config.php"
  fi

  sudo -u www-data php "${MOODLE_DIR}/admin/cli/install.php" \
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
}

generate_self_signed_cert() {
  log "Generating self-signed TLS certificate if needed"
  install -d -m 0755 "${NGINX_SSL_DIR}"
  if [[ -f "${NGINX_CERT_FILE}" && -f "${NGINX_KEY_FILE}" ]]; then
    log "Existing TLS certificate and key found; skipping generation"
    return
  fi

  local san="DNS:${MOODLE_HOST}"
  if is_ipv4 "${MOODLE_HOST}"; then
    san="${san},IP:${MOODLE_HOST}"
  fi

  openssl req -x509 -nodes -newkey rsa:4096 -sha256 \
    -days "${CERT_VALID_DAYS}" \
    -keyout "${NGINX_KEY_FILE}" \
    -out "${NGINX_CERT_FILE}" \
    -subj "/CN=${MOODLE_HOST}" \
    -addext "subjectAltName=${san}"

  chmod 0600 "${NGINX_KEY_FILE}"
  chmod 0644 "${NGINX_CERT_FILE}"
}

write_nginx_site() {
  log "Writing Nginx Moodle site"
  rm -f /etc/nginx/sites-enabled/default

  cat > "${NGINX_SITE_FILE}" <<NGINX_SITE
server {
    listen 80;
    listen [::]:80;
    server_name ${MOODLE_HOST};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name ${MOODLE_HOST};

    ssl_certificate /etc/nginx/ssl/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    client_max_body_size 256M;
    root /var/www/moodle;
    index index.php;

    add_header X-Frame-Options SAMEORIGIN always;
    add_header X-Content-Type-Options nosniff always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy strict-origin-when-cross-origin always;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ^~ /moodledata/ {
        deny all;
    }

    location ~ /\.(?!well-known).* {
        deny all;
    }

    location ~* ^/(vendor/|composer\.(json|lock)$|config\.php$) {
        deny all;
    }

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

  if grep -Eq '^[[:space:]]*server_tokens[[:space:]]+' /etc/nginx/nginx.conf; then
    sed -i -E 's/^[[:space:]]*server_tokens[[:space:]]+[^;]+;/        server_tokens off;/' /etc/nginx/nginx.conf
  else
    sed -i '/http {/a\        server_tokens off;' /etc/nginx/nginx.conf
  fi

  nginx -t
  systemctl reload nginx
}

configure_firewall() {
  log "Configuring UFW firewall"
  ufw default deny incoming
  ufw default allow outgoing
  ufw status | grep -Eq '22/tcp|OpenSSH' || ufw allow 22/tcp comment 'SSH'
  ufw status | grep -Eq '80/tcp' || ufw allow 80/tcp comment 'HTTP'
  ufw status | grep -Eq '443/tcp' || ufw allow 443/tcp comment 'HTTPS'
  ufw --force enable
}

write_systemd_cron() {
  log "Writing Moodle cron systemd timer"
  cat > "${SYSTEMD_SERVICE_FILE}" <<'SYSTEMD_SERVICE'
[Unit]
Description=Moodle cron job
After=network.target postgresql.service redis-server.service

[Service]
Type=oneshot
ExecStart=/usr/bin/sudo -u www-data /usr/bin/php /var/www/moodle/admin/cli/cron.php
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
}

post_install_hardening() {
  log "Applying post-install hardening"
  if [[ -f /etc/ssh/sshd_config ]]; then
    if grep -Eq '^[#[:space:]]*PermitRootLogin[[:space:]]+' /etc/ssh/sshd_config; then
      sed -i -E 's/^[#[:space:]]*PermitRootLogin[[:space:]]+.*/PermitRootLogin no/' /etc/ssh/sshd_config
    else
      printf '\nPermitRootLogin no\n' >> /etc/ssh/sshd_config
    fi
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || warn "Could not reload SSH service; verify SSH configuration manually"
  else
    warn "/etc/ssh/sshd_config not found; skipping root SSH login hardening"
  fi

  cat > /etc/fail2ban/jail.d/sshd.local <<'FAIL2BAN_JAIL'
[sshd]
enabled = true
port = ssh
filter = sshd
logpath = %(sshd_log)s
backend = systemd
maxretry = 5
findtime = 10m
bantime = 1h
FAIL2BAN_JAIL
  systemctl enable --now fail2ban
  systemctl restart fail2ban
}

health_check() {
  log "Waiting for Moodle login page"
  local url="https://${MOODLE_HOST}/login/index.php"
  local deadline=$((SECONDS + 600))
  local ok=false

  while (( SECONDS < deadline )); do
    if curl -sk --connect-timeout 5 --max-time 20 "${url}" | grep -Eiq '<title>|login'; then
      ok=true
      break
    fi
    if curl -sk --connect-timeout 5 --max-time 20 --resolve "${MOODLE_HOST}:443:127.0.0.1" "${url}" | grep -Eiq '<title>|login'; then
      ok=true
      break
    fi
    printf 'Moodle is not ready yet; retrying in 15 seconds...\n'
    sleep 15
  done

  if [[ "${ok}" != "true" ]]; then
    warn "Moodle did not respond successfully within 10 minutes. Check Nginx, PHP-FPM, and Moodle logs listed below."
  fi
}

print_success_summary() {
  cat <<SUMMARY

============================================================
Moodle provisioning complete
============================================================

Access URL:
  https://${MOODLE_HOST}

Admin username:
  ${MOODLE_ADMIN_USER}

Self-signed certificate note:
  Browsers will show a certificate warning until clients trust the local
  certificate. Import this certificate into client trust stores:
  /etc/nginx/ssl/fullchain.pem

Useful logs:
  Nginx:    /var/log/nginx/
  PHP-FPM:  /var/log/php${PHP_VERSION}-fpm.log

Moodle cron timer:
  systemctl status moodle-cron.timer

Environment file:
  ${MOODLE_ENV_FILE}

============================================================
SUMMARY
}

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
  generate_self_signed_cert
  write_nginx_site
  configure_firewall
  write_systemd_cron
  post_install_hardening
  health_check
  print_success_summary
}

main "$@"
