#!/bin/bash

# RouteX Ultimate VPN Stack Manager (v4.1.0-unified)
# Commercial-grade, interactive installer and manager for VPN & CDN Cascade setups.
# Supports Ubuntu 20.04/22.04/24.04, Debian 11/12.
# v4.1.0: Fixed WARP watchdog - checks real non-CF sites, uses full re-registration recovery

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

mkdir -p "$BIN_DIR" "$LOG_DIR" "$STATE_DIR"

require_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        echo -e "${C_RED}\u041e\u0448\u0438\u0431\u043a\u0430: \u0417\u0430\u043f\u0443\u0441\u0442\u0438 \u0441\u043a\u0440\u0438\u043f\u0442 \u0441 \u043f\u0440\u0430\u0432\u0430\u043c\u0438 \u0441\u0443\u043f\u0435\u0440\u043f\u043e\u043b\u044c\u0437\u043e\u0432\u0430\u0442\u0435\u043b\u044f (sudo / root).${C_RESET}" >&2
        exit 1
    fi
}

pause() {
    read -r -p "\u041d\u0430\u0436\u043c\u0438 Enter \u0434\u043b\u044f \u043f\u0440\u043e\u0434\u043e\u043b\u0436\u0435\u043d\u0438\u044f..." _
}

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
        echo -e "${C_CYAN}\u0423\u0441\u0442\u0430\u043d\u0430\u0432\u043b\u0438\u0432\u0430\u044e \u043d\u0435\u043e\u0431\u0445\u043e\u0434\u0438\u043c\u044b\u0435 \u043f\u0430\u043a\u0435\u0442\u044b: ${pkgs[*]}...${C_RESET}"
        apt-get update -y
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"
    fi
}

install_fake_site() {
    local domain="$1"
    local web_root="/var/www/$domain"
    mkdir -p "$web_root"
    cat > "$web_root/index.html" <<'EOF_HTML'
<!DOCTYPE html>
<html lang="ru"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"><title>IT-Consulting</title>
<style>body{font-family:'Segoe UI',sans-serif;background:#0b0f19;color:#f3f4f6;margin:0;display:flex;align-items:center;justify-content:center;height:100vh;overflow:hidden}.c{text-align:center;max-width:600px;padding:40px;background:rgba(255,255,255,.03);border:1px solid rgba(255,255,255,.05);border-radius:16px;box-shadow:0 8px 32px rgba(0,0,0,.37);backdrop-filter:blur(8px)}h1{color:#3b82f6;font-size:2.5rem;margin-bottom:10px}p{font-size:1.1rem;line-height:1.6;color:#9ca3af;margin-bottom:30px}.b{display:inline-block;padding:6px 12px;background:rgba(59,130,246,.1);color:#3b82f6;border-radius:9999px;font-size:.85rem;margin-bottom:20px}.l{width:48px;height:48px;border:5px solid #1f2937;border-bottom-color:#3b82f6;border-radius:50%;display:inline-block;animation:r 1s linear infinite}@keyframes r{to{transform:rotate(360deg)}}</style>
</head><body><div class="c"><div class="b">Cloud Infrastructure</div><h1>IT-Consulting Node</h1><p>Automated network metrics and traffic optimization node.</p><div class="l"></div></div></body></html>
EOF_HTML
    echo -e "${C_GREEN}Fake site installed at $web_root${C_RESET}"
}

install_xui() {
    local port="$1" user="$2" pass="$3"
    echo -e "${C_CYAN}Installing 3x-ui panel...${C_RESET}"
    bash <(curl -Ls https://raw.githubusercontent.com/morytyann/aapanel-3x-ui/master/install.sh) <<EOF
y
$user
$pass
$port
EOF
    systemctl stop x-ui || true
}

# --- Cloudflare WARP ---
have_warp() { command -v warp-cli >/dev/null 2>&1; }

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
        echo -e "${C_GREEN}WARP already installed.${C_RESET}"
        return 0
    fi
    echo -e "${C_CYAN}Installing Cloudflare WARP...${C_RESET}"
    mkdir -p /usr/share/keyrings
    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
    local codename=""
    [[ -r /etc/os-release ]] && { . /etc/os-release; codename="${VERSION_CODENAME:-}"; }
    [[ -z "$codename" ]] && codename="jammy"
    cat > /etc/apt/sources.list.d/cloudflare-client.list <<EOF
deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ ${codename} main
EOF
    apt-get update -y && apt-get install -y cloudflare-warp
    systemctl enable --now warp-svc
    sleep 3
    yes | warp-cli --accept-tos registration new || true
    warp-cli --accept-tos mode proxy || true
    warp-cli --accept-tos proxy port 40000 || true
    warp-cli --accept-tos connect || true

    # --- WARP Watchdog: checks REAL sites (not just cloudflare), full re-registration recovery ---
    echo -e "${C_CYAN}Setting up 10s Instant WARP Watchdog...${C_RESET}"
    mkdir -p /opt/vpn-tools/bin /var/log/vpn-tools /var/lib/vpn-tools

    cat << 'EOF_WATCHDOG' > /opt/vpn-tools/bin/warp-watchdog.sh
#!/usr/bin/env bash
set -u -o pipefail
LOG_FILE="/var/log/vpn-tools/warp-watchdog.log"
FAIL_COUNT_FILE="/var/lib/vpn-tools/warp_fail_count"
LOCK_FILE="/var/run/warp-watchdog.lock"
SOCKS_ADDR="127.0.0.1:40000"
mkdir -p /var/log/vpn-tools /var/lib/vpn-tools
log_msg() { echo "$(date '+%F %T') - $*" >> "$LOG_FILE"; }

# KEY: check a REAL non-Cloudflare site, not cloudflare trace!
# WARP can show warp=on but fail to route non-CF traffic (degraded state).
check_warp_real() {
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 --socks5-hostname "$SOCKS_ADDR" https://www.google.com 2>/dev/null || echo 000)"
  [[ "$code" =~ ^(200|301|302|303|307)$ ]] && return 0
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 --socks5-hostname "$SOCKS_ADDR" https://en.wikipedia.org 2>/dev/null || echo 000)"
  [[ "$code" =~ ^(200|301|302|303|307)$ ]] && return 0
  return 1
}

# Full nuclear recovery: delete registration + re-register from scratch
recover_warp() {
  log_msg "⚡ WARP degraded! Full re-registration..."
  warp-cli --accept-tos disconnect >/dev/null 2>&1 || true
  sleep 1
  warp-cli --accept-tos registration delete >/dev/null 2>&1 || true
  sleep 1
  systemctl restart warp-svc >/dev/null 2>&1 || true
  sleep 4
  warp-cli --accept-tos registration new >/dev/null 2>&1 || true
  sleep 1
  warp-cli --accept-tos mode proxy >/dev/null 2>&1 || true
  warp-cli --accept-tos proxy port 40000 >/dev/null 2>&1 || true
  warp-cli --accept-tos connect >/dev/null 2>&1 || true
  sleep 4
  check_warp_real
}

exec 9>"$LOCK_FILE"
flock -n 9 || exit 0
if check_warp_real; then
  echo "0" > "$FAIL_COUNT_FILE"
  exit 0
else
  fail_count=0
  [[ -f "$FAIL_COUNT_FILE" ]] && fail_count="$(cat "$FAIL_COUNT_FILE" 2>/dev/null || echo 0)"
  fail_count=$((fail_count + 1))
  echo "$fail_count" > "$FAIL_COUNT_FILE"
  log_msg "WARP REAL check FAIL (${fail_count}/2)"
  if (( fail_count >= 2 )); then
    if recover_warp; then
      log_msg "✅ WARP recovered via re-registration!"
      echo "0" > "$FAIL_COUNT_FILE"
      exit 0
    else
      log_msg "❌ WARP re-registration FAILED"
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
EOF_SERVICE

    cat << 'EOF_TIMER' > /etc/systemd/system/vpn-tools-warp-watchdog.timer
[Unit]
Description=RouteX WARP Watchdog (every 10s)
[Timer]
OnCalendar=*-*-* *:*:0/10
AccuracySec=1s
Persistent=true
[Install]
WantedBy=timers.target
EOF_TIMER

    systemctl daemon-reload
    systemctl enable --now vpn-tools-warp-watchdog.timer
    echo -e "${C_GREEN}WARP installed on 127.0.0.1:40000 with 10s Instant Watchdog!${C_RESET}"
    pause
}

services_control_menu() {
    while true; do
        clear
        echo -e "${C_BOLD}${C_CYAN}=== SERVICE CONTROL ===${C_RESET}"
        echo -e "1. Nginx status"
        echo -e "2. 3x-ui status"
        echo -e "3. Nginx logs"
        echo -e "4. Xray logs"
        echo -e "5. Restart all"
        echo -e "0. Back"
        read -p "Choice [0-5]: " choice
        case $choice in
            1) systemctl status nginx --no-pager; pause ;;
            2) systemctl status x-ui --no-pager; pause ;;
            3) journalctl -u nginx -n 50 --no-pager; pause ;;
            4) journalctl -u x-ui -n 50 --no-pager; pause ;;
            5) systemctl restart nginx x-ui; echo -e "${C_GREEN}Restarted.${C_RESET}"; pause ;;
            0) break ;;
            *) pause ;;
        esac
    done
}

main_menu() {
    require_root
    while true; do
        clear
        local xray_status nginx_status warp_status
        xray_status=$(systemctl is-active x-ui 2>/dev/null || echo "inactive")
        nginx_status=$(systemctl is-active nginx 2>/dev/null || echo "inactive")
        warp_status=$(warp_cli_summary)
        echo -e "${C_BOLD}${C_BLUE}======================================================${C_RESET}"
        echo -e "${C_BOLD}${C_CYAN}     RouteX VPN & Cascade Stack Manager v4.1.0       ${C_RESET}"
        echo -e "${C_BOLD}${C_BLUE}======================================================${C_RESET}"
        echo -e "  3x-ui: $([ "$xray_status" = "active" ] && echo -e "${C_GREEN}active${C_RESET}" || echo -e "${C_RED}inactive${C_RESET}")"
        echo -e "  Nginx: $([ "$nginx_status" = "active" ] && echo -e "${C_GREEN}active${C_RESET}" || echo -e "${C_RED}inactive${C_RESET}")"
        echo -e "  WARP:  $([ "$warp_status" = "Connected" ] && echo -e "${C_GREEN}connected${C_RESET}" || echo -e "${C_YELLOW}$warp_status${C_RESET}")"
        echo -e "${C_BLUE}------------------------------------------------------${C_RESET}"
        echo -e "  ${C_CYAN}1.${C_RESET} Setup ${C_BOLD}RU Server (Cascade Origin)${C_RESET}"
        echo -e "  ${C_CYAN}2.${C_RESET} Setup ${C_BOLD}Foreign Exit Server${C_RESET}"
        echo -e "  ${C_CYAN}3.${C_RESET} Service control & logs"
        echo -e "  ${C_CYAN}4.${C_RESET} Install ${C_BOLD}Cloudflare WARP (10s Watchdog)${C_RESET}"
        echo -e "  ${C_CYAN}0.${C_RESET} Exit"
        echo -e "${C_BLUE}======================================================${C_RESET}"
        read -p "Option [0-4]: " opt
        case $opt in
            1) echo "RU server setup - coming soon"; pause ;;
            2) echo "Exit server setup - coming soon"; pause ;;
            3) services_control_menu ;;
            4) install_warp_client ;;
            0) echo -e "${C_GREEN}Goodbye!${C_RESET}"; exit 0 ;;
            *) pause ;;
        esac
    done
}

main_menu
