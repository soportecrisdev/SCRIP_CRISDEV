#!/usr/bin/env bash
#
# setup.sh — Instalador único e INTERACTIVO de BHTTP_CRISDEV (motor BTUN pré-ZTUN).
#
# Este script clona el repo de configuración/scripts y luego busca el paquete
# de binarios offline (btun-offline/BTUN/) para ejecutar install.sh.
#
# Diseñado para VPS que ya tienen SCRIP_BASICA con:
#   22  → OpenSSH  |  80  → SOCKS  |  90/110 → Dropbear
#   443 → SSL Tunnel  |  7300 → BADVPN
#
# Uso en la VPS (como root):
#   wget https://raw.githubusercontent.com/CristianBatero/BHTTP_CRISDEV/main/setup.sh \
#       && chmod +x setup.sh && ./setup.sh
#
# O si ya tienes el repo clonado:
#   bash /opt/bhttp-crisdev/setup.sh
#
set -Eeuo pipefail

# ---- Configuración (edita si el repo/rama cambia) ----
REPO_URL="${BTUN_REPO_URL:-https://github.com/CristianBatero/BHTTP_CRISDEV.git}"
BRANCH="${BTUN_BRANCH:-main}"
INSTALL_DIR="${BTUN_INSTALL_DIR:-/opt/bhttp-crisdev}"
# Directorio donde están los binarios offline (si se instala separado)
BIN_PKG_DIR="${BTUN_BIN_DIR:-/opt/bhttp-crisdev-bin}"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

C='\033[0m'; CY='\033[0;36m'; YE='\033[0;33m'; RE='\033[0;31m'; GR='\033[0;32m'
log()  { printf "${CY}[setup]${C} %s\n" "$*"; }
warn() { printf "${YE}[setup WARN]${C} %s\n" "$*" >&2; }
die()  { printf "${RE}[setup ERROR]${C} %s\n" "$*" >&2; exit 1; }
ok()   { printf "${GR}[setup OK]${C} %s\n" "$*"; }

(( EUID == 0 )) || die "Ejecuta como root:  sudo bash $SCRIPT_NAME  (o directo como root)"

# Verificar dependencias mínimas
for cmd in git sha256sum systemctl install; do
    command -v "$cmd" >/dev/null 2>&1 || die "Comando obligatorio ausente: $cmd (instala con: apt-get install -y $cmd)"
done

# ---- Detectar si estamos ejecutando desde dentro del repo clonado ----
IS_IN_REPO=0
SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_PATH/ports.env" ]]; then
    IS_IN_REPO=1
    INSTALL_DIR="$SCRIPT_PATH"
    log "Ejecutando desde dentro del repo: $INSTALL_DIR"
fi

# ---- 1. Obtener el repo de scripts (git clone o git pull) ----
if (( IS_IN_REPO == 0 )); then
    mkdir -p "$INSTALL_DIR"
    if [[ -d "$INSTALL_DIR/.git" ]]; then
        log "Repo ya existe en $INSTALL_DIR. Actualizando..."
        cd "$INSTALL_DIR"
        git fetch --prune origin
        git pull --ff-only origin "$BRANCH" || warn "git pull falló — continuando con versión actual."
    else
        log "Clonando repo en $INSTALL_DIR..."
        git clone --branch "$BRANCH" --depth 1 "$REPO_URL" "$INSTALL_DIR"
        cd "$INSTALL_DIR"
    fi
else
    cd "$INSTALL_DIR"
fi

# ---- 2. Cargar ports.env (evita colisiones con SCRIP_BASICA) ----
PORTS_FILE="$INSTALL_DIR/ports.env"
if [[ -f "$PORTS_FILE" ]]; then
    log "Cargando puertos desde ports.env..."
    set -a
    # shellcheck disable=SC1091
    source "$PORTS_FILE"
    set +a
    log "Puertos configurados: BHTTP=$BHTTP_PORT XHTTP=$XHTTP_PORT BTUN=$BTUN_PORT"
else
    warn "ports.env no encontrado. Se usarán los puertos por defecto del install.sh."
fi

# ---- 3. Buscar install.sh del paquete offline de binarios ----
# Prioridad: BIN_PKG_DIR → subdirectorio local → INSTALL_DIR
ACTUAL_INSTALL_SCRIPT=""

if [[ -f "$BIN_PKG_DIR/install.sh" ]]; then
    ACTUAL_INSTALL_SCRIPT="$BIN_PKG_DIR/install.sh"
    log "Paquete de binarios encontrado en: $BIN_PKG_DIR"
elif [[ -f "$INSTALL_DIR/install.sh" && -d "$INSTALL_DIR/bin" ]]; then
    ACTUAL_INSTALL_SCRIPT="$INSTALL_DIR/install.sh"
    log "Paquete de binarios encontrado en: $INSTALL_DIR"
else
    echo ""
    warn "No se encontró el paquete offline de binarios BTUN."
    warn "Coloca el contenido de btun-offline/BTUN/ en: $BIN_PKG_DIR"
    warn "O descárgalo y extráelo manualmente:"
    echo ""
    echo "  mkdir -p $BIN_PKG_DIR"
    echo "  # Copia bhttp-menu, bin/, install.sh, bhttp-menu, sources/ a $BIN_PKG_DIR"
    echo "  bash $BIN_PKG_DIR/install.sh"
    echo ""
    die "Paquete offline de binarios no encontrado. Ver instrucciones arriba."
fi

# ---- 4. Ejecutar install.sh del paquete offline ----
log "Ejecutando instalación: $ACTUAL_INSTALL_SCRIPT"
bash "$ACTUAL_INSTALL_SCRIPT" "$@"

ok "Setup completado. Ejecuta 'bhttp' para abrir el menú de gestión."
ok "Para actualizar en el futuro: bash $INSTALL_DIR/update.sh"

# ---- 5. Instalar cron de actualizaciones automáticas (opcional) ----
echo ""
read -rp "¿Instalar actualización automática diaria (cron a las 4am)? [s/N]: " CRON_RESP
if [[ "${CRON_RESP,,}" == "s" || "${CRON_RESP,,}" == "si" || "${CRON_RESP,,}" == "y" ]]; then
    bash "$INSTALL_DIR/update.sh" --install-cron
fi
