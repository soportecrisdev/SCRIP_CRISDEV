#!/usr/bin/env python3
# encoding: utf-8
# ==============================================================================
# SSHPlus wsproxy.py — Versión Ultra Rápida con Buffers de 64 KB y TCP_NODELAY
# Compatible con inyectores directos (200 OK) y CDNs CloudFront/Cloudflare (101)
# ==============================================================================
import base64
import hashlib
import socket
import threading
import select
import signal
import sys
import time
import getopt
from datetime import datetime

# Limitar stack por hilo a 256 KB para evitar consumo excesivo de RAM
try:
    threading.stack_size(262144)
except Exception:
    pass

PASS = ''
LISTENING_ADDR = '0.0.0.0'
try:
    LISTENING_PORT = int(sys.argv[1])
except Exception:
    LISTENING_PORT = 80

BUFLEN = 65536  # Buffer de 64 KB para máxima velocidad de descarga (YouTube / streaming)
TIMEOUT = 600   # 600 * 3s = 1800s (30 minutos de inactividad total antes de cerrar)
HTTP_STATUS = "200"
MSG = ""
COR = '<font color="null">'
FTAG = '</font>'
POST_HEADER_RAW = ""
DEFAULT_HOST = "127.0.0.1:22"
LOG_FILE = "/var/log/sshplus-wsproxy.log"
WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def _compose_initial_response():
    """Primera respuesta al túnel con formato HTTP estándar para máxima compatibilidad."""
    st = str(HTTP_STATUS).strip()
    post = str(POST_HEADER_RAW or "")
    reason_map = {
        "100": "Continue",
        "101": "Switching Protocols",
        "200": "OK",
        "201": "Created",
        "204": "No Content",
        "300": "Multiple Choices",
        "301": "Moved Permanently",
        "302": "Found",
        "400": "Bad Request",
        "401": "Unauthorized",
        "403": "Forbidden",
        "404": "Not Found",
        "500": "Internal Server Error",
        "502": "Bad Gateway",
        "503": "Service Unavailable",
    }
    reason = reason_map.get(st, "OK")

    def _norm_headers(raw):
        if not raw:
            return ""
        h = raw.replace("\r\n", "\n").replace("\r", "\n").strip("\n")
        if not h:
            return ""
        return h.replace("\n", "\r\n")

    p = _norm_headers(post)
    if st == "101":
        out = (
            "HTTP/1.1 101 Switching Protocols\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
        )
        if p:
            out += p + "\r\n"
        out += "\r\n"
        return out.encode("latin1")

    if st == "200" and not p:
        return (
            b"HTTP/1.1 200 OK\r\n"
            b"Content-Length: 0\r\n"
            b"\r\n"
            b"HTTP/1.1 200 Connection Established\r\n"
            b"\r\n"
        )

    body = (str(COR) + str(MSG) + str(FTAG)).encode("latin1", errors="replace")
    out = f"HTTP/1.1 {st} {reason}\r\n"
    out += "Content-Type: text/html; charset=latin1\r\n"
    out += f"Content-Length: {len(body)}\r\n"
    out += "Connection: keep-alive\r\n"
    if p:
        out += p + "\r\n"
    out += "\r\n"
    return out.encode("latin1") + body


RESPONSE = _compose_initial_response()


def _b(s):
    return s.encode("latin1") if isinstance(s, str) else s


def _optimize_socket(soc):
    """Aplica TCP_NODELAY y buffers amplios para máxima velocidad de navegación y streaming."""
    try:
        soc.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    except Exception:
        pass
    try:
        soc.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 262144)
        soc.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 262144)
    except Exception:
        pass


class Server(threading.Thread):
    def __init__(self, host, port):
        super().__init__()
        self.running = False
        self.host = host
        self.port = port
        self.threads = []
        self.threadsLock = threading.Lock()
        self.logLock = threading.Lock()
        self.soc = None

    def run(self):
        for attempt in range(1, 15):
            try:
                self.soc = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                self.soc.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                if hasattr(socket, 'SO_REUSEPORT'):
                    try:
                        self.soc.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
                    except Exception:
                        pass
                _optimize_socket(self.soc)
                self.soc.settimeout(2)
                self.soc.bind((self.host, self.port))
                self.soc.listen(2048)
                self.running = True
                self.printLog(f"Servidor Proxy Ultra-Veloz activo en {self.host}:{self.port} (Destino={DEFAULT_HOST}, Buf={BUFLEN})")
                break
            except OSError as e:
                self.printLog(f"Bind intento {attempt}/15 en {self.host}:{self.port} fallo ({e}); reintentando en 1s...")
                try:
                    if self.soc:
                        self.soc.close()
                except Exception:
                    pass
                time.sleep(1)

        if not self.running:
            self.printLog(f"FATAL: No se pudo enlazar en {self.host}:{self.port}")
            return

        try:
            while self.running:
                try:
                    c, addr = self.soc.accept()
                    c.setblocking(1)
                    c.settimeout(15)
                    _optimize_socket(c)
                except socket.timeout:
                    continue
                except Exception:
                    continue

                conn = ConnectionHandler(c, self, addr)
                conn.daemon = True
                self.addConn(conn)
                conn.start()
        finally:
            self.running = False
            try:
                if self.soc:
                    self.soc.close()
            except Exception:
                pass

    def printLog(self, log):
        self.logLock.acquire()
        try:
            ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            line = f"[{ts}] [DEBUG] {log}"
            print(line)
            try:
                import os
                mode = "w" if (os.path.exists(LOG_FILE) and os.path.getsize(LOG_FILE) > 2097152) else "a"
                with open(LOG_FILE, mode, encoding="utf-8") as f:
                    f.write(line + "\n")
            except Exception:
                pass
        finally:
            self.logLock.release()

    def addConn(self, conn):
        try:
            self.threadsLock.acquire()
            if self.running:
                self.threads.append(conn)
        finally:
            self.threadsLock.release()

    def removeConn(self, conn):
        try:
            self.threadsLock.acquire()
            if conn in self.threads:
                self.threads.remove(conn)
        except Exception:
            pass
        finally:
            self.threadsLock.release()

    def close(self):
        try:
            self.running = False
            self.threadsLock.acquire()
            threads = list(self.threads)
            for c in threads:
                c.close()
        finally:
            self.threadsLock.release()


class ConnectionHandler(threading.Thread):
    def __init__(self, socClient, server, addr):
        super().__init__()
        self.clientClosed = False
        self.targetClosed = True
        self.client = socClient
        self.client_buffer = b''
        self.server = server
        self.addr = addr
        self.log = 'Connection: ' + str(addr)
        self.target = None

    def close(self):
        try:
            if not self.clientClosed:
                self.client.shutdown(socket.SHUT_RDWR)
                self.client.close()
        except Exception:
            pass
        finally:
            self.clientClosed = True

        try:
            if not self.targetClosed and self.target is not None:
                self.target.shutdown(socket.SHUT_RDWR)
                self.target.close()
        except Exception:
            pass
        finally:
            self.targetClosed = True

    def run(self):
        try:
            try:
                self.server.printLog(
                    'Accepted connection from %s:%s' % (self.addr[0], self.addr[1])
                )
            except Exception:
                self.server.printLog('Accepted connection from ' + str(self.addr))

            try:
                self.client_buffer = self.client.recv(BUFLEN)
            except socket.timeout:
                return

            if not self.client_buffer:
                return

            # Si es un escaneo TLS (Client Hello en puerto 80), cerrar de inmediato
            if self.client_buffer.startswith(b"\x16\x03"):
                return

            # Si el cliente comenzó con SSH directo puro (ej: SSH-2.0-...)
            if self.client_buffer.startswith(b'SSH-'):
                self.method_DIRECT_SSH(DEFAULT_HOST, initial_data=self.client_buffer)
                return

            buf = self.client_buffer
            if isinstance(buf, bytes):
                buf = buf.decode("latin1", errors="replace")

            buf_lower = buf.lower()
            is_vpn = (
                "x-real-host" in buf_lower or
                "x-forward" in buf_lower or
                "upgrade" in buf_lower or
                "websocket" in buf_lower or
                "x-split" in buf_lower or
                "x-pass" in buf_lower or
                buf.startswith("CONNECT ")
            )

            # Si es un simple GET / o POST web sin indicio de VPN ni bughost, responder 400 y salir
            if not is_vpn and (buf.startswith("GET / ") or buf.startswith("POST / ") or buf.startswith("HEAD / ")):
                self.client.sendall(b"HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n")
                return

            # Detección de WebSocket para CDN (CloudFront / Cloudflare)
            is_ws = ("upgrade: websocket" in buf_lower) or ("upgrade" in buf_lower and "websocket" in buf_lower)

            hostPort = self.findHeader(buf, 'X-Real-Host')
            if hostPort == '':
                hostPort = DEFAULT_HOST

            split = self.findHeader(buf, 'X-Split')
            if split != '':
                try:
                    self.client.recv(BUFLEN)
                except Exception:
                    pass

            if hostPort != '':
                passwd = self.findHeader(buf, 'X-Pass')

                if len(PASS) != 0 and passwd == PASS:
                    self.method_CONNECT(hostPort, is_ws=is_ws, buf_raw=buf)
                elif len(PASS) != 0 and passwd != PASS:
                    self.client.send(_b('HTTP/1.1 400 WrongPass!\r\n\r\n'))
                elif hostPort.startswith('127.0.0.1') or hostPort.startswith('localhost'):
                    self.method_CONNECT(hostPort, is_ws=is_ws, buf_raw=buf)
                else:
                    self.client.send(_b('HTTP/1.1 403 Forbidden!\r\n\r\n'))
            else:
                self.client.send(_b('HTTP/1.1 400 NoXRealHost!\r\n\r\n'))

        except Exception as e:
            err = getattr(e, 'strerror', None) or str(e)
            self.log += ' - error: ' + err
            self.server.printLog(self.log)
        finally:
            self.close()
            self.server.removeConn(self)

    def findHeader(self, head, header):
        aux = head.find(header + ': ')
        if aux == -1:
            return ''
        aux = head.find(':', aux)
        head = head[aux + 2:]
        aux = head.find('\r\n')
        if aux == -1:
            return ''
        return head[:aux]

    def connect_target(self, host):
        i = host.find(':')
        if i != -1:
            port = int(host[i + 1:])
            host = host[:i]
        else:
            port = 22

        (soc_family, soc_type, proto, _, address) = socket.getaddrinfo(host, port)[0]

        self.target = socket.socket(soc_family, soc_type, proto)
        self.targetClosed = False
        self.target.settimeout(10)
        self.target.connect(address)
        self.target.settimeout(None)
        _optimize_socket(self.target)
        try:
            self.client.settimeout(None)
        except Exception:
            pass

    def method_DIRECT_SSH(self, path, initial_data=b''):
        self.log += ' - DIRECT_SSH ' + str(path)
        self.connect_target(path)
        if initial_data:
            self.target.sendall(initial_data)
        self.client_buffer = b''
        self.server.printLog('Direct SSH connected to ' + str(path))
        self.doCONNECT()

    def method_CONNECT(self, path, is_ws=False, buf_raw=""):
        self.log += ' - CONNECT ' + path

        self.connect_target(path)

        if is_ws:
            sec_key = self.findHeader(buf_raw, 'Sec-WebSocket-Key')
            if sec_key:
                digest = hashlib.sha1((sec_key.strip() + WS_GUID).encode("ascii", errors="ignore")).digest()
                accept_hdr = base64.b64encode(digest).decode("ascii")
                ws_resp = (
                    f"HTTP/1.1 101 Switching Protocols\r\n"
                    f"Upgrade: websocket\r\n"
                    f"Connection: Upgrade\r\n"
                    f"Sec-WebSocket-Accept: {accept_hdr}\r\n\r\n"
                ).encode("latin1")
            else:
                ws_resp = (
                    b"HTTP/1.1 101 Switching Protocols\r\n"
                    b"Upgrade: websocket\r\n"
                    b"Connection: Upgrade\r\n\r\n"
                )
            self.client.sendall(ws_resp)
        else:
            self.client.sendall(RESPONSE)

        self.client_buffer = b''
        self.server.printLog('Redirected to ' + path + (' (WS 101)' if is_ws else ' (200 OK)'))
        self.doCONNECT()

    def doCONNECT(self):
        """Túnel bidireccional puro y de alta velocidad con sendall y buffers optimizados."""
        socs = [self.client, self.target]
        count = 0
        close_reason = "normal"
        while True:
            count += 1
            try:
                (recv, _, _) = select.select(socs, [], [], 3)
            except Exception as e:
                close_reason = f"select_err: {e}"
                break

            if recv:
                for in_ in recv:
                    try:
                        data = in_.recv(BUFLEN)
                        if data:
                            other = self.client if in_ is self.target else self.target
                            other.sendall(data)
                            count = 0
                        else:
                            side = "target(sshd)" if in_ is self.target else "client"
                            close_reason = f"eof_from_{side}"
                            break
                    except Exception as e:
                        side = "target(sshd)" if in_ is self.target else "client"
                        close_reason = f"recv_err_{side}: {e}"
                        break
                if close_reason != "normal":
                    break

            if count >= TIMEOUT:
                close_reason = f"idle_timeout_{TIMEOUT * 3}s"
                break

        self.server.printLog(f"Connection closed: {close_reason} (client={self.addr})")


def print_usage():
    print('Use: wsproxy.py -p <port>')
    print('       wsproxy.py -b <ip> -p <puerto>')
    print('       wsproxy.py 80')


def parse_args(argv):
    global LISTENING_ADDR
    global LISTENING_PORT
    try:
        opts, args = getopt.getopt(argv, "hb:p:", ["bind=", "port="])
    except getopt.GetoptError:
        print_usage()
        sys.exit(2)
    for opt, arg in opts:
        if opt == '-h':
            print_usage()
            sys.exit()
        elif opt in ("-b", "--bind"):
            LISTENING_ADDR = arg
        elif opt in ("-p", "--port"):
            LISTENING_PORT = int(arg)


def main(host=LISTENING_ADDR, port=LISTENING_PORT):
    print("\033[0;34m━" * 8, "\033[1;32m PROXY WEBSOCKET ULTRA", "\033[0;34m━" * 8, "\n")
    print("\033[1;33mIP:\033[1;32m " + LISTENING_ADDR)
    print("\033[1;33mPUERTO:\033[1;32m " + str(LISTENING_PORT) + "\n")
    print("\033[0;34m━" * 10, "\033[1;32m CRISDEV SPEED BOOST", "\033[0;34m━\033[1;37m" * 11, "\n")

    server = Server(LISTENING_ADDR, LISTENING_PORT)
    server.start()

    while True:
        try:
            time.sleep(2)
        except KeyboardInterrupt:
            print('Parando...')
            server.close()
            break


if __name__ == '__main__':
    if len(sys.argv) > 1 and not sys.argv[1].startswith('-'):
        try:
            LISTENING_PORT = int(sys.argv[1])
        except ValueError:
            pass
    else:
        parse_args(sys.argv[1:])
    main()
