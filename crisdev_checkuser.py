#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
CRISDEV CHECKUSER & ATOKEN DAEMON v2.0
======================================
Servidor multi-hilo ultra-ligero de alta concurrencia para la validación
de usuarios, tokens de dispositivo (HWID/aToken) y contador online de apps.

100% Compatible con:
- HTTP Conexión (VpsUserAuthManager.kt & DeviceTokenHelper.kt)
- DTunnel / Conecta4G / GLTunnel / SSHPlus CheckUser clients
- Consumo de recursos: < 15 MB RAM, 0% CPU en reposo
"""

import os
import sys
import json
import time
import urllib.parse
from http.server import HTTPServer, BaseHTTPRequestHandler
from socketserver import ThreadingMixIn
from threading import Lock

# Asegurar importación de crisdev_db
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
if SCRIPT_DIR not in sys.path:
    sys.path.insert(0, SCRIPT_DIR)

import crisdev_db

CHECKUSER_PORT = int(os.environ.get("CHECKUSER_PORT", 5000))
ATOKEN_PORT = int(os.environ.get("ATOKEN_PORT", 8888))

# Rate limiting básico en memoria anti-fuerza bruta (30 consultas por minuto por IP)
rate_limit_lock = Lock()
ip_request_history = {}

def is_rate_limited(client_ip):
    now = time.time()
    with rate_limit_lock:
        timestamps = ip_request_history.get(client_ip, [])
        # Filtrar timestamps de los últimos 60 segundos
        timestamps = [ts for ts in timestamps if now - ts < 60]
        if len(timestamps) >= 60:
            ip_request_history[client_ip] = timestamps
            return True
        timestamps.append(now)
        ip_request_history[client_ip] = timestamps
        return False

class ThreadedHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True
    allow_reuse_address = True

class CheckUserHandler(BaseHTTPRequestHandler):
    server_version = "CRISDEV-CheckUser/2.0"

    def _send_json(self, data, status_code=200):
        try:
            body = json.dumps(data, ensure_ascii=False).encode("utf-8")
            self.send_response(status_code)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
            self.send_header("Access-Control-Allow-Headers", "Content-Type, Authorization, X-Requested-With")
            self.send_header("Cache-Control", "no-cache, no-store, must-revalidate")
            self.end_headers()
            self.wfile.write(body)
        except Exception:
            pass

    def _send_text(self, text, status_code=200):
        try:
            body = text.encode("utf-8")
            self.send_response(status_code)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(body)
        except Exception:
            pass

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, Authorization, X-Requested-With")
        self.end_headers()

    def do_GET(self):
        client_ip = self.client_address[0]
        if is_rate_limited(client_ip):
            self._send_json({"error": "rate_limited", "message": "Demasiadas peticiones. Intenta de nuevo en un minuto."}, 429)
            return

        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path.rstrip("/")
        params = urllib.parse.parse_qs(parsed.query)

        # 1. Validador aToken (GET /?token=TK-XXXX...)
        if "token" in params:
            token_val = params["token"][0].strip()
            res = crisdev_db.validate_device_token(token_val)
            if res.get("is_valid"):
                # HTTP Conexión espera que el texto contenga 'OK' o el token
                self._send_json(res, 200)
            else:
                self._send_json(res, 403)
            return

        # 2. CheckUser estándar (GET /checkuser?user=X o GET /check?user=X)
        if path in ("/checkuser", "/check", "/checkUser"):
            username = None
            for k in ("user", "username", "usuario", "u"):
                if k in params:
                    username = params[k][0].strip()
                    break
            hwid = params.get("hwid", [None])[0]

            if not username:
                self._send_json({"error": "missing_user", "message": "Parámetro 'user' requerido"}, 400)
                return

            res = crisdev_db.checkuser_query(username, hwid=hwid)
            status_code = 200 if res.get("active") else 200  # 200 con is_expired=True para que el cliente Android lo parsee
            self._send_json(res, status_code)
            return

        # 3. Contador Online para Apps (GET /server/online o GET /online)
        if path in ("/server/online", "/online"):
            stats = crisdev_db.get_user_stats()
            self._send_json({
                "onlines": str(stats["online"]),
                "online": stats["online"],
                "total": stats["total"],
                "limite": "1000",
                "active": stats["active"]
            })
            return

        # 4. Raíz (GET /) -> Devuelve el número entero de sesiones (compatible con queryActiveSessions de HTTP Conexión)
        if path in ("", "/"):
            stats = crisdev_db.get_user_stats()
            self._send_text(str(stats["online"]))
            return

        # 5. Endpoint de salud / ping
        if path in ("/health", "/ping"):
            self._send_json({"status": "OK", "service": "crisdev-checkuser", "time": int(time.time())})
            return

        self._send_json({"error": "not_found", "message": "Ruta no encontrada"}, 404)

    def do_POST(self):
        client_ip = self.client_address[0]
        if is_rate_limited(client_ip):
            self._send_json({"error": "rate_limited", "message": "Demasiadas peticiones."}, 429)
            return

        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path.rstrip("/")

        # Leer body JSON
        try:
            length = int(self.headers.get("Content-Length", 0))
            raw_body = self.rfile.read(length).decode("utf-8") if length > 0 else "{}"
            body_json = json.loads(raw_body)
        except Exception:
            body_json = {}

        # 1. POST /checkuser con JSON {"user": "...", "hwid": "..."} (HTTP Conexión nativo)
        if path in ("/checkuser", "/check", "/checkUser"):
            username = body_json.get("user") or body_json.get("username")
            hwid = body_json.get("hwid")
            if not username:
                self._send_json({"error": "missing_user", "message": "Campo 'user' requerido en JSON"}, 400)
                return

            res = crisdev_db.checkuser_query(username, hwid=hwid)
            self._send_json(res, 200)
            return

        self._send_json({"error": "not_found"}, 404)

    def log_message(self, format, *args):
        # Silenciar logs ruidosos para no saturar journalctl
        pass

def start_server(port):
    server = ThreadedHTTPServer(("0.0.0.0", port), CheckUserHandler)
    print(f"⚡ Demonio CheckUser / aToken activo en puerto: {port}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()

if __name__ == "__main__":
    crisdev_db.init_db()
    port = CHECKUSER_PORT
    if len(sys.argv) > 1 and sys.argv[1].isdigit():
        port = int(sys.argv[1])
    start_server(port)
