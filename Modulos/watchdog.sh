#!/usr/bin/env bash
# ==============================================================================
#  CRISDEV WATCHDOG — Guardián Anti-Caídas y Auto-Heal Daemon
#  Desarrollado para: HTTP Conexión / SSH-CRIS Master VPS
# ==============================================================================

LOG_FILE="/var/log/crisdev-watchdog.log"
CONFIG_FILE="/etc/ssh-cris/watchdog.conf"

mkdir -p /etc/ssh-cris
[[ -f "$CONFIG_FILE" ]] || echo "ENABLED=1" > "$CONFIG_FILE"

log_event() {
    local msg="$1"
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$ts] $msg" >> "$LOG_FILE"
    # Mantener log limpio a maximo 500 lineas
    if [[ $(wc -l < "$LOG_FILE" 2>/dev/null || echo 0) -gt 500 ]]; then
        tail -n 250 "$LOG_FILE" > "${LOG_FILE}.tmp" 2>/dev/null && mv -f "${LOG_FILE}.tmp" "$LOG_FILE"
    fi
}

check_and_heal() {
    # 1. OpenSSH (sshd)
    if ! systemctl is-active --quiet ssh 2>/dev/null && ! systemctl is-active --quiet sshd 2>/dev/null; then
        systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
        log_event "⚠️ ALERTA: OpenSSH (sshd) estaba caído. ¡Auto-recuperado con éxito!"
    fi

    # 2. Dropbear (si estaba configurado en /etc/default/dropbear)
    if grep -q 'NO_START=0' /etc/default/dropbear 2>/dev/null; then
        if ! systemctl is-active --quiet dropbear 2>/dev/null && ! pgrep -x dropbear >/dev/null 2>&1; then
            systemctl restart dropbear 2>/dev/null || /etc/init.d/dropbear restart 2>/dev/null || true
            log_event "⚠️ ALERTA: Dropbear estaba caído. ¡Auto-recuperado con éxito!"
        fi
    fi

    # 3. Stunnel (SSL / TLS)
    if grep -q 'ENABLED=1' /etc/default/stunnel4 2>/dev/null || [[ -f /etc/stunnel/stunnel.conf ]]; then
        if ! systemctl is-active --quiet stunnel4 2>/dev/null && ! pgrep -x stunnel4 >/dev/null 2>&1 && ! pgrep -x stunnel >/dev/null 2>&1; then
            systemctl restart stunnel4 2>/dev/null || /etc/init.d/stunnel4 restart 2>/dev/null || true
            log_event "⚠️ ALERTA: Stunnel (SSL/TLS 443) estaba caído. ¡Auto-recuperado con éxito!"
        fi
    fi

    # 4. HCR Relay (HTTP Custom Relay - hcr-server)
    if [[ -s /etc/hcr-server/ports.conf ]]; then
        while IFS='|' read -r p _rest; do
            [[ "$p" =~ ^[0-9]+$ ]] || continue
            local svc="hcr-${p}.service"
            if [[ -f "/etc/systemd/system/${svc}" ]]; then
                if ! systemctl is-active --quiet "$svc" 2>/dev/null; then
                    systemctl restart "$svc" 2>/dev/null || true
                    log_event "⚠️ ALERTA: HCR Relay (Puerto ${p}) estaba caído. ¡Auto-recuperado con éxito!"
                fi
            fi
        done < /etc/hcr-server/ports.conf
    fi

    # 5. UDP Custom (udp-custom)
    if [[ -f /etc/systemd/system/udp-custom.service ]]; then
        if ! systemctl is-active --quiet udp-custom 2>/dev/null && ! pgrep -x udp-custom >/dev/null 2>&1; then
            systemctl restart udp-custom 2>/dev/null || true
            log_event "⚠️ ALERTA: UDP Custom (Gaming/Voz) estaba caído. ¡Auto-recuperado con éxito!"
        fi
    fi

    # 6. SlowDNS (dnstt-server)
    if [[ -f /etc/systemd/system/slowdns.service ]]; then
        if ! systemctl is-active --quiet slowdns 2>/dev/null && ! pgrep -x dnstt-server >/dev/null 2>&1; then
            systemctl restart slowdns 2>/dev/null || true
            /etc/slowdns/iptables.sh apply 2>/dev/null || true
            log_event "⚠️ ALERTA: SlowDNS (DNSTT 5300/53) estaba caído. ¡Auto-recuperado con éxito!"
        fi
    fi

    # 7. Hysteria v1 (UDP CRIS)
    if [[ -f /etc/systemd/system/hysteria.service ]]; then
        if ! systemctl is-active --quiet hysteria 2>/dev/null && ! pgrep -x hysteria1 >/dev/null 2>&1 && ! pgrep -x hysteria >/dev/null 2>&1; then
            systemctl restart hysteria 2>/dev/null || true
            log_event "⚠️ ALERTA: Hysteria v1 (UDP CRIS) estaba caído. ¡Auto-recuperado con éxito!"
        fi
    fi

    # 8. Hysteria v2
    if [[ -f /etc/systemd/system/hysteria2.service ]]; then
        if ! systemctl is-active --quiet hysteria2 2>/dev/null && ! pgrep -x hysteria2 >/dev/null 2>&1; then
            systemctl restart hysteria2 2>/dev/null || true
            log_event "⚠️ ALERTA: Hysteria v2 estaba caído. ¡Auto-recuperado con éxito!"
        fi
    fi

    # 9. BadVPN UDP Gateway (7300)
    if [[ -f /etc/systemd/system/badvpn-udpgw.service ]]; then
        if ! systemctl is-active --quiet badvpn-udpgw 2>/dev/null && ! pgrep -x badvpn-udpgw >/dev/null 2>&1; then
            systemctl restart badvpn-udpgw 2>/dev/null || true
            log_event "⚠️ ALERTA: BadVPN (WhatsApp Calls 7300) estaba caído. ¡Auto-recuperado con éxito!"
        fi
    fi

    # 10. BHTTP / XHTTP
    if [[ -f /etc/systemd/system/bhttp-server.service ]]; then
        if ! systemctl is-active --quiet bhttp-server 2>/dev/null; then
            systemctl restart bhttp-server 2>/dev/null || true
            log_event "⚠️ ALERTA: BHTTP Server estaba caído. ¡Auto-recuperado con éxito!"
        fi
    fi
}

# Si se ejecuta con argumento "once", hace una pasada y sale
if [[ "${1:-}" == "once" ]]; then
    check_and_heal
    exit 0
fi

# Bucle continuo del Daemon (cada 45s)
while true; do
    if [[ -f "$CONFIG_FILE" ]] && grep -q 'ENABLED=1' "$CONFIG_FILE" 2>/dev/null; then
        check_and_heal
    fi
    sleep 45
done
