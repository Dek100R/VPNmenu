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
    echo -e "${C_CYAN}Настраиваю базу данных Xray (создание инбаундов и маршрутов)...${C_RESET}"
    python3 - <<EOF
import sqlite3
import json

db_path = "/etc/x-ui/x-ui.db"
conn = sqlite3.connect(db_path)
cursor = conn.cursor()

# 1. Direct Inbound (Port 10443, Local, TLS terminated by Nginx)
stream_5 = {
  "network": "xhttp",
  "xhttpSettings": { "path": "/xhttp-route" },
  "security": "none",
  "externalProxy": []
}

settings_5 = {
  "clients": [
    {
      "id": "$EXIT_UUID",
      "email": "Direct-Client",
      "enable": True,
      "limitIp": 0,
      "totalGB": 0,
      "expiryTime": 0
    }
  ],
  "decryption": "none",
  "encryption": "none"
}

# 2. CDN Cascade Inbound (Port 30007, Local, TLS terminated by Nginx)
stream_7 = {
  "network": "httpupgrade",
  "httpupgradeSettings": {
    "acceptProxyProtocol": False,
    "path": "/cdn-cascade-route",
    "host": "",
    "headers": {}
  },
  "security": "none",
  "externalProxy": []
}

settings_7 = {
  "clients": [
    {
      "id": "$EXIT_UUID",
      "email": "CDN-Cascade-Client",
      "enable": True,
      "limitIp": 0,
      "totalGB": 0,
      "expiryTime": 0
    }
  ],
  "decryption": "none",
  "encryption": "none"
}

sniffing = {
  "enabled": True,
  "destOverride": ["http", "tls", "quic", "fakedns"]
}

# Clear previous entries
cursor.execute("DELETE FROM inbounds WHERE port=10443 OR tag='in-10443-direct'")
cursor.execute("DELETE FROM inbounds WHERE port=30007 OR tag='in-30007-cdn-cascade'")

# Insert direct inbound
cursor.execute("""
    INSERT INTO inbounds (user_id, up, down, total, remark, enable, expiry_time, traffic_reset, 
    last_traffic_reset_time, listen, port, protocol, settings, stream_settings, tag, sniffing, origin_node_guid)
    VALUES (1, 0, 0, 0, 'Direct-Inbound', 1, 0, 'never', 0, '127.0.0.1', 10443, 'vless', ?, ?, 'in-10443-direct', ?, '')
""", (json.dumps(settings_5), json.dumps(stream_5), json.dumps(sniffing)))

# Insert CDN inbound
cursor.execute("""
    INSERT INTO inbounds (user_id, up, down, total, remark, enable, expiry_time, traffic_reset, 
    last_traffic_reset_time, listen, port, protocol, settings, stream_settings, tag, sniffing, origin_node_guid)
    VALUES (1, 0, 0, 0, 'CDN-Cascade-Inbound', 1, 0, 'never', 0, '127.0.0.1', 30007, 'vless', ?, ?, 'in-30007-cdn-cascade', ?, '')
""", (json.dumps(settings_7), json.dumps(stream_7), json.dumps(sniffing)))

# 3. Setup Xray Template Routing & Outbounds
xray_template = {
  "api": {
    "services": ["HandlerService", "LoggerService", "StatsService"],
    "tag": "api"
  },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": 62789,
      "protocol": "tunnel",
      "settings": { "rewriteAddress": "127.0.0.1" },
      "tag": "api"
    }
  ],
  "log": {
    "access": "./access.log",
    "dnsLog": False,
    "error": "./error.log",
    "loglevel": "warning"
  },
  "metrics": {
    "listen": "127.0.0.1:11111",
    "tag": "metrics_out"
  },
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": {
        "domainStrategy": "AsIs",
        "finalRules": [{"action": "allow"}]
      }
    },
    {
      "tag": "Germany-CDN",
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "$EXIT_ADDR",
            "port": int("$EXIT_PORT"),
            "users": [
              {
                "id": "$EXIT_UUID",
                "flow": "$EXIT_TYPE" if "$EXIT_TYPE" == "xtls-rprx-vision" else "",
                "encryption": "none"
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "$EXIT_TYPE",
        "security": "$EXIT_SEC",
        "tlsSettings": {
          "serverName": "$EXIT_SNI",
          "alpn": ["h2", "http/1.1"]
        }
      }
    },
    {
      "tag": "blocked",
      "protocol": "blackhole",
      "settings": {}
    }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "inboundTag": ["in-30007-cdn-cascade", "in-10443-direct"],
        "outboundTag": "Germany-CDN"
      },
      {
        "inboundTag": ["api"],
        "outboundTag": "api",
        "type": "field"
      },
      {
        "ip": ["geoip:private"],
        "outboundTag": "blocked",
        "type": "field"
      }
    ]
  }
}

# Update settings
cursor.execute("UPDATE settings SET value=? WHERE key='xrayTemplateConfig'", (json.dumps(xray_template, indent=2, ensure_ascii=False),))
conn.commit()
conn.close()
EOF

    # Configure Nginx Reverse Proxy
    echo -e "${C_CYAN}Настраиваю конфигурацию Nginx...${C_RESET}"
    
    nginx_conf="server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $DIRECT_DOMAIN;

    ssl_certificate     /etc/letsencrypt/live/$DIRECT_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DIRECT_DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    root /var/www/$DIRECT_DOMAIN;
    index index.html;

    location /xhttp-route {
        proxy_pass http://127.0.0.1:10443;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \"upgrade\";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_buffering off;
        proxy_request_buffering off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $ORIGIN_DOMAIN;

    ssl_certificate     /etc/letsencrypt/live/$ORIGIN_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$ORIGIN_DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    root /var/www/$ORIGIN_DOMAIN;
    index index.html;

    location /cdn-cascade-route {
        proxy_pass http://127.0.0.1:30007;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \"upgrade\";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_buffering off;
        proxy_request_buffering off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
"
    echo "$nginx_conf" > /etc/nginx/sites-available/routex-inbounds
    ln -sf /etc/nginx/sites-available/routex-inbounds /etc/nginx/sites-enabled/routex-inbounds
    rm -f /etc/nginx/sites-enabled/default || true
    
    # Configure Firewall Ports
    ufw allow 22/tcp
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw allow "$XUI_PORT"/tcp
    ufw --force enable
    
    # Test Nginx and restart all
    nginx -t
    systemctl restart nginx
    systemctl start x-ui
    
    echo -e "\n${C_GREEN}===================================================${C_RESET}"
    echo -e "${C_GREEN}       RU СЕРВЕР УСПЕШНО НАСТРОЕН И ЗАПУЩЕН!      ${C_RESET}"
    echo -e "${C_GREEN}===================================================${C_RESET}"
    echo -e "  - Прямой VPN:  ${C_CYAN}vless://$EXIT_UUID@$DIRECT_DOMAIN:443?path=/xhttp-route&security=tls&type=xhttp${C_RESET}"
    echo -e "  - CDN Каскад:  ${C_CYAN}vless://$EXIT_UUID@cdn.cloud-packet.ru:443?path=/cdn-cascade-route&security=tls&type=httpupgrade${C_RESET}"
    echo -e "  - Панель X-UI: ${C_YELLOW}http://YOUR_SERVER_IP:$XUI_PORT${C_RESET}"
    echo -e "${C_GREEN}===================================================${C_RESET}\n"
    pause
}

# ROLE 2: DE Server (Cascade Exit Node)
setup_de_server() {
    ensure_prereqs
    
    echo -e "\n${C_BOLD}${C_BLUE}=== НАСТРОЙКА GERMANY СЕРВЕРА (ВЫХОДНОЙ УЗЕЛ / EXIT NODE) ===${C_RESET}"
    echo -e "${C_GRAY}Этот сервер является конечной точкой и обеспечивает выход в открытый интернет.${C_RESET}\n"
    
    read -p "1. Домен сервера (например, de.cloud-packet.ru): " DE_DOMAIN
    read -p "2. Email для SSL-сертификатов (Certbot): " EMAIL
    read -p "3. Порт панели 3x-ui [24871]: " XUI_PORT
    XUI_PORT=${XUI_PORT:-24871}
    read -p "4. Логин панели 3x-ui [admin]: " XUI_USER
    XUI_USER=${XUI_USER:-admin}
    read -p "5. Пароль панели 3x-ui [admin]: " XUI_PASS
    XUI_PASS=${XUI_PASS:-admin}
    
    echo -e "\n${C_CYAN}Останавливаю службы для выпуска SSL сертификатов...${C_RESET}"
    systemctl stop nginx || true
    
    echo -e "${C_CYAN}Выпускаю сертификат для домена: $DE_DOMAIN...${C_RESET}"
    certbot certonly --standalone --non-interactive --agree-tos --email "$EMAIL" -d "$DE_DOMAIN"
    
    install_fake_site "$DE_DOMAIN"
    
    install_xui "$XUI_PORT" "$XUI_USER" "$XUI_PASS"
    
    # Database config on exit node
    echo -e "${C_CYAN}Настраиваю базу данных Xray на выходном узле...${C_RESET}"
    python3 - <<EOF
import sqlite3
import json
import uuid

db_path = "/etc/x-ui/x-ui.db"
conn = sqlite3.connect(db_path)
cursor = conn.cursor()

# Generate UUID for clients
client_uuid = str(uuid.uuid4())
print(f"CLIENT_UUID:{client_uuid}")

# 1. Direct inbound (Port 10443, Local, proxy-passed by Nginx)
stream_5 = {
  "network": "xhttp",
  "xhttpSettings": { "path": "/xhttp-route" },
  "security": "none"
}
settings_5 = {
  "clients": [
    { "id": client_uuid, "email": "Direct-Client", "enable": True, "limitIp": 0, "totalGB": 0, "expiryTime": 0 }
  ],
  "decryption": "none",
  "encryption": "none"
}

# 2. CDN inbound (Port 30007, Local, proxy-passed by Nginx)
stream_7 = {
  "network": "httpupgrade",
  "httpupgradeSettings": { "acceptProxyProtocol": False, "path": "/cdn-cascade-route", "host": "", "headers": {} },
  "security": "none"
}
settings_7 = {
  "clients": [
    { "id": client_uuid, "email": "CDN-Cascade-Client", "enable": True, "limitIp": 0, "totalGB": 0, "expiryTime": 0 }
  ],
  "decryption": "none",
  "encryption": "none"
}

sniffing = { "enabled": True, "destOverride": ["http", "tls", "quic", "fakedns"] }

cursor.execute("DELETE FROM inbounds WHERE port=10443 OR tag='in-10443-direct'")
cursor.execute("DELETE FROM inbounds WHERE port=30007 OR tag='in-30007-cdn-cascade'")

cursor.execute("""
    INSERT INTO inbounds (user_id, up, down, total, remark, enable, expiry_time, traffic_reset, 
    last_traffic_reset_time, listen, port, protocol, settings, stream_settings, tag, sniffing, origin_node_guid)
    VALUES (1, 0, 0, 0, 'Direct-Inbound', 1, 0, 'never', 0, '127.0.0.1', 10443, 'vless', ?, ?, 'in-10443-direct', ?, '')
""", (json.dumps(settings_5), json.dumps(stream_5), json.dumps(sniffing)))

cursor.execute("""
    INSERT INTO inbounds (user_id, up, down, total, remark, enable, expiry_time, traffic_reset, 
    last_traffic_reset_time, listen, port, protocol, settings, stream_settings, tag, sniffing, origin_node_guid)
    VALUES (1, 0, 0, 0, 'CDN-Cascade-Inbound', 1, 0, 'never', 0, '127.0.0.1', 30007, 'vless', ?, ?, 'in-30007-cdn-cascade', ?, '')
""", (json.dumps(settings_7), json.dumps(stream_7), json.dumps(sniffing)))

# Save client UUID to state directory for referencing
with open("/var/lib/vpn-tools/client_uuid", "w") as f:
    f.write(client_uuid)

conn.commit()
conn.close()
EOF

    # Retrieve Client UUID generated by python
    CLIENT_UUID=$(cat /var/lib/vpn-tools/client_uuid)

    # Configure Nginx Reverse Proxy for DE Node
    nginx_conf="server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $DE_DOMAIN;

    ssl_certificate     /etc/letsencrypt/live/$DE_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DE_DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    root /var/www/$DE_DOMAIN;
    index index.html;

    location /xhttp-route {
        proxy_pass http://127.0.0.1:10443;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \"upgrade\";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_buffering off;
        proxy_request_buffering off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }

    location /cdn-cascade-route {
        proxy_pass http://127.0.0.1:30007;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \"upgrade\";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_buffering off;
        proxy_request_buffering off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
"
    echo "$nginx_conf" > /etc/nginx/sites-available/routex-exit
    ln -sf /etc/nginx/sites-available/routex-exit /etc/nginx/sites-enabled/routex-exit
    rm -f /etc/nginx/sites-enabled/default || true
    
    # Configure Firewall Ports
    ufw allow 22/tcp
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw allow "$XUI_PORT"/tcp
    ufw --force enable
    
    nginx -t
    systemctl restart nginx
    systemctl start x-ui
    
    echo -e "\n${C_GREEN}===================================================${C_RESET}"
    echo -e "${C_GREEN}       DE СЕРВЕР (EXIT NODE) УСПЕШНО НАСТРОЕН!      ${C_RESET}"
    echo -e "${C_GREEN}===================================================${C_RESET}"
    echo -e "  - VLESS Link: ${C_CYAN}vless://$CLIENT_UUID@$DE_DOMAIN:443?path=/cdn-cascade-route&security=tls&type=httpupgrade#Germany-CDN-Exit${C_RESET}"
    echo -e "  - UUID Клиента: ${C_YELLOW}$CLIENT_UUID${C_RESET}"
    echo -e "${C_GRAY}Скопируйте VLESS ссылку выше и вставьте её при настройке RU сервера.${C_RESET}"
    echo -e "${C_GREEN}===================================================${C_RESET}\n"
    pause
}

# ROLE 3: Standalone VPN Server
setup_standalone_server() {
    ensure_prereqs
    
    echo -e "\n${C_BOLD}${C_BLUE}=== СТАНДАРТНАЯ НАСТРОЙКА ОДИНОЧНОГО ВПН СЕРВЕРА ===${C_RESET}"
    
    read -p "1. Домен сервера (например, vpn.cloud-packet.ru): " DOMAIN
    read -p "2. Email для SSL-сертификатов (Certbot): " EMAIL
    read -p "3. Порт панели 3x-ui [24871]: " XUI_PORT
    
    echo -e "\n${C_CYAN}Останавливаю службы для выпуска SSL сертификата...${C_RESET}"
    systemctl stop nginx || true
    
    certbot certonly --standalone --non-interactive --agree-tos --email "$EMAIL" -d "$DOMAIN"
    
    install_fake_site "$DOMAIN"
    
    install_xui "$XUI_PORT" "admin" "admin"
    
    # Simple direct inbound (Port 10443)
    echo -e "${C_CYAN}Настраиваю базу данных Xray...${C_RESET}"
    python3 - <<EOF
import sqlite3
import json
import uuid

db_path = "/etc/x-ui/x-ui.db"
conn = sqlite3.connect(db_path)
cursor = conn.cursor()

client_uuid = str(uuid.uuid4())
print(f"CLIENT_UUID:{client_uuid}")

stream_5 = {
  "network": "xhttp",
  "xhttpSettings": { "path": "/xhttp-route" },
  "security": "none"
}
settings_5 = {
  "clients": [
    { "id": client_uuid, "email": "User1", "enable": True, "limitIp": 0, "totalGB": 0, "expiryTime": 0 }
  ],
  "decryption": "none",
  "encryption": "none"
}

sniffing = { "enabled": True, "destOverride": ["http", "tls", "quic", "fakedns"] }

cursor.execute("DELETE FROM inbounds WHERE port=10443 OR tag='in-10443-direct'")

cursor.execute("""
    INSERT INTO inbounds (user_id, up, down, total, remark, enable, expiry_time, traffic_reset, 
    last_traffic_reset_time, listen, port, protocol, settings, stream_settings, tag, sniffing, origin_node_guid)
    VALUES (1, 0, 0, 0, 'VLESS-XHTTP-Inbound', 1, 0, 'never', 0, '127.0.0.1', 10443, 'vless', ?, ?, 'in-10443-direct', ?, '')
""", (json.dumps(settings_5), json.dumps(stream_5), json.dumps(sniffing)))

with open("/var/lib/vpn-tools/client_uuid", "w") as f:
    f.write(client_uuid)

conn.commit()
conn.close()
EOF

    CLIENT_UUID=$(cat /var/lib/vpn-tools/client_uuid)

    # Configure Nginx Reverse Proxy
    nginx_conf="server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate     /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    root /var/www/$DOMAIN;
    index index.html;

    location /xhttp-route {
        proxy_pass http://127.0.0.1:10443;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \"upgrade\";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_buffering off;
        proxy_request_buffering off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
"
    echo "$nginx_conf" > /etc/nginx/sites-available/routex-standalone
    ln -sf /etc/nginx/sites-available/routex-standalone /etc/nginx/sites-enabled/routex-standalone
    rm -f /etc/nginx/sites-enabled/default || true
    
    # Configure Firewall Ports
    ufw allow 22/tcp
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw allow "$XUI_PORT"/tcp
    ufw --force enable
    
    nginx -t
    systemctl restart nginx
    systemctl start x-ui
    
    echo -e "\n${C_GREEN}===================================================${C_RESET}"
    echo -e "${C_GREEN}       ВПН СЕРВЕР СТАНДАРТНО НАСТРОЕН И ЗАПУЩЕН!   ${C_RESET}"
    echo -e "${C_GREEN}===================================================${C_RESET}"
    echo -e "  - VLESS Link: ${C_CYAN}vless://$CLIENT_UUID@$DOMAIN:443?path=/xhttp-route&security=tls&type=xhttp#Standalone-VPN${C_RESET}"
    echo -e "  - Панель X-UI: ${C_YELLOW}http://YOUR_SERVER_IP:$XUI_PORT${C_RESET}"
    echo -e "${C_GREEN}===================================================${C_RESET}\n"
    pause
}

# --- Cloudflare WARP Support Functions ---
have_warp() {
    command -v warp-cli >/dev/null 2>&1
}

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
    warp-cli --accept-tos mode proxy
    warp-cli --accept-tos proxy port 40000
    warp-cli --accept-tos connect
    
    echo -e "${C_GREEN}WARP успешно установлен и запущен на локальном SOCKS5 порту: 127.0.0.1:40000${C_RESET}"
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
        echo -e "5. Перезапустить Nginx"
        echo -e "6. Перезапустить X-UI"
        echo -e "0. Назад"
        echo
        read -r -p "Выбери действие: " act
        case "$act" in
            1) systemctl status nginx --no-pager; pause ;;
            2) systemctl status x-ui --no-pager; pause ;;
            3) tail -n 50 /var/log/nginx/error.log /var/log/nginx/access.log 2>/dev/null || true; pause ;;
            4) journalctl -u x-ui -n 50 --no-pager; pause ;;
            5) systemctl restart nginx; echo -e "${C_GREEN}Nginx перезапущен.${C_RESET}"; pause ;;
            6) systemctl restart x-ui; echo -e "${C_GREEN}X-UI перезапущен.${C_RESET}"; pause ;;
            0) break ;;
            *) echo -e "${C_RED}Неверный выбор.${C_RESET}"; pause ;;
        esac
    done
}

# --- Main CLI Menu ---
main_menu() {
    require_root
    while true; do
        clear
        echo -e "${C_BOLD}${C_BLUE}====================================================${C_RESET}"
        echo -e "${C_BOLD}${C_BLUE}     RouteX Ultimate VPN Stack Manager v4.0.0      ${C_RESET}"
        echo -e "${C_BOLD}${C_BLUE}====================================================${C_RESET}"
        
        # Display short statuses
        local xray_status nginx_status warp_status
        xray_status=$(systemctl is-active x-ui 2>/dev/null || echo "inactive")
        nginx_status=$(systemctl is-active nginx 2>/dev/null || echo "inactive")
        warp_status=$(warp_cli_summary)
        
        echo -e "🧩 Статус X-UI Panel:  $(if [ "$xray_status" = "active" ]; then echo -e "${C_GREEN}активен${C_RESET}"; else echo -e "${C_RED}неактивен${C_RESET}"; fi)"
        echo -e "🌐 Статус Nginx Proxy: $(if [ "$nginx_status" = "active" ]; then echo -e "${C_GREEN}активен${C_RESET}"; else echo -e "${C_RED}неактивен${C_RESET}"; fi)"
        echo -e "🛡️ Статус CF WARP:     $(if [ "$warp_status" = "Connected" ]; then echo -e "${C_GREEN}подключен${C_RESET}"; else echo -e "${C_YELLOW}$warp_status${C_RESET}"; fi)"
        echo -e "${C_GRAY}────────────────────────────────────────────────────${C_RESET}"
        echo -e "${C_BOLD}РАЗВЕРТЫВАНИЕ И УСТАНОВКА:${C_RESET}"
        echo -e "  ${C_CYAN}1.${C_RESET} Настроить ${C_BOLD}RU Сервер${C_RESET} (Входной узел / Cascade Origin)"
        echo -e "  ${C_CYAN}2.${C_RESET} Настроить ${C_BOLD}Зарубежный Сервер${C_RESET} (Выходной узел / Cascade Exit)"
        echo -e "  ${C_CYAN}3.${C_RESET} Настроить ${C_BOLD}Одиночный ВПН Сервер${C_RESET} (Standalone)"
        echo -e "${C_BOLD}ДОПОЛНИТЕЛЬНЫЕ ИНСТРУМЕНТЫ:${C_RESET}"
        echo -e "  ${C_CYAN}4.${C_RESET} Установить / Настроить ${C_BOLD}Cloudflare WARP SOCKS5${C_RESET}"
        echo -e "  ${C_CYAN}5.${C_RESET} Управление службами и логами (Nginx / X-UI)"
        echo -e "  ${C_CYAN}0.${C_RESET} Выход"
        echo -e "${C_BLUE}====================================================${C_RESET}"
        
        read -r -p "Выберите опцию: " opt
        case "$opt" in
            1) setup_ru_server ;;
            2) setup_de_server ;;
            3) setup_standalone_server ;;
            4) install_warp_client ;;
            5) services_control_menu ;;
            0) echo "Выход..."; exit 0 ;;
            *) echo -e "${C_RED}Неверный выбор.${C_RESET}"; pause ;;
        esac
    done
}

# Run the menu
main_menu
