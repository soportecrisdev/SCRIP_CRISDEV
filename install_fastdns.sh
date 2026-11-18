#!/usr/bin/env bash
# ==============================================================================
# HTTP CONEXIÓN - FastDNS (DNSTT Turbo) Installer & Manager
# Soporta túnel DNS de alta velocidad mediante DoH (HTTPS 443), DoT (TLS 853)
# y UDP 53 hacia el servidor VPS.
# ==============================================================================
set -Euo pipefail

VERSION="2.0.0-turbo"
TITLE="HTTP CONEXIÓN - FastDNS (DNSTT Turbo)"

SLOW_DIR="/etc/slowdns"
SLOW_CONF="${SLOW_DIR}/slowdns.conf"
SLOW_KEY="${SLOW_DIR}/server.key"
SLOW_PUB="${SLOW_DIR}/server.pub"
SLOW_NS_FILE="${SLOW_DIR}/ns.txt"
SLOW_BIN="/usr/local/bin/dnstt-server"
SLOW_SERVICE="/etc/systemd/system/fastdns.service"
SLOW_LEGACY_SERVICE="/etc/systemd/system/slowdns.service"
SLOW_IPTABLES="${SLOW_DIR}/iptables.sh"
SLOW_LOG="/var/log/fastdns.log"

SYSCTL_CONF="/etc/sysctl.d/99-fastdns-performance.conf"

DEFAULT_PORT="5300"
DEFAULT_SSH_PORT="22"

# Colores y Formato
red='\033[1;31m'
green='\033[1;32m'
cyan='\033[1;36m'
yellow='\033[1;33m'
blue='\033[1;34m'
magenta='\033[1;35m'
neon='\033[1;38;2;0;255;127m'
white='\033[1;37m'
dim='\033[2m'
reset='\033[0m'

ok()   { printf '%b✔%b %s\n' "$green" "$reset" "$*"; }
info() { printf '%bℹ%b %s\n' "$cyan" "$reset" "$*"; }
warn() { printf '%b⚠%b %s\n' "$yellow" "$reset" "$*"; }
fail() { printf '%b✘%b %s\n' "$red" "$reset" "$*" >&2; }

need_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        fail "Este script debe ejecutarse como root o con sudo."
        exit 1
    fi
}

line() {
    printf '%b%s%b\n' "$cyan" "==================================================================" "$reset"
}

banner() {
    clear
    line
    printf '%b  ⚡  %s (v%s)  ⚡%b\n' "$neon" "$TITLE" "$VERSION" "$reset"
    printf '%b     Túnel DNS Cifrado para HTTP Conexión (DoH / DoT / UDP)%b\n' "$dim" "$reset"
    line
}

pause() {
    echo
    printf '%b* Presiona ENTER para continuar...%b' "$yellow" "$reset"
    read -r _ || true
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        armv7l|armhf) echo "arm" ;;
        *) return 1 ;;
    esac
}

get_public_ip() {
    local ip
    ip=$(curl -4 -sSL --connect-timeout 3 https://api.ipify.org 2>/dev/null || \
         curl -4 -sSL --connect-timeout 3 https://ifconfig.me 2>/dev/null || \
         hostname -I | awk '{print $1}')
    echo "${ip:-127.0.0.1}"
}

install_dependencies() {
    info "Verificando dependencias del sistema..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y >/dev/null 2>&1 || true
        apt-get install -y curl wget iptables net-tools ca-certificates dnsutils lsof >/dev/null 2>&1 || true
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl wget iptables net-tools ca-certificates bind-utils lsof >/dev/null 2>&1 || true
    fi
    ok "Dependencias verificadas."
}

install_binary() {
    local arch s_arch script_dir
    arch="$(detect_arch)" || {
        fail "Arquitectura no soportada: $(uname -m)"
        return 1
    }
    s_arch="$arch"
    [[ "$arch" == "arm" ]] && s_arch="arm"

    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

    # 1. Verificar si ya existe binario ejecutable y funcional
    if [[ -x "$SLOW_BIN" ]]; then
        ok "Binario dnstt-server existente en $SLOW_BIN."
        return 0
    fi

    # 2. Verificar copias locales en el directorio del script
    if [[ -f "${script_dir}/dnstt-server-${s_arch}" ]]; then
        info "Instalando dnstt-server desde copia local (${s_arch})..."
        cp -f "${script_dir}/dnstt-server-${s_arch}" "$SLOW_BIN"
    elif [[ -f "${script_dir}/dnstt-server" ]]; then
        info "Instalando dnstt-server desde copia local..."
        cp -f "${script_dir}/dnstt-server" "$SLOW_BIN"
    elif [[ -x "/bin/dnstt-server" ]]; then
        cp -f "/bin/dnstt-server" "$SLOW_BIN"
    else
        # 3. Descargar desde repositorios oficiales / espejo
        info "Descargando dnstt-server para ${s_arch}..."
        local downloaded=0
        local urls=(
            "https://raw.githubusercontent.com/soportecrisdev/SCRIP_CRISDEV/main/dnstt-server-${s_arch}"
            "https://dnstt.network/dnstt-server-linux-${s_arch}"
        )
        for u in "${urls[@]}"; do
            if curl -fsSL --retry 3 --connect-timeout 8 "$u" -o "$SLOW_BIN" 2>/dev/null; then
                downloaded=1
                break
            elif wget -q -T 8 "$u" -O "$SLOW_BIN" 2>/dev/null; then
                downloaded=1
                break
            fi
        done

        if [[ $downloaded -eq 0 || ! -s "$SLOW_BIN" ]]; then
            fail "No se pudo descargar dnstt-server. Verifica tu conexión a internet."
            return 1
        fi
    fi

    chmod 755 "$SLOW_BIN"
    ln -sfn "$SLOW_BIN" /bin/dnstt-server 2>/dev/null || true
    ok "Binario dnstt-server instalado exitosamente."
}

free_port_53() {
    info "Comprobando disponibilidad del puerto 53 UDP..."
    local resolved_conf="/etc/systemd/resolved.conf"

    if [[ -f "$resolved_conf" ]]; then
        if grep -q "DNSStubListener" "$resolved_conf" 2>/dev/null; then
            sed -i 's/^#\?DNSStubListener=.*/DNSStubListener=no/' "$resolved_conf"
        else
            echo "DNSStubListener=no" >> "$resolved_conf"
        fi

        # Si el resolv.conf apunta al stub listener 127.0.0.53, redirigirlo a 1.1.1.1 y 8.8.8.8
        if grep -q "127.0.0.53" /etc/resolv.conf 2>/dev/null; then
            rm -f /etc/resolv.conf
            cat > /etc/resolv.conf <<EOF
nameserver 1.1.1.1
nameserver 8.8.8.8
nameserver 1.0.0.1
EOF
        fi
        systemctl restart systemd-resolved 2>/dev/null || true
    fi

    # Detener servicios locales que ocupen el puerto 53
    if command -v fuser >/dev/null 2>&1; then
        fuser -k 53/udp 2>/dev/null || true
    fi
    ok "Puerto 53 liberado para FastDNS."
}

tune_system() {
    info "Aplicando optimizaciones de Kernel para alto rendimiento UDP..."
    mkdir -p /etc/sysctl.d
    cat > "$SYSCTL_CONF" <<EOF
# FastDNS / DNSTT High Performance Tuning
net.core.rmem_max=26214400
net.core.rmem_default=26214400
net.core.wmem_max=26214400
net.core.wmem_default=26214400
net.core.netdev_max_backlog=10000
net.ipv4.udp_rmem_min=16384
net.ipv4.udp_wmem_min=16384
net.ipv4.ip_forward=1
net.netfilter.nf_conntrack_udp_timeout=120
net.netfilter.nf_conntrack_udp_timeout_stream=300
EOF
    sysctl --system >/dev/null 2>&1 || sysctl -p "$SYSCTL_CONF" >/dev/null 2>&1 || true
    ok "Kernel optimizado para tráfico FastDNS."
}

generate_keys_if_needed() {
    mkdir -p "$SLOW_DIR"
    if [[ -f "$SLOW_KEY" && -f "$SLOW_PUB" && -s "$SLOW_KEY" && -s "$SLOW_PUB" ]]; then
        info "Claves criptográficas existentes encontradas."
        return 0
    fi

    info "Generando nuevo par de claves elípticas (Curve25519)..."
    "$SLOW_BIN" -gen-key -privkey-file "$SLOW_KEY" -pubkey-file "$SLOW_PUB" >/dev/null 2>&1 || {
        fail "Fallo al generar claves con $SLOW_BIN."
        return 1
    }
    chmod 600 "$SLOW_KEY"
    chmod 644 "$SLOW_PUB"
    ok "Par de claves generado con éxito."
}

configure_iptables() {
    mkdir -p "$SLOW_DIR"
    cat > "$SLOW_IPTABLES" << 'EOF'
#!/bin/bash
ACTION="${1:-apply}"
PORT="5300"
REDIR="53"

clear_rules() {
    iptables -D INPUT -p udp --dport "$REDIR" -j ACCEPT >/dev/null 2>&1 || true
    iptables -D INPUT -p udp --dport "$PORT" -j ACCEPT >/dev/null 2>&1 || true
    while iptables -t nat -C PREROUTING -p udp -m udp --dport "$REDIR" -j REDIRECT --to-ports "$PORT" >/dev/null 2>&1; do
        iptables -t nat -D PREROUTING -p udp -m udp --dport "$REDIR" -j REDIRECT --to-ports "$PORT" >/dev/null 2>&1 || break
    done
    while iptables -t nat -C PREROUTING -p udp --dport "$REDIR" -j REDIRECT --to-ports "$PORT" >/dev/null 2>&1; do
        iptables -t nat -D PREROUTING -p udp --dport "$REDIR" -j REDIRECT --to-ports "$PORT" >/dev/null 2>&1 || break
    done
}

apply_rules() {
    clear_rules
    iptables -I INPUT 1 -p udp --dport "$REDIR" -j ACCEPT >/dev/null 2>&1 || true
    iptables -I INPUT 1 -p udp --dport "$PORT" -j ACCEPT >/dev/null 2>&1 || true
    iptables -t nat -I PREROUTING 1 -p udp -m udp --dport "$REDIR" -j REDIRECT --to-ports "$PORT" >/dev/null 2>&1 || true
}

case "$ACTION" in
    apply) apply_rules ;;
    clear) clear_rules ;;
esac
exit 0
EOF
    chmod +x "$SLOW_IPTABLES"
    "$SLOW_IPTABLES" apply
    ok "Reglas de redirección UDP 53 -> 5300 aplicadas."
}

setup_systemd_service() {
    local ns_domain="$1"
    local ssh_port="$2"

    mkdir -p "$SLOW_DIR"
    echo "$ns_domain" > "$SLOW_NS_FILE"

    cat > "$SLOW_CONF" <<EOF
SLOW_PORT="$DEFAULT_PORT"
SLOW_TRAFFIC="$ssh_port"
SLOW_DOMAIN="$ns_domain"
SLOW_REDIRECT="53"
EOF

    # Detener servicios previos
    systemctl stop fastdns 2>/dev/null || true
    systemctl stop slowdns 2>/dev/null || true
    pkill -9 -f dnstt-server 2>/dev/null || true

    cat > "$SLOW_SERVICE" <<EOF
[Unit]
Description=HTTP CONEXION FastDNS (DNSTT Turbo) Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment="GOMEMLIMIT=384MiB"
Environment="GOGC=250"
ExecStartPre=-${SLOW_IPTABLES} apply
ExecStart=${SLOW_BIN} -udp :${DEFAULT_PORT} -privkey-file ${SLOW_KEY} ${ns_domain} 127.0.0.1:${ssh_port}
ExecStopPost=-${SLOW_IPTABLES} clear
Restart=always
RestartSec=2
LimitNOFILE=65535
StandardOutput=append:${SLOW_LOG}
StandardError=append:${SLOW_LOG}

[Install]
WantedBy=multi-user.target
EOF

    # Compatibilidad con scripts legacy (slowdns.service)
    ln -sfn "$SLOW_SERVICE" "$SLOW_LEGACY_SERVICE" 2>/dev/null || true

    systemctl daemon-reload
    systemctl unmask fastdns.service slowdns.service 2>/dev/null || true
    systemctl enable fastdns.service >/dev/null 2>&1
    systemctl restart fastdns.service

    sleep 1.5
    if systemctl is-active --quiet fastdns.service || pgrep -f dnstt-server >/dev/null 2>&1; then
        ok "Servicio FastDNS activo y escuchando en el puerto 53 / 5300."
    else
        warn "El servicio inició pero está verificando sockets. Revisa los logs con: journalctl -u fastdns -n 30"
    fi
}

show_connection_data() {
    banner
    local vps_ip ns_domain pub_key ssh_port

    vps_ip="$(get_public_ip)"
    ns_domain="$(cat "$SLOW_NS_FILE" 2>/dev/null || echo "t.tudominio.com")"
    pub_key="$(cat "$SLOW_PUB" 2>/dev/null || echo "No generada aún")"
    ssh_port="22"
    if [[ -f "$SLOW_CONF" ]]; then
        ssh_port="$(grep 'SLOW_TRAFFIC=' "$SLOW_CONF" | cut -d'"' -f2 || echo "22")"
    fi

    printf '%b%s%b\n' "$yellow" "1. CONFIGURACIÓN REQUERIDA EN TU PROVEEDOR DNS (Cloudflare / Namecheap)" "$reset"
    printf '   %bCrea 2 registros DNS para vincular el tráfico:%b\n\n' "$white" "$reset"
    printf '   %b[Registro A]%b\n' "$cyan" "$reset"
    printf '   • Tipo:       %bA%b\n' "$white" "$reset"
    printf '   • Nombre:     %bns%b (o ns1)\n' "$neon" "$reset"
    printf '   • Contenido:  %b%s%b (IP pública del VPS)\n' "$green" "$vps_ip" "$reset"
    printf '   • Proxy:      %bDNS Only (Nube GRIS / Desactivada)%b\n\n' "$yellow" "$reset"

    printf '   %b[Registro NS (Nameserver Delegado)]%b\n' "$cyan" "$reset"
    printf '   • Tipo:       %bNS%b\n' "$white" "$reset"
    printf '   • Nombre:     %bt%b (ejemplo: t.%s)\n' "$neon" "$reset" "${ns_domain#*.}"
    printf '   • Contenido:  %bns.%s%b\n' "$green" "${ns_domain#*.}" "$reset"
    printf '   • Proxy:      %bDNS Only%b\n\n' "$yellow" "$reset"

    line
    printf '%b%s%b\n' "$neon" "2. DATOS PARA LA APP HTTP CONEXIÓN / GEN SERVIDORES" "$reset"
    line
    printf ' • %bProtocolo:%b        %b⚡ FastDNS / Slow%b\n' "$white" "$reset" "$neon" "$reset"
    printf ' • %bNameserver (NS):%b   %b%s%b\n' "$white" "$reset" "$yellow" "$ns_domain" "$reset"
    printf ' • %bClave Pública:%b     %b%s%b\n' "$white" "$reset" "$green" "$pub_key" "$reset"
    printf ' • %bResolver FastDNS:%b  %bhttps://cloudflare-dns.com/dns-query%b (DoH Turbo ⚡)\n' "$white" "$reset" "$cyan" "$reset"
    printf ' • %bResolver Alterno:%b  %bhttps://dns.google/dns-query%b (Google DoH)\n' "$white" "$reset" "$cyan" "$reset"
    printf ' • %bResolver DoT:%b      %b1.1.1.1:853%b (TLS 853 🔒)\n' "$white" "$reset" "$cyan" "$reset"
    printf ' • %bDestino SSH VPS:%b   %b127.0.0.1:%s%b\n' "$white" "$reset" "$white" "$ssh_port" "$reset"
    line
    pause
}

check_service_status() {
    banner
    printf '%bESTADO DEL SERVICIO FASTDNS:%b\n' "$cyan" "$reset"
    line
    if systemctl is-active --quiet fastdns.service 2>/dev/null || pgrep -f dnstt-server >/dev/null 2>&1; then
        printf ' Estado: %b● ACTIVO Y EN EJECUCIÓN%b\n\n' "$green" "$reset"
    else
        printf ' Estado: %b○ DETENIDO / INACTIVO%b\n\n' "$red" "$reset"
    fi

    printf '%bPuertos en escucha:%b\n' "$yellow" "$reset"
    netstat -ulnp 2>/dev/null | grep -E ':(53|5300)\b' || ss -ulpn 2>/dev/null | grep -E ':(53|5300)\b' || echo "Sin sockets visibles."
    echo
    printf '%bReglas IPTables activas (Redirección 53 -> 5300):%b\n' "$yellow" "$reset"
    iptables -t nat -S PREROUTING 2>/dev/null | grep -E '5300' || echo "No hay reglas PREROUTING activas."
    line
    pause
}

view_logs() {
    banner
    printf '%bÚLTIMOS EVENTOS DE FASTDNS:%b\n' "$cyan" "$reset"
    line
    journalctl -u fastdns -n 60 --no-pager 2>/dev/null || tail -n 60 "$SLOW_LOG" 2>/dev/null || echo "Sin logs disponibles."
    pause
}

restart_service() {
    info "Reiniciando FastDNS..."
    "$SLOW_IPTABLES" apply 2>/dev/null || true
    systemctl restart fastdns.service 2>/dev/null || true
    ok "Servicio reiniciado."
    sleep 1
}

stop_service() {
    info "Deteniendo servicio FastDNS..."
    systemctl stop fastdns.service 2>/dev/null || true
    systemctl stop slowdns.service 2>/dev/null || true
    pkill -9 -f dnstt-server 2>/dev/null || true
    "$SLOW_IPTABLES" clear 2>/dev/null || true
    ok "Servicio detenido y reglas de firewall limpiadas."
    pause
}

run_wizard() {
    banner
    printf '%bINSTALACIÓN Y CONFIGURACIÓN DE FASTDNS (DNSTT)%b\n' "$yellow" "$reset"
    line

    local current_ns=""
    [[ -f "$SLOW_NS_FILE" ]] && current_ns="$(cat "$SLOW_NS_FILE" 2>/dev/null)"

    printf '%bIngresa tu dominio Nameserver delegado (NS):%b\n' "$white" "$reset"
    printf '%bEjemplo: t.tudominio.com%b\n' "$dim" "$reset"
    if [[ -n "$current_ns" ]]; then
        printf 'Actual: %b%s%b\n' "$green" "$current_ns" "$reset"
    fi
    printf '%bDominio NS:%b ' "$cyan" "$reset"
    read -r user_ns
    user_ns="${user_ns:-$current_ns}"

    if [[ -z "$user_ns" ]]; then
        fail "Debes especificar un dominio NS válido."
        pause
        return 1
    fi

    printf '\n%bPuerto local SSH / Dropbear de destino [22]:%b ' "$cyan" "$reset"
    read -r user_ssh
    user_ssh="${user_ssh:-$DEFAULT_SSH_PORT}"

    line
    install_dependencies
    install_binary
    free_port_53
    tune_system
    generate_keys_if_needed
    configure_iptables
    setup_systemd_service "$user_ns" "$user_ssh"

    ok "¡FastDNS instalado y configurado correctamente!"
    sleep 1
    show_connection_data
}

# Modo CLI Automático (No interactivo)
handle_cli_args() {
    local ns=""
    local port="$DEFAULT_SSH_PORT"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ns)
                ns="$2"
                shift 2
                ;;
            --ssh-port)
                port="$2"
                shift 2
                ;;
            --auto)
                need_root
                install_dependencies
                install_binary
                free_port_53
                tune_system
                generate_keys_if_needed
                configure_iptables
                setup_systemd_service "$ns" "$port"
                show_connection_data
                exit 0
                ;;
            --status)
                check_service_status
                exit 0
                ;;
            --stop)
                stop_service
                exit 0
                ;;
            --help|-h)
                echo "Uso: $0 [--ns <dominio_ns>] [--ssh-port <puerto>] [--auto]"
                exit 0
                ;;
            *)
                shift
                ;;
        esac
    done
}

# Menú Principal Interactivo
main_menu() {
    need_root
    while true; do
        banner
        local status_str="${red}DETENIDO${reset}"
        if systemctl is-active --quiet fastdns.service 2>/dev/null || pgrep -f dnstt-server >/dev/null 2>&1; then
            status_str="${green}ACTIVO (Puerto 53 -> 5300 UDP)${reset}"
        fi

        printf ' • Estado: %b\n' "$status_str"
        if [[ -f "$SLOW_NS_FILE" ]]; then
            printf ' • Nameserver: %b%s%b\n' "$yellow" "$(cat "$SLOW_NS_FILE" 2>/dev/null)" "$reset"
        fi
        if [[ -f "$SLOW_PUB" ]]; then
            printf ' • Clave Pública: %b%s%b\n' "$neon" "$(cat "$SLOW_PUB" 2>/dev/null)" "$reset"
        fi
        line
        printf ' %b[1]%b %bInstalar / Configurar FastDNS (Dominio y Claves)%b\n' "$neon" "$reset" "$white" "$reset"
        printf ' %b[2]%b %bVer Datos de Conexión (App HTTP Conexión & DNS)%b\n' "$neon" "$reset" "$white" "$reset"
        printf ' %b[3]%b %bComprobar Estado y Puertos del Servicio%b\n' "$neon" "$reset" "$white" "$reset"
        printf ' %b[4]%b %bVer Logs en Vivo%b\n' "$neon" "$reset" "$white" "$reset"
        printf ' %b[5]%b %bReiniciar Servicio FastDNS%b\n' "$neon" "$reset" "$white" "$reset"
        printf ' %b[6]%b %bDetener Servicio FastDNS%b\n' "$red" "$reset" "$white" "$reset"
        printf ' %b[0]%b %bSalir%b\n' "$red" "$reset" "$white" "$reset"
        line
        printf '%bOpción:%b ' "$cyan" "$reset"
        read -r choice

        case "$choice" in
            1) run_wizard ;;
            2) show_connection_data ;;
            3) check_service_status ;;
            4) view_logs ;;
            5) restart_service ;;
            6) stop_service ;;
            0) clear; exit 0 ;;
            *) warn "Opción no válida." ; sleep 1 ;;
        esac
    done
}

if [[ $# -gt 0 ]]; then
    handle_cli_args "$@"
else
    main_menu
fi
