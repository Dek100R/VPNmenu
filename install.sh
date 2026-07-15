#!/bin/bash

# RouteX One-Click VPN & CDN Cascade Installer
# Target OS: Ubuntu 20.04/22.04/24.04, Debian 11/12

set -e

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}===============================================${NC}"
echo -e "${BLUE}      RouteX One-Click VPN & CDN Installer     ${NC}"
echo -e "${BLUE}===============================================${NC}"

# Check root privilege
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: Please run as root.${NC}"
    exit 1
fi

# 1. Gather configuration values from user
read -p "Enter Direct VPN domain (e.g., cloud-packet.ru): " DIRECT_DOMAIN
read -p "Enter CDN Origin domain (e.g., origin.cloud-packet.ru): " ORIGIN_DOMAIN
read -p "Enter Email for SSL Certificates: " EMAIL
read -p "Enter Xray Admin Port [24871]: " XUI_PORT
XUI_PORT=${XUI_PORT:-24871}
read -p "Enter Xray Admin Username [admin]: " XUI_USER
XUI_USER=${XUI_USER:-admin}
read -p "Enter Xray Admin Password [admin]: " XUI_PASS
XUI_PASS=${XUI_PASS:-admin}

echo -e "\n${YELLOW}--- Germany (Exit Node) Settings ---${NC}"
read -p "Enter Germany IP/Address [64.188.72.75]: " EXIT_ADDR
EXIT_ADDR=${EXIT_ADDR:-64.188.72.75}
read -p "Enter Germany Port [8443]: " EXIT_PORT
EXIT_PORT=${EXIT_PORT:-8443}
read -p "Enter Germany VLESS UUID [41f58200-24ea-4b4d-b16a-d8e044754127]: " EXIT_UUID
EXIT_UUID=${EXIT_UUID:-41f58200-24ea-4b4d-b16a-d8e044754127}
read -p "Enter Germany Path [/cdn-cascade-route]: " EXIT_PATH
EXIT_PATH=${EXIT_PATH:-/cdn-cascade-route}
read -p "Enter Germany SNI [x-route.shop]: " EXIT_SNI
EXIT_SNI=${EXIT_SNI:-x-route.shop}
read -p "Enter Germany Host [relay-cdn.x-route.shop]: " EXIT_HOST
EXIT_HOST=${EXIT_HOST:-relay-cdn.x-route.shop}

echo -e "\n${GREEN}Starting installation...${NC}"

# 2. Update packages and install dependencies
apt-get update -y
apt-get install -y curl wget socat git cron nginx sqlite3 python3 certbot python3-certbot-nginx ufw

# 3. Configure Firewall
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow "$XUI_PORT"/tcp
ufw --force enable

# 4. Request Let's Encrypt Certificates
echo -e "${YELLOW}Requesting SSL certificates...${NC}"
systemctl stop nginx || true

# Request cert for DIRECT_DOMAIN
certbot certonly --standalone --non-interactive --agree-tos --email "$EMAIL" -d "$DIRECT_DOMAIN"

# Request cert for ORIGIN_DOMAIN
certbot certonly --standalone --non-interactive --agree-tos --email "$EMAIL" -d "$ORIGIN_DOMAIN"

# 5. Install 3x-ui
echo -e "${YELLOW}Installing 3x-ui panel...${NC}"
export XUI_PORT="$XUI_PORT"
export XUI_USER="$XUI_USER"
export XUI_PASS="$XUI_PASS"
bash <(curl -Ls https://raw.githubusercontent.com/morytyann/aapanel-3x-ui/master/install.sh) <<EOF
y
$XUI_USER
$XUI_PASS
$XUI_PORT
EOF

# Ensure XUI service is stopped while we modify the DB
systemctl stop x-ui || true

# 6. Configure 3x-ui Database (inbounds, settings, template routing)
echo -e "${YELLOW}Configuring Xray database...${NC}"

python3 - <<EOF
import sqlite3
import json

db_path = "/etc/x-ui/x-ui.db"
conn = sqlite3.connect(db_path)
cursor = conn.cursor()

# 6.1 Create Inbound 5: VLESS-XHTTP (Direct connection on local port 10443)
stream_5 = {
  "network": "xhttp",
  "xhttpSettings": {
    "path": "/xhttp-route",
    "extra": {}
  },
  "security": "none",
  "externalProxy": []
}

settings_5 = {
  "clients": [
    {
      "id": "173bcb8b-784d-493d-bf2e-590148b20f36",
      "email": "Obhod",
      "enable": True,
      "limitIp": 0,
      "totalGB": 0,
      "expiryTime": 0
    }
  ],
  "decryption": "none",
  "encryption": "none"
}

sniffing_5 = {
  "enabled": True,
  "destOverride": ["http", "tls", "quic", "fakedns"]
}

# Remove existing with same port/tag if any
cursor.execute("DELETE FROM inbounds WHERE port=10443 OR tag='in-10443-direct'")

cursor.execute("""
    INSERT INTO inbounds (
        user_id, up, down, total, remark, enable, expiry_time, traffic_reset, 
        last_traffic_reset_time, listen, port, protocol, settings, stream_settings, tag, sniffing, origin_node_guid
    ) VALUES (1, 0, 0, 0, 'Direct-XHTTP-Inbound', 1, 0, 'never', 0, '127.0.0.1', 10443, 'vless', ?, ?, 'in-10443-direct', ?, '')
""", (json.dumps(settings_5), json.dumps(stream_5), json.dumps(sniffing_5)))

# 6.2 Create Inbound 7: VLESS-HTTPUpgrade (CDN Cascade connection on local port 30007)
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
      "id": "173bcb8b-784d-493d-bf2e-590148b20f36",
      "email": "Obhod",
      "enable": True,
      "limitIp": 0,
      "totalGB": 0,
      "expiryTime": 0
    }
  ],
  "decryption": "none",
  "encryption": "none"
}

sniffing_7 = {
  "enabled": True,
  "destOverride": ["http", "tls", "quic", "fakedns"]
}

# Remove existing with same port/tag if any
cursor.execute("DELETE FROM inbounds WHERE port=30007 OR tag='in-30007-cdn-cascade'")

cursor.execute("""
    INSERT INTO inbounds (
        user_id, up, down, total, remark, enable, expiry_time, traffic_reset, 
        last_traffic_reset_time, listen, port, protocol, settings, stream_settings, tag, sniffing, origin_node_guid
    ) VALUES (1, 0, 0, 0, 'CDN-Cascade-Inbound', 1, 0, 'never', 0, '127.0.0.1', 30007, 'vless', ?, ?, 'in-30007-cdn-cascade', ?, '')
""", (json.dumps(settings_7), json.dumps(stream_7), json.dumps(sniffing_7)))

# 6.3 Update xrayTemplateConfig (Routing Rules and Outbounds)
xray_template = {
  "api": {
    "services": [
      "HandlerService",
      "LoggerService",
      "StatsService"
    ],
    "tag": "api"
  },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": 62789,
      "protocol": "tunnel",
      "settings": {
        "rewriteAddress": "127.0.0.1"
      },
      "tag": "api"
    }
  ],
  "log": {
    "access": "./access.log",
    "dnsLog": False,
    "error": "./error.log",
    "loglevel": "warning",
    "maskAddress": ""
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
        "finalRules": [
          {"action": "allow"}
        ]
      }
    },
    {
      "tag": "Germany-CDN",
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "$EXIT_ADDR",
            "port": $EXIT_PORT,
            "users": [
              {
                "id": "$EXIT_UUID",
                "flow": "",
                "encryption": "none"
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "httpupgrade",
        "httpupgradeSettings": {
          "path": "$EXIT_PATH",
          "host": "$EXIT_HOST",
          "headers": {}
        },
        "security": "tls",
        "tlsSettings": {
          "serverName": "$EXIT_SNI",
          "alpn": [
            "h2",
            "http/1.1"
          ]
        }
      }
    },
    {
      "tag": "blocked",
      "protocol": "blackhole",
      "settings": {}
    }
  ],
  "policy": {
    "system": {
      "statsInboundDownlink": True,
      "statsInboundUplink": True,
      "statsOutboundDownlink": False,
      "statsOutboundUplink": False
    },
    "levels": {
      "0": {
        "statsUserDownlink": True,
        "statsUserUplink": True
      }
    }
  },
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "inboundTag": [
          "in-30007-cdn-cascade",
          "in-10443-direct"
        ],
        "outboundTag": "Germany-CDN"
      },
      {
        "inboundTag": [
          "api"
        ],
        "outboundTag": "api",
        "type": "field"
      },
      {
        "ip": [
          "geoip:private"
        ],
        "outboundTag": "blocked",
        "type": "field"
      },
      {
        "outboundTag": "blocked",
        "protocol": [
          "bittorrent"
        ],
        "type": "field"
      }
    ]
  },
  "stats": {}
}

# Update settings table
cursor.execute("UPDATE settings SET value=? WHERE key='xrayTemplateConfig'", (json.dumps(xray_template, indent=2, ensure_ascii=False),))
conn.commit()
conn.close()
print("Xray DB configured successfully.")
EOF

# 7. Configure Nginx
echo -e "${YELLOW}Configuring Nginx routing...${NC}"

nginx_config="server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $DIRECT_DOMAIN;

    ssl_certificate     /etc/letsencrypt/live/$DIRECT_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DIRECT_DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    client_max_body_size 0;
    client_header_buffer_size 64k;
    large_client_header_buffers 8 128k;

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

    client_max_body_size 0;
    client_header_buffer_size 64k;
    large_client_header_buffers 8 128k;

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

echo "$nginx_config" > /etc/nginx/sites-available/routex-inbounds
ln -sf /etc/nginx/sites-available/routex-inbounds /etc/nginx/sites-enabled/routex-inbounds
rm -f /etc/nginx/sites-enabled/default || true

# Test Nginx syntax
nginx -t

# 8. Start Services
echo -e "${YELLOW}Starting X-UI and Nginx services...${NC}"
systemctl restart nginx
systemctl start x-ui

echo -e "\n${GREEN}===============================================${NC}"
echo -e "${GREEN}             INSTALLATION COMPLETE             ${NC}"
echo -e "${GREEN}===============================================${NC}"
echo -e "${BLUE}Direct VPN domain: ${NC}$DIRECT_DOMAIN"
echo -e "${BLUE}CDN Origin domain: ${NC}$ORIGIN_DOMAIN"
echo -e "${BLUE}X-UI Panel Port:   ${NC}$XUI_PORT"
echo -e "${BLUE}X-UI Username:     ${NC}$XUI_USER"
echo -e "${BLUE}X-UI Password:     ${NC}$XUI_PASS"
echo -e "${BLUE}Germany Cascade Target: ${NC}$EXIT_ADDR:$EXIT_PORT"
echo -e "${YELLOW}Please verify that both domains are pointed correctly before connecting.${NC}"
echo -e "${BLUE}===============================================${NC}"
