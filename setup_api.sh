#!/bin/bash
# ============================================================================
# CRISDEV Auth API - Instalador y Activador del servicio de Autenticación
# ============================================================================
set -euo pipefail

PORT=${1:-8080}
INSTALL_DIR="/opt/crisdev"

echo "╔══════════════════════════════════════════════════════════╗"
echo "║      CRISDEV VPS Auth API - Instalador de Servicio      ║"
echo "╚══════════════════════════════════════════════════════════╝"

if [[ $EUID -ne 0 ]]; then
    echo "[ERROR] Ejecuta como root: sudo bash setup_api.sh"
    exit 1
fi

mkdir -p "$INSTALL_DIR"

# Copiar el script vps_api.py al directorio /opt/crisdev
cp -f vps_api.py "$INSTALL_DIR/vps_api.py" 2>/dev/null || true
chmod +x "$INSTALL_DIR/vps_api.py"

# Crear servicio systemd
cat > /etc/systemd/system/crisdev-api.service << EOF
[Unit]
Description=CRISDEV VPS Auth API Service
After=network.target

[Service]
Type=simple
User=root
Environment=PORT=$PORT
ExecStart=/usr/bin/python3 $INSTALL_DIR/vps_api.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable crisdev-api
systemctl restart crisdev-api

echo ""
echo "[OK] Servicio 'crisdev-api' instalado y activado en el puerto $PORT."
echo "[OK] Credenciales por defecto para Google Play Store:"
echo "     Usuario:    demo"
echo "     Contraseña: demo123"
echo ""
echo "Para verificar el estado ejecuta: systemctl status crisdev-api"
