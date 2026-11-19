#!/usr/bin/env bash
# ==============================================================================
# DIAGNÓSTICO EN VIVO — HCR RELAY (HTTP CUSTOM RELAY)
# Ubicación: proxy/hcr/check.sh
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
echo -e "${C_CYAN}           DIAGNÓSTICO EN VIVO — HCR RELAY${NC}"
echo -e "${C_CYAN}============================================================${NC}"

LIVE_PORTS=$(ss -tlpn 2>/dev/null | grep '"hcr-server"' | awk '{print $4}' | awk -F: '{print $NF}' | sort -un | xargs || true)

if [[ -n "$LIVE_PORTS" ]]; then
    RAM_KB=$(ps -eo rss,comm 2>/dev/null | awk '$2=="hcr-server" {s+=$1} END {print s+0}')
    RAM_MB=$(awk "BEGIN {printf \"%.2f MB\", ${RAM_KB:-0}/1024}")
    echo -e "${C_GREEN}● ESTADO         : ACTIVO Y ESCUCHANDO (hcr-server)${NC}"
    echo -e "${C_WHITE}• Puerto(s) TCP  : ${C_GREEN}${LIVE_PORTS}${NC}"
    echo -e "${C_WHITE}• Memoria RAM    : ${C_CYAN}${RAM_MB}${NC}"
    for _p in $LIVE_PORTS; do
        _conns=$(ss -tn state established "( sport = :${_p} )" 2>/dev/null | tail -n +2 | wc -l)
        echo -e "${C_WHITE}• Conexiones :${_p} : ${C_GREEN}${_conns} clientes activos${NC}"
    done
else
    echo -e "${C_RED}○ ESTADO         : INACTIVO${NC}"
fi

echo -e "${C_CYAN}------------------------------------------------------------${NC}"
echo -e "${C_YELLOW}[LOGS RECIENTES HCR]:${NC}"
journalctl -u crisdev-hcr.service -u hcr.service -n 8 --no-pager 2>/dev/null || true
echo -e "${C_CYAN}============================================================${NC}"
read -n1 -r -p "Presione cualquier tecla para volver..."
