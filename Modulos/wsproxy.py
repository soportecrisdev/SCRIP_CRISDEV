#!/usr/bin/env python3
# encoding: utf-8
# Python 3 (Ubuntu 22+); compatible con llamada: wsproxy.py <porta> [destino]
import socket
import threading
import select
import signal
import sys
import time
import getopt
from datetime import datetime

PASS = ''
LISTENING_ADDR = '0.0.0.0'
try:
    LISTENING_PORT = int(sys.argv[1])
except Exception:
    LISTENING_PORT = 80

DEFAULT_HOST = "127.0.0.1:22"
if len(sys.argv) > 2 and not sys.argv[2].startswith("-"):
    DEFAULT_HOST = sys.argv[2].strip()

BUFLEN = 4096 * 4
TIMEOUT = 60
# Código de respuesta HTTP inicial (compatibilidad general: 200 por defecto)
HTTP_STATUS = "200"
MSG = ""
COR = '<font color="null">'
FTAG = '</font>'
POST_HEADER_RAW = ""
LOG_FILE = "/var/log/sshplus-wsproxy.log"


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

    # Para otros códigos, mantenemos el minibanner como cuerpo HTML y la línea de estado RFC.
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


class Server(threading.Thread):
    def __init__(self, host, port):
        threading.Thread.__init__(self)
        self.running = False
        self.host = host
        self.port = port
        self.threads = []
        self.threadsLock = threading.Lock()
        self.logLock = threading.Lock()

    def run(self):
        self.soc = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.soc.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.soc.settimeout(2)
        self.soc.bind((self.host, self.port))
        self.soc.listen(128)
        self.running = True

        try:
            while self.running:
                try:
                    c, addr = self.soc.accept()
                    c.setblocking(1)
                except socket.timeout:
                    continue

                conn = ConnectionHandler(c, self, addr)
                conn.start()
                self.addConn(conn)
        finally:
            self.running = False
            try:
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
                with open(LOG_FILE, "a", encoding="utf-8") as f:
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
        threading.Thread.__init__(self)
        self.clientClosed = False
        self.targetClosed = True
        self.client = socClient
        self.client_buffer = b''
        self.server = server
        self.addr = addr
        self.log = 'Connection: ' + str(addr)

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
            if not self.targetClosed:
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

            # ─────────────────────────────────────────────────────────────────
            # MULTIPLEXOR INTELIGENTE: SSH DIRECTO (puro) vs WEBSOCKET / PAYLOAD
            # ─────────────────────────────────────────────────────────────────
            # 1. Esperamos hasta 0.35s para ver si el cliente transmite datos de inmediato.
            r, _, _ = select.select([self.client], [], [], 0.35)
            if not r:
                # Comportamiento SSH Directo Pasivo: el cliente SSH espera a que el
                # servidor OpenSSH envíe su banner SSH-2.0-... primero.
                self.method_DIRECT_SSH(DEFAULT_HOST, initial_data=b'')
                return

            self.client_buffer = self.client.recv(BUFLEN)
            if not self.client_buffer:
                return

            # 2. Si el cliente comenzó con "SSH-" (ej: SSH-2.0-OpenSSH / SSH-2.0-GoCore / SSH-2.0-HTTPCustom)
            #    Es un cliente SSH Directo Activo. Conectar y entregar el banner directo a OpenSSH.
            if self.client_buffer.startswith(b'SSH-'):
                self.method_DIRECT_SSH(DEFAULT_HOST, initial_data=self.client_buffer)
                return

            # 3. El cliente envió una petición HTTP (Payload / WebSocket)
            buf = self.client_buffer
            if isinstance(buf, bytes):
                buf = buf.decode("latin1", errors="replace")

            hostPort = self.findHeader(buf, 'X-Real-Host')
            if hostPort == '':
                hostPort = DEFAULT_HOST

            split = self.findHeader(buf, 'X-Split')
            if split != '':
                self.client.recv(BUFLEN)

            # Detección de WebSocket Upgrade para responder 101 si es necesario
            buf_lower = buf.lower()
            is_ws = ("upgrade: websocket" in buf_lower) or ("upgrade" in buf_lower and "websocket" in buf_lower)

            if hostPort != '':
                passwd = self.findHeader(buf, 'X-Pass')

                if len(PASS) != 0 and passwd == PASS:
                    self.method_CONNECT(hostPort, is_ws=is_ws)
                elif len(PASS) != 0 and passwd != PASS:
                    self.client.send(_b('HTTP/1.1 400 WrongPass!\r\n\r\n'))
                elif hostPort.startswith('127.0.0.1') or hostPort.startswith('localhost') or hostPort.startswith(LISTENING_ADDR):
                    self.method_CONNECT(hostPort, is_ws=is_ws)
                else:
                    self.client.send(_b('HTTP/1.1 403 Forbidden!\r\n\r\n'))
            else:
                self.method_DIRECT_SSH(DEFAULT_HOST, initial_data=b'')

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

    def method_DIRECT_SSH(self, path, initial_data=b''):
        """Túnel SSH Directo transparente (sin inyectar cabeceras HTTP ficticias)."""
        self.log += ' - DIRECT_SSH ' + str(path)
        self.connect_target(path)
        if initial_data:
            self.target.sendall(initial_data)
        self.client_buffer = b''
        self.server.printLog('Direct SSH connected to ' + str(path))
        self.doCONNECT()

    def method_CONNECT(self, path, is_ws=False):
        """Conexión con Payload / WebSocket."""
        self.log += ' - CONNECT ' + str(path)
        self.connect_target(path)
        if is_ws and HTTP_STATUS == "200":
            # Si el cliente solicita WebSocket Upgrade y el status está en 200,
            # enviar 101 Switching Protocols para máxima compatibilidad con CDNs
            ws_resp = (
                b"HTTP/1.1 101 Switching Protocols\r\n"
                b"Upgrade: websocket\r\n"
                b"Connection: Upgrade\r\n\r\n"
            )
            self.client.sendall(ws_resp)
        else:
            self.client.sendall(RESPONSE)
        self.client_buffer = b''
        self.server.printLog('Redirected to ' + str(path))
        self.doCONNECT()

    def doCONNECT(self):
        socs = [self.client, self.target]
        count = 0
        error = False
        while True:
            count += 1
            (recv, _, err) = select.select(socs, [], socs, 3)
            if err:
                error = True
            if recv:
                for in_ in recv:
                    try:
                        data = in_.recv(BUFLEN)
                        if data:
                            if in_ is self.target:
                                self.client.sendall(data)
                            else:
                                while data:
                                    byte = self.target.send(data)
                                    data = data[byte:]
                            count = 0
                        else:
                            break
                    except Exception:
                        error = True
                        break
            if count == TIMEOUT:
                error = True
            if error:
                self.server.printLog('Connection closed')
                break


def print_usage():
    print('Use: wsproxy.py -p <port>')
    print('       wsproxy.py -b <ip> -p <puerto>')
    print('       wsproxy.py 80 [destino_ssh: 127.0.0.1:22]')


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
    print("\033[0;34m━" * 8, "\033[1;32m PROXY WEBSOCKET & SSH DIRECTO", "\033[0;34m━" * 8, "\n")
    print("\033[1;33mIP:\033[1;32m " + LISTENING_ADDR)
    print("\033[1;33mPUERTO:\033[1;32m " + str(LISTENING_PORT))
    print("\033[1;33mDESTINO SSH:\033[1;32m " + str(DEFAULT_HOST) + "\n")
    print("\033[0;34m━" * 10, "\033[1;32m SSH-CRIS MASTER", "\033[0;34m━\033[1;37m" * 11, "\n")

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
