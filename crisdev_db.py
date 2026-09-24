#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
CRISDEV DATABASE & CRYPTO ENGINE
================================
Gestor maestro de Base de Datos SQLite en modo WAL y cifrado canónico AES-256-CBC
para la infraestructura de servidores VPN de HTTP Conexión / CRISDEV.
Soporte completo para los 13 métodos de conexión y clasificación Free / Premium.
"""

import os
import sys
import json
import time
import base64
import hashlib
import sqlite3
from threading import RLock

try:
    from Crypto.Cipher import AES
except ImportError:
    AES = None

DB_PATH = "/etc/crisdev/crisdev_servers.db"
DEFAULT_GRETTA_PASS = "©risdev~"
JA_TEST = "4paZ4paa4pab4pac4pad4pae4paf4paD4paE4paF4paG4paH4paI4paJ4paK4paQ"
VAR_CHARS = base64.b64decode(JA_TEST).decode("utf-8")

db_lock = RLock()

# ═════════════════════════════════════════════════════════════════════
# MOTOR CRIPTOGRÁFICO CANÓNICO AES-256-CBC
# ═════════════════════════════════════════════════════════════════════
def _gen_string(s):
    res = bytearray()
    for i in range(0, len(s), 2):
        c1 = s[i]
        c2 = s[i+1]
        idx1 = VAR_CHARS.index(c1)
        idx2 = VAR_CHARS.index(c2)
        res.append((idx1 * 16 + idx2) & 0xFF)
    return res.decode("latin-1")

def _encode_var_chars(b64_str):
    res = []
    for b in b64_str.encode("latin-1"):
        nib1 = (b >> 4) & 0x0F
        nib2 = b & 0x0F
        res.append(VAR_CHARS[nib1])
        res.append(VAR_CHARS[nib2])
    return "".join(res)

def decrypt_payload(password, enc_text):
    if not AES or not enc_text:
        return None
    try:
        b64_cipher = _gen_string(enc_text)
        cipher_bytes = base64.b64decode(b64_cipher)
        hex_pass = password.encode("utf-8").hex().upper()
        key = hashlib.sha256(hex_pass.encode("utf-8")).digest()
        cipher = AES.new(key, AES.MODE_CBC, bytes(16))
        dec = cipher.decrypt(cipher_bytes)
        pad = dec[-1]
        if pad < 16:
            dec = dec[:-pad]
        return dec.decode("utf-8", errors="ignore")
    except Exception:
        return None

def encrypt_payload(password, raw_json_str):
    if not AES or not raw_json_str:
        return None
    try:
        raw_bytes = raw_json_str.encode("utf-8")
        pad_len = 16 - (len(raw_bytes) % 16)
        padded = raw_bytes + bytes([pad_len] * pad_len)
        hex_pass = password.encode("utf-8").hex().upper()
        key = hashlib.sha256(hex_pass.encode("utf-8")).digest()
        cipher = AES.new(key, AES.MODE_CBC, bytes(16))
        encrypted = cipher.encrypt(padded)
        b64 = base64.b64encode(encrypted).decode("ascii")
        return _encode_var_chars(b64)
    except Exception:
        return None

# ═════════════════════════════════════════════════════════════════════
def determine_protocol(s):
    """Identifica con precisión el método de conexión entre los 13 protocolos soportados usando los flags canónicos."""
    if parse_boolean(s.get("isTcp")) or parse_boolean(s.get("isocho")):
        proto = str(s.get("v2rayProtocol", "VMess")).upper()
        if len(proto) > 15 or "=" in proto or " " in proto:
            proto = "VMess"
        return "V2RAY", f"V2Ray ({proto})", 8
    elif parse_boolean(s.get("isBhttp")):
        if parse_boolean(s.get("bhttpTls")):
            return "BHTTP_TLS", "BHTTP + TLS (SNI)", 11
        return "BHTTP", "Binary HTTP (BHTTP)", 11
    elif parse_boolean(s.get("isHcr")):
        if parse_boolean(s.get("hcrTls")):
            return "HCR_TLS", "SSH HCR + TLS", 12
        return "HCR", "SSH HCR (HTTP Custom)", 12
    elif parse_boolean(s.get("isSlow")):
        return "SLOWDNS", "SlowDNS (DNSTT)", 7
    elif parse_boolean(s.get("isUdpCustomSni")):
        return "UDP_CUSTOM_SNI", "UDP Custom + SNI", 6
    elif parse_boolean(s.get("isUdpCustom")):
        return "UDP_CUSTOM", "UDP Custom (Rango)", 6
    elif parse_boolean(s.get("isUdpSni")):
        return "UDP_HYSTERIA_SNI", "UDP Hysteria + SNI", 5
    elif parse_boolean(s.get("isUdp")):
        v = str(s.get("udpVersion", "1"))
        return "UDP_HYSTERIA", f"UDP Hysteria v{v}", 5
    elif parse_boolean(s.get("isZivpn")):
        return "UDP_ZIVPN", "UDP ZIVPN", 10
    elif parse_boolean(s.get("isPayloadSSL")):
        return "SSL_PAYLOAD", "SSL + Payload", 4
    elif parse_boolean(s.get("isInject")):
        return "SSH_PROXY", "SSH + Proxy", 2
    elif parse_boolean(s.get("isDirect")):
        return "DIRECT", "SSH Directo", 1
    elif parse_boolean(s.get("isSSL")):
        return "SSH_SSL", "SSH + SSL/TLS", 3
    else:
        if s.get("SNI") or s.get("SSLPort"):
            return "SSH_SSL", "SSH + SSL/TLS", 3
        return "DIRECT", "SSH Directo", 1

def parse_boolean(val, default=False):
    if val is None:
        return 1 if default else 0
    if isinstance(val, bool):
        return 1 if val else 0
    if isinstance(val, (int, float)):
        return 1 if val == 1 else 0
    if isinstance(val, str):
        return 1 if val.lower() in ("true", "1", "yes") else 0
    return 1 if default else 0

# ═════════════════════════════════════════════════════════════════════
# GESTIÓN DE BASE DE DATOS SQLITE (WAL MODE)
# ═════════════════════════════════════════════════════════════════════
def get_db_connection(db_file=DB_PATH):
    os.makedirs(os.path.dirname(db_file), exist_ok=True)
    conn = sqlite3.connect(db_file, check_same_thread=False, timeout=15.0)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL;")
    conn.execute("PRAGMA synchronous=NORMAL;")
    conn.execute("PRAGMA foreign_keys=ON;")
    return conn

def init_db(db_file=DB_PATH):
    with db_lock:
        conn = get_db_connection(db_file)
        cur = conn.cursor()

        # Auto-migración si existe el esquema viejo sin is_free / protocol_type / total_free
        cur.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='servers';")
        if cur.fetchone():
            cur.execute("PRAGMA table_info(servers);")
            cols = [row[1] for row in cur.fetchall()]
            if "is_free" not in cols or "protocol_type" not in cols:
                cur.execute("DROP TABLE servers;")

        cur.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='versions';")
        if cur.fetchone():
            cur.execute("PRAGMA table_info(versions);")
            cols = [row[1] for row in cur.fetchall()]
            if "total_free" not in cols:
                cur.execute("DROP TABLE versions;")

        # 1. Tabla Maestra de Servidores con soporte exhaustivo multi-método y Free/Premium
        cur.execute("""
        CREATE TABLE IF NOT EXISTS servers (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            server_index INTEGER NOT NULL,
            server_name TEXT NOT NULL,
            country_code TEXT NOT NULL,
            country_name TEXT NOT NULL,
            operator_name TEXT NOT NULL,
            is_free INTEGER DEFAULT 1,
            is_premium INTEGER DEFAULT 0,
            is_minfo TEXT,
            check_user TEXT,

            -- Parámetros Principales de Conexión
            server_host TEXT,
            server_port TEXT,
            ssl_port TEXT,
            proxy_ip TEXT,
            proxy_port TEXT,
            server_user TEXT,
            server_pass TEXT,
            payload TEXT,
            ssl_sni TEXT,

            -- Identificadores de Método / Protocolo
            protocol_type TEXT NOT NULL,
            protocol_name TEXT NOT NULL,
            tunnel_type INTEGER DEFAULT 1,
            is_ssl INTEGER DEFAULT 0,
            is_payload_ssl INTEGER DEFAULT 0,
            is_direct INTEGER DEFAULT 0,
            is_inject INTEGER DEFAULT 0,
            is_slow INTEGER DEFAULT 0,
            is_udp INTEGER DEFAULT 0,
            is_udp_sni INTEGER DEFAULT 0,
            is_udp_custom INTEGER DEFAULT 0,
            is_udp_custom_sni INTEGER DEFAULT 0,
            is_zivpn INTEGER DEFAULT 0,
            is_bhttp INTEGER DEFAULT 0,
            is_hcr INTEGER DEFAULT 0,
            is_tcp INTEGER DEFAULT 0,
            isocho INTEGER DEFAULT 0,

            -- V2Ray / Xray Específicos
            v2ray_protocol TEXT,
            v2ray_address TEXT,
            v2ray_port TEXT,
            v2ray_uuid TEXT,
            v2ray_security TEXT,
            v2ray_network TEXT,
            v2ray_path TEXT,
            v2ray_host TEXT,
            v2ray_server_name TEXT,
            v2ray_public_key TEXT,
            v2ray_short_id TEXT,
            v2ray_flow TEXT,
            v2ray_obfs TEXT,
            v2ray_allow_insecure INTEGER DEFAULT 0,
            use_tcp TEXT,

            -- BHTTP / XHTTP / HCR Específicos
            bhttp_host TEXT,
            bhttp_port TEXT,
            bhttp_tls INTEGER DEFAULT 0,
            bhttp_chunk TEXT,
            bhttp_tls_version TEXT,
            bhttp_shield INTEGER DEFAULT 0,
            bhttp_upload_conns INTEGER DEFAULT 1,
            bhttp_download_conns INTEGER DEFAULT 1,
            hcr_host TEXT,
            hcr_port TEXT,
            hcr_tls INTEGER DEFAULT 0,

            -- SlowDNS Específicos
            slow_chave TEXT,
            nameserver TEXT,
            slow_dns TEXT,

            -- UDP Hysteria Específicos
            udp_obfs TEXT,
            udp_version TEXT DEFAULT '1',
            udp_up TEXT,
            udp_down TEXT,
            udp_buffer TEXT,

            -- UDP ZIVPN Específicos
            zivpn_password TEXT,
            zivpn_receive_windows TEXT,

            -- Snapshot JSON Completo
            raw_json TEXT NOT NULL,
            is_active INTEGER DEFAULT 1,
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
        );
        """)

        # 2. Tabla de Versiones
        cur.execute("""
        CREATE TABLE IF NOT EXISTS versions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            version_code TEXT NOT NULL UNIQUE,
            release_notes TEXT,
            total_servers INTEGER NOT NULL,
            total_countries INTEGER NOT NULL,
            total_free INTEGER DEFAULT 0,
            total_premium INTEGER DEFAULT 0,
            checksum_hash TEXT NOT NULL,
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP
        );
        """)

        # 3. Tabla de Caché Pre-cifrada (Entrega en 1 ms)
        cur.execute("""
        CREATE TABLE IF NOT EXISTS cached_blobs (
            id INTEGER PRIMARY KEY,
            version_code TEXT NOT NULL,
            raw_json TEXT NOT NULL,
            encrypted_blob TEXT NOT NULL,
            etag TEXT NOT NULL,
            updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
        );
        """)

        # 4. Tabla de Respaldos
        cur.execute("""
        CREATE TABLE IF NOT EXISTS backups (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            backup_name TEXT NOT NULL,
            version_code TEXT NOT NULL,
            raw_content TEXT NOT NULL,
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP
        );
        """)

        # 5. Tabla de Auditoría
        cur.execute("""
        CREATE TABLE IF NOT EXISTS audit_logs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            action TEXT NOT NULL,
            details TEXT,
            ip_address TEXT,
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP
        );
        """)

        # Índices de Alto Rendimiento para Búsqueda y Filtrado Instantáneo
        cur.execute("CREATE INDEX IF NOT EXISTS idx_servers_country ON servers(country_code);")
        cur.execute("CREATE INDEX IF NOT EXISTS idx_servers_operator ON servers(operator_name);")
        cur.execute("CREATE INDEX IF NOT EXISTS idx_servers_free ON servers(is_free);")
        cur.execute("CREATE INDEX IF NOT EXISTS idx_servers_premium ON servers(is_premium);")
        cur.execute("CREATE INDEX IF NOT EXISTS idx_servers_protocol ON servers(protocol_type);")
        cur.execute("CREATE INDEX IF NOT EXISTS idx_servers_active ON servers(is_active);")
        cur.execute("CREATE INDEX IF NOT EXISTS idx_servers_tunnel ON servers(tunnel_type);")

        conn.commit()
        conn.close()

# ═════════════════════════════════════════════════════════════════════
# OPERACIONES DE SINCRONIZACIÓN Y GUARDADO DE CATÁLOGO
# ═════════════════════════════════════════════════════════════════════
def save_full_catalog(version_code, release_notes, servers_list, password=DEFAULT_GRETTA_PASS, db_file=DB_PATH):
    """
    Guarda el catálogo completo de servidores en la base de datos con
    clasificación de métodos, planes Free/Premium, caché pre-cifrada y respaldos.
    """
    with db_lock:
        init_db(db_file)
        conn = get_db_connection(db_file)
        cur = conn.cursor()

        # Construir JSON estructurado canónico
        catalog_obj = {
            "Version": str(version_code).replace("v", "").strip(),
            "ReleaseNotes": release_notes or "Servidores oficiales actualizados.",
            "Servers": servers_list
        }

        raw_json_str = json.dumps(catalog_obj, ensure_ascii=False, indent=2)
        checksum_hash = hashlib.sha256(raw_json_str.encode("utf-8")).hexdigest()
        etag = f'"{hashlib.md5(raw_json_str.encode("utf-8")).hexdigest()}"'

        # Cifrar payload para la App
        encrypted_blob = encrypt_payload(password, raw_json_str)

        # 1. Vaciar tabla de servidores actuales e insertar los nuevos con esquema completo
        cur.execute("DELETE FROM servers;")

        countries_set = set()
        free_count = 0
        premium_count = 0

        for idx, s in enumerate(servers_list):
            flag = str(s.get("FLAG", "un")).lower().strip()
            countries_set.add(flag)
            name = s.get("Name", f"Server {idx+1}")
            flagg = str(s.get("FLAGG", flag)).lower().strip()
            
            # Clasificación Free vs Premium
            is_free_val = s.get("isFree", True)
            is_free = parse_boolean(is_free_val, default=True)
            is_premium = 1 if is_free == 0 else 0

            if is_free == 1:
                free_count += 1
            else:
                premium_count += 1

            # Detección de protocolo
            proto_type, proto_name, tunnel_code = determine_protocol(s)

            # Inserción con todos los campos tipados
            cur.execute("""
            INSERT INTO servers (
                server_index, server_name, country_code, country_name, operator_name,
                is_free, is_premium, is_minfo, check_user,
                server_host, server_port, ssl_port, proxy_ip, proxy_port,
                server_user, server_pass, payload, ssl_sni,
                protocol_type, protocol_name, tunnel_type,
                is_ssl, is_payload_ssl, is_direct, is_inject, is_slow,
                is_udp, is_udp_sni, is_udp_custom, is_udp_custom_sni,
                is_zivpn, is_bhttp, is_hcr, is_tcp, isocho,
                v2ray_protocol, v2ray_address, v2ray_port, v2ray_uuid,
                v2ray_security, v2ray_network, v2ray_path, v2ray_host,
                v2ray_server_name, v2ray_public_key, v2ray_short_id,
                v2ray_flow, v2ray_obfs, v2ray_allow_insecure, use_tcp,
                bhttp_host, bhttp_port, bhttp_tls, bhttp_chunk,
                bhttp_tls_version, bhttp_shield, bhttp_upload_conns, bhttp_download_conns,
                hcr_host, hcr_port, hcr_tls,
                slow_chave, nameserver, slow_dns,
                udp_obfs, udp_version, udp_up, udp_down, udp_buffer,
                zivpn_password, zivpn_receive_windows,
                raw_json, is_active
            ) VALUES (
                ?, ?, ?, ?, ?,
                ?, ?, ?, ?,
                ?, ?, ?, ?, ?,
                ?, ?, ?, ?,
                ?, ?, ?,
                ?, ?, ?, ?, ?,
                ?, ?, ?, ?,
                ?, ?, ?, ?, ?,
                ?, ?, ?, ?,
                ?, ?, ?, ?,
                ?, ?, ?,
                ?, ?, ?, ?,
                ?, ?, ?, ?,
                ?, ?, ?, ?,
                ?, ?, ?,
                ?, ?, ?,
                ?, ?, ?, ?, ?,
                ?, ?,
                ?, 1
            );
            """, (
                idx + 1, name, flag, flagg, flagg,
                is_free, is_premium, s.get("isMinfo", ""), s.get("CheckUser", ""),
                s.get("ServerIP", s.get("Server", "")), str(s.get("ServerPort", "")), str(s.get("SSLPort", "")),
                str(s.get("ProxyIP", "")), str(s.get("ProxyPort", "")),
                s.get("ServerUser", ""), s.get("ServerPass", ""),
                s.get("Payload", ""), s.get("SNI", s.get("SSLServerName", "")),
                proto_type, proto_name, int(s.get("TunnelType", tunnel_code)),
                parse_boolean(s.get("isSSL")), parse_boolean(s.get("isPayloadSSL")),
                parse_boolean(s.get("isDirect")), parse_boolean(s.get("isInject")),
                parse_boolean(s.get("isSlow")), parse_boolean(s.get("isUdp")),
                parse_boolean(s.get("isUdpSni")), parse_boolean(s.get("isUdpCustom")),
                parse_boolean(s.get("isUdpCustomSni")), parse_boolean(s.get("isZivpn")),
                parse_boolean(s.get("isBhttp")), parse_boolean(s.get("isHcr")),
                parse_boolean(s.get("isTcp")), parse_boolean(s.get("isocho")),
                s.get("v2rayProtocol", ""), s.get("v2rayAddress", ""), str(s.get("v2rayPort", "")),
                s.get("v2rayUuid", ""), s.get("v2raySecurity", ""), s.get("v2rayNetwork", ""),
                s.get("v2rayPath", ""), s.get("v2rayHost", ""), s.get("v2rayServerName", ""),
                s.get("v2rayPublicKey", ""), s.get("v2rayShortId", ""), s.get("v2rayFlow", ""),
                s.get("v2rayObfs", ""), parse_boolean(s.get("v2rayAllowInsecure")), s.get("UseTcp", ""),
                s.get("bhttpHost", ""), str(s.get("bhttpPort", "")), parse_boolean(s.get("bhttpTls")),
                str(s.get("bhttpChunk", "")), str(s.get("bhttpTlsVersion", "")), parse_boolean(s.get("bhttpShield")),
                int(s.get("bhttpUploadConns", 1) or 1), int(s.get("bhttpDownloadConns", 1) or 1),
                s.get("hcrHost", ""), str(s.get("hcrPort", "")), parse_boolean(s.get("hcrTls")),
                s.get("Slowchave", ""), s.get("Nameserver", ""), s.get("Slowdns", ""),
                s.get("udpObfs", ""), str(s.get("udpVersion", "1")), str(s.get("udpUp", "")),
                str(s.get("udpDown", "")), str(s.get("udpBuffer", "")),
                s.get("zivpnPassword", ""), str(s.get("zivpnReceiveWindows", "")),
                json.dumps(s, ensure_ascii=False)
            ))

        # 2. Registrar en versions
        cur.execute("""
        INSERT OR REPLACE INTO versions (
            version_code, release_notes, total_servers, total_countries,
            total_free, total_premium, checksum_hash
        ) VALUES (?, ?, ?, ?, ?, ?, ?);
        """, (
            f"v{catalog_obj['Version']}",
            release_notes,
            len(servers_list),
            len(countries_set),
            free_count,
            premium_count,
            checksum_hash
        ))

        # 3. Guardar en cached_blobs (id=1)
        cur.execute("""
        INSERT OR REPLACE INTO cached_blobs (
            id, version_code, raw_json, encrypted_blob, etag, updated_at
        ) VALUES (1, ?, ?, ?, ?, CURRENT_TIMESTAMP);
        """, (
            f"v{catalog_obj['Version']}",
            raw_json_str,
            encrypted_blob or "",
            etag
        ))

        # 4. Crear Respaldo Automático
        now_tag = time.strftime("%Y%m%d_%H%M%S")
        cur.execute("""
        INSERT INTO backups (backup_name, version_code, raw_content)
        VALUES (?, ?, ?);
        """, (
            f"backup_v{catalog_obj['Version']}_{now_tag}.json",
            f"v{catalog_obj['Version']}",
            raw_json_str
        ))

        # 5. Registro de Auditoría
        cur.execute("""
        INSERT INTO audit_logs (action, details, ip_address)
        VALUES ('SAVE_CATALOG', ?, '127.0.0.1');
        """, (f"Publicada version v{catalog_obj['Version']} con {len(servers_list)} servidores ({free_count} Free, {premium_count} Premium).",))

        conn.commit()
        conn.close()
        return True, f"v{catalog_obj['Version']}", len(servers_list), len(countries_set), free_count, premium_count

def get_live_cached_blob(db_file=DB_PATH):
    """Devuelve el blob pre-cifrado en 1 ms para las peticiones de los clientes."""
    try:
        init_db(db_file)
        conn = get_db_connection(db_file)
        row = conn.execute("SELECT version_code, raw_json, encrypted_blob, etag, updated_at FROM cached_blobs WHERE id=1;").fetchone()
        conn.close()
        if row:
            return {
                "version_code": row["version_code"],
                "raw_json": row["raw_json"],
                "encrypted_blob": row["encrypted_blob"],
                "etag": row["etag"],
                "updated_at": row["updated_at"]
            }
    except Exception:
        pass
    return None

def get_stats(db_file=DB_PATH):
    """Estadísticas globales completas del servidor con desglose de países, métodos y planes."""
    try:
        init_db(db_file)
        conn = get_db_connection(db_file)
        total_servers = conn.execute("SELECT COUNT(*) FROM servers WHERE is_active=1;").fetchone()[0]
        total_countries = conn.execute("SELECT COUNT(DISTINCT country_code) FROM servers WHERE is_active=1;").fetchone()[0]
        total_free = conn.execute("SELECT COUNT(*) FROM servers WHERE is_active=1 AND is_free=1;").fetchone()[0]
        total_premium = conn.execute("SELECT COUNT(*) FROM servers WHERE is_active=1 AND is_premium=1;").fetchone()[0]
        ver_row = conn.execute("SELECT version_code, release_notes, created_at FROM versions ORDER BY id DESC LIMIT 1;").fetchone()
        
        country_counts = {}
        for r in conn.execute("SELECT country_code, COUNT(*) as cnt FROM servers WHERE is_active=1 GROUP BY country_code ORDER BY cnt DESC;"):
            country_counts[r["country_code"]] = r["cnt"]

        protocol_counts = {}
        for r in conn.execute("SELECT protocol_name, COUNT(*) as cnt FROM servers WHERE is_active=1 GROUP BY protocol_name ORDER BY cnt DESC;"):
            protocol_counts[r["protocol_name"]] = r["cnt"]

        operator_counts = {}
        for r in conn.execute("SELECT operator_name, COUNT(*) as cnt FROM servers WHERE is_active=1 GROUP BY operator_name ORDER BY cnt DESC LIMIT 15;"):
            operator_counts[r["operator_name"]] = r["cnt"]

        conn.close()
        return {
            "total_servers": total_servers,
            "total_countries": total_countries,
            "total_free": total_free,
            "total_premium": total_premium,
            "version": ver_row["version_code"] if ver_row else "v1.0.0",
            "release_notes": ver_row["release_notes"] if ver_row else "",
            "last_update": ver_row["created_at"] if ver_row else "",
            "by_country": country_counts,
            "by_protocol": protocol_counts,
            "by_operator": operator_counts
        }
    except Exception as e:
        return {"error": str(e), "total_servers": 0, "total_countries": 0, "version": "v0"}

def query_servers(filters=None, limit=100, db_file=DB_PATH):
    """Consulta flexible con filtros por país, método, free/premium o búsqueda de texto."""
    try:
        init_db(db_file)
        conn = get_db_connection(db_file)
        sql = "SELECT * FROM servers WHERE is_active=1"
        params = []
        
        if filters:
            if "country" in filters:
                sql += " AND country_code = ?"
                params.append(filters["country"].lower().strip())
            if "is_free" in filters:
                sql += " AND is_free = ?"
                params.append(1 if filters["is_free"] else 0)
            if "is_premium" in filters:
                sql += " AND is_premium = ?"
                params.append(1 if filters["is_premium"] else 0)
            if "protocol" in filters:
                sql += " AND (protocol_type = ? OR protocol_name LIKE ?)"
                params.extend([filters["protocol"].upper(), f"%{filters['protocol']}%"])
            if "search" in filters:
                term = f"%{filters['search']}%"
                sql += " AND (server_name LIKE ? OR operator_name LIKE ? OR country_code LIKE ? OR server_host LIKE ? OR protocol_name LIKE ? OR protocol_type LIKE ? OR is_minfo LIKE ?)"
                params.extend([term, term, term, term, term, term, term])

        sql += " ORDER BY server_index ASC"
        if limit:
            sql += f" LIMIT {int(limit)}"

        rows = conn.execute(sql, params).fetchall()
        result = [dict(r) for r in rows]
        conn.close()
        return result
    except Exception as e:
        return []

if __name__ == "__main__":
    init_db()
    print("✔ Base de datos CRISDEV inicializada con esquema maestro optimizado (13 métodos + Free/Premium).")
