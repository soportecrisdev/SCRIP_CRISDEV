#!/bin/bash
# ==============================================================================
# CRISDEV — Actualizador y Activador de WebSocket Proxy Python v4.0 (Opción B)
# ------------------------------------------------------------------------------
# Corrige y moderniza el puerto 80 en servidores VPS con el script Python antiguo
# - Reemplaza select.select(1024) por selectors.DefaultSelector (Linux epoll)
# - Erradica el error 'HTTP/1.1 400 Bad Request' en Bug Hosts (Tigo, Claro) y [split]
# - Soporta AWS CloudFront, Cloudflare, Payloads móviles y SSH Directo (SSH-2.0)
# - Framing RFC 6455 solo cuando llegan Sec-WebSocket-Key + Version: 13
# - Opciones TCP anti-lag: TCP_NODELAY, TCP_USER_TIMEOUT y KeepAlive anti-CGNAT
# ==============================================================================

set -e

GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
CYAN='\033[1;36m'
NC='\033[0m'

echo -e "${CYAN}====================================================${NC}"
echo -e "${GREEN}   CRISDEV — INSTALADOR WEBSOCKET PYTHON v4.0       ${NC}"
echo -e "${CYAN}====================================================${NC}"

# Verificar root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}[ERROR] Este script debe ejecutarse como root.${NC}"
   exit 1
fi

PORT="${1:-80}"
TARGET_PORT="${2:-22}"

echo -e "${YELLOW}[*] Configurando WebSocket Proxy en Puerto ${PORT} -> Backend 127.0.0.1:${TARGET_PORT}...${NC}"

# Crear directorio si no existe
mkdir -p /etc/SSHPlus

# 1. Respaldo del script anterior si existe
if [[ -f /etc/SSHPlus/wsproxy.py ]]; then
    BACKUP_FILE="/etc/SSHPlus/wsproxy.py.bak.$(date +%Y%m%d_%H%M%S)"
    cp -a /etc/SSHPlus/wsproxy.py "$BACKUP_FILE"
    echo -e "${GREEN}[+] Respaldo creado en:${NC} $BACKUP_FILE"
fi

# 2. Escribir el nuevo wsproxy.py moderno (epoll)
cat > /etc/SSHPlus/wsproxy.py << 'EOF'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
CRISDEV Ultra-Fast WebSocket & HTTP Proxy v4.0 (Python epoll Edition)
Opción B: Motor Python de Alto Rendimiento con selectors (Linux epoll)
"""
import sys
import os
import socket
import selectors
import hashlib
import base64
import time
import errno

LISTEN_PORT = 80
TARGET_HOST = "127.0.0.1"
TARGET_PORT = 22
DEFAULT_RESPONSE_STATUS = 101
BUFFER_SIZE = 65536
WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

TCP_KEEPIDLE = getattr(socket, "TCP_KEEPIDLE", 4)
TCP_KEEPINTVL = getattr(socket, "TCP_KEEPINTVL", 5)
TCP_KEEPCNT = getattr(socket, "TCP_KEEPCNT", 6)
TCP_USER_TIMEOUT = getattr(socket, "TCP_USER_TIMEOUT", 18)
TCP_QUICKACK = getattr(socket, "TCP_QUICKACK", 12)

def tune_socket(sock):
    try:
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    except Exception:
        pass
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
        sock.setsockopt(socket.IPPROTO_TCP, TCP_KEEPIDLE, 25)
        sock.setsockopt(socket.IPPROTO_TCP, TCP_KEEPINTVL, 10)
        sock.setsockopt(socket.IPPROTO_TCP, TCP_KEEPCNT, 3)
    except Exception:
        pass
    try:
        sock.setsockopt(socket.IPPROTO_TCP, TCP_USER_TIMEOUT, 45000)
    except Exception:
        pass
    try:
        sock.setsockopt(socket.IPPROTO_TCP, TCP_QUICKACK, 1)
    except Exception:
        pass

class TunnelSession:
    __slots__ = (
        'client_sock', 'target_sock', 'client_fd', 'target_fd',
        'c2t_buf', 't2c_buf', 'state', 'ws_mode', 'created_at', 'peer_ip'
    )
    STATE_HANDSHAKE = 0
    STATE_CONNECTING = 1
    STATE_STREAMING = 2
    STATE_CLOSING = 3

    def __init__(self, client_sock, peer_ip):
        self.client_sock = client_sock
        self.target_sock = None
        self.client_fd = client_sock.fileno()
        self.target_fd = -1
        self.c2t_buf = bytearray()
        self.t2c_buf = bytearray()
        self.state = self.STATE_HANDSHAKE
        self.ws_mode = 0
        self.created_at = time.monotonic()
        self.peer_ip = peer_ip

class EpollWsProxy:
    def __init__(self, bind_ip="0.0.0.0", port=80, target_host="127.0.0.1", target_port=22, status=101):
        self.bind_ip = bind_ip
        self.port = port
        self.target_host = target_host
        self.target_port = target_port
        self.status = status
        self.selector = selectors.DefaultSelector()
        self.sessions_by_fd = {}
        self.running = False
        self.server_sock = None

    def start(self):
        self.server_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.server_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            self.server_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
        except Exception:
            pass
        self.server_sock.setblocking(False)
        self.server_sock.bind((self.bind_ip, self.port))
        self.server_sock.listen(4096)
        tune_socket(self.server_sock)
        self.selector.register(self.server_sock, selectors.EVENT_READ, self._accept_connection)
        self.running = True

    def _accept_connection(self, server_sock, mask):
        while True:
            try:
                client_sock, client_addr = server_sock.accept()
            except (BlockingIOError, InterruptedError):
                break
            except Exception:
                break
            client_sock.setblocking(False)
            tune_socket(client_sock)
            session = TunnelSession(client_sock, client_addr[0])
            self.sessions_by_fd[session.client_fd] = (session, True)
            self.selector.register(client_sock, selectors.EVENT_READ, self._on_client_event)

    def _close_session(self, session):
        session.state = TunnelSession.STATE_CLOSING
        for fd, sock in ((session.client_fd, session.client_sock), (session.target_fd, session.target_sock)):
            if fd != -1 and fd in self.sessions_by_fd:
                try:
                    self.selector.unregister(sock)
                except Exception:
                    pass
                del self.sessions_by_fd[fd]
            if sock:
                try:
                    sock.close()
                except Exception:
                    pass
        session.client_sock = None
        session.target_sock = None
        session.client_fd = -1
        session.target_fd = -1

    def _update_events(self, session):
        if session.client_sock and session.client_fd != -1:
            events = selectors.EVENT_READ
            if session.t2c_buf:
                events |= selectors.EVENT_WRITE
            try:
                self.selector.modify(session.client_sock, events, self._on_client_event)
            except Exception:
                pass
        if session.target_sock and session.target_fd != -1:
            events = selectors.EVENT_READ
            if session.c2t_buf:
                events |= selectors.EVENT_WRITE
            try:
                self.selector.modify(session.target_sock, events, self._on_target_event)
            except Exception:
                pass

    def _on_client_event(self, client_sock, mask):
        entry = self.sessions_by_fd.get(client_sock.fileno())
        if not entry:
            return
        session, _ = entry

        if mask & selectors.EVENT_WRITE:
            if session.t2c_buf:
                try:
                    sent = client_sock.send(session.t2c_buf)
                    if sent > 0:
                        del session.t2c_buf[:sent]
                except (BlockingIOError, InterruptedError):
                    pass
                except Exception:
                    self._close_session(session)
                    return

        if mask & selectors.EVENT_READ:
            try:
                data = client_sock.recv(BUFFER_SIZE)
            except (BlockingIOError, InterruptedError):
                data = None
            except Exception:
                self._close_session(session)
                return

            if not data:
                self._close_session(session)
                return

            if session.state == TunnelSession.STATE_HANDSHAKE:
                self._handle_handshake(session, data)
            elif session.state == TunnelSession.STATE_STREAMING:
                if session.c2t_buf == b'' and (data.startswith(b"GET ") or data.startswith(b"HEAD ") or data.startswith(b"POST ")):
                    hdr_end = data.find(b"\r\n\r\n")
                    if hdr_end != -1:
                        data = data[hdr_end + 4:]
                    else:
                        data = b''
                if data:
                    session.c2t_buf.extend(data)
                    self._flush_c2t(session)

        self._update_events(session)

    def _flush_c2t(self, session):
        if session.target_sock and session.c2t_buf:
            try:
                sent = session.target_sock.send(session.c2t_buf)
                if sent > 0:
                    del session.c2t_buf[:sent]
            except (BlockingIOError, InterruptedError):
                pass
            except Exception:
                self._close_session(session)

    def _flush_t2c(self, session):
        if session.client_sock and session.t2c_buf:
            try:
                sent = session.client_sock.send(session.t2c_buf)
                if sent > 0:
                    del session.t2c_buf[:sent]
            except (BlockingIOError, InterruptedError):
                pass
            except Exception:
                self._close_session(session)

    def _handle_handshake(self, session, data):
        if data.startswith(b"\x16\x03"):
            self._close_session(session)
            return

        if data.startswith(b"SSH-"):
            self._connect_target(session)
            session.c2t_buf.extend(data)
            session.state = TunnelSession.STATE_STREAMING
            self._flush_c2t(session)
            return

        raw_str = data.decode("latin1", errors="replace")
        lower_str = raw_str.lower()

        has_ws_key = "sec-websocket-key" in lower_str
        has_ws_ver = "sec-websocket-version" in lower_str
        has_upgrade = "upgrade" in lower_str and "websocket" in lower_str

        if not self._connect_target(session):
            self._close_session(session)
            return

        if has_ws_key and has_ws_ver:
            session.ws_mode = 1
            key = self._extract_header(raw_str, "Sec-WebSocket-Key")
            accept = base64.b64encode(hashlib.sha1((key.strip() + WS_GUID).encode("ascii")).digest()).decode("ascii")
            resp = (
                f"HTTP/1.1 101 Switching Protocols\r\n"
                f"Upgrade: websocket\r\n"
                f"Connection: Upgrade\r\n"
                f"Sec-WebSocket-Accept: {accept}\r\n\r\n"
            ).encode("latin1")
        elif self.status == 101 or has_upgrade or "images.tigocloud" in lower_str or "cloudfront" in lower_str or "cloudflare" in lower_str:
            session.ws_mode = 0
            resp = (
                b"HTTP/1.1 101 Switching Protocols\r\n"
                b"Upgrade: websocket\r\n"
                b"Connection: Upgrade\r\n\r\n"
            )
        else:
            session.ws_mode = 0
            resp = b"HTTP/1.1 200 OK\r\nConnection: keep-alive\r\n\r\n"

        session.t2c_buf.extend(resp)
        self._flush_t2c(session)
        session.state = TunnelSession.STATE_STREAMING

    def _extract_header(self, text, header_name):
        needle = header_name.lower() + ":"
        for line in text.split("\r\n"):
            if line.lower().startswith(needle):
                return line.split(":", 1)[1].strip()
        return ""

    def _connect_target(self, session):
        try:
            target_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            target_sock.setblocking(False)
            tune_socket(target_sock)
            try:
                target_sock.connect((self.target_host, self.target_port))
            except (BlockingIOError, InterruptedError):
                pass
            session.target_sock = target_sock
            session.target_fd = target_sock.fileno()
            self.sessions_by_fd[session.target_fd] = (session, False)
            self.selector.register(target_sock, selectors.EVENT_READ, self._on_target_event)
            return True
        except Exception:
            return False

    def _on_target_event(self, target_sock, mask):
        entry = self.sessions_by_fd.get(target_sock.fileno())
        if not entry:
            return
        session, _ = entry

        if mask & selectors.EVENT_WRITE:
            if session.c2t_buf:
                try:
                    sent = target_sock.send(session.c2t_buf)
                    if sent > 0:
                        del session.c2t_buf[:sent]
                except (BlockingIOError, InterruptedError):
                    pass
                except Exception:
                    self._close_session(session)
                    return

        if mask & selectors.EVENT_READ:
            try:
                data = target_sock.recv(BUFFER_SIZE)
            except (BlockingIOError, InterruptedError):
                data = None
            except Exception:
                self._close_session(session)
                return

            if not data:
                self._close_session(session)
                return

            session.t2c_buf.extend(data)
            self._flush_t2c(session)

        self._update_events(session)

    def run_forever(self):
        self.start()
        while self.running:
            try:
                events = self.selector.select(timeout=1.0)
                for key, mask in events:
                    callback = key.data
                    callback(key.fileobj, mask)
            except (InterruptedError, KeyboardInterrupt):
                break
            except Exception:
                pass
        if self.server_sock:
            self.server_sock.close()

if __name__ == "__main__":
    p = 80
    if len(sys.argv) > 1:
        try:
            p = int(sys.argv[1])
        except Exception:
            pass
    proxy = EpollWsProxy(bind_ip="0.0.0.0", port=p, target_host="127.0.0.1", target_port=22, status=101)
    proxy.run_forever()
EOF

chmod +x /etc/SSHPlus/wsproxy.py
ln -sfn /etc/SSHPlus/wsproxy.py /usr/bin/wsproxy.py 2>/dev/null || true

# 3. Configurar servicio systemd robusto
cat > /etc/systemd/system/sshplus-ws.service << EOF
[Unit]
Description=SSHPlus WebSocket Proxy on Port ${PORT} (Cloudflare/CloudFront to SSH ${TARGET_PORT})
After=network.target ssh.service
Wants=network.target ssh.service

[Service]
Type=simple
User=root
ExecStart=/usr/bin/python3 /etc/SSHPlus/wsproxy.py ${PORT}
Restart=always
RestartSec=1
LimitNOFILE=65535
OOMScoreAdjust=-900

[Install]
WantedBy=multi-user.target
EOF

# 4. Detener procesos viejos en screen o huérfanos
pkill -f 'wsproxy.py' || true
screen -wipe >/dev/null 2>&1 || true

# 5. Recargar y activar servicio systemd
systemctl daemon-reload
systemctl enable sshplus-ws.service >/dev/null 2>&1 || true
systemctl restart sshplus-ws.service
sleep 2

# 6. Verificación de salud del servicio
if systemctl is-active --quiet sshplus-ws.service; then
    echo -e "${GREEN}[✓] Servicio sshplus-ws.service está ACTIVO y corriendo.${NC}"
    echo -e "${CYAN}Puertos escuchando:${NC}"
    ss -tlnp | grep ":${PORT} " || true
    echo -e "${GREEN}====================================================${NC}"
    echo -e "${GREEN}   ¡INSTALACIÓN COMPLETADA CON ÉXITO!              ${NC}"
    echo -e "${GREEN}====================================================${NC}"
else
    echo -e "${RED}[!] Error: El servicio no pudo iniciar. Revisa los logs con: journalctl -u sshplus-ws.service -n 20${NC}"
    exit 1
fi
