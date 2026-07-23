#!/bin/bash
# ============================================================================
# CRISDEV VPN Manager - Instalador Remoto
# Ejecutar en el VPS nuevo con:
#   bash <(curl -fsSL https://raw.githubusercontent.com/soportecrisdev/SCRIP_CRISDEV/main/install.sh)
# ============================================================================
set -euo pipefail

REPO_URL="https://github.com/soportecrisdev/SCRIP_CRISDEV.git"
INSTALL_DIR="/opt/crisdev"
SCRIPT_NAME="crisdev.sh"
REMOTE_SCRIPT="https://raw.githubusercontent.com/soportecrisdev/SCRIP_CRISDEV/main/$SCRIPT_NAME"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${CYAN}"
echo "╔══════════════════════════════════════════════════════════╗"
echo "║     CRISDEV VPN Manager - Instalador Remoto            ║"
echo "║     @CRISIS1823                                         ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# Verificar root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[ERROR]${NC} Ejecuta como root: sudo bash install.sh"
    exit 1
fi

echo -e "${YELLOW}[1/5]${NC} Verificando sistema..."

# Detectar sistema operativo
if [[ -f /etc/debian_version ]]; then
    OS="debian"
    echo -e "${GREEN}[OK]${NC} Sistema Debian/Ubuntu detectado"
elif [[ -f /etc/redhat-release ]]; then
    OS="redhat"
    echo -e "${GREEN}[OK]${NC} Sistema CentOS/RHEL detectado"
else
    echo -e "${RED}[ERROR]${NC} Sistema no soportado (solo Debian/Ubuntu/CentOS)"
    exit 1
fi

echo -e "${YELLOW}[2/5]${NC} Instalando dependencias básicas..."
if [[ "$OS" == "debian" ]]; then
    apt-get update -qq
    apt-get install -y -qq curl wget git jq openssl stunnel4 dropbear ufw fail2ban \
        socat netcat-openbsd python3 python3-pip libssl-dev screen nano unzip 2>/dev/null
else
    yum install -y -q curl wget git jq openssl stunnel ufw fail2ban \
        socat nmap-ncat python3 python3-pip openssl-devel screen nano unzip 2>/dev/null
fi
echo -e "${GREEN}[OK]${NC} Dependencias instaladas"

echo -e "${YELLOW}[3/5]${NC} Descargando CRISDEV VPN Manager..."
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

# Intentar clonar repo completo
if git clone "$REPO_URL" . 2>/dev/null; then
    echo -e "${GREEN}[OK]${NC} Repositorio clonado"
else
    echo -e "${YELLOW}[WARN]${NC} Clon falló, descargando script directamente..."
    wget -q "$REMOTE_SCRIPT" -O "$SCRIPT_NAME" 2>/dev/null || \
    curl -fsSL "$REMOTE_SCRIPT" -o "$SCRIPT_NAME" 2>/dev/null
    if [[ ! -f "$SCRIPT_NAME" ]]; then
        echo -e "${RED}[ERROR]${NC} No se pudo descargar el script"
        exit 1
    fi
    echo -e "${GREEN}[OK]${NC} Script descargado"
fi

chmod +x "$SCRIPT_NAME"

echo -e "${YELLOW}[4/5]${NC} Instalando comando 'crisdev'..."
ln -sf "$INSTALL_DIR/$SCRIPT_NAME" /usr/local/bin/crisdev
echo -e "${GREEN}[OK]${NC} Comando 'crisdev' disponible"

echo -e "${YELLOW}[5/5]${NC} Ejecutando instalación completa..."
echo ""
bash "$SCRIPT_NAME" --install

echo ""
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${GREEN}  INSTALACIÓN COMPLETADA${NC}"
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════${NC}"
echo ""
echo -e "  Ejecuta: ${BOLD}crisdev${NC}"
echo ""
