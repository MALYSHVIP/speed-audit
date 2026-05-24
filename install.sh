#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="Speed Audit"
APP_VERSION="1.2.0"
INSTALL_DIR="/opt/speed-audit"
AUDIT_TARGET="${INSTALL_DIR}/speed-audit"
BIN_TARGET="/usr/local/bin/speed-audit"
RAW_BASE_URL_DEFAULT="https://raw.githubusercontent.com/MALYSHVIP/speed-audit/main"

FORCE_INSTALL=0
CHECK_ONLY=0
RAW_BASE_URL="${SPEED_AUDIT_RAW_BASE_URL:-${RAW_BASE_URL_DEFAULT}}"

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

log() {
  printf '[%s] %s\n' "${APP_NAME}" "$1"
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Запустите установщик от root: sudo bash install.sh" >&2
    exit 1
  fi
}

parse_args() {
  while (($# > 0)); do
    case "$1" in
      --force-install)
        FORCE_INSTALL=1
        ;;
      --check-only)
        CHECK_ONLY=1
        ;;
      --help|-h)
        cat <<'EOF_HELP'
Использование:
  curl -fsSL https://raw.githubusercontent.com/MALYSHVIP/speed-audit/main/install.sh | sudo bash

Опции:
  --check-only     Не устанавливать пакеты, а только запустить проверку.
  --force-install  Перекачать локальный скрипт проверки и заново сверить установку.
  --help           Показать эту справку.

Переменные окружения:
  SPEED_AUDIT_RAW_BASE_URL        Базовый raw URL для install.sh и bin/.
  SPEED_AUDIT_LOCAL_SCRIPT_SOURCE Локальный путь до bin/speed-audit для отладки.
EOF_HELP
        exit 0
        ;;
      *)
        echo "Неизвестный аргумент: $1" >&2
        exit 1
        ;;
    esac
    shift
  done
}

resolve_local_script_source() {
  local local_override="${SPEED_AUDIT_LOCAL_SCRIPT_SOURCE:-}"
  local script_dir candidate

  if [[ -n "${local_override}" && -f "${local_override}" ]]; then
    printf '%s\n' "${local_override}"
    return 0
  fi

  if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    candidate="${script_dir}/bin/speed-audit"
    if [[ -f "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  fi

  return 1
}

download_audit_script() {
  local target="$1"
  local local_source raw_url

  mkdir -p "$(dirname "${target}")"

  if local_source="$(resolve_local_script_source)"; then
    log "Беру локальный скрипт проверки из ${local_source}."
    cp "${local_source}" "${target}"
  else
    raw_url="${RAW_BASE_URL}/bin/speed-audit"
    log "Загружаю актуальный скрипт проверки из ${raw_url}."
    curl -fsSL "${raw_url}" -o "${target}"
  fi

  chmod +x "${target}"
}

fix_packagekit_if_needed() {
  log "Пробую убрать проблему с PackageKit, если она мешает apt."

  if command_exists systemctl; then
    systemctl unmask packagekit.service 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
    systemctl start packagekit.service 2>/dev/null || true
  fi

  if dpkg -s packagekit >/dev/null 2>&1; then
    apt-get -y purge packagekit packagekit-tools >/dev/null 2>&1 || true
  fi
}

safe_apt_update() {
  if apt-get update -y; then
    return 0
  fi

  fix_packagekit_if_needed
  apt-get update -y
}

install_packages_if_needed() {
  local packages=("$@")

  if ((${#packages[@]} == 0)); then
    return 0
  fi

  safe_apt_update
  log "Устанавливаю системные зависимости: ${packages[*]}"
  apt-get install -y "${packages[@]}"
}

ensure_runtime_packages() {
  local include_speedtest_prereqs="$1"
  local packages=()

  export DEBIAN_FRONTEND=noninteractive

  if ! command_exists curl; then
    packages+=("curl")
  fi
  if ! command_exists jq; then
    packages+=("jq")
  fi
  if [[ "${include_speedtest_prereqs}" -eq 1 ]]; then
    if ! command_exists gpg; then
      packages+=("gnupg")
    fi
    if ! dpkg -s ca-certificates >/dev/null 2>&1; then
      packages+=("ca-certificates")
    fi
  fi

  install_packages_if_needed "${packages[@]}"
}

cleanup_old_ookla_entries() {
  local repo_match="packagecloud.io/ookla/speedtest-cli"

  mkdir -p /etc/apt/keyrings /etc/apt/sources.list.d

  find /etc/apt/sources.list.d -maxdepth 1 -type f \( -name '*ookla*' -o -name '*speedtest*' \) -print0 2>/dev/null \
    | while IFS= read -r -d '' file; do
        if grep -Fq "${repo_match}" "${file}"; then
          rm -f "${file}"
        fi
      done

  if [[ -f /etc/apt/sources.list ]] && grep -Fq "${repo_match}" /etc/apt/sources.list; then
    cp /etc/apt/sources.list "/etc/apt/sources.list.bak.speedtest.$(date +%s)"
    grep -Fv "${repo_match}" /etc/apt/sources.list > /etc/apt/sources.list.tmp
    mv /etc/apt/sources.list.tmp /etc/apt/sources.list
  fi
}

configure_ookla_repo() {
  local repo_url="https://packagecloud.io/ookla/speedtest-cli/ubuntu/"
  local keyring="/etc/apt/keyrings/ookla_speedtest-cli-archive-keyring.gpg"
  local repo_list="/etc/apt/sources.list.d/ookla-speedtest.list"
  local repo_codename=""

  . /etc/os-release
  : "${VERSION_CODENAME:=jammy}"

  cleanup_old_ookla_entries
  rm -f "${keyring}" /etc/apt/keyrings/ookla_speedtest_cli.gpg

  curl -fsSL https://packagecloud.io/ookla/speedtest-cli/gpgkey \
    | gpg --dearmor --batch --yes -o "${keyring}"

  for candidate in "${VERSION_CODENAME}" jammy; do
    if curl -fsSI "${repo_url}dists/${candidate}/Release" >/dev/null; then
      repo_codename="${candidate}"
      break
    fi
  done

  if [[ -z "${repo_codename}" ]]; then
    echo "Не удалось определить поддерживаемый репозиторий Ookla для ${VERSION_CODENAME}." >&2
    exit 1
  fi

  if [[ "${repo_codename}" != "${VERSION_CODENAME}" ]]; then
    log "Для Ookla нет ветки ${VERSION_CODENAME}; будет использована ${repo_codename}."
  fi

  printf 'deb [signed-by=%s] %s %s main\n' "${keyring}" "${repo_url}" "${repo_codename}" > "${repo_list}"
}

install_speedtest_if_needed() {
  local need_speedtest="$1"

  if [[ "${need_speedtest}" -eq 0 ]]; then
    log "Speedtest уже найден. Повторно не устанавливаю."
    return 0
  fi

  log "Готовлю установку Ookla Speedtest."
  ensure_runtime_packages 1
  configure_ookla_repo
  safe_apt_update
  ACCEPT_EULA=Y apt-get install -y speedtest
}

install_local_wrapper() {
  mkdir -p "${INSTALL_DIR}"
  download_audit_script "${AUDIT_TARGET}"
  ln -sfn "${AUDIT_TARGET}" "${BIN_TARGET}"
}

run_check() {
  if [[ ! -x "${BIN_TARGET}" ]]; then
    echo "Скрипт проверки не найден: ${BIN_TARGET}" >&2
    exit 1
  fi

  exec "${BIN_TARGET}"
}

main() {
  local need_speedtest=0

  parse_args "$@"

  if [[ "${CHECK_ONLY}" -eq 1 ]]; then
    log "Запущен режим только проверки."
    run_check
  fi

  if command_exists speedtest; then
    need_speedtest=0
  else
    need_speedtest=1
  fi

  if [[ "${FORCE_INSTALL}" -eq 0 ]] && command_exists speedtest && command_exists jq && command_exists curl && [[ -x "${BIN_TARGET}" ]]; then
    log "Все нужные компоненты уже установлены. Сразу перехожу к проверке."
    run_check
  fi

  require_root

  log "Обновляю локальный скрипт проверки."
  install_local_wrapper

  if [[ "${need_speedtest}" -eq 1 ]]; then
    log "Speedtest еще не установлен. Сейчас поставлю только нужные пакеты."
    install_speedtest_if_needed 1
  else
    log "Speedtest уже есть. Установщик не будет повторно ставить пакеты."
    ensure_runtime_packages 0
  fi

  log "Запускаю итоговую проверку сервера."
  run_check
}

main "$@"
