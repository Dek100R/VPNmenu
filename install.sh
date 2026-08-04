#!/bin/bash
# RouteX VPN Stack Manager - Installer Bootstrap
# Downloads and runs the main script
set -euo pipefail
curl -fsSL https://raw.githubusercontent.com/Dek100R/VPNmenu/main/vpn_stack_manager_stable_v3.8.1_clean_client_pages.sh -o /tmp/vpnmenu.sh
chmod +x /tmp/vpnmenu.sh
bash /tmp/vpnmenu.sh
