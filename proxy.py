#!/usr/bin/env python3
# encoding: utf-8
# CRISDEV_PROXY_V3
import base64
from datetime import datetime
import hashlib
import select
import socket
import struct
import sys
import threading
import time

try:
    threading.stack_size(262144)
except Exception:
    pass

IP = "0.0.0.0"
try:
    PORT = int(sys.argv[1])
except Exception:
    PORT = 80
PASS = ""
BUFLEN = 65536
TIMEOUT = 120
MSG = ""
COR = '<font color="null">'
FTAG = "</font>"
DEFAULT_HOST = "127.0.0.1:22"
LOG_FILE = "/var/log/sshplus-proxy.log"
WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
_HTTP_METHODS = (b"GET ", b"POST ", b"CONNECT ", b"HEAD ", b"PUT ", b"OPTIONS ", b"DELETE ", b"PATCH ")


def _init_log_file():
    global LOG_FILE
    for candidate in ("/var/log/sshplus-proxy.log", "/tmp/sshplus-proxy.log"):
        try:
            with open(candidate, "a", encoding="utf-8"):
                pass
            LOG_FILE = candidate
            return
        except Exception:
            continue
    LOG_FILE = None


_init_log_file()

RESPONSE = b"HTTP/1.1 200 Connection Established\r\n\r\n"


def _compute_ws_accept(sec_key):
    digest = hashlib.sha1((sec_key.strip() + WS_GUID).encode("ascii", errors="ignore")).digest()
    return base64.b64encode(digest).decode("ascii")


def _ws_encode_frame(payload, opcode=0x02):
    if not payload and opcode not in (0x08, 0x09, 0x0A):
        return b""
    length = len(payload)
    b0 = 0x80 | (opcode & 0x0F)
    if length < 126:
        header = struct.pack("!BB", b0, length)
    elif length <= 0xFFFF:
        header = struct.pack("!BBH", b0, 126, length)
    else:
        header = struct.pack("!BBQ", b0, 127, length)
    return header + payload


def _unmask_bytes(payload, mask_key):
    n = len(payload)
    if n == 0:
        return b""
    repeated = (mask_key * ((n + 3) // 4))[:n]
    val = int.from_bytes(payload, "big") ^ int.from_bytes(repeated, "big")
    return val.to_bytes(n, "big")


def _ws_decode_frames(buf):
    frames = []
    pos = 0
    total = len(buf)
    while pos + 2 <= total:
        b0 = buf[pos]
        b1 = buf[pos + 1]
        opcode = b0 & 0x0F
        masked = (b1 & 0x80) != 0
        length = b1 & 0x7F
        idx = pos + 2
        if length == 126:
            if idx + 2 > total:
                break
            length = struct.unpack("!H", buf[idx:idx + 2])[0]
            idx += 2
        elif length == 127:
            if idx + 8 > total:
                break
            length = struct.unpack("!Q", buf[idx:idx + 8])[0]
            idx += 8
        if length > 16 * 1024 * 1024:
            raise ValueError("WS frame too large")
        mask_len = 4 if masked else 0
        if idx + mask_len + length > total:
            break
        if masked:
            mask_key = bytes(buf[idx:idx + 4])
            idx += 4
            raw_payload = bytes(buf[idx:idx + length])
            payload = _unmask_bytes(raw_payload, mask_key)
        else:
            payload = bytes(buf[idx:idx + length])
        pos = idx + length
        frames.append((opcode, payload))
    if pos > 0:
        del buf[:pos]
    return frames


def _is_rfc6455_client_frame(data):
    if len(data) < 2:
        return False
    if data.startswith(b"SSH-") or data.startswith(_HTTP_METHODS):
        return False
    b0 = data[0]
    b1 = data[1]
    rsv = b0 & 0x70
    opcode = b0 & 0x0F
    masked = (b1 & 0x80) != 0
    return rsv == 0 and masked and opcode in (0x01, 0x02, 0x08, 0x09, 0x0A)


class Server(threading.Thread):
    def __init__(self, host, port):
        threading.Thread.__init__(self)
        self.running = False
        self.host = host
        self.port = port
        self.threads = []
        self.threadsLock = threading.Lock()
        self.logLock = threading.Lock()
        self.soc = None

    def run(self):
        self.soc = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.soc.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.soc.settimeout(2)
        self.soc.bind((self.host, self.port))
        self.soc.listen(512)
        self.running = True

        try:
            while self.running:
                try:
                    c, addr = self.soc.accept()
                    c.setblocking(1)
                    c.settimeout(20)
                    try:
                        c.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                        c.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
                    except Exception:
                        pass
                except socket.timeout:
                    continue
                except Exception:
                    if not self.running:
                        break
                    continue

                conn = ConnectionHandler(c, self, addr)
                conn.daemon = True
                self.addConn(conn)
                conn.start()
        finally:
            self.running = False
            try:
                if self.soc is not None:
                    self.soc.close()
            except Exception:
                pass

    def addConn(self, conn):
        self.threadsLock.acquire()
        try:
            if self.running:
                self.threads.append(conn)
        finally:
            self.threadsLock.release()

    def removeConn(self, conn):
        self.threadsLock.acquire()
        try:
            if conn in self.threads:
                self.threads.remove(conn)
        except Exception:
            pass
        finally:
            self.threadsLock.release()

    def close(self):
        self.running = False
        self.threadsLock.acquire()
        try:
            threads = list(self.threads)
        finally:
            self.threadsLock.release()
        for c in threads:
            try:
                c.close()
            except Exception:
                pass

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
        self.target = None
        self.client_buffer = b""
        self.server = server
        self.addr = addr
        self.log = "Connection: " + str(addr)

    def close(self):
        if not self.clientClosed:
            try:
                self.client.shutdown(socket.SHUT_RDWR)
            except Exception:
                pass
            try:
                self.client.close()
            except Exception:
                pass
            self.clientClosed = True

        if not self.targetClosed and self.target is not None:
            try:
                self.target.shutdown(socket.SHUT_RDWR)
            except Exception:
                pass
            try:
                self.target.close()
            except Exception:
                pass
            self.targetClosed = True

    def _read_initial_request(self):
        buf = bytearray()
        deadline = time.monotonic() + 12.0
        while len(buf) < 32768 and time.monotonic() < deadline:
            if buf.startswith(b"SSH-"):
                return True, b"", bytes(buf)
            sep_idx = buf.find(b"\r\n\r\n")
            sep_len = 4
            if sep_idx == -1:
                sep_idx = buf.find(b"\n\n")
                sep_len = 2
            if sep_idx != -1:
                end = sep_idx + sep_len
                return False, bytes(buf[:end]), bytes(buf[end:])
            try:
                chunk = self.client.recv(BUFLEN)
            except socket.timeout:
                break
            if not chunk:
                break
            buf.extend(chunk)
        if buf.startswith(b"SSH-"):
            return True, b"", bytes(buf)
        return False, bytes(buf), b""

    def _parse_headers(self, header_bytes):
        text = header_bytes.decode("latin1", errors="replace")
        headers = {}
        first_line = ""
        lines = text.splitlines()
        if lines:
            first_line = lines[0].strip()
        for line in lines[1:]:
            if ":" in line:
                k, v = line.split(":", 1)
                headers[k.strip().lower()] = v.strip()
        return first_line, headers

    def findHeader(self, head, header):
        target_key = header.strip().lower()
        text = head.decode("latin1", errors="replace") if isinstance(head, bytes) else head
        for line in text.splitlines():
            if ":" in line:
                k, v = line.split(":", 1)
                if k.strip().lower() == target_key:
                    return v.strip()
        return ""

    def _resolve_target(self, requested_host):
        default_clean = str(DEFAULT_HOST).strip() or "127.0.0.1:22"
        if ":" not in default_clean:
            default_clean = f"{default_clean}:22"
        def_host, def_port_str = default_clean.rsplit(":", 1)
        if def_host in ("0.0.0.0", ""):
            def_host = "127.0.0.1"
        try:
            def_port = int(def_port_str)
        except Exception:
            def_port = 22

        cand = (requested_host or "").strip()
        if not cand:
            return f"{def_host}:{def_port}"

        host_part = cand
        port_val = def_port
        if ":" in cand and not cand.startswith("["):
            hp, pp = cand.rsplit(":", 1)
            if pp.isdigit():
                host_part = hp.strip()
                p_int = int(pp)
                if 1 <= p_int <= 65535:
                    port_val = p_int

        if host_part.lower() in ("127.0.0.1", "localhost", "::1"):
            return f"127.0.0.1:{port_val}"

        return f"{def_host}:{def_port}"

    def connect_target(self, host):
        i = host.find(":")
        if i != -1:
            port = int(host[i + 1:])
            host_only = host[:i]
        else:
            host_only = host
            port = 22

        if host_only in ("0.0.0.0", "localhost", ""):
            host_only = "127.0.0.1"

        soc_family, soc_type, proto, _, address = socket.getaddrinfo(
            host_only, port, socket.AF_INET, socket.SOCK_STREAM
        )[0]
        self.target = socket.socket(soc_family, soc_type, proto)
        self.target.settimeout(8)
        self.target.connect(address)
        self.target.settimeout(None)
        try:
            self.target.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            self.target.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
        except Exception:
            pass
        self.targetClosed = False

    def _strip_decoy_http(self, leftover):
        if not leftover or not leftover.startswith(_HTTP_METHODS):
            return leftover
        buf = bytearray(leftover)
        deadline = time.monotonic() + 0.5
        while len(buf) < 16384:
            idx = buf.find(b"\r\n\r\n")
            if idx != -1:
                return bytes(buf[idx + 4:])
            idx2 = buf.find(b"\n\n")
            if idx2 != -1:
                return bytes(buf[idx2 + 2:])
            rem = deadline - time.monotonic()
            if rem <= 0:
                break
            r, _, _ = select.select([self.client], [], [], min(rem, 0.1))
            if not r:
                continue
            chunk = self.client.recv(BUFLEN)
            if not chunk:
                break
            buf.extend(chunk)
        return bytes(buf)

    def _build_response(self, is_ws_req, ws_key):
        if is_ws_req:
            out = (
                "HTTP/1.1 101 Switching Protocols\r\n"
                "Upgrade: websocket\r\n"
                "Connection: Upgrade\r\n"
            )
            if ws_key:
                out += f"Sec-WebSocket-Accept: {_compute_ws_accept(ws_key)}\r\n"
            m = str(MSG or "").replace("\r", "").replace("\n", "").strip()
            if m:
                out += f"X-Message: {m}\r\n"
            out += "\r\n"
            return out.encode("latin1")
        if MSG:
            m = str(MSG).replace("\r", "").replace("\n", "").strip()
            return f"HTTP/1.1 200 {COR}{m}{FTAG}\r\n\r\n".encode("latin1", errors="replace")
        return RESPONSE

    def run(self):
        try:
            is_direct_ssh, header_bytes, leftover = self._read_initial_request()
            if not is_direct_ssh and not header_bytes and not leftover:
                return

            if is_direct_ssh:
                target_host = self._resolve_target(DEFAULT_HOST)
                self.connect_target(target_host)
                self.client.settimeout(None)
                if leftover:
                    self.target.sendall(leftover)
                self.doCONNECT(ws_negotiated=False, initial_client_bytes=b"", headers={})
                return

            first_line, headers = self._parse_headers(header_bytes)
            passwd = headers.get("x-pass", "")
            if len(PASS) != 0 and passwd != PASS:
                self.client.sendall(b"HTTP/1.1 400 WrongPass!\r\n\r\n")
                return

            req_host = headers.get("x-real-host", "")
            target_host = self._resolve_target(req_host)

            is_ws_req = (
                "websocket" in headers.get("upgrade", "").lower()
                or "upgrade" in headers.get("connection", "").lower()
                or "sec-websocket-key" in headers
            )
            ws_key = headers.get("sec-websocket-key", "")

            self.connect_target(target_host)
            self.client.settimeout(None)

            self.client.sendall(self._build_response(is_ws_req, ws_key))

            if leftover:
                leftover = self._strip_decoy_http(leftover)

            self.server.printLog(f"{self.log} -> {target_host} | {first_line[:60]} | ws={is_ws_req}")
            self.doCONNECT(
                ws_negotiated=is_ws_req,
                initial_client_bytes=leftover,
                headers=headers,
            )
        except Exception as e:
            self.server.printLog(f"error ({self.addr}): {e}")
        finally:
            self.close()
            self.server.removeConn(self)

    def doCONNECT(self, ws_negotiated=False, initial_client_bytes=b"", headers=None):
        headers = headers or {}
        is_cloudfront = ("x-amz-cf-id" in headers) or ("cloudfront" in headers.get("via", "").lower())
        ws_mode = None if ws_negotiated else False
        ws_probe_buf = bytearray()
        ws_rx_buf = bytearray()
        pre_ssh_buf = bytearray()
        ssh_started = False
        target_pending = bytearray()
        detect_deadline = time.monotonic() + 2.0

        def _send_to_client(payload):
            if not payload:
                return
            if ws_mode is True:
                self.client.sendall(_ws_encode_frame(payload, opcode=0x02))
            else:
                self.client.sendall(payload)

        def _flush_pending_target():
            if target_pending:
                data_out = bytes(target_pending)
                target_pending.clear()
                _send_to_client(data_out)

        def _strip_pre_ssh_and_send(data):
            nonlocal ssh_started
            if ssh_started:
                self.target.sendall(data)
                return
            pre_ssh_buf.extend(data)
            while pre_ssh_buf:
                head = bytes(pre_ssh_buf[:8])
                if any(m.startswith(head) for m in _HTTP_METHODS) or any(head.startswith(m) for m in _HTTP_METHODS):
                    idx = pre_ssh_buf.find(b"\r\n\r\n")
                    sep_len = 4
                    if idx == -1:
                        idx = pre_ssh_buf.find(b"\n\n")
                        sep_len = 2
                    if idx == -1:
                        if len(pre_ssh_buf) > 16384:
                            break
                        return
                    del pre_ssh_buf[:idx + sep_len]
                    continue
                break
            if pre_ssh_buf:
                ssh_started = True
                self.target.sendall(bytes(pre_ssh_buf))
                pre_ssh_buf.clear()

        def _handle_client_bytes(data):
            nonlocal ws_mode
            if ws_mode is None:
                ws_probe_buf.extend(data)
                if len(ws_probe_buf) < 2:
                    return True
                probe = bytes(ws_probe_buf)
                ws_probe_buf.clear()
                ws_mode = _is_rfc6455_client_frame(probe)
                _flush_pending_target()
                data = probe

            if ws_mode is True:
                ws_rx_buf.extend(data)
                frames = _ws_decode_frames(ws_rx_buf)
                for opcode, payload in frames:
                    if opcode in (0x00, 0x01, 0x02):
                        if payload:
                            _strip_pre_ssh_and_send(payload)
                    elif opcode == 0x09:
                        self.client.sendall(_ws_encode_frame(payload, opcode=0x0A))
                    elif opcode == 0x08:
                        try:
                            self.client.sendall(_ws_encode_frame(b"\x03\xe8", opcode=0x08))
                        except Exception:
                            pass
                        return False
            else:
                _strip_pre_ssh_and_send(data)
            return True

        if initial_client_bytes:
            if not _handle_client_bytes(initial_client_bytes):
                return

        socs = [self.client, self.target]
        idle_ticks = 0
        while True:
            wait_sec = 0.2 if ws_mode is None else 3.0
            recv, _, err = select.select(socs, [], socs, wait_sec)
            if err:
                break

            if ws_mode is None and time.monotonic() >= detect_deadline:
                ws_mode = True if is_cloudfront else False
                _flush_pending_target()

            if not recv:
                idle_ticks += 1
                if ws_mode is not None and idle_ticks >= TIMEOUT:
                    break
                continue

            closed = False
            for in_ in recv:
                try:
                    data = in_.recv(BUFLEN)
                except Exception:
                    closed = True
                    break
                if not data:
                    closed = True
                    break
                idle_ticks = 0
                if in_ is self.target:
                    if ws_mode is None:
                        target_pending.extend(data)
                    else:
                        _send_to_client(data)
                else:
                    if not _handle_client_bytes(data):
                        closed = True
                        break
            if closed:
                break


def print_usage():
    print("Uso: proxy.py -p <port>")
    print("     proxy.py -b <ip> -p <port>")


def main(host=IP, port=PORT):
    print("\033[0;34m━" * 8, "\033[1;32m PROXY SOCKS", "\033[0;34m━" * 8, "\n")
    print("\033[1;33mIP:\033[1;32m " + IP)
    print("\033[1;33mPUERTO:\033[1;32m " + str(PORT) + "\n")
    print("\033[0;34m━" * 10, "\033[1;32m VPSMANAGER", "\033[0;34m━\033[1;37m" * 11, "\n")

    server = Server(IP, PORT)
    server.start()
    while True:
        try:
            time.sleep(2)
        except KeyboardInterrupt:
            print("Parando...")
            server.close()
            break


if __name__ == "__main__":
    main()
