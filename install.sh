#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="TokerVPN Speed Audit"
APP_VERSION="1.0.0"
INSTALL_DIR="/opt/tokervpn-speed-audit"
AUDIT_TARGET="${INSTALL_DIR}/tokervpn-speed-audit"
BIN_TARGET="/usr/local/bin/tokervpn-speed-audit"

FORCE_INSTALL=0
CHECK_ONLY=0

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
  sudo bash install.sh

Опции:
  --check-only     Не устанавливать пакеты, а только запустить проверку.
  --force-install  Пересоздать локальный скрипт и заново проверить установку Speedtest.
  --help           Показать эту справку.
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

emit_audit_script() {
  local target="$1"

  cat >"${target}" <<'EOF_AUDIT'
#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="TokerVPN Speed Audit"
APP_VERSION="1.0.0"

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

float_ge() {
  awk -v a="$1" -v b="$2" 'BEGIN { exit !(a >= b) }'
}

float_gt() {
  awk -v a="$1" -v b="$2" 'BEGIN { exit !(a > b) }'
}

float_le() {
  awk -v a="$1" -v b="$2" 'BEGIN { exit !(a <= b) }'
}

format_mb() {
  awk -v mb="$1" 'BEGIN {
    if (mb >= 1024) {
      printf "%.1f ГБ", mb / 1024
    } else {
      printf "%d МБ", mb
    }
  }'
}

format_percent() {
  awk -v value="$1" 'BEGIN { printf "%.1f%%", value }'
}

trim() {
  awk '{$1=$1; print}'
}

dir_size_mb() {
  local path="$1"
  du -sm "$path" 2>/dev/null | awk '{print $1 + 0}'
}

print_line() {
  printf '%s\n' "============================================================"
}

print_block_title() {
  printf '\n%s\n' "$1"
}

cpu_usage_percent() {
  local user nice system idle iowait irq softirq steal guest guest_nice
  local prev_idle prev_total idle_now total_now idle_delta total_delta

  read -r _ user nice system idle iowait irq softirq steal guest guest_nice < /proc/stat
  prev_idle=$((idle + iowait))
  prev_total=$((user + nice + system + idle + iowait + irq + softirq + steal))
  sleep 1
  read -r _ user nice system idle iowait irq softirq steal guest guest_nice < /proc/stat
  idle_now=$((idle + iowait))
  total_now=$((user + nice + system + idle + iowait + irq + softirq + steal))

  idle_delta=$((idle_now - prev_idle))
  total_delta=$((total_now - prev_total))

  awk -v idle_delta="$idle_delta" -v total_delta="$total_delta" 'BEGIN {
    if (total_delta <= 0) {
      printf "0.0"
    } else {
      printf "%.1f", (100 * (total_delta - idle_delta) / total_delta)
    }
  }'
}

collect_speedtest_json() {
  local output_file="$1"

  if ! command_exists speedtest; then
    return 1
  fi

  speedtest --accept-license --accept-gdpr --format=json >"${output_file}"
}

main() {
  local hostname_now timestamp os_name kernel_name uptime_human cpu_model cpu_cores load_avg
  local cpu_usage cpu_status cpu_advice
  local mem_total_mb mem_used_mb mem_available_mb mem_used_pct mem_status mem_advice
  local disk_total_mb disk_used_mb disk_free_mb disk_used_pct disk_status disk_advice
  local apt_cache_mb tmp_mb vartmp_mb varlog_mb junk_total_mb junk_status junk_advice
  local overall_points=0
  local recommendations=()
  local speedtest_json=""
  local speedtest_ok=0
  local speed_ping="" speed_jitter="" speed_packet_loss="" speed_download="" speed_upload="" speed_server="" speed_isp=""
  local net_status="Сетевой тест не запускался."
  local net_advice="Для оценки канала установите Ookla Speedtest."

  hostname_now="$(hostname 2>/dev/null || echo "неизвестно")"
  timestamp="$(date '+%Y-%m-%d %H:%M:%S %Z')"
  os_name="$(. /etc/os-release 2>/dev/null && printf '%s %s' "${NAME:-Linux}" "${VERSION_ID:-}")"
  kernel_name="$(uname -r 2>/dev/null || echo "неизвестно")"
  uptime_human="$(uptime -p 2>/dev/null | sed 's/^up //')"
  cpu_model="$(awk -F': ' '/model name/ {print $2; exit}' /proc/cpuinfo 2>/dev/null | trim)"
  cpu_model="${cpu_model:-неизвестно}"
  cpu_cores="$(nproc 2>/dev/null || echo "неизвестно")"
  load_avg="$(awk '{printf "%s / %s / %s", $1, $2, $3}' /proc/loadavg 2>/dev/null)"
  cpu_usage="$(cpu_usage_percent)"

  mem_total_mb="$(free -m | awk '/^Mem:/ {print $2}')"
  mem_used_mb="$(free -m | awk '/^Mem:/ {print $3}')"
  mem_available_mb="$(free -m | awk '/^Mem:/ {print $7}')"
  mem_used_pct="$(awk -v used="${mem_used_mb}" -v total="${mem_total_mb}" 'BEGIN {
    if (total <= 0) {
      printf "0.0"
    } else {
      printf "%.1f", (used * 100 / total)
    }
  }')"

  read -r disk_total_mb disk_used_mb disk_free_mb disk_used_pct < <(
    df -Pm / | awk 'NR == 2 {
      gsub(/%/, "", $5)
      print $2, $3, $4, $5
    }'
  )

  apt_cache_mb="$(dir_size_mb /var/cache/apt)"
  tmp_mb="$(dir_size_mb /tmp)"
  vartmp_mb="$(dir_size_mb /var/tmp)"
  varlog_mb="$(dir_size_mb /var/log)"
  junk_total_mb=$((apt_cache_mb + tmp_mb + vartmp_mb + varlog_mb))

  if float_ge "${cpu_usage}" "85"; then
    cpu_status="Процессор загружен сильно. Уже есть риск тормозов под дополнительной нагрузкой."
    cpu_advice="Рекомендация: проверить самые тяжелые процессы и подумать о расширении по vCPU."
    overall_points=$((overall_points + 2))
    recommendations+=("Проверить процессы, нагружающие CPU, и рассмотреть увеличение числа vCPU.")
  elif float_ge "${cpu_usage}" "65"; then
    cpu_status="Нагрузка на процессор заметная, но пока рабочая."
    cpu_advice="Рекомендация: понаблюдать за пиковыми часами работы."
    overall_points=$((overall_points + 1))
    recommendations+=("Следить за пиковыми периодами нагрузки на CPU.")
  else
    cpu_status="Все в порядке, процессор не перегружен."
    cpu_advice="Рекомендация: текущего запаса процессора достаточно."
  fi

  if float_ge "${mem_used_pct}" "85"; then
    mem_status="Оперативная память занята сильно. Сервер близок к нехватке RAM."
    mem_advice="Рекомендация: увеличить объем памяти или разгрузить сервисы."
    overall_points=$((overall_points + 2))
    recommendations+=("Увеличить объем RAM или отключить лишние процессы.")
  elif float_ge "${mem_used_pct}" "70"; then
    mem_status="Память занята заметно, но запас еще есть."
    mem_advice="Рекомендация: следить, чтобы потребление RAM не росло дальше."
    overall_points=$((overall_points + 1))
    recommendations+=("Понаблюдать за ростом потребления оперативной памяти.")
  else
    mem_status="Память в норме, свободный запас есть."
    mem_advice="Рекомендация: по оперативной памяти расширение пока не требуется."
  fi

  if float_ge "${disk_used_pct}" "90"; then
    disk_status="Диск заполнен очень сильно. Это уже опасная зона."
    disk_advice="Рекомендация: срочно освобождать место или расширять диск."
    overall_points=$((overall_points + 2))
    recommendations+=("Освободить место на диске или увеличить объем хранилища.")
  elif float_ge "${disk_used_pct}" "75"; then
    disk_status="Диск заполнен заметно. Пока работать можно, но запас уменьшается."
    disk_advice="Рекомендация: почистить старые файлы и подготовить план расширения."
    overall_points=$((overall_points + 1))
    recommendations+=("Почистить диск и держать под контролем рост данных.")
  else
    disk_status="По диску все в порядке, свободное место есть."
    disk_advice="Рекомендация: срочное расширение диска не требуется."
  fi

  if (( junk_total_mb >= 3072 )); then
    junk_status="Служебного мусора уже много: кеши, временные файлы и журналы занимают заметный объем."
    junk_advice="Рекомендация: выполнить чистку /tmp, /var/tmp, /var/log и кеша apt."
    overall_points=$((overall_points + 2))
    recommendations+=("Почистить временные файлы, журналы и кеш apt.")
  elif (( junk_total_mb >= 1024 )); then
    junk_status="Служебный мусор уже накопился, но ситуация пока не критичная."
    junk_advice="Рекомендация: планово почистить кеши и старые временные файлы."
    overall_points=$((overall_points + 1))
    recommendations+=("Сделать плановую чистку кешей и временных файлов.")
  else
    junk_status="Мусора немного, срочная чистка не нужна."
    junk_advice="Рекомендация: можно оставить как есть и чистить по расписанию."
  fi

  if command_exists speedtest && command_exists jq; then
    speedtest_json="$(mktemp)"
    trap 'rm -f "${speedtest_json:-}"' EXIT

    if collect_speedtest_json "${speedtest_json}"; then
      speedtest_ok=1
      speed_ping="$(jq -r '.ping.latency // 0' "${speedtest_json}")"
      speed_jitter="$(jq -r '.ping.jitter // 0' "${speedtest_json}")"
      speed_packet_loss="$(jq -r '.packetLoss // 0' "${speedtest_json}")"
      speed_download="$(jq -r 'if .download.bandwidth then (.download.bandwidth * 8 / 1000000) else 0 end' "${speedtest_json}")"
      speed_upload="$(jq -r 'if .upload.bandwidth then (.upload.bandwidth * 8 / 1000000) else 0 end' "${speedtest_json}")"
      speed_server="$(jq -r '.server.name // "неизвестно"' "${speedtest_json}")"
      speed_isp="$(jq -r '.isp // "неизвестно"' "${speedtest_json}")"

      if float_ge "${speed_packet_loss}" "1.0"; then
        net_status="Канал работает нестабильно: есть заметные потери пакетов."
        net_advice="Рекомендация: проверить провайдера, маршрут и сетевую нагрузку."
        overall_points=$((overall_points + 2))
        recommendations+=("Проверить потери пакетов и стабильность сетевого канала.")
      elif float_ge "${speed_ping}" "100"; then
        net_status="Пинг высокий. Для чувствительных сервисов это уже нехорошо."
        net_advice="Рекомендация: проверить маршрут, регион сервера или сетевую перегрузку."
        overall_points=$((overall_points + 2))
        recommendations+=("Снизить сетевую задержку или перенести нагрузку ближе к пользователям.")
      elif float_ge "${speed_ping}" "60"; then
        net_status="Пинг повышенный, но для части задач еще допустимый."
        net_advice="Рекомендация: наблюдать за задержкой и jitter."
        overall_points=$((overall_points + 1))
        recommendations+=("Понаблюдать за пингом и стабильностью канала.")
      elif float_le "${speed_download}" "30" || float_le "${speed_upload}" "10"; then
        net_status="Скорость канала низкая. Для нагруженного сервера это может быть узким местом."
        net_advice="Рекомендация: проверить тариф, порт и ограничения со стороны сети."
        overall_points=$((overall_points + 1))
        recommendations+=("Проверить тариф или ограничения по каналу связи.")
      else
        net_status="По скорости и задержке сеть выглядит нормально."
        net_advice="Рекомендация: канал можно использовать в текущем виде."
      fi
    else
      net_status="Speedtest не смог завершить сетевую проверку."
      net_advice="Рекомендация: повторить тест позже или проверить исходящий доступ в интернет."
      overall_points=$((overall_points + 1))
      recommendations+=("Повторить сетевой тест и проверить доступ в интернет.")
    fi
  elif command_exists speedtest; then
    net_status="Speedtest найден, но не установлен jq для разбора результата."
    net_advice="Рекомендация: установить jq через установщик."
    overall_points=$((overall_points + 1))
    recommendations+=("Установить jq для полного сетевого отчета.")
  else
    recommendations+=("Установить Ookla Speedtest для проверки ping, download и upload.")
  fi

  print_line
  printf '%s %s\n' "${APP_NAME}" "v${APP_VERSION}"
  print_line
  printf 'Дата проверки: %s\n' "${timestamp}"
  printf 'Сервер: %s\n' "${hostname_now}"
  printf 'Система: %s\n' "${os_name:-Linux}"
  printf 'Ядро: %s\n' "${kernel_name}"
  printf 'Время работы: %s\n' "${uptime_human:-неизвестно}"

  print_block_title "Системные ресурсы"
  printf 'Процессор: %s\n' "${cpu_model}"
  printf 'Количество ядер: %s\n' "${cpu_cores}"
  printf 'Текущая загрузка процессора: %s\n' "$(format_percent "${cpu_usage}")"
  printf 'Load average: %s\n' "${load_avg:-неизвестно}"
  printf 'Оценка: %s\n' "${cpu_status}"
  printf '%s\n' "${cpu_advice}"
  printf '\n'
  printf 'Оперативная память занято: %s из %s (%s)\n' \
    "$(format_mb "${mem_used_mb}")" \
    "$(format_mb "${mem_total_mb}")" \
    "$(format_percent "${mem_used_pct}")"
  printf 'Оперативная память доступно: %s\n' "$(format_mb "${mem_available_mb}")"
  printf 'Оценка: %s\n' "${mem_status}"
  printf '%s\n' "${mem_advice}"
  printf '\n'
  printf 'Диск занято: %s из %s (%s)\n' \
    "$(format_mb "${disk_used_mb}")" \
    "$(format_mb "${disk_total_mb}")" \
    "$(format_percent "${disk_used_pct}")"
  printf 'Диск свободно: %s\n' "$(format_mb "${disk_free_mb}")"
  printf 'Оценка: %s\n' "${disk_status}"
  printf '%s\n' "${disk_advice}"
  printf '\n'
  printf 'Служебный мусор всего: %s\n' "$(format_mb "${junk_total_mb}")"
  printf 'Кеш apt: %s, /tmp: %s, /var/tmp: %s, /var/log: %s\n' \
    "$(format_mb "${apt_cache_mb}")" \
    "$(format_mb "${tmp_mb}")" \
    "$(format_mb "${vartmp_mb}")" \
    "$(format_mb "${varlog_mb}")"
  printf 'Оценка: %s\n' "${junk_status}"
  printf '%s\n' "${junk_advice}"

  print_block_title "Сеть и задержка"
  if (( speedtest_ok == 1 )); then
    printf 'Провайдер: %s\n' "${speed_isp}"
    printf 'Тестовый сервер: %s\n' "${speed_server}"
    printf 'Пинг: %.1f мс\n' "${speed_ping}"
    printf 'Jitter: %.1f мс\n' "${speed_jitter}"
    printf 'Потери пакетов: %.1f%%\n' "${speed_packet_loss}"
    printf 'Скорость загрузки: %.1f Мбит/с\n' "${speed_download}"
    printf 'Скорость отдачи: %.1f Мбит/с\n' "${speed_upload}"
  else
    printf 'Данные Speedtest: недоступны\n'
  fi
  printf 'Оценка: %s\n' "${net_status}"
  printf '%s\n' "${net_advice}"

  print_block_title "Итоговая оценка"
  if (( overall_points <= 2 )); then
    printf 'Все в порядке, сервер можно использовать.\n'
  elif (( overall_points <= 5 )); then
    printf 'Сервер в рабочем состоянии, но за ресурсами уже стоит наблюдать.\n'
  else
    printf 'Серверу желательно уделить внимание: есть признаки перегрузки или нехватки ресурсов.\n'
  fi

  if ((${#recommendations[@]} > 0)); then
    printf '\nРекомендации:\n'
    printf ' - %s\n' "${recommendations[@]}"
  fi

  print_line
}

main "$@"
EOF_AUDIT

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

ensure_runtime_packages() {
  local install_speedtest="$1"
  local packages=()

  export DEBIAN_FRONTEND=noninteractive

  if ! command_exists curl; then
    packages+=("curl")
  fi
  if ! command_exists jq; then
    packages+=("jq")
  fi
  if [[ "${install_speedtest}" -eq 1 ]]; then
    if ! command_exists gpg; then
      packages+=("gnupg")
    fi
    packages+=("ca-certificates")
  fi

  if ((${#packages[@]} > 0)); then
    log "Устанавливаю системные зависимости: ${packages[*]}"
    apt-get install -y "${packages[@]}"
  fi
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
  safe_apt_update
  ensure_runtime_packages 1
  configure_ookla_repo
  safe_apt_update
  ACCEPT_EULA=Y apt-get install -y speedtest
}

install_local_wrapper() {
  mkdir -p "${INSTALL_DIR}"
  emit_audit_script "${AUDIT_TARGET}"
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
  else
    log "Speedtest уже есть. Установщик не будет повторно ставить пакеты."
  fi

  if [[ "${need_speedtest}" -eq 1 ]]; then
    install_speedtest_if_needed 1
  else
    ensure_runtime_packages 0
  fi

  log "Запускаю итоговую проверку сервера."
  run_check
}

main "$@"
