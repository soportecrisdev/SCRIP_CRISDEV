#!/usr/bin/env bash
# ==============================================================================
#  SSH-CRIS v1 — VPS Master VPN Suite & Server Manager
#  Autor: CRISDEV / HTTP Conexión
#  Soporte: OpenSSH, Proxy Socks, SSL Tunnel, Dropbear, V2Ray/Xray, SlowDNS,
#           UDP CRIS / Hysteria v1, Trojan-Go, BadVPN 7300, OpenVPN, WebSocket,
#           SSLH, Squid, Chisel, BHTTP Multi-Puerto Relay y Token HTTP Conexión.
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

scan_bhttp_ports() {
    local ports=()
    local raw_ports
    raw_ports=$(ss -tlpn 2>/dev/null | grep -E "wakkodev|bhttp" | awk '{print $4}' | awk -F: '{print $NF}' | sort -n -u)
    if [[ -n "$raw_ports" ]]; then
        for p in $raw_ports; do
            [[ "$p" =~ ^[0-9]+$ ]] && ports+=("$p")
        done
    fi
    if [[ ${#ports[@]} -eq 0 ]]; then
        local svc_ports
        svc_ports=$(grep -h -o -E "\-\-port [0-9]+" /etc/systemd/system/wakkodev-bhttp*.service 2>/dev/null | awk '{print $2}' | sort -n -u || true)
        for p in $svc_ports; do
            [[ "$p" =~ ^[0-9]+$ ]] && ports+=("$p")
        done
    fi
    echo "${ports[@]:-}"
}

get_online_users_count() {
    who 2>/dev/null | grep -E "pts|sshd" | wc -l || echo "0"
}

get_users_stats() {
    local total=0
    local active=0
    local expired=0
    local now_sec; now_sec=$(date +%s)

    if [[ -f "$USER_DATABASE" ]]; then
        while IFS=: read -r u limit exp || [[ -n "$u" ]]; do
            [[ -z "$u" || "$u" =~ ^# ]] && continue
            ((total++))
            local exp_sec; exp_sec=$(date -d "$exp" +%s 2>/dev/null || date -d "$exp 23:59:59" +%s 2>/dev/null || echo 0)
            if [[ $exp_sec -ge $now_sec ]]; then
                ((active++))
            else
                ((expired++))
            fi
        done < "$USER_DATABASE"
    fi

    local online; online=$(get_online_users_count)
    echo "$total:$active:$expired:$online"
}

get_status_icon() {
    local query="$1"
    if [[ "$query" == "bhttp" ]]; then
        local ports
        ports=$(scan_bhttp_ports)
        if [[ -n "$ports" ]]; then
            echo -e "${GREEN}o${NC}"
        else
            echo -e "${RED}x${NC}"
        fi
        return
    fi

    if systemctl is-active --quiet "$query" 2>/dev/null || pgrep -f "$query" >/dev/null 2>&1; then
        echo -e "${GREEN}o${NC}"
    else
        echo -e "${RED}x${NC}"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
#  CABECERA DEL MENÚ PRINCIPAL
# ─────────────────────────────────────────────────────────────────────────────
draw_main_header() {
    clear
    local ip; ip=$(get_public_ip)
    local os; os=$(lsb_release -sd 2>/dev/null || cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d= -f2 | tr -d '\"' || echo 'Linux')
    local ram_used; ram_used=$(free -m | awk '/Mem:/ {print $3}')
    local ram_total; ram_total=$(free -m | awk '/Mem:/ {print $2}')
    local ram_pct; ram_pct=$(( ram_used * 100 / (ram_total > 0 ? ram_total : 1) ))
    local cpu_load; cpu_load=$(top -bn1 2>/dev/null | grep "Cpu(s)" | awk '{print $2 + $4"%"}' || echo "N/A")
    local uptime_str; uptime_str=$(uptime -p 2>/dev/null | sed 's/up //' || uptime | awk -F'( |,|:)+' '{print $6"h "$7"m"}')

    local stats_str; stats_str=$(get_users_stats)
    local u_total; u_total=$(echo "$stats_str" | cut -d: -f1)
    local u_active; u_active=$(echo "$stats_str" | cut -d: -f2)
    local u_expired; u_expired=$(echo "$stats_str" | cut -d: -f3)
    local u_online; u_online=$(echo "$stats_str" | cut -d: -f4)

    echo -e "${CYAN}========================================================================${NC}"
    echo -e "${WHITE}                 ⚡ SSH-CRIS MASTER SUITE ${VERSION} ⚡            ${NC}"
    echo -e "${DIM}           Control Maestro de Túneles VPN & Servidores          ${NC}"
    echo -e "${CYAN}========================================================================${NC}"
    printf " ${WHITE}IP Pública:    ${GREEN}%-18s${WHITE}   SO:  ${YELLOW}%s${NC}\n" "$ip" "$os"
    printf " ${WHITE}Memoria RAM:   ${GREEN}%-18s${WHITE}   CPU: ${YELLOW}%s | %s${NC}\n" "${ram_used}MB / ${ram_total}MB (${ram_pct}%)" "$cpu_load" "$uptime_str"
    printf " ${WHITE}Creados: ${GREEN}%-4s${WHITE} | Activos: ${GREEN}%-4s${WHITE} | Vencidos: ${RED}%-4s${WHITE} | En Línea: ${GREEN}%-4s${NC}\n" "$u_total" "$u_active" "$u_expired" "$u_online"
    echo -e "${CYAN}========================================================================${NC}"
}

# ─────────────────────────────────────────────────────────────────────────────
#  1. ADMINISTRAR USUARIOS
# ─────────────────────────────────────────────────────────────────────────────
menu_users() {
    while true; do
        clear
        local stats_str; stats_str=$(get_users_stats)
        local u_total; u_total=$(echo "$stats_str" | cut -d: -f1)
        local u_active; u_active=$(echo "$stats_str" | cut -d: -f2)
        local u_expired; u_expired=$(echo "$stats_str" | cut -d: -f3)
        local u_online; u_online=$(echo "$stats_str" | cut -d: -f4)

        echo -e "${CYAN}========================================================================${NC}"
        echo -e "${WHITE}                          ADMINISTRAR USUARIOS                          ${NC}"
        echo -e "${CYAN}========================================================================${NC}"
        printf " ${WHITE}Creados: ${GREEN}%-4s${WHITE} | Activos: ${GREEN}%-4s${WHITE} | Vencidos: ${RED}%-4s${WHITE} | En Línea: ${GREEN}%-4s${NC}\n" "$u_total" "$u_active" "$u_expired" "$u_online"
        echo -e "${CYAN}========================================================================${NC}"
        echo -e " ${GREEN}[1]${WHITE}  > CREAR USUARIO          ${GREEN}[6]${WHITE}  > CAMBIAR LIMITE"
        echo -e " ${GREEN}[2]${WHITE}  > CREAR PRUEBA           ${GREEN}[7]${WHITE}  > CAMBIAR CLAVE"
        echo -e " ${GREEN}[3]${WHITE}  > ELIMINAR USUARIO       ${GREEN}[8]${WHITE}  > INFORME DE USUARIO"
        echo -e " ${GREEN}[4]${WHITE}  > MONITOR ONLINE         ${GREEN}[9]${WHITE}  > ELIMINAR CADUCADOS"
        echo -e " ${GREEN}[5]${WHITE}  > CAMBIAR FECHA          ${GREEN}[10]${WHITE} > TOKEN HTTP CONEXION"
        echo -e "                           ${RED}[0]${WHITE}  > VOLVER"
        echo -e "${CYAN}========================================================================${NC}"
        read -r -p " Opcion: " u_opt

        case "$u_opt" in
            1) crear_usuario ;;
            2) crear_prueba ;;
            3) eliminar_usuario ;;
            4) monitor_conexiones ;;
            5) renovar_usuario ;;
            6) cambiar_limite ;;
            7) cambiar_clave ;;
            8) listar_usuarios ;;
            9) eliminar_caducados ;;
            10) generar_token_http_conexion ;;
            0) break ;;
            *) warn "Opción inválida"; sleep 1 ;;
        esac
    done
}

crear_usuario() {
    clear
    echo -e "${CYAN}========================================================================${NC}"
    echo -e "${WHITE}                          CREAR NUEVO USUARIO                           ${NC}"
    echo -e "${CYAN}========================================================================${NC}"
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

    sed -i "/^$username:/d" "$USER_DATABASE" 2>/dev/null || true
    echo "$username:$limit:$exp_date" >> "$USER_DATABASE"

    local ip; ip=$(get_public_ip)
    ok "Usuario '$username' creado exitosamente:"
    echo "────────────────────────────────────────────────────────────────────────"
    echo -e "${WHITE}• Servidor:   ${GREEN}$ip${NC}"
    echo -e "${WHITE}• Usuario:    ${YELLOW}$username${NC}"
    echo -e "${WHITE}• Contraseña: ${YELLOW}$password${NC}"
    echo -e "${WHITE}• Vence el:   ${CYAN}$exp_date ($days días)${NC}"
    echo -e "${WHITE}• Límite:     ${GREEN}$limit conexión(es)${NC}"
    echo "────────────────────────────────────────────────────────────────────────"
    pause
}

crear_prueba() {
    clear
    echo -e "${CYAN}========================================================================${NC}"
    echo -e "${WHITE}                       CREAR USUARIO DE PRUEBA (TRIAL)                  ${NC}"
    echo -e "${CYAN}========================================================================${NC}"
    read -r -p " Horas de duración para la prueba (ej: 2 o 4, default 2): " hours
    [[ ! "$hours" =~ ^[0-9]+$ ]] && hours=2

    local rand_id=$(( RANDOM % 9000 + 1000 ))
    local username="test_${rand_id}"
    local password=$(( RANDOM % 9000 + 1000 ))
    local exp_date; exp_date=$(date -d "+$hours hours" "+%Y-%m-%d" 2>/dev/null || date "+%Y-%m-%d")

    useradd -M -s /bin/false "$username" 2>/dev/null || useradd -s /bin/false "$username"
    echo "$username:$password" | chpasswd

    sed -i "/^$username:/d" "$USER_DATABASE" 2>/dev/null || true
    echo "$username:1:$exp_date" >> "$USER_DATABASE"

    if command -v at >/dev/null 2>&1; then
        echo "userdel -f $username 2>/dev/null; sed -i '/^$username:/d' $USER_DATABASE" | at now + $hours hours 2>/dev/null || true
    fi

    local ip; ip=$(get_public_ip)
    ok "Usuario de prueba creado exitosamente:"
    echo "────────────────────────────────────────────────────────────────────────"
    echo -e "${WHITE}• Servidor:   ${GREEN}$ip${NC}"
    echo -e "${WHITE}• Usuario:    ${YELLOW}$username${NC}"
    echo -e "${WHITE}• Contraseña: ${YELLOW}$password${NC}"
    echo -e "${WHITE}• Duración:   ${CYAN}$hours hora(s)${NC}"
    echo -e "${WHITE}• Límite:     ${GREEN}1 conexión${NC}"
    echo "────────────────────────────────────────────────────────────────────────"
    pause
}

eliminar_usuario() {
    clear
    echo -e "${CYAN}========================================================================${NC}"
    echo -e "${WHITE}                          ELIMINAR USUARIO                              ${NC}"
    echo -e "${CYAN}========================================================================${NC}"
    read -r -p " Nombre de usuario a eliminar: " username
    if ! id "$username" >/dev/null 2>&1; then
        fail "El usuario '$username' no existe."
        pause; return
    fi
    pkill -u "$username" 2>/dev/null || true
    userdel -f "$username" 2>/dev/null || true
    sed -i "/^$username:/d" "$USER_DATABASE" 2>/dev/null || true
    ok "Usuario '$username' eliminado correctamente."
    pause
}

renovar_usuario() {
    clear
    echo -e "${CYAN}========================================================================${NC}"
    echo -e "${WHITE}                       CAMBIAR FECHA / RENOVAR USUARIO                  ${NC}"
    echo -e "${CYAN}========================================================================${NC}"
    read -r -p " Nombre de usuario: " username
    if ! id "$username" >/dev/null 2>&1; then
        fail "El usuario '$username' no existe."
        pause; return
    fi

    read -r -p " Agregar días adicionales (ej: 30): " add_days
    if [[ "$add_days" =~ ^[0-9]+$ ]] && [[ "$add_days" -gt 0 ]]; then
        local exp_date
        exp_date=$(date -d "+$add_days days" "+%Y-%m-%d" 2>/dev/null || date -v+${add_days}d "+%Y-%m-%d")
        chage -E "$exp_date" "$username" 2>/dev/null || true
        local limit; limit=$(grep "^$username:" "$USER_DATABASE" 2>/dev/null | cut -d: -f2 || echo "1")
        sed -i "/^$username:/d" "$USER_DATABASE" 2>/dev/null || true
        echo "$username:${limit:-1}:$exp_date" >> "$USER_DATABASE"
        ok "Fecha de vencimiento extendida a $exp_date."
    fi
    pause
}

cambiar_limite() {
    clear
    echo -e "${CYAN}========================================================================${NC}"
    echo -e "${WHITE}                       CAMBIAR LIMITE DE CONEXIONES                     ${NC}"
    echo -e "${CYAN}========================================================================${NC}"
    read -r -p " Nombre de usuario: " username
    if ! id "$username" >/dev/null 2>&1; then
        fail "El usuario '$username' no existe."
        pause; return
    fi

    read -r -p " Nuevo límite de conexiones (ej: 1, 2, 3): " new_limit
    [[ ! "$new_limit" =~ ^[0-9]+$ ]] && new_limit=1

    local exp; exp=$(grep "^$username:" "$USER_DATABASE" 2>/dev/null | cut -d: -f3 || echo "")
    sed -i "/^$username:/d" "$USER_DATABASE" 2>/dev/null || true
    echo "$username:$new_limit:${exp:-2026-12-31}" >> "$USER_DATABASE"
    ok "Límite actualizado a $new_limit conexión(es) simultánea(s)."
    pause
}

cambiar_clave() {
    clear
    echo -e "${CYAN}========================================================================${NC}"
    echo -e "${WHITE}                       CAMBIAR CONTRASEÑA DE USUARIO                    ${NC}"
    echo -e "${CYAN}========================================================================${NC}"
    read -r -p " Nombre de usuario: " username
    if ! id "$username" >/dev/null 2>&1; then
        fail "El usuario '$username' no existe."
        pause; return
    fi

    read -r -p " Nueva contraseña: " password
    [[ -z "$password" ]] && { fail "Contraseña vacía"; pause; return; }
    echo "$username:$password" | chpasswd
    ok "Contraseña actualizada exitosamente."
    pause
}

listar_usuarios() {
    clear
    echo -e "${CYAN}========================================================================${NC}"
    echo -e "${WHITE}                       INFORME DETALLADO DE USUARIOS                    ${NC}"
    echo -e "${CYAN}========================================================================${NC}"
    printf "%-16s %-12s %-10s %-16s %-8s\n" "USUARIO" "VENCE" "DIAS" "ESTADO" "LIMITE"
    echo "────────────────────────────────────────────────────────────────────────"
    local now_sec; now_sec=$(date +%s)

    while IFS=: read -r u limit exp || [[ -n "$u" ]]; do
        [[ -z "$u" || "$u" =~ ^# ]] && continue
        local exp_sec; exp_sec=$(date -d "$exp" +%s 2>/dev/null || echo 0)
        local days_left=$(( (exp_sec - now_sec) / 86400 ))
        local status
        if [[ $exp_sec -lt $now_sec ]]; then
            status="${RED}VENCIDO${NC}"
            days_left="0"
        else
            status="${GREEN}ACTIVO${NC}"
        fi
        printf "%-16s %-12s %-10s %-24b %-8s\n" "$u" "$exp" "${days_left}d" "$status" "${limit} conn"
    done < "$USER_DATABASE"
    echo "────────────────────────────────────────────────────────────────────────"
    pause
}

eliminar_caducados() {
    clear
    echo -e "${CYAN}========================================================================${NC}"
    echo -e "${WHITE}                       ELIMINAR USUARIOS CADUCADOS                      ${NC}"
    echo -e "${CYAN}========================================================================${NC}"
    local now_sec; now_sec=$(date +%s)
    local count=0

    if [[ -f "$USER_DATABASE" ]]; then
        while IFS=: read -r u limit exp || [[ -n "$u" ]]; do
            [[ -z "$u" || "$u" =~ ^# ]] && continue
            local exp_sec; exp_sec=$(date -d "$exp" +%s 2>/dev/null || echo 0)
            if [[ $exp_sec -lt $now_sec ]]; then
                userdel -f "$u" 2>/dev/null || true
                pkill -u "$u" 2>/dev/null || true
                sed -i "/^$u:/d" "$USER_DATABASE" 2>/dev/null || true
                echo -e " ${RED}✘ Eliminado usuario vencido:${NC} $u (Venció: $exp)"
                ((count++))
            fi
        done < "$USER_DATABASE"
    fi

    if [[ $count -eq 0 ]]; then
        ok "No se encontraron usuarios caducados."
    else
        ok "Se eliminaron $count usuario(s) caducado(s) exitosamente."
    fi
    pause
}

generar_token_http_conexion() {
    clear
    echo -e "${CYAN}========================================================================${NC}"
    echo -e "${WHITE}               GENERAR TOKEN EXCLUSIVO HTTP CONEXION                    ${NC}"
    echo -e "${CYAN}========================================================================${NC}"
    read -r -p " Usuario a generar Token: " username
    if ! id "$username" >/dev/null 2>&1; then
        fail "El usuario '$username' no existe."
        pause; return
    fi
    local u_info; u_info=$(grep "^$username:" "$USER_DATABASE" 2>/dev/null || echo "$username:1:N/A")
    local u_limit; u_limit=$(echo "$u_info" | cut -d: -f2)
    local u_exp; u_exp=$(echo "$u_info" | cut -d: -f3)

    read -r -p " Ingresa la contraseña del usuario: " u_pass
    [[ -z "$u_pass" ]] && u_pass="1234"

    local ip; ip=$(get_public_ip)
    local bhttp_ports_arr; read -r -a bhttp_ports_arr <<< "$(scan_bhttp_ports)"
    local b_port="${bhttp_ports_arr[0]:-8080}"

    local json_payload
    json_payload=$(cat << EOF
{"app":"HTTP_CONEXION","server":"$ip","ssh_port":22,"ssl_port":443,"bhttp_port":$b_port,"udp_port":36712,"user":"$username","pass":"$u_pass","limit":$u_limit,"exp":"$u_exp","auth_sig":"CRISDEV_$(date +%s)"}
EOF
)
    local b64_token
    b64_token=$(echo -n "$json_payload" | base64 | tr -d '\n')
    local final_token="HC://${b64_token}"

    echo ""
    echo -e "${GREEN}✔ Token generado exitosamente para HTTP Conexión:${NC}"
    echo "────────────────────────────────────────────────────────────────────────"
    echo -e "${YELLOW}${final_token}${NC}"
    echo "────────────────────────────────────────────────────────────────────────"
    echo -e "${WHITE}• Usuario:${NC}    ${GREEN}$username${NC}"
    echo -e "${WHITE}• Vencimiento:${NC}${CYAN}$u_exp${NC}"
    echo -e "${WHITE}• Límite:${NC}     ${YELLOW}$u_limit conexión(es)${NC}"
    echo -e "${WHITE}• Servidor:${NC}   ${CYAN}$ip${NC}"
    echo ""
    echo -e "${DIM}Este Token encapsula credenciales seguras listas para importar en 1 click en la app HTTP Conexión.${NC}"
    pause
}

monitor_conexiones() {
    clear
    echo -e "${CYAN}========================================================================${NC}"
    echo -e "${WHITE}                       MONITOR DE CONEXIONES ONLINE                     ${NC}"
    echo -e "${CYAN}========================================================================${NC}"
    printf "%-18s %-12s %-20s\n" "USUARIO" "PID" "DESDE"
    echo "────────────────────────────────────────────────────────────────────────"
    who 2>/dev/null | grep -E "pts|sshd" | awk '{printf "%-18s %-12s %-20s\n", $1, $2, $5}' || echo "No hay conexiones activas"
    echo "────────────────────────────────────────────────────────────────────────"
    pause
}

# ─────────────────────────────────────────────────────────────────────────────
#  CABECERA Y LISTA DE SERVICIOS ACTIVOS DE PROTOCOLOS (SOLO ACTIVOS)
# ─────────────────────────────────────────────────────────────────────────────
print_protocols_active_header() {
    echo -e "${CYAN}========================================================================${NC}"
    echo -e "${WHITE}                       CONFIGURACION DE PROTOCOLOS                      ${NC}"
    echo -e "${CYAN}========================================================================${NC}"

    # OpenSSH
    if systemctl is-active --quiet sshd 2>/dev/null || systemctl is-active --quiet ssh 2>/dev/null || pgrep -f sshd >/dev/null 2>&1; then
        echo -e "${CYAN}SERVICIO: ${WHITE}OPENSSH ${CYAN}PUERTO: ${GREEN}22${NC}"
    fi

    # Proxy Socks / Python Socks / WebSocket
    if systemctl is-active --quiet proxy-socks 2>/dev/null || systemctl is-active --quiet ws-proxy 2>/dev/null || pgrep -f "proxy.py" >/dev/null 2>&1; then
        local p_port; p_port=$(ss -tlpn 2>/dev/null | grep -E "proxy|python" | awk '{print $4}' | awk -F: '{print $NF}' | head -n1 || echo "80")
        echo -e "${CYAN}SERVICIO: ${WHITE}PROXY SOCKS ${CYAN}PUERTO: ${GREEN}${p_port:-80}${NC}"
    fi

    # SSL Tunnel
    if systemctl is-active --quiet stunnel4 2>/dev/null || pgrep -f stunnel4 >/dev/null 2>&1; then
        echo -e "${CYAN}SERVICIO: ${WHITE}SSL TUNNEL ${CYAN}PUERTO: ${GREEN}443${NC}"
    fi

    # Dropbear
    if systemctl is-active --quiet dropbear 2>/dev/null || pgrep -f dropbear >/dev/null 2>&1; then
        local dp_ports; dp_ports=$(ss -tlpn 2>/dev/null | grep dropbear | awk '{print $4}' | awk -F: '{print $NF}' | sort -n -u | tr '\n' ' ' | sed 's/ $//' || echo "110")
        echo -e "${CYAN}SERVICIO: ${WHITE}DROPBEAR ${CYAN}PUERTO: ${GREEN}${dp_ports:-110}${NC}"
    fi

    # Hysteria v1 / UDP CRIS
    if systemctl is-active --quiet hysteria-server.service 2>/dev/null || pgrep -f hysteria >/dev/null 2>&1; then
        local uport="36712"
        if [[ -f /etc/hysteria/config.json ]]; then
            uport=$(grep -o '"listen": "[^"]*"' /etc/hysteria/config.json 2>/dev/null | cut -d: -f3 | tr -d '":, ' || echo "36712")
            [[ -z "$uport" ]] && uport=$(grep -o '"listen": ":[0-9]*"' /etc/hysteria/config.json 2>/dev/null | cut -d: -f3 | tr -d '":, ' || echo "36712")
        fi
        echo -e "${CYAN}SERVICIO: ${WHITE}HYSTERIA v1 (UDP CRIS) ${CYAN}PUERTO: ${GREEN}${uport}${NC}"
    fi

    # BHTTP Multi-Puerto
    local bhttp_arr
    read -r -a bhttp_arr <<< "$(scan_bhttp_ports)"
    if [[ ${#bhttp_arr[@]} -gt 0 ]]; then
        local b_str; b_str=$(IFS=", "; echo "${bhttp_arr[*]}")
        echo -e "${CYAN}SERVICIO: ${WHITE}BHTTP RELAY ${CYAN}PUERTO: ${GREEN}${b_str}${NC}"
    fi

    # BadVPN
    if systemctl is-active --quiet badvpn.service 2>/dev/null || pgrep -f badvpn-udpgw >/dev/null 2>&1; then
        echo -e "${CYAN}SERVICIO: ${WHITE}BADVPN ${CYAN}PUERTO: ${GREEN}7300${NC}"
    fi

    # SlowDNS
    if pgrep -f dnstt-server >/dev/null 2>&1 || systemctl is-active --quiet dnstt-server 2>/dev/null; then
        echo -e "${CYAN}SERVICIO: ${WHITE}SLOWDNS ${CYAN}PUERTO: ${GREEN}53${NC}"
    fi

    # V2Ray / Xray
    if systemctl is-active --quiet xray 2>/dev/null || systemctl is-active --quiet v2ray 2>/dev/null; then
        echo -e "${CYAN}SERVICIO: ${WHITE}V2RAY / XRAY ${CYAN}PUERTO: ${GREEN}443, 8443${NC}"
    fi

    echo -e "${CYAN}========================================================================${NC}"
}

# ─────────────────────────────────────────────────────────────────────────────
#  2. CONFIGURACION DE PROTOCOLOS (GRID 2 COLUMNAS)
# ─────────────────────────────────────────────────────────────────────────────
menu_protocolos() {
    while true; do
        clear
        print_protocols_active_header

        local st_ssh; st_ssh=$(get_status_icon "sshd")
        local st_socks; st_socks=$(get_status_icon "proxy")
        local st_ssl; st_ssl=$(get_status_icon "stunnel4")
        local st_drop; st_drop=$(get_status_icon "dropbear")
        local st_v2ray; st_v2ray=$(get_status_icon "xray")
        local st_slow; st_slow=$(get_status_icon "dnstt")
        local st_hyst; st_hyst=$(get_status_icon "hysteria")
        local st_trojan; st_trojan=$(get_status_icon "trojan")
        local st_badvpn; st_badvpn=$(get_status_icon "badvpn")
        local st_ovpn; st_ovpn=$(get_status_icon "openvpn")
        local st_ws; st_ws=$(get_status_icon "websocket")
        local st_sslh; st_sslh=$(get_status_icon "sslh")
        local st_squid; st_squid=$(get_status_icon "squid")
        local st_chisel; st_chisel=$(get_status_icon "chisel")
        local st_bhttp; st_bhttp=$(get_status_icon "bhttp")

        printf " ${GREEN}[1]${WHITE}  > OPENSSH            %b    ${GREEN}[10]${WHITE} > OPENVPN             %b\n" "$st_ssh" "$st_ovpn"
        printf " ${GREEN}[2]${WHITE}  > PROXY SOCKS        %b    ${GREEN}[11]${WHITE} > WEBSOCKET-CORRECTOR %b\n" "$st_socks" "$st_ws"
        printf " ${GREEN}[3]${WHITE}  > SSL TUNNEL         %b    ${GREEN}[12]${WHITE} > SSLH MULTIPLEX      %b\n" "$st_ssl" "$st_sslh"
        printf " ${GREEN}[4]${WHITE}  > DROPBEAR           %b    ${GREEN}[13]${WHITE} > SQUID PROXY         %b\n" "$st_drop" "$st_squid"
        printf " ${GREEN}[5]${WHITE}  > V2RAY              %b    ${GREEN}[14]${WHITE} > CHISEL              %b\n" "$st_v2ray" "$st_chisel"
        printf " ${GREEN}[6]${WHITE}  > SLOWDNS            %b    ${GREEN}[15]${WHITE} > BHTTP MULTI-PUERTO  %b\n" "$st_slow" "$st_bhttp"
        printf " ${GREEN}[7]${WHITE}  > HYSTERIA / UDPCRIS %b    ${GREEN}[16]${WHITE} > EXPORTAR PARA GEN\n" "$st_hyst"
        printf " ${GREEN}[8]${WHITE}  > TROJAN-GO          %b    ${GREEN}[17]${WHITE} > TEST DE CONECTIVIDAD\n" "$st_trojan"
        printf " ${GREEN}[9]${WHITE}  > BADVPN             %b    ${RED}[0]${WHITE}  > VOLVER\n" "$st_badvpn"
        echo -e "${CYAN}========================================================================${NC}"
        read -r -p " Opcion: " proto_opt

        case "$proto_opt" in
            1) config_openssh ;;
            2) config_proxy_socks ;;
            3) config_stunnel ;;
            4) menu_dropbear ;;
            5) menu_v2ray ;;
            6) menu_slowdns ;;
            7) menu_udp ;;
            8) menu_trojan ;;
            9) instalar_badvpn ;;
            10) menu_openvpn ;;
            11) menu_websocket ;;
            12) menu_sslh ;;
            13) menu_squid ;;
            14) menu_chisel ;;
            15) menu_bhttp ;;
            16) exportar_servidor_gen ;;
            17) test_general_puertos ;;
            0) break ;;
            *) warn "Opción inválida"; sleep 1 ;;
        esac
    done
}

# ─────────────────────────────────────────────────────────────────────────────
#  PROTOCOLOS: SUBRUTINAS
# ─────────────────────────────────────────────────────────────────────────────
config_openssh() {
    clear
    echo -e "${CYAN}========================================================================${NC}"
    echo -e "${WHITE}                       CONFIGURACION OPENSSH SERVER                     ${NC}"
    echo -e "${CYAN}========================================================================${NC}"
    info "Optimizando configuración de OpenSSH (Puerto 22)..."
    sed -i 's/#*AllowTcpForwarding.*/AllowTcpForwarding yes/' /etc/ssh/sshd_config
    sed -i 's/#*GatewayPorts.*/GatewayPorts yes/' /etc/ssh/sshd_config
    sed -i 's/#*TCPKeepAlive.*/TCPKeepAlive yes/' /etc/ssh/sshd_config
    sed -i 's/#*ClientAliveInterval.*/ClientAliveInterval 30/' /etc/ssh/sshd_config
    sed -i 's/#*ClientAliveCountMax.*/ClientAliveCountMax 3/' /etc/ssh/sshd_config
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
    ok "OpenSSH configurado y activo en puerto 22 con TCP Forwarding."
    pause
}

config_proxy_socks() {
    clear
    echo -e "${CYAN}========================================================================${NC}"
    echo -e "${WHITE}                       PROXY SOCKS / HTTP PROXY                         ${NC}"
    echo -e "${CYAN}========================================================================${NC}"
    echo -e " ${GREEN}1)${WHITE} Iniciar Proxy Socks en Puerto 80"
    echo -e " ${GREEN}2)${WHITE} Iniciar Proxy Socks en Puerto Personalizado"
    echo -e " ${RED}3)${WHITE} Detener Proxy Socks"
    echo -e " ${RED}0)${WHITE} Volver"
    echo -e "${CYAN}========================================================================${NC}"
    read -r -p " Opcion: " ps_opt
    case "$ps_opt" in
        1|2)
            local pport=80
            [[ "$ps_opt" == "2" ]] && read -r -p " Ingresa puerto proxy (ej: 8080): " pport
            [[ ! "$pport" =~ ^[0-9]+$ ]] && pport=80
            mkdir -p /opt/ssh-cris
            cat > /opt/ssh-cris/proxy.py << 'PYEOF'
import socket, threading, select, sys

def handle_client(client_socket, target_host, target_port):
    try:
        server_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server_socket.connect((target_host, target_port))
    except Exception:
        client_socket.close()
        return

    sockets = [client_socket, server_socket]
    while True:
        try:
            r, _, _ = select.select(sockets, [], [], 30)
            if not r: break
            for s in r:
                other = server_socket if s is client_socket else client_socket
                data = s.recv(8192)
                if not data: return
                other.sendall(data)
        except Exception:
            break
    client_socket.close()
    server_socket.close()

def main(listen_port):
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(('0.0.0.0', int(listen_port)))
    server.listen(256)
    while True:
        client, _ = server.accept()
        t = threading.Thread(target=handle_client, args=(client, '127.0.0.1', 22))
        t.daemon = True
        t.start()

if __name__ == '__main__':
    main(sys.argv[1] if len(sys.argv) > 1 else 80)
PYEOF
            cat > /etc/systemd/system/proxy-socks.service << EOF
[Unit]
Description=CRISDEV Proxy Socks
After=network.target

[Service]
ExecStart=/usr/bin/python3 /opt/ssh-cris/proxy.py $pport
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload
            systemctl enable --now proxy-socks.service
            ufw allow "$pport"/tcp 2>/dev/null || true
            ok "Proxy Socks activo en puerto TCP $pport -> SSH 22"
            pause
            ;;
        3)
            systemctl disable --now proxy-socks.service 2>/dev/null || true
            ok "Proxy Socks detenido."
            pause
            ;;
        0) return ;;
    esac
}

config_stunnel() {
    clear
    echo -e "${CYAN}========================================================================${NC}"
    echo -e "${WHITE}                       SSL TUNNEL (STUNNEL4 PUERTO 443)                 ${NC}"
    echo -e "${CYAN}========================================================================${NC}"
    info "Instalando y configurando Stunnel4 SSL en puerto 443 -> SSH 22..."
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

menu_dropbear() {
    clear
    echo -e "${CYAN}========================================================================${NC}"
    echo -e "${WHITE}                       DROPBEAR SSH                                     ${NC}"
    echo -e "${CYAN}========================================================================${NC}"
    echo -e " ${GREEN}1)${WHITE} Configurar e Iniciar Dropbear (Elegir Puertos)"
    echo -e " ${RED}2)${WHITE} Detener / Desactivar Dropbear"
    echo -e " ${RED}0)${WHITE} Volver"
    echo -e "${CYAN}========================================================================${NC}"
    read -r -p " Opcion: " d_opt
    case "$d_opt" in
        1)
            read -r -p " Puertos para Dropbear separados por espacio (ej: 110 442 8888): " dp_pts
            [[ -z "$dp_pts" ]] && dp_pts="110 442 8888"
            apt-get install -y dropbear 2>/dev/null || true
            local extra_args=""
            for p in $dp_pts; do extra_args="$extra_args -p $p"; done
            cat > /etc/default/dropbear << EOF
NO_START=0
DROPBEAR_PORT=
DROPBEAR_EXTRA_ARGS="$extra_args"
DROPBEAR_BANNER=""
DROPBEAR_RECEIVE_WINDOW=65536
EOF
            systemctl restart dropbear 2>/dev/null || true
            for p in $dp_pts; do ufw allow "$p"/tcp 2>/dev/null || true; done
            ok "Dropbear activo en puertos: $dp_pts"
            pause
            ;;
        2)
            systemctl stop dropbear 2>/dev/null || true
            systemctl disable dropbear 2>/dev/null || true
            ok "Dropbear detenido."
            pause
            ;;
        0) return ;;
    esac
}

menu_v2ray() {
    clear
    echo -e "${CYAN}========================================================================${NC}"
    echo -e "${WHITE}                       V2RAY / XRAY CORE                                ${NC}"
    echo -e "${CYAN}========================================================================${NC}"
    echo -e " ${GREEN}1)${WHITE} Instalar Xray-core Oficial"
    echo -e " ${GREEN}2)${WHITE} Ver Estado del Servicio"
    echo -e " ${RED}3)${WHITE} Detener Xray"
    echo -e " ${RED}0)${WHITE} Volver"
    echo -e "${CYAN}========================================================================${NC}"
    read -r -p " Opcion: " vx_opt
    case "$vx_opt" in
        1)
            info "Instalando Xray-core..."
            bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
            ok "Xray instalado."
            pause
            ;;
        2) systemctl status xray --no-pager || true; pause ;;
        3) systemctl disable --now xray 2>/dev/null || true; ok "Xray detenido."; pause ;;
        0) return ;;
    esac
}

menu_slowdns() {
    clear
    echo -e "${CYAN}========================================================================${NC}"
    echo -e "${WHITE}                       SLOWDNS (DNSTT SERVER PUERTO 53)                 ${NC}"
    echo -e "${CYAN}========================================================================${NC}"
    echo -e " ${GREEN}1)${WHITE} Configurar Dominio NameServer (NS) y Generar Claves"
    echo -e " ${GREEN}2)${WHITE} Ver Clave Pública y NameServer"
    echo -e " ${RED}3)${WHITE} Detener SlowDNS"
    echo -e " ${RED}0)${WHITE} Volver"
    echo -e "${CYAN}========================================================================${NC}"
    read -r -p " Opcion: " sd_opt
    case "$sd_opt" in
        1)
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
            [[ -f /etc/slowdns/server.pub ]] && echo -e "${YELLOW}Clave Pública:${NC} $(cat /etc/slowdns/server.pub)"
            pause
            ;;
        2)
            if [[ -f /etc/slowdns/server.pub ]]; then
                echo -e "${WHITE}• NameServer:${NC} $(cat /etc/slowdns/ns.txt 2>/dev/null || echo 'No configurado')"
                echo -e "${WHITE}• Clave Pública:${NC} ${GREEN}$(cat /etc/slowdns/server.pub)${NC}"
            else
                warn "SlowDNS aún no está configurado."
            fi
            pause
            ;;
        3) pkill -f dnstt-server 2>/dev/null || true; ok "SlowDNS detenido."; pause ;;
        0) return ;;
    esac
}

menu_udp() {
    clear
    echo -e "${CYAN}========================================================================${NC}"
    echo -e "${WHITE}                       HYSTERIA v1 / UDP CRIS                           ${NC}"
    echo -e "${CYAN}========================================================================${NC}"
    echo -e " ${GREEN}1)${WHITE} Instalar / Configurar UDP CRIS (Hysteria Engine)"
    echo -e " ${GREEN}2)${WHITE} Activar / Desactivar Port Hopping (Rango 6000:50000)"
    echo -e " ${GREEN}3)${WHITE} Ver Estado y Logs"
    echo -e " ${RED}4)${WHITE} Detener / Desinstalar UDP CRIS"
    echo -e " ${RED}0)${WHITE} Volver"
    echo -e "${CYAN}========================================================================${NC}"
    read -r -p " Opcion: " u_opt
    case "$u_opt" in
        1)
            info "Configurando UDP CRIS Core (Hysteria Engine)..."
            read -r -p " Puerto UDP de escucha (ej: 36712 o 5666): " uport
            [[ ! "$uport" =~ ^[0-9]+$ ]] && uport=36712

            read -r -p " Contraseña OBFS (ej: crisdev): " obfs_pass
            [[ -z "$obfs_pass" ]] && obfs_pass="crisdev"

            read -r -p " Contraseña de Autenticación (Auth): " auth_pass
            [[ -z "$auth_pass" ]] && auth_pass="crisdev"

            mkdir -p /etc/hysteria /usr/local/bin
            curl -fL --retry 3 "https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-amd64" -o /usr/local/bin/hysteria 2>/dev/null || \
            wget -q "https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-amd64" -O /usr/local/bin/hysteria
            chmod +x /usr/local/bin/hysteria

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
            ;;
        2)
            if iptables -t nat -L PREROUTING -n 2>/dev/null | grep -q "6000:50000"; then
                iptables -t nat -D PREROUTING -p udp --dport 6000:50000 -j REDIRECT 2>/dev/null || true
                ok "Port Hopping desactivado."
            else
                local uport="36712"
                [[ -f /etc/hysteria/config.json ]] && uport=$(grep -o '"listen": "[^"]*"' /etc/hysteria/config.json 2>/dev/null | cut -d: -f3 | tr -d '":, ' || echo "36712")
                iptables -t nat -A PREROUTING -p udp --dport 6000:50000 -j REDIRECT --to-ports "$uport" 2>/dev/null || true
                ok "Port hopping UDP 6000-50000 activado hacia $uport."
            fi
            pause
            ;;
        3) systemctl status hysteria-server.service --no-pager || true; pause ;;
        4)
            systemctl disable --now hysteria-server.service 2>/dev/null || true
            rm -rf /etc/hysteria /usr/local/bin/hysteria /etc/systemd/system/hysteria-server.service
            systemctl daemon-reload
            ok "UDP CRIS desinstalado."
            pause
            ;;
        0) return ;;
    esac
}

menu_trojan() {
    clear
    echo -e "${CYAN}========================================================================${NC}"
    echo -e "${WHITE}                       TROJAN-GO                                        ${NC}"
    echo -e "${CYAN}========================================================================${NC}"
    info "Trojan-Go integrado via motor Xray (Puerto 443 / 8443)."
    pause
}

instalar_badvpn() {
    clear
    echo -e "${CYAN}========================================================================${NC}"
    echo -e "${WHITE}                       BADVPN UDPGW (PUERTO 7300)                       ${NC}"
    echo -e "${CYAN}========================================================================${NC}"
    info "Instalando BadVPN UDPGW (Puerto 7300 - Juegos / Llamadas WhatsApp)..."
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

menu_openvpn() {
    clear
    echo -e "${CYAN}========================================================================${NC}"
    echo -e "${WHITE}                       OPENVPN SERVER                                   ${NC}"
    echo -e "${CYAN}========================================================================${NC}"
    info "Instalador de OpenVPN."
    if ! command -v openvpn >/dev/null 2>&1; then
        apt-get install -y openvpn 2>/dev/null || true
    fi
    ok "Soporte OpenVPN verificado."
    pause
}

menu_websocket() {
    clear
    echo -e "${CYAN}========================================================================${NC}"
    echo -e "${WHITE}                       WEBSOCKET-CORRECTOR                              ${NC}"
    echo -e "${CYAN}========================================================================${NC}"
    info "Iniciando WebSocket Proxy Corrector en puerto 80 / 8080..."
    config_proxy_socks
}

menu_sslh() {
    clear
    echo -e "${CYAN}========================================================================${NC}"
    echo -e "${WHITE}                       SSLH MULTIPLEX                                   ${NC}"
    echo -e "${CYAN}========================================================================${NC}"
    info "Instalando SSLH Multiplex (Puerto 443 SSH + SSL + OpenVPN)..."
    apt-get install -y sslh 2>/dev/null || true
    ok "SSLH disponible."
    pause
}

menu_squid() {
    clear
    echo -e "${CYAN}========================================================================${NC}"
    echo -e "${WHITE}                       SQUID PROXY (PUERTOS 3128 / 8080)                ${NC}"
    echo -e "${CYAN}========================================================================${NC}"
    apt-get install -y squid 2>/dev/null || true
    ok "Squid Proxy configurado."
    pause
}

menu_chisel() {
    clear
    echo -e "${CYAN}========================================================================${NC}"
    echo -e "${WHITE}                       CHISEL TUNNEL                                    ${NC}"
    echo -e "${CYAN}========================================================================${NC}"
    info "Chisel TCP/UDP Tunnel over HTTP."
    pause
}

menu_bhttp() {
    while true; do
        clear
        local ports_arr
        read -r -a ports_arr <<< "$(scan_bhttp_ports)"
        local total=${#ports_arr[@]}

        echo -e "${CYAN}========================================================================${NC}"
        echo -e "${WHITE}                 BHTTP MULTI-PUERTO RELAY (WAKKO ENGINE)                ${NC}"
        echo -e "${CYAN}========================================================================${NC}"
        if [[ $total -gt 0 ]]; then
            echo -e " ${WHITE}Puertos BHTTP Activos: ${GREEN}${total}${WHITE} | Lista: ${YELLOW}${ports_arr[*]}${NC}"
        else
            echo -e " ${WHITE}Puertos BHTTP Activos: ${DIM}Ninguno (Apagado)${NC}"
        fi
        echo -e "${CYAN}========================================================================${NC}"
        echo -e " ${GREEN}[1]${WHITE} > Instalar / Actualizar Motor BHTTP Relay"
        echo -e " ${GREEN}[2]${WHITE} > Configurar Puerto Principal BHTTP (ej: 8080 -> SSH 22)"
        echo -e " ${GREEN}[3]${WHITE} > Abrir Puerto Adicional (Multi-Puerto: 80, 8888, 3128, etc.)"
        echo -e " ${GREEN}[4]${WHITE} > Listar Puertos BHTTP Activos"
        echo -e " ${GREEN}[5]${WHITE} > Eliminar un Puerto BHTTP Específico"
        echo -e " ${GREEN}[6]${WHITE} > Probar Conectividad BHTTP -> Backend SSH (Socket Test)"
        echo -e " ${GREEN}[7]${WHITE} > Ver Logs en Vivo de BHTTP"
        echo -e " ${RED}[8]${WHITE} > Detener / Desinstalar Servicios BHTTP"
        echo -e " ${RED}[0]${WHITE} > Volver a Protocolos"
        echo -e "${CYAN}========================================================================${NC}"
        read -r -p " Opcion: " b_opt

        case "$b_opt" in
            1)
                info "Descargando motor BHTTP Relay oficial..."
                local arch; arch=$(uname -m)
                local url=""
                [[ "$arch" == "x86_64" || "$arch" == "amd64" ]] && url="$AMD64_BHTTP"
                [[ "$arch" == "aarch64" || "$arch" == "arm64" ]] && url="$ARM64_BHTTP"
                mkdir -p "$BHTTP_BASE"
                systemctl stop wakkodev-bhttp.service 2>/dev/null || true
                curl -fL --retry 3 "$url" -o /usr/local/bin/wakkodev-bhttp-server
                chmod 755 /usr/local/bin/wakkodev-bhttp-server
                ok "Motor BHTTP instalado en /usr/local/bin/wakkodev-bhttp-server"
                pause
                ;;
            2)
                read -r -p " Ingresa puerto principal para BHTTP (ej: 8080 o 80): " bport
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
                ;;
            3)
                read -r -p " Ingresa puerto adicional (ej: 80, 8888, 3128, 8081): " xport
                [[ ! "$xport" =~ ^[0-9]+$ ]] && { fail "Puerto inválido"; pause; continue; }
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
                ok "Puerto extra BHTTP $xport activado."
                pause
                ;;
            4)
                echo -e "${YELLOW}Puertos BHTTP escuchando:${NC}"
                ss -tlpn | grep -E "bhttp|wakkodev" || echo "No hay puertos BHTTP activos"
                pause
                ;;
            5)
                local ports_arr
                read -r -a ports_arr <<< "$(scan_bhttp_ports)"
                echo -e "Puertos detectados: ${YELLOW}${ports_arr[*]:-Ninguno}${NC}"
                read -r -p " Ingresa el puerto a eliminar: " del_port
                if [[ -f "/etc/systemd/system/wakkodev-bhttp-port-${del_port}.service" ]]; then
                    systemctl disable --now "wakkodev-bhttp-port-${del_port}.service" 2>/dev/null || true
                    rm -f "/etc/systemd/system/wakkodev-bhttp-port-${del_port}.service"
                    systemctl daemon-reload
                    ok "Puerto extra $del_port eliminado."
                elif [[ -f "/etc/systemd/system/wakkodev-bhttp.service" ]] && grep -q -- "--port $del_port" /etc/systemd/system/wakkodev-bhttp.service; then
                    systemctl disable --now wakkodev-bhttp.service 2>/dev/null || true
                    rm -f /etc/systemd/system/wakkodev-bhttp.service
                    systemctl daemon-reload
                    ok "Puerto principal $del_port eliminado."
                fi
                pause
                ;;
            6)
                if nc -z -w2 127.0.0.1 22 2>/dev/null || (exec 3<>/dev/tcp/127.0.0.1/22) 2>/dev/null; then
                    ok "Backend SSH en 127.0.0.1:22 respondiendo OK."
                else
                    fail "Backend SSH en 127.0.0.1:22 cerrado."
                fi
                for p in "${ports_arr[@]}"; do
                    if nc -z -w2 127.0.0.1 "$p" 2>/dev/null || (exec 3<>/dev/tcp/127.0.0.1/"$p") 2>/dev/null; then
                        ok "Puerto BHTTP $p: Escuchando correctamente."
                    else
                        fail "Puerto BHTTP $p: No responde."
                    fi
                done
                pause
                ;;
            7)
                journalctl -u "wakkodev-bhttp*" -n 40 --no-pager -f || true
                ;;
            8)
                systemctl disable --now wakkodev-bhttp.service 2>/dev/null || true
                for f in /etc/systemd/system/wakkodev-bhttp-port-*.service; do
                    [[ -f "$f" ]] && systemctl disable --now "$(basename "$f")" 2>/dev/null || true
                done
                rm -f /etc/systemd/system/wakkodev-bhttp*.service
                systemctl daemon-reload
                ok "Servicios BHTTP detenidos."
                pause
                ;;
            0) break ;;
        esac
    done
}

exportar_servidor_gen() {
    clear
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

    echo -e "${CYAN}========================================================================${NC}"
    echo -e "${WHITE}           DATOS PARA IMPORTAR EN EL GEN (APP ANDROID)          ${NC}"
    echo -e "${CYAN}========================================================================${NC}"
    printf " • IP Servidor:         ${GREEN}%-40s${NC}\n" "$ip"
    printf " • Puerto SSH:          ${GREEN}%-40s${NC}\n" "22"
    printf " • Puerto SSL:          ${GREEN}%-40s${NC}\n" "443"
    printf " • BHTTP Relay:         ${GREEN}%-40s${NC}\n" "Principal: $bhttp_main_port (Todos: $bhttp_all)"
    printf " • UDP CRIS (Hysteria): ${GREEN}%-40s${NC}\n" "$uport (OBFS: $obfs_val | Auth: $auth_val)"
    printf " • BadVPN UDPGW:        ${GREEN}%-40s${NC}\n" "7300"
    printf " • SlowDNS NameServer:  ${GREEN}%-40s${NC}\n" "${slowdns_ns}"
    printf " • SlowDNS Clave Pub:   ${GREEN}%-40s${NC}\n" "${slowdns_pub}"
    echo -e "${CYAN}========================================================================${NC}"
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

test_general_puertos() {
    clear
    echo -e "${CYAN}========================================================================${NC}"
    echo -e "${WHITE}                   TEST DE CONECTIVIDAD DE PUERTOS                      ${NC}"
    echo -e "${CYAN}========================================================================${NC}"
    echo -e "${YELLOW}Sockets TCP en escucha:${NC}"
    ss -tlpn | grep -E "sshd|dropbear|stunnel|wakkodev|bhttp|xray|python" || echo "No se encontraron puertos TCP activos"
    echo ""
    echo -e "${YELLOW}Sockets UDP en escucha:${NC}"
    ss -ulpn | grep -E "hysteria|dnstt|badvpn" || echo "No se encontraron puertos UDP activos"
    echo ""
    echo -e "${YELLOW}Reglas NAT / Port Hopping:${NC}"
    iptables -t nat -L PREROUTING -n -v 2>/dev/null | grep -E "6000:50000|REDIRECT" || echo "Sin reglas de Port Hopping activas"
    echo -e "${CYAN}========================================================================${NC}"
    pause
}

# ─────────────────────────────────────────────────────────────────────────────
#  MENÚ PRINCIPAL
# ─────────────────────────────────────────────────────────────────────────────
main_menu() {
    need_root
    while true; do
        draw_main_header
        echo -e " ${GREEN}[1]${WHITE}  > ADMINISTRAR USUARIOS"
        echo -e " ${GREEN}[2]${WHITE}  > CONFIGURACION DE PROTOCOLOS"
        echo -e " ${GREEN}[3]${WHITE}  > MONITOR DE CONEXIONES ONLINE"
        echo -e " ${GREEN}[4]${WHITE}  > EXPORTAR DATOS PARA EL GEN"
        echo -e " ${GREEN}[5]${WHITE}  > OPTIMIZACION DE RED & TCP BBR"
        echo -e " ${GREEN}[6]${WHITE}  > SEGURIDAD & FIREWALL UFW"
        echo -e " ${RED}[0]${WHITE}  > SALIR"
        echo -e "${CYAN}========================================================================${NC}"
        read -r -p " Opcion: " main_opt

        case "$main_opt" in
            1) menu_users ;;
            2) menu_protocolos ;;
            3) monitor_conexiones ;;
            4) exportar_servidor_gen ;;
            5)
                clear
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
                ;;
            6)
                clear
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
