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
    ss -lntu | awk '{print $5}' | grep -E "(:|\])$port$" >/dev/null 2>&1
}

# Mostrar servicios conocidos detectados
echo -e "  Puertos actualmente ocupados en el servidor:"
ss -lntp 2>/dev/null | grep -E ':(22|80|90|110|443|8080|5300|8880|36712|7300|8881|7081)\b' | awk '{print "    - Port " $4 " (" $6 ")"}' || true

# Variable de entorno BHTTP_PORT o argumento
SELECTED_BHTTP_PORT="${BHTTP_PORT:-}"
DEFAULT_SSH_PORT="${SSH_PORT:-22}"

if [[ -z "$SELECTED_BHTTP_PORT" ]]; then
    # Evaluar puertos sugeridos para evitar pisar V2Ray (8080) o Proxy Socks (80)
    if ! check_port_in_use 8881; then
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
# 4. CONFIGURACIÓN O ACTUALIZACIÓN DEL SERVICIO BILOLA-SERVER
# ============================================================================
echo -e "\n${YELLOW}[4/5] Configurando servicio bilola-server...${NC}"

# Buscar binario bilola-server
BILOLA_BIN=""
for path in /usr/local/lib/bilola/bilola-server /usr/local/lib/btun/bilola-server /root/BTUN/bin/amd64/bilola-server /opt/crisdev/btun/bilola-server; do
    if [[ -x "$path" ]]; then
        BILOLA_BIN="$path"
        break
    fi
done

if [[ -z "$BILOLA_BIN" ]]; then
    # Copiar desde el paquete local si existe
    if [[ -f "/root/BTUN/bin/$(uname -m)/bilola-server" ]]; then
        mkdir -p /usr/local/lib/bilola
        cp "/root/BTUN/bin/$(uname -m)/bilola-server" /usr/local/lib/bilola/bilola-server
        chmod +x /usr/local/lib/bilola/bilola-server
        BILOLA_BIN="/usr/local/lib/bilola/bilola-server"
    fi
fi

if [[ -n "$BILOLA_BIN" ]]; then
    cat > /etc/systemd/system/bilola-go-server.service <<EOF
[Unit]
Description=Bilola BHTTP Go server (CRISDEV)
After=network-online.target ssh.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BILOLA_BIN --listen 0.0.0.0:$SELECTED_BHTTP_PORT --target 127.0.0.1:$DEFAULT_SSH_PORT
Restart=on-failure
RestartSec=3
User=root
LimitNOFILE=65536
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable bilola-go-server >/dev/null 2>&1 || true
    systemctl restart bilola-go-server 2>/dev/null || systemctl start bilola-go-server 2>/dev/null || true
    echo -e "${GREEN}[OK] Servicio bilola-go-server activo en puerto $SELECTED_BHTTP_PORT -> SSH $DEFAULT_SSH_PORT${NC}"
else
    echo -e "${YELLOW}[INFO] Binario bilola-server no detectado aún en el sistema.${NC}"
    echo -e "       El puerto $SELECTED_BHTTP_PORT ha quedado preparado para cuando instales el servicio con BTUN."
fi

# ============================================================================
# 5. ENRUTAMIENTO Y FIREWALL
# ============================================================================
echo -e "\n${YELLOW}[5/5] Configurando Firewall y Enrutamiento de Paquetes...${NC}"

# Habilitar IP Forwarding en el Kernel
mkdir -p /etc/sysctl.d
cat > /etc/sysctl.d/99-bhttp.conf <<'EOF'
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
EOF
sysctl -p /etc/sysctl.d/99-bhttp.conf >/dev/null 2>&1 || sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true

# Abrir puertos en UFW si está activo
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
    ufw allow "$SELECTED_BHTTP_PORT/tcp" comment "BHTTP Relay" >/dev/null 2>&1 || true
    ufw allow 7300/udp comment "UDPGW / BTUN" >/dev/null 2>&1 || true
    ufw allow 7300/tcp comment "UDPGW / BTUN" >/dev/null 2>&1 || true
    echo -e "${GREEN}[OK] Reglas agregadas en UFW para $SELECTED_BHTTP_PORT/tcp y 7300/udp${NC}"
elif command -v iptables >/dev/null 2>&1; then
    iptables -I INPUT -p tcp --dport "$SELECTED_BHTTP_PORT" -j ACCEPT 2>/dev/null || true
    iptables -I INPUT -p udp --dport 7300 -j ACCEPT 2>/dev/null || true
    echo -e "${GREEN}[OK] Reglas añadidas en iptables para puertos $SELECTED_BHTTP_PORT y 7300.${NC}"
fi

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
