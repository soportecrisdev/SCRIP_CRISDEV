#!/usr/bin/env bash
#
# update.sh — Actualizador automático de BHTTP_CRISDEV (motor BTUN).
#
# Usa GIT como puente: hace pull del repo y, si hay cambios, verifica la
# integridad de los archivos del repo (NO de los binarios, que están aparte)
# y re-ejecuta install.sh desde el directorio de instalación de binarios.
#
# Contexto de tu VPS:
#   La SCRIP_BASICA ya ocupa: 22 (SSH), 80 (SOCKS), 90/110 (Dropbear),
#   443 (SSL Tunnel), 7300 (BADVPN). Los puertos BHTTP usarán los de ports.env.
#
# Uso (como root):
#   bash /opt/bhttp-crisdev/update.sh
#
# O instala el cron con:
#   bash /opt/bhttp-crisdev/update.sh --install-cron
#
set -Eeuo pipefail

REPO_URL="${BTUN_REPO_URL:-https://github.com/CristianBatero/BHTTP_CRISDEV.git}"
BRANCH="${BTUN_BRANCH:-main}"
INSTALL_DIR="${BTUN_INSTALL_DIR:-/opt/bhttp-crisdev}"
# Directorio donde están los binarios compilados (instalados aparte offline)
BIN_PKG_DIR="${BTUN_BIN_DIR:-/opt/bhttp-crisdev-bin}"

C='\033[0m'; CY='\033[0;36m'; YE='\033[0;33m'; RE='\033[0;31m'; GR='\033[0;32m'
log()  { printf "${CY}[update]${C} %s\n" "$*"; }
warn() { printf "${YE}[update WARN]${C} %s\n" "$*" >&2; }
die()  { printf "${RE}[update ERROR]${C} %s\n" "$*" >&2; exit 1; }
ok()   { printf "${GR}[update OK]${C} %s\n" "$*"; }

# ---- Modo especial: instalar cron de actualización automática ----
if [[ "${1:-}" == "--install-cron" ]]; then
    CRON_LINE="0 4 * * * root bash $INSTALL_DIR/update.sh >> /var/log/bhttp-update.log 2>&1"
    CRON_FILE="/etc/cron.d/bhttp-crisdev-update"
    echo "$CRON_LINE" > "$CRON_FILE"
    chmod 0644 "$CRON_FILE"
    ok "Cron instalado: actualización automática diaria a las 4am."
    ok "Log en: /var/log/bhttp-update.log"
    exit 0
fi

(( EUID == 0 )) || die "Ejecuta como root:  sudo bash update.sh"
command -v git >/dev/null 2>&1 || die "git está ausente. Instala con: apt-get install -y git"
[[ -d "$INSTALL_DIR/.git" ]] || die "No hay repo git en $INSTALL_DIR. Ejecuta primero: bash setup.sh"

cd "$INSTALL_DIR"

log "Verificando actualizaciones en $REPO_URL (rama $BRANCH)..."
git fetch --prune origin

LOCAL_HEAD="$(git rev-parse HEAD 2>/dev/null || true)"
REMOTE_HEAD="$(git rev-parse "origin/$BRANCH" 2>/dev/null || true)"

if [[ -z "$REMOTE_HEAD" ]]; then
    die "No se encontró la rama '$BRANCH' remota. Revisa REPO_URL/BRANCH."
fi

FORCE_INSTALL=0
if [[ "${1:-}" == "--force" || "${1:-}" == "-f" ]]; then
    FORCE_INSTALL=1
    shift
fi

if [[ "$LOCAL_HEAD" == "$REMOTE_HEAD" && $FORCE_INSTALL -eq 0 ]]; then
    ok "Ya estás en la última versión (${LOCAL_HEAD:0:8})."
    log "Usa: bash update.sh --force para forzar la reinstalación de servicios."
    exit 0
fi

if [[ "$LOCAL_HEAD" != "$REMOTE_HEAD" ]]; then
    log "Nueva versión disponible: ${REMOTE_HEAD:0:8} (actual: ${LOCAL_HEAD:0:8})"
    git pull --ff-only origin "$BRANCH" || die "git pull falló (¿cambios locales sin commitear?)."
fi

# ---- Verificar integridad de los archivos del REPO (no de los binarios) ----
# SHA256SUMS cubre solo los archivos que git entrega: setup.sh, update.sh, ports.env, etc.
# Los binarios (bin/amd64/, bin/arm64/) NO están en el repo y NO se verifican aquí.
if [[ -f SHA256SUMS ]]; then
    # Filtrar solo los archivos que existen en este directorio (excluir binarios ausentes)
    SUMS_TO_CHECK="$(mktemp)"
    while IFS= read -r line; do
        # Extraer la ruta del archivo del SHA256SUMS
        filepath="${line##*  }"   # todo después de los dos espacios
        # Solo verificar si el archivo existe
        if [[ -f "$filepath" ]]; then
            echo "$line" >> "$SUMS_TO_CHECK"
        fi
    done < SHA256SUMS

    if [[ -s "$SUMS_TO_CHECK" ]]; then
        if sha256sum -c "$SUMS_TO_CHECK" --quiet >/dev/null 2>&1; then
            ok "Integridad de archivos del repo verificada (SHA256SUMS OK)."
        else
            rm -f "$SUMS_TO_CHECK"
            die "SHA256SUMS no coincide tras la actualización. Abortando por seguridad."
        fi
    else
        warn "SHA256SUMS no contiene archivos verificables en este directorio; se omite."
    fi
    rm -f "$SUMS_TO_CHECK"
else
    warn "SHA256SUMS ausente en el repo; se omite la verificación de integridad."
fi

# ---- Cargar puertos (evita chocar con SCRIP_BASICA: 22/80/90/110/443/7300) ----
PORTS_FILE="$INSTALL_DIR/ports.env"
if [[ -f "$PORTS_FILE" ]]; then
    log "Cargando configuración de puertos desde ports.env..."
    set -a
    # shellcheck disable=SC1091
    source "$PORTS_FILE"
    set +a
else
    warn "ports.env no encontrado en $INSTALL_DIR. Se usarán los puertos por defecto del install.sh."
fi

# ---- Determinar dónde están los binarios offline instalados ----
# Si existe el directorio BIN_PKG_DIR (instalación separada de binarios), usarlo.
# Si no, buscar en INSTALL_DIR (instalación todo-en-uno con git-lfs o submodule).
ACTUAL_INSTALL_SCRIPT=""
if [[ -f "$BIN_PKG_DIR/install.sh" ]]; then
    ACTUAL_INSTALL_SCRIPT="$BIN_PKG_DIR/install.sh"
    log "Usando binarios desde: $BIN_PKG_DIR"
elif [[ -f "$INSTALL_DIR/install.sh" ]]; then
    ACTUAL_INSTALL_SCRIPT="$INSTALL_DIR/install.sh"
    log "Usando install.sh local en: $INSTALL_DIR"
else
    die "No se encontró install.sh. Verifica que el paquete offline esté en $BIN_PKG_DIR o $INSTALL_DIR."
fi

# ---- Reinstalar (backup + reinstala binarios + reinicia servicios) ----
log "Reinstalando binarios y servicios desde ${ACTUAL_INSTALL_SCRIPT}..."
bash "$ACTUAL_INSTALL_SCRIPT" "$@"

ok "Actualización completada a ${REMOTE_HEAD:0:8}."
