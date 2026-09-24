#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
CRISDEV REST API SERVER — HIGH-PERFORMANCE SERVERS & SYNC DAEMON
===============================================================
Servidor API REST asíncrono para la sincronización en tiempo real de servidores
entre el GEN NEW APP PRO (administrador) y la App HTTP Conexión / Bot Telegram.
Soporte completo multi-método (13 protocolos), segmentación Free/Premium y entrega en 1 ms.
Puerto por defecto: 8088 (Sin colisiones con OpenSSH, Stunnel, Dropbear, BHTTP, XHTTP, HCR).
"""

import os
import sys
import json
import time
import socket
import logging
import argparse
import urllib.parse
from http.server import HTTPServer, BaseHTTPRequestHandler
from socketserver import ThreadingMixIn

# Importar el motor de base de datos
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import crisdev_db

API_PORT = int(os.environ.get("CRISDEV_API_PORT", 8088))
ADMIN_TOKEN = os.environ.get("CRISDEV_ADMIN_TOKEN", "CRISDEV_SECRET_ADMIN_KEY_2026")
START_TIME = time.time()

logging.basicConfig(
    format="%(asctime)s - [API] %(levelname)s - %(message)s",
    level=logging.INFO
)

class ThreadedHTTPServer(ThreadingMixIn, HTTPServer):
    """Manejo de peticiones concurrentes en hilos separados sin bloquear el servidor."""
    daemon_threads = True

    def server_bind(self):
        self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        super().server_bind()

class CrisDevApiHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _send_response_json(self, data, status_code=200, extra_headers=None):
        payload = json.dumps(data, ensure_ascii=False).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, X-Admin-Token, If-None-Match")
        self.send_header("Server", "CRISDEV-Engine/3.0")
        if extra_headers:
            for k, v in extra_headers.items():
                self.send_header(k, v)
        self.end_headers()
        self.wfile.write(payload)

    def _send_response_text(self, text_content, content_type="text/plain; charset=utf-8", status_code=200, extra_headers=None):
        payload = text_content.encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, X-Admin-Token, If-None-Match")
        self.send_header("Server", "CRISDEV-Engine/3.0")
        if extra_headers:
            for k, v in extra_headers.items():
                self.send_header(k, v)
        self.end_headers()
        self.wfile.write(payload)

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, X-Admin-Token, If-None-Match")
        self.end_headers()

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path.rstrip("/")
        query = urllib.parse.parse_qs(parsed.query)
        if not path:
            path = "/"

        # ── 1. ENDPOINTS PÚBLICOS (CONSUMO APP Y BOT) ──

        # A) /api/v1/version (Head-check ultraligero con métricas Free/Premium)
        if path in ["/api/v1/version", "/version"]:
            blob_info = crisdev_db.get_live_cached_blob()
            stats = crisdev_db.get_stats()
            if blob_info:
                resp = {
                    "version": blob_info["version_code"],
                    "total_servers": stats["total_servers"],
                    "total_countries": stats["total_countries"],
                    "total_free": stats.get("total_free", 0),
                    "total_premium": stats.get("total_premium", 0),
                    "release_notes": stats.get("release_notes", ""),
                    "updated_at": blob_info["updated_at"],
                    "etag": blob_info["etag"]
                }
                self._send_response_json(resp, 200, {"ETag": blob_info["etag"], "Cache-Control": "public, max-age=30"})
            else:
                self._send_response_json({"version": "v1.0.0", "total_servers": 0, "total_countries": 0}, 200)
            return

        # B) /api/v1/servers/live (Payload pre-cifrado para App Android)
        if path in ["/api/v1/servers/live", "/api/v1/servers", "/live"]:
            blob_info = crisdev_db.get_live_cached_blob()
            if not blob_info or not blob_info["encrypted_blob"]:
                self._send_response_json({"error": "No hay catálogo de servidores activo en la base de datos."}, 404)
                return

            client_etag = self.headers.get("If-None-Match", "").strip()
            server_etag = blob_info["etag"].strip()

            # Soporte HTTP 304 Not Modified para ahorro masivo de ancho de banda
            if client_etag and client_etag == server_etag:
                self.send_response(304)
                self.send_header("ETag", server_etag)
                self.send_header("Access-Control-Allow-Origin", "*")
                self.end_headers()
                return

            extra_h = {
                "ETag": server_etag,
                "Cache-Control": "public, max-age=60",
                "X-Version-Code": blob_info["version_code"]
            }
            self._send_response_text(blob_info["encrypted_blob"], "text/plain; charset=utf-8", 200, extra_h)
            return

        # C) /api/v1/servers/raw o /api/v1/servers/json (JSON sin cifrar)
        if path in ["/api/v1/servers/raw", "/api/v1/servers/json", "/raw", "/json"]:
            blob_info = crisdev_db.get_live_cached_blob()
            if blob_info and blob_info["raw_json"]:
                self._send_response_text(blob_info["raw_json"], "application/json; charset=utf-8", 200, {"ETag": blob_info["etag"]})
            else:
                self._send_response_json({"Version": "1.0.0", "Servers": []}, 200)
            return

        # D) /api/v1/servers/stats (Estadísticas exhaustivas por país, método y plan Free/Premium)
        if path in ["/api/v1/servers/stats", "/stats"]:
            stats = crisdev_db.get_stats()
            self._send_response_json(stats, 200)
            return

        # E) /api/v1/servers/free (Filtrado de servidores gratuitos)
        if path in ["/api/v1/servers/free", "/free"]:
            servers = crisdev_db.query_servers(filters={"is_free": True}, limit=500)
            parsed_servers = [json.loads(s["raw_json"]) if s.get("raw_json") else s for s in servers]
            self._send_response_json({
                "count": len(parsed_servers),
                "plan": "FREE",
                "servers": parsed_servers
            }, 200)
            return

        # F) /api/v1/servers/premium (Filtrado de servidores VIP / Premium)
        if path in ["/api/v1/servers/premium", "/premium"]:
            servers = crisdev_db.query_servers(filters={"is_premium": True}, limit=500)
            parsed_servers = [json.loads(s["raw_json"]) if s.get("raw_json") else s for s in servers]
            self._send_response_json({
                "count": len(parsed_servers),
                "plan": "PREMIUM",
                "servers": parsed_servers
            }, 200)
            return

        # G) /api/v1/servers/search (Búsqueda dinámica por texto, país o método)
        if path in ["/api/v1/servers/search", "/search"]:
            q = query.get("q", [""])[0]
            country = query.get("country", [""])[0]
            proto = query.get("protocol", [""])[0]
            filters = {}
            if q:
                filters["search"] = q
            if country:
                filters["country"] = country
            if proto:
                filters["protocol"] = proto
            results = crisdev_db.query_servers(filters=filters, limit=200)
            parsed = [json.loads(s["raw_json"]) if s.get("raw_json") else s for s in results]
            self._send_response_json({"total": len(parsed), "results": parsed}, 200)
            return

        # H) /api/v1/health (Health check)
        if path in ["/api/v1/health", "/health", "/"]:
            uptime_sec = int(time.time() - START_TIME)
            stats = crisdev_db.get_stats()
            self._send_response_json({
                "status": "online",
                "service": "CRISDEV VPS Servers Sync API",
                "uptime_seconds": uptime_sec,
                "version_code": stats.get("version", "v1.0.0"),
                "total_servers": stats.get("total_servers", 0),
                "total_countries": stats.get("total_countries", 0),
                "total_free": stats.get("total_free", 0),
                "total_premium": stats.get("total_premium", 0),
                "database_mode": "SQLite WAL"
            }, 200)
            return

        # ── 2. ENDPOINTS DE ADMINISTRACIÓN (PROTEGIDOS POR TOKEN) ──

        auth_header = self.headers.get("X-Admin-Token", "")
        if auth_header != ADMIN_TOKEN:
            self._send_response_json({"error": "No autorizado: Token de administrador no proporcionado o inválido."}, 401)
            return

        # A) Listar copias de seguridad
        if path == "/api/v1/admin/backups":
            try:
                conn = crisdev_db.get_db_connection()
                rows = conn.execute("SELECT id, backup_name, version_code, created_at FROM backups ORDER BY id DESC;").fetchall()
                conn.close()
                backups = [{"id": r["id"], "name": r["backup_name"], "version": r["version_code"], "date": r["created_at"]} for r in rows]
                self._send_response_json({"backups": backups}, 200)
            except Exception as e:
                self._send_response_json({"error": str(e)}, 500)
            return

        self._send_response_json({"error": "Endpoint no encontrado", "path": path}, 404)

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path.rstrip("/")

        auth_header = self.headers.get("X-Admin-Token", "")
        if auth_header != ADMIN_TOKEN:
            self._send_response_json({"error": "No autorizado: Token de administrador no proporcionado o inválido."}, 401)
            return

        content_len = int(self.headers.get("Content-Length", 0))
        post_body = self.rfile.read(content_len).decode("utf-8") if content_len > 0 else ""

        # A) /api/v1/admin/sync (Publicar catálogo desde el GEN o Bot)
        if path in ["/api/v1/admin/sync", "/api/v1/admin/publish"]:
            try:
                data = json.loads(post_body)
                v = data.get("Version", "1.0.0")
                notes = data.get("ReleaseNotes", "Actualización desde API.")
                servers = data.get("Servers", [])
                pwd = data.get("Password", crisdev_db.DEFAULT_GRETTA_PASS)

                if not isinstance(servers, list):
                    self._send_response_json({"error": "El campo 'Servers' debe ser una lista válida."}, 400)
                    return

                ok, v_code, tot_s, tot_c, tot_f, tot_p = crisdev_db.save_full_catalog(v, notes, servers, password=pwd)
                logging.info(f" Catálogo actualizado exitosamente: {tot_s} servidores ({tot_f} Free, {tot_p} Premium) en {tot_c} países (Versión {v_code}).")
                
                self._send_response_json({
                    "success": True,
                    "version_code": v_code,
                    "total_servers": tot_s,
                    "total_countries": tot_c,
                    "total_free": tot_f,
                    "total_premium": tot_p,
                    "message": f"Servidores publicados y sincronizados con éxito ({v_code})."
                }, 200)
            except Exception as e:
                logging.error(f"Error procesando sync POST: {e}")
                self._send_response_json({"success": False, "error": str(e)}, 500)
            return

        # B) /api/v1/admin/restore (Restaurar un respaldo)
        if path == "/api/v1/admin/restore":
            try:
                data = json.loads(post_body)
                backup_id = data.get("backup_id")
                conn = crisdev_db.get_db_connection()
                row = conn.execute("SELECT raw_content, version_code FROM backups WHERE id=?;", (backup_id,)).fetchone()
                conn.close()

                if not row:
                    self._send_response_json({"error": "Respaldo no encontrado."}, 404)
                    return

                content_obj = json.loads(row["raw_content"])
                v = content_obj.get("Version", row["version_code"])
                notes = content_obj.get("ReleaseNotes", "Restauración de respaldo.")
                servers = content_obj.get("Servers", [])

                crisdev_db.save_full_catalog(v, notes, servers)
                self._send_response_json({"success": True, "message": f"Respaldo {row['version_code']} restaurado exitosamente."}, 200)
            except Exception as e:
                self._send_response_json({"success": False, "error": str(e)}, 500)
            return

        self._send_response_json({"error": "Endpoint POST no reconocido", "path": path}, 404)

    def log_message(self, format, *args):
        pass

def run_server(port=API_PORT):
    crisdev_db.init_db()
    server_address = ("0.0.0.0", port)
    httpd = ThreadedHTTPServer(server_address, CrisDevApiHandler)
    logging.info(f"⚡ Servidor API REST CRISDEV escuchando en: http://0.0.0.0:{port}")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        logging.info("Deteniendo servidor API...")
        httpd.shutdown()

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="CRISDEV VPS REST API Server")
    parser.add_argument("--port", type=int, default=API_PORT, help="Puerto de escucha HTTP (default: 8088)")
    args = parser.parse_args()
    run_server(args.port)
