#!/usr/bin/env python3
# encoding: utf-8
import socket
import threading
import select
import signal
import sys
import time
from os import system
from datetime import datetime

system("clear")
# conexao
IP = "0.0.0.0"
try:
    PORT = int(sys.argv[1])
except Exception:
    PORT = 80
PASS = ""
BUFLEN = 8196 * 8
TIMEOUT = 60
MSG = ""
COR = '<font color="null">'
FTAG = "</font>"
DEFAULT_HOST = "0.0.0.0:22"
LOG_FILE = "/var/log/sshplus-proxy.log"


def _init_log_file():
    """Crea el archivo de log al cargar el módulo; si /var/log falla, usa /tmp."""
    global LOG_FILE
    for candidate in ("/var/log/sshplus-proxy.log", "/tmp/sshplus-proxy.log"):
        try:
            ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            with open(candidate, "a", encoding="utf-8") as f:
                f.write(f"[{ts}] proxy SOCKS: registro iniciado\n")
            LOG_FILE = candidate
            return
        except Exception:
            continue
    LOG_FILE = None


_init_log_file()
# Inyectores tipo HTTP Custom / Style suelen registrar primero "200 OK" y luego "Connection Established"
# (a veces en saltos distintos); enviar ambas respuestas mínimas antes del túnel TCP ayuda a esos clientes.
RESPONSE = (
    b"HTTP/1.1 200 OK\r\n"
    b"Connection: keep-alive\r\n"
    b"Content-Length: 0\r\n"
    b"\r\n"
    b"HTTP/1.1 200 Connection Established\r\n"
    b"\r\n"
)
 
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
        self.soc = socket.socket(socket.AF_INET)
        self.soc.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.soc.settimeout(2)
        self.soc.bind((self.host, self.port))
        self.soc.listen(0)
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
            self.soc.close()
            
	
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

    def printLog(self, log):
        self.logLock.acquire()
        try:
            ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            line = f"[{ts}] [DEBUG] {log}"
            print(line)
            if LOG_FILE is None:
                return
            try:
                with open(LOG_FILE, "a", encoding="utf-8") as f:
                    f.write(line + "\n")
            except Exception:
                pass
        finally:
            self.logLock.release()
			

class ConnectionHandler(threading.Thread):
    def __init__(self, socClient, server, addr):
        threading.Thread.__init__(self)
        self.clientClosed = False
        self.targetClosed = True
        self.client = socClient
        self.client_buffer = ''
        self.server = server
        self.addr = addr
        self.log = "Connection: " + str(addr)

    def close(self):
        try:
            if not self.clientClosed:
                self.client.shutdown(socket.SHUT_RDWR)
                self.client.close()
        except:
            pass
        finally:
            self.clientClosed = True
            
        try:
            if not self.targetClosed:
                self.target.shutdown(socket.SHUT_RDWR)
                self.target.close()
        except:
            pass
        finally:
            self.targetClosed = True

    def run(self):
        try:
            try:
                self.server.printLog(
                    "Accepted connection from %s:%s" % (self.addr[0], self.addr[1])
                )
            except Exception:
                self.server.printLog("Accepted connection from " + str(self.addr))
            self.client_buffer = self.client.recv(BUFLEN)
            buf = self.client_buffer
            if isinstance(buf, bytes):
                buf = buf.decode("latin1", errors="replace")

            hostPort = self.findHeader(buf, "X-Real-Host")

            if hostPort == "":
                hostPort = DEFAULT_HOST

            split = self.findHeader(buf, "X-Split")

            if split != "":
                self.client.recv(BUFLEN)

            if hostPort != "":
                passwd = self.findHeader(buf, "X-Pass")
                allowed = (
                    hostPort.startswith(IP)
                    or hostPort.startswith("127.0.0.1")
                    or hostPort.startswith("localhost")
                )
                if len(PASS) != 0 and passwd != PASS:
                    self.client.sendall(b"HTTP/1.1 400 WrongPass!\r\n\r\n")
                elif allowed:
                    self.method_CONNECT(hostPort)
                else:
                    self.client.sendall(b"HTTP/1.1 403 Forbidden!\r\n\r\n")
            else:
                print("- No X-Real-Host!")
                self.client.sendall(b"HTTP/1.1 400 NoXRealHost!\r\n\r\n")

        except Exception:
            self.server.printLog(self.log + " - error")
        finally:
            self.close()
            self.server.removeConn(self)

    def findHeader(self, head, header):
        aux = head.find(header + ': ')
    
        if aux == -1:
            return ''

        aux = head.find(':', aux)
        head = head[aux+2:]
        aux = head.find('\r\n')

        if aux == -1:
            return ''

        return head[:aux];

    def connect_target(self, host):
        i = host.find(':')
        if i != -1:
            port = int(host[i+1:])
            host = host[:i]
        else:
            port = 22

        (soc_family, soc_type, proto, _, address) = socket.getaddrinfo(host, port)[0]

        self.target = socket.socket(soc_family, soc_type, proto)
        self.targetClosed = False
        self.target.settimeout(10)
        self.target.connect(address)
        self.target.settimeout(None)

    def method_CONNECT(self, path):
        self.log += " - CONNECT " + path
        self.connect_target(path)
        self.client.sendall(RESPONSE)
        self.client_buffer = b""
        self.server.printLog("Redirected to " + path)
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
                self.server.printLog("Connection closed")
                break



def main(host=IP, port=PORT):
    print("\033[0;34m━" * 8, "\033[1;32m PROXY SOCKS", "\033[0;34m━" * 8, "\n")
    print("\033[1;33mIP:\033[1;32m " + IP)
    print("\033[1;33mPUERTO:\033[1;32m " + str(PORT) + "\n")
    print("\033[0;34m━" * 10, "\033[1;32m SSHPLUS", "\033[0;34m━\033[1;37m" * 11, "\n")
    server = Server(IP, PORT)
    server.start()
    while True:
        try:
            time.sleep(2)
        except KeyboardInterrupt:
            print("\nParando...")
            server.close()
            break


if __name__ == "__main__":
    main()
