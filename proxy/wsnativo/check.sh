#!/usr/bin/env bash
# ==============================================================================
# DIAGNÓSTICO EN VIVO — WEBSOCKET NATIVO EN C v3.0 (ANTI-DPI + MTU 1280)
# Ubicación: proxy/wsnativo/check.sh
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
echo -e "${C_CYAN}     DIAGNÓSTICO EN VIVO — WEBSOCKET NATIVO C v3.0${NC}"
echo -e "${C_CYAN}============================================================${NC}"

LIVE_PORTS=$(ss -tlpn 2>/dev/null | grep '"wsproxy-c"' | awk '{print $4}' | awk -F: '{print $NF}' | sort -un | xargs || true)

if [[ -n "$LIVE_PORTS" ]]; then
    RAM_KB=$(ps -eo rss,comm 2>/dev/null | awk '$2=="wsproxy-c" {s+=$1} END {print s+0}')
    RAM_MB=$(awk "BEGIN {printf \"%.2f MB\", ${RAM_KB:-0}/1024}")
    echo -e "${C_GREEN}● ESTADO         : ACTIVO Y ESCUCHANDO (C epoll v3.0 Anti-DPI)${NC}"
    echo -e "${C_WHITE}• Puerto(s) TCP  : ${C_GREEN}${LIVE_PORTS}${NC}"
    echo -e "${C_WHITE}• Memoria RAM    : ${C_CYAN}${RAM_MB}${NC}"
    for _p in $LIVE_PORTS; do
        _conns=$(ss -tn state established "( sport = :${_p} )" 2>/dev/null | tail -n +2 | wc -l)
        echo -e "${C_WHITE}• Conexiones :${_p} : ${C_GREEN}${_conns} clientes activos${NC}"
    done
else
    echo -e "${C_RED}○ ESTADO         : INACTIVO (No se detectó socket escuchando)${NC}"
fi

DEF_IFACE=$(ip route 2>/dev/null | awk '/^default/ {print $5; exit}')
IFACE_MTU="N/A"
if [[ -n "$DEF_IFACE" ]]; then
    IFACE_MTU=$(ip link show "$DEF_IFACE" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="mtu") print $(i+1)}' | head -1)
fi
BASE_MSS=$(sysctl -n net.ipv4.tcp_base_mss 2>/dev/null || echo "N/A")
BBR_CUR=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "N/A")
MTU_CUR=$(sysctl -n net.ipv4.tcp_mtu_probing 2>/dev/null || echo "N/A")
MSS_1220="INACTIVO"
if iptables -t mangle -S OUTPUT 2>/dev/null | grep -q 'set-mss 1220'; then
    MSS_1220="ACTIVO (MTU=1280)"
fi
WD_ST="INACTIVO"
[[ -f /etc/cron.d/crisdev-ws-c-watchdog ]] && WD_ST="ACTIVO (cada 2m)"

echo -e "${C_WHITE}• Interfaz / MTU : ${C_GREEN}${DEF_IFACE:-eth0} (NIC=${IFACE_MTU})${NC} │ WS Efectivo: ${C_GREEN}${MSS_1220}${NC}"
echo -e "${C_WHITE}• MTU Probing    : ${C_GREEN}${MTU_CUR}${NC} │ Base MSS: ${C_GREEN}${BASE_MSS}${NC} │ TCP: ${C_GREEN}${BBR_CUR}${NC}"
echo -e "${C_WHITE}• Watchdog Salud : ${C_CYAN}${WD_ST}${NC}"

if ss -tlpn 2>/dev/null | grep -q 'badvpn-udpgw'; then
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
