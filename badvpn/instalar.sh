#!/usr/bin/env bash
# ==============================================================================
# INSTALADOR PROFESIONAL — BADVPN UDPGW (AUTO-CALIBRADO 1GB RAM / 100+ USUARIOS)
# Ubicación: badvpn/instalar.sh
# Uso: bash instalar.sh [PUERTO]   (default: 7300)
# ==============================================================================

set -u

PORT="${1:-7300}"
[[ ! "$PORT" =~ ^[0-9]+$ ]] && PORT="7300"

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

install_badvpn_binary() {
    if [[ -x /usr/local/bin/badvpn-udpgw || -x /bin/badvpn-udpgw ]]; then
        [[ ! -x /usr/local/bin/badvpn-udpgw && -x /bin/badvpn-udpgw ]] && ln -sf /bin/badvpn-udpgw /usr/local/bin/badvpn-udpgw
        [[ ! -x /bin/badvpn-udpgw && -x /usr/local/bin/badvpn-udpgw ]] && ln -sf /usr/local/bin/badvpn-udpgw /bin/badvpn-udpgw
        return 0
    fi

    echo -e "${C_YELLOW}[*] Compilando binario oficial badvpn-udpgw...${NC}"
    if command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || true
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq build-essential cmake make gcc g++ >/dev/null 2>&1 || true
    fi

    local workdir="/usr/local/src"
    mkdir -p "$workdir"
    cd "$workdir" || return 1
    rm -rf badvpn-1.999.130 badvpn-build badvpn.tar.gz 2>/dev/null || true

    curl -fL --retry 3 "https://github.com/ambrop72/badvpn/archive/refs/tags/1.999.130.tar.gz" -o badvpn.tar.gz 2>/dev/null || \
    wget -q "https://github.com/ambrop72/badvpn/archive/refs/tags/1.999.130.tar.gz" -O badvpn.tar.gz 2>/dev/null || true

    if [[ -s badvpn.tar.gz ]]; then
        tar -xzf badvpn.tar.gz >/dev/null 2>&1 || true
        mkdir -p badvpn-build
        cd badvpn-build || return 1
        cmake ../badvpn-1.999.130 -DCMAKE_INSTALL_PREFIX=/usr/local -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 >/dev/null 2>&1 || true
        make -j"$(nproc 2>/dev/null || echo 1)" install >/dev/null 2>&1 || true
    fi

    if [[ -x /usr/local/bin/badvpn-udpgw ]]; then
        ln -sf /usr/local/bin/badvpn-udpgw /bin/badvpn-udpgw
        chmod 755 /usr/local/bin/badvpn-udpgw /bin/badvpn-udpgw 2>/dev/null || true
        return 0
    fi
    return 1
}

ensure_swap_for_low_ram() {
    local ram_mb="$1"
    if (( ram_mb <= 1536 )); then
        local swap_mb
        swap_mb=$(free -m 2>/dev/null | awk '/^Swap:/ {print $2+0}')
        if (( swap_mb < 512 )) && [[ ! -f /swapfile ]]; then
            echo -e "${C_YELLOW}[*] VPS de ${ram_mb} MB RAM sin SWAP detectado. Creando /swapfile de 1 GB anti-OOM...${NC}"
            (fallocate -l 1G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=1024 status=none 2>/dev/null) && \
            chmod 600 /swapfile && \
            mkswap /swapfile >/dev/null 2>&1 && \
            swapon /swapfile >/dev/null 2>&1 || true
            if swapon --show 2>/dev/null | grep -q '/swapfile'; then
                grep -q '/swapfile' /etc/fstab 2>/dev/null || echo '/swapfile none swap sw 0 0' >> /etc/fstab
                echo -e "${C_GREEN}✔ SWAP de 1 GB activado (protección anti-OOM Killer lista).${NC}"
            fi
        fi
    fi
}

apply_1gb_high_concurrency_tuning() {
    local ram_mb="$1"
    echo -e "${C_YELLOW}[*] Aplicando tuning de Kernel para 100+ usuarios (${ram_mb} MB RAM)...${NC}"

    modprobe tcp_bbr 2>/dev/null || true
    modprobe nf_conntrack 2>/dev/null || true

    # Buffers calibrados según RAM para evitar OOM bajo 100-300 conexiones
    local max_buf="4194304"
    local ct_max="131072"
    if (( ram_mb >= 3500 )); then
        max_buf="16777216"
        ct_max="262144"
    fi

    mkdir -p /etc/sysctl.d
    cat > /etc/sysctl.d/97-crisdev-badvpn-tuning.conf <<EOF_SYS
# CRISDEV BadVPN + WSProxy High-Concurrency Tuning (${ram_mb}MB RAM)
vm.swappiness = 15
vm.vfs_cache_pressure = 50

# Congestión BBR y baja latencia Juegos / VoIP
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_mtu_probing = 2
net.ipv4.tcp_base_mss = 1024
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15

# Anti-CGNAT Keepalive
net.ipv4.tcp_keepalive_time = 20
net.ipv4.tcp_keepalive_intvl = 5
net.ipv4.tcp_keepalive_probes = 3

# Buffers seguros para 100-300 usuarios sin disparar OOM Killer
net.core.rmem_max = ${max_buf}
net.core.wmem_max = ${max_buf}
net.core.rmem_default = 65536
net.core.wmem_default = 65536
net.ipv4.tcp_rmem = 4096 65536 ${max_buf}
net.ipv4.tcp_wmem = 4096 65536 ${max_buf}
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535

# Anti-saturación conntrack UDP (Juegos / Llamadas / DNS)
net.netfilter.nf_conntrack_max = ${ct_max}
net.netfilter.nf_conntrack_udp_timeout = 30
net.netfilter.nf_conntrack_udp_timeout_stream = 60
EOF_SYS
    sysctl -p /etc/sysctl.d/97-crisdev-badvpn-tuning.conf >/dev/null 2>&1 || true

    # TCP MSS Clamping anti-bloqueo MTU de operadoras móviles
    if command -v iptables >/dev/null 2>&1; then
        iptables -t mangle -C POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
        iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
        iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
        iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
    fi

    # Afinar OpenSSH para 100+ sesiones simultáneas con menor consumo de RAM/CPU
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
echo -e "${C_BLUE_BG}   INSTALACIÓN OPTIMIZADA — BADVPN UDPGW (PUERTO ${PORT})   ${NC}\n"

# 1. Detectar RAM real y auto-calibrar perfil
RAM_MB=$(free -m 2>/dev/null | awk '/^Mem:/ {print $2+0}')
[[ -z "$RAM_MB" || "$RAM_MB" -eq 0 ]] && RAM_MB=1024

if (( RAM_MB <= 1536 )); then
    PROFILE_NAME="VPS 1 GB RAM (100-300 usuarios · Anti-OOM)"
    MAX_CLIENTS=512
    MAX_CONN_PER_CLI=16
    SNDBUF=65536
    MEM_MAX="180M"
    CPU_QUOTA="60%"
elif (( RAM_MB <= 3200 )); then
    PROFILE_NAME="VPS 2 GB RAM (300-600 usuarios · Alto Rendimiento)"
    MAX_CLIENTS=1024
    MAX_CONN_PER_CLI=24
    SNDBUF=65536
    MEM_MAX="320M"
    CPU_QUOTA="75%"
else
    PROFILE_NAME="VPS 4+ GB RAM (600+ usuarios · Máxima Escala)"
    MAX_CLIENTS=2048
    MAX_CONN_PER_CLI=32
    SNDBUF=131072
    MEM_MAX="512M"
    CPU_QUOTA="85%"
fi

echo -e "${C_WHITE}• RAM Detectada   : ${C_GREEN}${RAM_MB} MB${NC}"
echo -e "${C_WHITE}• Perfil Aplicado : ${C_CYAN}${PROFILE_NAME}${NC}"
echo -e "${C_WHITE}• Parámetros      : ${C_YELLOW}--max-clients ${MAX_CLIENTS} --max-connections-for-client ${MAX_CONN_PER_CLI} --client-socket-sndbuf ${SNDBUF}${NC}"
echo -e "${C_WHITE}• Blindaje Systemd: ${C_GREEN}MemoryMax=${MEM_MAX} │ CPUQuota=${CPU_QUOTA} │ OOMScoreAdjust=-500${NC}\n"

# 2. Garantizar binario badvpn-udpgw
if ! install_badvpn_binary; then
    echo -e "${C_RED}✖ No se pudo instalar/compilar badvpn-udpgw.${NC}"
    exit 1
fi

# 3. Limpiar screens legacy y autostart conflictivos para ese puerto
for sid in $(screen -ls 2>/dev/null | grep -E 'badvpn|udpvpn' | awk '{print $1}'); do
    screen -r -S "$sid" -X quit 2>/dev/null || true
done
screen -wipe >/dev/null 2>&1 || true
[[ -f /etc/autostart ]] && sed -i '/udpvpn\|badvpn-udpgw/d' /etc/autostart 2>/dev/null || true

# 4. SWAP anti-OOM + Tuning de Kernel
ensure_swap_for_low_ram "$RAM_MB"
apply_1gb_high_concurrency_tuning "$RAM_MB"

# 5. Crear servicio systemd blindado
SVC_NAME="badvpn-udpgw.service"
[[ "$PORT" != "7300" ]] && SVC_NAME="badvpn-udpgw-${PORT}.service"
SVC_FILE="/etc/systemd/system/${SVC_NAME}"

cat > "$SVC_FILE" <<EOF_SVC
[Unit]
Description=CRISDEV BadVPN UDPGW Port ${PORT} (${PROFILE_NAME})
After=network-online.target ssh.service
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/badvpn-udpgw --listen-addr 127.0.0.1:${PORT} --max-clients ${MAX_CLIENTS} --max-connections-for-client ${MAX_CONN_PER_CLI} --client-socket-sndbuf ${SNDBUF}
Restart=always
RestartSec=1
OOMScoreAdjust=-500
LimitNOFILE=65535
MemoryMax=${MEM_MAX}
CPUQuota=${CPU_QUOTA}
TasksMax=64

[Install]
WantedBy=multi-user.target
EOF_SVC

systemctl daemon-reload
systemctl enable --now "$SVC_NAME" >/dev/null 2>&1 || true
systemctl restart "$SVC_NAME" 2>/dev/null || true

sleep 1
if ss -tlpn 2>/dev/null | grep -qE "127\.0\.0\.1:${PORT}[[:space:]].*badvpn-udpgw"; then
    echo -e "\n${C_GREEN}✔ BADVPN UDPGW ACTIVADO Y BLINDADO EN 127.0.0.1:${PORT}${NC}"
    echo -e "${C_WHITE}  • Listo para 100+ usuarios simultáneos en Juegos y Llamadas VoIP sin tumbar wsproxy.${NC}"
else
    echo -e "\n${C_RED}✖ Error al iniciar ${SVC_NAME}. Últimos logs:${NC}"
    journalctl -u "$SVC_NAME" -n 10 --no-pager 2>/dev/null || true
    exit 1
fi
