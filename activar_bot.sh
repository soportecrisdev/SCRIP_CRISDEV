#!/bin/bash
# ==============================================================================
# CRISDEV TELEGRAM BOT — INSTALADOR Y ACTIVADOR OFICIAL EN VPS ⚡
# HTTP Conexión / Conexiones EL CRIS
# ==============================================================================

set -e

GREEN="\033[1;32m"
BLUE="\033[1;34m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
CYAN="\033[1;36m"
NC="\033[0m"

clear
echo -e "${BLUE}═════════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}        CRISDEV TELEGRAM BOT — ACTIVADOR AUTOMÁTICO EN VPS       ${NC}"
echo -e "${BLUE}═════════════════════════════════════════════════════════════════${NC}"
echo ""

# 1. Comprobar permisos root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}[ERROR] Este script debe ejecutarse como root (sudo -i).${NC}"
   exit 1
fi

# 2. Instalar dependencias Python
echo -e "${YELLOW}[1/5] Verificando dependencias Python y paquetes necesarios...${NC}"
apt-get update -y >/dev/null 2>&1 || true
apt-get install -y python3 python3-pip python3-setuptools libssl-dev >/dev/null 2>&1 || true

# Instalar pycryptodome y requests
python3 -m pip install --break-system-packages pycryptodome requests >/dev/null 2>&1 || \
python3 -m pip install pycryptodome requests >/dev/null 2>&1 || \
apt-get install -y python3-pycryptodome python3-requests >/dev/null 2>&1 || true

echo -e "${GREEN}  ✔ Dependencias listas.${NC}"

# 3. Ubicar o copiar el script crisdev_bot.py
echo -e "${YELLOW}[2/5] Desplegando archivo del bot en /bin/crisdev_bot.py...${NC}"
mkdir -p /etc/crisdev/bot /bin

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/Modulos/crisdev_bot.py" ]]; then
    cp -af "$SCRIPT_DIR/Modulos/crisdev_bot.py" /bin/crisdev_bot.py
elif [[ -f "$SCRIPT_DIR/crisdev_bot.py" ]]; then
    cp -af "$SCRIPT_DIR/crisdev_bot.py" /bin/crisdev_bot.py
elif [[ ! -f "/bin/crisdev_bot.py" ]]; then
    echo -e "${YELLOW}  Descargando última versión de crisdev_bot.py desde repositorio...${NC}"
    curl -fsSL "https://raw.githubusercontent.com/soportecrisdev/SCRIP_CRISDEV/main/Modulos/crisdev_bot.py" -o /bin/crisdev_bot.py || true
fi

chmod +x /bin/crisdev_bot.py
echo -e "${GREEN}  ✔ Script del bot listo en /bin/crisdev_bot.py.${NC}"

# 4. Configurar token de Telegram
echo -e "${YELLOW}[3/5] Configuración del Token de Telegram...${NC}"
TOKEN_FILE="/etc/crisdev/bot/token.txt"
CURRENT_TOKEN=""
if [[ -f "$TOKEN_FILE" ]]; then
    CURRENT_TOKEN=$(cat "$TOKEN_FILE" | tr -d '[:space:]')
fi

if [[ -n "$CURRENT_TOKEN" ]]; then
    echo -e "  Token actual configurado: ${CYAN}${CURRENT_TOKEN:0:10}...${CURRENT_TOKEN: -5}${NC}"
    read -p "  ¿Deseas cambiar el token? [s/N]: " CAMBIAR_TOKEN
    if [[ "$CAMBIAR_TOKEN" =~ ^[sS]$ ]]; then
        read -p "  Ingresa el nuevo token del bot de Telegram: " NUEVO_TOKEN
        if [[ -n "$NUEVO_TOKEN" ]]; then
            echo "$NUEVO_TOKEN" > "$TOKEN_FILE"
            chmod 600 "$TOKEN_FILE"
            echo -e "${GREEN}  ✔ Token actualizado y protegido con chmod 600.${NC}"
        fi
    fi
else
    echo -e "  No hay token configurado."
    read -p "  Ingresa el token de tu bot de @BotFather: " NUEVO_TOKEN
    while [[ -z "$NUEVO_TOKEN" ]]; do
        echo -e "${RED}  ✖ El token es obligatorio para que el bot funcione de forma segura.${NC}"
        read -p "  Ingresa el token de tu bot de @BotFather: " NUEVO_TOKEN
    done
    echo "$NUEVO_TOKEN" > "$TOKEN_FILE"
    chmod 600 "$TOKEN_FILE"
    echo -e "${GREEN}  ✔ Token guardado de forma segura en $TOKEN_FILE (chmod 600).${NC}"
fi

# 5. Crear servicio systemd
echo -e "${YELLOW}[4/5] Creando y registrando servicio systemd crisdev-bot.service...${NC}"
cat << 'EOF' > /etc/systemd/system/crisdev-bot.service
[Unit]
Description=CRISDEV Telegram Bot Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/bin
ExecStart=/usr/bin/python3 /bin/crisdev_bot.py
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable crisdev-bot >/dev/null 2>&1
echo -e "${GREEN}  ✔ Servicio systemd registrado y habilitado para inicio automático.${NC}"

# 6. Iniciar el servicio y verificar estado
echo -e "${YELLOW}[5/5] Iniciando Bot de Telegram...${NC}"
systemctl restart crisdev-bot
sleep 2

STATUS=$(systemctl is-active crisdev-bot || true)
echo ""
echo -e "${BLUE}═════════════════════════════════════════════════════════════════${NC}"
if [[ "$STATUS" == "active" ]]; then
    echo -e "${GREEN}  ✔ ¡EL BOT DE TELEGRAM ESTÁ ACTIVO Y FUNCIONANDO EN EL VPS! ⚡${NC}"
    echo -e "${CYAN}  Servicio: ${NC}crisdev-bot.service"
    echo -e "${CYAN}  Comandos útiles en VPS:${NC}"
    echo -e "    • Ver estado:     ${YELLOW}systemctl status crisdev-bot${NC}"
    echo -e "    • Ver logs vivos: ${YELLOW}journalctl -u crisdev-bot -f${NC}"
    echo -e "    • Reiniciar bot:  ${YELLOW}systemctl restart crisdev-bot${NC}"
    echo -e "    • Desde menú:     ${YELLOW}menu -> Opción 5 (Bot y API)${NC}"
else
    echo -e "${RED}  ✖ El bot intentó arrancar pero su estado es: $STATUS${NC}"
    echo -e "${YELLOW}  Revisa el detalle de los errores con:${NC}"
    echo -e "    journalctl -u crisdev-bot -n 25 --no-pager"
fi
echo -e "${BLUE}═════════════════════════════════════════════════════════════════${NC}"
echo ""
