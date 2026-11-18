#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
=============================================================================
CRISDEV Ultra-Stable WebSocket & HTTP Proxy v4.6 (Python epoll Gaming/VoIP Edition)
-----------------------------------------------------------------------------
Motor WebSocket Clásico Mejorado y Optimizado para CERO Desconexiones,
Juegos en Línea (Bajo Ping / Cero Jitter) y Llamadas VoIP:
  1. Arquitectura Linux epoll pura (selectors.DefaultSelector) sin hilos y
     sin el límite de 1024 descriptores de select.select().
  2. Cero caídas por inactividad: Sin timeouts artificiales en streaming; la
     conexión permanece viva durante horas/días mientras el cliente no corte.
  3. Evasión de muerte por CGNAT móvil (Tigo, Claro, Movistar, Wom, Vivo):
     TCP_KEEPIDLE=20s, TCP_KEEPINTVL=5s, TCP_KEEPCNT=3 en cliente y backend.
  4. Baja Latencia para Juegos y Llamadas VoIP:
     TCP_NODELAY=1 + TCP_QUICKACK=1 + IP_TOS=0x10 (IPTOS_LOWDELAY).
  5. Prevención de Sockets Zombis: TCP_USER_TIMEOUT=30000ms.
  6. Acumulador de Payloads Fragmentados: Soporta paquetes HTTP partidos por
     DPI o [split] hasta detectar \\r\\n\\r\\n (hasta 8KB).
  7. Minibanner HTML en línea de estado HTTP + Encabezados Personalizados.
=============================================================================
"""

import sys
import os
import re
import socket
import selectors
import hashlib
import base64
import time
import errno
import signal
import argparse

WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
BUFFER_SIZE = 65536
MAX_HANDSHAKE_BYTES = 8192

TCP_KEEPIDLE = getattr(socket, "TCP_KEEPIDLE", 4)
TCP_KEEPINTVL = getattr(socket, "TCP_KEEPINTVL", 5)
TCP_KEEPCNT = getattr(socket, "TCP_KEEPCNT", 6)
TCP_USER_TIMEOUT = getattr(socket, "TCP_USER_TIMEOUT", 18)
TCP_QUICKACK = getattr(socket, "TCP_QUICKACK", 12)


def tune_socket_stability(sock):
    """Aplica afinamiento de red de baja latencia y anti-desconexión móvil."""
    # 1. Desactivar Nagle (entrega inmediata para juegos, llamadas y SSH handshake)
    try:
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    except Exception:
        pass

    # 2. Prioridad de baja latencia IP (IPTOS_LOWDELAY = 0x10)
    try:
        sock.setsockopt(socket.IPPROTO_IP, socket.IP_TOS, 0x10)
    except Exception:
        pass

    # 3. Keep-Alive agresivo contra CGNAT móvil (sondeo a los 20s, reintento cada 5s)
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
        sock.setsockopt(socket.IPPROTO_TCP, TCP_KEEPIDLE, 20)
        sock.setsockopt(socket.IPPROTO_TCP, TCP_KEEPINTVL, 5)
        sock.setsockopt(socket.IPPROTO_TCP, TCP_KEEPCNT, 3)
    except Exception:
        pass

    # 4. Timeout de usuario: si un paquete no recibe ACK en 30s, liberar socket
    try:
        sock.setsockopt(socket.IPPROTO_TCP, TCP_USER_TIMEOUT, 30000)
    except Exception:
        pass

    # 5. ACKs rápidos inmediatos (elimina 40ms de Delayed ACK)
    try:
        sock.setsockopt(socket.IPPROTO_TCP, TCP_QUICKACK, 1)
    except Exception:
        pass

    # 6. Buffers equilibrados (evita bufferbloat en juegos sin sacrificar velocidad)
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 65536)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 65536)
    except Exception:
        pass


class TunnelSession:
    """Representa una sesión de túnel cliente <-> backend."""
    __slots__ = (
        'client_sock', 'target_sock', 'client_fd', 'target_fd',
        'c2t_buf', 't2c_buf', 'hs_buf', 'state', 'created_at', 'peer_ip'
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
        self.hs_buf = bytearray()
        self.state = self.STATE_HANDSHAKE
        self.created_at = time.monotonic()
        self.peer_ip = peer_ip


class EpollWsProxy:
    def __init__(self, bind_ip="0.0.0.0", port=80, target_host="127.0.0.1",
                 target_port=22, status=101, banner="", custom_headers=""):
        self.bind_ip = bind_ip
        self.port = int(port)
        self.target_host = target_host
        self.target_port = int(target_port)
        self.status = int(status)
        self.banner = banner.strip() if banner else ""
        self.custom_headers = self._normalize_headers(custom_headers)
        self.running = False
        self.selector = selectors.DefaultSelector()
        self.server_sock = None
        self.sessions_by_fd = {}

    def _normalize_headers(self, raw):
        if not raw:
            return ""
        text = raw.replace("\\r\\n", "\r\n").replace("\\n", "\r\n").strip()
        if not text:
            return ""
        lines = [ln.strip() for ln in text.splitlines() if ln.strip()]
        if not lines:
            return ""
        return "\r\n".join(lines) + "\r\n"

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

        print(f"[+] CRISDEV WS Proxy v4.6 [epoll Gaming/VoIP Zero-Reconnect] activo en {self.bind_ip}:{self.port}", flush=True)
        print(f"[+] Backend destino: {self.target_host}:{self.target_port} (HTTP {self.status})", flush=True)
        if self.banner:
            print(f"[+] Minibanner: {self.banner}", flush=True)

    def _on_accept(self, server_sock, mask):
        while True:
            try:
                client_sock, (client_ip, _client_port) = server_sock.accept()
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

        self.sessions_by_fd.pop(session.client_fd, None)
        self.sessions_by_fd.pop(session.target_fd, None)

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

        # 2. Acumular payloads HTTP fragmentados hasta ver \r\n\r\n (o exceder límite)
        session.hs_buf.extend(raw_bytes)
        if len(session.hs_buf) > MAX_HANDSHAKE_BYTES:
            self._close_session(session)
            return

        # Si parece petición HTTP incompleta, esperar siguiente paquete
        if b"\r\n\r\n" not in session.hs_buf and b"\n\n" not in session.hs_buf:
            # Si no empieza como método HTTP estándar, tratar como payload directo inmediato
            first_word = session.hs_buf[:12].upper()
            http_methods = (b"GET ", b"POST ", b"HEAD ", b"PUT ", b"CONNECT ", b"OPTIONS ", b"PATCH ", b"DELETE ")
            if any(first_word.startswith(m) for m in http_methods):
                return

        full_raw = bytes(session.hs_buf)
        session.hs_buf.clear()

        try:
            raw_str = full_raw.decode("latin1", errors="replace")
        except Exception:
            raw_str = ""

        lower_str = raw_str.lower()
        has_ws_key = "sec-websocket-key" in lower_str
        has_ws_ver = "sec-websocket-version" in lower_str
        has_upgrade = "upgrade" in lower_str and "websocket" in lower_str

        if not self._connect_target(session):
            self._close_session(session)
            return

        reason_101 = self.banner if self.banner else "Switching Protocols"
        reason_200 = self.banner if self.banner else "OK"
        extra_hdrs = self.custom_headers

        # Caso RFC 6455 auténtico (Sec-WebSocket-Key presente)
        if has_ws_key and has_ws_ver:
            key = self._extract_header(raw_str, "Sec-WebSocket-Key")
            accept = base64.b64encode(
                hashlib.sha1((key.strip() + WS_GUID).encode("ascii")).digest()
            ).decode("ascii")
            resp = (
                f"HTTP/1.1 101 {reason_101}\r\n"
                f"Upgrade: websocket\r\n"
                f"Connection: Upgrade\r\n"
                f"Sec-WebSocket-Accept: {accept}\r\n"
                f"{extra_hdrs}\r\n"
            ).encode("latin1")
        # Caso 101 genérico o CDN (Cloudflare / CloudFront / Tigo)
        elif self.status == 101 or has_upgrade or "cloudfront" in lower_str or "cloudflare" in lower_str:
            resp = (
                f"HTTP/1.1 101 {reason_101}\r\n"
                f"Upgrade: websocket\r\n"
                f"Connection: Upgrade\r\n"
                f"{extra_hdrs}\r\n"
            ).encode("latin1")
        # Caso 200 OK clásico (Inyección directa)
        else:
            resp = (
                f"HTTP/1.1 200 {reason_200}\r\n"
                f"Connection: keep-alive\r\n"
                f"Content-Length: 0\r\n"
                f"{extra_hdrs}\r\n"
            ).encode("latin1")

        session.t2c_buf.extend(resp)
        self._flush_t2c(session)

        # Reenviar datos sobrantes tras el fin de cabeceras (payloads [split] o SSH pegado)
        idx = full_raw.find(b"\r\n\r\n")
        sep_len = 4
        if idx == -1:
            idx = full_raw.find(b"\n\n")
            sep_len = 2
        if idx != -1 and (idx + sep_len) < len(full_raw):
            remainder = full_raw[idx + sep_len:]
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

        if mask & selectors.EVENT_WRITE:
            self._flush_t2c(session)

        if mask & selectors.EVENT_READ:
            try:
                data = client_sock.recv(BUFFER_SIZE)
            except (BlockingIOError, InterruptedError):
                return
            except ConnectionResetError:
                self._close_session(session)
                return
            except OSError as e:
                if e.errno in (errno.EAGAIN, errno.EWOULDBLOCK, errno.EINTR):
                    return
                self._close_session(session)
                return

            if not data:
                self._close_session(session)
                return

            if session.state == TunnelSession.STATE_HANDSHAKE:
                self._process_handshake(session, data)
            else:
                session.c2t_buf.extend(data)
                self._flush_c2t(session)

    def _on_target_event(self, target_sock, mask):
        entry = self.sessions_by_fd.get(target_sock.fileno())
        if not entry:
            return
        session, _ = entry

        if mask & selectors.EVENT_WRITE:
            self._flush_c2t(session)

        if mask & selectors.EVENT_READ:
            try:
                data = target_sock.recv(BUFFER_SIZE)
            except (BlockingIOError, InterruptedError):
                return
            except ConnectionResetError:
                self._close_session(session)
                return
            except OSError as e:
                if e.errno in (errno.EAGAIN, errno.EWOULDBLOCK, errno.EINTR):
                    return
                self._close_session(session)
                return

            if not data:
                self._close_session(session)
                return

            session.t2c_buf.extend(data)
            self._flush_t2c(session)

    def _flush_c2t(self, session):
        if session.state == TunnelSession.STATE_CLOSING or not session.target_sock:
            return
        while session.c2t_buf:
            try:
                sent = session.target_sock.send(session.c2t_buf)
                if sent <= 0:
                    break
                del session.c2t_buf[:sent]
            except (BlockingIOError, InterruptedError):
                self._set_write_interest(session.target_sock, self._on_target_event, True)
                return
            except OSError as e:
                if e.errno in (errno.EAGAIN, errno.EWOULDBLOCK, errno.EINTR):
                    self._set_write_interest(session.target_sock, self._on_target_event, True)
                    return
                self._close_session(session)
                return
        self._set_write_interest(session.target_sock, self._on_target_event, False)

    def _flush_t2c(self, session):
        if session.state == TunnelSession.STATE_CLOSING or not session.client_sock:
            return
        while session.t2c_buf:
            try:
                sent = session.client_sock.send(session.t2c_buf)
                if sent <= 0:
                    break
                del session.t2c_buf[:sent]
            except (BlockingIOError, InterruptedError):
                self._set_write_interest(session.client_sock, self._on_client_event, True)
                return
            except OSError as e:
                if e.errno in (errno.EAGAIN, errno.EWOULDBLOCK, errno.EINTR):
                    self._set_write_interest(session.client_sock, self._on_client_event, True)
                    return
                self._close_session(session)
                return
        self._set_write_interest(session.client_sock, self._on_client_event, False)

    def _set_write_interest(self, sock, callback, want_write):
        try:
            key = self.selector.get_key(sock)
            desired = selectors.EVENT_READ | (selectors.EVENT_WRITE if want_write else 0)
            if key.events != desired:
                self.selector.modify(sock, desired, callback)
        except Exception:
            pass

    def serve_forever(self):
        last_sweep = time.monotonic()
        try:
            while self.running:
                events = self.selector.select(timeout=2.0)
                for key, mask in events:
                    callback = key.data
                    callback(key.fileobj, mask)

                # Limpieza exclusiva de handshakes colgados (>15s sin completar HTTP),
                # NUNCA toca conexiones en STATE_STREAMING.
                now = time.monotonic()
                if now - last_sweep >= 10.0:
                    last_sweep = now
                    stale = [
                        sess for sess, is_cli in self.sessions_by_fd.values()
                        if is_cli and sess.state == TunnelSession.STATE_HANDSHAKE and (now - sess.created_at) > 15.0
                    ]
                    for sess in stale:
                        self._close_session(sess)
        except KeyboardInterrupt:
            pass
        finally:
            self.stop()

    def stop(self):
        self.running = False
        for session, is_cli in list(self.sessions_by_fd.values()):
            if is_cli:
                self._close_session(session)
        if self.server_sock:
            try:
                self.selector.unregister(self.server_sock)
            except Exception:
                pass
            try:
                self.server_sock.close()
            except Exception:
                pass
        try:
            self.selector.close()
        except Exception:
            pass


def parse_num(val, default):
    if not val:
        return default
    m = re.search(r'\d+', str(val))
    return int(m.group(0)) if m else default


def main():
    parser = argparse.ArgumentParser(
        description="CRISDEV Ultra-Stable WebSocket Proxy v4.6 (Gaming/VoIP Zero-Reconnect)"
    )
    parser.add_argument("-b", "--bind", default="0.0.0.0", help="IP de escucha")
    parser.add_argument("-p", "--port", type=str, default=None, help="Puerto de escucha")
    parser.add_argument("-t", "--target", default="127.0.0.1:22", help="Backend host:port")
    parser.add_argument("-s", "--status", type=str, default="101", help="Código HTTP (101 o 200)")
    parser.add_argument("-m", "--banner", default="", help="Minibanner HTML o texto")
    parser.add_argument("-H", "--headers", default="", help="Encabezados HTTP extra")
    parser.add_argument("port_pos", nargs="?", type=str, help="Puerto posicional")
    parser.add_argument("target_pos", nargs="?", type=str, help="Destino posicional")
    args = parser.parse_args()

    listen_port = parse_num(args.port if args.port is not None else args.port_pos, 80)
    http_status = parse_num(args.status, 101)
    target_str = args.target_pos if args.target_pos else args.target

    if ":" in target_str:
        t_host, t_port_s = target_str.rsplit(":", 1)
        t_port = parse_num(t_port_s, 22)
    else:
        t_host = "127.0.0.1"
        t_port = parse_num(target_str, 22)

    proxy = EpollWsProxy(
        bind_ip=args.bind,
        port=listen_port,
        target_host=t_host,
        target_port=t_port,
        status=http_status,
        banner=args.banner,
        custom_headers=args.headers
    )

    def _handle_sig(_signum, _frame):
        proxy.running = False

    signal.signal(signal.SIGTERM, _handle_sig)
    signal.signal(signal.SIGINT, _handle_sig)

    proxy.start()
    proxy.serve_forever()


if __name__ == "__main__":
    main()
