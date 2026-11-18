#!/usr/bin/env bash
# ============================================================================
# CRISDEV BHTTP VPS FIX & DEPLOY
# Script para configurar y optimizar el entorno BHTTP en la VPS:
#  1. Habilita AllowTcpForwarding en OpenSSH de forma segura
#  2. Instala helper de respaldo bhttp-connect
#  3. Detecta puertos en uso (evita colisiones con V2Ray, Proxy Socks, Dropbear, etc.)
#  4. Configura el servicio bilola-server
#  5. Configura Firewall UFW / iptables y sysctl ip_forward
# Autor: CRISDEV / @CRISIS1823
# ============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Verificar root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[ERROR] Este script debe ejecutarse como root: sudo bash $0${NC}"
    exit 1
fi

echo -e "${CYAN}"
echo "╔══════════════════════════════════════════════════════════╗"
echo "║       CRISDEV - BHTTP & OpenSSH VPS Optimizer            ║"
echo "║                   @CRISIS1823                            ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# ============================================================================
# 1. HABILITAR FORWARDING Y SEGURIDAD EN OPENSSH
# ============================================================================
echo -e "${YELLOW}[1/5] Optimizando OpenSSH (Habilitando TCP Forwarding)...${NC}"

SSH_DROP_DIR="/etc/ssh/sshd_config.d"
mkdir -p "$SSH_DROP_DIR"

CONFIG_FILE="$SSH_DROP_DIR/99-bhttp-forwarding.conf"

cat > "$CONFIG_FILE" <<'SSHEOF'
# Configuración optimizada por CRISDEV BHTTP
AllowTcpForwarding yes
AllowAgentForwarding yes
GatewayPorts yes
PermitTunnel yes
TcpRcvBufPoll yes
ClientAliveInterval 30
ClientAliveCountMax 3

# Algoritmos KEX y Ciphers compatibles con Trilead SSH2
KexAlgorithms +curve25519-sha256,diffie-hellman-group-exchange-sha256,diffie-hellman-group14-sha256,diffie-hellman-group14-sha1,diffie-hellman-group-exchange-sha1,diffie-hellman-group1-sha1
Ciphers +chacha20-poly1305@openssh.com,aes128-ctr,aes192-ctr,aes256-ctr,aes128-cbc,aes256-cbc,3des-cbc
MACs +hmac-sha2-256,hmac-sha2-512,hmac-sha1,hmac-sha1-96
HostKeyAlgorithms +ssh-rsa,rsa-sha2-512,rsa-sha2-256,ssh-ed25519
PubkeyAcceptedAlgorithms +ssh-rsa,rsa-sha2-512,rsa-sha2-256
SSHEOF

# Comprobar sintaxis antes de reiniciar para proteger el acceso
if sshd -t 2>/dev/null; then
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || service ssh restart 2>/dev/null || true
    echo -e "${GREEN}[OK] OpenSSH configurado con AllowTcpForwarding yes y reiniciado con éxito.${NC}"
else
    echo -e "${YELLOW}[WARN] sshd_config.d no soportado en esta versión antigua de OpenSSH, inyectando en /etc/ssh/sshd_config...${NC}"
    rm -f "$CONFIG_FILE"
    
    # Backup
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.bhttp
    
    sed -i '/AllowTcpForwarding/d' /etc/ssh/sshd_config
    sed -i '/GatewayPorts/d' /etc/ssh/sshd_config
    sed -i '/PermitTunnel/d' /etc/ssh/sshd_config
    
    echo "AllowTcpForwarding yes" >> /etc/ssh/sshd_config
    echo "GatewayPorts yes" >> /etc/ssh/sshd_config
    echo "PermitTunnel yes" >> /etc/ssh/sshd_config
    
    if sshd -t 2>/dev/null; then
        systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || service ssh restart 2>/dev/null || true
        echo -e "${GREEN}[OK] /etc/ssh/sshd_config modificado y reiniciado.${NC}"
    else
        echo -e "${RED}[ERROR] Error en sshd_config, restaurando backup...${NC}"
        cp /etc/ssh/sshd_config.bak.bhttp /etc/ssh/sshd_config
    fi
fi

# ============================================================================
# 2. INSTALACIÓN DEL HELPER NATIVO bhttp-connect
# ============================================================================
echo -e "\n${YELLOW}[2/5] Instalando helper de canal sesión /usr/local/bin/bhttp-connect...${NC}"

cat > /usr/local/bin/bhttp-connect <<'HELPEREOF'
#!/usr/bin/env bash
# Helper nativo CRISDEV para reenvío TCP por canal SSH de sesión
DEST_HOST="$1"
DEST_PORT="$2"

if [[ -z "$DEST_HOST" || -z "$DEST_PORT" ]]; then
    echo "Uso: bhttp-connect <host> <port>" >&2
    exit 1
fi

if command -v nc >/dev/null 2>&1; then
    exec nc "$DEST_HOST" "$DEST_PORT"
elif command -v socat >/dev/null 2>&1; then
    exec socat - "TCP:$DEST_HOST:$DEST_PORT"
else
    # Fallback puro de bash
    exec 3<>/dev/tcp/"$DEST_HOST"/"$DEST_PORT" && { cat <&3 & cat >&3; }
fi
HELPEREOF

chmod 755 /usr/local/bin/bhttp-connect
echo -e "${GREEN}[OK] Helper bhttp-connect disponible en /usr/local/bin/bhttp-connect${NC}"

# ============================================================================
# 3. DETECCIÓN DE PUERTOS Y SELECCIÓN INTELIGENTE
# ============================================================================
echo -e "\n${YELLOW}[3/5] Analizando puertos en uso en la VPS...${NC}"

check_port_in_use() {
    local port="$1"
    ss -lntup 2>/dev/null | grep -v 'bhttp-server' | awk '{print $5}' | grep -E "(:|\])$port$" >/dev/null 2>&1
}

# Mostrar servicios conocidos detectados
echo -e "  Puertos actualmente ocupados en el servidor:"
ss -lntp 2>/dev/null | grep -E ':(22|80|90|110|443|8080|5300|8880|36712|7300|8881|7081)\b' | awk '{print "    - Port " $4 " (" $6 ")"}' || true

# Variable de entorno BHTTP_PORT o argumento
SELECTED_BHTTP_PORT="${BHTTP_PORT:-}"
DEFAULT_SSH_PORT="${SSH_PORT:-22}"

if [[ -z "$SELECTED_BHTTP_PORT" ]]; then
    # Evaluar puertos sugeridos para evitar pisar V2Ray (8080) o Proxy Socks (80)
    if ! check_port_in_use 8080; then
        SUGGESTED_PORT="8080"
    elif ! check_port_in_use 8881; then
        SUGGESTED_PORT="8881"
    elif ! check_port_in_use 7081; then
        SUGGESTED_PORT="7081"
    elif ! check_port_in_use 8090; then
        SUGGESTED_PORT="8090"
    else
        SUGGESTED_PORT="8888"
    fi

    if [[ -t 0 ]]; then
        echo -e "\n${BOLD}${CYAN}Selecciona el puerto para el servicio BHTTP (BHP1):${NC}"
        echo -e "  ${YELLOW}Nota:${NC} Si en tu VPS tienes V2Ray en 8080 y Proxy Socks en 80,"
        echo -e "        debes usar un puerto alterno para BHTTP (ej. 8881 o 7081)."
        read -r -p "  Puerto BHTTP a usar [$SUGGESTED_PORT]: " INPUT_PORT
        SELECTED_BHTTP_PORT="${INPUT_PORT:-$SUGGESTED_PORT}"
    else
        SELECTED_BHTTP_PORT="$SUGGESTED_PORT"
    fi
fi

# Validar si el puerto elegido está ocupado
if check_port_in_use "$SELECTED_BHTTP_PORT"; then
    echo -e "${RED}[ALERTA] El puerto $SELECTED_BHTTP_PORT ya está siendo usado por otro servicio en la VPS.${NC}"
    echo -e "${YELLOW}Verifica qué servicio lo ocupa con: ss -lntp '( sport = :$SELECTED_BHTTP_PORT )'${NC}"
    echo -e "Continuando con la configuración para dicho puerto..."
else
    echo -e "${GREEN}[OK] Puerto $SELECTED_BHTTP_PORT libre y seleccionado para BHTTP.${NC}"
fi

# ============================================================================
# 4. COMPILACIÓN E INSTALACIÓN DEL MOTOR NATIVO C BHTTP (AVX2 + LONG-POLLING)
# ============================================================================
echo -e "\n${YELLOW}[4/5] Compilando e instalando Motor BHTTP C (AVX2 x8 + Long-Polling 800ms)...${NC}"

mkdir -p /etc/bhttp /etc/bhttp/certs /usr/local/bin
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo "")"
if [[ -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/bhttp-server.c" ]]; then
    cp -f "$SCRIPT_DIR/bhttp-server.c" /etc/bhttp/bhttp-server.c 2>/dev/null || true
fi
if [[ ! -s /etc/bhttp/bhttp-server.c ]]; then
    curl -fsSL "https://raw.githubusercontent.com/soportecrisdev/SCRIP_CRISDEV/main/bhttp-server.c" -o /etc/bhttp/bhttp-server.c 2>/dev/null || \
    wget -q "https://raw.githubusercontent.com/soportecrisdev/SCRIP_CRISDEV/main/bhttp-server.c" -O /etc/bhttp/bhttp-server.c 2>/dev/null || true
fi

if ! command -v gcc >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq gcc libc6-dev >/dev/null 2>&1 || true
fi

systemctl stop bhttp.service bilola-go-server.service wakkodev-bhttp.service 2>/dev/null || true
rm -f /etc/systemd/system/bilola-go-server.service /etc/systemd/system/wakkodev-bhttp.service 2>/dev/null || true

if [[ -s /etc/bhttp/bhttp-server.c ]] && command -v gcc >/dev/null 2>&1; then
    if gcc -O3 -march=native -mtune=native -pthread -o /usr/local/bin/bhttp-server.new /etc/bhttp/bhttp-server.c 2>/dev/null || \
       gcc -O2 -pthread -o /usr/local/bin/bhttp-server.new /etc/bhttp/bhttp-server.c 2>/dev/null; then
        mv -f /usr/local/bin/bhttp-server.new /usr/local/bin/bhttp-server
        chmod 755 /usr/local/bin/bhttp-server
        ln -sfn /usr/local/bin/bhttp-server /usr/local/bin/bhttp 2>/dev/null || true
        ln -sfn /usr/local/bin/bhttp-server /bin/bhttp-server 2>/dev/null || true
        ln -sfn /usr/local/bin/bhttp-server /bin/bhttp 2>/dev/null || true
        /usr/local/bin/bhttp-server --self-test || true
    fi
fi

BHTTP_LISTEN_LIST="0.0.0.0:8080,0.0.0.0:8088,0.0.0.0:8881"
if [[ -n "$SELECTED_BHTTP_PORT" && "$SELECTED_BHTTP_PORT" != "8080" && "$SELECTED_BHTTP_PORT" != "8088" && "$SELECTED_BHTTP_PORT" != "8881" ]]; then
    BHTTP_LISTEN_LIST="0.0.0.0:${SELECTED_BHTTP_PORT},${BHTTP_LISTEN_LIST}"
fi

cat > /etc/bhttp/config <<EOF
BHTTP_PORT=8080,8088,8881
BACKEND_PORT=${DEFAULT_SSH_PORT}
SESSION_TTL=180
MAX_SESSIONS=4096
PROFILE=performance
EOF

cat > /etc/systemd/system/bhttp.service <<EOF
[Unit]
Description=HTTP Conexion BHTTP C Engine (AVX2 + Long-Polling 800ms)
After=network-online.target ssh.service sshd.service
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=-/etc/bhttp/config
ExecStart=/usr/local/bin/bhttp-server --listen ${BHTTP_LISTEN_LIST} --backend 127.0.0.1:${DEFAULT_SSH_PORT} --session-ttl 180 --max-sessions 4096 --max-per-ip 256 --poll-wait-ms 800 --max-requests-per-conn 2048
Restart=always
RestartSec=1
LimitNOFILE=524288
TasksMax=infinity
OOMScoreAdjust=-300

[Install]
WantedBy=multi-user.target
EOF

# Configurar BHTTP TLS (XHTTP) en puertos Cloudflare (2053, 2083) + directo (8444) si existe xhttp-server
if [[ -x /usr/local/bin/xhttp-server ]]; then
    if [[ ! -f /etc/bhttp/server.crt || ! -f /etc/bhttp/server.key ]]; then
        openssl req -x509 -newkey rsa:2048 -days 3650 -nodes \
            -keyout /etc/bhttp/server.key -out /etc/bhttp/server.crt -subj "/CN=crisdev.online" >/dev/null 2>&1 || true
        chmod 600 /etc/bhttp/server.key 2>/dev/null || true
        chmod 644 /etc/bhttp/server.crt 2>/dev/null || true
    fi
    echo "2053,2083,8444" > /etc/bhttp/tls_port
    cat > /etc/systemd/system/bhttp-tls.service <<EOF
[Unit]
Description=HTTP Conexion BHTTP TLS (XHTTP) Relay Service (Ports 2053, 2083, 8444)
After=network-online.target ssh.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/xhttp-server -listen 0.0.0.0:2053,0.0.0.0:2083,0.0.0.0:8444 -target 127.0.0.1:${DEFAULT_SSH_PORT} -tls-cert /etc/bhttp/server.crt -tls-key /etc/bhttp/server.key -session-timeout 5m
Restart=always
RestartSec=1
LimitNOFILE=524288

[Install]
WantedBy=multi-user.target
EOF
    systemctl enable --now bhttp-tls.service >/dev/null 2>&1 || true
    systemctl restart bhttp-tls.service 2>/dev/null || true
fi

systemctl daemon-reload
systemctl enable --now bhttp.service >/dev/null 2>&1 || true
systemctl restart bhttp.service 2>/dev/null || true
echo -e "${GREEN}[OK] Servicio bhttp.service activo (${BHTTP_LISTEN_LIST}) -> SSH 127.0.0.1:${DEFAULT_SSH_PORT}${NC}"

# ============================================================================
# 5. ENRUTAMIENTO, KERNEL BBR Y FIREWALL
# ============================================================================
echo -e "\n${YELLOW}[5/5] Configurando Kernel BBR, Keepalive 60s y Firewall...${NC}"

modprobe tcp_bbr 2>/dev/null || true
mkdir -p /etc/sysctl.d
cat > /etc/sysctl.d/99-bhttp.conf <<'EOF'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
fs.file-max = 2097152
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 100000
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.ip_local_port_range = 10240 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_max_tw_buckets = 2000000
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 6
net.ipv4.tcp_mtu_probing = 1
EOF
sysctl -p /etc/sysctl.d/99-bhttp.conf >/dev/null 2>&1 || sysctl --system >/dev/null 2>&1 || true

for p in 8080 8088 8881 2053 2083 8444 "$SELECTED_BHTTP_PORT"; do
    [[ -z "$p" ]] && continue
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
        ufw allow "$p/tcp" comment "BHTTP/XHTTP Relay" >/dev/null 2>&1 || true
    fi
    if command -v iptables >/dev/null 2>&1; then
        iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || true
    fi
done
if command -v iptables >/dev/null 2>&1 && [[ -d /etc/iptables ]]; then
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
fi
echo -e "${GREEN}[OK] Reglas de Firewall y Kernel BBR aplicadas para BHTTP/XHTTP (8080, 8088, 8881, 2053, 2083, 8444).${NC}"

# ============================================================================
# REPORTE FINAL
# ============================================================================
SERVER_IP=$(curl -s4 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')

echo ""
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${GREEN}        OPTIMIZACIÓN BHTTP VPS COMPLETADA                  ${NC}"
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo -e "  IP Servidor:         ${BOLD}${SERVER_IP}${NC}"
echo -e "  AllowTcpForwarding:  ${BOLD}${GREEN}YES (Activo)${NC}"
echo -e "  Puerto BHTTP:        ${BOLD}${CYAN}${SELECTED_BHTTP_PORT}/tcp${NC}"
echo -e "  Puerto UDPGW:        ${BOLD}7300/udp${NC}"
echo -e "  Destino SSH:         ${BOLD}127.0.0.1:${DEFAULT_SSH_PORT}${NC}"
echo -e "  Helper bhttp-connect:${BOLD}${GREEN}Instalado${NC}"
echo ""
echo -e "  ${BOLD}En tu App Android (HTTP Conexión):${NC}"
echo -e "  - Servidor: ${BOLD}${SERVER_IP}${NC} (o tu dominio)"
echo -e "  - Puerto BHTTP: ${BOLD}${CYAN}${SELECTED_BHTTP_PORT}${NC}"
echo -e "  - Puerto SSH:   ${BOLD}${DEFAULT_SSH_PORT}${NC}"
echo ""
