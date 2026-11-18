#!/usr/bin/env bash
# ==============================================================================
# DESINSTALADOR LIMPIO — BADVPN UDPGW
# Ubicación: badvpn/desinstalar.sh
# ==============================================================================

set -u

C_GREEN='\033[1;32m'
C_YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${C_YELLOW}[*] Deteniendo todos los servicios de BadVPN UDPGW...${NC}"

for svc in /etc/systemd/system/badvpn-udpgw*.service; do
    [[ -f "$svc" ]] || continue
    svc_name=$(basename "$svc")
    systemctl stop "$svc_name" 2>/dev/null || true
    systemctl disable "$svc_name" 2>/dev/null || true
    rm -f "$svc" 2>/dev/null || true
done
systemctl daemon-reload 2>/dev/null || true

for sid in $(screen -ls 2>/dev/null | grep -E 'badvpn|udpvpn' | awk '{print $1}'); do
    screen -r -S "$sid" -X quit 2>/dev/null || true
done
screen -wipe >/dev/null 2>&1 || true

pkill -9 -x badvpn-udpgw 2>/dev/null || true
[[ -f /etc/autostart ]] && sed -i '/udpvpn\|badvpn-udpgw/d' /etc/autostart 2>/dev/null || true

echo -e "${C_GREEN}✔ BadVPN UDPGW detenido y limpiado por completo.${NC}"
