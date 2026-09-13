#!/bin/bash
# ============================================================
#  DNS por País - Addon para NoxuraSSH / DoriaxVPN
#  Compatible con: Ubuntu 18.04+ / Debian 9+
#  NO modifica puertos existentes ni servicios activos
#  Solo instala/configura dnsmasq en puerto 53 local
# ============================================================

RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
CYAN='\033[38;2;76;228;255m'
NEON='\033[1;38;2;0;255;127m'
WHITE='\033[1;37m'
SCOLOR='\033[0m'

DNSMASQ_CONF="/etc/dnsmasq.conf"
BACKUP_CONF="/etc/dnsmasq.conf.backup_noxura"
DNS_CONFIG_DIR="/etc/SSHPlus/dns"
DNS_CURRENT_FILE="/etc/SSHPlus/dns/current_country"

# ─────────────────────────────────────────────
# DNS públicos por país/región
# Formato: "DNS_PRIMARIO DNS_SECUNDARIO"
# ─────────────────────────────────────────────
declare -A DNS_PAISES
DNS_PAISES["colombia"]="200.21.225.82 190.254.2.53"        # ETB + Claro Colombia
DNS_PAISES["argentina"]="200.69.218.1 200.69.219.1"        # Telecom Argentina
DNS_PAISES["mexico"]="200.78.225.82 200.33.15.0"           # Telmex México
DNS_PAISES["brasil"]="189.38.95.95 189.38.95.96"           # Claro Brasil
DNS_PAISES["chile"]="200.75.51.2 200.75.51.3"              # Entel Chile
DNS_PAISES["venezuela"]="190.202.1.2 190.202.1.10"         # CANTV Venezuela
DNS_PAISES["peru"]="200.48.225.130 200.48.225.131"         # Telefonica Perú
DNS_PAISES["ecuador"]="200.93.130.133 200.93.130.134"      # CNT Ecuador
DNS_PAISES["bolivia"]="190.129.0.1 190.129.0.2"            # Tigo Bolivia
DNS_PAISES["uruguay"]="200.40.30.245 200.40.30.246"        # Antel Uruguay
DNS_PAISES["paraguay"]="200.4.133.100 200.4.133.101"       # Copaco Paraguay
DNS_PAISES["costarica"]="168.243.254.1 168.243.254.2"      # ICE Costa Rica
DNS_PAISES["honduras"]="201.220.50.1 201.220.50.2"         # Tigo Honduras
DNS_PAISES["guatemala"]="190.111.236.2 190.111.236.3"      # Claro Guatemala
DNS_PAISES["elsalvador"]="190.96.152.1 190.96.152.2"       # Claro El Salvador
DNS_PAISES["nicaragua"]="186.176.193.1 186.176.193.2"      # Claro Nicaragua
DNS_PAISES["panama"]="200.46.200.18 200.46.200.19"         # Cable & Wireless Panamá
DNS_PAISES["dominicanrep"]="190.144.11.2 190.144.11.3"     # Claro Rep. Dominicana
DNS_PAISES["usa"]="8.8.8.8 8.8.4.4"                       # Google USA (default)
DNS_PAISES["cloudflare"]="1.1.1.1 1.0.0.1"                # Cloudflare global
DNS_PAISES["quad9"]="9.9.9.9 149.112.112.112"              # Quad9 (seguro)
DNS_PAISES["opendns"]="208.67.222.222 208.67.220.220"      # Cisco OpenDNS
DNS_PAISES["custom"]=""                                     # DNS personalizado

line() {
    echo -e "${CYAN}============================================================${SCOLOR}"
}

check_root() {
    if [[ "$EUID" -ne 0 ]]; then
        echo -e "${RED}[x] Debe ejecutarse como root.${SCOLOR}"
        exit 1
    fi
}

check_os() {
    if ! grep -qs "ubuntu\|debian" /etc/os-release; then
        echo -e "${RED}[x] Solo compatible con Ubuntu/Debian.${SCOLOR}"
        exit 1
    fi
}

install_dnsmasq() {
    if dpkg -l | grep -q "^ii.*dnsmasq "; then
        echo -e "${GREEN}[✓] dnsmasq ya está instalado.${SCOLOR}"
        return 0
    fi
    echo -e "${YELLOW}[~] Instalando dnsmasq...${SCOLOR}"
    apt-get update -y -qq
    apt-get install -y -qq dnsmasq
    if ! dpkg -l | grep -q "^ii.*dnsmasq "; then
        echo -e "${RED}[x] Error instalando dnsmasq.${SCOLOR}"
        exit 1
    fi
    echo -e "${GREEN}[✓] dnsmasq instalado correctamente.${SCOLOR}"
}

# Verifica si el puerto 53 ya está en uso por otro proceso
check_port53() {
    local process_on_53
    process_on_53=$(ss -lnup 'sport = :53' 2>/dev/null | grep -v dnsmasq | grep -v "^Netid")
    if [[ -n "$process_on_53" ]]; then
        echo -e "${YELLOW}[!] Advertencia: otro proceso usa el puerto 53:${SCOLOR}"
        echo "$process_on_53"
        echo -e "${YELLOW}[!] dnsmasq escuchará en 127.0.0.1:53 solamente.${SCOLOR}"
        LISTEN_LOCAL_ONLY=true
    else
        LISTEN_LOCAL_ONLY=false
    fi
}

backup_config() {
    if [[ -f "$DNSMASQ_CONF" ]] && [[ ! -f "$BACKUP_CONF" ]]; then
        cp "$DNSMASQ_CONF" "$BACKUP_CONF"
        echo -e "${GREEN}[✓] Backup guardado en: ${BACKUP_CONF}${SCOLOR}"
    fi
}

apply_dns() {
    local country="$1"
    local dns1 dns2

    # Si es custom, pedir al usuario
    if [[ "$country" == "custom" ]]; then
        echo -ne "${WHITE}Ingresa DNS primario: ${SCOLOR}"
        read -r dns1
        echo -ne "${WHITE}Ingresa DNS secundario: ${SCOLOR}"
        read -r dns2
        # Validar formato IP básico
        if ! [[ "$dns1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo -e "${RED}[x] IP inválida: $dns1${SCOLOR}"
            return 1
        fi
    else
        local dns_pair="${DNS_PAISES[$country]}"
        if [[ -z "$dns_pair" ]]; then
            echo -e "${RED}[x] País no reconocido: $country${SCOLOR}"
            return 1
        fi
        dns1=$(echo "$dns_pair" | awk '{print $1}')
        dns2=$(echo "$dns_pair" | awk '{print $2}')
    fi

    echo -e "${YELLOW}[~] Aplicando DNS: ${dns1} / ${dns2}${SCOLOR}"

    backup_config
    check_port53

    # Escribir configuración de dnsmasq
    cat > "$DNSMASQ_CONF" <<EOF
# DNS por País - NoxuraSSH Addon
# País activo: ${country}
# Generado: $(date)

# Escuchar en loopback y en la interfaz de red principal
listen-address=127.0.0.1
EOF

    if [[ "$LISTEN_LOCAL_ONLY" != "true" ]]; then
        echo "listen-address=0.0.0.0" >> "$DNSMASQ_CONF"
        echo "bind-interfaces" >> "$DNSMASQ_CONF"
    fi

    cat >> "$DNSMASQ_CONF" <<EOF

# DNS upstream del país seleccionado
server=${dns1}
server=${dns2}

# Fallback universal (Cloudflare)
server=1.1.1.1
server=8.8.8.8

# Cache DNS para mejor rendimiento
cache-size=1000
min-cache-ttl=300

# No leer /etc/resolv.conf (evita conflictos)
no-resolv

# Seguridad: no responder consultas de redes privadas hacia afuera
bogus-priv

# Log opcional (comentar si no se necesita)
# log-queries
# log-facility=/var/log/dnsmasq.log
EOF

    # Reiniciar servicio
    systemctl restart dnsmasq 2>/dev/null || service dnsmasq restart 2>/dev/null
    systemctl enable dnsmasq 2>/dev/null || true

    # Guardar país actual
    mkdir -p "$DNS_CONFIG_DIR"
    echo "$country" > "$DNS_CURRENT_FILE"

    # Actualizar /etc/resolv.conf para que el sistema use nuestro dnsmasq
    # Solo si no está gestionado por systemd-resolved
    if ! systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        chattr -i /etc/resolv.conf 2>/dev/null || true
        echo "nameserver 127.0.0.1" > /etc/resolv.conf
        chattr +i /etc/resolv.conf 2>/dev/null || true
    else
        # Con systemd-resolved, configurar mediante resolvectl
        resolvectl dns lo "${dns1}" "${dns2}" 2>/dev/null || true
    fi

    echo -e "${GREEN}[✓] DNS aplicados para: ${WHITE}${country^^}${SCOLOR}"
    echo -e "${NEON}    DNS1: ${dns1}${SCOLOR}"
    echo -e "${NEON}    DNS2: ${dns2}${SCOLOR}"
}

show_status() {
    line
    echo -e "${WHITE}           ESTADO ACTUAL DEL DNS${SCOLOR}"
    line

    local current="desconocido"
    [[ -f "$DNS_CURRENT_FILE" ]] && current=$(cat "$DNS_CURRENT_FILE")
    echo -e " ${CYAN}País activo:${SCOLOR}  ${WHITE}${current^^}${SCOLOR}"

    echo -e " ${CYAN}Servicio:${SCOLOR}     $(systemctl is-active dnsmasq 2>/dev/null || echo 'no instalado')"

    if systemctl is-active --quiet dnsmasq 2>/dev/null; then
        echo -e " ${CYAN}DNS en uso:${SCOLOR}"
        grep "^server=" "$DNSMASQ_CONF" 2>/dev/null | head -4 | while read -r line_srv; do
            echo -e "   ${NEON}${line_srv}${SCOLOR}"
        done
    fi

    echo -e " ${CYAN}Prueba resolución:${SCOLOR}"
    if command -v dig >/dev/null 2>&1; then
        local resolved
        resolved=$(dig +short google.com @127.0.0.1 2>/dev/null | head -1)
        [[ -n "$resolved" ]] && echo -e "   ${GREEN}google.com → ${resolved}${SCOLOR}" || echo -e "   ${RED}Sin respuesta${SCOLOR}"
    elif command -v nslookup >/dev/null 2>&1; then
        nslookup google.com 127.0.0.1 2>/dev/null | grep "Address:" | tail -1
    fi
    line
}

restore_original() {
    if [[ -f "$BACKUP_CONF" ]]; then
        cp "$BACKUP_CONF" "$DNSMASQ_CONF"
        systemctl restart dnsmasq 2>/dev/null || true
        # Liberar resolv.conf
        chattr -i /etc/resolv.conf 2>/dev/null || true
        echo -e "${GREEN}[✓] Configuración original restaurada.${SCOLOR}"
    else
        echo -e "${YELLOW}[!] No hay backup disponible.${SCOLOR}"
    fi
}

uninstall_dns() {
    echo -ne "${YELLOW}[!] ¿Desinstalar dnsmasq y restaurar config original? [s/N]: ${SCOLOR}"
    read -r confirm
    if [[ "${confirm,,}" == "s" ]]; then
        restore_original
        chattr -i /etc/resolv.conf 2>/dev/null || true
        systemctl stop dnsmasq 2>/dev/null || true
        apt-get remove -y dnsmasq 2>/dev/null || true
        rm -rf "$DNS_CONFIG_DIR"
        echo -e "${GREEN}[✓] dnsmasq removido y configuración restaurada.${SCOLOR}"
    fi
}

show_menu() {
    clear
    line
    echo -e "${WHITE}         DNS POR PAÍS - NoxuraSSH Addon${SCOLOR}"
    echo -e "${CYAN}         Servidor: USA | Sin afectar servicios${SCOLOR}"
    line
    echo -e " ${NEON}[1]${SCOLOR}  🇨🇴 ${WHITE}Colombia${SCOLOR}          ${CYAN}(ETB / Claro)${SCOLOR}"
    echo -e " ${NEON}[2]${SCOLOR}  🇦🇷 ${WHITE}Argentina${SCOLOR}         ${CYAN}(Telecom)${SCOLOR}"
    echo -e " ${NEON}[3]${SCOLOR}  🇲🇽 ${WHITE}México${SCOLOR}            ${CYAN}(Telmex)${SCOLOR}"
    echo -e " ${NEON}[4]${SCOLOR}  🇧🇷 ${WHITE}Brasil${SCOLOR}            ${CYAN}(Claro BR)${SCOLOR}"
    echo -e " ${NEON}[5]${SCOLOR}  🇨🇱 ${WHITE}Chile${SCOLOR}             ${CYAN}(Entel)${SCOLOR}"
    echo -e " ${NEON}[6]${SCOLOR}  🇻🇪 ${WHITE}Venezuela${SCOLOR}         ${CYAN}(CANTV)${SCOLOR}"
    echo -e " ${NEON}[7]${SCOLOR}  🇵🇪 ${WHITE}Perú${SCOLOR}              ${CYAN}(Telefónica)${SCOLOR}"
    echo -e " ${NEON}[8]${SCOLOR}  🇪🇨 ${WHITE}Ecuador${SCOLOR}           ${CYAN}(CNT)${SCOLOR}"
    echo -e " ${NEON}[9]${SCOLOR}  🇧🇴 ${WHITE}Bolivia${SCOLOR}           ${CYAN}(Tigo)${SCOLOR}"
    echo -e " ${NEON}[10]${SCOLOR} 🇺🇾 ${WHITE}Uruguay${SCOLOR}           ${CYAN}(Antel)${SCOLOR}"
    echo -e " ${NEON}[11]${SCOLOR} 🇵🇾 ${WHITE}Paraguay${SCOLOR}          ${CYAN}(Copaco)${SCOLOR}"
    echo -e " ${NEON}[12]${SCOLOR} 🇨🇷 ${WHITE}Costa Rica${SCOLOR}        ${CYAN}(ICE)${SCOLOR}"
    echo -e " ${NEON}[13]${SCOLOR} 🇭🇳 ${WHITE}Honduras${SCOLOR}          ${CYAN}(Tigo HN)${SCOLOR}"
    echo -e " ${NEON}[14]${SCOLOR} 🇬🇹 ${WHITE}Guatemala${SCOLOR}         ${CYAN}(Claro GT)${SCOLOR}"
    echo -e " ${NEON}[15]${SCOLOR} 🇸🇻 ${WHITE}El Salvador${SCOLOR}       ${CYAN}(Claro SV)${SCOLOR}"
    echo -e " ${NEON}[16]${SCOLOR} 🇳🇮 ${WHITE}Nicaragua${SCOLOR}         ${CYAN}(Claro NI)${SCOLOR}"
    echo -e " ${NEON}[17]${SCOLOR} 🇵🇦 ${WHITE}Panamá${SCOLOR}            ${CYAN}(Cable&W)${SCOLOR}"
    echo -e " ${NEON}[18]${SCOLOR} 🇩🇴 ${WHITE}Rep. Dominicana${SCOLOR}   ${CYAN}(Claro DO)${SCOLOR}"
    line
    echo -e " ${NEON}[19]${SCOLOR} 🇺🇸 ${WHITE}USA${SCOLOR}               ${CYAN}(Google 8.8.8.8)${SCOLOR}"
    echo -e " ${NEON}[20]${SCOLOR} 🌐 ${WHITE}Cloudflare${SCOLOR}         ${CYAN}(1.1.1.1 global)${SCOLOR}"
    echo -e " ${NEON}[21]${SCOLOR} 🌐 ${WHITE}Quad9${SCOLOR}              ${CYAN}(9.9.9.9 seguro)${SCOLOR}"
    echo -e " ${NEON}[22]${SCOLOR} 🌐 ${WHITE}OpenDNS${SCOLOR}            ${CYAN}(208.67.222.222)${SCOLOR}"
    echo -e " ${NEON}[23]${SCOLOR} ✏️  ${WHITE}DNS Personalizado${SCOLOR}"
    line
    echo -e " ${NEON}[s]${SCOLOR}  Ver estado actual"
    echo -e " ${NEON}[r]${SCOLOR}  Restaurar config original"
    echo -e " ${NEON}[u]${SCOLOR}  Desinstalar addon"
    echo -e " ${NEON}[0]${SCOLOR}  Salir"
    line

    # Mostrar país activo si existe
    if [[ -f "$DNS_CURRENT_FILE" ]]; then
        echo -e " ${GREEN}▶ Activo: $(cat "$DNS_CURRENT_FILE" | tr '[:lower:]' '[:upper:]')${SCOLOR}"
        line
    fi

    echo -ne "${WHITE}Opción: ${SCOLOR}"
    read -r opt

    case "$opt" in
        1)  install_dnsmasq && apply_dns "colombia" ;;
        2)  install_dnsmasq && apply_dns "argentina" ;;
        3)  install_dnsmasq && apply_dns "mexico" ;;
        4)  install_dnsmasq && apply_dns "brasil" ;;
        5)  install_dnsmasq && apply_dns "chile" ;;
        6)  install_dnsmasq && apply_dns "venezuela" ;;
        7)  install_dnsmasq && apply_dns "peru" ;;
        8)  install_dnsmasq && apply_dns "ecuador" ;;
        9)  install_dnsmasq && apply_dns "bolivia" ;;
        10) install_dnsmasq && apply_dns "uruguay" ;;
        11) install_dnsmasq && apply_dns "paraguay" ;;
        12) install_dnsmasq && apply_dns "costarica" ;;
        13) install_dnsmasq && apply_dns "honduras" ;;
        14) install_dnsmasq && apply_dns "guatemala" ;;
        15) install_dnsmasq && apply_dns "elsalvador" ;;
        16) install_dnsmasq && apply_dns "nicaragua" ;;
        17) install_dnsmasq && apply_dns "panama" ;;
        18) install_dnsmasq && apply_dns "dominicanrep" ;;
        19) install_dnsmasq && apply_dns "usa" ;;
        20) install_dnsmasq && apply_dns "cloudflare" ;;
        21) install_dnsmasq && apply_dns "quad9" ;;
        22) install_dnsmasq && apply_dns "opendns" ;;
        23) install_dnsmasq && apply_dns "custom" ;;
        s|S) show_status ;;
        r|R) restore_original ;;
        u|U) uninstall_dns ;;
        0)  echo -e "${CYAN}Saliendo...${SCOLOR}" ; exit 0 ;;
        *)  echo -e "${RED}[x] Opción inválida.${SCOLOR}" ;;
    esac

    echo ""
    echo -ne "${YELLOW}Presiona Enter para continuar...${SCOLOR}"
    read -r
    show_menu
}

# ─────────────────────────────────────────────
# ENTRADA PRINCIPAL
# ─────────────────────────────────────────────
check_root
check_os

# Permite uso directo: bash dns_paises.sh colombia
if [[ -n "${1:-}" ]]; then
    install_dnsmasq
    apply_dns "$1"
else
    show_menu
fi
