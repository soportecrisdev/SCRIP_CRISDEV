#!/usr/bin/env bash
# ==============================================================================
# DESINSTALADOR LIMPIO — WEBSOCKET CLÁSICO PYTHON v4.6
# Ubicación: proxy/wsclasico/desinstalar.sh
# ==============================================================================

set -u

SERVICE_NAME="crisdev-ws-python.service"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"
CONF_FILE="/etc/crisdev/ws-python.conf"

C_GREEN='\033[1;32m'
C_YELLOW='\033[1;33m'
C_RED='\033[1;31m'
NC='\033[0m'

echo -e "${C_YELLOW}[*] Deteniendo WebSocket Clásico Python v4.6...${NC}"

# 1. Detener y deshabilitar systemd
systemctl stop "$SERVICE_NAME" 2>/dev/null || true
systemctl disable "$SERVICE_NAME" 2>/dev/null || true
rm -f "$SERVICE_FILE" 2>/dev/null || true
systemctl daemon-reload 2>/dev/null || true

# 2. Limpiar procesos residuales y screens antiguos de wsproxy.py
for _pid in $(pgrep -f 'wsproxy\.py' 2>/dev/null); do
    kill -9 "$_pid" 2>/dev/null || true
done
for _sc in $(screen -ls 2>/dev/null | grep -E '\.ws\b|\.ws_' | awk '{print $1}'); do
    screen -r -S "$_sc" -X quit 2>/dev/null || true
done
screen -wipe >/dev/null 2>&1 || true

# 3. Limpiar archivo de configuración de Python WS (no toca ws-c.conf)
rm -f "$CONF_FILE" 2>/dev/null || true

echo -e "${C_GREEN}✔ WebSocket Clásico Python detenido y desinstalado limpiamente.${NC}"
