#!/usr/bin/env bash
set -Eeuo pipefail

ACTION="install"
MOODLE_DIR="${MOODLE_DIR:-/var/www/moodle}"
BACKUP_DIR="${BACKUP_DIR:-/opt/moodle/quiz-timer-bar/backups}"
MARKER_START="<!-- moodle-quiz-timebar:start -->"
MARKER_END="<!-- moodle-quiz-timebar:end -->"

usage() {
  cat <<'USAGE'
Usage:
  sudo ./install-quiz-timer-bar.sh [install|uninstall|status] [--moodle-dir /var/www/moodle]

Actions:
  install     Add or replace the quiz timer red bar snippet in Moodle Additional HTML.
  uninstall   Remove the quiz timer red bar snippet from Moodle Additional HTML.
  status      Show whether the snippet is currently installed.

Environment:
  MOODLE_DIR  Moodle code directory. Default: /var/www/moodle
  BACKUP_DIR  Backup directory. Default: /opt/moodle/quiz-timer-bar/backups
USAGE
}

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

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    install|uninstall|status)
      ACTION="$1"
      shift
      ;;
    --moodle-dir)
      [[ "$#" -ge 2 ]] || die "--moodle-dir requires a value"
      MOODLE_DIR="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

CFG_CLI="${MOODLE_DIR}/admin/cli/cfg.php"
PURGE_CACHES_CLI="${MOODLE_DIR}/admin/cli/purge_caches.php"

if [[ ! -d "${MOODLE_DIR}" ]]; then
  die "Moodle directory not found: ${MOODLE_DIR}"
fi

if [[ ! -f "${MOODLE_DIR}/config.php" ]]; then
  die "Moodle config.php not found: ${MOODLE_DIR}/config.php"
fi

if [[ ! -f "${CFG_CLI}" ]]; then
  die "Moodle cfg.php not found: ${CFG_CLI}"
fi

if command -v php >/dev/null 2>&1; then
  PHP_BIN="$(command -v php)"
else
  die "php command not found"
fi

moodle_cli() {
  if id -u www-data >/dev/null 2>&1; then
    sudo -u www-data "${PHP_BIN}" "$@"
  else
    "${PHP_BIN}" "$@"
  fi
}

moodle_cfg_get() {
  moodle_cli "${CFG_CLI}" --name=additionalhtmlhead --no-eol
}

moodle_cfg_set() {
  local value="$1"
  moodle_cli "${CFG_CLI}" --name=additionalhtmlhead --set="${value}"
}

purge_moodle_caches() {
  if [[ -f "${PURGE_CACHES_CLI}" ]]; then
    moodle_cli "${PURGE_CACHES_CLI}"
  fi
}

current_additional_html() {
  local current
  if current="$(moodle_cfg_get 2>/dev/null)"; then
    printf '%s' "${current}"
  else
    printf ''
  fi
}

remove_existing_snippet() {
  awk -v start="${MARKER_START}" -v end="${MARKER_END}" '
    index($0, start) { skip = 1; next }
    index($0, end) { skip = 0; next }
    !skip { print }
  '
}

snippet_installed() {
  local content="$1"
  [[ "${content}" == *"${MARKER_START}"* && "${content}" == *"${MARKER_END}"* ]]
}

write_backup() {
  local content="$1"
  local backup_file

  install -d -m 0750 "${BACKUP_DIR}"
  backup_file="${BACKUP_DIR}/additionalhtmlhead.$(date +%Y%m%d%H%M%S).backup"
  printf '%s' "${content}" > "${backup_file}"
  chmod 0640 "${backup_file}"
  printf '%s' "${backup_file}"
}

quiz_timer_bar_snippet() {
  cat <<'SNIPPET'
<!-- moodle-quiz-timebar:start -->
<style id="moodle-quiz-timebar-style">
  #moodle-quiz-timebar {
    position: fixed;
    top: 0;
    left: 0;
    right: 0;
    height: 10px;
    z-index: 2147483000;
    background: rgba(0, 0, 0, 0.08);
    pointer-events: none;
  }

  #moodle-quiz-timebar-fill {
    width: 100%;
    height: 100%;
    background: #d71920;
    box-shadow: 0 0 10px rgba(215, 25, 32, 0.55);
    transform-origin: left center;
    transition: width 0.35s linear;
  }

  body.moodle-quiz-timebar-active {
    padding-top: 10px;
  }

  body.moodle-quiz-timebar-critical #moodle-quiz-timebar-fill {
    animation: moodle-quiz-timebar-pulse 1s ease-in-out infinite;
  }

  @keyframes moodle-quiz-timebar-pulse {
    0%, 100% { opacity: 1; }
    50% { opacity: 0.55; }
  }
</style>
<script id="moodle-quiz-timebar-script">
(function() {
  'use strict';

  if (window.__moodleQuizTimebarLoaded) {
    return;
  }
  window.__moodleQuizTimebarLoaded = true;

  var storagePrefix = 'moodleQuizTimebar:';
  var storageKey = storagePrefix + window.location.pathname + window.location.search;

  function parseTimeToSeconds(rawText) {
    var text = String(rawText || '').toLowerCase().replace(/\u00a0/g, ' ').trim();
    if (!text) {
      return null;
    }

    var clockMatches = text.match(/\d+\s*:\s*\d{1,2}(?:\s*:\s*\d{1,2})?/g);
    if (clockMatches && clockMatches.length) {
      var clock = clockMatches[clockMatches.length - 1].replace(/\s/g, '').split(':').map(Number);
      if (clock.length === 3) {
        return (clock[0] * 3600) + (clock[1] * 60) + clock[2];
      }
      if (clock.length === 2) {
        return (clock[0] * 60) + clock[1];
      }
    }

    var total = 0;
    var matched = false;
    var patterns = [
      [/(\d+)\s*(?:days?|d)\b/g, 86400],
      [/(\d+)\s*(?:hours?|hrs?|h)\b/g, 3600],
      [/(\d+)\s*(?:minutes?|mins?|m)\b/g, 60],
      [/(\d+)\s*(?:seconds?|secs?|s)\b/g, 1]
    ];

    patterns.forEach(function(pair) {
      var pattern = pair[0];
      var multiplier = pair[1];
      var match;
      while ((match = pattern.exec(text)) !== null) {
        total += Number(match[1]) * multiplier;
        matched = true;
      }
    });

    return matched ? total : null;
  }

  function findTimerElement() {
    return document.getElementById('quiz-time-left');
  }

  function ensureBar() {
    var existing = document.getElementById('moodle-quiz-timebar');
    if (existing) {
      return existing;
    }

    var bar = document.createElement('div');
    bar.id = 'moodle-quiz-timebar';
    bar.setAttribute('aria-hidden', 'true');

    var fill = document.createElement('div');
    fill.id = 'moodle-quiz-timebar-fill';
    bar.appendChild(fill);

    document.body.insertBefore(bar, document.body.firstChild);
    document.body.classList.add('moodle-quiz-timebar-active');
    return bar;
  }

  function readStoredTotal() {
    try {
      var stored = Number(window.sessionStorage.getItem(storageKey));
      return Number.isFinite(stored) && stored > 0 ? stored : null;
    } catch (error) {
      return null;
    }
  }

  function writeStoredTotal(total) {
    try {
      window.sessionStorage.setItem(storageKey, String(total));
    } catch (error) {
      // If storage is unavailable, the bar still works for the current page load.
    }
  }

  function updateBar() {
    var timer = findTimerElement();
    if (!timer) {
      return;
    }

    var secondsRemaining = parseTimeToSeconds(timer.textContent);
    if (secondsRemaining === null) {
      return;
    }

    ensureBar();

    var total = readStoredTotal();
    if (!total || secondsRemaining > total) {
      total = secondsRemaining;
      writeStoredTotal(total);
    }

    var percent = Math.max(0, Math.min(100, (secondsRemaining / total) * 100));
    var fill = document.getElementById('moodle-quiz-timebar-fill');
    if (fill) {
      fill.style.width = percent + '%';
    }

    document.body.classList.toggle('moodle-quiz-timebar-critical', percent <= 20);
  }

  function start() {
    if (!findTimerElement()) {
      return;
    }

    updateBar();
    window.setInterval(updateBar, 1000);

    var observer = new MutationObserver(updateBar);
    observer.observe(findTimerElement(), {
      childList: true,
      characterData: true,
      subtree: true
    });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', start);
  } else {
    start();
  }
})();
</script>
<!-- moodle-quiz-timebar:end -->
SNIPPET
}

install_snippet() {
  local current cleaned snippet backup_file new_content

  current="$(current_additional_html)"
  backup_file="$(write_backup "${current}")"
  cleaned="$(printf '%s' "${current}" | remove_existing_snippet)"
  snippet="$(quiz_timer_bar_snippet)"

  if [[ -n "${cleaned//[[:space:]]/}" ]]; then
    new_content="${cleaned}"$'\n\n'"${snippet}"
  else
    new_content="${snippet}"
  fi

  log "Installing quiz timer red bar snippet"
  moodle_cfg_set "${new_content}"
  purge_moodle_caches

  printf 'Previous additionalhtmlhead backed up to:\n  %s\n' "${backup_file}"
  printf 'Quiz timer red bar installed.\n'
}

uninstall_snippet() {
  local current cleaned backup_file

  current="$(current_additional_html)"
  if ! snippet_installed "${current}"; then
    log "Quiz timer red bar snippet is not installed"
    return
  fi

  backup_file="$(write_backup "${current}")"
  cleaned="$(printf '%s' "${current}" | remove_existing_snippet)"

  log "Removing quiz timer red bar snippet"
  moodle_cfg_set "${cleaned}"
  purge_moodle_caches

  printf 'Previous additionalhtmlhead backed up to:\n  %s\n' "${backup_file}"
  printf 'Quiz timer red bar removed.\n'
}

show_status() {
  local current

  current="$(current_additional_html)"
  if snippet_installed "${current}"; then
    printf 'Quiz timer red bar is installed.\n'
  else
    printf 'Quiz timer red bar is not installed.\n'
  fi
}

case "${ACTION}" in
  install)
    install_snippet
    ;;
  uninstall)
    uninstall_snippet
    ;;
  status)
    show_status
    ;;
esac
