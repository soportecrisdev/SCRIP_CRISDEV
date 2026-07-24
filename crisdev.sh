#!/bin/bash
# ============================================================================
# CRISDEV VPN Manager v1.1 — Interfaz Profesional
# Script privado de administracion VPN para VPS
# Autor: CRISDEV / @CRISIS1823
# ============================================================================
set -uo pipefail

# ========================= VARIABLES GLOBALES =========================
CRISDEV_VERSION="1.1.0"
CRISDEV_HOME="/etc/crisdev"
CRISDEV_DATA="$CRISDEV_HOME/data"
CRISDEV_LOGS="$CRISDEV_HOME/logs"
CRISDEV_BACKUPS="$CRISDEV_HOME/backups"
USERS_DB="$CRISDEV_DATA/users.json"
SERVER_CONFIG="$CRISDEV_DATA/server_config.json"
AUDIT_LOG="$CRISDEV_LOGS/audit.log"
STATE_FILE="$CRISDEV_DATA/state.json"
CERT_DIR="/etc/crisdev/certs"

PORT_SSH=22
PORT_SSH_ALT=80
PORT_SSH_SSL=443
PORT_WEBSOCKET=8880
PORT_SLOWDNS=53
PORT_XRAY_WS=2053
PORT_XRAY_GRPC=2083
PORT_XRAY_REALITY=8443
PORT_XRAY_VLESS=2096
PORT_HYSTERIA=443
PORT_UDP_CUSTOM=7100-7200

# ========================= UI THEME — COLORES SEMANTICOS =========================
# Convencion: cada color tiene un significado fijo y NO se rompe en ningun modulo.
C_OK='\033[0;32m'        # Verde    = activo / OK / exito
C_ERR='\033[0;31m'       # Rojo     = expirado / bloqueado / detenido / accion destructiva
C_WARN='\033[1;33m'      # Amarillo = advertencia / por vencer / atencion
C_INFO='\033[0;36m'      # Cyan     = informacion neutra / encabezados de seccion
C_DIM='\033[2m'          # Gris     = texto secundario / deshabilitado
C_BOLD='\033[1m'         # Negrita  = titulos de bloque
C_NORM='\033[0m'         # Reset    = fin de color
C_PROMPT='\033[1;37m'    # Blanco   = prompt de entrada
C_ACCENT='\033[0;35m'    # Magenta  = acento especial

# ========================= UI COMPONENTS =========================

ui_clear() { clear; }

# --- Encabezado compacto (se repite en TODAS las pantallas internas) ---
ui_header() {
    local ip os_name date_str
    ip=$(get_server_ip 2>/dev/null || echo "?.?.?.?")
    os_name=$(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d'"' -f2 | cut -c1-20)
    date_str=$(date '+%d-%m-%Y %H:%M')
    echo -e "${C_INFO}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_NORM}"
    echo -e " ${C_BOLD}CRISDEV VPN MANAGER v${CRISDEV_VERSION}${C_NORM}                   ${C_DIM}@CRISIS1823${C_NORM}"
    echo -e " IP: ${C_BOLD}${ip}${C_NORM}   |   ${os_name}   |   ${date_str}"
    echo -e "${C_INFO}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_NORM}"
}

# --- Banner grande (SOLO para la primera pantalla de bienvenida) ---
ui_banner_welcome() {
    echo ""
    echo -e "${C_BOLD}${C_INFO}"
    echo "     ██████╗██████╗ ██╗██████╗ ████████╗███████╗██████╗ ███╗   ██╗"
    echo "    ██╔════╝██╔══██╗██║██╔══██╗╚══██╔══╝██╔════╝██╔══██╗████╗  ██║"
    echo "    ██║     ██████╔╝██║██████╔╝   ██║   █████╗  ██████╔╝██╔██╗ ██║"
    echo "    ██║     ██╔══██╗██║██╔═══╝    ██║   ██╔══╝  ██╔══██╗██║╚██╗██║"
    echo "    ╚██████╗██║  ██║██║██║        ██║   ███████╗██║  ██║██║ ╚████║"
    echo "     ╚═════╝╚═╝  ╚═╝╚═╝╚═╝        ╚═╝   ╚══════╝╚═╝  ╚═╝╚═╝  ╚═══╝"
    echo -e "${C_NORM}"
    echo -e "          ${C_BOLD}VPN Manager v${CRISDEV_VERSION}${C_NORM}    ${C_DIM}by CRISDEV / @CRISIS1823${C_NORM}"
    echo ""
}

# --- Panel de estado en vivo (dashboard) ---
ui_dashboard() {
    local total active expiring suspended banned
    total=$(jq 'length' "$USERS_DB" 2>/dev/null || echo 0)
    active=$(jq '[.[] | select(.status == "active")] | length' "$USERS_DB" 2>/dev/null || echo 0)
    suspended=$(jq '[.[] | select(.status == "suspended")] | length' "$USERS_DB" 2>/dev/null || echo 0)
    expiring=$(jq "[.[] | select(.status == \"active\" and .expires_at != null and (.expires_at | fromdateiso8601) > now and ((.expires_at | fromdateiso8601) - now) < 259200)] | length" "$USERS_DB" 2>/dev/null || echo 0)
    banned=$(fail2ban-client status sshd 2>/dev/null | grep "Currently banned" | awk '{print $NF}' 2>/dev/null || echo "0")
    [[ -z "$banned" ]] && banned="0"

    echo ""
    echo -e "  ${C_BOLD}USUARIOS${C_NORM}  ${C_OK}ACTIVOS: ${active}${C_NORM}  ${C_ERR}EXPIRADOS: ${expiring}${C_NORM}  ${C_WARN}SUSPENDIDOS: ${suspended}${C_NORM}  TOTAL: ${total}  ${C_DIM}|${C_NORM}  ${C_ERR}BANEADOS SSH: ${banned}${C_NORM}"

    # Estado de servicios con indicador visual
    echo -ne "  ${C_BOLD}SERVICIOS${C_NORM}  "
    for svc in xray hysteria-server stunnel4 udp-custom sshd ufw; do
        local st
        st=$(systemctl is-active "$svc" 2>/dev/null || echo "dead")
        if [[ "$st" == "active" ]]; then
            echo -ne "${C_OK}●${C_NORM}$(echo "$svc" | cut -c1-10) "
        else
            echo -ne "${C_ERR}○${C_NORM}$(echo "$svc" | cut -c1-10) "
        fi
    done
    echo ""
    echo ""
}

# --- Separador de seccion ---
ui_section() {
    local title="$1"
    echo -e "  ${C_BOLD}${C_INFO}${title}${C_NORM}"
}

# --- Separador visual ---
ui_separator() {
    echo -e "  ${C_DIM}──────────────────────────────────────────────────────────${C_NORM}"
}

# --- Prompt de entrada con estilo ---
ui_prompt() {
    echo ""
    echo -ne "  ${C_PROMPT}Ingresa una opcion: ${C_NORM}"
}

# --- Confirmacion destructiva (doble paso) ---
ui_confirm_destructive() {
    local msg="${1:-}"
    echo ""
    echo -e "  ${C_BOLD}${C_ERR}╔══════════════════════════════════════════════════╗${C_NORM}"
    echo -e "  ${C_BOLD}${C_ERR}║  ⚠  ACCION DESTRUCTIVA                         ║${C_NORM}"
    echo -e "  ${C_ERR}║${C_NORM}  ${msg}"
    echo -e "  ${C_BOLD}${C_ERR}╚══════════════════════════════════════════════════╝${C_NORM}"
    echo ""
    echo -ne "  ${C_ERR}Escribe ${C_BOLD}SI${C_NORM}${C_ERR} para confirmar: ${C_NORM}"
    read confirm
    [[ "$confirm" == "SI" ]]
}

# --- Breadcrumb de navegacion ---
ui_breadcrumb() {
    local path="$1"
    echo ""
    echo -e "  ${C_DIM}${path}${C_NORM}"
    echo ""
}

# --- Mensaje de exito ---
ui_ok() {
    echo -e "  ${C_OK}[OK]${C_NORM} $1"
}

# --- Mensaje de error ---
ui_error() {
    echo -e "  ${C_ERR}[ERROR]${C_NORM} $1"
}

# --- Mensaje de info ---
ui_info() {
    echo -e "  ${C_OK}[INFO]${C_NORM} $1"
}

# --- Mensaje de warning ---
ui_warn() {
    echo -e "  ${C_WARN}[WARN]${C_NORM} $1"
}

# --- Completar accion con Enter ---
ui_pause() {
    echo ""
    echo -ne "  ${C_DIM}Presiona Enter para continuar...${C_NORM}"
    read -r
}

# ========================= LOG FUNCTIONS =========================

log_audit() {
    local action="$1" detail="$2"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $action: $detail" >> "$AUDIT_LOG"
}

log_info() { ui_info "$1"; }
log_warn() { ui_warn "$1"; }
log_error() { ui_error "$1"; }
log_success() { ui_ok "$1"; }

confirm_action() {
    local msg="${1:-¿Estas seguro?}"
    ui_confirm_destructive "$msg"
}

# ========================= BASE FUNCTIONS =========================

check_root() {
    if [[ $EUID -ne 0 ]]; then
        ui_error "Este script debe ejecutarse como root"
        exit 1
    fi
}

check_dependencies() {
    local deps=("curl" "wget" "jq" "openssl" "systemctl" "ufw" "fail2ban-client")
    local missing=()
    for dep in "${deps[@]}"; do
        command -v "$dep" &>/dev/null || missing+=("$dep")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        ui_warn "Dependencias faltantes: ${missing[*]}"
        ui_info "Instalando dependencias..."
        apt-get update -qq 2>/dev/null
        apt-get install -y -qq "${missing[@]}" 2>/dev/null
    fi
}

init_directories() {
    mkdir -p "$CRISDEV_HOME" "$CRISDEV_DATA" "$CRISDEV_LOGS" "$CRISDEV_BACKUPS" "$CERT_DIR"
    [[ -f "$USERS_DB" ]] || echo '[]' > "$USERS_DB"
    [[ -f "$SERVER_CONFIG" ]] || echo '{}' > "$SERVER_CONFIG"
    [[ -f "$STATE_FILE" ]] || echo '{"services":{},"ports":{}}' > "$STATE_FILE"
    [[ -f "$AUDIT_LOG" ]] || touch "$AUDIT_LOG"
}

get_server_ip() {
    curl -s4 ifconfig.me 2>/dev/null || curl -s4 ipinfo.io/ip 2>/dev/null || hostname -I | awk '{print $1}'
}

get_server_domain() { jq -r '.domain // empty' "$SERVER_CONFIG" 2>/dev/null; }
generate_uuid() { cat /proc/sys/kernel/random/uuid 2>/dev/null || python3 -c "import uuid; print(uuid.uuid4())" 2>/dev/null || openssl rand -hex 16; }
generate_password() { openssl rand -base64 12 | tr -d '/+=' | head -c 16; }

json_add_user() { local tmp; tmp=$(mktemp); jq ". + [$1]" "$USERS_DB" > "$tmp" && mv "$tmp" "$USERS_DB"; }
json_remove_user() { local tmp; tmp=$(mktemp); jq "map(select(.username != \"$1\"))" "$USERS_DB" > "$tmp" && mv "$tmp" "$USERS_DB"; }
json_update_user() { local tmp; tmp=$(mktemp); jq "map(if .username == \"$1\" then . + ($2) else . end)" "$USERS_DB" > "$tmp" && mv "$tmp" "$USERS_DB"; }
user_exists() { jq -e "map(select(.username == \"$1\")) | length > 0" "$USERS_DB" >/dev/null 2>&1; }
get_user() { jq ".[] | select(.username == \"$1\")" "$USERS_DB" 2>/dev/null; }

# ========================= INSTALADOR =========================

install_complete() {
    ui_clear
    ui_banner_welcome
    echo -e "  ${C_BOLD}${C_INFO}INSTALACION COMPLETA CRISDEV VPN MANAGER${C_NORM}"
    ui_separator
    echo ""

    local SERVER_IP
    SERVER_IP=$(get_server_ip)

    echo -e "  ${C_BOLD}Paso 1/10: Configuracion del servidor${C_NORM}"
    read -p "  IP del servidor [$SERVER_IP]: " INPUT_IP
    SERVER_IP="${INPUT_IP:-$SERVER_IP}"
    read -p "  Dominio del servidor (vacio si no tienes): " SERVER_DOMAIN
    # Validar dominio si se proporciono
    if [[ -n "$SERVER_DOMAIN" ]]; then
        if ! echo "$SERVER_DOMAIN" | grep -qP '^([a-z0-9]+(-[a-z0-9]+)*\.)+[a-z]{2,}$'; then
            ui_error "Dominio invalido: $SERVER_DOMAIN"
            ui_info "Ejemplo: test.crisdev.online"
            read -p "  Dominio correcto: " SERVER_DOMAIN
        fi
        # Verificar que el DNS apunta a este servidor
        local RESOLVED=""
        if command -v dig &>/dev/null; then
            RESOLVED=$(dig +short "$SERVER_DOMAIN" 2>/dev/null | head -1)
        elif command -v host &>/dev/null; then
            RESOLVED=$(host "$SERVER_DOMAIN" 2>/dev/null | awk '/has address/ {print $NF; exit}')
        elif command -v nslookup &>/dev/null; then
            RESOLVED=$(nslookup "$SERVER_DOMAIN" 2>/dev/null | awk '/Address:/ {print $2; exit}')
        fi
        if [[ -n "$RESOLVED" ]] && [[ "$RESOLVED" != "$SERVER_IP" ]]; then
            ui_warn "DNS de $SERVER_DOMAIN apunta a $RESOLVED (no a $SERVER_IP)"
            ui_info "El certificado TLS podria fallar. Verifica la configuracion DNS."
        fi
    fi
    read -p "  Email para certificados TLS (vacio si no tienes): " EMAIL_TLS

    jq -n --arg ip "$SERVER_IP" --arg domain "$SERVER_DOMAIN" --arg email "$EMAIL_TLS" \
        '{server_ip: $ip, domain: $domain, email_tls: $email, installed_at: now | todate}' > "$SERVER_CONFIG"
    ui_info "IP: $SERVER_IP"

    echo -e "\n  ${C_BOLD}Paso 2/10: Actualizando sistema...${C_NORM}"
    apt-get update -qq 2>/dev/null || true; apt-get upgrade -y -qq 2>/dev/null || true
    ui_ok "Sistema actualizado"

    echo -e "\n  ${C_BOLD}Paso 3/10: Instalando dependencias...${C_NORM}"
    apt-get install -y -qq curl wget jq openssl git unzip stunnel4 dropbear socat netcat-openbsd bc coreutils python3 python3-pip libssl-dev screen tmux nano vim dnsutils 2>/dev/null || true
    ui_ok "Dependencias instaladas"

    echo -e "\n  ${C_BOLD}Paso 4/10: Configurando firewall...${C_NORM}"
    configure_firewall_base

    echo -e "\n  ${C_BOLD}Paso 5/10: Configurando fail2ban...${C_NORM}"
    apt-get install -y -qq fail2ban 2>/dev/null || true
    configure_fail2ban

    echo -e "\n  ${C_BOLD}Paso 6/10: Configurando SSH...${C_NORM}"
    configure_ssh_base

    echo -e "\n  ${C_BOLD}Paso 7/10: Instalando Xray-core...${C_NORM}"
    install_xray_core || ui_error "Error instalando Xray-core (puedes instalarlo despues)"
    # Generar configuracion Xray con UUIDs y protocols
    generate_xray_config || ui_error "Error generando config Xray"

    echo -e "\n  ${C_BOLD}Paso 8/10: Instalando Hysteria2...${C_NORM}"
    install_hysteria2 || ui_error "Error instalando Hysteria2 (puedes instalarlo despues)"
    # Configurar Hysteria2 con password y obfs automaticos
    configure_hysteria2 "$PORT_HYSTERIA" "auto" || ui_error "Error configurando Hysteria2"

    echo -e "\n  ${C_BOLD}Paso 9/10: Instalando udp-custom...${C_NORM}"
    install_udp_custom || ui_error "Error instalando udp-custom (puedes instalarlo despues)"

    echo -e "\n  ${C_BOLD}Paso 10/10: Configurando certificados TLS...${C_NORM}"
    if [[ -n "$SERVER_DOMAIN" ]]; then
        install_acme_sh || true
        issue_certificate "$SERVER_DOMAIN" || ui_error "Error emitiendo certificado"
    else
        ui_warn "Sin dominio — se usaran certificados autofirmados"
        generate_self_signed_cert
    fi

    # Reiniciar todos los servicios con los certificados correctos
    ui_info "Reiniciando servicios..."
    systemctl restart xray 2>/dev/null || true
    systemctl restart hysteria-server 2>/dev/null || true
    systemctl restart stunnel4 2>/dev/null || true
    systemctl restart udp-custom 2>/dev/null || true

    echo ""
    install_crisdev_command

    # Mostrar informacion de conexion
    echo ""
    echo -e "  ${C_BOLD}${C_OK}═══════════════════════════════════════════════════${C_NORM}"
    echo -e "  ${C_BOLD}${C_OK}  INSTALACION COMPLETADA EXITOSAMENTE${C_NORM}"
    echo -e "  ${C_BOLD}${C_OK}═══════════════════════════════════════════════════${C_NORM}"
    echo -e "  IP: ${C_BOLD}$SERVER_IP${C_NORM}"
    [[ -n "$SERVER_DOMAIN" ]] && echo -e "  Dominio: ${C_BOLD}$SERVER_DOMAIN${C_NORM}"
    echo -e "  SSH: ${C_BOLD}$PORT_SSH${C_NORM} | SSH-SSL: ${C_BOLD}$PORT_SSH_SSL${C_NORM} | Xray: ${C_BOLD}$PORT_XRAY_WS${C_NORM}"
    echo -e "  Hysteria2: ${C_BOLD}$PORT_HYSTERIA${C_NORM}/udp | udp-custom: ${C_BOLD}$PORT_UDP_CUSTOM${C_NORM}/udp"
    echo ""
    # Mostrar contrasenas generadas
    if [[ -f /etc/hysteria/config.yaml ]]; then
        local HY_AUTH; HY_AUTH=$(grep "password:" /etc/hysteria/config.yaml | head -1 | awk -F'"' '{print $2}')
        local HY_OBFS; HY_OBFS=$(grep "password:" /etc/hysteria/config.yaml | tail -1 | awk -F'"' '{print $2}')
        if [[ -n "$HY_AUTH" ]]; then
            echo -e "  ${C_BOLD}Credenciales Hysteria2:${C_NORM}"
            echo -e "  Auth password: ${C_BOLD}$HY_AUTH${C_NORM}"
            echo -e "  Obfs password:  ${C_BOLD}$HY_OBFS${C_NORM}"
            local HOST="${SERVER_DOMAIN:-$SERVER_IP}"
            echo -e "  Link: ${C_INFO}hysteria2://${HY_AUTH}@${HOST}:${PORT_HYSTERIA}?obfs=salamander&obfs-password=${HY_OBFS}#CRISDEV${C_NORM}"
        fi
    fi
    echo ""
    echo -e "  Ejecuta ${C_BOLD}crisdev${C_NORM} para administrar"
    log_audit "INSTALL" "Instalacion completa en $SERVER_IP"
}

install_crisdev_command() {
    local script_path
    script_path=$(realpath "$0")
    ln -sf "$script_path" /usr/local/bin/crisdev
    chmod +x /usr/local/bin/crisdev
    ui_ok "Comando 'crisdev' instalado"
}

# ========================= FIREWALL =========================

configure_firewall_base() {
    if ! command -v ufw &>/dev/null; then apt-get install -y -qq ufw 2>/dev/null; fi
    ufw disable 2>/dev/null || true; sleep 1
    echo "y" | ufw reset 2>/dev/null || true; sleep 1
    ufw default deny incoming 2>/dev/null || true
    ufw default allow outgoing 2>/dev/null || true
    ufw allow "$PORT_SSH/tcp" comment "SSH" 2>/dev/null || true
    ufw allow "$PORT_SSH_ALT/tcp" comment "SSH-ALT" 2>/dev/null || true
    ufw allow "$PORT_SSH_SSL/tcp" comment "SSH-SSL" 2>/dev/null || true
    ufw allow "$PORT_XRAY_WS/tcp" comment "Xray-WS" 2>/dev/null || true
    ufw allow "$PORT_XRAY_GRPC/tcp" comment "Xray-gRPC" 2>/dev/null || true
    ufw allow "$PORT_XRAY_REALITY/tcp" comment "Xray-REALITY" 2>/dev/null || true
    ufw allow "$PORT_XRAY_VLESS/tcp" comment "Xray-VLESS" 2>/dev/null || true
    ufw allow "$PORT_HYSTERIA/udp" comment "Hysteria2" 2>/dev/null || true
    ufw allow "$PORT_WEBSOCKET/tcp" comment "WebSocket" 2>/dev/null || true
    ufw allow "$PORT_UDP_CUSTOM/udp" comment "udp-custom" 2>/dev/null || true
    echo "y" | ufw enable 2>/dev/null || true
    ui_ok "Firewall configurado"
}

open_port() { ufw allow "$1/$2" comment "$3" >/dev/null 2>&1; ui_info "Puerto $1/$2 abierto ($3)"; }
close_port() { ufw delete allow "$1/$2" >/dev/null 2>&1; ui_info "Puerto $1/$2 cerrado"; }

# ========================= FAIL2BAN =========================

configure_fail2ban() {
    cat > /etc/fail2ban/jail.local <<'F2B'
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 5
banaction = ufw
[sshd]
enabled = true
port    = ssh
filter  = sshd
logpath = /var/log/auth.log
maxretry = 3
F2B
    systemctl enable fail2ban >/dev/null 2>&1
    systemctl restart fail2ban >/dev/null 2>&1
    ui_ok "fail2ban configurado"
}

# ========================= SSH =========================

configure_ssh_base() {
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak 2>/dev/null || true
    cat > /etc/ssh/sshd_config.d/crisdev.conf <<SSHEOF
Port $PORT_SSH
Port $PORT_SSH_ALT
Protocol 2
PermitRootLogin prohibit-password
PasswordAuthentication yes
PubkeyAuthentication yes
X11Forwarding no
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
UseDNS no
Banner /etc/issue.net
SSHEOF
    cat > /etc/issue.net <<'BANNER'
╔══════════════════════════════════════════╗
║     CRISDEV VPN Server - Acceso SSH     ║
║     Conexiones monitoreadas             ║
╚══════════════════════════════════════════╝
BANNER
    systemctl restart sshd >/dev/null 2>&1 || systemctl restart ssh >/dev/null 2>&1
    ui_ok "SSH configurado (puertos $PORT_SSH, $PORT_SSH_ALT)"
    # Desactivar Dropbear si esta corriendo para evitar conflicto
    systemctl stop dropbear 2>/dev/null || true
    systemctl disable dropbear 2>/dev/null || true
}

configure_dropbear() {
    local port="${1:-110}"
    # Asegurar que SSH no este en el puerto de Dropbear
    if ss -tlnp 2>/dev/null | grep -q ":$port "; then
        ui_error "Puerto $port ya esta en uso"
        return 1
    fi
    # Configurar Dropbear
    sed -i 's/^NO_START=1/NO_START=0/' /etc/default/dropbear 2>/dev/null || true
    sed -i "s/^DROPBEAR_PORT=.*/DROPBEAR_PORT=$port/" /etc/default/dropbear 2>/dev/null || true
    # Si el archivo no tiene DROPBEAR_PORT, agregarlo
    if ! grep -q "DROPBEAR_PORT" /etc/default/dropbear 2>/dev/null; then
        echo -e "DROPBEAR_PORT=$port\nDROPBEAR_EXTRA_ARGS=\"\"\nNO_START=0" >> /etc/default/dropbear
    fi
    systemctl enable dropbear >/dev/null 2>&1
    systemctl restart dropbear >/dev/null 2>&1
    open_port "$port" "tcp" "Dropbear"
    ui_ok "Dropbear SSH configurado en puerto $port"
}

create_ssh_user() {
    local username="$1" password="$2"
    if id "$username" &>/dev/null; then ui_error "Usuario $username ya existe"; return 1; fi
    useradd -m -s /bin/false "$username" 2>/dev/null
    echo "$username:$password" | chpasswd 2>/dev/null
    chsh -s /bin/false "$username" 2>/dev/null || true
    ui_ok "Usuario SSH $username creado"
}

# ========================= SSH-SSL =========================

configure_stunnel() {
    local port="${1:-$PORT_SSH_SSL}"
    apt-get install -y -qq stunnel4 2>/dev/null
    cat > /etc/stunnel/stunnel.conf <<STEOF
pid = /var/run/stunnel4/stunnel.pid
setuid = stunnel4
setgid = stunnel4
debug = 0
foreground = no
[ssh-tunnel]
accept = 0.0.0.0:$port
connect = 127.0.0.1:$PORT_SSH
cert = $CERT_DIR/stunnel.pem
TIMEOUTclose = 0
STEOF
    if [[ ! -f "$CERT_DIR/stunnel.pem" ]]; then
        openssl req -new -x509 -days 3650 -nodes -out "$CERT_DIR/stunnel.pem" -keyout "$CERT_DIR/stunnel.key" -subj "/CN=crisdev-stunnel" 2>/dev/null
        cat "$CERT_DIR/stunnel.pem" "$CERT_DIR/stunnel.key" > "$CERT_DIR/stunnel.pem"
        rm -f "$CERT_DIR/stunnel.key"
    fi
    mkdir -p /var/run/stunnel4
    systemctl enable stunnel4 >/dev/null 2>&1
    systemctl restart stunnel4 >/dev/null 2>&1
    open_port "$port" "tcp" "SSH-SSL"
    ui_ok "SSH-SSL configurado en puerto $port"
}

# ========================= SLOWDNS =========================

install_slowdns() {
    ui_breadcrumb "CRISDEV > Protocolos > SlowDNS"
    echo -e "  ${C_BOLD}${C_INFO}INSTALACION SLOWDNS${C_NORM}"
    ui_separator
    read -p "  Dominio NS delegado: " SLOWDNS_DOMAIN
    read -p "  Puerto DNS [53]: " SLOWDNS_PORT; SLOWDNS_PORT="${SLOWDNS_PORT:-53}"
    local arch; arch=$(uname -m)
    case "$arch" in x86_64) arch="amd64" ;; aarch64) arch="arm64" ;; armv7l) arch="armv7" ;; esac
    mkdir -p /opt/slowdns; cd /opt/slowdns
    if [[ ! -f server ]]; then
        wget -q "https://github.com/earthxam/slowdns/releases/latest/download/server-linux-${arch}" -O server 2>/dev/null
        chmod +x server
    fi
    [[ ! -f server.key ]] && ./server -gen-key -privkey-file server.key -pubkey-file server.pub
    cat > /etc/systemd/system/slowdns.service <<SVCEOF
[Unit]
Description=SlowDNS Tunnel
After=network.target
[Service]
Type=simple
ExecStart=/opt/slowdns/server -udp 0.0.0.0:${SLOWDNS_PORT} -privkey-server /opt/slowdns/server.key -pubkey-client /opt/slowdns/server.pub -dns-addr ${SLOWDNS_DOMAIN}:${SLOWDNS_PORT} -silent
Restart=always
RestartSec=3
LimitNOFILE=65535
[Install]
WantedBy=multi-user.target
SVCEOF
    systemctl daemon-reload; systemctl enable slowdns >/dev/null 2>&1; systemctl start slowdns 2>/dev/null || true
    open_port "$SLOWDNS_PORT" "udp" "SlowDNS"; open_port "$SLOWDNS_PORT" "tcp" "SlowDNS"
    ui_ok "SlowDNS instalado en puerto $SLOWDNS_PORT"
    echo -e "  Llave publica: ${C_BOLD}$(cat /opt/slowdns/server.pub)${C_NORM}"
    log_audit "SLOWDNS" "Instalado en $SLOWDNS_PORT"
    cd - >/dev/null
}

# ========================= XRAY-CORE =========================

install_xray_core() {
    local latest_version; latest_version=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -r '.tag_name' 2>/dev/null || echo "v1.8.4")
    local arch; arch=$(uname -m)
    case "$arch" in x86_64) arch="64" ;; aarch64) arch="arm64-v8a" ;; armv7l) arch="arm32-v7a" ;; esac
    mkdir -p /opt/xray
    if [[ ! -f /opt/xray/xray ]]; then
        ui_info "Descargando Xray-core $latest_version..."
        wget -q "https://github.com/XTLS/Xray-core/releases/download/${latest_version}/Xray-linux-${arch}.zip" -O /tmp/xray.zip 2>/dev/null
        unzip -o /tmp/xray.zip -d /opt/xray/ >/dev/null 2>&1; chmod +x /opt/xray/xray; rm -f /tmp/xray.zip
    fi
    mkdir -p /usr/local/etc/xray
    cat > /etc/systemd/system/xray.service <<'XEOF'
[Unit]
Description=Xray Service
After=network.target nss-lookup.target
[Service]
Type=simple
ExecStart=/opt/xray/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartSec=3
LimitNOFILE=65535
[Install]
WantedBy=multi-user.target
XEOF
    systemctl daemon-reload; systemctl enable xray >/dev/null 2>&1
    ui_ok "Xray-core instalado"
}

generate_xray_config() {
    local SERVER_IP; SERVER_IP=$(get_server_ip)
    local SERVER_DOMAIN; SERVER_DOMAIN=$(get_server_domain)
    local UUID_VLESS; UUID_VLESS=$(generate_uuid)
    local UUID_VMESS; UUID_VMESS=$(generate_uuid)
    local WS_PATH="/$(openssl rand -hex 8)"
    local GRPC_SERVICE="grpc-$(openssl rand -hex 4)"
    local TROJAN_PASS; TROJAN_PASS=$(generate_password)
    local CERT_PATH="$CERT_DIR/fullchain.pem" KEY_PATH="$CERT_DIR/privkey.pem"
    [[ ! -f "$CERT_PATH" ]] && CERT_PATH="$CERT_DIR/self-signed.pem" && KEY_PATH="$CERT_DIR/self-signed-key.pem"
    # Generar claves REALITY ANTES de escribir config
    local REALITY_PUB=""
    local REALITY_KEY=""
    if [[ -f /opt/xray/xray ]]; then
        local RK; RK=$(/opt/xray/xray x25519 2>/dev/null || echo "")
        if [[ -n "$RK" ]]; then
            REALITY_KEY=$(echo "$RK" | grep "Private" | awk '{print $3}')
            REALITY_PUB=$(echo "$RK" | grep "Public" | awk '{print $3}')
        fi
    fi

    cat > /usr/local/etc/xray/config.json <<XRAYEOF
{
    "log":{"loglevel":"warning","access":"/var/log/xray/access.log","error":"/var/log/xray/error.log"},
    "inbounds":[
        {"tag":"vless-ws","listen":"0.0.0.0","port":$PORT_XRAY_WS,"protocol":"vless","settings":{"clients":[{"id":"$UUID_VLESS","flow":""}],"decryption":"none"},"streamSettings":{"network":"ws","security":"tls","tlsSettings":{"certificates":[{"certificateFile":"$CERT_PATH","keyFile":"$KEY_PATH"}],"minVersion":"1.2","alpn":["h2","http/1.1"]},"wsSettings":{"path":"$WS_PATH","headers":{"Host":"${SERVER_DOMAIN:-$SERVER_IP}"}}},"sniffing":{"enabled":true,"destOverride":["http","tls"]}},
        {"tag":"vless-grpc","listen":"0.0.0.0","port":$PORT_XRAY_GRPC,"protocol":"vless","settings":{"clients":[{"id":"$UUID_VLESS","flow":""}],"decryption":"none"},"streamSettings":{"network":"grpc","security":"tls","tlsSettings":{"certificates":[{"certificateFile":"$CERT_PATH","keyFile":"$KEY_PATH"}],"minVersion":"1.2","alpn":["h2"]},"grpcSettings":{"serviceName":"$GRPC_SERVICE"}},"sniffing":{"enabled":true,"destOverride":["http","tls"]}},
        {"tag":"vmess-ws","listen":"0.0.0.0","port":$PORT_WEBSOCKET,"protocol":"vmess","settings":{"clients":[{"id":"$UUID_VMESS","alterId":0}]},"streamSettings":{"network":"ws","security":"tls","tlsSettings":{"certificates":[{"certificateFile":"$CERT_PATH","keyFile":"$KEY_PATH"}],"minVersion":"1.2","alpn":["h2","http/1.1"]},"wsSettings":{"path":"/vmess-ws","headers":{"Host":"${SERVER_DOMAIN:-$SERVER_IP}"}}},"sniffing":{"enabled":true,"destOverride":["http","tls"]}},
        {"tag":"vless-reality","listen":"0.0.0.0","port":$PORT_XRAY_REALITY,"protocol":"vless","settings":{"clients":[{"id":"$UUID_VLESS","flow":"xtls-rprx-vision"}],"decryption":"none"},"streamSettings":{"network":"tcp","security":"reality","realitySettings":{"show":false,"dest":"www.microsoft.com:443","xver":0,"serverNames":["www.microsoft.com","www.apple.com","www.samsung.com"],"privateKey":"$REALITY_KEY","publicKey":"$REALITY_PUB","shortIds":["6ba85179e30d4fc2"]}},"sniffing":{"enabled":true,"destOverride":["http","tls"]}},
        {"tag":"trojan-ws","listen":"0.0.0.0","port":$PORT_XRAY_VLESS,"protocol":"trojan","settings":{"clients":[{"password":"$TROJAN_PASS"}]},"streamSettings":{"network":"ws","security":"tls","tlsSettings":{"certificates":[{"certificateFile":"$CERT_PATH","keyFile":"$KEY_PATH"}],"minVersion":"1.2","alpn":["h2","http/1.1"]},"wsSettings":{"path":"/trojan-ws"}},"sniffing":{"enabled":true,"destOverride":["http","tls"]}}
    ],
    "routing":{"domainStrategy":"AsIs","rules":[{"type":"field","outboundTag":"blocked","ip":["geoip:private"]}]},
    "outbounds":[{"protocol":"freedom","tag":"direct"},{"protocol":"blackhole","tag":"blocked"}]
}
XRAYEOF
    mkdir -p /var/log/xray; touch /var/log/xray/access.log /var/log/xray/error.log
    # Mostrar claves REALITY
    if [[ -n "$REALITY_PUB" ]]; then
        ui_info "REALITY Public Key: $REALITY_PUB"
    fi
    # Guardar paths y UUIDs para que generate_user_links los use
    local tmp; tmp=$(mktemp)
    jq --arg ws "$WS_PATH" --arg grpc "$GRPC_SERVICE" --arg uuid "$UUID_VLESS" \
       --arg vmess "$UUID_VMESS" --arg trojan "$TROJAN_PASS" \
       '. + {xray_ws_path: $ws, xray_grpc_service: $grpc, uuid_vless: $uuid, uuid_vmess: $vmess, trojan_pass: $trojan}' \
       "$SERVER_CONFIG" > "$tmp" 2>/dev/null && mv "$tmp" "$SERVER_CONFIG"
    ui_ok "Configuracion Xray generada (VLESS-WS, VLESS-gRPC, VMess-WS, VLESS-REALITY, Trojan-WS)"
    log_audit "XRAY" "Configuracion generada"
}


# ========================= HYSTERIA2 =========================

install_hysteria2() {
    bash <(curl -fsSL https://get.hy2.sh/) 2>/dev/null
    mkdir -p /etc/hysteria
    ui_ok "Hysteria2 instalado"
}

configure_hysteria2() {
    local port="${1:-$PORT_HYSTERIA}"
    local SERVER_DOMAIN; SERVER_DOMAIN=$(get_server_domain)
    local AUTO_MODE="${2:-}"
    local OBFS_PASS
    if [[ "$AUTO_MODE" == "auto" ]]; then
        OBFS_PASS=$(generate_password)
    else
        read -p "  Obfs password [auto-generate]: " OBFS_PASS; OBFS_PASS="${OBFS_PASS:-$(generate_password)}"
    fi
    local AUTH_PASS; AUTH_PASS=$(generate_password)
    local CERT_PATH="$CERT_DIR/fullchain.pem" KEY_PATH="$CERT_DIR/privkey.pem"
    [[ ! -f "$CERT_PATH" ]] && CERT_PATH="$CERT_DIR/self-signed.pem" && KEY_PATH="$CERT_DIR/self-signed-key.pem"
    cat > /etc/hysteria/config.yaml <<HYEOF
listen: :$port
tls:
  cert: $CERT_PATH
  key: $KEY_PATH
auth:
  type: password
  password: "$AUTH_PASS"
obfs:
  type: salamander
  salamander:
    password: "$OBFS_PASS"
bandwidth:
  up: 100 mbps
  down: 100 mbps
masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com
    rewriteHost: true
HYEOF
    systemctl enable hysteria-server >/dev/null 2>&1; systemctl restart hysteria-server 2>/dev/null || true
    open_port "$port" "udp" "Hysteria2"
    # Guardar passwords para generate_user_links
    local tmp; tmp=$(mktemp)
    jq --arg auth "$AUTH_PASS" --arg obfs "$OBFS_PASS" \
       '. + {hysteria_auth_pass: $auth, hysteria_obfs_pass: $obfs}' \
       "$SERVER_CONFIG" > "$tmp" 2>/dev/null && mv "$tmp" "$SERVER_CONFIG"
    ui_ok "Hysteria2 configurado en puerto $port"
    if [[ "$AUTO_MODE" == "auto" ]]; then
        ui_info "Auth password: $AUTH_PASS"
        ui_info "Obfs password: $OBFS_PASS"
    fi
    log_audit "HYSTERIA2" "Configurado en $port"
}

# ========================= UDP-CUSTOM =========================

install_udp_custom() {
    local arch; arch=$(uname -m)
    case "$arch" in x86_64) arch="amd64" ;; aarch64) arch="arm64" ;; armv7l) arch="armv7" ;; esac
    mkdir -p /opt/udp-custom
    if [[ ! -f /opt/udp-custom/server ]]; then
        wget -q "https://github.com/AmnesiaPod/UDPCustom/releases/latest/download/udp-custom-linux-${arch}" -O /opt/udp-custom/server 2>/dev/null || \
        wget -q "https://github.com/JoYonghyeok/UDPCustom/releases/latest/download/udp-custom-linux-${arch}" -O /opt/udp-custom/server 2>/dev/null
        chmod +x /opt/udp-custom/server
    fi
    ui_ok "udp-custom instalado"
}

configure_udp_custom() {
    local port_range="${1:-$PORT_UDP_CUSTOM}"
    cat > /opt/udp-custom/config.json <<UDPEOF
{"bind":"0.0.0.0:${port_range%%-*}","stream_buffer_size":2048,"core_buffer_size":1024,"max_open_stream":4096,"max_open_conn":10240,"stream_congestion_control":"bbr","conn_congestion_control":"bbr","enable_metrics":false}
UDPEOF
    cat > /etc/systemd/system/udp-custom.service <<'UDEOF'
[Unit]
Description=UDP Custom Server
After=network.target
[Service]
Type=simple
ExecStart=/opt/udp-custom/server -c /opt/udp-custom/config.json
Restart=on-failure
RestartSec=3
LimitNOFILE=65535
[Install]
WantedBy=multi-user.target
UDEOF
    systemctl daemon-reload; systemctl enable udp-custom >/dev/null 2>&1; systemctl restart udp-custom 2>/dev/null || true
    open_port "${port_range%%-*}" "udp" "udp-custom"
    ui_ok "udp-custom configurado en puerto $port_range"
}

# ========================= CERTIFICADOS TLS =========================

install_acme_sh() {
    if [[ ! -f ~/.acme.sh/acme.sh ]]; then
        curl -fsSL https://get.acme.sh | sh -s -- --install-online 2>/dev/null
        ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt 2>/dev/null
    fi
    # Verificar que acme.sh se instalo correctamente
    if [[ ! -f ~/.acme.sh/acme.sh ]]; then
        ui_error "acme.sh no se pudo instalar"
        return 1
    fi
    ui_ok "acme.sh instalado"
}

issue_certificate() {
    local domain="$1"
    [[ -z "$domain" ]] && { ui_error "Se requiere dominio"; return 1; }
    ui_info "Emitiendo certificado para $domain..."
    local saved; saved=$(systemctl is-active xray 2>/dev/null || echo "inactive")
    systemctl stop xray 2>/dev/null || true
    # Intentar emitir certificado
    if ! ~/.acme.sh/acme.sh --issue -d "$domain" --standalone --force 2>/dev/null; then
        ui_error "Error al emitir certificado para $domain"
        ui_info "Verifica que el DNS del dominio apunte a este servidor"
        [[ "$saved" == "active" ]] && systemctl start xray 2>/dev/null || true
        return 1
    fi
    # Instalar certificado
    if ! ~/.acme.sh/acme.sh --install-cert -d "$domain" --key-file "$CERT_DIR/privkey.pem" --fullchain-file "$CERT_DIR/fullchain.pem" --reloadcmd "systemctl restart xray; systemctl restart hysteria-server; systemctl restart stunnel4" 2>/dev/null; then
        ui_error "Error al instalar certificado"
        [[ "$saved" == "active" ]] && systemctl start xray 2>/dev/null || true
        return 1
    fi
    # Verificar que los archivos existen
    if [[ ! -f "$CERT_DIR/fullchain.pem" ]] || [[ ! -f "$CERT_DIR/privkey.pem" ]]; then
        ui_error "Certificados no se generaron correctamente"
        [[ "$saved" == "active" ]] && systemctl start xray 2>/dev/null || true
        return 1
    fi
    [[ "$saved" == "active" ]] && systemctl start xray 2>/dev/null || true
    ui_ok "Certificado emitido para $domain"
    log_audit "CERT" "Emitido para $domain"
}

generate_self_signed_cert() {
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 -keyout "$CERT_DIR/self-signed-key.pem" -out "$CERT_DIR/self-signed.pem" -subj "/CN=crisdev-vpn/O=CRISDEV/C=US" 2>/dev/null
    ui_ok "Certificado autofirmado generado (10 anios)"
}

renew_certificates() {
    ~/.acme.sh/acme.sh --renew-all 2>/dev/null
    systemctl restart xray 2>/dev/null || true; systemctl restart hysteria-server 2>/dev/null || true; systemctl restart stunnel4 2>/dev/null || true
    ui_info "Certificados renovados"
}

# ========================= USUARIOS =========================

create_user() {
    ui_breadcrumb "CRISDEV > Usuarios > Crear"
    echo -e "  ${C_BOLD}${C_INFO}CREAR USUARIO${C_NORM}"
    ui_separator

    read -p "  Nombre de usuario: " username
    [[ -z "$username" ]] && { ui_error "Nombre no puede estar vacio"; return 1; }
    user_exists "$username" && { ui_error "Usuario $username ya existe"; return 1; }

    read -p "  Contrasena (vacio = auto-generar): " password
    password="${password:-$(generate_password)}"

    echo -e "\n  ${C_BOLD}Protocolos:${C_NORM}"
    echo "    1) SSH          6) Xray VMess"
    echo "    2) SSH-SSL      7) Xray Trojan"
    echo "    3) WebSocket    8) Hysteria2"
    echo "    4) SlowDNS      9) udp-custom"
    echo "    5) Xray VLESS   0) TODOS"
    read -p "  Selecciona (coma separados): " protocols_input
    local protocols; IFS=',' read -ra protocols <<< "$protocols_input"

    read -p "  Dias de vigencia [30]: " days; days="${days:-30}"
    read -p "  Max conexiones simultaneas [2]: " max_conn; max_conn="${max_conn:-2}"
    read -p "  Limite BW (Mbps, 0=sin limite) [0]: " bw_limit; bw_limit="${bw_limit:-0}"

    local exp_date; exp_date=$(date -d "+${days} days" '+%Y-%m-%d %H:%M:%S')
    local user_json; user_json=$(jq -n --arg u "$username" --arg p "$password" --arg exp "$exp_date" --argjson mc "$max_conn" --argjson bw "$bw_limit" --argjson protos "$(printf '%s\n' "${protocols[@]}" | jq -R . | jq -s .)" --argjson conn "0" \
        '{username:$u,password:$p,status:"active",created_at:(now|todate),expires_at:$exp,max_connections:$mc,current_connections:$conn,bandwidth_limit:$bw,protocols:$protos,data_used_bytes:0,last_login:null,last_ip:null}')
    json_add_user "$user_json"

    for proto in "${protocols[@]}"; do
        case "$proto" in 1|"ssh"|"2"|"ssh-ssl") create_ssh_user "$username" "$password" ;; esac
    done

    echo ""
    echo -e "  ${C_BOLD}${C_OK}USUARIO CREADO EXITOSAMENTE${C_NORM}"
    echo -e "  Usuario:    ${C_BOLD}$username${C_NORM}"
    echo -e "  Contrasena: ${C_BOLD}$password${C_NORM}"
    echo -e "  Expira:     ${C_BOLD}$exp_date${C_NORM}"
    echo -e "  Protocolos: ${C_BOLD}${protocols[*]}${C_NORM}"
    echo -e "  Max conex:  ${C_BOLD}$max_conn${C_NORM}"
    log_audit "USER_CREATE" "$username, protos: ${protocols[*]}, expira: $exp_date"
}

edit_user() {
    ui_breadcrumb "CRISDEV > Usuarios > Editar"
    echo -e "  ${C_BOLD}${C_INFO}EDITAR USUARIO${C_NORM}"
    ui_separator
    read -p "  Usuario a editar: " username
    user_exists "$username" || { ui_error "Usuario no encontrado"; return 1; }

    local ud; ud=$(get_user "$username")
    echo -e "\n  ${C_DIM}Datos actuales:${C_NORM}"
    echo "$ud" | jq -r '"  Estado: \(.status)  |  Expira: \(.expires_at)  |  MaxConex: \(.max_connections)  |  BW: \(.bandwidth_limit)Mbps\n  Protocolos: \(.protocols | join(", "))"'

    echo -e "\n  ${C_BOLD}Que deseas cambiar?${C_NORM}"
    echo "    1) Contrasena       4) Limite BW"
    echo "    2) Expiracion       5) Protocolos"
    echo "    3) Max conexiones   0) Volver"
    read -p "  Opcion: " opt
    case $opt in
        1) read -p "  Nueva contrasena: " np; [[ -n "$np" ]] && json_update_user "$username" "{\"password\":\"$np\"}" && echo "$username:$np" | chpasswd 2>/dev/null || true ;;
        2) read -p "  Dias a agregar: " nd; local ne; ne=$(date -d "+${nd} days" '+%Y-%m-%d %H:%M:%S'); json_update_user "$username" "{\"expires_at\":\"$ne\"}" ;;
        3) read -p "  Nuevo max: " nm; json_update_user "$username" "{\"max_connections\":$nm}" ;;
        4) read -p "  Nuevo BW (0=sin limite): " nb; json_update_user "$username" "{\"bandwidth_limit\":$nb}" ;;
        5) read -p  "  Nuevos protos (coma): " np2; IFS=',' read -ra pa <<< "$np2"; json_update_user "$username" "{\"protocols\":$(printf '%s\n' "${pa[@]}" | jq -R . | jq -s .)}" ;;
        *) return 0 ;;
    esac
    log_audit "USER_EDIT" "$username"
    ui_ok "Usuario $username actualizado"
}

suspend_user() {
    ui_breadcrumb "CRISDEV > Usuarios > Suspender"
    read -p "  Usuario a suspender: " username
    user_exists "$username" || { ui_error "Usuario no encontrado"; return 1; }
    if ui_confirm_destructive "Suspender a $username? Se cerraran sus sesiones activas."; then
        json_update_user "$username" '{"status":"suspended"}'
        usermod -L "$username" 2>/dev/null || true
        pkill -u "$username" 2>/dev/null || true
        log_audit "USER_SUSPEND" "$username"
        ui_ok "Usuario $username suspendido"
    fi
}

reactivate_user() {
    ui_breadcrumb "CRISDEV > Usuarios > Reactivar"
    read -p "  Usuario a reactivar: " username
    user_exists "$username" || { ui_error "Usuario no encontrado"; return 1; }
    json_update_user "$username" '{"status":"active"}'
    usermod -U "$username" 2>/dev/null || true
    log_audit "USER_REACTIVATE" "$username"
    ui_ok "Usuario $username reactivado"
}

delete_user() {
    ui_breadcrumb "CRISDEV > Usuarios > Eliminar"
    read -p "  Usuario a eliminar: " username
    user_exists "$username" || { ui_error "Usuario no encontrado"; return 1; }
    if ui_confirm_destructive "ELIMINAR a $username permanentemente? Esta accion NO se puede deshacer."; then
        pkill -u "$username" 2>/dev/null || true
        userdel -r "$username" 2>/dev/null || userdel "$username" 2>/dev/null || true
        json_remove_user "$username"
        log_audit "USER_DELETE" "$username"
        ui_ok "Usuario $username eliminado completamente"
    fi
}

renew_user() {
    ui_breadcrumb "CRISDEV > Usuarios > Renovar"
    read -p "  Usuario a renovar: " username
    user_exists "$username" || { ui_error "Usuario no encontrado"; return 1; }
    local ce; ce=$(jq -r ".[] | select(.username == \"$username\") | .expires_at // empty" "$USERS_DB")
    read -p "  Dias a agregar [30]: " ad; ad="${ad:-30}"
    local base
    if [[ -n "$ce" ]]; then
        local ets; ets=$(date -d "$ce" +%s 2>/dev/null || echo 0)
        local now; now=$(date +%s)
        [[ $ets -gt $now ]] && base="$ce" || base=$(date '+%Y-%m-%d %H:%M:%S')
    else
        base=$(date '+%Y-%m-%d %H:%M:%S')
    fi
    local ne; ne=$(date -d "$base + ${ad} days" '+%Y-%m-%d %H:%M:%S')
    json_update_user "$username" "{\"expires_at\":\"$ne\",\"status\":\"active\"}"
    usermod -U "$username" 2>/dev/null || true
    log_audit "USER_RENEW" "$username hasta $ne"
    ui_ok "Usuario $username renovado hasta $ne"
}

list_users() {
    ui_breadcrumb "CRISDEV > Usuarios > Lista"
    echo -e "  ${C_BOLD}${C_INFO}LISTA DE USUARIOS${C_NORM}"
    ui_separator
    echo "    1) Todos    3) Vencidos    5) Por vencer (3d)"
    echo "    2) Activos  4) Suspendidos 6) Por protocolo"
    read -p "  Filtro: " filter
    local query
    case $filter in
        2) query='.[] | select(.status == "active")' ;;
        3) query='[.[] | select(.expires_at != null and (.expires_at | fromdateiso8601) < now)] | .[]' ;;
        4) query='.[] | select(.status == "suspended")' ;;
        5) query='[.[] | select(.expires_at != null and (.expires_at | fromdateiso8601) > now and ((.expires_at | fromdateiso8601) - now) < 259200)] | .[]' ;;
        6) read -p "  Protocolo: " pf; query=".[] | select(.protocols | map(ascii_downcase) | index(\"$pf\"))" ;;
        *) query='.[]' ;;
    esac
    echo ""
    printf "  ${C_BOLD}%-14s %-10s %-12s %-6s %-8s %s${C_NORM}\n" "USUARIO" "ESTADO" "EXPIRA" "CONEX" "BW" "PROTOCOLOS"
    echo -e "  ${C_DIM}───────────────────────────────────────────────────────────────────────${C_NORM}"
    jq -r "$query | @tsv" "$USERS_DB" 2>/dev/null | while IFS=$'\t' read -r u s e c b p; do
        local sc="$C_OK"; [[ "$s" == "suspended" ]] && sc="$C_WARN"; [[ "$s" == "expired" ]] && sc="$C_ERR"
        printf "  %-14s ${sc}%-10s${C_NORM} %-12s %-6s %-8s %s\n" "$u" "$s" "${e:-N/A}" "${c:-0}" "${b:-0}" "${p:-[]}"
    done
    local t; t=$(jq 'length' "$USERS_DB" 2>/dev/null || echo 0)
    local a; a=$(jq '[.[] | select(.status == "active")] | length' "$USERS_DB" 2>/dev/null || echo 0)
    echo -e "\n  Total: ${C_BOLD}$t${C_NORM} | Activos: ${C_OK}${C_BOLD}$a${C_NORM}"
}

user_detail() {
    ui_breadcrumb "CRISDEV > Usuarios > Detalle"
    read -p "  Usuario: " username
    user_exists "$username" || { ui_error "Usuario no encontrado"; return 1; }
    echo ""
    get_user "$username" | jq -r '
        "  ┌─────────────────────────────────────────────┐",
        "  │  DETALLE DE USUARIO                         │",
        "  └─────────────────────────────────────────────┘",
        "",
        "  Usuario:      \(.username)",
        "  Estado:       \(.status)",
        "  Creado:       \(.created_at)",
        "  Expira:       \(.expires_at)",
        "  Max Conex:    \(.max_connections)",
        "  Conexiones:   \(.current_connections)",
        "  BW Limite:    \(.bandwidth_limit) Mbps",
        "  Datos usados: \(.data_used_bytes) bytes",
        "  Ultimo login: \(.last_login // \"Nunca\")",
        "  Ultima IP:    \(.last_ip // \"N/A\")",
        "  Protocolos:   \(.protocols | join(\", \"))"
    '
}

search_users() {
    ui_breadcrumb "CRISDEV > Usuarios > Buscar"
    read -p "  Buscar: " q
    echo ""
    jq -r ".[] | select(.username | contains(\"$q\")) | \"  \(.username)  \(.status)  \(.expires_at // \"N/A\")\"" "$USERS_DB" 2>/dev/null
}

# ========================= MONITOREO =========================

show_server_status() {
    ui_breadcrumb "CRISDEV > Servidor > Estado"
    echo -e "  ${C_BOLD}${C_INFO}ESTADO DEL SERVIDOR${C_NORM}"
    ui_separator

    echo -e "\n  ${C_BOLD}Sistema:${C_NORM}"
    echo "    IP: $(get_server_ip)"
    echo "    Hostname: $(hostname)"
    echo "    OS: $(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d'"' -f2)"
    echo "    Kernel: $(uname -r)"
    echo "    Uptime: $(uptime -p 2>/dev/null || uptime)"

    echo -e "\n  ${C_BOLD}Recursos:${C_NORM}"
    local cpu; cpu=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' 2>/dev/null || echo "N/A")
    echo "    CPU: ${cpu}%"
    free -h | awk '/Mem:/{print "    RAM: "$3"/"$2}'

    echo -e "\n  ${C_BOLD}Servicios:${C_NORM}"
    for svc in xray hysteria-server stunnel4 udp-custom sshd ufw fail2ban; do
        local st; st=$(systemctl is-active "$svc" 2>/dev/null || echo "dead")
        if [[ "$st" == "active" ]]; then
            printf "    ${C_OK}●${C_NORM} %-18s ${C_OK}active${C_NORM}\n" "$svc"
        else
            printf "    ${C_ERR}○${C_NORM} %-18s ${C_ERR}%s${C_NORM}\n" "$svc" "$st"
        fi
    done

    echo -e "\n  ${C_BOLD}Conexiones:${C_NORM}"
    echo "    SSH:     $(ss -tn | grep -c ":$PORT_SSH " 2>/dev/null || echo 0)"
    echo "    Xray:    $(ss -tn | grep -cE ":($PORT_XRAY_WS|$PORT_XRAY_GRPC) " 2>/dev/null || echo 0)"
    echo "    Hysteria: $(ss -un | grep -c ":$PORT_HYSTERIA " 2>/dev/null || echo 0)"
}

show_bandwidth_usage() {
    ui_breadcrumb "CRISDEV > Servidor > Ancho de banda"
    if command -v vnstat &>/dev/null; then vnstat -h 2>/dev/null | head -20
    else ui_info "Instalando vnstat..."; apt-get install -y -qq vnstat 2>/dev/null; vnstat -u 2>/dev/null; sleep 2; vnstat -h 2>/dev/null | head -20; fi
}

# ========================= BACKUPS =========================

create_backup() {
    ui_breadcrumb "CRISDEV > Sistema > Backup"
    echo -e "  ${C_BOLD}${C_INFO}CREAR BACKUP${C_NORM}"
    local ts; ts=$(date +%Y%m%d_%H%M%S)
    local bf="$CRISDEV_BACKUPS/crisdev_backup_${ts}.tar.gz"
    tar -czf "$bf" -C / "etc/crisdev/data" "etc/crisdev/certs" "etc/hysteria" "usr/local/etc/xray" "opt/slowdns/server.key" "opt/slowdns/server.pub" 2>/dev/null
    local sz; sz=$(du -h "$bf" | awk '{print $1}')
    ui_ok "Backup: ${C_BOLD}$bf${C_NORM} ($sz)"
    log_audit "BACKUP" "$bf ($sz)"
}

restore_backup() {
    ui_breadcrumb "CRISDEV > Sistema > Restaurar"
    echo -e "  ${C_BOLD}${C_INFO}RESTAURAR BACKUP${C_NORM}"
    echo ""
    ls "$CRISDEV_BACKUPS/"*.tar.gz 2>/dev/null | awk '{print "    " NR") " $NF}'
    echo ""
    read -p "  Numero de backup: " bn
    local bf; bf=$(ls "$CRISDEV_BACKUPS/"*.tar.gz 2>/dev/null | sed -n "${bn}p")
    [[ -z "$bf" || ! -f "$bf" ]] && { ui_error "Backup no encontrado"; return 1; }
    if ui_confirm_destructive "Restaurar desde $(basename "$bf")? Se sobreescribira la config actual."; then
        tar -xzf "$bf" -C / 2>/dev/null; systemctl daemon-reload
        systemctl restart xray 2>/dev/null || true; systemctl restart hysteria-server 2>/dev/null || true
        log_audit "RESTORE" "$bf"; ui_ok "Backup restaurado"
    fi
}

# ========================= LINKS =========================

generate_user_links() {
    ui_breadcrumb "CRISDEV > Protocolos > Links"
    read -p "  Usuario: " username
    user_exists "$username" || { ui_error "Usuario no encontrado"; return 1; }
    local ud; ud=$(get_user "$username")
    local uid; uid=$(echo "$ud" | jq -r '.username')
    local upass; upass=$(echo "$ud" | jq -r '.password')
    local SIP; SIP=$(get_server_ip)
    local SDOM; SDOM=$(get_server_domain)
    local H="${SDOM:-$SIP}"

    # Leer paths y UUIDs del config guardado
    local WS_PATH; WS_PATH=$(jq -r '.xray_ws_path // "/'"$(openssl rand -hex 8)"'"' "$SERVER_CONFIG" 2>/dev/null)
    local GRPC_SVC; GRPC_SVC=$(jq -r '.xray_grpc_service // "grpc-'"$(openssl rand -hex 4)"'"' "$SERVER_CONFIG" 2>/dev/null)
    local UUID_VL; UUID_VL=$(jq -r '.uuid_vless // ""' "$SERVER_CONFIG" 2>/dev/null)
    local UUID_VM; UUID_VM=$(jq -r '.uuid_vmess // ""' "$SERVER_CONFIG" 2>/dev/null)
    local TROJAN_P; TROJAN_P=$(jq -r '.trojan_pass // ""' "$SERVER_CONFIG" 2>/dev/null)
    # Si no hay UUIDs guardados, usar el username como fallback
    [[ -z "$UUID_VL" ]] && UUID_VL="$uid"
    [[ -z "$UUID_VM" ]] && UUID_VM="$uid"
    [[ -z "$TROJAN_P" ]] && TROJAN_P="$upass"

    echo ""
    echo -e "  ${C_BOLD}${C_INFO}LINKS DE CONEXION${C_NORM}"
    echo -e "  ${C_DIM}Para: $username${C_NORM}"
    ui_separator

    local vws="vless://${UUID_VL}@${H}:${PORT_XRAY_WS}?encryption=none&security=tls&type=ws&path=${WS_PATH}&host=${H}#CRISDEV-VLESS-WS"
    echo -e "\n  ${C_BOLD}VLESS + WS + TLS:${C_NORM}"
    echo "    $vws"

    local vgc="vless://${UUID_VL}@${H}:${PORT_XRAY_GRPC}?encryption=none&security=tls&type=grpc&serviceName=${GRPC_SVC}&fp=chrome#CRISDEV-VLESS-gRPC"
    echo -e "\n  ${C_BOLD}VLESS + gRPC + TLS:${C_NORM}"
    echo "    $vgc"

    local vmj="{\"v\":\"2\",\"ps\":\"CRISDEV-VMess\",\"add\":\"${H}\",\"port\":\"${PORT_WEBSOCKET}\",\"id\":\"${UUID_VM}\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"${H}\",\"path\":\"/vmess-ws\",\"tls\":\"tls\"}"
    echo -e "\n  ${C_BOLD}VMess + WS + TLS:${C_NORM}"
    echo "    vmess://$(echo -n "$vmj" | base64 -w0 2>/dev/null || echo -n "$vmj" | base64)"

    local trj="trojan://${TROJAN_P}@${H}:${PORT_XRAY_VLESS}?type=ws&host=${H}&path=%2Ftrojan-ws&security=tls#CRISDEV-Trojan"
    echo -e "\n  ${C_BOLD}Trojan + WS + TLS:${C_NORM}"
    echo "    $trj"

    # Hysteria2 - leer passwords del config
    local HY_AUTH; HY_AUTH=$(jq -r '.hysteria_auth_pass // ""' "$SERVER_CONFIG" 2>/dev/null)
    local HY_OBFS; HY_OBFS=$(jq -r '.hysteria_obfs_pass // ""' "$SERVER_CONFIG" 2>/dev/null)
    if [[ -n "$HY_AUTH" ]]; then
        local hy2="hysteria2://${HY_AUTH}@${H}:${PORT_HYSTERIA}?obfs=salamander&obfs-password=${HY_OBFS}#CRISDEV-Hysteria2"
        echo -e "\n  ${C_BOLD}Hysteria2:${C_NORM}"
        echo "    $hy2"
    fi

    if command -v qrencode &>/dev/null; then
        echo -e "\n  ${C_BOLD}QR Code VLESS-WS:${C_NORM}"
        qrencode -t ANSIUTF8 "$vws" 2>/dev/null
    fi
}

# ========================= ACTUALIZACIONES =========================

update_xray_core() {
    ui_info "Actualizando Xray-core..."
    local lv; lv=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -r '.tag_name' 2>/dev/null)
    local arch; arch=$(uname -m); case "$arch" in x86_64) arch="64" ;; aarch64) arch="arm64-v8a" ;; armv7l) arch="arm32-v7a" ;; esac
    wget -q "https://github.com/XTLS/Xray-core/releases/download/${lv}/Xray-linux-${arch}.zip" -O /tmp/xray.zip
    unzip -o /tmp/xray.zip -d /opt/xray/ >/dev/null 2>&1; chmod +x /opt/xray/xray; rm -f /tmp/xray.zip
    systemctl restart xray 2>/dev/null || true
    ui_ok "Xray-core actualizado a $lv"
}

update_hysteria2() {
    ui_info "Actualizando Hysteria2..."
    bash <(curl -fsSL https://get.hy2.sh/) 2>/dev/null
    systemctl restart hysteria-server 2>/dev/null || true
    ui_ok "Hysteria2 actualizado"
}

check_versions() {
    ui_breadcrumb "CRISDEV > Sistema > Versiones"
    echo -e "\n  ${C_BOLD}Instaladas:${C_NORM}"
    echo -ne "    Xray: "; /opt/xray/xray version 2>/dev/null | head -1 || echo "No instalado"
    echo -ne "    Hysteria2: "; hysteria-server version 2>/dev/null | head -1 || echo "No instalado"
    echo -ne "    udp-custom: "; /opt/udp-custom/server --version 2>/dev/null || echo "No instalado"
    echo -e "\n  ${C_BOLD}Ultimas disponibles:${C_NORM}"
    echo "    Xray: $(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -r '.tag_name' 2>/dev/null)"
    echo "    Hysteria2: $(curl -s https://api.github.com/repos/apernet/hysteria/releases/latest | jq -r '.tag_name' 2>/dev/null)"
}

# ========================= VALIDACION DE PROTOCOLOS =========================

validate_all_protocols() {
    ui_breadcrumb "CRISDEV > Protocolos > Validar"
    echo -e "  ${C_BOLD}${C_INFO}VALIDACION DE PROTOCOLOS${C_NORM}"
    ui_separator
    local SIP; SIP=$(get_server_ip)
    local SDOM; SDOM=$(get_server_domain)
    local H="${SDOM:-$SIP}"
    local OK=0 FAIL=0

    # SSH
    echo -ne "  SSH ($PORT_SSH/tcp):           "
    if ss -tlnp 2>/dev/null | grep -q ":$PORT_SSH "; then
        echo -e "${C_OK}[OK]${C_NORM}"; ((OK++))
    else
        echo -e "${C_ERROR}[FAIL]${C_NORM}"; ((FAIL++))
    fi

    # SSH-SSL (Stunnel)
    echo -ne "  SSH-SSL ($PORT_SSH_SSL/tcp):     "
    if ss -tlnp 2>/dev/null | grep -q ":$PORT_SSH_SSL "; then
        # Verificar que connect apunta a SSH (no loop)
        if grep -q "connect = 127.0.0.1:$PORT_SSH" /etc/stunnel/stunnel.conf 2>/dev/null; then
            echo -e "${C_OK}[OK]${C_NORM}"; ((OK++))
        else
            echo -e "${C_ERROR}[BAD CONFIG]${C_NORM} - connect no apunta a SSH"; ((FAIL++))
        fi
    else
        echo -e "${C_ERROR}[OFF]${C_NORM}"; ((FAIL++))
    fi

    # Xray VLESS-WS
    echo -ne "  Xray VLESS-WS ($PORT_XRAY_WS/tcp):  "
    if ss -tlnp 2>/dev/null | grep -q ":$PORT_XRAY_WS "; then
        # Verificar que xray responde
        if curl -sk --connect-timeout 3 "https://$H:$PORT_XRAY_WS" >/dev/null 2>&1 || \
           ss -tlnp 2>/dev/null | grep -q "xray"; then
            echo -e "${C_OK}[OK]${C_NORM}"; ((OK++))
        else
            echo -e "${C_WARN}[RUNNING - UNTESTED]${C_NORM}"; ((OK++))
        fi
    else
        echo -e "${C_ERROR}[OFF]${C_NORM}"; ((FAIL++))
    fi

    # Hysteria2
    echo -ne "  Hysteria2 ($PORT_HYSTERIA/udp):     "
    if ss -ulnp 2>/dev/null | grep -q ":$PORT_HYSTERIA "; then
        echo -e "${C_OK}[OK]${C_NORM}"; ((OK++))
    else
        echo -e "${C_ERROR}[OFF]${C_NORM}"; ((FAIL++))
    fi

    # UDP-Custom
    echo -ne "  UDP-Custom ($PORT_UDP_CUSTOM/udp):  "
    if ss -ulnp 2>/dev/null | grep -q ":7100 "; then
        echo -e "${C_OK}[OK]${C_NORM}"; ((OK++))
    else
        echo -e "${C_ERROR}[OFF]${C_NORM}"; ((FAIL++))
    fi

    # Certificados
    echo -ne "  Certificados TLS:            "
    if [[ -f "$CERT_DIR/fullchain.pem" ]]; then
        local EXPIRY; EXPIRY=$(openssl x509 -in "$CERT_DIR/fullchain.pem" -noout -enddate 2>/dev/null | cut -d= -f2)
        echo -e "${C_OK}[OK]${C_NORM} Expira: $EXPIRY"; ((OK++))
    elif [[ -f "$CERT_DIR/self-signed.pem" ]]; then
        echo -e "${C_WARN}[SELF-SIGNED]${C_NORM}"; ((OK++))
    else
        echo -e "${C_ERROR}[NO CERT]${C_NORM}"; ((FAIL++))
    fi

    echo ""
    ui_separator
    echo -e "  Resultado: ${C_OK}$OK OK${C_NORM} | ${C_ERROR}$FAIL FAIL${C_NORM}"

    if [[ $FAIL -gt 0 ]]; then
        echo ""
        ui_info "Para arreglar los protocolos con FAIL:"
        echo "    1) Re-ejecuta: crisdev --install"
        echo "    2) O configura manualmente desde el menu"
    fi
}

show_connection_info() {
    ui_breadcrumb "CRISDEV > Protocolos > Info"
    echo -e "  ${C_BOLD}${C_INFO}INFORMACION DE CONEXION${C_NORM}"
    ui_separator
    local SIP; SIP=$(get_server_ip)
    local SDOM; SDOM=$(get_server_domain)
    local H="${SDOM:-$SIP}"

    echo -e "\n  ${C_BOLD}Servidor:${C_NORM} $H ($SIP)"
    echo -e "\n  ${C_BOLD}Protocolos Disponibles:${C_NORM}"

    # SSH
    echo -e "\n  ${C_BOLD}1. SSH (OpenSSH)${C_NORM}"
    echo -e "    Puerto: $PORT_SSH/tcp"
    echo -e "    Conexion: ${C_INFO}ssh root@$H -p $PORT_SSH${C_NORM}"

    # SSH-SSL
    echo -e "\n  ${C_BOLD}2. SSH-SSL (Stunnel)${C_NORM}"
    echo -e "    Puerto: $PORT_SSH_SSL/tcp (TLS)"
    echo -e "    Clientes: Stunnel, HTTPS Tunnel, SSLSocket"
    echo -e "    Conexion: Conectar Stunnel a $H:$PORT_SSH_SSL, luego SSH a 127.0.0.1:22"

    # Xray links
    echo -e "\n  ${C_BOLD}3. Xray/V2Ray${C_NORM}"
    if [[ -f "$SERVER_CONFIG" ]]; then
        local WS_PATH; WS_PATH=$(jq -r '.xray_ws_path // ""' "$SERVER_CONFIG" 2>/dev/null)
        local GRPC_SVC; GRPC_SVC=$(jq -r '.xray_grpc_service // ""' "$SERVER_CONFIG" 2>/dev/null)
        local UUID_VL; UUID_VL=$(jq -r '.uuid_vless // ""' "$SERVER_CONFIG" 2>/dev/null)
        if [[ -n "$UUID_VL" ]]; then
            echo -e "    UUID: ${C_BOLD}$UUID_VL${C_NORM}"
            echo -e "    VLESS-WS: vless://$UUID_VL@$H:$PORT_XRAY_WS?encryption=none&security=tls&type=ws&path=$WS_PATH&host=$H"
            echo -e "    VLESS-gRPC: vless://$UUID_VL@$H:$PORT_XRAY_GRPC?encryption=none&security=tls&type=grpc&serviceName=$GRPC_SVC"
        else
            echo -e "    ${C_WARN}No configurado - ejecuta 'Configurar Xray' primero${C_NORM}"
        fi
    else
        echo -e "    ${C_WARN}No configurado${C_NORM}"
    fi

    # Hysteria2
    echo -e "\n  ${C_BOLD}4. Hysteria2 (QUIC/UDP)${C_NORM}"
    if [[ -f "$SERVER_CONFIG" ]]; then
        local HY_AUTH; HY_AUTH=$(jq -r '.hysteria_auth_pass // ""' "$SERVER_CONFIG" 2>/dev/null)
        local HY_OBFS; HY_OBFS=$(jq -r '.hysteria_obfs_pass // ""' "$SERVER_CONFIG" 2>/dev/null)
        if [[ -n "$HY_AUTH" ]]; then
            echo -e "    Puerto: $PORT_HYSTERIA/udp"
            echo -e "    Auth: ${C_BOLD}$HY_AUTH${C_NORM}"
            echo -e "    Obfs: ${C_BOLD}$HY_OBFS${C_NORM}"
            echo -e "    Link: ${C_INFO}hysteria2://$HY_AUTH@$H:$PORT_HYSTERIA?obfs=salamander&obfs-password=$HY_OBFS#CRISDEV${C_NORM}"
        else
            echo -e "    ${C_WARN}No configurado - ejecuta 'Configurar Hysteria2' primero${C_NORM}"
        fi
    fi

    # UDP-Custom
    echo -e "\n  ${C_BOLD}5. UDP-Custom${C_NORM}"
    echo -e "    Puerto: 7100/udp"
    echo -e "    Clientes: HTTP Tunnel, UDPvpn, SlowDNS"

    echo ""
    ui_separator
}

# ========================= MENUS =========================

quick_xray_menu() {
    ui_breadcrumb "CRISDEV > Protocolos > Xray-core"
    echo -e "  ${C_BOLD}${C_INFO}XRAY-CORE${C_NORM}"
    ui_separator
    echo "    1) Config completa (todos los protocolos)"
    echo "    2) Solo VLESS + WS + TLS"
    echo "    3) Solo VLESS + gRPC + TLS"
    echo "    4) Solo VLESS + REALITY"
    echo "    5) Solo VMess + WS + TLS"
    echo "    6) Solo Trojan + WS + TLS"
    echo "    7) Modificar puertos"
    echo "    0) Volver"
    read -p "  Opcion: " xo
    case $xo in
        1) generate_xray_config ;;
        2|3|4|5|6)
            local uuid; uuid=$(generate_uuid)
            echo -e "\n  UUID: ${C_BOLD}$uuid${C_NORM} (guadalo para el usuario)" ;;
        7)
            echo -e "\n  ${C_BOLD}Puertos actuales:${C_NORM}"
            echo "    VLESS-WS: $PORT_XRAY_WS | gRPC: $PORT_XRAY_GRPC | REALITY: $PORT_XRAY_REALITY | Trojan: $PORT_XRAY_VLESS | VMess: $PORT_WEBSOCKET"
            read -p "  Nuevo VLESS-WS [Enter=no cambia]: " np; [[ -n "$np" ]] && PORT_XRAY_WS=$np
            read -p "  Nuevo gRPC [Enter=no cambia]: " np; [[ -n "$np" ]] && PORT_XRAY_GRPC=$np
            read -p "  Nuevo REALITY [Enter=no cambia]: " np; [[ -n "$np" ]] && PORT_XRAY_REALITY=$np
            generate_xray_config ;;
        *) return 0 ;;
    esac
}

panic_mode() {
    ui_breadcrumb "CRISDEV > Servidor > Modo Panico"
    if ui_confirm_destructive "ACTIVAR MODO PANICO? Se cerraran TODOS los puertos excepto SSH ($PORT_SSH)."; then
        ufw disable 2>/dev/null || true
        echo "y" | ufw reset 2>/dev/null || true
        ufw default deny incoming 2>/dev/null || true
        ufw default allow outgoing 2>/dev/null || true
        ufw allow "$PORT_SSH/tcp" comment "SSH-emergency" 2>/dev/null || true
        echo "y" | ufw enable 2>/dev/null || true
        log_audit "PANIC" "Modo panico activado"
        ui_warn "MODO PANICO ACTIVADO - Solo SSH ($PORT_SSH) abierto"
    fi
}

# --- SUB-MENUS ---

menu_ssh() {
    ui_breadcrumb "CRISDEV > Protocolos > SSH"
    echo -e "  ${C_BOLD}${C_INFO}SSH / SSH-SSL${C_NORM}"
    ui_separator
    echo "    1) Configurar SSH-SSL (stunnel)"
    echo "    2) Cambiar puerto SSH"
    echo "    3) Reiniciar SSH"
    echo "    4) Ver intentos fallidos (fail2ban)"
    echo "    5) Desbanear IP"
    echo "    0) Volver"
    read -p "  Opcion: " so
    case $so in
        1) configure_stunnel ;;
        2) read -p "  Nuevo puerto: " np; PORT_SSH="$np"; configure_ssh_base ;;
        3) systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null; ui_ok "SSH reiniciado" ;;
        4) fail2ban-client status sshd 2>/dev/null ;;
        5) read -p "  IP a desbanear: " ip; fail2ban-client set sshd unbanip "$ip" 2>/dev/null; ui_info "IP $ip desbaneada" ;;
        *) return 0 ;;
    esac
}

menu_firewall() {
    ui_breadcrumb "CRISDEV > Servidor > Firewall"
    echo -e "  ${C_BOLD}${C_INFO}FIREWALL / PUERTOS${C_NORM}"
    ui_separator
    echo "    1) Ver reglas actuales"
    echo "    2) Abrir puerto"
    echo "    3) Cerrar puerto"
    echo "    4) Restablecer firewall"
    echo "    5) Modo panico"
    echo "    0) Volver"
    read -p "  Opcion: " fo
    case $fo in
        1) ufw status verbose 2>/dev/null ;;
        2) read -p "  Puerto: " pp; read -p "  Proto (tcp/udp) [tcp]: " pr; pr="${pr:-tcp}"; open_port "$pp" "$pr" ;;
        3) read -p "  Puerto: " pp; read -p "  Proto (tcp/udp) [tcp]: " pr; pr="${pr:-tcp}"; close_port "$pp" "$pr" ;;
        4) configure_firewall_base ;;
        5) panic_mode ;;
        *) return 0 ;;
    esac
}

menu_certs() {
    ui_breadcrumb "CRISDEV > Servidor > Certificados"
    echo -e "  ${C_BOLD}${C_INFO}CERTIFICADOS TLS${C_NORM}"
    ui_separator
    echo "    1) Ver certificado actual"
    echo "    2) Emitir certificado (Let's Encrypt)"
    echo "    3) Generar certificado autofirmado"
    echo "    4) Renovar todos"
    echo "    0) Volver"
    read -p "  Opcion: " co
    case $co in
        1) [[ -f "$CERT_DIR/fullchain.pem" ]] && openssl x509 -in "$CERT_DIR/fullchain.pem" -noout -subject -dates 2>/dev/null || echo "  No hay certificado" ;;
        2) read -p "  Dominio: " cd; install_acme_sh; issue_certificate "$cd" ;;
        3) generate_self_signed_cert ;;
        4) renew_certificates ;;
        *) return 0 ;;
    esac
}

menu_service_logs() {
    ui_breadcrumb "CRISDEV > Sistema > Logs"
    echo -e "  ${C_BOLD}${C_INFO}LOGS DE SERVICIOS${C_NORM}"
    ui_separator
    echo "    1) Xray       3) SSH"
    echo "    2) Hysteria2  4) fail2ban"
    echo "    0) Volver"
    read -p "  Opcion: " lo
    case $lo in
        1) journalctl -u xray --no-pager -n 30 ;;
        2) journalctl -u hysteria-server --no-pager -n 30 ;;
        3) journalctl -u sshd --no-pager -n 30 ;;
        4) fail2ban-client status sshd 2>/dev/null ;;
        *) return 0 ;;
    esac
}

update_crisdev() {
    ui_info "Actualizando CRISDEV..."
    local url="https://raw.githubusercontent.com/soportecrisdev/SCRIP_CRISDEV/main/crisdev.sh"
    curl -fsSL "$url" -o /tmp/crisdev_new.sh 2>/dev/null
    if [[ -f /tmp/crisdev_new.sh ]]; then
        local nv; nv=$(grep "CRISDEV_VERSION=" /tmp/crisdev_new.sh | head -1 | cut -d'"' -f2)
        if [[ "$nv" != "$CRISDEV_VERSION" ]]; then
            cp /usr/local/bin/crisdev /usr/local/bin/crisdev.bak 2>/dev/null || true
            cp /tmp/crisdev_new.sh /usr/local/bin/crisdev; chmod +x /usr/local/bin/crisdev
            ui_ok "CRISDEV actualizado a v$nv"
        else
            ui_info "Ya en la ultima version ($CRISDEV_VERSION)"
        fi
    else
        ui_error "No se pudo descargar la actualizacion"
    fi
}

# ========================= MENU PRINCIPAL =========================

menu_main() {
    while true; do
        ui_clear
        ui_header
        ui_dashboard

        # --- USUARIOS ---
        ui_section "USUARIOS"
        echo "    ${C_BOLD}1)${C_NORM} Crear usuario          ${C_BOLD}6)${C_NORM} Renovar usuario"
        echo "    ${C_BOLD}2)${C_NORM} Editar usuario         ${C_BOLD}7)${C_NORM} Listar usuarios"
        echo "    ${C_BOLD}3)${C_NORM} ${C_ERR}Eliminar usuario${C_NORM}      ${C_BOLD}8)${C_NORM} Ver detalle"
        echo "    ${C_BOLD}4)${C_NORM} Suspender usuario      ${C_BOLD}9)${C_NORM} Buscar usuario"
        echo "    ${C_BOLD}5)${C_NORM} Reactivar usuario"
        echo ""

        # --- PROTOCOLOS ---
        ui_section "PROTOCOLOS"
        echo "    ${C_BOLD}10)${C_NORM} SSH / SSH-SSL          ${C_BOLD}13)${C_NORM} Hysteria2"
        echo "    ${C_BOLD}11)${C_NORM} SlowDNS                ${C_BOLD}14)${C_NORM} udp-custom"
        echo "    ${C_BOLD}12)${C_NORM} Xray (VLESS/VMess/Trojan)  ${C_BOLD}25)${C_NORM} Validar protocolos"
        echo ""

        # --- SERVIDOR ---
        ui_section "SERVIDOR"
        echo "    ${C_BOLD}15)${C_NORM} Generar links          ${C_BOLD}18)${C_NORM} Certificados TLS"
        echo "    ${C_BOLD}16)${C_NORM} Estado del servidor    ${C_BOLD}19)${C_NORM} Backups"
        echo "    ${C_BOLD}17)${C_NORM} Firewall / puertos     ${C_BOLD}26)${C_NORM} Info de conexion"
        echo ""

        # --- SISTEMA ---
        ui_section "SISTEMA"
        echo "    ${C_BOLD}20)${C_NORM} Verificar versiones    ${C_BOLD}23)${C_NORM} Logs de auditoria"
        echo "    ${C_BOLD}21)${C_NORM} Logs de servicios     ${C_BOLD}24)${C_NORM} Actualizar CRISDEV"
        echo ""

        # --- SALIDA ---
        ui_separator
        echo "    ${C_ERR}[0] Salir del script${C_NORM}              ${C_WARN}[9] Reiniciar VPS${C_NORM}"
        echo ""

        ui_prompt
        read choice
        echo ""

        case $choice in
            1)  create_user ;;
            2)  edit_user ;;
            3)  delete_user ;;
            4)  suspend_user ;;
            5)  reactivate_user ;;
            6)  renew_user ;;
            7)  list_users ;;
            8)  user_detail ;;
            9)
                if ui_confirm_destructive "Reiniciar el VPS? Se cerraran todas las conexiones."; then
                    reboot
                fi ;;
            10) menu_ssh ;;
            11) install_slowdns ;;
            12) quick_xray_menu ;;
            13) configure_hysteria2 ;;
            14) configure_udp_custom ;;
            15) generate_user_links ;;
            16) show_server_status ;;
            17) menu_firewall ;;
            18) menu_certs ;;
            19) create_backup ;;
            20) check_versions ;;
            21) menu_service_logs ;;
            23) tail -50 "$AUDIT_LOG" ;;
            24) update_crisdev ;;
            25) validate_all_protocols ;;
            26) show_connection_info ;;
            0)  echo -e "  ${C_OK}Hasta luego, CRISDEV.${C_NORM}"; exit 0 ;;
            *)  ui_error "Opcion invalida" ;;
        esac
        ui_pause
    done
}

# ========================= ENTRY POINT =========================

main() {
    check_root
    init_directories
    check_dependencies

    case "${1:-}" in
        --install|-i) install_complete ;;
        --status|-s)  ui_clear; ui_header; show_server_status ;;
        --backup|-b)  create_backup ;;
        --users|-u)   ui_clear; ui_header; list_users ;;
        --help|-h)
            echo "CRISDEV VPN Manager v$CRISDEV_VERSION"
            echo ""
            echo "  crisdev              Menu interactivo"
            echo "  crisdev --install    Instalacion completa"
            echo "  crisdev --status     Estado del servidor"
            echo "  crisdev --backup     Crear backup"
            echo "  crisdev --users      Listar usuarios"
            echo "  crisdev --help       Mostrar ayuda"
            ;;
        *) menu_main ;;
    esac
}

main "$@"
