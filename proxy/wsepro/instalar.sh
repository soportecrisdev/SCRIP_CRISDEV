#!/usr/bin/env bash
# ==============================================================================
# INSTALADOR COMPLETO — WS-EPRO (ePro Dev Team + MTU 1280 + BBR + 1GB RAM SAFE)
# Ubicación: proxy/wsepro/instalar.sh
# ==============================================================================

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_DIR="/etc/crisdev/ws-epro"
CONF_FILE="${CONF_DIR}/config.yml"
BIN_DEST="/usr/local/bin/ws-epro"
SERVICE_NAME="crisdev-ws-epro.service"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"
REPO_RAW="https://raw.githubusercontent.com/soportecrisdev/SCRIP_CRISDEV/main/proxy/wsepro"

C_CYAN='\033[1;36m'
C_GREEN='\033[1;32m'
C_YELLOW='\033[1;33m'
C_RED='\033[1;31m'
C_WHITE='\033[1;37m'
C_BLUE_BG='\E[44;1;37m'
NC='\033[0m'

line_bar() {
    echo -e "${C_CYAN}============================================================${NC}"
}

get_service_ports() {
    local pattern="$1"
    local pids
    pids=$(pgrep -f "$pattern" 2>/dev/null | tr '\n' '|' | sed 's/|$//')
    [[ -z "$pids" ]] && return
    ss -tlpn 2>/dev/null | grep -E "pid=(${pids})," | awk '{print $4}' | awk -F: '{print $NF}' | sort -un | xargs
}

ensure_wsepro_bin() {
    mkdir -p /usr/local/bin "$CONF_DIR"
    if [[ -s "${SCRIPT_DIR}/ws-epro" ]]; then
        cp -af "${SCRIPT_DIR}/ws-epro" "$BIN_DEST"
    elif [[ -s "/opt/ssh-cris/proxy/wsepro/ws-epro" ]]; then
        cp -af "/opt/ssh-cris/proxy/wsepro/ws-epro" "$BIN_DEST"
    elif [[ ! -x "$BIN_DEST" ]]; then
        echo -e "${C_YELLOW}[*] Descargando binario oficial ws-epro...${NC}"
        curl -fsSL "${REPO_RAW}/ws-epro" -o "$BIN_DEST" 2>/dev/null || \
        wget -q "${REPO_RAW}/ws-epro" -O "$BIN_DEST" 2>/dev/null || true
    fi
    chmod 755 "$BIN_DEST" 2>/dev/null || true
    [[ -x "$BIN_DEST" ]]
}

apply_mtu_bbr_tuning() {
    local port="$1"
    echo -e "${C_YELLOW}[*] Aplicando MTU 1280 (MSS=1220), TCP BBR y Keep-Alive Anti-CGNAT...${NC}"
    modprobe tcp_bbr 2>/dev/null || true
    mkdir -p /etc/sysctl.d
    cat > /etc/sysctl.d/98-crisdev-ws-gaming.conf << 'EOF_SYSCTL'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_mtu_probing = 2
net.ipv4.tcp_base_mss = 1024
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 25
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 6
net.ipv4.tcp_sack = 1
net.ipv4.tcp_window_scaling = 1
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
EOF_SYSCTL
    sysctl -p /etc/sysctl.d/98-crisdev-ws-gaming.conf >/dev/null 2>&1 || true

    if command -v iptables >/dev/null 2>&1; then
        iptables -t mangle -C POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
        iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
        iptables -t mangle -C OUTPUT -p tcp --sport "${port}" --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1220 2>/dev/null || \
        iptables -t mangle -A OUTPUT -p tcp --sport "${port}" --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1220 2>/dev/null || true
    fi
}

clear
echo -e "${C_BLUE_BG}       ACTIVAR WS-EPRO (ePro Dev Team · HTTP Custom Engine)       ${NC}\n"
echo -e "${C_YELLOW}• Motor oficial ePro Dev Team (multi-puerto YAML, ultra-liviano)${NC}"
echo -e "${C_YELLOW}• Optimizado con MTU 1280 (MSS 1220), TCP BBR y protección 1GB RAM${NC}\n"

# ------------------------------------------------------------------------------
# PASO 1: PUERTO DE ESCUCHA
# ------------------------------------------------------------------------------
line_bar
echo -e "${C_GREEN}[PASO 1/2] PUERTO DE ESCUCHA WS-EPRO${NC}"
line_bar
echo -ne "${C_WHITE}¿Qué puerto desea utilizar? (default 80): ${NC}"
read -r WS_PORT
[[ -z "$WS_PORT" || ! "$WS_PORT" =~ ^[0-9]+$ ]] && WS_PORT="80"

OCCUPIED=$(ss -tlpn 2>/dev/null | grep -E "[:.]${WS_PORT}[[:space:]]" || true)
if [[ -n "$OCCUPIED" ]]; then
    echo -e "\n${C_YELLOW}[!] El puerto ${WS_PORT} está siendo usado actualmente:${NC}"
    echo -e "    ${OCCUPIED}"
    echo -ne "${C_YELLOW}¿Desea liberar el puerto ${WS_PORT} para WS-ePro? [s/N]: ${NC}"
    read -r FREE_OPT
    if [[ ! "$FREE_OPT" =~ ^[sSyY]$ ]]; then
        echo -e "${C_RED}Instalación cancelada.${NC}"
        sleep 1.5
        exit 1
    fi
    if echo "$OCCUPIED" | grep -q 'wsproxy-c'; then
        [[ -x /opt/ssh-cris/proxy/wsnativo/desinstalar.sh ]] && bash /opt/ssh-cris/proxy/wsnativo/desinstalar.sh >/dev/null 2>&1 || true
        pkill -9 -x 'wsproxy-c' 2>/dev/null || true
    fi
    if echo "$OCCUPIED" | grep -q 'python'; then
        systemctl stop crisdev-ws-python.service 2>/dev/null || true
        systemctl disable crisdev-ws-python.service 2>/dev/null || true
        pkill -9 -f 'wsproxy\.py' 2>/dev/null || true
        pkill -9 -f "/etc/SSHPlus/proxy\.py.*${WS_PORT}" 2>/dev/null || true
    fi
    if echo "$OCCUPIED" | grep -q 'ws-epro'; then
        systemctl stop "$SERVICE_NAME" ws-epro.service 2>/dev/null || true
        pkill -9 -x 'ws-epro' 2>/dev/null || true
    fi
    fuser -k "${WS_PORT}/tcp" >/dev/null 2>&1 || true
    sleep 1
fi

# ------------------------------------------------------------------------------
# PASO 2: DESTINO DE REDIRECCIÓN LOCAL
# ------------------------------------------------------------------------------
clear
line_bar
echo -e "${C_CYAN}             CONFIGURAR WS-EPRO (REDIRECCIÓN LOCAL)${NC}"
line_bar
echo -e "${C_GREEN}[PASO 2/2] PUERTO ESCUCHA:${NC} ${C_WHITE}${WS_PORT}${NC}"
echo -e "${C_WHITE}¿A qué servicio local desea redirigir el tráfico?${NC}"
line_bar

_lbl=()
_prt=()
_append_dst() {
    local l="$1" p="$2"
    [[ -z "$p" || ! "$p" =~ ^[0-9]+$ ]] && return
    for ep in "${_prt[@]:-}"; do [[ "$ep" == "$p" ]] && return; done
    _lbl+=("$l")
    _prt+=("$p")
}

SSH_P=$(grep -E '^Port ' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1 || true)
[[ -z "$SSH_P" ]] && SSH_P="22"
_append_dst "OpenSSH Directo" "$SSH_P"

DRP_P=$(get_service_ports 'dropbear' | awk '{print $1}')
[[ -n "$DRP_P" ]] && _append_dst "Dropbear SSH" "$DRP_P"

OVP_P=$(get_service_ports 'openvpn' | awk '{print $1}')
[[ -n "$OVP_P" ]] && _append_dst "OpenVPN TCP" "$OVP_P"

for ((i = 0; i < ${#_prt[@]}; i++)); do
    printf "  ${C_GREEN}[%d]${NC} > %-24s ${C_YELLOW}........${NC} ${C_WHITE}%s${NC}\n" "$((i + 1))" "${_lbl[i]}" "${_prt[i]}"
done
echo -e "  ${C_GREEN}[5]${NC} > INGRESAR MANUALMENTE (IP:Puerto)"
echo -e "  ${C_RED}[0]${NC} > CANCELAR"
line_bar
echo -ne "${C_CYAN}Opción [default 1]: ${NC}"
read -r DST_CH

TARGET_HOST="127.0.0.1"
TARGET_PORT="$SSH_P"

case "${DST_CH:-1}" in
    0) echo -e "${C_RED}Cancelado.${NC}"; sleep 1; exit 1 ;;
    5)
        echo -ne "${C_WHITE}IP Destino (default 127.0.0.1): ${NC}"
        read -r M_HOST
        [[ -n "$M_HOST" ]] && TARGET_HOST="$M_HOST"
        echo -ne "${C_WHITE}Puerto Destino (ej. 22, 90, 143): ${NC}"
        read -r M_PORT
        [[ "$M_PORT" =~ ^[0-9]+$ ]] && TARGET_PORT="$M_PORT"
        ;;
    *)
        if [[ "$DST_CH" =~ ^[0-9]+$ ]] && (( DST_CH >= 1 && DST_CH <= ${#_prt[@]} )); then
            TARGET_PORT="${_prt[$((DST_CH - 1))]}"
        fi
        ;;
esac

if [[ "$TARGET_PORT" == "$WS_PORT" ]]; then
    echo -e "\n${C_RED}[!] ERROR ANTI-BUCLE: Corrigiendo destino a 127.0.0.1:${SSH_P}${NC}"
    TARGET_HOST="127.0.0.1"
    TARGET_PORT="$SSH_P"
    sleep 1.5
fi

# ------------------------------------------------------------------------------
# DESPLIEGUE Y ARRANQUE
# ------------------------------------------------------------------------------
clear
line_bar
echo -e "${C_CYAN}             INSTALANDO Y ACTIVANDO WS-EPRO...${NC}"
line_bar

if ! ensure_wsepro_bin; then
    echo -e "${C_RED}✖ No se encontró ni pudo descargar el binario ws-epro.${NC}"
    read -n1 -r -p "Presione cualquier tecla para continuar..."
    exit 1
fi

RAM_MB=$(free -m 2>/dev/null | awk '/^Mem:/ {print $2+0}')
[[ -z "$RAM_MB" || "$RAM_MB" -eq 0 ]] && RAM_MB=1024
MEM_MAX="256M"
(( RAM_MB <= 1536 )) && MEM_MAX="128M"

# Limpiar servicio legacy ws-epro.service si existía
systemctl stop ws-epro.service "$SERVICE_NAME" 2>/dev/null || true
systemctl disable ws-epro.service 2>/dev/null || true
rm -f /etc/systemd/system/ws-epro.service 2>/dev/null || true
pkill -9 -x 'ws-epro' 2>/dev/null || true

cat > "$CONF_FILE" <<EOF_YML
# verbose level 0=info, 1=verbose, 2=very verbose
verbose: 0
listen:
- target_host: ${TARGET_HOST}
  target_port: ${TARGET_PORT}
  listen_port: ${WS_PORT}
EOF_YML

apply_mtu_bbr_tuning "$WS_PORT"

cat > "$SERVICE_FILE" <<EOF_SVC
[Unit]
Description=CRISDEV WS-ePro Service (ePro Dev Team + MTU 1280)
After=network-online.target nss-lookup.target ssh.service
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
WorkingDirectory=${CONF_DIR}
ExecStart=${BIN_DEST} -f ${CONF_FILE}
Restart=always
RestartSec=1
RestartPreventExitStatus=23
OOMScoreAdjust=-900
LimitNOFILE=65535
MemoryMax=${MEM_MAX}
TasksMax=128

[Install]
WantedBy=multi-user.target
EOF_SVC

systemctl daemon-reload
systemctl enable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
systemctl restart "$SERVICE_NAME" 2>/dev/null || true

if command -v ufw >/dev/null 2>&1; then
    ufw allow "${WS_PORT}/tcp" >/dev/null 2>&1 || true
fi
if command -v iptables >/dev/null 2>&1; then
    iptables -C INPUT -p tcp --dport "$WS_PORT" -j ACCEPT 2>/dev/null || \
    iptables -I INPUT -p tcp --dport "$WS_PORT" -j ACCEPT 2>/dev/null || true
fi

sleep 1.2
LIVE_PORT=$(ss -tlpn 2>/dev/null | grep '"ws-epro"' | awk '{print $4}' | awk -F: '{print $NF}' | sort -un | xargs || true)

echo ""
if [[ -n "$LIVE_PORT" ]]; then
    echo -e "${C_GREEN}✔ WS-EPRO ACTIVADO EXITOSAMENTE${NC}"
    echo -e "${C_WHITE}  • Puerto Activo : ${C_GREEN}${LIVE_PORT} (TCP)${NC}"
    echo -e "${C_WHITE}  • Destino Local : ${C_CYAN}${TARGET_HOST}:${TARGET_PORT}${NC}"
    echo -e "${C_WHITE}  • Config YAML   : ${C_YELLOW}${CONF_FILE}${NC}"
    echo -e "${C_WHITE}  • Blindaje      : ${C_GREEN}MTU 1280 (MSS 1220) + BBR + MemoryMax=${MEM_MAX}${NC}"
    echo ""
    echo -e "${C_YELLOW}[*] Prueba en vivo (127.0.0.1:${WS_PORT}):${NC}"
    curl -i -s -N --max-time 2 "http://127.0.0.1:${WS_PORT}/" | head -6 || true
else
    echo -e "${C_RED}✖ Error al iniciar WS-ePro. Últimos logs:${NC}"
    journalctl -u "$SERVICE_NAME" -n 12 --no-pager 2>/dev/null || true
    exit 1
fi
echo ""
read -n1 -r -p "Presione cualquier tecla para continuar..."
