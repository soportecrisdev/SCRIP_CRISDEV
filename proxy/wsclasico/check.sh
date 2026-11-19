#!/usr/bin/env bash
# ==============================================================================
# DIAGNÓSTICO EN VIVO — WEBSOCKET CLÁSICO PYTHON v4.7
# Ubicación: proxy/wsclasico/check.sh
# ==============================================================================

set -u

C_CYAN='\033[1;36m'
C_GREEN='\033[1;32m'
C_YELLOW='\033[1;33m'
C_RED='\033[1;31m'
C_WHITE='\033[1;37m'
NC='\033[0m'

clear
echo -e "${C_CYAN}============================================================${NC}"
echo -e "${C_CYAN}     DIAGNÓSTICO EN VIVO — WEBSOCKET PYTHON v4.7${NC}"
echo -e "${C_CYAN}============================================================${NC}"

PIDS=$(pgrep -f 'wsproxy\.py' 2>/dev/null | tr '\n' '|' | sed 's/|$//')
LIVE_PORTS=""
if [[ -n "$PIDS" ]]; then
    LIVE_PORTS=$(ss -tlpn 2>/dev/null | grep -E "pid=(${PIDS})," | awk '{print $4}' | awk -F: '{print $NF}' | sort -un | xargs)
fi

if [[ -n "$LIVE_PORTS" ]]; then
    RAM_KB=$(ps -ef 2>/dev/null | grep '[w]sproxy\.py' | awk '{s+=$6} END {print s+0}')
    RAM_MB=$(awk "BEGIN {printf \"%.1f MB\", ${RAM_KB:-0}/1024}")
    echo -e "${C_GREEN}● ESTADO         : ACTIVO Y ESCUCHANDO${NC}"
    echo -e "${C_WHITE}• Puerto(s) TCP  : ${C_GREEN}${LIVE_PORTS}${NC}"
    echo -e "${C_WHITE}• Memoria RAM    : ${C_CYAN}${RAM_MB}${NC}"
else
    echo -e "${C_RED}○ ESTADO         : INACTIVO (No se detectó socket escuchando)${NC}"
fi

# Verificar MTU Probing y BBR
BBR_CUR=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "N/A")
MTU_CUR=$(sysctl -n net.ipv4.tcp_mtu_probing 2>/dev/null || echo "N/A")
MSS_CLAMP="INACTIVO"
if iptables -t mangle -S POSTROUTING 2>/dev/null | grep -q 'clamp-mss-to-pmtu'; then
    MSS_CLAMP="ACTIVO"
fi

echo -e "${C_WHITE}• Congestión TCP : ${C_GREEN}${BBR_CUR}${NC}"
echo -e "${C_WHITE}• MTU Probing    : ${C_GREEN}${MTU_CUR}${NC} │ MSS Clamping: ${C_GREEN}${MSS_CLAMP}${NC}"

if pgrep -x badvpn-udpgw >/dev/null 2>&1 || pgrep -x udpvpn >/dev/null 2>&1; then
    echo -e "${C_WHITE}• BadVPN (7300)  : ${C_GREEN}● ACTIVO (Juegos y Llamadas VoIP listos)${NC}"
else
    echo -e "${C_WHITE}• BadVPN (7300)  : ${C_YELLOW}○ INACTIVO${NC}"
fi

echo -e "${C_CYAN}------------------------------------------------------------${NC}"
if [[ -n "$LIVE_PORTS" ]]; then
    for _p in $LIVE_PORTS; do
        echo -e "${C_YELLOW}[TEST] Handshake HTTP en http://127.0.0.1:${_p}/ :${NC}"
        curl -i -s -N --max-time 3 "http://127.0.0.1:${_p}/" | head -8 || true
        echo ""
    done
fi

echo -e "${C_CYAN}============================================================${NC}"
read -n1 -r -p "Presione cualquier tecla para volver..."
