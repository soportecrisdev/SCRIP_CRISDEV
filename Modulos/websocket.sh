#!/bin/bash
# lang=es websocket.sh
# CRISDEV WebSocket/HTTP Proxy Manager (wsproxy-c native epoll + systemd)
# Gestiona /usr/local/bin/wsproxy-c mediante sshplus-ws.service y /etc/sshplus-ws.conf.

RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[1;38;2;76;228;255m'
NEON='\033[1;38;2;0;255;127m'
WHITE='\033[1;37m'
NC='\033[0m'

RAW_REPO="${SSHPLUS_RAW:-https://raw.githubusercontent.com/${SSHPLUS_GH_USER_REPO:-soportecrisdev/SCRIP_CRISDEV}/${SSHPLUS_GH_BRANCH:-main}}"
WS_BIN="/usr/local/bin/wsproxy-c"
WS_SRC="/usr/local/src/wsproxy-c.c"
WS_CONF="/etc/sshplus-ws.conf"
WS_SERVICE="/etc/systemd/system/sshplus-ws.service"
AUTOSTART="/etc/autostart"

pause_ws() { echo -ne "\n${RED}ENTER ${YELLOW}para volver al menu${NC}"; read -r _; }

need_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        echo -e "${RED}[x] Ejecute como root.${NC}"
        exit 1
    fi
}

cleanup_legacy_ws() {
    for sid in $(screen -ls 2>/dev/null | grep '\.ws' | awk '{print $1}'); do
        screen -r -S "$sid" -X quit 2>/dev/null || true
    done
    for pid in $(pgrep -f '/etc/SSHPlus/wsproxy.py' 2>/dev/null); do
        [[ "$pid" =~ ^[0-9]+$ ]] && kill "$pid" 2>/dev/null || true
    done
    [[ -f "$AUTOSTART" ]] && sed -i '/wsproxy\.py/d' "$AUTOSTART" 2>/dev/null || true
    screen -wipe >/dev/null 2>&1 || true
}

install_wsproxy_c() {
    if [[ -x "$WS_BIN" ]]; then
        return 0
    fi
    mkdir -p /usr/local/src /usr/local/bin
    local arch
    arch="$(uname -m)"
    echo -e "${YELLOW}[*] Instalando motor nativo wsproxy-c (epoll)...${NC}"

    # 1. Intentar compilar desde codigo fuente
    if [[ ! -s "$WS_SRC" ]]; then
        curl -fsSL -H 'Cache-Control: no-cache' "${RAW_REPO}/wsproxy-c.c" -o "$WS_SRC" 2>/dev/null || \
        wget -qO "$WS_SRC" "${RAW_REPO}/wsproxy-c.c" 2>/dev/null || true
    fi
    if [[ -s "$WS_SRC" ]] && command -v gcc >/dev/null 2>&1; then
        if gcc -O2 -Wall -Wextra -o "${WS_BIN}.tmp" "$WS_SRC" 2>/dev/null; then
            mv -f "${WS_BIN}.tmp" "$WS_BIN"
            chmod 755 "$WS_BIN"
            return 0
        fi
        rm -f "${WS_BIN}.tmp"
    fi

    # 2. Fallback: descargar binario precompilado
    local bin_url=""
    if [[ "$arch" == "x86_64" || "$arch" == "amd64" ]]; then
        bin_url="${RAW_REPO}/wsproxy-c-amd64"
    elif [[ "$arch" == "aarch64" || "$arch" == "arm64" ]]; then
        bin_url="${RAW_REPO}/wsproxy-c-arm64"
    fi
    if [[ -n "$bin_url" ]]; then
        curl -fsSL "$bin_url" -o "${WS_BIN}.tmp" 2>/dev/null || \
        wget -qO "${WS_BIN}.tmp" "$bin_url" 2>/dev/null || true
        if [[ -s "${WS_BIN}.tmp" ]]; then
            mv -f "${WS_BIN}.tmp" "$WS_BIN"
            chmod 755 "$WS_BIN"
            return 0
        fi
        rm -f "${WS_BIN}.tmp"
    fi

    echo -e "${RED}[x] No se pudo instalar ${WS_BIN}.${NC}"
    return 1
}

write_ws_conf() {
    local listen_port="$1" redir_port="$2" http_code="$3" banner_msg="$4"
    local clean_msg
    clean_msg="$(printf '%s' "$banner_msg" | tr -d '\r\n"')"
    cat > "$WS_CONF" <<EOF
LISTEN_ADDR=0.0.0.0
LISTEN_PORT=${listen_port}
TARGET_HOST=127.0.0.1
TARGET_PORT=${redir_port}
HTTP_STATUS=${http_code}
BANNER_MSG=${clean_msg}
IDLE_TIMEOUT=300
MAX_CONNS=16384
EOF
    chmod 644 "$WS_CONF"
}

ensure_ws_service() {
    cat > "$WS_SERVICE" <<'EOF'
[Unit]
Description=CRISDEV Native epoll WebSocket/HTTP Proxy (Port 80 CDN/CloudFront/Cloudflare)
After=network-online.target ssh.service
Wants=network-online.target ssh.service
StartLimitIntervalSec=0

[Service]
Type=simple
User=root
EnvironmentFile=-/etc/sshplus-ws.conf
ExecStart=/bin/sh -c 'exec /usr/local/bin/wsproxy-c --bind "${LISTEN_ADDR:-0.0.0.0}" --port "${LISTEN_PORT:-80}" --target "${TARGET_HOST:-127.0.0.1}:${TARGET_PORT:-22}" --status "${HTTP_STATUS:-101}" --idle "${IDLE_TIMEOUT:-300}" --max-conns "${MAX_CONNS:-16384}" ${BANNER_MSG:+--msg "$BANNER_MSG"}'
Restart=always
RestartSec=1
OOMScoreAdjust=-900
LimitNOFILE=65535
MemoryMax=256M
TasksMax=64
NoNewPrivileges=yes
ProtectSystem=full
PrivateTmp=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload >/dev/null 2>&1 || true
}

stop_websocket() {
    systemctl disable --now sshplus-ws.service >/dev/null 2>&1 || true
    cleanup_legacy_ws
}

start_websocket() {
    cleanup_legacy_ws
    ensure_ws_service
    systemctl enable sshplus-ws.service >/dev/null 2>&1 || true
    systemctl restart sshplus-ws.service >/dev/null 2>&1 || true
    sleep 1
    if ! systemctl is-active --quiet sshplus-ws.service 2>/dev/null; then
        echo -e "${RED}[x] WebSocket no pudo iniciar. Revise: journalctl -u sshplus-ws -n 30${NC}"
        return 1
    fi
    return 0
}

port_busy_by_other() {
    local port="$1"
    ss -lntp 2>/dev/null | grep -E ":${port}[[:space:]]" | grep -vqE 'wsproxy-c|wsproxy\.py'
}

main() {
    need_root
    install_wsproxy_c || { pause_ws; exit 1; }

    clear
    echo -e "${BLUE}         WEBSOCKET SSH (wsproxy-c epoll)         ${NC}"
    echo ""
    if systemctl is-active --quiet sshplus-ws.service 2>/dev/null; then
        local cur_port cur_target mem_kb
        cur_port=$(grep '^LISTEN_PORT=' "$WS_CONF" 2>/dev/null | cut -d= -f2)
        cur_target=$(grep '^TARGET_PORT=' "$WS_CONF" 2>/dev/null | cut -d= -f2)
        local pid
        pid=$(systemctl show -p MainPID --value sshplus-ws.service 2>/dev/null)
        mem_kb=$(awk '/^VmRSS:/{print $2}' "/proc/${pid}/status" 2>/dev/null || echo 0)
        echo -e "${GREEN}WebSocket activo (systemd / wsproxy-c)${NC}"
        echo -e "${WHITE}Puerto:${NC} ${cur_port:-80}  ${WHITE}Destino:${NC} 127.0.0.1:${cur_target:-22}  ${WHITE}RAM:${NC} $((mem_kb / 1024)) MB"
        echo ""
        echo -e "${NEON}[1]${NC} ${WHITE}>${NC} ${WHITE}Reiniciar WebSocket${NC}"
        echo -e "${NEON}[2]${NC} ${WHITE}>${NC} ${WHITE}Reconfigurar puerto / destino / banner${NC}"
        echo -e "${NEON}[3]${NC} ${WHITE}>${NC} ${WHITE}Desactivar WebSocket${NC}"
        echo -e "${NEON}[0]${NC} ${WHITE}>${NC} ${WHITE}Volver${NC}"
        echo ""
        echo -ne "${CYAN}Opcion:${NC} "; read -r choice
        case "$choice" in
            1)
                start_websocket && echo -e "${GREEN}WebSocket reiniciado correctamente.${NC}"
                pause_ws
                exit 0
                ;;
            3)
                stop_websocket
                echo -e "${GREEN}WebSocket desactivado.${NC}"
                pause_ws
                exit 0
                ;;
            2) ;;
            *) exit 0 ;;
        esac
    fi

    read -r -e -i 80 -p "Puerto WebSocket a escuchar: " listen_port
    [[ -z "$listen_port" ]] && listen_port=80
    if [[ ! "$listen_port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}[x] Puerto invalido.${NC}"
        pause_ws
        exit 1
    fi
    if port_busy_by_other "$listen_port"; then
        echo -e "${RED}[x] El puerto $listen_port ya esta en uso por otro servicio.${NC}"
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

    read -r -e -i 101 -p "Estado HTTP (101 WebSocket/Cloudflare/CloudFront, 200 directo): " http_code
    [[ -z "$http_code" ]] && http_code=101
    [[ ! "$http_code" =~ ^[0-9]{3}$ ]] && http_code=101
    read -r -p "Minibanner opcional (Enter para limpio - recomendado CDN): " minibanner

    write_ws_conf "$listen_port" "$redir_port" "$http_code" "$minibanner"
    if start_websocket; then
        echo -e "${GREEN}WebSocket (wsproxy-c epoll) activado correctamente.${NC}"
        echo -e "${WHITE}Escucha:${NC} $listen_port  ${WHITE}Destino:${NC} 127.0.0.1:$redir_port"
    fi
    pause_ws
}

main "$@"
