#!/usr/bin/env bash
# ==============================================================================
# INSTALADOR COMPLETO — WEBSOCKET NATIVO EN C v3.0 (ANTI-DPI + MTU 1280 + CDN)
# Ubicación: proxy/wsnativo/instalar.sh
# ==============================================================================

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_DIR="/etc/crisdev"
CONF_FILE="${CONF_DIR}/ws-c.conf"
BIN_DEST="/usr/local/bin/wsproxy-c"
SRC_DEST="/usr/local/src/wsproxy-c.c"
SERVICE_NAME="crisdev-ws-c.service"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"

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

compile_wsproxy_c() {
    mkdir -p /usr/local/bin /usr/local/src
    if [[ -f "${SCRIPT_DIR}/wsproxy-c.c" ]]; then
        cp -af "${SCRIPT_DIR}/wsproxy-c.c" "$SRC_DEST"
    elif [[ -f "/opt/ssh-cris/proxy/wsnativo/wsproxy-c.c" ]]; then
        cp -af "/opt/ssh-cris/proxy/wsnativo/wsproxy-c.c" "$SRC_DEST"
    elif [[ -f "/opt/ssh-cris/wsproxy-c.c" ]]; then
        cp -af "/opt/ssh-cris/wsproxy-c.c" "$SRC_DEST"
    fi

    if ! command -v gcc >/dev/null 2>&1; then
        echo -e "${C_YELLOW}[*] Instalando gcc para compilar wsproxy-c v3.0...${NC}"
        DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || true
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq gcc >/dev/null 2>&1 || true
    fi

    if [[ -s "$SRC_DEST" ]] && command -v gcc >/dev/null 2>&1; then
        echo -e "${C_YELLOW}[*] Compilando wsproxy-c v3.0 nativo optimizado (-O3)...${NC}"
        if gcc -O3 -Wall -Wextra -o "${BIN_DEST}.new" "$SRC_DEST" 2>/tmp/wsproxy_c_build.log; then
            mv -f "${BIN_DEST}.new" "$BIN_DEST"
            chmod 755 "$BIN_DEST"
            echo -e "${C_GREEN}✔ Binario nativo wsproxy-c v3.0 compilado con éxito.${NC}"
            return 0
        else
            echo -e "${C_RED}✖ Error al compilar wsproxy-c.c:${NC}"
            tail -n 10 /tmp/wsproxy_c_build.log 2>/dev/null || true
            rm -f "${BIN_DEST}.new"
            return 1
        fi
    fi

    [[ -x "$BIN_DEST" ]] && return 0
    return 1
}

apply_anti_dpi_mtu_tuning() {
    echo -e "${C_YELLOW}[*] Aplicando optimización Anti-MTU (MTU=1280 / MSS=1220), BBR y Gaming/VoIP...${NC}"
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
        iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
        iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
        iptables -t mangle -C OUTPUT -p tcp --sport "${WS_PORT}" --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1220 2>/dev/null || \
        iptables -t mangle -A OUTPUT -p tcp --sport "${WS_PORT}" --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1220 2>/dev/null || true
    fi

    if [[ -d /etc/ssh ]]; then
        mkdir -p /etc/ssh/sshd_config.d 2>/dev/null || true
        cat > /etc/ssh/sshd_config.d/98-crisdev-tunnel.conf << 'EOF_SSH'
AllowTcpForwarding yes
GatewayPorts yes
PermitTunnel yes
Compression no
TCPKeepAlive yes
ClientAliveInterval 20
ClientAliveCountMax 4
MaxStartups 100:30:300
MaxSessions 200
UseDNS no
EOF_SSH
        if sshd -t 2>/dev/null; then
            systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || service ssh reload 2>/dev/null || true
        else
            rm -f /etc/ssh/sshd_config.d/98-crisdev-tunnel.conf 2>/dev/null || true
        fi
    fi
}

clear
echo -e "${C_BLUE_BG}   ACTIVAR WEBSOCKET NATIVO EN C v3.0 (ANTI-DPI + MTU 1280)   ${NC}\n"
echo -e "${C_YELLOW}• Motor C epoll puro (< 5 MB RAM · 16,000 conexiones · 0 ms latencia)${NC}"
echo -e "${C_YELLOW}• Evasión DPI L7 (MSS 1220 / Separación HTTP->SSH / Fragmentación SS+H-2.0)${NC}"
echo -e "${C_YELLOW}• Filtro Universal Payloads (Ofuscados, [lf][lf], [split], CDN RFC 6455)${NC}\n"

# ------------------------------------------------------------------------------
# PASO 1: PUERTO DE ESCUCHA
# ------------------------------------------------------------------------------
line_bar
echo -e "${C_GREEN}[PASO 1/5] PUERTO DE ESCUCHA WEBSOCKET NATIVO C${NC}"
line_bar
echo -ne "${C_WHITE}¿Qué puerto desea utilizar? (default 80): ${NC}"
read -r WS_PORT
[[ -z "$WS_PORT" || ! "$WS_PORT" =~ ^[0-9]+$ ]] && WS_PORT="80"

OCCUPIED=$(ss -tlpn 2>/dev/null | grep -E "[:.]${WS_PORT}[[:space:]]" || true)
if [[ -n "$OCCUPIED" ]]; then
    echo -e "\n${C_YELLOW}[!] El puerto ${WS_PORT} está siendo usado actualmente:${NC}"
    echo -e "    ${OCCUPIED}"
    echo -ne "${C_YELLOW}¿Desea liberar el puerto ${WS_PORT} para WebSocket Nativo C? [s/N]: ${NC}"
    read -r FREE_OPT
    if [[ ! "$FREE_OPT" =~ ^[sSyY]$ ]]; then
        echo -e "${C_RED}Instalación cancelada por el usuario.${NC}"
        sleep 1.5
        exit 1
    fi
    if echo "$OCCUPIED" | grep -q 'python'; then
        systemctl stop crisdev-ws-python.service 2>/dev/null || true
        systemctl disable crisdev-ws-python.service 2>/dev/null || true
        pkill -9 -f 'wsproxy\.py' 2>/dev/null || true
        pkill -9 -f "/etc/SSHPlus/proxy\.py.*${WS_PORT}" 2>/dev/null || true
    fi
    if echo "$OCCUPIED" | grep -q 'wsproxy-c'; then
        bash "${SCRIPT_DIR}/desinstalar.sh" >/dev/null 2>&1 || true
    fi
    fuser -k "${WS_PORT}/tcp" >/dev/null 2>&1 || true
    sleep 1
fi

# ------------------------------------------------------------------------------
# PASO 2: DESTINO DE REDIRECCIÓN LOCAL
# ------------------------------------------------------------------------------
clear
line_bar
echo -e "${C_CYAN}         CONFIGURAR WEBSOCKET NATIVO C (REDIRECCIÓN LOCAL)${NC}"
line_bar
echo -e "${C_GREEN}[PASO 2/5] PUERTO ESCUCHA:${NC} ${C_WHITE}${WS_PORT}${NC}"
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

# Protección Anti-Bucle
if [[ "$TARGET_PORT" == "$WS_PORT" ]]; then
    echo -e "\n${C_RED}[!] ERROR ANTI-BUCLE: El destino no puede ser el mismo puerto de escucha (${WS_PORT}).${NC}"
    echo -e "${C_YELLOW}[*] Corrigiendo destino automáticamente a OpenSSH local: 127.0.0.1:${SSH_P}${NC}"
    TARGET_HOST="127.0.0.1"
    TARGET_PORT="$SSH_P"
    sleep 2
fi

# ------------------------------------------------------------------------------
# PASO 3: MODO HTTP
# ------------------------------------------------------------------------------
clear
line_bar
echo -e "${C_CYAN}         CONFIGURAR WEBSOCKET NATIVO C (MODO HTTP)${NC}"
line_bar
echo -e "${C_GREEN}[PASO 3/5] MODO DE RESPUESTA HTTP (ANTI-DPI & CDN)${NC}\n"
echo -e "  ${C_GREEN}[auto]${NC} INTELIGENTE         ${C_YELLOW}(RECOMENDADO: 101 a CDN/WS + 200 limpio a Payloads Directos)${NC}"
echo -e "  ${C_GREEN}[101]${NC}  Switching Protocols ${C_YELLOW}(Forzado 101 para Cloudflare / CloudFront / WS)${NC}"
echo -e "  ${C_GREEN}[200]${NC}  HTTP OK Limpio      ${C_YELLOW}(Forzado 200 sin Content-Length: 0 para Payloads Directos)${NC}\n"
echo -ne "${C_WHITE}Ingresa modo de respuesta [auto / 101 / 200] (default auto): ${NC}"
read -r HTTP_CODE
[[ -z "$HTTP_CODE" ]] && HTTP_CODE="auto"
if [[ "$HTTP_CODE" != "auto" && "$HTTP_CODE" != "101" && "$HTTP_CODE" != "200" && ! "$HTTP_CODE" =~ ^[0-9]{3}$ ]]; then
    HTTP_CODE="auto"
fi

# ------------------------------------------------------------------------------
# PASO 4: MINIBANNER / MENSAJE DE ESTADO
# ------------------------------------------------------------------------------
echo ""
line_bar
echo -e "${C_GREEN}[PASO 4/5] MINIBANNER / MENSAJE DE ESTADO${NC}"
echo -ne "${C_WHITE}Ingresa tu minibanner (default: HTTP CONEXION): ${NC}"
read -r RAW_BANNER
[[ -z "$RAW_BANNER" ]] && RAW_BANNER="HTTP CONEXION"

# ------------------------------------------------------------------------------
# PASO 5: PALETA DE COLOR HTML
# ------------------------------------------------------------------------------
echo ""
line_bar
echo -e "${C_GREEN}[PASO 5/5] SELECCIONE EL COLOR HTML PARA EL MINIBANNER${NC}"
line_bar
echo -e "  ${C_CYAN}[01]${NC} AZUL (#2979FF)       ${C_CYAN}[06]${NC} CYAN (#00E5FF)"
echo -e "  ${C_CYAN}[02]${NC} VERDE (#00E676)      ${C_CYAN}[07]${NC} NARANJA (#FF9100)"
echo -e "  ${C_CYAN}[03]${NC} ROJO (#FF1744)       ${C_CYAN}[08]${NC} PÚRPURA (#D500F9)"
echo -e "  ${C_CYAN}[04]${NC} AMARILLO (#FFD600)   ${C_CYAN}[09]${NC} NEGRO (#000000)"
echo -e "  ${C_CYAN}[05]${NC} ROSA (#F535AA)       ${C_CYAN}[10]${NC} SIN COLOR (Texto Plano)"
line_bar
echo -ne "${C_WHITE}¿Qué color desea? [1-10] (default 06): ${NC}"
read -r COR_OPT

HTML_COLOR="cyan"
case "${COR_OPT:-6}" in
    1|01) HTML_COLOR="blue" ;;
    2|02) HTML_COLOR="green" ;;
    3|03) HTML_COLOR="red" ;;
    4|04) HTML_COLOR="yellow" ;;
    5|05) HTML_COLOR="#F535AA" ;;
    6|06) HTML_COLOR="cyan" ;;
    7|07) HTML_COLOR="#FF9100" ;;
    8|08) HTML_COLOR="#D500F9" ;;
    9|09) HTML_COLOR="black" ;;
    10)   HTML_COLOR="none" ;;
    *)    HTML_COLOR="cyan" ;;
esac

if [[ "$HTML_COLOR" != "none" ]]; then
    FULL_BANNER="<font color=\"${HTML_COLOR}\"><b>${RAW_BANNER}</b></font>"
else
    FULL_BANNER="${RAW_BANNER}"
fi

# ------------------------------------------------------------------------------
# COMPILACIÓN, AUTO-CALIBRACIÓN RAM, HARDENING Y ARRANQUE
# ------------------------------------------------------------------------------
clear
line_bar
echo -e "${C_CYAN}     COMPILANDO E INSTALANDO WEBSOCKET NATIVO C v3.0...${NC}"
line_bar

RAM_MB=$(free -m 2>/dev/null | awk '/^Mem:/ {print $2+0}')
[[ -z "$RAM_MB" || "$RAM_MB" -eq 0 ]] && RAM_MB=1024

if (( RAM_MB <= 1536 )); then
    MAX_CONNS=4096
    MEM_MAX="128M"
    CPU_QUOTA="70%"
    RAM_PROFILE="VPS 1 GB RAM (4096 conns · Anti-OOM)"
else
    MAX_CONNS=16384
    MEM_MAX="256M"
    CPU_QUOTA="85%"
    RAM_PROFILE="VPS 2+ GB RAM (16384 conns · Máximo Rendimiento)"
fi

if ! compile_wsproxy_c; then
    echo -e "${C_RED}✖ Falló la compilación de wsproxy-c v3.0.${NC}"
    read -n1 -r -p "Presione cualquier tecla para continuar..."
    exit 1
fi

# Limpiar servicios legacy previos antes de crear crisdev-ws-c.service
for _svc in sshplus-ws.service wsproxy-c.service ws-c.service websocket.service wsproxy.service; do
    systemctl stop "$_svc" 2>/dev/null || true
    systemctl disable "$_svc" 2>/dev/null || true
    rm -f "/etc/systemd/system/${_svc}" 2>/dev/null || true
done
systemctl stop "$SERVICE_NAME" 2>/dev/null || true
pkill -9 -x 'wsproxy-c' 2>/dev/null || true

mkdir -p "$CONF_DIR"
cat > "$CONF_FILE" <<EOF_CCONF
LISTEN_ADDR=0.0.0.0
LISTEN_PORT=${WS_PORT}
TARGET_HOST=${TARGET_HOST}
TARGET_PORT=${TARGET_PORT}
HTTP_STATUS=${HTTP_CODE}
BANNER_MSG='${FULL_BANNER}'
BANNER_RAW='${RAW_BANNER}'
BANNER_COLOR='${HTML_COLOR}'
IDLE_TIMEOUT=0
MAX_CONNS=${MAX_CONNS}
EOF_CCONF

apply_anti_dpi_mtu_tuning

cat > "$SERVICE_FILE" <<EOF_SVC
[Unit]
Description=CRISDEV Native epoll WebSocket Proxy v3.0 (Anti-DPI + MTU 1280 · ${RAM_PROFILE})
After=network-online.target ssh.service
Wants=network-online.target ssh.service
StartLimitIntervalSec=0

[Service]
Type=simple
User=root
EnvironmentFile=-${CONF_FILE}
ExecStart=/bin/sh -c 'exec ${BIN_DEST} --bind "\${LISTEN_ADDR:-0.0.0.0}" --port "\${LISTEN_PORT:-${WS_PORT}}" --target "\${TARGET_HOST:-${TARGET_HOST}}:\${TARGET_PORT:-${TARGET_PORT}}" --status "\${HTTP_STATUS:-${HTTP_CODE}}" --idle "\${IDLE_TIMEOUT:-0}" --max-conns "\${MAX_CONNS:-${MAX_CONNS}}" \${BANNER_MSG:+--msg "\$BANNER_MSG"}'
Restart=always
RestartSec=1
OOMScoreAdjust=-900
LimitNOFILE=65535
MemoryMax=${MEM_MAX}
CPUQuota=${CPU_QUOTA}
TasksMax=64

[Install]
WantedBy=multi-user.target
EOF_SVC

# Instalar Watchdog seguro (solo monitorea si crisdev-ws-c.service está habilitado)
if [[ -f "${SCRIPT_DIR}/watchdog.sh" ]]; then
    chmod +x "${SCRIPT_DIR}/watchdog.sh"
    echo "*/2 * * * * root /opt/ssh-cris/proxy/wsnativo/watchdog.sh >/dev/null 2>&1" > /etc/cron.d/crisdev-ws-c-watchdog
    chmod 644 /etc/cron.d/crisdev-ws-c-watchdog
fi

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
LIVE_PORT=$(ss -tlpn 2>/dev/null | grep '"wsproxy-c"' | awk '{print $4}' | awk -F: '{print $NF}' | sort -un | xargs || true)

echo ""
if [[ -n "$LIVE_PORT" ]]; then
    echo -e "${C_GREEN}✔ WEBSOCKET NATIVO EN C v3.0 ACTIVADO EXITOSAMENTE${NC}"
    echo -e "${C_WHITE}  • Puerto Activo  : ${C_GREEN}${LIVE_PORT} (TCP)${NC}"
    echo -e "${C_WHITE}  • Destino Local  : ${C_CYAN}${TARGET_HOST}:${TARGET_PORT}${NC}"
    echo -e "${C_WHITE}  • Modo HTTP      : ${C_GREEN}${HTTP_CODE}${NC}"
    echo -e "${C_WHITE}  • Perfil RAM     : ${C_CYAN}${RAM_PROFILE}${NC}"
    echo -e "${C_WHITE}  • Estabilidad    : ${C_GREEN}Anti-DPI + MTU 1280 (MSS 1220) + Watchdog 2m${NC}"
    echo ""
    echo -e "${C_YELLOW}[*] Prueba en vivo de respuesta HTTP (127.0.0.1:${WS_PORT}):${NC}"
    curl -i -s -N --max-time 2 "http://127.0.0.1:${WS_PORT}/" | head -6 || true
else
    echo -e "${C_RED}✖ Error al iniciar WebSocket Nativo C v3.0. Últimos logs:${NC}"
    journalctl -u "$SERVICE_NAME" -n 12 --no-pager 2>/dev/null || true
    exit 1
fi
echo ""
read -n1 -r -p "Presione cualquier tecla para continuar..."
