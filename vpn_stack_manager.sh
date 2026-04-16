#!/usr/bin/env bash
set -u -o pipefail

# --- Конфигурация ---
APP_NAME="Менеджер VPN-инструментов"
APP_VERSION="3.5.0-stable"
BASE_DIR="/opt/vpn-tools"
BIN_DIR="$BASE_DIR/bin"
LOG_DIR="/var/log/vpn-tools"
STATE_DIR="/var/lib/vpn-tools"
ENV_FILE="/etc/vpn-tools.env"
BACKUP_DIR="/root/vpn-manager-backups"

# SOCKS5 / 3proxy
SOCKS5_COMP="socks5-proxy"
SOCKS5_BIN="/usr/local/bin/3proxy"
SOCKS5_CFG_FILE="$STATE_DIR/3proxy.cfg"
SOCKS5_SRC_DIR="/usr/local/src/3proxy"

# Цвета
C_RESET="\033[0m"
C_BOLD="\033[1m"
C_RED="\033[31m"
C_GREEN="\033[32m"
C_YELLOW="\033[33m"
C_CYAN="\033[36m"
C_GRAY="\033[90m"

# --- Базовые функции ---

require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo -e "${C_RED}Ошибка: Запусти скрипт от root (sudo).${C_RESET}" >&2
    exit 1
  fi
}

ensure_dirs() {
  mkdir -p "$BIN_DIR" "$LOG_DIR" "$STATE_DIR" "$BACKUP_DIR" "/usr/local/src"
}

pause() {
  read -r -p "Нажми Enter для продолжения..." _
}

# --- Логика SOCKS5 (3proxy) ---

install_3proxy_binary() {
  echo -e "${C_CYAN}Установка зависимостей для сборки...${C_RESET}"
  apt-get update
  # Для Ubuntu 24.04 критически важен libssl-dev
  DEBIAN_FRONTEND=noninteractive apt-get install -y build-essential git libssl-dev ca-certificates findutils >/dev/null 2>&1

  rm -rf "$SOCKS5_SRC_DIR"
  echo -e "${C_CYAN}Загрузка 3proxy из GitHub...${C_RESET}"
  git clone https://github.com/z3APA3A/3proxy.git "$SOCKS5_SRC_DIR" >/dev/null 2>&1 || return 1

  echo -e "${C_CYAN}Сборка (Makefile.Linux)...${C_RESET}"
  (cd "$SOCKS5_SRC_DIR" && make -f Makefile.Linux) >/dev/null 2>&1 || {
    echo -e "${C_RED}Ошибка компиляции.${C_RESET}"
    return 1
  }

  # Поиск бинарника (структура папок может меняться)
  local found_bin
  found_bin=$(find "$SOCKS5_SRC_DIR" -type f -executable -name "3proxy" | head -n 1)

  if [[ -z "$found_bin" ]]; then
    echo -e "${C_RED}Бинарник не найден после сборки.${C_RESET}"
    return 1
  fi

  cp -f "$found_bin" "$SOCKS5_BIN"
  chmod +x "$SOCKS5_BIN"
  return 0
}

write_socks5_config() {
  local login="${SOCKS5_LOGIN:-proxyuser}"
  local pass="${SOCKS5_PASSWORD:-password123}"
  local port="${SOCKS5_PORT:-1080}"

  cat > "$SOCKS5_CFG_FILE" <<EOF
daemon
maxconn 1024
nserver 1.1.1.1
nserver 8.8.8.8
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
setgid 65534
setuid 65534
flush
auth strong
users $login:CL:$pass
allow $login
socks -n -a -p$port
EOF
  chmod 600 "$SOCKS5_CFG_FILE"
}

install_socks5_proxy() {
  ensure_dirs
  if install_3proxy_binary; then
    echo -e "${C_GREEN}Бинарник готов.${C_RESET}"
    read -p "Введите логин SOCKS5: " S_USER
    read -p "Введите пароль SOCKS5: " S_PASS
    read -p "Введите порт [1080]: " S_PORT
    
    SOCKS5_LOGIN=${S_USER:-proxyuser}
    SOCKS5_PASSWORD=${S_PASS:-pass123}
    SOCKS5_PORT=${S_PORT:-1080}
    
    write_socks5_config

    # Создание системного сервиса
    cat > /etc/systemd/system/vpn-tools-socks5.service <<EOF
[Unit]
Description=3proxy SOCKS5 Gateway
After=network.target

[Service]
Type=forking
ExecStart=$SOCKS5_BIN $SOCKS5_CFG_FILE
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now vpn-tools-socks5
    echo -e "${C_GREEN}SOCKS5 успешно запущен на порту $SOCKS5_PORT${C_RESET}"
  else
    echo -e "${C_RED}Не удалось установить SOCKS5.${C_RESET}"
  fi
}

# --- Логика Обновления ---

update_manager_from_url() {
  local url
  echo -e "${C_YELLOW}Введите прямую ссылку (Raw) на скрипт из GitHub:${C_RESET}"
  read -r url
  [[ -z "$url" ]] && return 1

  local tmp_file="/tmp/vpn_manager_new.sh"
  echo -e "${C_CYAN}Загрузка обновления...${C_RESET}"
  curl -fsSL "$url" -o "$tmp_file" || { echo -e "${C_RED}Ошибка загрузки.${C_RESET}"; return 1; }

  # Проверка синтаксиса перед заменой
  if ! bash -n "$tmp_file"; then
    echo -e "${C_RED}Ошибка: скачанный файл поврежден или содержит ошибки синтаксиса.${C_RESET}"
    rm -f "$tmp_file"
    return 1
  fi

  # Бэкап текущей версии
  cp "$(readlink -f "$0")" "/root/vpn_stack_manager.backup.sh"
  
  # Замена
  mv "$tmp_file" "$(readlink -f "$0")"
  chmod +x "$(readlink -f "$0")"
  
  echo -e "${C_GREEN}Обновление завершено успешно! Перезапустите скрипт.${C_RESET}"
  exit 0
}

# --- Меню ---

show_header() {
  clear
  echo -e "${C_CYAN}${C_BOLD}=== $APP_NAME v$APP_VERSION ===${C_RESET}"
  echo -e "${C_GRAY}Система: Ubuntu 24.04 (Noble) Ready${C_RESET}"
  echo "----------------------------------------"
}

main_menu() {
  while true; do
    show_header
    echo -e "1. ${C_GREEN}Установить SOCKS5 (3proxy)${C_RESET}"
    echo -e "2. Удалить SOCKS5"
    echo -e "3. Статус сервиса SOCKS5"
    echo "----------------------------------------"
    echo -e "10. ${C_YELLOW}Обновить этот скрипт (GitHub Raw)${C_RESET}"
    echo -e "0. Выход"
    echo "----------------------------------------"
    read -p "Выберите действие: " choice

    case "$choice" in
      1) install_socks5_proxy; pause ;;
      2) systemctl disable --now vpn-tools-socks5; rm -f /etc/systemd/system/vpn-tools-socks5.service; echo "Удалено."; pause ;;
      3) systemctl status vpn-tools-socks5; pause ;;
      10) update_manager_from_url; pause ;;
      0) exit 0 ;;
      *) echo "Неверный выбор." ; sleep 1 ;;
    esac
  done
}

require_root
main_menu