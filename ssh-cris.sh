#!/usr/bin/env bash
# ==============================================================================
#  SSH-CRIS v1 — VPS Master VPN Suite & Server Manager
#  Autor: CRISDEV / HTTP Conexión
#  Soporte: OpenSSH, Dropbear, SSL/Stunnel, BHTTP Multi-Puerto Relay (Wakko Engine),
#           UDP CRIS (Hysteria Engine), SlowDNS (DNSTT), BadVPN UDPGW 7300,
#           Xray/V2Ray, Limitador Multi-Login, Diagnóstico y Exportador GEN.
# ==============================================================================
set -Euo pipefail

VERSION="v1.0-CRISDEV"
TITLE="SSH-CRIS MASTER SUITE"
INSTALL_DIR="/opt/ssh-cris"
BHTTP_BASE="/etc/wakkodev-bhttp"
BHTTP_CONFIG="$BHTTP_BASE/config"
USER_DATABASE="/etc/ssh-cris/users.db"
LIMITER_LOG="/var/log/ssh-cris-limiter.log"

AMD64_BHTTP="https://www.dropbox.com/scl/fi/xe5uut31ybiiwpio8njlp/wakkodev-bhttp-server-amd64?rlkey=9f92nqgiezysxoq4xjta4lpfc&st=8ezemtuj&dl=1"
ARM64_BHTTP="https://www.dropbox.com/scl/fi/h3pruw07ecgh4iph24gbm/wakkodev-bhttp-server-arm64?rlkey=hzmvl36pl50k7d9qqkgi4ltzz&st=fs95gvtz&dl=1"

# Colores ANSI
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
BLUE='\033[1;34m'
MAGENTA='\033[1;35m'
WHITE='\033[1;37m'
DIM='\033[2m'
NC='\033[0m'

ok()    { printf "%b[✔]%b %s\n" "$GREEN" "$NC" "$*"; }
info()  { printf "%b[ℹ]%b %s\n" "$CYAN" "$NC" "$*"; }
warn()  { printf "%b[⚠]%b %s\n" "$YELLOW" "$NC" "$*"; }
fail()  { printf "%b[✘]%b %s\n" "$RED" "$NC" "$*" >&2; }
pause() { echo ""; read -r -p " Presiona [ENTER] para continuar..." _ || true; }

need_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        fail "Este script requiere permisos de root. Ejecuta con: sudo $0"
        exit 1
    fi
}

mkdir -p /etc/ssh-cris /etc/wakkodev-bhttp /etc/hysteria /etc/stunnel /etc/slowdns
touch "$USER_DATABASE"

get_public_ip() {
    local ip
    ip=$(curl -s --connect-timeout 3 https://api.ipify.org || curl -s --connect-timeout 3 https://ifconfig.me || hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")
    echo "$ip"
}

# ─────────────────────────────────────────────────────────────────────────────
#  ESCANEO EN VIVO DE PUERTOS Y PROTOCOLOS
# ─────────────────────────────────────────────────────────────────────────────
scan_bhttp_ports() {
    # Detecta puertos escuchando por el binario wakkodev-bhttp-server o configurados en systemd
    local ports=()
    local raw_ports
    raw_ports=$(ss -tlpn 2>/dev/null | grep -E "wakkodev|bhttp" | awk '{print $4}' | awk -F: '{print $NF}' | sort -n -u)
    
    if [[ -n "$raw_ports" ]]; then
        for p in $raw_ports; do
            [[ "$p" =~ ^[0-9]+$ ]] && ports+=("$p")
        done
    fi

    # Si no están corriendo en ss, verificar si hay servicios creados
    if [[ ${#ports[@]} -eq 0 ]]; then
        local svc_ports
        svc_ports=$(grep -h -o -E "\-\-port [0-9]+" /etc/systemd/system/wakkodev-bhttp*.service 2>/dev/null | awk '{print $2}' | sort -n -u || true)
        for p in $svc_ports; do
            [[ "$p" =~ ^[0-9]+$ ]] && ports+=("$p")
        done
    fi

    echo "${ports[@]:-}"
}

get_bhttp_live_status() {
    local ports_arr
    read -r -a ports_arr <<< "$(scan_bhttp_ports)"
    local total=${#ports_arr[@]}

    if [[ $total -gt 0 ]]; then
        local ports_str
        ports_str=$(IFS=", "; echo "${ports_arr[*]}")
        echo -e "${GREEN}[ONLINE]${NC} ${WHITE}Puertos: ${CYAN}${ports_str}${NC} ${YELLOW}(${total} activo$([[ $total -gt 1 ]] && echo 's'))${NC}"
    else
        echo -e "${RED}[OFFLINE]${NC} ${DIM}Desactivado${NC}"
    fi
}

get_udpcris_live_status() {
    local uport=""
    if [[ -f /etc/hysteria/config.json ]]; then
        uport=$(grep -o '"listen": "[^"]*"' /etc/hysteria/config.json 2>/dev/null | cut -d: -f3 | tr -d '":, ' || echo "")
        [[ -z "$uport" ]] && uport=$(grep -o '"listen": ":[0-9]*"' /etc/hysteria/config.json 2>/dev/null | cut -d: -f3 | tr -d '":, ' || echo "")
    fi
    [[ -z "$uport" ]] && uport="36712"

    local is_running=false
    if systemctl is-active --quiet hysteria-server.service 2>/dev/null || pgrep -f hysteria >/dev/null 2>&1; then
        is_running=true
    fi

    local badvpn_status="OFF"
    if systemctl is-active --quiet badvpn.service 2>/dev/null || pgrep -f badvpn-udpgw >/dev/null 2>&1; then
        badvpn_status="7300"
    fi

    local hop_status="OFF"
    if iptables -t nat -L PREROUTING -n 2>/dev/null | grep -q "6000:50000"; then
        hop_status="6000:50000"
    fi

    if [[ "$is_running" == "true" ]]; then
        echo -e "${GREEN}[ONLINE]${NC} ${WHITE}UDP: ${CYAN}${uport}${WHITE} | BadVPN: ${CYAN}${badvpn_status}${WHITE} | Hop: ${CYAN}${hop_status}${NC}"
    else
        echo -e "${RED}[OFFLINE]${NC} ${DIM}Desactivado${NC}"
    fi
}

get_ssh_live_status() {
    local is_running=false
    if systemctl is-active --quiet sshd 2>/dev/null || systemctl is-active --quiet ssh 2>/dev/null || pgrep -f sshd >/dev/null 2>&1; then
        is_running=true
    fi
    if [[ "$is_running" == "true" ]]; then
        echo -e "${GREEN}[ONLINE]${NC} ${CYAN}Puerto 22${NC}"
    else
        echo -e "${RED}[OFFLINE]${NC}"
    fi
}

get_ssl_live_status() {
    if systemctl is-active --quiet stunnel4 2>/dev/null || pgrep -f stunnel4 >/dev/null 2>&1; then
        echo -e "${GREEN}[ONLINE]${NC} ${CYAN}Puerto 443 -> 22${NC}"
    else
        echo -e "${RED}[OFFLINE]${NC}"
    fi
}

get_dropbear_live_status() {
    if systemctl is-active --quiet dropbear 2>/dev/null || pgrep -f dropbear >/dev/null 2>&1; then
        echo -e "${GREEN}[ONLINE]${NC} ${CYAN}80, 8080, 442, 8888${NC}"
    else
        echo -e "${RED}[OFFLINE]${NC}"
    fi
}

get_slowdns_live_status() {
    if pgrep -f dnstt-server >/dev/null 2>&1 || systemctl is-active --quiet dnstt-server 2>/dev/null; then
        local ns; ns=$(cat /etc/slowdns/ns.txt 2>/dev/null || echo "Configurado")
        echo -e "${GREEN}[ONLINE]${NC} ${CYAN}Puerto 53${NC} (${WHITE}${ns}${NC})"
    else
        echo -e "${RED}[OFFLINE]${NC}"
    fi
}

get_online_users_count() {
    who 2>/dev/null | grep -E "pts|sshd" | wc -l || echo "0"
}

get_total_users_count() {
    [[ -f "$USER_DATABASE" ]] && wc -l < "$USER_DATABASE" || echo "0"
}

draw_header() {
    clear
    local ip; ip=$(get_public_ip)
    local os; os=$(lsb_release -sd 2>/dev/null || cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d= -f2 | tr -d '\"' || echo 'Linux')
    local ram_used; ram_used=$(free -m | awk '/Mem:/ {print $3}')
    local ram_total; ram_total=$(free -m | awk '/Mem:/ {print $2}')
    local ram_pct; ram_pct=$(( ram_used * 100 / (ram_total > 0 ? ram_total : 1) ))
    local cpu_load; cpu_load=$(top -bn1 2>/dev/null | grep "Cpu(s)" | awk '{print $2 + $4"%"}' || echo "N/A")
    local uptime_str; uptime_str=$(uptime -p 2>/dev/null | sed 's/up //' || uptime | awk -F'( |,|:)+' '{print $6"h "$7"m"}')
    local users_online; users_online=$(get_online_users_count)
    local users_total; users_total=$(get_total_users_count)

    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${WHITE}             ⚡ SSH-CRIS MASTER SUITE ${VERSION} ⚡               ${CYAN}║${NC}"
    echo -e "${CYAN}║${DIM}           Control Maestro de Túneles VPN & Servidores            ${CYAN}║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════╝${NC}"
    printf " ${WHITE}🌐 IP Pública:    ${GREEN}%-18s${WHITE}   🖥️  SO:  ${YELLOW}%s${NC}\n" "$ip" "$os"
    printf " ${WHITE}💾 Memoria RAM:   ${GREEN}%-18s${WHITE}   ⚡ CPU: ${YELLOW}%s | %s${NC}\n" "${ram_used}MB / ${ram_total}MB (${ram_pct}%)" "$cpu_load" "$uptime_str"
    printf " ${WHITE}👥 SSH Online:    ${GREEN}%-18s${WHITE}   📁  DB:  ${YELLOW}%s usuario(s)${NC}\n" "${users_online} conectado(s)" "$users_total"
    echo -e "${CYAN}─────────────────────── ESTADO DE PROTOCOLOS ───────────────────────${NC}"
    echo -e " ${WHITE}• BHTTP Relay:  $(get_bhttp_live_status)"
    echo -e " ${WHITE}• UDP CRIS:     $(get_udpcris_live_status)"
    echo -e " ${WHITE}• OpenSSH:      $(get_ssh_live_status)"
    echo -e " ${WHITE}• Stunnel SSL:  $(get_ssl_live_status)"
    echo -e " ${WHITE}• Dropbear:     $(get_dropbear_live_status)"
    echo -e " ${WHITE}• SlowDNS:      $(get_slowdns_live_status)"
    echo -e "${CYAN}────────────────────────────────────────────────────────────────────${NC}"
    echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
#  1. GESTIÓN DE USUARIOS SSH / VPN
# ─────────────────────────────────────────────────────────────────────────────
menu_users() {
    while true; do
        draw_header
        echo -e "${YELLOW}══ GESTIÓN DE USUARIOS SSH / VPN ════════════════════════════════${NC}"
        echo -e " ${GREEN}1)${WHITE} Crear Usuario SSH/VPN"
        echo -e " ${GREEN}2)${WHITE} Modificar Contraseña / Renovar Días"
        echo -e " ${GREEN}3)${WHITE} Eliminar Usuario"
        echo -e " ${GREEN}4)${WHITE} Bloquear / Suspender Usuario"
        echo -e " ${GREEN}5)${WHITE} Desbloquear Usuario"
        echo -e " ${GREEN}6)${WHITE} Listar Usuarios (Activos / Vencidos)"
        echo -e " ${GREEN}7)${WHITE} Monitor de Conexiones Online en Vivo"
        echo -e " ${GREEN}8)${WHITE} Configurar Limitador Multi-Login (Auto-Kill)"
        echo -e " ${RED}0)${WHITE} Volver al Menú Principal"
        echo -e "${YELLOW}────────────────────────────────────────────────────────────────${NC}"
        read -r -p " Selecciona una opción [0-8]: " opt

        case "$opt" in
            1) crear_usuario ;;
            2) renovar_usuario ;;
            3) eliminar_usuario ;;
            4) bloquear_usuario ;;
            5) desbloquear_usuario ;;
            6) listar_usuarios ;;
            7) monitor_conexiones ;;
            8) configurar_limitador ;;
            0) break ;;
            *) warn "Opción inválida"; sleep 1 ;;
        esac
    done
}

crear_usuario() {
    draw_header
    echo -e "${GREEN}── CREAR NUEVO USUARIO ──────────────────────────────────────────${NC}"
    read -r -p " Nombre de usuario: " username
    [[ -z "$username" ]] && { fail "El nombre no puede estar vacío"; pause; return; }

    if id "$username" >/dev/null 2>&1; then
        fail "El usuario '$username' ya existe en el sistema."
        pause; return
    fi

    read -r -p " Contraseña: " password
    [[ -z "$password" ]] && { fail "La contraseña no puede estar vacía"; pause; return; }

    read -r -p " Días de duración (ej: 30): " days
    [[ ! "$days" =~ ^[0-9]+$ ]] && days=30

    read -r -p " Límite de conexiones simultáneas (ej: 1 o 2): " limit
    [[ ! "$limit" =~ ^[0-9]+$ ]] && limit=1

    local exp_date
    exp_date=$(date -d "+$days days" "+%Y-%m-%d" 2>/dev/null || date -v+${days}d "+%Y-%m-%d")

    useradd -M -s /bin/false -e "$exp_date" "$username" 2>/dev/null || useradd -M -s /bin/false "$username"
    echo "$username:$password" | chpasswd

    # Guardar en base de datos local: username:limit:exp_date
    sed -i "/^$username:/d" "$USER_DATABASE" 2>/dev/null || true
    echo "$username:$limit:$exp_date" >> "$USER_DATABASE"

    ok "Usuario '$username' creado exitosamente."
    echo -e "${WHITE}• Vence el: ${YELLOW}$exp_date ($days días)${NC}"
    echo -e "${WHITE}• Límite:   ${GREEN}$limit conexión(es)${NC}"
    pause
}

renovar_usuario() {
    draw_header
    echo -e "${GREEN}── RENOVAR USUARIO / CAMBIAR CONTRASEÑA ─────────────────────────${NC}"
    read -r -p " Nombre de usuario: " username
    if ! id "$username" >/dev/null 2>&1; then
        fail "El usuario '$username' no existe."
        pause; return
    fi

    read -r -p " Nueva contraseña (deja vacío para no cambiar): " password
    if [[ -n "$password" ]]; then
        echo "$username:$password" | chpasswd
        ok "Contraseña actualizada."
    fi

    read -r -p " Agregar días adicionales (ej: 30, o 0 para no cambiar): " add_days
    if [[ "$add_days" =~ ^[0-9]+$ ]] && [[ "$add_days" -gt 0 ]]; then
        local exp_date
        exp_date=$(date -d "+$add_days days" "+%Y-%m-%d" 2>/dev/null || date -v+${add_days}d "+%Y-%m-%d")
        chage -E "$exp_date" "$username" 2>/dev/null || true
        ok "Fecha de vencimiento extendida a $exp_date."
        local limit; limit=$(grep "^$username:" "$USER_DATABASE" 2>/dev/null | cut -d: -f2 || echo "1")
        sed -i "/^$username:/d" "$USER_DATABASE" 2>/dev/null || true
        echo "$username:${limit:-1}:$exp_date" >> "$USER_DATABASE"
    fi
    pause
}

eliminar_usuario() {
    draw_header
    echo -e "${RED}── ELIMINAR USUARIO ─────────────────────────────────────────────${NC}"
    read -r -p " Nombre de usuario a eliminar: " username
    if ! id "$username" >/dev/null 2>&1; then
        fail "El usuario '$username' no existe."
        pause; return
    fi
    userdel -f "$username" 2>/dev/null || true
    sed -i "/^$username:/d" "$USER_DATABASE" 2>/dev/null || true
    ok "Usuario '$username' eliminado correctamente."
    pause
}

bloquear_usuario() {
    draw_header
    echo -e "${YELLOW}── BLOQUEAR / SUSPENDER USUARIO ─────────────────────────────────${NC}"
    read -r -p " Usuario a bloquear: " username
    if ! id "$username" >/dev/null 2>&1; then
        fail "El usuario '$username' no existe."
        pause; return
    fi
    passwd -l "$username" >/dev/null 2>&1
    pkill -u "$username" 2>/dev/null || true
    ok "Usuario '$username' suspendido y sesiones desconectadas."
    pause
}

desbloquear_usuario() {
    draw_header
    echo -e "${GREEN}── DESBLOQUEAR USUARIO ──────────────────────────────────────────${NC}"
    read -r -p " Usuario a desbloquear: " username
    if ! id "$username" >/dev/null 2>&1; then
        fail "El usuario '$username' no existe."
        pause; return
    fi
    passwd -u "$username" >/dev/null 2>&1
    ok "Usuario '$username' reactivado."
    pause
}

listar_usuarios() {
    draw_header
    echo -e "${YELLOW}── LISTADO DE USUARIOS REGISTRADOS ──────────────────────────────${NC}"
    printf "%-18s %-14s %-18s %-10s\n" "USUARIO" "VENCE" "ESTADO" "LÍMITE"
    echo "────────────────────────────────────────────────────────────────"
    local now_sec; now_sec=$(date +%s)

    while IFS=: read -r u limit exp; do
        [[ -z "$u" ]] && continue
        local exp_sec; exp_sec=$(date -d "$exp" +%s 2>/dev/null || echo 0)
        local status
        if [[ $exp_sec -lt $now_sec ]]; then
            status="${RED}VENCIDO${NC}"
        else
            status="${GREEN}ACTIVO${NC}"
        fi
        printf "%-18s %-14s %-26b %-10s\n" "$u" "$exp" "$status" "${limit} conn"
    done < "$USER_DATABASE"
    pause
}

monitor_conexiones() {
    draw_header
    echo -e "${CYAN}── CONEXIONES SSH ONLINE EN VIVO ────────────────────────────────${NC}"
    printf "%-18s %-12s %-20s\n" "USUARIO" "PID" "DESDE"
    echo "────────────────────────────────────────────────────────────────"
    who | grep -E "pts|sshd" | awk '{printf "%-18s %-12s %-20s\n", $1, $2, $5}' || echo "No hay conexiones activas"
    pause
}

configurar_limitador() {
    draw_header
    echo -e "${CYAN}── CONFIGURAR LIMITADOR MULTI-LOGIN (AUTO-KILL) ──────────────────${NC}"
    info "El limitador desconecta automáticamente a quienes superen sus conexiones permitidas."

    cat > /usr/local/bin/ssh-cris-limiter << 'EOF'
#!/usr/bin/env bash
DB="/etc/ssh-cris/users.db"
[[ ! -f "$DB" ]] && exit 0

while IFS=: read -r user limit exp; do
    [[ -z "$user" ]] && continue
    conns=$(ps -u "$user" -o pid,cmd 2>/dev/null | grep -E "sshd|dropbear" | grep -v "grep" | wc -l)
    if [[ "$conns" -gt "$limit" ]]; then
        pids=$(ps -u "$user" -o pid,cmd 2>/dev/null | grep -E "sshd|dropbear" | grep -v "grep" | awk '{print $1}')
        for pid in $pids; do
            kill -9 "$pid" 2>/dev/null || true
        done
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Multi-login detectado en $user ($conns/$limit) - Sesiones terminadas" >> /var/log/ssh-cris-limiter.log
    fi
done < "$DB"
EOF
    chmod +x /usr/local/bin/ssh-cris-limiter

    if ! crontab -l 2>/dev/null | grep -q "ssh-cris-limiter"; then
        (crontab -l 2>/dev/null; echo "* * * * * /usr/local/bin/ssh-cris-limiter >/dev/null 2>&1") | crontab -
    fi
    ok "Limitador multi-login configurado y activo en segundo plano."
    pause
}

# ─────────────────────────────────────────────────────────────────────────────
#  2. BHTTP MULTI-PUERTO RELAY (WAKKO ENGINE INTEGRADO)
# ─────────────────────────────────────────────────────────────────────────────
menu_bhttp() {
    while true; do
        draw_header
        local ports_arr
        read -r -a ports_arr <<< "$(scan_bhttp_ports)"
        local total=${#ports_arr[@]}

        echo -e "${GREEN}══ BHTTP MULTI-PUERTO RELAY (WAKKO ENGINE) ═════════════════════${NC}"
        echo -e " ${WHITE}Puertos BHTTP Activos: ${CYAN}${total}${WHITE} | Lista: ${YELLOW}${ports_arr[*]:-Ninguno}${NC}"
        echo -e "${GREEN}────────────────────────────────────────────────────────────────${NC}"
        echo -e " ${GREEN}1)${WHITE} Instalar / Actualizar Motor BHTTP Relay"
        echo -e " ${GREEN}2)${WHITE} Configurar Puerto Principal BHTTP (ej: 8080 -> SSH 22)"
        echo -e " ${GREEN}3)${WHITE} Abrir Puerto Adicional (Multi-Puerto BHTTP: 80, 8888, 3128)"
        echo -e " ${GREEN}4)${WHITE} Listar y Contar Puertos Activos"
        echo -e " ${GREEN}5)${WHITE} Eliminar un Puerto BHTTP Específico"
        echo -e " ${GREEN}6)${WHITE} Probar Conectividad BHTTP -> Backend SSH (Socket Test)"
        echo -e " ${GREEN}7)${WHITE} Ver Logs en Vivo de BHTTP"
        echo -e " ${YELLOW}8)${WHITE} Aplicar Optimización Kernel TCP BBR"
        echo -e " ${RED}9)${WHITE} Detener / Desinstalar Todos los Servicios BHTTP"
        echo -e " ${RED}0)${WHITE} Volver al Menú Principal"
        echo -e "${GREEN}────────────────────────────────────────────────────────────────${NC}"
        read -r -p " Selecciona una opción [0-9]: " opt

        case "$opt" in
            1) instalar_motor_bhttp ;;
            2) config_puerto_principal_bhttp ;;
            3) config_multipuerro_bhttp ;;
            4) listar_puertos_bhttp ;;
            5) eliminar_puerto_bhttp ;;
            6) test_conectividad_bhttp ;;
            7) logs_bhttp ;;
            8) optimizar_red_bhttp ;;
            9) desinstalar_bhttp ;;
            0) break ;;
            *) warn "Opción inválida"; sleep 1 ;;
        esac
    done
}

instalar_motor_bhttp() {
    draw_header
    info "Descargando e instalando motor BHTTP Relay de alto rendimiento..."
    local arch; arch=$(uname -m)
    local url=""
    if [[ "$arch" == "x86_64" || "$arch" == "amd64" ]]; then
        url="$AMD64_BHTTP"
    elif [[ "$arch" == "aarch64" || "$arch" == "arm64" ]]; then
        url="$ARM64_BHTTP"
    else
        fail "Arquitectura $arch no soportada para BHTTP."
        pause; return
    fi

    mkdir -p "$BHTTP_BASE"
    systemctl stop wakkodev-bhttp.service 2>/dev/null || true
    curl -fL --retry 3 "$url" -o /usr/local/bin/wakkodev-bhttp-server
    chmod 755 /usr/local/bin/wakkodev-bhttp-server

    ok "Motor BHTTP instalado en /usr/local/bin/wakkodev-bhttp-server"
    pause
}

config_puerto_principal_bhttp() {
    draw_header
    if [[ ! -f /usr/local/bin/wakkodev-bhttp-server ]]; then
        warn "Motor BHTTP no encontrado. Se instalará automáticamente."
        instalar_motor_bhttp
    fi

    echo -e "${GREEN}── CONFIGURAR PUERTO PRINCIPAL BHTTP ────────────────────────────${NC}"
    read -r -p " Ingresa el puerto principal para BHTTP (ej: 8080 o 80): " bport
    [[ ! "$bport" =~ ^[0-9]+$ ]] && bport=8080

    read -r -p " Puerto SSH destino (Backend, default 22): " backend_port
    [[ ! "$backend_port" =~ ^[0-9]+$ ]] && backend_port=22

    mkdir -p "$BHTTP_BASE"
    cat > "$BHTTP_CONFIG" << EOF
BHTTP_PORT=$bport
BACKEND_PORT=$backend_port
SESSION_TTL=180
MAX_SESSIONS=4096
PROFILE=performance
EOF

    cat > /etc/systemd/system/wakkodev-bhttp.service << EOF
[Unit]
Description=CRISDEV BHTTP Relay Service (Port $bport)
After=network-online.target ssh.service
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=-$BHTTP_CONFIG
ExecStart=/usr/local/bin/wakkodev-bhttp-server --listen 0.0.0.0 --port $bport --backend-host 127.0.0.1 --backend-port $backend_port --session-ttl 180 --max-sessions 4096 --request-timeout 30 --read-wait-ms 2 --sequence-wait 6 --max-requests-per-conn 2048
Restart=always
RestartSec=1
LimitNOFILE=524288

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now wakkodev-bhttp.service
    ufw allow "$bport"/tcp 2>/dev/null || true

    ok "BHTTP Relay activo en puerto TCP $bport -> SSH $backend_port"
    pause
}

config_multipuerro_bhttp() {
    draw_header
    if [[ ! -f /usr/local/bin/wakkodev-bhttp-server ]]; then
        warn "Motor BHTTP no encontrado. Se instalará automáticamente."
        instalar_motor_bhttp
    fi

    echo -e "${YELLOW}── ABRIR PUERTO ADICIONAL BHTTP (MULTI-PUERTO) ──────────────────${NC}"
    read -r -p " Ingresa puerto extra (ej: 80, 8888, 3128, 8081): " xport
    [[ ! "$xport" =~ ^[0-9]+$ ]] && { fail "Puerto inválido"; pause; return; }

    cat > "/etc/systemd/system/wakkodev-bhttp-port-${xport}.service" << EOF
[Unit]
Description=CRISDEV BHTTP Extra Port $xport
After=network-online.target ssh.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/wakkodev-bhttp-server --listen 0.0.0.0 --port $xport --backend-host 127.0.0.1 --backend-port 22 --session-ttl 180 --max-sessions 4096 --request-timeout 30 --read-wait-ms 2 --sequence-wait 6 --max-requests-per-conn 2048
Restart=always
RestartSec=1
LimitNOFILE=524288

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now "wakkodev-bhttp-port-${xport}.service"
    ufw allow "$xport"/tcp 2>/dev/null || true

    ok "Puerto extra BHTTP $xport activado exitosamente."
    pause
}

listar_puertos_bhttp() {
    draw_header
    echo -e "${CYAN}── PUERTOS BHTTP ACTIVOS Y EN ESCUCHA ───────────────────────────${NC}"
    local ports_arr
    read -r -a ports_arr <<< "$(scan_bhttp_ports)"
    local total=${#ports_arr[@]}

    if [[ $total -eq 0 ]]; then
        warn "No hay puertos BHTTP activos en este momento."
    else
        echo -e "${WHITE}Total de puertos BHTTP en ejecución:${NC} ${GREEN}${total}${NC}"
        echo "────────────────────────────────────────────────────────────────"
        printf "%-8s %-15s %-20s %-12s\n" "PUERTO" "ESTADO" "SERVICIO" "DESTINO"
        echo "────────────────────────────────────────────────────────────────"
        for p in "${ports_arr[@]}"; do
            local svc_name="wakkodev-bhttp"
            [[ -f "/etc/systemd/system/wakkodev-bhttp-port-${p}.service" ]] && svc_name="wakkodev-bhttp-port-${p}"
            local st; st=$(systemctl is-active "$svc_name" 2>/dev/null || echo "activo")
            printf "%-8s %-23b %-20s %-12s\n" "$p" "${GREEN}ONLINE ($st)${NC}" "$svc_name" "127.0.0.1:22"
        done
    fi
    echo ""
    pause
}

eliminar_puerto_bhttp() {
    draw_header
    echo -e "${RED}── ELIMINAR UN PUERTO BHTTP ─────────────────────────────────────${NC}"
    local ports_arr
    read -r -a ports_arr <<< "$(scan_bhttp_ports)"
    echo -e "Puertos detectados: ${YELLOW}${ports_arr[*]:-Ninguno}${NC}"
    read -r -p " Ingresa el puerto a desactivar/eliminar: " del_port
    [[ ! "$del_port" =~ ^[0-9]+$ ]] && { fail "Puerto inválido"; pause; return; }

    # Verificar si es el principal o extra
    if [[ -f "/etc/systemd/system/wakkodev-bhttp-port-${del_port}.service" ]]; then
        systemctl disable --now "wakkodev-bhttp-port-${del_port}.service" 2>/dev/null || true
        rm -f "/etc/systemd/system/wakkodev-bhttp-port-${del_port}.service"
        systemctl daemon-reload
        ok "Puerto extra $del_port eliminado."
    elif [[ -f "/etc/systemd/system/wakkodev-bhttp.service" ]] && grep -q -- "--port $del_port" /etc/systemd/system/wakkodev-bhttp.service; then
        systemctl disable --now wakkodev-bhttp.service 2>/dev/null || true
        rm -f /etc/systemd/system/wakkodev-bhttp.service
        systemctl daemon-reload
        ok "Puerto principal $del_port detenido y eliminado."
    else
        fail "No se encontró un servicio específico para el puerto $del_port."
    fi
    pause
}

test_conectividad_bhttp() {
    draw_header
    echo -e "${CYAN}── TEST DE CONECTIVIDAD BHTTP -> BACKEND SSH ────────────────────${NC}"
    local ports_arr
    read -r -a ports_arr <<< "$(scan_bhttp_ports)"
    
    if [[ ${#ports_arr[@]} -eq 0 ]]; then
        warn "No hay puertos BHTTP activos para probar."
        pause; return
    fi

    # 1. Probar que SSH backend responde
    if nc -z -w2 127.0.0.1 22 2>/dev/null || (exec 3<>/dev/tcp/127.0.0.1/22) 2>/dev/null; then
        ok "Backend SSH en 127.0.0.1:22 respondiendo correctamente."
    else
        fail "Backend SSH en 127.0.0.1:22 no responde o está cerrado."
    fi

    # 2. Probar cada puerto BHTTP
    for p in "${ports_arr[@]}"; do
        if nc -z -w2 127.0.0.1 "$p" 2>/dev/null || (exec 3<>/dev/tcp/127.0.0.1/"$p") 2>/dev/null; then
            ok "Puerto BHTTP $p: Escuchando y listo para recibir clientes."
        else
            fail "Puerto BHTTP $p: No responde en loopback."
        fi
    done
    pause
}

logs_bhttp() {
    draw_header
    echo -e "${CYAN}── LOGS EN TIEMPO REAL BHTTP (Presiona CTRL+C para salir) ───────${NC}"
    journalctl -u "wakkodev-bhttp*" -n 40 --no-pager -f || true
}

optimizar_red_bhttp() {
    draw_header
    info "Aplicando optimizaciones de Kernel BBR & High Performance..."
    cat > /etc/sysctl.d/99-ssh-cris-performance.conf << 'EOF'
fs.file-max = 1048576
net.core.somaxconn = 16384
net.core.netdev_max_backlog = 16384
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 131072 16777216
net.ipv4.tcp_wmem = 4096 131072 16777216
net.ipv4.ip_local_port_range = 10240 65535
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.tcp_max_tw_buckets = 262144
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 4
net.ipv4.tcp_mtu_probing = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    modprobe tcp_bbr 2>/dev/null || true
    sysctl -p /etc/sysctl.d/99-ssh-cris-performance.conf >/dev/null 2>&1 || true
    ok "Perfil BBR + Rendimiento TCP aplicado."
    pause
}

desinstalar_bhttp() {
    draw_header
    systemctl disable --now wakkodev-bhttp.service 2>/dev/null || true
    for f in /etc/systemd/system/wakkodev-bhttp-port-*.service; do
        [[ -f "$f" ]] && systemctl disable --now "$(basename "$f")" 2>/dev/null || true
    done
    rm -f /etc/systemd/system/wakkodev-bhttp*.service
    systemctl daemon-reload
    ok "Todos los servicios BHTTP han sido detenidos y eliminados."
    pause
}

# ─────────────────────────────────────────────────────────────────────────────
#  3. UDP CRIS / HYSTERIA ENGINE & BADVPN 7300
# ─────────────────────────────────────────────────────────────────────────────
menu_udp() {
    while true; do
        draw_header
        echo -e "${YELLOW}══ UDP CRIS / HYSTERIA & BADVPN 7300 ════════════════════════════${NC}"
        echo -e " ${GREEN}1)${WHITE} Instalar / Configurar UDP CRIS (Hysteria Engine)"
        echo -e " ${GREEN}2)${WHITE} Instalar BadVPN UDPGW (Puerto 7300 - Juegos/Llamadas)"
        echo -e " ${GREEN}3)${WHITE} Activar / Desactivar Port Hopping (Rango 6000:50000)"
        echo -e " ${GREEN}4)${WHITE} Probar Socket UDP Local"
        echo -e " ${GREEN}5)${WHITE} Ver Estado y Logs de UDP CRIS"
        echo -e " ${RED}6)${WHITE} Detener / Desinstalar UDP CRIS"
        echo -e " ${RED}0)${WHITE} Volver al Menú Principal"
        echo -e "${YELLOW}────────────────────────────────────────────────────────────────${NC}"
        read -r -p " Selecciona una opción [0-6]: " opt

        case "$opt" in
            1) instalar_udpcris ;;
            2) instalar_badvpn ;;
            3) toggle_port_hopping ;;
            4) test_socket_udp ;;
            5) estado_udpcris ;;
            6) desinstalar_udpcris ;;
            0) break ;;
            *) warn "Opción inválida"; sleep 1 ;;
        esac
    done
}

instalar_udpcris() {
    draw_header
    info "Instalando UDP CRIS Core (Hysteria Engine)..."
    read -r -p " Puerto UDP de escucha (ej: 36712 o 5666): " uport
    [[ ! "$uport" =~ ^[0-9]+$ ]] && uport=36712

    read -r -p " Contraseña OBFS (ej: crisdev): " obfs_pass
    [[ -z "$obfs_pass" ]] && obfs_pass="crisdev"

    read -r -p " Contraseña de Autenticación (Auth Password): " auth_pass
    [[ -z "$auth_pass" ]] && auth_pass="crisdev"

    mkdir -p /etc/hysteria /usr/local/bin
    curl -fL --retry 3 "https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-amd64" -o /usr/local/bin/hysteria 2>/dev/null || \
    wget -q "https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-amd64" -O /usr/local/bin/hysteria
    chmod +x /usr/local/bin/hysteria

    # Generar certificado auto-firmado
    openssl req -new -newkey rsa:2048 -days 3650 -nodes -x509 \
        -subj "/C=US/ST=CRIS/L=CRIS/O=CRISDEV/CN=crisdev.online" \
        -keyout /etc/hysteria/server.key -out /etc/hysteria/server.crt >/dev/null 2>&1

    cat > /etc/hysteria/config.json << EOF
{
  "listen": ":$uport",
  "protocol": "udp",
  "cert": "/etc/hysteria/server.crt",
  "key": "/etc/hysteria/server.key",
  "obfs": "$obfs_pass",
  "auth": {
    "mode": "password",
    "config": {
      "password": "$auth_pass"
    }
  },
  "alpn": "h3",
  "recv_window_conn": 15728640,
  "recv_window": 67108864,
  "max_conn_client": 0,
  "disable_mtu_discovery": false,
  "resolver": "8.8.8.8:53"
}
EOF

    cat > /etc/systemd/system/hysteria-server.service << EOF
[Unit]
Description=CRISDEV UDP Hysteria Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/hysteria -c /etc/hysteria/config.json server
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now hysteria-server.service
    ufw allow "$uport"/udp 2>/dev/null || true

    ok "UDP CRIS activo en puerto UDP $uport (OBFS: $obfs_pass, Auth: $auth_pass)"
    pause
}

instalar_badvpn() {
    draw_header
    info "Instalando BadVPN UDPGW (Puerto 7300)..."
    apt-get update -qq && apt-get install -y -qq cmake gcc make build-essential git 2>/dev/null || true

    if [[ ! -f /usr/local/bin/badvpn-udpgw ]]; then
        wget -q -O /usr/local/bin/badvpn-udpgw "https://raw.githubusercontent.com/soportecrisdev/SCRIP_CRISDEV/main/UDP_CRIS/badvpn-udpgw" 2>/dev/null || \
        wget -q -O /usr/local/bin/badvpn-udpgw "https://github.com/ambrop72/badvpn/raw/master/bin/badvpn-udpgw" 2>/dev/null
        chmod +x /usr/local/bin/badvpn-udpgw 2>/dev/null || true
    fi

    cat > /etc/systemd/system/badvpn.service << 'EOF'
[Unit]
Description=BadVPN UDPGW Service 7300
After=network.target

[Service]
ExecStart=/usr/local/bin/badvpn-udpgw --listen-addr 127.0.0.1:7300 --max-clients 1000 --max-connections-for-client 100
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now badvpn.service 2>/dev/null || true
    ok "BadVPN UDPGW activo en 127.0.0.1:7300"
    pause
}

toggle_port_hopping() {
    draw_header
    echo -e "${CYAN}── REDIRECCIÓN DE RANGO DE PUERTOS UDP (PORT HOPPING) ──────────${NC}"
    
    if iptables -t nat -L PREROUTING -n 2>/dev/null | grep -q "6000:50000"; then
        read -r -p " Port Hopping está ACTIVO. ¿Deseas DESACTIVARLO? [s/n]: " ans
        if [[ "$ans" =~ ^[sS]$ ]]; then
            iptables -t nat -D PREROUTING -p udp --dport 6000:50000 -j REDIRECT 2>/dev/null || true
            ok "Port Hopping desactivado."
        fi
    else
        local uport="36712"
        if [[ -f /etc/hysteria/config.json ]]; then
            uport=$(grep -o '"listen": "[^"]*"' /etc/hysteria/config.json 2>/dev/null | cut -d: -f3 | tr -d '":, ' || echo "36712")
            [[ -z "$uport" ]] && uport=$(grep -o '"listen": ":[0-9]*"' /etc/hysteria/config.json 2>/dev/null | cut -d: -f3 | tr -d '":, ' || echo "36712")
        fi
        read -r -p " Puerto UDP destino de UDP CRIS (default $uport): " target_uport
        [[ -z "$target_uport" ]] && target_uport="$uport"

        info "Redirigiendo puertos UDP 6000:50000 -> $target_uport..."
        iptables -t nat -A PREROUTING -p udp --dport 6000:50000 -j REDIRECT --to-ports "$target_uport" 2>/dev/null || true
        ok "Port hopping UDP 6000-50000 activado hacia puerto $target_uport."
    fi
    pause
}

test_socket_udp() {
    draw_header
    echo -e "${CYAN}── TEST DE SOCKET UDP CRIS & BADVPN ─────────────────────────────${NC}"
    if systemctl is-active --quiet hysteria-server.service 2>/dev/null || pgrep -f hysteria >/dev/null 2>&1; then
        local uport="36712"
        if [[ -f /etc/hysteria/config.json ]]; then
            uport=$(grep -o '"listen": "[^"]*"' /etc/hysteria/config.json 2>/dev/null | cut -d: -f3 | tr -d '":, ' || echo "36712")
            [[ -z "$uport" ]] && uport=$(grep -o '"listen": ":[0-9]*"' /etc/hysteria/config.json 2>/dev/null | cut -d: -f3 | tr -d '":, ' || echo "36712")
        fi
        ok "Servicio UDP CRIS activo y escuchando en puerto UDP $uport."
    else
        fail "Servicio UDP CRIS no está activo."
    fi

    if systemctl is-active --quiet badvpn.service 2>/dev/null || pgrep -f badvpn-udpgw >/dev/null 2>&1; then
        ok "BadVPN UDPGW activo en 127.0.0.1:7300."
    else
        warn "BadVPN UDPGW 7300 no está activo."
    fi
    pause
}

estado_udpcris() {
    draw_header
    systemctl status hysteria-server.service --no-pager || true
    echo ""
    systemctl status badvpn.service --no-pager || true
    pause
}

desinstalar_udpcris() {
    draw_header
    systemctl disable --now hysteria-server.service badvpn.service 2>/dev/null || true
    rm -rf /etc/hysteria /usr/local/bin/hysteria /etc/systemd/system/hysteria-server.service /etc/systemd/system/badvpn.service
    systemctl daemon-reload
    ok "UDP CRIS y BadVPN desinstalados."
    pause
}

# ─────────────────────────────────────────────────────────────────────────────
#  4. OPENSSH, DROPBEAR & STUNNEL SSL
# ─────────────────────────────────────────────────────────────────────────────
menu_ssh_ssl() {
    while true; do
        draw_header
        echo -e "${CYAN}══ OPENSSH, DROPBEAR & STUNNEL SSL ══════════════════════════════${NC}"
        echo -e " ${GREEN}1)${WHITE} Configurar OpenSSH (Puerto 22, TCP Forwarding)"
        echo -e " ${GREEN}2)${WHITE} Instalar / Configurar Dropbear (Puertos 80, 8080, 442, 8888)"
        echo -e " ${GREEN}3)${WHITE} Instalar / Configurar Stunnel4 SSL (Puerto 443 -> SSH 22)"
        echo -e " ${GREEN}4)${WHITE} Reiniciar Servicios SSH/SSL"
        echo -e " ${RED}0)${WHITE} Volver al Menú Principal"
        echo -e "${CYAN}────────────────────────────────────────────────────────────────${NC}"
        read -r -p " Selecciona una opción [0-4]: " opt

        case "$opt" in
            1) config_openssh ;;
            2) config_dropbear ;;
            3) config_stunnel ;;
            4) restart_ssh_ssl ;;
            0) break ;;
            *) warn "Opción inválida"; sleep 1 ;;
        esac
    done
}

config_openssh() {
    draw_header
    info "Optimizando configuración de OpenSSH..."
    sed -i 's/#*AllowTcpForwarding.*/AllowTcpForwarding yes/' /etc/ssh/sshd_config
    sed -i 's/#*GatewayPorts.*/GatewayPorts yes/' /etc/ssh/sshd_config
    sed -i 's/#*TCPKeepAlive.*/TCPKeepAlive yes/' /etc/ssh/sshd_config
    sed -i 's/#*ClientAliveInterval.*/ClientAliveInterval 30/' /etc/ssh/sshd_config
    sed -i 's/#*ClientAliveCountMax.*/ClientAliveCountMax 3/' /etc/ssh/sshd_config
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
    ok "OpenSSH configurado en puerto 22 con TCP Forwarding activado."
    pause
}

config_dropbear() {
    draw_header
    info "Instalando y configurando Dropbear..."
    apt-get install -y dropbear 2>/dev/null || true
    cat > /etc/default/dropbear << 'EOF'
NO_START=0
DROPBEAR_PORT=80
DROPBEAR_EXTRA_ARGS="-p 8080 -p 442 -p 8888"
DROPBEAR_BANNER=""
DROPBEAR_RECEIVE_WINDOW=65536
EOF
    systemctl restart dropbear 2>/dev/null || true
    ufw allow 80/tcp 2>/dev/null || true
    ufw allow 8080/tcp 2>/dev/null || true
    ufw allow 442/tcp 2>/dev/null || true
    ufw allow 8888/tcp 2>/dev/null || true
    ok "Dropbear activo en puertos 80, 8080, 442, 8888."
    pause
}

config_stunnel() {
    draw_header
    info "Instalando y configurando Stunnel4 SSL..."
    apt-get install -y stunnel4 2>/dev/null || true

    mkdir -p /etc/stunnel
    openssl req -new -newkey rsa:2048 -days 3650 -nodes -x509 \
        -subj "/C=US/ST=CRIS/L=CRIS/O=CRISDEV/CN=ssl.crisdev.online" \
        -keyout /etc/stunnel/stunnel.pem -out /etc/stunnel/stunnel.pem >/dev/null 2>&1

    cat > /etc/stunnel/stunnel.conf << 'EOF'
cert = /etc/stunnel/stunnel.pem
client = no
socket = a:SO_REUSEADDR=1
socket = l:TCP_NODELAY=1
socket = r:TCP_NODELAY=1

[ssh-ssl]
accept = 443
connect = 127.0.0.1:22
EOF

    sed -i 's/ENABLED=0/ENABLED=1/' /etc/default/stunnel4 2>/dev/null || true
    systemctl restart stunnel4 2>/dev/null || true
    ufw allow 443/tcp 2>/dev/null || true
    ok "Stunnel4 SSL activo en puerto 443 -> SSH 22."
    pause
}

restart_ssh_ssl() {
    draw_header
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
    systemctl restart dropbear 2>/dev/null || true
    systemctl restart stunnel4 2>/dev/null || true
    ok "Servicios SSH y SSL reiniciados."
    pause
}

# ─────────────────────────────────────────────────────────────────────────────
#  5. SLOWDNS & XRAY / V2RAY
# ─────────────────────────────────────────────────────────────────────────────
menu_dns_v2ray() {
    while true; do
        draw_header
        echo -e "${MAGENTA}══ SLOWDNS & XRAY / V2RAY ════════════════════════════════════${NC}"
        echo -e " ${GREEN}1)${WHITE} Instalar / Configurar SlowDNS (DNSTT Puerto 53)"
        echo -e " ${GREEN}2)${WHITE} Instalar Xray-core (V2Ray / VMess / VLESS / Trojan)"
        echo -e " ${GREEN}3)${WHITE} Ver Claves y Estado de SlowDNS"
        echo -e " ${RED}0)${WHITE} Volver al Menú Principal"
        echo -e "${MAGENTA}────────────────────────────────────────────────────────────────${NC}"
        read -r -p " Selecciona una opción [0-3]: " opt

        case "$opt" in
            1) instalar_slowdns ;;
            2) instalar_xray ;;
            3) ver_slowdns ;;
            0) break ;;
            *) warn "Opción inválida"; sleep 1 ;;
        esac
    done
}

instalar_slowdns() {
    draw_header
    info "Configurando SlowDNS (DNSTT Server)..."
    read -r -p " Dominio NameServer (NS) (ej: ns1.tudominio.com): " ns_domain
    [[ -z "$ns_domain" ]] && { fail "El NameServer es requerido."; pause; return; }

    mkdir -p /etc/slowdns
    wget -q -O /usr/local/bin/dnstt-server "https://raw.githubusercontent.com/soportecrisdev/SCRIP_CRISDEV/main/dnstt-server" 2>/dev/null || true
    chmod +x /usr/local/bin/dnstt-server 2>/dev/null || true

    if [[ -x /usr/local/bin/dnstt-server ]]; then
        /usr/local/bin/dnstt-server -gen-key -privkey-file /etc/slowdns/server.key -pubkey-file /etc/slowdns/server.pub 2>/dev/null || true
    fi

    echo "$ns_domain" > /etc/slowdns/ns.txt
    ok "SlowDNS configurado con NS: $ns_domain"
    if [[ -f /etc/slowdns/server.pub ]]; then
        echo -e "${YELLOW}Clave Pública SlowDNS:${NC} $(cat /etc/slowdns/server.pub)"
    fi
    pause
}

ver_slowdns() {
    draw_header
    if [[ -f /etc/slowdns/server.pub ]]; then
        echo -e "${WHITE}• NameServer:${NC} $(cat /etc/slowdns/ns.txt 2>/dev/null || echo 'No configurado')"
        echo -e "${WHITE}• Clave Pública:${NC} ${GREEN}$(cat /etc/slowdns/server.pub)${NC}"
    else
        warn "SlowDNS aún no está configurado."
    fi
    pause
}

instalar_xray() {
    draw_header
    info "Instalando Xray-core oficial..."
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    ok "Xray-core instalado correctamente."
    pause
}

# ─────────────────────────────────────────────────────────────────────────────
#  6. APARTADO CENTRAL DE PROTOCOLOS
# ─────────────────────────────────────────────────────────────────────────────
menu_protocolos() {
    while true; do
        draw_header
        echo -e "${CYAN}══ APARTADO MAESTRO DE PROTOCOLOS ═══════════════════════════════${NC}"
        echo -e " ${GREEN}[1]${WHITE}  BHTTP Multi-Puerto Relay (Wakko Engine)"
        echo -e " ${GREEN}[2]${WHITE}  UDP CRIS (Hysteria Engine & BadVPN 7300)"
        echo -e " ${GREEN}[3]${WHITE}  OpenSSH, Dropbear & Stunnel SSL"
        echo -e " ${GREEN}[4]${WHITE}  SlowDNS (DNSTT Puerto 53)"
        echo -e " ${GREEN}[5]${WHITE}  Xray / V2Ray Core"
        echo -e " ${GREEN}[6]${WHITE}  Test de Conectividad General de Puertos"
        echo -e " ${GREEN}[7]${WHITE}  Exportar Configuración Completa para el GEN"
        echo -e " ${RED}[0]${WHITE}  Volver al Menú Principal"
        echo -e "${CYAN}────────────────────────────────────────────────────────────────${NC}"
        read -r -p " Selecciona una opción [0-7]: " proto_opt

        case "$proto_opt" in
            1) menu_bhttp ;;
            2) menu_udp ;;
            3) menu_ssh_ssl ;;
            4) menu_dns_v2ray ;;
            5) menu_dns_v2ray ;;
            6) test_general_puertos ;;
            7) exportar_servidor_gen ;;
            0) break ;;
            *) warn "Opción inválida"; sleep 1 ;;
        esac
    done
}

# ─────────────────────────────────────────────────────────────────────────────
#  7. TEST & DIAGNÓSTICO GENERAL DE PUERTOS
# ─────────────────────────────────────────────────────────────────────────────
test_general_puertos() {
    draw_header
    echo -e "${CYAN}── DIAGNÓSTICO GENERAL DE PUERTOS Y SOCKETS ─────────────────────${NC}"
    echo -e "${YELLOW}Sockets TCP en escucha:${NC}"
    ss -tlpn | grep -E "sshd|dropbear|stunnel|wakkodev|bhttp|xray" || echo "No se encontraron puertos TCP activos"
    echo ""
    echo -e "${YELLOW}Sockets UDP en escucha:${NC}"
    ss -ulpn | grep -E "hysteria|dnstt|badvpn" || echo "No se encontraron puertos UDP activos"
    echo ""
    echo -e "${YELLOW}Reglas NAT / Port Hopping:${NC}"
    iptables -t nat -L PREROUTING -n -v 2>/dev/null | grep -E "6000:50000|REDIRECT" || echo "Sin reglas de Port Hopping activas"
    pause
}

# ─────────────────────────────────────────────────────────────────────────────
#  8. EXPORTAR SERVIDOR AL GEN / HTTP CONEXIÓN
# ─────────────────────────────────────────────────────────────────────────────
exportar_servidor_gen() {
    draw_header
    local ip; ip=$(get_public_ip)
    local bhttp_ports_arr
    read -r -a bhttp_ports_arr <<< "$(scan_bhttp_ports)"
    local bhttp_main_port="${bhttp_ports_arr[0]:-8080}"
    local bhttp_all="${bhttp_ports_arr[*]:-8080}"

    local uport="36712"
    local obfs_val="crisdev"
    local auth_val="crisdev"
    if [[ -f /etc/hysteria/config.json ]]; then
        uport=$(grep -o '"listen": "[^"]*"' /etc/hysteria/config.json 2>/dev/null | cut -d: -f3 | tr -d '":, ' || echo "36712")
        [[ -z "$uport" ]] && uport=$(grep -o '"listen": ":[0-9]*"' /etc/hysteria/config.json 2>/dev/null | cut -d: -f3 | tr -d '":, ' || echo "36712")
        obfs_val=$(grep -o '"obfs": "[^"]*"' /etc/hysteria/config.json 2>/dev/null | cut -d: -f2 | tr -d '":, ' || echo "crisdev")
        auth_val=$(grep -o '"password": "[^"]*"' /etc/hysteria/config.json 2>/dev/null | cut -d: -f2 | tr -d '":, ' || echo "crisdev")
    fi

    local slowdns_ns; slowdns_ns=$(cat /etc/slowdns/ns.txt 2>/dev/null || echo "No configurado")
    local slowdns_pub; slowdns_pub=$(cat /etc/slowdns/server.pub 2>/dev/null || echo "No configurado")

    echo -e "${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${WHITE}           DATOS PARA IMPORTAR EN EL GEN (APP ANDROID)          ${CYAN}║${NC}"
    echo -e "${CYAN}╠════════════════════════════════════════════════════════════════╣${NC}"
    printf "${CYAN}║${WHITE} • IP Servidor:         ${GREEN}%-40s${CYAN}║\n" "$ip"
    printf "${CYAN}║${WHITE} • Puerto SSH:          ${GREEN}%-40s${CYAN}║\n" "22"
    printf "${CYAN}║${WHITE} • Puerto SSL:          ${GREEN}%-40s${CYAN}║\n" "443"
    printf "${CYAN}║${WHITE} • Dropbear:            ${GREEN}%-40s${CYAN}║\n" "80, 8080, 442, 8888"
    printf "${CYAN}║${WHITE} • BHTTP Relay:         ${GREEN}%-40s${CYAN}║\n" "Principal: $bhttp_main_port (Todos: $bhttp_all)"
    printf "${CYAN}║${WHITE} • UDP CRIS (Hysteria): ${GREEN}%-40s${CYAN}║\n" "$uport (OBFS: $obfs_val | Auth: $auth_val)"
    printf "${CYAN}║${WHITE} • BadVPN UDPGW:        ${GREEN}%-40s${CYAN}║\n" "7300"
    printf "${CYAN}║${WHITE} • SlowDNS NameServer:  ${GREEN}%-40s${CYAN}║\n" "${slowdns_ns:0:40}"
    printf "${CYAN}║${WHITE} • SlowDNS Clave Pub:   ${GREEN}%-40s${CYAN}║\n" "${slowdns_pub:0:40}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}JSON para agregar en el GEN (ServerEditorActivity):${NC}"
    cat << EOF
{
  "Name": "CRISDEV - $ip",
  "ServerIP": "$ip",
  "ServerPort": "22",
  "SSLPort": "443",
  "bhttpHost": "$ip",
  "bhttpPort": "$bhttp_main_port",
  "isBhttp": true,
  "isUdp": true,
  "udpPort": "$uport",
  "udpObfs": "$obfs_val",
  "udpAuth": "$auth_val",
  "badvpnPort": "7300",
  "ns": "$slowdns_ns",
  "pubKey": "$slowdns_pub"
}
EOF
    echo ""
    pause
}

# ─────────────────────────────────────────────────────────────────────────────
#  MENÚ PRINCIPAL
# ─────────────────────────────────────────────────────────────────────────────
main_menu() {
    need_root
    while true; do
        draw_header
        echo -e " ${GREEN}[1]${WHITE}  Gestión de Usuarios SSH & Conexiones Multi-Login"
        echo -e " ${GREEN}[2]${WHITE}  APARTADO DE PROTOCOLOS (BHTTP, UDP CRIS, SSL, SSH, DNS)"
        echo -e " ${GREEN}[3]${WHITE}  BHTTP Multi-Puerto Relay (Acceso Rápido)"
        echo -e " ${GREEN}[4]${WHITE}  UDP CRIS & BadVPN 7300 (Acceso Rápido)"
        echo -e " ${GREEN}[5]${WHITE}  Exportar Configuración Servidor para el GEN"
        echo -e " ${GREEN}[6]${WHITE}  Diagnóstico & Test de Conectividad de Puertos"
        echo -e " ${GREEN}[7]${WHITE}  Optimización de Red (TCP BBR & Kernel Buffers)"
        echo -e " ${GREEN}[8]${WHITE}  Seguridad, Firewall UFW & Monitor de Sistema"
        echo -e " ${RED}[0]${WHITE}  Salir del Administrador"
        echo -e "${CYAN}────────────────────────────────────────────────────────────────${NC}"
        read -r -p " Selecciona una opción [0-8]: " main_opt

        case "$main_opt" in
            1) menu_users ;;
            2) menu_protocolos ;;
            3) menu_bhttp ;;
            4) menu_udp ;;
            5) exportar_servidor_gen ;;
            6) test_general_puertos ;;
            7) optimizar_red_bhttp ;;
            8)
                draw_header
                echo -e "${YELLOW}Estado de UFW Firewall:${NC}"
                ufw status verbose 2>/dev/null || iptables -L -n -v
                pause
                ;;
            0)
                echo -e "\n${GREEN}¡Hasta pronto!${NC}\n"
                exit 0
                ;;
            *)
                warn "Opción inválida."
                sleep 1
                ;;
        esac
    done
}

main_menu "$@"
