#!/bin/bash
# lang=es websocket.sh
# WebSocket SSH proxy installer/manager. Uses /etc/SSHPlus/wsproxy.py and screen.

RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[1;38;2;76;228;255m'
NEON='\033[1;38;2;0;255;127m'
WHITE='\033[1;37m'
NC='\033[0m'
RAW_REPO="${SSHPLUS_RAW:-https://raw.githubusercontent.com/${SSHPLUS_GH_USER_REPO:-soportecrisdev/SCRIP_CRISDEV}/${SSHPLUS_GH_BRANCH:-main}}"
WS_FILE="/etc/SSHPlus/wsproxy.py"
AUTOSTART="/etc/autostart"
PYBIN="$(command -v python3 || true)"

pause_ws() { echo -ne "\n${RED}ENTER ${YELLOW}para volver al menu${NC}"; read -r _; }

need_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        echo -e "${RED}[x] Ejecute como root.${NC}"
        exit 1
    fi
}

apt_install_ws_deps() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y screen python3 wget curl net-tools >/dev/null 2>&1 || {
        apt-get update -y >/dev/null 2>&1 || true
        apt-get install -y screen python3 wget curl net-tools >/dev/null 2>&1 || true
    }
    PYBIN="$(command -v python3 || true)"
    if [[ -z "$PYBIN" ]]; then
        echo -e "${RED}[x] No se encontro python3.${NC}"
        return 1
    fi
}

valid_ws_file() {
    [[ -s "$WS_FILE" ]] || return 1
    grep -q 'class Server' "$WS_FILE" 2>/dev/null || return 1
    grep -q 'DEFAULT_HOST' "$WS_FILE" 2>/dev/null || return 1
    grep -qiE '<!DOCTYPE|<html' "$WS_FILE" 2>/dev/null && return 1
    "$PYBIN" -m py_compile "$WS_FILE" >/dev/null 2>&1 || return 1
    return 0
}

download_wsproxy() {
    mkdir -p /etc/SSHPlus
    local tmp="${WS_FILE}.new" url="${RAW_REPO}/Modulos/wsproxy.py?_=$(date +%s%N 2>/dev/null || date +%s)"
    rm -f "$tmp"
    if command -v wget >/dev/null 2>&1; then
        wget -qO "$tmp" --header='Cache-Control: no-cache' --header='Pragma: no-cache' "$url" || true
    fi
    if [[ ! -s "$tmp" ]] && command -v curl >/dev/null 2>&1; then
        curl -fsSL -o "$tmp" -H 'Cache-Control: no-cache' "$url" || true
    fi
    if [[ -s "$tmp" ]]; then
        mv -f "$tmp" "$WS_FILE"
        chmod +x "$WS_FILE" 2>/dev/null || true
    fi
    rm -f "$tmp"
    valid_ws_file
}

stop_websocket() {
    for sid in $(screen -ls 2>/dev/null | grep '\.ws' | awk '{print $1}'); do
        screen -r -S "$sid" -X quit 2>/dev/null || true
    done
    for pid in $(pgrep -f '/etc/SSHPlus/wsproxy.py' 2>/dev/null); do
        [[ "$pid" =~ ^[0-9]+$ ]] && kill "$pid" 2>/dev/null || true
    done
    [[ -f "$AUTOSTART" ]] && sed -i '/wsproxy.py/d' "$AUTOSTART" 2>/dev/null || true
    screen -wipe >/dev/null 2>&1 || true
}

port_busy() {
    local port="$1"
    ss -lntp 2>/dev/null | grep -qE ":${port}[[:space:]]" && return 0
    netstat -nltp 2>/dev/null | awk '{print $4}' | grep -qE ":${port}$" && return 0
    return 1
}

patch_wsproxy() {
    local redir="$1" http_code="$2" minibanner="$3" post_header="$4"
    export WS_PATCH_REDIR="$redir" WS_PATCH_HTTP="$http_code"
    WS_PATCH_MSG_B64=$(printf '%s' "$minibanner" | base64 2>/dev/null | tr -d '\n\r')
    WS_PATCH_POST_B64=$(printf '%s' "$post_header" | base64 2>/dev/null | tr -d '\n\r')
    export WS_PATCH_MSG_B64 WS_PATCH_POST_B64
    "$PYBIN" <<'PY' || return 1
import base64
import os
import pathlib
import re
import sys

path = pathlib.Path('/etc/SSHPlus/wsproxy.py')
if not path.is_file():
    sys.exit(1)
text = path.read_text(encoding='utf-8', errors='replace')
redir = os.environ['WS_PATCH_REDIR']
http = os.environ['WS_PATCH_HTTP']
msg = base64.b64decode(os.environ.get('WS_PATCH_MSG_B64', '')).decode('utf-8', errors='replace')
post = base64.b64decode(os.environ.get('WS_PATCH_POST_B64', '')).decode('latin1', errors='replace')

def rep_line(t, name, rhs):
    pat = r'^' + re.escape(name) + r' = .*$'
    if not re.search(pat, t, flags=re.MULTILINE):
        return None
    return re.sub(pat, name + ' = ' + rhs, t, count=1, flags=re.MULTILINE)

for name, rhs in (
    ('DEFAULT_HOST', repr('127.0.0.1:' + redir)),
    ('HTTP_STATUS', repr(http)),
    ('MSG', repr(msg)),
    ('POST_HEADER_RAW', repr(post)),
):
    new_text = rep_line(text, name, rhs)
    if new_text is None:
        sys.stderr.write('Falta la linea ' + name + ' en wsproxy.py\n')
        sys.exit(1)
    text = new_text
path.write_text(text, encoding='utf-8')
PY
}

start_websocket() {
    local listen_port="$1"
    touch /var/log/sshplus-wsproxy.log 2>/dev/null || true
    chmod 644 /var/log/sshplus-wsproxy.log 2>/dev/null || true
    stop_websocket
    screen -dmS ws "$PYBIN" "$WS_FILE" "$listen_port"
    sleep 1
    if ! pgrep -f '/etc/SSHPlus/wsproxy.py' >/dev/null 2>&1; then
        echo -e "${RED}[x] WebSocket no pudo iniciar. Revise /var/log/sshplus-wsproxy.log${NC}"
        return 1
    fi
    [[ -f "$AUTOSTART" ]] || { echo '#!/bin/bash' > "$AUTOSTART"; chmod +x "$AUTOSTART"; }
    sed -i '/wsproxy.py/d' "$AUTOSTART" 2>/dev/null || true
    echo "netstat -tlpn 2>/dev/null | grep -w $listen_port >/dev/null || { screen -r -S 'ws' -X quit 2>/dev/null; screen -dmS ws $PYBIN $WS_FILE $listen_port; }" >> "$AUTOSTART"
    return 0
}

main() {
    need_root
    apt_install_ws_deps || { pause_ws; exit 1; }
    if ! valid_ws_file; then
        echo -e "${YELLOW}[*] Preparando wsproxy.py...${NC}"
        download_wsproxy || {
            echo -e "${RED}[x] No se pudo preparar /etc/SSHPlus/wsproxy.py${NC}"
            pause_ws
            exit 1
        }
    fi

    clear
    echo -e "${BLUE}             WEBSOCKET SSH             ${NC}"
    echo ""
    if pgrep -f '/etc/SSHPlus/wsproxy.py' >/dev/null 2>&1; then
        cur_port=$(ps x | grep '[S]SHPlus/wsproxy.py' | head -1 | awk '{print $NF}')
        echo -e "${GREEN}WebSocket activo${NC} Puerto: ${cur_port:-desconocido}"
        echo ""
        echo -e "${NEON}[1]${NC} ${WHITE}>${NC} ${WHITE}Desactivar WebSocket${NC}"
        echo -e "${NEON}[0]${NC} ${WHITE}>${NC} ${WHITE}Volver${NC}"
        echo ""
        echo -ne "${CYAN}Opcion:${NC} "; read -r choice
        if [[ "$choice" == "1" ]]; then
            stop_websocket
            echo -e "${GREEN}WebSocket desactivado.${NC}"
            pause_ws
        fi
        exit 0
    fi

    read -r -e -i 80 -p "Puerto WebSocket a escuchar: " listen_port
    [[ -z "$listen_port" ]] && listen_port=80
    if [[ ! "$listen_port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}[x] Puerto invalido.${NC}"
        pause_ws
        exit 1
    fi
    if port_busy "$listen_port"; then
        echo -e "${RED}[x] El puerto $listen_port ya esta en uso.${NC}"
        ss -lntp 2>/dev/null | grep -E ":${listen_port}[[:space:]]" || true
        pause_ws
        exit 1
    fi

    read -r -e -i 22 -p "Puerto destino local SSH/VPN: " redir_port
    [[ -z "$redir_port" ]] && redir_port=22
    if [[ ! "$redir_port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}[x] Puerto destino invalido.${NC}"
        pause_ws
        exit 1
    fi

    read -r -e -i 200 -p "Estado HTTP (200 default, 101 WebSocket): " http_code
    [[ -z "$http_code" ]] && http_code=200
    [[ ! "$http_code" =~ ^[0-9]{3}$ ]] && http_code=200
    read -r -p "Minibanner (opcional): " minibanner
    post_header=""

    patch_wsproxy "$redir_port" "$http_code" "$minibanner" "$post_header" || {
        echo -e "${RED}[x] No se pudo configurar wsproxy.py.${NC}"
        pause_ws
        exit 1
    }
    if start_websocket "$listen_port"; then
        echo -e "${GREEN}WebSocket activado correctamente.${NC}"
        echo -e "${WHITE}Escucha:${NC} $listen_port  ${WHITE}Destino:${NC} 127.0.0.1:$redir_port"
    fi
    pause_ws
}

main "$@"
