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

# Instalar BadVPN (badvpn-udpgw) binario
echo -e "${YELLOW}[*]${NC} Configurando BadVPN udpgw..."
if [[ -f "./badvpn/badvpn-udpgw" ]]; then
    cp -af "./badvpn/badvpn-udpgw" /usr/local/bin/badvpn-udpgw 2>/dev/null || true
    cp -af "./badvpn/badvpn-udpgw" /bin/badvpn-udpgw 2>/dev/null || true
else
    curl -fsSL "$REPO_RAW/badvpn/badvpn-udpgw" -o /usr/local/bin/badvpn-udpgw 2>/dev/null || \
    wget -q "$REPO_RAW/badvpn/badvpn-udpgw" -O /usr/local/bin/badvpn-udpgw 2>/dev/null || true
    cp -af /usr/local/bin/badvpn-udpgw /bin/badvpn-udpgw 2>/dev/null || true
fi
chmod +x /usr/local/bin/badvpn-udpgw /bin/badvpn-udpgw 2>/dev/null || true

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
chmod +x /usr/local/bin/hysteria1 2>/dev/null || true
ln -sfn /usr/local/bin/hysteria1 /usr/local/bin/hysteria 2>/dev/null || true

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
