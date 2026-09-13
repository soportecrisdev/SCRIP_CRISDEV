#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import sys
import socket
import select
import threading

LISTEN_IP = "0.0.0.0"
DEFAULT_HOST = "127.0.0.1:22"
MSG = "HTTP CONEXION"
COLOR = "green"
IPTAG = '<font color="' + COLOR + '">'
FTAG = "</font>"

RESPONSE = (
    b"HTTP/1.1 200 OK\r\n"
    b"Content-Length: 0\r\n"
    b"\r\n"
    b"HTTP/1.1 200 Connection Established\r\n"
    b"\r\n"
)

BUFFER_SIZE = 8192
TIMEOUT = 60

def forward_sockets(client_sock, server_sock):
    sockets = [client_sock, server_sock]
    try:
        while True:
            r_socks, _, x_socks = select.select(sockets, [], sockets, TIMEOUT)
            if x_socks or not r_socks:
                break
            for s in r_socks:
                other = server_sock if s is client_sock else client_sock
                try:
                    data = s.recv(BUFFER_SIZE)
                    if not data:
                        return
                    other.sendall(data)
                except Exception:
                    return
    except Exception:
        pass
    finally:
        try: client_sock.close()
        except Exception: pass
        try: server_sock.close()
        except Exception: pass

def handle_connection(client_sock, client_addr, default_target_host, default_target_port):
    try:
        client_sock.settimeout(10)
        req = client_sock.recv(BUFFER_SIZE)
        if not req:
            client_sock.close()
            return
        
        target_host = default_target_host
        target_port = default_target_port

        lines = req.split(b"\r\n")
        first_line = lines[0].decode("latin1", errors="ignore")
        if first_line.startswith("CONNECT"):
            parts = first_line.split()
            if len(parts) >= 2:
                host_port = parts[1].split(":")
                target_host = host_port[0]
                if len(host_port) > 1 and host_port[1].isdigit():
                    target_port = int(host_port[1])

        try:
            server_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            server_sock.settimeout(10)
            server_sock.connect((target_host, target_port))
            server_sock.settimeout(None)
        except Exception:
            try:
                server_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                server_sock.connect((default_target_host, default_target_port))
                server_sock.settimeout(None)
            except Exception:
                client_sock.close()
                return

        try:
            client_sock.sendall(RESPONSE)
        except Exception:
            client_sock.close()
            server_sock.close()
            return

        client_sock.settimeout(None)
        forward_sockets(client_sock, server_sock)

    except Exception:
        try: client_sock.close()
        except Exception: pass

def main():
    listen_port = 80
    if len(sys.argv) > 1 and sys.argv[1].isdigit():
        listen_port = int(sys.argv[1])

    target_host = "127.0.0.1"
    target_port = 22
    if len(sys.argv) > 2:
        parts = sys.argv[2].split(":")
        target_host = parts[0]
        if len(parts) > 1 and parts[1].isdigit():
            target_port = int(parts[1])

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        srv.bind((LISTEN_IP, listen_port))
        srv.listen(512)
    except Exception as e:
        sys.stderr.write(f"Error binding on {LISTEN_IP}:{listen_port}: {e}\n")
        sys.exit(1)

    while True:
        try:
            client_sock, client_addr = srv.accept()
            t = threading.Thread(
                target=handle_connection,
                args=(client_sock, client_addr, target_host, target_port),
                daemon=True,
            )
            t.start()
        except KeyboardInterrupt:
            break
        except Exception:
            continue

if __name__ == "__main__":
    main()
