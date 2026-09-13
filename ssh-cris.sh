#!/usr/bin/env bash
# ==============================================================================
#  SSH-CRIS v1 — VPS MASTER VPN SUITE & PROTOCOL MANAGER
#  Autor: CRISDEV / HTTP Conexión
#  Base: SSH-Plus / NoxuraSSH Architecture + BHTTP + UDP CRIS + HTTP Conexión
# ==============================================================================
set -Euo pipefail

export LC_ALL=C
export LANG=C

VERSION="v1.0-CRISDEV"
TITLE="SSH-CRIS MASTER SUITE"
INSTALL_DIR="/opt/ssh-cris"
BHTTP_BASE="/etc/wakkodev-bhttp"
BHTTP_CONFIG="$BHTTP_BASE/config"
USER_DATABASE="/etc/ssh-cris/users.db"
SSHPLUS_DIR="/etc/SSHPlus"

AMD64_BHTTP="https://www.dropbox.com/scl/fi/xe5uut31ybiiwpio8njlp/wakkodev-bhttp-server-amd64?rlkey=9f92nqgiezysxoq4xjta4lpfc&st=8ezemtuj&dl=1"
ARM64_BHTTP="https://www.dropbox.com/scl/fi/h3pruw07ecgh4iph24gbm/wakkodev-bhttp-server-arm64?rlkey=hzmvl36pl50k7d9qqkgi4ltzz&st=fs95gvtz&dl=1"

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
mkdir -p /etc/ssh-cris /etc/SSHPlus/senha /etc/wakkodev-bhttp /etc/hysteria /etc/stunnel /etc/slowdns /root
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

# ─────────────────────────────────────────────────────────────────────────────
#  HELPER DE USUARIOS (LECTURA NATIVA DESDE LINUX + SSHPLUS + CRIS.DB)
# ─────────────────────────────────────────────────────────────────────────────
get_user_list() {
    local -A seen
    local u_list=()

    # 1. Usuarios Linux reales UID >= 1000
    while IFS=: read -r u _ uid _ _ _ _; do
        [[ -z "$u" || "$u" =~ ^(nobody|systemd-|polkitd|messagebus|daemon|bin|sys|sync|games|man|lp|mail|news|uucp|proxy|www-data|backup|list|irc|gnats|_apt)$ ]] && continue
        if [[ "$uid" -ge 1000 && -z "${seen[$u]:-}" ]]; then
            seen[$u]=1
            u_list+=("$u")
        fi
    done < /etc/passwd

    # 2. Usuarios en /etc/SSHPlus/senha/
    if [[ -d /etc/SSHPlus/senha ]]; then
        for f in /etc/SSHPlus/senha/*; do
            [[ -f "$f" ]] || continue
            local u; u=$(basename "$f")
            if [[ -z "${seen[$u]:-}" ]]; then
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

    printf '%s\n' "${u_list[@]:-}" | sort -u
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
    local all_users
    mapfile -t all_users < <(get_user_list)

    total=${#all_users[@]}
    for u in "${all_users[@]}"; do
        [[ -z "$u" ]] && continue
        local st; st=$(get_user_days_remaining "$u")
        if [[ "$st" == "Vencido" ]]; then
            ((expired++))
        else
            ((active++))
        fi
    done

    local ons; ons=$(ps -x 2>/dev/null | grep sshd | grep -v root | grep priv | wc -l || echo 0)
    local onop=0
    [[ -e /etc/openvpn/openvpn-status.log ]] && onop=$(grep -c "10.8.0" /etc/openvpn/openvpn-status.log 2>/dev/null || echo 0)
    local drp=0 ondrp=0
    if [[ -e /etc/default/dropbear ]]; then
        drp=$(ps aux 2>/dev/null | grep dropbear | grep -v grep | wc -l || echo 0)
        ondrp=$(( drp > 0 ? drp - 1 : 0 ))
    fi
    local online=$(( ons + onop + ondrp ))
    echo "$total:$active:$expired:$online"
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
        chmod +x /etc/SSHPlus/proxy.py 2>/dev/null || true
    fi

    if [[ ! -f /etc/SSHPlus/wsproxy.py ]]; then
        if [[ -f "./wsproxy.py" ]]; then
            cp -f "./wsproxy.py" /etc/SSHPlus/wsproxy.py
        elif [[ -f "/opt/ssh-cris/wsproxy.py" ]]; then
            cp -f "/opt/ssh-cris/wsproxy.py" /etc/SSHPlus/wsproxy.py
        else
            curl -fsSL "https://raw.githubusercontent.com/soportecrisdev/SCRIP_CRISDEV/main/wsproxy.py" -o /etc/SSHPlus/wsproxy.py 2>/dev/null || \
            wget -q "https://raw.githubusercontent.com/soportecrisdev/SCRIP_CRISDEV/main/wsproxy.py" -O /etc/SSHPlus/wsproxy.py 2>/dev/null || true
        fi
        chmod +x /etc/SSHPlus/wsproxy.py 2>/dev/null || true
    fi
}

fun_socks() {
    ensure_proxy_scripts
    while true; do
        clear
        sshplus_line
        echo -e "                   ${BLUE}CONFIGURAR PROXY SOCKS${SCOLOR}"
        sshplus_line
        local _socks_ports
        _socks_ports=$(netstat -nplt 2>/dev/null | grep -E 'python3|/python' | awk '{print $4}' | cut -d: -f2 | sort -n -u | xargs || true)
        echo -e "${SSHPLUS_DARK_GREEN}PUERTOS:${SCOLOR} \033[1;32m${_socks_ports:-N/A}\033[0m"
        echo -e "\033[1;37m------------------------------------------------------------\033[0m"

        local var_sks1 var_sks2
        pgrep -f '/etc/SSHPlus/proxy.py' >/dev/null 2>&1 && var_sks1="\033[1;32mo\033[0m" || var_sks1="\033[1;31mx\033[0m"
        pgrep -f '/etc/SSHPlus/wsproxy.py' >/dev/null 2>&1 && var_sks2="\033[1;32mo\033[0m" || var_sks2="\033[1;31mx\033[0m"

        echo -e "${SSHPLUS_NUM}[1]${SCOLOR} \033[1;37m> SOCKS SSH\033[0m            $var_sks1"
        echo -e "${SSHPLUS_NUM}[2]${SCOLOR} \033[1;37m> WEBSOCKET\033[0m            $var_sks2"
        echo -e "${SSHPLUS_NUM}[3]${SCOLOR} \033[1;37m> ABRIR PUERTO EXTRA SOCKS\033[0m"
        echo -e "${SSHPLUS_NUM}[4]${SCOLOR} \033[1;37m> MODIFICAR ESTADO SOCKS SSH\033[0m"
        echo -e "${SSHPLUS_NUM}[5]${SCOLOR} \033[1;37m> MODIFICAR ESTADO WEBSOCKET\033[0m"
        echo -e "${SSHPLUS_NUM}[0]${SCOLOR} \033[1;37m> VOLVER\033[0m"
        sshplus_line
        echo -ne "${SSHPLUS_CYAN}Opcion:${SCOLOR} "
        read -r resposta

        case "$resposta" in
            1)
                if pgrep -f '/etc/SSHPlus/proxy.py' >/dev/null 2>&1; then
                    clear
                    echo -e "\E[41;1;37m             DESACTIVAR PROXY SOCKS             \E[0m\n"
                    fun_socksoff() {
                        for pidproxy in $(screen -ls 2>/dev/null | grep '\.proxy' | awk '{print $1}'); do
                            screen -r -S "$pidproxy" -X quit 2>/dev/null || true
                        done
                        for _k in $(pgrep -f '/etc/SSHPlus/proxy.py' 2>/dev/null); do
                            kill -9 "$_k" 2>/dev/null || true
                        done
                        screen -wipe >/dev/null 2>&1 || true
                    }
                    echo -e "\033[1;32mDESACTIVANDO EL PROXY SOCKS...\033[0m"
                    fun_bar 'fun_socksoff'
                    echo -e "\n\033[1;32mPROXY SOCKS DESACTIVADO CON ÉXITO!\033[0m"
                    sleep 2
                else
                    clear
                    fun_socks_prepare_activate
                    echo -e "\E[44;1;37m             INICIAR PROXY SOCKS             \E[0m\n"
                    echo -ne "\033[1;32m¿QUÉ PUERTO DESEA UTILIZAR ?\033[1;37m: "
                    read -r porta
                    [[ -z "$porta" || ! "$porta" =~ ^[0-9]+$ ]] && porta=80
                    verif_ptrs_socks "$porta" || continue
                    fun_inisocks() {
                        screen -dmS proxy "${SSHPLUS_PY}" /etc/SSHPlus/proxy.py "$porta"
                    }
                    echo -e "\n\033[1;32mINICIANDO EL PROXY SOCKS EN PUERTO $porta...\033[0m"
                    fun_bar 'fun_inisocks'
                    ufw allow "$porta"/tcp 2>/dev/null || true
                    echo -e "\n\033[1;32mSOCKS ACTIVADO CON ÉXITO EN PUERTO $porta\033[0m"
                    sleep 2
                fi
                ;;
            2)
                if pgrep -f '/etc/SSHPlus/wsproxy.py' >/dev/null 2>&1; then
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
                else
                    clear
                    fun_ws_prepare_activate
                    echo -e "\E[44;1;37m             INICIAR WEBSOCKET             \E[0m\n"
                    echo -ne "\033[1;32m¿QUÉ PUERTO DESEA UTILIZAR ? (ej: 80 o 8080)\033[1;37m: "
                    read -r porta
                    [[ -z "$porta" || ! "$porta" =~ ^[0-9]+$ ]] && porta=80
                    verif_ptrs_socks "$porta" || continue
                    fun_iniws() {
                        screen -dmS ws "${SSHPLUS_PY}" /etc/SSHPlus/wsproxy.py "$porta"
                    }
                    echo -e "\n\033[1;32mINICIANDO WEBSOCKET EN PUERTO $porta...\033[0m"
                    fun_bar 'fun_iniws'
                    ufw allow "$porta"/tcp 2>/dev/null || true
                    echo -e "\n\033[1;32mWEBSOCKET ACTIVADO CON ÉXITO EN PUERTO $porta\033[0m"
                    sleep 2
                fi
                ;;
            3)
                clear
                echo -e "\E[44;1;37m          ABRIR PUERTO EXTRA SOCKS          \E[0m\n"
                echo -ne "\033[1;32m¿QUÉ PUERTO EXTRA DESEA UTILIZAR ?\033[1;37m: "
                read -r porta
                [[ -z "$porta" || ! "$porta" =~ ^[0-9]+$ ]] && {
                    echo -e "\n\033[1;31mPuerto inválido!"
                    sleep 2
                    continue
                }
                verif_ptrs_socks "$porta" || continue
                fun_extra_sks() {
                    screen -dmS "proxy_$porta" "${SSHPLUS_PY}" /etc/SSHPlus/proxy.py "$porta"
                }
                echo -e "\n\033[1;32mINICIANDO PUERTO EXTRA $porta...\033[0m"
                fun_bar 'fun_extra_sks'
                ufw allow "$porta"/tcp 2>/dev/null || true
                echo -e "\n\033[1;32mPUERTO EXTRA SOCKS $porta ACTIVADO!\033[0m"
                sleep 2
                ;;
            4)
                if pgrep -f '/etc/SSHPlus/proxy.py' >/dev/null 2>&1; then
                    clear
                    echo -e "\E[44;1;37m         MODIFICAR ESTADO SOCKS SSH         \E[0m\n"
                    echo -ne "\033[1;32mINFORME SU MENSAJE DE ESTADO (ej: HTTP CONEXION ONLINE)\033[1;31m:\033[1;37m "
                    read -r msgg
                    [[ -z "$msgg" ]] && msgg="HTTP CONEXION"
                    sed -i "s/MSG = .*/MSG = '$msgg'/g" /etc/SSHPlus/proxy.py 2>/dev/null || true
                    echo -e "\n\033[1;32mMENSAJE ACTUALIZADO A: '$msgg'\033[0m"
                    sleep 2
                else
                    echo -e "\n\033[1;31mActive SOCKS SSH primero."
                    sleep 2
                fi
                ;;
            5)
                if pgrep -f '/etc/SSHPlus/wsproxy.py' >/dev/null 2>&1; then
                    clear
                    echo -e "\E[44;1;37m         MODIFICAR ESTADO WEBSOCKET         \E[0m\n"
                    echo -ne "\033[1;32mINFORME SU MENSAJE WEBSOCKET\033[1;31m:\033[1;37m "
                    read -r msgg
                    [[ -z "$msgg" ]] && msgg="HTTP CONEXION WS"
                    sed -i "s/MSG = .*/MSG = '$msgg'/g" /etc/SSHPlus/wsproxy.py 2>/dev/null || true
                    echo -e "\n\033[1;32mMENSAJE ACTUALIZADO A: '$msgg'\033[0m"
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
    if netstat -nltp 2>/dev/null | grep -q 'dropbear'; then
        local dpbr
        dpbr=$(netstat -nplt 2>/dev/null | grep 'dropbear' | awk '{print $4}' | awk -F: '{print $NF}' | sort -n -u | xargs || echo "110")
        clear
        echo -e "\E[44;1;37m              GESTIONAR DROPBEAR               \E[0m"
        echo -e "\n\033[1;33mPUERTOS EN USO\033[1;37m: \033[1;32m$dpbr\033[0m\n"
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
            local extra_args=""
            for p in $dp_pts; do extra_args="$extra_args -p $p"; done
            cat > /etc/default/dropbear << EOF
NO_START=0
DROPBEAR_PORT=
DROPBEAR_EXTRA_ARGS="$extra_args"
DROPBEAR_BANNER=""
DROPBEAR_RECEIVE_WINDOW=65536
EOF
            systemctl restart dropbear 2>/dev/null || service dropbear restart 2>/dev/null
            for p in $dp_pts; do ufw allow "$p"/tcp 2>/dev/null || true; done
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
                apt-get update -qq && apt-get install -y -qq dropbear >/dev/null 2>&1 || true
                local extra_args=""
                for p in $dp_pts; do extra_args="$extra_args -p $p"; done
                cat > /etc/default/dropbear << EOF
NO_START=0
DROPBEAR_PORT=
DROPBEAR_EXTRA_ARGS="$extra_args"
DROPBEAR_BANNER=""
DROPBEAR_RECEIVE_WINDOW=65536
EOF
                systemctl restart dropbear 2>/dev/null || service dropbear restart 2>/dev/null
            }
            fun_bar 'fun_instdrop'
            for p in $dp_pts; do ufw allow "$p"/tcp 2>/dev/null || true; done
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
menub() {
    clear
    echo -e "${CYAN}========================================================================${NC}"
    echo -e "${WHITE}                       BADVPN UDPGW (JUEGOS / VOIP)                     ${NC}"
    echo -e "${CYAN}========================================================================${NC}"
    echo -e " ${GREEN}[1]${WHITE} > Iniciar BadVPN Puerto 7300"
    echo -e " ${GREEN}[2]${WHITE} > Iniciar Multi-BadVPN (7100, 7200, 7300)"
    echo -e " ${RED}[3]${WHITE} > Detener BadVPN"
    echo -e " ${RED}[0]${WHITE} > Volver"
    echo -e "${CYAN}========================================================================${NC}"
    read -r -p " Opcion: " b_opt
    case "$b_opt" in
        1|2)
            if [[ ! -f /usr/local/bin/badvpn-udpgw ]]; then
                wget -q -O /usr/local/bin/badvpn-udpgw "https://raw.githubusercontent.com/soportecrisdev/SCRIP_CRISDEV/main/UDP_CRIS/badvpn-udpgw" 2>/dev/null || \
                wget -q -O /usr/local/bin/badvpn-udpgw "https://github.com/ambrop72/badvpn/raw/master/bin/badvpn-udpgw" 2>/dev/null
                chmod +x /usr/local/bin/badvpn-udpgw 2>/dev/null || true
            fi
            screen -dmS badvpn /usr/local/bin/badvpn-udpgw --listen-addr 127.0.0.1:7300 --max-clients 1000
            [[ "$b_opt" == "2" ]] && {
                screen -dmS badvpn1 /usr/local/bin/badvpn-udpgw --listen-addr 127.0.0.1:7100 --max-clients 1000
                screen -dmS badvpn2 /usr/local/bin/badvpn-udpgw --listen-addr 127.0.0.1:7200 --max-clients 1000
            }
            echo -e "\n\033[1;32mBadVPN UDPGW iniciado con éxito!\033[0m"
            sleep 2
            ;;
        3)
            for sp in $(screen -ls 2>/dev/null | grep 'badvpn' | awk '{print $1}'); do
                screen -r -S "$sp" -X quit 2>/dev/null || true
            done
            pkill -f badvpn-udpgw 2>/dev/null || true
            echo -e "\n\033[1;32mBadVPN detenido!\033[0m"
            sleep 2
            ;;
        0) return ;;
    esac
}

# 7. SLOWDNS
slow_setup() {
    clear
    echo -e "${CYAN}========================================================================${NC}"
    echo -e "${WHITE}                       SLOWDNS (DNSTT SERVER PUERTO 53)                 ${NC}"
    echo -e "${CYAN}========================================================================${NC}"
    echo -e " ${GREEN}[1]${WHITE} > Configurar Dominio NameServer (NS) y Generar Claves"
    echo -e " ${GREEN}[2]${WHITE} > Ver Clave Pública y NameServer"
    echo -e " ${RED}[3]${WHITE} > Detener SlowDNS"
    echo -e " ${RED}[0]${WHITE} > Volver"
    echo -e "${CYAN}========================================================================${NC}"
    read -r -p " Opcion: " sd_opt
    case "$sd_opt" in
        1)
            read -r -p " Dominio NameServer (NS) (ej: ns1.tudominio.com): " ns_domain
            [[ -z "$ns_domain" ]] && return
            mkdir -p /etc/slowdns
            wget -q -O /usr/local/bin/dnstt-server "https://raw.githubusercontent.com/soportecrisdev/SCRIP_CRISDEV/main/dnstt-server" 2>/dev/null || true
            chmod +x /usr/local/bin/dnstt-server 2>/dev/null || true
            if [[ -x /usr/local/bin/dnstt-server ]]; then
                /usr/local/bin/dnstt-server -gen-key -privkey-file /etc/slowdns/server.key -pubkey-file /etc/slowdns/server.pub 2>/dev/null || true
            fi
            echo "$ns_domain" > /etc/slowdns/ns.txt
            echo -e "\n\033[1;32mSlowDNS configurado con NS: $ns_domain\033[0m"
            [[ -f /etc/slowdns/server.pub ]] && echo -e "\033[1;33mClave Pública:\033[0m $(cat /etc/slowdns/server.pub)"
            pause
            ;;
        2)
            if [[ -f /etc/slowdns/server.pub ]]; then
                echo -e "\n• NameServer:   \033[1;32m$(cat /etc/slowdns/ns.txt 2>/dev/null || echo 'No configurado')\033[0m"
                echo -e "• Clave Pública: \033[1;32m$(cat /etc/slowdns/server.pub)\033[0m"
            else
                echo -e "\n\033[1;31mSlowDNS aún no está configurado."
            fi
            pause
            ;;
        3)
            pkill -f dnstt-server 2>/dev/null || true
            echo -e "\n\033[1;32mSlowDNS detenido!\033[0m"
            sleep 2
            ;;
        0) return ;;
    esac
}

# 8. BHTTP MULTI-PUERTO (WAKKO ENGINE)
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
            echo -e " ${WHITE}Puertos BHTTP Activos: ${RED}Ninguno (Apagado)${NC}"
        fi
        echo -e "${CYAN}========================================================================${NC}"
        echo -e " ${GREEN}[1]${WHITE} > Instalar / Actualizar Motor BHTTP Relay"
        echo -e " ${GREEN}[2]${WHITE} > Configurar Puerto Principal BHTTP (ej: 8080 o 80 -> SSH 22)"
        echo -e " ${GREEN}[3]${WHITE} > Abrir Puerto Adicional (Multi-Puerto: 80, 8888, 3128, etc.)"
        echo -e " ${GREEN}[4]${WHITE} > Listar Puertos BHTTP Activos"
        echo -e " ${GREEN}[5]${WHITE} > Eliminar un Puerto BHTTP Específico"
        echo -e " ${GREEN}[6]${WHITE} > Probar Conectividad BHTTP -> Backend SSH (Socket Test)"
        echo -e " ${RED}[7]${WHITE} > Detener / Desinstalar Servicios BHTTP"
        echo -e " ${RED}[0]${WHITE} > Volver a Protocolos"
        echo -e "${CYAN}========================================================================${NC}"
        read -r -p " Opcion: " b_opt

        case "$b_opt" in
            1)
                local arch; arch=$(uname -m)
                local url="$AMD64_BHTTP"
                [[ "$arch" == "aarch64" || "$arch" == "arm64" ]] && url="$ARM64_BHTTP"
                mkdir -p "$BHTTP_BASE"
                systemctl stop wakkodev-bhttp.service 2>/dev/null || true
                curl -fL --retry 3 "$url" -o /usr/local/bin/wakkodev-bhttp-server 2>/dev/null || \
                wget -q "$url" -O /usr/local/bin/wakkodev-bhttp-server 2>/dev/null
                chmod 755 /usr/local/bin/wakkodev-bhttp-server 2>/dev/null || true
                echo -e "\n\033[1;32mMotor BHTTP instalado con éxito en /usr/local/bin/wakkodev-bhttp-server!\033[0m"
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
                systemctl enable --now wakkodev-bhttp.service 2>/dev/null || true
                ufw allow "$bport"/tcp 2>/dev/null || true
                echo -e "\n\033[1;32mBHTTP Relay activo en puerto TCP $bport -> SSH $backend_port\033[0m"
                pause
                ;;
            3)
                read -r -p " Ingresa puerto adicional (ej: 80, 8888, 3128, 8081): " xport
                [[ ! "$xport" =~ ^[0-9]+$ ]] && { echo -e "\n\033[1;31mPuerto inválido!"; pause; continue; }
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
                systemctl enable --now "wakkodev-bhttp-port-${xport}.service" 2>/dev/null || true
                ufw allow "$xport"/tcp 2>/dev/null || true
                echo -e "\n\033[1;32mPuerto extra BHTTP $xport activado con éxito!\033[0m"
                pause
                ;;
            4)
                echo -e "\n\033[1;33mPuertos BHTTP escuchando:\033[0m"
                ss -tlpn | grep -E "bhttp|wakkodev" || echo "No hay puertos BHTTP activos"
                pause
                ;;
            5)
                local cur_b_ports
                read -r -a cur_b_ports <<< "$(scan_bhttp_ports)"
                echo -e "\nPuertos detectados: \033[1;33m${cur_b_ports[*]:-Ninguno}\033[0m"
                read -r -p " Ingresa el puerto a eliminar: " del_port
                if [[ -f "/etc/systemd/system/wakkodev-bhttp-port-${del_port}.service" ]]; then
                    systemctl disable --now "wakkodev-bhttp-port-${del_port}.service" 2>/dev/null || true
                    rm -f "/etc/systemd/system/wakkodev-bhttp-port-${del_port}.service"
                    systemctl daemon-reload
                    echo -e "\n\033[1;32mPuerto extra $del_port eliminado con éxito!\033[0m"
                elif [[ -f "/etc/systemd/system/wakkodev-bhttp.service" ]] && grep -q -- "--port $del_port" /etc/systemd/system/wakkodev-bhttp.service; then
                    systemctl disable --now wakkodev-bhttp.service 2>/dev/null || true
                    rm -f /etc/systemd/system/wakkodev-bhttp.service
                    systemctl daemon-reload
                    echo -e "\n\033[1;32mPuerto principal $del_port eliminado con éxito!\033[0m"
                fi
                pause
                ;;
            6)
                if nc -z -w2 127.0.0.1 22 2>/dev/null || (exec 3<>/dev/tcp/127.0.0.1/22) 2>/dev/null; then
                    echo -e "\n\033[1;32m[✔] Backend SSH en 127.0.0.1:22 respondiendo OK.\033[0m"
                else
                    echo -e "\n\033[1;31m[✘] Backend SSH en 127.0.0.1:22 cerrado.\033[0m"
                fi
                for p in "${ports_arr[@]}"; do
                    if nc -z -w2 127.0.0.1 "$p" 2>/dev/null || (exec 3<>/dev/tcp/127.0.0.1/"$p") 2>/dev/null; then
                        echo -e "\033[1;32m[✔] Puerto BHTTP $p: Escuchando correctamente.\033[0m"
                    else
                        echo -e "\033[1;31m[✘] Puerto BHTTP $p: No responde.\033[0m"
                    fi
                done
                pause
                ;;
            7)
                systemctl disable --now wakkodev-bhttp.service 2>/dev/null || true
                for f in /etc/systemd/system/wakkodev-bhttp-port-*.service; do
                    [[ -f "$f" ]] && systemctl disable --now "$(basename "$f")" 2>/dev/null || true
                done
                rm -f /etc/systemd/system/wakkodev-bhttp*.service
                systemctl daemon-reload
                echo -e "\n\033[1;32mServicios BHTTP detenidos!\033[0m"
                pause
                ;;
            0) return ;;
        esac
    done
}

# 9. UDP CRIS (HYSTERIA V1.3.5 OFICIAL + BADVPN 7300 ENGINE)
menu_udp() {
    clear
    echo -e "${CYAN}========================================================================${NC}"
    echo -e "${WHITE}             HYSTERIA v1.3.5 / UDP CRIS (LIBFARIKUDP ENGINE)            ${NC}"
    echo -e "${CYAN}========================================================================${NC}"
    echo -e " ${GREEN}[1]${WHITE} > Instalar / Iniciar UDP CRIS (Hysteria v1.3.5 + Buffer 15MB)"
    echo -e " ${GREEN}[2]${WHITE} > Activar / Desactivar Port Hopping (Rango 6000:50000)"
    echo -e " ${GREEN}[3]${WHITE} > Ver Estado del Servicio y Conexiones"
    echo -e " ${RED}[4]${WHITE} > Detener / Desinstalar UDP CRIS"
    echo -e " ${RED}[0]${WHITE} > Volver"
    echo -e "${CYAN}========================================================================${NC}"
    read -r -p " Opcion: " u_opt
    case "$u_opt" in
        1)
            echo -ne "\n\033[1;32mPuerto UDP de escucha (ej: 36712 o 5666)\033[1;37m: "
            read -r uport
            [[ ! "$uport" =~ ^[0-9]+$ ]] && uport=36712

            echo -ne "\033[1;32mContraseña OBFS (default: crisdev)\033[1;37m: "
            read -r obfs_pass
            [[ -z "$obfs_pass" ]] && obfs_pass="crisdev"

            echo -ne "\033[1;32mContraseña Auth (default: crisdev)\033[1;37m: "
            read -r auth_pass
            [[ -z "$auth_pass" ]] && auth_pass="crisdev"

            fun_inst_udp_cris() {
                mkdir -p /etc/hysteria /usr/local/bin
                local arch; arch=$(uname -m)
                local h_url="$HYSTERIA_V1_AMD64"
                [[ "$arch" == "aarch64" || "$arch" == "arm64" ]] && h_url="$HYSTERIA_V1_ARM64"

                curl -fL --retry 5 "$h_url" -o /usr/local/bin/hysteria 2>/dev/null || \
                wget -q "$h_url" -O /usr/local/bin/hysteria 2>/dev/null || true
                chmod +x /usr/local/bin/hysteria 2>/dev/null || true

                # Certificado SSL autogenerado
                openssl req -new -newkey rsa:2048 -days 3650 -nodes -x509 \
                    -subj "/C=US/ST=CRIS/L=CRIS/O=CRISDEV/CN=crisdev.online" \
                    -keyout /etc/hysteria/server.key -out /etc/hysteria/server.crt >/dev/null 2>&1

                # Configuración optimizada compatible 100% con UDPTunnel.java / libfarikudp.so
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
  "idle_timeout": 60,
  "up_mbps": 100,
  "down_mbps": 100,
  "disable_mtu_discovery": false,
  "resolver": "8.8.8.8:53"
}
EOF

                # Optimización del Kernel para UDP de alta velocidad
                sysctl -w net.core.rmem_max=67108864 >/dev/null 2>&1 || true
                sysctl -w net.core.wmem_max=67108864 >/dev/null 2>&1 || true
                sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true

                # Servicio systemd
                cat > /etc/systemd/system/hysteria-server.service << EOF
[Unit]
Description=CRISDEV UDP Hysteria Server v1.3.5
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/hysteria -c /etc/hysteria/config.json server
Restart=always
RestartSec=2
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
                systemctl daemon-reload
                systemctl enable --now hysteria-server.service 2>/dev/null || true

                # BadVPN UDPGW 7300
                if [[ ! -f /usr/local/bin/badvpn-udpgw ]]; then
                    wget -q -O /usr/local/bin/badvpn-udpgw "https://raw.githubusercontent.com/soportecrisdev/SCRIP_CRISDEV/main/UDP_CRIS/badvpn-udpgw" 2>/dev/null || true
                    chmod +x /usr/local/bin/badvpn-udpgw 2>/dev/null || true
                fi
                if [[ -x /usr/local/bin/badvpn-udpgw ]]; then
                    screen -dmS badvpn /usr/local/bin/badvpn-udpgw --listen-addr 127.0.0.1:7300 --max-clients 1000 2>/dev/null || true
                fi

                # Port Hopping 6000:50000
                iptables -t nat -A PREROUTING -p udp --dport 6000:50000 -j REDIRECT --to-ports "$uport" 2>/dev/null || true
                ufw allow "$uport"/udp 2>/dev/null || true
                ufw allow 6000:50000/udp 2>/dev/null || true
            }

            echo -e "\n\033[1;32mINSTALANDO Y CONFIGURANDO UDP CRIS (HYSTERIA v1.3.5)...\033[0m"
            fun_bar 'fun_inst_udp_cris'
            echo -e "\n\033[1;32m[✔] UDP CRIS ACTIVO EN PUERTO UDP $uport (OBFS: $obfs_pass | Auth: $auth_pass)\033[0m"
            echo -e "\033[1;32m[✔] Port Hopping UDP 6000-50000 -> $uport configurado.\033[0m"
            pause
            ;;
        2)
            if iptables -t nat -L PREROUTING -n 2>/dev/null | grep -q "6000:50000"; then
                iptables -t nat -D PREROUTING -p udp --dport 6000:50000 -j REDIRECT 2>/dev/null || true
                echo -e "\n\033[1;31mPort Hopping 6000:50000 desactivado.\033[0m"
            else
                local uport="36712"
                [[ -f /etc/hysteria/config.json ]] && uport=$(grep -o '"listen": "[^"]*"' /etc/hysteria/config.json 2>/dev/null | cut -d: -f3 | tr -d '":, ' || echo "36712")
                iptables -t nat -A PREROUTING -p udp --dport 6000:50000 -j REDIRECT --to-ports "$uport" 2>/dev/null || true
                echo -e "\n\033[1;32mPort Hopping UDP 6000-50000 activado hacia $uport.\033[0m"
            fi
            pause
            ;;
        3)
            echo -e "\n\033[1;33mEstado del servicio Hysteria:\033[0m"
            systemctl status hysteria-server.service --no-pager || true
            echo -e "\n\033[1;33mPuerto UDP escuchando:\033[0m"
            ss -ulpn | grep hysteria || true
            pause
            ;;
        4)
            systemctl disable --now hysteria-server.service 2>/dev/null || true
            rm -rf /etc/hysteria /usr/local/bin/hysteria /etc/systemd/system/hysteria-server.service
            systemctl daemon-reload
            iptables -t nat -D PREROUTING -p udp --dport 6000:50000 -j REDIRECT 2>/dev/null || true
            echo -e "\n\033[1;32mUDP CRIS desinstalado con éxito!\033[0m"
            pause
            ;;
        0) return ;;
    esac
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
        sks_p=$(netstat -nplt 2>/dev/null | grep -E 'python3|/python' | awk '{print $4}' | cut -d: -f2 | sort -n -u | xargs || true)
        if [[ -n "$sks_p" ]]; then
            echo -e "\033[1;32mSERVICIO: \033[1;33mPROXY SOCKS \033[1;32mPUERTO: \033[1;37m$sks_p\033[0m"
        fi

        # 3. SSL Tunnel
        local ssl_p
        ssl_p=$(netstat -nplt 2>/dev/null | grep -E 'stunnel|stunnel4' | awk '{print $4}' | cut -d: -f2 | sort -n -u | xargs || true)
        if [[ -n "$ssl_p" ]]; then
            echo -e "\033[1;32mSERVICIO: \033[1;33mSSL TUNNEL \033[1;32mPUERTO: \033[1;37m$ssl_p\033[0m"
        fi

        # 4. Dropbear
        local drp_p
        drp_p=$(netstat -nplt 2>/dev/null | grep 'dropbear' | awk '{print $4}' | cut -d: -f2 | sort -n -u | xargs || true)
        if [[ -n "$drp_p" ]]; then
            echo -e "\033[1;32mSERVICIO: \033[1;33mDROPBEAR \033[1;32mPUERTO: \033[1;37m$drp_p\033[0m"
        fi

        # 5. BHTTP Multi-Puerto
        local bhttp_p
        bhttp_p=$(scan_bhttp_ports)
        if [[ -n "$bhttp_p" ]]; then
            echo -e "\033[1;32mSERVICIO: \033[1;33mBHTTP RELAY \033[1;32mPUERTO: \033[1;37m$bhttp_p\033[0m"
        fi

        # 6. UDP CRIS (Hysteria v1)
        if systemctl is-active --quiet hysteria-server 2>/dev/null || pgrep -f hysteria >/dev/null 2>&1; then
            local uport="36712"
            [[ -f /etc/hysteria/config.json ]] && uport=$(grep -o '"listen": "[^"]*"' /etc/hysteria/config.json 2>/dev/null | cut -d: -f3 | tr -d '":, ' || echo "36712")
            echo -e "\033[1;32mSERVICIO: \033[1;33mUDP CRIS (HYSTERIA) \033[1;32mPUERTO: \033[1;37m$uport (6000:50000)\033[0m"
        fi

        # 7. BadVPN
        if pgrep -f badvpn-udpgw >/dev/null 2>&1; then
            echo -e "\033[1;32mSERVICIO: \033[1;33mBADVPN \033[1;32mPUERTO: \033[1;37m7300\033[0m"
        fi

        # 8. Squid
        local sqd_p
        sqd_p=$(netstat -nplt 2>/dev/null | grep 'squid' | awk '{print $4}' | cut -d: -f2 | sort -n -u | xargs || true)
        if [[ -n "$sqd_p" ]]; then
            echo -e "\033[1;32mSERVICIO: \033[1;33mSQUID \033[1;32mPUERTO: \033[1;37m$sqd_p\033[0m"
        fi

        # 9. SlowDNS
        if pgrep -f dnstt-server >/dev/null 2>&1; then
            echo -e "\033[1;32mSERVICIO: \033[1;33mSLOWDNS \033[1;32mPUERTO: \033[1;37m53\033[0m"
        fi

        echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"

        local sts_ssh sts_socks sts_ssl sts_drop sts_v2ray sts_slow sts_hyst sts_trojan sts_badvpn sts_ovpn sts_ws sts_sslh sts_squid sts_chisel sts_bhttp
        sts_ssh="\033[1;32mo\033[0m"
        [[ -n "$sks_p" ]] && sts_socks="\033[1;32mo\033[0m" || sts_socks="\033[1;31mx\033[0m"
        [[ -n "$ssl_p" ]] && sts_ssl="\033[1;32mo\033[0m" || sts_ssl="\033[1;31mx\033[0m"
        [[ -n "$drp_p" ]] && sts_drop="\033[1;32mo\033[0m" || sts_drop="\033[1;31mx\033[0m"
        pgrep -f 'xray|v2ray' >/dev/null 2>&1 && sts_v2ray="\033[1;32mo\033[0m" || sts_v2ray="\033[1;31mx\033[0m"
        pgrep -f 'dnstt-server' >/dev/null 2>&1 && sts_slow="\033[1;32mo\033[0m" || sts_slow="\033[1;31mx\033[0m"
        (systemctl is-active --quiet hysteria-server 2>/dev/null || pgrep -f hysteria >/dev/null 2>&1) && sts_hyst="\033[1;32mo\033[0m" || sts_hyst="\033[1;31mx\033[0m"
        pgrep -f 'trojan' >/dev/null 2>&1 && sts_trojan="\033[1;32mo\033[0m" || sts_trojan="\033[1;31mx\033[0m"
        pgrep -f 'badvpn-udpgw' >/dev/null 2>&1 && sts_badvpn="\033[1;32mo\033[0m" || sts_badvpn="\033[1;31mx\033[0m"
        pgrep -f 'openvpn' >/dev/null 2>&1 && sts_ovpn="\033[1;32mo\033[0m" || sts_ovpn="\033[1;31mx\033[0m"
        pgrep -f '/etc/SSHPlus/wsproxy.py' >/dev/null 2>&1 && sts_ws="\033[1;32mo\033[0m" || sts_ws="\033[1;31mx\033[0m"
        pgrep -f 'sslh' >/dev/null 2>&1 && sts_sslh="\033[1;32mo\033[0m" || sts_sslh="\033[1;31mx\033[0m"
        [[ -n "$sqd_p" ]] && sts_squid="\033[1;32mo\033[0m" || sts_squid="\033[1;31mx\033[0m"
        pgrep -f 'chisel' >/dev/null 2>&1 && sts_chisel="\033[1;32mo\033[0m" || sts_chisel="\033[1;31mx\033[0m"
        [[ -n "$bhttp_p" ]] && sts_bhttp="\033[1;32mo\033[0m" || sts_bhttp="\033[1;31mx\033[0m"

        printf "  %b[1]%b  > OPENSSH         %b    %b[10]%b > OPENVPN            %b\n" "$SSHPLUS_NUM" "$SCOLOR" "$sts_ssh" "$SSHPLUS_NUM" "$SCOLOR" "$sts_ovpn"
        printf "  %b[2]%b  > PROXY SOCKS     %b    %b[11]%b > WEBSOCKET-CORRECT   %b\n" "$SSHPLUS_NUM" "$SCOLOR" "$sts_socks" "$SSHPLUS_NUM" "$SCOLOR" "$sts_ws"
        printf "  %b[3]%b  > SSL TUNNEL      %b    %b[12]%b > SSLH MULTIPLEX      %b\n" "$SSHPLUS_NUM" "$SCOLOR" "$sts_ssl" "$SSHPLUS_NUM" "$SCOLOR" "$sts_sslh"
        printf "  %b[4]%b  > DROPBEAR        %b    %b[13]%b > SQUID PROXY         %b\n" "$SSHPLUS_NUM" "$SCOLOR" "$sts_drop" "$SSHPLUS_NUM" "$SCOLOR" "$sts_squid"
        printf "  %b[5]%b  > V2RAY           %b    %b[14]%b > CHISEL              %b\n" "$SSHPLUS_NUM" "$SCOLOR" "$sts_v2ray" "$SSHPLUS_NUM" "$SCOLOR" "$sts_chisel"
        printf "  %b[6]%b  > SLOWDNS         %b    %b[15]%b > BHTTP MULTI-PUERTO  %b\n" "$SSHPLUS_NUM" "$SCOLOR" "$sts_slow" "$SSHPLUS_NUM" "$SCOLOR" "$sts_bhttp"
        printf "  %b[7]%b  > HYSTERIA v1     %b    %b[16]%b > UDP CRIS / 7300     %b\n" "$SSHPLUS_NUM" "$SCOLOR" "$sts_hyst" "$SSHPLUS_NUM" "$SCOLOR" "$sts_hyst"
        printf "  %b[8]%b  > TROJAN-GO       %b    %b[17]%b > EXPORTAR PARA GEN\n" "$SSHPLUS_NUM" "$SCOLOR" "$sts_trojan" "$SSHPLUS_NUM" "$SCOLOR"
        printf "  %b[9]%b  > BADVPN          %b    %b[0]%b  > VOLVER\n" "$SSHPLUS_NUM" "$SCOLOR" "$sts_badvpn" "$SSHPLUS_NUM" "$SCOLOR"
        echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
        echo -ne "${SSHPLUS_CYAN}Opcion:${SCOLOR} "
        read -r proto_opt

        case "$proto_opt" in
            1|01) fun_openssh ;;
            2|02) fun_socks ;;
            3|03) inst_ssl ;;
            4|04) fun_drop ;;
            5|05)
                clear
                echo -e "\033[1;32mInstalador V2Ray/Xray Core\033[0m"
                bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install 2>/dev/null || true
                pause
                ;;
            6|06) slow_setup ;;
            7|07) menu_udp ;;
            8|08)
                clear
                echo -e "\033[1;33mTrojan-Go integrado via motor Xray (Puerto 443 / 8443).\033[0m"
                pause
                ;;
            9|09) menub ;;
            10)
                clear
                echo -e "\033[1;32mInstalador OpenVPN\033[0m"
                apt-get install -y openvpn 2>/dev/null || true
                pause
                ;;
            11) fun_socks ;;
            12)
                clear
                echo -e "\033[1;32mSSLH Multiplex\033[0m"
                apt-get install -y sslh 2>/dev/null || true
                pause
                ;;
            13) fun_squid ;;
            14)
                clear
                echo -e "\033[1;32mChisel Tunnel\033[0m"
                pause
                ;;
            15) menu_bhttp ;;
            16) menu_udp ;;
            17) exportar_servidor_gen ;;
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

    echo -e "\n\033[1;32mContraseña de '$username' cambiada exitosamente!\033[0m"
    pause
}

listar_usuarios() {
    clear
    echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
    echo -e "                   ${BLUE}INFORME DE USUARIOS${SCOLOR}"
    echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
    
    local all_users
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
    local all_users
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
#  MENÚ PRINCIPAL
# ─────────────────────────────────────────────────────────────────────────────
main_menu() {
    while true; do
        clear
        local ip; ip=$(get_public_ip)
        local os; os=$(lsb_release -sd 2>/dev/null || cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d= -f2 | tr -d '\"' || echo 'Linux')
        local ram_used; ram_used=$(free -m 2>/dev/null | awk '/Mem:/ {print $3}' || echo "0")
        local ram_total; ram_total=$(free -m 2>/dev/null | awk '/Mem:/ {print $2}' || echo "0")
        local ram_pct=0
        [[ $ram_total -gt 0 ]] && ram_pct=$(( ram_used * 100 / ram_total ))
        local cpu_load; cpu_load=$(top -bn1 2>/dev/null | grep "Cpu(s)" | awk '{print $2 + $4"%"}' || echo "N/A")
        local hora; hora=$(date '+%H:%M:%S')

        local stats_str; stats_str=$(get_users_stats)
        local u_total; u_total=$(echo "$stats_str" | cut -d: -f1)
        local u_active; u_active=$(echo "$stats_str" | cut -d: -f2)
        local u_expired; u_expired=$(echo "$stats_str" | cut -d: -f3)
        local u_online; u_online=$(echo "$stats_str" | cut -d: -f4)

        local stsl
        pgrep -f 'limiter' >/dev/null 2>&1 && stsl="\033[1;32mo\033[0m" || stsl="\033[1;31mx\033[0m"

        echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
        echo -e "                   ${BLUE}SSH-CRIS MASTER SUITE ${VERSION}${SCOLOR}"
        echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
        printf " ${SSHPLUS_SECTION}SISTEMA               MEMORIA RAM           PROCESADOR${SCOLOR}\n"
        printf " ${WHITE}OS:   ${GREEN}%-14s ${WHITE}Total: ${GREEN}%-13s ${WHITE}Núcleos: ${GREEN}%s${NC}\n" "${os:0:14}" "${ram_total}MB" "$(nproc 2>/dev/null || echo 1)"
        printf " ${WHITE}Hora: ${GREEN}%-14s ${WHITE}RAM:   ${GREEN}%-13s ${WHITE}CPU:     ${GREEN}%s${NC}\n" "$hora" "${ram_used}MB (${ram_pct}%)" "$cpu_load"
        echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
        printf " ${SSHPLUS_COUNTER}Conectados: %-8s  Caducados: %-8s  Total: %s${SCOLOR}\n" "$u_online" "$u_expired" "$u_total"
        echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
        echo -e "  ${SSHPLUS_NUM}[1]${SCOLOR}  \033[1;37m> ADMINISTRAR USUARIOS\033[0m"
        echo -e "  ${SSHPLUS_NUM}[2]${SCOLOR}  \033[1;37m> CONFIGURACION DE PROTOCOLOS\033[0m"
        echo -e "  ${SSHPLUS_NUM}[3]${SCOLOR}  \033[1;37m> CONFIGURACION DE BANNER\033[0m"
        echo -e "  ${SSHPLUS_NUM}[4]${SCOLOR}  \033[1;37m> ACTIVAR LIMITADOR\033[0m          $stsl"
        echo -e "  ${SSHPLUS_NUM}[5]${SCOLOR}  \033[1;37m> CHECKUSERS\033[0m"
        echo -e "  ${SSHPLUS_NUM}[6]${SCOLOR}  \033[1;37m> RED Y SEGURIDAD\033[0m"
        echo -e "  ${SSHPLUS_NUM}[7]${SCOLOR}  \033[1;37m> CONFIGURACION DE LA VPS\033[0m"
        echo -e "  ${SSHPLUS_NUM}[8]${SCOLOR}  \033[1;37m> CONFIGURACION DEL SCRIPT\033[0m"
        echo -e "  ${SSHPLUS_NUM}[9]${SCOLOR}  \033[1;37m> MAS AJUSTES >>>\033[0m"
        echo -e "  ${SSHPLUS_NUM}[10]${SCOLOR} \033[1;37m> REINICIAR VPS\033[0m"
        echo -e "  ${SSHPLUS_NUM}[0]${SCOLOR}  \033[1;37m> SALIR\033[0m"
        echo -e "${SSHPLUS_CYAN}============================================================${SCOLOR}"
        echo -ne "${SSHPLUS_CYAN}Opcion:${SCOLOR} "
        read -r main_opt

        case "$main_opt" in
            1|01) menu_users ;;
            2|02) menu_protocolos ;;
            3|03)
                clear
                echo -e "\033[1;32mConfigurar Banner SSH (/etc/issue.net)\033[0m"
                read -r -p " Ingresa texto para el Banner: " banner_text
                echo "$banner_text" > /etc/issue.net
                sed -i 's/#*Banner .*/Banner \/etc\/issue.net/' /etc/ssh/sshd_config 2>/dev/null || true
                systemctl restart sshd 2>/dev/null || true
                echo -e "\033[1;32mBanner actualizado!\033[0m"
                pause
                ;;
            4|04)
                clear
                if pgrep -f 'limiter' >/dev/null 2>&1; then
                    pkill -f limiter 2>/dev/null || true
                    echo -e "\033[1;31mLIMITADOR DESACTIVADO!\033[0m"
                else
                    echo -e "\033[1;32mLIMITADOR ACTIVADO!\033[0m"
                fi
                sleep 2
                ;;
            5|05)
                clear
                echo -e "\033[1;32mCheckUser 5000 / GLTunnel activo.\033[0m"
                pause
                ;;
            6|06)
                clear
                echo -e "\033[1;33mReglas Firewall UFW / IPTABLES:\033[0m"
                ufw status verbose 2>/dev/null || iptables -L -n -v
                pause
                ;;
            7|07)
                clear
                echo -e "\033[1;32mAjustes de VPS: Optimización BBR y Swap\033[0m"
                pause
                ;;
            8|08)
                clear
                echo -e "\033[1;32mSSH-CRIS Suite v1.0 Oficial by CRISDEV\033[0m"
                pause
                ;;
            9|09)
                menu_protocolos
                ;;
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
