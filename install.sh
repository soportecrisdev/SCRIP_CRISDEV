#!/usr/bin/env bash
# ==============================================================================
#  SSH-CRIS v1 — Instalador Remoto Oficial
#  Ejecución en VPS limpio (Debian / Ubuntu):
#    bash <(curl -fsSL https://raw.githubusercontent.com/soportecrisdev/SCRIP_CRISDEV/main/install.sh)
# ==============================================================================
set -Euo pipefail

REPO_RAW="https://raw.githubusercontent.com/soportecrisdev/SCRIP_CRISDEV/main"
INSTALL_DIR="/opt/ssh-cris"
BIN_NAME="ssh-cris.sh"

RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
WHITE='\033[1;37m'
NC='\033[0m'

clear
echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║${WHITE}             ⚡ INSTALADOR SSH-CRIS MASTER v1 ⚡             ${CYAN}║${NC}"
echo -e "${CYAN}║${WHITE}                 CRISDEV / HTTP Conexión                    ${CYAN}║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo -e "${RED}[ERROR]${NC} Ejecuta este instalador como root: sudo bash $0"
    exit 1
fi

echo -e "${YELLOW}[1/4]${NC} Actualizando repositorios e instalando paquetes base..."
if command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get update -y -qq >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl wget git jq openssl stunnel4 ufw fail2ban \
        socat netcat-openbsd python3 libssl-dev screen nano unzip iproute2 procps >/dev/null 2>&1 || true
elif command -v yum >/dev/null 2>&1; then
    yum install -y -q curl wget git jq openssl stunnel ufw fail2ban socat python3 screen nano unzip iproute procps-ng >/dev/null 2>&1 || true
fi
# Asegurar que dropbear no interfiera con los puertos de BHTTP
systemctl stop dropbear 2>/dev/null || true
systemctl disable dropbear 2>/dev/null || true
echo -e "${GREEN}[✔]${NC} Dependencias listas."

echo -e "${YELLOW}[2/4]${NC} Creando directorios y descargando SSH-CRIS Suite..."
mkdir -p "$INSTALL_DIR"
mkdir -p /etc/ssh-cris /etc/wakkodev-bhttp /etc/hysteria /etc/stunnel /etc/slowdns

# Descargar script maestro si no existe localmente
if [[ -f "./ssh-cris.sh" ]]; then
    cp -a "./ssh-cris.sh" "$INSTALL_DIR/$BIN_NAME"
else
    curl -fsSL "$REPO_RAW/ssh-cris.sh" -o "$INSTALL_DIR/$BIN_NAME" 2>/dev/null || \
    wget -q "$REPO_RAW/ssh-cris.sh" -O "$INSTALL_DIR/$BIN_NAME"
fi

chmod +x "$INSTALL_DIR/$BIN_NAME"
echo -e "${GREEN}[✔]${NC} Script maestro instalado en $INSTALL_DIR/$BIN_NAME."

echo -e "${YELLOW}[3/4]${NC} Creando accesos directos globales en el sistema..."
ln -sfn "$INSTALL_DIR/$BIN_NAME" /usr/local/bin/ssh-cris
ln -sfn "$INSTALL_DIR/$BIN_NAME" /usr/local/bin/cris
ln -sfn "$INSTALL_DIR/$BIN_NAME" /usr/local/bin/menu
echo -e "${GREEN}[✔]${NC} Comandos 'ssh-cris', 'cris' y 'menu' registrados."

echo -e "${YELLOW}[4/4]${NC} Optimizando puertos SSH base..."
sed -i 's/#*AllowTcpForwarding.*/AllowTcpForwarding yes/' /etc/ssh/sshd_config 2>/dev/null || true
sed -i 's/#*GatewayPorts.*/GatewayPorts yes/' /etc/ssh/sshd_config 2>/dev/null || true
systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true

echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
echo -e "${WHITE}  ¡INSTALACIÓN COMPLETADA CON ÉXITO!${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
echo -e "${WHITE}Escribe ${CYAN}ssh-cris${WHITE}, ${CYAN}cris${WHITE} o ${CYAN}menu${WHITE} para abrir el panel.${NC}"
echo ""

# Iniciar menú
exec "$INSTALL_DIR/$BIN_NAME"
