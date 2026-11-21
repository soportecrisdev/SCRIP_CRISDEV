#!/usr/bin/env bash
# ==============================================================================
# CRISDEV V2Ray / Xray Pro Installer (Multi-Puerto o Puerto Unico sin Colisiones)
# ==============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_PY="${SCRIPT_DIR}/v2ray_core.py"
CERT_SH="${SCRIPT_DIR}/cert_manager.sh"

CYAN='\033[1;36m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
NC='\033[0m'

install_v2ray_binary() {
    if [[ -x /usr/bin/v2ray/v2ray || -x /usr/local/bin/v2ray ]]; then
        echo -e "${GREEN}[+] V2Ray ya esta instalado.${NC}"
        return 0
    fi
    echo -e "${YELLOW}[*] Instalando V2Ray-core oficial...${NC}"
    apt-get update -qq && apt-get install -y -qq curl unzip jq openssl python3
    bash <(curl -fsSL https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-release.sh)
    mkdir -p /etc/v2ray /var/log/v2ray
    if [[ -f /usr/local/etc/v2ray/config.json && ! -f /etc/v2ray/config.json ]]; then
        ln -sf /usr/local/etc/v2ray/config.json /etc/v2ray/config.json
    fi
}

sync_wsproxy_passthrough() {
    # Asegura que el wsproxy.py con passthrough V2Ray + Turbo Buffers este instalado en /usr/local/bin/wsproxy.py
    local src=""
    for cand in "/opt/ssh-cris/proxy/wsclasico/wsproxy.py" "/opt/ssh-cris/wsproxy.py" "${SCRIPT_DIR}/../../proxy/wsclasico/wsproxy.py"; do
        if [[ -f "$cand" ]] && grep -q "V2RAY_PASSTHROUGH" "$cand" 2>/dev/null; then
            src="$cand"
            break
        fi
    done
    if [[ -n "$src" ]]; then
        cp -af "$src" /usr/local/bin/wsproxy.py
        cp -af "$src" /etc/SSHPlus/wsproxy.py 2>/dev/null || true
        chmod 755 /usr/local/bin/wsproxy.py /etc/SSHPlus/wsproxy.py 2>/dev/null || true
        systemctl restart crisdev-ws-python.service 2>/dev/null || true
        echo -e "${GREEN}[+] wsproxy.py sincronizado con Passthrough V2Ray (puerto 80 / CF Flexible 443).${NC}"
    fi
}

echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN}         INSTALADOR CRISDEV V2RAY / XRAY PRO${NC}"
echo -e "${CYAN}============================================================${NC}"
install_v2ray_binary

echo ""
echo "Selecciona el modo de puertos (Cero colisiones con Stunnel/BHTTP/XHTTP/HCR):"
echo "  [1] Modo Multi-Puerto Pro (Recomendado)"
echo "      -> 8443 (VMess TLS) | 2096 (VLESS TLS) | 8880 (VMess Plain) | 80 & 443 CF (via wsproxy)"
echo "  [2] Modo Puerto Unico Personalizado"
echo "      -> Eliges 1 solo puerto libre, protocolo (VLESS/VMess), TLS y path"
read -rp "Opcion [1]: " mode_opt
mode_opt="${mode_opt:-1}"

if [[ ! -f /etc/ssl/crisdev/fullchain.crt ]]; then
    echo ""
    read -rp "Deseas emitir certificado oficial Let's Encrypt ahora? (s/N): " want_le
    if [[ "${want_le,,}" == "s" ]]; then
        bash "$CERT_SH" letsencrypt
    else
        bash "$CERT_SH" selfsigned "ip.crispdev.online"
    fi
fi

if [[ "$mode_opt" == "2" ]]; then
    read -rp "Puerto libre para V2Ray (ej. 8443 o 2096): " p_single
    read -rp "Protocolo (vless/vmess) [vless]: " proto_single
    read -rp "Activar TLS? (1=Si / 0=No) [1]: " tls_single
    read -rp "Path WebSocket [/vless]: " path_single
    python3 "$CORE_PY" init-single \
        --port "${p_single:-2096}" \
        --protocol "${proto_single:-vless}" \
        --tls "${tls_single:-1}" \
        --path "${path_single:-/vless}"
else
    python3 "$CORE_PY" init-multi
    sync_wsproxy_passthrough
fi

echo -e "${GREEN}[+] Instalacion y configuracion V2Ray Pro completadas.${NC}"
