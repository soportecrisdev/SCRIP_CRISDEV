#!/usr/bin/env bash
# ==============================================================================
# DESINSTALADOR DEFINITIVO — WEBSOCKET NATIVO EN C v3.0
# Ubicación: proxy/wsnativo/desinstalar.sh
# ==============================================================================

set -u

C_GREEN='\033[1;32m'
C_YELLOW='\033[1;33m'
C_RED='\033[1;31m'
NC='\033[0m'

echo -e "${C_YELLOW}[*] Deteniendo y desinstalando WebSocket Nativo en C...${NC}"

# 1. Eliminar watchdog cron para que jamás reviva
rm -f /etc/cron.d/crisdev-ws-c-watchdog 2>/dev/null || true

# 2. Detectar dinámicamente la unidad systemd dueña de cualquier PID wsproxy-c
for _wcpid in $(pgrep -f 'wsproxy-c' 2>/dev/null); do
    _owner_svc=$(awk -F/ '/system\.slice/ {print $NF}' "/proc/${_wcpid}/cgroup" 2>/dev/null | grep '\.service$' | head -1)
    if [[ -n "$_owner_svc" ]]; then
        systemctl stop "$_owner_svc" 2>/dev/null || true
        systemctl disable "$_owner_svc" 2>/dev/null || true
        rm -f "/etc/systemd/system/${_owner_svc}" 2>/dev/null || true
    fi
done

# 3. Detener, deshabilitar y eliminar todas las unidades conocidas y legacy
for _svc in crisdev-ws-c.service sshplus-ws.service wsproxy-c.service ws-c.service websocket.service wsproxy.service; do
    systemctl stop "$_svc" 2>/dev/null || true
    systemctl disable "$_svc" 2>/dev/null || true
    rm -f "/etc/systemd/system/${_svc}" 2>/dev/null || true
done
systemctl daemon-reload 2>/dev/null || true

# 4. Limpiar autostart legacy y matar cualquier proceso residual
[[ -f /etc/autostart ]] && sed -i '/wsproxy-c/d' /etc/autostart 2>/dev/null || true
pkill -9 -x 'wsproxy-c' 2>/dev/null || pkill -9 -f 'wsproxy-c' 2>/dev/null || true

# 5. Eliminar archivo de configuración de C WS (no toca ws-python.conf)
rm -f /etc/crisdev/ws-c.conf 2>/dev/null || true

sleep 0.6
if [[ -z "$(ss -tlpn 2>/dev/null | grep '"wsproxy-c"')" ]]; then
    echo -e "${C_GREEN}✔ WebSocket Nativo en C apagado y desinstalado limpiamente.${NC}"
else
    echo -e "${C_RED}[!] Aún se detecta wsproxy-c escuchando. Verifica cron/supervisores externos.${NC}"
fi
