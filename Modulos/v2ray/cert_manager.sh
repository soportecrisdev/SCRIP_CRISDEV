#!/usr/bin/env bash
# ==============================================================================
# CRISDEV TLS Certificate Manager (Let's Encrypt ECDSA / Cloudflare Origin / Self-Signed)
# Centraliza certificados en /etc/ssl/crisdev/ y recarga stunnel4, v2ray, bhttp-tls, hysteria2.
# ==============================================================================
set -e

SSL_DIR="/etc/ssl/crisdev"
RELOAD_BIN="/usr/local/bin/crisdev-cert-reload.sh"

CYAN='\033[1;36m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
NC='\033[0m'

install_reload_hook() {
    cat > "$RELOAD_BIN" << 'EOF_RELOAD'
#!/usr/bin/env bash
set -e
CERT="/etc/ssl/crisdev/fullchain.crt"
KEY="/etc/ssl/crisdev/private.key"
STUNNEL_PEM="/etc/ssl/crisdev/stunnel.pem"

if [[ -s "$CERT" && -s "$KEY" ]]; then
    cat "$CERT" "$KEY" > "$STUNNEL_PEM"
    chmod 644 "$CERT"
    chmod 600 "$KEY" "$STUNNEL_PEM"

    if [[ -d /etc/stunnel ]]; then
        cp -f "$STUNNEL_PEM" /etc/stunnel/stunnel.pem
        chmod 600 /etc/stunnel/stunnel.pem
        systemctl restart stunnel4 2>/dev/null || /etc/init.d/stunnel4 restart 2>/dev/null || true
    fi

    systemctl restart v2ray 2>/dev/null || systemctl restart xray 2>/dev/null || true

    if [[ -d /etc/bhttp ]]; then
        cp -f "$CERT" /etc/bhttp/server.crt
        cp -f "$KEY" /etc/bhttp/server.key
        chmod 644 /etc/bhttp/server.crt
        chmod 600 /etc/bhttp/server.key
        systemctl restart bhttp-tls 2>/dev/null || true
    fi

    if [[ -d /etc/hysteria2 ]]; then
        cp -f "$CERT" /etc/hysteria2/server.crt
        cp -f "$KEY" /etc/hysteria2/server.key
        chmod 644 /etc/hysteria2/server.crt
        chmod 600 /etc/hysteria2/server.key
        systemctl restart hysteria2 2>/dev/null || true
    fi
fi
EOF_RELOAD
    chmod 755 "$RELOAD_BIN"
}

issue_letsencrypt() {
    local domain="$1"
    if [[ -z "$domain" ]]; then
        read -rp "Dominio apuntando directo a esta VPS (nube gris, ej. ip.crispdev.online): " domain
    fi
    [[ -z "$domain" ]] && { echo -e "${RED}Dominio vacio.${NC}"; return 1; }

    mkdir -p "$SSL_DIR"
    install_reload_hook

    echo -e "${YELLOW}[*] Verificando socat y acme.sh...${NC}"
    command -v socat >/dev/null 2>&1 || (apt-get update -qq && apt-get install -y -qq socat)
    if [[ ! -x /root/.acme.sh/acme.sh ]]; then
        curl -fsSL https://get.acme.sh | sh -s email=admin@crispdev.online >/dev/null 2>&1
    fi
    /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt >/dev/null 2>&1

    echo -e "${YELLOW}[*] Pausando puerto 80 (~10s) para validacion ACME HTTP-01...${NC}"
    systemctl stop crisdev-ws-python.service 2>/dev/null || true
    set +e
    /root/.acme.sh/acme.sh --issue -d "$domain" --standalone --keylength ec-256 --server letsencrypt --force \
        --pre-hook "systemctl stop crisdev-ws-python.service" \
        --post-hook "systemctl start crisdev-ws-python.service"
    local rc=$?
    set -e
    systemctl start crisdev-ws-python.service 2>/dev/null || true

    if [[ $rc -ne 0 ]]; then
        echo -e "${RED}[!] Fallo la emision de Let's Encrypt. Verifica que $domain apunte a la IP real de esta VPS.${NC}"
        return 1
    fi

    /root/.acme.sh/acme.sh --install-cert -d "$domain" --ecc \
        --fullchain-file "$SSL_DIR/fullchain.crt" \
        --key-file "$SSL_DIR/private.key" \
        --reloadcmd "$RELOAD_BIN"

    echo -e "${GREEN}[+] Certificado oficial Let's Encrypt ECDSA instalado y servicios recargados.${NC}"
}

generate_self_signed() {
    local domain="${1:-ip.crispdev.online}"
    mkdir -p "$SSL_DIR"
    install_reload_hook
    openssl ecparam -name prime256v1 -genkey -noout -out "$SSL_DIR/private.key"
    openssl req -new -x509 -key "$SSL_DIR/private.key" -out "$SSL_DIR/fullchain.crt" -days 3650 \
        -subj "/CN=$domain" \
        -addext "subjectAltName=DNS:$domain"
    "$RELOAD_BIN"
    echo -e "${GREEN}[+] Certificado ECDSA autofirmado (10 anos) generado y aplicado.${NC}"
}

install_cloudflare_origin() {
    mkdir -p "$SSL_DIR"
    install_reload_hook
    echo -e "${CYAN}Pega el Origin Certificate de Cloudflare y presiona Ctrl+D al terminar:${NC}"
    cat > "$SSL_DIR/fullchain.crt"
    echo -e "${CYAN}Ahora pega la Private Key de Cloudflare y presiona Ctrl+D al terminar:${NC}"
    cat > "$SSL_DIR/private.key"
    if openssl x509 -in "$SSL_DIR/fullchain.crt" -noout >/dev/null 2>&1; then
        "$RELOAD_BIN"
        echo -e "${GREEN}[+] Certificado Cloudflare Origin instalado y servicios recargados.${NC}"
    else
        echo -e "${RED}[!] Certificado invalido.${NC}"
        return 1
    fi
}

show_status() {
    echo -e "${CYAN}=== ESTADO DE CERTIFICADOS TLS ===${NC}"
    if [[ -f "$SSL_DIR/fullchain.crt" ]]; then
        openssl x509 -in "$SSL_DIR/fullchain.crt" -noout -subject -issuer -dates
    else
        echo -e "${YELLOW}No existe certificado en $SSL_DIR/fullchain.crt${NC}"
    fi
}

case "${1:-menu}" in
    letsencrypt) issue_letsencrypt "${2:-}" ;;
    selfsigned)  generate_self_signed "${2:-ip.crispdev.online}" ;;
    cloudflare)  install_cloudflare_origin ;;
    status)      show_status ;;
    *)
        echo -e "${CYAN}=== GESTOR DE CERTIFICADOS TLS (CRISDEV) ===${NC}"
        echo "  [1] Emitir / Renovar Let's Encrypt Oficial (ECDSA P-256 + Auto-renovacion)"
        echo "  [2] Instalar Certificado Cloudflare Origin CA (15 anos)"
        echo "  [3] Generar Certificado ECDSA Autofirmado (rapido / sin dominio)"
        echo "  [4] Ver estado del certificado actual"
        echo "  [0] Volver"
        read -rp "Opcion: " copt
        case "$copt" in
            1) issue_letsencrypt ;;
            2) install_cloudflare_origin ;;
            3) read -rp "Dominio CN [ip.crispdev.online]: " d; generate_self_signed "${d:-ip.crispdev.online}" ;;
            4) show_status ;;
        esac
        ;;
esac
