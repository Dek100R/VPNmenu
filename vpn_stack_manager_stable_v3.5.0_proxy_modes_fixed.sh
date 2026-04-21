#!/usr/bin/env bash
set -u -o pipefail

APP_NAME="Менеджер VPN-инструментов"
APP_VERSION="3.5.0-stable"

BASE_DIR="/opt/vpn-tools"
BIN_DIR="$BASE_DIR/bin"
LOG_DIR="/var/log/vpn-tools"
STATE_DIR="/var/lib/vpn-tools"
LOCK_DIR="/run/vpn-tools"
BACKUP_DIR="/root/vpn-manager-backups"
ENV_FILE="/etc/vpn-tools.env"
XUI_WARP_FALLBACK_STATE_FILE="$STATE_DIR/xui_warp_fallback.active"
XUI_WARP_FALLBACK_BACKUP_FILE="$STATE_DIR/xui_warp_fallback_config.json"

WARP_WATCHDOG_COMP="warp-watchdog"
XRAY_WATCHDOG_COMP="xray-watchdog"
DAILY_COMP="vpn-daily-report"
STATUS_COMP="vpn-status"
OPTIMIZE_COMP="warp-optimize"
TG_CONTROL_COMP="telegram-control-bot"
LOGROTATE_COMP="logrotate"
MTPROTO_COMP="mtproto-proxy"
MTPROTO_WATCHDOG_COMP="mtproto-watchdog"
MTPROTO_DAILY_COMP="mtproto-daily-check"
MTPROTO_DIR="$BASE_DIR/mtproto"
MTPROTO_INFO_FILE="$STATE_DIR/mtproto_info.env"
MTPROTO_STATS_FILE="$STATE_DIR/mtproto_stats.env"
MTPROTO_HISTORY_FILE="$STATE_DIR/mtproto_history.log"
SOCKS5_COMP="socks5-proxy"
SOCKS5_CFG_FILE="$STATE_DIR/3proxy.cfg"
SOCKS5_BIN="/usr/local/3proxy/bin/3proxy"
SOCKS5_SRC_DIR="/usr/local/src/3proxy"

C_RESET="\033[0m"
C_BOLD="\033[1m"
C_DIM="\033[2m"
C_RED="\033[31m"
C_GREEN="\033[32m"
C_YELLOW="\033[33m"
C_BLUE="\033[34m"
C_MAGENTA="\033[35m"
C_CYAN="\033[36m"
C_GRAY="\033[90m"

require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo -e "${C_RED}Запусти скрипт от root.${C_RESET}" >&2
    exit 1
  fi
}

pause() { read -r -p "Нажми Enter для продолжения..." _; }

ensure_dirs() {
  mkdir -p "$BIN_DIR" "$LOG_DIR" "$STATE_DIR" "$LOCK_DIR" "$BACKUP_DIR" "$MTPROTO_DIR"
}

write_env_if_missing() {
  if [[ ! -f "$ENV_FILE" ]]; then
    cat > "$ENV_FILE" <<'EOF_ENV'
BOT_TOKEN=""
CHAT_ID=""
SOCKS_ADDR="127.0.0.1:40000"
TRACE_URL="https://1.1.1.1/cdn-cgi/trace"
DAILY_REPORT_HOUR="6"
DAILY_REPORT_MINUTE="0"
WARP_SERVICE_NAME="warp-svc"
XRAY_SERVICE_NAME="x-ui"
AUTO_OPTIMIZE_AFTER_RECOVERY="true"
MTPROTO_PORT="8443"
MTPROTO_STATS_PORT="8888"
MTPROTO_WORKERS="1"
MTPROTO_AUTO_OPEN_UFW="true"
MTPROTO_RESERVE_PORT="9443"
SOCKS5_PORT="1080"
SOCKS5_LOGIN="proxyuser"
SOCKS5_PASSWORD="change_me"
SOCKS5_BIND_ADDR="0.0.0.0"
SOCKS5_AUTO_OPEN_UFW="true"
SOCKS5_TYPE="socks5"
SOCKS5_AUTH_MODE="auth"
EOF_ENV
    chmod 600 "$ENV_FILE"
  fi
}

load_env() {
  write_env_if_missing
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  BOT_TOKEN="${BOT_TOKEN:-}"
  CHAT_ID="${CHAT_ID:-}"
  SOCKS_ADDR="${SOCKS_ADDR:-127.0.0.1:40000}"
  TRACE_URL="${TRACE_URL:-https://1.1.1.1/cdn-cgi/trace}"
  DAILY_REPORT_HOUR="${DAILY_REPORT_HOUR:-6}"
  DAILY_REPORT_MINUTE="${DAILY_REPORT_MINUTE:-0}"
  WARP_SERVICE_NAME="${WARP_SERVICE_NAME:-warp-svc}"
  XRAY_SERVICE_NAME="${XRAY_SERVICE_NAME:-x-ui}"
  AUTO_OPTIMIZE_AFTER_RECOVERY="${AUTO_OPTIMIZE_AFTER_RECOVERY:-true}"
  MTPROTO_PORT="${MTPROTO_PORT:-8443}"
  MTPROTO_STATS_PORT="${MTPROTO_STATS_PORT:-8888}"
  MTPROTO_WORKERS="${MTPROTO_WORKERS:-1}"
  MTPROTO_AUTO_OPEN_UFW="${MTPROTO_AUTO_OPEN_UFW:-true}"
  MTPROTO_RESERVE_PORT="${MTPROTO_RESERVE_PORT:-9443}"
  SOCKS5_PORT="${SOCKS5_PORT:-1080}"
  SOCKS5_LOGIN="${SOCKS5_LOGIN:-proxyuser}"
  SOCKS5_PASSWORD="${SOCKS5_PASSWORD:-change_me}"
  SOCKS5_BIND_ADDR="${SOCKS5_BIND_ADDR:-0.0.0.0}"
  SOCKS5_AUTO_OPEN_UFW="${SOCKS5_AUTO_OPEN_UFW:-true}"
  SOCKS5_TYPE="${SOCKS5_TYPE:-socks5}"
  SOCKS5_AUTH_MODE="${SOCKS5_AUTH_MODE:-auth}"
}

save_env() {
  cat > "$ENV_FILE" <<EOF_ENV
BOT_TOKEN="${BOT_TOKEN}"
CHAT_ID="${CHAT_ID}"
SOCKS_ADDR="${SOCKS_ADDR}"
TRACE_URL="${TRACE_URL}"
DAILY_REPORT_HOUR="${DAILY_REPORT_HOUR}"
DAILY_REPORT_MINUTE="${DAILY_REPORT_MINUTE}"
WARP_SERVICE_NAME="${WARP_SERVICE_NAME}"
XRAY_SERVICE_NAME="${XRAY_SERVICE_NAME}"
AUTO_OPTIMIZE_AFTER_RECOVERY="${AUTO_OPTIMIZE_AFTER_RECOVERY}"
MTPROTO_PORT="${MTPROTO_PORT}"
MTPROTO_STATS_PORT="${MTPROTO_STATS_PORT}"
MTPROTO_WORKERS="${MTPROTO_WORKERS}"
MTPROTO_AUTO_OPEN_UFW="${MTPROTO_AUTO_OPEN_UFW}"
MTPROTO_RESERVE_PORT="${MTPROTO_RESERVE_PORT}"
SOCKS5_PORT="${SOCKS5_PORT}"
SOCKS5_LOGIN="${SOCKS5_LOGIN}"
SOCKS5_PASSWORD="${SOCKS5_PASSWORD}"
SOCKS5_BIND_ADDR="${SOCKS5_BIND_ADDR}"
SOCKS5_AUTO_OPEN_UFW="${SOCKS5_AUTO_OPEN_UFW}"
SOCKS5_TYPE="${SOCKS5_TYPE}"
SOCKS5_AUTH_MODE="${SOCKS5_AUTH_MODE}"
EOF_ENV
  chmod 600 "$ENV_FILE"
}

ensure_prereqs() {
  local pkgs=()
  command -v curl >/dev/null 2>&1 || pkgs+=(curl)
  command -v python3 >/dev/null 2>&1 || pkgs+=(python3)
  command -v ping >/dev/null 2>&1 || pkgs+=(iputils-ping)
  command -v awk >/dev/null 2>&1 || pkgs+=(gawk)
  command -v flock >/dev/null 2>&1 || pkgs+=(util-linux)
  command -v logrotate >/dev/null 2>&1 || pkgs+=(logrotate)
  command -v gpg >/dev/null 2>&1 || pkgs+=(gnupg)
  command -v tar >/dev/null 2>&1 || pkgs+=(tar)
  command -v grep >/dev/null 2>&1 || pkgs+=(grep)
  command -v jq >/dev/null 2>&1 || pkgs+=(jq)
  command -v ss >/dev/null 2>&1 || pkgs+=(iproute2)
  if ((${#pkgs[@]})); then
    echo -e "${C_CYAN}Устанавливаю зависимости: ${pkgs[*]}${C_RESET}"
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"
  fi
}

service_name_for() { echo "vpn-tools-$1.service"; }
timer_name_for() { echo "vpn-tools-$1.timer"; }
systemd_reload() { systemctl daemon-reload >/dev/null 2>&1 || true; }
run_cmd() { "$@" >/dev/null 2>&1 || true; }

status_label() {
  local v="${1:-}"
  case "$v" in
    active) echo "активен" ;;
    enabled) echo "включён" ;;
    installed|установлен) echo "установлен" ;;
    set|задан) echo "задан" ;;
    Connected) echo "подключён" ;;
    Disconnected) echo "отключён" ;;
    on) echo "включён" ;;
    off) echo "выключен" ;;
    OK) echo "ОК" ;;
    FAIL) echo "Ошибка" ;;
    inactive) echo "неактивен" ;;
    disabled) echo "выключен" ;;
    "не установлен"|not-found) echo "не установлен" ;;
    "не задан") echo "не задан" ;;
    "") echo "н/д" ;;
    *) echo "$v" ;;
  esac
}

fmt_status() {
  local v="${1:-}"
  local lbl
  lbl="$(status_label "$v")"
  case "$v" in
    active|enabled|installed|установлен|set|задан|Connected|on|OK)
      echo -e "${C_GREEN}${lbl}${C_RESET}"
      ;;
    inactive|disabled|Disconnected|off|FAIL|not-found|"не установлен"|"не задан")
      echo -e "${C_RED}${lbl}${C_RESET}"
      ;;
    *)
      echo -e "${C_YELLOW}${lbl}${C_RESET}"
      ;;
  esac
}

menu_line() {
  local num="$1" icon="$2" color="$3" text="$4"
  echo -e "${C_CYAN}${C_BOLD}${num}.${C_RESET} ${color}${icon}${C_RESET} ${text}"
}

safe_is_active() {
  local unit="${1:-}"
  local out
  out="$(systemctl is-active "$unit" 2>/dev/null | head -n1 || true)"
  [[ -z "$out" ]] && out="inactive"
  echo "$out"
}

safe_is_enabled() {
  local unit="${1:-}"
  local out
  out="$(systemctl is-enabled "$unit" 2>/dev/null | head -n1 || true)"
  [[ -z "$out" ]] && out="not-found"
  echo "$out"
}

have_warp() { command -v warp-cli >/dev/null 2>&1; }

warp_cli_summary() {
  if have_warp; then
    local out
    out="$((warp-cli status 2>/dev/null || true) | head -n1 | sed 's/^Status update: //;s/^Status: //;s/^Success$//')"
    [[ -z "$out" ]] && out="н/д"
    echo "$out"
  else
    echo "не установлен"
  fi
}

warp_egress_state() {
  if have_warp && curl -s --max-time 10 --socks5-hostname "$SOCKS_ADDR" "$TRACE_URL" 2>/dev/null | grep -q 'warp=on'; then
    echo "on"
  elif have_warp; then
    echo "off"
  else
    echo "not-found"
  fi
}

require_warp() {
  if ! have_warp; then
    echo -e "${C_YELLOW}WARP не установлен.${C_RESET}"
    return 1
  fi
  return 0
}

xui_config_path() {
  local cfg="/usr/local/x-ui/bin/config.json"
  [[ -f "$cfg" ]] && echo "$cfg"
}

check_warp_outbound_in_xui() {
  local cfg
  cfg="$(xui_config_path || true)"
  if [[ -z "$cfg" ]]; then
    echo "config.json 3x-ui не найден."
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "jq не установлен."
    return 1
  fi
  if jq -e '.outbounds[]? | select(.tag=="WARP")' "$cfg" >/dev/null 2>&1; then
    echo "Outbound WARP найден в 3x-ui."
    return 0
  fi
  echo "Outbound WARP не найден в 3x-ui."
  return 1
}


check_warp_references_in_xui() {
  local cfg
  cfg="$(xui_config_path || true)"
  if [[ -z "$cfg" ]]; then
    echo "config.json 3x-ui не найден."
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "jq не установлен."
    return 1
  fi

  local refs
  refs="$(jq -r '
    [
      (.routing.rules[]? | select(.outboundTag? == "WARP") | "routing.rules[].outboundTag=WARP"),
      (.balancers[]? | select(.selector? != null) | .selector[]? | select(. == "WARP") | "balancers[].selector содержит WARP"),
      (.observatory.subjectSelector[]? | select(. == "WARP") | "observatory.subjectSelector содержит WARP")
    ] | .[]' "$cfg" 2>/dev/null || true)"

  if [[ -n "$refs" ]]; then
    echo "Найдены ссылки на outbound WARP:"
    echo "$refs"
    return 0
  fi

  echo "Ссылок на outbound WARP в config.json не найдено."
  return 1
}

ensure_warp_outbound_in_xui() {
  local cfg tmp
  cfg="$(xui_config_path || true)"
  if [[ -z "$cfg" ]]; then
    echo -e "${C_YELLOW}config.json 3x-ui не найден, пропускаю создание outbound WARP.${C_RESET}"
    return 1
  fi
  command -v jq >/dev/null 2>&1 || { ensure_prereqs; }
  cp -f "$cfg" "${cfg}.bak"
  if jq -e '.outbounds[]? | select(.tag=="WARP")' "$cfg" >/dev/null 2>&1; then
    echo -e "${C_GREEN}Outbound WARP уже существует в 3x-ui.${C_RESET}"
    return 0
  fi
  tmp="$(mktemp)"
  if jq '
    .outbounds = ((.outbounds // []) + [
      {
        "tag": "WARP",
        "protocol": "socks",
        "settings": {
          "servers": [
            {
              "address": "127.0.0.1",
              "port": 40000
            }
          ]
        }
      }
    ])
  ' "$cfg" > "$tmp"; then
    mv "$tmp" "$cfg"
  else
    rm -f "$tmp"
    echo -e "${C_RED}Не удалось обновить config.json.${C_RESET}"
    return 1
  fi

  if ! jq empty "$cfg" >/dev/null 2>&1; then
    cp -f "${cfg}.bak" "$cfg"
    echo -e "${C_RED}После изменения JSON стал некорректным. Выполнен откат backup.${C_RESET}"
    return 1
  fi

  run_cmd systemctl restart "$XRAY_SERVICE_NAME"
  sleep 2
  echo -e "${C_GREEN}Outbound WARP добавлен в 3x-ui и ${XRAY_SERVICE_NAME} перезапущен.${C_RESET}"
  return 0
}

remove_warp_outbound_in_xui() {
  local cfg tmp
  cfg="$(xui_config_path || true)"
  if [[ -z "$cfg" ]]; then
    echo "config.json 3x-ui не найден."
    return 1
  fi
  command -v jq >/dev/null 2>&1 || { ensure_prereqs; }

  echo -e "${C_YELLOW}Проверяю, используется ли outbound WARP в routing rules 3x-ui...${C_RESET}"
  local refs_output=""
  refs_output="$(check_warp_references_in_xui 2>/dev/null || true)"
  if grep -q "routing.rules\[\]\.outboundTag=WARP\|selector содержит WARP\|subjectSelector содержит WARP" <<<"$refs_output"; then
    echo -e "${C_YELLOW}${refs_output}${C_RESET}"
    echo -e "${C_YELLOW}Если удалить outbound WARP сейчас, эти правила начнут выдавать ошибки в Xray.${C_RESET}"
    read -r -p "Удалить outbound WARP всё равно? [y/N]: " confirm
    [[ "${confirm,,}" != "y" ]] && { echo "Удаление отменено."; return 1; }
  fi

  cp -f "$cfg" "${cfg}.bak"
  tmp="$(mktemp)"
  if jq ' .outbounds = ((.outbounds // []) | map(select(.tag != "WARP"))) ' "$cfg" > "$tmp"; then
    mv "$tmp" "$cfg"
  else
    rm -f "$tmp"
    echo -e "${C_RED}Не удалось удалить outbound WARP из config.json.${C_RESET}"
    return 1
  fi
  if ! jq empty "$cfg" >/dev/null 2>&1; then
    cp -f "${cfg}.bak" "$cfg"
    echo -e "${C_RED}После изменения JSON стал некорректным. Выполнен откат backup.${C_RESET}"
    return 1
  fi
  run_cmd systemctl restart "$XRAY_SERVICE_NAME"
  sleep 2
  echo -e "${C_GREEN}Outbound WARP удалён из 3x-ui, ${XRAY_SERVICE_NAME} перезапущен.${C_RESET}"
}


xui_warp_fallback_status() {
  [[ -f "$XUI_WARP_FALLBACK_STATE_FILE" ]] && echo "active" || echo "inactive"
}

activate_xui_warp_fallback_to_direct() {
  local cfg tmp changed=0
  cfg="$(xui_config_path || true)"
  if [[ -z "$cfg" ]]; then
    echo "config.json 3x-ui не найден."
    return 1
  fi
  command -v jq >/dev/null 2>&1 || { ensure_prereqs; }
  mkdir -p "$STATE_DIR"
  if [[ -f "$XUI_WARP_FALLBACK_STATE_FILE" && -f "$XUI_WARP_FALLBACK_BACKUP_FILE" ]]; then
    echo "Fallback WARP→direct уже активирован."
    return 0
  fi
  cp -f "$cfg" "$XUI_WARP_FALLBACK_BACKUP_FILE"
  tmp="$(mktemp)"
  if jq '
    def mapwarp(x): if x == "WARP" then "direct" else x end;
    .routing.rules = ((.routing.rules // []) | map(if .outboundTag? == "WARP" then .outboundTag = "direct" else . end))
    | .balancers = ((.balancers // []) | map(if .selector? then .selector = (.selector | map(mapwarp(.))) else . end))
    | .observatory.subjectSelector = ((.observatory.subjectSelector // []) | map(mapwarp(.)))
  ' "$cfg" > "$tmp"; then
    mv "$tmp" "$cfg"
  else
    rm -f "$tmp"
    rm -f "$XUI_WARP_FALLBACK_BACKUP_FILE"
    echo "Не удалось активировать fallback WARP→direct."
    return 1
  fi
  if ! jq empty "$cfg" >/dev/null 2>&1; then
    cp -f "$XUI_WARP_FALLBACK_BACKUP_FILE" "$cfg"
    rm -f "$XUI_WARP_FALLBACK_BACKUP_FILE"
    echo "После активации fallback JSON стал некорректным. Выполнен откат."
    return 1
  fi
  touch "$XUI_WARP_FALLBACK_STATE_FILE"
  run_cmd systemctl restart "$XRAY_SERVICE_NAME"
  sleep 2
  echo "Fallback WARP→direct активирован, ${XRAY_SERVICE_NAME} перезапущен."
  return 0
}

restore_xui_warp_routes_from_fallback() {
  local cfg
  cfg="$(xui_config_path || true)"
  if [[ -z "$cfg" ]]; then
    echo "config.json 3x-ui не найден."
    return 1
  fi
  if [[ ! -f "$XUI_WARP_FALLBACK_STATE_FILE" || ! -f "$XUI_WARP_FALLBACK_BACKUP_FILE" ]]; then
    echo "Fallback WARP→direct не активирован."
    return 0
  fi
  cp -f "$XUI_WARP_FALLBACK_BACKUP_FILE" "$cfg"
  if ! jq empty "$cfg" >/dev/null 2>&1; then
    echo "Не удалось восстановить backup fallback: JSON некорректен."
    return 1
  fi
  rm -f "$XUI_WARP_FALLBACK_STATE_FILE" "$XUI_WARP_FALLBACK_BACKUP_FILE"
  run_cmd systemctl restart "$XRAY_SERVICE_NAME"
  sleep 2
  echo "Fallback WARP→direct отключён, маршруты WARP восстановлены."
  return 0
}

mtproto_env_source() {
  load_env
  if [[ -f "$MTPROTO_INFO_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$MTPROTO_INFO_FILE"
  fi
}

mtproto_secret_value() {
  local secret=""
  if [[ -f "$MTPROTO_INFO_FILE" ]]; then
    secret="$(awk -F= '''$1=="MTPROTO_SECRET"{gsub(/^"|"$/, "", $2); print $2}''' "$MTPROTO_INFO_FILE" 2>/dev/null || true)"
  fi
  secret="${secret#dd}"
  echo "$secret"
}

mtproto_client_secret() {
  local secret
  secret="$(mtproto_secret_value)"
  [[ -n "$secret" ]] && echo "dd${secret}" || true
}

ensure_mtproto_pid_compatibility() {
  local current="0"
  current="$(cat /proc/sys/kernel/pid_max 2>/dev/null || echo 0)"
  if [[ "$current" =~ ^[0-9]+$ ]] && (( current <= 65535 )); then
    return 0
  fi
  echo -e "${C_YELLOW}Для стабильной работы MTProto нужен kernel.pid_max не выше 65535.${C_RESET}"
  echo -e "${C_DIM}Сейчас будет автоматически записано значение 65535 в /etc/sysctl.d/99-pid-max.conf.${C_RESET}"
  echo 'kernel.pid_max = 65535' > /etc/sysctl.d/99-mtproto-pid-max.conf
  sysctl -q --system >/dev/null 2>&1 || true
  current="$(cat /proc/sys/kernel/pid_max 2>/dev/null || echo 0)"
  if [[ "$current" =~ ^[0-9]+$ ]] && (( current <= 65535 )); then
    echo -e "${C_GREEN}kernel.pid_max установлен в ${current}.${C_RESET}"
  else
    echo -e "${C_YELLOW}Не удалось применить kernel.pid_max сразу. После перезагрузки сервера значение станет 65535.${C_RESET}"
  fi
}

prompt_mtproto_settings() {
  load_env
  local input
  echo -e "${C_DIM}Настройка MTProto Proxy.${C_RESET}"
  echo -e "${C_DIM}Внешний порт — это основной порт, к которому будет подключаться Telegram. Часто выбирают 443, 8443, 5443 или 2443.${C_RESET}"
  read -r -p "Основной внешний порт MTProto [${MTPROTO_PORT}]: " input || true
  if [[ -n "$input" ]]; then
    if [[ "$input" =~ ^[0-9]+$ ]] && (( input >= 1 && input <= 65535 )); then
      MTPROTO_PORT="$input"
    else
      echo -e "${C_YELLOW}Некорректный порт. Оставляю текущее значение: ${MTPROTO_PORT}.${C_RESET}"
    fi
  fi

  echo -e "${C_DIM}Резервный порт нужен для автоматического переключения, если основной порт станет недоступен или будет конфликтовать с другим сервисом.${C_RESET}"
  read -r -p "Резервный внешний порт MTProto [${MTPROTO_RESERVE_PORT}]: " input || true
  if [[ -n "$input" ]]; then
    if [[ "$input" =~ ^[0-9]+$ ]] && (( input >= 1 && input <= 65535 )); then
      MTPROTO_RESERVE_PORT="$input"
    else
      echo -e "${C_YELLOW}Некорректный резервный порт. Оставляю текущее значение: ${MTPROTO_RESERVE_PORT}.${C_RESET}"
    fi
  fi

  echo -e "${C_DIM}Локальный stats-порт используется только на сервере для локальной статистики. Обычно можно оставить 8888.${C_RESET}"
  read -r -p "Локальный stats-порт [${MTPROTO_STATS_PORT}]: " input || true
  if [[ -n "$input" ]]; then
    if [[ "$input" =~ ^[0-9]+$ ]] && (( input >= 1 && input <= 65535 )); then
      MTPROTO_STATS_PORT="$input"
    else
      echo -e "${C_YELLOW}Некорректный stats-порт. Оставляю текущее значение: ${MTPROTO_STATS_PORT}.${C_RESET}"
    fi
  fi

  if [[ "$MTPROTO_RESERVE_PORT" == "$MTPROTO_PORT" ]]; then
    if (( MTPROTO_PORT == 8443 )); then
      MTPROTO_RESERVE_PORT="9443"
    else
      MTPROTO_RESERVE_PORT="$((MTPROTO_PORT + 1000))"
    fi
    echo -e "${C_YELLOW}Резервный порт не должен совпадать с основным. Автоматически выбрал ${MTPROTO_RESERVE_PORT}.${C_RESET}"
  fi
  if [[ "$MTPROTO_STATS_PORT" == "$MTPROTO_PORT" || "$MTPROTO_STATS_PORT" == "$MTPROTO_RESERVE_PORT" ]]; then
    MTPROTO_STATS_PORT="8888"
    echo -e "${C_YELLOW}Stats-порт не должен совпадать с внешними портами. Возвращаю 8888.${C_RESET}"
  fi

  MTPROTO_WORKERS="1"
  echo -e "${C_DIM}Workers для MTProto фиксирован в 1 для стабильной работы на этом сервере.${C_RESET}"
}


mtproto_local_open() {
  timeout 3 bash -c "</dev/tcp/127.0.0.1/${MTPROTO_PORT}" >/dev/null 2>&1
}

mtproto_port_in_use() {
  local port="${1:-$MTPROTO_PORT}"
  ss -lntp 2>/dev/null | awk -v p=":${port}" '$4 ~ p {print}'
}

mtproto_check_port_free() {
  local port="$1"
  local used
  used="$(mtproto_port_in_use "$port" || true)"
  [[ -z "$used" ]] && return 0
  grep -q 'mtproto-proxy' <<<"$used"
}

mtproto_switch_to_reserve_port() {
  load_env
  local old_port="${MTPROTO_PORT}" reserve="${MTPROTO_RESERVE_PORT}" link ip secret
  if [[ -z "$reserve" || "$reserve" == "$old_port" ]]; then
    echo -e "${C_RED}Резервный порт MTProto не задан или совпадает с основным.${C_RESET}"
    return 1
  fi
  if ! mtproto_check_port_free "$reserve"; then
    echo -e "${C_RED}Резервный порт ${reserve} тоже занят. Автопереключение невозможно.${C_RESET}"
    return 1
  fi
  MTPROTO_PORT="$reserve"
  MTPROTO_RESERVE_PORT="$old_port"
  save_env
  write_systemd_unit "$MTPROTO_COMP"
  systemd_reload
  ensure_mtproto_firewall
  run_cmd systemctl restart "$(service_name_for "$MTPROTO_COMP")"
  sleep 3
  if safe_is_active "$(service_name_for "$MTPROTO_COMP")" | grep -q '^active$' && mtproto_local_open; then
    echo -e "${C_GREEN}MTProto переключён на резервный порт ${MTPROTO_PORT}. Старый порт сохранён как резервный.${C_RESET}"
    secret="$(mtproto_client_secret)"
    ip="$(mtproto_public_ip)"
    link=""
    [[ -n "$secret" && -n "$ip" ]] && link="tg://proxy?server=${ip}&port=${MTPROTO_PORT}&secret=${secret}"
    if [[ -n "$link" ]]; then
      mtproto_send_tg "🔁 MTProto автоматически переключён на резервный порт ${MTPROTO_PORT}. Старый порт: ${old_port}

Новая ссылка:
${link}"
    else
      mtproto_send_tg "🔁 MTProto автоматически переключён на резервный порт ${MTPROTO_PORT}. Старый порт: ${old_port}"
    fi
    return 0
  fi
  MTPROTO_PORT="$old_port"
  MTPROTO_RESERVE_PORT="$reserve"
  save_env
  write_systemd_unit "$MTPROTO_COMP"
  systemd_reload
  run_cmd systemctl restart "$(service_name_for "$MTPROTO_COMP")"
  echo -e "${C_RED}Переключение на резервный порт не помогло. Возвращаю прежние настройки.${C_RESET}"
  return 1
}

mtproto_public_check() {
  local ip
  ip="$(mtproto_public_ip)"
  [[ -z "$ip" ]] && { echo "н/д"; return 0; }
  timeout 3 bash -c "</dev/tcp/${ip}/${MTPROTO_PORT}" >/dev/null 2>&1 && echo "доступен" || echo "не подтверждён"
}

ensure_mtproto_port_available() {
  local used reserve_used
  used="$(mtproto_port_in_use "$MTPROTO_PORT" || true)"
  if [[ -n "$used" ]] && ! grep -q 'mtproto-proxy' <<<"$used"; then
    echo -e "${C_RED}Основной порт ${MTPROTO_PORT} уже занят другим сервисом:${C_RESET}"
    echo "$used"
    return 1
  fi
  if [[ -n "${MTPROTO_RESERVE_PORT:-}" ]]; then
    reserve_used="$(mtproto_port_in_use "$MTPROTO_RESERVE_PORT" || true)"
    if [[ -n "$reserve_used" ]] && ! grep -q 'mtproto-proxy' <<<"$reserve_used"; then
      echo -e "${C_RED}Резервный порт ${MTPROTO_RESERVE_PORT} уже занят другим сервисом:${C_RESET}"
      echo "$reserve_used"
      return 1
    fi
  fi
  return 0
}

ensure_mtproto_firewall() {
  local port
  if ! command -v ufw >/dev/null 2>&1; then
    return 0
  fi
  if ! ufw status 2>/dev/null | grep -q '^Status: active'; then
    return 0
  fi
  for port in "$MTPROTO_PORT" "${MTPROTO_RESERVE_PORT:-}"; do
    [[ -z "$port" ]] && continue
    if ufw status numbered 2>/dev/null | grep -qE "${port}/tcp"; then
      continue
    fi
    if [[ "${MTPROTO_AUTO_OPEN_UFW:-true}" == "true" ]]; then
      ufw allow "${port}/tcp" >/dev/null 2>&1 || true
      echo -e "${C_GREEN}Для MTProto открыт порт ${port}/tcp в UFW.${C_RESET}"
    else
      echo -e "${C_YELLOW}UFW активен. Не забудь открыть порт ${port}/tcp вручную.${C_RESET}"
    fi
  done
}

mtproto_send_tg() {
  local text="$1"
  load_env
  [[ -z "$BOT_TOKEN" || -z "$CHAT_ID" ]] && return 0
  curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" -d chat_id="${CHAT_ID}" --data-urlencode text="${text}" >/dev/null 2>&1 || true
}

mtproto_repair() {
  load_env
  ensure_dirs
  ensure_mtproto_pid_compatibility
  ensure_prereqs
  ensure_mtproto_port_available || return 1
  systemctl unmask "$(service_name_for "$MTPROTO_COMP")" >/dev/null 2>&1 || true
  write_systemd_unit "$MTPROTO_COMP"
  systemd_reload
  ensure_mtproto_firewall
  run_cmd systemctl enable --now "$(service_name_for "$MTPROTO_COMP")"
  sleep 3
  if safe_is_active "$(service_name_for "$MTPROTO_COMP")" | grep -q '^active$' && mtproto_local_open; then
    echo -e "${C_GREEN}MTProto успешно восстановлен.${C_RESET}"
    return 0
  fi
  echo -e "${C_YELLOW}Обычное восстановление не помогло. Пробую резервный порт...${C_RESET}"
  mtproto_switch_to_reserve_port && return 0
  echo -e "${C_RED}MTProto не удалось восстановить автоматически.${C_RESET}"
  return 1
}

have_mtproto() {
  [[ -x "$MTPROTO_DIR/objs/bin/mtproto-proxy" ]] && [[ -f "/etc/systemd/system/$(service_name_for "$MTPROTO_COMP")" ]]
}

mtproto_ensure_tracking_files() {
  ensure_dirs
  [[ -f "$MTPROTO_STATS_FILE" ]] || cat > "$MTPROTO_STATS_FILE" <<'EOF_STATS'
AUTOREPAIR_COUNT="0"
FAILOVER_COUNT="0"
DAILY_CHECK_COUNT="0"
LAST_AUTOREPAIR_AT=""
LAST_FAILOVER_AT=""
LAST_FAIL_REASON=""
EOF_STATS
  [[ -f "$MTPROTO_HISTORY_FILE" ]] || : > "$MTPROTO_HISTORY_FILE"
  chmod 600 "$MTPROTO_STATS_FILE" "$MTPROTO_HISTORY_FILE" >/dev/null 2>&1 || true
}

mtproto_update_stat() {
  local key="$1" value="$2" tmp
  mtproto_ensure_tracking_files
  tmp="$(mktemp)"
  awk -F= -v k="$key" -v v="$value" '
    BEGIN{done=0}
    $1==k {printf "%s=\"%s\"\n", k, v; done=1; next}
    {print}
    END{if(!done) printf "%s=\"%s\"\n", k, v}
  ' "$MTPROTO_STATS_FILE" > "$tmp" && mv "$tmp" "$MTPROTO_STATS_FILE"
  chmod 600 "$MTPROTO_STATS_FILE" >/dev/null 2>&1 || true
}

mtproto_bump_stat() {
  local key="$1" current=0
  mtproto_ensure_tracking_files
  current="$(awk -F= -v k="$key" '$1==k{gsub(/^"|"$/, "", $2); print $2}' "$MTPROTO_STATS_FILE" 2>/dev/null || true)"
  [[ "$current" =~ ^[0-9]+$ ]] || current=0
  mtproto_update_stat "$key" "$((current + 1))"
}

mtproto_record_history() {
  local event="$1" details="${2:-}"
  mtproto_ensure_tracking_files
  printf "%s | %s | %s\n" "$(date '+%F %T')" "$event" "$details" >> "$MTPROTO_HISTORY_FILE"
}

show_mtproto_history() {
  mtproto_ensure_tracking_files
  if [[ ! -s "$MTPROTO_HISTORY_FILE" ]]; then
    echo "История MTProto пока пуста."
    return 0
  fi
  tail -n 30 "$MTPROTO_HISTORY_FILE"
}

show_mtproto_counters() {
  mtproto_ensure_tracking_files
  # shellcheck disable=SC1090
  source "$MTPROTO_STATS_FILE"
  echo "Автопочинок: ${AUTOREPAIR_COUNT:-0}"
  echo "Переключений на резервный порт: ${FAILOVER_COUNT:-0}"
  echo "Профилактических проверок: ${DAILY_CHECK_COUNT:-0}"
  echo "Последняя автопочинка: ${LAST_AUTOREPAIR_AT:-не было}"
  echo "Последнее переключение: ${LAST_FAILOVER_AT:-не было}"
  echo "Последняя причина сбоя: ${LAST_FAIL_REASON:-не зафиксирована}"
}

reset_mtproto_counters() {
  mtproto_ensure_tracking_files
  cat > "$MTPROTO_STATS_FILE" <<'EOF_STATS'
AUTOREPAIR_COUNT="0"
FAILOVER_COUNT="0"
DAILY_CHECK_COUNT="0"
LAST_AUTOREPAIR_AT=""
LAST_FAILOVER_AT=""
LAST_FAIL_REASON=""
EOF_STATS
  : > "$MTPROTO_HISTORY_FILE"
  chmod 600 "$MTPROTO_STATS_FILE" "$MTPROTO_HISTORY_FILE" >/dev/null 2>&1 || true
  echo -e "${C_GREEN}История и счётчики MTProto сброшены.${C_RESET}"
}

mtproto_public_ip() {
  curl -4 -fsSL --max-time 10 https://api.ipify.org 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}'
}

mtproto_links() {
  mtproto_env_source
  local secret ip
  secret="$(mtproto_client_secret)"
  ip="$(mtproto_public_ip)"
  [[ -z "$secret" ]] && { echo "Секрет MTProto не найден."; return 1; }
  cat <<EOF_MTP
Стандартная ссылка:
tg://proxy?server=${ip}&port=${MTPROTO_PORT}&secret=${secret}

Ссылка c https://:
https://t.me/proxy?server=${ip}&port=${MTPROTO_PORT}&secret=${secret}

Резервный порт: ${MTPROTO_RESERVE_PORT}
EOF_MTP
}

show_mtproto_links() {
  if ! have_mtproto; then
    echo "MTProto Proxy не установлен."
    return 1
  fi
  mtproto_links
}

regenerate_mtproto_secret() {
  if ! have_mtproto; then
    echo "MTProto Proxy не установлен."
    return 1
  fi
  load_env
  local secret
  secret="$(openssl rand -hex 16 2>/dev/null || true)"
  if [[ ! "$secret" =~ ^[0-9a-f]{32}$ ]]; then
    echo -e "${C_RED}Не удалось сгенерировать новый secret для MTProto.${C_RESET}"
    return 1
  fi
  cat > "$MTPROTO_INFO_FILE" <<EOF_MTPINFO
MTPROTO_SECRET="${secret}"
EOF_MTPINFO
  chmod 600 "$MTPROTO_INFO_FILE" >/dev/null 2>&1 || true
  write_systemd_unit "$MTPROTO_COMP"
  systemd_reload
  run_cmd systemctl restart "$(service_name_for "$MTPROTO_COMP")"
  sleep 3
  if safe_is_active "$(service_name_for "$MTPROTO_COMP")" | grep -q '^active$' && mtproto_local_open; then
    echo -e "${C_GREEN}Новый secret MTProto сохранён, сервис перезапущен.${C_RESET}"
    mtproto_links || true
    if [[ -n "${BOT_TOKEN:-}" && -n "${CHAT_ID:-}" ]]; then
      local ip link client_secret
      client_secret="$(mtproto_client_secret)"
      ip="$(mtproto_public_ip)"
      [[ -n "$client_secret" && -n "$ip" ]] && link="tg://proxy?server=${ip}&port=${MTPROTO_PORT}&secret=${client_secret}"
      if [[ -n "$link" ]]; then
        mtproto_send_tg "♻️ MTProto secret пересоздан. Новая ссылка:
${link}"
      fi
    fi
    return 0
  fi
  echo -e "${C_RED}После смены secret MTProto не прошёл локальную проверку. Откат не выполнялся, проверь статус и журнал.${C_RESET}"
  return 1
}

status_mtproto_short() {
  if have_mtproto; then
    safe_is_active "$(service_name_for "$MTPROTO_COMP")"
  else
    echo "not-found"
  fi
}

install_mtproto() {
  ensure_dirs
  ensure_prereqs
  load_env
  prompt_mtproto_settings
  save_env
  ensure_mtproto_pid_compatibility
  ensure_mtproto_port_available || return 1
  echo -e "${C_CYAN}Устанавливаю MTProto Proxy...${C_RESET}"
  DEBIAN_FRONTEND=noninteractive apt-get install -y git build-essential libssl-dev zlib1g-dev ca-certificates openssl >/dev/null 2>&1 || {
    echo -e "${C_RED}Не удалось установить зависимости для MTProto.${C_RESET}"
    return 1
  }
  if [[ -d "$MTPROTO_DIR/.git" ]]; then
    git -C "$MTPROTO_DIR" fetch --all --tags >/dev/null 2>&1 || true
    git -C "$MTPROTO_DIR" reset --hard origin/master >/dev/null 2>&1 || true
    git -C "$MTPROTO_DIR" clean -fd >/dev/null 2>&1 || true
  else
    rm -rf "$MTPROTO_DIR"
    git clone https://github.com/TelegramMessenger/MTProxy "$MTPROTO_DIR" >/dev/null 2>&1 || {
      echo -e "${C_RED}Не удалось скачать исходники MTProxy.${C_RESET}"
      return 1
    }
  fi
  (cd "$MTPROTO_DIR" && make clean >/dev/null 2>&1 || true && make >/dev/null 2>&1) || {
    echo -e "${C_RED}Сборка MTProxy завершилась ошибкой.${C_RESET}"
    return 1
  }
  curl -fsSL https://core.telegram.org/getProxySecret -o "$MTPROTO_DIR/proxy-secret" || {
    echo -e "${C_RED}Не удалось скачать proxy-secret.${C_RESET}"
    return 1
  }
  curl -fsSL https://core.telegram.org/getProxyConfig -o "$MTPROTO_DIR/proxy-multi.conf" || {
    echo -e "${C_RED}Не удалось скачать proxy-multi.conf.${C_RESET}"
    return 1
  }
  local secret
  secret="$(mtproto_secret_value)"
  if [[ -z "$secret" ]]; then
    secret="$(openssl rand -hex 16)"
  fi
  cat > "$MTPROTO_INFO_FILE" <<EOF_MTPINFO
MTPROTO_SECRET="${secret}"
EOF_MTPINFO
  chmod 600 "$MTPROTO_INFO_FILE"
  mtproto_ensure_tracking_files
  write_component_script "$MTPROTO_COMP"
  write_component_script "$MTPROTO_WATCHDOG_COMP"
  write_component_script "$MTPROTO_DAILY_COMP"
  write_systemd_unit "$MTPROTO_COMP"
  write_systemd_unit "$MTPROTO_WATCHDOG_COMP"
  write_systemd_unit "$MTPROTO_DAILY_COMP"
  systemd_reload
  ensure_mtproto_firewall
  run_cmd systemctl enable --now "$(service_name_for "$MTPROTO_COMP")"
  run_cmd systemctl enable --now "$(timer_name_for "$MTPROTO_WATCHDOG_COMP")"
  run_cmd systemctl enable --now "$(timer_name_for "$MTPROTO_DAILY_COMP")"
  sleep 3
  if safe_is_active "$(service_name_for "$MTPROTO_COMP")" | grep -q '^active$' && mtproto_local_open; then
    echo -e "${C_GREEN}MTProto Proxy установлен.${C_RESET}"
  else
    echo -e "${C_YELLOW}MTProto установлен, но сервис не прошёл локальную проверку. Запусти пункт восстановления или проверь журнал.${C_RESET}"
  fi
  mtproto_links || true
}

remove_mtproto() {
  echo -e "${C_YELLOW}Будет удалён MTProto Proxy. Продолжить? [y/N]${C_RESET}"
  read -r ans
  [[ "${ans,,}" != "y" ]] && return 0
  remove_component "$MTPROTO_DAILY_COMP" >/dev/null 2>&1 || true
  remove_component "$MTPROTO_COMP"
}

status_mtproto() {
  if ! have_mtproto; then
    echo "MTProto Proxy не установлен."
    return 0
  fi
  mtproto_env_source
  echo "== Сервис MTProto =="
  systemctl status "$(service_name_for "$MTPROTO_COMP")" --no-pager 2>/dev/null || true
  echo
  echo "== Ссылки подключения =="
  mtproto_links || true
  echo
  echo "== Локальная статистика =="
  curl -fsSL --max-time 5 "http://127.0.0.1:${MTPROTO_STATS_PORT}/stats" 2>/dev/null || echo "Статистика пока недоступна."
}

have_socks5_proxy() {
  [[ -x "$SOCKS5_BIN" ]] && [[ -f "$SOCKS5_CFG_FILE" ]] && [[ -f "/etc/systemd/system/$(service_name_for "$SOCKS5_COMP")" ]]
}

normalize_proxy_type() {
  case "${1,,}" in
    socks5|s5) echo "socks5" ;;
    socks4|s4) echo "socks4" ;;
    http|https|http_https|http/https|connect) echo "http" ;;
    *) echo "socks5" ;;
  esac
}

normalize_proxy_auth_mode() {
  case "${1,,}" in
    none|no|off|0) echo "none" ;;
    auth|password|on|1|login) echo "auth" ;;
    *) echo "auth" ;;
  esac
}

proxy_type_label() {
  case "$(normalize_proxy_type "$1")" in
    http) echo "HTTP/HTTPS" ;;
    socks4) echo "SOCKS4" ;;
    *) echo "SOCKS5" ;;
  esac
}

proxy_auth_label() {
  case "$(normalize_proxy_auth_mode "$1")" in
    none) echo "без логина и пароля" ;;
    *) echo "с логином и паролем" ;;
  esac
}

proxy_scheme_for_type() {
  case "$(normalize_proxy_type "$1")" in
    http) echo "http" ;;
    socks4) echo "socks4" ;;
    *) echo "socks5" ;;
  esac
}

proxy_service_cmd_for_type() {
  case "$(normalize_proxy_type "$1")" in
    http) echo "proxy" ;;
    socks4|socks5) echo "socks" ;;
    *) echo "socks" ;;
  esac
}

proxy_type_hint() {
  case "$(normalize_proxy_type "$1")" in
    http) echo "В клиенте выбирай тип HTTP. Этот режим подходит и для HTTPS-сайтов через CONNECT." ;;
    socks4) echo "Совместимый режим SOCKS4. Логин и пароль не используются." ;;
    *) echo "Рекомендуемый режим SOCKS5 для большинства клиентов." ;;
  esac
}

proxy_supports_auth() {
  [[ "$(normalize_proxy_type "$1")" != "socks4" ]]
}

socks5_port_in_use() {
  local port="${1:-$SOCKS5_PORT}"
  ss -lntp 2>/dev/null | awk -v p=":${port}" '$4 ~ p {print}'
}

socks5_is_port_free() {
  local port="$1"
  [[ -z "$port" ]] && return 1
  ! ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE "(^|[:.])${port}$"
}

pick_socks5_port() {
  local candidate
  for candidate in 1080 2080 3080 4080 5080 6080 7080 8088 10808 18080 28080; do
    if socks5_is_port_free "$candidate"; then
      echo "$candidate"
      return 0
    fi
  done
  for candidate in $(seq 20000 20150); do
    if socks5_is_port_free "$candidate"; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

strip_socks5_input() {
  printf '%s' "$1" | LC_ALL=C tr -cd '\041-\176'
}

validate_socks5_credential() {
  local field_name="$1"
  local value="$2"
  if [[ -z "$value" ]]; then
    echo -e "${C_RED}${field_name} не должен быть пустым.${C_RESET}"
    return 1
  fi
  if [[ "$value" == *:* ]]; then
    echo -e "${C_RED}${field_name} не должен содержать двоеточие :${C_RESET}"
    return 1
  fi
  if [[ "$value" =~ [[:space:]] ]]; then
    echo -e "${C_RED}${field_name} не должен содержать пробелы.${C_RESET}"
    return 1
  fi
  if ! LC_ALL=C grep -Eq '^[A-Za-z0-9._~-]+$' <<<"$value"; then
    echo -e "${C_RED}${field_name} содержит недопустимые символы. Разрешены только латинские буквы, цифры и символы . _ ~ -${C_RESET}"
    return 1
  fi
  return 0
}

prompt_proxy_type_choice() {
  local current="$1" choice=""
  current="$(normalize_proxy_type "$current")"
  echo -e "${C_DIM}Выбери тип прокси:${C_RESET}" >&2
  echo -e "  ${C_GREEN}1${C_RESET}) SOCKS5 — рекомендованный универсальный вариант" >&2
  echo -e "  ${C_GREEN}2${C_RESET}) HTTP/HTTPS — для клиентов с HTTP proxy, HTTPS идёт через CONNECT" >&2
  echo -e "  ${C_GREEN}3${C_RESET}) SOCKS4 — режим совместимости без логина и пароля" >&2
  printf "Тип прокси [%s]: " "$(proxy_type_label "$current")" >&2
  read -r choice || true
  case "${choice,,}" in
    "" ) echo "$current" ;;
    1|socks5|s5) echo "socks5" ;;
    2|http|https|http/https|connect) echo "http" ;;
    3|socks4|s4) echo "socks4" ;;
    *) echo "__INVALID__" ;;
  esac
}

prompt_proxy_auth_choice() {
  local current="$1" choice=""
  current="$(normalize_proxy_auth_mode "$current")"
  echo -e "${C_DIM}Выбери режим авторизации:${C_RESET}" >&2
  echo -e "  ${C_GREEN}1${C_RESET}) Без логина и пароля" >&2
  echo -e "  ${C_GREEN}2${C_RESET}) С логином и паролем" >&2
  printf "Авторизация [%s]: " "$(proxy_auth_label "$current")" >&2
  read -r choice || true
  case "${choice,,}" in
    "" ) echo "$current" ;;
    1|none|no|off) echo "none" ;;
    2|auth|password|login|on) echo "auth" ;;
    *) echo "__INVALID__" ;;
  esac
}

prompt_socks5_settings() {
  load_env
  local input chosen_type chosen_auth
  SOCKS5_TYPE="$(normalize_proxy_type "${SOCKS5_TYPE:-socks5}")"
  SOCKS5_AUTH_MODE="$(normalize_proxy_auth_mode "${SOCKS5_AUTH_MODE:-auth}")"
  echo -e "${C_DIM}Настройка прокси 3proxy. Порт и адрес выбираются автоматически.${C_RESET}"
  chosen_type="$(prompt_proxy_type_choice "$SOCKS5_TYPE")"
  if [[ "$chosen_type" == "__INVALID__" ]]; then
    echo -e "${C_RED}Некорректный тип прокси.${C_RESET}"
    return 1
  fi
  SOCKS5_TYPE="$chosen_type"
  echo -e "${C_CYAN}Выбран тип: $(proxy_type_label "$SOCKS5_TYPE").${C_RESET}"
  echo -e "${C_DIM}$(proxy_type_hint "$SOCKS5_TYPE")${C_RESET}"

  if proxy_supports_auth "$SOCKS5_TYPE"; then
    chosen_auth="$(prompt_proxy_auth_choice "$SOCKS5_AUTH_MODE")"
    if [[ "$chosen_auth" == "__INVALID__" ]]; then
      echo -e "${C_RED}Некорректный режим авторизации.${C_RESET}"
      return 1
    fi
    SOCKS5_AUTH_MODE="$chosen_auth"
  else
    SOCKS5_AUTH_MODE="none"
    echo -e "${C_DIM}Для SOCKS4 логин и пароль не используются.${C_RESET}"
  fi

  if [[ "$SOCKS5_AUTH_MODE" == "auth" ]]; then
    read -r -p "Логин прокси [${SOCKS5_LOGIN}]: " input || true
    if [[ -n "$input" ]]; then
      SOCKS5_LOGIN="$(strip_socks5_input "$input")"
    else
      SOCKS5_LOGIN="$(strip_socks5_input "$SOCKS5_LOGIN")"
    fi
    read -r -p "Пароль прокси [${SOCKS5_PASSWORD}]: " input || true
    if [[ -n "$input" ]]; then
      SOCKS5_PASSWORD="$(strip_socks5_input "$input")"
    else
      SOCKS5_PASSWORD="$(strip_socks5_input "$SOCKS5_PASSWORD")"
    fi
    validate_socks5_credential "Логин прокси" "$SOCKS5_LOGIN" || return 1
    validate_socks5_credential "Пароль прокси" "$SOCKS5_PASSWORD" || return 1
  else
    SOCKS5_LOGIN=""
    SOCKS5_PASSWORD=""
  fi
  SOCKS5_BIND_ADDR="0.0.0.0"
  save_env
}

install_3proxy_binary() {
  ensure_prereqs
  echo -e "${C_CYAN}Устанавливаю 3proxy из исходников...${C_RESET}"
  DEBIAN_FRONTEND=noninteractive apt-get install -y build-essential git ca-certificates findutils >/dev/null 2>&1 || {
    echo -e "${C_RED}Не удалось установить зависимости для 3proxy.${C_RESET}"
    return 1
  }

  mkdir -p /usr/local/src /usr/local/3proxy/bin
  rm -rf "$SOCKS5_SRC_DIR"
  git clone https://github.com/z3APA3A/3proxy.git "$SOCKS5_SRC_DIR" >/dev/null 2>&1 || {
    echo -e "${C_RED}Не удалось скачать исходники 3proxy.${C_RESET}"
    return 1
  }

  (
    cd "$SOCKS5_SRC_DIR" && \
    make -f Makefile.Linux clean >/dev/null 2>&1 || true
  )

  (
    cd "$SOCKS5_SRC_DIR" && \
    make -f Makefile.Linux >/dev/null 2>&1
  ) || {
    echo -e "${C_RED}Сборка 3proxy завершилась ошибкой.${C_RESET}"
    return 1
  }

  local found_bin=""
  found_bin="$(cd "$SOCKS5_SRC_DIR" && find . -type f -name 3proxy 2>/dev/null | grep -E '/(src|bin)/3proxy$|^\./3proxy$' | head -n 1 || true)"

  if [[ -z "$found_bin" ]]; then
    echo -e "${C_RED}Бинарник 3proxy не найден после сборки.${C_RESET}"
    return 1
  fi

  install -m 755 "$SOCKS5_SRC_DIR/${found_bin#./}" "$SOCKS5_BIN" || {
    echo -e "${C_RED}Не удалось установить бинарник 3proxy.${C_RESET}"
    return 1
  }

  if [[ ! -x "$SOCKS5_BIN" ]]; then
    echo -e "${C_RED}3proxy скопирован некорректно: бинарник не исполняемый.${C_RESET}"
    return 1
  fi

  return 0
}

write_socks5_config() {
  load_env
  ensure_dirs
  local cfg_type cfg_auth svc_cmd log_file
  SOCKS5_TYPE="$(normalize_proxy_type "$SOCKS5_TYPE")"
  SOCKS5_AUTH_MODE="$(normalize_proxy_auth_mode "$SOCKS5_AUTH_MODE")"
  cfg_type="$SOCKS5_TYPE"
  cfg_auth="$SOCKS5_AUTH_MODE"
  log_file="$LOG_DIR/3proxy-proxy.log"
  svc_cmd="$(proxy_service_cmd_for_type "$cfg_type")"

  mkdir -p "$LOG_DIR"
  : > "$log_file"
  chmod 640 "$log_file" >/dev/null 2>&1 || true

  {
    printf '%s\n' "log ${log_file} D"
    printf '%s\n' "timeouts 1 5 30 60 180 1800 15 60"
    if [[ "$cfg_auth" == "auth" ]]; then
      SOCKS5_LOGIN="$(strip_socks5_input "$SOCKS5_LOGIN")"
      SOCKS5_PASSWORD="$(strip_socks5_input "$SOCKS5_PASSWORD")"
      validate_socks5_credential "Логин прокси" "$SOCKS5_LOGIN" || return 1
      validate_socks5_credential "Пароль прокси" "$SOCKS5_PASSWORD" || return 1
      printf '%s\n' "auth strong"
      printf '%s\n' "users ${SOCKS5_LOGIN}:CL:${SOCKS5_PASSWORD}"
      printf '%s\n' "allow ${SOCKS5_LOGIN}"
    else
      printf '%s\n' "auth none"
      printf '%s\n' "allow *"
    fi
    printf '%s\n' "${svc_cmd} -p${SOCKS5_PORT} -i${SOCKS5_BIND_ADDR}"
    printf '%s\n' "flush"
  } > "$SOCKS5_CFG_FILE"

  chmod 600 "$SOCKS5_CFG_FILE"
  save_env
}

ensure_socks5_firewall() {
  local port="${SOCKS5_PORT:-1080}"
  if ! command -v ufw >/dev/null 2>&1; then
    return 0
  fi
  if ! ufw status 2>/dev/null | grep -q '^Status: active'; then
    return 0
  fi
  if ufw status numbered 2>/dev/null | grep -qE "${port}/tcp"; then
    return 0
  fi
  if [[ "${SOCKS5_AUTO_OPEN_UFW:-true}" == "true" ]]; then
    ufw allow "${port}/tcp" >/dev/null 2>&1 || true
    echo -e "${C_GREEN}Для прокси открыт порт ${port}/tcp в UFW.${C_RESET}"
  else
    echo -e "${C_YELLOW}UFW активен. Не забудь открыть порт ${port}/tcp вручную.${C_RESET}"
  fi
}

socks5_local_check() {
  timeout 3 bash -c "</dev/tcp/127.0.0.1/${SOCKS5_PORT}" >/dev/null 2>&1
}

proxy_local_protocol_check() {
  load_env
  python3 - "$SOCKS5_TYPE" "$SOCKS5_AUTH_MODE" "$SOCKS5_PORT" <<'PY'
import socket, sys
ptype = sys.argv[1].lower()
auth = sys.argv[2].lower()
port = int(sys.argv[3])
try:
    with socket.create_connection(("127.0.0.1", port), timeout=3) as s:
        s.settimeout(3)
        if ptype == "http":
            s.sendall(b"GET http://example.com/ HTTP/1.0\r\n\r\n")
            data = s.recv(16)
            ok = data.startswith(b"HTTP/")
        else:
            method = b"\x02" if auth == "auth" else b"\x00"
            s.sendall(b"\x05\x01" + method)
            data = s.recv(2)
            ok = len(data) == 2 and data[:1] == b"\x05"
            if auth == "auth":
                ok = ok and data[1:] == b"\x02"
            else:
                ok = ok and data[1:] in (b"\x00", b"\x02")
except Exception:
    ok = False
sys.exit(0 if ok else 1)
PY
}

proxy_runtime_check() {
  safe_is_active "$(service_name_for "$SOCKS5_COMP")" | grep -q '^active$' && socks5_local_check && proxy_local_protocol_check
}

install_socks5_proxy() {
  ensure_dirs
  ensure_prereqs
  load_env
  prompt_socks5_settings || return 1
  if ! install_3proxy_binary; then
    return 1
  fi
  local current_used selected_port
  current_used="$(socks5_port_in_use "$SOCKS5_PORT" || true)"
  if [[ -z "$SOCKS5_PORT" || ( -n "$current_used" && ! "$current_used" =~ 3proxy ) ]]; then
    selected_port="$(pick_socks5_port || true)"
    if [[ -z "$selected_port" ]]; then
      echo -e "${C_RED}Не удалось автоматически подобрать свободный порт для прокси.${C_RESET}"
      return 1
    fi
    SOCKS5_PORT="$selected_port"
  fi
  SOCKS5_BIND_ADDR="0.0.0.0"
  save_env
  echo -e "${C_CYAN}Устанавливаю прокси 3proxy...${C_RESET}"
  write_socks5_config || return 1
  write_systemd_unit "$SOCKS5_COMP"
  systemd_reload
  ensure_socks5_firewall
  run_cmd systemctl enable --now "$(service_name_for "$SOCKS5_COMP")"
  sleep 2
  if proxy_runtime_check; then
    echo -e "${C_GREEN}Прокси 3proxy установлен и запущен.${C_RESET}"
    echo -e "${C_GREEN}Тип: $(proxy_type_label "$SOCKS5_TYPE"), авторизация: $(proxy_auth_label "$SOCKS5_AUTH_MODE").${C_RESET}"
    echo -e "${C_GREEN}Автоматически выбран порт ${SOCKS5_PORT}, адрес привязки ${SOCKS5_BIND_ADDR}.${C_RESET}"
    show_socks5_connection_info
    return 0
  fi
  echo -e "${C_RED}Прокси установлен, но не прошёл локальную проверку протокола. Проверь статус и journal.${C_RESET}"
  journalctl -u "$(service_name_for "$SOCKS5_COMP")" -n 20 --no-pager 2>/dev/null || true
  return 1
}

remove_socks5_proxy() {
  echo -e "${C_YELLOW}Будет удалён прокси 3proxy. Продолжить? [y/N]${C_RESET}"
  read -r ans
  [[ "${ans,,}" != "y" ]] && return 0
  remove_component "$SOCKS5_COMP"
  rm -f "$SOCKS5_CFG_FILE"
  rm -rf /usr/local/3proxy "$SOCKS5_SRC_DIR"
  echo -e "${C_GREEN}Прокси 3proxy удалён.${C_RESET}"
}

show_socks5_connection_info() {
  load_env
  local server_ip scheme
  server_ip="$(curl -4 -fsSL --max-time 10 https://api.ipify.org 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}')"
  scheme="$(proxy_scheme_for_type "$SOCKS5_TYPE")"
  echo "Тип: $(proxy_type_label "$SOCKS5_TYPE")"
  echo "Авторизация: $(proxy_auth_label "$SOCKS5_AUTH_MODE")"
  echo "Адрес: ${server_ip:-<IP_СЕРВЕРА>}"
  echo "Порт: ${SOCKS5_PORT}"
  if [[ "$SOCKS5_AUTH_MODE" == "auth" ]]; then
    echo "Логин: ${SOCKS5_LOGIN}"
    echo "Пароль: ${SOCKS5_PASSWORD}"
    echo "URL: ${scheme}://${SOCKS5_LOGIN}:${SOCKS5_PASSWORD}@${server_ip:-<IP_СЕРВЕРА>}:${SOCKS5_PORT}"
  else
    echo "Логин: не используется"
    echo "Пароль: не используется"
    echo "URL: ${scheme}://${server_ip:-<IP_СЕРВЕРА>}:${SOCKS5_PORT}"
  fi
  echo "Подсказка: $(proxy_type_hint "$SOCKS5_TYPE")"
}

status_socks5_proxy() {
  if ! have_socks5_proxy; then
    echo "Прокси 3proxy не установлен."
    return 0
  fi
  systemctl status "$(service_name_for "$SOCKS5_COMP")" --no-pager 2>/dev/null || true
  echo
  show_socks5_connection_info
}

socks5_menu() {
  while true; do
    show_header
    echo -e "${C_GRAY}Раздел прокси 3proxy: HTTP/HTTPS, SOCKS5 и SOCKS4-совместимый режим. Порт и адрес назначаются автоматически.${C_RESET}"
    echo
    menu_line "1" "🧦" "$C_GREEN" "Установить / обновить прокси 3proxy"
    menu_line "2" "⚙️" "$C_YELLOW" "Изменить тип, авторизацию и учётные данные"
    menu_line "3" "▶️" "$C_GREEN" "Запустить прокси"
    menu_line "4" "⏹" "$C_RED" "Остановить прокси"
    menu_line "5" "🔄" "$C_YELLOW" "Перезапустить прокси"
    menu_line "6" "📊" "$C_BLUE" "Статус прокси"
    menu_line "7" "🔐" "$C_CYAN" "Показать данные для подключения"
    menu_line "8" "🗑" "$C_RED" "Удалить прокси 3proxy"
    menu_line "0" "↩" "$C_GRAY" "Назад"
    read -r -p $'\033[36mВыбери:\033[0m ' c
    case "$c" in
      1) install_socks5_proxy; pause ;;
      2)
        if prompt_socks5_settings && write_socks5_config && write_systemd_unit "$SOCKS5_COMP" && systemd_reload && run_cmd systemctl restart "$(service_name_for "$SOCKS5_COMP")"; then
          if proxy_runtime_check; then
            echo -e "${C_GREEN}Настройки прокси сохранены и локальная проверка пройдена.${C_RESET}"
          else
            echo -e "${C_RED}Настройки сохранены, но локальная проверка не пройдена. Проверь статус и journal.${C_RESET}"
          fi
        fi
        pause ;;
      3) start_component "$SOCKS5_COMP"; pause ;;
      4) stop_component "$SOCKS5_COMP"; pause ;;
      5)
        run_cmd systemctl restart "$(service_name_for "$SOCKS5_COMP")"
        if proxy_runtime_check; then
          echo "Прокси 3proxy перезапущен и отвечает корректно."
        else
          echo "Прокси перезапущен, но локальная проверка не пройдена."
        fi
        pause ;;
      6) status_socks5_proxy; pause ;;
      7) show_socks5_connection_info; pause ;;
      8) remove_socks5_proxy; pause ;;
      0) break ;;
      *) echo -e "${C_RED}Неверный выбор.${C_RESET}"; pause ;;
    esac
  done
}

show_header() {
  load_env
  clear || true
  local warp_pkg="не установлен"
  have_warp && warp_pkg="установлен"
  local warp_svc xray_svc mtproto_svc mtproto_recovery mtproto_daily warp_cli warp_egress warp_recovery daily_enabled token_set chat_set socks5_svc socks5_pkg
  warp_svc="$(safe_is_active "$WARP_SERVICE_NAME")"
  xray_svc="$(safe_is_active "$XRAY_SERVICE_NAME")"
  if [[ -x "$SOCKS5_BIN" ]]; then socks5_pkg="установлен"; else socks5_pkg="не установлен"; fi
  socks5_svc="$(safe_is_active "$(service_name_for "$SOCKS5_COMP")")"
  mtproto_svc="$(status_mtproto_short)"
  mtproto_recovery="$(safe_is_enabled "$(timer_name_for "$MTPROTO_WATCHDOG_COMP")")"
  mtproto_daily="$(safe_is_enabled "$(timer_name_for "$MTPROTO_DAILY_COMP")")"
  warp_cli="$(warp_cli_summary)"
  warp_egress="$(warp_egress_state)"
  warp_recovery="$(safe_is_enabled "$(timer_name_for "$WARP_WATCHDOG_COMP")")"
  daily_enabled="$(safe_is_enabled "$(timer_name_for "$DAILY_COMP")")"
  xui_warp_fallback="$(xui_warp_fallback_status)"
  [[ -n "$BOT_TOKEN" ]] && token_set="задан" || token_set="не задан"
  [[ -n "$CHAT_ID" ]] && chat_set="задан" || chat_set="не задан"
  echo -e "${C_CYAN}${C_BOLD}${APP_NAME} v${APP_VERSION}${C_RESET}"
  echo -e "${C_GRAY}────────────────────────────────────────${C_RESET}"
  echo -e "📦 Пакет WARP: $(fmt_status "$warp_pkg")"
  echo -e "🧩 Сервис ${WARP_SERVICE_NAME}: $(fmt_status "$warp_svc")"
  echo -e "📡 Статус warp-cli: $(fmt_status "$warp_cli")"
  echo -e "🌍 WARP egress: $(fmt_status "$warp_egress")"
  echo -e "🛟 Автовосстановление WARP: $(fmt_status "$warp_recovery")"
  echo -e "⚙️ Сервис ${XRAY_SERVICE_NAME}: $(fmt_status "$xray_svc")"
  echo -e "🧦 Пакет прокси (3proxy): $(fmt_status "$socks5_pkg")"
  echo -e "🧦 Сервис прокси: $(fmt_status "$socks5_svc")"
  echo -e "↪️ Fallback WARP→direct: $(fmt_status "$xui_warp_fallback")"
  echo -e "📨 MTProto Proxy: $(fmt_status "$mtproto_svc")"
  echo -e "🩺 Автовосстановление MTProto: $(fmt_status "$mtproto_recovery")"
  echo -e "🗓 Профилактика MTProto: $(fmt_status "$mtproto_daily")"
  if [[ -f "$MTPROTO_STATS_FILE" ]]; then
    local mtproto_repairs mtproto_failovers
    mtproto_repairs="$(awk -F= '$1=="AUTOREPAIR_COUNT"{gsub(/^"|"$/, "", $2); print $2}' "$MTPROTO_STATS_FILE" 2>/dev/null || echo 0)"
    mtproto_failovers="$(awk -F= '$1=="FAILOVER_COUNT"{gsub(/^"|"$/, "", $2); print $2}' "$MTPROTO_STATS_FILE" 2>/dev/null || echo 0)"
    echo -e "📈 MTProto: автопочинок ${C_YELLOW}${mtproto_repairs:-0}${C_RESET}, переключений ${C_YELLOW}${mtproto_failovers:-0}${C_RESET}"
  fi
  echo -e "🤖 Токен Telegram: $(fmt_status "$token_set")"
  echo -e "💬 Chat ID Telegram: $(fmt_status "$chat_set")"
  echo -e "🕘 Ежедневный отчёт: $(fmt_status "$daily_enabled") ${C_GRAY}в $(printf '%02d:%02d' "$DAILY_REPORT_HOUR" "$DAILY_REPORT_MINUTE")${C_RESET}"
  echo -e "⏱ Интервал WARP watchdog: ${C_YELLOW}1м${C_RESET}"
  echo -e "⏱ Интервал Xray watchdog: ${C_YELLOW}1м${C_RESET}"
  echo -e "${C_GRAY}────────────────────────────────────────${C_RESET}"
}

prompt_telegram_settings() {
  load_env
  local input
  echo -e "${C_DIM}Настройка Telegram: токен бота, сетевые параметры и время отчёта.${C_RESET}"
  read -r -p "BOT_TOKEN [${BOT_TOKEN}]: " input || true
  BOT_TOKEN="${input:-$BOT_TOKEN}"
  read -r -p "SOCKS_ADDR [${SOCKS_ADDR}]: " input || true
  SOCKS_ADDR="${input:-$SOCKS_ADDR}"
  read -r -p "TRACE_URL [${TRACE_URL}]: " input || true
  TRACE_URL="${input:-$TRACE_URL}"
  read -r -p "Час ежедневного отчёта по времени сервера 0-23 [${DAILY_REPORT_HOUR}]: " input || true
  DAILY_REPORT_HOUR="${input:-$DAILY_REPORT_HOUR}"
  read -r -p "Минута ежедневного отчёта 0-59 [${DAILY_REPORT_MINUTE}]: " input || true
  DAILY_REPORT_MINUTE="${input:-$DAILY_REPORT_MINUTE}"
  save_env
  echo -e "${C_GREEN}Настройки сохранены.${C_RESET}"
}

auto_get_chat_id() {
  load_env
  if [[ -z "$BOT_TOKEN" ]]; then
    echo -e "${C_YELLOW}Сначала задай BOT_TOKEN.${C_RESET}"
    return 1
  fi
  echo "Напиши боту любое сообщение и нажми Enter."
  read -r
  local cid
  cid="$(python3 - "$BOT_TOKEN" <<'PY'
import json, sys, urllib.request
token = sys.argv[1]
url = f"https://api.telegram.org/bot{token}/getUpdates"
try:
    data = json.load(urllib.request.urlopen(url, timeout=20))
    result = data.get("result") or []
    chat_id = ""
    for item in reversed(result):
        msg = item.get("message")
        if not msg and item.get("callback_query"):
            msg = item["callback_query"].get("message")
        if msg and msg.get("chat") and "id" in msg["chat"]:
            chat_id = str(msg["chat"]["id"])
            break
    print(chat_id)
except Exception:
    print("")
PY
)"
  if [[ -z "$cid" ]]; then
    echo -e "${C_RED}Не удалось получить Chat ID. Нажми Start у бота и отправь сообщение.${C_RESET}"
    return 1
  fi
  CHAT_ID="$cid"
  save_env
  echo -e "${C_GREEN}Chat ID сохранён: ${CHAT_ID}${C_RESET}"
}

send_test_telegram() {
  load_env
  if [[ -z "$BOT_TOKEN" || -z "$CHAT_ID" ]]; then
    echo -e "${C_YELLOW}Сначала задай BOT_TOKEN и Chat ID.${C_RESET}"
    return 1
  fi
  if curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -d chat_id="${CHAT_ID}" \
    --data-urlencode text="✅ Тест: ${APP_NAME} настроен" >/dev/null; then
    echo -e "${C_GREEN}Тестовое сообщение отправлено.${C_RESET}"
  else
    echo -e "${C_RED}Не удалось отправить тестовое сообщение.${C_RESET}"
  fi
}

install_warp_repo() {
  ensure_prereqs
  if [[ ! -f /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg ]]; then
    mkdir -p /usr/share/keyrings
    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
  fi
  local codename=""
  if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    codename="${VERSION_CODENAME:-}"
  fi
  [[ -z "$codename" ]] && codename="noble"
  cat > /etc/apt/sources.list.d/cloudflare-client.list <<EOF
deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ ${codename} main
EOF
}

install_warp() {
  ensure_prereqs
  if have_warp; then
    echo -e "${C_GREEN}WARP уже установлен.${C_RESET}"
    return 0
  fi
  echo -e "${C_CYAN}Устанавливаю WARP...${C_RESET}"
  install_warp_repo
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y cloudflare-warp || {
    echo -e "${C_RED}Не удалось установить cloudflare-warp.${C_RESET}"
    return 1
  }
  run_cmd systemctl enable --now "$WARP_SERVICE_NAME"
  sleep 3
  yes | warp-cli registration new >/dev/null 2>&1 || true
  run_cmd warp-cli mode proxy
  run_cmd warp-cli proxy port 40000
  run_cmd warp-cli connect
  ensure_warp_outbound_in_xui || true
  echo -e "${C_GREEN}WARP установлен.${C_RESET}"
}

remove_warp() {
  echo -e "${C_YELLOW}Будет удалён WARP. Продолжить? [y/N]${C_RESET}"
  read -r ans
  [[ "${ans,,}" != "y" ]] && return 0
  disable_warp_recovery >/dev/null 2>&1 || true
  if have_warp; then
    run_cmd warp-cli disconnect
  fi
  remove_warp_outbound_in_xui >/dev/null 2>&1 || true
  apt-get remove -y cloudflare-warp >/dev/null 2>&1 || true
  rm -f /etc/apt/sources.list.d/cloudflare-client.list /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
  echo -e "${C_GREEN}WARP удалён.${C_RESET}"
}

start_warp() { require_warp || return 1; run_cmd systemctl start "$WARP_SERVICE_NAME"; sleep 2; run_cmd warp-cli connect; echo -e "${C_GREEN}WARP запущен.${C_RESET}"; }
stop_warp() { require_warp || return 1; run_cmd warp-cli disconnect; run_cmd systemctl stop "$WARP_SERVICE_NAME"; echo -e "${C_GREEN}WARP остановлен.${C_RESET}"; }
restart_warp() { require_warp || return 1; run_cmd systemctl restart "$WARP_SERVICE_NAME"; sleep 3; run_cmd warp-cli connect; echo -e "${C_GREEN}WARP перезапущен.${C_RESET}"; }

status_warp() {
  if ! have_warp; then
    echo "WARP не установлен."
    return 0
  fi
  echo "== ${WARP_SERVICE_NAME} =="
  systemctl status "$WARP_SERVICE_NAME" --no-pager 2>/dev/null || true
  echo
  echo "== warp-cli =="
  warp-cli status 2>/dev/null || true
  echo
  echo "== trace через SOCKS =="
  curl -s --max-time 15 --socks5-hostname "$SOCKS_ADDR" "$TRACE_URL" || true
}

reissue_warp_registration() {
  require_warp || return 1
  echo -e "${C_YELLOW}Будет перевыпущена регистрация WARP. Продолжить? [y/N]${C_RESET}"
  read -r ans
  [[ "${ans,,}" != "y" ]] && return 0
  run_cmd warp-cli disconnect
  run_cmd warp-cli registration delete
  yes | warp-cli registration new >/dev/null 2>&1 || true
  run_cmd warp-cli mode proxy
  run_cmd warp-cli proxy port 40000
  run_cmd warp-cli connect
  echo -e "${C_GREEN}Регистрация WARP перевыпущена.${C_RESET}"
}

enable_warp_proxy_mode() { require_warp || return 1; run_cmd warp-cli mode proxy; run_cmd warp-cli proxy port 40000; run_cmd warp-cli connect; echo -e "${C_GREEN}SOCKS proxy mode включён.${C_RESET}"; }
disable_warp_proxy_mode() { require_warp || return 1; run_cmd warp-cli disconnect; echo -e "${C_GREEN}SOCKS proxy mode отключён.${C_RESET}"; }

write_component_script() {
  local comp="$1"
  ensure_dirs
  case "$comp" in
    warp-optimize)
      cat > "$BIN_DIR/warp-optimize.sh" <<'EOF_SCRIPT'
#!/usr/bin/env bash
set -u -o pipefail
LOG_FILE="/var/log/vpn-tools/warp-optimize.log"
mkdir -p /var/log/vpn-tools
if ! command -v warp-cli >/dev/null 2>&1; then
  echo "$(date '+%F %T') - WARP не установлен" >> "$LOG_FILE"
  exit 0
fi
tries=5
for i in $(seq 1 "$tries"); do
  warp-cli disconnect >/dev/null 2>&1 || true
  sleep 2
  warp-cli connect >/dev/null 2>&1 || true
  sleep 8
  p="$(ping -c 3 1.1.1.1 2>/dev/null | awk -F'/' 'END{print $5}')"
  [[ -z "$p" ]] && p="н/д"
  echo "$(date '+%F %T') - попытка $i: $p ms" >> "$LOG_FILE"
done
echo "$(date '+%F %T') - оптимизация завершена" >> "$LOG_FILE"
EOF_SCRIPT
      chmod +x "$BIN_DIR/warp-optimize.sh"
      ;;
    warp-watchdog)
      cat > "$BIN_DIR/warp-watchdog.sh" <<'EOF_SCRIPT'
#!/usr/bin/env bash
set -u -o pipefail
ENV_FILE="/etc/vpn-tools.env"
LOG_FILE="/var/log/vpn-tools/warp.log"
STATE_FILE="/var/lib/vpn-tools/warp_state"
LOCK_FILE="/run/vpn-tools/warp-watchdog.lock"
XUI_FALLBACK_STATE_FILE="/var/lib/vpn-tools/xui_warp_fallback.active"
XUI_FALLBACK_BACKUP_FILE="/var/lib/vpn-tools/xui_warp_fallback_config.json"
mkdir -p /var/log/vpn-tools /var/lib/vpn-tools /run/vpn-tools
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"
BOT_TOKEN="${BOT_TOKEN:-}"
CHAT_ID="${CHAT_ID:-}"
SOCKS_ADDR="${SOCKS_ADDR:-127.0.0.1:40000}"
TRACE_URL="${TRACE_URL:-https://1.1.1.1/cdn-cgi/trace}"
WARP_SERVICE_NAME="${WARP_SERVICE_NAME:-warp-svc}"
XRAY_SERVICE_NAME="${XRAY_SERVICE_NAME:-x-ui}"
AUTO_OPTIMIZE_AFTER_RECOVERY="${AUTO_OPTIMIZE_AFTER_RECOVERY:-true}"
send_tg() {
  local text="$1"
  [[ -z "$BOT_TOKEN" || -z "$CHAT_ID" ]] && return 0
  curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" -d chat_id="${CHAT_ID}" --data-urlencode text="${text}" >/dev/null 2>&1 || true
}
log_msg() { echo "$(date '+%F %T') - $*" >> "$LOG_FILE"; }
have_warp() { command -v warp-cli >/dev/null 2>&1; }
get_trace() { curl -s --max-time 12 --socks5-hostname "$SOCKS_ADDR" "$TRACE_URL" 2>/dev/null || true; }
get_field() { local k="$1"; awk -F= -v k="$k" '$1==k{print $2}' <<<"$2"; }
get_ping() { ping -c 3 1.1.1.1 2>/dev/null | awk -F'/' 'END{print $5}'; }
xui_config_path() {
  local cfg="/usr/local/x-ui/bin/config.json"
  [[ -f "$cfg" ]] && echo "$cfg"
}
activate_xui_fallback() {
  local cfg tmp
  cfg="$(xui_config_path || true)"
  [[ -z "$cfg" ]] && return 1
  command -v jq >/dev/null 2>&1 || return 1
  if [[ -f "$XUI_FALLBACK_STATE_FILE" && -f "$XUI_FALLBACK_BACKUP_FILE" ]]; then
    return 0
  fi
  cp -f "$cfg" "$XUI_FALLBACK_BACKUP_FILE"
  tmp="$(mktemp)"
  if jq '
    def mapwarp(x): if x == "WARP" then "direct" else x end;
    .routing.rules = ((.routing.rules // []) | map(if .outboundTag? == "WARP" then .outboundTag = "direct" else . end))
    | .balancers = ((.balancers // []) | map(if .selector? then .selector = (.selector | map(mapwarp(.))) else . end))
    | .observatory.subjectSelector = ((.observatory.subjectSelector // []) | map(mapwarp(.)))
  ' "$cfg" > "$tmp"; then
    mv "$tmp" "$cfg"
  else
    rm -f "$tmp" "$XUI_FALLBACK_BACKUP_FILE"
    return 1
  fi
  jq empty "$cfg" >/dev/null 2>&1 || {
    cp -f "$XUI_FALLBACK_BACKUP_FILE" "$cfg"
    rm -f "$XUI_FALLBACK_BACKUP_FILE"
    return 1
  }
  touch "$XUI_FALLBACK_STATE_FILE"
  systemctl restart "$XRAY_SERVICE_NAME" >/dev/null 2>&1 || true
  sleep 3
  return 0
}
restore_xui_fallback() {
  local cfg
  cfg="$(xui_config_path || true)"
  [[ -z "$cfg" ]] && return 1
  [[ -f "$XUI_FALLBACK_STATE_FILE" && -f "$XUI_FALLBACK_BACKUP_FILE" ]] || return 0
  cp -f "$XUI_FALLBACK_BACKUP_FILE" "$cfg"
  jq empty "$cfg" >/dev/null 2>&1 || return 1
  rm -f "$XUI_FALLBACK_STATE_FILE" "$XUI_FALLBACK_BACKUP_FILE"
  systemctl restart "$XRAY_SERVICE_NAME" >/dev/null 2>&1 || true
  sleep 3
  return 0
}
check_warp() {
  local t ip
  t="$(get_trace)"
  grep -q 'warp=on' <<<"$t" && return 0
  ip="$(curl -s --max-time 8 --socks5-hostname "$SOCKS_ADDR" ifconfig.me 2>/dev/null || true)"
  grep -Eq '^(162\.|104\.)' <<<"$ip" && return 0
  return 1
}
recover_warp() {
  systemctl restart "$WARP_SERVICE_NAME" >/dev/null 2>&1 || true
  sleep 8
  warp-cli disconnect >/dev/null 2>&1 || true
  sleep 2
  warp-cli connect >/dev/null 2>&1 || true
  sleep 10
  if [[ "$AUTO_OPTIMIZE_AFTER_RECOVERY" == "true" ]] && [[ -x /opt/vpn-tools/bin/warp-optimize.sh ]]; then
    /opt/vpn-tools/bin/warp-optimize.sh >/dev/null 2>&1 || true
    sleep 5
  fi
  check_warp
}
exec 9>"$LOCK_FILE"
flock -n 9 || exit 0
if ! have_warp; then
  log_msg "WARP не установлен, watchdog пропущен"
  exit 0
fi
last="OK"
[[ -f "$STATE_FILE" ]] && last="$(cat "$STATE_FILE")"
current="OK"
systemctl is-active --quiet "$WARP_SERVICE_NAME" || current="FAIL"
if [[ "$current" == "OK" ]]; then
  status="$((warp-cli status 2>/dev/null || true) | head -n1)"
  grep -qi 'Connected' <<<"$status" || current="FAIL"
fi
if [[ "$current" == "OK" ]]; then
  check_warp || current="FAIL"
fi
if [[ "$current" == "FAIL" ]]; then
  log_msg "WARP FAIL"
  if activate_xui_fallback; then
    log_msg "Активирован fallback WARP→direct в 3x-ui"
    [[ "$last" == "OK" ]] && send_tg "↪️ WARP недоступен. В 3x-ui активирован fallback WARP→direct, чтобы трафик не пропал."
  fi
  [[ "$last" == "OK" ]] && send_tg "⚠️ WARP упал. Пытаюсь восстановить..."
  if recover_warp; then
    trace="$(get_trace)"
    ip="$(get_field ip "$trace")"
    colo="$(get_field colo "$trace")"
    loc="$(get_field loc "$trace")"
    p="$(get_ping)"
    if restore_xui_fallback >/dev/null 2>&1; then
      log_msg "Fallback WARP→direct отключён, маршруты 3x-ui возвращены на WARP"
    fi
    echo "OK" > "$STATE_FILE"
    log_msg "WARP восстановлен"
    send_tg "✅ WARP восстановлен
IP: ${ip}
COLO: ${colo}
LOC: ${loc}
PING: ${p} ms
Маршруты 3x-ui возвращены с direct обратно на WARP."
    exit 0
  else
    echo "FAIL" > "$STATE_FILE"
    log_msg "WARP не удалось восстановить, fallback direct оставлен активным"
    [[ "$last" == "OK" ]] && send_tg "❌ WARP не удалось восстановить автоматически. В 3x-ui оставлен fallback WARP→direct, чтобы соединение оставалось рабочим."
    exit 1
  fi
fi
if [[ -f "$XUI_FALLBACK_STATE_FILE" ]]; then
  if restore_xui_fallback; then
    log_msg "WARP OK, fallback WARP→direct отключён"
    [[ "$last" == "FAIL" ]] && send_tg "✅ WARP снова работает. В 3x-ui отключён fallback WARP→direct, маршруты через WARP восстановлены."
  fi
fi
echo "OK" > "$STATE_FILE"
log_msg "OK"
EOF_SCRIPT
      chmod +x "$BIN_DIR/warp-watchdog.sh"
      ;;
    xray-watchdog)
      cat > "$BIN_DIR/xray-watchdog.sh" <<'EOF_SCRIPT'
#!/usr/bin/env bash
set -u -o pipefail
ENV_FILE="/etc/vpn-tools.env"
LOG_FILE="/var/log/vpn-tools/xray.log"
STATE_FILE="/var/lib/vpn-tools/xray_state"
mkdir -p /var/log/vpn-tools /var/lib/vpn-tools
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"
BOT_TOKEN="${BOT_TOKEN:-}"
CHAT_ID="${CHAT_ID:-}"
XRAY_SERVICE_NAME="${XRAY_SERVICE_NAME:-x-ui}"
send_tg() {
  local text="$1"
  [[ -z "$BOT_TOKEN" || -z "$CHAT_ID" ]] && return 0
  curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" -d chat_id="${CHAT_ID}" --data-urlencode text="${text}" >/dev/null 2>&1 || true
}
log_msg() { echo "$(date '+%F %T') - $*" >> "$LOG_FILE"; }
last="OK"
[[ -f "$STATE_FILE" ]] && last="$(cat "$STATE_FILE")"
if systemctl is-active --quiet "$XRAY_SERVICE_NAME"; then
  echo "OK" > "$STATE_FILE"
  log_msg "OK"
  exit 0
fi
log_msg "${XRAY_SERVICE_NAME} inactive"
[[ "$last" == "OK" ]] && send_tg "⚠️ ${XRAY_SERVICE_NAME} упал. Пытаюсь восстановить..."
systemctl restart "$XRAY_SERVICE_NAME" >/dev/null 2>&1 || true
sleep 6
if systemctl is-active --quiet "$XRAY_SERVICE_NAME"; then
  echo "OK" > "$STATE_FILE"
  log_msg "Восстановлен"
  send_tg "✅ ${XRAY_SERVICE_NAME} был перезапущен и восстановлен"
  exit 0
fi
echo "FAIL" > "$STATE_FILE"
send_tg "❌ ${XRAY_SERVICE_NAME} не удалось восстановить автоматически"
exit 1
EOF_SCRIPT
      chmod +x "$BIN_DIR/xray-watchdog.sh"
      ;;
    vpn-status)
      cat > "$BIN_DIR/vpn-status.sh" <<'EOF_SCRIPT'
#!/usr/bin/env bash
set -u -o pipefail
ENV_FILE="/etc/vpn-tools.env"
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"
SOCKS_ADDR="${SOCKS_ADDR:-127.0.0.1:40000}"
TRACE_URL="${TRACE_URL:-https://1.1.1.1/cdn-cgi/trace}"
WARP_SERVICE_NAME="${WARP_SERVICE_NAME:-warp-svc}"
XRAY_SERVICE_NAME="${XRAY_SERVICE_NAME:-x-ui}"
have_warp() { command -v warp-cli >/dev/null 2>&1; }
if have_warp; then
  trace="$(curl -s --max-time 10 --socks5-hostname "$SOCKS_ADDR" "$TRACE_URL" 2>/dev/null || true)"
  ip="$(awk -F= '$1=="ip"{print $2}' <<<"$trace")"
  colo="$(awk -F= '$1=="colo"{print $2}' <<<"$trace")"
  loc="$(awk -F= '$1=="loc"{print $2}' <<<"$trace")"
  warp="$(awk -F= '$1=="warp"{print $2}' <<<"$trace")"
else
  ip="н/д"; colo="н/д"; loc="н/д"; warp="не установлен"
fi
p="$(ping -c 3 1.1.1.1 2>/dev/null | awk -F'/' 'END{print $5}')"
up="$(uptime -p 2>/dev/null || true)"
ws="$(systemctl is-active "$WARP_SERVICE_NAME" 2>/dev/null || echo inactive)"
xs="$(systemctl is-active "$XRAY_SERVICE_NAME" 2>/dev/null || echo inactive)"
disk="$(df -h / | awk 'NR==2 {print $3 " / " $2 " (" $5 ")"}')"
mem="$(free -m | awk '/^Mem:/ {printf "%d / %d MB (%.0f%%)", $3,$2,($3/$2)*100}')"
load="$(uptime 2>/dev/null | awk -F'load average:' '{print $2}' | xargs || true)"
echo "Сервис WARP: ${ws:-н/д}"
echo "Xray/x-ui: ${xs:-н/д}"
echo "Статус WARP trace: ${warp:-неизвестно}"
echo "IP: ${ip:-н/д}"
echo "COLO: ${colo:-н/д}"
echo "LOC: ${loc:-н/д}"
echo "PING: ${p:-н/д} ms"
echo "Диск: ${disk:-н/д}"
echo "RAM: ${mem:-н/д}"
echo "Нагрузка: ${load:-н/д}"
echo "Аптайм: ${up:-н/д}"
EOF_SCRIPT
      chmod +x "$BIN_DIR/vpn-status.sh"
      ;;
    vpn-daily-report)
      cat > "$BIN_DIR/vpn-daily-report.sh" <<'EOF_SCRIPT'
#!/usr/bin/env bash
set -u -o pipefail
ENV_FILE="/etc/vpn-tools.env"
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"
BOT_TOKEN="${BOT_TOKEN:-}"
CHAT_ID="${CHAT_ID:-}"
[[ -z "$BOT_TOKEN" || -z "$CHAT_ID" ]] && exit 0
status="$(/opt/vpn-tools/bin/vpn-status.sh 2>/dev/null || true)"
curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" -d chat_id="${CHAT_ID}" --data-urlencode text="📊 Ежедневный отчёт VPN

${status}" >/dev/null 2>&1 || true
EOF_SCRIPT
      chmod +x "$BIN_DIR/vpn-daily-report.sh"
      ;;
    telegram-control-bot)
      cat > "$BIN_DIR/telegram-control-bot.py" <<'EOF_SCRIPT'
#!/usr/bin/env python3
import json, os, subprocess, time, urllib.parse, urllib.request

ENV_FILE = "/etc/vpn-tools.env"
INFO_FILE = "/var/lib/vpn-tools/mtproto_info.env"
OFFSET_FILE = "/var/lib/vpn-tools/telegram-bot-offset"
PENDING_ROTATE_FILE = "/var/lib/vpn-tools/telegram-mtproto-rotate-pending"
MTPROTO_SERVICE = "vpn-tools-mtproto-proxy.service"

def load_env_file(path):
    cfg = {}
    if os.path.exists(path):
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                cfg[k] = v.strip().strip('"')
    return cfg

def load_env():
    return load_env_file(ENV_FILE)

CFG = load_env()
BOT_TOKEN = CFG.get("BOT_TOKEN", "")
CHAT_ID = CFG.get("CHAT_ID", "")
API_BASE = "https://api.telegram.org/bot{token}/{method}"

def api(method, data=None):
    if not BOT_TOKEN:
        return {}
    url = API_BASE.format(token=BOT_TOKEN, method=method)
    if data is None:
        with urllib.request.urlopen(url, timeout=25) as r:
            return json.loads(r.read().decode())
    body = urllib.parse.urlencode(data).encode()
    with urllib.request.urlopen(url, body, timeout=25) as r:
        return json.loads(r.read().decode())

def shell(cmd):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True)

def get_offset():
    try:
        with open(OFFSET_FILE, "r", encoding="utf-8") as f:
            return int(f.read().strip() or "0")
    except Exception:
        return 0

def set_offset(v):
    os.makedirs(os.path.dirname(OFFSET_FILE), exist_ok=True)
    with open(OFFSET_FILE, "w", encoding="utf-8") as f:
        f.write(str(v))

def is_allowed(chat_id):
    return str(chat_id) == str(CHAT_ID) and str(chat_id) != ""

def current_cfg():
    return load_env()

def have_warp():
    return shell("command -v warp-cli >/dev/null 2>&1").returncode == 0

def timer_state():
    out = shell("systemctl is-enabled vpn-tools-warp-watchdog.timer").stdout.strip().splitlines()
    return out[0] if out else "not-found"

def mtproto_installed():
    return shell("test -x /opt/vpn-tools/mtproto/objs/bin/mtproto-proxy").returncode == 0

def mtproto_raw_secret():
    info = load_env_file(INFO_FILE)
    raw = info.get("MTPROTO_SECRET", "")
    if raw.startswith("dd"):
        raw = raw[2:]
    return raw

def mtproto_public_ip():
    return shell("curl -4 -fsSL --max-time 10 https://api.ipify.org 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}'").stdout.strip()

def mtproto_link():
    cfg = current_cfg()
    raw = mtproto_raw_secret()
    port = cfg.get("MTPROTO_PORT", "8443")
    ip = mtproto_public_ip()
    if len(raw) != 32 or not ip:
        return ""
    return f"tg://proxy?server={ip}&port={port}&secret=dd{raw}"

def mtproto_status_text():
    if not mtproto_installed():
        return "MTProto\n\nПрокси не установлен."
    cfg = current_cfg()
    port = cfg.get("MTPROTO_PORT", "8443")
    reserve = cfg.get("MTPROTO_RESERVE_PORT", "9443")
    svc = shell(f"systemctl is-active {MTPROTO_SERVICE}").stdout.strip() or "inactive"
    local_open = shell(f"timeout 3 bash -c '</dev/tcp/127.0.0.1/{port}' >/dev/null 2>&1").returncode == 0
    link = mtproto_link()
    return (
        "MTProto\n\n"
        f"Сервис: {svc}\n"
        f"Основной порт: {port}\n"
        f"Резервный порт: {reserve}\n"
        f"Локальная проверка: {'OPEN' if local_open else 'CLOSED'}\n"
        f"Ссылка: {'готова' if link else 'недоступна'}"
    )

def warp_status_text():
    if have_warp():
        cfg = current_cfg()
        svc = shell(f"systemctl is-active {cfg.get('WARP_SERVICE_NAME', 'warp-svc')}").stdout.strip() or "inactive"
        cli_lines = shell("warp-cli status").stdout.strip().splitlines()
        cli = cli_lines[0] if cli_lines else "н/д"
        trace = shell(
            f"curl -s --max-time 10 --socks5-hostname {cfg.get('SOCKS_ADDR', '127.0.0.1:40000')} "
            f"{cfg.get('TRACE_URL', 'https://1.1.1.1/cdn-cgi/trace')}"
        ).stdout
        warp = "off"
        ip = colo = loc = "н/д"
        for line in trace.splitlines():
            if line.startswith("warp="):
                warp = line.split("=", 1)[1]
            elif line.startswith("ip="):
                ip = line.split("=", 1)[1]
            elif line.startswith("colo="):
                colo = line.split("=", 1)[1]
            elif line.startswith("loc="):
                loc = line.split("=", 1)[1]
    else:
        svc = "не установлен"
        cli = "не установлен"
        warp = "не установлен"
        ip = colo = loc = "н/д"

    rec = timer_state()
    mtp = mtproto_status_text()
    return (
        "WARP управление\n\n"
        f"Сервис WARP: {svc}\n"
        f"warp-cli: {cli}\n"
        f"WARP egress: {warp}\n"
        f"Автовосстановление WARP: {rec}\n"
        f"IP: {ip}\n"
        f"COLO: {colo}\n"
        f"LOC: {loc}\n\n"
        f"{mtp}"
    )

def pending_rotate():
    if not os.path.exists(PENDING_ROTATE_FILE):
        return False
    try:
        ts = float(open(PENDING_ROTATE_FILE, "r", encoding="utf-8").read().strip() or "0")
        return (time.time() - ts) <= 45
    except Exception:
        return False

def set_pending_rotate():
    os.makedirs(os.path.dirname(PENDING_ROTATE_FILE), exist_ok=True)
    with open(PENDING_ROTATE_FILE, "w", encoding="utf-8") as f:
        f.write(str(time.time()))

def clear_pending_rotate():
    try:
        os.remove(PENDING_ROTATE_FILE)
    except FileNotFoundError:
        pass

def keyboard():
    confirm_rotate = pending_rotate()
    rotate_text = "⚠️ Подтвердить новую ссылку" if confirm_rotate else "♻️ Новая ссылка MTProto"
    return {
        "inline_keyboard": [
            [{"text": "▶️ WARP ВКЛ", "callback_data": "warp_on"}, {"text": "⏹ WARP ВЫКЛ", "callback_data": "warp_off"}],
            [{"text": "🛡️ WARP авто ВКЛ", "callback_data": "rec_on"}, {"text": "🛑 WARP авто ВЫКЛ", "callback_data": "rec_off"}],
            [{"text": "🔗 Ссылка MTProto", "callback_data": "mtproto_link"}, {"text": rotate_text, "callback_data": "mtproto_rotate"}],
            [{"text": "📡 Статус MTProto", "callback_data": "mtproto_status"}, {"text": "⚙️ Порты MTProto", "callback_data": "mtproto_ports"}],
            [{"text": "🩺 Починить MTProto", "callback_data": "mtproto_fix"}, {"text": "📊 Общий статус", "callback_data": "status"}],
            [{"text": "🔄 Обновить", "callback_data": "refresh"}],
        ]
    }

def send_menu(chat_id):
    api("sendMessage", {
        "chat_id": str(chat_id),
        "text": warp_status_text(),
        "reply_markup": json.dumps(keyboard(), ensure_ascii=False)
    })

def edit_menu(chat_id, msg_id):
    api("editMessageText", {
        "chat_id": str(chat_id),
        "message_id": str(msg_id),
        "text": warp_status_text(),
        "reply_markup": json.dumps(keyboard(), ensure_ascii=False)
    })

def answer_cb(cb_id, text="OK"):
    api("answerCallbackQuery", {"callback_query_id": cb_id, "text": text})

def send_mtproto_link(chat_id):
    if not mtproto_installed():
        return "MTProto не установлен"
    link = mtproto_link()
    if not link:
        return "Не удалось собрать ссылку"
    api("sendMessage", {"chat_id": str(chat_id), "text": f"🔗 Актуальная ссылка MTProto:\n\n{link}"})
    return "Ссылка MTProto отправлена"

def rotate_mtproto_secret(chat_id):
    if not mtproto_installed():
        return "MTProto не установлен"
    if not pending_rotate():
        set_pending_rotate()
        return "Нажми ещё раз в течение 45 секунд для подтверждения"
    clear_pending_rotate()
    raw = shell("openssl rand -hex 16").stdout.strip()
    if len(raw) != 32:
        return "Не удалось сгенерировать secret"
    os.makedirs(os.path.dirname(INFO_FILE), exist_ok=True)
    with open(INFO_FILE, "w", encoding="utf-8") as f:
        f.write(f'MTPROTO_SECRET="{raw}"\n')
    shell("systemctl daemon-reload")
    shell(f"systemctl restart {MTPROTO_SERVICE}")
    time.sleep(3)
    ok = shell(f"systemctl is-active {MTPROTO_SERVICE}").stdout.strip() == "active"
    port = current_cfg().get("MTPROTO_PORT", "8443")
    local_open = shell(f"timeout 3 bash -c '</dev/tcp/127.0.0.1/{port}' >/dev/null 2>&1").returncode == 0
    if ok and local_open:
        link = mtproto_link()
        if link:
            api("sendMessage", {"chat_id": str(chat_id), "text": f"♻️ MTProto secret пересоздан.\n\nНовая ссылка:\n{link}"})
        return "Новая ссылка MTProto отправлена"
    return "Сервис не подтвердил работу"

def send_mtproto_status(chat_id):
    api("sendMessage", {"chat_id": str(chat_id), "text": f"📡 Статус MTProto\n\n{mtproto_status_text()}"})
    return "Статус MTProto отправлен"

def fix_mtproto(chat_id):
    if not mtproto_installed():
        return "MTProto не установлен"
    shell(f"systemctl unmask {MTPROTO_SERVICE} >/dev/null 2>&1 || true")
    shell("systemctl daemon-reload")
    shell(f"systemctl restart {MTPROTO_SERVICE}")
    time.sleep(3)
    cfg = current_cfg()
    port = cfg.get("MTPROTO_PORT", "8443")
    ok = shell(f"systemctl is-active {MTPROTO_SERVICE}").stdout.strip() == "active"
    local_open = shell(f"timeout 3 bash -c '</dev/tcp/127.0.0.1/{port}' >/dev/null 2>&1").returncode == 0
    if not (ok and local_open):
        shell("curl -fsSL https://core.telegram.org/getProxySecret -o /opt/vpn-tools/mtproto/proxy-secret >/dev/null 2>&1 || true")
        shell("curl -fsSL https://core.telegram.org/getProxyConfig -o /opt/vpn-tools/mtproto/proxy-multi.conf >/dev/null 2>&1 || true")
        shell(f"systemctl restart {MTPROTO_SERVICE}")
        time.sleep(4)
        ok = shell(f"systemctl is-active {MTPROTO_SERVICE}").stdout.strip() == "active"
        local_open = shell(f"timeout 3 bash -c '</dev/tcp/127.0.0.1/{port}' >/dev/null 2>&1").returncode == 0
    if ok and local_open:
        link = mtproto_link()
        msg = "🩺 MTProto восстановлен."
        if link:
            msg += f"\n\nАктуальная ссылка:\n{link}"
        api("sendMessage", {"chat_id": str(chat_id), "text": msg})
        return "MTProto восстановлен"
    return "Не удалось восстановить MTProto"

def do_action(action, chat_id=None):
    if action == "warp_on":
        if not have_warp():
            return "WARP не установлен"
        cfg = current_cfg()
        shell(f"systemctl start {cfg.get('WARP_SERVICE_NAME', 'warp-svc')}")
        time.sleep(2)
        shell("warp-cli connect")
        return "WARP включён"
    if action == "warp_off":
        if not have_warp():
            return "WARP не установлен"
        cfg = current_cfg()
        shell("warp-cli disconnect")
        shell(f"systemctl stop {cfg.get('WARP_SERVICE_NAME', 'warp-svc')}")
        return "WARP выключен"
    if action == "rec_on":
        shell("systemctl enable --now vpn-tools-warp-watchdog.timer")
        return "Автовосстановление WARP включено"
    if action == "rec_off":
        shell("systemctl disable --now vpn-tools-warp-watchdog.timer")
        return "Автовосстановление WARP выключено"
    if action == "mtproto_link":
        return send_mtproto_link(chat_id)
    if action == "mtproto_rotate":
        return rotate_mtproto_secret(chat_id)
    if action == "mtproto_status":
        return send_mtproto_status(chat_id)
    if action == "mtproto_ports":
        return mtproto_ports_help(chat_id)
    if action == "mtproto_fix":
        return fix_mtproto(chat_id)
    if action == "status":
        api("sendMessage", {"chat_id": str(chat_id), "text": f"📊 Общий статус\n\n{warp_status_text()}"})
        return "Общий статус отправлен"
    return "Обновлено"

def main():
    while True:
        try:
            offset = get_offset()
            res = api("getUpdates", {"timeout": "25", "offset": str(offset + 1)})
            for item in res.get("result", []):
                upd_id = item["update_id"]
                set_offset(upd_id)
                if "message" in item:
                    msg = item["message"]
                    chat_id = msg["chat"]["id"]
                    text = (msg.get("text") or "").strip()
                    if not is_allowed(chat_id):
                        continue
                    if text in ("/start", "/menu", "/warp", "/status", "/proxy", "/mtproto"):
                        send_menu(chat_id)
                        if text == "/start":
                            link = mtproto_link()
                            if link:
                                api("sendMessage", {"chat_id": str(chat_id), "text": f"🔗 Текущая ссылка MTProto:\n\n{link}"})
                elif "callback_query" in item:
                    cb = item["callback_query"]
                    chat_id = cb["message"]["chat"]["id"]
                    if not is_allowed(chat_id):
                        continue
                    answer_cb(cb["id"], do_action(cb.get("data", ""), chat_id))
                    edit_menu(chat_id, cb["message"]["message_id"])
        except Exception:
            time.sleep(5)

if __name__ == "__main__":
    main()
EOF_SCRIPT
      chmod +x "$BIN_DIR/telegram-control-bot.py"
      ;;
    mtproto-proxy)
      cat > "$BIN_DIR/mtproto-proxy.sh" <<'EOF_SCRIPT'
#!/usr/bin/env bash
set -u -o pipefail
ENV_FILE="/etc/vpn-tools.env"
INFO_FILE="/var/lib/vpn-tools/mtproto_info.env"
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"
[[ -f "$INFO_FILE" ]] && source "$INFO_FILE"
IP="$(curl -4 -fsSL --max-time 10 https://api.ipify.org 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}')"
echo "MTProto Proxy helper"
echo "Сервис: vpn-tools-mtproto-proxy.service"
echo "IP: ${IP:-н/д}"
echo "PORT: ${MTPROTO_PORT:-8443}"
echo "RESERVE_PORT: ${MTPROTO_RESERVE_PORT:-9443}"
if [[ -n "${MTPROTO_SECRET:-}" ]]; then
  echo "tg://proxy?server=${IP}&port=${MTPROTO_PORT:-8443}&secret=dd${MTPROTO_SECRET#dd}"
else
  echo "Секрет ещё не сгенерирован."
fi
EOF_SCRIPT
      chmod +x "$BIN_DIR/mtproto-proxy.sh"
      ;;
    mtproto-watchdog)
      cat > "$BIN_DIR/mtproto-watchdog.sh" <<'EOF_SCRIPT'
#!/usr/bin/env bash
set -u -o pipefail
ENV_FILE="/etc/vpn-tools.env"
LOG_FILE="/var/log/vpn-tools/mtproto-watchdog.log"
STATE_FILE="/var/lib/vpn-tools/mtproto_watchdog_state"
STATS_FILE="/var/lib/vpn-tools/mtproto_stats.env"
HISTORY_FILE="/var/lib/vpn-tools/mtproto_history.log"
LOCK_FILE="/run/vpn-tools/mtproto-watchdog.lock"
SERVICE="vpn-tools-mtproto-proxy.service"
mkdir -p /var/log/vpn-tools /var/lib/vpn-tools /run/vpn-tools
[[ -f "$STATS_FILE" ]] || cat > "$STATS_FILE" <<'EOF_STATS'
AUTOREPAIR_COUNT="0"
FAILOVER_COUNT="0"
DAILY_CHECK_COUNT="0"
LAST_AUTOREPAIR_AT=""
LAST_FAILOVER_AT=""
LAST_FAIL_REASON=""
EOF_STATS
[[ -f "$HISTORY_FILE" ]] || : > "$HISTORY_FILE"
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"
BOT_TOKEN="${BOT_TOKEN:-}"
CHAT_ID="${CHAT_ID:-}"
MTPROTO_PORT="${MTPROTO_PORT:-8443}"
MTPROTO_RESERVE_PORT="${MTPROTO_RESERVE_PORT:-9443}"
send_tg() {
  local text="$1"
  [[ -z "$BOT_TOKEN" || -z "$CHAT_ID" ]] && return 0
  curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" -d chat_id="${CHAT_ID}" --data-urlencode text="${text}" >/dev/null 2>&1 || true
}
log_msg() { echo "$(date '+%F %T') - $*" >> "$LOG_FILE"; }
bump_stat() {
  local key="$1" current=0 tmp
  current="$(awk -F= -v k="$key" '$1==k{gsub(/^"|"$/, "", $2); print $2}' "$STATS_FILE" 2>/dev/null || true)"
  [[ "$current" =~ ^[0-9]+$ ]] || current=0
  tmp="$(mktemp)"
  awk -F= -v k="$key" -v v="$((current + 1))" '
    BEGIN{done=0}
    $1==k {printf "%s=\"%s\"\n", k, v; done=1; next}
    {print}
    END{if(!done) printf "%s=\"%s\"\n", k, v}
  ' "$STATS_FILE" > "$tmp" && mv "$tmp" "$STATS_FILE"
}
update_stat() {
  local key="$1" value="$2" tmp
  tmp="$(mktemp)"
  awk -F= -v k="$key" -v v="$value" '
    BEGIN{done=0}
    $1==k {printf "%s=\"%s\"\n", k, v; done=1; next}
    {print}
    END{if(!done) printf "%s=\"%s\"\n", k, v}
  ' "$STATS_FILE" > "$tmp" && mv "$tmp" "$STATS_FILE"
}
record_history() {
  printf "%s | %s | %s\n" "$(date '+%F %T')" "$1" "${2:-}" >> "$HISTORY_FILE"
}
public_ip() {
  curl -4 -fsSL --max-time 10 https://api.ipify.org 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}'
}
client_secret() {
  local raw=""
  [[ -f /var/lib/vpn-tools/mtproto_info.env ]] && raw="$(awk -F= '$1=="MTPROTO_SECRET"{gsub(/^"|"$/, "", $2); print $2}' /var/lib/vpn-tools/mtproto_info.env 2>/dev/null || true)"
  raw="${raw#dd}"
  [[ -n "$raw" ]] && echo "dd${raw}" || true
}
proxy_link() {
  local ip secret
  ip="$(public_ip)"
  secret="$(client_secret)"
  [[ -n "$ip" && -n "$secret" ]] && echo "tg://proxy?server=${ip}&port=${MTPROTO_PORT}&secret=${secret}" || true
}
port_open() {
  local port="$1"
  timeout 3 bash -c "</dev/tcp/127.0.0.1/${port}" >/dev/null 2>&1
}
check_ok() {
  systemctl is-active --quiet "$SERVICE" || return 1
  port_open "$MTPROTO_PORT" || return 1
  return 0
}
open_ufw_port() {
  local port="$1"
  command -v ufw >/dev/null 2>&1 || return 0
  ufw status 2>/dev/null | grep -q '^Status: active' || return 0
  ufw status numbered 2>/dev/null | grep -qE "${port}/tcp" && return 0
  ufw allow "${port}/tcp" >/dev/null 2>&1 || true
}
swap_ports_in_env() {
  local current="$1" reserve="$2" tmp
  tmp="$(mktemp)"
  awk -F= -v cur="$current" -v res="$reserve" '
    BEGIN{done1=0;done2=0}
    $1=="MTPROTO_PORT" {printf "MTPROTO_PORT=\"%s\"\n", res; done1=1; next}
    $1=="MTPROTO_RESERVE_PORT" {printf "MTPROTO_RESERVE_PORT=\"%s\"\n", cur; done2=1; next}
    {print}
    END {
      if (!done1) printf "MTPROTO_PORT=\"%s\"\n", res
      if (!done2) printf "MTPROTO_RESERVE_PORT=\"%s\"\n", cur
    }
  ' "$ENV_FILE" > "$tmp" && mv "$tmp" "$ENV_FILE"
  chmod 600 "$ENV_FILE" >/dev/null 2>&1 || true
}
rebuild_and_restart() {
  systemctl unmask "$SERVICE" >/dev/null 2>&1 || true
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl restart "$SERVICE" >/dev/null 2>&1 || true
}
try_failover() {
  [[ -z "$MTPROTO_RESERVE_PORT" || "$MTPROTO_RESERVE_PORT" == "$MTPROTO_PORT" ]] && return 1
  if ss -lntp 2>/dev/null | awk -v p=":${MTPROTO_RESERVE_PORT}" '$4 ~ p && $0 !~ /mtproto-proxy/ {found=1} END{exit !found}'; then
    log_msg "Резервный порт ${MTPROTO_RESERVE_PORT} занят другим сервисом"
    record_history "failover-skip" "reserve port ${MTPROTO_RESERVE_PORT} busy"
    return 1
  fi
  local old_port="$MTPROTO_PORT"
  open_ufw_port "$MTPROTO_RESERVE_PORT"
  swap_ports_in_env "$MTPROTO_PORT" "$MTPROTO_RESERVE_PORT"
  source "$ENV_FILE"
  rebuild_and_restart
  sleep 5
  if check_ok; then
    local link
    link="$(proxy_link)"
    log_msg "MTProto переключён на резервный порт ${MTPROTO_PORT}"
    bump_stat "FAILOVER_COUNT"
    update_stat "LAST_FAILOVER_AT" "$(date '+%F %T')"
    record_history "failover" "new port ${MTPROTO_PORT}, old port ${old_port}"
    if [[ -n "$link" ]]; then
      send_tg "🔁 MTProto автоматически переключён на резервный порт ${MTPROTO_PORT}. Старый порт сохранён как резервный.

Новая ссылка:
${link}"
    else
      send_tg "🔁 MTProto автоматически переключён на резервный порт ${MTPROTO_PORT}. Старый порт сохранён как резервный."
    fi
    return 0
  fi
  return 1
}
repair() {
  bump_stat "AUTOREPAIR_COUNT"
  update_stat "LAST_AUTOREPAIR_AT" "$(date '+%F %T')"
  record_history "autorepair-start" "port ${MTPROTO_PORT}"
  rebuild_and_restart
  sleep 5
  check_ok && return 0
  curl -fsSL https://core.telegram.org/getProxySecret -o /opt/vpn-tools/mtproto/proxy-secret >/dev/null 2>&1 || true
  curl -fsSL https://core.telegram.org/getProxyConfig -o /opt/vpn-tools/mtproto/proxy-multi.conf >/dev/null 2>&1 || true
  rebuild_and_restart
  sleep 5
  check_ok && return 0
  try_failover
}
exec 9>"$LOCK_FILE"
flock -n 9 || exit 0
last="OK"
[[ -f "$STATE_FILE" ]] && last="$(cat "$STATE_FILE")"
if check_ok; then
  echo "OK" > "$STATE_FILE"
  log_msg "OK"
  exit 0
fi
reason="service_or_port_check_failed on ${MTPROTO_PORT}"
log_msg "MTProto FAIL on port ${MTPROTO_PORT}"
update_stat "LAST_FAIL_REASON" "$reason"
record_history "fail" "$reason"
[[ "$last" == "OK" ]] && send_tg "⚠️ MTProto Proxy недоступен на порту ${MTPROTO_PORT}. Пытаюсь восстановить..."
if repair; then
  link="$(proxy_link)"
  echo "OK" > "$STATE_FILE"
  log_msg "MTProto восстановлен"
  record_history "autorepair-ok" "current port ${MTPROTO_PORT}"
  if [[ -n "$link" ]]; then
    send_tg "✅ MTProto Proxy восстановлен автоматически. Текущий порт: ${MTPROTO_PORT}

Текущая ссылка:
${link}"
  else
    send_tg "✅ MTProto Proxy восстановлен автоматически. Текущий порт: ${MTPROTO_PORT}"
  fi
  exit 0
fi
echo "FAIL" > "$STATE_FILE"
log_msg "MTProto не удалось восстановить"
record_history "autorepair-fail" "current port ${MTPROTO_PORT}"
[[ "$last" == "OK" ]] && send_tg "❌ MTProto Proxy не удалось восстановить автоматически. Нужна ручная проверка."
exit 1
EOF_SCRIPT
      chmod +x "$BIN_DIR/mtproto-watchdog.sh"
      ;;
    mtproto-daily-check)
      cat > "$BIN_DIR/mtproto-daily-check.sh" <<'EOF_SCRIPT'
#!/usr/bin/env bash
set -u -o pipefail
ENV_FILE="/etc/vpn-tools.env"
LOG_FILE="/var/log/vpn-tools/mtproto-daily.log"
SERVICE="vpn-tools-mtproto-proxy.service"
WATCHDOG="/opt/vpn-tools/bin/mtproto-watchdog.sh"
STATS_FILE="/var/lib/vpn-tools/mtproto_stats.env"
HISTORY_FILE="/var/lib/vpn-tools/mtproto_history.log"
mkdir -p /var/log/vpn-tools /var/lib/vpn-tools /run/vpn-tools
[[ -f "$STATS_FILE" ]] || cat > "$STATS_FILE" <<'EOF_STATS'
AUTOREPAIR_COUNT="0"
FAILOVER_COUNT="0"
DAILY_CHECK_COUNT="0"
LAST_AUTOREPAIR_AT=""
LAST_FAILOVER_AT=""
LAST_FAIL_REASON=""
EOF_STATS
[[ -f "$HISTORY_FILE" ]] || : > "$HISTORY_FILE"
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"
BOT_TOKEN="${BOT_TOKEN:-}"
CHAT_ID="${CHAT_ID:-}"
MTPROTO_PORT="${MTPROTO_PORT:-8443}"
MTPROTO_RESERVE_PORT="${MTPROTO_RESERVE_PORT:-9443}"
MTPROTO_STATS_PORT="${MTPROTO_STATS_PORT:-8888}"
send_tg() {
  local text="$1"
  [[ -z "$BOT_TOKEN" || -z "$CHAT_ID" ]] && return 0
  curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" -d chat_id="${CHAT_ID}" --data-urlencode text="${text}" >/dev/null 2>&1 || true
}
log_msg() { echo "$(date '+%F %T') - $*" >> "$LOG_FILE"; }
bump_stat() {
  local key="$1" current=0 tmp
  current="$(awk -F= -v k="$key" '$1==k{gsub(/^"|"$/, "", $2); print $2}' "$STATS_FILE" 2>/dev/null || true)"
  [[ "$current" =~ ^[0-9]+$ ]] || current=0
  tmp="$(mktemp)"
  awk -F= -v k="$key" -v v="$((current + 1))" '
    BEGIN{done=0}
    $1==k {printf "%s=\"%s\"\n", k, v; done=1; next}
    {print}
    END{if(!done) printf "%s=\"%s\"\n", k, v}
  ' "$STATS_FILE" > "$tmp" && mv "$tmp" "$STATS_FILE"
}
record_history() {
  printf "%s | %s | %s\n" "$(date '+%F %T')" "$1" "${2:-}" >> "$HISTORY_FILE"
}
port_open() {
  local port="$1"
  timeout 3 bash -c "</dev/tcp/127.0.0.1/${port}" >/dev/null 2>&1
}
public_ip() {
  curl -4 -fsSL --max-time 10 https://api.ipify.org 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}'
}
client_secret() {
  local raw=""
  [[ -f /var/lib/vpn-tools/mtproto_info.env ]] && raw="$(awk -F= '$1=="MTPROTO_SECRET"{gsub(/^"|"$/, "", $2); print $2}' /var/lib/vpn-tools/mtproto_info.env 2>/dev/null || true)"
  raw="${raw#dd}"
  [[ -n "$raw" ]] && echo "dd${raw}" || true
}
proxy_link() {
  local ip secret
  ip="$(public_ip)"
  secret="$(client_secret)"
  [[ -n "$ip" && -n "$secret" ]] && echo "tg://proxy?server=${ip}&port=${MTPROTO_PORT}&secret=${secret}" || true
}
public_port_ok() {
  local ip
  ip="$(public_ip)"
  [[ -z "$ip" ]] && return 1
  timeout 4 bash -c "</dev/tcp/${ip}/${MTPROTO_PORT}" >/dev/null 2>&1
}
open_ufw_port() {
  local port="$1"
  command -v ufw >/dev/null 2>&1 || return 0
  ufw status 2>/dev/null | grep -q '^Status: active' || return 0
  ufw status numbered 2>/dev/null | grep -qE "${port}/tcp" && return 0
  ufw allow "${port}/tcp" >/dev/null 2>&1 || true
}
summary() {
  local unit_state local_state public_state pidmax reserve stats
  unit_state="$(systemctl is-active "$SERVICE" 2>/dev/null || echo inactive)"
  port_open "$MTPROTO_PORT" && local_state="OPEN" || local_state="CLOSED"
  public_port_ok && public_state="OPEN" || public_state="WARN"
  pidmax="$(cat /proc/sys/kernel/pid_max 2>/dev/null || echo n/a)"
  stats="${MTPROTO_STATS_PORT}"
  reserve="${MTPROTO_RESERVE_PORT}"
  printf 'service=%s local=%s public=%s port=%s reserve=%s stats=%s pid_max=%s' "$unit_state" "$local_state" "$public_state" "$MTPROTO_PORT" "$reserve" "$stats" "$pidmax"
}
[[ -x "$WATCHDOG" ]] || { log_msg "daily-check: mtproto-watchdog.sh не найден"; exit 0; }
open_ufw_port "$MTPROTO_PORT"
[[ -n "$MTPROTO_RESERVE_PORT" ]] && open_ufw_port "$MTPROTO_RESERVE_PORT"
bump_stat "DAILY_CHECK_COUNT"
record_history "daily-check" "start ${MTPROTO_PORT}"
pre="$(summary)"
if systemctl is-active --quiet "$SERVICE" && port_open "$MTPROTO_PORT"; then
  if public_port_ok; then
    log_msg "daily-check OK: ${pre}"
    record_history "daily-check-ok" "${pre}"
    exit 0
  fi
  log_msg "daily-check warning: внешний доступ не подтверждён, запускаю мягкое восстановление: ${pre}"
  record_history "daily-check-warn" "${pre}"
else
  log_msg "daily-check repair: найдено отклонение, запускаю восстановление: ${pre}"
  record_history "daily-check-repair" "${pre}"
fi
"$WATCHDOG" >/dev/null 2>&1 || true
sleep 5
post="$(summary)"
link="$(proxy_link)"
if systemctl is-active --quiet "$SERVICE" && port_open "$MTPROTO_PORT"; then
  log_msg "daily-check repaired: ${post}"
  record_history "daily-check-repaired" "${post}"
  if [[ -n "$link" ]]; then
    send_tg "🛠 Профилактическая проверка MTProto завершена. Сервис подтверждён на порту ${MTPROTO_PORT}.

Актуальная ссылка:
${link}"
  else
    send_tg "🛠 Профилактическая проверка MTProto завершена. Сервис подтверждён на порту ${MTPROTO_PORT}."
  fi
  exit 0
fi
log_msg "daily-check failed: ${post}"
record_history "daily-check-fail" "${post}"
send_tg "❌ Профилактическая проверка MTProto не смогла подтвердить работу прокси. Нужна ручная проверка.

Текущее состояние: ${post}"
exit 1
EOF_SCRIPT
      chmod +x "$BIN_DIR/mtproto-daily-check.sh"
      ;;
    logrotate)
      cat > /etc/logrotate.d/vpn-tools <<'EOF_SCRIPT'
/var/log/vpn-tools/*.log
{
    daily
    rotate 7
    compress
    missingok
    notifempty
    copytruncate
}
EOF_SCRIPT
      ;;
    *)
      echo "Неизвестный компонент: $comp"
      return 1
      ;;
  esac
}

write_systemd_unit() {
  local comp="$1"
  local service="/etc/systemd/system/$(service_name_for "$comp")"
  local timer="/etc/systemd/system/$(timer_name_for "$comp")"
  if [[ "$comp" == "$MTPROTO_COMP" ]]; then
    local secret workers
    secret="$(mtproto_secret_value)"
    workers="1"
    cat > "$service" <<EOF_SVC
[Unit]
Description=VPN-инструменты - MTProto Proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$MTPROTO_DIR
ExecStartPre=/usr/bin/curl -fsSL https://core.telegram.org/getProxySecret -o $MTPROTO_DIR/proxy-secret
ExecStartPre=/usr/bin/curl -fsSL https://core.telegram.org/getProxyConfig -o $MTPROTO_DIR/proxy-multi.conf
ExecStart=$MTPROTO_DIR/objs/bin/mtproto-proxy -u nobody -p 127.0.0.1:${MTPROTO_STATS_PORT} -H ${MTPROTO_PORT} -S ${secret} --aes-pwd $MTPROTO_DIR/proxy-secret $MTPROTO_DIR/proxy-multi.conf -M ${workers}
Restart=always
RestartSec=5
User=root
Group=root
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF_SVC
    rm -f "$timer"
    return 0
  fi
  if [[ "$comp" == "$TG_CONTROL_COMP" ]]; then
    cat > "$service" <<EOF_SVC
[Unit]
Description=VPN-инструменты - Telegram control bot
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 $BIN_DIR/telegram-control-bot.py
Restart=always
RestartSec=5
User=root
Group=root

[Install]
WantedBy=multi-user.target
EOF_SVC
    rm -f "$timer"
    return 0
  fi
  if [[ "$comp" == "$SOCKS5_COMP" ]]; then
    cat > "$service" <<EOF_SVC
[Unit]
Description=VPN-инструменты - Proxy service (3proxy)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=/usr/bin/test -x $SOCKS5_BIN
ExecStartPre=/usr/bin/test -f $SOCKS5_CFG_FILE
ExecStart=$SOCKS5_BIN $SOCKS5_CFG_FILE
Restart=always
RestartSec=5
User=root
Group=root
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF_SVC
    rm -f "$timer"
    return 0
  fi

  cat > "$service" <<EOF_SVC
[Unit]
Description=VPN-инструменты - $comp
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$BIN_DIR/$comp.sh
User=root
Group=root
EOF_SVC

  case "$comp" in
    "$MTPROTO_DAILY_COMP")
      cat > "$timer" <<EOF_T
[Unit]
Description=Профилактическая ежедневная проверка MTProto

[Timer]
OnCalendar=*-*-* 04:30:00
Persistent=true
Unit=$(service_name_for "$comp")

[Install]
WantedBy=timers.target
EOF_T
      ;;
    "$OPTIMIZE_COMP")
      cat > "$timer" <<EOF_T
[Unit]
Description=Запуск $comp ежедневно

[Timer]
OnCalendar=*-*-* 05:00:00
Persistent=true
Unit=$(service_name_for "$comp")

[Install]
WantedBy=timers.target
EOF_T
      ;;
    "$WARP_WATCHDOG_COMP"|"$XRAY_WATCHDOG_COMP"|"$MTPROTO_WATCHDOG_COMP")
      cat > "$timer" <<EOF_T
[Unit]
Description=Запуск $comp каждую минуту

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
AccuracySec=10s
Persistent=true
Unit=$(service_name_for "$comp")

[Install]
WantedBy=timers.target
EOF_T
      ;;
    "$DAILY_COMP")
      load_env
      local hh mm
      hh=$(printf '%02d' "$DAILY_REPORT_HOUR")
      mm=$(printf '%02d' "$DAILY_REPORT_MINUTE")
      cat > "$timer" <<EOF_T
[Unit]
Description=Ежедневный отчёт VPN

[Timer]
OnCalendar=*-*-* ${hh}:${mm}:00
Persistent=true
Unit=$(service_name_for "$comp")

[Install]
WantedBy=timers.target
EOF_T
      ;;
    *)
      rm -f "$timer"
      ;;
  esac
}

install_component() {
  local comp="$1"
  ensure_dirs
  ensure_prereqs
  load_env
  if [[ "$comp" == "$MTPROTO_COMP" ]]; then
    install_mtproto
    return $?
  fi
  if [[ "$comp" == "$SOCKS5_COMP" ]]; then
    install_socks5_proxy
    return $?
  fi
  if [[ "$comp" == "$WARP_WATCHDOG_COMP" || "$comp" == "$DAILY_COMP" || "$comp" == "$TG_CONTROL_COMP" ]]; then
    if [[ -z "$BOT_TOKEN" || -z "$CHAT_ID" ]]; then
      echo -e "${C_YELLOW}Для '$comp' нужны BOT_TOKEN и Chat ID.${C_RESET}"
      return 1
    fi
  fi
  if [[ "$comp" == "$WARP_WATCHDOG_COMP" || "$comp" == "$OPTIMIZE_COMP" ]]; then
    if ! have_warp; then
      echo -e "${C_YELLOW}WARP не установлен. Компонент '$comp' можно поставить позже.${C_RESET}"
      return 1
    fi
  fi
  write_component_script "$comp"
  if [[ "$comp" != "$LOGROTATE_COMP" ]]; then
    write_systemd_unit "$comp"
    systemd_reload
    case "$comp" in
      "$WARP_WATCHDOG_COMP"|"$XRAY_WATCHDOG_COMP"|"$DAILY_COMP"|"$OPTIMIZE_COMP"|"$MTPROTO_DAILY_COMP")
        run_cmd systemctl enable --now "$(timer_name_for "$comp")"
        ;;
      "$TG_CONTROL_COMP")
        run_cmd systemctl enable --now "$(service_name_for "$comp")"
        ;;
    esac
  fi
  echo -e "${C_GREEN}Компонент '$comp' установлен.${C_RESET}"
}

remove_systemd_unit() {
  local comp="$1"
  run_cmd systemctl disable --now "$(timer_name_for "$comp")"
  run_cmd systemctl disable --now "$(service_name_for "$comp")"
  rm -f "/etc/systemd/system/$(service_name_for "$comp")" "/etc/systemd/system/$(timer_name_for "$comp")"
  systemd_reload
}

remove_component() {
  local comp="$1"
  case "$comp" in
    "$LOGROTATE_COMP")
      rm -f /etc/logrotate.d/vpn-tools
      ;;
    "$TG_CONTROL_COMP")
      remove_systemd_unit "$comp"
      rm -f "$BIN_DIR/telegram-control-bot.py"
      ;;
    "$MTPROTO_COMP")
      remove_systemd_unit "$comp"
      rm -rf "$MTPROTO_DIR"
      rm -f "$BIN_DIR/mtproto-proxy.sh" "$MTPROTO_INFO_FILE"
      ;;
    "$SOCKS5_COMP")
      remove_systemd_unit "$comp"
      rm -f "$SOCKS5_CFG_FILE"
      ;;
    *)
      remove_systemd_unit "$comp"
      rm -f "$BIN_DIR/$comp.sh"
      ;;
  esac
  echo -e "${C_GREEN}Компонент '$comp' удалён.${C_RESET}"
}

start_component() {
  local comp="$1"
  case "$comp" in
    "$LOGROTATE_COMP")
      echo "Для logrotate запуск вручную не требуется."
      ;;
    "$STATUS_COMP")
      [[ -x "$BIN_DIR/$STATUS_COMP.sh" ]] && "$BIN_DIR/$STATUS_COMP.sh" || echo "vpn-status не установлен."
      ;;
    "$TG_CONTROL_COMP")
      run_cmd systemctl enable --now "$(service_name_for "$comp")"
      echo "Telegram-бот запущен."
      ;;
    "$MTPROTO_COMP")
      run_cmd systemctl enable --now "$(service_name_for "$comp")"
      echo "MTProto Proxy запущен."
      ;;
    "$SOCKS5_COMP")
      run_cmd systemctl enable --now "$(service_name_for "$comp")"
      echo "Прокси 3proxy запущен."
      ;;
    "$WARP_WATCHDOG_COMP"|"$XRAY_WATCHDOG_COMP"|"$DAILY_COMP"|"$OPTIMIZE_COMP"|"$MTPROTO_DAILY_COMP")
      run_cmd systemctl enable --now "$(timer_name_for "$comp")"
      run_cmd systemctl start "$(service_name_for "$comp")"
      echo "Компонент '$comp' запущен."
      ;;
    *)
      run_cmd systemctl start "$(service_name_for "$comp")"
      echo "Компонент '$comp' запущен."
      ;;
  esac
}

stop_component() {
  local comp="$1"
  case "$comp" in
    "$LOGROTATE_COMP"|"$STATUS_COMP")
      echo "Для '$comp' остановка не требуется."
      ;;
    "$TG_CONTROL_COMP")
      run_cmd systemctl disable --now "$(service_name_for "$comp")"
      echo "Telegram-бот остановлен."
      ;;
    "$MTPROTO_COMP")
      run_cmd systemctl stop "$(service_name_for "$comp")"
      echo "MTProto Proxy остановлен."
      ;;
    "$SOCKS5_COMP")
      run_cmd systemctl stop "$(service_name_for "$comp")"
      echo "Прокси 3proxy остановлен."
      ;;
    "$WARP_WATCHDOG_COMP"|"$XRAY_WATCHDOG_COMP"|"$DAILY_COMP"|"$OPTIMIZE_COMP"|"$MTPROTO_DAILY_COMP")
      run_cmd systemctl disable --now "$(timer_name_for "$comp")"
      run_cmd systemctl stop "$(service_name_for "$comp")"
      echo "Компонент '$comp' остановлен."
      ;;
    *)
      run_cmd systemctl stop "$(service_name_for "$comp")"
      echo "Компонент '$comp' остановлен."
      ;;
  esac
}

status_component() {
  local comp="$1"
  case "$comp" in
    "$LOGROTATE_COMP")
      [[ -f /etc/logrotate.d/vpn-tools ]] && echo "logrotate: установлен" || echo "logrotate: не установлен"
      ;;
    "$STATUS_COMP")
      [[ -x "$BIN_DIR/$STATUS_COMP.sh" ]] && "$BIN_DIR/$STATUS_COMP.sh" || echo "vpn-status не установлен"
      ;;
    "$TG_CONTROL_COMP")
      systemctl status "$(service_name_for "$comp")" --no-pager 2>/dev/null || true
      ;;
    "$MTPROTO_COMP")
      systemctl status "$(service_name_for "$comp")" --no-pager 2>/dev/null || true
      echo
      mtproto_links || true
      ;;
    "$SOCKS5_COMP")
      systemctl status "$(service_name_for "$comp")" --no-pager 2>/dev/null || true
      echo
      show_socks5_connection_info || true
      ;;
    *)
      [[ -x "$BIN_DIR/$comp.sh" ]] && echo "Скрипт: установлен" || echo "Скрипт: не установлен"
      systemctl status "$(service_name_for "$comp")" --no-pager 2>/dev/null || true
      [[ -f "/etc/systemd/system/$(timer_name_for "$comp")" ]] && systemctl status "$(timer_name_for "$comp")" --no-pager 2>/dev/null || true
      ;;
  esac
}

enable_warp_recovery() {
  if ! have_warp; then
    echo -e "${C_YELLOW}WARP не установлен.${C_RESET}"
    return 1
  fi
  if [[ ! -f "/etc/systemd/system/$(timer_name_for "$WARP_WATCHDOG_COMP")" ]]; then
    echo -e "${C_YELLOW}Сначала установи WARP watchdog.${C_RESET}"
    return 1
  fi
  run_cmd systemctl enable --now "$(timer_name_for "$WARP_WATCHDOG_COMP")"
  echo -e "${C_GREEN}Автовосстановление WARP включено.${C_RESET}"
}

disable_warp_recovery() { run_cmd systemctl disable --now "$(timer_name_for "$WARP_WATCHDOG_COMP")"; echo -e "${C_GREEN}Автовосстановление WARP выключено.${C_RESET}"; }

status_warp_recovery() {
  if [[ ! -f "/etc/systemd/system/$(timer_name_for "$WARP_WATCHDOG_COMP")" ]]; then
    echo "Автовосстановление WARP не установлено."
    return 0
  fi
  echo "== Статус автовосстановления WARP =="
  systemctl status "$(timer_name_for "$WARP_WATCHDOG_COMP")" --no-pager 2>/dev/null || true
  echo
  systemctl list-timers --all | grep "$(timer_name_for "$WARP_WATCHDOG_COMP" | sed 's/.timer//')" || true
}

enable_mtproto_recovery() {
  if [[ ! -f "/etc/systemd/system/$(timer_name_for "$MTPROTO_WATCHDOG_COMP")" ]]; then
    echo -e "${C_YELLOW}Сначала установи MTProto Proxy.${C_RESET}"
    return 1
  fi
  run_cmd systemctl enable --now "$(timer_name_for "$MTPROTO_WATCHDOG_COMP")"
  run_cmd systemctl enable --now "$(timer_name_for "$MTPROTO_DAILY_COMP")"
  echo "Автовосстановление MTProto включено."
}

disable_mtproto_recovery() { run_cmd systemctl disable --now "$(timer_name_for "$MTPROTO_WATCHDOG_COMP")"; echo "Автовосстановление MTProto выключено."; }

status_mtproto_recovery() {
  if [[ ! -f "/etc/systemd/system/$(timer_name_for "$MTPROTO_WATCHDOG_COMP")" ]]; then
    echo "Автовосстановление MTProto не установлено."
    return 0
  fi
  systemctl status "$(timer_name_for "$MTPROTO_WATCHDOG_COMP")" --no-pager 2>/dev/null || true
}

enable_mtproto_daily_check() {
  if [[ ! -f "/etc/systemd/system/$(timer_name_for "$MTPROTO_DAILY_COMP")" ]]; then
    echo -e "${C_YELLOW}Сначала установи MTProto Proxy.${C_RESET}"
    return 1
  fi
  run_cmd systemctl enable --now "$(timer_name_for "$MTPROTO_DAILY_COMP")"
  echo "Профилактическая ежедневная проверка MTProto включена."
}

disable_mtproto_daily_check() { run_cmd systemctl disable --now "$(timer_name_for "$MTPROTO_DAILY_COMP")"; echo "Профилактическая ежедневная проверка MTProto выключена."; }

status_mtproto_daily_check() {
  if [[ ! -f "/etc/systemd/system/$(timer_name_for "$MTPROTO_DAILY_COMP")" ]]; then
    echo "Профилактическая ежедневная проверка MTProto не установлена."
    return 0
  fi
  systemctl status "$(timer_name_for "$MTPROTO_DAILY_COMP")" --no-pager 2>/dev/null || true
}

enable_xray_recovery() {
  if [[ ! -f "/etc/systemd/system/$(timer_name_for "$XRAY_WATCHDOG_COMP")" ]]; then
    echo -e "${C_YELLOW}Сначала установи Xray watchdog.${C_RESET}"
    return 1
  fi
  run_cmd systemctl enable --now "$(timer_name_for "$XRAY_WATCHDOG_COMP")"
  echo "Автовосстановление Xray включено."
}

disable_xray_recovery() { run_cmd systemctl disable --now "$(timer_name_for "$XRAY_WATCHDOG_COMP")"; echo "Автовосстановление Xray выключено."; }

status_xray_recovery() {
  if [[ ! -f "/etc/systemd/system/$(timer_name_for "$XRAY_WATCHDOG_COMP")" ]]; then
    echo "Автовосстановление Xray не установлено."
    return 0
  fi
  systemctl status "$(timer_name_for "$XRAY_WATCHDOG_COMP")" --no-pager 2>/dev/null || true
}

enable_daily_report() {
  if [[ ! -f "/etc/systemd/system/$(timer_name_for "$DAILY_COMP")" ]]; then
    echo -e "${C_YELLOW}Сначала установи daily report.${C_RESET}"
    return 1
  fi
  run_cmd systemctl enable --now "$(timer_name_for "$DAILY_COMP")"
  echo "Ежедневный отчёт включён."
}

disable_daily_report() { run_cmd systemctl disable --now "$(timer_name_for "$DAILY_COMP")"; echo "Ежедневный отчёт выключен."; }

set_daily_report_time() {
  load_env
  local input
  read -r -p "Час ежедневного отчёта [${DAILY_REPORT_HOUR}]: " input || true
  DAILY_REPORT_HOUR="${input:-$DAILY_REPORT_HOUR}"
  read -r -p "Минута ежедневного отчёта [${DAILY_REPORT_MINUTE}]: " input || true
  DAILY_REPORT_MINUTE="${input:-$DAILY_REPORT_MINUTE}"
  save_env
  if [[ -f "$BIN_DIR/$DAILY_COMP.sh" ]]; then
    write_systemd_unit "$DAILY_COMP"
    systemd_reload
    run_cmd systemctl restart "$(timer_name_for "$DAILY_COMP")"
  fi
  echo "Время отчёта обновлено."
}

create_backup() {
  ensure_dirs
  local ts file
  ts="$(date +%F-%H%M%S)"
  file="$BACKUP_DIR/backup-$ts.tar.gz"
  tar -czf "$file" "$BASE_DIR" "$ENV_FILE" /etc/systemd/system/vpn-tools-* /etc/logrotate.d/vpn-tools /root/vpn_stack_manager.sh 2>/dev/null || true
  echo "Backup создан: $file"
}

list_backups() { ls -1 "$BACKUP_DIR" 2>/dev/null || true; }

restore_backup() {
  list_backups
  read -r -p "Введи имя backup-файла: " f
  [[ -z "$f" ]] && return 1
  tar -xzf "$BACKUP_DIR/$f" -C / 2>/dev/null || { echo "Не удалось восстановить backup."; return 1; }
  systemd_reload
  echo "Backup восстановлен."
}

normalize_manager_version() {
  local v="${1:-0}"
  v="${v#v}"
  v="${v%-stable}"
  v="${v//[^0-9.]/}"
  [[ -z "$v" ]] && v="0"
  echo "$v"
}

version_is_newer() {
  local current candidate
  current="$(normalize_manager_version "$1")"
  candidate="$(normalize_manager_version "$2")"
  [[ "$current" == "$candidate" ]] && return 1
  [[ "$(printf '%s\n%s\n' "$current" "$candidate" | sort -V | tail -n1)" == "$candidate" ]]
}

resolve_manager_download_url() {
  local src="$1"
  if [[ "$src" =~ ^https?://disk\.yandex\.(ru|com)/d/ || "$src" =~ ^https?://yadi\.sk/d/ ]]; then
    python3 - "$src" <<'PY'
import json, sys, urllib.parse, urllib.request
u=sys.argv[1]
api="https://cloud-api.yandex.net/v1/disk/public/resources?public_key="+urllib.parse.quote(u, safe="")
data=json.load(urllib.request.urlopen(api, timeout=30))
print(data["file"])
PY
  else
    echo "$src"
  fi
}

update_manager_from_url() {
  local url dl tmp new_ver current_ver backup
  read -r -p "Ссылка на новую версию скрипта: " url
  [[ -z "$url" ]] && return 1
  tmp="/tmp/vpn_stack_manager.sh.$$"
  backup="/root/vpn_stack_manager.backup.sh"
  cp -f "$(readlink -f "$0")" "$backup"
  dl="$(resolve_manager_download_url "$url")" || { echo -e "${C_RED}Не удалось получить прямую ссылку на загрузку.${C_RESET}"; rm -f "$tmp"; return 1; }
  curl -fsSL "$dl" -o "$tmp" || { echo -e "${C_RED}Не удалось скачать новую версию.${C_RESET}"; rm -f "$tmp"; return 1; }
  if ! bash -n "$tmp"; then
    rm -f "$tmp"
    echo -e "${C_RED}Скачанная версия содержит ошибку синтаксиса. Обновление отменено.${C_RESET}"
    return 1
  fi
  new_ver="$(grep -m1 '^APP_VERSION=' "$tmp" | cut -d'"' -f2)"
  current_ver="$APP_VERSION"
  if [[ -n "$new_ver" ]] && ! version_is_newer "$current_ver" "$new_ver"; then
    echo -e "${C_YELLOW}Скачанная версия ($new_ver) не новее текущей ($current_ver). Обновление отменено.${C_RESET}"
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" /root/vpn_stack_manager.sh
  chmod +x /root/vpn_stack_manager.sh
  ln -sf /root/vpn_stack_manager.sh /usr/local/bin/vpnmenu
  sed -i '/^MANAGER_UPDATE_URL=/d' "$ENV_FILE" 2>/dev/null || true
  echo "MANAGER_UPDATE_URL=\"$url\"" >> "$ENV_FILE"
  echo "Менеджер обновлён до версии ${new_ver:-неизвестно}. Запусти 'vpnmenu' заново."
  exit 0
}

remove_all_components() {
  local comp
  for comp in "$OPTIMIZE_COMP" "$WARP_WATCHDOG_COMP" "$XRAY_WATCHDOG_COMP" "$STATUS_COMP" "$DAILY_COMP" "$TG_CONTROL_COMP" "$MTPROTO_WATCHDOG_COMP" "$MTPROTO_COMP" "$SOCKS5_COMP" "$LOGROTATE_COMP"; do
    remove_component "$comp" >/dev/null 2>&1 || true
  done
  rm -f "$ENV_FILE"
  rm -rf "$BASE_DIR" "$LOG_DIR" "$STATE_DIR" "$LOCK_DIR"
  echo "Все компоненты удалены."
}

self_delete_manager() {
  echo -e "${C_YELLOW}Будут удалены все компоненты и сам менеджер. Продолжить? [y/N]${C_RESET}"
  read -r ans
  [[ "${ans,,}" != "y" ]] && return 0
  remove_all_components
  rm -f /etc/systemd/system/vpn-tools-*.service /etc/systemd/system/vpn-tools-*.timer
  systemd_reload
  local self
  self="$(readlink -f "$0" 2>/dev/null || echo "$0")"
  rm -f /usr/local/bin/vpnmenu
  rm -f "$self"
  echo "Менеджер удалён."
  exit 0
}

quick_install_all() {
  ensure_dirs
  ensure_prereqs
  prompt_telegram_settings
  if [[ -n "${BOT_TOKEN:-}" ]]; then
    auto_get_chat_id || true
  fi
  install_warp || true
  if have_warp; then
    enable_warp_proxy_mode || true
    install_component "$OPTIMIZE_COMP" || true
    install_component "$WARP_WATCHDOG_COMP" || true
  fi
  install_component "$XRAY_WATCHDOG_COMP" || true
  install_component "$STATUS_COMP" || true
  install_component "$DAILY_COMP" || true
  install_component "$LOGROTATE_COMP" || true
  install_component "$TG_CONTROL_COMP" || true
  install_component "$MTPROTO_DAILY_COMP" || true
  install_component "$MTPROTO_COMP" || true
  echo -e "${C_GREEN}Быстрая установка завершена.${C_RESET}"
  echo -e "${C_GRAY}Что установлено:${C_RESET}"
  if have_warp; then
    echo -e "${C_GRAY}- WARP и SOCKS proxy mode${C_RESET}"
    echo -e "${C_GRAY}- автоматическое создание outbound WARP в 3x-ui${C_RESET}"
    echo -e "${C_GRAY}- ночная оптимизация маршрута WARP${C_RESET}"
    echo -e "${C_GRAY}- автоконтроль и автовосстановление WARP${C_RESET}"
  else
    echo -e "${C_GRAY}- WARP пропущен: пакет не установлен или недоступен${C_RESET}"
  fi
  echo -e "${C_GRAY}- автоконтроль Xray/x-ui${C_RESET}"
  echo -e "${C_GRAY}- ежедневный отчёт VPN${C_RESET}"
  echo -e "${C_GRAY}- Telegram-бот с меню управления WARP${C_RESET}"
  echo -e "${C_GRAY}- MTProto Proxy для Telegram${C_RESET}"
}

show_logs_menu() {
  while true; do
    show_header
    echo -e "${C_GRAY}Логи: быстрый просмотр watchdog-логов и journal сервисов, а также очистка рабочих логов менеджера.${C_RESET}"
    echo
    menu_line "1" "📜" "$C_MAGENTA" "Показать log WARP watchdog"
    menu_line "2" "📜" "$C_MAGENTA" "Показать log Xray watchdog"
    menu_line "3" "📜" "$C_MAGENTA" "Показать log MTProto watchdog"
    menu_line "4" "📜" "$C_MAGENTA" "Показать log daily report"
    menu_line "5" "📘" "$C_BLUE" "Показать journal ${WARP_SERVICE_NAME}"
    menu_line "6" "📘" "$C_BLUE" "Показать journal ${XRAY_SERVICE_NAME}"
    menu_line "7" "📘" "$C_BLUE" "Показать journal MTProto Proxy"
    menu_line "8" "📘" "$C_BLUE" "Показать journal прокси 3proxy"
    menu_line "9" "🧹" "$C_RED" "Очистить логи"
    menu_line "0" "↩" "$C_GRAY" "Назад"
    read -r -p $'\033[36mВыбери:\033[0m ' c
    case "$c" in
      1) tail -n 50 "$LOG_DIR/warp.log" 2>/dev/null || echo "Лог WARP watchdog пуст."; pause ;;
      2) tail -n 50 "$LOG_DIR/xray.log" 2>/dev/null || echo "Лог Xray watchdog пуст."; pause ;;
      3) tail -n 50 "$LOG_DIR/mtproto-watchdog.log" 2>/dev/null || echo "Лог MTProto watchdog пуст."; pause ;;
      4) tail -n 50 "$LOG_DIR/vpn-daily-report.log" 2>/dev/null || echo "Лог daily report пуст."; pause ;;
      5) journalctl -u "$WARP_SERVICE_NAME" -n 50 --no-pager 2>/dev/null || true; pause ;;
      6) journalctl -u "$XRAY_SERVICE_NAME" -n 50 --no-pager 2>/dev/null || true; pause ;;
      7) journalctl -u "$(service_name_for "$MTPROTO_COMP")" -n 50 --no-pager 2>/dev/null || true; pause ;;
      8) journalctl -u "$(service_name_for "$SOCKS5_COMP")" -n 50 --no-pager 2>/dev/null || true; pause ;;
      9) rm -f "$LOG_DIR"/*.log; echo "Логи очищены."; pause ;;
      0) break ;;
      *) echo -e "${C_RED}Неверный выбор.${C_RESET}"; pause ;;
    esac
  done
}

telegram_menu() {
  while true; do
    show_header
    echo -e "${C_GRAY}Telegram: настройка токена, автоматическое получение Chat ID, тестовые уведомления и меню управления WARP прямо из бота.${C_RESET}"
    echo
    menu_line "1" "🔑" "$C_GREEN" "Задать токен и базовые настройки"
    menu_line "2" "🆔" "$C_GREEN" "Автоматически получить Chat ID"
    menu_line "3" "📋" "$C_BLUE" "Показать текущие настройки Telegram"
    menu_line "4" "✉️" "$C_CYAN" "Отправить тестовое сообщение"
    menu_line "5" "➕" "$C_GREEN" "Установить Telegram-меню управления WARP"
    menu_line "6" "➖" "$C_RED" "Удалить Telegram-меню управления WARP"
    menu_line "7" "▶️" "$C_GREEN" "Запустить Telegram-меню управления WARP"
    menu_line "8" "⏹" "$C_RED" "Остановить Telegram-меню управления WARP"
    menu_line "9" "📊" "$C_BLUE" "Статус Telegram-меню управления WARP"
    menu_line "0" "↩" "$C_GRAY" "Назад"
    read -r -p $'\033[36mВыбери:\033[0m ' c
    case "$c" in
      1) prompt_telegram_settings; pause ;;
      2) auto_get_chat_id; pause ;;
      3)
         load_env
         local masked="не задан"
         [[ -n "$BOT_TOKEN" ]] && masked="${BOT_TOKEN:0:10}********"
         echo "BOT_TOKEN: $masked"
         echo "Chat ID: ${CHAT_ID:-не задан}"
         echo "SOCKS_ADDR: $SOCKS_ADDR"
         echo "TRACE_URL: $TRACE_URL"
         pause
         ;;
      4) send_test_telegram; pause ;;
      5) install_component "$TG_CONTROL_COMP"; pause ;;
      6) remove_component "$TG_CONTROL_COMP"; pause ;;
      7) start_component "$TG_CONTROL_COMP"; pause ;;
      8) stop_component "$TG_CONTROL_COMP"; pause ;;
      9) status_component "$TG_CONTROL_COMP"; pause ;;
      0) break ;;
      *) echo -e "${C_RED}Неверный выбор.${C_RESET}"; pause ;;
    esac
  done
}

warp_menu() {
  while true; do
    show_header
    echo -e "${C_GRAY}Раздел WARP: установка, запуск, остановка, перевыпуск регистрации, включение SOCKS-режима, ночная оптимизация маршрута, автовосстановление и outbound WARP в 3x-ui.${C_RESET}"
    echo
    menu_line "1" "➕" "$C_GREEN" "Установить WARP"
    menu_line "2" "🗑" "$C_RED" "Удалить WARP"
    menu_line "3" "▶️" "$C_GREEN" "Запустить WARP"
    menu_line "4" "⏹" "$C_RED" "Остановить WARP"
    menu_line "5" "🔄" "$C_YELLOW" "Перезапустить WARP"
    menu_line "6" "📊" "$C_BLUE" "Статус WARP"
    menu_line "7" "♻️" "$C_YELLOW" "Перевыпустить регистрацию / ключ WARP"
    menu_line "8" "⚡" "$C_CYAN" "Оптимизировать маршрут WARP"
    menu_line "9" "🧦" "$C_GREEN" "Включить SOCKS proxy mode"
    menu_line "10" "🚫" "$C_RED" "Отключить SOCKS proxy mode"
    menu_line "11" "➕" "$C_GREEN" "Установить WARP watchdog"
    menu_line "12" "🗑" "$C_RED" "Удалить WARP watchdog"
    menu_line "13" "🛟" "$C_GREEN" "Включить автовосстановление WARP"
    menu_line "14" "🛑" "$C_RED" "Выключить автовосстановление WARP"
    menu_line "15" "📊" "$C_BLUE" "Статус автовосстановления WARP"
    menu_line "16" "🔌" "$C_GREEN" "Создать / восстановить outbound WARP в 3x-ui"
    menu_line "17" "🔎" "$C_BLUE" "Проверить outbound WARP в 3x-ui"
    menu_line "18" "🧭" "$C_YELLOW" "Проверить, где WARP используется в routing 3x-ui"
    menu_line "19" "🗑" "$C_RED" "Удалить outbound WARP из 3x-ui"
    menu_line "0" "↩" "$C_GRAY" "Назад"
    read -r -p $'\033[36mВыбери:\033[0m ' c
    case "$c" in
      1) install_warp; pause ;;
      2) remove_warp; pause ;;
      3) start_warp; pause ;;
      4) stop_warp; pause ;;
      5) restart_warp; pause ;;
      6) status_warp; pause ;;
      7) reissue_warp_registration; pause ;;
      8)
         if [[ -x "$BIN_DIR/$OPTIMIZE_COMP.sh" ]]; then
           "$BIN_DIR/$OPTIMIZE_COMP.sh"
         elif have_warp; then
           install_component "$OPTIMIZE_COMP" && "$BIN_DIR/$OPTIMIZE_COMP.sh"
         else
           echo "WARP не установлен."
         fi
         pause
         ;;
      9) enable_warp_proxy_mode; pause ;;
      10) disable_warp_proxy_mode; pause ;;
      11) install_component "$WARP_WATCHDOG_COMP"; pause ;;
      12) remove_component "$WARP_WATCHDOG_COMP"; pause ;;
      13) enable_warp_recovery; pause ;;
      14) disable_warp_recovery; pause ;;
      15) status_warp_recovery; pause ;;
      16) ensure_warp_outbound_in_xui; pause ;;
      17) check_warp_outbound_in_xui; pause ;;
      18) check_warp_references_in_xui; pause ;;
      19) remove_warp_outbound_in_xui; pause ;;
      0) break ;;
      *) echo -e "${C_RED}Неверный выбор.${C_RESET}"; pause ;;
    esac
  done
}


mtproto_menu() {
  while true; do
    show_header
    echo -e "${C_GRAY}Раздел MTProto Proxy: установка, обновление, настройка основного и резервного портов, запуск, остановка, ссылки для Telegram, автолечение, автопереключение на резервный порт, ежедневная профилактическая самопроверка, диагностика и удаление прокси.${C_RESET}"
    echo
    menu_line "1" "📨" "$C_GREEN" "Установить / обновить MTProto Proxy"
    menu_line "2" "⚙️" "$C_YELLOW" "Изменить основной и резервный порты MTProto"
    menu_line "3" "▶️" "$C_GREEN" "Запустить MTProto Proxy"
    menu_line "4" "⏹" "$C_RED" "Остановить MTProto Proxy"
    menu_line "5" "🔄" "$C_YELLOW" "Перезапустить MTProto Proxy"
    menu_line "6" "📊" "$C_BLUE" "Статус MTProto Proxy"
    menu_line "7" "🔗" "$C_CYAN" "Показать ссылки MTProto"
    menu_line "8" "🩺" "$C_GREEN" "Починить MTProto Proxy"
    menu_line "9" "🛟" "$C_GREEN" "Включить автовосстановление MTProto"
    menu_line "10" "🛑" "$C_RED" "Выключить автовосстановление MTProto"
    menu_line "11" "📊" "$C_BLUE" "Статус автовосстановления MTProto"
    menu_line "12" "🗓" "$C_GREEN" "Включить ежедневную самопроверку MTProto"
    menu_line "13" "🗓" "$C_RED" "Выключить ежедневную самопроверку MTProto"
    menu_line "14" "📊" "$C_BLUE" "Статус ежедневной самопроверки MTProto"
    menu_line "15" "🕘" "$C_BLUE" "Показать историю MTProto"
    menu_line "16" "📈" "$C_BLUE" "Показать счётчики MTProto"
    menu_line "17" "🧹" "$C_YELLOW" "Сбросить историю и счётчики MTProto"
    menu_line "18" "♻️" "$C_CYAN" "Пересоздать secret и ссылку MTProto"
    menu_line "19" "🗑" "$C_RED" "Удалить MTProto Proxy"
    menu_line "0" "↩" "$C_GRAY" "Назад"
    read -r -p $'[36mВыбери:[0m ' c
    case "$c" in
      1) install_component "$MTPROTO_COMP"; pause ;;
      2) prompt_mtproto_settings; save_env; if ensure_mtproto_port_available; then ensure_mtproto_firewall; if have_mtproto; then write_systemd_unit "$MTPROTO_COMP"; systemd_reload; run_cmd systemctl restart "$(service_name_for "$MTPROTO_COMP")"; fi; echo -e "${C_GREEN}Порты MTProto сохранены.${C_RESET}"; else echo -e "${C_RED}Настройки не применены из-за конфликта порта.${C_RESET}"; fi; pause ;;
      3) start_component "$MTPROTO_COMP"; pause ;;
      4) stop_component "$MTPROTO_COMP"; pause ;;
      5) run_cmd systemctl restart "$(service_name_for "$MTPROTO_COMP")"; echo "MTProto Proxy перезапущен."; pause ;;
      6) status_mtproto; pause ;;
      7) show_mtproto_links; pause ;;
      8) mtproto_repair; pause ;;
      9) enable_mtproto_recovery; pause ;;
      10) disable_mtproto_recovery; pause ;;
      11) status_mtproto_recovery; pause ;;
      12) enable_mtproto_daily_check; pause ;;
      13) disable_mtproto_daily_check; pause ;;
      14) status_mtproto_daily_check; pause ;;
      15) show_mtproto_history; pause ;;
      16) show_mtproto_counters; pause ;;
      17) reset_mtproto_counters; pause ;;
      18) regenerate_mtproto_secret; pause ;;
      19) remove_mtproto; pause ;;
      0) break ;;
      *) echo -e "${C_RED}Неверный выбор.${C_RESET}"; pause ;;
    esac
  done
}

watchdogs_menu() {
  while true; do
    show_header
    echo -e "${C_GRAY}Раздел мониторинга: watchdog для WARP и Xray/x-ui, ежедневный отчёт, статус VPN и управление расписанием сервисов.${C_RESET}"
    echo
    menu_line "1" "➕" "$C_GREEN" "Установить Xray watchdog"
    menu_line "2" "🗑" "$C_RED" "Удалить Xray watchdog"
    menu_line "3" "🛟" "$C_GREEN" "Включить автовосстановление Xray"
    menu_line "4" "🛑" "$C_RED" "Выключить автовосстановление Xray"
    menu_line "5" "📊" "$C_BLUE" "Статус автовосстановления Xray"
    menu_line "6" "➕" "$C_GREEN" "Установить vpn-status"
    menu_line "7" "➕" "$C_GREEN" "Установить daily report"
    menu_line "8" "🗑" "$C_RED" "Удалить daily report"
    menu_line "9" "▶️" "$C_GREEN" "Включить daily report"
    menu_line "10" "⏹" "$C_RED" "Выключить daily report"
    menu_line "11" "🕘" "$C_YELLOW" "Изменить время daily report"
    menu_line "12" "📋" "$C_BLUE" "Статус всех компонентов"
    menu_line "0" "↩" "$C_GRAY" "Назад"
    read -r -p $'\033[36mВыбери:\033[0m ' c
    case "$c" in
      1) install_component "$XRAY_WATCHDOG_COMP"; pause ;;
      2) remove_component "$XRAY_WATCHDOG_COMP"; pause ;;
      3) enable_xray_recovery; pause ;;
      4) disable_xray_recovery; pause ;;
      5) status_xray_recovery; pause ;;
      6) install_component "$STATUS_COMP"; pause ;;
      7) install_component "$DAILY_COMP"; pause ;;
      8) remove_component "$DAILY_COMP"; pause ;;
      9) enable_daily_report; pause ;;
      10) disable_daily_report; pause ;;
      11) set_daily_report_time; pause ;;
      12)
         local comp
         for comp in "$OPTIMIZE_COMP" "$WARP_WATCHDOG_COMP" "$XRAY_WATCHDOG_COMP" "$STATUS_COMP" "$DAILY_COMP" "$TG_CONTROL_COMP" "$MTPROTO_WATCHDOG_COMP" "$MTPROTO_COMP" "$SOCKS5_COMP" "$LOGROTATE_COMP"; do
           echo "---- $comp ----"
           status_component "$comp" || true
           echo
         done
         pause
         ;;
      0) break ;;
      *) echo -e "${C_RED}Неверный выбор.${C_RESET}"; pause ;;
    esac
  done
}

diagnostics_menu() {
  while true; do
    show_header
    echo -e "${C_GRAY}Диагностика: быстрые проверки сервисов, egress WARP, таймеров, нагрузки сервера и общего состояния VPN-стека.${C_RESET}"
    echo
    menu_line "1" "🧪" "$C_CYAN" "Проверить всё"
    menu_line "2" "🤖" "$C_BLUE" "Проверить Telegram"
    menu_line "3" "🌍" "$C_CYAN" "Проверить WARP egress"
    menu_line "4" "⚙️" "$C_BLUE" "Проверить Xray/x-ui"
    menu_line "5" "⏱" "$C_YELLOW" "Проверить timers/services"
    menu_line "6" "💾" "$C_MAGENTA" "Проверить диск / RAM / load"
    menu_line "7" "📊" "$C_BLUE" "Показать статус VPN"
    menu_line "0" "↩" "$C_GRAY" "Назад"
    read -r -p $'\033[36mВыбери:\033[0m ' c
    case "$c" in
      1)
        echo "== Проверка всего =="
        if have_warp; then
          echo -e "WARP пакет: $(fmt_status OK)"
          echo -e "Сервис WARP: $(fmt_status "$(safe_is_active "$WARP_SERVICE_NAME")")"
          echo -e "WARP egress: $(fmt_status "$(warp_egress_state)")"
        else
          echo -e "WARP пакет: $(fmt_status not-found)"
          echo -e "Сервис WARP: $(fmt_status not-found)"
          echo -e "WARP egress: $(fmt_status not-found)"
        fi
        echo -e "Сервис Xray/x-ui: $(fmt_status "$(safe_is_active "$XRAY_SERVICE_NAME")")"
        echo -e "Сервис прокси: $(fmt_status "$(safe_is_active "$(service_name_for "$SOCKS5_COMP")")")"
        echo -e "Telegram token: $([[ -n "${BOT_TOKEN:-}" ]] && fmt_status OK || fmt_status FAIL)"
        echo -e "Telegram chat id: $([[ -n "${CHAT_ID:-}" ]] && fmt_status OK || fmt_status FAIL)"
        echo -e "Таймер WARP watchdog: $(fmt_status "$(safe_is_enabled "$(timer_name_for "$WARP_WATCHDOG_COMP")")")"
        echo -e "Таймер Xray watchdog: $(fmt_status "$(safe_is_enabled "$(timer_name_for "$XRAY_WATCHDOG_COMP")")")"
        echo -e "Таймер daily report: $(fmt_status "$(safe_is_enabled "$(timer_name_for "$DAILY_COMP")")")"
        if check_warp_outbound_in_xui >/dev/null 2>&1; then
          echo -e "Outbound WARP в 3x-ui: $(fmt_status OK)"
        else
          echo -e "Outbound WARP в 3x-ui: $(fmt_status FAIL)"
        fi
        pause
        ;;
      2) send_test_telegram; pause ;;
      3)
        if have_warp; then
          curl -s --max-time 10 --socks5-hostname "$SOCKS_ADDR" "$TRACE_URL" || true
        else
          echo "WARP не установлен."
        fi
        pause
        ;;
      4) systemctl status "$XRAY_SERVICE_NAME" --no-pager 2>/dev/null || true; pause ;;
      5) systemctl list-timers --all | grep 'vpn-tools-' || echo "Таймеры менеджера не найдены."; pause ;;
      6) df -h /; echo; free -m; echo; uptime; pause ;;
      7)
        if [[ -x "$BIN_DIR/$STATUS_COMP.sh" ]]; then
          "$BIN_DIR/$STATUS_COMP.sh"
        else
          echo "vpn-status не установлен."
        fi
        pause
        ;;
      0) break ;;
      *) echo -e "${C_RED}Неверный выбор.${C_RESET}"; pause ;;
    esac
  done
}

backup_menu() {
  while true; do
    show_header
    echo -e "${C_GRAY}Резервные копии: создание, просмотр, восстановление и удаление backup.${C_RESET}"
    echo
    menu_line "1" "💾" "$C_GREEN" "Создать backup"
    menu_line "2" "📂" "$C_BLUE" "Показать список backup"
    menu_line "3" "♻️" "$C_YELLOW" "Восстановить backup"
    menu_line "4" "🗑" "$C_RED" "Удалить backup"
    menu_line "0" "↩" "$C_GRAY" "Назад"
    read -r -p $'\033[36mВыбери:\033[0m ' c
    case "$c" in
      1) create_backup; pause ;;
      2) list_backups; pause ;;
      3) restore_backup; pause ;;
      4) list_backups; read -r -p "Имя backup для удаления: " f; rm -f "$BACKUP_DIR/$f"; echo "Удалено."; pause ;;
      0) break ;;
      *) echo -e "${C_RED}Неверный выбор.${C_RESET}"; pause ;;
    esac
  done
}

update_menu() {
  while true; do
    show_header
    echo -e "${C_GRAY}Обновление менеджера: установка новой версии по URL, просмотр версии и откат к предыдущей копии.${C_RESET}"
    echo
    menu_line "1" "♻️" "$C_YELLOW" "Обновить менеджер из URL"
    menu_line "2" "🏷" "$C_BLUE" "Показать текущую версию"
    menu_line "3" "↩" "$C_YELLOW" "Откатить предыдущую версию"
    menu_line "0" "↩" "$C_GRAY" "Назад"
    read -r -p $'\033[36mВыбери:\033[0m ' c
    case "$c" in
      1) update_manager_from_url; pause ;;
      2) echo "Версия: $APP_VERSION"; pause ;;
      3)
        if [[ -f /root/vpn_stack_manager.backup.sh ]]; then
          cp -f /root/vpn_stack_manager.backup.sh /root/vpn_stack_manager.sh
          chmod +x /root/vpn_stack_manager.sh
          ln -sf /root/vpn_stack_manager.sh /usr/local/bin/vpnmenu
          echo "Откат выполнен."
        else
          echo "Резервная версия не найдена."
        fi
        pause
        ;;
      0) break ;;
      *) echo -e "${C_RED}Неверный выбор.${C_RESET}"; pause ;;
    esac
  done
}

remove_menu() {
  while true; do
    show_header
    echo -e "${C_GRAY}Удаление: аккуратная очистка компонентов, таймеров, конфигов или полное самоуничтожение менеджера вместе с его файлами.${C_RESET}"
    echo
    menu_line "1" "🧹" "$C_YELLOW" "Удалить только компоненты"
    menu_line "2" "🗂" "$C_YELLOW" "Удалить всё кроме WARP"
    menu_line "3" "🗑" "$C_RED" "Удалить вообще всё включая WARP"
    menu_line "4" "💣" "$C_RED" "Удалить менеджер, его файлы и себя"
    menu_line "0" "↩" "$C_GRAY" "Назад"
    read -r -p $'\033[36mВыбери:\033[0m ' c
    case "$c" in
      1) remove_all_components; pause ;;
      2) remove_all_components; pause ;;
      3) remove_all_components; remove_warp; pause ;;
      4) self_delete_manager ;;
      0) break ;;
      *) echo -e "${C_RED}Неверный выбор.${C_RESET}"; pause ;;
    esac
  done
}

main_menu() {
  ensure_dirs
  ensure_prereqs
  load_env
  while true; do
    show_header
    echo -e "${C_GRAY}Меню ниже управляет установкой WARP, прокси 3proxy и MTProto Proxy, watchdog-сервисами, отчётами, Telegram-ботом, логами и резервными копиями.${C_RESET}"
    echo
    menu_line "1" "🚀" "$C_GREEN" "Быстрая установка всего — WARP, watchdog, отчёты, Telegram"
    menu_line "2" "🤖" "$C_BLUE" "Telegram и уведомления — токен, Chat ID, тесты, бот-меню"
    menu_line "3" "🛡" "$C_CYAN" "WARP — установка, управление, оптимизация, recovery"
    menu_line "4" "🧦" "$C_CYAN" "Прокси 3proxy — HTTP/HTTPS, SOCKS5, SOCKS4"
    menu_line "5" "📨" "$C_GREEN" "MTProto Proxy — установка, настройка и ссылки"
    menu_line "6" "🩺" "$C_YELLOW" "Мониторинг и отчёты — watchdog, status, daily report"
    menu_line "7" "🔎" "$C_BLUE" "Диагностика — быстрые проверки состояния VPN"
    menu_line "8" "📜" "$C_MAGENTA" "Логи — watchdog и journal сервисов"
    menu_line "9" "🗂" "$C_CYAN" "Резервные копии и восстановление"
    menu_line "10" "♻️" "$C_YELLOW" "Обновить менеджер — новая версия или откат"
    menu_line "11" "🗑" "$C_RED" "Удалить компоненты — частично или полностью"
    menu_line "0" "🚪" "$C_GRAY" "Выход"
    read -r -p $'\033[36mВыбери:\033[0m ' choice
    case "$choice" in
      1) quick_install_all; pause ;;
      2) telegram_menu ;;
      3) warp_menu ;;
      4) socks5_menu ;;
      5) mtproto_menu ;;
      6) watchdogs_menu ;;
      7) diagnostics_menu ;;
      8) show_logs_menu ;;
      9) backup_menu ;;
      10) update_menu ;;
      11) remove_menu ;;
      0) exit 0 ;;
      *) echo -e "${C_RED}Неверный выбор.${C_RESET}"; pause ;;
    esac
  done
}

require_root
main_menu
