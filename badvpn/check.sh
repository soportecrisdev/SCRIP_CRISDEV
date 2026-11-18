#!/usr/bin/env bash
# ==============================================================================
# AUDITORÍA Y DIAGNÓSTICO EN VIVO — BADVPN UDPGW + WSPROXY (1GB RAM MONITOR)
# Ubicación: badvpn/check.sh
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
echo -e "${C_CYAN}     AUDITORÍA EN VIVO — BADVPN UDPGW & SALUD DE RAM${NC}"
echo -e "${C_CYAN}============================================================${NC}"

# 1. Puertos TCP reales de BadVPN
BAD_PORTS=$(ss -tlpn 2>/dev/null | grep 'badvpn-udpgw' | awk '{print $4}' | awk -F: '{print $NF}' | sort -un | xargs || true)

if [[ -n "$BAD_PORTS" ]]; then
    echo -e "${C_GREEN}● ESTADO BADVPN  : ACTIVO Y BLINDADO${NC}"
    echo -e "${C_WHITE}• Puerto(s) TCP  : ${C_GREEN}${BAD_PORTS}${NC} (127.0.0.1)"
    for _p in $BAD_PORTS; do
        _conns=$(ss -tn state established "( sport = :${_p} )" 2>/dev/null | tail -n +2 | wc -l)
        echo -e "${C_WHITE}• Clientes :${_p} : ${C_CYAN}${_conns} sesiones activas${NC}"
    done
else
    echo -e "${C_RED}○ ESTADO BADVPN  : INACTIVO${NC}"
fi

echo -e "${C_CYAN}------------------------------------------------------------${NC}"

# 2. Consumo de RAM por servicio crítico
ram_proc_mb() {
    local kb
    kb=$(ps -ef 2>/dev/null | grep -E "$1" | grep -v grep | awk '{s+=$6} END {print s+0}')
    awk "BEGIN {printf \"%.1f MB\", ${kb:-0}/1024}"
}

RAM_BAD=$(ram_proc_mb 'badvpn-udpgw')
RAM_WS=$(ram_proc_mb 'wsproxy\.py|wsproxy-c')
RAM_SSH=$(ram_proc_mb 'sshd:')
RAM_TOT=$(free -m 2>/dev/null | awk '/^Mem:/ {printf "%d/%d MB (Libre: %d MB)", $3, $2, $7}')
SWAP_TOT=$(free -m 2>/dev/null | awk '/^Swap:/ {printf "%d/%d MB", $3, $2}')

echo -e "${C_WHITE}• RAM BadVPN     : ${C_GREEN}${RAM_BAD}${NC}"
echo -e "${C_WHITE}• RAM WebSocket  : ${C_GREEN}${RAM_WS}${NC}"
echo -e "${C_WHITE}• RAM SSHD Users : ${C_YELLOW}${RAM_SSH}${NC}"
echo -e "${C_WHITE}• RAM Total VPS  : ${C_CYAN}${RAM_TOT}${NC}"
echo -e "${C_WHITE}• SWAP Anti-OOM  : ${C_CYAN}${SWAP_TOT}${NC}"

# 3. Salud de tabla conntrack y MTU
CT_CUR=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo "N/A")
CT_MAX=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo "N/A")
BBR_CUR=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "N/A")
MTU_PRB=$(sysctl -n net.ipv4.tcp_mtu_probing 2>/dev/null || echo "N/A")

echo -e "${C_CYAN}------------------------------------------------------------${NC}"
echo -e "${C_WHITE}• Conntrack NAT  : ${C_GREEN}${CT_CUR} / ${CT_MAX}${NC}"
echo -e "${C_WHITE}• TCP BBR / MTU  : ${C_GREEN}${BBR_CUR}${NC} │ MTU Probing: ${C_GREEN}${MTU_PRB}${NC}"
echo -e "${C_CYAN}============================================================${NC}"
read -n1 -r -p "Presione cualquier tecla para volver..."
