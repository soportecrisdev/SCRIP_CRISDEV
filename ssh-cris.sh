#!/usr/bin/env bash
# ==============================================================================
#  SSH-CRIS v1 — VPS MASTER VPN SUITE & PROTOCOL MANAGER
#  Autor: CRISDEV / HTTP Conexión
#  Base: SSH-Plus / NoxuraSSH Architecture + BHTTP + UDP CRIS + HTTP Conexión
# ==============================================================================

export LC_ALL=C
export LANG=C

VERSION="v1.0-CRISDEV"
TITLE="SSH-CRIS MASTER SUITE"
INSTALL_DIR="/opt/ssh-cris"
BHTTP_BASE="/etc/bhttp"
BHTTP_CONFIG="$BHTTP_BASE/config"
BHTTP_CERTS="$BHTTP_BASE/certs"
USER_DATABASE="/etc/ssh-cris/users.db"
SSHPLUS_DIR="/etc/SSHPlus"

AMD64_BHTTP="https://raw.githubusercontent.com/soportecrisdev/SCRIP_CRISDEV/main/bhttp-server-amd64"
ARM64_BHTTP="https://raw.githubusercontent.com/soportecrisdev/SCRIP_CRISDEV/main/bhttp-server-arm64"
AMD64_XHTTP="https://raw.githubusercontent.com/soportecrisdev/SCRIP_CRISDEV/main/xhttp-server-amd64"
ARM64_XHTTP="https://raw.githubusercontent.com/soportecrisdev/SCRIP_CRISDEV/main/xhttp-server-arm64"

# Hysteria v1.3.5 (Core Oficial para UDPCris / libfarikudp.so)
HYSTERIA_V1_AMD64="https://github.com/apernet/hysteria/releases/download/v1.3.5/hysteria-linux-amd64"
HYSTERIA_V1_ARM64="https://github.com/apernet/hysteria/releases/download/v1.3.5/hysteria-linux-arm64"

# Colores ANSI
SSHPLUS_CYAN=$'\033[1;38;2;76;228;255m'
SSHPLUS_NUM=$'\033[1;38;2;0;255;127m'
SSHPLUS_DARK_GREEN=$'\033[0;32m'
SSHPLUS_SECTION=$'\033[1;38;2;240;230;140m'
SSHPLUS_DATA=$'\033[1;38;2;127;255;0m'
SSHPLUS_COUNTER=$'\033[1;38;2;255;179;71m'

CYAN='\033[1;36m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
WHITE='\033[1;37m'
BLUE='\033[1;34m'
SCOLOR='\033[0m'
NC='\033[0m'

SSHPLUS_PY="$(command -v python3 2>/dev/null || command -v python 2>/dev/null || echo python3)"

# Directorios base
mkdir -p /etc/ssh-cris /etc/SSHPlus/senha /etc/bhttp /etc/bhttp/certs /etc/hysteria /etc/stunnel /etc/slowdns /root
touch "$USER_DATABASE" /etc/SSHPlus/Exp /root/usuarios.db 2>/dev/null || true

# ─────────────────────────────────────────────────────────────────────────────
#  FUNCIONES DE APOYO Y ANIMACIÓN
# ─────────────────────────────────────────────────────────────────────────────
fun_bar() {
    local cmd1="$1"
    local cmd2="${2:-true}"
    (
        [[ -e $HOME/fim ]] && rm -f "$HOME/fim"
        eval "$cmd1" >/dev/null 2>&1
        eval "$cmd2" >/dev/null 2>&1
        touch "$HOME/fim"
    ) >/dev/null 2>&1 &
    tput civis 2>/dev/null || true
    echo -ne "${SSHPLUS_CYAN}ESPERE ${SCOLOR}\033[1;37m- ${SSHPLUS_CYAN}["
    while true; do
        for ((i = 0; i < 18; i++)); do
            echo -ne "${SSHPLUS_CYAN}#"
            sleep 0.08s
        done
        [[ -e $HOME/fim ]] && rm -f "$HOME/fim" && break
        echo -e "${SSHPLUS_CYAN}]${SCOLOR}"
        sleep 0.5s
        tput cuu1 2>/dev/null || true
        tput dl1 2>/dev/null || true
        echo -ne "${SSHPLUS_CYAN}ESPERE ${SCOLOR}\033[1;37m- ${SSHPLUS_CYAN}["
    done
    echo -e "${SSHPLUS_CYAN}]${SCOLOR}\033[1;37m - OK !\033[0m"
    tput cnorm 2>/dev/null || true
}

sshplus_line() {
    echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
}

pause() {
    echo ""
    read -r -p " Presiona [ENTER] para continuar..." _ || true
}

get_public_ip() {
    local ip
    ip=$(curl -s --connect-timeout 3 https://api.ipify.org 2>/dev/null || curl -s --connect-timeout 3 https://ifconfig.me 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")
    echo "$ip"
}

verif_ptrs() {
    local porta=$1
    local PT svcs pton
    PT=$(lsof -V -i tcp -P -n 2>/dev/null | grep -v "ESTABLISHED" | grep -v "COMMAND" | grep "LISTEN" || true)
    if [[ -n "$PT" ]]; then
        for pton in $(echo "$PT" | cut -d: -f2 | cut -d' ' -f1 | uniq); do
            svcs=$(echo "$PT" | grep -w "$pton" | awk '{print $1}' | uniq)
            if [[ "$porta" == "$pton" ]]; then
                echo -e "\n\033[1;31mPUERTO \033[1;33m$porta \033[1;31mEN USO POR \033[1;37m$svcs\033[0m"
                sleep 2
                return 1
            fi
        done
    fi
    return 0
}

verif_ptrs_socks() {
    local porta=$1
    if command -v lsof >/dev/null 2>&1; then
        local occ
        occ=$(lsof -iTCP:"$porta" -sTCP:LISTEN -n -P 2>/dev/null | tail -n +2)
        if [[ -n "$occ" ]]; then
            echo -e "\n\033[1;31mPUERTO \033[1;33m$porta \033[1;31mEN USO (LISTEN):\033[0m"
            echo "$occ"
            sleep 2
            return 1
        fi
    elif command -v ss >/dev/null 2>&1; then
        if ss -tln 2>/dev/null | grep -qE "[:,]${porta}([^0-9]|$)"; then
            echo -e "\n\033[1;31mPUERTO \033[1;33m$porta \033[1;31mEN USO (ss LISTEN)\033[0m"
            sleep 2
            return 1
        fi
    fi
    return 0
}

scan_bhttp_ports() {
    local ports=()
    local raw_ports
    raw_ports=$(ss -tlpn 2>/dev/null | grep -E "bhttp-server|bilola-server|wakkodev" | grep -v -E "xhttp|tls" | awk '{print $4}' | awk -F: '{print $NF}' | sort -n -u)
    if [[ -n "$raw_ports" ]]; then
        for p in $raw_ports; do
            [[ "$p" =~ ^[0-9]+$ ]] && ports+=("$p")
        done
    fi
    if [[ ${#ports[@]} -eq 0 ]]; then
        local svc_ports
        svc_ports=$(grep -h -o -E "\-\-port [0-9]+" /etc/systemd/system/bhttp*.service /etc/systemd/system/wakkodev-bhttp*.service 2>/dev/null | awk '{print $2}' | sort -n -u || true)
        for p in $svc_ports; do
            [[ "$p" =~ ^[0-9]+$ ]] && ports+=("$p")
        done
    fi
    echo "${ports[*]:-}"
}

scan_xhttp_port() {
    local tls_p=""
    if systemctl is-active --quiet bhttp-tls.service 2>/dev/null || pgrep -f 'xhttp-server|bilola-xhttp' >/dev/null 2>&1; then
        [[ -f /etc/bhttp/tls_port ]] && tls_p=$(cat /etc/bhttp/tls_port 2>/dev/null)
        if [[ -z "$tls_p" ]]; then
            tls_p=$(ss -tlpn 2>/dev/null | grep -E "xhttp-server|bilola-xhttp" | awk '{print $4}' | awk -F: '{print $NF}' | head -1)
        fi
        [[ -z "$tls_p" ]] && tls_p="443"
    fi
    echo "$tls_p"
}

scan_hcr_ports() {
    local hcr_pts=()
    if [[ -s /etc/hcr-server/ports.conf ]]; then
        while IFS='|' read -r p _rest; do
            [[ -z "$p" ]] && continue
            if systemctl is-active --quiet "hcr-${p}.service" 2>/dev/null; then
                hcr_pts+=("$p")
            fi
        done < /etc/hcr-server/ports.conf
    fi
    if [[ ${#hcr_pts[@]} -eq 0 ]]; then
        local raw_hcr
        raw_hcr=$(ss -tlpn 2>/dev/null | grep -E "hcr-server" | awk '{print $4}' | awk -F: '{print $NF}' | sort -n -u)
        for p in $raw_hcr; do
            [[ "$p" =~ ^[0-9]+$ ]] && hcr_pts+=("$p")
        done
    fi
    echo "${hcr_pts[*]:-}"
}

scan_udpcustom_port() {
    local udp_p=""
    if [[ -f /opt/udp-custom/config.json ]]; then
        udp_p=$(grep -oE '"listen"[[:space:]]*:[[:space:]]*"[^"]+"' /opt/udp-custom/config.json 2>/dev/null | grep -oE '[0-9]+$' | head -1)
        [[ -z "$udp_p" || "$udp_p" == "0" ]] && udp_p=$(grep -oE ':[0-9]+' /opt/udp-custom/config.json 2>/dev/null | tr -d ':' | head -1)
    fi
    if [[ -z "$udp_p" || "$udp_p" == "0" && -f /etc/udp-custom/server.json ]]; then
        udp_p=$(grep -oE '"listen"[[:space:]]*:[[:space:]]*"[^"]+"' /etc/udp-custom/server.json 2>/dev/null | grep -oE '[0-9]+$' | head -1)
        [[ -z "$udp_p" || "$udp_p" == "0" ]] && udp_p=$(grep -oE ':[0-9]+' /etc/udp-custom/server.json 2>/dev/null | tr -d ':' | head -1)
    fi
    if [[ -z "$udp_p" || "$udp_p" == "0" ]]; then
        udp_p=$(ss -ulnp 2>/dev/null | grep -E "udp-custom|server" | awk '{print $5}' | grep -oE '[0-9]+$' | head -1)
    fi
    [[ "$udp_p" == "0" ]] && udp_p="7100"
    echo "$udp_p"
}

scan_hysteria2_port() {
    local hy2_p=""
    if [[ -f /etc/hysteria2/config.yaml ]]; then
        hy2_p=$(grep -E '^[[:space:]]*listen:' /etc/hysteria2/config.yaml 2>/dev/null | head -1 | awk '{print $2}' | tr -d '"' | tr -d "'" | sed 's/^://')
    fi
    if [[ -z "$hy2_p" ]]; then
        hy2_p=$(ss -ulnp 2>/dev/null | grep -E "hysteria2" | awk '{print $5}' | grep -oE '[0-9]+$' | head -1)
    fi
    echo "$hy2_p"
}

get_proc_ports() {
    local pattern="$1"
    local ports=()
    if command -v ss >/dev/null 2>&1; then
        while read -r p; do
            [[ -n "$p" && "$p" =~ ^[0-9]+$ ]] && ports+=("$p")
        done < <(ss -tlpn 2>/dev/null | grep -E "$pattern" | awk '{print $4}' | awk -F: '{print $NF}' | sort -n -u)
    fi
    if [[ ${#ports[@]} -eq 0 ]] && command -v netstat >/dev/null 2>&1; then
        while read -r p; do
            [[ -n "$p" && "$p" =~ ^[0-9]+$ ]] && ports+=("$p")
        done < <(netstat -tlpn 2>/dev/null | grep -E "$pattern" | awk '{print $4}' | awk -F: '{print $NF}' | sort -n -u)
    fi
    echo "${ports[*]:-}"
}

# ─────────────────────────────────────────────────────────────────────────────
#  HELPER DE USUARIOS
# ─────────────────────────────────────────────────────────────────────────────
get_user_list() {
    local -A seen=()
    local u_list=()

    # 1. Usuarios Linux reales UID >= 1000
    if [[ -f /etc/passwd ]]; then
        while IFS=: read -r u _ uid _ _ _ _; do
            [[ -z "$u" || "$u" =~ ^(nobody|systemd-|polkitd|messagebus|daemon|bin|sys|sync|games|man|lp|mail|news|uucp|proxy|www-data|backup|list|irc|gnats|_apt|sshd|statd|mysql|postfix|dovecot|redis|mongodb)$ ]] && continue
            if [[ "$uid" =~ ^[0-9]+$ ]] && [[ "$uid" -ge 1000 && -z "${seen[$u]:-}" ]]; then
                seen[$u]=1
                u_list+=("$u")
            fi
        done < /etc/passwd
    fi

    # 2. Usuarios en /etc/SSHPlus/senha/
    if [[ -d /etc/SSHPlus/senha ]]; then
        for f in /etc/SSHPlus/senha/*; do
            [[ ! -f "$f" ]] && continue
            local u; u=$(basename "$f")
            if [[ -n "$u" && -z "${seen[$u]:-}" ]]; then
                seen[$u]=1
                u_list+=("$u")
            fi
        done
    fi

    # 3. Usuarios en /root/usuarios.db
    if [[ -f /root/usuarios.db ]]; then
        while read -r u _; do
            [[ -z "$u" || "$u" =~ ^# ]] && continue
            if [[ -z "${seen[$u]:-}" ]]; then
                seen[$u]=1
                u_list+=("$u")
            fi
        done < /root/usuarios.db
    fi

    # 4. Usuarios en $USER_DATABASE
    if [[ -f "$USER_DATABASE" ]]; then
        while IFS=: read -r u _ _; do
            [[ -z "$u" || "$u" =~ ^# ]] && continue
            if [[ -z "${seen[$u]:-}" ]]; then
                seen[$u]=1
                u_list+=("$u")
            fi
        done < "$USER_DATABASE"
    fi

    for u in "${u_list[@]}"; do
        [[ -n "$u" ]] && echo "$u"
    done | sort -u
}

get_user_password() {
    local u="$1"
    if [[ -f "/etc/SSHPlus/senha/$u" ]]; then
        cat "/etc/SSHPlus/senha/$u" | head -n1 | tr -d '\r\n'
    elif [[ -f "$USER_DATABASE" ]] && grep -q "^$u:" "$USER_DATABASE"; then
        grep "^$u:" "$USER_DATABASE" | cut -d: -f4 2>/dev/null || echo "1234"
    else
        echo "----"
    fi
}

get_user_limit() {
    local u="$1"
    if [[ -f /root/usuarios.db ]] && grep -qw "$u" /root/usuarios.db; then
        grep -w "$u" /root/usuarios.db | head -1 | awk '{print $2}'
    elif [[ -f "$USER_DATABASE" ]] && grep -q "^$u:" "$USER_DATABASE"; then
        grep "^$u:" "$USER_DATABASE" | cut -d: -f2
    else
        echo "1"
    fi
}

get_user_days_remaining() {
    local u="$1"
    local raw exp today days
    raw="$(chage -l "$u" 2>/dev/null | awk -F: '/Account expires|La cuenta caduca|Cuenta expira|conta expira/ {gsub(/^ +/,"",$2); print $2; exit}')"
    [[ -z "$raw" ]] && raw="$(chage -l "$u" 2>/dev/null | grep -iE 'expires|caduca|expira' | head -1 | awk -F: '{gsub(/^ +/,"",$2); print $2}')"
    
    if [[ -z "$raw" || "$raw" =~ ^(never|nunca)$ ]]; then
        if [[ -f "$USER_DATABASE" ]] && grep -q "^$u:" "$USER_DATABASE"; then
            raw=$(grep "^$u:" "$USER_DATABASE" | cut -d: -f3)
        fi
    fi

    if [[ -z "$raw" || "$raw" =~ ^(never|nunca)$ ]]; then
        echo "Nunca"
        return
    fi

    exp="$(date -d "$raw" +%s 2>/dev/null || date -d "$raw 23:59:59" +%s 2>/dev/null || echo 0)"
    today="$(date +%s)"
    if [[ $exp -le 0 ]]; then
        echo "S/R"
    elif [[ "$today" -ge "$exp" ]]; then
        echo "Vencido"
    else
        days=$(( (exp - today) / 86400 ))
        echo "${days}d (${raw})"
    fi
}

get_users_stats() {
    local total=0
    local active=0
    local expired=0
    local all_users=()

    while IFS= read -r u; do
        [[ -z "$u" ]] && continue
        all_users+=("$u")
        ((total++))
        local st
        st=$(get_user_days_remaining "$u" 2>/dev/null || echo "S/R")
        if [[ "$st" == "Vencido" ]]; then
            ((expired++))
        else
            ((active++))
        fi
    done < <(get_user_list 2>/dev/null || true)

    local ons=0
    local raw_ons
    raw_ons=$(ps -x 2>/dev/null | grep sshd | grep -v root | grep priv | wc -l || echo 0)
    ons=$(echo "$raw_ons" | tr -dc '0-9')
    [[ -z "$ons" ]] && ons=0

    local onop=0
    if [[ -f /etc/openvpn/openvpn-status.log ]]; then
        local raw_onop
        raw_onop=$(grep -c "10.8.0" /etc/openvpn/openvpn-status.log 2>/dev/null || echo 0)
        onop=$(echo "$raw_onop" | tr -dc '0-9')
    fi
    [[ -z "$onop" ]] && onop=0

    local ondrp=0
    if [[ -f /etc/default/dropbear ]]; then
        local raw_drp
        raw_drp=$(ps aux 2>/dev/null | grep dropbear | grep -v grep | wc -l || echo 0)
        local drp
        drp=$(echo "$raw_drp" | tr -dc '0-9')
        if [[ -n "$drp" && "$drp" -gt 1 ]]; then
            ondrp=$(( drp - 1 ))
        fi
    fi
    [[ -z "$ondrp" ]] && ondrp=0

    local online=$(( ons + onop + ondrp ))
    echo "${total}:${active}:${expired}:${online}"
}

# ─────────────────────────────────────────────────────────────────────────────
#  SUBMÓDULOS DE PROTOCOLOS AUTÉNTICOS SSH-PLUS
# ─────────────────────────────────────────────────────────────────────────────

# 1. OPENSSH
fun_openssh() {
    clear
    echo -e "\E[44;1;37m            OPENSSH             \E[0m\n"
    local cur_ssh
    cur_ssh=$(grep '^Port ' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | xargs || echo "22")
    echo -e "\033[1;33mPUERTOS EN USO: \033[1;32m${cur_ssh:-22}\033[0m\n"
    echo -e "\033[1;31m[\033[1;36m1\033[1;31m] \033[1;37m> \033[1;33mAÑADIR PUERTO\033[1;31m"
    echo -e "[\033[1;36m2\033[1;31m] \033[1;37m> \033[1;33mELIMINAR PUERTO\033[1;31m"
    echo -e "[\033[1;36m0\033[1;31m] \033[1;37m> \033[1;33mVOLVER\033[0m"
    echo ""
    echo -ne "\033[1;32m¿QUÉ DESEA HACER ?\033[1;37m "
    read -r resp
    if [[ "$resp" == '1' ]]; then
        clear
        echo -e "\E[44;1;37m         AÑADIR PUERTO AL SSH         \E[0m\n"
        echo -ne "\033[1;32m¿QUÉ PUERTO DESEA AÑADIR ?\033[1;37m "
        read -r pt
        [[ -z "$pt" || ! "$pt" =~ ^[0-9]+$ ]] && {
            echo -e "\n\033[1;31mPuerto no válido!"
            sleep 2
            return
        }
        verif_ptrs "$pt" || return
        echo -e "\n\033[1;32mAÑADIENDO PUERTO AL SSH\033[0m"
        echo ""
        fun_addpssh() {
            echo "Port $pt" >>/etc/ssh/sshd_config
            sed -i 's/#*AllowTcpForwarding.*/AllowTcpForwarding yes/' /etc/ssh/sshd_config
            sed -i 's/#*GatewayPorts.*/GatewayPorts yes/' /etc/ssh/sshd_config
            systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || service ssh restart 2>/dev/null
        }
        fun_bar 'fun_addpssh'
        ufw allow "$pt"/tcp 2>/dev/null || true
        echo -e "\n\033[1;32mPUERTO $pt AÑADIDO CON ÉXITO!\033[0m"
        sleep 2
    elif [[ "$resp" == '2' ]]; then
        clear
        echo -e "\E[41;1;37m        ELIMINAR PUERTO DEL SSH        \E[0m\n"
        echo -e "\033[1;33mPUERTOS EN USO: \033[1;32m${cur_ssh:-22}\033[0m\n"
        echo -ne "\033[1;32m¿QUÉ PUERTO DESEA ELIMINAR ?\033[1;37m "
        read -r pt
        [[ -z "$pt" || "$pt" == "22" ]] && {
            echo -e "\n\033[1;31mNo se puede eliminar el puerto principal 22 o puerto vacío."
            sleep 2
            return
        }
        sed -i "/^Port $pt/d" /etc/ssh/sshd_config
        systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || service ssh restart 2>/dev/null
        echo -e "\n\033[1;32mPUERTO $pt ELIMINADO CON ÉXITO!\033[0m"
        sleep 2
    fi
}

# 2. PROXY SOCKS / WEBSOCKET (SSH-Plus Native Engine)
fun_socks_prepare_activate() {
    for _k in $(pgrep -f '/etc/SSHPlus/proxy.py' 2>/dev/null); do
        [[ "$_k" =~ ^[0-9]+$ ]] && kill -9 "$_k" 2>/dev/null || true
    done
    for _sp in $(screen -ls 2>/dev/null | grep '\.proxy' | awk '{print $1}'); do
        screen -r -S "$_sp" -X quit 2>/dev/null || true
    done
    screen -wipe >/dev/null 2>&1 || true
}

fun_ws_prepare_activate() {
    for _k in $(pgrep -f '/etc/SSHPlus/wsproxy.py' 2>/dev/null); do
        [[ "$_k" =~ ^[0-9]+$ ]] && kill -9 "$_k" 2>/dev/null || true
    done
    for _sp in $(screen -ls 2>/dev/null | grep '\.ws' | awk '{print $1}'); do
        screen -r -S "$_sp" -X quit 2>/dev/null || true
    done
    screen -wipe >/dev/null 2>&1 || true
}

ensure_proxy_scripts() {
    if [[ ! -f /etc/SSHPlus/proxy.py ]]; then
        if [[ -f "./proxy.py" ]]; then
            cp -f "./proxy.py" /etc/SSHPlus/proxy.py
        elif [[ -f "/opt/ssh-cris/proxy.py" ]]; then
            cp -f "/opt/ssh-cris/proxy.py" /etc/SSHPlus/proxy.py
        else
            curl -fsSL "https://raw.githubusercontent.com/soportecrisdev/SCRIP_CRISDEV/main/proxy.py" -o /etc/SSHPlus/proxy.py 2>/dev/null || \
            wget -q "https://raw.githubusercontent.com/soportecrisdev/SCRIP_CRISDEV/main/proxy.py" -O /etc/SSHPlus/proxy.py 2>/dev/null || true
        fi
    fi
    chmod +x /etc/SSHPlus/proxy.py 2>/dev/null || true

    if [[ ! -f /etc/SSHPlus/wsproxy.py ]]; then
        if [[ -f "./wsproxy.py" ]]; then
            cp -f "./wsproxy.py" /etc/SSHPlus/wsproxy.py
        elif [[ -f "/opt/ssh-cris/wsproxy.py" ]]; then
            cp -f "/opt/ssh-cris/wsproxy.py" /etc/SSHPlus/wsproxy.py
        else
            curl -fsSL "https://raw.githubusercontent.com/soportecrisdev/SCRIP_CRISDEV/main/wsproxy.py" -o /etc/SSHPlus/wsproxy.py 2>/dev/null || \
            wget -q "https://raw.githubusercontent.com/soportecrisdev/SCRIP_CRISDEV/main/wsproxy.py" -O /etc/SSHPlus/wsproxy.py 2>/dev/null || true
        fi
    fi
    chmod +x /etc/SSHPlus/wsproxy.py 2>/dev/null || true
}

fun_ws_pick_redirect() {
    local porta_ws="$1"
    local _lbl=() _prt=()

    _ws_append() {
        local l="$1" p="$2"
        [[ -z "$p" || ! "$p" =~ ^[0-9]+$ ]] && return
        for ep in "${_prt[@]:-}"; do
            [[ "$ep" == "$p" ]] && return
        done
        _lbl+=("$l")
        _prt+=("$p")
    }

    local ssh_p; ssh_p=$(grep '^Port ' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | xargs || true)
    [[ -z "$ssh_p" ]] && ssh_p="22"
    _ws_append "openssh" "$ssh_p"

    local drp; drp=$(netstat -nplt 2>/dev/null | grep dropbear | awk '{print $4}' | awk -F: '{print $NF}' | head -1 || true)
    _ws_append "dropbear" "$drp"

    local ovp; ovp=$(netstat -nplt 2>/dev/null | grep openvpn | awk '{print $4}' | awk -F: '{print $NF}' | head -1 || true)
    _ws_append "openvpn" "$ovp"

    local n=${#_prt[@]}
    WS_REDIR_PORT=""
    while true; do
        clear
        sshplus_line
        echo -e "${SSHPLUS_CYAN}              CONFIGURAR WEBSOCKET (REDIRECCION)${SCOLOR}"
        sshplus_line
        echo -e "${SSHPLUS_DARK_GREEN}PUERTO WEBSOCKET (escucha):${SCOLOR} \033[1;37m${porta_ws}${SCOLOR}"
        sshplus_line
        echo -e "\033[1;37m        ¿A QUÉ PUERTO DESEA REDIRIGIR EL TRÁFICO?${SCOLOR}"
        sshplus_line
        if [[ "$n" -eq 0 ]]; then
            echo -e "\033[1;37mNo se detectaron listeners locales (sshd, dropbear, openvpn)${SCOLOR}"
            echo -e "\033[1;37mUse [5] para escribir el puerto destino (127.0.0.1).${SCOLOR}"
        else
            for ((i = 0; i < n; i++)); do
                local left="[$((i + 1))] > ${_lbl[i]} "
                local pad=$((40 - ${#left} - ${#_prt[i]}))
                ((pad < 2)) && pad=2
                local d; d=$(printf "%*s" "$pad" "" | tr " " ".")
                echo -e "${SSHPLUS_NUM}[$((i + 1))]${SCOLOR} \033[1;37m> ${_lbl[i]} \033[1;33m${d}\033[1;37m${_prt[i]}${SCOLOR}"
            done
        fi
        sshplus_line
        echo -e "${SSHPLUS_NUM}[0]${SCOLOR} \033[1;37m> CANCELAR${SCOLOR}    ${SSHPLUS_NUM}[5]${SCOLOR} \033[1;37m> INGRESAR MANUALMENTE${SCOLOR}"
        sshplus_line
        echo ""
        echo -ne "${SSHPLUS_CYAN}Opcion:${SCOLOR} "
        read -r ch
        case "$ch" in
            0) return 1 ;;
            5)
                echo -ne "${SSHPLUS_CYAN}PUERTO DESTINO (127.0.0.1):${SCOLOR} \033[1;37m"
                read -r manualp
                [[ -z "$manualp" ]] && continue
                if [[ ! "$manualp" =~ ^[0-9]+$ ]]; then
                    echo -e "\033[1;31mPuerto inválido\033[0m"
                    sleep 2
                    continue
                fi
                WS_REDIR_PORT="$manualp"
                break
                ;;
            *)
                if [[ "$ch" =~ ^[0-9]+$ ]] && [[ "$ch" -ge 1 && "$ch" -le "$n" ]]; then
                    WS_REDIR_PORT="${_prt[$((ch - 1))]}"
                    break
                fi
                echo -e "\033[1;33mOpción inválida\033[0m"
                sleep 1
                ;;
        esac
    done
    [[ ! "$WS_REDIR_PORT" =~ ^[0-9]+$ ]] && return 1
    return 0
}

fun_ws_apply_py_config() {
    local _redir="$1" _http="$2" _msg="$3" _post="$4"
    export WS_PATCH_REDIR="$_redir" WS_PATCH_HTTP="$_http"
    WS_PATCH_MSG_B64=$(printf '%s' "$_msg" | base64 2>/dev/null | tr -d '\n\r')
    WS_PATCH_POST_B64=$(printf '%s' "$_post" | base64 2>/dev/null | tr -d '\n\r')
    export WS_PATCH_MSG_B64 WS_PATCH_POST_B64
    "${SSHPLUS_PY}" <<'PATCHWS' 2>/dev/null || return 1
import base64
import os
import pathlib
import re
import sys

path = pathlib.Path("/etc/SSHPlus/wsproxy.py")
if not path.is_file():
    sys.exit(1)
text = path.read_text(encoding="utf-8", errors="replace")
redir = os.environ.get("WS_PATCH_REDIR", "22")
http = os.environ.get("WS_PATCH_HTTP", "200")
msg = base64.b64decode(os.environ.get("WS_PATCH_MSG_B64", "")).decode("utf-8", errors="replace")
post = base64.b64decode(os.environ.get("WS_PATCH_POST_B64", "")).decode("latin1", errors="replace")

def rep_line(t, name, rhs):
    pat = r"^" + re.escape(name) + r" = .*$"
    if not re.search(pat, t, flags=re.MULTILINE):
        return None
    return re.sub(pat, name + " = " + rhs, t, count=1, flags=re.MULTILINE)

n = repr(f"127.0.0.1:{redir}")
t2 = rep_line(text, "DEFAULT_HOST", n)
if t2 is not None:
    text = t2
for _name, _rhs in (
    ("HTTP_STATUS", repr(http)),
    ("MSG", repr(msg)),
    ("POST_HEADER_RAW", repr(post)),
):
    _t = rep_line(text, _name, _rhs)
    if _t is not None:
        text = _t
path.write_text(text, encoding="utf-8")
PATCHWS
}

fun_ws_config_wizard() {
    local porta_ws="$1" redir="$2"
    local ws_http_code ws_encab ws_mini ws_post_final
    clear
    echo -e "\033[1;33m════════════════════════════════════════════\033[0m"
    echo -e "\033[1;33m   CONFIGURAR WEBSOCKET (RESPUESTA HTTP)\033[0m"
    echo -e "\033[1;33m════════════════════════════════════════════\033[0m"
    echo ""
    echo -e "\033[1;33mEnter aplica configuración predeterminada (200 OK)\033[0m"
    echo -e "\033[1;33m101 Para Switching Protocols (WebSocket)\033[0m"
    echo ""
    echo -ne "\033[1;37mINGRESA UN ESTADO DE RESPUESTA (default 200): \033[0m"
    read -r ws_http_code
    [[ -z "$ws_http_code" ]] && ws_http_code="200"
    if [[ ! "$ws_http_code" =~ ^[0-9]{3}$ ]]; then
        echo -e "\033[1;33mValor no válido; se usa 200\033[0m"
        ws_http_code="200"
        sleep 1
    fi
    echo -e "\033[1;37mRESPUESTA: \033[1;32m${ws_http_code}\033[0m"
    echo ""
    echo -e "\033[1;33mEj:\033[1;37m \\r\\nContent-length: 0\\r\\n\\r\\nHTTP/1.1 200 Connection Established\\r\\n\\r\\n\033[0m"
    echo ""
    echo -ne "\033[1;37mENCABEZADO PERSONALIZADO (Enter = Default): \033[0m"
    read -r ws_encab
    ws_post_final="${ws_encab:-}"
    if [[ -z "$ws_encab" ]]; then
        echo -e "\033[1;37mENCABEZADO: \033[1;32mDEFAULT\033[0m"
    else
        echo -e "\033[1;37mENCABEZADO: \033[1;32m(personalizado)\033[0m"
    fi
    echo ""
    echo -ne "\033[1;37mINGRESA TU MINIBANNER (ej: HTTP CONEXION WS): \033[0m"
    read -r ws_mini
    [[ -z "$ws_mini" ]] && ws_mini="HTTP CONEXION WS"
    fun_ws_apply_py_config "$redir" "$ws_http_code" "$ws_mini" "$ws_post_final" || return 1
    return 0
}

fun_socks() {
    ensure_proxy_scripts
    while true; do
        clear
        sshplus_line
        echo -e "                   ${BLUE}CONFIGURAR PROXY SOCKS${SCOLOR}"
        sshplus_line
        local _socks_ports
        _socks_ports=$(get_proc_ports 'proxy\.py|wsproxy\.py|/python')
        echo -e "${SSHPLUS_DARK_GREEN}PUERTOS:${SCOLOR} \033[1;32m${_socks_ports:-N/A}\033[0m"
        echo -e "\033[1;37m------------------------------------------------------------\033[0m"

        local var_sks1 var_sks2 var_sks3
        (pgrep -f 'proxy.py.*22' >/dev/null 2>&1 || (pgrep -f '/etc/SSHPlus/proxy.py' >/dev/null 2>&1 && ! pgrep -f '1194' >/dev/null 2>&1)) && var_sks1="\033[1;32mo\033[0m" || var_sks1="\033[1;31mx\033[0m"
        pgrep -f '/etc/SSHPlus/wsproxy.py' >/dev/null 2>&1 && var_sks2="\033[1;32mo\033[0m" || var_sks2="\033[1;31mx\033[0m"
        pgrep -f 'proxy.py.*1194' >/dev/null 2>&1 && var_sks3="\033[1;32mo\033[0m" || var_sks3="\033[1;31mx\033[0m"

        echo -e "${SSHPLUS_NUM}[1]${SCOLOR} \033[1;37m> SOCKS SSH\033[0m                 $var_sks1"
        echo -e "${SSHPLUS_NUM}[2]${SCOLOR} \033[1;37m> WEBSOCKET\033[0m                 $var_sks2"
        echo -e "${SSHPLUS_NUM}[3]${SCOLOR} \033[1;37m> SOCKS OPENVPN\033[0m             $var_sks3"
        echo -e "${SSHPLUS_NUM}[4]${SCOLOR} \033[1;37m> ABRIR PUERTO\033[0m"
        echo -e "${SSHPLUS_NUM}[5]${SCOLOR} \033[1;37m> MODIFICAR ESTADO SOCKS SSH\033[0m"
        echo -e "${SSHPLUS_NUM}[6]${SCOLOR} \033[1;37m> MODIFICAR ESTADO DEL WEBSOCKET\033[0m"
        echo -e "${SSHPLUS_NUM}[0]${SCOLOR} \033[1;37m> VOLVER\033[0m"
        sshplus_line
        echo -ne "${SSHPLUS_CYAN}Opcion:${SCOLOR} "
        read -r resposta

        case "$resposta" in
            1)
                if pgrep -f '/etc/SSHPlus/proxy.py' >/dev/null 2>&1 && ! pgrep -f 'proxy.py.*1194' >/dev/null 2>&1; then
                    clear
                    echo -e "\E[44;1;37m          SOCKS SSH — YA ESTÁ ACTIVO           \E[0m\n"
                    echo -e "\033[1;32mEl proxy SOCKS SSH sigue en marcha.\033[0m"
                    echo ""
                    local _cur_pts; _cur_pts=$(ps x 2>/dev/null | grep '[S]SHPlus/proxy.py' | head -1 | awk '{print $NF}')
                    [[ "$_cur_pts" =~ ^[0-9]+$ ]] && echo -e "\033[1;33mPuerto SOCKS SSH: \033[1;32m$_cur_pts\033[0m\n" || echo -e "\033[1;33mSOCKS SSH en ejecución\033[0m\n"
                    echo -e "\033[1;31m[\033[1;36m1\033[1;31m] \033[1;33mDESACTIVAR SOCKS SSH\033[0m"
                    echo -e "\033[1;31m[\033[1;36m0\033[1;31m] \033[1;33mVOLVER (mantener activo)\033[0m\n"
                    echo -ne "\033[1;32m¿QUÉ DESEA HACER ? \033[1;37m"
                    read -r _socks_on_choice
                    if [[ "$_socks_on_choice" == "1" ]]; then
                        clear
                        echo -e "\E[41;1;37m             DESACTIVAR SOCKS SSH             \E[0m\n"
                        fun_socksoff() {
                            for pidproxy in $(screen -ls 2>/dev/null | grep '\.proxy' | awk '{print $1}'); do
                                screen -r -S "$pidproxy" -X quit 2>/dev/null || true
                            done
                            for _k in $(pgrep -f '/etc/SSHPlus/proxy.py' 2>/dev/null); do
                                kill -9 "$_k" 2>/dev/null || true
                            done
                            screen -wipe >/dev/null 2>&1 || true
                        }
                        echo -e "\033[1;32mDESACTIVANDO EL PROXY SOCKS SSH...\033[0m"
                        fun_bar 'fun_socksoff'
                        echo -e "\n\033[1;32mSOCKS SSH DESACTIVADO CON ÉXITO!\033[0m"
                        sleep 2
                    fi
                else
                    clear
                    fun_socks_prepare_activate
                    echo -e "\E[44;1;37m             INICIAR SOCKS SSH             \E[0m\n"
                    echo -ne "\033[1;32m¿QUÉ PUERTO DESEA UTILIZAR ? (ej: 80 o 8080)\033[1;37m: "
                    read -r porta
                    [[ -z "$porta" || ! "$porta" =~ ^[0-9]+$ ]] && porta=80
                    verif_ptrs_socks "$porta" || continue

                    echo -ne "\033[1;32mPUERTO SSH LOCAL DESTINO (default 22)\033[1;37m: "
                    read -r dst_port
                    [[ -z "$dst_port" || ! "$dst_port" =~ ^[0-9]+$ ]] && dst_port=22

                    echo -ne "\033[1;32mINFORME SU MENSAJE DE ESTADO (ej: HTTP CONEXION)\033[1;37m: "
                    read -r msgg
                    [[ -z "$msgg" ]] && msgg="HTTP CONEXION"
                    sed -i "s/MSG = .*/MSG = '$msgg'/g" /etc/SSHPlus/proxy.py 2>/dev/null || true

                    mkdir -p /var/run/screen /run/screen 2>/dev/null || true
                    chmod 777 /var/run/screen /run/screen 2>/dev/null || true
                    fun_inisocks() {
                        screen -wipe >/dev/null 2>&1 || true
                        screen -dmS proxy "${SSHPLUS_PY}" /etc/SSHPlus/proxy.py "$porta" "127.0.0.1:$dst_port" 2>/dev/null || true
                        sleep 1
                        if ! pgrep -f '/etc/SSHPlus/proxy.py' >/dev/null 2>&1; then
                            nohup "${SSHPLUS_PY}" /etc/SSHPlus/proxy.py "$porta" "127.0.0.1:$dst_port" >/dev/null 2>&1 &
                        fi
                    }
                    echo -e "\n\033[1;32mINICIANDO EL PROXY SOCKS EN PUERTO $porta -> SSH $dst_port...\033[0m"
                    fun_bar 'fun_inisocks'
                    ufw allow "$porta"/tcp 2>/dev/null || true
                    echo -e "\n\033[1;32mSOCKS SSH ACTIVADO CON ÉXITO EN PUERTO $porta (MSG: '$msgg')\033[0m"
                    sleep 2
                fi
                ;;
            2)
                if pgrep -f '/etc/SSHPlus/wsproxy.py' >/dev/null 2>&1; then
                    clear
                    echo -e "\E[44;1;37m         WEBSOCKET — YA ESTÁ ACTIVO          \E[0m\n"
                    echo -e "\033[1;32mEl WebSocket sigue en marcha.\033[0m"
                    echo ""
                    local _cur_wsp; _cur_wsp=$(ps x 2>/dev/null | grep '[S]SHPlus/wsproxy.py' | head -1 | awk '{print $NF}')
                    [[ "$_cur_wsp" =~ ^[0-9]+$ ]] && echo -e "\033[1;33mPuerto WebSocket: \033[1;32m$_cur_wsp\033[0m\n" || echo -e "\033[1;33mWebSocket en ejecución\033[0m\n"
                    echo -e "\033[1;31m[\033[1;36m1\033[1;31m] \033[1;33mDESACTIVAR WEBSOCKET\033[0m"
                    echo -e "\033[1;31m[\033[1;36m0\033[1;31m] \033[1;33mVOLVER (mantener activo)\033[0m\n"
                    echo -ne "\033[1;32m¿QUÉ DESEA HACER ? \033[1;37m"
                    read -r _ws_on_choice
                    if [[ "$_ws_on_choice" == "1" ]]; then
                        clear
                        echo -e "\E[41;1;37m             DESACTIVAR WEBSOCKET             \E[0m\n"
                        fun_wssoff() {
                            for pidproxy in $(screen -ls 2>/dev/null | grep '\.ws' | awk '{print $1}'); do
                                screen -r -S "$pidproxy" -X quit 2>/dev/null || true
                            done
                            for _k in $(pgrep -f '/etc/SSHPlus/wsproxy.py' 2>/dev/null); do
                                kill -9 "$_k" 2>/dev/null || true
                            done
                            screen -wipe >/dev/null 2>&1 || true
                        }
                        echo -e "\033[1;32mDESACTIVANDO WEBSOCKET...\033[0m"
                        fun_bar 'fun_wssoff'
                        echo -e "\n\033[1;32mWEBSOCKET DESACTIVADO CON ÉXITO!\033[0m"
                        sleep 2
                    fi
                else
                    clear
                    fun_ws_prepare_activate
                    echo -e "\E[44;1;37m             INICIAR WEBSOCKET             \E[0m\n"
                    echo -ne "\033[1;32m¿QUÉ PUERTO DESEA UTILIZAR ? (ej: 80 o 8080)\033[1;37m: "
                    read -r porta
                    [[ -z "$porta" || ! "$porta" =~ ^[0-9]+$ ]] && porta=80
                    verif_ptrs_socks "$porta" || continue

                    local WS_REDIR_PORT=""
                    if ! fun_ws_pick_redirect "$porta"; then
                        continue
                    fi

                    if fun_ws_config_wizard "$porta" "$WS_REDIR_PORT"; then
                        mkdir -p /var/run/screen /run/screen 2>/dev/null || true
                        chmod 777 /var/run/screen /run/screen 2>/dev/null || true
                        fun_iniws() {
                            screen -wipe >/dev/null 2>&1 || true
                            screen -dmS ws "${SSHPLUS_PY}" /etc/SSHPlus/wsproxy.py "$porta" "127.0.0.1:$WS_REDIR_PORT" 2>/dev/null || true
                            sleep 1
                            if ! pgrep -f '/etc/SSHPlus/wsproxy.py' >/dev/null 2>&1; then
                                nohup "${SSHPLUS_PY}" /etc/SSHPlus/wsproxy.py "$porta" "127.0.0.1:$WS_REDIR_PORT" >/dev/null 2>&1 &
                            fi
                        }
                        echo -e "\n\033[1;32mINICIANDO WEBSOCKET EN PUERTO $porta -> DESTINO $WS_REDIR_PORT...\033[0m"
                        fun_bar 'fun_iniws'
                        ufw allow "$porta"/tcp 2>/dev/null || true
                        echo -e "\n\033[1;32mWEBSOCKET ACTIVADO CON ÉXITO EN PUERTO $porta!\033[0m"
                        sleep 2
                    else
                        echo -e "\n\033[1;31mNo se pudo configurar WebSocket.\033[0m"
                        sleep 2
                    fi
                fi
                ;;
            3)
                if pgrep -f 'proxy.py.*1194' >/dev/null 2>&1; then
                    clear
                    echo -e "\E[41;1;37m             DESACTIVAR SOCKS OPENVPN             \E[0m\n"
                    fun_ovpnoff() {
                        for pidproxy in $(screen -ls 2>/dev/null | grep '\.ovpnproxy' | awk '{print $1}'); do
                            screen -r -S "$pidproxy" -X quit 2>/dev/null || true
                        done
                        for _k in $(pgrep -f 'proxy.py.*1194' 2>/dev/null); do
                            kill -9 "$_k" 2>/dev/null || true
                        done
                        screen -wipe >/dev/null 2>&1 || true
                    }
                    echo -e "\033[1;32mDESACTIVANDO SOCKS OPENVPN...\033[0m"
                    fun_bar 'fun_ovpnoff'
                    echo -e "\n\033[1;32mSOCKS OPENVPN DESACTIVADO CON ÉXITO!\033[0m"
                    sleep 2
                else
                    clear
                    echo -e "\E[44;1;37m             INICIAR SOCKS OPENVPN             \E[0m\n"
                    echo -ne "\033[1;32m¿QUÉ PUERTO DESEA UTILIZAR PARA OPENVPN ? (ej: 8080)\033[1;37m: "
                    read -r porta
                    [[ -z "$porta" || ! "$porta" =~ ^[0-9]+$ ]] && porta=8080
                    verif_ptrs_socks "$porta" || continue

                    echo -ne "\033[1;32mPUERTO OPENVPN LOCAL DESTINO (default 1194)\033[1;37m: "
                    read -r dst_port
                    [[ -z "$dst_port" || ! "$dst_port" =~ ^[0-9]+$ ]] && dst_port=1194

                    echo -ne "\033[1;32mINFORME SU MENSAJE DE ESTADO (ej: HTTP CONEXION OPENVPN)\033[1;37m: "
                    read -r msgg
                    [[ -z "$msgg" ]] && msgg="HTTP CONEXION OPENVPN"

                    mkdir -p /var/run/screen /run/screen 2>/dev/null || true
                    chmod 777 /var/run/screen /run/screen 2>/dev/null || true
                    fun_iniovpn() {
                        screen -wipe >/dev/null 2>&1 || true
                        screen -dmS "ovpnproxy" "${SSHPLUS_PY}" /etc/SSHPlus/proxy.py "$porta" "127.0.0.1:$dst_port" 2>/dev/null || true
                        sleep 1
                        if ! pgrep -f "proxy.py $porta 127.0.0.1:$dst_port" >/dev/null 2>&1; then
                            nohup "${SSHPLUS_PY}" /etc/SSHPlus/proxy.py "$porta" "127.0.0.1:$dst_port" >/dev/null 2>&1 &
                        fi
                    }
                    echo -e "\n\033[1;32mINICIANDO SOCKS OPENVPN EN PUERTO $porta -> OPENVPN $dst_port...\033[0m"
                    fun_bar 'fun_iniovpn'
                    ufw allow "$porta"/tcp 2>/dev/null || true
                    echo -e "\n\033[1;32mSOCKS OPENVPN ACTIVADO CON ÉXITO EN PUERTO $porta!\033[0m"
                    sleep 2
                fi
                ;;
            4)
                clear
                echo -e "\E[44;1;37m               ABRIR PUERTO EXTRA               \E[0m\n"
                echo -e "${SSHPLUS_NUM}[1]${SCOLOR} \033[1;37m> SOCKS SSH (Destino 22)\033[0m"
                echo -e "${SSHPLUS_NUM}[2]${SCOLOR} \033[1;37m> WEBSOCKET (Destino 22)\033[0m"
                echo -e "${SSHPLUS_NUM}[3]${SCOLOR} \033[1;37m> SOCKS OPENVPN (Destino 1194)\033[0m"
                echo -e "${SSHPLUS_NUM}[0]${SCOLOR} \033[1;37m> VOLVER\033[0m\n"
                echo -ne "\033[1;32mTipo de puerto a abrir\033[1;37m: "
                read -r t_opt
                [[ "$t_opt" == "0" || -z "$t_opt" ]] && continue

                echo -ne "\033[1;32m¿QUÉ PUERTO EXTRA DESEA UTILIZAR ? (ej: 8888, 3128)\033[1;37m: "
                read -r porta
                [[ -z "$porta" || ! "$porta" =~ ^[0-9]+$ ]] && {
                    echo -e "\n\033[1;31mPuerto inválido!"
                    sleep 2
                    continue
                }
                verif_ptrs_socks "$porta" || continue

                mkdir -p /var/run/screen /run/screen 2>/dev/null || true
                chmod 777 /var/run/screen /run/screen 2>/dev/null || true

                case "$t_opt" in
                    1)
                        fun_extra_sks() {
                            screen -wipe >/dev/null 2>&1 || true
                            screen -dmS "proxy_$porta" "${SSHPLUS_PY}" /etc/SSHPlus/proxy.py "$porta" "127.0.0.1:22" 2>/dev/null || true
                            sleep 1
                            if ! pgrep -f "/etc/SSHPlus/proxy.py $porta" >/dev/null 2>&1; then
                                nohup "${SSHPLUS_PY}" /etc/SSHPlus/proxy.py "$porta" "127.0.0.1:22" >/dev/null 2>&1 &
                            fi
                        }
                        echo -e "\n\033[1;32mINICIANDO PUERTO EXTRA SOCKS $porta...\033[0m"
                        fun_bar 'fun_extra_sks'
                        ufw allow "$porta"/tcp 2>/dev/null || true
                        echo -e "\n\033[1;32mPUERTO EXTRA SOCKS $porta ACTIVADO!\033[0m"
                        sleep 2
                        ;;
                    2)
                        fun_extra_ws() {
                            screen -wipe >/dev/null 2>&1 || true
                            screen -dmS "ws_$porta" "${SSHPLUS_PY}" /etc/SSHPlus/wsproxy.py "$porta" "127.0.0.1:22" 2>/dev/null || true
                            sleep 1
                            if ! pgrep -f "/etc/SSHPlus/wsproxy.py $porta" >/dev/null 2>&1; then
                                nohup "${SSHPLUS_PY}" /etc/SSHPlus/wsproxy.py "$porta" "127.0.0.1:22" >/dev/null 2>&1 &
                            fi
                        }
                        echo -e "\n\033[1;32mINICIANDO PUERTO EXTRA WEBSOCKET $porta...\033[0m"
                        fun_bar 'fun_extra_ws'
                        ufw allow "$porta"/tcp 2>/dev/null || true
                        echo -e "\n\033[1;32mPUERTO EXTRA WEBSOCKET $porta ACTIVADO!\033[0m"
                        sleep 2
                        ;;
                    3)
                        fun_extra_ovpn() {
                            screen -wipe >/dev/null 2>&1 || true
                            screen -dmS "ovpn_$porta" "${SSHPLUS_PY}" /etc/SSHPlus/proxy.py "$porta" "127.0.0.1:1194" 2>/dev/null || true
                            sleep 1
                            if ! pgrep -f "proxy.py $porta 127.0.0.1:1194" >/dev/null 2>&1; then
                                nohup "${SSHPLUS_PY}" /etc/SSHPlus/proxy.py "$porta" "127.0.0.1:1194" >/dev/null 2>&1 &
                            fi
                        }
                        echo -e "\n\033[1;32mINICIANDO PUERTO EXTRA OPENVPN $porta...\033[0m"
                        fun_bar 'fun_extra_ovpn'
                        ufw allow "$porta"/tcp 2>/dev/null || true
                        echo -e "\n\033[1;32mPUERTO EXTRA OPENVPN $porta ACTIVADO!\033[0m"
                        sleep 2
                        ;;
                esac
                ;;
            5)
                if pgrep -f '/etc/SSHPlus/proxy.py' >/dev/null 2>&1; then
                    clear
                    local msgsocks; msgsocks=$(cat /etc/SSHPlus/proxy.py 2>/dev/null | grep -E "MSG =" | awk -F = '{print $2}' | tr -d " '\"")
                    echo -e "\E[44;1;37m             PROXY SOCKS              \E[0m\n"
                    echo -e "\033[1;33mSTATUS ACTUAL: \033[1;32m${msgsocks:-HTTP CONEXION}\033[0m\n"
                    echo -ne "\033[1;32mINFORME SU NUEVO MENSAJE DE ESTADO\033[1;31m:\033[1;37m "
                    read -r msgg
                    [[ -z "$msgg" ]] && msgg="HTTP CONEXION"

                    echo -e "\n\033[1;31m[\033[1;36m01\033[1;31m]\033[1;33m AZUL"
                    echo -e "\033[1;31m[\033[1;36m02\033[1;31m]\033[1;33m VERDE"
                    echo -e "\033[1;31m[\033[1;36m03\033[1;31m]\033[1;33m ROJO"
                    echo -e "\033[1;31m[\033[1;36m04\033[1;31m]\033[1;33m AMARILLO"
                    echo -e "\033[1;31m[\033[1;36m05\033[1;31m]\033[1;33m ROSA"
                    echo -e "\033[1;31m[\033[1;36m06\033[1;31m]\033[1;33m CYAN"
                    echo -e "\033[1;31m[\033[1;36m07\033[1;31m]\033[1;33m NARANJA"
                    echo -e "\033[1;31m[\033[1;36m08\033[1;31m]\033[1;33m PÚRPURA"
                    echo -e "\033[1;31m[\033[1;36m09\033[1;31m]\033[1;33m NEGRO"
                    echo -e "\033[1;31m[\033[1;36m10\033[1;31m]\033[1;33m SIN COLOR"
                    echo ""
                    echo -ne "\033[1;32m¿QUÉ COLOR DESEA ?\033[1;37m: "
                    read -r sts_cor
                    local cor_sts
                    case "$sts_cor" in
                        1|01) cor_sts="blue" ;;
                        2|02) cor_sts="green" ;;
                        3|03) cor_sts="red" ;;
                        4|04) cor_sts="yellow" ;;
                        5|05) cor_sts="#F535AA" ;;
                        6|06) cor_sts="cyan" ;;
                        7|07) cor_sts="#FF7F00" ;;
                        8|08) cor_sts="#9932CD" ;;
                        9|09) cor_sts="black" ;;
                        10) cor_sts="null" ;;
                        *) cor_sts="green" ;;
                    esac

                    sed -i "s/MSG = .*/MSG = '$msgg'/g" /etc/SSHPlus/proxy.py 2>/dev/null || true
                    sed -i "s/COR = .*/COR = '<font color=\"$cor_sts\">'/g" /etc/SSHPlus/proxy.py 2>/dev/null || true

                    fun_restart_sks() {
                        local _old_p; _old_p=$(get_proc_ports 'proxy\.py')
                        for pidproxy in $(screen -ls 2>/dev/null | grep '\.proxy' | awk '{print $1}'); do
                            screen -r -S "$pidproxy" -X quit 2>/dev/null || true
                        done
                        screen -wipe >/dev/null 2>&1 || true
                        sleep 1
                        for p in $_old_p; do
                            [[ "$p" =~ ^[0-9]+$ ]] && screen -dmS "proxy" "${SSHPLUS_PY}" /etc/SSHPlus/proxy.py "$p" 2>/dev/null || true
                        done
                    }
                    echo -e "\n\033[1;32mAPLICANDO NUEVO ESTADO AL PROXY SOCKS...\033[0m"
                    fun_bar 'fun_restart_sks'
                    echo -e "\n\033[1;32mMENSAJE ACTUALIZADO A: '$msgg' (Color: $cor_sts)\033[0m"
                    sleep 2
                else
                    echo -e "\n\033[1;31mActive SOCKS SSH primero."
                    sleep 2
                fi
                ;;
            6)
                if pgrep -f '/etc/SSHPlus/wsproxy.py' >/dev/null 2>&1; then
                    clear
                    local msgws; msgws=$(cat /etc/SSHPlus/wsproxy.py 2>/dev/null | grep -E "MSG =" | awk -F = '{print $2}' | tr -d " '\"")
                    echo -e "\E[44;1;37m         MODIFICAR ESTADO DEL WEBSOCKET     \E[0m\n"
                    echo -e "\033[1;33mSTATUS ACTUAL: \033[1;32m${msgws:-HTTP CONEXION WS}\033[0m\n"
                    echo -ne "\033[1;32mINFORME SU NUEVO MENSAJE WEBSOCKET\033[1;31m:\033[1;37m "
                    read -r msgg
                    [[ -z "$msgg" ]] && msgg="HTTP CONEXION WS"

                    echo -e "\n\033[1;31m[\033[1;36m01\033[1;31m]\033[1;33m AZUL"
                    echo -e "\033[1;31m[\033[1;36m02\033[1;31m]\033[1;33m VERDE"
                    echo -e "\033[1;31m[\033[1;36m03\033[1;31m]\033[1;33m ROJO"
                    echo -e "\033[1;31m[\033[1;36m04\033[1;31m]\033[1;33m AMARILLO"
                    echo -e "\033[1;31m[\033[1;36m05\033[1;31m]\033[1;33m ROSA"
                    echo -e "\033[1;31m[\033[1;36m06\033[1;31m]\033[1;33m CYAN"
                    echo -e "\033[1;31m[\033[1;36m07\033[1;31m]\033[1;33m NARANJA"
                    echo -e "\033[1;31m[\033[1;36m08\033[1;31m]\033[1;33m PÚRPURA"
                    echo -e "\033[1;31m[\033[1;36m09\033[1;31m]\033[1;33m NEGRO"
                    echo -e "\033[1;31m[\033[1;36m10\033[1;31m]\033[1;33m SIN COLOR"
                    echo ""
                    echo -ne "\033[1;32m¿QUÉ COLOR DESEA ?\033[1;37m: "
                    read -r sts_cor
                    local cor_sts
                    case "$sts_cor" in
                        1|01) cor_sts="blue" ;;
                        2|02) cor_sts="green" ;;
                        3|03) cor_sts="red" ;;
                        4|04) cor_sts="yellow" ;;
                        5|05) cor_sts="#F535AA" ;;
                        6|06) cor_sts="cyan" ;;
                        7|07) cor_sts="#FF7F00" ;;
                        8|08) cor_sts="#9932CD" ;;
                        9|09) cor_sts="black" ;;
                        10) cor_sts="null" ;;
                        *) cor_sts="green" ;;
                    esac

                    sed -i "s/MSG = .*/MSG = '$msgg'/g" /etc/SSHPlus/wsproxy.py 2>/dev/null || true
                    sed -i "s/COR = .*/COR = '<font color=\"$cor_sts\">'/g" /etc/SSHPlus/wsproxy.py 2>/dev/null || true

                    fun_restart_ws() {
                        local _old_p; _old_p=$(get_proc_ports 'wsproxy\.py')
                        for pidproxy in $(screen -ls 2>/dev/null | grep '\.ws' | awk '{print $1}'); do
                            screen -r -S "$pidproxy" -X quit 2>/dev/null || true
                        done
                        screen -wipe >/dev/null 2>&1 || true
                        sleep 1
                        for p in $_old_p; do
                            [[ "$p" =~ ^[0-9]+$ ]] && screen -dmS "ws" "${SSHPLUS_PY}" /etc/SSHPlus/wsproxy.py "$p" 2>/dev/null || true
                        done
                    }
                    echo -e "\n\033[1;32mAPLICANDO NUEVO ESTADO AL WEBSOCKET...\033[0m"
                    fun_bar 'fun_restart_ws'
                    echo -e "\n\033[1;32mMENSAJE ACTUALIZADO A: '$msgg' (Color: $cor_sts)\033[0m"
                    sleep 2
                else
                    echo -e "\n\033[1;31mActive WebSocket primero."
                    sleep 2
                fi
                ;;
            0) return ;;
        esac
    done
}

# 3. SSL TUNNEL (STUNNEL4)
inst_ssl() {
    if netstat -nltp 2>/dev/null | grep -q 'stunnel'; then
        local sslt
        sslt=$(netstat -nplt 2>/dev/null | grep stunnel | awk '{print $4}' | awk -F: '{print $NF}' | xargs || echo "443")
        clear
        echo -e "\E[44;1;37m              GESTIONAR SSL TUNNEL               \E[0m"
        echo -e "\n\033[1;33mPUERTOS EN USO\033[1;37m: \033[1;32m$sslt\033[0m\n"
        echo -e "\033[1;31m[\033[1;36m1\033[1;31m] \033[1;37m> \033[1;33mMODIFICAR PUERTO SSL TUNNEL\033[0m"
        echo -e "\033[1;31m[\033[1;36m2\033[1;31m] \033[1;37m> \033[1;33mELIMINAR / DETENER SSL TUNNEL\033[0m"
        echo -e "\033[1;31m[\033[1;36m0\033[1;31m] \033[1;37m> \033[1;33mVOLVER\033[0m"
        echo ""
        echo -ne "\033[1;32m¿QUÉ DESEA HACER ?\033[1;37m "
        read -r resposta
        if [[ "$resposta" == '1' ]]; then
            echo -ne "\n\033[1;32m¿QUÉ PUERTO DESEA UTILIZAR ?\033[1;37m "
            read -r porta
            [[ -z "$porta" || ! "$porta" =~ ^[0-9]+$ ]] && return
            verif_ptrs "$porta" || return
            sed -i "s/accept = .*/accept = $porta/g" /etc/stunnel/stunnel.conf 2>/dev/null || true
            systemctl restart stunnel4 2>/dev/null || service stunnel4 restart 2>/dev/null
            ufw allow "$porta"/tcp 2>/dev/null || true
            echo -e "\n\033[1;32mPUERTO MODIFICADO CON ÉXITO A $porta!\033[0m"
            sleep 2
        elif [[ "$resposta" == '2' ]]; then
            del_ssl() {
                systemctl stop stunnel4 2>/dev/null || service stunnel4 stop 2>/dev/null || true
                systemctl disable stunnel4 2>/dev/null || true
            }
            fun_bar 'del_ssl'
            echo -e "\n\033[1;32mSSL TUNNEL DETENIDO!\033[0m"
            sleep 2
        fi
    else
        clear
        sshplus_line
        echo -e "${SSHPLUS_CYAN}                  INSTALAR SSL TUNNEL${SCOLOR}"
        sshplus_line
        echo -e "${SSHPLUS_NUM}[1]${SCOLOR} \033[1;37m> INSTALAR SSL TUNNEL POR DEFECTO (443 -> 22)\033[0m"
        echo -e "${SSHPLUS_NUM}[2]${SCOLOR} \033[1;37m> INSTALAR SSL TUNNEL WEBSOCKET (443 -> 80)\033[0m"
        echo -e "${SSHPLUS_NUM}[0]${SCOLOR} \033[1;37m> VOLVER\033[0m"
        sshplus_line
        echo -ne "${SSHPLUS_CYAN}Opcion:${SCOLOR} "
        read -r resp_ssl

        local target_port=22
        [[ "$resp_ssl" == '2' ]] && target_port=80
        [[ "$resp_ssl" == '0' ]] && return

        echo -ne "\n\033[1;32mDEFINA EL PUERTO SSL (default 443)\033[1;37m: "
        read -r porta
        [[ -z "$porta" || ! "$porta" =~ ^[0-9]+$ ]] && porta=443
        verif_ptrs "$porta" || return

        fun_setup_ssl() {
            apt-get update -qq && apt-get install -y -qq stunnel4 >/dev/null 2>&1 || true
            mkdir -p /etc/stunnel
            openssl req -new -newkey rsa:2048 -days 3650 -nodes -x509 \
                -subj "/C=US/ST=CRIS/L=CRIS/O=CRISDEV/CN=ssl.crisdev.online" \
                -keyout /etc/stunnel/stunnel.pem -out /etc/stunnel/stunnel.pem >/dev/null 2>&1
            cat > /etc/stunnel/stunnel.conf << EOF
cert = /etc/stunnel/stunnel.pem
client = no
socket = a:SO_REUSEADDR=1
socket = l:TCP_NODELAY=1
socket = r:TCP_NODELAY=1

[ssh-ssl]
accept = $porta
connect = 127.0.0.1:$target_port
EOF
            sed -i 's/ENABLED=0/ENABLED=1/' /etc/default/stunnel4 2>/dev/null || true
            systemctl restart stunnel4 2>/dev/null || service stunnel4 restart 2>/dev/null
        }
        echo -e "\n\033[1;32mINSTALANDO Y CONFIGURANDO SSL TUNNEL...\033[0m"
        fun_bar 'fun_setup_ssl'
        ufw allow "$porta"/tcp 2>/dev/null || true
        echo -e "\n\033[1;32mSSL TUNNEL ACTIVO EN PUERTO $porta -> $target_port!\033[0m"
        sleep 2
    fi
}

# 4. DROPBEAR
fun_drop() {
    if pgrep -f 'dropbear' >/dev/null 2>&1 || ss -tlnp 2>/dev/null | grep -q 'dropbear' || systemctl is-active --quiet dropbear 2>/dev/null; then
        local dpbr
        dpbr=$(ss -tlnp 2>/dev/null | grep 'dropbear' | awk '{print $4}' | awk -F: '{print $NF}' | sort -n -u | xargs || netstat -nplt 2>/dev/null | grep 'dropbear' | awk '{print $4}' | awk -F: '{print $NF}' | sort -n -u | xargs || echo "110")
        clear
        echo -e "\E[44;1;37m              GESTIONAR DROPBEAR               \E[0m"
        echo -e "\n\033[1;33mPUERTOS EN USO\033[1;37m: \033[1;32m${dpbr:-110}\033[0m\n"
        echo -e "\033[1;31m[\033[1;36m1\033[1;31m] \033[1;37m> \033[1;33mMODIFICAR PUERTOS DROPBEAR\033[0m"
        echo -e "\033[1;31m[\033[1;36m2\033[1;31m] \033[1;37m> \033[1;33mELIMINAR / DETENER DROPBEAR\033[0m"
        echo -e "\033[1;31m[\033[1;36m0\033[1;31m] \033[1;37m> \033[1;33mVOLVER\033[0m"
        echo ""
        echo -ne "\033[1;32m¿QUÉ DESEA HACER ?\033[1;37m "
        read -r resposta
        if [[ "$resposta" == '1' ]]; then
            echo -ne "\n\033[1;32mPUERTOS SEPARADOS POR ESPACIO (ej: 110 442 8888)\033[1;37m: "
            read -r dp_pts
            [[ -z "$dp_pts" ]] && dp_pts="110 442 8888"
            
            local main_port="${dp_pts%% *}"
            local rest_ports=""
            [[ "$dp_pts" == *" "* ]] && rest_ports="${dp_pts#* }"
            local extra_args=""
            for p in $rest_ports; do [[ -n "$p" ]] && extra_args="$extra_args -p $p"; done

            cat > /etc/default/dropbear << EOF
NO_START=0
DROPBEAR_PORT=$main_port
DROPBEAR_EXTRA_ARGS="$extra_args"
DROPBEAR_BANNER=""
DROPBEAR_RECEIVE_WINDOW=65536
EOF
            sed -i 's/NO_START=1/NO_START=0/' /etc/default/dropbear 2>/dev/null || true
            systemctl unmask dropbear >/dev/null 2>&1 || true
            systemctl stop dropbear.socket >/dev/null 2>&1 || true
            systemctl disable dropbear.socket >/dev/null 2>&1 || true
            systemctl daemon-reload >/dev/null 2>&1 || true
            systemctl enable dropbear >/dev/null 2>&1 || true
            systemctl restart dropbear 2>/dev/null || service dropbear restart 2>/dev/null || /etc/init.d/dropbear restart 2>/dev/null || true

            for p in $dp_pts; do
                ufw allow "$p"/tcp >/dev/null 2>&1 || true
                iptables -I INPUT 1 -p tcp --dport "$p" -j ACCEPT >/dev/null 2>&1 || true
            done
            echo -e "\n\033[1;32mPUERTOS DROPBEAR ACTUALIZADOS: $dp_pts\033[0m"
            sleep 2
        elif [[ "$resposta" == '2' ]]; then
            fun_dropunistall() {
                systemctl stop dropbear 2>/dev/null || service dropbear stop 2>/dev/null || true
                systemctl disable dropbear 2>/dev/null || true
            }
            fun_bar 'fun_dropunistall'
            echo -e "\n\033[1;32mDROPBEAR DETENIDO CON ÉXITO!\033[0m"
            sleep 2
        fi
    else
        clear
        echo -e "\E[44;1;37m           INSTALADOR DROPBEAR              \E[0m\n"
        echo -ne "\033[1;32m¿DESEA INSTALAR DROPBEAR ? \033[1;33m[s/n]:\033[1;37m "
        read -r resposta
        if [[ "$resposta" == "s" || "$resposta" == "S" ]]; then
            echo -ne "\n\033[1;32mPUERTOS PARA DROPBEAR (ej: 110 442 8888)\033[1;37m: "
            read -r dp_pts
            [[ -z "$dp_pts" ]] && dp_pts="110 442 8888"
            fun_instdrop() {
                apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq dropbear >/dev/null 2>&1 || true
                local main_port="${dp_pts%% *}"
                local rest_ports=""
                [[ "$dp_pts" == *" "* ]] && rest_ports="${dp_pts#* }"
                local extra_args=""
                for p in $rest_ports; do [[ -n "$p" ]] && extra_args="$extra_args -p $p"; done

                cat > /etc/default/dropbear << EOF
NO_START=0
DROPBEAR_PORT=$main_port
DROPBEAR_EXTRA_ARGS="$extra_args"
DROPBEAR_BANNER=""
DROPBEAR_RECEIVE_WINDOW=65536
EOF
                sed -i 's/NO_START=1/NO_START=0/' /etc/default/dropbear 2>/dev/null || true
                systemctl unmask dropbear >/dev/null 2>&1 || true
                systemctl stop dropbear.socket >/dev/null 2>&1 || true
                systemctl disable dropbear.socket >/dev/null 2>&1 || true
                systemctl daemon-reload >/dev/null 2>&1 || true
                systemctl enable dropbear >/dev/null 2>&1 || true
                systemctl restart dropbear 2>/dev/null || service dropbear restart 2>/dev/null || /etc/init.d/dropbear restart 2>/dev/null || true
            }
            fun_bar 'fun_instdrop'
            for p in $dp_pts; do
                ufw allow "$p"/tcp >/dev/null 2>&1 || true
                iptables -I INPUT 1 -p tcp --dport "$p" -j ACCEPT >/dev/null 2>&1 || true
            done
            echo -e "\n\033[1;32mDROPBEAR INSTALADO CON ÉXITO EN PUERTOS: $dp_pts\033[0m"
            sleep 2
        fi
    fi
}

# 5. SQUID PROXY
fun_squid() {
    if netstat -nltp 2>/dev/null | grep -q 'squid'; then
        local sqdp
        sqdp=$(netstat -nplt 2>/dev/null | grep 'squid' | awk '{print $4}' | awk -F: '{print $NF}' | sort -n -u | xargs || echo "8080")
        clear
        echo -e "\E[44;1;37m          GESTIONAR SQUID PROXY           \E[0m"
        echo -e "\n\033[1;33mPUERTOS EN USO\033[1;37m: \033[1;32m$sqdp\033[0m\n"
        echo -e "\033[1;31m[\033[1;36m1\033[1;31m] \033[1;37m> \033[1;33mELIMINAR / DETENER SQUID\033[0m"
        echo -e "\033[1;31m[\033[1;36m0\033[1;31m] \033[1;37m> \033[1;33mVOLVER\033[0m"
        echo ""
        echo -ne "\033[1;32m¿QUÉ DESEA HACER ?\033[1;37m "
        read -r resp
        if [[ "$resp" == '1' ]]; then
            fun_remsqd() {
                systemctl stop squid 2>/dev/null || true
                systemctl disable squid 2>/dev/null || true
            }
            fun_bar 'fun_remsqd'
            echo -e "\n\033[1;32mSQUID PROXY DETENIDO!\033[0m"
            sleep 2
        fi
    else
        clear
        echo -e "\E[44;1;37m              INSTALADOR SQUID                \E[0m\n"
        echo -ne "\033[1;32m¿PUERTOS PARA SQUID ? (ej: 8080 3128)\033[1;37m: "
        read -r sq_pts
        [[ -z "$sq_pts" ]] && sq_pts="8080 3128"
        fun_instsqd() {
            apt-get update -qq && apt-get install -y -qq squid >/dev/null 2>&1 || true
            local sqd_file="/etc/squid/squid.conf"
            [[ ! -d /etc/squid && -d /etc/squid3 ]] && sqd_file="/etc/squid3/squid.conf"
            cat > "$sqd_file" << 'EOF'
acl localhost src 127.0.0.1/32 ::1
acl to_localhost dst 127.0.0.0/8 0.0.0.0/32 ::1
acl localnet src 0.0.0.0/0
acl SSL_ports port 443
acl Safe_ports port 80
acl Safe_ports port 21
acl Safe_ports port 443
acl Safe_ports port 70
acl Safe_ports port 210
acl Safe_ports port 1025-65535
acl Safe_ports port 280
acl Safe_ports port 488
acl Safe_ports port 591
acl Safe_ports port 777
acl CONNECT method CONNECT
http_access allow all
http_port 8080
http_port 3128
visible_hostname CRISDEV-SQUID
via off
forwarded_for off
pipeline_prefetch off
EOF
            systemctl restart squid 2>/dev/null || true
        }
        echo -e "\n\033[1;32mINSTALANDO SQUID PROXY...\033[0m"
        fun_bar 'fun_instsqd'
        echo -e "\n\033[1;32mSQUID INSTALADO CON ÉXITO!\033[0m"
        sleep 2
    fi
}

# 6. BADVPN UDPGW
install_badvpn_bin() {
    if [[ -x /usr/local/bin/badvpn-udpgw || -x /bin/badvpn-udpgw ]]; then
        [[ ! -x /usr/local/bin/badvpn-udpgw && -x /bin/badvpn-udpgw ]] && ln -sf /bin/badvpn-udpgw /usr/local/bin/badvpn-udpgw
        [[ ! -x /bin/badvpn-udpgw && -x /usr/local/bin/badvpn-udpgw ]] && ln -sf /usr/local/bin/badvpn-udpgw /bin/badvpn-udpgw
        return 0
    fi
    echo -e "${YELLOW}Instalando y compilando badvpn-udpgw oficial...${NC}"
    apt-get update -qq >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq build-essential cmake make gcc g++ screen >/dev/null 2>&1 || true
    
    local workdir="/usr/local/src"
    mkdir -p "$workdir"
    cd "$workdir" || return 1
    rm -rf badvpn-1.999.130 badvpn-build badvpn.tar.gz 2>/dev/null || true
    curl -fL --retry 3 "https://github.com/ambrop72/badvpn/archive/refs/tags/1.999.130.tar.gz" -o badvpn.tar.gz 2>/dev/null || \
    wget -q "https://github.com/ambrop72/badvpn/archive/refs/tags/1.999.130.tar.gz" -O badvpn.tar.gz 2>/dev/null || true
    
    if [[ -f badvpn.tar.gz ]]; then
        tar -xzf badvpn.tar.gz >/dev/null 2>&1 || true
        mkdir -p badvpn-build
        cd badvpn-build || return 1
        cmake ../badvpn-1.999.130 -DCMAKE_INSTALL_PREFIX=/usr/local -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 >/dev/null 2>&1 || true
        make -j"$(nproc 2>/dev/null || echo 1)" >/dev/null 2>&1 || true
        make install >/dev/null 2>&1 || true
    fi
    
    if [[ -x /usr/local/bin/badvpn-udpgw ]]; then
        ln -sf /usr/local/bin/badvpn-udpgw /bin/badvpn-udpgw
        chmod +x /usr/local/bin/badvpn-udpgw /bin/badvpn-udpgw 2>/dev/null || true
        return 0
    fi
    return 1
}

menub() {
    while true; do
        clear
        local bad_p
        bad_p=$(ss -tulpn 2>/dev/null | grep -E 'badvpn-udpgw|udpvpn' | awk '{print $5}' | grep -oE '[0-9]+$' | sort -u | xargs || true)
        [[ -z "$bad_p" && -f /etc/systemd/system/badvpn-udpgw.service ]] && bad_p=$(grep -oE '\-\-listen\-addr[[:space:]]+127\.0\.0\.1:[0-9]+' /etc/systemd/system/badvpn-udpgw.service 2>/dev/null | cut -d: -f2 | xargs || true)
        
        echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
        echo -e "${BLUE}                       BADVPN UDPGW (7300)${NC}"
        echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
        if [[ -n "$bad_p" ]]; then
            echo -e " ${WHITE}Estado: ${GREEN}ACTIVO${WHITE} | Puertos: ${YELLOW}${bad_p}${NC}"
        else
            echo -e " ${WHITE}Estado: ${RED}APAGADO${NC}"
        fi
        echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
        echo -e " ${SSHPLUS_NUM}[1]${NC} ${WHITE}> Activar BadVPN Puerto 7300 (Servicio Continuo)${NC}"
        echo -e " ${SSHPLUS_NUM}[2]${NC} ${WHITE}> Activar BadVPN en Puerto Personalizado (ej: 7200, 7300)${NC}"
        echo -e " ${SSHPLUS_NUM}[3]${NC} ${WHITE}> Activar Multi-BadVPN (7100, 7200, 7300)${NC}"
        echo -e " ${RED}[4]${NC} ${WHITE}> Detener BadVPN${NC}"
        echo -e " ${RED}[0]${NC} ${WHITE}> Volver${NC}"
        echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
        echo -ne "${SSHPLUS_CYAN}Opcion:${NC} "
        read -r b_opt
        case "$b_opt" in
            1)
                echo -e "\n\033[1;32mIniciando BadVPN en puerto 7300...\033[0m"
                fun_bar "install_badvpn_bin"
                cat > /etc/systemd/system/badvpn-udpgw.service << EOF
[Unit]
Description=CRISDEV BadVPN UDPGW Port 7300
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/badvpn-udpgw --listen-addr 127.0.0.1:7300 --max-clients 9000 --max-connections-for-client 8 --client-socket-sndbuf 10000
Restart=always
RestartSec=2
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
                systemctl daemon-reload
                systemctl enable --now badvpn-udpgw.service 2>/dev/null || true
                systemctl restart badvpn-udpgw.service 2>/dev/null || true
                
                screen -dmS udpvpn /usr/local/bin/badvpn-udpgw --listen-addr 127.0.0.1:7300 --max-clients 9000 2>/dev/null || true
                echo -e "\n\033[1;32m[✔] BadVPN UDPGW activo en 127.0.0.1:7300!\033[0m"
                pause
                ;;
            2)
                echo -ne "\n\033[1;32mPuerto UDPGW deseado (ej: 7300 o 7200)\033[1;37m: "
                read -r cus_port
                [[ ! "$cus_port" =~ ^[0-9]+$ ]] && cus_port=7300
                fun_bar "install_badvpn_bin"
                cat > "/etc/systemd/system/badvpn-udpgw.service" << EOF
[Unit]
Description=CRISDEV BadVPN UDPGW Port $cus_port
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/badvpn-udpgw --listen-addr 127.0.0.1:$cus_port --max-clients 9000 --max-connections-for-client 8 --client-socket-sndbuf 10000
Restart=always
RestartSec=2
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
                systemctl daemon-reload
                systemctl enable --now badvpn-udpgw.service 2>/dev/null || true
                systemctl restart badvpn-udpgw.service 2>/dev/null || true
                screen -dmS udpvpn /usr/local/bin/badvpn-udpgw --listen-addr 127.0.0.1:"$cus_port" --max-clients 9000 2>/dev/null || true
                echo -e "\n\033[1;32m[✔] BadVPN UDPGW activo en 127.0.0.1:$cus_port!\033[0m"
                pause
                ;;
            3)
                fun_bar "install_badvpn_bin"
                cat > /etc/systemd/system/badvpn-udpgw.service << EOF
[Unit]
Description=CRISDEV BadVPN UDPGW Port 7300
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/badvpn-udpgw --listen-addr 127.0.0.1:7300 --max-clients 9000 --max-connections-for-client 8 --client-socket-sndbuf 10000
Restart=always
RestartSec=2
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
                cat > /etc/systemd/system/badvpn-udpgw-7200.service << EOF
[Unit]
Description=CRISDEV BadVPN UDPGW Port 7200
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/badvpn-udpgw --listen-addr 127.0.0.1:7200 --max-clients 9000 --max-connections-for-client 8 --client-socket-sndbuf 10000
Restart=always
RestartSec=2
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
                cat > /etc/systemd/system/badvpn-udpgw-7100.service << EOF
[Unit]
Description=CRISDEV BadVPN UDPGW Port 7100
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/badvpn-udpgw --listen-addr 127.0.0.1:7100 --max-clients 9000 --max-connections-for-client 8 --client-socket-sndbuf 10000
Restart=always
RestartSec=2
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
                systemctl daemon-reload
                systemctl enable --now badvpn-udpgw.service badvpn-udpgw-7200.service badvpn-udpgw-7100.service 2>/dev/null || true
                systemctl restart badvpn-udpgw.service badvpn-udpgw-7200.service badvpn-udpgw-7100.service 2>/dev/null || true
                screen -dmS udpvpn /usr/local/bin/badvpn-udpgw --listen-addr 127.0.0.1:7300 --max-clients 9000 2>/dev/null || true
                screen -dmS udpvpn1 /usr/local/bin/badvpn-udpgw --listen-addr 127.0.0.1:7200 --max-clients 9000 2>/dev/null || true
                screen -dmS udpvpn2 /usr/local/bin/badvpn-udpgw --listen-addr 127.0.0.1:7100 --max-clients 9000 2>/dev/null || true
                echo -e "\n\033[1;32m[✔] Multi-BadVPN activo en puertos 7100, 7200 y 7300!\033[0m"
                pause
                ;;
            4)
                systemctl disable --now badvpn-udpgw.service badvpn-udpgw-7200.service badvpn-udpgw-7100.service 2>/dev/null || true
                rm -f /etc/systemd/system/badvpn-udpgw*.service
                systemctl daemon-reload
                for sid in $(screen -ls 2>/dev/null | grep -E 'badvpn|udpvpn' | awk '{print $1}'); do
                    screen -r -S "$sid" -X quit 2>/dev/null || true
                done
                pkill -f badvpn-udpgw 2>/dev/null || true
                echo -e "\n\033[1;32mBadVPN detenido con éxito!\033[0m"
                pause
                ;;
            0) return ;;
        esac
    done
}

# 7. SLOWDNS (DNSTT SERVER)
slow_setup() {
    if [[ -x /bin/slowdnsmanager || -x /usr/local/bin/slowdnsmanager ]]; then
        slowdnsmanager
        return
    fi
    while true; do
        clear
        echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
        echo -e "${BLUE}                 SLOWDNS (DNSTT SERVER PUERTO 53)${NC}"
        echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
        local _sd_sts="${RED}APAGADO${NC}"
        if systemctl is-active --quiet slowdns 2>/dev/null || pgrep -f dnstt-server >/dev/null 2>&1; then
            _sd_sts="${GREEN}ACTIVO (Puerto 53 / 5300)${NC}"
        fi
        echo -e " ${WHITE}Estado: $_sd_sts"
        if [[ -f /etc/slowdns/ns.txt ]]; then
            echo -e " ${WHITE}NameServer (NS): ${YELLOW}$(cat /etc/slowdns/ns.txt 2>/dev/null)${NC}"
        fi
        if [[ -f /etc/slowdns/server.pub ]]; then
            echo -e " ${WHITE}Clave Pública:   ${GREEN}$(cat /etc/slowdns/server.pub 2>/dev/null)${NC}"
        fi
        echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
        echo -e " ${SSHPLUS_NUM}[1]${NC} ${WHITE}> Instalar / Iniciar SlowDNS (Configurar NS y Claves)${NC}"
        echo -e " ${SSHPLUS_NUM}[2]${NC} ${WHITE}> Ver Claves y Datos de Conexión${NC}"
        echo -e " ${SSHPLUS_NUM}[3]${NC} ${WHITE}> Reiniciar Servicio SlowDNS${NC}"
        echo -e " ${RED}[4]${NC} ${WHITE}> Detener Servicio SlowDNS${NC}"
        echo -e " ${RED}[0]${NC} ${WHITE}> Volver${NC}"
        echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
        echo -ne "${SSHPLUS_CYAN}Opcion:${NC} "
        read -r sd_opt
        case "$sd_opt" in
            1)
                clear
                echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
                echo -e "${BLUE}               CONFIGURAR SLOWDNS (DNSTT)${NC}"
                echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
                echo -ne "${GREEN}Ingresa tu Dominio NameServer (NS) (ej: ns1.tudominio.com): ${NC}"
                read -r ns_domain
                [[ -z "$ns_domain" ]] && { echo -e "${RED}Dominio NS requerido.${NC}"; sleep 1; continue; }
                
                echo -ne "${GREEN}Puerto destino SSH/Dropbear [22]: ${NC}"
                read -r target_p
                [[ -z "$target_p" || ! "$target_p" =~ ^[0-9]+$ ]] && target_p=22
                
                mkdir -p /etc/slowdns /usr/local/bin
                echo -e "\n${YELLOW}Descargando dnstt-server oficial...${NC}"
                local arch; arch=$(uname -m)
                local s_arch="amd64"
                [[ "$arch" == "aarch64" || "$arch" == "arm64" ]] && s_arch="arm64"
                [[ "$arch" =~ armv7 ]] && s_arch="arm"
                
                curl -fsSL --retry 3 "https://dnstt.network/dnstt-server-linux-${s_arch}" -o /usr/local/bin/dnstt-server 2>/dev/null || \
                wget -qO /usr/local/bin/dnstt-server "https://dnstt.network/dnstt-server-linux-${s_arch}" 2>/dev/null || \
                wget -qO /usr/local/bin/dnstt-server "https://raw.githubusercontent.com/soportecrisdev/SCRIP_CRISDEV/main/dnstt-server-${s_arch}" 2>/dev/null || true
                
                chmod +x /usr/local/bin/dnstt-server 2>/dev/null || true
                [[ ! -x /usr/local/bin/dnstt-server && -x /bin/dnstt-server ]] && cp /bin/dnstt-server /usr/local/bin/dnstt-server
                
                # Generar claves si no existen
                if [[ ! -f /etc/slowdns/server.key || ! -f /etc/slowdns/server.pub ]]; then
                    /usr/local/bin/dnstt-server -gen-key -privkey-file /etc/slowdns/server.key -pubkey-file /etc/slowdns/server.pub 2>/dev/null || true
                    chmod 600 /etc/slowdns/server.key 2>/dev/null || true
                    chmod 644 /etc/slowdns/server.pub 2>/dev/null || true
                fi
                echo "$ns_domain" > /etc/slowdns/ns.txt
                
                # Liberar puerto 53 de systemd-resolved si está en uso
                if grep -q "DNSStubListener" /etc/systemd/resolved.conf 2>/dev/null; then
                    sed -i 's/^#\?DNSStubListener=.*/DNSStubListener=no/' /etc/systemd/resolved.conf
                    systemctl restart systemd-resolved 2>/dev/null || true
                fi
                
                # Configurar IPTables para redirigir 53 a 5300
                cat > /etc/slowdns/iptables.sh << 'EOF'
#!/bin/bash
ACTION="$1"
clear_rules() {
    iptables -D INPUT -p udp --dport 53 -j ACCEPT 2>/dev/null || true
    iptables -D INPUT -p udp --dport 5300 -j ACCEPT 2>/dev/null || true
    while iptables -t nat -C PREROUTING -p udp --dport 53 -j REDIRECT --to-ports 5300 2>/dev/null; do
        iptables -t nat -D PREROUTING -p udp --dport 53 -j REDIRECT --to-ports 5300 2>/dev/null || break
    done
}
apply_rules() {
    clear_rules
    iptables -I INPUT 1 -p udp --dport 53 -j ACCEPT 2>/dev/null || true
    iptables -I INPUT 1 -p udp --dport 5300 -j ACCEPT 2>/dev/null || true
    iptables -t nat -I PREROUTING 1 -p udp --dport 53 -j REDIRECT --to-ports 5300 2>/dev/null || true
}
case "$ACTION" in
    apply) apply_rules ;;
    clear) clear_rules ;;
esac
exit 0
EOF
                chmod +x /etc/slowdns/iptables.sh
                /etc/slowdns/iptables.sh apply
                
                cat > /etc/slowdns/slowdns.conf << EOF
SLOW_PORT="5300"
SLOW_TRAFFIC="$target_p"
SLOW_DOMAIN="$ns_domain"
SLOW_REDIRECT="53"
EOF
                cat > /etc/systemd/system/slowdns.service << EOF
[Unit]
Description=CRISDEV SlowDNS DNSTT Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=-/etc/slowdns/iptables.sh apply
ExecStart=/usr/local/bin/dnstt-server -udp :5300 -privkey-file /etc/slowdns/server.key $ns_domain 127.0.0.1:$target_p
ExecStopPost=-/etc/slowdns/iptables.sh clear
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
                systemctl daemon-reload
                systemctl unmask slowdns.service 2>/dev/null || true
                systemctl enable --now slowdns.service 2>/dev/null || true
                systemctl restart slowdns.service 2>/dev/null || true
                
                echo -e "\n${SSHPLUS_CYAN}============================================================${SCOLOR}"
                echo -e "${GREEN}⚡ ¡SLOWDNS CONFIGURADO Y ACTIVADO CON ÉXITO! ⚡${NC}"
                echo "────────────────────────────────────────────────────────────"
                echo -e " ${WHITE}• NameServer (NS): ${YELLOW}$ns_domain${NC}"
                echo -e " ${WHITE}• Puerto DNSTT:    ${GREEN}53 (Redirigido a 5300 UDP)${NC}"
                echo -e " ${WHITE}• Destino SSH:     ${CYAN}127.0.0.1:$target_p${NC}"
                [[ -f /etc/slowdns/server.pub ]] && echo -e " ${WHITE}• Clave Pública:   ${GREEN}$(cat /etc/slowdns/server.pub)${NC}"
                echo "────────────────────────────────────────────────────────────"
                pause
                ;;
            2)
                clear
                echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
                echo -e "${BLUE}                 DATOS SLOWDNS ACTUALES${NC}"
                echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
                if [[ -f /etc/slowdns/server.pub ]]; then
                    echo -e " ${WHITE}• NameServer (NS):   ${YELLOW}$(cat /etc/slowdns/ns.txt 2>/dev/null || echo 'No configurado')${NC}"
                    echo -e " ${WHITE}• Clave Pública:     ${GREEN}$(cat /etc/slowdns/server.pub)${NC}"
                    echo -e " ${WHITE}• Ruta Clave Priv:   ${CYAN}/etc/slowdns/server.key${NC}"
                    echo -e " ${WHITE}• Puerto UDP:        ${GREEN}53 / 5300${NC}"
                else
                    echo -e " ${RED}SlowDNS aún no está configurado.${NC}"
                fi
                pause
                ;;
            3)
                systemctl restart slowdns 2>/dev/null || true
                /etc/slowdns/iptables.sh apply 2>/dev/null || true
                echo -e "\n\033[1;32mSlowDNS reiniciado con éxito!\033[0m"
                sleep 1
                ;;
            4)
                systemctl disable --now slowdns 2>/dev/null || true
                /etc/slowdns/iptables.sh clear 2>/dev/null || true
                pkill -f dnstt-server 2>/dev/null || true
                echo -e "\n\033[1;32mSlowDNS detenido!\033[0m"
                sleep 1
                ;;
            0) return ;;
        esac
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# 8. BHTTP & TLS (XHTTP) MANAGER — HTTP CONEXIÓN
# ─────────────────────────────────────────────────────────────────────────────
install_bhttp_binary() {
    if [[ -x /usr/local/bin/bhttp-server || -x /bin/bhttp-server ]]; then
        return 0
    fi
    echo -e "${YELLOW}Descargando Core BHTTP Relay oficial...${NC}"
    local arch; arch=$(uname -m)
    local raw_url="$AMD64_BHTTP"
    [[ "$arch" == "aarch64" || "$arch" == "arm64" ]] && raw_url="$ARM64_BHTTP"
    mkdir -p "$BHTTP_BASE"
    curl -fsSL "$raw_url" -o /usr/local/bin/bhttp-server 2>/dev/null || \
    wget -q "$raw_url" -O /usr/local/bin/bhttp-server 2>/dev/null || \
    curl -fsSL "https://raw.githubusercontent.com/soportecrisdev/SCRIP_CRISDEV/main/bhttp-server" -o /usr/local/bin/bhttp-server 2>/dev/null || true
    chmod 755 /usr/local/bin/bhttp-server 2>/dev/null || true
    ln -sfn /usr/local/bin/bhttp-server /usr/local/bin/bhttp 2>/dev/null || true
    ln -sfn /usr/local/bin/bhttp-server /bin/bhttp-server 2>/dev/null || true
    ln -sfn /usr/local/bin/bhttp-server /bin/bhttp 2>/dev/null || true
    chmod 755 /bin/bhttp-server /bin/bhttp 2>/dev/null || true
    [[ -x /usr/local/bin/bhttp-server || -x /bin/bhttp-server ]]
}

install_xhttp_binary() {
    if [[ -x /usr/local/bin/xhttp-server || -x /bin/xhttp-server ]]; then
        return 0
    fi
    echo -e "${YELLOW}Descargando Core BHTTP-TLS (XHTTP) oficial...${NC}"
    local arch; arch=$(uname -m)
    local raw_url="$AMD64_XHTTP"
    [[ "$arch" == "aarch64" || "$arch" == "arm64" ]] && raw_url="$ARM64_XHTTP"
    mkdir -p "$BHTTP_BASE"
    curl -fsSL "$raw_url" -o /usr/local/bin/xhttp-server 2>/dev/null || \
    wget -q "$raw_url" -O /usr/local/bin/xhttp-server 2>/dev/null || \
    curl -fsSL "https://raw.githubusercontent.com/soportecrisdev/SCRIP_CRISDEV/main/xhttp-server" -o /usr/local/bin/xhttp-server 2>/dev/null || true
    chmod 755 /usr/local/bin/xhttp-server 2>/dev/null || true
    ln -sfn /usr/local/bin/xhttp-server /usr/local/bin/xhttp 2>/dev/null || true
    ln -sfn /usr/local/bin/xhttp-server /bin/xhttp-server 2>/dev/null || true
    ln -sfn /usr/local/bin/xhttp-server /bin/xhttp 2>/dev/null || true
    chmod 755 /bin/xhttp-server /bin/xhttp 2>/dev/null || true
    [[ -x /usr/local/bin/xhttp-server || -x /bin/xhttp-server ]]
}

ensure_bhttp_tls_cert() {
    local domain="${1:-crisdev.online}"
    mkdir -p /etc/bhttp /etc/bhttp/certs
    if [[ ! -f /etc/bhttp/server.crt || ! -f /etc/bhttp/server.key ]]; then
        echo -e "${YELLOW}Generando certificado SSL/TLS (RSA 2048) para BHTTP TLS...${NC}"
        openssl req -x509 -newkey rsa:2048 -days 3650 -nodes \
            -keyout /etc/bhttp/server.key -out /etc/bhttp/server.crt \
            -subj "/CN=${domain}" >/dev/null 2>&1 || true
        chmod 600 /etc/bhttp/server.key 2>/dev/null || true
        chmod 644 /etc/bhttp/server.crt 2>/dev/null || true
    fi
}

ensure_bhttp_connect() {
    if [[ ! -x /usr/local/bin/bhttp-connect ]]; then
        cat > /usr/local/bin/bhttp-connect << 'EOF_BHTTP_CONN_SH'
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
EOF_BHTTP_CONN_SH
        chmod 755 /usr/local/bin/bhttp-connect /bin/bhttp-connect 2>/dev/null || true
    fi
}

menu_bhttp() {
    while true; do
        clear
        local ports_arr
        read -r -a ports_arr <<< "$(scan_bhttp_ports)"
        local total_plain=${#ports_arr[@]}
        local tls_port
        tls_port=$(scan_xhttp_port)

        local plain_status="${RED}DESACTIVADO${NC}"
        [[ $total_plain -gt 0 ]] && plain_status="${GREEN}ACTIVADO (${total_plain} puerto/s)${NC}"

        local tls_status="${RED}DESACTIVADO${NC}"
        [[ -n "$tls_port" ]] && tls_status="${GREEN}ACTIVADO (Puerto: ${tls_port})${NC}"

        echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
        echo -e "             ${BLUE}⚡ GESTIONAR BHTTP (HTTP CONEXIÓN) ⚡${SCOLOR}"
        echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
        echo -e "  ${WHITE}BHTTP PLANO (HTTP/1.1) : ${plain_status}"
        if [[ $total_plain -gt 0 ]]; then
            echo -e "  ${WHITE}PUERTOS PLANOS        : ${YELLOW}${ports_arr[*]}${NC}"
        fi
        echo -e "  ${WHITE}BHTTP TLS (HTTP/2 XHTTP): ${tls_status}"
        echo -e "  ${WHITE}BACKEND SSH DESTINO   : ${GREEN}127.0.0.1:22${NC}"
        echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
        printf "  %b[1]%b > PUERTO PRINCIPAL      %b[6]%b > CERTIFICADOS SSL\n" "$SSHPLUS_NUM" "$SCOLOR" "$SSHPLUS_NUM" "$SCOLOR"
        printf "  %b[2]%b > ACTIVAR / AJUSTAR TLS %b[7]%b > DATOS DE CONEXION\n" "$SSHPLUS_NUM" "$SCOLOR" "$SSHPLUS_NUM" "$SCOLOR"
        printf "  %b[3]%b > ABRIR PUERTO EXTRA    %b[8]%b > TEST DE CONEXION\n" "$SSHPLUS_NUM" "$SCOLOR" "$SSHPLUS_NUM" "$SCOLOR"
        printf "  %b[4]%b > LISTAR PUERTOS        %b[9]%b > DETENER BHTTP\n" "$SSHPLUS_NUM" "$SCOLOR" "$SSHPLUS_NUM" "$SCOLOR"
        printf "  %b[5]%b > ELIMINAR PUERTO       %b[0]%b > VOLVER A PROTOCOLOS\n" "$SSHPLUS_NUM" "$SCOLOR" "$SSHPLUS_NUM" "$SCOLOR"
        echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
        echo -ne "${SSHPLUS_CYAN}Opcion:${SCOLOR} "
        read -r b_opt

        case "$b_opt" in
            1|01)
                clear
                echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
                echo -e "              ${BLUE}CONFIGURAR PUERTO PRINCIPAL BHTTP${SCOLOR}"
                echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
                install_bhttp_binary
                ensure_bhttp_connect
                if [[ ! -x /usr/local/bin/bhttp-server && ! -x /bin/bhttp-server ]]; then
                    echo -e "\033[1;31mError al descargar o instalar bhttp-server.\033[0m"
                    pause
                    continue
                fi

                local def_p="8080"
                if ! ss -tlpn 2>/dev/null | grep -q ':80 '; then
                    def_p="80"
                fi

                echo -ne "${WHITE}Ingresa puerto principal para BHTTP [Enter = ${def_p}]: ${NC}"
                read -r bport
                [[ -z "$bport" || ! "$bport" =~ ^[0-9]+$ ]] && bport="$def_p"

                local cur_b_use
                cur_b_use=$(ss -tlpn 2>/dev/null | grep -E "[:\s]${bport}\s" | awk '{print $NF}' | head -1)
                if [[ -n "$cur_b_use" ]] && ! grep -q -E "bhttp-server|bhttp" <<< "$cur_b_use"; then
                    echo -e "\n\033[1;31m[ERROR] El puerto ${bport} YA ESTÁ EN USO por: ${cur_b_use}\033[0m"
                    echo -e "\033[1;33mPor favor elija otro puerto libre (ej: 8080, 8088, 8888) o detenga el servicio en conflicto.\033[0m"
                    pause
                    continue
                fi

                echo -ne "${WHITE}Puerto SSH destino Backend [Enter = 22]: ${NC}"
                read -r backend_port
                [[ -z "$backend_port" || ! "$backend_port" =~ ^[0-9]+$ ]] && backend_port="22"

                mkdir -p "$BHTTP_BASE"
                cat > "$BHTTP_CONFIG" << EOF
BHTTP_PORT=$bport
BACKEND_PORT=$backend_port
SESSION_TTL=180
MAX_SESSIONS=4096
PROFILE=performance
EOF
                # Limpiar servicios obsoletos con nombres viejos
                systemctl stop wakkodev-bhttp.service 2>/dev/null || true
                rm -f /etc/systemd/system/wakkodev-bhttp.service 2>/dev/null || true

                cat > /etc/systemd/system/bhttp.service << EOF
[Unit]
Description=HTTP Conexion BHTTP Relay Service (Port $bport)
After=network-online.target ssh.service
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=-$BHTTP_CONFIG
ExecStart=/usr/local/bin/bhttp-server --listen 0.0.0.0 --port $bport --backend-host 127.0.0.1 --backend-port $backend_port --session-ttl 180 --max-sessions 4096 --request-timeout 30 --read-wait-ms 2 --sequence-wait 6 --max-requests-per-conn 2048
Restart=always
RestartSec=1
LimitNOFILE=524288

[Install]
WantedBy=multi-user.target
EOF
                systemctl daemon-reload
                systemctl unmask bhttp.service 2>/dev/null || true
                systemctl enable --now bhttp.service 2>/dev/null || true
                systemctl restart bhttp.service 2>/dev/null || true
                iptables -I INPUT -p tcp --dport "$bport" -j ACCEPT 2>/dev/null || true
                ufw allow "$bport"/tcp 2>/dev/null || true

                sleep 1
                if systemctl is-active --quiet bhttp.service 2>/dev/null; then
                    echo -e "\n\033[1;32m⚡ BHTTP Relay activo y funcionando en el puerto TCP ${bport} -> SSH ${backend_port}! ⚡\033[0m"
                else
                    echo -e "\n\033[1;31mError al iniciar BHTTP Relay. Registro del servicio:\033[0m"
                    journalctl -u bhttp.service -n 10 --no-pager 2>/dev/null || systemctl status bhttp.service --no-pager 2>/dev/null || true
                fi
                pause
                ;;
            2|02)
                clear
                echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
                echo -e "             ${BLUE}CONFIGURAR BHTTP TLS (XHTTP / SSL)${SCOLOR}"
                echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
                install_xhttp_binary
                ensure_bhttp_connect

                if [[ ! -x /usr/local/bin/xhttp-server && ! -x /bin/xhttp-server ]]; then
                    echo -e "\033[1;31mError al descargar o instalar xhttp-server.\033[0m"
                    pause
                    continue
                fi

                local def_tls="443"
                if ss -tlpn 2>/dev/null | grep -q ':443 '; then
                    def_tls="8443"
                fi

                echo -ne "${WHITE}Ingresa puerto para BHTTP TLS [Enter = ${def_tls}]: ${NC}"
                read -r new_tls
                [[ -z "$new_tls" || ! "$new_tls" =~ ^[0-9]+$ ]] && new_tls="$def_tls"

                local cur_tls_use
                cur_tls_use=$(ss -tlpn 2>/dev/null | grep -E "[:\s]${new_tls}\s" | awk '{print $NF}' | head -1)
                if [[ -n "$cur_tls_use" ]] && ! grep -q -E "xhttp-server|bhttp-tls" <<< "$cur_tls_use"; then
                    echo -e "\n\033[1;31m[ERROR] El puerto ${new_tls} YA ESTÁ EN USO por: ${cur_tls_use}\033[0m"
                    echo -e "\033[1;33mPor favor elija otro puerto libre (ej: 8443, 7443, 443) o detenga el servicio en conflicto.\033[0m"
                    pause
                    continue
                fi

                echo -ne "${WHITE}Puerto SSH destino Backend [Enter = 22]: ${NC}"
                read -r tls_backend
                [[ -z "$tls_backend" || ! "$tls_backend" =~ ^[0-9]+$ ]] && tls_backend="22"

                echo -ne "${WHITE}Dominio SNI sugerido [Enter = crisdev.online]: ${NC}"
                read -r custom_sni
                [[ -z "$custom_sni" ]] && custom_sni="crisdev.online"

                ensure_bhttp_tls_cert "$custom_sni"
                mkdir -p "$BHTTP_BASE"
                echo "$new_tls" > /etc/bhttp/tls_port
                echo "$custom_sni" > /etc/bhttp/tls_sni

                cat > /etc/systemd/system/bhttp-tls.service << EOF
[Unit]
Description=HTTP Conexion BHTTP TLS (XHTTP) Relay Service (Port $new_tls)
After=network-online.target ssh.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/xhttp-server -listen 0.0.0.0:$new_tls -target 127.0.0.1:$tls_backend -tls-cert /etc/bhttp/server.crt -tls-key /etc/bhttp/server.key -session-timeout 2m
Restart=always
RestartSec=1
LimitNOFILE=524288

[Install]
WantedBy=multi-user.target
EOF
                systemctl daemon-reload
                systemctl unmask bhttp-tls.service 2>/dev/null || true
                systemctl enable --now bhttp-tls.service 2>/dev/null || true
                systemctl restart bhttp-tls.service 2>/dev/null || true
                iptables -I INPUT -p tcp --dport "$new_tls" -j ACCEPT 2>/dev/null || true
                ufw allow "$new_tls"/tcp 2>/dev/null || true

                sleep 1
                if systemctl is-active --quiet bhttp-tls.service 2>/dev/null; then
                    echo -e "\n\033[1;32m⚡ BHTTP TLS (XHTTP) activo y escuchando en el puerto TCP ${new_tls} (SSL/TLS) -> SSH ${tls_backend}! ⚡\033[0m"
                else
                    echo -e "\n\033[1;31mError al iniciar BHTTP TLS. Registro del servicio:\033[0m"
                    journalctl -u bhttp-tls.service -n 10 --no-pager 2>/dev/null || systemctl status bhttp-tls.service --no-pager 2>/dev/null || true
                fi
                pause
                ;;
            3|03)
                clear
                echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
                echo -e "                 ${BLUE}ABRIR PUERTO ADICIONAL BHTTP${SCOLOR}"
                echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
                install_bhttp_binary
                echo -ne "${WHITE}Ingresa puerto adicional (ej: 8081, 8888, 3128, 7080): ${NC}"
                read -r xport
                [[ ! "$xport" =~ ^[0-9]+$ ]] && { echo -e "\n\033[1;31mPuerto inválido!\033[0m"; pause; continue; }

                cat > "/etc/systemd/system/bhttp-port-${xport}.service" << EOF
[Unit]
Description=HTTP Conexion BHTTP Extra Port $xport
After=network-online.target ssh.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/bhttp-server --listen 0.0.0.0 --port $xport --backend-host 127.0.0.1 --backend-port 22 --session-ttl 180 --max-sessions 4096 --request-timeout 30 --read-wait-ms 2 --sequence-wait 6 --max-requests-per-conn 2048
Restart=always
RestartSec=1
LimitNOFILE=524288

[Install]
WantedBy=multi-user.target
EOF
                systemctl daemon-reload
                systemctl unmask "bhttp-port-${xport}.service" 2>/dev/null || true
                systemctl enable --now "bhttp-port-${xport}.service" 2>/dev/null || true
                iptables -I INPUT -p tcp --dport "$xport" -j ACCEPT 2>/dev/null || true
                ufw allow "$xport"/tcp 2>/dev/null || true
                echo -e "\n\033[1;32m⚡ Puerto adicional BHTTP ${xport} activado con éxito! ⚡\033[0m"
                pause
                ;;
            4|04)
                clear
                echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
                echo -e "                 ${BLUE}PUERTOS BHTTP ACTIVOS EN EL SISTEMA${SCOLOR}"
                echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
                echo -e "\n${YELLOW}Servicios y sockets escuchando:${NC}\n"
                ss -tlpn 2>/dev/null | grep -E "bhttp-server|xhttp-server|bilola" || echo -e "  \033[1;31mNo hay servicios BHTTP/TLS escuchando.\033[0m"
                echo -e "\n${SSHPLUS_CYAN}============================================================${SCOLOR}"
                pause
                ;;
            5|05)
                clear
                echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
                echo -e "                ${RED}ELIMINAR PUERTO BHTTP O DETENER TLS${SCOLOR}"
                echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
                local cur_b_ports
                read -r -a cur_b_ports <<< "$(scan_bhttp_ports)"
                local cur_tls; cur_tls=$(scan_xhttp_port)

                echo -e "Puertos BHTTP Planos detectados: \033[1;33m${cur_b_ports[*]:-Ninguno}\033[0m"
                echo -e "Puerto BHTTP TLS detectado    : \033[1;33m${cur_tls:-Ninguno}\033[0m"
                echo ""
                echo -ne "${WHITE}Ingresa el número de puerto a eliminar o detener: ${NC}"
                read -r del_port

                if [[ -n "$cur_tls" && "$del_port" == "$cur_tls" ]]; then
                    systemctl disable --now bhttp-tls.service 2>/dev/null || true
                    rm -f /etc/systemd/system/bhttp-tls.service /etc/bhttp/tls_port
                    systemctl daemon-reload
                    echo -e "\n\033[1;32mBHTTP TLS en puerto ${del_port} detenido y eliminado con éxito!\033[0m"
                elif [[ -f "/etc/systemd/system/bhttp-port-${del_port}.service" ]]; then
                    systemctl disable --now "bhttp-port-${del_port}.service" 2>/dev/null || true
                    rm -f "/etc/systemd/system/bhttp-port-${del_port}.service"
                    systemctl daemon-reload
                    echo -e "\n\033[1;32mPuerto extra BHTTP ${del_port} eliminado con éxito!\033[0m"
                elif [[ -f "/etc/systemd/system/bhttp.service" ]] && grep -q -- "--port $del_port" /etc/systemd/system/bhttp.service; then
                    systemctl disable --now bhttp.service 2>/dev/null || true
                    rm -f /etc/systemd/system/bhttp.service
                    systemctl daemon-reload
                    echo -e "\n\033[1;32mPuerto principal BHTTP ${del_port} eliminado con éxito!\033[0m"
                else
                    echo -e "\n\033[1;31mNo se encontró ningún servicio BHTTP configurado en el puerto ${del_port}.\033[0m"
                fi
                pause
                ;;
            6|06)
                clear
                echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
                echo -e "              ${BLUE}GESTIONAR CERTIFICADO SSL/TLS (BHTTP)${SCOLOR}"
                echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
                mkdir -p /etc/bhttp /etc/bhttp/certs
                if [[ -f /etc/bhttp/server.crt ]]; then
                    local exp_date; exp_date=$(openssl x509 -enddate -noout -in /etc/bhttp/server.crt 2>/dev/null | cut -d= -f2)
                    local subj_cn; subj_cn=$(openssl x509 -subject -noout -in /etc/bhttp/server.crt 2>/dev/null | sed -e 's/subject=//')
                    echo -e "  ${WHITE}Certificado Actual : ${GREEN}Existente${NC}"
                    echo -e "  ${WHITE}Sujeto (CN)        : ${YELLOW}${subj_cn}${NC}"
                    echo -e "  ${WHITE}Vencimiento        : ${GREEN}${exp_date}${NC}"
                else
                    echo -e "  ${WHITE}Certificado Actual : ${RED}No configurado${NC}"
                fi
                echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
                echo -e "  ${SSHPLUS_NUM}[1]${SCOLOR} \033[1;37m> Generar nuevo certificado auto-firmado (RSA 2048 / 10 años)\033[0m"
                echo -e "  ${SSHPLUS_NUM}[2]${SCOLOR} \033[1;37m> Importar certificado de Hysteria / Stunnel\033[0m"
                echo -e "  ${SSHPLUS_NUM}[0]${SCOLOR} \033[1;37m> Volver\033[0m"
                echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
                echo -ne "${SSHPLUS_CYAN}Opcion:${SCOLOR} "
                read -r c_opt
                case "$c_opt" in
                    1)
                        echo -ne "${WHITE}Ingresa Dominio / Host para el certificado [Enter = crisdev.online]: ${NC}"
                        read -r new_dom
                        [[ -z "$new_dom" ]] && new_dom="crisdev.online"
                        openssl req -x509 -newkey rsa:2048 -days 3650 -nodes \
                            -keyout /etc/bhttp/server.key -out /etc/bhttp/server.crt \
                            -subj "/CN=${new_dom}" >/dev/null 2>&1
                        chmod 600 /etc/bhttp/server.key
                        chmod 644 /etc/bhttp/server.crt
                        systemctl restart bhttp-tls.service 2>/dev/null || true
                        echo -e "\n\033[1;32mCertificado SSL generado y aplicado correctamente para CN=${new_dom}!\033[0m"
                        pause
                        ;;
                    2)
                        if [[ -f /etc/hysteria/server.crt && -f /etc/hysteria/server.key ]]; then
                            cp -f /etc/hysteria/server.crt /etc/bhttp/server.crt
                            cp -f /etc/hysteria/server.key /etc/bhttp/server.key
                            chmod 600 /etc/bhttp/server.key
                            chmod 644 /etc/bhttp/server.crt
                            systemctl restart bhttp-tls.service 2>/dev/null || true
                            echo -e "\n\033[1;32mCertificado importado desde Hysteria con éxito!\033[0m"
                        elif [[ -f /etc/stunnel/stunnel.pem ]]; then
                            cp -f /etc/stunnel/stunnel.pem /etc/bhttp/server.crt
                            cp -f /etc/stunnel/stunnel.pem /etc/bhttp/server.key
                            systemctl restart bhttp-tls.service 2>/dev/null || true
                            echo -e "\n\033[1;32mCertificado importado desde Stunnel con éxito!\033[0m"
                        else
                            echo -e "\n\033[1;31mNo se encontraron certificados previos en Hysteria ni Stunnel.\033[0m"
                        fi
                        pause
                        ;;
                esac
                ;;
            7|07)
                clear
                local ip; ip=$(get_public_ip)
                local cur_tls_p; cur_tls_p=$(scan_xhttp_port)
                local cur_sni="crisdev.online"
                [[ -f /etc/bhttp/tls_sni ]] && cur_sni=$(cat /etc/bhttp/tls_sni 2>/dev/null)

                echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
                echo -e "             ${BLUE}DATOS DE CONEXIÓN BHTTP (HTTP CONEXIÓN)${SCOLOR}"
                echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
                printf "  \033[1;32m%-22s\033[0m \033[1;37m%s\033[0m\n" "HOST / IP VPS:" "$ip"
                printf "  \033[1;32m%-22s\033[0m \033[1;37m%s\033[0m\n" "PUERTOS BHTTP PLANOS:" "${ports_arr[*]:-Ninguno}"
                printf "  \033[1;32m%-22s\033[0m \033[1;37m%s\033[0m\n" "PUERTO BHTTP TLS:" "${cur_tls_p:-Desactivado}"
                printf "  \033[1;32m%-22s\033[0m \033[1;37m%s\033[0m\n" "SSH BACKEND DESTINO:" "127.0.0.1:22"
                printf "  \033[1;32m%-22s\033[0m \033[1;37m%s\033[0m\n" "SNI / HOST TLS:" "$cur_sni"
                echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
                echo -e "\033[1;33mMODOS DE USO EN LA APP HTTP CONEXIÓN / GEN:\033[0m"
                echo -e "  • \033[1;37mModo BHTTP Plano:\033[0m IP = ${ip} | Puerto = ${ports_arr[0]:-8080} | Tipo = SSH + BHTTP (BHP1)"
                echo -e "  • \033[1;37mModo BHTTP TLS  :\033[0m IP = ${ip} | Puerto = ${cur_tls_p:-443} | SNI = ${cur_sni} | Tipo = SSH + XHTTP (TLS)"
                echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
                pause
                ;;
            8|08)
                clear
                echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
                echo -e "            ${BLUE}PROBAR CONECTIVIDAD BHTTP & SSH BACKEND${SCOLOR}"
                echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
                if nc -z -w2 127.0.0.1 22 2>/dev/null || (exec 3<>/dev/tcp/127.0.0.1/22) 2>/dev/null; then
                    echo -e "  \033[1;32m[✔] Backend SSH en 127.0.0.1:22 respondiendo OK.\033[0m"
                else
                    echo -e "  \033[1;31m[✘] Backend SSH en 127.0.0.1:22 cerrado o inaccesible.\033[0m"
                fi
                for p in "${ports_arr[@]}"; do
                    if nc -z -w2 127.0.0.1 "$p" 2>/dev/null || (exec 3<>/dev/tcp/127.0.0.1/"$p") 2>/dev/null; then
                        echo -e "  \033[1;32m[✔] Puerto BHTTP Plano $p: Escuchando y respondiendo.\033[0m"
                    else
                        echo -e "  \033[1;31m[✘] Puerto BHTTP Plano $p: No responde.\033[0m"
                    fi
                done
                local t_port; t_port=$(scan_xhttp_port)
                if [[ -n "$t_port" ]]; then
                    if nc -z -w2 127.0.0.1 "$t_port" 2>/dev/null || (exec 3<>/dev/tcp/127.0.0.1/"$t_port") 2>/dev/null; then
                        echo -e "  \033[1;32m[✔] Puerto BHTTP TLS $t_port: Escuchando y respondiendo.\033[0m"
                    else
                        echo -e "  \033[1;31m[✘] Puerto BHTTP TLS $t_port: No responde.\033[0m"
                    fi
                fi
                echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
                pause
                ;;
            9|09)
                clear
                echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
                echo -e "                 ${RED}DETENER TODOS LOS SERVICIOS BHTTP${SCOLOR}"
                echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
                systemctl disable --now bhttp.service 2>/dev/null || true
                systemctl disable --now bhttp-tls.service 2>/dev/null || true
                systemctl disable --now wakkodev-bhttp.service 2>/dev/null || true
                for f in /etc/systemd/system/bhttp-port-*.service /etc/systemd/system/wakkodev-bhttp-port-*.service; do
                    [[ -f "$f" ]] && systemctl disable --now "$(basename "$f")" 2>/dev/null || true
                done
                rm -f /etc/systemd/system/bhttp*.service /etc/systemd/system/wakkodev-bhttp*.service /etc/bhttp/tls_port
                pkill -9 -f 'bhttp-server|xhttp-server|wakkodev' >/dev/null 2>&1 || true
                systemctl daemon-reload
                echo -e "\n\033[1;32mTodos los servicios BHTTP y BHTTP TLS han sido detenidos.\033[0m"
                pause
                ;;
            0|00) return ;;
            *) echo -e "\n\033[1;31mOpción inválida!\033[0m"; sleep 1 ;;
        esac
    done
}

# 9. UDP CRIS (HYSTERIA V1.3.5 OFICIAL - NOXURASSH / SSH-PLUS ENGINE)
HYST_BIN="/usr/local/bin/hysteria1"
HYST_DIR="/etc/hysteria"
HYST_CONF="${HYST_DIR}/config.json"
HYST_ENV="${HYST_DIR}/sshplus.env"
HYST_CERT="${HYST_DIR}/server.crt"
HYST_KEY="${HYST_DIR}/server.key"
HYST_IPTABLES="${HYST_DIR}/iptables.sh"
HYST_SERVICE="/etc/systemd/system/hysteria-server.service"

hyst_cleanup_old_menu_bins() {
    for old in /bin/hysteria /usr/bin/hysteria; do
        [[ -f "$old" ]] || continue
        if grep -q 'Hysteria .* manager' "$old" 2>/dev/null; then
            rm -f "$old" 2>/dev/null || true
        fi
    done
}

hyst_rand() {
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${1:-16}"
}

hyst_load_env() {
    [[ -f "$HYST_ENV" ]] && . "$HYST_ENV"
}

hyst_client_ranges() {
    local value="${1// /}"
    echo "${value//:/-}"
}

hyst_migrate_old_port() {
    hyst_load_env
    if [[ -f "$HYST_CONF" ]]; then
        hyst_install_binary >/dev/null 2>&1 && hyst_write_service
    fi
    if [[ "${HYST_PORT:-}" = "1" && -n "${HYST_RULES:-}" ]]; then
        hyst_write_config "36712" "$HYST_RULES" "${HYST_OBFS:-$(hyst_rand 18)}" || return 0
        hyst_write_service
        systemctl restart hysteria-server >/dev/null 2>&1
    elif grep -q 'type: password' "$HYST_CONF" 2>/dev/null || grep -q '^HYST_USER=' "$HYST_ENV" 2>/dev/null; then
        hyst_write_config "${HYST_PORT:-36712}" "${HYST_RULES:-1:65535}" "${HYST_OBFS:-$(hyst_rand 18)}" || return 0
        hyst_write_service
        systemctl restart hysteria-server >/dev/null 2>&1
    fi
}

hyst_status_mark() {
    systemctl is-active --quiet hysteria-server 2>/dev/null && echo -e "${GREEN}o${NC}" || echo -e "${RED}x${NC}"
}

hyst_status_text() {
    systemctl is-active --quiet hysteria-server 2>/dev/null && echo -e "${GREEN}o${NC}" || echo -e "${RED}x${NC}"
}

hyst_valid_port() {
    local value="$1"
    [[ "$value" =~ ^[0-9]+$ ]] || return 1
    (( value >= 1 && value <= 65535 ))
}

hyst_valid_rule_ranges() {
    local value="${1// /}" item first last
    [[ -n "$value" ]] || return 1
    IFS=',' read -ra _items <<<"$value"
    for item in "${_items[@]}"; do
        [[ "$item" =~ ^[0-9]+(:[0-9]+)?$ ]] || return 1
        first="${item%%:*}"
        last="${item##*:}"
        [[ "$item" != *:* ]] && last="$first"
        (( first >= 1 && first <= 65535 && last >= 1 && last <= 65535 && first <= last )) || return 1
    done
}

hyst_json_quote() {
    printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"
}

hyst_shell_quote() {
    printf '%q' "$1"
}

hyst_build_auth_list() {
    local db="/root/usuarios.db" pass_dir="/etc/SSHPlus/senha" user pass found=0 sep=""
    if [[ -f "$db" ]]; then
        while read -r user _; do
            [[ -z "$user" ]] && continue
            [[ -f "$pass_dir/$user" ]] || continue
            pass="$(cat "$pass_dir/$user" 2>/dev/null)"
            [[ -z "$pass" ]] && continue
            printf '%s      %s\n' "$sep" "$(hyst_json_quote "${user}:${pass}")"
            sep=","
            found=1
        done <"$db"
    fi
    if [[ "$found" != "1" && -f "$USER_DATABASE" ]]; then
        while IFS=: read -r user limit exp pass; do
            [[ -z "$user" || -z "$pass" ]] && continue
            printf '%s      %s\n' "$sep" "$(hyst_json_quote "${user}:${pass}")"
            sep=","
            found=1
        done <"$USER_DATABASE"
    fi
    if [[ "$found" != "1" ]]; then
        return 1
    fi
    return 0
}

hyst_install_binary() {
    mkdir -p /etc/hysteria /usr/local/bin
    hyst_cleanup_old_menu_bins
    if [[ -s "$HYST_BIN" && -x "$HYST_BIN" ]]; then
        ln -sfn "$HYST_BIN" /usr/local/bin/hysteria 2>/dev/null || true
        chmod 755 /usr/local/bin/hysteria 2>/dev/null || true
        return 0
    fi
    if [[ -s "/bin/hysteria1" && -x "/bin/hysteria1" ]]; then
        cp -f /bin/hysteria1 "$HYST_BIN" 2>/dev/null || true
        ln -sfn "$HYST_BIN" /usr/local/bin/hysteria 2>/dev/null || true
        chmod 755 "$HYST_BIN" /usr/local/bin/hysteria 2>/dev/null || true
        return 0
    fi
    echo -e "${YELLOW}Descargando Hysteria v1.3.5 Oficial...${NC}"
    local asset url
    case "$(uname -m)" in
        x86_64|amd64) asset="hysteria-linux-amd64" ;;
        aarch64|arm64|armv8) asset="hysteria-linux-arm64" ;;
        *) asset="hysteria-linux-amd64" ;;
    esac
    url="https://github.com/apernet/hysteria/releases/download/v1.3.5/${asset}"
    curl -fL --retry 3 --connect-timeout 10 "$url" -o "$HYST_BIN" 2>/dev/null || \
    wget -t 3 -T 10 -qO "$HYST_BIN" "$url" 2>/dev/null || true
    
    if [[ ! -s "$HYST_BIN" ]]; then
        local url2="https://raw.githubusercontent.com/soportecrisdev/SCRIP_CRISDEV/main/hysteria1-amd64"
        [[ "$asset" == *"arm64"* ]] && url2="https://raw.githubusercontent.com/soportecrisdev/SCRIP_CRISDEV/main/hysteria1-arm64"
        curl -fL --retry 3 --connect-timeout 10 "$url2" -o "$HYST_BIN" 2>/dev/null || \
        wget -t 3 -T 10 -qO "$HYST_BIN" "$url2" 2>/dev/null || true
    fi
    
    chmod 755 "$HYST_BIN" 2>/dev/null || true
    ln -sfn "$HYST_BIN" /usr/local/bin/hysteria 2>/dev/null || true
    chmod 755 /usr/local/bin/hysteria 2>/dev/null || true
    [[ -s "$HYST_BIN" && -x "$HYST_BIN" ]]
}

hyst_write_service() {
    sysctl -w net.core.rmem_max=67108864 >/dev/null 2>&1 || true
    sysctl -w net.core.wmem_max=67108864 >/dev/null 2>&1 || true
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true

    cat >"$HYST_SERVICE" <<EOF
[Unit]
Description=SSHPlus Hysteria v1.3.5 Server (UDP CRIS)
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Environment=HYSTERIA_LOG_LEVEL=debug
ExecStartPre=-${HYST_IPTABLES} apply
ExecStart=/usr/local/bin/hysteria1 -c ${HYST_CONF} server
ExecStopPost=-${HYST_IPTABLES} clear
WorkingDirectory=${HYST_DIR}
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable hysteria-server >/dev/null 2>&1
}

hyst_write_config() {
    local port="$1" rules="$2" obfs="$3" auth_block
    auth_block="$(hyst_build_auth_list)"
    mkdir -p "$HYST_DIR"
    if [[ ! -f "$HYST_CERT" || ! -f "$HYST_KEY" ]]; then
        openssl req -x509 -newkey rsa:2048 -days 3650 -nodes \
            -keyout "$HYST_KEY" -out "$HYST_CERT" -subj "/CN=crisdev.online" >/dev/null 2>&1
    fi
    cat >"$HYST_CONF" <<EOF
{
  "listen": ":${port}",
  "cert": "${HYST_CERT}",
  "key": "${HYST_KEY}",
  "obfs": "$obfs",
  "auth": {
    "mode": "passwords",
    "config": [
${auth_block}
    ]
  }
}
EOF
    cat >"$HYST_ENV" <<EOF
HYST_PORT="$port"
HYST_RULES="$rules"
HYST_OBFS="$obfs"
EOF
}

hyst_show_summary() {
    hyst_load_env
    local redirect
    redirect="$(hyst_client_ranges "${HYST_RULES:-N/A}")"
    echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
    echo -e "${BLUE}                       UDP-HYSTERIA v1${NC}"
    echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
    echo -e "${WHITE}VERSION:${NC} ${YELLOW}HYSTERIA v1.3.5${NC}"
    echo -e "${WHITE}PORT:${NC} ${GREEN}${HYST_PORT:-36712}${NC}"
    echo -e "${WHITE}REDIRECT:${NC} ${YELLOW}${redirect} > ${HYST_PORT:-36712}${NC}"
    echo -e "${WHITE}OBFS:${NC} ${CYAN}${HYST_OBFS:-crisdev}${NC}"
    echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
}

hyst_configure() {
    clear
    echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
    echo -e "                ${BLUE}RECONFIGURAR UDP-HYSTERIA v1${NC}"
    echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
    local port rules obfs
    echo -ne "${GREEN}Puerto principal Hysteria v1 [36712]: ${NC}"
    read -r port
    [[ -z "$port" ]] && port="36712"
    echo -ne "${GREEN}Habilitar Port Hopping (Rangos UDP)? [s/N]: ${NC}"
    read -r hop_resp
    if [[ "$hop_resp" =~ ^[sS]$ ]]; then
        echo -ne "${GREEN}Rangos iptables UDP [20000:50000]: ${NC}"
        read -r rules
        [[ -z "$rules" ]] && rules="20000:50000"
    else
        rules="none"
    fi
    echo -ne "${GREEN}OBFS Hysteria v1 [crisdev]: ${NC}"
    read -r obfs
    [[ -z "$obfs" ]] && obfs="crisdev"
    exec_install_udp_cris "$port" "$rules" "$obfs" "crisdev" "crisdev"
}

hyst_change_obfs() {
    hyst_load_env
    echo -ne "${GREEN}Nuevo OBFS Hysteria v1: ${NC}"
    read -r new_obfs
    [[ -z "$new_obfs" ]] && return
    exec_install_udp_cris "${HYST_PORT:-36712}" "${HYST_RULES:-20000:50000}" "$new_obfs" "crisdev" "crisdev"
}

hyst_change_range() {
    hyst_load_env
    echo -ne "${GREEN}Nuevos Rangos Port Hopping [20000:50000]: ${NC}"
    read -r new_r
    [[ -z "$new_r" ]] && new_r="20000:50000"
    exec_install_udp_cris "${HYST_PORT:-36712}" "$new_r" "${HYST_OBFS:-crisdev}" "crisdev" "crisdev"
}

hyst_toggle_service() {
    if systemctl is-active --quiet hysteria-server 2>/dev/null; then
        systemctl disable --now hysteria-server >/dev/null 2>&1 || true
        /etc/hysteria/iptables.sh clear 2>/dev/null || true
        pkill -f hysteria 2>/dev/null || true
        echo -e "${YELLOW}Hysteria v1 detenido.${NC}"
    else
        /etc/hysteria/iptables.sh apply 2>/dev/null || true
        systemctl unmask hysteria-server 2>/dev/null || true
        systemctl enable --now hysteria-server >/dev/null 2>&1 || true
        echo -e "${GREEN}Hysteria v1 iniciado.${NC}"
    fi
    sleep 2
}

hyst_service_status() {
    clear
    echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
    echo -e "                ${BLUE}ESTADO HYSTERIA v1${NC}"
    echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
    systemctl status hysteria-server --no-pager -l 2>/dev/null || echo "Inactivo"
    pause
}

hyst_show_logs() {
    clear
    echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
    echo -e "                 ${BLUE}LOGS HYSTERIA v1${NC}"
    echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
    journalctl -u hysteria-server -n 50 --no-pager 2>/dev/null || true
    pause
}

hyst_follow_logs() {
    clear
    echo -e "${YELLOW}Presiona Ctrl+C para salir del log en tiempo real.${NC}"
    journalctl -u hysteria-server -f --no-pager 2>/dev/null || true
}

hyst_reinstall() {
    exec_install_udp_cris "36712" "20000:50000" "crisdev" "crisdev" "crisdev"
}

hyst_uninstall() {
    systemctl disable --now hysteria-server.service 2>/dev/null || true
    systemctl disable --now hysteria-server 2>/dev/null || true
    /etc/hysteria/iptables.sh clear 2>/dev/null || true
    pkill -f hysteria 2>/dev/null || true
    rm -rf /etc/hysteria /usr/local/bin/hysteria1 /etc/systemd/system/hysteria-server.service
    systemctl daemon-reload
    echo -e "\n${GREEN}Hysteria v1 desinstalado por completo.${NC}"
    sleep 2
}

menu_udp_cris() {
    while true; do
        clear
        local ip; ip=$(get_public_ip)
        local _u_sts="${RED}APAGADO${NC}"
        local _u_pt="36712"
        local _u_rules="20000:50000"
        local _u_obfs="crisdev"
        local _u_usr="crisdev"
        local _u_pass="crisdev"

        if [[ -f /etc/hysteria/sshplus.env ]]; then
            _u_pt="$(grep '^HYST_PORT=' /etc/hysteria/sshplus.env 2>/dev/null | cut -d= -f2 | tr -d '"')"
            _u_rules="$(grep '^HYST_RULES=' /etc/hysteria/sshplus.env 2>/dev/null | cut -d= -f2 | tr -d '"')"
            _u_obfs="$(grep '^HYST_OBFS=' /etc/hysteria/sshplus.env 2>/dev/null | cut -d= -f2 | tr -d '"')"
            _u_usr="$(grep '^HYST_USER=' /etc/hysteria/sshplus.env 2>/dev/null | cut -d= -f2 | tr -d '"')"
            _u_pass="$(grep '^HYST_PASS=' /etc/hysteria/sshplus.env 2>/dev/null | cut -d= -f2 | tr -d '"')"
        fi
        [[ -z "$_u_pt" ]] && _u_pt="36712"
        [[ -z "$_u_rules" ]] && _u_rules="20000:50000"
        [[ -z "$_u_obfs" ]] && _u_obfs="crisdev"
        [[ -z "$_u_usr" ]] && _u_usr="crisdev"
        [[ -z "$_u_pass" ]] && _u_pass="crisdev"

        if systemctl is-active --quiet hysteria-server 2>/dev/null || pgrep -f 'hysteria' >/dev/null 2>&1 || ss -ulpn 2>/dev/null | grep -qE 'hysteria|:36712 '; then
            _u_sts="${GREEN}ACTIVO${NC}"
        fi

        echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
        echo -e "                 ${BLUE}INSTALADOR Y GESTOR UDP CRIS${SCOLOR}"
        echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
        echo -e " ${WHITE}Estado: $_u_sts ${WHITE}| Puerto: ${YELLOW}$_u_pt${WHITE} | Rangos: ${YELLOW}$_u_rules${WHITE} | OBFS: ${YELLOW}$_u_obfs${NC}"
        echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
        echo -e "  ${SSHPLUS_NUM}[1]${SCOLOR} \033[1;37m> ACTIVAR MODO HTTP CONEXION (1-Click Automático)\033[0m"
        echo -e "  ${SSHPLUS_NUM}[2]${SCOLOR} \033[1;37m> ACTIVAR MODO MANUAL / PERSONALIZADO (Enter = Default)\033[0m"
        echo -e "  ${SSHPLUS_NUM}[3]${SCOLOR} \033[1;37m> VER DATOS DE CONEXION Y ESTADO\033[0m"
        echo -e "  ${SSHPLUS_NUM}[4]${SCOLOR} \033[1;37m> REINICIAR SERVICIO UDP CRIS\033[0m"
        echo -e "  ${RED}[5]${SCOLOR}  \033[1;31m> DETENER SERVICIO UDP CRIS\033[0m"
        echo -e "  ${SSHPLUS_NUM}[0]${SCOLOR} \033[1;37m> VOLVER\033[0m"
        echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
        echo -ne "${SSHPLUS_CYAN}Opcion:${SCOLOR} "
        read -r uc_opt
        case "$uc_opt" in
            1)
                clear
                echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
                echo -e "${BLUE}        ACTIVANDO MODO HTTP CONEXION (1-CLICK AUTOMATICO)${NC}"
                echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
                echo -e "${YELLOW}Configurando valores oficiales de HTTP Conexión...${NC}"
                exec_install_udp_cris "36712" "20000:50000" "crisdev" "crisdev" "crisdev"
                ;;
            2)
                clear
                echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
                echo -e "${BLUE}        ACTIVAR MODO MANUAL / PERSONALIZADO UDP CRIS${NC}"
                echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
                local m_port m_rules m_obfs m_user m_pass
                echo -ne "${GREEN}Puerto UDP [Enter = 36712]: ${NC}"
                read -r m_port
                [[ -z "$m_port" ]] && m_port="36712"

                echo -ne "${GREEN}Rangos Port Hopping [Enter = 20000:50000] (o 'none'): ${NC}"
                read -r m_rules
                [[ -z "$m_rules" ]] && m_rules="20000:50000"

                echo -ne "${GREEN}OBFS UDP CRIS [Enter = crisdev]: ${NC}"
                read -r m_obfs
                [[ -z "$m_obfs" ]] && m_obfs="crisdev"

                echo -ne "${GREEN}Usuario UDP CRIS [Enter = crisdev]: ${NC}"
                read -r m_user
                [[ -z "$m_user" ]] && m_user="crisdev"

                echo -ne "${GREEN}Contraseña UDP CRIS [Enter = crisdev]: ${NC}"
                read -r m_pass
                [[ -z "$m_pass" ]] && m_pass="crisdev"

                exec_install_udp_cris "$m_port" "$m_rules" "$m_obfs" "$m_user" "$m_pass"
                ;;
            3)
                clear
                echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
                echo -e "${BLUE}                 DATOS UDP CRIS ACTUALES${NC}"
                echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
                echo -e " ${WHITE}• Servidor IP:     ${GREEN}$ip${NC}"
                echo -e " ${WHITE}• Puerto UDP:      ${GREEN}$_u_pt${NC}"
                echo -e " ${WHITE}• Rangos Hopping:  ${YELLOW}$_u_rules${NC}"
                echo -e " ${WHITE}• OBFS:            ${CYAN}$_u_obfs${NC}"
                echo -e " ${WHITE}• Usuario:         ${YELLOW}$_u_usr${NC}"
                echo -e " ${WHITE}• Contraseña:      ${YELLOW}$_u_pass${NC}"
                echo "────────────────────────────────────────────────────────────"
                echo -e "${YELLOW}Estado de Systemd:${NC}"
                systemctl status hysteria-server --no-pager -l 2>/dev/null | tail -n 12 || echo "Inactivo"
                echo "────────────────────────────────────────────────────────────"
                echo -e "${YELLOW}Socket UDP escuchando:${NC}"
                ss -ulpn 2>/dev/null | grep -E 'hysteria|36712' || echo "Sin socket activo"
                pause
                ;;
            4)
                systemctl restart hysteria-server.service 2>/dev/null || systemctl restart hysteria-server 2>/dev/null || true
                /etc/hysteria/iptables.sh apply 2>/dev/null || true
                echo -e "\n\033[1;32mServicio UDP CRIS reiniciado con éxito!\033[0m"
                sleep 1
                ;;
            5)
                systemctl disable --now hysteria-server.service 2>/dev/null || systemctl disable --now hysteria-server 2>/dev/null || true
                /etc/hysteria/iptables.sh clear 2>/dev/null || true
                pkill -f hysteria 2>/dev/null || true
                echo -e "\n\033[1;32mServicio UDP CRIS detenido!\033[0m"
                sleep 1
                ;;
            0|00) break ;;
            *) echo -e "\n\033[1;31mOpción inválida!\033[0m"; sleep 1 ;;
        esac
    done
}

instalar_udp_cris() {
    menu_udp_cris "$@"
}

exec_install_udp_cris() {
    local u_port="$1"
    local u_rules="$2"
    local u_obfs="$3"
    local u_user="$4"
    local u_pass="$5"

    echo -e "\n${YELLOW}Instalando y activando UDP CRIS (Core Hysteria v1)...${NC}"
    fun_bar "hyst_install_binary"

    mkdir -p /etc/hysteria /etc/SSHPlus/senha /root
    
    # Registrar credencial si no existe
    echo "$u_pass" > "/etc/SSHPlus/senha/$u_user" 2>/dev/null || true
    if ! grep -qw "$u_user" /root/usuarios.db 2>/dev/null; then
        echo "$u_user 999" >> /root/usuarios.db
    fi

    if [[ ! -f "$HYST_CERT" || ! -f "$HYST_KEY" ]]; then
        openssl req -x509 -newkey rsa:2048 -days 3650 -nodes \
            -keyout "$HYST_KEY" -out "$HYST_CERT" -subj "/CN=crisdev.online" >/dev/null 2>&1 || true
    fi
    chmod 600 "$HYST_KEY" 2>/dev/null || true
    chmod 644 "$HYST_CERT" 2>/dev/null || true

    local auth_block
    auth_block="$(hyst_build_auth_list)"
    if [[ "$auth_block" != *"${u_user}:${u_pass}"* ]]; then
        auth_block="$(printf '      "%s:%s",\n%s' "$u_user" "$u_pass" "$auth_block")"
    fi

    cat >"$HYST_CONF" <<EOF
{
  "listen": ":${u_port}",
  "cert": "${HYST_CERT}",
  "key": "${HYST_KEY}",
  "obfs": "$u_obfs",
  "auth": {
    "mode": "passwords",
    "config": [
${auth_block}
    ]
  }
}
EOF
    cat >"$HYST_ENV" <<EOF
HYST_PORT="$u_port"
HYST_RULES="$u_rules"
HYST_OBFS="$u_obfs"
HYST_USER="$u_user"
HYST_PASS="$u_pass"
EOF
    cat >"$HYST_IPTABLES" <<EOF
#!/bin/bash
ACTION="\$1"
ENV_FILE="/etc/hysteria/sshplus.env"
CHAIN="SSHPLUS_HYSTERIA"
[[ -f "\$ENV_FILE" ]] && . "\$ENV_FILE"
clear_rules() {
    while iptables -t nat -C PREROUTING -p udp -j "\$CHAIN" >/dev/null 2>&1; do
        iptables -t nat -D PREROUTING -p udp -j "\$CHAIN" >/dev/null 2>&1 || break
    done
    iptables -t nat -F "\$CHAIN" >/dev/null 2>&1 || true
    iptables -t nat -X "\$CHAIN" >/dev/null 2>&1 || true
}
apply_rules() {
    clear_rules
    iptables -I INPUT 1 -p udp --dport "${u_port}" -j ACCEPT >/dev/null 2>&1 || true
    [[ -z "\$HYST_RULES" || "\$HYST_RULES" = "none" || "\$HYST_RULES" = "0" ]] && return 0
    iptables -t nat -N "\$CHAIN" >/dev/null 2>&1 || true
    iptables -t nat -I PREROUTING 1 -p udp -j "\$CHAIN" >/dev/null 2>&1 || true
    local clean="\${HYST_RULES// /}" item
    IFS=',' read -ra items <<<"\$clean"
    for item in "\${items[@]}"; do
        [[ -z "\$item" || "\$item" = "53" || "\$item" = "5300" ]] && continue
        iptables -t nat -A "\$CHAIN" -p udp --dport "\$item" -j REDIRECT --to-ports "${u_port}" >/dev/null 2>&1 || true
    done
}
case "\$ACTION" in
    apply) apply_rules ;;
    clear) clear_rules ;;
esac
exit 0
EOF
    chmod +x "$HYST_IPTABLES" 2>/dev/null || true
    "$HYST_IPTABLES" apply 2>/dev/null || true
    ufw allow "${u_port}/udp" >/dev/null 2>&1 || true
    iptables -I INPUT 1 -p udp --dport "${u_port}" -j ACCEPT 2>/dev/null || true

    hyst_write_service
    systemctl unmask hysteria-server.service 2>/dev/null || true
    systemctl unmask hysteria-server 2>/dev/null || true
    systemctl daemon-reload
    systemctl enable hysteria-server.service 2>/dev/null || true
    systemctl restart hysteria-server.service 2>/dev/null || systemctl restart hysteria-server 2>/dev/null || true
    
    sleep 1
    if ! systemctl is-active --quiet hysteria-server 2>/dev/null; then
        nohup /usr/local/bin/hysteria1 -c /etc/hysteria/config.json server >/dev/null 2>&1 &
    fi
    
    local ip; ip=$(get_public_ip)
    echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
    echo -e "${GREEN}⚡ ¡UDP CRIS INSTALADO Y ACTIVADO CON ÉXITO! ⚡${NC}"
    echo "────────────────────────────────────────────────────────────"
    echo -e " ${WHITE}• Servidor IP:     ${GREEN}$ip${NC}"
    echo -e " ${WHITE}• Puerto UDP:      ${GREEN}$u_port${NC}"
    echo -e " ${WHITE}• Rangos Hopping:  ${YELLOW}$u_rules${NC}"
    echo -e " ${WHITE}• OBFS:            ${CYAN}$u_obfs${NC}"
    echo -e " ${WHITE}• Usuario / Clave: ${YELLOW}$u_user : $u_pass${NC} ${WHITE}(+ usuarios SSH)${NC}"
    echo "────────────────────────────────────────────────────────────"
    echo -e "${WHITE}Configura estos mismos datos en la app HTTP Conexión.${NC}"
    pause
}

menu_udp() {
    while true; do
        clear
        if [[ ! -f "$HYST_CONF" ]]; then
            echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
            echo -e "${BLUE}                       UDP-HYSTERIA v1${NC}"
            echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
            echo -e "${SSHPLUS_NUM}[1]${NC} ${WHITE}>${NC} INSTALAR HYSTERIA v1 (UDP CRIS)"
            echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
            echo -e "${SSHPLUS_NUM}[0]${NC} ${WHITE}>${NC} Volver"
        else
            hyst_show_summary
            echo -e "${SSHPLUS_NUM}[1]${NC} ${WHITE}>${NC} RECONFIGURAR UDP-HYSTERIA v1"
            echo -e "${SSHPLUS_NUM}[2]${NC} ${WHITE}>${NC} MODIFICAR OBFS"
            echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
            echo -e "${SSHPLUS_NUM}[3]${NC} ${WHITE}>${NC} MODIFICAR RANGOS IPTABLE"
            echo -e "${SSHPLUS_NUM}[4]${NC} ${WHITE}>${NC} ESTADO DEL SERVICIO"
            echo -e "${SSHPLUS_NUM}[5]${NC} ${WHITE}>${NC} REINICIAR SERVICIO"
            echo -e "${SSHPLUS_NUM}[6]${NC} ${WHITE}>${NC} INICIAR/PARAR SERVICIO $(hyst_status_text)"
            echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
            echo -e "${SSHPLUS_NUM}[7]${NC} ${WHITE}>${NC} LOG UDP-HYSTERIA v1"
            echo -e "${SSHPLUS_NUM}[8]${NC} ${WHITE}>${NC} LOG UDP-HYSTERIA v1 EN TIEMPO REAL"
            echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
            printf "%b  %b  %b\n" "${SSHPLUS_NUM}[0]${NC} ${WHITE}> Volver${NC}" "${SSHPLUS_NUM}[9]${NC} ${WHITE}> REINSTALAR${NC}" "${SSHPLUS_NUM}[10]${NC} ${WHITE}> DESINSTALAR${NC}"
        fi
        echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
        echo -ne "${SSHPLUS_CYAN}Opcion:${NC} "
        read -r opt
        case "$opt" in
            1) hyst_configure ;;
            2) [[ -f "$HYST_CONF" ]] && hyst_change_obfs ;;
            3) [[ -f "$HYST_CONF" ]] && hyst_change_range ;;
            4) [[ -f "$HYST_CONF" ]] && hyst_service_status ;;
            5) [[ -f "$HYST_CONF" ]] && systemctl restart hysteria-server && sleep 1 ;;
            6) [[ -f "$HYST_CONF" ]] && hyst_toggle_service ;;
            7) [[ -f "$HYST_CONF" ]] && hyst_show_logs ;;
            8) [[ -f "$HYST_CONF" ]] && hyst_follow_logs ;;
            9) [[ -f "$HYST_CONF" ]] && hyst_reinstall ;;
            10) [[ -f "$HYST_CONF" ]] && hyst_uninstall ;;
            0|00) return ;;
            *) echo -e "${RED}Opción no válida.${NC}"; sleep 1 ;;
        esac
    done
}

# ─────────────────────────────────────────────────────────────────────────────
#  CHISEL TUNNEL MANAGER (NATIVO SYSTEMD)
# ─────────────────────────────────────────────────────────────────────────────
install_chisel_binary() {
    if [[ -x /usr/local/bin/chisel || -x /bin/chisel || -x /usr/bin/chisel ]]; then
        return 0
    fi
    echo -e "${YELLOW}Descargando binario oficial de Chisel...${NC}"
    local arch; arch=$(uname -m)
    if [[ "$arch" == "x86_64" || "$arch" == "amd64" ]]; then
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
    elif [[ "$arch" == "aarch64" || "$arch" == "arm64" ]]; then
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
    chmod 755 /usr/local/bin/chisel 2>/dev/null || true
    ln -sfn /usr/local/bin/chisel /usr/bin/chisel 2>/dev/null || true
    ln -sfn /usr/local/bin/chisel /bin/chisel 2>/dev/null || true
    chmod 755 /bin/chisel /usr/bin/chisel 2>/dev/null || true
    [[ -x /usr/local/bin/chisel || -x /bin/chisel ]]
}

fun_chisel() {
    while true; do
        clear
        local ch_active=false ch_status="${RED}DESACTIVADO${NC}" ch_port="8088" ch_user="admin" ch_pass="admin"
        mkdir -p /etc/chisel
        [[ -f /etc/chisel/port ]] && ch_port=$(cat /etc/chisel/port 2>/dev/null)
        [[ -f /etc/chisel/user ]] && ch_user=$(cat /etc/chisel/user 2>/dev/null)
        [[ -f /etc/chisel/pass ]] && ch_pass=$(cat /etc/chisel/pass 2>/dev/null)
        
        if systemctl is-active chisel >/dev/null 2>&1 || pgrep -x chisel >/dev/null 2>&1; then
            ch_active=true
            ch_status="${GREEN}ACTIVADO${NC}"
        fi
        
        echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
        echo -e "                   ${BLUE}GESTIONAR CHISEL TUNNEL${SCOLOR}"
        echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
        echo -e "  ${WHITE}SERVICIO : ${ch_status}"
        echo -e "  ${WHITE}PUERTO   : ${YELLOW}${ch_port}${NC}"
        [[ "$ch_active" == "true" ]] && echo -e "  ${WHITE}USUARIO  : ${GREEN}${ch_user}${NC} | ${WHITE}CLAVE : ${GREEN}${ch_pass}${NC}"
        echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
        if [[ "$ch_active" == "true" ]]; then
            echo -e "  ${SSHPLUS_NUM}[1]${SCOLOR} \033[1;37m> RECONFIGURAR / CAMBIAR PUERTO Y CLAVE\033[0m"
            echo -e "  ${SSHPLUS_NUM}[2]${SCOLOR} \033[1;37m> DETENER / DESACTIVAR CHISEL\033[0m"
            echo -e "  ${SSHPLUS_NUM}[3]${SCOLOR} \033[1;37m> VER DATOS Y COMANDOS DE CONEXION\033[0m"
            echo -e "  ${SSHPLUS_NUM}[4]${SCOLOR} \033[1;37m> REINICIAR SERVICIO CHISEL\033[0m"
            echo -e "  ${SSHPLUS_NUM}[5]${SCOLOR} \033[1;37m> DESINSTALAR CHISEL\033[0m"
        else
            echo -e "  ${SSHPLUS_NUM}[1]${SCOLOR} \033[1;37m> ACTIVAR / INICIAR CHISEL\033[0m"
            echo -e "  ${SSHPLUS_NUM}[2]${SCOLOR} \033[1;37m> VER DATOS Y COMANDOS DE CONEXION\033[0m"
            echo -e "  ${SSHPLUS_NUM}[3]${SCOLOR} \033[1;37m> DESINSTALAR CHISEL\033[0m"
        fi
        echo -e "  ${SSHPLUS_NUM}[0]${SCOLOR} \033[1;37m> VOLVER\033[0m"
        echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
        echo -ne "${SSHPLUS_CYAN}Opcion:${SCOLOR} "
        read -r ch_opt
        
        case "$ch_opt" in
            1|01)
                clear
                echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
                echo -e "                   ${BLUE}CONFIGURAR CHISEL SERVER${SCOLOR}"
                echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
                
                install_chisel_binary
                if [[ ! -x /usr/local/bin/chisel && ! -x /bin/chisel ]]; then
                    echo -e "\033[1;31mError: No se pudo instalar el binario de Chisel.\033[0m"
                    pause
                    continue
                fi
                
                echo -ne "${WHITE}Puerto para Chisel [Enter = ${ch_port}]: ${NC}"
                read -r new_p
                [[ -n "$new_p" ]] && ch_port="$new_p"
                
                echo -ne "${WHITE}Usuario de autenticación [Enter = ${ch_user}]: ${NC}"
                read -r new_u
                [[ -n "$new_u" ]] && ch_user="$new_u"
                
                echo -ne "${WHITE}Contraseña de autenticación [Enter = ${ch_pass}]: ${NC}"
                read -r new_pwd
                [[ -n "$new_pwd" ]] && ch_pass="$new_pwd"
                
                mkdir -p /etc/chisel
                echo "$ch_port" > /etc/chisel/port
                echo "$ch_user" > /etc/chisel/user
                echo "$ch_pass" > /etc/chisel/pass
                
                # Crear servicio systemd nativo
                cat > /etc/systemd/system/chisel.service << EOF_CHISEL_SVC
[Unit]
Description=HTTP Conexion Chisel Tunnel Server
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/chisel server --port ${ch_port} --socks5 --reverse --auth "${ch_user}:${ch_pass}"
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF_CHISEL_SVC

                systemctl daemon-reload >/dev/null 2>&1
                systemctl unmask chisel 2>/dev/null || true
                systemctl enable --now chisel >/dev/null 2>&1
                systemctl restart chisel >/dev/null 2>&1
                
                # Abrir puerto en firewall si ufw o iptables estan activos
                iptables -I INPUT -p tcp --dport "$ch_port" -j ACCEPT 2>/dev/null || true
                
                if systemctl is-active chisel >/dev/null 2>&1 || pgrep -x chisel >/dev/null 2>&1; then
                    echo -e "\n\033[1;32m⚡ Chisel Server Iniciado y Activo en el puerto ${ch_port}! ⚡\033[0m"
                else
                    echo -e "\n\033[1;31mError al iniciar Chisel. Verifique con: systemctl status chisel\033[0m"
                fi
                pause
                ;;
            2|02)
                if [[ "$ch_active" == "true" ]]; then
                    echo -e "\n${YELLOW}Deteniendo servicio Chisel...${NC}"
                    systemctl stop chisel >/dev/null 2>&1 || true
                    systemctl disable chisel >/dev/null 2>&1 || true
                    pkill -9 -f chisel >/dev/null 2>&1 || true
                    echo -e "\033[1;32mChisel detenido correctamente.\033[0m"
                    pause
                else
                    ver_datos_chisel "$ch_port" "$ch_user" "$ch_pass"
                fi
                ;;
            3|03)
                if [[ "$ch_active" == "true" ]]; then
                    ver_datos_chisel "$ch_port" "$ch_user" "$ch_pass"
                else
                    desinstalar_chisel
                fi
                ;;
            4|04)
                if [[ "$ch_active" == "true" ]]; then
                    systemctl restart chisel >/dev/null 2>&1
                    echo -e "\n\033[1;32mServicio Chisel reiniciado.\033[0m"
                    pause
                fi
                ;;
            5|05)
                if [[ "$ch_active" == "true" ]]; then
                    desinstalar_chisel
                fi
                ;;
            0|00) return ;;
            *) echo -e "\n\033[1;31mOpción inválida!\033[0m"; sleep 1 ;;
        esac
    done
}

ver_datos_chisel() {
    local p="$1" u="$2" pwd="$3"
    local ip; ip=$(get_public_ip)
    clear
    echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
    echo -e "                   ${BLUE}DATOS DE CONEXION CHISEL${SCOLOR}"
    echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
    printf "  \033[1;32m%-18s\033[0m \033[1;37m%s\033[0m\n" "HOST / IP VPS:" "$ip"
    printf "  \033[1;32m%-18s\033[0m \033[1;37m%s\033[0m\n" "PUERTO SERVER:" "$p"
    printf "  \033[1;32m%-18s\033[0m \033[1;37m%s\033[0m\n" "USUARIO:" "$u"
    printf "  \033[1;32m%-18s\033[0m \033[1;37m%s\033[0m\n" "CONTRASEÑA:" "$pwd"
    echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
    echo -e "\033[1;33mCOMANDO PARA CLIENTE (Crea Proxy SOCKS5 Local en 1080):\033[0m"
    echo -e "\033[1;36mchisel client --auth \"${u}:${pwd}\" ${ip}:${p} socks\033[0m"
    echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
    pause
}

desinstalar_chisel() {
    clear
    echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
    echo -e "                   ${RED}DESINSTALAR CHISEL${SCOLOR}"
    echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
    echo -ne "${WHITE}¿Está seguro de desinstalar Chisel? [s/n]: ${NC}"
    read -r resp
    [[ "$resp" != @(s|S|si|SI) ]] && return
    systemctl stop chisel >/dev/null 2>&1 || true
    systemctl disable chisel >/dev/null 2>&1 || true
    pkill -9 -f chisel >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/chisel.service /usr/local/bin/chisel /usr/bin/chisel /bin/chisel
    rm -rf /etc/chisel
    systemctl daemon-reload >/dev/null 2>&1
    echo -e "\n\033[1;32mChisel desinstalado completamente del sistema.\033[0m"
    pause
}

# ─────────────────────────────────────────────────────────────────────────────
#  UDP CUSTOM MANAGER (NATIVO INTEGRADO)
# ─────────────────────────────────────────────────────────────────────────────
UDPC_INSTALL_DIR="/opt/udp-custom"
UDPC_CONFIG_FILE="${UDPC_INSTALL_DIR}/config.json"
UDPC_BINARY_PATH="/usr/local/bin/udp-custom"
UDPC_SERVICE_NAME="udp-custom.service"
UDPC_SERVICE_FILE="/etc/systemd/system/${UDPC_SERVICE_NAME}"

udpc_ensure_binary() {
    if [[ -x "$UDPC_BINARY_PATH" ]] && head -c 4 "$UDPC_BINARY_PATH" 2>/dev/null | grep -q 'ELF'; then
        return 0
    fi
    if [[ -x "${UDPC_INSTALL_DIR}/server" ]] && head -c 4 "${UDPC_INSTALL_DIR}/server" 2>/dev/null | grep -q 'ELF'; then
        ln -sfn "${UDPC_INSTALL_DIR}/server" "$UDPC_BINARY_PATH"
        return 0
    fi
    if [[ -f "/opt/ssh-cris/udp-custom" ]] && head -c 4 "/opt/ssh-cris/udp-custom" 2>/dev/null | grep -q 'ELF'; then
        cp -f "/opt/ssh-cris/udp-custom" "$UDPC_BINARY_PATH"
        chmod +x "$UDPC_BINARY_PATH"
        return 0
    fi
    if [[ -f "/etc/SSHPlus/udp-custom" ]] && head -c 4 "/etc/SSHPlus/udp-custom" 2>/dev/null | grep -q 'ELF'; then
        cp -f "/etc/SSHPlus/udp-custom" "$UDPC_BINARY_PATH"
        chmod +x "$UDPC_BINARY_PATH"
        return 0
    fi

    echo -e "\033[1;33m[*] Descargando binario oficial UDP-Custom...\033[0m"
    local arch; arch=$(uname -m)
    case "$arch" in
        x86_64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        armv7l|armhf) arch="armv7" ;;
        *) arch="amd64" ;;
    esac

    local url1="https://raw.githubusercontent.com/soportecrisdev/SCRIP_CRISDEV/main/udp-custom"
    local url2="https://raw.githubusercontent.com/karl1999x/PandaScript/main/BINARIOS/udp-amd64.bin"
    local url3="https://github.com/AmnesiaPod/UDPCustom/releases/latest/download/udp-custom-linux-${arch}"

    curl -fsSLk "$url1" -o "$UDPC_BINARY_PATH" 2>/dev/null || \
    curl -fsSLk "$url2" -o "$UDPC_BINARY_PATH" 2>/dev/null || \
    curl -fsSLk "$url3" -o "$UDPC_BINARY_PATH" 2>/dev/null || \
    wget --no-check-certificate -q "$url1" -O "$UDPC_BINARY_PATH" 2>/dev/null || true

    chmod 755 "$UDPC_BINARY_PATH" 2>/dev/null || true
    if [[ -x "$UDPC_BINARY_PATH" ]] && head -c 4 "$UDPC_BINARY_PATH" 2>/dev/null | grep -q 'ELF'; then
        mkdir -p "${UDPC_INSTALL_DIR}"
        cp -f "$UDPC_BINARY_PATH" "${UDPC_INSTALL_DIR}/server" 2>/dev/null || true
        return 0
    fi
    return 1
}

udpc_is_running() {
    systemctl is-active --quiet "$UDPC_SERVICE_NAME" 2>/dev/null || pgrep -x udp-custom >/dev/null 2>&1
}

udpc_get_port() {
    local port="7100"
    if [[ -f "$UDPC_CONFIG_FILE" ]]; then
        port=$(grep -oE '"listen"[[:space:]]*:[[:space:]]*"[^"]+"' "$UDPC_CONFIG_FILE" 2>/dev/null | grep -oE '[0-9]+$' | head -1)
        [[ -z "$port" || "$port" == "0" ]] && port=$(grep -oE ':[0-9]+' "$UDPC_CONFIG_FILE" 2>/dev/null | tr -d ':' | head -1)
    fi
    if [[ -z "$port" || "$port" == "0" && -f /etc/udp-custom/server.json ]]; then
        port=$(grep -oE '"listen"[[:space:]]*:[[:space:]]*"[^"]+"' /etc/udp-custom/server.json 2>/dev/null | grep -oE '[0-9]+$' | head -1)
        [[ -z "$port" || "$port" == "0" ]] && port=$(grep -oE ':[0-9]+' /etc/udp-custom/server.json 2>/dev/null | tr -d ':' | head -1)
    fi
    if [[ -z "$port" || "$port" == "0" ]]; then
        port=$(ss -ulnp 2>/dev/null | grep -E "udp-custom|server" | awk '{print $5}' | grep -oE '[0-9]+$' | head -1)
    fi
    echo "${port:-7100}"
}

udpc_create_config() {
    local port="${1:-7100}"
    local stream_buf="${2:-33554432}"
    local core_buf="${3:-8388608}"

    mkdir -p "${UDPC_INSTALL_DIR}" /etc/udp-custom /root/udp
    cat > "$UDPC_CONFIG_FILE" <<EOF
{
  "listen": ":${port}",
  "stream_buffer": ${stream_buf},
  "receive_buffer": ${core_buf},
  "auth": {
    "mode": "passwords",
    "config": ["crisdev", "1234"]
  }
}
EOF
    chmod 644 "$UDPC_CONFIG_FILE"
    cp -f "$UDPC_CONFIG_FILE" /etc/udp-custom/server.json 2>/dev/null || true
    cp -f "$UDPC_CONFIG_FILE" /etc/udp-custom/config.json 2>/dev/null || true
    cp -f "$UDPC_CONFIG_FILE" /root/udp/config.json 2>/dev/null || true
}

udpc_create_service() {
    cat > "$UDPC_SERVICE_FILE" <<EOF
[Unit]
Description=UDP Custom Server - HTTP Conexión
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${UDPC_INSTALL_DIR}
ExecStart=${UDPC_BINARY_PATH} server -c ${UDPC_CONFIG_FILE}
Restart=always
RestartSec=3s
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$UDPC_SERVICE_FILE"
    systemctl daemon-reload >/dev/null 2>&1 || true
}

udpc_stop() {
    systemctl stop "$UDPC_SERVICE_NAME" >/dev/null 2>&1 || true
    systemctl disable "$UDPC_SERVICE_NAME" >/dev/null 2>&1 || true
    pkill -9 -x udp-custom >/dev/null 2>&1 || true
    pkill -9 -f 'udp-custom' >/dev/null 2>&1 || true
}

menu_udpcustom() {
    mkdir -p "${UDPC_INSTALL_DIR}"
    while true; do
        clear
        local running_sts="\033[1;31mDETENIDO [x]\033[0m"
        local cur_port; cur_port=$(udpc_get_port)

        if udpc_is_running; then
            running_sts="\033[1;32mACTIVO [o]\033[0m"
        fi

        echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
        echo -e "             \033[1;36mGESTOR UDP CUSTOM — HTTP CONEXIÓN\033[0m"
        echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
        echo -e "  \033[1;37mESTADO DEL SERVICIO  : ${running_sts}"
        echo -e "  \033[1;37mPUERTO UDP EN USO    : \033[1;33m${cur_port}/udp\033[0m"
        echo -e "  \033[1;37mUBICACIÓN CONFIG     : \033[1;36m${UDPC_CONFIG_FILE}\033[0m"
        echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
        echo -e "  ${SSHPLUS_NUM}[1]${SCOLOR} \033[1;37m> ACTIVAR / CAMBIAR PUERTO UDP\033[0m"
        if udpc_is_running; then
            echo -e "  ${SSHPLUS_NUM}[2]${SCOLOR} \033[1;37m> DETENER SERVICIO UDP-CUSTOM\033[0m"
            echo -e "  ${SSHPLUS_NUM}[3]${SCOLOR} \033[1;37m> REINICIAR SERVICIO UDP-CUSTOM\033[0m"
        else
            echo -e "  ${SSHPLUS_NUM}[2]${SCOLOR} \033[1;37m> INICIAR SERVICIO UDP-CUSTOM\033[0m"
        fi
        echo -e "  ${SSHPLUS_NUM}[4]${SCOLOR} \033[1;37m> VER REGISTRO / LOGS EN VIVO\033[0m"
        echo -e "  \033[1;31m[5]\033[0m \033[1;37m> DESINSTALAR UDP-CUSTOM\033[0m"
        echo -e "  ${SSHPLUS_NUM}[0]${SCOLOR} \033[1;37m> VOLVER\033[0m"
        echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
        echo -ne "${SSHPLUS_CYAN}Opción:${SCOLOR} "
        read -r opc
        case "$opc" in
            1|01)
                clear
                echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
                echo -e "           \033[1;36mCONFIGURAR PUERTO UDP-CUSTOM\033[0m"
                echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
                udpc_ensure_binary || {
                    echo -e "\033[1;31m[ERROR] No se pudo obtener el binario ejecutable de UDP-Custom.\033[0m"
                    pause
                    continue
                }
                local cur_p; cur_p=$(udpc_get_port)
                echo -e "\033[1;37mPuertos recomendados para UDP Custom:\033[0m"
                echo -e "  • \033[1;33m7100\033[0m (Estándar UDP Custom / VPN)"
                echo -e "  • \033[1;33m7200\033[0m, \033[1;33m7300\033[0m, \033[1;33m7400\033[0m (Alternativos)"
                echo -e "  • \033[1;33m53\033[0m / \033[1;33m5300\033[0m (DNS bypass operadores)"
                echo ""
                echo -ne "\033[1;32mIngrese el puerto a configurar [Enter = ${cur_p}]:\033[0m "
                read -r in_port
                [[ -z "$in_port" ]] && in_port="$cur_p"
                if ! [[ "$in_port" =~ ^[0-9]+$ ]] || (( in_port < 1 || in_port > 65535 )); then
                    echo -e "\033[1;31mPuerto no válido (1-65535).\033[0m"
                    pause
                    continue
                fi
                echo ""
                echo -e "\033[1;37mSeleccione tamaño de buffer:\033[0m"
                echo -e "  \033[1;32m[1]\033[0m \033[1;37m> Estándar (Stream: 32 MB, Core: 8 MB) - Recomendado\033[0m"
                echo -e "  \033[1;32m[2]\033[0m \033[1;37m> Alto Rendimiento (Stream: 64 MB, Core: 16 MB)\033[0m"
                echo -ne "\033[1;32mOpción [Enter = 1]:\033[0m "
                read -r buf_opt
                local s_buf=33554432 c_buf=8388608
                [[ "$buf_opt" == "2" ]] && { s_buf=67108864; c_buf=16777216; }

                udpc_stop
                udpc_create_config "$in_port" "$s_buf" "$c_buf"
                udpc_create_service
                systemctl enable --now "$UDPC_SERVICE_NAME" >/dev/null 2>&1 || true
                iptables -I INPUT -p udp --dport "$in_port" -j ACCEPT 2>/dev/null || true
                ufw allow "${in_port}/udp" 2>/dev/null || true
                sleep 1
                echo ""
                if udpc_is_running; then
                    echo -e "\033[1;32m✔ Servidor UDP-Custom activo y funcionando en el puerto UDP ${in_port}! ⚡\033[0m"
                else
                    echo -e "\033[1;31m✗ No se pudo iniciar el servicio en el puerto ${in_port}.\033[0m"
                    echo -e "\033[1;33mRegistro de error:\033[0m"
                    journalctl -u "$UDPC_SERVICE_NAME" -n 8 --no-pager 2>/dev/null || true
                fi
                pause
                ;;
            2|02)
                if udpc_is_running; then
                    udpc_stop
                    echo -e "\n\033[1;33mServicio UDP-Custom detenido.\033[0m"
                else
                    udpc_ensure_binary
                    systemctl enable --now "$UDPC_SERVICE_NAME" >/dev/null 2>&1 || true
                    echo -e "\n\033[1;32mServicio UDP-Custom iniciado.\033[0m"
                fi
                pause
                ;;
            3|03)
                if udpc_is_running; then
                    systemctl restart "$UDPC_SERVICE_NAME" >/dev/null 2>&1 || true
                    echo -e "\n\033[1;32mServicio UDP-Custom reiniciado.\033[0m"
                    pause
                fi
                ;;
            4|04)
                clear
                echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
                echo -e "             \033[1;36mLOGS UDP-CUSTOM EN VIVO\033[0m"
                echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
                journalctl -u "$UDPC_SERVICE_NAME" -n 25 --no-pager 2>/dev/null || echo "Sin registros disponibles."
                pause
                ;;
            5|05)
                clear
                echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
                echo -e "             \033[1;31mDESINSTALAR UDP-CUSTOM\033[0m"
                echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
                echo -ne "\033[1;31m¿Está seguro de detener y desinstalar UDP-Custom? [s/N]: \033[0m"
                read -r conf
                if [[ "$conf" =~ ^[sS]$ ]]; then
                    udpc_stop
                    rm -f "$UDPC_SERVICE_FILE"
                    systemctl daemon-reload >/dev/null 2>&1 || true
                    systemctl reset-failed "$UDPC_SERVICE_NAME" >/dev/null 2>&1 || true
                    rm -rf "${UDPC_INSTALL_DIR}" /etc/udp-custom /root/udp
                    echo -e "\n\033[1;32m✔ UDP-Custom ha sido desinstalado completamente del servidor.\033[0m"
                    pause
                fi
                ;;
            0|00) return ;;
            *) echo -e "\033[1;31mOpción no válida!\033[0m"; sleep 1 ;;
        esac
    done
}

# ─────────────────────────────────────────────────────────────────────────────
#  HYSTERIA 2 MANAGER (NATIVO INTEGRADO)
# ─────────────────────────────────────────────────────────────────────────────
HY2_INSTALL_DIR="/etc/hysteria2"
HY2_CONFIG_FILE="${HY2_INSTALL_DIR}/config.yaml"
HY2_BINARY_PATH="/usr/local/bin/hysteria2"
HY2_SERVICE_NAME="hysteria2.service"
HY2_SERVICE_FILE="/etc/systemd/system/${HY2_SERVICE_NAME}"
HY2_CERT_FILE="${HY2_INSTALL_DIR}/server.crt"
HY2_KEY_FILE="${HY2_INSTALL_DIR}/server.key"

hy2_ensure_binary() {
    if [[ -x "$HY2_BINARY_PATH" ]] && "$HY2_BINARY_PATH" version 2>/dev/null | grep -qiE 'v2|2\.'; then
        return 0
    fi
    if [[ -x "$HY2_BINARY_PATH" ]] && head -c 4 "$HY2_BINARY_PATH" 2>/dev/null | grep -q 'ELF'; then
        return 0
    fi

    echo -e "\033[1;33m[*] Descargando Hysteria v2 oficial...\033[0m"
    local arch; arch=$(uname -m)
    case "$arch" in
        x86_64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        armv7l|armhf) arch="armv7" ;;
        *) arch="amd64" ;;
    esac

    local url="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${arch}"
    curl -fsSLk "$url" -o "$HY2_BINARY_PATH" 2>/dev/null || \
    wget --no-check-certificate -q "$url" -O "$HY2_BINARY_PATH" 2>/dev/null || true

    chmod 755 "$HY2_BINARY_PATH" 2>/dev/null || true
    [[ -x "$HY2_BINARY_PATH" ]] && head -c 4 "$HY2_BINARY_PATH" 2>/dev/null | grep -q 'ELF'
}

hy2_ensure_certificates() {
    local domain="${1:-crisdev.online}"
    mkdir -p "${HY2_INSTALL_DIR}"
    if [[ ! -f "$HY2_CERT_FILE" || ! -f "$HY2_KEY_FILE" ]]; then
        echo -e "\033[1;33m[*] Generando certificado TLS para Hysteria 2 (CN: ${domain})...\033[0m"
        openssl req -x509 -newkey rsa:2048 -days 3650 -nodes \
            -keyout "$HY2_KEY_FILE" -out "$HY2_CERT_FILE" \
            -subj "/CN=${domain}" >/dev/null 2>&1 || true
        chmod 600 "$HY2_KEY_FILE" 2>/dev/null || true
        chmod 644 "$HY2_CERT_FILE" 2>/dev/null || true
    fi
}

hy2_is_running() {
    systemctl is-active --quiet "$HY2_SERVICE_NAME" 2>/dev/null || pgrep -x hysteria2 >/dev/null 2>&1
}

hy2_get_port() {
    local port="443"
    if [[ -f "$HY2_CONFIG_FILE" ]]; then
        port=$(grep -E '^[[:space:]]*listen:' "$HY2_CONFIG_FILE" 2>/dev/null | awk '{print $2}' | tr -d ' ":' | head -1)
    fi
    [[ -z "$port" ]] && port="443"
    echo "$port"
}

hy2_get_auth() {
    local auth="crisdev"
    if [[ -f "$HY2_CONFIG_FILE" ]]; then
        auth=$(grep -E '^[[:space:]]*password:' "$HY2_CONFIG_FILE" 2>/dev/null | awk '{print $2}' | tr -d ' "' | head -1)
    fi
    echo "${auth:-crisdev}"
}

hy2_get_obfs() {
    local obfs=""
    if [[ -f "$HY2_CONFIG_FILE" ]]; then
        obfs=$(grep -E '^[[:space:]]*salamander:' -A 1 "$HY2_CONFIG_FILE" 2>/dev/null | grep 'password:' | awk '{print $2}' | tr -d ' "' | head -1)
    fi
    echo "$obfs"
}

hy2_get_sni() {
    local sni="crisdev.online"
    if [[ -f "$HY2_CONFIG_FILE" ]]; then
        sni=$(grep -E '^[[:space:]]*url:' "$HY2_CONFIG_FILE" 2>/dev/null | awk '{print $2}' | sed 's|https://||' | tr -d ' "' | head -1)
    fi
    echo "${sni:-crisdev.online}"
}

hy2_create_config() {
    local port="${1:-443}"
    local auth_pass="${2:-crisdev}"
    local obfs_pass="${3:-}"
    local sni_domain="${4:-crisdev.online}"

    mkdir -p "${HY2_INSTALL_DIR}"
    hy2_ensure_certificates "$sni_domain"

    local obfs_block=""
    if [[ -n "$obfs_pass" ]]; then
        obfs_block="obfs:
  type: salamander
  salamander:
    password: ${obfs_pass}"
    fi

    cat > "$HY2_CONFIG_FILE" <<EOF
listen: :${port}

tls:
  cert: ${HY2_CERT_FILE}
  key: ${HY2_KEY_FILE}

auth:
  type: password
  password: ${auth_pass}

${obfs_block}

masquerade:
  type: proxy
  proxy:
    url: https://${sni_domain}
    rewriteHost: true

bandwidth:
  up: 100 mbps
  down: 100 mbps

ignoreClientBandwidth: false
disableUDP: false
udpIdleTimeout: 60s
EOF
    chmod 644 "$HY2_CONFIG_FILE"
}

hy2_create_service() {
    cat > "$HY2_SERVICE_FILE" <<EOF
[Unit]
Description=Hysteria 2 Server - HTTP Conexión
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${HY2_INSTALL_DIR}
ExecStart=${HY2_BINARY_PATH} server -c ${HY2_CONFIG_FILE}
Restart=always
RestartSec=3s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$HY2_SERVICE_FILE"
    systemctl daemon-reload >/dev/null 2>&1 || true
}

hy2_stop() {
    systemctl stop "$HY2_SERVICE_NAME" >/dev/null 2>&1 || true
    systemctl disable "$HY2_SERVICE_NAME" >/dev/null 2>&1 || true
    pkill -9 -x hysteria2 >/dev/null 2>&1 || true
    pkill -9 -f 'hysteria2' >/dev/null 2>&1 || true
}

menu_hysteria2() {
    mkdir -p "${HY2_INSTALL_DIR}"
    while true; do
        clear
        local running_sts="\033[1;31mDETENIDO [x]\033[0m"
        local cur_port; cur_port=$(hy2_get_port)
        local cur_auth; cur_auth=$(hy2_get_auth)
        local cur_obfs; cur_obfs=$(hy2_get_obfs)

        if hy2_is_running; then
            running_sts="\033[1;32mACTIVO [o]\033[0m"
        fi

        echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
        echo -e "       \033[1;36mGESTOR HYSTERIA v2 (QUIC UDP) — HTTP CONEXIÓN\033[0m"
        echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
        echo -e "  \033[1;37mESTADO DEL SERVICIO  : ${running_sts}"
        echo -e "  \033[1;37mPUERTO UDP EN USO    : \033[1;33m${cur_port}/udp\033[0m"
        echo -e "  \033[1;37mAUTENTICACIÓN        : \033[1;32m${cur_auth}\033[0m"
        echo -e "  \033[1;37mOFUSCACIÓN SALAMANDER: \033[1;36m${cur_obfs:-Desactivada}\033[0m"
        echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
        echo -e "  ${SSHPLUS_NUM}[1]${SCOLOR} \033[1;37m> CONFIGURAR / CAMBIAR PUERTO HYSTERIA 2\033[0m"
        if hy2_is_running; then
            echo -e "  ${SSHPLUS_NUM}[2]${SCOLOR} \033[1;37m> DETENER SERVICIO HYSTERIA 2\033[0m"
            echo -e "  ${SSHPLUS_NUM}[3]${SCOLOR} \033[1;37m> REINICIAR SERVICIO HYSTERIA 2\033[0m"
        else
            echo -e "  ${SSHPLUS_NUM}[2]${SCOLOR} \033[1;37m> INICIAR SERVICIO HYSTERIA 2\033[0m"
        fi
        echo -e "  ${SSHPLUS_NUM}[4]${SCOLOR} \033[1;37m> VER DATOS DE CONEXIÓN / ENLACE\033[0m"
        echo -e "  ${SSHPLUS_NUM}[5]${SCOLOR} \033[1;37m> VER REGISTRO DE LOGS EN VIVO\033[0m"
        echo -e "  \033[1;31m[6]\033[0m \033[1;37m> DESINSTALAR HYSTERIA 2\033[0m"
        echo -e "  ${SSHPLUS_NUM}[0]${SCOLOR} \033[1;37m> VOLVER\033[0m"
        echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
        echo -ne "${SSHPLUS_CYAN}Opción:${SCOLOR} "
        read -r opc
        case "$opc" in
            1|01)
                clear
                echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
                echo -e "           \033[1;36mCONFIGURAR PUERTO HYSTERIA 2\033[0m"
                echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
                hy2_ensure_binary || {
                    echo -e "\033[1;31m[ERROR] No se pudo obtener el binario Hysteria 2.\033[0m"
                    pause
                    continue
                }
                local cur_p; cur_p=$(hy2_get_port)
                echo -ne "\033[1;32mPuerto UDP a escuchar [Enter = ${cur_p}]:\033[0m "
                read -r in_port
                [[ -z "$in_port" ]] && in_port="$cur_p"
                if ! [[ "$in_port" =~ ^[0-9]+$ ]] || (( in_port < 1 || in_port > 65535 )); then
                    echo -e "\033[1;31mPuerto no válido.\033[0m"
                    pause
                    continue
                fi
                echo -ne "\033[1;32mContraseña de autenticación (auth password) [Enter = $(hy2_get_auth)]:\033[0m "
                read -r in_auth
                [[ -z "$in_auth" ]] && in_auth=$(hy2_get_auth)

                echo -ne "\033[1;32mContraseña de Ofuscación Salamander (opcional, Enter = omitir):\033[0m "
                read -r in_obfs

                local in_sni
                in_sni=$(hy2_get_sni)
                echo -ne "\033[1;32mDominio SNI de camuflaje web [Enter = ${in_sni}]:\033[0m "
                read -r input_sni
                [[ -n "$input_sni" ]] && in_sni="$input_sni"

                hy2_stop
                hy2_create_config "$in_port" "$in_auth" "$in_obfs" "$in_sni"
                hy2_create_service
                systemctl enable --now "$HY2_SERVICE_NAME" >/dev/null 2>&1 || true
                iptables -I INPUT -p udp --dport "$in_port" -j ACCEPT 2>/dev/null || true
                ufw allow "${in_port}/udp" 2>/dev/null || true
                sleep 1
                echo ""
                if hy2_is_running; then
                    echo -e "\033[1;32m✔ Servidor Hysteria 2 activo y escuchando en el puerto UDP ${in_port}! ⚡\033[0m"
                else
                    echo -e "\033[1;31m✗ No se pudo iniciar el servicio Hysteria 2.\033[0m"
                    echo -e "\033[1;33mRegistro de error:\033[0m"
                    journalctl -u "$HY2_SERVICE_NAME" -n 8 --no-pager 2>/dev/null || true
                fi
                pause
                ;;
            2|02)
                if hy2_is_running; then
                    hy2_stop
                    echo -e "\n\033[1;33mServicio Hysteria 2 detenido.\033[0m"
                else
                    hy2_ensure_binary
                    systemctl enable --now "$HY2_SERVICE_NAME" >/dev/null 2>&1 || true
                    echo -e "\n\033[1;32mServicio Hysteria 2 iniciado.\033[0m"
                fi
                pause
                ;;
            3|03)
                if hy2_is_running; then
                    systemctl restart "$HY2_SERVICE_NAME" >/dev/null 2>&1 || true
                    echo -e "\n\033[1;32mServicio Hysteria 2 reiniciado.\033[0m"
                    pause
                fi
                ;;
            4|04)
                clear
                echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
                echo -e "             \033[1;36mDATOS DE CONEXIÓN HYSTERIA 2\033[0m"
                echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
                local my_ip; my_ip=$(curl -4 -s --max-time 3 https://api.ipify.org 2>/dev/null || cat /etc/IP 2>/dev/null || echo "127.0.0.1")
                local p; p=$(hy2_get_port)
                local a; a=$(hy2_get_auth)
                local o; o=$(hy2_get_obfs)
                local s; s=$(hy2_get_sni)
                local obfs_param=""
                [[ -n "$o" ]] && obfs_param="&obfs=salamander&obfs-password=${o}"
                local hy2_url="hysteria2://${a}@${my_ip}:${p}/?sni=${s}&insecure=1${obfs_param}#HTTP_Conexion-HY2"
                echo -e "  \033[1;32mHOST / IP SERVIDOR:\033[0m \033[1;37m${my_ip}\033[0m"
                echo -e "  \033[1;32mPUERTO UDP        :\033[0m \033[1;37m${p}\033[0m"
                echo -e "  \033[1;32mPASSWORD / AUTH   :\033[0m \033[1;37m${a}\033[0m"
                echo -e "  \033[1;32mOFUSCACIÓN (OBFS) :\033[0m \033[1;37m${o:-Desactivada}\033[0m"
                echo -e "  \033[1;32mSNI / DOMINIO     :\033[0m \033[1;37m${s}\033[0m"
                echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
                echo -e "\033[1;33mENLACE OFICIAL HYSTERIA 2:\033[0m"
                echo -e "\033[1;36m${hy2_url}\033[0m"
                pause
                ;;
            5|05)
                clear
                echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
                echo -e "             \033[1;36mLOGS HYSTERIA 2 EN VIVO\033[0m"
                echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
                journalctl -u "$HY2_SERVICE_NAME" -n 25 --no-pager 2>/dev/null || echo "Sin registros disponibles."
                pause
                ;;
            6|06)
                clear
                echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
                echo -e "             \033[1;31mDESINSTALAR HYSTERIA 2\033[0m"
                echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
                echo -ne "\033[1;31m¿Está seguro de detener y desinstalar Hysteria 2? [s/N]: \033[0m"
                read -r conf
                if [[ "$conf" =~ ^[sS]$ ]]; then
                    hy2_stop
                    rm -f "$HY2_SERVICE_FILE"
                    systemctl daemon-reload >/dev/null 2>&1 || true
                    systemctl reset-failed "$HY2_SERVICE_NAME" >/dev/null 2>&1 || true
                    rm -rf "${HY2_INSTALL_DIR}"
                    echo -e "\n\033[1;32m✔ Hysteria 2 ha sido desinstalado completamente.\033[0m"
                    pause
                fi
                ;;
            0|00) return ;;
            *) echo -e "\033[1;31mOpción no válida!\033[0m"; sleep 1 ;;
        esac
    done
}

# ─────────────────────────────────────────────────────────────────────────────
#  MENÚ DE PROTOCOLOS (CONFIGURACION DE PROTOCOLOS)
# ─────────────────────────────────────────────────────────────────────────────
menu_protocolos() {
    while true; do
        clear
        echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
        echo -e "                ${BLUE}CONFIGURACION DE PROTOCOLOS${SCOLOR}"
        echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"

        # 1. OpenSSH
        local ssh_p
        ssh_p=$(grep '^Port ' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | xargs || true)
        [[ -z "$ssh_p" ]] && ssh_p="22"
        echo -e "\033[1;32mSERVICIO: \033[1;33mOPENSSH \033[1;32mPUERTO: \033[1;37m$ssh_p\033[0m"

        # 2. Proxy Socks
        local sks_p
        sks_p=$(get_proc_ports 'proxy\.py|wsproxy\.py|/python')
        if [[ -n "$sks_p" ]]; then
            echo -e "\033[1;32mSERVICIO: \033[1;33mPROXY SOCKS \033[1;32mPUERTO: \033[1;37m$sks_p\033[0m"
        fi

        # 3. SSL Tunnel
        local ssl_p
        ssl_p=$(get_proc_ports 'stunnel|stunnel4')
        if [[ -n "$ssl_p" ]]; then
            echo -e "\033[1;32mSERVICIO: \033[1;33mSSL TUNNEL \033[1;32mPUERTO: \033[1;37m$ssl_p\033[0m"
        fi

        # 4. Dropbear
        local drp_p
        drp_p=$(get_proc_ports 'dropbear')
        if [[ -n "$drp_p" ]]; then
            echo -e "\033[1;32mSERVICIO: \033[1;33mDROPBEAR \033[1;32mPUERTO: \033[1;37m$drp_p\033[0m"
        fi

        # 5. V2Ray / Xray
        local is_v2_active=0
        local v2_engine=""
        local v2_ports=""
        if systemctl is-active --quiet xray 2>/dev/null || pgrep -x xray >/dev/null 2>&1; then
            is_v2_active=1
            v2_engine="XRAY"
            if command -v jq >/dev/null 2>&1 && [[ -f /usr/local/etc/xray/config.json ]]; then
                v2_ports="$(jq -r '[.inbounds[]?.port] | map(select(. != null)) | unique | join(" ")' /usr/local/etc/xray/config.json 2>/dev/null)"
            elif command -v jq >/dev/null 2>&1 && [[ -f /etc/xray/config.json ]]; then
                v2_ports="$(jq -r '[.inbounds[]?.port] | map(select(. != null)) | unique | join(" ")' /etc/xray/config.json 2>/dev/null)"
            fi
            [[ -z "${v2_ports// }" ]] && v2_ports="$(ss -tlpn 2>/dev/null | grep -w 'xray' | awk '{print $4}' | awk -F: '{print $NF}' | sort -un | xargs)"
        elif systemctl is-active --quiet v2ray 2>/dev/null || pgrep -x v2ray >/dev/null 2>&1; then
            is_v2_active=1
            v2_engine="V2RAY"
            if command -v jq >/dev/null 2>&1 && [[ -f /etc/v2ray/config.json ]]; then
                v2_ports="$(jq -r '[.inbounds[]?.port] | map(select(. != null)) | unique | join(" ")' /etc/v2ray/config.json 2>/dev/null)"
            fi
            [[ -z "${v2_ports// }" ]] && v2_ports="$(ss -tlpn 2>/dev/null | grep -w 'v2ray' | awk '{print $4}' | awk -F: '{print $NF}' | sort -un | xargs)"
        fi

        if [[ $is_v2_active -eq 1 ]]; then
            echo -e "\033[1;32mSERVICIO: \033[1;33m${v2_engine} \033[1;32mPUERTO: \033[1;37m${v2_ports:-N/A}\033[0m"
        fi

        # 6. UDP CRIS / HYSTERIA
        if systemctl is-active --quiet hysteria-server 2>/dev/null || pgrep -x hysteria1 >/dev/null 2>&1 || pgrep -x hysteria >/dev/null 2>&1; then
            local _hyst_pt=""
            [[ -f /etc/hysteria/sshplus.env ]] && _hyst_pt="$(grep '^HYST_PORT=' /etc/hysteria/sshplus.env 2>/dev/null | head -1 | cut -d= -f2 | tr -d '"')"
            [[ -z "${_hyst_pt// }" && -f /etc/hysteria/config.json ]] && _hyst_pt="$(grep -oE '"listen"[[:space:]]*:[[:space:]]*"[^"]+"' /etc/hysteria/config.json 2>/dev/null | grep -oE '[0-9]+' | head -1)"
            [[ -z "${_hyst_pt// }" ]] && _hyst_pt="$(ss -ulnp 2>/dev/null | grep 'hysteria' | awk '{print $5}' | grep -oE '[0-9]+$' | head -1)"
            [[ -z "${_hyst_pt// }" ]] && _hyst_pt="36712"
            
            local _hyst_rules=""
            [[ -f /etc/hysteria/sshplus.env ]] && _hyst_rules="$(grep '^HYST_RULES=' /etc/hysteria/sshplus.env 2>/dev/null | head -1 | cut -d= -f2 | tr -d '"')"
            if [[ -n "$_hyst_rules" && "$_hyst_rules" != "none" && "$_hyst_rules" != "0" ]]; then
                echo -e "\033[1;32mSERVICIO: \033[1;33mUDP CRIS (v1) \033[1;32mPUERTO: \033[1;37m$_hyst_pt \033[1;33mRANGOS: \033[1;37m$_hyst_rules\033[0m"
            else
                echo -e "\033[1;32mSERVICIO: \033[1;33mUDP CRIS (v1) \033[1;32mPUERTO: \033[1;37m$_hyst_pt\033[0m"
            fi
        fi

        # 6.1 HYSTERIA V2
        if systemctl is-active --quiet hysteria2 2>/dev/null || pgrep -x hysteria2 >/dev/null 2>&1; then
            local _hy2_pt; _hy2_pt=$(scan_hysteria2_port)
            echo -e "\033[1;32mSERVICIO: \033[1;33mHYSTERIA V2 \033[1;32mPUERTO: \033[1;37m${_hy2_pt:-443}/udp\033[0m"
        fi

        # 7. BadVPN
        if systemctl is-active --quiet badvpn-udpgw 2>/dev/null || pgrep -x badvpn-udpgw >/dev/null 2>&1 || pgrep -x udpvpn >/dev/null 2>&1; then
            local _bad_p
            _bad_p=$(ss -ulpn 2>/dev/null | grep -E 'badvpn-udpgw|udpvpn' | awk '{print $5}' | grep -oE '[0-9]+$' | sort -un | xargs || true)
            [[ -z "$_bad_p" && -f /etc/systemd/system/badvpn-udpgw.service ]] && _bad_p=$(grep -oE '\-\-listen\-addr[[:space:]]+127\.0\.0\.1:[0-9]+' /etc/systemd/system/badvpn-udpgw.service 2>/dev/null | cut -d: -f2 | xargs || true)
            [[ -z "$_bad_p" ]] && _bad_p="7300"
            echo -e "\033[1;32mSERVICIO: \033[1;33mBADVPN \033[1;32mPUERTO: \033[1;37m$_bad_p\033[0m"
        fi

        # 8. Squid
        local sqd_p
        sqd_p=$(get_proc_ports 'squid')
        if [[ -n "$sqd_p" ]]; then
            echo -e "\033[1;32mSERVICIO: \033[1;33mSQUID \033[1;32mPUERTO: \033[1;37m$sqd_p\033[0m"
        fi

        # 9. SlowDNS
        if systemctl is-active --quiet slowdns 2>/dev/null || pgrep -x dnstt-server >/dev/null 2>&1 || pgrep -f 'dnstt-server' >/dev/null 2>&1; then
            local _slow_pt="53"
            [[ -f /etc/slowdns/slowdns.conf ]] && _slow_pt="$(grep '^SLOW_PORT=' /etc/slowdns/slowdns.conf 2>/dev/null | head -1 | cut -d= -f2 | tr -d '"')"
            [[ -z "$_slow_pt" ]] && _slow_pt="53"
            echo -e "\033[1;32mSERVICIO: \033[1;33mSLOWDNS \033[1;32mPUERTO: \033[1;37m$_slow_pt\033[0m"
        fi

        # 10. Chisel
        if systemctl is-active --quiet chisel 2>/dev/null || pgrep -f 'chisel' >/dev/null 2>&1; then
            local _ch_pt="8088"
            [[ -f /etc/chisel/port ]] && _ch_pt=$(cat /etc/chisel/port 2>/dev/null)
            echo -e "\033[1;32mSERVICIO: \033[1;33mCHISEL \033[1;32mPUERTO: \033[1;37m$_ch_pt\033[0m"
        fi

        # 11. BHTTP
        local _b_pts; _b_pts=$(scan_bhttp_ports)
        local _bx_pt; _bx_pt=$(scan_xhttp_port)
        if [[ -n "$_b_pts" || -n "$_bx_pt" ]]; then
            local _b_dsp=""
            [[ -n "$_b_pts" ]] && _b_dsp="BHTTP: ${_b_pts}"
            [[ -n "$_bx_pt" ]] && _b_dsp="${_b_dsp:+${_b_dsp} | }TLS: ${_bx_pt}"
            echo -e "\033[1;32mSERVICIO: \033[1;33mBHTTP \033[1;32mPUERTOS: \033[1;37m$_b_dsp\033[0m"
        fi

        # 12. HCR RELAY (HTTP CUSTOM RELAY)
        local _hcr_pts; _hcr_pts=$(scan_hcr_ports)
        if [[ -n "$_hcr_pts" ]]; then
            echo -e "\033[1;32mSERVICIO: \033[1;33mHCR RELAY \033[1;32mPUERTOS: \033[1;37m$_hcr_pts\033[0m"
        fi

        # 13. UDP CUSTOM
        if systemctl is-active --quiet udp-custom 2>/dev/null || pgrep -x udp-custom >/dev/null 2>&1; then
            local _udpc_pt; _udpc_pt=$(scan_udpcustom_port)
            echo -e "\033[1;32mSERVICIO: \033[1;33mUDP CUSTOM \033[1;32mPUERTO: \033[1;37m${_udpc_pt:-7100}/udp\033[0m"
        fi

        echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"

        local sts_ssh sts_socks sts_ssl sts_drop sts_v2ray sts_slow sts_hyst sts_hy2 sts_trojan sts_badvpn sts_ovpn sts_ws sts_sslh sts_squid sts_chisel sts_bhttp sts_hcr sts_udpc
        sts_ssh="\033[1;32mo\033[0m"
        (pgrep -f 'proxy\.py|wsproxy\.py' >/dev/null 2>&1 || [[ -n "$sks_p" ]]) && sts_socks="\033[1;32mo\033[0m" || sts_socks="\033[1;31mx\033[0m"
        (systemctl is-active --quiet stunnel4 2>/dev/null || pgrep -f 'stunnel' >/dev/null 2>&1 || [[ -n "$ssl_p" ]]) && sts_ssl="\033[1;32mo\033[0m" || sts_ssl="\033[1;31mx\033[0m"
        (pgrep -f 'dropbear' >/dev/null 2>&1 || [[ -n "$drp_p" ]]) && sts_drop="\033[1;32mo\033[0m" || sts_drop="\033[1;31mx\033[0m"
        
        local v2_title="V2RAY"
        local sts_v2ray="\033[1;31mx\033[0m"
        if [[ $is_v2_active -eq 1 ]]; then
            sts_v2ray="\033[1;32mo\033[0m"
            v2_title="${v2_engine}"
        fi

        (systemctl is-active --quiet slowdns 2>/dev/null || pgrep -x dnstt-server >/dev/null 2>&1 || pgrep -f 'dnstt-server' >/dev/null 2>&1) && sts_slow="\033[1;32mo\033[0m" || sts_slow="\033[1;31mx\033[0m"
        (systemctl is-active --quiet hysteria-server 2>/dev/null || pgrep -x hysteria1 >/dev/null 2>&1 || pgrep -x hysteria >/dev/null 2>&1) && sts_hyst="\033[1;32mo\033[0m" || sts_hyst="\033[1;31mx\033[0m"
        (systemctl is-active --quiet hysteria2 2>/dev/null || pgrep -x hysteria2 >/dev/null 2>&1) && sts_hy2="\033[1;32mo\033[0m" || sts_hy2="\033[1;31mx\033[0m"
        pgrep -f 'trojan' >/dev/null 2>&1 && sts_trojan="\033[1;32mo\033[0m" || sts_trojan="\033[1;31mx\033[0m"
        (systemctl is-active --quiet badvpn-udpgw 2>/dev/null || pgrep -x badvpn-udpgw >/dev/null 2>&1 || pgrep -x udpvpn >/dev/null 2>&1) && sts_badvpn="\033[1;32mo\033[0m" || sts_badvpn="\033[1;31mx\033[0m"
        pgrep -f 'openvpn' >/dev/null 2>&1 && sts_ovpn="\033[1;32mo\033[0m" || sts_ovpn="\033[1;31mx\033[0m"
        pgrep -f '/etc/SSHPlus/wsproxy.py' >/dev/null 2>&1 && sts_ws="\033[1;32mo\033[0m" || sts_ws="\033[1;31mx\033[0m"
        pgrep -f 'sslh' >/dev/null 2>&1 && sts_sslh="\033[1;32mo\033[0m" || sts_sslh="\033[1;31mx\033[0m"
        (pgrep -f 'squid' >/dev/null 2>&1 || [[ -n "$sqd_p" ]]) && sts_squid="\033[1;32mo\033[0m" || sts_squid="\033[1;31mx\033[0m"
        (systemctl is-active --quiet chisel 2>/dev/null || pgrep -f 'chisel' >/dev/null 2>&1) && sts_chisel="\033[1;32mo\033[0m" || sts_chisel="\033[1;31mx\033[0m"
        (systemctl is-active --quiet bhttp 2>/dev/null || systemctl is-active --quiet bhttp-tls 2>/dev/null || pgrep -f 'bhttp-server|xhttp-server|bilola' >/dev/null 2>&1 || [[ -n "$_b_pts" || -n "$_bx_pt" ]]) && sts_bhttp="\033[1;32mo\033[0m" || sts_bhttp="\033[1;31mx\033[0m"
        (systemctl is-active --quiet hcr-* 2>/dev/null || pgrep -f 'hcr-server' >/dev/null 2>&1 || [[ -n "$_hcr_pts" ]]) && sts_hcr="\033[1;32mo\033[0m" || sts_hcr="\033[1;31mx\033[0m"
        (systemctl is-active --quiet udp-custom 2>/dev/null || pgrep -x udp-custom >/dev/null 2>&1) && sts_udpc="\033[1;32mo\033[0m" || sts_udpc="\033[1;31mx\033[0m"

        printf "  %b[1]%b  > OPENSSH         %b    %b[10]%b > BADVPN             %b\n" "$SSHPLUS_NUM" "$SCOLOR" "$sts_ssh" "$SSHPLUS_NUM" "$SCOLOR" "$sts_badvpn"
        printf "  %b[2]%b  > PROXY SOCKS     %b    %b[11]%b > OPENVPN            %b\n" "$SSHPLUS_NUM" "$SCOLOR" "$sts_socks" "$SSHPLUS_NUM" "$SCOLOR" "$sts_ovpn"
        printf "  %b[3]%b  > SSL TUNNEL      %b    %b[12]%b > WEBSOCKET-CORRECT   %b\n" "$SSHPLUS_NUM" "$SCOLOR" "$sts_ssl" "$SSHPLUS_NUM" "$SCOLOR" "$sts_ws"
        printf "  %b[4]%b  > DROPBEAR        %b    %b[13]%b > SSLH MULTIPLEX      %b\n" "$SSHPLUS_NUM" "$SCOLOR" "$sts_drop" "$SSHPLUS_NUM" "$SCOLOR" "$sts_sslh"
        printf "  %b[5]%b  > %-15s %b    %b[14]%b > SQUID PROXY         %b\n" "$SSHPLUS_NUM" "$SCOLOR" "$v2_title" "$sts_v2ray" "$SSHPLUS_NUM" "$SCOLOR" "$sts_squid"
        printf "  %b[6]%b  > SLOWDNS         %b    %b[15]%b > CHISEL              %b\n" "$SSHPLUS_NUM" "$SCOLOR" "$sts_slow" "$SSHPLUS_NUM" "$SCOLOR" "$sts_chisel"
        printf "  %b[7]%b  > UDP CRIS        %b    %b[16]%b > BHTTP (BHP1/TLS)    %b\n" "$SSHPLUS_NUM" "$SCOLOR" "$sts_hyst" "$SSHPLUS_NUM" "$SCOLOR" "$sts_bhttp"
        printf "  %b[8]%b  > UDP HYSTERIA v2 %b    %b[17]%b > HCR RELAY           %b\n" "$SSHPLUS_NUM" "$SCOLOR" "$sts_hy2" "$SSHPLUS_NUM" "$SCOLOR" "$sts_hcr"
        printf "  %b[9]%b  > UDP CUSTOM      %b    %b[18]%b > TROJAN-GO           %b\n" "$SSHPLUS_NUM" "$SCOLOR" "$sts_udpc" "$SSHPLUS_NUM" "$SCOLOR" "$sts_trojan"
        printf "  %b[19]%b > EXPORTAR PARA GEN     %b[0]%b  > VOLVER\n" "$SSHPLUS_NUM" "$SCOLOR" "$SSHPLUS_NUM" "$SCOLOR"
        echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
        echo -ne "${SSHPLUS_CYAN}Opcion:${SCOLOR} "
        read -r proto_opt

        case "$proto_opt" in
            1|01) fun_openssh ;;
            2|02) fun_socks ;;
            3|03) inst_ssl ;;
            4|04) fun_drop ;;
            5|05)
                if [[ -x /bin/v2raymanager || -x /usr/bin/v2raymanager ]]; then
                    v2raymanager
                elif [[ -f /opt/ssh-cris/Modulos/v2raymanager ]]; then
                    bash /opt/ssh-cris/Modulos/v2raymanager
                else
                    clear
                    echo -e "\033[1;32mDescargando e iniciando V2Ray Manager...\033[0m"
                    curl -fsSL https://raw.githubusercontent.com/soportecrisdev/SCRIP_CRISDEV/main/Modulos/v2raymanager -o /bin/v2raymanager 2>/dev/null
                    chmod +x /bin/v2raymanager 2>/dev/null || true
                    v2raymanager
                fi
                ;;
            6|06) slow_setup ;;
            7|07) menu_udp_cris ;;
            8|08) menu_hysteria2 ;;
            9|09) menu_udpcustom ;;
            10) menub ;;
            11)
                clear
                echo -e "\033[1;32mInstalador OpenVPN\033[0m"
                apt-get install -y openvpn 2>/dev/null || true
                pause
                ;;
            12) fun_socks ;;
            13)
                clear
                echo -e "\033[1;32mSSLH Multiplex\033[0m"
                apt-get install -y sslh 2>/dev/null || true
                pause
                ;;
            14) fun_squid ;;
            15) fun_chisel ;;
            16) menu_bhttp ;;
            17)
                [[ -f /bin/hcr-manager && ! -s /bin/hcr-manager ]] && rm -f /bin/hcr-manager
                if [[ -s /bin/hcr-manager && -x /bin/hcr-manager ]]; then
                    /bin/hcr-manager
                elif [[ -s /usr/bin/hcr-manager && -x /usr/bin/hcr-manager ]]; then
                    /usr/bin/hcr-manager
                elif [[ -f /opt/ssh-cris/Modulos/hcr-manager ]]; then
                    bash /opt/ssh-cris/Modulos/hcr-manager
                else
                    clear
                    echo -e "\033[1;32mDescargando e iniciando HCR Manager...\033[0m"
                    curl -fsSL https://raw.githubusercontent.com/soportecrisdev/SCRIP_CRISDEV/main/Modulos/hcr-manager -o /bin/hcr-manager 2>/dev/null || \
                    wget -q "https://raw.githubusercontent.com/soportecrisdev/SCRIP_CRISDEV/main/Modulos/hcr-manager" -O /bin/hcr-manager 2>/dev/null || true
                    chmod +x /bin/hcr-manager 2>/dev/null || true
                    if [[ -s /bin/hcr-manager ]]; then
                        /bin/hcr-manager
                    else
                        echo -e "\033[1;31mError al descargar HCR Manager. Verifique conexion o actualice el repositorio.\033[0m"
                        sleep 2
                    fi
                fi
                ;;
            18)
                clear
                echo -e "\033[1;33mTrojan-Go integrado via motor Xray (Puerto 443 / 8443).\033[0m"
                pause
                ;;
            19) exportar_servidor_gen ;;
            0|00) return ;;
            *) echo -e "\n\033[1;31mOpción inválida!\033[0m"; sleep 1 ;;
        esac
    done
}

# ─────────────────────────────────────────────────────────────────────────────
#  ADMINISTRACIÓN DE USUARIOS
# ─────────────────────────────────────────────────────────────────────────────
menu_users() {
    while true; do
        clear
        local stats_str; stats_str=$(get_users_stats)
        local u_total; u_total=$(echo "$stats_str" | cut -d: -f1)
        local u_active; u_active=$(echo "$stats_str" | cut -d: -f2)
        local u_expired; u_expired=$(echo "$stats_str" | cut -d: -f3)
        local u_online; u_online=$(echo "$stats_str" | cut -d: -f4)

        echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
        echo -e "                   ${BLUE}ADMINISTRAR USUARIOS${SCOLOR}"
        echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
        printf " ${WHITE}Creados: ${GREEN}%-4s${WHITE} | Activos: ${GREEN}%-4s${WHITE} | Vencidos: ${RED}%-4s${WHITE} | En Línea: ${GREEN}%-4s${NC}\n" "$u_total" "$u_active" "$u_expired" "$u_online"
        echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
        echo -e "  ${SSHPLUS_NUM}[1]${SCOLOR} \033[1;37m> CREAR USUARIO\033[0m          ${SSHPLUS_NUM}[6]${SCOLOR}  \033[1;37m> CAMBIAR LIMITE\033[0m"
        echo -e "  ${SSHPLUS_NUM}[2]${SCOLOR} \033[1;37m> CREAR PRUEBA\033[0m           ${SSHPLUS_NUM}[7]${SCOLOR}  \033[1;37m> CAMBIAR CLAVE\033[0m"
        echo -e "  ${SSHPLUS_NUM}[3]${SCOLOR} \033[1;37m> ELIMINAR USUARIO\033[0m       ${SSHPLUS_NUM}[8]${SCOLOR}  \033[1;37m> INFORME DE USUARIOS\033[0m"
        echo -e "  ${SSHPLUS_NUM}[4]${SCOLOR} \033[1;37m> MONITOR ONLINE\033[0m         ${SSHPLUS_NUM}[9]${SCOLOR}  \033[1;37m> ELIMINAR CADUCADOS\033[0m"
        echo -e "  ${SSHPLUS_NUM}[5]${SCOLOR} \033[1;37m> CAMBIAR FECHA\033[0m          ${SSHPLUS_NUM}[10]${SCOLOR} \033[1;37m> TOKEN HTTP CONEXION\033[0m"
        echo -e "                             ${SSHPLUS_NUM}[0]${SCOLOR}  \033[1;37m> VOLVER\033[0m"
        echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
        echo -ne "${SSHPLUS_CYAN}Opcion:${SCOLOR} "
        read -r u_opt

        case "$u_opt" in
            1|01) crear_usuario ;;
            2|02) crear_prueba ;;
            3|03) eliminar_usuario ;;
            4|04) monitor_conexiones ;;
            5|05) renovar_usuario ;;
            6|06) cambiar_limite ;;
            7|07) cambiar_clave ;;
            8|08) listar_usuarios ;;
            9|09) eliminar_caducados ;;
            10) generar_token_http_conexion ;;
            0|00) return ;;
            *) echo -e "\n\033[1;31mOpción inválida!\033[0m"; sleep 1 ;;
        esac
    done
}

crear_usuario() {
    clear
    echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
    echo -e "                   ${BLUE}CREAR NUEVO USUARIO${SCOLOR}"
    echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
    echo -ne "\033[1;32mNombre de usuario\033[1;37m: "
    read -r username
    [[ -z "$username" ]] && return

    if id "$username" >/dev/null 2>&1 || grep -q "^$username:" /etc/passwd 2>/dev/null; then
        echo -e "\n\033[1;31mEl usuario '$username' ya existe."
        pause; return
    fi

    echo -ne "\033[1;32mContraseña\033[1;37m: "
    read -r password
    [[ -z "$password" ]] && return

    echo -ne "\033[1;32mDías de duración (ej: 30)\033[1;37m: "
    read -r days
    [[ ! "$days" =~ ^[0-9]+$ ]] && days=30

    echo -ne "\033[1;32mLímite de conexiones simultáneas (ej: 1 o 2)\033[1;37m: "
    read -r limit
    [[ ! "$limit" =~ ^[0-9]+$ ]] && limit=1

    local exp_date
    exp_date=$(date -d "+$days days" "+%Y-%m-%d" 2>/dev/null || date "+%Y-%m-%d")

    useradd -M -s /bin/false -e "$exp_date" "$username" >/dev/null 2>&1 || useradd -M -s /bin/false "$username"
    echo "$username:$password" | chpasswd

    # Guardar contraseña legible para SSH-Plus y sincronización
    mkdir -p /etc/SSHPlus/senha /root
    echo "$password" > "/etc/SSHPlus/senha/$username"
    sed -i "/^$username /d" /root/usuarios.db 2>/dev/null || true
    echo "$username $limit" >> /root/usuarios.db

    sed -i "/^$username:/d" "$USER_DATABASE" 2>/dev/null || true
    echo "$username:$limit:$exp_date:$password" >> "$USER_DATABASE"
    hyst_sync_users >/dev/null 2>&1 || true

    local ip; ip=$(get_public_ip)
    echo -e "\n\033[1;32mUSUARIO CREADO EXITOSAMENTE!\033[0m"
    echo "────────────────────────────────────────────────────────────"
    echo -e "${WHITE}• Servidor:   ${GREEN}$ip${NC}"
    echo -e "${WHITE}• Usuario:    ${YELLOW}$username${NC}"
    echo -e "${WHITE}• Contraseña: ${YELLOW}$password${NC}"
    echo -e "${WHITE}• Vence el:   ${CYAN}$exp_date ($days días)${NC}"
    echo -e "${WHITE}• Límite:     ${GREEN}$limit conexión(es)${NC}"
    echo "────────────────────────────────────────────────────────────"
    pause
}

crear_prueba() {
    clear
    echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
    echo -e "              ${BLUE}CREAR USUARIO DE PRUEBA (TRIAL)${SCOLOR}"
    echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
    echo -ne "\033[1;32mHoras de duración (ej: 2 o 4, default 2)\033[1;37m: "
    read -r hours
    [[ ! "$hours" =~ ^[0-9]+$ ]] && hours=2

    local rand_id=$(( RANDOM % 9000 + 1000 ))
    local username="test_${rand_id}"
    local password=$(( RANDOM % 9000 + 1000 ))
    local exp_date; exp_date=$(date -d "+$hours hours" "+%Y-%m-%d" 2>/dev/null || date "+%Y-%m-%d")

    useradd -M -s /bin/false "$username" 2>/dev/null || useradd -s /bin/false "$username"
    echo "$username:$password" | chpasswd

    mkdir -p /etc/SSHPlus/senha /root
    echo "$password" > "/etc/SSHPlus/senha/$username"
    echo "$username 1" >> /root/usuarios.db
    sed -i "/^$username:/d" "$USER_DATABASE" 2>/dev/null || true
    echo "$username:1:$exp_date:$password" >> "$USER_DATABASE"
    hyst_sync_users >/dev/null 2>&1 || true

    local ip; ip=$(get_public_ip)
    echo -e "\n\033[1;32mUSUARIO DE PRUEBA CREADO!\033[0m"
    echo "────────────────────────────────────────────────────────────"
    echo -e "${WHITE}• Usuario:    ${YELLOW}$username${NC}"
    echo -e "${WHITE}• Contraseña: ${YELLOW}$password${NC}"
    echo -e "${WHITE}• Duración:   ${CYAN}$hours hora(s)${NC}"
    echo -e "${WHITE}• Servidor:   ${GREEN}$ip${NC}"
    echo "────────────────────────────────────────────────────────────"
    pause
}

eliminar_usuario() {
    clear
    echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
    echo -e "                   ${BLUE}ELIMINAR USUARIO${SCOLOR}"
    echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
    echo -ne "\033[1;32mNombre de usuario a eliminar\033[1;37m: "
    read -r username
    [[ -z "$username" ]] && return

    pkill -u "$username" 2>/dev/null || true
    userdel -f "$username" 2>/dev/null || true
    rm -f "/etc/SSHPlus/senha/$username" 2>/dev/null || true
    sed -i "/^$username /d" /root/usuarios.db 2>/dev/null || true
    sed -i "/^$username:/d" "$USER_DATABASE" 2>/dev/null || true
    hyst_sync_users >/dev/null 2>&1 || true
    echo -e "\n\033[1;32mUsuario '$username' eliminado con éxito!\033[0m"
    pause
}

monitor_conexiones() {
    clear
    echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
    echo -e "               ${BLUE}MONITOR DE CONEXIONES ONLINE${SCOLOR}"
    echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
    printf "%-18s %-12s %-20s\n" "USUARIO" "PID" "DESDE"
    echo "────────────────────────────────────────────────────────────"
    who 2>/dev/null | grep -E "pts|sshd" | awk '{printf "%-18s %-12s %-20s\n", $1, $2, $5}' || echo "No hay conexiones activas"
    echo "────────────────────────────────────────────────────────────"
    pause
}

renovar_usuario() {
    clear
    echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
    echo -e "                   ${BLUE}CAMBIAR FECHA / RENOVAR${SCOLOR}"
    echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
    echo -ne "\033[1;32mNombre de usuario\033[1;37m: "
    read -r username
    [[ -z "$username" ]] && return

    echo -ne "\033[1;32mNuevos días a sumar (ej: 30)\033[1;37m: "
    read -r days
    [[ ! "$days" =~ ^[0-9]+$ ]] && days=30

    local new_exp
    new_exp=$(date -d "+$days days" "+%Y-%m-%d" 2>/dev/null || date "+%Y-%m-%d")
    chage -E "$new_exp" "$username" 2>/dev/null || true

    local limit; limit=$(get_user_limit "$username")
    local pass; pass=$(get_user_password "$username")
    sed -i "/^$username:/d" "$USER_DATABASE" 2>/dev/null || true
    echo "$username:${limit:-1}:$new_exp:$pass" >> "$USER_DATABASE"

    echo -e "\n\033[1;32mUsuario '$username' renovado hasta $new_exp\033[0m"
    pause
}

cambiar_limite() {
    clear
    echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
    echo -e "                   ${BLUE}CAMBIAR LIMITE DE CONEXIONES${SCOLOR}"
    echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
    echo -ne "\033[1;32mNombre de usuario\033[1;37m: "
    read -r username
    [[ -z "$username" ]] && return

    echo -ne "\033[1;32mNuevo límite de conexiones (ej: 1, 2, 3)\033[1;37m: "
    read -r limit
    [[ ! "$limit" =~ ^[0-9]+$ ]] && limit=1

    sed -i "/^$username /d" /root/usuarios.db 2>/dev/null || true
    echo "$username $limit" >> /root/usuarios.db

    local exp="2030-01-01"
    local pass; pass=$(get_user_password "$username")
    if [[ -f "$USER_DATABASE" ]] && grep -q "^$username:" "$USER_DATABASE"; then
        exp=$(grep "^$username:" "$USER_DATABASE" | cut -d: -f3 || echo "2030-01-01")
        sed -i "/^$username:/d" "$USER_DATABASE"
    fi
    echo "$username:$limit:$exp:$pass" >> "$USER_DATABASE"
    echo -e "\n\033[1;32mLímite de '$username' actualizado a $limit conexión(es)\033[0m"
    pause
}

cambiar_clave() {
    clear
    echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
    echo -e "                   ${BLUE}CAMBIAR CONTRASEÑA${SCOLOR}"
    echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
    echo -ne "\033[1;32mNombre de usuario\033[1;37m: "
    read -r username
    [[ -z "$username" ]] && return

    echo -ne "\033[1;32mNueva contraseña\033[1;37m: "
    read -r password
    [[ -z "$password" ]] && return

    echo "$username:$password" | chpasswd
    mkdir -p /etc/SSHPlus/senha
    echo "$password" > "/etc/SSHPlus/senha/$username"

    local limit; limit=$(get_user_limit "$username")
    local exp="2030-01-01"
    if [[ -f "$USER_DATABASE" ]] && grep -q "^$username:" "$USER_DATABASE"; then
        exp=$(grep "^$username:" "$USER_DATABASE" | cut -d: -f3 || echo "2030-01-01")
        sed -i "/^$username:/d" "$USER_DATABASE"
    fi
    echo "$username:$limit:$exp:$password" >> "$USER_DATABASE"
    hyst_sync_users >/dev/null 2>&1 || true

    echo -e "\n\033[1;32mContraseña de '$username' cambiada exitosamente!\033[0m"
    pause
}

listar_usuarios() {
    clear
    echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
    echo -e "                   ${BLUE}INFORME DE USUARIOS${SCOLOR}"
    echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
    
    local all_users=()
    mapfile -t all_users < <(get_user_list)
    local total=${#all_users[@]}
    local stats_str; stats_str=$(get_users_stats)
    local online; online=$(echo "$stats_str" | cut -d: -f4)
    local expired; expired=$(echo "$stats_str" | cut -d: -f3)

    echo -e "${WHITE}  TOTAL: ${GREEN}${total}${WHITE}  |  EN LINEA: ${GREEN}${online}${WHITE}  |  VENCIDOS: ${RED}${expired}${NC}"
    echo "────────────────────────────────────────────────────────────"
    printf "%-4s %-16s %-12s %-8s %s\n" "#" "USUARIO" "CONTRASENA" "LIMITE" "VENCIMIENTO"
    echo "────────────────────────────────────────────────────────────"

    local i=1
    for u in "${all_users[@]}"; do
        [[ -z "$u" ]] && continue
        local pass; pass=$(get_user_password "$u")
        local limit; limit=$(get_user_limit "$u")
        local days; days=$(get_user_days_remaining "$u")
        local col_days="${GREEN}$days${NC}"
        [[ "$days" == "Vencido" ]] && col_days="${RED}$days${NC}"
        printf "%-4s %-16s %-12s %-8s %b\n" "$i" "$u" "$pass" "$limit" "$col_days"
        ((i++))
    done
    if [[ $total -eq 0 ]]; then
        echo -e "  ${YELLOW}No hay usuarios registrados en el sistema.${NC}"
    fi
    echo "────────────────────────────────────────────────────────────"
    pause
}

eliminar_caducados() {
    clear
    echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
    echo -e "                   ${BLUE}ELIMINAR USUARIOS CADUCADOS${SCOLOR}"
    echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
    local count=0
    local all_users=()
    mapfile -t all_users < <(get_user_list)

    for u in "${all_users[@]}"; do
        [[ -z "$u" ]] && continue
        local st; st=$(get_user_days_remaining "$u")
        if [[ "$st" == "Vencido" ]]; then
            pkill -u "$u" 2>/dev/null || true
            userdel -f "$u" 2>/dev/null || true
            rm -f "/etc/SSHPlus/senha/$u" 2>/dev/null || true
            sed -i "/^$u /d" /root/usuarios.db 2>/dev/null || true
            sed -i "/^$u:/d" "$USER_DATABASE" 2>/dev/null || true
            ((count++))
            echo -e " • Usuario vencido eliminado: \033[1;31m$u\033[0m"
        fi
    done
    hyst_sync_users >/dev/null 2>&1 || true
    echo -e "\n\033[1;32mTotal de usuarios caducados eliminados: $count\033[0m"
    pause
}

generar_token_http_conexion() {
    clear
    echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
    echo -e "              ${BLUE}TOKEN EXCLUSIVO HTTP CONEXION${SCOLOR}"
    echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
    echo -ne "\033[1;32mNombre de usuario\033[1;37m: "
    read -r username
    [[ -z "$username" ]] && return

    echo -ne "\033[1;32mContraseña\033[1;37m: "
    read -r password
    [[ -z "$password" ]] && return

    local ip; ip=$(get_public_ip)
    local bhttp_ports_arr
    read -r -a bhttp_ports_arr <<< "$(scan_bhttp_ports)"
    local bport="${bhttp_ports_arr[0]:-8080}"

    local uport="36712"
    local obfs_val="crisdev"
    local auth_val="crisdev"
    if [[ -f /etc/hysteria/config.json ]]; then
        uport=$(grep -o '"listen": "[^"]*"' /etc/hysteria/config.json 2>/dev/null | cut -d: -f3 | tr -d '":, ' || echo "36712")
        obfs_val=$(grep -o '"obfs": "[^"]*"' /etc/hysteria/config.json 2>/dev/null | cut -d: -f2 | tr -d '":, ' || echo "crisdev")
        auth_val=$(grep -o '"password": "[^"]*"' /etc/hysteria/config.json 2>/dev/null | cut -d: -f2 | tr -d '":, ' || echo "crisdev")
    fi

    local raw_token
    raw_token="SERVER=${ip};SSH=22;SSL=443;BHTTP=${bport};UDP=${uport};OBFS=${obfs_val};AUTH=${auth_val};USER=${username};PASS=${password};APP=HTTP_CONEXION"
    local b64_token
    b64_token=$(printf '%s' "$raw_token" | base64 | tr -d '\n\r')

    echo -e "\n\033[1;32mTOKEN GENERADO PARA LA APP:\033[0m"
    echo "────────────────────────────────────────────────────────────"
    echo -e "\033[1;33mHC://${b64_token}\033[0m"
    echo "────────────────────────────────────────────────────────────"
    echo -e "${WHITE}Copia este token y pégalo directamente en HTTP Conexión.${NC}"
    pause
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
        obfs_val=$(grep -o '"obfs": "[^"]*"' /etc/hysteria/config.json 2>/dev/null | cut -d: -f2 | tr -d '":, ' || echo "crisdev")
        auth_val=$(grep -o '"password": "[^"]*"' /etc/hysteria/config.json 2>/dev/null | cut -d: -f2 | tr -d '":, ' || echo "crisdev")
    fi

    local slowdns_ns; slowdns_ns=$(cat /etc/slowdns/ns.txt 2>/dev/null || echo "No configurado")
    local slowdns_pub; slowdns_pub=$(cat /etc/slowdns/server.pub 2>/dev/null || echo "No configurado")

    echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
    echo -e "           ${BLUE}DATOS PARA IMPORTAR EN EL GEN (APP ANDROID)${SCOLOR}"
    echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
    printf " • IP Servidor:         ${GREEN}%-35s${NC}\n" "$ip"
    printf " • Puerto SSH:          ${GREEN}%-35s${NC}\n" "22"
    printf " • Puerto SSL:          ${GREEN}%-35s${NC}\n" "443"
    printf " • BHTTP Relay:         ${GREEN}%-35s${NC}\n" "Principal: $bhttp_main_port (Todos: $bhttp_all)"
    printf " • UDP CRIS (Hysteria): ${GREEN}%-35s${NC}\n" "$uport (OBFS: $obfs_val | Auth: $auth_val)"
    printf " • BadVPN UDPGW:        ${GREEN}%-35s${NC}\n" "7300"
    printf " • SlowDNS NameServer:  ${GREEN}%-35s${NC}\n" "${slowdns_ns}"
    printf " • SlowDNS Clave Pub:   ${GREEN}%-35s${NC}\n" "${slowdns_pub}"
    echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
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
#  SUBMENÚS COMPLETOS DE SISTEMA Y HERRAMIENTAS
# ─────────────────────────────────────────────────────────────────────────────
menu_banner() {
    if [[ -x /bin/banner || -x /usr/bin/banner ]]; then
        banner
        return
    fi
    clear
    echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
    echo -e "                 ${BLUE}CONFIGURACION DE BANNER SSH${SCOLOR}"
    echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
    echo -e "${WHITE}Banner actual en /etc/issue.net:${NC}"
    echo -e "${YELLOW}------------------------------------------------------------${NC}"
    cat /etc/issue.net 2>/dev/null || echo "(Vacío)"
    echo -e "${YELLOW}------------------------------------------------------------${NC}"
    echo -e "\n${GREEN}[1]${WHITE} > Escribir Nuevo Banner"
    echo -e "${RED}[0]${WHITE} > Volver"
    echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
    echo -ne "${SSHPLUS_CYAN}Opcion:${SCOLOR} "
    read -r b_opt
    case "$b_opt" in
        1)
            echo -ne "\n\033[1;32mIngresa el nuevo texto para el Banner: \033[1;37m"
            read -r new_banner
            [[ -z "$new_banner" ]] && return
            echo "$new_banner" > /etc/issue.net
            sed -i 's/^#*Banner .*/Banner \/etc\/issue.net/' /etc/ssh/sshd_config 2>/dev/null || true
            grep -q '^Banner /etc/issue.net' /etc/ssh/sshd_config || echo 'Banner /etc/issue.net' >> /etc/ssh/sshd_config
            systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
            echo -e "\n\033[1;32m[✔] Banner SSH actualizado con éxito!\033[0m"
            pause
            ;;
        *) return ;;
    esac
}

menu_checkusers() {
    while true; do
        clear
        echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
        echo -e "                     ${BLUE}MENU CHECKUSERS${SCOLOR}"
        echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
        echo -e "  ${SSHPLUS_NUM}[1]${SCOLOR} \033[1;37m> CHECKUSER MULTI-PUERTO (Puerto 5000 / 80 / 8080)\033[0m"
        echo -e "  ${SSHPLUS_NUM}[2]${SCOLOR} \033[1;37m> CHECKUSER GLTUNNEL\033[0m"
        echo -e "  ${SSHPLUS_NUM}[0]${SCOLOR} \033[1;37m> VOLVER\033[0m"
        echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
        echo -ne "${SSHPLUS_CYAN}Opcion:${SCOLOR} "
        read -r chk_opt
        case "$chk_opt" in
            1|01)
                if [[ -x /bin/initcheck || -x /usr/bin/initcheck ]]; then
                    initcheck
                else
                    clear
                    echo -e "\033[1;32mIniciando CheckUser en puerto 5000...\033[0m"
                    screen -dmS checkuser python3 -m http.server 5000 2>/dev/null || true
                    echo -e "\033[1;32m[✔] CheckUser activo en puerto 5000.\033[0m"
                    pause
                fi
                ;;
            2|02)
                if [[ -x /bin/gltunnel || -x /usr/bin/gltunnel ]]; then
                    gltunnel
                else
                    clear
                    echo -e "\033[1;32mCheckUser GLTunnel listo.\033[0m"
                    pause
                fi
                ;;
            0|00) break ;;
            *) echo -e "\n\033[1;31mOpción inválida!\033[0m"; sleep 1 ;;
        esac
    done
}

menu_network_security() {
    while true; do
        clear
        echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
        echo -e "                   ${BLUE}RED Y SEGURIDAD${SCOLOR}"
        echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
        echo -e "  ${SSHPLUS_NUM}[1]${SCOLOR} \033[1;37m> FIREWALL PRO (Bloqueo de Ataques y Puertos)\033[0m"
        echo -e "  ${SSHPLUS_NUM}[2]${SCOLOR} \033[1;37m> SPEEDTEST (Test de Velocidad VPS)\033[0m"
        echo -e "  ${SSHPLUS_NUM}[3]${SCOLOR} \033[1;37m> MONITOR DE TRAFICO DE RED EN VIVO\033[0m"
        echo -e "  ${SSHPLUS_NUM}[0]${SCOLOR} \033[1;37m> VOLVER\033[0m"
        echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
        echo -ne "${SSHPLUS_CYAN}Opcion:${SCOLOR} "
        read -r net_opt
        case "$net_opt" in
            1|01)
                if [[ -x /bin/fr || -x /usr/bin/fr ]]; then
                    fr
                else
                    clear
                    echo -e "\033[1;33mEstado del Firewall:\033[0m"
                    ufw status verbose 2>/dev/null || iptables -L -n -v
                    pause
                fi
                ;;
            2|02)
                if [[ -x /bin/speedtest || -x /usr/bin/speedtest ]]; then
                    speedtest
                else
                    clear
                    echo -e "\033[1;32mEjecutando Speedtest...\033[0m"
                    speedtest-cli --simple 2>/dev/null || echo -e "Instalando speedtest-cli: apt-get install -y speedtest-cli"
                    pause
                fi
                ;;
            3|03)
                if [[ -x /bin/totaltraffic || -x /usr/bin/totaltraffic ]]; then
                    totaltraffic
                else
                    clear
                    echo -e "\033[1;32mTráfico de interfaces de red:\033[0m"
                    ip -s link
                    pause
                fi
                ;;
            0|00) break ;;
            *) echo -e "\n\033[1;31mOpción inválida!\033[0m"; sleep 1 ;;
        esac
    done
}

ecualizar_horario() {
    clear
    local cur_tz
    cur_tz=$(cat /etc/timezone 2>/dev/null || timedatectl 2>/dev/null | grep "Time zone" | awk '{print $3}' || echo "UTC")
    local cur_time
    cur_time=$(date '+%Y-%m-%d %H:%M:%S (%Z)')

    echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
    echo -e "        ${BLUE}⚡ ECUALIZAR HORARIO / ZONA HORARIA DE LA VPS ⚡${SCOLOR}"
    echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
    echo -e "  ${WHITE}Hora Actual del Servidor : ${YELLOW}${cur_time}${NC}"
    echo -e "  ${WHITE}Zona Horaria Actual      : ${GREEN}${cur_tz}${NC}"
    echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
    echo -e "  ${SSHPLUS_NUM}[1]${SCOLOR}  \033[1;37m> America/Bogota       (Colombia, Perú, Ecuador, Panamá - UTC-5)\033[0m"
    echo -e "  ${SSHPLUS_NUM}[2]${SCOLOR}  \033[1;37m> America/Mexico_City  (México Centro - UTC-6)\033[0m"
    echo -e "  ${SSHPLUS_NUM}[3]${SCOLOR}  \033[1;37m> America/Caracas      (Venezuela - UTC-4)\033[0m"
    echo -e "  ${SSHPLUS_NUM}[4]${SCOLOR}  \033[1;37m> America/Santiago     (Chile - UTC-3/UTC-4)\033[0m"
    echo -e "  ${SSHPLUS_NUM}[5]${SCOLOR}  \033[1;37m> America/Argentina/Buenos_Aires (Argentina - UTC-3)\033[0m"
    echo -e "  ${SSHPLUS_NUM}[6]${SCOLOR}  \033[1;37m> America/La_Paz       (Bolivia - UTC-4)\033[0m"
    echo -e "  ${SSHPLUS_NUM}[7]${SCOLOR}  \033[1;37m> America/Lima         (Perú - UTC-5)\033[0m"
    echo -e "  ${SSHPLUS_NUM}[8]${SCOLOR}  \033[1;37m> America/Santo_Domingo (Rep. Dominicana - UTC-4)\033[0m"
    echo -e "  ${SSHPLUS_NUM}[9]${SCOLOR}  \033[1;37m> America/Guatemala    (Centroamérica - UTC-6)\033[0m"
    echo -e "  ${SSHPLUS_NUM}[10]${SCOLOR} \033[1;37m> America/Sao_Paulo   (Brasil - UTC-3)\033[0m"
    echo -e "  ${SSHPLUS_NUM}[11]${SCOLOR} \033[1;37m> Europe/Madrid       (España - UTC+1)\033[0m"
    echo -e "  ${SSHPLUS_NUM}[12]${SCOLOR} \033[1;37m> America/New_York    (USA Este - UTC-5)\033[0m"
    echo -e "  ${SSHPLUS_NUM}[13]${SCOLOR} \033[1;37m> Mantener zona actual (${cur_tz})\033[0m"
    echo -e "  ${SSHPLUS_NUM}[14]${SCOLOR} \033[1;37m> Ingresar zona personalizada manualmente\033[0m"
    echo -e "  ${SSHPLUS_NUM}[0]${SCOLOR}  \033[1;37m> Volver\033[0m"
    echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
    echo -ne "${SSHPLUS_CYAN}Selecciona opción [Enter = 1 (America/Bogota)]:${SCOLOR} "
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
        0|00) return ;;
        *) target_tz="America/Bogota" ;;
    esac

    echo -e "\n\033[1;33mAplicando zona horaria ${target_tz} y sincronizando NTP...\033[0m"
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
    echo -e "\033[1;37mNueva hora del servidor: \033[1;32m$(date '+%Y-%m-%d %H:%M:%S (%Z)')\033[0m"
    pause
}

menu_vps_settings() {
    while true; do
        clear
        echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
        echo -e "                ${BLUE}CONFIGURACION DE LA VPS${SCOLOR}"
        echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
        echo -e "  ${SSHPLUS_NUM}[1]${SCOLOR} \033[1;37m> CREAR MEMORIA SWAP (1GB, 2GB, 4GB)\033[0m"
        echo -e "  ${SSHPLUS_NUM}[2]${SCOLOR} \033[1;37m> OPTIMIZAR SISTEMA (BBR, Buffers y Kernel)\033[0m"
        echo -e "  ${SSHPLUS_NUM}[3]${SCOLOR} \033[1;37m> RESPALDO / RESTAURACION DE USUARIOS\033[0m"
        echo -e "  ${SSHPLUS_NUM}[4]${SCOLOR} \033[1;37m> ECUALIZAR / CONFIGURAR ZONA HORARIA (HORARIO)\033[0m"
        echo -e "  ${SSHPLUS_NUM}[0]${SCOLOR} \033[1;37m> VOLVER\033[0m"
        echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
        echo -ne "${SSHPLUS_CYAN}Opcion:${SCOLOR} "
        read -r vps_opt
        case "$vps_opt" in
            1|01)
                if [[ -x /bin/swapmemory || -x /usr/bin/swapmemory ]]; then
                    swapmemory
                else
                    clear
                    echo -e "\033[1;32mCreando 2GB de Swap...\033[0m"
                    fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048
                    chmod 600 /swapfile
                    mkswap /swapfile 2>/dev/null || true
                    swapon /swapfile 2>/dev/null || true
                    echo -e "\033[1;32m[✔] SWAP activo:\033[0m"
                    free -h
                    pause
                fi
                ;;
            2|02)
                if [[ -x /bin/tcptweaker.sh || -x /usr/bin/tcptweaker.sh ]]; then
                    tcptweaker.sh
                elif [[ -x /bin/bbr-manager || -x /usr/bin/bbr-manager ]]; then
                    bbr-manager
                elif [[ -f /opt/ssh-cris/Modulos/tcptweaker.sh ]]; then
                    bash /opt/ssh-cris/Modulos/tcptweaker.sh
                elif [[ -x /bin/optimize || -x /usr/bin/optimize ]]; then
                    optimize
                else
                    clear
                    echo -e "\033[1;32mDescargando e iniciando TCP Tweaker & BBR...\033[0m"
                    curl -fsSL https://raw.githubusercontent.com/soportecrisdev/SCRIP_CRISDEV/main/Modulos/tcptweaker.sh -o /bin/tcptweaker.sh 2>/dev/null
                    chmod +x /bin/tcptweaker.sh 2>/dev/null || true
                    tcptweaker.sh
                fi
                ;;
            3|03)
                if [[ -x /bin/userbackup || -x /usr/bin/userbackup ]]; then
                    userbackup
                else
                    clear
                    echo -e "\033[1;32mCreando respaldo en /root/backup-ssh.tar.gz...\033[0m"
                    tar -czf /root/backup-ssh.tar.gz /etc/passwd /etc/shadow /etc/SSHPlus /root/usuarios.db 2>/dev/null || true
                    echo -e "\033[1;32m[✔] Respaldo guardado en /root/backup-ssh.tar.gz\033[0m"
                    pause
                fi
                ;;
            4|04)
                ecualizar_horario
                ;;
            0|00) break ;;
            *) echo -e "\n\033[1;31mOpción inválida!\033[0m"; sleep 1 ;;
        esac
    done
}

menu_script_settings() {
    while true; do
        clear
        echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
        echo -e "               ${BLUE}CONFIGURACION DEL SCRIPT${SCOLOR}"
        echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
        echo -e "  ${SSHPLUS_NUM}[1]${SCOLOR} \033[1;37m> INFORMACION DETALLADA DEL VPS\033[0m"
        echo -e "  ${SSHPLUS_NUM}[2]${SCOLOR} \033[1;37m> ACTUALIZAR SCRIPT (CRISDEV)\033[0m"
        echo -e "  ${SSHPLUS_NUM}[3]${SCOLOR} \033[1;37m> SELECCIONAR IDIOMA\033[0m"
        echo -e "  ${RED}[4]${SCOLOR}  \033[1;31m> DESINSTALAR SCRIPT\033[0m"
        echo -e "  ${SSHPLUS_NUM}[0]${SCOLOR} \033[1;37m> VOLVER\033[0m"
        echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
        echo -ne "${SSHPLUS_CYAN}Opcion:${SCOLOR} "
        read -r scr_opt
        case "$scr_opt" in
            1|01)
                if [[ -x /bin/details || -x /usr/bin/details ]]; then
                    details
                else
                    clear
                    echo -e "${CYAN}=== INFORMACIÓN DE LA VPS ===${NC}"
                    uname -a
                    lscpu 2>/dev/null | grep 'Model name\|CPU(s):' || true
                    free -h
                    df -h /
                    pause
                fi
                ;;
            2|02)
                clear
                echo -e "\033[1;32mActualizando SSH-CRIS desde repositorio oficial...\033[0m"
                bash <(curl -fsSL https://raw.githubusercontent.com/soportecrisdev/SCRIP_CRISDEV/main/install.sh)
                pause
                ;;
            3|03)
                clear
                echo -e "1) Español\n2) English"
                read -r -p "Selecciona idioma: " l_sel
                [[ "$l_sel" == "2" ]] && echo "en" > /etc/SSHPlus/lang || echo "es" > /etc/SSHPlus/lang
                echo -e "\033[1;32mIdioma actualizado!\033[0m"
                pause
                ;;
            4|04)
                if [[ -x /bin/delscript || -x /usr/bin/delscript ]]; then
                    delscript
                else
                    clear
                    echo -ne "\033[1;31m¿Desea desinstalar el script por completo? [s/n]: \033[0m"
                    read -r ans_del
                    if [[ "$ans_del" =~ ^[sS]$ ]]; then
                        rm -rf /opt/ssh-cris /etc/SSHPlus /bin/ssh-cris /bin/menu /etc/bhttp /etc/wakkodev-bhttp /etc/hysteria
                        echo -e "\033[1;32mScript desinstalado.\033[0m"
                        exit 0
                    fi
                fi
                ;;
            0|00) break ;;
            *) echo -e "\n\033[1;31mOpción inválida!\033[0m"; sleep 1 ;;
        esac
    done
}

menu_mas_ajustes() {
    while true; do
        clear
        echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
        echo -e "                   ${BLUE}MAS AJUSTES Y HERRAMIENTAS${SCOLOR}"
        echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
        echo -e "  ${SSHPLUS_NUM}[1]${SCOLOR}  \033[1;37m> AGREGAR HOST / DOMINIO\033[0m"
        echo -e "  ${SSHPLUS_NUM}[2]${SCOLOR}  \033[1;37m> ELIMINAR HOST / DOMINIO\033[0m"
        echo -e "  ${SSHPLUS_NUM}[3]${SCOLOR}  \033[1;37m> REINICIAR TODOS LOS SERVICIOS\033[0m"
        echo -e "  ${SSHPLUS_NUM}[4]${SCOLOR}  \033[1;37m> BLOQUEAR TORRENT\033[0m"
        echo -e "  ${SSHPLUS_NUM}[5]${SCOLOR}  \033[1;37m> BOT SSH TELEGRAM\033[0m"
        echo -e "  ${SSHPLUS_NUM}[6]${SCOLOR}  \033[1;37m> BOT PRUEBAS TELEGRAM\033[0m"
        echo -e "  ${SSHPLUS_NUM}[7]${SCOLOR}  \033[1;37m> HERRAMIENTAS EXTRAS\033[0m"
        echo -e "  ${SSHPLUS_NUM}[8]${SCOLOR}  \033[1;37m> CAMBIAR CLAVE ROOT\033[0m"
        echo -e "  ${SSHPLUS_NUM}[9]${SCOLOR}  \033[1;37m> TCP TWEAKER (BBR & Buffers)\033[0m"
        echo -e "  ${SSHPLUS_NUM}[10]${SCOLOR} \033[1;37m> REINICIAR VPS\033[0m"
        echo -e "  ${SSHPLUS_NUM}[0]${SCOLOR}  \033[1;37m> VOLVER\033[0m"
        echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
        echo -ne "${SSHPLUS_CYAN}Opcion:${SCOLOR} "
        read -r m2_opt
        case "$m2_opt" in
            1|01)
                [[ -x /bin/addhost ]] && addhost || { echo -ne "Ingresa Host/SNI: "; read -r nh; echo "$nh" >> /etc/hosts; pause; }
                ;;
            2|02)
                [[ -x /bin/delhost ]] && delhost || pause
                ;;
            3|03)
                if [[ -x /bin/restartservices ]]; then
                    restartservices
                else
                    clear
                    echo -e "\033[1;32mReiniciando servicios...\033[0m"
                    systemctl restart sshd ssh dropbear stunnel4 badvpn-udpgw hysteria-server slowdns bhttp bhttp-tls chisel 2>/dev/null || true
                    echo -e "\033[1;32m[✔] Servicios reiniciados!\033[0m"
                    pause
                fi
                ;;
            4|04)
                [[ -x /bin/blockt ]] && blockt || pause
                ;;
            5|05)
                [[ -x /bin/botssh ]] && botssh || pause
                ;;
            6|06)
                [[ -x /bin/install-testbot ]] && install-testbot || pause
                ;;
            7|07)
                [[ -x /bin/utili ]] && utili || pause
                ;;
            8|08)
                [[ -x /bin/rootpass ]] && rootpass || { passwd root; pause; }
                ;;
            9|09)
                [[ -x /bin/tcptweaker.sh ]] && tcptweaker.sh || pause
                ;;
            10)
                clear
                echo -ne "\033[1;31m¿Reiniciar servidor VPS ahora? [s/n]: \033[0m"
                read -r r_ok
                [[ "$r_ok" == "s" || "$r_ok" == "S" ]] && reboot
                ;;
            0|00) break ;;
            *) echo -e "\n\033[1;31mOpción inválida!\033[0m"; sleep 1 ;;
        esac
    done
}

# ─────────────────────────────────────────────────────────────────────────────
#  MENÚ PRINCIPAL
# ─────────────────────────────────────────────────────────────────────────────
main_menu() {
    while true; do
        clear
        local ip; ip=$(get_public_ip)
        local os; os=$(lsb_release -sd 2>/dev/null || cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d= -f2 | tr -d '\"' || echo 'Linux')
        
        # Cálculo robusto de Memoria RAM (independiente de idioma/locale)
        local ram_total=0 ram_used=0
        if [[ -f /proc/meminfo ]]; then
            local kb_tot kb_avail
            kb_tot=$(grep -i '^MemTotal:' /proc/meminfo 2>/dev/null | awk '{print $2}')
            kb_avail=$(grep -i '^MemAvailable:' /proc/meminfo 2>/dev/null | awk '{print $2}')
            [[ -z "$kb_avail" ]] && kb_avail=$(grep -i '^MemFree:' /proc/meminfo 2>/dev/null | awk '{print $2}')
            [[ -n "$kb_tot" && "$kb_tot" -gt 0 ]] && ram_total=$(( kb_tot / 1024 ))
            [[ -n "$kb_tot" && -n "$kb_avail" && "$kb_tot" -ge "$kb_avail" ]] && ram_used=$(( (kb_tot - kb_avail) / 1024 ))
        fi
        if [[ $ram_total -eq 0 ]]; then
            read -r ram_total ram_used <<< "$(LC_ALL=C free -m 2>/dev/null | awk 'NR==2 {print $2, $3}')"
        fi
        ram_total=${ram_total:-0}
        ram_used=${ram_used:-0}
        local ram_pct=0
        [[ $ram_total -gt 0 ]] && ram_pct=$(( ram_used * 100 / ram_total ))

        # Cálculo de CPU
        local cpu_load
        cpu_load=$(LC_ALL=C top -bn1 2>/dev/null | grep -i "cpu(s)" | head -1 | awk -F, '{for(i=1;i<=NF;i++) if($i ~ /id/) {gsub(/[^0-9.]/,"",$i); print int(100 - $i)"%"}}')
        [[ -z "$cpu_load" ]] && cpu_load=$(top -bn1 2>/dev/null | grep -i "cpu" | head -1 | awk '{print $2"%"}' || echo "0%")
        [[ -z "$cpu_load" || "$cpu_load" == "%" ]] && cpu_load="0%"

        local hora; hora=$(date '+%H:%M:%S')

        local stats_str; stats_str=$(get_users_stats)
        local u_total; u_total=$(echo "$stats_str" | cut -d: -f1)
        local u_active; u_active=$(echo "$stats_str" | cut -d: -f2)
        local u_expired; u_expired=$(echo "$stats_str" | cut -d: -f3)
        local u_online; u_online=$(echo "$stats_str" | cut -d: -f4)

        local stsl
        pgrep -f 'limiter' >/dev/null 2>&1 && stsl="\033[1;32mo\033[0m" || stsl="\033[1;31mx\033[0m"

        echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
        echo -e "               ${BLUE}⚡ HTTP CONEXIÓN MASTER SUITE ⚡${SCOLOR}"
        echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
        printf " ${SSHPLUS_SECTION}%-21s %-21s %-16s${SCOLOR}\n" "SISTEMA" "MEMORIA RAM" "PROCESADOR"
        printf " ${WHITE}OS:   ${GREEN}%-15s ${WHITE}Total: ${GREEN}%-14s ${WHITE}Núcleos: ${GREEN}%s${NC}\n" "${os:0:15}" "${ram_total} MB" "$(nproc 2>/dev/null || echo 1)"
        printf " ${WHITE}Hora: ${GREEN}%-15s ${WHITE}RAM:   ${GREEN}%-14s ${WHITE}CPU:     ${GREEN}%s${NC}\n" "$hora" "${ram_used} MB (${ram_pct}%)" "$cpu_load"
        echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
        printf " ${SSHPLUS_COUNTER}Conectados: %-8s  Caducados: %-8s  Total: %s${SCOLOR}\n" "$u_online" "$u_expired" "$u_total"
        echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
        printf "  %b[1]%b  > USUARIOS                %b[6]%b  > RED Y SEGURIDAD\n" "$SSHPLUS_NUM" "$SCOLOR" "$SSHPLUS_NUM" "$SCOLOR"
        printf "  %b[2]%b  > PROTOCOLOS DE TUNEL     %b[7]%b  > GESTION DE LA VPS\n" "$SSHPLUS_NUM" "$SCOLOR" "$SSHPLUS_NUM" "$SCOLOR"
        printf "  %b[3]%b  > BANNER DE CONEXION      %b[8]%b  > AJUSTES DEL SCRIPT\n" "$SSHPLUS_NUM" "$SCOLOR" "$SSHPLUS_NUM" "$SCOLOR"
        printf "  %b[4]%b  > LIMITADOR DE USUARIOS %b %b[9]%b  > HERRAMIENTAS EXTRA\n" "$SSHPLUS_NUM" "$SCOLOR" "$stsl" "$SSHPLUS_NUM" "$SCOLOR"
        printf "  %b[5]%b  > CHECKUSERS BOT          %b[10]%b > REINICIAR VPS\n" "$SSHPLUS_NUM" "$SCOLOR" "$SSHPLUS_NUM" "$SCOLOR"
        printf "  %b[0]%b  > SALIR DEL SCRIPT\n" "$SSHPLUS_NUM" "$SCOLOR"
        echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
        echo -ne "${SSHPLUS_CYAN}Opcion:${SCOLOR} "
        read -r main_opt

        case "$main_opt" in
            1|01) menu_users ;;
            2|02) menu_protocolos ;;
            3|03) menu_banner ;;
            4|04)
                clear
                if pgrep -f 'limiter' >/dev/null 2>&1; then
                    pkill -f limiter 2>/dev/null || true
                    echo -e "\033[1;31mLIMITADOR DESACTIVADO!\033[0m"
                else
                    screen -dmS limiter /bin/limiter 2>/dev/null || true
                    echo -e "\033[1;32mLIMITADOR ACTIVADO!\033[0m"
                fi
                sleep 2
                ;;
            5|05) menu_checkusers ;;
            6|06) menu_network_security ;;
            7|07) menu_vps_settings ;;
            8|08) menu_script_settings ;;
            9|09) menu_mas_ajustes ;;
            10)
                clear
                echo -ne "\033[1;31m¿Reiniciar servidor VPS ahora? [s/n]: \033[0m"
                read -r r_ok
                [[ "$r_ok" == "s" || "$r_ok" == "S" ]] && reboot
                ;;
            0|00)
                echo -e "\n\033[1;32m¡Hasta pronto!\033[0m\n"
                exit 0
                ;;
            *)
                echo -e "\n\033[1;31mOpción inválida!\033[0m"
                sleep 1
                ;;
        esac
    done
}

# Iniciar
main_menu "$@"
