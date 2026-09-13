#!/usr/bin/env python3
"""
CRISDEV VPS Auth API Server
===========================
Servidor HTTP ultraligero y a prueba de fallos para autenticar usuarios Premium en la App.
"""

import os
import sys
import json
import time
import secrets
import socket
from http.server import HTTPServer, BaseHTTPRequestHandler

PORT = int(os.environ.get("PORT", 8080))
USERS_DB = "/etc/crisdev/users.json"
TOKENS_FILE = "/tmp/crisdev_tokens.json"

def load_tokens():
    if os.path.exists(TOKENS_FILE):
        try:
            with open(TOKENS_FILE, "r") as f:
                return json.load(f)
        except Exception:
            return {}
    return {}

def save_tokens(tokens):
    try:
        with open(TOKENS_FILE, "w") as f:
            json.dump(tokens, f)
    except Exception:
        pass

def authenticate_user(username, password):
    # 1. Usuario DEMO por defecto para Google Play Store
    if username == "demo" and password == "demo123":
        return True, time.time() + (30 * 86400)  # 30 días de acceso

    # 2. Verificar en la base de datos de CRISDEV (/etc/crisdev/users.json)
    if os.path.exists(USERS_DB):
        try:
            with open(USERS_DB, "r") as f:
                users = json.load(f)
                for u in users:
                    if u.get("username") == username and u.get("password") == password:
                        return True, time.time() + (30 * 86400)
        except Exception:
            pass

    # 3. Autenticación con usuarios SSH de Linux (/etc/shadow)
    try:
        import spwd
        shadow_entry = spwd.getspnam(username)
        encrypted_pass = shadow_entry.sp_pwdp
        if encrypted_pass:
            try:
                import crypt
                if crypt.crypt(password, encrypted_pass) == encrypted_pass:
                    return True, time.time() + (30 * 86400)
            except Exception:
                import subprocess
                parts = encrypted_pass.split('$')
                if len(parts) >= 3:
                    salt = parts[2]
                    res = subprocess.run(['openssl', 'passwd', '-6', '-salt', salt, password],
                                         capture_output=True, text=True)
                    if res.stdout.strip() == encrypted_pass:
                        return True, time.time() + (30 * 86400)
    except Exception:
        pass

    return False, 0

class ReuseAddrHTTPServer(HTTPServer):
    def server_bind(self):
        self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        super().server_bind()

class AuthHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        content_length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(content_length)
        
        try:
            data = json.loads(body.decode('utf-8'))
        except Exception:
            self._send_json({"success": False, "error": "invalid_json"}, 400)
            return

        if self.path == '/login':
            username = data.get('username', '')
            password = data.get('password', '')
            device_id = data.get('device_id', '')

            valid, expires_at_sec = authenticate_user(username, password)
            if valid:
                token = secrets.token_hex(16)
                expires_at_ms = int(expires_at_sec * 1000)
                
                tokens = load_tokens()
                tokens[token] = {
                    "username": username,
                    "device_id": device_id,
                    "expires_at": expires_at_ms
                }
                save_tokens(tokens)

                self._send_json({
                    "success": True,
                    "token": token,
                    "username": username,
                    "expires_at": expires_at_ms
                })
            else:
                self._send_json({
                    "success": False,
                    "error": "invalid_credentials"
                })

        elif self.path == '/verify':
            token = data.get('token', '')
            tokens = load_tokens()
            if token in tokens:
                token_data = tokens[token]
                if time.time() * 1000 < token_data.get("expires_at", 0):
                    self._send_json({
                        "valid": True,
                        "expires_at": token_data.get("expires_at")
                    })
                    return

            self._send_json({"valid": False})

        else:
            self._send_json({"error": "not_found"}, 404)

    def _send_json(self, data, status=200):
        self.send_response(status)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.end_headers()
        self.wfile.write(json.dumps(data).encode('utf-8'))

    def log_message(self, format, *args):
        pass  # Silenciar logs

if __name__ == '__main__':
    print(f"CRISDEV VPS Auth API escuchando en puerto {PORT}...")
    try:
        server = ReuseAddrHTTPServer(('0.0.0.0', PORT), AuthHandler)
        server.serve_forever()
    except Exception as e:
        print(f"Error al iniciar servidor API: {e}", file=sys.stderr)
        sys.exit(1)
