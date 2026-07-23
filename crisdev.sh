#!/bin/bash
# ============================================================================
# CRISDEV VPN Manager v1.0
# Script privado de administración VPN para VPS
# Autor: CRISDEV / @CRISIS1823
# ============================================================================
set -uo pipefail

# ========================= VARIABLES GLOBALES =========================
CRISDEV_VERSION="1.0.0"
CRISDEV_HOME="/etc/crisdev"
CRISDEV_DATA="$CRISDEV_HOME/data"
CRISDEV_LOGS="$CRISDEV_HOME/logs"
CRISDEV_BACKUPS="$CRISDEV_HOME/backups"
USERS_DB="$CRISDEV_DATA/users.json"
SERVER_CONFIG="$CRISDEV_DATA/server_config.json"
AUDIT_LOG="$CRISDEV_LOGS/audit.log"
STATE_FILE="$CRISDEV_DATA/state.json"
CERT_DIR="/etc/crisdev/certs"

# Puertos por defecto
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

# Colores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

# ========================= FUNCIONES BASE =========================

banner() {
    clear
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                                                              ║"
    echo "║   ██████╗██████╗ ██╗██████╗ ████████╗███████╗██████╗ ███╗   ║"
    echo "║  ██╔════╝██╔══██╗██║██╔══██╗╚══██╔══╝██╔════╝██╔══██╗████╗  ║"
    echo "║  ██║     ██████╔╝██║██████╔╝   ██║   █████╗  ██████╔╝██╔██╗ ║"
    echo "║  ██║     ██╔══██╗██║██╔═══╝    ██║   ██╔══╝  ██╔══██╗██║╚██╗║"
    echo "║  ╚██████╗██║  ██║██║██║        ██║   ███████╗██║  ██║██║ ╚████║"
    echo "║   ╚═════╝╚═╝  ╚═╝╚═╝╚═╝        ╚═╝   ╚══════╝╚═╝  ╚═╝╚═╝  ╚═══╝"
    echo "║                  VPN Manager v${CRISDEV_VERSION}                    ║"
    echo "║                  @CRISIS1823                                  ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

log_audit() {
    local action="$1"
    local detail="$2"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $action: $detail" >> "$AUDIT_LOG"
}

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

confirm_action() {
    local msg="${1:-¿Estás seguro?}"
    echo -e "${YELLOW}⚠  $msg${NC}"
    read -p "Responda (s/n): " resp
    [[ "$resp" =~ ^[sS]$ ]]
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Este script debe ejecutarse como root"
        exit 1
    fi
}

check_dependencies() {
    local deps=("curl" "wget" "jq" "openssl" "systemctl" "ufw" "fail2ban-client")
    local missing=()
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            missing+=("$dep")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_warn "Dependencias faltantes: ${missing[*]}"
        log_info "Instalando dependencias..."
        apt-get update -qq
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

get_server_domain() {
    jq -r '.domain // empty' "$SERVER_CONFIG" 2>/dev/null
}

generate_uuid() {
    cat /proc/sys/kernel/random/uuid 2>/dev/null || python3 -c "import uuid; print(uuid.uuid4())" 2>/dev/null || openssl rand -hex 16
}

generate_password() {
    openssl rand -base64 12 | tr -d '/+=' | head -c 16
}

generate_random_port() {
    shuf -i 10000-65000 -n 1
}

json_get() {
    local file="$1" key="$2"
    jq -r "$key" "$file" 2>/dev/null
}

json_set() {
    local file="$1" key="$2" value="$3"
    local tmp
    tmp=$(mktemp)
    jq "$key = $value" "$file" > "$tmp" && mv "$tmp" "$file"
}

json_add_user() {
    local user_json="$1"
    local tmp
    tmp=$(mktemp)
    jq ". + [$user_json]" "$USERS_DB" > "$tmp" && mv "$tmp" "$USERS_DB"
}

json_remove_user() {
    local username="$1"
    local tmp
    tmp=$(mktemp)
    jq "map(select(.username != \"$username\"))" "$USERS_DB" > "$tmp" && mv "$tmp" "$USERS_DB"
}

json_update_user() {
    local username="$1" updates="$2"
    local tmp
    tmp=$(mktemp)
    jq "map(if .username == \"$username\" then . + ($updates) else . end)" "$USERS_DB" > "$tmp" && mv "$tmp" "$USERS_DB"
}

user_exists() {
    local username="$1"
    jq -e "map(select(.username == \"$username\")) | length > 0" "$USERS_DB" >/dev/null 2>&1
}

get_user() {
    local username="$1"
    jq ".[] | select(.username == \"$username\")" "$USERS_DB" 2>/dev/null
}

is_user_expired() {
    local username="$1"
    local exp_date
    exp_date=$(jq -r ".[] | select(.username == \"$username\") | .expires_at // empty" "$USERS_DB" 2>/dev/null)
    [[ -z "$exp_date" ]] && return 1
    local now
    now=$(date +%s)
    local exp
    exp=$(date -d "$exp_date" +%s 2>/dev/null || echo 0)
    [[ $now -gt $exp ]]
}

is_user_suspended() {
    local username="$1"
    local status
    status=$(jq -r ".[] | select(.username == \"$username\") | .status // \"active\"" "$USERS_DB" 2>/dev/null)
    [[ "$status" == "suspended" ]]
}

# ========================= INSTALADOR COMPLETO =========================

install_complete() {
    banner
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  INSTALACIÓN COMPLETA CRISDEV VPN MANAGER${NC}"
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════${NC}"
    echo ""

    local SERVER_IP
    SERVER_IP=$(get_server_ip)

    # Paso 1: Datos del servidor
    echo -e "${BOLD}Paso 1/10: Configuración del servidor${NC}"
    read -p "IP del servidor [$SERVER_IP]: " INPUT_IP
    SERVER_IP="${INPUT_IP:-$SERVER_IP}"

    read -p "Dominio del servidor (deja vacío si no tienes): " SERVER_DOMAIN
    read -p "Email para certificados TLS (deja vacío si no tienes): " EMAIL_TLS

    # Guardar config inicial
    jq -n \
        --arg ip "$SERVER_IP" \
        --arg domain "$SERVER_DOMAIN" \
        --arg email "$EMAIL_TLS" \
        '{server_ip: $ip, domain: $domain, email_tls: $email, installed_at: now | todate}' \
        > "$SERVER_CONFIG"

    log_info "IP: $SERVER_IP"
    [[ -n "$SERVER_DOMAIN" ]] && log_info "Dominio: $SERVER_DOMAIN"

    # Paso 2: Actualizar sistema
    echo ""
    echo -e "${BOLD}Paso 2/10: Actualizando sistema...${NC}"
    apt-get update -qq 2>/dev/null || true
    apt-get upgrade -y -qq 2>/dev/null || true
    log_success "Sistema actualizado"

    # Paso 3: Instalar dependencias
    echo ""
    echo -e "${BOLD}Paso 3/10: Instalando dependencias...${NC}"
    apt-get install -y -qq \
        curl wget jq openssl git unzip \
        stunnel4 dropbear \
        socat netcat-openbsd \
        bc coreutils \
        python3 python3-pip \
        libssl-dev \
        screen tmux \
        nano vim \
        2>/dev/null || true
    log_success "Dependencias instaladas"

    # Paso 4: Configurar firewall
    echo ""
    echo -e "${BOLD}Paso 4/10: Configurando firewall...${NC}"
    configure_firewall_base

    # Paso 5: Instalar fail2ban
    echo ""
    echo -e "${BOLD}Paso 5/10: Configurando fail2ban...${NC}"
    apt-get install -y -qq fail2ban 2>/dev/null || true
    configure_fail2ban

    # Paso 6: Configurar SSH
    echo ""
    echo -e "${BOLD}Paso 6/10: Configurando SSH...${NC}"
    configure_ssh_base

    # Paso 7: Instalar Xray-core
    echo ""
    echo -e "${BOLD}Paso 7/10: Instalando Xray-core...${NC}"
    install_xray_core || log_error "Error instalando Xray-core (puedes instalarlo después)"

    # Paso 8: Instalar Hysteria2
    echo ""
    echo -e "${BOLD}Paso 8/10: Instalando Hysteria2...${NC}"
    install_hysteria2 || log_error "Error instalando Hysteria2 (puedes instalarlo después)"

    # Paso 9: Instalar udp-custom
    echo ""
    echo -e "${BOLD}Paso 9/10: Instalando udp-custom...${NC}"
    install_udp_custom || log_error "Error instalando udp-custom (puedes instalarlo después)"

    # Paso 10: Configurar certificados TLS
    echo ""
    echo -e "${BOLD}Paso 10/10: Configurando certificados TLS...${NC}"
    if [[ -n "$SERVER_DOMAIN" ]]; then
        install_acme_sh || true
        issue_certificate "$SERVER_DOMAIN" || log_error "Error emitiendo certificado (puedes hacerlo después)"
    else
        log_warn "Sin dominio — se usarán certificados autofirmados"
        generate_self_signed_cert
    fi

    # Paso Final: Instalar comando crisdev
    echo ""
    echo -e "${BOLD}Configurando comando 'crisdev'...${NC}"
    install_crisdev_command

    # Resumen
    echo ""
    echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${GREEN}  INSTALACIÓN COMPLETADA EXITOSAMENTE${NC}"
    echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  IP del servidor: ${BOLD}$SERVER_IP${NC}"
    [[ -n "$SERVER_DOMAIN" ]] && echo -e "  Dominio: ${BOLD}$SERVER_DOMAIN${NC}"
    echo -e "  SSH puerto: ${BOLD}$PORT_SSH${NC}"
    echo -e "  SSH-SSL puerto: ${BOLD}$PORT_SSH_SSL${NC}"
    echo -e "  Xray VLESS-WS: ${BOLD}$PORT_XRAY_WS${NC}"
    echo -e "  Xray gRPC: ${BOLD}$PORT_XRAY_GRPC${NC}"
    echo -e "  Xray REALITY: ${BOLD}$PORT_XRAY_REALITY${NC}"
    echo -e "  Hysteria2: ${BOLD}$PORT_HYSTERIA${NC}"
    echo -e "  udp-custom: ${BOLD}$PORT_UDP_CUSTOM${NC}"
    echo ""
    echo -e "  Ejecuta ${BOLD}crisdev${NC} para administrar"
    echo ""
    log_audit "INSTALL" "Instalación completa en $SERVER_IP"
}

install_crisdev_command() {
    local script_path
    script_path=$(realpath "$0")
    ln -sf "$script_path" /usr/local/bin/crisdev
    chmod +x /usr/local/bin/crisdev
    log_success "Comando 'crisdev' instalado"
}

# ========================= MÓDULO FIREWALL =========================

configure_firewall_base() {
    # Instalar ufw si no está
    if ! command -v ufw &>/dev/null; then
        apt-get install -y -qq ufw 2>/dev/null
    fi

    # Detener ufw si está corriendo para resetear limpiamente
    ufw disable 2>/dev/null || true
    sleep 1

    # Resetear reglas
    echo "y" | ufw reset 2>/dev/null || true
    sleep 1

    # Configurar política por defecto
    ufw default deny incoming 2>/dev/null || true
    ufw default allow outgoing 2>/dev/null || true

    # SSH - CRÍTICO: siempre abierto para no perder acceso
    ufw allow "$PORT_SSH/tcp" comment "SSH" 2>/dev/null || true
    ufw allow "$PORT_SSH_ALT/tcp" comment "SSH-ALT" 2>/dev/null || true

    # Puertos de servicios
    ufw allow "$PORT_SSH_SSL/tcp" comment "SSH-SSL" 2>/dev/null || true
    ufw allow "$PORT_XRAY_WS/tcp" comment "Xray-WS" 2>/dev/null || true
    ufw allow "$PORT_XRAY_GRPC/tcp" comment "Xray-gRPC" 2>/dev/null || true
    ufw allow "$PORT_XRAY_REALITY/tcp" comment "Xray-REALITY" 2>/dev/null || true
    ufw allow "$PORT_XRAY_VLESS/tcp" comment "Xray-VLESS" 2>/dev/null || true
    ufw allow "$PORT_HYSTERIA/udp" comment "Hysteria2" 2>/dev/null || true
    ufw allow "$PORT_WEBSOCKET/tcp" comment "WebSocket" 2>/dev/null || true
    ufw allow "$PORT_UDP_CUSTOM/udp" comment "udp-custom" 2>/dev/null || true

    # Habilitar UFW sin prompt
    echo "y" | ufw enable 2>/dev/null || true

    log_success "Firewall configurado"
    ufw status numbered 2>/dev/null || true
}

open_port() {
    local port="$1" protocol="${2:-tcp}" comment="${3:-}"
    ufw allow "$port/$protocol" comment "$comment" >/dev/null 2>&1
    log_info "Puerto $port/$protocol abierto ($comment)"
}

close_port() {
    local port="$1" protocol="${2:-tcp}"
    ufw delete allow "$port/$protocol" >/dev/null 2>&1
    log_info "Puerto $port/$protocol cerrado"
}

panic_mode() {
    if confirm_action "¿Activar modo pánico? Se cerrarán todos los puertos excepto SSH."; then
        ufw --force reset >/dev/null 2>&1
        ufw default deny incoming >/dev/null 2>&1
        ufw default allow outgoing >/dev/null 2>&1
        ufw allow "$PORT_SSH/tcp" comment "SSH-emergency" >/dev/null 2>&1
        ufw --force enable >/dev/null 2>&1
        log_audit "PANIC" "Modo pánico activado - todos los puertos cerrados excepto SSH"
        log_warn "MODO PÁNICO ACTIVADO - Solo SSH ($PORT_SSH) está abierto"
    fi
}

# ========================= MÓDULO FAIL2BAN =========================

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
    log_success "fail2ban configurado"
}

# ========================= MÓDULO SSH =========================

configure_ssh_base() {
    # Backup de config original
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak 2>/dev/null || true

    cat > /etc/ssh/sshd_config.d/crisdev.conf <<SSHEOF
# CRISDEV SSH Configuration
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

    # Banner personalizado
    cat > /etc/issue.net <<'BANNER'
╔══════════════════════════════════════════╗
║     CRISDEV VPN Server - Acceso SSH     ║
║     Conexiones monitoreadas             ║
╚══════════════════════════════════════════╝
BANNER

    systemctl restart sshd >/dev/null 2>&1 || systemctl restart ssh >/dev/null 2>&1
    log_success "SSH configurado (puertos $PORT_SSH, $PORT_SSH_ALT)"
}

create_ssh_user() {
    local username="$1" password="$2"

    if id "$username" &>/dev/null; then
        log_error "Usuario $username ya existe en el sistema"
        return 1
    fi

    useradd -m -s /bin/false "$username" 2>/dev/null
    echo "$username:$password" | chpasswd 2>/dev/null

    # Shell restringido
    chsh -s /bin/false "$username" 2>/dev/null || true

    log_success "Usuario SSH $username creado"
}

delete_ssh_user() {
    local username="$1"
    userdel -r "$username" 2>/dev/null || userdel "$username" 2>/dev/null || true
    log_info "Usuario SSH $username eliminado"
}

# ========================= MÓDULO SSH-SSL (STUNNEL) =========================

configure_stunnel() {
    local port="${1:-$PORT_SSH_SSL}"

    apt-get install -y -qq stunnel4 2>/dev/null

    cat > /etc/stunnel/stunnel.conf <<STEOF
pid = /var/run/stunnel4/stunnel.pid
setuid = stunnel4
setgid = stunnel4
debug = 4
foreground = no

[ssh-tunnel]
accept = 0.0.0.0:$port
connect = 127.0.0.1:$PORT_SSH_SSL
cert = $CERT_DIR/stunnel.pem
STEOF

    # Generar certificado para stunnel si no existe
    if [[ ! -f "$CERT_DIR/stunnel.pem" ]]; then
        openssl req -new -x509 -days 3650 -nodes \
            -out "$CERT_DIR/stunnel.pem" \
            -keyout "$CERT_DIR/stunnel.key" \
            -subj "/CN=crisdev-stunnel" 2>/dev/null
        cat "$CERT_DIR/stunnel.pem" "$CERT_DIR/stunnel.key" > "$CERT_DIR/stunnel.pem"
        rm -f "$CERT_DIR/stunnel.key"
    fi

    mkdir -p /var/run/stunnel4
    systemctl enable stunnel4 >/dev/null 2>&1
    systemctl restart stunnel4 >/dev/null 2>&1
    open_port "$port" "tcp" "SSH-SSL"
    log_success "SSH-SSL configurado en puerto $port"
}

# ========================= MÓDULO SLOWDNS =========================

install_slowdns() {
    echo -e "${BOLD}${CYAN}══════ INSTALACIÓN SLOWDNS ══════${NC}"
    echo ""

    read -p "Dominio NS delegado (ej: dns.tudominio.com): " SLOWDNS_DOMAIN
    read -p "Puerto DNS [53]: " SLOWDNS_PORT
    SLOWDNS_PORT="${SLOWDNS_PORT:-53}"

    # Descargar SlowDNS
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)  arch="amd64" ;;
        aarch64) arch="arm64" ;;
        armv7l)  arch="armv7" ;;
    esac

    mkdir -p /opt/slowdns
    cd /opt/slowdns

    if [[ ! -f server ]]; then
        wget -q "https://github.com/earthxam/slowdns/releases/latest/download/server-linux-${arch}" -O server 2>/dev/null
        chmod +x server
    fi

    # Generar par de llaves
    if [[ ! -f server.key ]]; then
        ./server -gen-key -privkey-file server.key -pubkey-file server.pub
    fi

    # Crear servicio systemd
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

    systemctl daemon-reload
    systemctl enable slowdns >/dev/null 2>&1
    systemctl start slowdns 2>/dev/null || true

    open_port "$SLOWDNS_PORT" "udp" "SlowDNS"
    open_port "$SLOWDNS_PORT" "tcp" "SlowDNS"

    log_success "SlowDNS instalado en puerto $SLOWDNS_PORT"
    echo -e "  Dominio NS: ${BOLD}$SLOWDNS_DOMAIN${NC}"
    echo -e "  Llave pública: ${BOLD}$(cat /opt/slowdns/server.pub)${NC}"
    echo -e "  Llave privada: ${BOLD}/opt/slowdns/server.key${NC}"

    log_audit "SLOWDNS" "Instalado en puerto $SLOWDNS_PORT, dominio $SLOWDNS_DOMAIN"
    cd - >/dev/null
}

# ========================= MÓDULO XRAY-CORE =========================

install_xray_core() {
    echo -e "${BOLD}${CYAN}══════ INSTALACIÓN XRAY-CORE ══════${NC}"

    # Obtener última versión
    local latest_version
    latest_version=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -r '.tag_name' 2>/dev/null || echo "v1.8.4")

    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)  arch="64" ;;
        aarch64) arch="arm64-v8a" ;;
        armv7l)  arch="arm32-v7a" ;;
    esac

    mkdir -p /opt/xray

    if [[ ! -f /opt/xray/xray ]]; then
        log_info "Descargando Xray-core $latest_version..."
        local url="https://github.com/XTLS/Xray-core/releases/download/${latest_version}/Xray-linux-${arch}.zip"
        wget -q "$url" -O /tmp/xray.zip 2>/dev/null
        unzip -o /tmp/xray.zip -d /opt/xray/ >/dev/null 2>&1
        chmod +x /opt/xray/xray
        rm -f /tmp/xray.zip
        log_success "Xray-core $latest_version instalado"
    fi

    # Crear directorio de configuración
    mkdir -p /usr/local/etc/xray

    # Servicio systemd
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

    systemctl daemon-reload
    systemctl enable xray >/dev/null 2>&1

    log_success "Xray-core instalado en /opt/xray/"
}

generate_xray_config() {
    local SERVER_IP
    SERVER_IP=$(get_server_ip)
    local SERVER_DOMAIN
    SERVER_DOMAIN=$(get_server_domain)

    local UUID_VLESS
    UUID_VLESS=$(generate_uuid)
    local UUID_VMESS
    UUID_VMESS=$(generate_uuid)

    local WS_PATH="/$(openssl rand -hex 8)"
    local GRPC_SERVICE="grpc-$(openssl rand -hex 4)"
    local REALITY_SNI="www.microsoft.com"

    local CERT_PATH="$CERT_DIR/fullchain.pem"
    local KEY_PATH="$CERT_DIR/privkey.pem"

    # Si no hay dominio real, usar certificado autofirmado
    if [[ ! -f "$CERT_PATH" ]]; then
        CERT_PATH="$CERT_DIR/self-signed.pem"
        KEY_PATH="$CERT_DIR/self-signed-key.pem"
    fi

    cat > /usr/local/etc/xray/config.json <<XRAYEOF
{
    "log": {
        "loglevel": "warning",
        "access": "/var/log/xray/access.log",
        "error": "/var/log/xray/error.log"
    },
    "inbounds": [
        {
            "tag": "vless-ws",
            "listen": "0.0.0.0",
            "port": $PORT_XRAY_WS,
            "protocol": "vless",
            "settings": {
                "clients": [
                    {
                        "id": "$UUID_VLESS",
                        "flow": ""
                    }
                ],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "ws",
                "security": "tls",
                "tlsSettings": {
                    "certificates": [
                        {
                            "certificateFile": "$CERT_PATH",
                            "keyFile": "$KEY_PATH"
                        }
                    ],
                    "minVersion": "1.2",
                    "alpn": ["h2", "http/1.1"]
                },
                "wsSettings": {
                    "path": "$WS_PATH",
                    "headers": {
                        "Host": "${SERVER_DOMAIN:-$SERVER_IP}"
                    }
                }
            },
            "sniffing": {
                "enabled": true,
                "destOverride": ["http", "tls"]
            }
        },
        {
            "tag": "vless-grpc",
            "listen": "0.0.0.0",
            "port": $PORT_XRAY_GRPC,
            "protocol": "vless",
            "settings": {
                "clients": [
                    {
                        "id": "$UUID_VLESS",
                        "flow": ""
                    }
                ],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "grpc",
                "security": "tls",
                "tlsSettings": {
                    "certificates": [
                        {
                            "certificateFile": "$CERT_PATH",
                            "keyFile": "$KEY_PATH"
                        }
                    ],
                    "minVersion": "1.2",
                    "alpn": ["h2"]
                },
                "grpcSettings": {
                    "serviceName": "$GRPC_SERVICE"
                }
            },
            "sniffing": {
                "enabled": true,
                "destOverride": ["http", "tls"]
            }
        },
        {
            "tag": "vmess-ws",
            "listen": "0.0.0.0",
            "port": $PORT_WEBSOCKET,
            "protocol": "vmess",
            "settings": {
                "clients": [
                    {
                        "id": "$UUID_VMESS",
                        "alterId": 0
                    }
                ]
            },
            "streamSettings": {
                "network": "ws",
                "security": "tls",
                "tlsSettings": {
                    "certificates": [
                        {
                            "certificateFile": "$CERT_PATH",
                            "keyFile": "$KEY_PATH"
                        }
                    ],
                    "minVersion": "1.2",
                    "alpn": ["h2", "http/1.1"]
                },
                "wsSettings": {
                    "path": "/vmess-ws",
                    "headers": {
                        "Host": "${SERVER_DOMAIN:-$SERVER_IP}"
                    }
                }
            },
            "sniffing": {
                "enabled": true,
                "destOverride": ["http", "tls"]
            }
        },
        {
            "tag": "vless-reality",
            "listen": "0.0.0.0",
            "port": $PORT_XRAY_REALITY,
            "protocol": "vless",
            "settings": {
                "clients": [
                    {
                        "id": "$UUID_VLESS",
                        "flow": "xtls-rprx-vision"
                    }
                ],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "show": false,
                    "dest": "www.microsoft.com:443",
                    "xver": 0,
                    "serverNames": [
                        "www.microsoft.com",
                        "www.apple.com",
                        "www.samsung.com"
                    ],
                    "privateKey": "",
                    "shortIds": [
                        "",
                        "6ba85179e30d4fc2"
                    ]
                }
            },
            "sniffing": {
                "enabled": true,
                "destOverride": ["http", "tls"]
            }
        },
        {
            "tag": "trojan-ws",
            "listen": "0.0.0.0",
            "port": $PORT_XRAY_VLESS,
            "protocol": "trojan",
            "settings": {
                "clients": [
                    {
                        "password": "$(generate_password)"
                    }
                ]
            },
            "streamSettings": {
                "network": "ws",
                "security": "tls",
                "tlsSettings": {
                    "certificates": [
                        {
                            "certificateFile": "$CERT_PATH",
                            "keyFile": "$KEY_PATH"
                        }
                    ],
                    "minVersion": "1.2",
                    "alpn": ["h2", "http/1.1"]
                },
                "wsSettings": {
                    "path": "/trojan-ws"
                }
            },
            "sniffing": {
                "enabled": true,
                "destOverride": ["http", "tls"]
            }
        }
    ],
    "routing": {
        "domainStrategy": "AsIs",
        "rules": [
            {
                "type": "field",
                "inboundTag": ["api"],
                "outboundTag": "api"
            },
            {
                "type": "field",
                "outboundTag": "blocked",
                "ip": ["geoip:private"]
            }
        ]
    },
    "outbounds": [
        {
            "protocol": "freedom",
            "tag": "direct"
        },
        {
            "protocol": "blackhole",
            "tag": "blocked"
        }
    ]
}
XRAYEOF

    # Crear directorios de log
    mkdir -p /var/log/xray
    touch /var/log/xray/access.log /var/log/xray/error.log

    # Generar keys para REALITY
    generate_reality_keys

    log_success "Configuración Xray generada"
    log_audit "XRAY" "Configuración generada con VLESS-WS, VLESS-gRPC, VMess-WS, VLESS-REALITY, Trojan-WS"
}

generate_reality_keys() {
    local REALITY_KEYS
    REALITY_KEYS=$(/opt/xray/xray x25519 2>/dev/null || echo "")
    if [[ -n "$REALITY_KEYS" ]]; then
        local PRIVATE_KEY PUBLIC_KEY
        PRIVATE_KEY=$(echo "$REALITY_KEYS" | grep "Private" | awk '{print $3}')
        PUBLIC_KEY=$(echo "$REALITY_KEYS" | grep "Public" | awk '{print $3}')

        # Actualizar config con las llaves
        local tmp
        tmp=$(mktemp)
        jq --arg pk "$PRIVATE_KEY" \
           '.inbounds[] | select(.tag == "vless-reality") | .streamSettings.realitySettings.privateKey = $pk' \
           /usr/local/etc/xray/config.json > "$tmp" 2>/dev/null && mv "$tmp" /usr/local/etc/xray/config.json

        echo -e "  REALITY Private Key: ${BOLD}$PRIVATE_KEY${NC}"
        echo -e "  REALITY Public Key: ${BOLD}$PUBLIC_KEY${NC}"
        log_info "REALITY keys generados"
    fi
}

start_xray() {
    systemctl start xray 2>/dev/null
    systemctl restart xray 2>/dev/null
    if systemctl is-active --quiet xray; then
        log_success "Xray-core iniciado"
    else
        log_error "Error al iniciar Xray-core"
        journalctl -u xray --no-pager -n 10
    fi
}

stop_xray() {
    systemctl stop xray 2>/dev/null
    log_info "Xray-core detenido"
}

# ========================= MÓDULO HYSTERIA2 =========================

install_hysteria2() {
    echo -e "${BOLD}${CYAN}══════ INSTALACIÓN HYSTERIA2 ══════${NC}"

    bash <(curl -fsSL https://get.hy2.sh/) 2>/dev/null

    mkdir -p /etc/hysteria
    log_success "Hysteria2 instalado"
}

configure_hysteria2() {
    local port="${1:-$PORT_HYSTERIA}"
    local SERVER_DOMAIN
    SERVER_DOMAIN=$(get_server_domain)

    read -p "Obfs password [auto-generate]: " OBFS_PASS
    OBFS_PASS="${OBFS_PASS:-$(generate_password)}"

    local CERT_PATH="$CERT_DIR/fullchain.pem"
    local KEY_PATH="$CERT_DIR/privkey.pem"

    if [[ ! -f "$CERT_PATH" ]]; then
        CERT_PATH="$CERT_DIR/self-signed.pem"
        KEY_PATH="$CERT_DIR/self-signed-key.pem"
    fi

    cat > /etc/hysteria/config.yaml <<HYEOF
listen: :$port

tls:
  cert: $CERT_PATH
  key: $KEY_PATH

auth:
  type: password
  password: "$(generate_password)"

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

    systemctl enable hysteria-server >/dev/null 2>&1
    systemctl restart hysteria-server 2>/dev/null || true

    open_port "$port" "udp" "Hysteria2"

    log_success "Hysteria2 configurado en puerto $port"
    log_audit "HYSTERIA2" "Configurado en puerto $port, obfs: salamander"
}

# ========================= MÓDULO UDP-CUSTOM =========================

install_udp_custom() {
    echo -e "${BOLD}${CYAN}══════ INSTALACIÓN UDP-CUSTOM ══════${NC}"

    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)  arch="amd64" ;;
        aarch64) arch="arm64" ;;
        armv7l)  arch="armv7" ;;
    esac

    mkdir -p /opt/udp-custom

    if [[ ! -f /opt/udp-custom/server ]]; then
        wget -q "https://github.com/AmnesiaPod/UDPCustom/releases/latest/download/udp-custom-linux-${arch}" \
            -O /opt/udp-custom/server 2>/dev/null || \
        wget -q "https://github.com/JoYonghyeok/UDPCustom/releases/latest/download/udp-custom-linux-${arch}" \
            -O /opt/udp-custom/server 2>/dev/null
        chmod +x /opt/udp-custom/server
    fi

    log_success "udp-custom instalado en /opt/udp-custom/"
}

configure_udp_custom() {
    local port_range="${1:-$PORT_UDP_CUSTOM}"

    cat > /opt/udp-custom/config.json <<UDPEOF
{
    "bind": "0.0.0.0:${port_range%%-*}",
    "stream_buffer_size": 2048,
    "core_buffer_size": 1024,
    "max_open_stream": 4096,
    "max_open_conn": 10240,
    "stream_congestion_control": "bbr",
    "conn_congestion_control": "bbr",
    "enable_metrics": false
}
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

    systemctl daemon-reload
    systemctl enable udp-custom >/dev/null 2>&1
    systemctl restart udp-custom 2>/dev/null || true

    open_port "${port_range%%-*}" "udp" "udp-custom"

    log_success "udp-custom configurado en puerto $port_range"
    log_audit "UDP-CUSTOM" "Configurado en puerto $port_range"
}

# ========================= MÓDULO CERTIFICADOS TLS =========================

install_acme_sh() {
    if [[ ! -f ~/.acme.sh/acme.sh ]]; then
        curl -fsSL https://get.acme.sh | sh -s -- --install-online 2>/dev/null
        ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt 2>/dev/null
        log_success "acme.sh instalado"
    fi
}

issue_certificate() {
    local domain="$1"

    if [[ -z "$domain" ]]; then
        log_error "Se requiere un dominio para emitir certificado"
        return 1
    fi

    log_info "Emitiendo certificado para $domain..."

    # Asegurar que los puertos 80 y 443 estén libres para ACME
    local saved_xray_state
    saved_xray_state=$(systemctl is-active xray 2>/dev/null || echo "inactive")
    systemctl stop xray 2>/dev/null || true

    ~/.acme.sh/acme.sh --issue -d "$domain" --standalone --force 2>/dev/null

    ~/.acme.sh/acme.sh --install-cert -d "$domain" \
        --key-file "$CERT_DIR/privkey.pem" \
        --fullchain-file "$CERT_DIR/fullchain.pem" \
        --reloadcmd "systemctl restart xray; systemctl restart hysteria-server; systemctl restart stunnel4" 2>/dev/null

    if [[ "$saved_xray_state" == "active" ]]; then
        systemctl start xray 2>/dev/null || true
    fi

    log_success "Certificado emitido para $domain"
    log_audit "CERT" "Certificado emitido para $domain"
}

generate_self_signed_cert() {
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout "$CERT_DIR/self-signed-key.pem" \
        -out "$CERT_DIR/self-signed.pem" \
        -subj "/CN=crisdev-vpn/O=CRISDEV/C=US" 2>/dev/null

    log_success "Certificado autofirmado generado (10 años)"
}

renew_certificates() {
    ~/.acme.sh/acme.sh --renew-all 2>/dev/null
    systemctl restart xray 2>/dev/null || true
    systemctl restart hysteria-server 2>/dev/null || true
    systemctl restart stunnel4 2>/dev/null || true
    log_info "Certificados renovados"
}

# ========================= MÓDULO USUARIOS CENTRAL =========================

create_user() {
    echo -e "${BOLD}${CYAN}══════ CREAR USUARIO ══════${NC}"
    echo ""

    read -p "Nombre de usuario: " username
    [[ -z "$username" ]] && { log_error "Nombre no puede estar vacío"; return 1; }

    if user_exists "$username"; then
        log_error "Usuario $username ya existe"
        return 1
    fi

    read -p "Contraseña (dejar vacío para auto-generar): " password
    password="${password:-$(generate_password)}"

    echo ""
    echo -e "${BOLD}Habilitar protocolos:${NC}"
    echo "  1) SSH"
    echo "  2) SSH-SSL"
    echo "  3) WebSocket (Payload)"
    echo "  4) SlowDNS"
    echo "  5) Xray VLESS"
    echo "  6) Xray VMess"
    echo "  7) Xray Trojan"
    echo "  8) Hysteria2"
    echo "  9) udp-custom"
    echo "  10) TODOS"
    read -p "Selecciona protocolos (separados por coma): " protocols_input

    local protocols
    IFS=',' read -ra protocols <<< "$protocols_input"

    read -p "Días de vigencia [30]: " days
    days="${days:-30}"

    read -p "Límite de conexiones simultáneas [2]: " max_conn
    max_conn="${max_conn:-2}"

    read -p "Límite de ancho de banda (Mbps, 0=sin límite) [0]: " bw_limit
    bw_limit="${bw_limit:-0}"

    local exp_date
    exp_date=$(date -d "+${days} days" '+%Y-%m-%d %H:%M:%S')

    local user_json
    user_json=$(jq -n \
        --arg u "$username" \
        --arg p "$password" \
        --arg exp "$exp_date" \
        --argjson mc "$max_conn" \
        --argjson bw "$bw_limit" \
        --argjson protos "$(printf '%s\n' "${protocols[@]}" | jq -R . | jq -s .)" \
        --argjson conn "0" \
        '{
            username: $u,
            password: $p,
            status: "active",
            created_at: (now | todate),
            expires_at: $exp,
            max_connections: $mc,
            current_connections: $conn,
            bandwidth_limit: $bw,
            protocols: $protos,
            data_used_bytes: 0,
            last_login: null,
            last_ip: null
        }')

    json_add_user "$user_json"

    # Crear usuario SSH si protocolo SSH está habilitado
    for proto in "${protocols[@]}"; do
        case "$proto" in
            1|"ssh")        create_ssh_user "$username" "$password" ;;
            2|"ssh-ssl")    create_ssh_user "$username" "$password" ;;
        esac
    done

    echo ""
    echo -e "${BOLD}${GREEN}═══════════════════════════════════════${NC}"
    echo -e "${GREEN}  Usuario ${BOLD}$username${NC}${GREEN} creado exitosamente${NC}"
    echo -e "${BOLD}${GREEN}═══════════════════════════════════════${NC}"
    echo -e "  Contraseña: ${BOLD}$password${NC}"
    echo -e "  Expira: ${BOLD}$exp_date${NC}"
    echo -e "  Protocolos: ${BOLD}${protocols[*]}${NC}"
    echo -e "  Max conexiones: ${BOLD}$max_conn${NC}"
    echo ""

    log_audit "USER_CREATE" "Usuario $username creado, protocolos: ${protocols[*]}, expira: $exp_date"
}

edit_user() {
    echo -e "${BOLD}${CYAN}══════ EDITAR USUARIO ══════${NC}"
    read -p "Nombre de usuario a editar: " username

    if ! user_exists "$username"; then
        log_error "Usuario $username no encontrado"
        return 1
    fi

    local user_data
    user_data=$(get_user "$username")

    echo -e "\nDatos actuales:"
    echo "$user_data" | jq -r '"  Estado: \(.status)\n  Expira: \(.expires_at)\n  Max conexiones: \(.max_connections)\n  BW límite: \(.bandwidth_limit)\n  Protocolos: \(.protocols | join(", "))"'

    echo ""
    echo "  1) Cambiar contraseña"
    echo "  2) Cambiar expiración"
    echo "  3) Cambiar límite de conexiones"
    echo "  4) Cambiar límite de ancho de banda"
    echo "  5) Modificar protocolos"
    echo "  6) Volver al menú"
    read -p "Opción: " opt

    case $opt in
        1)
            read -p "Nueva contraseña: " new_pass
            [[ -n "$new_pass" ]] && json_update_user "$username" "{\"password\": \"$new_pass\"}"
            # Actualizar en sistema
            echo "$username:$new_pass" | chpasswd 2>/dev/null || true
            ;;
        2)
            read -p "Nuevos días de vigencia: " new_days
            local new_exp
            new_exp=$(date -d "+${new_days} days" '+%Y-%m-%d %H:%M:%S')
            json_update_user "$username" "{\"expires_at\": \"$new_exp\"}"
            ;;
        3)
            read -p "Nuevo límite de conexiones: " new_mc
            json_update_user "$username" "{\"max_connections\": $new_mc}"
            ;;
        4)
            read -p "Nuevo límite de BW (Mbps, 0=sin límite): " new_bw
            json_update_user "$username" "{\"bandwidth_limit\": $new_bw}"
            ;;
        5)
            echo "  1) SSH  2) SSH-SSL  3) WS  4) SlowDNS  5) VLESS  6) VMess  7) Trojan  8) Hysteria2  9) udp-custom"
            read -p "Nuevos protocolos (coma separados): " new_protos
            local protos_arr
            IFS=',' read -ra protos_arr <<< "$new_protos"
            json_update_user "$username" "{\"protocols\": $(printf '%s\n' "${protos_arr[@]}" | jq -R . | jq -s .)}"
            ;;
        *) return 0 ;;
    esac

    log_audit "USER_EDIT" "Usuario $username editado"
    log_success "Usuario $username actualizado"
}

suspend_user() {
    read -p "Usuario a suspender: " username
    if ! user_exists "$username"; then
        log_error "Usuario $username no encontrado"
        return 1
    fi

    json_update_user "$username" '{"status": "suspended"}'

    # Bloquear usuario SSH
    usermod -L "$username" 2>/dev/null || true

    # Matar sesiones activas
    pkill -u "$username" 2>/dev/null || true

    log_audit "USER_SUSPEND" "Usuario $username suspendido"
    log_info "Usuario $username suspendido"
}

reactivate_user() {
    read -p "Usuario a reactivar: " username
    if ! user_exists "$username"; then
        log_error "Usuario $username no encontrado"
        return 1
    fi

    json_update_user "$username" '{"status": "active"}'
    usermod -U "$username" 2>/dev/null || true

    log_audit "USER_REACTIVATE" "Usuario $username reactivado"
    log_success "Usuario $username reactivado"
}

delete_user() {
    read -p "Usuario a eliminar: " username
    if ! user_exists "$username"; then
        log_error "Usuario $username no encontrado"
        return 1
    fi

    if ! confirm_action "¿Eliminar usuario $username permanentemente?"; then
        return 0
    fi

    # Cerrar sesiones activas
    pkill -u "$username" 2>/dev/null || true

    # Eliminar usuario del sistema
    userdel -r "$username" 2>/dev/null || userdel "$username" 2>/dev/null || true

    # Eliminar de la base de datos
    json_remove_user "$username"

    log_audit "USER_DELETE" "Usuario $username eliminado"
    log_info "Usuario $username eliminado completamente"
}

renew_user() {
    read -p "Usuario a renovar: " username
    if ! user_exists "$username"; then
        log_error "Usuario $username no encontrado"
        return 1
    fi

    local current_exp
    current_exp=$(jq -r ".[] | select(.username == \"$username\") | .expires_at // empty" "$USERS_DB")

    read -p "Días a agregar [30]: " add_days
    add_days="${add_days:-30}"

    local base_date
    if [[ -n "$current_exp" ]]; then
        local exp_ts
        exp_ts=$(date -d "$current_exp" +%s 2>/dev/null || echo 0)
        local now_ts
        now_ts=$(date +%s)
        if [[ $exp_ts -gt $now_ts ]]; then
            base_date="$current_exp"
        else
            base_date=$(date '+%Y-%m-%d %H:%M:%S')
        fi
    else
        base_date=$(date '+%Y-%m-%d %H:%M:%S')
    fi

    local new_exp
    new_exp=$(date -d "$base_date + ${add_days} days" '+%Y-%m-%d %H:%M:%S')
    json_update_user "$username" "{\"expires_at\": \"$new_exp\", \"status\": \"active\"}"
    usermod -U "$username" 2>/dev/null || true

    log_audit "USER_RENEW" "Usuario $username renovado hasta $new_exp"
    log_success "Usuario $username renovado hasta $new_exp"
}

list_users() {
    echo -e "${BOLD}${CYAN}══════ LISTA DE USUARIOS ══════${NC}"
    echo ""
    echo "Filtros:"
    echo "  1) Todos"
    echo "  2) Solo activos"
    echo "  3) Solo vencidos"
    echo "  4) Solo suspendidos"
    echo "  5) Por vencer (3 días)"
    echo "  6) Por protocolo"
    read -p "Filtro: " filter

    local query
    case $filter in
        2) query='.[] | select(.status == "active")' ;;
        3) query='[.[] | select(.expires_at != null and (.expires_at | fromdateiso8601) < now)] | .[]' ;;
        4) query='.[] | select(.status == "suspended")' ;;
        5) query='[.[] | select(.expires_at != null and (.expires_at | fromdateiso8601) > now and ((.expires_at | fromdateiso8601) - now) < 259200)] | .[]' ;;
        6)
            read -p "Protocolo (ssh/ssh-ssl/ws/slowdns/vless/vmess/trojan/hysteria/udp-custom): " proto_filter
            query=".[] | select(.protocols | map(ascii_downcase) | index(\"$proto_filter\"))"
            ;;
        *) query='.[]' ;;
    esac

    echo ""
    printf "${BOLD}%-15s %-10s %-12s %-8s %-10s %s${NC}\n" "USUARIO" "ESTADO" "EXPIRA" "CONEX" "BW(L)" "PROTOCOLOS"
    echo "─────────────────────────────────────────────────────────────────────────────"

    jq -r "$query | @tsv" "$USERS_DB" 2>/dev/null | while IFS=$'\t' read -r uname status exp conn bw protos; do
        local status_color="$GREEN"
        [[ "$status" == "suspended" ]] && status_color="$YELLOW"
        [[ "$status" == "expired" ]] && status_color="$RED"
        printf "%-15s ${status_color}%-10s${NC} %-12s %-8s %-10s %s\n" \
            "$uname" "$status" "${exp:-N/A}" "${conn:-0}" "${bw:-0}" "${protos:-[]}"
    done

    local total active_count
    total=$(jq 'length' "$USERS_DB")
    active_count=$(jq '[.[] | select(.status == "active")] | length' "$USERS_DB")
    echo ""
    echo -e "  Total: ${BOLD}$total${NC} | Activos: ${GREEN}${BOLD}$active_count${NC}"
}

user_detail() {
    read -p "Usuario: " username
    if ! user_exists "$username"; then
        log_error "Usuario $username no encontrado"
        return 1
    fi

    echo ""
    get_user "$username" | jq -r '
        "╔══════════════════════════════════════════╗",
        "║         DETALLE DE USUARIO              ║",
        "╚══════════════════════════════════════════╝",
        "",
        "  Usuario:       \(.username)",
        "  Estado:        \(.status)",
        "  Creado:        \(.created_at)",
        "  Expira:        \(.expires_at)",
        "  Max Conex:     \(.max_connections)",
        "  Conexiones:    \(.current_connections)",
        "  BW Límite:     \(.bandwidth_limit) Mbps",
        "  Datos usados:  \(.data_used_bytes) bytes",
        "  Último login:  \(.last_login // "Nunca")",
        "  Última IP:     \(.last_ip // "N/A")",
        "  Protocolos:    \(.protocols | join(", "))"
    '
}

search_users() {
    read -p "Buscar usuario: " query
    echo ""
    jq -r ".[] | select(.username | contains(\"$query\")) | \"  \(.username) - \(.status) - \(.expires_at // "N/A")\"" "$USERS_DB" 2>/dev/null
}

# ========================= MÓDULO MONITOREO =========================

show_server_status() {
    echo -e "${BOLD}${CYAN}══════ ESTADO DEL SERVIDOR ══════${NC}"
    echo ""

    # IP y sistema
    echo -e "${BOLD}Sistema:${NC}"
    echo -e "  IP: $(get_server_ip)"
    echo -e "  Hostname: $(hostname)"
    echo -e "  OS: $(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d'"' -f2)"
    echo -e "  Kernel: $(uname -r)"
    echo -e "  Uptime: $(uptime -p 2>/dev/null || uptime)"
    echo ""

    # CPU y RAM
    echo -e "${BOLD}Recursos:${NC}"
    local cpu_usage
    cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' 2>/dev/null || echo "N/A")
    echo -e "  CPU: ${cpu_usage}%"
    free -h | awk '/Mem:/{print "  RAM: "$3"/"$2" ("$3/$2*100"% uso)"}'
    df -h / | awk 'NR==2{print "  Disco: "$3"/"$2" ("$5" uso)"}'
    echo ""

    # Servicios
    echo -e "${BOLD}Servicios:${NC}"
    local services=("xray" "hysteria-server" "stunnel4" "slowdns" "udp-custom" "sshd" "fail2ban" "ufw")
    for svc in "${services[@]}"; do
        local status
        status=$(systemctl is-active "$svc" 2>/dev/null || echo "not-found")
        local icon="${RED}✗${NC}"
        local status_text="${RED}$status${NC}"
        if [[ "$status" == "active" ]]; then
            icon="${GREEN}●${NC}"
            status_text="${GREEN}active${NC}"
        elif [[ "$status" == "inactive" ]]; then
            icon="${YELLOW}○${NC}"
            status_text="${YELLOW}inactive${NC}"
        fi
        printf "  %b %-20s %b\n" "$icon" "$svc" "$status_text"
    done
    echo ""

    # Puertos abiertos
    echo -e "${BOLD}Puertos abiertos:${NC}"
    ss -tuln | grep LISTEN | awk '{print "  "$1, $5}' | sort -u | head -20
    echo ""

    # Conexiones activas
    echo -e "${BOLD}Conexiones activas:${NC}"
    echo -e "  SSH: $(ss -tn | grep -c ":$PORT_SSH " 2>/dev/null || echo 0)"
    echo -e "  Xray: $(ss -tn | grep -cE ":($PORT_XRAY_WS|$PORT_XRAY_GRPC|$PORT_XRAY_REALITY) " 2>/dev/null || echo 0)"
    echo -e "  Hysteria: $(ss -un | grep -c ":$PORT_HYSTERIA " 2>/dev/null || echo 0)"

    # Usuarios
    echo ""
    echo -e "${BOLD}Usuarios:${NC}"
    local total active_count exp_count
    total=$(jq 'length' "$USERS_DB" 2>/dev/null || echo 0)
    active_count=$(jq '[.[] | select(.status == "active")] | length' "$USERS_DB" 2>/dev/null || echo 0)
    exp_count=$(jq '[.[] | select(.expires_at != null and (.expires_at | fromdateiso8601) < now)] | length' "$USERS_DB" 2>/dev/null || echo 0)
    echo -e "  Total: ${BOLD}$total${NC}"
    echo -e "  Activos: ${GREEN}${BOLD}$active_count${NC}"
    echo -e "  Vencidos: ${RED}${BOLD}$exp_count${NC}"
    echo ""

    # fail2ban
    echo -e "${BOLD}fail2ban:${NC}"
    local banned
    banned=$(fail2ban-client status sshd 2>/dev/null | grep "Currently banned" | awk '{print $NF}' || echo "0")
    echo -e "  Baneados SSH: ${BOLD}$banned${NC}"
}

show_bandwidth_usage() {
    echo -e "${BOLD}${CYAN}══════ CONSUMO DE ANCHO DE BANDA ══════${NC}"
    echo ""

    # Total del servidor
    if command -v vnstat &>/dev/null; then
        vnstat -h 2>/dev/null | head -20
    else
        echo "  Instalando vnstat..."
        apt-get install -y -qq vnstat 2>/dev/null
        vnstat -u 2>/dev/null
        sleep 2
        vnstat -h 2>/dev/null | head -20
    fi
    echo ""

    # Por interfaz
    echo -e "${BOLD}Por interfaz:${NC}"
    for iface in /sys/class/net/*/statistics; do
        local iname
        iname=$(echo "$iface" | cut -d'/' -f5)
        [[ "$iname" == "lo" ]] && continue
        if [[ -f "$iface/rx_bytes" ]]; then
            local rx tx
            rx=$(cat "$iface/rx_bytes" 2>/dev/null || echo 0)
            tx=$(cat "$iface/tx_bytes" 2>/dev/null || echo 0)
            printf "  %-10s RX: %s bytes  TX: %s bytes\n" "$iname" "$rx" "$tx"
        fi
    done
}

# ========================= MÓDULO BACKUPS =========================

create_backup() {
    echo -e "${BOLD}${CYAN}══════ CREAR BACKUP ══════${NC}"

    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_file="$CRISDEV_BACKUPS/crisdev_backup_${timestamp}.tar.gz"

    tar -czf "$backup_file" \
        -C / \
        "etc/crisdev/data" \
        "etc/crisdev/certs" \
        "etc/hysteria" \
        "usr/local/etc/xray" \
        "opt/slowdns/server.key" \
        "opt/slowdns/server.pub" \
        2>/dev/null

    local size
    size=$(du -h "$backup_file" | awk '{print $1}')

    echo -e "  Backup creado: ${BOLD}$backup_file${NC}"
    echo -e "  Tamaño: ${BOLD}$size${NC}"

    log_audit "BACKUP" "Backup creado: $backup_file ($size)"
}

restore_backup() {
    echo -e "${BOLD}${CYAN}══════ RESTAURAR BACKUP ══════${NC}"
    echo ""

    echo "Backups disponibles:"
    ls -la "$CRISDEV_BACKUPS/" 2>/dev/null | grep ".tar.gz" | awk '{print "  " NR") " $NF " (" $5 " bytes)"}'

    echo ""
    read -p "Número de backup a restaurar: " backup_num
    local backup_file
    backup_file=$(ls "$CRISDEV_BACKUPS/"*.tar.gz 2>/dev/null | sed -n "${backup_num}p")

    if [[ -z "$backup_file" || ! -f "$backup_file" ]]; then
        log_error "Backup no encontrado"
        return 1
    fi

    if confirm_action "¿Restaurar desde $backup_file? Se sobreescribirán las configuraciones actuales."; then
        tar -xzf "$backup_file" -C / 2>/dev/null
        systemctl daemon-reload
        systemctl restart xray 2>/dev/null || true
        systemctl restart hysteria-server 2>/dev/null || true
        systemctl restart stunnel4 2>/dev/null || true
        systemctl restart slowdns 2>/dev/null || true
        systemctl restart udp-custom 2>/dev/null || true

        log_audit "RESTORE" "Backup restaurado desde $backup_file"
        log_success "Backup restaurado exitosamente"
    fi
}

list_backups() {
    echo -e "${BOLD}${CYAN}══════ BACKUPS DISPONIBLES ══════${NC}"
    echo ""
    if ls "$CRISDEV_BACKUPS/"*.tar.gz 1>/dev/null 2>&1; then
        ls -lah "$CRISDEV_BACKUPS/"*.tar.gz | awk '{print "  " $NF " - " $5}'
    else
        echo "  No hay backups disponibles"
    fi
}

# ========================= MÓDULO GENERACIÓN DE LINKS =========================

generate_user_links() {
    read -p "Usuario: " username
    if ! user_exists "$username"; then
        log_error "Usuario $username no encontrado"
        return 1
    fi

    local user_data
    user_data=$(get_user "$username")
    local user_id user_pass
    user_id=$(echo "$user_data" | jq -r '.username')
    user_pass=$(echo "$user_data" | jq -r '.password')

    local SERVER_IP
    SERVER_IP=$(get_server_ip)
    local SERVER_DOMAIN
    SERVER_DOMAIN=$(get_server_domain)
    local HOST="${SERVER_DOMAIN:-$SERVER_IP}"

    echo -e "${BOLD}${CYAN}══════ LINKS DE CONEXIÓN ══════${NC}"
    echo ""

    # VLESS + WS + TLS
    local vless_ws_link="vless://${user_id}@${HOST}:${PORT_XRAY_WS}?encryption=none&security=tls&type=ws&path=%2F$(openssl rand -hex 8)&host=${HOST}#CRISDEV-VLESS-WS"
    echo -e "${BOLD}VLESS + WS + TLS:${NC}"
    echo "  $vless_ws_link"
    echo ""

    # VLESS + gRPC + TLS
    local vless_grpc_link="vless://${user_id}@${HOST}:${PORT_XRAY_GRPC}?encryption=none&security=tls&type=grpc&serviceName=grpc-$(openssl rand -hex 4)&fp=chrome#CRISDEV-VLESS-gRPC"
    echo -e "${BOLD}VLESS + gRPC + TLS:${NC}"
    echo "  $vless_grpc_link"
    echo ""

    # VMess + WS + TLS
    local vmess_json="{\"v\":\"2\",\"ps\":\"CRISDEV-VMess-WS\",\"add\":\"${HOST}\",\"port\":\"${PORT_WEBSOCKET}\",\"id\":\"${user_id}\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"${HOST}\",\"path\":\"/vmess-ws\",\"tls\":\"tls\",\"sni\":\"${HOST}\",\"alpn\":\"h2,http/1.1\"}"
    local vmess_link="vmess://$(echo -n "$vmess_json" | base64 -w0)"
    echo -e "${BOLD}VMess + WS + TLS:${NC}"
    echo "  $vmess_link"
    echo ""

    # Trojan + WS + TLS
    local trojan_link="trojan://${user_pass}@${HOST}:${PORT_XRAY_VLESS}?type=ws&host=${HOST}&path=%2Ftrojan-ws&security=tls#CRISDEV-Trojan-WS"
    echo -e "${BOLD}Trojan + WS + TLS:${NC}"
    echo "  $trojan_link"
    echo ""

    # Hysteria2
    local hy2_link="hysteria2://${user_pass}@${HOST}:${PORT_HYSTERIA}?insecure=1&obfs=salamander&obfs-password=${user_pass}#CRISDEV-Hysteria2"
    echo -e "${BOLD}Hysteria2:${NC}"
    echo "  $hy2_link"
    echo ""

    # QR Code (si qrencode está instalado)
    if command -v qrencode &>/dev/null; then
        echo -e "${BOLD}QR Code VLESS-WS:${NC}"
        qrencode -t ANSIUTF8 "$vless_ws_link" 2>/dev/null
    else
        echo "  Instala qrencode para generar QR: apt install qrencode"
    fi
}

# ========================= MÓDULO ACTUALIZACIONES =========================

update_xray_core() {
    log_info "Actualizando Xray-core..."
    local latest_version
    latest_version=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -r '.tag_name' 2>/dev/null)

    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)  arch="64" ;;
        aarch64) arch="arm64-v8a" ;;
        armv7l)  arch="arm32-v7a" ;;
    esac

    wget -q "https://github.com/XTLS/Xray-core/releases/download/${latest_version}/Xray-linux-${arch}.zip" -O /tmp/xray.zip
    unzip -o /tmp/xray.zip -d /opt/xray/ >/dev/null 2>&1
    chmod +x /opt/xray/xray
    rm -f /tmp/xray.zip

    systemctl restart xray 2>/dev/null || true
    log_success "Xray-core actualizado a $latest_version"
    log_audit "UPDATE" "Xray-core actualizado a $latest_version"
}

update_hysteria2() {
    log_info "Actualizando Hysteria2..."
    bash <(curl -fsSL https://get.hy2.sh/) 2>/dev/null
    systemctl restart hysteria-server 2>/dev/null || true
    log_success "Hysteria2 actualizado"
    log_audit "UPDATE" "Hysteria2 actualizado"
}

check_versions() {
    echo -e "${BOLD}${CYAN}══════ VERSIONES INSTALADAS ══════${NC}"
    echo ""

    echo -n "  Xray-core: "
    /opt/xray/xray version 2>/dev/null | head -1 || echo "No instalado"

    echo -n "  Hysteria2: "
    hysteria-server version 2>/dev/null | head -1 || echo "No instalado"

    echo -n "  udp-custom: "
    /opt/udp-custom/server --version 2>/dev/null || echo "No instalado"

    echo ""
    echo -e "${BOLD}Últimas versiones disponibles:${NC}"
    local xray_latest hy_latest
    xray_latest=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -r '.tag_name' 2>/dev/null)
    hy_latest=$(curl -s https://api.github.com/repos/apernet/hysteria/releases/latest | jq -r '.tag_name' 2>/dev/null)
    echo "  Xray-core: $xray_latest"
    echo "  Hysteria2: $hy_latest"
}

# ========================= MÓDULO SELECCIÓN RÁPIDA (XRAY) =========================

quick_xray_menu() {
    echo -e "${BOLD}${CYAN}══════ XRAY-CORE - SELECCIÓN RÁPIDA ══════${NC}"
    echo ""
    echo "  1) Generar configuración completa (todos los protocolos)"
    echo "  2) Solo VLESS + WS + TLS"
    echo "  3) Solo VLESS + gRPC + TLS"
    echo "  4) Solo VLESS + REALITY"
    echo "  5) Solo VMess + WS + TLS"
    echo "  6) Solo Trojan + WS + TLS"
    echo "  7) Modificar puertos"
    echo "  8) Regresar"
    echo ""
    read -p "Opción: " xray_opt

    case $xray_opt in
        1) generate_xray_config ;;
        2-6)
            local SERVER_IP
            SERVER_IP=$(get_server_ip)
            local uuid
            uuid=$(generate_uuid)
            local ws_path="/$(openssl rand -hex 8)"

            echo -e "\n${BOLD}UUID para este usuario: $uuid${NC}"
            echo -e "Guárdalo en la base de datos de usuarios.\n"
            ;;
        7)
            echo -e "${BOLD}Puertos actuales:${NC}"
            echo "  VLESS-WS: $PORT_XRAY_WS"
            echo "  gRPC: $PORT_XRAY_GRPC"
            echo "  REALITY: $PORT_XRAY_REALITY"
            echo "  Trojan: $PORT_XRAY_VLESS"
            echo "  VMess-WS: $PORT_WEBSOCKET"
            echo ""
            read -p "Nuevo puerto VLESS-WS [Enter = no cambia]: " new_port
            [[ -n "$new_port" ]] && PORT_XRAY_WS=$new_port
            read -p "Nuevo puerto gRPC [Enter = no cambia]: " new_port
            [[ -n "$new_port" ]] && PORT_XRAY_GRPC=$new_port
            read -p "Nuevo puerto REALITY [Enter = no cambia]: " new_port
            [[ -n "$new_port" ]] && PORT_XRAY_REALITY=$new_port
            generate_xray_config
            ;;
        *) return 0 ;;
    esac
}

# ========================= MENÚ PRINCIPAL =========================

menu_main() {
    while true; do
        banner
        echo -e "${BOLD}  MENÚ PRINCIPAL${NC}"
        echo -e "${CYAN}───────────────────────────────────────${NC}"
        echo ""
        echo "  ${BOLD}USUARIOS${NC}"
        echo "    1) Crear usuario"
        echo "    2) Editar usuario"
        echo "    3) Eliminar usuario"
        echo "    4) Suspender usuario"
        echo "    5) Reactivar usuario"
        echo "    6) Renovar usuario"
        echo "    7) Listar usuarios"
        echo "    8) Ver detalle de usuario"
        echo "    9) Buscar usuario"
        echo ""
        echo "  ${BOLD}PROTOCOLOS${NC}"
        echo "   10) SSH / SSH-SSL"
        echo "   11) SlowDNS"
        echo "   12) Xray-core (VLESS/VMess/Trojan)"
        echo "   13) Hysteria2"
        echo "   14) udp-custom"
        echo "   15) Generar links de conexión"
        echo ""
        echo "  ${BOLD}SERVIDOR${NC}"
        echo "   16) Estado del servidor"
        echo "   17) Consumo de ancho de banda"
        echo "   18) Firewall"
        echo "   19) Certificados TLS"
        echo "   20) Modo pánico"
        echo ""
        echo "  ${BOLD}SISTEMA${NC}"
        echo "   21) Backup"
        echo "   22) Restaurar backup"
        echo "   23) Verificar/actualizar versiones"
        echo "   24) Logs de auditoría"
        echo "   25) Logs de servicios"
        echo "   26) Actualizar CRISDEV"
        echo ""
        echo "    0) Salir"
        echo ""
        echo -e "${CYAN}───────────────────────────────────────${NC}"
        read -p "  Selecciona una opción: " choice
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
            9)  search_users ;;
            10) menu_ssh ;;
            11) install_slowdns ;;
            12) quick_xray_menu ;;
            13) configure_hysteria2 ;;
            14) configure_udp_custom ;;
            15) generate_user_links ;;
            16) show_server_status ;;
            17) show_bandwidth_usage ;;
            18) menu_firewall ;;
            19) menu_certs ;;
            20) panic_mode ;;
            21) create_backup ;;
            22) restore_backup ;;
            23) check_versions ;;
            24) tail -50 "$AUDIT_LOG" ;;
            25) menu_service_logs ;;
            26) update_crisdev ;;
            0)  echo -e "${GREEN}Hasta luego, CRISDEV.${NC}"; exit 0 ;;
            *)  log_error "Opción inválida" ;;
        esac

        echo ""
        read -p "Presiona Enter para continuar..."
    done
}

# ========================= SUB-MENÚS =========================

menu_ssh() {
    echo -e "${BOLD}${CYAN}══════ MENÚ SSH ══════${NC}"
    echo ""
    echo "  1) Configurar SSH-SSL (stunnel)"
    echo "  2) Cambiar puerto SSH"
    echo "  3) Reiniciar SSH"
    echo "  4) Ver intentos fallidos (fail2ban)"
    echo "  5) Desbanear IP"
    echo "  6) Regresar"
    echo ""
    read -p "Opción: " ssh_opt

    case $ssh_opt in
        1)  configure_stunnel ;;
        2)
            read -p "Nuevo puerto SSH: " new_port
            PORT_SSH="$new_port"
            configure_ssh_base
            ;;
        3)  systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null
            log_success "SSH reiniciado" ;;
        4)  fail2ban-client status sshd 2>/dev/null ;;
        5)
            read -p "IP a desbanear: " ban_ip
            fail2ban-client set sshd unbanip "$ban_ip" 2>/dev/null
            log_info "IP $ban_ip desbaneada"
            ;;
        *)  return 0 ;;
    esac
}

menu_firewall() {
    echo -e "${BOLD}${CYAN}══════ MENÚ FIREWALL ══════${NC}"
    echo ""
    echo "  1) Ver reglas actuales"
    echo "  2) Abrir puerto"
    echo "  3) Cerrar puerto"
    echo "  4) Restablecer firewall"
    echo "  5) Modo pánico"
    echo "  6) Regresar"
    echo ""
    read -p "Opción: " fw_opt

    case $fw_opt in
        1)  ufw status verbose 2>/dev/null ;;
        2)
            read -p "Puerto: " p_port
            read -p "Protocolo (tcp/udp) [tcp]: " p_proto
            p_proto="${p_proto:-tcp}"
            open_port "$p_port" "$p_proto"
            ;;
        3)
            read -p "Puerto: " p_port
            read -p "Protocolo (tcp/udp) [tcp]: " p_proto
            p_proto="${p_proto:-tcp}"
            close_port "$p_port" "$p_proto"
            ;;
        4)  configure_firewall_base ;;
        5)  panic_mode ;;
        *)  return 0 ;;
    esac
}

menu_certs() {
    echo -e "${BOLD}${CYAN}══════ MENÚ CERTIFICADOS TLS ══════${NC}"
    echo ""
    echo "  1) Ver certificado actual"
    echo "  2) Emitir/renovar certificado (Let's Encrypt)"
    echo "  3) Generar certificado autofirmado"
    echo "  4) Renovar todos los certificados"
    echo "  5) Regresar"
    echo ""
    read -p "Opción: " cert_opt

    case $cert_opt in
        1)
            if [[ -f "$CERT_DIR/fullchain.pem" ]]; then
                openssl x509 -in "$CERT_DIR/fullchain.pem" -noout -subject -dates 2>/dev/null
            else
                echo "No hay certificado instalado"
            fi
            ;;
        2)
            read -p "Dominio: " cert_domain
            install_acme_sh
            issue_certificate "$cert_domain"
            ;;
        3)  generate_self_signed_cert ;;
        4)  renew_certificates ;;
        *)  return 0 ;;
    esac
}

menu_service_logs() {
    echo -e "${BOLD}${CYAN}══════ LOGS DE SERVICIOS ══════${NC}"
    echo ""
    echo "  1) Xray (últimas 20 líneas)"
    echo "  2) Hysteria2"
    echo "  3) SSH"
    echo "  4) fail2ban"
    echo "  5) Regresar"
    echo ""
    read -p "Opción: " log_opt

    case $log_opt in
        1)  journalctl -u xray --no-pager -n 20 ;;
        2)  journalctl -u hysteria-server --no-pager -n 20 ;;
        3)  journalctl -u sshd --no-pager -n 20 ;;
        4)  fail2ban-client status sshd 2>/dev/null ;;
        *)  return 0 ;;
    esac
}

update_crisdev() {
    log_info "Actualizando CRISDEV VPN Manager..."
    local script_url="https://raw.githubusercontent.com/CRISDEV/crisdev/main/crisdev.sh"
    curl -fsSL "$script_url" -o /tmp/crisdev_new.sh 2>/dev/null

    if [[ -f /tmp/crisdev_new.sh ]]; then
        local new_version
        new_version=$(grep "CRISDEV_VERSION=" /tmp/crisdev_new.sh | head -1 | cut -d'"' -f2)
        if [[ "$new_version" != "$CRISDEV_VERSION" ]]; then
            cp /usr/local/bin/crisdev /usr/local/bin/crisdev.bak 2>/dev/null || true
            cp /tmp/crisdev_new.sh /usr/local/bin/crisdev
            chmod +x /usr/local/bin/crisdev
            log_success "CRISDEV actualizado a v$new_version"
        else
            log_info "Ya estás en la última versión ($CRISDEV_VERSION)"
        fi
    else
        log_error "No se pudo descargar la actualización"
    fi
}

# ========================= PUNTO DE ENTRADA =========================

main() {
    check_root
    init_directories
    check_dependencies

    case "${1:-}" in
        --install|-i)
            install_complete
            ;;
        --status|-s)
            show_server_status
            ;;
        --backup|-b)
            create_backup
            ;;
        --users|-u)
            list_users
            ;;
        --help|-h)
            echo "CRISDEV VPN Manager v$CRISDEV_VERSION"
            echo ""
            echo "Uso:"
            echo "  crisdev              - Menú interactivo"
            echo "  crisdev --install    - Instalación completa"
            echo "  crisdev --status     - Estado del servidor"
            echo "  crisdev --backup     - Crear backup"
            echo "  crisdev --users      - Listar usuarios"
            echo "  crisdev --help       - Mostrar ayuda"
            ;;
        *)
            menu_main
            ;;
    esac
}

main "$@"
