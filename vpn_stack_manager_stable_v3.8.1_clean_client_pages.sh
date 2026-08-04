#!/bin/bash

# RouteX Ultimate VPN Stack Manager (v4.0.0-unified)
# Commercial-grade, interactive installer and manager for VPN & CDN Cascade setups.
# Supports Ubuntu 20.04/22.04/24.04, Debian 11/12.

set -u -o pipefail

# --- Color Theme & Fonts ---
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

# Paths & Settings
ENV_FILE="/etc/vpn-tools.env"
BASE_DIR="/opt/vpn-tools"
BIN_DIR="$BASE_DIR/bin"
LOG_DIR="/var/log/vpn-tools"
STATE_DIR="/var/lib/vpn-tools"

# Ensure directories exist
mkdir -p "$BIN_DIR" "$LOG_DIR" "$STATE_DIR"

# Root privilege check
require_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        echo -e "${C_RED}Ошибка: Запусти скрипт с правами суперпользователя (sudo / root).${C_RESET}" >&2
        exit 1
    fi
}

pause() {
    read -r -p "Нажми Enter для продолжения..." _
}

# --- System Dependencies ---
ensure_prereqs() {
    local pkgs=()
    command -v curl >/dev/null 2>&1 || pkgs+=(curl)
    command -v python3 >/dev/null 2>&1 || pkgs+=(python3)
    command -v nginx >/dev/null 2>&1 || pkgs+=(nginx)
    command -v sqlite3 >/dev/null 2>&1 || pkgs+=(sqlite3)
    command -v certbot >/dev/null 2>&1 || pkgs+=(certbot)
    command -v jq >/dev/null 2>&1 || pkgs+=(jq)
    command -v ufw >/dev/null 2>&1 || pkgs+=(ufw)
    command -v git >/dev/null 2>&1 || pkgs+=(git)
    command -v socat >/dev/null 2>&1 || pkgs+=(socat)
    
    if ((${#pkgs[@]})); then
        echo -e "${C_CYAN}Устанавливаю необходимые системные пакеты: ${pkgs[*]}...${C_RESET}"
        apt-get update -y
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"
    fi
}

# --- HTML Fake Site Template ---
install_fake_site() {
    local domain="$1"
    local web_root="/var/www/$domain"
    mkdir -p "$web_root"
    
    # Beautiful responsive HTML5 business card template
    cat > "$web_root/index.html" <<'EOF_HTML'
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>IT-Consulting & Cloud Services</title>
    <style>
        body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; background-color: #0b0f19; color: #f3f4f6; margin: 0; padding: 0; display: flex; align-items: center; justify-content: center; height: 100vh; overflow: hidden; }
        .container { text-align: center; max-width: 600px; padding: 40px; background: rgba(255, 255, 255, 0.03); border: 1px solid rgba(255, 255, 255, 0.05); border-radius: 16px; box-shadow: 0 8px 32px 0 rgba(0, 0, 0, 0.37); backdrop-filter: blur(8px); }
        h1 { color: #3b82f6; font-size: 2.5rem; margin-bottom: 10px; font-weight: 600; letter-spacing: -0.025em; }
        p { font-size: 1.1rem; line-height: 1.6; color: #9ca3af; margin-bottom: 30px; }
        .badge { display: inline-block; padding: 6px 12px; background-color: rgba(59, 130, 246, 0.1); color: #3b82f6; border-radius: 9999px; font-size: 0.85rem; font-weight: 500; margin-bottom: 20px; }
        .loader { width: 48px; height: 48px; border: 5px solid #1f2937; border-bottom-color: #3b82f6; border-radius: 50%; display: inline-block; box-sizing: border-box; animation: rotation 1s linear infinite; }
        @keyframes rotation { 0% { transform: rotate(0deg); } 100% { transform: rotate(360deg); } }
    </style>
</head>
<body>
    <div class="container">
        <div class="badge">Сервер мониторинга и оптимизации</div>
        <h1>Узел инфраструктуры IT-Consulting</h1>
        <p>Данный сервер используется для автоматического сбора сетевых метрик и оптимизации трафика распределенной облачной инфраструктуры компании.</p>
        <div class="loader"></div>
    </div>
</body>
</html>
EOF_HTML
    echo -e "${C_GREEN}Заглушка сайта успешно установлена в $web_root${C_RESET}"
}

# --- Install X-UI ---
install_xui() {
    local port="$1" user="$2" pass="$3"
    echo -e "${C_CYAN}Устанавливаю панель управления 3x-ui...${C_RESET}"
    export XUI_PORT="$port"
    export XUI_USER="$user"
    export XUI_PASS="$pass"
    bash <(curl -Ls https://raw.githubusercontent.com/morytyann/aapanel-3x-ui/master/install.sh) <<EOF
y
$user
$pass
$port
EOF
    systemctl stop x-ui || true
}

# --- Main Configuration Roles ---

# ROLE 1: RU Server (Cascade Origin)
setup_ru_server() {
    ensure_prereqs
    
    echo -e "\n${C_BOLD}${C_BLUE}=== НАСТРОЙКА RU СЕРВЕРА (ВХОДНОЙ УЗЕЛ / ORIGIN) ===${C_RESET}"
    echo -e "${C_GRAY}RU сервер принимает трафик клиентов на порту 443 и перенаправляет на зарубежный сервер.${C_RESET}\n"
    
    read -p "1. Домен для ПРЯМОГО подключения (например, cloud-packet.ru): " DIRECT_DOMAIN
    read -p "2. Домен для каскада через CDN (например, origin.cloud-packet.ru): " ORIGIN_DOMAIN
    read -p "3. Email для SSL-сертификатов (Certbot): " EMAIL
    read -p "4. Порт панели 3x-ui [24871]: " XUI_PORT
    XUI_PORT=${XUI_PORT:-24871}
    read -p "5. Логин панели 3x-ui [admin]: " XUI_USER
    XUI_USER=${XUI_USER:-admin}
    read -p "6. Пароль панели 3x-ui [admin]: " XUI_PASS
    XUI_PASS=${XUI_PASS:-admin}
    
    echo -e "\n${C_YELLOW}Вставьте VLESS ссылку вашего зарубежного (немецкого) сервера (Exit Node):${C_RESET}"
    read -p "Ссылка: " OUTBOUND_LINK
    
    # Parse Outbound Link using Python helper
    echo -e "${C_CYAN}Анализирую параметры выходного узла...${C_RESET}"
    PARSED_PARAMS=$(python3 - "$OUTBOUND_LINK" <<'EOF_PARSER'
import sys
import urllib.parse
link = sys.argv[1].strip()
try:
    if not link.startswith("vless://"):
        raise Exception("Ссылка должна начинаться с vless://")
    parsed = urllib.parse.urlparse(link)
    uuid = parsed.username
    netloc = parsed.hostname
    port = parsed.port
    query = urllib.parse.parse_qs(parsed.query)
    path = query.get('path', ['/'])[0]
    host = query.get('host', [''])[0]
    sni = query.get('sni', [''])[0]
    type_ = query.get('type', ['tcp'])[0]
    security = query.get('security', ['none'])[0]
    
    print(f"OK|{netloc}|{port}|{uuid}|{path}|{host}|{sni}|{type_}|{security}")
except Exception as e:
    print(f"ERROR|{e}")
EOF_PARSER
)

    if [[ ! "$PARSED_PARAMS" =~ ^OK ]]; then
        echo -e "${C_RED}Ошибка разбора ссылки: ${PARSED_PARAMS#*|}${C_RESET}"
        exit 1
    fi
    
    IFS='|' read -r status EXIT_ADDR EXIT_PORT EXIT_UUID EXIT_PATH EXIT_HOST EXIT_SNI EXIT_TYPE EXIT_SEC <<< "$PARSED_PARAMS"
    echo -e "${C_GREEN}Параметры успешно извлечены:${C_RESET}"
    echo -e "  - Сервер: $EXIT_ADDR:$EXIT_PORT"
    echo -e "  - UUID: $EXIT_UUID"
    echo -e "  - Транспорт: $EXIT_TYPE"
    echo -e "  - Path: $EXIT_PATH"
    echo -e "  - SNI: $EXIT_SNI"
    
    # SSL cert request
    echo -e "${C_CYAN}Останавливаю службы для выпуска SSL сертификатов...${C_RESET}"
    systemctl stop nginx || true
    
    echo -e "${C_CYAN}Выпускаю сертификат для прямого домена: $DIRECT_DOMAIN...${C_RESET}"
    certbot certonly --standalone --non-interactive --agree-tos --email "$EMAIL" -d "$DIRECT_DOMAIN"
    
    echo -e "${C_CYAN}Выпускаю сертификат для CDN домена: $ORIGIN_DOMAIN...${C_RESET}"
    certbot certonly --standalone --non-interactive --agree-tos --email "$EMAIL" -d "$ORIGIN_DOMAIN"
    
    # Web roots and fake sites
    install_fake_site "$DIRECT_DOMAIN"
    install_fake_site "$ORIGIN_DOMAIN"
    
    # 3x-ui installation
    install_xui "$XUI_PORT" "$XUI_USER" "$XUI_PASS"
    
    # DB Configuration via python3
    echo -e "${C_CYAN}Настраиваю маршрутизацию 3x-ui каскада...${C_RESET}"
    python3 - "$XUI_PORT" "$EXIT_ADDR" "$EXIT_PORT" "$EXIT_UUID" "$EXIT_PATH" "$EXIT_HOST" "$EXIT_SNI" "$EXIT_TYPE" "$EXIT_SEC" <<'EOF_XUI_SETUP'
import sys
import sqlite3
import json

xui_port, exit_addr, exit_port, exit_uuid, exit_path, exit_host, exit_sni, exit_type, exit_sec = sys.argv[1:]

db_path = "/etc/x-ui/x-ui.db"
conn = sqlite3.connect(db_path)
c = conn.cursor()

# Outbound Cascade Config
outbound = {
    "protocol": "vless",
    "settings": {
        "vnext": [{
            "address": exit_addr,
            "port": int(exit_port),
            "users": [{
                "id": exit_uuid,
                "encryption": "none",
                "flow": "xtls-rprx-vision" if exit_type == "tcp" else ""
            }]
        }]
    },
    "streamSettings": {
        "network": exit_type,
        "security": exit_sec,
        "tlsSettings": {"serverName": exit_sni, "alpn": ["h2", "http/1.1"]} if exit_sec == "tls" else {},
        "wsSettings": {"headers": {"Host": exit_host}, "path": exit_path} if exit_type == "ws" else {},
        "httpupgradeSettings": {"headers": {"Host": exit_host}, "path": exit_path} if exit_type == "httpupgrade" else {}
    },
    "tag": "Каскад"
}

# Master config update
config_json_path = "/usr/local/x-ui/bin/config.json"
try:
    with open(config_json_path, 'r') as f:
        cfg = json.load(f)
    
    # Add outbound tag "Каскад"
    cfg['outbounds'] = [o for o in cfg.get('outbounds', []) if o.get('tag') != 'Каскад']
    cfg['outbounds'].append(outbound)
    
    # Add Routing Rule
    routing_rule = {
        "type": "field",
        "inboundTag": ["in-443-tcp", "in-58522-udp"],
        "outboundTag": "Каскад"
    }
    rules = [r for r in cfg.get('routing', {}).get('rules', []) if r.get('outboundTag') != 'Каскад']
    rules.append(routing_rule)
    cfg['routing']['rules'] = rules
    
    with open(config_json_path, 'w') as f:
        json.dump(cfg, f, indent=2)
except Exception as e:
    print(f"Config update error: {e}")

conn.commit()
conn.close()
EOF_XUI_SETUP

    # Nginx Configuration
    cat > /etc/nginx/sites-available/default <<EOF_NGINX
server {
    listen 80;
    server_name $DIRECT_DOMAIN $ORIGIN_DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $DIRECT_DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DIRECT_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DIRECT_DOMAIN/privkey.pem;

    root /var/www/$DIRECT_DOMAIN;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }

    location /xhttp-route {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:8004;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}

server {
    listen 443 ssl http2;
    server_name $ORIGIN_DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$ORIGIN_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$ORIGIN_DOMAIN/privkey.pem;

    root /var/www/$ORIGIN_DOMAIN;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }

    location /cdn-cascade-route {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:8443;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOF_NGINX

    systemctl restart nginx
    systemctl start x-ui
    
    echo -e "\n${C_BOLD}${C_GREEN}=== RU СЕРВЕР УСПЕШНО НАСТРОЕН ===${C_RESET}"
    echo -e "  - Домен прямого подключения: https://$DIRECT_DOMAIN"
    echo -e "  - Домен CDN Каскада: https://$ORIGIN_DOMAIN"
    echo -e "  - Панель 3x-ui: https://YOUR_IP:$XUI_PORT"
    pause
}

# ROLE 2: Foreign Exit Server (DE / NL)
setup_exit_server() {
    ensure_prereqs
    
    echo -e "\n${C_BOLD}${C_MAGENTA}=== НАСТРОЙКА ЗАРУБЕЖНОГО СЕРВЕРА (ВЫХОДНОЙ УЗЕЛ / EXIT NODE) ===${C_RESET}"
    echo -e "${C_GRAY}Зарубежный узел обеспечивает прямой защищенный доступ к интернету.${C_RESET}\n"
    
    read -p "1. Основной домен сервера (например, exit.x-route.shop): " DOMAIN
    read -p "2. Email для SSL-сертификатов (Certbot): " EMAIL
    read -p "3. Порт панели 3x-ui [24871]: " XUI_PORT
    XUI_PORT=${XUI_PORT:-24871}
    read -p "4. Логин панели 3x-ui [admin]: " XUI_USER
    XUI_USER=${XUI_USER:-admin}
    read -p "5. Пароль панели 3x-ui [admin]: " XUI_PASS
    XUI_PASS=${XUI_PASS:-admin}
    
    # SSL cert request
    echo -e "${C_CYAN}Останавливаю службы для выпуска SSL сертификата...${C_RESET}"
    systemctl stop nginx || true
    
    certbot certonly --standalone --non-interactive --agree-tos --email "$EMAIL" -d "$DOMAIN"
    install_fake_site "$DOMAIN"
    
    # 3x-ui installation
    install_xui "$XUI_PORT" "$XUI_USER" "$XUI_PASS"
    
    # Nginx Configuration for Exit Node
    cat > /etc/nginx/sites-available/default <<EOF_EXIT_NGINX
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    root /var/www/$DOMAIN;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }

    location /cdn-cascade-route {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:8443;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOF_EXIT_NGINX

    systemctl restart nginx
    systemctl start x-ui
    
    echo -e "\n${C_BOLD}${C_GREEN}=== ЗАРУБЕЖНЫЙ ВЫХОДНОЙ СЕРВЕР УСПЕШНО НАСТРОЕН ===${C_RESET}"
    echo -e "  - Домен: https://$DOMAIN"
    echo -e "  - Панель 3x-ui: https://YOUR_IP:$XUI_PORT"
    pause
}

# --- Cloudflare WARP Support Functions ---
have_warp() {
    command -v warp-cli >/dev/null 2>&1
}

warp_cli_summary() {
    if have_warp; then
        out="$((warp-cli --accept-tos status 2>/dev/null || true) | head -n1 | sed 's/^Status update: //;s/^Status: //')"
        [[ -z "$out" ]] && out="Installed"
        echo "$out"
    else
        echo "Not Installed"
    fi
}

install_warp_client() {
    ensure_prereqs
    if have_warp; then
        echo -e "${C_GREEN}WARP клиент уже установлен.${C_RESET}"
        return 0
    fi
    echo -e "${C_CYAN}Устанавливаю Cloudflare WARP клиент...${C_RESET}"
    
    # Get GPG Key & Repo
    mkdir -p /usr/share/keyrings
    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
    
    local codename=""
    if [[ -r /etc/os-release ]]; then
        . /etc/os-release
        codename="${VERSION_CODENAME:-}"
    fi
    [[ -z "$codename" ]] && codename="jammy"
    
    cat > /etc/apt/sources.list.d/cloudflare-client.list <<EOF
deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ ${codename} main
EOF

    apt-get update -y
    apt-get install -y cloudflare-warp
    
    # Configure WARP Proxy
    systemctl enable --now warp-svc
    sleep 3
    
    yes | warp-cli --accept-tos registration new || true
    warp-cli --accept-tos mode proxy || warp-cli mode proxy || true
    warp-cli --accept-tos proxy port 40000 || warp-cli proxy port 40000 || true
    warp-cli --accept-tos connect || warp-cli connect || true

    # Install 30-Second Auto-Recovery Watchdog Service & Timer
    echo -e "${C_CYAN}Настраиваю фоновую службу мгновенного автовосстановления WARP (30 сек Watchdog)...${C_RESET}"
    mkdir -p /opt/vpn-tools/bin /var/log/vpn-tools /var/lib/vpn-tools

    cat << 'EOF_WATCHDOG' > /opt/vpn-tools/bin/warp-watchdog.sh
#!/usr/bin/env bash
set -u -o pipefail

ENV_FILE="/etc/vpn-tools.env"
LOG_FILE="/var/log/vpn-tools/warp-watchdog.log"
STATE_FILE="/var/lib/vpn-tools/warp_state"
FAIL_COUNT_FILE="/var/lib/vpn-tools/warp_fail_count"
LOCK_FILE="/var/run/warp-watchdog.lock"

mkdir -p /var/log/vpn-tools /var/lib/vpn-tools

[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

WARP_SERVICE_NAME="${WARP_SERVICE_NAME:-warp-svc}"
SOCKS_ADDR="${SOCKS_ADDR:-127.0.0.1:40000}"
TRACE_URL="${TRACE_URL:-https://www.cloudflare.com/cdn-cgi/trace}"
WARP_FAIL_THRESHOLD="${WARP_FAIL_THRESHOLD:-3}"

port="${SOCKS_ADDR##*:}"

log_msg() {
  echo "$(date '+%F %T') - $*" >> "$LOG_FILE"
}

check_warp() {
  local t ip
  t="$(curl -s --max-time 8 --socks5-hostname "$SOCKS_ADDR" "$TRACE_URL" 2>/dev/null || true)"
  if grep -q 'warp=on' <<<"$t"; then return 0; fi
  ip="$(curl -s --max-time 8 --socks5-hostname "$SOCKS_ADDR" https://api.ipify.org 2>/dev/null || true)"
  grep -Eq '^(104\.28\.|162\.159\.)' <<<"$ip" && return 0
  return 1
}

recover_warp() {
  log_msg "Выполняю перезапуск WARP..."
  systemctl restart "$WARP_SERVICE_NAME" >/dev/null 2>&1 || true
  sleep 3
  warp-cli --accept-tos mode proxy >/dev/null 2>&1 || warp-cli mode proxy >/dev/null 2>&1 || true
  warp-cli --accept-tos proxy port "$port" >/dev/null 2>&1 || warp-cli proxy port "$port" >/dev/null 2>&1 || true
  warp-cli --accept-tos connect >/dev/null 2>&1 || warp-cli connect >/dev/null 2>&1 || true
  sleep 4
  check_warp
}

exec 9>"$LOCK_FILE"
flock -n 9 || exit 0

if check_warp; then
  echo "0" > "$FAIL_COUNT_FILE"
  echo "OK" > "$STATE_FILE"
  exit 0
else
  fail_count=0
  [[ -f "$FAIL_COUNT_FILE" ]] && fail_count="$(cat "$FAIL_COUNT_FILE" 2>/dev/null || echo 0)"
  fail_count=$((fail_count + 1))
  echo "$fail_count" > "$FAIL_COUNT_FILE"
  log_msg "WARP check FAIL ${fail_count}/${WARP_FAIL_THRESHOLD}"
  
  if (( fail_count >= WARP_FAIL_THRESHOLD )); then
    log_msg "Порог превышен, перезапускаю WARP!"
    if recover_warp; then
      log_msg "✅ WARP успешно восстановлен!"
      echo "0" > "$FAIL_COUNT_FILE"
      echo "OK" > "$STATE_FILE"
      exit 0
    else
      log_msg "❌ Не удалось восстановить WARP"
      echo "FAIL" > "$STATE_FILE"
      exit 1
    fi
  fi
fi
EOF_WATCHDOG

    chmod +x /opt/vpn-tools/bin/warp-watchdog.sh

    cat << 'EOF_SERVICE' > /etc/systemd/system/vpn-tools-warp-watchdog.service
[Unit]
Description=RouteX WARP Auto-Recovery Service
After=network.target

[Service]
Type=oneshot
ExecStart=/opt/vpn-tools/bin/warp-watchdog.sh
EOF

    cat << 'EOF_TIMER' > /etc/systemd/system/vpn-tools-warp-watchdog.timer
[Unit]
Description=RouteX WARP Watchdog Timer (every 30s)

[Timer]
OnCalendar=*-*-* *:*:0/30
AccuracySec=1s
Persistent=true

[Install]
WantedBy=timers.target
EOF_TIMER

    systemctl daemon-reload
    systemctl enable --now vpn-tools-warp-watchdog.timer
    
    echo -e "${C_GREEN}WARP успешно установлен, запущен (127.0.0.1:40000) и защищен 30s Watchdog службу!${C_RESET}"
    pause
}

# --- Service Status Menu ---
services_control_menu() {
    while true; do
        clear
        echo -e "${C_BOLD}${C_CYAN}=== УПРАВЛЕНИЕ СЛУЖБАМИ И ЛОГАМИ ===${C_RESET}"
        echo -e "1. Статус службы Nginx"
        echo -e "2. Статус службы 3x-ui"
        echo -e "3. Посмотреть последние логи Nginx"
        echo -e "4. Посмотреть последние логи Xray"
        echo -e "5. Перезапустить все службы"
        echo -e "0. Назад в главное меню"
        read -p "Выберите действие [0-5]: " choice
        case $choice in
            1) systemctl status nginx --no-pager; pause ;;
            2) systemctl status x-ui --no-pager; pause ;;
            3) journalctl -u nginx -n 50 --no-pager; pause ;;
            4) journalctl -u x-ui -n 50 --no-pager; pause ;;
            5) systemctl restart nginx x-ui; echo -e "${C_GREEN}Службы перезапущены.${C_RESET}"; pause ;;
            0) break ;;
            *) echo "Неверный выбор"; pause ;;
        esac
    done
}

# --- Main Dashboard & Control Menu ---
main_menu() {
    require_root
    while true; do
        clear
        local xray_status nginx_status warp_status
        xray_status=$(systemctl is-active x-ui 2>/dev/null || echo "inactive")
        nginx_status=$(systemctl is-active nginx 2>/dev/null || echo "inactive")
        warp_status=$(warp_cli_summary)

        echo -e "${C_BOLD}${C_BLUE}======================================================${C_RESET}"
        echo -e "${C_BOLD}${C_CYAN}     RouteX Ultimate VPN & Cascade Stack Manager      ${C_RESET}"
        echo -e "${C_BOLD}${C_BLUE}======================================================${C_RESET}"
        echo -e "⚙️  Статус 3x-ui панели: $(if [ "$xray_status" = "active" ]; then echo -e "${C_GREEN}работает${C_RESET}"; else echo -e "${C_RED}остановлен${C_RESET}"; fi)"
        echo -e "🌐 Статус Nginx сервера: $(if [ "$nginx_status" = "active" ]; then echo -e "${C_GREEN}работает${C_RESET}"; else echo -e "${C_RED}остановлен${C_RED}"; fi)"
        echo -e "🛡️ Статус CF WARP:     $(if [ "$warp_status" = "Connected" ]; then echo -e "${C_GREEN}подключен${C_RESET}"; else echo -e "${C_YELLOW}$warp_status${C_RESET}"; fi)"
        echo -e "${C_BLUE}------------------------------------------------------${C_RESET}"
        echo -e "  ${C_CYAN}1.${C_RESET} Авто-настройка ${C_BOLD}ВХОДНОГО RU СЕРВЕРА (Origin / Cascade Origin)${C_RESET}"
        echo -e "  ${C_CYAN}2.${C_RESET} Авто-настройка ${C_BOLD}ЗАРУБЕЖНОГО ВЫХОДНОГО СЕРВЕРА (Exit Node)${C_RESET}"
        echo -e "  ${C_CYAN}3.${C_RESET} Управление службами, статусами и логами"
        echo -e "  ${C_CYAN}4.${C_RESET} Установить / Настроить ${C_BOLD}Cloudflare WARP SOCKS5 (с 30s Watchdog)${C_RESET}"
        echo -e "  ${C_CYAN}0.${C_RESET} Выход"
        echo -e "${C_BLUE}======================================================${C_RESET}"
        read -p "Выберите опцию [0-4]: " opt
        case $opt in
            1) setup_ru_server ;;
            2) setup_exit_server ;;
            3) services_control_menu ;;
            4) install_warp_client ;;
            0) echo -e "${C_GREEN}До свидания!${C_RESET}"; exit 0 ;;
            *) echo "Неверная опция"; pause ;;
        esac
    done
}

main_menu
