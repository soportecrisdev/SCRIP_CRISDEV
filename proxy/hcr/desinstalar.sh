#!/usr/bin/env bash
# ==============================================================================
# DESINSTALADOR LIMPIO — HCR RELAY
# Ubicación: proxy/hcr/desinstalar.sh
# ==============================================================================

set -u

C_GREEN='\033[1;32m'
C_YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${C_YELLOW}[*] Deteniendo y desinstalando HCR Relay...${NC}"

for _svc in /etc/systemd/system/crisdev-hcr*.service /etc/systemd/system/hcr.service /etc/systemd/system/hcr-*.service; do
    [[ -f "$_svc" ]] || continue
    _name=$(basename "$_svc")
    systemctl stop "$_name" 2>/dev/null || true
    systemctl disable "$_name" 2>/dev/null || true
    rm -f "$_svc" 2>/dev/null || true
done
systemctl daemon-reload 2>/dev/null || true

pkill -9 -x 'hcr-server' 2>/dev/null || pkill -9 -f 'hcr-server' 2>/dev/null || true
echo -e "${C_GREEN}✔ HCR Relay detenido y desinstalado limpiamente.${NC}"
