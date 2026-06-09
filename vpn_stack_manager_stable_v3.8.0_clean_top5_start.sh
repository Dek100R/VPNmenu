#!/usr/bin/env bash
set -u -o pipefail

APP_NAME="Менеджер VPN-инструментов"
APP_VERSION="3.8.0-clean-top5-start"

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
  mkdir -p "$BIN_DIR" "$LOG_DIR" "$STATE_DIR" "$LOCK_DIR" "$BACKUP_DIR"
}

write_env_if_missing() {
  if [[ ! -f "$ENV_FILE" ]]; then
    cat > "$ENV_FILE" <<'EOF_ENV'
BOT_TOKEN=""
CHAT_ID=""
SOCKS_ADDR="127.0.0.1:40000"
TRACE_URL="https://www.cloudflare.com/cdn-cgi/trace"
DAILY_REPORT_HOUR="6"
DAILY_REPORT_MINUTE="0"
WARP_SERVICE_NAME="warp-svc"
XRAY_SERVICE_NAME="x-ui"
AUTO_OPTIMIZE_AFTER_RECOVERY="false"
WARP_FAIL_THRESHOLD="3"
WARP_RECOVERY_COOLDOWN_SEC="600"
WARP_WATCHDOG_INTERVAL="3min"
MANAGER_UPDATE_URL=""
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
  TRACE_URL="${TRACE_URL:-https://www.cloudflare.com/cdn-cgi/trace}"
  DAILY_REPORT_HOUR="${DAILY_REPORT_HOUR:-6}"
  DAILY_REPORT_MINUTE="${DAILY_REPORT_MINUTE:-0}"
  WARP_SERVICE_NAME="${WARP_SERVICE_NAME:-warp-svc}"
  XRAY_SERVICE_NAME="${XRAY_SERVICE_NAME:-x-ui}"
  AUTO_OPTIMIZE_AFTER_RECOVERY="${AUTO_OPTIMIZE_AFTER_RECOVERY:-false}"
  WARP_FAIL_THRESHOLD="${WARP_FAIL_THRESHOLD:-3}"
  WARP_RECOVERY_COOLDOWN_SEC="${WARP_RECOVERY_COOLDOWN_SEC:-600}"
  WARP_WATCHDOG_INTERVAL="${WARP_WATCHDOG_INTERVAL:-3min}"
  MANAGER_UPDATE_URL="${MANAGER_UPDATE_URL:-}"
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
WARP_FAIL_THRESHOLD="${WARP_FAIL_THRESHOLD:-3}"
WARP_RECOVERY_COOLDOWN_SEC="${WARP_RECOVERY_COOLDOWN_SEC:-600}"
WARP_WATCHDOG_INTERVAL="${WARP_WATCHDOG_INTERVAL:-3min}"
MANAGER_UPDATE_URL="${MANAGER_UPDATE_URL}"
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
    out="$((warp-cli --accept-tos status 2>/dev/null || true) | head -n1 | sed 's/^Status update: //;s/^Status: //;s/^Success$//')"
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
  local candidates=(
    "/usr/local/x-ui/bin/config.json"
    "/usr/local/x-ui/bin/xray/config.json"
    "/etc/x-ui/config.json"
    "/etc/x-ui/xray/config.json"
    "/usr/local/etc/xray/config.json"
    "/etc/xray/config.json"
  )
  local cfg=""
  local cand
  for cand in "${candidates[@]}"; do
    if [[ -f "$cand" ]]; then
      echo "$cand"
      return 0
    fi
  done
  cfg="$(find /etc /usr/local -maxdepth 5 -type f -name 'config.json' 2>/dev/null | grep -E '/(x-ui|3x-ui|xray)/' | head -n1 || true)"
  if [[ -n "$cfg" && -f "$cfg" ]]; then
    echo "$cfg"
    return 0
  fi
  return 1
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
    echo "Outbound WARP найден в 3x-ui: $cfg"
    return 0
  fi
  echo "Outbound WARP не найден в 3x-ui: $cfg"
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
  if ! command -v jq >/dev/null 2>&1; then
    echo -e "${C_RED}jq не установлен, не могу изменить config.json.${C_RESET}"
    return 1
  fi
  cp -f "$cfg" "${cfg}.bak"
  if jq -e '.outbounds[]? | select(.tag=="WARP")' "$cfg" >/dev/null 2>&1; then
    echo -e "${C_GREEN}Outbound WARP уже существует в 3x-ui: ${cfg}.${C_RESET}"
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

  if jq -e '.outbounds[]? | select(.tag=="WARP")' "$cfg" >/dev/null 2>&1; then
    echo -e "${C_GREEN}Outbound WARP добавлен в 3x-ui и ${XRAY_SERVICE_NAME} перезапущен. Файл: ${cfg}${C_RESET}"
    return 0
  fi

  cp -f "${cfg}.bak" "$cfg"
  run_cmd systemctl restart "$XRAY_SERVICE_NAME"
  echo -e "${C_RED}После перезапуска outbound WARP не найден. Выполнен откат config.json.${C_RESET}"
  return 1
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

show_header() {
  load_env
  clear || true
  local warp_pkg="не установлен"
  have_warp && warp_pkg="установлен"
  local warp_svc xray_svc warp_cli warp_egress warp_recovery daily_enabled token_set chat_set
  warp_svc="$(safe_is_active "$WARP_SERVICE_NAME")"
  xray_svc="$(safe_is_active "$XRAY_SERVICE_NAME")"
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
  echo -e "↪️ Fallback WARP→direct: $(fmt_status "$xui_warp_fallback")"
  echo -e "🤖 Токен Telegram: $(fmt_status "$token_set")"
  echo -e "💬 Chat ID Telegram: $(fmt_status "$chat_set")"
  echo -e "🕘 Ежедневный отчёт: $(fmt_status "$daily_enabled") ${C_GRAY}в $(printf '%02d:%02d' "$DAILY_REPORT_HOUR" "$DAILY_REPORT_MINUTE")${C_RESET}"
  echo -e "⏱ Интервал WARP watchdog: ${C_YELLOW}${WARP_WATCHDOG_INTERVAL:-3min}${C_RESET}"
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

warp_proxy_port() {
  load_env
  local port="${SOCKS_ADDR##*:}"
  [[ "$port" =~ ^[0-9]+$ ]] || port="40000"
  echo "$port"
}

sync_warp_socks_addr() {
  local port="${1:-$(warp_proxy_port)}"
  SOCKS_ADDR="127.0.0.1:${port}"
  save_env
}

warp_local_socks_check() {
  local port ip
  port="$(warp_proxy_port)"
  if ! have_warp; then
    echo -e "${C_YELLOW}WARP не установлен.${C_RESET}"
    return 1
  fi
  echo -e "${C_CYAN}Проверяю локальный WARP SOCKS5 на 127.0.0.1:${port}...${C_RESET}"
  ip="$(curl -s4 --max-time 15 --proxy "socks5h://127.0.0.1:${port}" ifconfig.me 2>/dev/null || true)"
  if [[ -n "$ip" ]]; then
    echo -e "${C_GREEN}Локальный WARP SOCKS5 отвечает. Внешний IP: ${ip}${C_RESET}"
    return 0
  fi
  echo -e "${C_RED}Локальный WARP SOCKS5 не ответил. Проверь статус WARP, proxy mode и порт ${port}.${C_RESET}"
  return 1
}

show_warp_xui_outbound_snippet() {
  local port
  port="$(warp_proxy_port)"
  cat <<EOF_WARP_OUTBOUND
Конфигурация для ручного ввода в x-ui → Исходящие подключения.

Если в панели есть вкладка JSON, вставь блок целиком:
{
  "tag": "WARP",
  "protocol": "socks",
  "settings": {
    "servers": [
      {
        "address": "127.0.0.1",
        "port": ${port}
      }
    ]
  }
}

Если в панели только форма:
- Протокол: SOCKS
- Тег: WARP
- Адрес: 127.0.0.1
- Порт: ${port}
- Авторизация: выключена
EOF_WARP_OUTBOUND
}

show_warp_xui_google_routing_snippet() {
  cat <<'EOF_WARP_ROUTING_GOOGLE'
Конфигурация для ручного ввода в x-ui → Маршрутизация.
Добавляй по одному правилу через форму, если JSON-поле недоступно.

Рекомендуемые домены для Gemini / Google AI:
- gemini.google.com
- aistudio.google.com
- ai.google.dev
- accounts.google.com
- googleapis.com
- gstatic.com
- googleusercontent.com
- withgoogle.com

Пример JSON-правила, если в панели есть JSON-режим:
{
  "type": "field",
  "outboundTag": "WARP",
  "domain": [
    "domain:gemini.google.com",
    "domain:aistudio.google.com",
    "domain:ai.google.dev",
    "domain:accounts.google.com",
    "domain:googleapis.com",
    "domain:gstatic.com",
    "domain:googleusercontent.com",
    "domain:withgoogle.com"
  ]
}
EOF_WARP_ROUTING_GOOGLE
}

show_warp_xui_ai_routing_snippet() {
  cat <<'EOF_WARP_ROUTING_AI'
Конфигурация для ручного ввода в x-ui → Маршрутизация.

Рекомендуемые домены для OpenAI / Claude / Perplexity:
- chat.openai.com
- api.openai.com
- auth.openai.com
- cdn.oaistatic.com
- claude.ai
- api.anthropic.com
- console.anthropic.com
- www.perplexity.ai
- api.perplexity.ai

Пример JSON-правила, если в панели есть JSON-режим:
{
  "type": "field",
  "outboundTag": "WARP",
  "domain": [
    "domain:chat.openai.com",
    "domain:api.openai.com",
    "domain:auth.openai.com",
    "domain:cdn.oaistatic.com",
    "domain:claude.ai",
    "domain:api.anthropic.com",
    "domain:console.anthropic.com",
    "domain:www.perplexity.ai",
    "domain:api.perplexity.ai"
  ]
}
EOF_WARP_ROUTING_AI
}

show_warp_xui_manual_steps() {
  local port
  port="$(warp_proxy_port)"
  cat <<EOF_WARP_STEPS
Пошаговая ручная интеграция WARP в x-ui:

1. Установи и подключи WARP в этом меню.
2. Проверь, что локальный SOCKS5 отвечает на 127.0.0.1:${port}.
3. В панели x-ui создай исходящее подключение:
   - Протокол: SOCKS
   - Тег: WARP
   - Адрес: 127.0.0.1
   - Порт: ${port}
4. В разделе маршрутизации добавь правила для нужных доменов.
5. Правила с outboundTag WARP должны стоять ВЫШЕ общих direct / blocked / balancer правил.
6. Если панель даёт только форму маршрутизации, добавляй по одному домену на правило.
7. После сохранения обязательно перезапусти Xray из панели.

Скрипт не правит config.json x-ui автоматически, потому что панель может затирать ручные изменения при перезапуске.
EOF_WARP_STEPS
}

warp_xui_manual_menu() {
  while true; do
    show_header
    echo -e "${C_GRAY}Ручная интеграция WARP в x-ui: готовые блоки для ввода в панель, список доменов и подсказки по порядку правил.${C_RESET}"
    echo
    menu_line "1" "🧩" "$C_GREEN" "Показать конфигурацию outbound для ручного ввода"
    menu_line "2" "🤖" "$C_BLUE" "Показать конфигурацию маршрутизации для Gemini / Google AI"
    menu_line "3" "🧠" "$C_CYAN" "Показать конфигурацию маршрутизации для OpenAI / Claude / Perplexity"
    menu_line "4" "📋" "$C_YELLOW" "Показать пошаговую инструкцию по x-ui"
    menu_line "5" "🧪" "$C_MAGENTA" "Проверить локальный WARP SOCKS5"
    menu_line "0" "↩" "$C_GRAY" "Назад"
    read -r -p $'[36mВыбери:[0m ' c
    case "$c" in
      1) show_warp_xui_outbound_snippet; pause ;;
      2) show_warp_xui_google_routing_snippet; pause ;;
      3) show_warp_xui_ai_routing_snippet; pause ;;
      4) show_warp_xui_manual_steps; pause ;;
      5) warp_local_socks_check; pause ;;
      0) break ;;
      *) echo -e "${C_RED}Неверный выбор.${C_RESET}"; pause ;;
    esac
  done
}

install_warp() {
  ensure_prereqs
  load_env
  local port
  port="$(warp_proxy_port)"
  if have_warp; then
    echo -e "${C_GREEN}WARP уже установлен.${C_RESET}"
    sync_warp_socks_addr "$port"
    return 0
  fi
  echo -e "${C_CYAN}Устанавливаю WARP через warp-cli в SOCKS proxy mode...${C_RESET}"
  install_warp_repo
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y cloudflare-warp || {
    echo -e "${C_RED}Не удалось установить cloudflare-warp.${C_RESET}"
    return 1
  }
  run_cmd systemctl enable --now "$WARP_SERVICE_NAME"
  sleep 3
  yes | warp-cli --accept-tos registration new >/dev/null 2>&1 || true
  run_cmd warp-cli --accept-tos mode proxy
  run_cmd warp-cli --accept-tos proxy port "$port"
  run_cmd warp-cli --accept-tos connect
  sync_warp_socks_addr "$port"
  echo -e "${C_GREEN}WARP установлен. Локальный SOCKS5: 127.0.0.1:${port}${C_RESET}"
  echo
  show_warp_xui_manual_steps
}

remove_warp() {
  echo -e "${C_YELLOW}Будет удалён WARP. Продолжить? [y/N]${C_RESET}"
  read -r ans
  [[ "${ans,,}" != "y" ]] && return 0
  disable_warp_recovery >/dev/null 2>&1 || true
  if have_warp; then
    run_cmd warp-cli --accept-tos disconnect
  fi
  apt-get remove -y cloudflare-warp >/dev/null 2>&1 || true
  rm -f /etc/apt/sources.list.d/cloudflare-client.list /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
  echo -e "${C_GREEN}WARP удалён.${C_RESET}"
}

start_warp() { require_warp || return 1; run_cmd systemctl start "$WARP_SERVICE_NAME"; sleep 2; run_cmd warp-cli --accept-tos connect; echo -e "${C_GREEN}WARP запущен.${C_RESET}"; }
stop_warp() { require_warp || return 1; run_cmd warp-cli --accept-tos disconnect; run_cmd systemctl stop "$WARP_SERVICE_NAME"; echo -e "${C_GREEN}WARP остановлен.${C_RESET}"; }
restart_warp() { require_warp || return 1; run_cmd systemctl restart "$WARP_SERVICE_NAME"; sleep 3; run_cmd warp-cli --accept-tos connect; echo -e "${C_GREEN}WARP перезапущен.${C_RESET}"; }

status_warp() {
  if ! have_warp; then
    echo "WARP не установлен."
    return 0
  fi
  local port
  port="$(warp_proxy_port)"
  echo "== ${WARP_SERVICE_NAME} =="
  systemctl status "$WARP_SERVICE_NAME" --no-pager 2>/dev/null || true
  echo
  echo "== warp-cli =="
  warp-cli --accept-tos status 2>/dev/null || true
  echo
  echo "== локальный SOCKS5 =="
  echo "127.0.0.1:${port}"
  echo
  echo "== trace через SOCKS =="
  curl -s --max-time 15 --socks5-hostname "127.0.0.1:${port}" "$TRACE_URL" || true
}

reissue_warp_registration() {
  require_warp || return 1
  local port
  port="$(warp_proxy_port)"
  echo -e "${C_YELLOW}Будет перевыпущена регистрация WARP. Продолжить? [y/N]${C_RESET}"
  read -r ans
  [[ "${ans,,}" != "y" ]] && return 0
  run_cmd warp-cli --accept-tos disconnect
  run_cmd warp-cli --accept-tos registration delete
  yes | warp-cli --accept-tos registration new >/dev/null 2>&1 || true
  run_cmd warp-cli --accept-tos mode proxy
  run_cmd warp-cli --accept-tos proxy port "$port"
  run_cmd warp-cli --accept-tos connect
  sync_warp_socks_addr "$port"
  echo -e "${C_GREEN}Регистрация WARP перевыпущена.${C_RESET}"
}

enable_warp_proxy_mode() {
  require_warp || return 1
  local port
  port="$(warp_proxy_port)"
  run_cmd warp-cli --accept-tos mode proxy
  run_cmd warp-cli --accept-tos proxy port "$port"
  run_cmd warp-cli --accept-tos connect
  sync_warp_socks_addr "$port"
  echo -e "${C_GREEN}SOCKS proxy mode включён. 127.0.0.1:${port}${C_RESET}"
}
disable_warp_proxy_mode() { require_warp || return 1; run_cmd warp-cli --accept-tos disconnect; echo -e "${C_GREEN}SOCKS proxy mode отключён.${C_RESET}"; }

write_component_script() {
  local comp="$1"
  ensure_dirs
  case "$comp" in
    warp-optimize)
      cat > "$BIN_DIR/warp-optimize.sh" <<'EOF_SCRIPT'
#!/usr/bin/env bash
set -u -o pipefail
ENV_FILE="/etc/vpn-tools.env"
LOG_FILE="/var/log/vpn-tools/warp-optimize.log"
mkdir -p /var/log/vpn-tools
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"
SOCKS_ADDR="${SOCKS_ADDR:-127.0.0.1:40000}"
TRACE_URL="${TRACE_URL:-https://www.cloudflare.com/cdn-cgi/trace}"
port="${SOCKS_ADDR##*:}"
log(){ echo "$(date '+%F %T') - $*" >> "$LOG_FILE"; }
if ! command -v warp-cli >/dev/null 2>&1; then
  log "WARP не установлен"
  exit 0
fi
log "Стабилизация WARP: proxy mode, port ${port}, без disconnect/connect циклов"
warp-cli --accept-tos mode proxy >/dev/null 2>&1 || true
warp-cli --accept-tos proxy port "$port" >/dev/null 2>&1 || true
warp-cli --accept-tos connect >/dev/null 2>&1 || true
sleep 8
trace="$(curl -s --max-time 20 --socks5-hostname "$SOCKS_ADDR" "$TRACE_URL" 2>/dev/null || true)"
if grep -q 'warp=on' <<<"$trace"; then
  ip="$(awk -F= '$1=="ip"{print $2}' <<<"$trace")"
  colo="$(awk -F= '$1=="colo"{print $2}' <<<"$trace")"
  loc="$(awk -F= '$1=="loc"{print $2}' <<<"$trace")"
  log "OK warp=on ip=${ip} colo=${colo} loc=${loc}"
else
  log "WARN trace не подтвердил warp=on"
fi
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
FAIL_COUNT_FILE="/var/lib/vpn-tools/warp_fail_count"
LAST_RECOVERY_FILE="/var/lib/vpn-tools/warp_last_recovery"
LOCK_FILE="/run/vpn-tools/warp-watchdog.lock"
XUI_FALLBACK_STATE_FILE="/var/lib/vpn-tools/xui_warp_fallback.active"
XUI_FALLBACK_BACKUP_FILE="/var/lib/vpn-tools/xui_warp_fallback_config.json"
mkdir -p /var/log/vpn-tools /var/lib/vpn-tools /run/vpn-tools
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"
BOT_TOKEN="${BOT_TOKEN:-}"
CHAT_ID="${CHAT_ID:-}"
SOCKS_ADDR="${SOCKS_ADDR:-127.0.0.1:40000}"
TRACE_URL="${TRACE_URL:-https://www.cloudflare.com/cdn-cgi/trace}"
WARP_SERVICE_NAME="${WARP_SERVICE_NAME:-warp-svc}"
XRAY_SERVICE_NAME="${XRAY_SERVICE_NAME:-x-ui}"
AUTO_OPTIMIZE_AFTER_RECOVERY="${AUTO_OPTIMIZE_AFTER_RECOVERY:-false}"
WARP_FAIL_THRESHOLD="${WARP_FAIL_THRESHOLD:-3}"
WARP_RECOVERY_COOLDOWN_SEC="${WARP_RECOVERY_COOLDOWN_SEC:-600}"
port="${SOCKS_ADDR##*:}"
send_tg() {
  local text="$1"
  [[ -z "$BOT_TOKEN" || -z "$CHAT_ID" ]] && return 0
  curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" -d chat_id="${CHAT_ID}" --data-urlencode text="${text}" >/dev/null 2>&1 || true
}
log_msg() { echo "$(date '+%F %T') - $*" >> "$LOG_FILE"; }
have_warp() { command -v warp-cli >/dev/null 2>&1; }
get_trace_once() {
  local url="$1"
  curl -s --max-time 20 --socks5-hostname "$SOCKS_ADDR" "$url" 2>/dev/null || true
}
get_trace() {
  local t
  t="$(get_trace_once "$TRACE_URL")"
  if grep -q 'warp=on' <<<"$t"; then echo "$t"; return 0; fi
  t="$(get_trace_once "https://www.cloudflare.com/cdn-cgi/trace")"
  if grep -q 'warp=on' <<<"$t"; then echo "$t"; return 0; fi
  t="$(get_trace_once "https://one.one.one.one/cdn-cgi/trace")"
  echo "$t"
}
get_field() { local k="$1"; awk -F= -v k="$k" '$1==k{print $2}' <<<"$2"; }
get_ping() { ping -c 3 1.1.1.1 2>/dev/null | awk -F'/' 'END{print $5}'; }
xui_config_path() { local cfg="/usr/local/x-ui/bin/config.json"; [[ -f "$cfg" ]] && echo "$cfg"; }
activate_xui_fallback() {
  local cfg tmp
  cfg="$(xui_config_path || true)"
  [[ -z "$cfg" ]] && return 1
  command -v jq >/dev/null 2>&1 || return 1
  if [[ -f "$XUI_FALLBACK_STATE_FILE" && -f "$XUI_FALLBACK_BACKUP_FILE" ]]; then return 0; fi
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
  jq empty "$cfg" >/dev/null 2>&1 || { cp -f "$XUI_FALLBACK_BACKUP_FILE" "$cfg"; rm -f "$XUI_FALLBACK_BACKUP_FILE"; return 1; }
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
  # Сначала проверяем реальный WARP trace через SOCKS. Это главный критерий.
  t="$(get_trace)"
  grep -q 'warp=on' <<<"$t" && return 0
  # Запасная проверка: Cloudflare WARP часто отдаёт 104.28.x.x / 162.159.x.x.
  ip="$(curl -s --max-time 12 --socks5-hostname "$SOCKS_ADDR" https://api.ipify.org 2>/dev/null || true)"
  grep -Eq '^(104\.28\.|162\.159\.)' <<<"$ip" && return 0
  return 1
}
soft_recover_warp() {
  systemctl is-active --quiet "$WARP_SERVICE_NAME" || systemctl start "$WARP_SERVICE_NAME" >/dev/null 2>&1 || true
  warp-cli --accept-tos mode proxy >/dev/null 2>&1 || true
  warp-cli --accept-tos proxy port "$port" >/dev/null 2>&1 || true
  warp-cli --accept-tos connect >/dev/null 2>&1 || true
  sleep 12
  check_warp
}
hard_recover_warp() {
  systemctl restart "$WARP_SERVICE_NAME" >/dev/null 2>&1 || true
  sleep 10
  warp-cli --accept-tos mode proxy >/dev/null 2>&1 || true
  warp-cli --accept-tos proxy port "$port" >/dev/null 2>&1 || true
  warp-cli --accept-tos connect >/dev/null 2>&1 || true
  sleep 15
  check_warp
}
recover_warp() {
  soft_recover_warp && return 0
  hard_recover_warp && return 0
  if [[ "$AUTO_OPTIMIZE_AFTER_RECOVERY" == "true" ]] && [[ -x /opt/vpn-tools/bin/warp-optimize.sh ]]; then
    /opt/vpn-tools/bin/warp-optimize.sh >/dev/null 2>&1 || true
    sleep 5
    check_warp && return 0
  fi
  return 1
}
exec 9>"$LOCK_FILE"
flock -n 9 || exit 0
if ! have_warp; then
  log_msg "WARP не установлен, watchdog пропущен"
  exit 0
fi
last="OK"
[[ -f "$STATE_FILE" ]] && last="$(cat "$STATE_FILE")"
fail_count=0
[[ -f "$FAIL_COUNT_FILE" ]] && fail_count="$(cat "$FAIL_COUNT_FILE" 2>/dev/null || echo 0)"
[[ "$fail_count" =~ ^[0-9]+$ ]] || fail_count=0
current="OK"
systemctl is-active --quiet "$WARP_SERVICE_NAME" || current="FAIL"
# Не считаем текст warp-cli status главным критерием: у новых версий он может просить ToS/менять формат вывода.
if [[ "$current" == "OK" ]]; then check_warp || current="FAIL"; fi
if [[ "$current" == "FAIL" ]]; then
  fail_count=$((fail_count + 1))
  echo "$fail_count" > "$FAIL_COUNT_FILE"
  log_msg "WARP check FAIL ${fail_count}/${WARP_FAIL_THRESHOLD}"
  if (( fail_count < WARP_FAIL_THRESHOLD )); then
    echo "OK" > "$STATE_FILE"
    exit 0
  fi
  now="$(date +%s)"
  last_rec="0"
  [[ -f "$LAST_RECOVERY_FILE" ]] && last_rec="$(cat "$LAST_RECOVERY_FILE" 2>/dev/null || echo 0)"
  [[ "$last_rec" =~ ^[0-9]+$ ]] || last_rec=0
  if (( now - last_rec < WARP_RECOVERY_COOLDOWN_SEC )); then
    log_msg "WARP FAIL, но recovery на cooldown $((WARP_RECOVERY_COOLDOWN_SEC - (now - last_rec))) сек; без перезапуска"
    echo "FAIL" > "$STATE_FILE"
    exit 1
  fi
  echo "$now" > "$LAST_RECOVERY_FILE"
  log_msg "WARP FAIL подтверждён, запускаю recovery"
  if activate_xui_fallback; then
    log_msg "Активирован fallback WARP→direct в 3x-ui"
    [[ "$last" == "OK" ]] && send_tg "↪️ WARP недоступен. Активирован fallback WARP→direct."
  fi
  [[ "$last" == "OK" ]] && send_tg "⚠️ WARP недоступен после ${WARP_FAIL_THRESHOLD} проверок. Пытаюсь восстановить..."
  if recover_warp; then
    trace="$(get_trace)"
    ip="$(get_field ip "$trace")"
    colo="$(get_field colo "$trace")"
    loc="$(get_field loc "$trace")"
    p="$(get_ping)"
    if restore_xui_fallback >/dev/null 2>&1; then log_msg "Fallback WARP→direct отключён, маршруты 3x-ui возвращены на WARP"; fi
    echo "0" > "$FAIL_COUNT_FILE"
    echo "OK" > "$STATE_FILE"
    log_msg "WARP восстановлен ip=${ip} colo=${colo} loc=${loc}"
    send_tg "✅ WARP восстановлен
IP: ${ip}
COLO: ${colo}
LOC: ${loc}
PING: ${p} ms"
    exit 0
  else
    echo "FAIL" > "$STATE_FILE"
    log_msg "WARP не удалось восстановить, fallback direct оставлен активным"
    [[ "$last" == "OK" ]] && send_tg "❌ WARP не удалось восстановить. Fallback WARP→direct оставлен активным."
    exit 1
  fi
fi
# OK
echo "0" > "$FAIL_COUNT_FILE"
if [[ -f "$XUI_FALLBACK_STATE_FILE" ]]; then
  if restore_xui_fallback; then
    log_msg "WARP OK, fallback WARP→direct отключён"
    [[ "$last" == "FAIL" ]] && send_tg "✅ WARP снова работает. Маршруты через WARP восстановлены."
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
TRACE_URL="${TRACE_URL:-https://www.cloudflare.com/cdn-cgi/trace}"
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
OFFSET_FILE = "/var/lib/vpn-tools/telegram-bot-offset"
API_BASE = "https://api.telegram.org/bot{token}/{method}"

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

CFG = load_env_file(ENV_FILE)
BOT_TOKEN = CFG.get("BOT_TOKEN", "")
CHAT_ID = CFG.get("CHAT_ID", "")

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

def have_warp():
    return shell("command -v warp-cli >/dev/null 2>&1").returncode == 0

def timer_state():
    out = shell("systemctl is-enabled vpn-tools-warp-watchdog.timer").stdout.strip().splitlines()
    return out[0] if out else "not-found"

def warp_status_text():
    if have_warp():
        svc = shell(f"systemctl is-active {CFG.get('WARP_SERVICE_NAME', 'warp-svc')}").stdout.strip() or "inactive"
        cli_lines = shell("warp-cli --accept-tos status").stdout.strip().splitlines()
        cli = cli_lines[0] if cli_lines else "н/д"
        trace = shell(
            f"curl -s --max-time 10 --socks5-hostname {CFG.get('SOCKS_ADDR', '127.0.0.1:40000')} "
            f"{CFG.get('TRACE_URL', 'https://1.1.1.1/cdn-cgi/trace')}"
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
    return (
        "WARP управление

"
        f"Сервис WARP: {svc}
"
        f"warp-cli: {cli}
"
        f"WARP egress: {warp}
"
        f"Автовосстановление WARP: {rec}
"
        f"IP: {ip}
"
        f"COLO: {colo}
"
        f"LOC: {loc}"
    )

def keyboard():
    return {
        "inline_keyboard": [
            [{"text": "▶️ WARP ВКЛ", "callback_data": "warp_on"}, {"text": "⏹ WARP ВЫКЛ", "callback_data": "warp_off"}],
            [{"text": "🛡️ WARP авто ВКЛ", "callback_data": "rec_on"}, {"text": "🛑 WARP авто ВЫКЛ", "callback_data": "rec_off"}],
            [{"text": "📊 Общий статус", "callback_data": "status"}, {"text": "🔄 Обновить", "callback_data": "refresh"}],
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

def do_action(action, chat_id=None):
    if action == "warp_on":
        if not have_warp():
            return "WARP не установлен"
        shell(f"systemctl start {CFG.get('WARP_SERVICE_NAME', 'warp-svc')}")
        time.sleep(2)
        shell("warp-cli connect")
        return "WARP включён"
    if action == "warp_off":
        if not have_warp():
            return "WARP не установлен"
        shell("warp-cli disconnect")
        shell(f"systemctl stop {CFG.get('WARP_SERVICE_NAME', 'warp-svc')}")
        return "WARP выключен"
    if action == "rec_on":
        shell("systemctl enable --now vpn-tools-warp-watchdog.timer")
        return "Автовосстановление WARP включено"
    if action == "rec_off":
        shell("systemctl disable --now vpn-tools-warp-watchdog.timer")
        return "Автовосстановление WARP выключено"
    if action == "status":
        api("sendMessage", {"chat_id": str(chat_id), "text": f"📊 Общий статус

{warp_status_text()}"})
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
                    if text in ("/start", "/menu", "/warp", "/status"):
                        send_menu(chat_id)
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
    "$WARP_WATCHDOG_COMP"|"$XRAY_WATCHDOG_COMP")
      cat > "$timer" <<EOF_T
[Unit]
Description=Запуск $comp каждую минуту

[Timer]
OnBootSec=1min
OnUnitActiveSec=${WARP_WATCHDOG_INTERVAL:-3min}
AccuracySec=30s
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
      "$WARP_WATCHDOG_COMP"|"$XRAY_WATCHDOG_COMP"|"$DAILY_COMP"|"$OPTIMIZE_COMP")
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
    "$WARP_WATCHDOG_COMP"|"$XRAY_WATCHDOG_COMP"|"$DAILY_COMP"|"$OPTIMIZE_COMP")
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
    "$WARP_WATCHDOG_COMP"|"$XRAY_WATCHDOG_COMP"|"$DAILY_COMP"|"$OPTIMIZE_COMP")
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

normalize_manager_update_url() {
  local src="$1"
  python3 - "$src" <<'PY'
import re, sys
u = sys.argv[1].strip()
if not u:
    print("")
    raise SystemExit
u = re.sub(r'/refs/heads/([^/]+)/', r'/\1/', u)
m = re.match(r'^https?://github\.com/([^/]+)/([^/]+)/blob/([^/]+)/(.+)$', u)
if m:
    print(f"https://raw.githubusercontent.com/{m.group(1)}/{m.group(2)}/{m.group(3)}/{m.group(4)}")
    raise SystemExit
m = re.match(r'^https?://raw\.githubusercontent\.com/([^/]+)/([^/]+)/refs/heads/([^/]+)/(.+)$', u)
if m:
    print(f"https://raw.githubusercontent.com/{m.group(1)}/{m.group(2)}/{m.group(3)}/{m.group(4)}")
    raise SystemExit
print(u)
PY
}

resolve_manager_download_url() {
  local src="$1"
  src="$(normalize_manager_update_url "$src")"
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


manager_validate_downloaded_script() {
  local candidate="$1"

  if [[ ! -s "$candidate" ]]; then
    echo -e "${C_RED}Скачанный файл пустой. Обновление отменено.${C_RESET}"
    return 1
  fi

  if ! head -n 1 "$candidate" | grep -qE '^#!/'; then
    echo -e "${C_RED}Скачанный файл не похож на shell-скрипт. Обновление отменено.${C_RESET}"
    return 1
  fi

  if ! grep -qE '^require_root\(\)' "$candidate"; then
    echo -e "${C_RED}В новой версии нет функции require_root(). Обновление отменено.${C_RESET}"
    return 1
  fi

  if ! grep -qE '^main_menu\(\)' "$candidate"; then
    echo -e "${C_RED}В новой версии нет функции main_menu(). Обновление отменено.${C_RESET}"
    return 1
  fi

  if ! tail -n 50 "$candidate" | grep -qE '^[[:space:]]*require_root[[:space:]]*$' || \
     ! tail -n 50 "$candidate" | grep -qE '^[[:space:]]*main_menu[[:space:]]*$'; then
    echo -e "${C_YELLOW}В новой версии нет запуска меню в конце файла. Автоматически добавляю require_root и main_menu.${C_RESET}"
    cat >> "$candidate" <<'EOF_MANAGER_ENTRYPOINT'

require_root
main_menu
EOF_MANAGER_ENTRYPOINT
  fi

  if ! bash -n "$candidate"; then
    echo -e "${C_RED}Скачанная версия содержит ошибку синтаксиса. Обновление отменено.${C_RESET}"
    return 1
  fi

  return 0
}

set_manager_update_url() {
  local url normalized dl tmp
  load_env
  echo -e "${C_DIM}Укажи raw-ссылку на скрипт. Поддерживаются raw GitHub, GitHub blob и публичные ссылки Яндекс Диска.${C_RESET}"
  read -r -p "URL обновления [${MANAGER_UPDATE_URL:-не задан}]: " url
  url="${url:-$MANAGER_UPDATE_URL}"
  [[ -z "$url" ]] && { echo -e "${C_YELLOW}URL не задан.${C_RESET}"; return 1; }
  normalized="$(normalize_manager_update_url "$url")"

  tmp="/tmp/vpn_stack_manager_url_check.$$"
  dl="$(resolve_manager_download_url "$normalized")" || { echo -e "${C_RED}Не удалось получить прямую ссылку на загрузку.${C_RESET}"; rm -f "$tmp"; return 1; }
  curl -fsSL "$dl" -o "$tmp" || { echo -e "${C_RED}Не удалось скачать файл для проверки. URL не сохранён.${C_RESET}"; rm -f "$tmp"; return 1; }
  sed -i 's/\r$//' "$tmp"

  if ! manager_validate_downloaded_script "$tmp"; then
    rm -f "$tmp"
    echo -e "${C_RED}URL не сохранён: файл не прошёл проверку безопасного обновления.${C_RESET}"
    return 1
  fi
  rm -f "$tmp"

  MANAGER_UPDATE_URL="$normalized"
  save_env
  echo -e "${C_GREEN}URL обновления проверен и сохранён:${C_RESET} ${MANAGER_UPDATE_URL}"
}


update_manager_from_url() {
  local requested_url url dl tmp new_ver current_ver backup
  requested_url="${1:-}"
  load_env
  if [[ -n "$requested_url" ]]; then
    url="$requested_url"
  else
    read -r -p "Ссылка на новую версию скрипта [${MANAGER_UPDATE_URL:-не задан}]: " url
    url="${url:-$MANAGER_UPDATE_URL}"
  fi
  [[ -z "$url" ]] && { echo -e "${C_YELLOW}Ссылка не указана.${C_RESET}"; return 1; }
  url="$(normalize_manager_update_url "$url")"
  tmp="/tmp/vpn_stack_manager.sh.$$"
  backup="/root/vpn_stack_manager.backup.sh"
  cp -f "$(readlink -f "$0")" "$backup"
  dl="$(resolve_manager_download_url "$url")" || { echo -e "${C_RED}Не удалось получить прямую ссылку на загрузку.${C_RESET}"; rm -f "$tmp"; return 1; }
  curl -fsSL "$dl" -o "$tmp" || { echo -e "${C_RED}Не удалось скачать новую версию.${C_RESET}"; rm -f "$tmp"; return 1; }
  sed -i 's/\r$//' "$tmp"
  if ! manager_validate_downloaded_script "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  new_ver="$(grep -m1 '^APP_VERSION=' "$tmp" | cut -d'"' -f2)"
  current_ver="$APP_VERSION"
  if [[ -n "$new_ver" ]] && [[ -n "$current_ver" ]] && ! version_is_newer "$current_ver" "$new_ver"; then
    echo -e "${C_YELLOW}Скачанная версия ($new_ver) не новее текущей ($current_ver). Обновление отменено.${C_RESET}"
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" /root/vpn_stack_manager.sh
  chmod +x /root/vpn_stack_manager.sh
  ln -sf /root/vpn_stack_manager.sh /usr/local/bin/vpnmenu
  MANAGER_UPDATE_URL="$url"
  save_env
  echo -e "${C_GREEN}Менеджер обновлён до версии ${new_ver:-неизвестно}.${C_RESET}"
  echo -e "${C_CYAN}Перезапускаю меню из новой версии...${C_RESET}"
  exec /usr/local/bin/vpnmenu
}

update_manager_from_saved_url() {
  load_env
  if [[ -z "$MANAGER_UPDATE_URL" ]]; then
    echo -e "${C_YELLOW}URL обновления не сохранён.${C_RESET}"
    return 1
  fi
  update_manager_from_url "$MANAGER_UPDATE_URL"
}

remove_all_components() {
  local comp
  for comp in "$OPTIMIZE_COMP" "$WARP_WATCHDOG_COMP" "$XRAY_WATCHDOG_COMP" "$STATUS_COMP" "$DAILY_COMP" "$TG_CONTROL_COMP" "$LOGROTATE_COMP"; do
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


show_getting_started_map() {
  cat <<'EOF_GETTING_STARTED'
Как пользоваться менеджером быстро и без путаницы:

1. Для Gemini / Google AI через x-ui:
   - Открой «Сценарии и быстрый старт» → «Минимум для Gemini / x-ui».
   - Скрипт поставит WARP, включит локальный WARP SOCKS и покажет, что добавить в x-ui.
   - В x-ui создай outbound WARP, затем добавь routing-правила.
   - Правила WARP должны стоять выше direct / blocked / balancer.

2. Для белого списка Happ:
   - Открой главный пункт «Установить / обновить белый список Happ».
   - Вставь новую ссылку happ://routing/onadd/...
   - Клиентам QR остаётся прежним: https://x-route.shop:8444/r

3. Для уведомлений и Telegram-бота:
   - Открой «Telegram и уведомления».
   - Задай токен, получи Chat ID, проверь тестовым сообщением.

4. Для обслуживания:
   - «Мониторинг и автоматизация» — watchdog, daily report, vpn-status.
   - «Диагностика и журналы» — быстрые проверки, логи и journal.
   - «Обслуживание» — backup, обновление менеджера и удаление компонентов.
EOF_GETTING_STARTED
}

show_warp_rule_priority_tips() {
  cat <<'EOF_WARP_PRIORITY'
Подсказки по маршрутизации WARP в x-ui:

- Сначала создай outbound с тегом WARP.
- Затем добавляй правила маршрутизации на домены.
- Если x-ui работает только через форму, добавляй ПО ОДНОМУ домену на правило.
- В списке правил маршрутизации правила WARP должны быть выше:
  • direct
  • blocked
  • balancer
  • общих catch-all правил
- После изменений нажми «Сохранить» и затем «Перезапуск Xray».
EOF_WARP_PRIORITY
}

quickstart_warp_xui() {
  echo -e "${C_CYAN}Сценарий: Gemini / Google AI через x-ui.${C_RESET}"
  install_warp || true
  if have_warp; then
    enable_warp_proxy_mode || true
    echo
    warp_local_socks_check || true
    echo
    show_warp_xui_manual_steps
    echo
    show_warp_xui_outbound_snippet
    echo
    show_warp_xui_google_routing_snippet
    echo
    show_warp_rule_priority_tips
  else
    echo -e "${C_RED}WARP не установлен. Сценарий не завершён.${C_RESET}"
  fi
}

quickstart_base_automation() {
  echo -e "${C_CYAN}Ставлю базовую автоматизацию менеджера...${C_RESET}"
  install_component "$XRAY_WATCHDOG_COMP" || true
  install_component "$STATUS_COMP" || true
  install_component "$DAILY_COMP" || true
  install_component "$LOGROTATE_COMP" || true
  echo -e "${C_GREEN}Базовая автоматизация установлена.${C_RESET}"
}

quick_install_all() {
  ensure_dirs
  ensure_prereqs
  load_env
  echo -e "${C_CYAN}Полная установка core-набора менеджера.${C_RESET}"
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
  if [[ -n "${BOT_TOKEN:-}" && -n "${CHAT_ID:-}" ]]; then
    install_component "$TG_CONTROL_COMP" || true
  fi
  echo -e "${C_GREEN}Быстрая установка завершена.${C_RESET}"
  echo -e "${C_GRAY}Что установлено:${C_RESET}"
  if have_warp; then
    echo -e "${C_GRAY}- WARP через warp-cli и локальный SOCKS5 proxy mode${C_RESET}"
    echo -e "${C_GRAY}- WARP watchdog и оптимизация маршрута${C_RESET}"
    echo -e "${C_GRAY}- готовые подсказки для ручной интеграции в x-ui${C_RESET}"
  else
    echo -e "${C_GRAY}- WARP пропущен: пакет не установлен или недоступен${C_RESET}"
  fi
  echo -e "${C_GRAY}- Xray watchdog${C_RESET}"
  echo -e "${C_GRAY}- vpn-status и daily report${C_RESET}"
  echo -e "${C_GRAY}- logrotate для логов менеджера${C_RESET}"
  if [[ -n "${BOT_TOKEN:-}" && -n "${CHAT_ID:-}" ]]; then
    echo -e "${C_GRAY}- Telegram-бот управления WARP${C_RESET}"
  else
    echo -e "${C_GRAY}- Telegram-бот пропущен: токен или Chat ID не заданы${C_RESET}"
  fi
  echo
}

quickstart_menu() {
  while true; do
    show_header
    echo -e "${C_GRAY}Сценарии: быстрые действия без поиска по меню.${C_RESET}"
    echo
    menu_line "1" "✨" "$C_GREEN" "Минимум для Gemini / x-ui — WARP + локальный WARP SOCKS + подсказки по x-ui"
    menu_line "2" "🛟" "$C_BLUE" "Поставить базовую автоматизацию: watchdog, status, daily report"
    menu_line "3" "🚀" "$C_YELLOW" "Полная установка core-набора менеджера"
    menu_line "4" "🗺" "$C_MAGENTA" "Показать карту разделов и порядок действий"
    menu_line "0" "↩" "$C_GRAY" "Назад"
    read -r -p $'\033[36mВыбери:\033[0m ' c
    case "$c" in
      1) quickstart_warp_xui; pause ;;
      2) quickstart_base_automation; pause ;;
      3) quick_install_all; pause ;;
      4) show_getting_started_map; pause ;;
      0) break ;;
      *) echo -e "${C_RED}Неверный выбор.${C_RESET}"; pause ;;
    esac
  done
}

show_logs_menu() {
  while true; do
    show_header
    echo -e "${C_GRAY}Журналы: сначала смотри рабочие логи менеджера, затем journal сервисов. Очистка удаляет только *.log в каталоге менеджера.${C_RESET}"
    echo
    menu_line "1" "📜" "$C_MAGENTA" "Показать лог WARP watchdog"
    menu_line "2" "📜" "$C_MAGENTA" "Показать лог Xray watchdog"
    menu_line "4" "📜" "$C_MAGENTA" "Показать лог daily report"
    menu_line "5" "📘" "$C_BLUE" "Показать journal WARP"
    menu_line "6" "📘" "$C_BLUE" "Показать journal x-ui / Xray"
    menu_line "9" "🧹" "$C_RED" "Очистить рабочие логи менеджера"
    menu_line "0" "↩" "$C_GRAY" "Назад"
    read -r -p $'\033[36mВыбери:\033[0m ' c
    case "$c" in
      1) tail -n 50 "$LOG_DIR/warp.log" 2>/dev/null || echo "Лог WARP watchdog пуст."; pause ;;
      2) tail -n 50 "$LOG_DIR/xray.log" 2>/dev/null || echo "Лог Xray watchdog пуст."; pause ;;
      4) tail -n 50 "$LOG_DIR/vpn-daily-report.log" 2>/dev/null || echo "Лог daily report пуст."; pause ;;
      5) journalctl -u "$WARP_SERVICE_NAME" -n 50 --no-pager 2>/dev/null || true; pause ;;
      6) journalctl -u "$XRAY_SERVICE_NAME" -n 50 --no-pager 2>/dev/null || true; pause ;;
      9) rm -f "$LOG_DIR"/*.log; echo "Рабочие логи менеджера очищены."; pause ;;
      0) break ;;
      *) echo -e "${C_RED}Неверный выбор.${C_RESET}"; pause ;;
    esac
  done
}

backup_menu() {
  while true; do
    show_header
    echo -e "${C_GRAY}Резервные копии: создавай backup перед крупными изменениями, обновлением менеджера и перед удалением компонентов.${C_RESET}"
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

telegram_menu() {
  while true; do
    show_header
    echo -e "${C_GRAY}Telegram: сначала задай токен, затем автоматически получи Chat ID, затем проверь тестовым сообщением. После этого можно ставить Telegram-меню управления WARP.${C_RESET}"
    echo
    menu_line "1" "🔑" "$C_GREEN" "Задать токен и базовые настройки"
    menu_line "2" "🆔" "$C_GREEN" "Автоматически получить Chat ID"
    menu_line "3" "📋" "$C_BLUE" "Показать текущие настройки Telegram"
    menu_line "4" "✉️" "$C_CYAN" "Отправить тестовое сообщение"
    menu_line "5" "➕" "$C_GREEN" "Установить Telegram-меню управления WARP"
    menu_line "6" "▶️" "$C_GREEN" "Запустить Telegram-меню управления WARP"
    menu_line "7" "⏹" "$C_RED" "Остановить Telegram-меню управления WARP"
    menu_line "8" "📊" "$C_BLUE" "Статус Telegram-меню управления WARP"
    menu_line "9" "🗑" "$C_RED" "Удалить Telegram-меню управления WARP"
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
      6) start_component "$TG_CONTROL_COMP"; pause ;;
      7) stop_component "$TG_CONTROL_COMP"; pause ;;
      8) status_component "$TG_CONTROL_COMP"; pause ;;
      9) remove_component "$TG_CONTROL_COMP"; pause ;;
      0) break ;;
      *) echo -e "${C_RED}Неверный выбор.${C_RESET}"; pause ;;
    esac
  done
}

warp_runtime_menu() {
  while true; do
    show_header
    echo -e "${C_GRAY}Управление WARP: установка, запуск, перевыпуск регистрации и локальный SOCKS5 proxy mode через warp-cli.${C_RESET}"
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
    menu_line "11" "🧪" "$C_BLUE" "Проверить локальный WARP SOCKS5"
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
         pause ;;
      9) enable_warp_proxy_mode; pause ;;
      10) disable_warp_proxy_mode; pause ;;
      11) warp_local_socks_check; pause ;;
      0) break ;;
      *) echo -e "${C_RED}Неверный выбор.${C_RESET}"; pause ;;
    esac
  done
}

warp_watchdog_menu() {
  while true; do
    show_header
    echo -e "${C_GRAY}Watchdog WARP: таймер проверяет сервис, а автовосстановление пробует поднять WARP и при сбое временно перевести x-ui на direct fallback.${C_RESET}"
    echo
    menu_line "1" "➕" "$C_GREEN" "Установить WARP watchdog"
    menu_line "2" "🗑" "$C_RED" "Удалить WARP watchdog"
    menu_line "3" "🛟" "$C_GREEN" "Включить автовосстановление WARP"
    menu_line "4" "🛑" "$C_RED" "Выключить автовосстановление WARP"
    menu_line "5" "📊" "$C_BLUE" "Статус автовосстановления WARP"
    menu_line "0" "↩" "$C_GRAY" "Назад"
    read -r -p $'\033[36mВыбери:\033[0m ' c
    case "$c" in
      1) install_component "$WARP_WATCHDOG_COMP"; pause ;;
      2) remove_component "$WARP_WATCHDOG_COMP"; pause ;;
      3) enable_warp_recovery; pause ;;
      4) disable_warp_recovery; pause ;;
      5) status_warp_recovery; pause ;;
      0) break ;;
      *) echo -e "${C_RED}Неверный выбор.${C_RESET}"; pause ;;
    esac
  done
}

warp_xui_manual_menu() {
  while true; do
    show_header
    echo -e "${C_GRAY}Ручная интеграция WARP в x-ui: менеджер не переписывает config.json панели автоматически, а показывает готовую конфигурацию и порядок действий.${C_RESET}"
    echo
    menu_line "1" "🧩" "$C_GREEN" "Показать конфигурацию outbound для ручного ввода"
    menu_line "2" "🤖" "$C_BLUE" "Показать конфигурацию маршрутизации для Gemini / Google AI"
    menu_line "3" "🧠" "$C_CYAN" "Показать конфигурацию маршрутизации для OpenAI / Claude / Perplexity"
    menu_line "4" "📍" "$C_YELLOW" "Показать подсказки по порядку правил в маршрутизации"
    menu_line "5" "📋" "$C_YELLOW" "Показать пошаговую инструкцию по x-ui"
    menu_line "6" "🧪" "$C_MAGENTA" "Проверить локальный WARP SOCKS5"
    menu_line "0" "↩" "$C_GRAY" "Назад"
    read -r -p $'\033[36mВыбери:\033[0m ' c
    case "$c" in
      1) show_warp_xui_outbound_snippet; pause ;;
      2) show_warp_xui_google_routing_snippet; pause ;;
      3) show_warp_xui_ai_routing_snippet; pause ;;
      4) show_warp_rule_priority_tips; pause ;;
      5) show_warp_xui_manual_steps; pause ;;
      6) warp_local_socks_check; pause ;;
      0) break ;;
      *) echo -e "${C_RED}Неверный выбор.${C_RESET}"; pause ;;
    esac
  done
}

warp_menu() {
  while true; do
    show_header
    echo -e "${C_GRAY}WARP: локальный SOCKS5 через warp-cli, ручная интеграция в x-ui и отдельный watchdog для автовосстановления.${C_RESET}"
    echo
    menu_line "1" "🛡" "$C_GREEN" "Установка и управление WARP"
    menu_line "2" "🧩" "$C_CYAN" "Ручная интеграция WARP в x-ui"
    menu_line "3" "🛟" "$C_BLUE" "Watchdog и автовосстановление WARP"
    menu_line "0" "↩" "$C_GRAY" "Назад"
    read -r -p $'\033[36mВыбери:\033[0m ' c
    case "$c" in
      1) warp_runtime_menu ;;
      2) warp_xui_manual_menu ;;
      3) warp_watchdog_menu ;;
      0) break ;;
      *) echo -e "${C_RED}Неверный выбор.${C_RESET}"; pause ;;
    esac
  done
}

xray_watchdog_menu() {
  while true; do
    show_header
    echo -e "${C_GRAY}Watchdog x-ui / Xray: таймер следит за сервисом и при падении пытается поднять его автоматически.${C_RESET}"
    echo
    menu_line "1" "➕" "$C_GREEN" "Установить Xray watchdog"
    menu_line "2" "🗑" "$C_RED" "Удалить Xray watchdog"
    menu_line "3" "🛟" "$C_GREEN" "Включить автовосстановление Xray"
    menu_line "4" "🛑" "$C_RED" "Выключить автовосстановление Xray"
    menu_line "5" "📊" "$C_BLUE" "Статус автовосстановления Xray"
    menu_line "0" "↩" "$C_GRAY" "Назад"
    read -r -p $'\033[36mВыбери:\033[0m ' c
    case "$c" in
      1) install_component "$XRAY_WATCHDOG_COMP"; pause ;;
      2) remove_component "$XRAY_WATCHDOG_COMP"; pause ;;
      3) enable_xray_recovery; pause ;;
      4) disable_xray_recovery; pause ;;
      5) status_xray_recovery; pause ;;
      0) break ;;
      *) echo -e "${C_RED}Неверный выбор.${C_RESET}"; pause ;;
    esac
  done
}

reports_menu() {
  while true; do
    show_header
    echo -e "${C_GRAY}Отчёты и status: vpn-status показывает состояние стека, daily report отправляет сводку в Telegram.${C_RESET}"
    echo
    menu_line "1" "➕" "$C_GREEN" "Установить vpn-status"
    menu_line "2" "➕" "$C_GREEN" "Установить daily report"
    menu_line "3" "🗑" "$C_RED" "Удалить daily report"
    menu_line "4" "▶️" "$C_GREEN" "Включить daily report"
    menu_line "5" "⏹" "$C_RED" "Выключить daily report"
    menu_line "6" "🕘" "$C_YELLOW" "Изменить время daily report"
    menu_line "7" "📊" "$C_BLUE" "Показать статус всех automation-компонентов"
    menu_line "0" "↩" "$C_GRAY" "Назад"
    read -r -p $'\033[36mВыбери:\033[0m ' c
    case "$c" in
      1) install_component "$STATUS_COMP"; pause ;;
      2) install_component "$DAILY_COMP"; pause ;;
      3) remove_component "$DAILY_COMP"; pause ;;
      4) enable_daily_report; pause ;;
      5) disable_daily_report; pause ;;
      6) set_daily_report_time; pause ;;
      7)
         local comp
         for comp in "$WARP_WATCHDOG_COMP" "$XRAY_WATCHDOG_COMP" "$STATUS_COMP" "$DAILY_COMP" "$TG_CONTROL_COMP" "$OPTIMIZE_COMP" "$LOGROTATE_COMP"; do
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

automation_menu() {
  while true; do
    show_header
    echo -e "${C_GRAY}Мониторинг и автоматизация: отдельные watchdog для WARP и x-ui, плюс status, daily report и служебные таймеры.${C_RESET}"
    echo
    menu_line "1" "🛟" "$C_GREEN" "WARP watchdog и автовосстановление"
    menu_line "2" "⚙️" "$C_BLUE" "Xray watchdog и автовосстановление"
    menu_line "3" "📊" "$C_CYAN" "vpn-status и daily report"
    menu_line "0" "↩" "$C_GRAY" "Назад"
    read -r -p $'\033[36mВыбери:\033[0m ' c
    case "$c" in
      1) warp_watchdog_menu ;;
      2) xray_watchdog_menu ;;
      3) reports_menu ;;
      0) break ;;
      *) echo -e "${C_RED}Неверный выбор.${C_RESET}"; pause ;;
    esac
  done
}

diagnostics_menu() {
  while true; do
    show_header
    echo -e "${C_GRAY}Диагностика: быстрые проверки живости сервисов, локального WARP SOCKS и нагрузки сервера.${C_RESET}"
    echo
    menu_line "1" "🧪" "$C_CYAN" "Проверить всё"
    menu_line "2" "🤖" "$C_BLUE" "Проверить Telegram"
    menu_line "3" "🧦" "$C_GREEN" "Проверить локальный WARP SOCKS"
    menu_line "4" "🌍" "$C_CYAN" "Проверить WARP trace через SOCKS"
    menu_line "5" "⚙️" "$C_BLUE" "Проверить x-ui / Xray"
    menu_line "6" "⏱" "$C_YELLOW" "Проверить timers/services"
    menu_line "7" "💾" "$C_MAGENTA" "Проверить диск / RAM / load"
    menu_line "8" "📊" "$C_BLUE" "Показать vpn-status"
    menu_line "9" "📜" "$C_MAGENTA" "Открыть раздел журналов"
    menu_line "0" "↩" "$C_GRAY" "Назад"
    read -r -p $'\033[36mВыбери:\033[0m ' c
    case "$c" in
      1)
        echo "== Проверка всего =="
        if have_warp; then
          echo -e "WARP пакет: $(fmt_status OK)"
          echo -e "Сервис WARP: $(fmt_status "$(safe_is_active "$WARP_SERVICE_NAME")")"
          echo -e "WARP egress: $(fmt_status "$(warp_egress_state)")"
          if ip="$(curl -s4 --max-time 10 --proxy "socks5h://127.0.0.1:$(warp_proxy_port)" ifconfig.me 2>/dev/null || true)"; [[ -n "$ip" ]]; then
            echo -e "Локальный WARP SOCKS: $(fmt_status OK) ${C_GRAY}${ip}${C_RESET}"
          else
            echo -e "Локальный WARP SOCKS: $(fmt_status FAIL)"
          fi
        else
          echo -e "WARP пакет: $(fmt_status not-found)"
          echo -e "Сервис WARP: $(fmt_status not-found)"
          echo -e "WARP egress: $(fmt_status not-found)"
          echo -e "Локальный WARP SOCKS: $(fmt_status not-found)"
        fi
        echo -e "Сервис x-ui / Xray: $(fmt_status "$(safe_is_active "$XRAY_SERVICE_NAME")")"
        echo -e "Telegram token: $([[ -n "${BOT_TOKEN:-}" ]] && fmt_status OK || fmt_status FAIL)"
        echo -e "Telegram chat id: $([[ -n "${CHAT_ID:-}" ]] && fmt_status OK || fmt_status FAIL)"
        echo -e "Таймер WARP watchdog: $(fmt_status "$(safe_is_enabled "$(timer_name_for "$WARP_WATCHDOG_COMP")")")"
        echo -e "Таймер Xray watchdog: $(fmt_status "$(safe_is_enabled "$(timer_name_for "$XRAY_WATCHDOG_COMP")")")"
        echo -e "Таймер daily report: $(fmt_status "$(safe_is_enabled "$(timer_name_for "$DAILY_COMP")")")"
        pause ;;
      2) send_test_telegram; pause ;;
      3) warp_local_socks_check; pause ;;
      4)
        if have_warp; then
          curl -s --max-time 10 --socks5-hostname "127.0.0.1:$(warp_proxy_port)" "$TRACE_URL" || true
        else
          echo "WARP не установлен."
        fi
        pause ;;
      5) systemctl status "$XRAY_SERVICE_NAME" --no-pager 2>/dev/null || true; pause ;;
      6) systemctl list-timers --all | grep 'vpn-tools-' || echo "Таймеры менеджера не найдены."; pause ;;
      7) df -h /; echo; free -m; echo; uptime; pause ;;
      8)
        if [[ -x "$BIN_DIR/$STATUS_COMP.sh" ]]; then
          "$BIN_DIR/$STATUS_COMP.sh"
        else
          echo "vpn-status не установлен."
        fi
        pause ;;
      9) show_logs_menu ;;
      0) break ;;
      *) echo -e "${C_RED}Неверный выбор.${C_RESET}"; pause ;;
    esac
  done
}

show_key_paths() {
  cat <<EOF_PATHS
Ключевые пути менеджера:

- Скрипт менеджера: /root/vpn_stack_manager.sh
- Команда запуска: /usr/local/bin/vpnmenu
- Основной env-файл: ${ENV_FILE}
- Рабочие бинарники: ${BIN_DIR}
- Логи менеджера: ${LOG_DIR}
- Состояние и служебные файлы: ${STATE_DIR}
- Backup: ${BACKUP_DIR}
- Страница белого списка Happ: /var/www/html/routing.html
EOF_PATHS
}

remove_automation_components() {
  local comp
  for comp in "$OPTIMIZE_COMP" "$WARP_WATCHDOG_COMP" "$XRAY_WATCHDOG_COMP" "$STATUS_COMP" "$DAILY_COMP" "$TG_CONTROL_COMP" "$LOGROTATE_COMP"; do
    remove_component "$comp" >/dev/null 2>&1 || true
  done
}

remove_everything_except_manager() {
  remove_automation_components
  if have_warp; then
    run_cmd warp-cli --accept-tos disconnect
    apt-get remove -y cloudflare-warp >/dev/null 2>&1 || true
    rm -f /etc/apt/sources.list.d/cloudflare-client.list /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
  fi
  rm -rf "$BASE_DIR" "$LOG_DIR" "$STATE_DIR" "$LOCK_DIR"
  echo "Стек менеджера удалён, сам менеджер оставлен."
}

remove_menu() {
  while true; do
    show_header
    echo -e "${C_GRAY}Удаление: сначала удаляй отдельный компонент, если точно знаешь, что больше он не нужен.${C_RESET}"
    echo
    menu_line "1" "🗑" "$C_RED" "Удалить только WARP"
    menu_line "2" "🧹" "$C_YELLOW" "Удалить automation-компоненты и бота"
    menu_line "3" "💣" "$C_RED" "Удалить весь стек, но оставить менеджер"
    menu_line "4" "☠" "$C_RED" "Удалить всё, включая сам менеджер"
    menu_line "0" "↩" "$C_GRAY" "Назад"
    read -r -p $'\033[36mВыбери:\033[0m ' c
    case "$c" in
      1) remove_warp; pause ;;
      2) remove_automation_components; echo "Automation-компоненты и бот удалены."; pause ;;
      3)
         echo -e "${C_YELLOW}Будет удалён весь стек, но менеджер останется. Продолжить? [y/N]${C_RESET}"
         read -r ans
         [[ "${ans,,}" == "y" ]] && remove_everything_except_manager
         pause ;;
      4) self_delete_manager ;;
      0) break ;;
      *) echo -e "${C_RED}Неверный выбор.${C_RESET}"; pause ;;
    esac
  done
}

maintenance_menu() {
  while true; do
    show_header
    echo -e "${C_GRAY}Обслуживание: резервные копии, обновление менеджера, ключевые пути и удаление компонентов. Этот раздел нужен перед большими изменениями и после них.${C_RESET}"
    echo
    menu_line "1" "🗂" "$C_GREEN" "Резервные копии"
    menu_line "2" "♻️" "$C_YELLOW" "Обновление менеджера"
    menu_line "3" "📁" "$C_BLUE" "Показать ключевые пути и файлы"
    menu_line "4" "🗑" "$C_RED" "Удаление компонентов"
    menu_line "0" "↩" "$C_GRAY" "Назад"
    read -r -p $'\033[36mВыбери:\033[0m ' c
    case "$c" in
      1) backup_menu ;;
      2) update_menu ;;
      3) show_key_paths; pause ;;
      4) remove_menu ;;
      0) break ;;
      *) echo -e "${C_RED}Неверный выбор.${C_RESET}"; pause ;;
    esac
  done
}

update_menu() {
  while true; do
    show_header
    load_env
    echo -e "${C_GRAY}Обновление менеджера: можно один раз сохранить GitHub raw / GitHub blob / Яндекс Диск URL, а затем обновляться по нему без ручного ввода.${C_RESET}"
    echo -e "${C_DIM}Сохранённый URL: ${MANAGER_UPDATE_URL:-не задан}${C_RESET}"
    echo
    menu_line "1" "💾" "$C_BLUE" "Сохранить URL обновления"
    menu_line "2" "♻️" "$C_YELLOW" "Обновить менеджер по сохранённому URL"
    menu_line "3" "🌐" "$C_YELLOW" "Обновить менеджер по новому URL"
    menu_line "4" "🏷" "$C_BLUE" "Показать текущую версию"
    menu_line "5" "↩" "$C_YELLOW" "Откатить предыдущую версию"
    menu_line "0" "↩" "$C_GRAY" "Назад"
    read -r -p $'\033[36mВыбери:\033[0m ' c
    case "$c" in
      1) set_manager_update_url; pause ;;
      2) update_manager_from_saved_url; pause ;;
      3) update_manager_from_url; pause ;;
      4) echo "Версия: $APP_VERSION"; pause ;;
      5)
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

ensure_happ_shortlink_placeholder_page() {
  local html_file="${1:-/var/www/html/routing.html}"
  mkdir -p "$(dirname "$html_file")"
  if [[ -f "$html_file" ]]; then
    return 0
  fi
  cat > "$html_file" <<'EOF_HAPP_PLACEHOLDER'
<!doctype html>
<html lang="ru">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>x-route whitelist</title>
  <style>
    * { box-sizing: border-box; }
    body { margin: 0; min-height: 100vh; font-family: Arial, sans-serif; background: radial-gradient(circle at top, #102333 0, #05070a 48%, #000 100%); color: #f5fbff; display: flex; align-items: center; justify-content: center; padding: 24px; }
    .box { width: 100%; max-width: 520px; padding: 30px; background: rgba(10,18,27,.92); border: 1px solid rgba(0,210,255,.25); border-radius: 22px; box-shadow: 0 18px 60px rgba(0,0,0,.45); text-align: center; }
    h1 { margin: 0 0 12px; font-size: 25px; }
    p { margin: 10px 0; line-height: 1.55; color: #c9d7df; }
  </style>
</head>
<body>
  <div class="box">
    <h1>x-route whitelist</h1>
    <p>Белый список ещё не настроен. Открой менеджер и выбери пункт «Установить / обновить белый список Happ».</p>
  </div>
</body>
</html>
EOF_HAPP_PLACEHOLDER
  chmod 644 "$html_file" >/dev/null 2>&1 || true
}

patch_happ_shortlink_http_server() {
  local domain="${1:-x-route.shop}"
  local html_file="${2:-/var/www/html/routing.html}"
  local patched_marker="/tmp/happ_shortlink_http_patched.$$"
  rm -f "$patched_marker"

  python3 - "$domain" "$html_file" "$patched_marker" <<'PY_HAPP_NGINX_PATCH'
import re
import sys
from pathlib import Path

domain, html_file, marker = sys.argv[1:4]
paths = []
for base in (Path('/etc/nginx/sites-enabled'), Path('/etc/nginx/sites-available'), Path('/etc/nginx/conf.d')):
    if not base.exists():
        continue
    for p in base.iterdir():
        try:
            real = p.resolve()
        except Exception:
            real = p
        if real.is_file() and real not in paths:
            paths.append(real)

parent = str(Path(html_file).parent)
name = Path(html_file).name
loc_r = """
    location = /r {{
        root {parent};
        try_files /{name} =404;
        default_type text/html;
    }}
""".format(parent=parent, name=name)
loc_acme = """
    location ^~ /.well-known/acme-challenge/ {
        root /var/www/certbot;
        allow all;
    }
"""

def server_blocks(text):
    out=[]
    i=0
    while True:
        m=re.search(r'(?m)^\s*server\s*\{', text[i:])
        if not m:
            break
        start=i+m.start()
        brace=text.find('{', start)
        depth=0
        end=None
        for j in range(brace, len(text)):
            if text[j]=='{':
                depth+=1
            elif text[j]=='}':
                depth-=1
                if depth==0:
                    end=j+1
                    break
        if end is None:
            break
        out.append((start,end,text[start:end]))
        i=end
    return out

def is_target_block(block):
    if not re.search(r'\bserver_name\s+[^;]*\b' + re.escape(domain) + r'\b[^;]*;', block):
        return False
    if re.search(r'listen\s+127\.0\.0\.1:80\b', block):
        return False
    if not (re.search(r'listen\s+80\b', block) or re.search(r'listen\s+\[::\]:80\b', block)):
        return False
    if re.search(r'listen\s+[^;]*ssl', block):
        return False
    return True

changed=False
for p in paths:
    try:
        text=p.read_text(encoding='utf-8')
    except UnicodeDecodeError:
        continue
    blocks=server_blocks(text)
    if not blocks:
        continue
    new_text=text
    offset=0
    file_changed=False
    for start,end,block in blocks:
        if not is_target_block(block):
            continue
        b=block
        inserts=''
        if 'location = /r' not in b:
            inserts += loc_r
        if '.well-known/acme-challenge' not in b:
            inserts += loc_acme
        if not inserts:
            changed=True
            continue
        sm=re.search(r'(?m)^\s*server_name\s+[^;]+;', b)
        if sm:
            insert_pos=sm.end()
        else:
            insert_pos=b.find('{')+1
        b=b[:insert_pos] + "\n" + inserts + b[insert_pos:]
        s=start+offset; e=end+offset
        new_text=new_text[:s]+b+new_text[e:]
        offset += len(b)-(e-s)
        file_changed=True
        changed=True
    if file_changed:
        p.write_text(new_text, encoding='utf-8')

if changed:
    Path(marker).write_text('patched', encoding='utf-8')
PY_HAPP_NGINX_PATCH

  if [[ -f "$patched_marker" ]]; then
    rm -f "$patched_marker"
    return 0
  fi

  cat > /etc/nginx/sites-available/happ-shortlink-http <<EOF_HAPP_HTTP
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};

    location = /r {
        root $(dirname "$html_file");
        try_files /$(basename "$html_file") =404;
        default_type text/html;
    }

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/certbot;
        allow all;
    }

    location / {
        return 404;
    }
}
EOF_HAPP_HTTP
  ln -sf /etc/nginx/sites-available/happ-shortlink-http /etc/nginx/sites-enabled/happ-shortlink-http
}

ensure_happ_shortlink_infra() {
  local domain="${HAPP_SHORTLINK_DOMAIN:-x-route.shop}"
  local port="${HAPP_SHORTLINK_PORT:-8444}"
  local html_file="${HAPP_SHORTLINK_HTML:-/var/www/html/routing.html}"
  local cert_file="/etc/letsencrypt/live/${domain}/fullchain.pem"
  local key_file="/etc/letsencrypt/live/${domain}/privkey.pem"
  local conf_file="/etc/nginx/sites-available/happ-shortlink-8444"
  local short_https="https://${domain}:${port}/r"
  local short_http="http://${domain}/r"

  echo -e "${C_CYAN}Проверяю инфраструктуру короткой ссылки Happ...${C_RESET}"

  mkdir -p /var/www/html /var/www/certbot /etc/nginx/sites-available /etc/nginx/sites-enabled
  ensure_happ_shortlink_placeholder_page "$html_file"

  if ! command -v nginx >/dev/null 2>&1; then
    echo -e "${C_CYAN}Nginx не найден. Устанавливаю nginx...${C_RESET}"
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y nginx
  fi

  patch_happ_shortlink_http_server "$domain" "$html_file"

  if ! nginx -t >/dev/null 2>&1; then
    echo -e "${C_RED}Конфигурация Nginx некорректна после подготовки HTTP-блока. Проверь nginx -t.${C_RESET}"
    nginx -t || true
    return 1
  fi
  run_cmd systemctl enable nginx
  run_cmd systemctl restart nginx

  if [[ ! -f "$cert_file" || ! -f "$key_file" ]]; then
    echo -e "${C_YELLOW}Сертификат Let's Encrypt для ${domain} не найден. Пробую получить через certbot webroot.${C_RESET}"
    if ! command -v certbot >/dev/null 2>&1; then
      apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y certbot
    fi
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
      ufw allow 80/tcp >/dev/null 2>&1 || true
    fi
    certbot certonly --webroot -w /var/www/certbot -d "$domain" --non-interactive --agree-tos --register-unsafely-without-email || {
      echo -e "${C_YELLOW}Не удалось автоматически получить сертификат. HTTPS ${short_https} пока может не работать.${C_RESET}"
      echo -e "${C_DIM}Проверь DNS домена, доступность порта 80 и получи сертификат вручную, затем повтори пункт обновления белого списка.${C_RESET}"
      echo -e "${C_DIM}Запасной HTTP-вариант: ${short_http}${C_RESET}"
      return 0
    }
  fi

  if [[ -f "$cert_file" && -f "$key_file" ]]; then
    cat > "$conf_file" <<EOF_HAPP_HTTPS
server {
    listen ${port} ssl http2;
    server_name ${domain};

    ssl_certificate ${cert_file};
    ssl_certificate_key ${key_file};

    location = /r {
        root $(dirname "$html_file");
        try_files /$(basename "$html_file") =404;
        default_type text/html;
    }

    location / {
        return 404;
    }
}
EOF_HAPP_HTTPS
    ln -sf "$conf_file" /etc/nginx/sites-enabled/happ-shortlink-8444
  fi

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow "${port}/tcp" >/dev/null 2>&1 || true
  fi

  if nginx -t; then
    run_cmd systemctl restart nginx
  else
    echo -e "${C_RED}Nginx не прошёл проверку после настройки короткой ссылки.${C_RESET}"
    return 1
  fi

  echo -e "${C_GREEN}Инфраструктура короткой ссылки готова.${C_RESET}"
  echo -e "${C_GREEN}Основная ссылка для QR:${C_RESET} ${short_https}"
  echo -e "${C_DIM}Запасной HTTP-вариант:${C_RESET} ${short_http}"
  return 0
}

update_happ_whitelist_page() {
  local html_file="/var/www/html/routing.html"
  local short_https="https://x-route.shop:8444/r"
  local short_http="http://x-route.shop/r"
  local link backup_file first_line

  show_header
  echo -e "${C_CYAN}${C_BOLD}Обновление белого списка Happ${C_RESET}"
  echo -e "${C_GRAY}Вставь новую ссылку из Happ Routing Builder. Скрипт обновит /var/www/html/routing.html и оставит короткую ссылку прежней.${C_RESET}"
  echo
  echo -e "${C_DIM}Нужный формат: happ://routing/onadd/...${C_RESET}"
  echo -e "${C_DIM}Если вставишь happ://routing/add/..., скрипт автоматически заменит add на onadd.${C_RESET}"
  echo

  ensure_happ_shortlink_infra || {
    echo -e "${C_RED}Не удалось подготовить короткую ссылку Happ. Обновление страницы остановлено.${C_RESET}"
    return 1
  }
  echo
  read -r -p "Вставь ссылку Happ routing: " link || true

  link="${link//$'\r'/}"
  link="${link#${link%%[![:space:]]*}}"
  link="${link%${link##*[![:space:]]}}"

  if [[ -z "$link" ]]; then
    echo -e "${C_RED}Ссылка пустая. Ничего не изменено.${C_RESET}"
    return 1
  fi

  if [[ "$link" == happ://routing/add/* ]]; then
    link="${link/happ:\/\/routing\/add\//happ:\/\/routing\/onadd\/}"
    echo -e "${C_YELLOW}Заменил режим add на onadd, чтобы профиль применялся автоматически.${C_RESET}"
  fi

  if [[ ! "$link" =~ ^happ://routing/onadd/[A-Za-z0-9._~+/=-]+$ ]]; then
    echo -e "${C_RED}Некорректная ссылка.${C_RESET}"
    echo "Ожидается ссылка вида: happ://routing/onadd/..."
    echo "Ничего не изменено."
    return 1
  fi

  mkdir -p /var/www/html

  if [[ -f "$html_file" ]]; then
    backup_file="/root/routing.html.backup-$(date +%Y%m%d-%H%M%S)"
    cp -f "$html_file" "$backup_file"
    echo -e "${C_DIM}Backup старой страницы: ${backup_file}${C_RESET}"
  fi

  python3 - "$html_file" "$link" <<'PY_HTML'
import json
import sys
from pathlib import Path

html_path = Path(sys.argv[1])
happ_link = sys.argv[2]
happ_link_js = json.dumps(happ_link, ensure_ascii=False)

html = """<!doctype html>
<html lang=\"ru\">
<head>
  <meta charset=\"utf-8\">
  <meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">
  <title>x-route whitelist</title>
  <style>
    * { box-sizing: border-box; }
    body {
      margin: 0;
      min-height: 100vh;
      font-family: Arial, sans-serif;
      background: radial-gradient(circle at top, #102333 0, #05070a 48%, #000 100%);
      color: #f5fbff;
      display: flex;
      align-items: center;
      justify-content: center;
      padding: 24px;
    }
    .box {
      width: 100%;
      max-width: 520px;
      padding: 30px;
      background: rgba(10, 18, 27, .92);
      border: 1px solid rgba(0, 210, 255, .25);
      border-radius: 22px;
      box-shadow: 0 18px 60px rgba(0, 0, 0, .45);
      text-align: center;
    }
    .icon {
      width: 78px;
      height: 78px;
      margin: 0 auto 18px;
      border: 4px solid #16cfff;
      border-radius: 20px;
      display: flex;
      align-items: center;
      justify-content: center;
      color: #16cfff;
      font-size: 46px;
      font-weight: 900;
      line-height: 1;
    }
    h1 { margin: 0 0 12px; font-size: 25px; }
    p { margin: 10px 0; line-height: 1.55; color: #c9d7df; }
    .btn {
      display: block;
      margin-top: 24px;
      padding: 16px 18px;
      border-radius: 14px;
      background: #12cfff;
      color: #001018;
      text-align: center;
      text-decoration: none;
      font-weight: 800;
      box-shadow: 0 10px 28px rgba(18, 207, 255, .23);
    }
    .note { margin-top: 16px; font-size: 14px; color: #96a8b2; }
  </style>
</head>
<body>
  <div class=\"box\">
    <div class=\"icon\">✓</div>
    <h1>x-route whitelist</h1>
    <p>Добавляет в Happ белый список: российские сервисы открываются напрямую, остальные сайты работают через VPN.</p>
    <a id=\"btn\" class=\"btn\" href=\"#\">Добавить белый список в Happ</a>
    <p class=\"note\">Если Happ не открылся автоматически, нажмите кнопку выше.</p>
  </div>

  <script>
    const happLink = __HAPP_LINK_JS__;
    const btn = document.getElementById('btn');
    btn.href = happLink;
    setTimeout(function () {
      window.location.href = happLink;
    }, 900);
  </script>
</body>
</html>
""".replace("__HAPP_LINK_JS__", happ_link_js)

html_path.write_text(html, encoding='utf-8')
PY_HTML

  chmod 644 "$html_file" >/dev/null 2>&1 || true

  echo
  echo -e "${C_GREEN}Белый список Happ обновлён.${C_RESET}"
  echo -e "${C_GREEN}Короткая ссылка для QR:${C_RESET} ${short_https}"
  echo -e "${C_DIM}Запасной HTTP-вариант:${C_RESET} ${short_http}"
  echo
  if command -v curl >/dev/null 2>&1; then
    first_line="$(curl -k -I --max-time 8 "$short_https" 2>/dev/null | head -n1 | tr -d '\r' || true)"
    if [[ "$first_line" == *" 200"* || "$first_line" == *" 200 "* ]]; then
      echo -e "${C_GREEN}Проверка ${short_https}: ${first_line}${C_RESET}"
    else
      echo -e "${C_YELLOW}Проверка ${short_https}: ${first_line:-нет ответа}. Если порт 8444 закрыт, используй ${short_http}.${C_RESET}"
    fi
  fi
}


normalize_slash_path() {
  local p="${1:-/}"
  [[ -z "$p" ]] && p="/"
  [[ "$p" != /* ]] && p="/$p"
  [[ "$p" != */ ]] && p="$p/"
  echo "$p"
}

xui_db_path() {
  if [[ -f /etc/x-ui/x-ui.db ]]; then
    echo "/etc/x-ui/x-ui.db"
  elif [[ -f /usr/local/x-ui/bin/x-ui.db ]]; then
    echo "/usr/local/x-ui/bin/x-ui.db"
  else
    echo "/etc/x-ui/x-ui.db"
  fi
}

xui_setting_get() {
  local key="$1" db
  db="$(xui_db_path)"
  command -v sqlite3 >/dev/null 2>&1 || return 1
  [[ -f "$db" ]] || return 1
  sqlite3 "$db" "select value from settings where key='${key}' limit 1;" 2>/dev/null | head -n1
}

xui_setting_set_if_exists() {
  local key="$1" value="$2" db count
  db="$(xui_db_path)"
  command -v sqlite3 >/dev/null 2>&1 || return 1
  [[ -f "$db" ]] || return 1
  count="$(sqlite3 "$db" "select count(*) from settings where key='${key}';" 2>/dev/null | tr -d '[:space:]')"
  [[ "$count" == "1" ]] || return 1
  sqlite3 "$db" "update settings set value='${value}' where key='${key}';" 2>/dev/null
}

latest_xui_sub_port_from_logs() {
  journalctl -u x-ui -n 500 --no-pager 2>/dev/null \
    | sed -nE 's/.*Sub server running HTTP on \[[^]]+\]:([0-9]+).*/\1/p' \
    | tail -n1
}

setup_xui_https_subscription() {
  clear
  echo -e "${C_CYAN}${C_BOLD}Автонастройка HTTPS-подписки 3X-UI для Happ/iPhone${C_RESET}"
  echo -e "${C_GRAY}Скрипт поднимет Nginx HTTPS reverse proxy для HTTP Sub server 3X-UI и сделает короткую ссылку вида https://domain:8445/SUB_ID.${C_RESET}"
  echo

  local pkgs=()
  command -v curl >/dev/null 2>&1 || pkgs+=(curl)
  command -v nginx >/dev/null 2>&1 || pkgs+=(nginx)
  command -v certbot >/dev/null 2>&1 || pkgs+=(certbot python3-certbot-nginx)
  command -v sqlite3 >/dev/null 2>&1 || pkgs+=(sqlite3)
  command -v ss >/dev/null 2>&1 || pkgs+=(iproute2)
  if ((${#pkgs[@]})); then
    echo -e "${C_CYAN}Устанавливаю зависимости: ${pkgs[*]}${C_RESET}"
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"
  fi

  systemctl enable --now nginx >/dev/null 2>&1 || true

  local default_domain domain
  default_domain=""
  if [[ -d /etc/letsencrypt/live ]]; then
    default_domain="$(find /etc/letsencrypt/live -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | grep -v '^README$' | head -n1 || true)"
  fi
  read -r -p "Домен для HTTPS-подписки${default_domain:+ [$default_domain]}: " domain || true
  domain="${domain:-$default_domain}"
  if [[ -z "$domain" ]]; then
    echo -e "${C_RED}Домен не указан. Отмена.${C_RESET}"
    return 1
  fi

  local default_https_port https_port
  default_https_port="8445"
  read -r -p "Внешний HTTPS-порт для подписки [$default_https_port]: " https_port || true
  https_port="${https_port:-$default_https_port}"
  if ! [[ "$https_port" =~ ^[0-9]+$ ]]; then
    echo -e "${C_RED}Порт должен быть числом.${C_RESET}"
    return 1
  fi

  local sub_port
  sub_port="$(xui_setting_get subPort || true)"
  [[ -z "$sub_port" ]] && sub_port="$(latest_xui_sub_port_from_logs || true)"
  if [[ -z "$sub_port" ]]; then
    sub_port="$(ss -lntp 2>/dev/null | awk '/x-ui/ {split($4,a,":"); print a[length(a)]}' | grep -E '^[0-9]+$' | sort -n | tail -n1 || true)"
  fi
  read -r -p "Локальный HTTP-порт подписки 3X-UI${sub_port:+ [$sub_port]}: " _sub_port || true
  sub_port="${_sub_port:-$sub_port}"
  if ! [[ "$sub_port" =~ ^[0-9]+$ ]]; then
    echo -e "${C_RED}Не смог определить порт подписки. Укажи его из 3X-UI → Настройки панели → Подписка.${C_RESET}"
    return 1
  fi

  local sub_path
  sub_path="$(xui_setting_get subPath || true)"
  [[ -z "$sub_path" ]] && sub_path="/"
  sub_path="$(normalize_slash_path "$sub_path")"
  read -r -p "URI-путь подписки 3X-UI [$sub_path]: " _sub_path || true
  sub_path="$(normalize_slash_path "${_sub_path:-$sub_path}")"

  echo
  echo -e "${C_CYAN}Проверяю DNS...${C_RESET}"
  local server_ip domain_ip
  server_ip="$(curl -4s --max-time 8 ifconfig.me 2>/dev/null || true)"
  domain_ip="$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1; exit}')"
  echo -e "IP сервера: ${C_GREEN}${server_ip:-н/д}${C_RESET}"
  echo -e "IP домена:  ${C_GREEN}${domain_ip:-н/д}${C_RESET}"
  if [[ -n "$server_ip" && -n "$domain_ip" && "$server_ip" != "$domain_ip" ]]; then
    echo -e "${C_YELLOW}Внимание: домен сейчас указывает не на этот IPv4. Certbot может не выпустить сертификат.${C_RESET}"
    read -r -p "Продолжить? [y/N]: " yn || true
    [[ "$yn" =~ ^[YyДд]$ ]] || return 1
  fi

  echo
  echo -e "${C_CYAN}Проверяю сертификат Let's Encrypt...${C_RESET}"
  if [[ ! -f "/etc/letsencrypt/live/$domain/fullchain.pem" || ! -f "/etc/letsencrypt/live/$domain/privkey.pem" ]]; then
    echo -e "${C_YELLOW}Сертификат не найден. Выпускаю сертификат для $domain...${C_RESET}"
    if ! certbot certonly --nginx -d "$domain" --agree-tos --register-unsafely-without-email; then
      echo -e "${C_RED}Certbot не смог выпустить сертификат.${C_RESET}"
      echo -e "${C_GRAY}Проверь DNS домена, порт 80 и firewall.${C_RESET}"
      return 1
    fi
  else
    echo -e "${C_GREEN}Сертификат найден: /etc/letsencrypt/live/$domain/${C_RESET}"
  fi

  local upstream_host="127.0.0.1"
  if ! curl -s --max-time 5 -o /dev/null "http://127.0.0.1:${sub_port}/"; then
    if curl -g -s --max-time 5 -o /dev/null "http://[::1]:${sub_port}/"; then
      upstream_host="[::1]"
    else
      echo -e "${C_YELLOW}Предупреждение: локальный Sub server не ответил на 127.0.0.1:${sub_port} и [::1]:${sub_port}.${C_RESET}"
      echo -e "${C_GRAY}Если подписка выключена, включи её в 3X-UI и перезапусти панель.${C_RESET}"
    fi
  fi

  local conf_name="xui-https-subscription-${domain}-${https_port}"
  local conf_path="/etc/nginx/sites-available/${conf_name}"
  echo
  echo -e "${C_CYAN}Пишу Nginx reverse proxy: $conf_path${C_RESET}"
  cat > "$conf_path" <<EOF_NGINX
server {
    listen ${https_port} ssl http2;
    listen [::]:${https_port} ssl http2;
    server_name ${domain};

    ssl_certificate /etc/letsencrypt/live/${domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;

    # Короткая ссылка: https://${domain}:${https_port}/SUB_ID
    # Внутрь 3X-UI уйдёт как: ${sub_path}SUB_ID
    location ~ "^/([0-9A-Fa-f-]+)/?$" {
        proxy_pass http://${upstream_host}:${sub_port}${sub_path}\$1;
        proxy_http_version 1.1;

        proxy_set_header Host \$host:${https_port};
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }

    # Полный путь тоже работает: https://${domain}:${https_port}${sub_path}SUB_ID
    location / {
        proxy_pass http://${upstream_host}:${sub_port};
        proxy_http_version 1.1;

        proxy_set_header Host \$host:${https_port};
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }
}
EOF_NGINX

  ln -sf "$conf_path" "/etc/nginx/sites-enabled/${conf_name}"

  if ! nginx -t; then
    echo -e "${C_RED}Nginx config test failed. Конфиг оставлен для проверки: $conf_path${C_RESET}"
    return 1
  fi
  systemctl restart nginx

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi 'Status: active'; then
    ufw allow "${https_port}/tcp" >/dev/null 2>&1 || true
    echo -e "${C_GREEN}UFW: порт ${https_port}/tcp открыт.${C_RESET}"
  fi

  local reverse_uri="https://${domain}:${https_port}/"
  local full_reverse_uri="https://${domain}:${https_port}${sub_path}"
  echo
  echo -e "${C_CYAN}Обновляю URI обратного прокси в базе 3X-UI, если ключ subURI существует...${C_RESET}"
  if xui_setting_set_if_exists subURI "$reverse_uri"; then
    echo -e "${C_GREEN}3X-UI: subURI установлен в ${reverse_uri}${C_RESET}"
    echo -e "${C_YELLOW}Перезапускаю x-ui для применения настроек...${C_RESET}"
    systemctl restart x-ui >/dev/null 2>&1 || true
    sleep 2
  else
    echo -e "${C_YELLOW}Не удалось автоматически обновить subURI. Поставь вручную в панели:${C_RESET} ${reverse_uri}"
  fi

  echo
  echo -e "${C_GREEN}${C_BOLD}Готово.${C_RESET}"
  echo -e "${C_GREEN}URI обратного прокси для 3X-UI:${C_RESET} ${reverse_uri}"
  echo -e "${C_DIM}Полный вариант тоже будет работать:${C_RESET} ${full_reverse_uri}"
  echo -e "${C_GREEN}Формат короткой SUB-ссылки для iPhone:${C_RESET} https://${domain}:${https_port}/SUB_ID"
  echo
  echo -e "${C_CYAN}Проверка HTTPS:${C_RESET}"
  curl -k -I --max-time 10 "https://${domain}:${https_port}/" 2>/dev/null | head -n3 || true
  echo
  echo -e "${C_GRAY}После этого открой клиента в 3X-UI и скопируй SUB заново. Она должна начинаться с ${reverse_uri}${C_RESET}"
}


# =========================
# v3.8.0: clean menu + Top-5 improvements + client start page
# =========================

xray_config_file() {
  local p="/usr/local/x-ui/bin/config.json"
  [[ -f "$p" ]] && echo "$p" || return 1
}

xui_service_active_ok() {
  systemctl is-active --quiet "${XRAY_SERVICE_NAME:-x-ui}"
}

xray_backup_config_only() {
  ensure_dirs
  local cfg ts dst
  cfg="$(xray_config_file 2>/dev/null || true)"
  if [[ -z "$cfg" ]]; then
    echo -e "${C_YELLOW}Xray config.json не найден.${C_RESET}"
    return 1
  fi
  ts="$(date +%F-%H%M%S)"
  dst="$BACKUP_DIR/xray-config-$ts.json"
  cp -f "$cfg" "$dst"
  chmod 600 "$dst" 2>/dev/null || true
  echo "$dst"
}

xray_rollback_last_config() {
  local cfg last
  cfg="$(xray_config_file 2>/dev/null || true)"
  [[ -n "$cfg" ]] || { echo -e "${C_RED}Xray config.json не найден.${C_RESET}"; return 1; }
  last="$(ls -1t "$BACKUP_DIR"/xray-config-*.json 2>/dev/null | head -n1 || true)"
  [[ -n "$last" ]] || { echo -e "${C_RED}Нет backup-файлов xray-config-*.json в $BACKUP_DIR.${C_RESET}"; return 1; }
  echo -e "${C_YELLOW}Восстанавливаю:${C_RESET} $last"
  cp -f "$last" "$cfg"
  systemctl restart "${XRAY_SERVICE_NAME:-x-ui}" || true
  sleep 3
  if xui_service_active_ok; then
    echo -e "${C_GREEN}Откат выполнен, x-ui активен.${C_RESET}"
  else
    echo -e "${C_RED}Откат выполнен, но x-ui всё ещё не активен. Смотри journal.${C_RESET}"
    journalctl -u "${XRAY_SERVICE_NAME:-x-ui}" -n 40 --no-pager 2>/dev/null || true
    return 1
  fi
}

xray_safe_restart_with_rollback() {
  local backup
  backup="$(xray_backup_config_only || true)"
  [[ -n "$backup" ]] && echo -e "${C_GREEN}Backup перед рестартом:${C_RESET} $backup"
  systemctl restart "${XRAY_SERVICE_NAME:-x-ui}" || true
  sleep 4
  if xui_service_active_ok; then
    echo -e "${C_GREEN}x-ui / Xray успешно запущен.${C_RESET}"
    return 0
  fi
  echo -e "${C_RED}x-ui не поднялся после рестарта.${C_RESET}"
  if [[ -n "$backup" && -f "$backup" ]]; then
    echo -e "${C_YELLOW}Возвращаю предыдущий config.json...${C_RESET}"
    cp -f "$backup" "$(xray_config_file)"
    systemctl restart "${XRAY_SERVICE_NAME:-x-ui}" || true
    sleep 4
  fi
  if xui_service_active_ok; then
    echo -e "${C_GREEN}Автооткат сработал, x-ui снова активен.${C_RESET}"
  else
    echo -e "${C_RED}Автооткат не помог. Последние ошибки:${C_RESET}"
    journalctl -u "${XRAY_SERVICE_NAME:-x-ui}" -n 60 --no-pager 2>/dev/null | grep -Ei 'failed|error|panic|invalid|reality|xray|target' || true
    return 1
  fi
}

# Override old generic backup: include 3X-UI DB, Xray config, Nginx and manager files.
create_backup() {
  ensure_dirs
  local ts file db cfg args=()
  ts="$(date +%F-%H%M%S)"
  file="$BACKUP_DIR/backup-$ts.tar.gz"
  args+=("$BASE_DIR")
  [[ -f "$ENV_FILE" ]] && args+=("$ENV_FILE")
  [[ -d /etc/systemd/system ]] && args+=(/etc/systemd/system/vpn-tools-*)
  [[ -f /etc/logrotate.d/vpn-tools ]] && args+=(/etc/logrotate.d/vpn-tools)
  [[ -f /root/vpn_stack_manager.sh ]] && args+=(/root/vpn_stack_manager.sh)
  db="$(xui_db_path 2>/dev/null || true)"
  [[ -f "$db" ]] && args+=("$db")
  cfg="$(xray_config_file 2>/dev/null || true)"
  [[ -f "$cfg" ]] && args+=("$cfg")
  [[ -d /etc/nginx/sites-available ]] && args+=(/etc/nginx/sites-available)
  [[ -d /etc/nginx/sites-enabled ]] && args+=(/etc/nginx/sites-enabled)
  tar --ignore-failed-read -czf "$file" "${args[@]}" 2>/dev/null || true
  chmod 600 "$file" 2>/dev/null || true
  echo "Backup создан: $file"
}

write_daily_xui_backup_script() {
  ensure_dirs
  cat > "$BIN_DIR/xui-daily-backup.sh" <<'EOF_XUI_BAK'
#!/usr/bin/env bash
set -u -o pipefail
BACKUP_DIR="/root/vpn-manager-backups/xui-auto"
mkdir -p "$BACKUP_DIR"
ts="$(date +%F-%H%M%S)"
file="$BACKUP_DIR/xui-auto-$ts.tar.gz"
args=()
[[ -f /etc/x-ui/x-ui.db ]] && args+=(/etc/x-ui/x-ui.db)
[[ -f /usr/local/x-ui/bin/x-ui.db ]] && args+=(/usr/local/x-ui/bin/x-ui.db)
[[ -f /usr/local/x-ui/bin/config.json ]] && args+=(/usr/local/x-ui/bin/config.json)
[[ -d /etc/nginx/sites-available ]] && args+=(/etc/nginx/sites-available)
[[ -d /etc/nginx/sites-enabled ]] && args+=(/etc/nginx/sites-enabled)
[[ -f /root/vpn_stack_manager.sh ]] && args+=(/root/vpn_stack_manager.sh)
if ((${#args[@]})); then
  tar --ignore-failed-read -czf "$file" "${args[@]}" 2>/dev/null || true
  chmod 600 "$file" 2>/dev/null || true
fi
find "$BACKUP_DIR" -type f -name 'xui-auto-*.tar.gz' -mtime +14 -delete 2>/dev/null || true
EOF_XUI_BAK
  chmod +x "$BIN_DIR/xui-daily-backup.sh"
}

setup_daily_xui_backup() {
  ensure_dirs
  write_daily_xui_backup_script
  cat > /etc/systemd/system/vpn-tools-xui-backup.service <<EOF_SVC
[Unit]
Description=VPN tools daily 3X-UI backup

[Service]
Type=oneshot
ExecStart=$BIN_DIR/xui-daily-backup.sh
EOF_SVC
  cat > /etc/systemd/system/vpn-tools-xui-backup.timer <<'EOF_TIMER'
[Unit]
Description=Run daily 3X-UI backup

[Timer]
OnCalendar=*-*-* 03:20:00
RandomizedDelaySec=20min
Persistent=true

[Install]
WantedBy=timers.target
EOF_TIMER
  systemctl daemon-reload
  systemctl enable --now vpn-tools-xui-backup.timer
  "$BIN_DIR/xui-daily-backup.sh" || true
  echo -e "${C_GREEN}Автобэкап включён. Папка: /root/vpn-manager-backups/xui-auto${C_RESET}"
  echo -e "${C_GRAY}Хранение: последние 14 дней.${C_RESET}"
}

configure_fail2ban_and_iplimit_basics() {
  clear
  echo -e "${C_CYAN}${C_BOLD}Защита: Fail2Ban + подготовка IP Limit для 3X-UI${C_RESET}"
  echo -e "${C_GRAY}Скрипт установит Fail2Ban, включит access.log в Xray и подскажет, где ставить limitIp клиентам.${C_RESET}"
  echo
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y fail2ban python3 >/dev/null
  systemctl enable --now fail2ban >/dev/null 2>&1 || true

  local cfg backup
  cfg="$(xray_config_file 2>/dev/null || true)"
  if [[ -n "$cfg" ]]; then
    backup="$(xray_backup_config_only || true)"
    python3 - <<'PY_XRAY_LOG'
import json
p = "/usr/local/x-ui/bin/config.json"
with open(p, "r", encoding="utf-8") as f:
    cfg = json.load(f)
log = cfg.setdefault("log", {})
log["access"] = log.get("access") if log.get("access") not in (None, "", "none") else "./access.log"
log["error"] = log.get("error") if log.get("error") not in (None, "", "none") else "./error.log"
log.setdefault("loglevel", "warning")
log.setdefault("dnsLog", False)
log.setdefault("maskAddress", "")
with open(p, "w", encoding="utf-8") as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
PY_XRAY_LOG
    echo -e "${C_GREEN}Xray access.log включён.${C_RESET}"
    xray_safe_restart_with_rollback || true
  else
    echo -e "${C_YELLOW}config.json Xray не найден, access.log не менял.${C_RESET}"
  fi

  cat > /etc/fail2ban/jail.d/vpn-tools-sshd.local <<'EOF_JAIL'
[sshd]
enabled = true
backend = systemd
maxretry = 5
findtime = 10m
bantime = 1h
EOF_JAIL
  systemctl restart fail2ban >/dev/null 2>&1 || true

  echo
  echo -e "${C_GREEN}Fail2Ban установлен и включён для SSH.${C_RESET}"
  echo -e "${C_YELLOW}IP Limit клиентов включается в 3X-UI вручную:${C_RESET}"
  echo -e "${C_GRAY}Клиенты → изменить клиента → limitIp = 2 для обычного пользователя.${C_RESET}"
  echo -e "${C_GRAY}После этого 3X-UI сможет использовать access.log для подсчёта IP.${C_RESET}"
}

server_health_check() {
  clear
  echo -e "${C_CYAN}${C_BOLD}Проверка сервера одной кнопкой${C_RESET}"
  echo
  local ok=0 warn=0 fail=0
  report_ok(){ echo -e "✅ $1"; ok=$((ok+1)); }
  report_warn(){ echo -e "⚠️  $1"; warn=$((warn+1)); }
  report_fail(){ echo -e "❌ $1"; fail=$((fail+1)); }

  if xui_service_active_ok; then report_ok "x-ui / Xray сервис активен"; else report_fail "x-ui / Xray не активен"; fi

  if ss -lntp 2>/dev/null | grep -qE '[:.]443[[:space:]].*xray|\*:443.*xray'; then
    report_ok "Порт 443 слушает Xray"
  elif ss -lntp 2>/dev/null | grep -q ':443'; then
    report_warn "Порт 443 занят, но не вижу Xray в ss"
  else
    report_fail "Порт 443 не слушается"
  fi

  local sub_port sub_path sub_uri
  sub_port="$(xui_setting_get subPort 2>/dev/null || true)"
  sub_path="$(xui_setting_get subPath 2>/dev/null || true)"
  sub_uri="$(xui_setting_get subURI 2>/dev/null || true)"
  [[ -z "$sub_port" ]] && sub_port="$(latest_xui_sub_port_from_logs || true)"
  if [[ -n "$sub_port" ]] && ss -lntp 2>/dev/null | grep -q ":${sub_port}"; then
    report_ok "Sub server слушает порт $sub_port"
  elif [[ -n "$sub_port" ]]; then
    report_fail "Sub server порт $sub_port не слушается"
  else
    report_warn "Не удалось определить порт Sub server"
  fi
  [[ -n "$sub_path" ]] && report_ok "subPath найден: $sub_path" || report_warn "subPath не найден в базе"
  [[ -n "$sub_uri" ]] && report_ok "subURI найден: $sub_uri" || report_warn "subURI не задан"

  if [[ -n "$sub_uri" ]]; then
    local code
    code="$(curl -k -s -o /dev/null -w '%{http_code}' --max-time 10 "$sub_uri" 2>/dev/null || true)"
    case "$code" in
      200|301|302|404) report_ok "HTTPS reverse proxy отвечает: HTTP $code" ;;
      000|"") report_fail "HTTPS reverse proxy не отвечает: $sub_uri" ;;
      *) report_warn "HTTPS reverse proxy отвечает нестандартно: HTTP $code" ;;
    esac
  fi

  local cfg
  cfg="$(xray_config_file 2>/dev/null || true)"
  if [[ -f "$cfg" ]]; then
    if python3 -m json.tool "$cfg" >/dev/null 2>&1; then report_ok "config.json валидный JSON"; else report_fail "config.json невалидный JSON"; fi
    if grep -q '"tag"[[:space:]]*:[[:space:]]*"WARP"' "$cfg" 2>/dev/null; then report_ok "outbound WARP есть в config.json"; else report_warn "outbound WARP не найден"; fi
    if grep -q '"target"[[:space:]]*:[[:space:]]*"[^"]\+:443"' "$cfg" 2>/dev/null; then report_ok "REALITY target похож на заполненный"; else report_warn "REALITY target не найден или пустой"; fi
  else
    report_warn "Xray config.json не найден"
  fi

  if have_warp; then
    local wstate
    wstate="$(warp_egress_state 2>/dev/null || true)"
    [[ "$wstate" == "OK" ]] && report_ok "WARP egress работает" || report_warn "WARP egress: ${wstate:-н/д}"
    if curl -s --max-time 10 --socks5-hostname "127.0.0.1:$(warp_proxy_port)" "${TRACE_URL:-https://www.cloudflare.com/cdn-cgi/trace}" | grep -q 'warp=on'; then
      report_ok "Локальный WARP SOCKS отвечает warp=on"
    else
      report_warn "Локальный WARP SOCKS не подтвердил warp=on"
    fi
  else
    report_warn "WARP не установлен"
  fi

  if command -v fail2ban-client >/dev/null 2>&1 && systemctl is-active --quiet fail2ban; then report_ok "Fail2Ban активен"; else report_warn "Fail2Ban не активен"; fi
  if command -v ufw >/dev/null 2>&1 && ufw status | grep -qi 'Status: active'; then report_ok "UFW активен"; else report_warn "UFW выключен или не установлен"; fi
  if systemctl is-enabled --quiet vpn-tools-xui-backup.timer 2>/dev/null; then report_ok "Автобэкап 3X-UI включён"; else report_warn "Автобэкап 3X-UI не включён"; fi

  echo
  echo -e "${C_BOLD}Итог:${C_RESET} ✅ $ok   ⚠️ $warn   ❌ $fail"
  if ((fail>0)); then
    echo -e "${C_RED}Есть критичные проблемы. Открой журналы или пришли вывод проверки.${C_RESET}"
  else
    echo -e "${C_GREEN}Критичных проблем не найдено.${C_RESET}"
  fi
}

setup_client_start_page() {
  clear
  echo -e "${C_CYAN}${C_BOLD}Клиентская страница /start${C_RESET}"
  echo -e "${C_GRAY}Создаёт простую страницу для пользователя: скачать Happ, добавить VPN-подписку и добавить белый список.${C_RESET}"
  echo
  local pkgs=()
  command -v nginx >/dev/null 2>&1 || pkgs+=(nginx)
  command -v certbot >/dev/null 2>&1 || pkgs+=(certbot python3-certbot-nginx)
  if ((${#pkgs[@]})); then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"
  fi
  systemctl enable --now nginx >/dev/null 2>&1 || true

  local default_domain domain page_port sub_link whitelist_link title page safe_title conf
  default_domain=""
  if [[ -d /etc/letsencrypt/live ]]; then
    default_domain="$(find /etc/letsencrypt/live -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | grep -v '^README$' | head -n1 || true)"
  fi
  read -r -p "Домен для страницы${default_domain:+ [$default_domain]}: " domain || true
  domain="${domain:-$default_domain}"
  [[ -n "$domain" ]] || { echo -e "${C_RED}Домен не указан.${C_RESET}"; return 1; }

  read -r -p "HTTPS-порт страницы [/start] [8444]: " page_port || true
  page_port="${page_port:-8444}"
  [[ "$page_port" =~ ^[0-9]+$ ]] || { echo -e "${C_RED}Порт должен быть числом.${C_RESET}"; return 1; }

  if [[ ! -f "/etc/letsencrypt/live/$domain/fullchain.pem" || ! -f "/etc/letsencrypt/live/$domain/privkey.pem" ]]; then
    echo -e "${C_YELLOW}Сертификат не найден. Выпускаю Let's Encrypt для $domain...${C_RESET}"
    certbot certonly --nginx -d "$domain" --agree-tos --register-unsafely-without-email || return 1
  fi

  read -r -p "Готовая SUB-ссылка VPN для кнопки 'Добавить VPN' [можно пусто]: " sub_link || true
  read -r -p "Ссылка белого списка Happ [https://x-route.shop:8444/r]: " whitelist_link || true
  whitelist_link="${whitelist_link:-https://x-route.shop:8444/r}"
  read -r -p "Название сервиса [VPN]: " title || true
  title="${title:-VPN}"
  safe_title="$(python3 -c 'import html,sys; print(html.escape(sys.argv[1]))' "$title")"

  page="/var/www/html/vpn-start-${domain}-${page_port}.html"
  cat > "$page" <<EOF_HTML
<!doctype html>
<html lang="ru">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${safe_title}</title>
  <style>
    body{margin:0;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Arial,sans-serif;background:#0b1020;color:#eef3ff;display:flex;min-height:100vh;align-items:center;justify-content:center;padding:22px}
    .box{max-width:560px;width:100%;background:#111a33;border:1px solid #25345e;border-radius:22px;padding:26px;box-shadow:0 18px 60px rgba(0,0,0,.35)}
    h1{margin:0 0 10px;font-size:26px}.muted{color:#aebce0;line-height:1.5}.btn{display:block;text-align:center;text-decoration:none;color:white;background:#2f7cff;border-radius:14px;padding:15px 16px;margin:12px 0;font-weight:700}.btn2{background:#18a058}.btn3{background:#3a455f}.steps{background:#0c1328;border-radius:14px;padding:14px 18px;color:#cdd8f7;line-height:1.55}.small{font-size:13px;color:#8e9bc0;margin-top:14px;word-break:break-word}
  </style>
</head>
<body>
  <div class="box">
    <h1>${safe_title}</h1>
    <p class="muted">Инструкция для подключения через Happ. Сначала установи приложение, затем добавь VPN и белый список.</p>
    <a class="btn btn3" href="https://www.happ.su/main">1. Скачать Happ</a>
EOF_HTML
  if [[ -n "$sub_link" ]]; then
    cat >> "$page" <<EOF_HTML
    <a class="btn" href="$sub_link">2. Добавить VPN-подписку</a>
EOF_HTML
  else
    cat >> "$page" <<'EOF_HTML'
    <div class="steps"><b>2. Добавить VPN-подписку</b><br>Скопируй SUB-ссылку, которую выдал администратор, и добавь её в Happ как подписку.</div>
EOF_HTML
  fi
  cat >> "$page" <<EOF_HTML
    <a class="btn btn2" href="$whitelist_link">3. Добавить белый список</a>
    <div class="steps">
      <b>Проверка:</b><br>
      Android: после добавления нажми подключить.<br>
      iPhone: добавляй именно HTTPS SUB-ссылку, не HTTP.
    </div>
    <div class="small">Страница: https://${domain}:${page_port}/start</div>
  </div>
</body>
</html>
EOF_HTML

  conf="/etc/nginx/sites-available/vpn-client-start-${domain}-${page_port}"
  cat > "$conf" <<EOF_NGX
server {
    listen ${page_port} ssl http2;
    listen [::]:${page_port} ssl http2;
    server_name ${domain};

    ssl_certificate /etc/letsencrypt/live/${domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;

    location = /start {
        alias ${page};
        default_type text/html;
    }

    location / {
        return 404;
    }
}
EOF_NGX
  ln -sf "$conf" "/etc/nginx/sites-enabled/vpn-client-start-${domain}-${page_port}"
  nginx -t && systemctl restart nginx || return 1
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi 'Status: active'; then
    ufw allow "${page_port}/tcp" >/dev/null 2>&1 || true
  fi
  echo -e "${C_GREEN}Готово:${C_RESET} https://${domain}:${page_port}/start"
}

audit_external_bootstrap() {
  clear
  echo -e "${C_CYAN}${C_BOLD}Безопасная проверка внешнего bootstrap.sh${C_RESET}"
  echo -e "${C_YELLOW}Не вставляй GitHub token в чат и не храни его в команде. Используй переменную GH_TOKEN только локально на сервере.${C_RESET}"
  echo
  local url out auth=()
  read -r -p "Raw URL bootstrap.sh: " url || true
  [[ -n "$url" ]] || return 1
  out="/root/bootstrap-audit-$(date +%F-%H%M%S).sh"
  if [[ -n "${GH_TOKEN:-}" ]]; then
    auth=(-H "Authorization: token ${GH_TOKEN}")
  fi
  if ! curl -fsSL "${auth[@]}" -o "$out" "$url"; then
    echo -e "${C_RED}Не удалось скачать скрипт. Если репозиторий приватный, экспортируй GH_TOKEN локально на сервере и повтори.${C_RESET}"
    return 1
  fi
  chmod 600 "$out"
  echo -e "${C_GREEN}Скачано:${C_RESET} $out"
  echo "SHA256: $(sha256sum "$out" | awk '{print $1}')"
  echo
  if bash -n "$out"; then echo -e "${C_GREEN}bash -n: синтаксис OK${C_RESET}"; else echo -e "${C_RED}bash -n: есть синтаксические ошибки${C_RESET}"; fi
  echo
  echo -e "${C_YELLOW}Подозрительные/важные места:${C_RESET}"
  grep -nE 'curl|wget|bash -c|rm -rf|mkfs|dd if=|chmod 777|iptables|nft|ufw|systemctl|crontab|authorized_keys|GH_TOKEN|token|password|passwd' "$out" | head -n 80 || echo "Явных совпадений нет."
  echo
  read -r -p "Запустить этот bootstrap сейчас? [y/N]: " yn || true
  if [[ "$yn" =~ ^[YyДд]$ ]]; then
    bash "$out"
  else
    echo "Запуск отменён. Файл оставлен для ручной проверки: $out"
  fi
}

first_run_wizard() {
  while true; do
    show_header
    echo -e "${C_GRAY}Мастер после переустановки: выбирай сверху вниз. Каждый пункт можно запускать отдельно.${C_RESET}"
    echo
    menu_line "1" "🍏" "$C_CYAN" "Настроить HTTPS-подписку для iPhone/Happ"
    menu_line "2" "📱" "$C_GREEN" "Создать клиентскую страницу /start"
    menu_line "3" "✅" "$C_GREEN" "Установить / обновить белый список Happ"
    menu_line "4" "🧠" "$C_BLUE" "Настроить WARP для AI-доменов"
    menu_line "5" "🛡" "$C_YELLOW" "Включить защиту: Fail2Ban + access.log для IP Limit"
    menu_line "6" "💾" "$C_MAGENTA" "Включить ежедневный автобэкап 3X-UI"
    menu_line "7" "🧪" "$C_CYAN" "Проверить сервер одной кнопкой"
    menu_line "0" "↩" "$C_GRAY" "Назад"
    read -r -p $'\033[36mВыбери:\033[0m ' c
    case "$c" in
      1) setup_xui_https_subscription; pause ;;
      2) setup_client_start_page; pause ;;
      3) update_happ_whitelist_page; pause ;;
      4) quickstart_warp_xui; pause ;;
      5) configure_fail2ban_and_iplimit_basics; pause ;;
      6) setup_daily_xui_backup; pause ;;
      7) server_health_check; pause ;;
      0) break ;;
      *) echo -e "${C_RED}Неверный выбор.${C_RESET}"; pause ;;
    esac
  done
}

security_limits_menu() {
  while true; do
    show_header
    echo -e "${C_GRAY}Защита сервера: Fail2Ban, access.log для IP Limit, backup и откат Xray.${C_RESET}"
    echo
    menu_line "1" "🛡" "$C_GREEN" "Установить Fail2Ban + включить access.log для IP Limit"
    menu_line "2" "💾" "$C_BLUE" "Создать backup Xray config.json"
    menu_line "3" "↩" "$C_YELLOW" "Откатить последний Xray config.json"
    menu_line "4" "🧪" "$C_CYAN" "Безопасно перезапустить x-ui с автооткатом"
    menu_line "0" "↩" "$C_GRAY" "Назад"
    read -r -p $'\033[36mВыбери:\033[0m ' c
    case "$c" in
      1) configure_fail2ban_and_iplimit_basics; pause ;;
      2) xray_backup_config_only; pause ;;
      3) xray_rollback_last_config; pause ;;
      4) xray_safe_restart_with_rollback; pause ;;
      0) break ;;
      *) echo -e "${C_RED}Неверный выбор.${C_RESET}"; pause ;;
    esac
  done
}

repair_menu_clean() {
  while true; do
    show_header
    echo -e "${C_GRAY}Проверка и ремонт: сюда заходить, если клиент offline, подписка не открывается или x-ui упал.${C_RESET}"
    echo
    menu_line "1" "🧪" "$C_CYAN" "Проверить сервер одной кнопкой"
    menu_line "2" "🍏" "$C_CYAN" "Починить / настроить HTTPS-подписку iPhone"
    menu_line "3" "↩" "$C_YELLOW" "Откатить последний Xray config.json"
    menu_line "4" "📜" "$C_MAGENTA" "Открыть журналы"
    menu_line "5" "🔎" "$C_BLUE" "Старое расширенное меню диагностики"
    menu_line "0" "↩" "$C_GRAY" "Назад"
    read -r -p $'\033[36mВыбери:\033[0m ' c
    case "$c" in
      1) server_health_check; pause ;;
      2) setup_xui_https_subscription; pause ;;
      3) xray_rollback_last_config; pause ;;
      4) show_logs_menu ;;
      5) diagnostics_menu ;;
      0) break ;;
      *) echo -e "${C_RED}Неверный выбор.${C_RESET}"; pause ;;
    esac
  done
}

backup_menu_clean() {
  while true; do
    show_header
    echo -e "${C_GRAY}Резервные копии: база 3X-UI, Xray config, Nginx и сам менеджер.${C_RESET}"
    echo
    menu_line "1" "💾" "$C_GREEN" "Создать backup сейчас"
    menu_line "2" "🕘" "$C_BLUE" "Включить ежедневный автобэкап 3X-UI"
    menu_line "3" "📂" "$C_CYAN" "Показать backup-файлы"
    menu_line "4" "♻️" "$C_YELLOW" "Восстановить backup вручную"
    menu_line "0" "↩" "$C_GRAY" "Назад"
    read -r -p $'\033[36mВыбери:\033[0m ' c
    case "$c" in
      1) create_backup; pause ;;
      2) setup_daily_xui_backup; pause ;;
      3) echo "== $BACKUP_DIR =="; ls -lah "$BACKUP_DIR" 2>/dev/null || true; echo; echo "== $BACKUP_DIR/xui-auto =="; ls -lah "$BACKUP_DIR/xui-auto" 2>/dev/null || true; pause ;;
      4) restore_backup; pause ;;
      0) break ;;
      *) echo -e "${C_RED}Неверный выбор.${C_RESET}"; pause ;;
    esac
  done
}

settings_menu_clean() {
  while true; do
    show_header
    echo -e "${C_GRAY}Дополнительные настройки: Telegram, обновление менеджера, служебные пути и безопасная проверка внешних bootstrap-скриптов.${C_RESET}"
    echo
    menu_line "1" "🤖" "$C_BLUE" "Telegram и уведомления"
    menu_line "2" "🩺" "$C_YELLOW" "Мониторинг и автоматизация"
    menu_line "3" "♻️" "$C_YELLOW" "Обновление менеджера"
    menu_line "4" "📁" "$C_BLUE" "Показать ключевые пути"
    menu_line "5" "🧾" "$C_MAGENTA" "Проверить внешний bootstrap.sh перед запуском"
    menu_line "6" "🗑" "$C_RED" "Удаление компонентов"
    menu_line "0" "↩" "$C_GRAY" "Назад"
    read -r -p $'\033[36mВыбери:\033[0m ' c
    case "$c" in
      1) telegram_menu ;;
      2) automation_menu ;;
      3) update_menu ;;
      4) show_key_paths; pause ;;
      5) audit_external_bootstrap; pause ;;
      6) remove_menu ;;
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
    echo -e "${C_GRAY}Упрощённое меню: сначала мастер, затем подписка, страница клиента, WARP, защита, проверка и backup.${C_RESET}"
    echo
    menu_line "1" "🚀" "$C_GREEN" "Мастер после переустановки сервера"
    menu_line "2" "🍏" "$C_CYAN" "HTTPS-подписка для Happ/iPhone"
    menu_line "3" "📱" "$C_GREEN" "Клиентская страница /start"
    menu_line "4" "✅" "$C_GREEN" "Белый список Happ"
    menu_line "5" "🧠" "$C_BLUE" "WARP для AI и x-ui"
    menu_line "6" "🛡" "$C_YELLOW" "Защита и лимиты"
    menu_line "7" "🧪" "$C_CYAN" "Проверка и ремонт"
    menu_line "8" "💾" "$C_MAGENTA" "Резервные копии"
    menu_line "9" "⚙️" "$C_GRAY" "Дополнительные настройки"
    menu_line "0" "🚪" "$C_GRAY" "Выход"
    read -r -p $'\033[36mВыбери:\033[0m ' choice
    case "$choice" in
      1) first_run_wizard ;;
      2) setup_xui_https_subscription; pause ;;
      3) setup_client_start_page; pause ;;
      4) update_happ_whitelist_page; pause ;;
      5) warp_menu ;;
      6) security_limits_menu ;;
      7) repair_menu_clean ;;
      8) backup_menu_clean ;;
      9) settings_menu_clean ;;
      0) exit 0 ;;
      *) echo -e "${C_RED}Неверный выбор.${C_RESET}"; pause ;;
    esac
  done
}

require_root
main_menu
