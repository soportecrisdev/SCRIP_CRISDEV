#!/usr/bin/env bash
# ==============================================================================
# CRISDEV V2Ray / Xray Pro Interactive Menu
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_PY="${SCRIPT_DIR}/v2ray_core.py"
CERT_SH="${SCRIPT_DIR}/cert_manager.sh"
INST_SH="${SCRIPT_DIR}/instalar.sh"

CYAN='\033[1;36m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
WHITE='\033[1;37m'
NC='\033[0m'

pause_key() {
    echo ""
    read -rp "Presiona Enter para continuar..." _
}

draw_header() {
    clear
    local st mode ports users cert svc
    eval "$(python3 "$CORE_PY" status 2>/dev/null | sed 's/^\([A-Z]*\)=\(.*\)/\1="\2"/')"
    local st_color="$RED"
    [[ "$STATE" == "active" ]] && st_color="$GREEN"

    echo -e "${CYAN}============================================================${NC}"
    echo -e "${CYAN}                CRISDEV V2RAY / XRAY PRO${NC}"
    echo -e "${CYAN}============================================================${NC}"
    echo -e "  Estado:   ${st_color}${STATE:-inactivo}${NC} (${SERVICE:-v2ray})  |  Modo: ${WHITE}${MODE:-N/A}${NC}"
    echo -e "  Puertos:  ${YELLOW}${PORTS:-Ninguno}${NC}"
    echo -e "  Usuarios: ${GREEN}${USERS:-0}${NC}  |  Passthrough :80/:443: $(grep -q V2RAY_PASSTHROUGH /usr/local/bin/wsproxy.py 2>/dev/null && echo -e "${GREEN}ACTIVO${NC}" || echo -e "${YELLOW}NO ACTIVO${NC}")"
    echo -e "  Cert TLS: ${WHITE}${CERT:-Sin certificado}${NC}"
    echo -e "${CYAN}------------------------------------------------------------${NC}"
}

menu_ports() {
    while true; do
        clear
        echo -e "${CYAN}=== GESTION DE PUERTOS V2RAY (ANTI-COLISIONES) ===${NC}"
        python3 "$CORE_PY" list-ports
        echo ""
        echo -e "  ${GREEN}[1]${NC} Agregar nuevo puerto"
        echo -e "  ${GREEN}[2]${NC} Eliminar puerto"
        echo -e "  ${GREEN}[3]${NC} Cambiar a Modo Multi-Puerto Pro (8443/2096/8880/8882)"
        echo -e "  ${GREEN}[4]${NC} Cambiar a Modo Puerto Unico"
        echo -e "  ${YELLOW}[0]${NC} Volver"
        read -rp "Opcion: " popt
        case "$popt" in
            1)
                read -rp "Puerto libre (ej. 2087, 2095, 8443): " np
                read -rp "Protocolo (vless/vmess) [vless]: " nproto
                read -rp "Activar TLS? (1=Si / 0=No) [1]: " ntls
                read -rp "Path WebSocket [/vless]: " npath
                python3 "$CORE_PY" add-port --port "$np" --protocol "${nproto:-vless}" --tls "${ntls:-1}" --path "${npath:-/vless}"
                pause_key
                ;;
            2)
                read -rp "Puerto a eliminar: " dp
                python3 "$CORE_PY" del-port --port "$dp"
                pause_key
                ;;
            3)
                python3 "$CORE_PY" init-multi
                pause_key
                ;;
            4)
                read -rp "Puerto unico libre (ej. 2096): " sp
                read -rp "Protocolo (vless/vmess) [vless]: " sproto
                read -rp "Activar TLS? (1=Si / 0=No) [1]: " stls
                read -rp "Path WebSocket [/vless]: " spath
                python3 "$CORE_PY" init-single --port "$sp" --protocol "${sproto:-vless}" --tls "${stls:-1}" --path "${spath:-/vless}"
                pause_key
                ;;
            0) return ;;
        esac
    done
}

menu_users() {
    while true; do
        clear
        echo -e "${CYAN}=== GESTION DE USUARIOS UUID ===${NC}"
        python3 "$CORE_PY" list-users
        echo ""
        echo -e "  ${GREEN}[1]${NC} Crear nuevo usuario UUID"
        echo -e "  ${GREEN}[2]${NC} Eliminar usuario (por UUID o nombre)"
        echo -e "  ${YELLOW}[0]${NC} Volver"
        read -rp "Opcion: " uopt
        case "$uopt" in
            1)
                read -rp "Nombre/etiqueta del usuario (ej. juan): " uname
                read -rp "UUID personalizado (Enter para generar automatico): " ucustom
                python3 "$CORE_PY" add-user --name "$uname" --uuid "$ucustom"
                pause_key
                ;;
            2)
                read -rp "UUID o nombre a eliminar: " udel
                python3 "$CORE_PY" del-user --uuid "$udel"
                pause_key
                ;;
            0) return ;;
        esac
    done
}

menu_gen_client() {
    clear
    echo -e "${CYAN}=== GENERADOR DE LINK Y JSON CLIENTE PRO ===${NC}"
    python3 "$CORE_PY" list-users
    echo ""
    python3 "$CORE_PY" list-ports
    echo ""
    read -rp "Indice o UUID del usuario [1]: " g_uid
    read -rp "Protocolo (vless/vmess) [vless]: " g_proto
    read -rp "Puerto cliente (80, 443, 8443, 2096, 8880) [80]: " g_port
    read -rp "Address (IP VPS o IP limpia Cloudflare, ej. 104.18.36.46): " g_addr
    read -rp "Host WebSocket (ej. c.miclaro.pro o dev.crispdev.online): " g_host
    read -rp "Activar TLS? (1=Si / 0=No) [0]: " g_tls
    read -rp "Activar Mux (concurrency 8)? (1=Si / 0=No) [1]: " g_mux
    read -rp "Path [/vless o /b7YMkKX8/]: " g_path
    read -rp "Nombre/Remark [CRISDEV-V2RAY]: " g_rem

    python3 "$CORE_PY" gen-client \
        --uuid "${g_uid:-1}" \
        --protocol "${g_proto:-vless}" \
        --port "${g_port:-80}" \
        --address "${g_addr:-ip.crispdev.online}" \
        --host "${g_host:-c.miclaro.pro}" \
        --sni "${g_host:-c.miclaro.pro}" \
        --path "${g_path:-/vless}" \
        --tls "${g_tls:-0}" \
        --mux "${g_mux:-1}" \
        --remark "${g_rem:-CRISDEV-V2RAY}" \
        --save
    pause_key
}

menu_diagnostics() {
    clear
    echo -e "${CYAN}=== DIAGNOSTICO EN VIVO V2RAY / XRAY ===${NC}"
    local vbin="/usr/bin/v2ray/v2ray"
    [[ ! -x "$vbin" ]] && vbin="$(command -v v2ray || command -v xray || echo v2ray)"
    echo -e "${YELLOW}[1] Validacion de config.json:${NC}"
    "$vbin" test -c /etc/v2ray/config.json 2>&1 || true
    echo -e "\n${YELLOW}[2] Puertos escuchando (v2ray/wsproxy/stunnel):${NC}"
    ss -tlpn 2>/dev/null | grep -E 'v2ray|xray|wsproxy|stunnel4' || true
    echo -e "\n${YELLOW}[3] Ultimas 15 conexiones en /var/log/v2ray/access.log:${NC}"
    tail -n 15 /var/log/v2ray/access.log 2>/dev/null || echo "(Sin logs aun)"
    pause_key
}

menu_service_control() {
    clear
    echo -e "${CYAN}=== CONTROL DE SERVICIO V2RAY ===${NC}"
    echo "  [1] Reiniciar V2Ray"
    echo "  [2] Detener V2Ray"
    echo "  [3] Iniciar V2Ray"
    echo "  [0] Volver"
    read -rp "Opcion: " sopt
    case "$sopt" in
        1) systemctl restart v2ray 2>/dev/null || systemctl restart xray 2>/dev/null; echo -e "${GREEN}Reiniciado.${NC}"; pause_key ;;
        2) systemctl stop v2ray 2>/dev/null || systemctl stop xray 2>/dev/null; echo -e "${YELLOW}Detenido.${NC}"; pause_key ;;
        3) systemctl start v2ray 2>/dev/null || systemctl start xray 2>/dev/null; echo -e "${GREEN}Iniciado.${NC}"; pause_key ;;
    esac
}

while true; do
    draw_header
    echo -e "  ${GREEN}[1]${NC} > Instalar / Reconfigurar V2Ray (Multi-Puerto o Puerto Unico)"
    echo -e "  ${GREEN}[2]${NC} > Gestionar Puertos (Agregar / Eliminar / Anti-colisiones)"
    echo -e "  ${GREEN}[3]${NC} > Gestionar Usuarios UUID (Crear / Listar / Eliminar)"
    echo -e "  ${GREEN}[4]${NC} > Generar Link (vless:// / vmess://) y JSON Cliente Pro"
    echo -e "  ${GREEN}[5]${NC} > Certificados TLS (Let's Encrypt / Cloudflare / Autofirmado)"
    echo -e "  ${GREEN}[6]${NC} > Sincronizar Passthrough Puerto 80/443 (wsproxy Turbo)"
    echo -e "  ${GREEN}[7]${NC} > Aplicar Tuning Pro (Bloqueo IPv6 + Policy + DNS IPv4 + BBR)"
    echo -e "  ${GREEN}[8]${NC} > Diagnostico en Vivo (test, puertos y logs)"
    echo -e "  ${GREEN}[9]${NC} > Control de Servicio (Reiniciar / Detener / Iniciar)"
    echo -e "  ${YELLOW}[0]${NC} > Volver"
    echo -e "${CYAN}============================================================${NC}"
    read -rp "Opcion: " opt
    case "$opt" in
        1) bash "$INST_SH"; pause_key ;;
        2) menu_ports ;;
        3) menu_users ;;
        4) menu_gen_client ;;
        5) bash "$CERT_SH" menu; pause_key ;;
        6)
            for cand in "/opt/ssh-cris/proxy/wsclasico/wsproxy.py" "/opt/ssh-cris/wsproxy.py"; do
                if [[ -f "$cand" ]]; then
                    cp -af "$cand" /usr/local/bin/wsproxy.py
                    cp -af "$cand" /etc/SSHPlus/wsproxy.py 2>/dev/null || true
                    chmod 755 /usr/local/bin/wsproxy.py /etc/SSHPlus/wsproxy.py 2>/dev/null || true
                    systemctl restart crisdev-ws-python.service 2>/dev/null || true
                    echo -e "${GREEN}[+] wsproxy.py sincronizado y reiniciado.${NC}"
                    break
                fi
            done
            pause_key
            ;;
        7) python3 "$CORE_PY" optimize; pause_key ;;
        8) menu_diagnostics ;;
        9) menu_service_control ;;
        0) exit 0 ;;
        *) echo -e "${RED}Opcion invalida.${NC}"; sleep 1 ;;
    esac
done
