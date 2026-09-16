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

mkdir -p /etc/SSHPlus /etc/ssh-cris /opt/ssh-cris

IS_UPDATE=0
if [[ "$1" == "--update" || "$1" == "-u" || "$1" == "update" ]]; then
    IS_UPDATE=1
elif [[ -f "/opt/ssh-cris/ssh-cris.sh" || -f "/etc/ssh-cris/lang" || -f "/etc/SSHPlus/lang" ]]; then
    IS_UPDATE=1
fi

# ── 1. SELECCIÓN DE IDIOMA ──
choose_language() {
    if [[ $IS_UPDATE -eq 1 ]]; then
        local prev_lang="es"
        [[ -f /etc/ssh-cris/lang ]] && prev_lang=$(cat /etc/ssh-cris/lang 2>/dev/null)
        [[ -f /etc/SSHPlus/lang && -z "$prev_lang" ]] && prev_lang=$(cat /etc/SSHPlus/lang 2>/dev/null)
        [[ -z "$prev_lang" ]] && prev_lang="es"
        echo "$prev_lang" > /etc/SSHPlus/lang
        echo "$prev_lang" > /etc/ssh-cris/lang
        return 0
    fi
    [[ -t 0 ]] || return 0
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${WHITE}             SELECCIONAR IDIOMA / SELECT LANGUAGE          ${NC}"
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${GREEN}[1]${NC} \033[1;37m> Español (Spanish)${NC}"
    echo -e "${GREEN}[2]${NC} \033[1;37m> English${NC}"
    echo -e "${CYAN}============================================================${NC}"
    echo -ne "\033[1;32mOpción / Option [Enter = 1]: ${NC}"
    read -r lang_opt
    local l_choice="es"
    case "$lang_opt" in
        2) l_choice="en" ;;
        *) l_choice="es" ;;
    esac
    echo "$l_choice" > /etc/SSHPlus/lang
    echo "$l_choice" > /etc/ssh-cris/lang
}

# ── 2. ECUALIZACIÓN / CONFIGURACIÓN DE ZONA HORARIA ──
choose_timezone() {
    if [[ $IS_UPDATE -eq 1 ]]; then
        return 0
    fi
    [[ -t 0 ]] || return 0
    local cur_tz
    cur_tz=$(cat /etc/timezone 2>/dev/null || timedatectl 2>/dev/null | grep "Time zone" | awk '{print $3}' || echo "UTC")
    local cur_time
    cur_time=$(date '+%Y-%m-%d %H:%M:%S (%Z)')

    echo ""
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${WHITE}        ⚡ ECUALIZAR HORARIO / CONFIGURAR ZONA HORARIA ⚡    ${NC}"
    echo -e "${CYAN}============================================================${NC}"
    echo -e "  ${WHITE}Hora Actual del Servidor : ${YELLOW}${cur_time}${NC}"
    echo -e "  ${WHITE}Zona Horaria Actual      : ${GREEN}${cur_tz}${NC}"
    echo -e "${CYAN}============================================================${NC}"
    echo -e "  ${GREEN}[1]${NC}  \033[1;37m> America/Bogota       (Colombia, Perú, Ecuador, Panamá - UTC-5)${NC}"
    echo -e "  ${GREEN}[2]${NC}  \033[1;37m> America/Mexico_City  (México Centro - UTC-6)${NC}"
    echo -e "  ${GREEN}[3]${NC}  \033[1;37m> America/Caracas      (Venezuela - UTC-4)${NC}"
    echo -e "  ${GREEN}[4]${NC}  \033[1;37m> America/Santiago     (Chile - UTC-3/UTC-4)${NC}"
    echo -e "  ${GREEN}[5]${NC}  \033[1;37m> America/Argentina/Buenos_Aires (Argentina - UTC-3)${NC}"
    echo -e "  ${GREEN}[6]${NC}  \033[1;37m> America/La_Paz       (Bolivia - UTC-4)${NC}"
    echo -e "  ${GREEN}[7]${NC}  \033[1;37m> America/Lima         (Perú - UTC-5)${NC}"
    echo -e "  ${GREEN}[8]${NC}  \033[1;37m> America/Santo_Domingo (Rep. Dominicana - UTC-4)${NC}"
    echo -e "  ${GREEN}[9]${NC}  \033[1;37m> America/Guatemala    (Centroamérica - UTC-6)${NC}"
    echo -e "  ${GREEN}[10]${NC} \033[1;37m> America/Sao_Paulo   (Brasil - UTC-3)${NC}"
    echo -e "  ${GREEN}[11]${NC} \033[1;37m> Europe/Madrid       (España - UTC+1)${NC}"
    echo -e "  ${GREEN}[12]${NC} \033[1;37m> America/New_York    (USA Este - UTC-5)${NC}"
    echo -e "  ${GREEN}[13]${NC} \033[1;37m> Mantener zona actual del servidor (${cur_tz})${NC}"
    echo -e "  ${GREEN}[14]${NC} \033[1;37m> Ingresar zona horaria personalizada${NC}"
    echo -e "${CYAN}============================================================${NC}"
    echo -ne "\033[1;32mSelecciona Zona Horaria [Enter = 1 (America/Bogota)]: ${NC}"
    read -r tz_opt

    local target_tz="America/Bogota"
    case "$tz_opt" in
        1|"") target_tz="America/Bogota" ;;
        2) target_tz="America/Mexico_City" ;;
        3) target_tz="America/Caracas" ;;
        4) target_tz="America/Santiago" ;;
        5) target_tz="America/Argentina/Buenos_Aires" ;;
        6) target_tz="America/La_Paz" ;;
        7) target_tz="America/Lima" ;;
        8) target_tz="America/Santo_Domingo" ;;
        9) target_tz="America/Guatemala" ;;
        10) target_tz="America/Sao_Paulo" ;;
        11) target_tz="Europe/Madrid" ;;
        12) target_tz="America/New_York" ;;
        13) target_tz="$cur_tz" ;;
        14)
            echo -ne "\033[1;33mEscribe la zona horaria (ej: America/Cancun): \033[0m"
            read -r manual_tz
            [[ -n "$manual_tz" ]] && target_tz="$manual_tz" || target_tz="America/Bogota"
            ;;
        *) target_tz="America/Bogota" ;;
    esac

    echo -e "\n\033[1;33mAplicando zona horaria: ${target_tz}...\033[0m"
    echo "$target_tz" > /etc/timezone 2>/dev/null || true
    if [[ -f "/usr/share/zoneinfo/$target_tz" ]]; then
        ln -fs "/usr/share/zoneinfo/$target_tz" /etc/localtime 2>/dev/null || true
    fi
    if command -v timedatectl >/dev/null 2>&1; then
        timedatectl set-timezone "$target_tz" 2>/dev/null || true
        timedatectl set-ntp true 2>/dev/null || true
    fi
    if command -v dpkg-reconfigure >/dev/null 2>&1; then
        dpkg-reconfigure --frontend noninteractive tzdata >/dev/null 2>&1 || true
    fi
    
    echo -e "\033[1;32m[✔] Horario sincronizado con éxito!\033[0m"
    echo -e "\033[1;37mNueva hora del servidor: \033[1;32m$(date '+%Y-%m-%d %H:%M:%S (%Z)')\033[0m\n"
    sleep 1
}

if [[ "${1:-}" != "--update" && "${1:-}" != "-u" ]]; then
    choose_language
    choose_timezone
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
    /etc/ssh-cris /etc/bhttp /etc/hysteria /etc/stunnel /etc/slowdns /usr/lib /bin

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
    "vnc_inst" "webmin.sh" "websocket.sh" "wsproxy.py" "sshplus_stats"
    "udp-custom-manager" "hysteria2-manager" "hcr-manager" "optimizar_vps.sh"
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

# Configurar Auto-Optimizador de Memoria RAM / Swap
if [[ -f "/bin/optimizar_vps.sh" ]]; then
    cp -af "/bin/optimizar_vps.sh" /usr/local/bin/optimizar_vps.sh 2>/dev/null || true
    chmod +x /usr/local/bin/optimizar_vps.sh /bin/optimizar_vps.sh
    echo "0 * * * * root /usr/local/bin/optimizar_vps.sh >/dev/null 2>&1" > /etc/cron.d/auto_opt_vps
    chmod 644 /etc/cron.d/auto_opt_vps
    if [[ -f /etc/sysctl.conf ]] && ! grep -q "^vm.swappiness" /etc/sysctl.conf 2>/dev/null; then
        echo "vm.swappiness=10" >> /etc/sysctl.conf
    fi
    sysctl -w vm.swappiness=10 >/dev/null 2>&1 || true
fi

# Copiar o descargar herramientas de Install/
_inst_files=(
    "EasyRSA-3.0.1.tgz" "ShellBot.sh" "botssh" "cert" "instsqd" "key" "list"
    "resolved.conf" "slowdns" "squid3" "sshd_config" "stunnel" "stunnel.pem"
    "tcptweaker.sh" "udp" "version"
)
if [[ -d "./Install" ]]; then
    cp -rf ./Install/* /etc/SSHPlus/ 2>/dev/null || true
    cp -af ./Install/udp /bin/udp 2>/dev/null || true
    cp -af ./Install/instsqd /bin/instsqd 2>/dev/null || true
    cp -af ./Install/slowdns /bin/slowdns 2>/dev/null || true
else
    for _if in "${_inst_files[@]}"; do
        curl -fsSL "$REPO_RAW/Install/$_if" -o "/etc/SSHPlus/$_if" 2>/dev/null || \
        wget -q "$REPO_RAW/Install/$_if" -O "/etc/SSHPlus/$_if" 2>/dev/null || true
    done
    cp -af /etc/SSHPlus/udp /bin/udp 2>/dev/null || true
    cp -af /etc/SSHPlus/instsqd /bin/instsqd 2>/dev/null || true
    cp -af /etc/SSHPlus/slowdns /bin/slowdns 2>/dev/null || true
fi
chmod +x /bin/udp /bin/instsqd /bin/slowdns 2>/dev/null || true

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
# BadVPN service installed (will start only when activated from menu)

# Instalar Core UDP CRIS (Hysteria v1.3.5)
echo -e "${YELLOW}[*]${NC} Descargando Core UDP CRIS (Hysteria v1.3.5)..."
ARCH=$(uname -m)
if [[ "$ARCH" == "x86_64" || "$ARCH" == "amd64" ]]; then
    curl -fsSL "https://github.com/apernet/hysteria/releases/download/v1.3.5/hysteria-linux-amd64" -o /usr/local/bin/hysteria1 2>/dev/null || \
    wget -q "https://github.com/apernet/hysteria/releases/download/v1.3.5/hysteria-linux-amd64" -O /usr/local/bin/hysteria1 2>/dev/null || \
    curl -fsSL "https://raw.githubusercontent.com/soportecrisdev/SCRIP_CRISDEV/main/hysteria1-amd64" -o /usr/local/bin/hysteria1 2>/dev/null || \
    wget -q "https://raw.githubusercontent.com/soportecrisdev/SCRIP_CRISDEV/main/hysteria1-amd64" -O /usr/local/bin/hysteria1 2>/dev/null || true
elif [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
    curl -fsSL "https://github.com/apernet/hysteria/releases/download/v1.3.5/hysteria-linux-arm64" -o /usr/local/bin/hysteria1 2>/dev/null || \
    wget -q "https://github.com/apernet/hysteria/releases/download/v1.3.5/hysteria-linux-arm64" -O /usr/local/bin/hysteria1 2>/dev/null || \
    curl -fsSL "https://raw.githubusercontent.com/soportecrisdev/SCRIP_CRISDEV/main/hysteria1-arm64" -o /usr/local/bin/hysteria1 2>/dev/null || \
    wget -q "https://raw.githubusercontent.com/soportecrisdev/SCRIP_CRISDEV/main/hysteria1-arm64" -O /usr/local/bin/hysteria1 2>/dev/null || true
fi
chmod 755 /usr/local/bin/hysteria1 2>/dev/null || true
ln -sfn /usr/local/bin/hysteria1 /usr/local/bin/hysteria 2>/dev/null || true
ln -sfn /usr/local/bin/hysteria1 /bin/hysteria1 2>/dev/null || true
ln -sfn /usr/local/bin/hysteria1 /bin/hysteria 2>/dev/null || true
chmod 755 /usr/local/bin/hysteria /bin/hysteria1 /bin/hysteria 2>/dev/null || true

# Instalar Core SlowDNS (dnstt-server)
echo -e "${YELLOW}[*]${NC} Descargando Core SlowDNS (dnstt-server)..."
if [[ "$ARCH" == "x86_64" || "$ARCH" == "amd64" ]]; then
    curl -fsSL "https://raw.githubusercontent.com/soportecrisdev/SCRIP_CRISDEV/main/dnstt-server-amd64" -o /usr/local/bin/dnstt-server 2>/dev/null || \
    wget -q "https://raw.githubusercontent.com/soportecrisdev/SCRIP_CRISDEV/main/dnstt-server-amd64" -O /usr/local/bin/dnstt-server 2>/dev/null || \
    curl -fsSL "https://dnstt.network/dnstt-server-linux-amd64" -o /usr/local/bin/dnstt-server 2>/dev/null || true
elif [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
    curl -fsSL "https://raw.githubusercontent.com/soportecrisdev/SCRIP_CRISDEV/main/dnstt-server-arm64" -o /usr/local/bin/dnstt-server 2>/dev/null || \
    wget -q "https://raw.githubusercontent.com/soportecrisdev/SCRIP_CRISDEV/main/dnstt-server-arm64" -O /usr/local/bin/dnstt-server 2>/dev/null || \
    curl -fsSL "https://dnstt.network/dnstt-server-linux-arm64" -o /usr/local/bin/dnstt-server 2>/dev/null || true
fi
chmod 755 /usr/local/bin/dnstt-server 2>/dev/null || true
ln -sfn /usr/local/bin/dnstt-server /bin/dnstt-server 2>/dev/null || true
chmod 755 /bin/dnstt-server 2>/dev/null || true

# Instalar Core Chisel Tunnel (jpillora/chisel)
echo -e "${YELLOW}[*]${NC} Descargando Core Chisel Tunnel..."
if [[ ! -x /usr/local/bin/chisel && ! -x /bin/chisel ]]; then
    if [[ "$ARCH" == "x86_64" || "$ARCH" == "amd64" ]]; then
        curl -fsSL "https://raw.githubusercontent.com/soportecrisdev/SCRIP_CRISDEV/main/chisel-amd64" -o /usr/local/bin/chisel 2>/dev/null || \
        wget -q "https://raw.githubusercontent.com/soportecrisdev/SCRIP_CRISDEV/main/chisel-amd64" -O /usr/local/bin/chisel 2>/dev/null || true
        if [[ ! -s /usr/local/bin/chisel ]]; then
            curl -fsSL "https://github.com/jpillora/chisel/releases/download/v1.9.1/chisel_1.9.1_linux_amd64.gz" -o /tmp/chisel.gz 2>/dev/null || \
            wget -q "https://github.com/jpillora/chisel/releases/download/v1.9.1/chisel_1.9.1_linux_amd64.gz" -O /tmp/chisel.gz 2>/dev/null || true
            if [[ -s /tmp/chisel.gz ]]; then
                gzip -dc /tmp/chisel.gz > /usr/local/bin/chisel 2>/dev/null || gunzip -c /tmp/chisel.gz > /usr/local/bin/chisel 2>/dev/null || true
                rm -f /tmp/chisel.gz 2>/dev/null || true
            fi
        fi
    elif [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
        curl -fsSL "https://raw.githubusercontent.com/soportecrisdev/SCRIP_CRISDEV/main/chisel-arm64" -o /usr/local/bin/chisel 2>/dev/null || \
        wget -q "https://raw.githubusercontent.com/soportecrisdev/SCRIP_CRISDEV/main/chisel-arm64" -O /usr/local/bin/chisel 2>/dev/null || true
        if [[ ! -s /usr/local/bin/chisel ]]; then
            curl -fsSL "https://github.com/jpillora/chisel/releases/download/v1.9.1/chisel_1.9.1_linux_arm64.gz" -o /tmp/chisel.gz 2>/dev/null || \
            wget -q "https://github.com/jpillora/chisel/releases/download/v1.9.1/chisel_1.9.1_linux_arm64.gz" -O /tmp/chisel.gz 2>/dev/null || true
            if [[ -s /tmp/chisel.gz ]]; then
                gzip -dc /tmp/chisel.gz > /usr/local/bin/chisel 2>/dev/null || gunzip -c /tmp/chisel.gz > /usr/local/bin/chisel 2>/dev/null || true
                rm -f /tmp/chisel.gz 2>/dev/null || true
            fi
        fi
    fi
    if [[ ! -s /usr/local/bin/chisel ]]; then
        curl -fsSL "https://raw.githubusercontent.com/soportecrisdev/SCRIP_CRISDEV/main/chisel" -o /usr/local/bin/chisel 2>/dev/null || true
    fi
fi
chmod 755 /usr/local/bin/chisel 2>/dev/null || true
ln -sfn /usr/local/bin/chisel /usr/bin/chisel 2>/dev/null || true
ln -sfn /usr/local/bin/chisel /bin/chisel 2>/dev/null || true
chmod 755 /bin/chisel /usr/bin/chisel 2>/dev/null || true

# Instalar Core BHTTP (Plano) y XHTTP (TLS/HTTP2)
echo -e "${YELLOW}[*]${NC} Descargando Cores BHTTP & BHTTP-TLS (XHTTP)..."
mkdir -p /etc/bhttp /etc/bhttp/certs
if [[ "$ARCH" == "x86_64" || "$ARCH" == "amd64" ]]; then
    curl -fsSL "https://raw.githubusercontent.com/soportecrisdev/SCRIP_CRISDEV/main/bhttp-server-amd64" -o /usr/local/bin/bhttp-server 2>/dev/null || \
    wget -q "https://raw.githubusercontent.com/soportecrisdev/SCRIP_CRISDEV/main/bhttp-server-amd64" -O /usr/local/bin/bhttp-server 2>/dev/null || true
    curl -fsSL "https://raw.githubusercontent.com/soportecrisdev/SCRIP_CRISDEV/main/xhttp-server-amd64" -o /usr/local/bin/xhttp-server 2>/dev/null || \
    wget -q "https://raw.githubusercontent.com/soportecrisdev/SCRIP_CRISDEV/main/xhttp-server-amd64" -O /usr/local/bin/xhttp-server 2>/dev/null || true
elif [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
    curl -fsSL "https://raw.githubusercontent.com/soportecrisdev/SCRIP_CRISDEV/main/bhttp-server-arm64" -o /usr/local/bin/bhttp-server 2>/dev/null || \
    wget -q "https://raw.githubusercontent.com/soportecrisdev/SCRIP_CRISDEV/main/bhttp-server-arm64" -O /usr/local/bin/bhttp-server 2>/dev/null || true
    curl -fsSL "https://raw.githubusercontent.com/soportecrisdev/SCRIP_CRISDEV/main/xhttp-server-arm64" -o /usr/local/bin/xhttp-server 2>/dev/null || \
    wget -q "https://raw.githubusercontent.com/soportecrisdev/SCRIP_CRISDEV/main/xhttp-server-arm64" -O /usr/local/bin/xhttp-server 2>/dev/null || true
fi
chmod 755 /usr/local/bin/bhttp-server /usr/local/bin/xhttp-server 2>/dev/null || true
ln -sfn /usr/local/bin/bhttp-server /usr/local/bin/bhttp 2>/dev/null || true
ln -sfn /usr/local/bin/bhttp-server /bin/bhttp-server 2>/dev/null || true
ln -sfn /usr/local/bin/bhttp-server /bin/bhttp 2>/dev/null || true
ln -sfn /usr/local/bin/xhttp-server /usr/local/bin/xhttp 2>/dev/null || true
ln -sfn /usr/local/bin/xhttp-server /bin/xhttp-server 2>/dev/null || true
ln -sfn /usr/local/bin/xhttp-server /bin/xhttp 2>/dev/null || true

# Generar certificado base para BHTTP TLS si no existe
if [[ ! -f /etc/bhttp/server.crt || ! -f /etc/bhttp/server.key ]]; then
    openssl req -x509 -newkey rsa:2048 -days 3650 -nodes \
        -keyout /etc/bhttp/server.key -out /etc/bhttp/server.crt -subj "/CN=crisdev.online" >/dev/null 2>&1 || true
    chmod 600 /etc/bhttp/server.key 2>/dev/null || true
    chmod 644 /etc/bhttp/server.crt 2>/dev/null || true
fi

# Instalar helper bhttp-connect para canal SSH sesión
cat > /usr/local/bin/bhttp-connect << 'EOF_BHTTP_CONN'
#!/usr/bin/env bash
DEST_HOST="${1:-127.0.0.1}"
DEST_PORT="${2:-22}"
if command -v nc >/dev/null 2>&1; then
    exec nc "$DEST_HOST" "$DEST_PORT"
elif command -v socat >/dev/null 2>&1; then
    exec socat - "TCP:$DEST_HOST:$DEST_PORT"
else
    exec 3<>/dev/tcp/"$DEST_HOST"/"$DEST_PORT" && { cat <&3 & cat >&3; }
fi
EOF_BHTTP_CONN
chmod 755 /usr/local/bin/bhttp-connect /bin/bhttp-connect 2>/dev/null || true

# Preparar directorio base para Hysteria (se configurará y activará desde el menú)
mkdir -p /etc/hysteria
systemctl daemon-reload >/dev/null 2>&1 || true

# Preparar estructura de BHTTP y BHTTP-TLS
mkdir -p /etc/bhttp /etc/bhttp/certs
touch /etc/bhttp/config 2>/dev/null || true

# Instalar Core HCR Relay (HTTP Custom Relay)
echo -e "${YELLOW}[*]${NC} Descargando Core HCR Relay (hcr-server)..."
mkdir -p /etc/hcr-server
touch /etc/hcr-server/ports.conf 2>/dev/null || true
chmod 600 /etc/hcr-server/ports.conf 2>/dev/null || true
if [[ ! -x /usr/local/bin/hcr-server && ! -x /bin/hcr-server ]]; then
    curl -fsSL "https://raw.githubusercontent.com/soportecrisdev/SCRIP_CRISDEV/main/hcr-server" -o /usr/local/bin/hcr-server 2>/dev/null || \
    wget -q "https://raw.githubusercontent.com/soportecrisdev/SCRIP_CRISDEV/main/hcr-server" -O /usr/local/bin/hcr-server 2>/dev/null || \
    curl -fsSL "https://www.dropbox.com/scl/fi/o8q0zs14a7xy03sk08a8j/hcr-server?rlkey=no7u3nggl0tw7i08rnadrao61&st=mb5b2zrg&dl=1" -o /usr/local/bin/hcr-server 2>/dev/null || \
    wget -q "https://www.dropbox.com/scl/fi/o8q0zs14a7xy03sk08a8j/hcr-server?rlkey=no7u3nggl0tw7i08rnadrao61&st=mb5b2zrg&dl=1" -O /usr/local/bin/hcr-server 2>/dev/null || true
fi
chmod 755 /usr/local/bin/hcr-server 2>/dev/null || true
ln -sfn /usr/local/bin/hcr-server /usr/bin/hcr-server 2>/dev/null || true
ln -sfn /usr/local/bin/hcr-server /bin/hcr-server 2>/dev/null || true
# Instalar Core UDP-Custom
echo -e "${YELLOW}[*]${NC} Descargando Core UDP-Custom (udp-custom)..."
mkdir -p /opt/udp-custom
if [[ ! -x /usr/local/bin/udp-custom && ! -x /bin/udp-custom ]]; then
    curl -fsSL "https://raw.githubusercontent.com/karl1999x/PandaScript/main/BINARIOS/udp-amd64.bin" -o /usr/local/bin/udp-custom 2>/dev/null || \
    curl -fsSL "https://github.com/AmnesiaPod/UDPCustom/releases/latest/download/udp-custom-linux-amd64" -o /usr/local/bin/udp-custom 2>/dev/null || \
    curl -fsSL "https://raw.githubusercontent.com/soportecrisdev/SCRIP_CRISDEV/main/udp-custom" -o /usr/local/bin/udp-custom 2>/dev/null || true
fi
chmod 755 /usr/local/bin/udp-custom 2>/dev/null || true
ln -sfn /usr/local/bin/udp-custom /usr/bin/udp-custom 2>/dev/null || true
ln -sfn /usr/local/bin/udp-custom /bin/udp-custom 2>/dev/null || true
ln -sfn /usr/local/bin/udp-custom /opt/udp-custom/server 2>/dev/null || true
chmod 755 /bin/udp-custom 2>/dev/null || true

# Instalar Core Hysteria v2 (apernet/hysteria v2)
echo -e "${YELLOW}[*]${NC} Descargando Core Hysteria v2..."
mkdir -p /etc/hysteria2 /etc/hysteria2/certs
if [[ ! -x /usr/local/bin/hysteria2 && ! -x /bin/hysteria2 ]]; then
    if [[ "$ARCH" == "x86_64" || "$ARCH" == "amd64" ]]; then
        curl -fsSL "https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-amd64" -o /usr/local/bin/hysteria2 2>/dev/null || \
        curl -fsSL "https://raw.githubusercontent.com/soportecrisdev/SCRIP_CRISDEV/main/hysteria2-amd64" -o /usr/local/bin/hysteria2 2>/dev/null || true
    elif [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
        curl -fsSL "https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-arm64" -o /usr/local/bin/hysteria2 2>/dev/null || \
        curl -fsSL "https://raw.githubusercontent.com/soportecrisdev/SCRIP_CRISDEV/main/hysteria2-arm64" -o /usr/local/bin/hysteria2 2>/dev/null || true
    fi
fi
chmod 755 /usr/local/bin/hysteria2 2>/dev/null || true
ln -sfn /usr/local/bin/hysteria2 /usr/bin/hysteria2 2>/dev/null || true
ln -sfn /usr/local/bin/hysteria2 /bin/hysteria2 2>/dev/null || true
chmod 755 /bin/hysteria2 2>/dev/null || true

echo -e "${GREEN}[✔]${NC} Módulos y servicios instalados correctamente."

echo -e "${YELLOW}[3/4]${NC} Creando accesos directos y enlaces globales..."
ln -sfn "$INSTALL_DIR/$BIN_NAME" /usr/local/bin/ssh-cris
ln -sfn "$INSTALL_DIR/$BIN_NAME" /usr/local/bin/cris
ln -sfn "$INSTALL_DIR/$BIN_NAME" /usr/local/bin/menu
ln -sfn "$INSTALL_DIR/$BIN_NAME" /usr/bin/ssh-cris 2>/dev/null || true
ln -sfn "$INSTALL_DIR/$BIN_NAME" /usr/bin/cris 2>/dev/null || true
ln -sfn "$INSTALL_DIR/$BIN_NAME" /usr/bin/menu 2>/dev/null || true
ln -sfn "$INSTALL_DIR/$BIN_NAME" /usr/bin/connection 2>/dev/null || true
ln -sfn "$INSTALL_DIR/$BIN_NAME" /usr/bin/conexao 2>/dev/null || true
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
sshplus_compat_alias bbr bbr-manager
sshplus_compat_alias tcptweaker tcptweaker.sh
sshplus_compat_alias udpcustom udp-custom-manager
sshplus_compat_alias udp-custom udp-custom-manager
sshplus_compat_alias hy2 hysteria2-manager
sshplus_compat_alias hysteria2 hysteria2-manager
sshplus_compat_alias hysteria2-manager hysteria2-manager
sshplus_compat_alias hcr hcr-manager
sshplus_compat_alias hcr-manager hcr-manager
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

# Configurar Banner Exclusivo de Login para HTTP Conexión / CRISDEV
sed -i '/HTTP_CONEXION_BANNER_START/,/HTTP_CONEXION_BANNER_END/d' /root/.bashrc 2>/dev/null || true
sed -i '/NOXURASSH_BANNER_START/,/NOXURASSH_BANNER_END/d' /root/.bashrc 2>/dev/null || true
sed -i '/SSHPLUS_BANNER_START/,/SSHPLUS_BANNER_END/d' /root/.bashrc 2>/dev/null || true
grep -v -E 'NoxuraSSH|by J DAVID AG|ALFAINTERNET|JDAVIDAG1' /root/.bashrc > /tmp/.bashrc.clean 2>/dev/null && mv -f /tmp/.bashrc.clean /root/.bashrc

cat <<'BASHRC_BANNER' >>/root/.bashrc
# HTTP_CONEXION_BANNER_START
CYAN=$'\033[1;38;2;76;228;255m'
NEON=$'\033[1;38;2;0;255;127m'
GOLD=$'\033[1;38;2;255;179;71m'
WHITE=$'\033[1;37m'
GREEN=$'\033[0;32m'
RESET=$'\033[0m'

echo "clear" >/dev/null 2>&1
echo -e "${CYAN}============================================================${RESET}"
echo -e "${CYAN}                      ⚡ HTTP CONEXIÓN ⚡${RESET}"
echo -e "${NEON}                     Master VPS by CRISDEV${RESET}"
echo -e "${CYAN}============================================================${RESET}"
echo -e "${GREEN}NOMBRE DEL SERVIDOR:${RESET} ${WHITE}$HOSTNAME${RESET}"
echo -e "${GREEN}SERVIDOR EN MARCHA:${RESET}  ${WHITE}$(uptime -p 2>/dev/null || uptime | awk '{print $3,$4}' | tr -d ',')${RESET}"
echo -e "${GREEN}FECHA:${RESET}               ${WHITE}$(date +'%d-%m-%Y')${RESET}"
echo -e "${GREEN}HORA:${RESET}                ${WHITE}$(date +'%T')${RESET}"
echo -e "${CYAN}============================================================${RESET}"
echo -e "${NEON}ESCRIBA:${RESET} ${WHITE}menu${RESET}  ${CYAN}o${RESET}  ${WHITE}ssh-cris${RESET}"
echo -e ""
# HTTP_CONEXION_BANNER_END
BASHRC_BANNER

echo -e "${GREEN}[✔]${NC} Banner exclusivo de bienvenida HTTP Conexión configurado."

echo -e "${YELLOW}[4/4]${NC} Optimizando puertos SSH base y firewall..."
sed -i 's/#*AllowTcpForwarding.*/AllowTcpForwarding yes/' /etc/ssh/sshd_config 2>/dev/null || true
sed -i 's/#*GatewayPorts.*/GatewayPorts yes/' /etc/ssh/sshd_config 2>/dev/null || true
sed -i 's/#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config 2>/dev/null || true
systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true

echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
echo -e "${WHITE}  ⚡ ¡SUITE HTTP CONEXIÓN (CRISDEV) INSTALADA CON ÉXITO! ⚡${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
echo -e "${WHITE}Escribe ${CYAN}ssh-cris${WHITE}, ${CYAN}cris${WHITE} o ${CYAN}menu${WHITE} para abrir el panel.${NC}"
echo ""

# Iniciar menú
exec "$INSTALL_DIR/$BIN_NAME"
