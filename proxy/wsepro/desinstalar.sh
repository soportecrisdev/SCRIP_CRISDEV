#!/usr/bin/env bash
# ==============================================================================
# DESINSTALADOR LIMPIO — WS-EPRO
# Ubicación: proxy/wsepro/desinstalar.sh
# ==============================================================================

set -u

C_GREEN='\033[1;32m'
C_YELLOW='\033[1;33m'
C_RED='\033[1;31m'
NC='\033[0m'

echo -e "${C_YELLOW}[*] Deteniendo y desinstalando WS-ePro...${NC}"

for _pid in $(pgrep -f 'ws-epro' 2>/dev/null); do
    _owner_svc=$(awk -F/ '/system\.slice/ {print $NF}' "/proc/${_pid}/cgroup" 2>/dev/null | grep '\.service$' | head -1)
    if [[ -n "$_owner_svc" ]]; then
        systemctl stop "$_owner_svc" 2>/dev/null || true
        systemctl disable "$_owner_svc" 2>/dev/null || true
        rm -f "/etc/systemd/system/${_owner_svc}" 2>/dev/null || true
    fi
done

for _svc in crisdev-ws-epro.service ws-epro.service; do
    systemctl stop "$_svc" 2>/dev/null || true
    systemctl disable "$_svc" 2>/dev/null || true
    rm -f "/etc/systemd/system/${_svc}" 2>/dev/null || true
done
systemctl daemon-reload 2>/dev/null || true

pkill -9 -x 'ws-epro' 2>/dev/null || pkill -9 -f 'ws-epro' 2>/dev/null || true
rm -rf /etc/crisdev/ws-epro 2>/dev/null || true

sleep 0.5
if [[ -z "$(ss -tlpn 2>/dev/null | grep '"ws-epro"')" ]]; then
    echo -e "${C_GREEN}✔ WS-ePro apagado y desinstalado limpiamente.${NC}"
else
    echo -e "${C_RED}[!] Aún se detecta ws-epro escuchando.${NC}"
fi
