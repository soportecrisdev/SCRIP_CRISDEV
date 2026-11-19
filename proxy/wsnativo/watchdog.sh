#!/usr/bin/env bash
# ==============================================================================
# WATCHDOG SEGURO — WEBSOCKET NATIVO EN C v3.0
# Solo actúa si crisdev-ws-c.service existe y está habilitado por el usuario.
# ==============================================================================

set -u

SERVICE_NAME="crisdev-ws-c.service"
CONF_FILE="/etc/crisdev/ws-c.conf"

# Si el usuario desinstaló o deshabilitó el servicio, salir inmediatamente
[[ -f "/etc/systemd/system/${SERVICE_NAME}" ]] || exit 0
systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null || exit 0

PORT="80"
if [[ -f "$CONF_FILE" ]]; then
    _p=$(grep -E '^LISTEN_PORT=' "$CONF_FILE" 2>/dev/null | cut -d= -f2 | tr -dc '0-9')
    [[ -n "$_p" ]] && PORT="$_p"
fi

# 1. Verificar que wsproxy-c esté escuchando en el puerto configurado
if ! ss -tlpn 2>/dev/null | grep -qE "[:.]${PORT}[[:space:]].*\"wsproxy-c\""; then
    systemctl restart "$SERVICE_NAME" >/dev/null 2>&1 || true
    exit 0
fi

# 2. Verificar respuesta HTTP local real (< 3s)
if ! curl -s -I --max-time 3 "http://127.0.0.1:${PORT}/" 2>/dev/null | grep -qE '^HTTP/1\.[01] (101|200)'; then
    systemctl restart "$SERVICE_NAME" >/dev/null 2>&1 || true
fi
