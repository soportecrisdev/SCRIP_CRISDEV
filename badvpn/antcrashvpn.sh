#!/usr/bin/env bash
# Wrapper anti-crash legacy redirigido a configuración calibrada
BIN="/usr/local/bin/badvpn-udpgw"
[[ ! -x "$BIN" ]] && BIN="/bin/badvpn-udpgw"
while true; do
    "$BIN" --listen-addr 127.0.0.1:7300 --max-clients 512 --max-connections-for-client 16 --client-socket-sndbuf 65536 >/dev/null 2>&1
    sleep 1
done
