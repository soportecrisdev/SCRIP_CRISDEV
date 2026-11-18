#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
=============================================================================
CRISDEV Ultra-Stable WebSocket & HTTP Proxy v4.5 (Python epoll Edition)
-----------------------------------------------------------------------------
Motor WebSocket Clásico Mejorado y Optimizado para CERO Desconexiones:
  1. Arquitectura Linux epoll pura (selectors.DefaultSelector) sin hilos y
     sin el límite de 1024 descriptores de select.select().
  2. Cero caídas por inactividad: Sin timeouts artificiales; la conexión
     permanece viva durante horas/días mientras el cliente no se desconecte.
  3. Evasión de muerte por CGNAT móvil (Tigo, Claro, Movistar, Wom, Vivo):
     Inyección de TCP_KEEPIDLE=20s, TCP_KEEPINTVL=5s, TCP_KEEPCNT=3 en cliente
     y backend sshd para mantener los estados NAT de las antenas 4G/5G activos.
  4. Prevención de Sockets Zombis: TCP_USER_TIMEOUT=30000ms para liberar
     sockets muertos al instante sin agotar los límites del usuario.
  5. Buffers elásticos no bloqueantes: Tolera caídas temporales de cobertura
     móvil sin arrojar BrokenPipeError ni abortar la sesión.
  6. Universal Payload Parser: Soporta RFC 6455 (Cloudflare/CloudFront 101),
     Inyección Directa (200 OK), payloads divididos [split] y SSH-2.0 directo.
=============================================================================
"""

import sys
import os
import socket
import selectors
import hashlib
import base64
import time
import errno
import signal
import argparse

WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
BUFFER_SIZE = 65536  # 64 KB para máximo caudal en YouTube / streaming

# Opciones de socket dependientes del kernel
TCP_KEEPIDLE = getattr(socket, "TCP_KEEPIDLE", 4)
TCP_KEEPINTVL = getattr(socket, "TCP_KEEPINTVL", 5)
TCP_KEEPCNT = getattr(socket, "TCP_KEEPCNT", 6)
TCP_USER_TIMEOUT = getattr(socket, "TCP_USER_TIMEOUT", 18)
TCP_QUICKACK = getattr(socket, "TCP_QUICKACK", 12)


def tune_socket_stability(sock):
    """Aplica afinamiento de red para erradicar desconexiones en redes móviles."""
    # 1. Desactivar algoritmo de Nagle (entrega inmediata de paquetes sin delay)
    try:
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    except Exception:
        pass

    # 2. Keep-Alive agresivo contra CGNAT móvil (sondeo a los 20s, reintento cada 5s)
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
        sock.setsockopt(socket.IPPROTO_TCP, TCP_KEEPIDLE, 20)
        sock.setsockopt(socket.IPPROTO_TCP, TCP_KEEPINTVL, 5)
        sock.setsockopt(socket.IPPROTO_TCP, TCP_KEEPCNT, 3)
    except Exception:
        pass

    # 3. Timeout de usuario: si un paquete no recibe ACK en 30s, liberar socket
    try:
        sock.setsockopt(socket.IPPROTO_TCP, TCP_USER_TIMEOUT, 30000)
    except Exception:
        pass

    # 4. ACKs rápidos inmediatos
    try:
        sock.setsockopt(socket.IPPROTO_TCP, TCP_QUICKACK, 1)
    except Exception:
        pass

    # 5. Buffers del kernel ampliados
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 131072)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 131072)
    except Exception:
        pass


class TunnelSession:
    """Representa una sesión de túnel cliente <-> sshd."""
    __slots__ = (
        'client_sock', 'target_sock', 'client_fd', 'target_fd',
        'c2t_buf', 't2c_buf', 'state', 'created_at', 'peer_ip'
    )
    STATE_HANDSHAKE = 0
    STATE_STREAMING = 1
    STATE_CLOSING = 2

    def __init__(self, client_sock, peer_ip):
        self.client_sock = client_sock
        self.target_sock = None
        self.client_fd = client_sock.fileno()
        self.target_fd = -1
        self.c2t_buf = bytearray()
        self.t2c_buf = bytearray()
        self.state = self.STATE_HANDSHAKE
        self.created_at = time.monotonic()
        self.peer_ip = peer_ip


class EpollWsProxy:
    def __init__(self, bind_ip="0.0.0.0", port=80, target_host="127.0.0.1", target_port=22, status=101, banner=""):
        self.bind_ip = bind_ip
        self.port = int(port)
        self.target_host = target_host
        self.target_port = int(target_port)
        self.status = int(status)
        self.banner = banner.strip() if banner else ""
        self.running = False
        self.selector = selectors.DefaultSelector()
        self.server_sock = None
        # fd -> (TunnelSession, is_client)
        self.sessions_by_fd = {}

    def start(self):
        self.server_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.server_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            self.server_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
        except Exception:
            pass

        self.server_sock.setblocking(False)
        self.server_sock.bind((self.bind_ip, self.port))
        self.server_sock.listen(8192)

        self.selector.register(self.server_sock, selectors.EVENT_READ, self._on_accept)
        self.running = True

        status_str = f"HTTP {self.status}"
        engine_name = "epoll Python v4.5 (Zero-Reconnect Edition)"
        print(f"[+] CRISDEV WS Proxy [{engine_name}] activo en {self.bind_ip}:{self.port}")
        print(f"[+] Backend destino: {self.target_host}:{self.target_port} ({status_str})")
        if self.banner:
            print(f"[+] Minibanner: '{self.banner}'")

    def _on_accept(self, server_sock, mask):
        while True:
            try:
                client_sock, (client_ip, client_port) = server_sock.accept()
            except (BlockingIOError, InterruptedError):
                break
            except Exception:
                break

            try:
                client_sock.setblocking(False)
                tune_socket_stability(client_sock)
                session = TunnelSession(client_sock, client_ip)
                self.sessions_by_fd[session.client_fd] = (session, True)
                self.selector.register(client_sock, selectors.EVENT_READ, self._on_client_event)
            except Exception:
                try:
                    client_sock.close()
                except Exception:
                    pass

    def _close_session(self, session):
        if session.state == TunnelSession.STATE_CLOSING:
            return
        session.state = TunnelSession.STATE_CLOSING

        if session.client_fd in self.sessions_by_fd:
            del self.sessions_by_fd[session.client_fd]
        if session.target_fd in self.sessions_by_fd:
            del self.sessions_by_fd[session.target_fd]

        if session.client_sock:
            try:
                self.selector.unregister(session.client_sock)
            except Exception:
                pass
            try:
                session.client_sock.close()
            except Exception:
                pass

        if session.target_sock:
            try:
                self.selector.unregister(session.target_sock)
            except Exception:
                pass
            try:
                session.target_sock.close()
            except Exception:
                pass

    def _connect_target(self, session):
        try:
            target_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            target_sock.setblocking(False)
            tune_socket_stability(target_sock)
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

    def _process_handshake(self, session, raw_bytes):
        # 1. Detección de conexión SSH pura directa
        if raw_bytes.startswith(b"SSH-2.0-") or raw_bytes.startswith(b"SSH-1."):
            if not self._connect_target(session):
                self._close_session(session)
                return
            session.c2t_buf.extend(raw_bytes)
            self._flush_c2t(session)
            session.state = TunnelSession.STATE_STREAMING
            return

        # 2. Análisis de encabezados HTTP / WebSocket
        try:
            raw_str = raw_bytes.decode("latin1", errors="replace")
        except Exception:
            raw_str = ""

        lower_str = raw_str.lower()
        has_ws_key = "sec-websocket-key" in lower_str
        has_ws_ver = "sec-websocket-version" in lower_str
        has_upgrade = "upgrade" in lower_str and "websocket" in lower_str

        if not self._connect_target(session):
            self._close_session(session)
            return

        banner_hdr = f"X-Banner: {self.banner}\r\n" if self.banner else ""

        # Caso RFC 6455 auténtico (Sec-WebSocket-Key presente)
        if has_ws_key and has_ws_ver:
            key = self._extract_header(raw_str, "Sec-WebSocket-Key")
            accept = base64.b64encode(hashlib.sha1((key.strip() + WS_GUID).encode("ascii")).digest()).decode("ascii")
            resp = (
                f"HTTP/1.1 101 Switching Protocols\r\n"
                f"Upgrade: websocket\r\n"
                f"Connection: Upgrade\r\n"
                f"Sec-WebSocket-Accept: {accept}\r\n"
                f"{banner_hdr}\r\n"
            ).encode("latin1")
        # Caso 101 genérico o Cloudflare/CloudFront/Tigo CDN
        elif self.status == 101 or has_upgrade or "images.tigocloud" in lower_str or "cloudfront" in lower_str or "cloudflare" in lower_str:
            resp = (
                f"HTTP/1.1 101 Switching Protocols\r\n"
                f"Upgrade: websocket\r\n"
                f"Connection: Upgrade\r\n"
                f"{banner_hdr}\r\n"
            ).encode("latin1")
        # Caso 200 OK clásico (Inyección directa)
        else:
            resp = (
                f"HTTP/1.1 200 OK\r\n"
                f"Connection: keep-alive\r\n"
                f"Content-Length: 0\r\n"
                f"{banner_hdr}\r\n"
            ).encode("latin1")

        session.t2c_buf.extend(resp)
        self._flush_t2c(session)

        # Si el payload incluía datos sobrantes tras el header HTTP (ej: split), encolarlos
        idx = raw_bytes.find(b"\r\n\r\n")
        if idx != -1 and (idx + 4) < len(raw_bytes):
            remainder = raw_bytes[idx + 4:]
            if remainder:
                session.c2t_buf.extend(remainder)
                self._flush_c2t(session)

        session.state = TunnelSession.STATE_STREAMING

    def _extract_header(self, text, header_name):
        needle = header_name.lower() + ":"
        for line in text.split("\r\n"):
            if line.lower().startswith(needle):
                return line.split(":", 1)[1].strip()
        return ""

    def _on_client_event(self, client_sock, mask):
        entry = self.sessions_by_fd.get(client_sock.fileno())
        if not entry:
            return
        session, _ = entry

        # Escritura pendiente hacia el cliente
        if mask & selectors.EVENT_WRITE:
            self._flush_t2c(session)

        # Lectura entrante desde el cliente
        if mask & selectors.EVENT_READ:
            try:
                data = client_sock.recv(BUFFER_SIZE)
            except (BlockingIOError, InterruptedError):
                data = None
            except Exception:
                self._close_session(session)
                return

            if data is not None:
                if not data:
                    # EOF normal enviado por el cliente
                    self._close_session(session)
                    return

                if session.state == TunnelSession.STATE_HANDSHAKE:
                    self._process_handshake(session, data)
                elif session.state == TunnelSession.STATE_STREAMING:
                    session.c2t_buf.extend(data)
                    self._flush_c2t(session)

        self._update_events(session)

    def _on_target_event(self, target_sock, mask):
        entry = self.sessions_by_fd.get(target_sock.fileno())
        if not entry:
            return
        session, _ = entry

        # Escritura pendiente hacia el backend (sshd)
        if mask & selectors.EVENT_WRITE:
            self._flush_c2t(session)

        # Lectura entrante desde el backend (sshd)
        if mask & selectors.EVENT_READ:
            try:
                data = target_sock.recv(BUFFER_SIZE)
            except (BlockingIOError, InterruptedError):
                data = None
            except Exception:
                self._close_session(session)
                return

            if data is not None:
                if not data:
                    # EOF enviado por sshd
                    self._close_session(session)
                    return

                session.t2c_buf.extend(data)
                self._flush_t2c(session)

        self._update_events(session)

    def _flush_c2t(self, session):
        """Envía datos pendientes del cliente hacia el backend sshd sin bloquear."""
        if not session.c2t_buf or not session.target_sock:
            return
        try:
            sent = session.target_sock.send(session.c2t_buf)
            if sent > 0:
                del session.c2t_buf[:sent]
        except (BlockingIOError, InterruptedError):
            pass
        except Exception:
            self._close_session(session)

    def _flush_t2c(self, session):
        """Envía datos pendientes del backend hacia el cliente sin bloquear."""
        if not session.t2c_buf or not session.client_sock:
            return
        try:
            sent = session.client_sock.send(session.t2c_buf)
            if sent > 0:
                del session.t2c_buf[:sent]
        except (BlockingIOError, InterruptedError):
            pass
        except Exception:
            self._close_session(session)

    def _update_events(self, session):
        """Ajusta las máscaras EVENT_READ / EVENT_WRITE según haya buffers pendientes."""
        if session.state == TunnelSession.STATE_CLOSING:
            return

        # Para el socket cliente:
        if session.client_sock:
            mask = selectors.EVENT_READ
            if session.t2c_buf:
                mask |= selectors.EVENT_WRITE
            try:
                self.selector.modify(session.client_sock, mask, self._on_client_event)
            except Exception:
                pass

        # Para el socket target (sshd):
        if session.target_sock:
            mask = selectors.EVENT_READ
            if session.c2t_buf:
                mask |= selectors.EVENT_WRITE
            try:
                self.selector.modify(session.target_sock, mask, self._on_target_event)
            except Exception:
                pass

    def run_forever(self):
        self.start()
        while self.running:
            try:
                # Polling sin bloqueo excesivo; reacciona en 1s a señales
                events = self.selector.select(timeout=1.0)
                for key, mask in events:
                    callback = key.data
                    callback(key.fileobj, mask)
            except (InterruptedError, KeyboardInterrupt):
                break
            except Exception:
                pass

        if self.server_sock:
            try:
                self.server_sock.close()
            except Exception:
                pass
        self.selector.close()


def main():
    parser = argparse.ArgumentParser(description="CRISDEV Ultra-Stable WS Proxy (Cero Desconexiones)")
    parser.add_argument("port_pos", nargs="?", type=int, default=None, help="Puerto de escucha (posicional)")
    parser.add_argument("target_pos", nargs="?", type=str, default=None, help="Destino host:port (posicional)")
    parser.add_argument("-b", "--bind", default=os.environ.get("WS_BIND", "0.0.0.0"), help="Dirección IP de escucha")
    parser.add_argument("-p", "--port", type=int, default=None, help="Puerto de escucha")
    parser.add_argument("-t", "--target", default=None, help="Destino host:puerto (default 127.0.0.1:22)")
    parser.add_argument("-s", "--status", type=int, default=None, help="Código HTTP (101 o 200)")
    parser.add_argument("-m", "--banner", default=os.environ.get("WS_BANNER", ""), help="Minibanner HTTP personalizado")

    args = parser.parse_args()

    port = args.port or args.port_pos or int(os.environ.get("WS_PORT", 80))
    raw_target = args.target or args.target_pos or os.environ.get("WS_TARGET", "127.0.0.1:22")
    if ":" in raw_target:
        target_host, target_port = raw_target.split(":", 1)
        target_port = int(target_port)
    else:
        target_host = "127.0.0.1"
        target_port = int(raw_target)

    status = args.status or int(os.environ.get("WS_HTTP_STATUS", 101))
    banner = args.banner

    proxy = EpollWsProxy(
        bind_ip=args.bind,
        port=port,
        target_host=target_host,
        target_port=target_port,
        status=status,
        banner=banner
    )

    def sig_handler(sig, frame):
        proxy.running = False

    signal.signal(signal.SIGINT, sig_handler)
    signal.signal(signal.SIGTERM, sig_handler)

    proxy.run_forever()


if __name__ == "__main__":
    main()
