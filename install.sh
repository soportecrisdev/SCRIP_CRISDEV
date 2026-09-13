#!/usr/bin/env bash
# ==============================================================================
#  SSH-CRIS v1 — Instalador Remoto Oficial
#  Ejecución en VPS (Debian / Ubuntu):
#    bash <(curl -fsSL https://raw.githubusercontent.com/soportecrisdev/SCRIP_CRISDEV/main/install.sh)
# ==============================================================================

REPO_RAW="https://raw.githubusercontent.com/soportecrisdev/SCRIP_CRISDEV/main"
INSTALL_DIR="/opt/ssh-cris"
BIN_NAME="ssh-cris.sh"

RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
WHITE='\033[1;37m'
NC='\033[0m'

clear
echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║${WHITE}             ⚡ INSTALADOR SSH-CRIS MASTER v1 ⚡             ${CYAN}║${NC}"
echo -e "${CYAN}║${WHITE}                 CRISDEV / HTTP Conexión                    ${CYAN}║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo -e "${RED}[ERROR]${NC} Ejecuta este instalador como root: sudo bash $0"
    exit 1
fi

echo -e "${YELLOW}[1/4]${NC} Actualizando repositorios e instalando paquetes base..."
if command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get update -y -qq >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl wget git jq openssl stunnel4 ufw fail2ban \
        socat netcat-openbsd python3 libssl-dev screen nano unzip iproute2 procps net-tools \
        build-essential cmake make gcc g++ iptables >/dev/null 2>&1 || true
elif command -v yum >/dev/null 2>&1; then
    yum install -y -q curl wget git jq openssl stunnel ufw fail2ban socat python3 screen nano unzip iproute procps-ng net-tools gcc gcc-c++ make cmake iptables >/dev/null 2>&1 || true
fi
echo -e "${GREEN}[✔]${NC} Dependencias listas."

echo -e "${YELLOW}[2/4]${NC} Creando estructura y descargando suite completa de módulos..."
mkdir -p "$INSTALL_DIR" /etc/SSHPlus /etc/SSHPlus/v2ray /etc/SSHPlus/senha /etc/SSHPlus/.tmp /etc/SSHPlus/userteste \
    /etc/bot /etc/bot/info-users /etc/bot/arquivos /etc/bot/revenda /etc/bot/suspensos /etc/rec \
    /etc/ssh-cris /etc/wakkodev-bhttp /etc/hysteria /etc/stunnel /etc/slowdns /usr/lib /bin

# Licencia y datos base
echo 'By J DAVID AG' > /usr/lib/sshplus
cp -f /usr/lib/sshplus /usr/lib/licence 2>/dev/null || true
echo 'By J DAVID AG' > /etc/rec/licence 2>/dev/null || true
touch /etc/SSHPlus/Exp /etc/bot/lista_ativos /etc/bot/lista_suspensos /root/usuarios.db 2>/dev/null || true

# Obtener IP del VPS
IP=$(curl -s4 icanhazip.com || curl -s4 ifconfig.me || wget -qO- ipv4.icanhazip.com || echo "127.0.0.1")
echo "$IP" > /etc/IP

# Lista de modulos completos
_mdls=(
    "ShellBot.sh" "ackclear" "acksyshttpack" "addhost" "apache2menu" "attscript"
    "badpro" "badpro1" "badvpn" "badvpn2" "badvpn3" "banner" "bashtop" "blocksite"
    "blockt" "blockuser" "bot" "botpro" "botssh" "changedate" "changelimit" "changepass"
    "check" "checkbot" "checkupdate" "chuser" "connection" "createtest" "createuser"
    "ddos" "delhost" "delscript" "details" "droplimiter" "expcleaner" "fr" "gltunnel"
    "h" "haveged" "help" "hysteria-menu" "infousers" "initbot" "initcheck" "install-testbot"
    "instsqd" "licence" "limit" "limiter" "menu" "menub" "mtuning" "multi" "multi2"
    "open.py" "optimize" "pkill.sh" "proxy.py" "removeuser" "restartservices" "restartsystem"
    "rootpass" "rps_cpu" "slowdnsmanager" "speedtest" "sshmonitor" "sshplus_lang" "swapmemory"
    "tcptweaker.sh" "testbot" "testbot.sh" "totaltraffic" "trojan-go" "tuning" "tweaker"
    "uexpired" "uncompress" "userbackup" "utili" "v2raymanager" "v2raypanel" "version"
    "vnc_inst" "webmin.sh" "websocket.sh" "wsproxy.py"
)

# Copiar o descargar modulos a /bin
if [[ -d "./Modulos" ]]; then
    cp -rf ./Modulos/* /bin/ 2>/dev/null || true
else
    for _m in "${_mdls[@]}"; do
        curl -fsSL "$REPO_RAW/Modulos/$_m" -o "/bin/$_m" 2>/dev/null || \
        wget -q "$REPO_RAW/Modulos/$_m" -O "/bin/$_m" 2>/dev/null || true
        chmod +x "/bin/$_m" 2>/dev/null || true
    done
fi
chmod +x /bin/* 2>/dev/null || true

# Colocar scripts python y bots en /etc/SSHPlus/
for _f in cabecalho bot open.py proxy.py wsproxy.py ShellBot.sh botssh; do
    if [[ -f "/bin/$_f" ]]; then
        cp -af "/bin/$_f" /etc/SSHPlus/ 2>/dev/null || true
    fi
done
chmod +x /etc/SSHPlus/* 2>/dev/null || true

# Descargar script maestro SSH-CRIS
if [[ -f "./ssh-cris.sh" ]]; then
    cp -af "./ssh-cris.sh" "$INSTALL_DIR/$BIN_NAME"
else
    curl -fsSL "$REPO_RAW/ssh-cris.sh" -o "$INSTALL_DIR/$BIN_NAME" 2>/dev/null || \
    wget -q "$REPO_RAW/ssh-cris.sh" -O "$INSTALL_DIR/$BIN_NAME"
fi
chmod +x "$INSTALL_DIR/$BIN_NAME"

# Instalar BadVPN (badvpn-udpgw) binario y compilar si es necesario
echo -e "${YELLOW}[*]${NC} Compilando e instalando BadVPN udpgw..."
if [[ ! -x /usr/local/bin/badvpn-udpgw && ! -x /bin/badvpn-udpgw ]]; then
    mkdir -p /usr/local/src
    (
        cd /usr/local/src
        curl -fsSL "https://github.com/ambrop72/badvpn/archive/refs/tags/1.999.130.tar.gz" -o badvpn-1.999.130.tar.gz 2>/dev/null || wget -q "https://github.com/ambrop72/badvpn/archive/refs/tags/1.999.130.tar.gz" -O badvpn-1.999.130.tar.gz
        tar -xzf badvpn-1.999.130.tar.gz 2>/dev/null || true
        mkdir -p badvpn-build && cd badvpn-build
        cmake ../badvpn-1.999.130 -DCMAKE_INSTALL_PREFIX=/usr/local -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 >/dev/null 2>&1 || true
        make -j$(nproc 2>/dev/null || echo 1) >/dev/null 2>&1 || true
        make install >/dev/null 2>&1 || true
    )
fi
chmod +x /usr/local/bin/badvpn-udpgw /bin/badvpn-udpgw 2>/dev/null || true
ln -sfn /usr/local/bin/badvpn-udpgw /bin/badvpn-udpgw 2>/dev/null || true

# Configurar servicio systemd para BadVPN (puerto 7300 por defecto)
cat > /etc/systemd/system/badvpn-udpgw.service << 'EOF'
[Unit]
Description=BadVPN UDP Gateway (Port 7300)
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/badvpn-udpgw --listen-addr 127.0.0.1:7300 --max-clients 9000 --max-connections-for-client 5 --client-socket-sndbuf 10000
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload >/dev/null 2>&1 || true
systemctl enable --now badvpn-udpgw.service >/dev/null 2>&1 || true

# Instalar Core UDP CRIS (Hysteria v1.3.5)
echo -e "${YELLOW}[*]${NC} Descargando Core UDP CRIS (Hysteria v1.3.5)..."
ARCH=$(uname -m)
if [[ "$ARCH" == "x86_64" || "$ARCH" == "amd64" ]]; then
    curl -fsSL "https://github.com/apernet/hysteria/releases/download/v1.3.5/hysteria-linux-amd64" -o /usr/local/bin/hysteria1 2>/dev/null || \
    wget -q "https://github.com/apernet/hysteria/releases/download/v1.3.5/hysteria-linux-amd64" -O /usr/local/bin/hysteria1 2>/dev/null || true
elif [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
    curl -fsSL "https://github.com/apernet/hysteria/releases/download/v1.3.5/hysteria-linux-arm64" -o /usr/local/bin/hysteria1 2>/dev/null || \
    wget -q "https://github.com/apernet/hysteria/releases/download/v1.3.5/hysteria-linux-arm64" -O /usr/local/bin/hysteria1 2>/dev/null || true
fi
chmod 755 /usr/local/bin/hysteria1 2>/dev/null || true
ln -sfn /usr/local/bin/hysteria1 /usr/local/bin/hysteria 2>/dev/null || true
chmod 755 /usr/local/bin/hysteria 2>/dev/null || true

# Configuración base inicial de Hysteria v1 para que arranque activo
mkdir -p /etc/hysteria
if [[ ! -f /etc/hysteria/server.crt || ! -f /etc/hysteria/server.key ]]; then
    openssl req -x509 -newkey rsa:2048 -days 3650 -nodes \
        -keyout /etc/hysteria/server.key -out /etc/hysteria/server.crt -subj "/CN=crisdev.online" >/dev/null 2>&1 || true
fi
chmod 600 /etc/hysteria/server.key 2>/dev/null || true
chmod 644 /etc/hysteria/server.crt 2>/dev/null || true

if [[ ! -f /etc/hysteria/config.json ]]; then
cat > /etc/hysteria/config.json << 'EOF'
{
  "listen": ":36712",
  "protocol": "udp",
  "cert": "/etc/hysteria/server.crt",
  "key": "/etc/hysteria/server.key",
  "obfs": "crisdev",
  "auth": {
    "mode": "passwords",
    "config": [
      "crisdev:crisdev"
    ]
  },
  "alpn": "h3",
  "recv_window_conn": 15728640,
  "recv_window": 67108864,
  "max_conn_client": 0,
  "idle_timeout": 60,
  "up_mbps": 100,
  "down_mbps": 100,
  "disable_mtu_discovery": false,
  "resolver": "8.8.8.8:53"
}
EOF
fi

cat > /etc/hysteria/sshplus.env << 'EOF'
HYST_PORT="36712"
HYST_RULES="20000:50000"
HYST_OBFS="crisdev"
EOF

cat > /etc/hysteria/iptables.sh << 'EOF'
#!/bin/bash
ACTION="$1"
ENV_FILE="/etc/hysteria/sshplus.env"
CHAIN="SSHPLUS_HYSTERIA"
[[ -f "$ENV_FILE" ]] && . "$ENV_FILE"
clear_rules() {
    while iptables -t nat -C PREROUTING -p udp -j "$CHAIN" >/dev/null 2>&1; do
        iptables -t nat -D PREROUTING -p udp -j "$CHAIN" >/dev/null 2>&1 || break
    done
    iptables -t nat -F "$CHAIN" >/dev/null 2>&1 || true
    iptables -t nat -X "$CHAIN" >/dev/null 2>&1 || true
}
apply_rules() {
    clear_rules
    iptables -I INPUT 1 -p udp --dport "${HYST_PORT:-36712}" -j ACCEPT >/dev/null 2>&1 || true
    [[ -z "$HYST_RULES" || "$HYST_RULES" = "none" || "$HYST_RULES" = "0" ]] && return 0
    iptables -t nat -N "$CHAIN" >/dev/null 2>&1 || true
    iptables -t nat -I PREROUTING 1 -p udp -j "$CHAIN" >/dev/null 2>&1 || true
    local clean="${HYST_RULES// /}" item
    IFS=',' read -ra items <<<"$clean"
    for item in "${items[@]}"; do
        [[ -z "$item" || "$item" = "53" || "$item" = "5300" ]] && continue
        iptables -t nat -A "$CHAIN" -p udp --dport "$item" -j REDIRECT --to-ports "$HYST_PORT" >/dev/null 2>&1 || true
    done
}
case "$ACTION" in
    apply) apply_rules ;;
    clear) clear_rules ;;
esac
exit 0
EOF
chmod +x /etc/hysteria/iptables.sh 2>/dev/null || true

cat > /etc/systemd/system/hysteria-server.service << 'EOF'
[Unit]
Description=CRISDEV UDP Hysteria v1.3.5 Server
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Environment=HYSTERIA_LOG_LEVEL=debug
ExecStartPre=-/etc/hysteria/iptables.sh apply
ExecStart=/usr/local/bin/hysteria -c /etc/hysteria/config.json server
ExecStopPost=-/etc/hysteria/iptables.sh clear
WorkingDirectory=/etc/hysteria
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload >/dev/null 2>&1 || true
systemctl enable --now hysteria-server.service >/dev/null 2>&1 || true

# Instalar Servidor BHTTP Multi-Puerto
if [[ -f "./wakkodev_bhttp_server.py" ]]; then
    cp -af "./wakkodev_bhttp_server.py" /etc/wakkodev-bhttp/wakkodev_bhttp_server.py 2>/dev/null || true
else
    curl -fsSL "$REPO_RAW/wakkodev_bhttp_server.py" -o /etc/wakkodev-bhttp/wakkodev_bhttp_server.py 2>/dev/null || \
    wget -q "$REPO_RAW/wakkodev_bhttp_server.py" -O /etc/wakkodev-bhttp/wakkodev_bhttp_server.py 2>/dev/null || true
fi
chmod +x /etc/wakkodev-bhttp/wakkodev_bhttp_server.py 2>/dev/null || true

echo -e "${GREEN}[✔]${NC} Módulos y servicios instalados correctamente."

echo -e "${YELLOW}[3/4]${NC} Creando accesos directos y enlaces globales..."
ln -sfn "$INSTALL_DIR/$BIN_NAME" /usr/local/bin/ssh-cris
ln -sfn "$INSTALL_DIR/$BIN_NAME" /usr/local/bin/cris
ln -sfn "$INSTALL_DIR/$BIN_NAME" /usr/local/bin/menu
ln -sfn "$INSTALL_DIR/$BIN_NAME" /bin/menu 2>/dev/null || true
ln -sfn "$INSTALL_DIR/$BIN_NAME" /bin/connection 2>/dev/null || true
ln -sfn "$INSTALL_DIR/$BIN_NAME" /bin/conexao 2>/dev/null || true

sshplus_compat_alias() {
    local old="$1" new="$2"
    [[ -e "/bin/$new" ]] || return 0
    rm -f "/bin/$old" 2>/dev/null || true
    ln -sfn "/bin/$new" "/bin/$old" 2>/dev/null || cp -af "/bin/$new" "/bin/$old"
    chmod +x "/bin/$old" 2>/dev/null || true
}
sshplus_compat_alias conexao connection
sshplus_compat_alias criarusuario createuser
sshplus_compat_alias criarteste createtest
sshplus_compat_alias remover removeuser
sshplus_compat_alias mudardata changedate
sshplus_compat_alias alterarsenha changepass
sshplus_compat_alias alterarlimite changelimit
sshplus_compat_alias ajuda help
sshplus_compat_alias detalhes details
sshplus_compat_alias otimizar optimize
sshplus_compat_alias painelv2ray v2raypanel
sshplus_compat_alias reiniciarservicos restartservices
sshplus_compat_alias reiniciarsistema restartsystem
sshplus_compat_alias senharoot rootpass
sshplus_compat_alias trafegototal totaltraffic
sshplus_compat_alias versao version
sshplus_compat_alias verifatt checkupdate
sshplus_compat_alias verifbot checkbot
sshplus_compat_alias botteste testbot
sshplus_compat_alias botteste.sh testbot.sh
sshplus_compat_alias inst-botteste install-testbot

echo -e "${GREEN}[✔]${NC} Comandos 'ssh-cris', 'cris', 'menu' y módulos registrados."

echo -e "${YELLOW}[4/4]${NC} Optimizando puertos SSH base y firewall..."
sed -i 's/#*AllowTcpForwarding.*/AllowTcpForwarding yes/' /etc/ssh/sshd_config 2>/dev/null || true
sed -i 's/#*GatewayPorts.*/GatewayPorts yes/' /etc/ssh/sshd_config 2>/dev/null || true
sed -i 's/#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config 2>/dev/null || true
systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true

echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
echo -e "${WHITE}  ⚡ ¡SUITE SSH-CRIS INSTALADA CON ÉXITO! ⚡${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
echo -e "${WHITE}Escribe ${CYAN}ssh-cris${WHITE}, ${CYAN}cris${WHITE} o ${CYAN}menu${WHITE} para abrir el panel.${NC}"
echo ""

# Iniciar menú
exec "$INSTALL_DIR/$BIN_NAME"
