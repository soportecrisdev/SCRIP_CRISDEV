#!/usr/bin/env bash
# ==============================================================================
# INSTALADOR PROFESIONAL — HCR RELAY (HTTP CUSTOM RELAY + HARDENING 1GB RAM)
# Flags optimizados: --max-download-frame 2000 --download-poll-timeout 5s
# Ubicación: proxy/hcr/instalar.sh
# ==============================================================================

set -u

CONF_DIR="/etc/crisdev/hcr"
BIN_DEST="/usr/local/bin/hcr-server"
SERVICE_NAME="crisdev-hcr.service"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"
REPO_RAW="https://raw.githubusercontent.com/soportecrisdev/SCRIP_CRISDEV/main"

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

ensure_hcr_bin() {
    mkdir -p /usr/local/bin "$CONF_DIR"
    if [[ -s /opt/ssh-cris/hcr-server ]]; then
        cp -af /opt/ssh-cris/hcr-server "$BIN_DEST"
    elif [[ ! -x "$BIN_DEST" ]]; then
        echo -e "${C_YELLOW}[*] Descargando binario hcr-server...${NC}"
        curl -fsSL "${REPO_RAW}/hcr-server" -o "$BIN_DEST" 2>/dev/null || \
        wget -q "${REPO_RAW}/hcr-server" -O "$BIN_DEST" 2>/dev/null || true
    fi
    chmod 755 "$BIN_DEST" 2>/dev/null || true
    [[ -x "$BIN_DEST" ]]
}

clear
echo -e "${C_BLUE_BG}       ACTIVAR HCR RELAY (HTTP CUSTOM RELAY · PLAIN / TLS)       ${NC}\n"
echo -e "${C_YELLOW}• Flags anti-congelamiento móvil: --max-download-frame 2000 --download-poll-timeout 5s${NC}"
echo -e "${C_YELLOW}• Hardening systemd + protección 1GB RAM (MemoryMax + MTU 1280)${NC}\n"

# PASO 1: Puerto HCR
line_bar
echo -e "${C_GREEN}[PASO 1/3] PUERTO DE ESCUCHA HCR RELAY${NC}"
line_bar
echo -ne "${C_WHITE}¿Qué puerto desea utilizar? (default 8090): ${NC}"
read -r HCR_PORT
[[ -z "$HCR_PORT" || ! "$HCR_PORT" =~ ^[0-9]+$ ]] && HCR_PORT="8090"

if ss -tlpn 2>/dev/null | grep -qE "[:.]${HCR_PORT}[[:space:]]"; then
    echo -e "\n${C_YELLOW}[!] El puerto ${HCR_PORT} está ocupado.${NC}"
    echo -ne "${C_YELLOW}¿Desea detener el proceso anterior en el puerto ${HCR_PORT}? [s/N]: ${NC}"
    read -r FREE_OPT
    if [[ ! "$FREE_OPT" =~ ^[sSyY]$ ]]; then
        echo -e "${C_RED}Cancelado.${NC}"; sleep 1.5; exit 1
    fi
    systemctl stop "$SERVICE_NAME" hcr.service 2>/dev/null || true
    pkill -9 -x 'hcr-server' 2>/dev/null || true
    fuser -k "${HCR_PORT}/tcp" >/dev/null 2>&1 || true
    sleep 1
fi

# PASO 2: Destino SSH Local
echo ""
line_bar
echo -e "${C_GREEN}[PASO 2/3] PUERTO DESTINO SSH LOCAL${NC}"
line_bar
SSH_P=$(grep -E '^Port ' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1 || true)
[[ -z "$SSH_P" ]] && SSH_P="22"
echo -e "  ${C_GREEN}[1]${NC} OpenSSH Directo (${SSH_P}) [Recomendado]"
echo -e "  ${C_GREEN}[2]${NC} Dropbear (90 / 110)"
echo -e "  ${C_GREEN}[3]${NC} Puerto manual"
echo -ne "${C_WHITE}Seleccione destino [1-3] (default 1): ${NC}"
read -r DST_OPT
TARGET_PORT="$SSH_P"
case "${DST_OPT:-1}" in
    2) TARGET_PORT="90" ;;
    3)
        echo -ne "${C_WHITE}Puerto destino local: ${NC}"
        read -r M_P
        [[ "$M_P" =~ ^[0-9]+$ ]] && TARGET_PORT="$M_P"
        ;;
esac

if [[ "$TARGET_PORT" == "$HCR_PORT" ]]; then
    echo -e "${C_RED}[!] Anti-Bucle: corrigiendo destino a 127.0.0.1:${SSH_P}${NC}"
    TARGET_PORT="$SSH_P"
fi

# PASO 3: Transporte Plain vs TLS
echo ""
line_bar
echo -e "${C_GREEN}[PASO 3/3] MODO DE TRANSPORTE HCR${NC}"
line_bar
echo -e "  ${C_GREEN}[1]${NC} PLAIN (HTTP directo — Recomendado para puerto 80 / 8090)"
echo -e "  ${C_GREEN}[2]${NC} TLS   (SSL/TLS con certificado automático — Recomendado 443 / 8443)"
echo -ne "${C_WHITE}Seleccione transporte [1-2] (default 1): ${NC}"
read -r TR_OPT

TRANSPORT="plain"
TLS_ARGS=""
if [[ "$TR_OPT" == "2" ]]; then
    TRANSPORT="tls"
    mkdir -p "$CONF_DIR"
    if [[ ! -s "${CONF_DIR}/cert.pem" || ! -s "${CONF_DIR}/key.pem" ]]; then
        echo -e "${C_YELLOW}[*] Generando certificado TLS autofirmado en ${CONF_DIR}...${NC}"
        openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
            -keyout "${CONF_DIR}/key.pem" -out "${CONF_DIR}/cert.pem" \
            -subj "/CN=crisdev-hcr" >/dev/null 2>&1 || true
    fi
    TLS_ARGS="--tls-cert ${CONF_DIR}/cert.pem --tls-key ${CONF_DIR}/key.pem"
fi

if ! ensure_hcr_bin; then
    echo -e "${C_RED}✖ No se pudo obtener el binario hcr-server.${NC}"
    read -n1 -r -p "Presione cualquier tecla para continuar..."
    exit 1
fi

RAM_MB=$(free -m 2>/dev/null | awk '/^Mem:/ {print $2+0}')
[[ -z "$RAM_MB" || "$RAM_MB" -eq 0 ]] && RAM_MB=1024
MEM_MAX="384M"
(( RAM_MB <= 1536 )) && MEM_MAX="192M"

# Limpiar servicios legacy hcr.service / hcr-*.service
for _old in /etc/systemd/system/hcr.service /etc/systemd/system/hcr-*.service; do
    [[ -f "$_old" ]] || continue
    _oname=$(basename "$_old")
    systemctl stop "$_oname" 2>/dev/null || true
    systemctl disable "$_oname" 2>/dev/null || true
    rm -f "$_old" 2>/dev/null || true
done
systemctl stop "$SERVICE_NAME" 2>/dev/null || true
pkill -9 -x 'hcr-server' 2>/dev/null || true

cat > "$SERVICE_FILE" <<EOF_SVC
[Unit]
Description=CRISDEV HCR Relay Service (Port ${HCR_PORT} · ${TRANSPORT})
After=network-online.target ssh.service sshd.service dropbear.service
Wants=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=exec
User=root
Group=root
WorkingDirectory=${CONF_DIR}
ExecStart=${BIN_DEST} --listen :${HCR_PORT} --target 127.0.0.1:${TARGET_PORT} --transport ${TRANSPORT} ${TLS_ARGS} --max-download-frame 2000 --download-poll-timeout 5s
Restart=on-failure
RestartSec=3s
TimeoutStopSec=15s
KillSignal=SIGTERM
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadOnlyPaths=${CONF_DIR}
OOMScoreAdjust=-800
LimitNOFILE=8192
TasksMax=512
MemoryMax=${MEM_MAX}
StandardOutput=journal
StandardError=journal
SyslogIdentifier=hcr-server

[Install]
WantedBy=multi-user.target
EOF_SVC

systemctl daemon-reload
systemctl enable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
systemctl restart "$SERVICE_NAME" 2>/dev/null || true

if command -v ufw >/dev/null 2>&1; then
    ufw allow "${HCR_PORT}/tcp" >/dev/null 2>&1 || true
fi
if command -v iptables >/dev/null 2>&1; then
    iptables -C INPUT -p tcp --dport "$HCR_PORT" -j ACCEPT 2>/dev/null || \
    iptables -I INPUT -p tcp --dport "$HCR_PORT" -j ACCEPT 2>/dev/null || true
    iptables -t mangle -C OUTPUT -p tcp --sport "${HCR_PORT}" --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1220 2>/dev/null || \
    iptables -t mangle -A OUTPUT -p tcp --sport "${HCR_PORT}" --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1220 2>/dev/null || true
fi

sleep 1.2
LIVE_PORT=$(ss -tlpn 2>/dev/null | grep '"hcr-server"' | awk '{print $4}' | awk -F: '{print $NF}' | sort -un | xargs || true)
echo ""
if [[ -n "$LIVE_PORT" ]]; then
    echo -e "${C_GREEN}✔ HCR RELAY ACTIVADO EXITOSAMENTE${NC}"
    echo -e "${C_WHITE}  • Puerto Activo : ${C_GREEN}${LIVE_PORT} (TCP · ${TRANSPORT^^})${NC}"
    echo -e "${C_WHITE}  • Destino SSH   : ${C_CYAN}127.0.0.1:${TARGET_PORT}${NC}"
    echo -e "${C_WHITE}  • Estabilidad   : ${C_GREEN}frame=2000 · poll=5s · MSS=1220 · MemoryMax=${MEM_MAX}${NC}"
else
    echo -e "${C_RED}✖ Error al iniciar HCR Relay. Últimos logs:${NC}"
    journalctl -u "$SERVICE_NAME" -n 12 --no-pager 2>/dev/null || true
    exit 1
fi
echo ""
read -n1 -r -p "Presione cualquier tecla para continuar..."
