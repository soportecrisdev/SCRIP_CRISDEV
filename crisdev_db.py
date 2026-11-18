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
from datetime import datetime, timedelta
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
    dir_name = os.path.dirname(db_file)
    if dir_name:
        os.makedirs(dir_name, exist_ok=True)
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

        # 6. Tabla Maestra de Usuarios Unificados (SSH / HWID / Token / Demo)
        cur.execute("""
        CREATE TABLE IF NOT EXISTS users (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            username TEXT NOT NULL UNIQUE,
            password_plain TEXT NOT NULL,
            password_hash TEXT,
            user_type TEXT NOT NULL DEFAULT 'SSH', -- 'SSH', 'TOKEN', 'HWID_LOCK', 'DEMO'
            hwid TEXT,                             -- Hardware ID o Device Token vinculado
            device_model TEXT,                     -- Modelo opcional del dispositivo
            limit_connections INTEGER DEFAULT 1,
            expiration_date TEXT NOT NULL,         -- Formato legible DD/MM/YYYY
            expires_at INTEGER NOT NULL,           -- Timestamp en milisegundos
            status TEXT DEFAULT 'active',          -- 'active', 'expired', 'locked'
            notes TEXT,
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
        );
        """)

        # 7. Tabla de Tokens Únicos de Dispositivo (aToken / TK-XXXX)
        cur.execute("""
        CREATE TABLE IF NOT EXISTS device_tokens (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            token TEXT NOT NULL UNIQUE,            -- 16 caracteres hex (TK-XXXX...)
            hwid_full TEXT,                        -- SHA-256 de 64 chars del teléfono
            user_id INTEGER REFERENCES users(id) ON DELETE CASCADE,
            username TEXT NOT NULL,
            expiration_date TEXT NOT NULL,
            expires_at INTEGER NOT NULL,
            limit_connections INTEGER DEFAULT 1,
            status TEXT DEFAULT 'active',          -- 'active', 'expired', 'revoked'
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP
        );
        """)

        # 8. Tabla de Sesiones Activas y Monitor en Vivo
        cur.execute("""
        CREATE TABLE IF NOT EXISTS sessions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            username TEXT NOT NULL,
            protocol TEXT NOT NULL,                -- 'SSH', 'DROPBEAR', 'BHTTP', 'HCR', 'HYSTERIA', 'UDPCUSTOM', 'ZIVPN'
            client_ip TEXT,
            pid INTEGER,
            started_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            last_seen DATETIME DEFAULT CURRENT_TIMESTAMP,
            bytes_up INTEGER DEFAULT 0,
            bytes_down INTEGER DEFAULT 0
        );
        """)

        # 9. Tabla de Nodos del Clúster (Miami, USA, Brasil, etc.)
        cur.execute("""
        CREATE TABLE IF NOT EXISTS nodes (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            node_code TEXT NOT NULL UNIQUE,        -- 'mia-01', 'usa-01', 'br-01'
            node_name TEXT NOT NULL,
            country_code TEXT NOT NULL,            -- 'us', 'br', 'co'
            public_ip TEXT NOT NULL,
            api_port INTEGER DEFAULT 8088,
            auth_token TEXT,
            is_master INTEGER DEFAULT 0,
            status TEXT DEFAULT 'online',          -- 'online', 'offline', 'maintenance'
            last_heartbeat DATETIME,
            online_users INTEGER DEFAULT 0,
            cpu_load REAL DEFAULT 0.0,
            ram_used_mb INTEGER DEFAULT 0,
            total_ram_mb INTEGER DEFAULT 0,
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

        cur.execute("CREATE INDEX IF NOT EXISTS idx_users_username ON users(username);")
        cur.execute("CREATE INDEX IF NOT EXISTS idx_users_status ON users(status);")
        cur.execute("CREATE INDEX IF NOT EXISTS idx_users_expires ON users(expires_at);")
        cur.execute("CREATE INDEX IF NOT EXISTS idx_users_hwid ON users(hwid);")
        cur.execute("CREATE INDEX IF NOT EXISTS idx_device_tokens_token ON device_tokens(token);")
        cur.execute("CREATE INDEX IF NOT EXISTS idx_sessions_username ON sessions(username);")
        cur.execute("CREATE INDEX IF NOT EXISTS idx_nodes_code ON nodes(node_code);")

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

# ═════════════════════════════════════════════════════════════════════
# GESTIÓN UNIFICADA DE USUARIOS, HWID, TOKENS Y SESIONES (v2.0)
# ═════════════════════════════════════════════════════════════════════

def _calc_expiration(days):
    """Calcula timestamp ms y fecha DD/MM/YYYY a partir de cantidad de días."""
    now = datetime.now()
    exp_dt = now + timedelta(days=int(days))
    date_formatted = exp_dt.strftime("%d/%m/%Y")
    expires_at_ms = int(exp_dt.timestamp() * 1000)
    return date_formatted, expires_at_ms

def _calc_days_remaining(expires_at_ms):
    """Calcula días restantes a partir de un timestamp en ms."""
    now_ms = int(time.time() * 1000)
    diff_ms = expires_at_ms - now_ms
    if diff_ms <= 0:
        return 0
    return int((diff_ms + (1000 * 3600 * 12)) // (1000 * 3600 * 24))

def create_or_update_user(username, password, days=30, limit=1, user_type='SSH', hwid=None, device_model=None, notes=None, db_file=DB_PATH):
    """Crea o actualiza un usuario en la base de datos central."""
    init_db(db_file)
    username = username.strip()
    date_formatted, expires_at_ms = _calc_expiration(days)
    
    with db_lock:
        conn = get_db_connection(db_file)
        cur = conn.cursor()
        cur.execute("""
            INSERT INTO users (username, password_plain, user_type, hwid, device_model, limit_connections, expiration_date, expires_at, status, notes)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'active', ?)
            ON CONFLICT(username) DO UPDATE SET
                password_plain=excluded.password_plain,
                user_type=excluded.user_type,
                hwid=COALESCE(excluded.hwid, users.hwid),
                device_model=COALESCE(excluded.device_model, users.device_model),
                limit_connections=excluded.limit_connections,
                expiration_date=excluded.expiration_date,
                expires_at=excluded.expires_at,
                status='active',
                notes=excluded.notes,
                updated_at=CURRENT_TIMESTAMP;
        """, (username, password, user_type, hwid, device_model, int(limit), date_formatted, expires_at_ms, notes))
        
        # Si es de tipo TOKEN o tiene HWID, registrarlo en device_tokens
        if user_type == 'TOKEN' or (hwid and hwid.startswith("TK-")):
            token_clean = (hwid or username).replace("TK-", "").replace("-", "").upper()
            cur.execute("""
                INSERT INTO device_tokens (token, username, expiration_date, expires_at, limit_connections, status)
                VALUES (?, ?, ?, ?, ?, 'active')
                ON CONFLICT(token) DO UPDATE SET
                    username=excluded.username,
                    expiration_date=excluded.expiration_date,
                    expires_at=excluded.expires_at,
                    limit_connections=excluded.limit_connections,
                    status='active';
            """, (token_clean, username, date_formatted, expires_at_ms, int(limit)))

        conn.commit()
        conn.close()
    return {
        "success": True,
        "username": username,
        "user_type": user_type,
        "limit": int(limit),
        "days": int(days),
        "expiration_date": date_formatted,
        "expires_at": expires_at_ms
    }

def delete_user(username, db_file=DB_PATH):
    """Elimina un usuario y sus tokens vinculados."""
    init_db(db_file)
    with db_lock:
        conn = get_db_connection(db_file)
        cur = conn.cursor()
        cur.execute("DELETE FROM users WHERE username = ?", (username,))
        cur.execute("DELETE FROM device_tokens WHERE username = ?", (username,))
        cur.execute("DELETE FROM sessions WHERE username = ?", (username,))
        conn.commit()
        conn.close()
    return {"success": True, "deleted": username}

def get_user(username, db_file=DB_PATH):
    """Obtiene información completa de un usuario por nombre."""
    init_db(db_file)
    conn = get_db_connection(db_file)
    row = conn.execute("SELECT * FROM users WHERE username = ?", (username,)).fetchone()
    conn.close()
    if not row:
        return None
    d = dict(row)
    d["days_remaining"] = _calc_days_remaining(d["expires_at"])
    d["is_expired"] = d["days_remaining"] <= 0 or d["status"] == 'expired'
    return d

def list_users(filter_status=None, search=None, limit=1000, db_file=DB_PATH):
    """Lista usuarios registrados con cálculo en vivo de días restantes y sesiones activas."""
    init_db(db_file)
    conn = get_db_connection(db_file)
    sql = "SELECT u.*, (SELECT COUNT(*) FROM sessions s WHERE s.username = u.username) AS active_sessions FROM users u WHERE 1=1"
    params = []
    
    if filter_status:
        sql += " AND u.status = ?"
        params.append(filter_status)
    if search:
        term = f"%{search}%"
        sql += " AND (u.username LIKE ? OR u.hwid LIKE ? OR u.notes LIKE ?)"
        params.extend([term, term, term])
        
    sql += " ORDER BY u.expires_at ASC LIMIT ?"
    params.append(int(limit))
    
    rows = conn.execute(sql, params).fetchall()
    conn.close()
    
    users = []
    now_ms = int(time.time() * 1000)
    for r in rows:
        item = dict(r)
        rem = _calc_days_remaining(item["expires_at"])
        item["days_remaining"] = rem
        if rem <= 0 and item["status"] == 'active':
            item["status"] = 'expired'
            item["is_expired"] = True
        else:
            item["is_expired"] = (item["status"] == 'expired')
        users.append(item)
    return users

def renew_user(username, days=30, db_file=DB_PATH):
    """Renueva un usuario fijando su vigencia desde el momento actual."""
    date_formatted, expires_at_ms = _calc_expiration(days)
    with db_lock:
        conn = get_db_connection(db_file)
        conn.execute("""
            UPDATE users SET expiration_date = ?, expires_at = ?, status = 'active', updated_at = CURRENT_TIMESTAMP
            WHERE username = ?
        """, (date_formatted, expires_at_ms, username))
        conn.execute("""
            UPDATE device_tokens SET expiration_date = ?, expires_at = ?, status = 'active'
            WHERE username = ?
        """, (date_formatted, expires_at_ms, username))
        conn.commit()
        conn.close()
    return {"success": True, "username": username, "days": days, "expiration_date": date_formatted, "expires_at": expires_at_ms}

def add_days_user(username, extra_days, db_file=DB_PATH):
    """Suma días a la fecha de vencimiento actual de un usuario."""
    u = get_user(username, db_file)
    if not u:
        return {"error": "Usuario no encontrado"}
    
    cur_exp = u["expires_at"]
    now_ms = int(time.time() * 1000)
    base_ts = cur_exp if cur_exp > now_ms else now_ms
    new_exp_ms = base_ts + (int(extra_days) * 86400 * 1000)
    new_date = datetime.fromtimestamp(new_exp_ms / 1000.0).strftime("%d/%m/%Y")
    
    with db_lock:
        conn = get_db_connection(db_file)
        conn.execute("""
            UPDATE users SET expiration_date = ?, expires_at = ?, status = 'active', updated_at = CURRENT_TIMESTAMP
            WHERE username = ?
        """, (new_date, new_exp_ms, username))
        conn.execute("""
            UPDATE device_tokens SET expiration_date = ?, expires_at = ?, status = 'active'
            WHERE username = ?
        """, (new_date, new_exp_ms, username))
        conn.commit()
        conn.close()
    return {"success": True, "username": username, "added": extra_days, "expiration_date": new_date, "expires_at": new_exp_ms}

def subtract_days_user(username, sub_days, db_file=DB_PATH):
    """Resta días a la fecha de vencimiento actual de un usuario."""
    u = get_user(username, db_file)
    if not u:
        return {"error": "Usuario no encontrado"}
    
    cur_exp = u["expires_at"]
    new_exp_ms = cur_exp - (int(sub_days) * 86400 * 1000)
    new_date = datetime.fromtimestamp(new_exp_ms / 1000.0).strftime("%d/%m/%Y")
    now_ms = int(time.time() * 1000)
    st = 'expired' if new_exp_ms <= now_ms else 'active'
    
    with db_lock:
        conn = get_db_connection(db_file)
        conn.execute("""
            UPDATE users SET expiration_date = ?, expires_at = ?, status = ?, updated_at = CURRENT_TIMESTAMP
            WHERE username = ?
        """, (new_date, new_exp_ms, st, username))
        conn.execute("""
            UPDATE device_tokens SET expiration_date = ?, expires_at = ?, status = ?
            WHERE username = ?
        """, (new_date, new_exp_ms, st, username))
        conn.commit()
        conn.close()
    return {"success": True, "username": username, "subtracted": sub_days, "expiration_date": new_date, "expires_at": new_exp_ms}

def change_limit_user(username, new_limit, db_file=DB_PATH):
    """Modifica el límite máximo de conexiones simultáneas."""
    with db_lock:
        conn = get_db_connection(db_file)
        conn.execute("UPDATE users SET limit_connections = ?, updated_at = CURRENT_TIMESTAMP WHERE username = ?", (int(new_limit), username))
        conn.execute("UPDATE device_tokens SET limit_connections = ? WHERE username = ?", (int(new_limit), username))
        conn.commit()
        conn.close()
    return {"success": True, "username": username, "limit": int(new_limit)}

def change_password_user(username, new_password, db_file=DB_PATH):
    """Actualiza la contraseña del usuario."""
    with db_lock:
        conn = get_db_connection(db_file)
        conn.execute("UPDATE users SET password_plain = ?, updated_at = CURRENT_TIMESTAMP WHERE username = ?", (new_password, username))
        conn.commit()
        conn.close()
    return {"success": True, "username": username}

def set_hwid_lock(username, hwid, device_model=None, db_file=DB_PATH):
    """Vincula el candado HWID al usuario."""
    with db_lock:
        conn = get_db_connection(db_file)
        conn.execute("""
            UPDATE users SET hwid = ?, device_model = COALESCE(?, device_model), user_type = 'HWID_LOCK', updated_at = CURRENT_TIMESTAMP
            WHERE username = ?
        """, (hwid.strip(), device_model, username))
        conn.commit()
        conn.close()
    return {"success": True, "username": username, "hwid": hwid}

def reset_hwid(username, db_file=DB_PATH):
    """Libera el candado HWID de un usuario para que pueda vincular un nuevo dispositivo."""
    with db_lock:
        conn = get_db_connection(db_file)
        conn.execute("""
            UPDATE users SET hwid = NULL, device_model = NULL, updated_at = CURRENT_TIMESTAMP
            WHERE username = ?
        """, (username,))
        conn.commit()
        conn.close()
    return {"success": True, "username": username, "message": "Candado HWID liberado"}

def set_user_status(username, status, db_file=DB_PATH):
    """Cambia el estado de un usuario ('active', 'locked', 'expired')."""
    with db_lock:
        conn = get_db_connection(db_file)
        conn.execute("UPDATE users SET status = ?, updated_at = CURRENT_TIMESTAMP WHERE username = ?", (status, username))
        conn.execute("UPDATE device_tokens SET status = ? WHERE username = ?", (status, username))
        conn.commit()
        conn.close()
    return {"success": True, "username": username, "status": status}

def clean_expired_users(db_file=DB_PATH):
    """Marca como expirados y limpia usuarios vencidos."""
    now_ms = int(time.time() * 1000)
    with db_lock:
        conn = get_db_connection(db_file)
        cur = conn.cursor()
        cur.execute("UPDATE users SET status = 'expired' WHERE expires_at <= ? AND status = 'active'", (now_ms,))
        cur.execute("UPDATE device_tokens SET status = 'expired' WHERE expires_at <= ? AND status = 'active'", (now_ms,))
        count = cur.rowcount
        conn.commit()
        conn.close()
    return {"success": True, "marked_expired": count}

def get_user_stats(db_file=DB_PATH):
    """Obtiene resumen instantáneo en < 2 ms para el dashboard superior del menú."""
    init_db(db_file)
    conn = get_db_connection(db_file)
    now_ms = int(time.time() * 1000)
    
    total = conn.execute("SELECT COUNT(*) FROM users").fetchone()[0]
    active = conn.execute("SELECT COUNT(*) FROM users WHERE status = 'active' AND expires_at > ?", (now_ms,)).fetchone()[0]
    expired = conn.execute("SELECT COUNT(*) FROM users WHERE status = 'expired' OR expires_at <= ?", (now_ms,)).fetchone()[0]
    locked = conn.execute("SELECT COUNT(*) FROM users WHERE status = 'locked'").fetchone()[0]
    online = conn.execute("SELECT COUNT(DISTINCT username) FROM sessions").fetchone()[0]
    
    ssh_users = conn.execute("SELECT COUNT(*) FROM users WHERE user_type IN ('SSH', 'HWID_LOCK')").fetchone()[0]
    token_users = conn.execute("SELECT COUNT(*) FROM users WHERE user_type = 'TOKEN'").fetchone()[0]
    demo_users = conn.execute("SELECT COUNT(*) FROM users WHERE user_type = 'DEMO'").fetchone()[0]
    
    conn.close()
    return {
        "total": total,
        "active": active,
        "expired": expired,
        "locked": locked,
        "online": online,
        "ssh": ssh_users,
        "token": token_users,
        "demo": demo_users
    }

# ═════════════════════════════════════════════════════════════════════
# DEMONIO CHECKUSER & VALIDADOR ATOKEN (COMPATIBLE CON HTTP CONEXIÓN)
# ═════════════════════════════════════════════════════════════════════

def register_device_token(token, days=30, limit=1, hwid_full=None, username=None, db_file=DB_PATH):
    """Registra o renueva un token de teléfono de 16 caracteres (aToken)."""
    clean_token = token.replace("TK-", "").replace("-", "").strip().upper()
    user_name = username or f"Token_{clean_token}"
    date_formatted, expires_at_ms = _calc_expiration(days)
    
    with db_lock:
        conn = get_db_connection(db_file)
        cur = conn.cursor()
        # 1. Crear / actualizar en users
        cur.execute("""
            INSERT INTO users (username, password_plain, user_type, hwid, limit_connections, expiration_date, expires_at, status)
            VALUES (?, ?, 'TOKEN', ?, ?, ?, ?, 'active')
            ON CONFLICT(username) DO UPDATE SET
                expiration_date=excluded.expiration_date,
                expires_at=excluded.expires_at,
                status='active',
                updated_at=CURRENT_TIMESTAMP;
        """, (user_name, clean_token, clean_token, int(limit), date_formatted, expires_at_ms))
        
        # 2. Registrar en device_tokens
        cur.execute("""
            INSERT INTO device_tokens (token, hwid_full, username, expiration_date, expires_at, limit_connections, status)
            VALUES (?, ?, ?, ?, ?, ?, 'active')
            ON CONFLICT(token) DO UPDATE SET
                username=excluded.username,
                hwid_full=COALESCE(excluded.hwid_full, device_tokens.hwid_full),
                expiration_date=excluded.expiration_date,
                expires_at=excluded.expires_at,
                limit_connections=excluded.limit_connections,
                status='active';
        """, (clean_token, hwid_full, user_name, date_formatted, expires_at_ms, int(limit)))
        conn.commit()
        conn.close()
        
    return {
        "success": True,
        "token": clean_token,
        "formatted_token": f"TK-{clean_token[:4]}-{clean_token[4:8]}-{clean_token[8:12]}-{clean_token[12:16]}" if len(clean_token) == 16 else f"TK-{clean_token}",
        "username": user_name,
        "days": days,
        "expiration_date": date_formatted,
        "expires_at": expires_at_ms
    }

def validate_device_token(token, db_file=DB_PATH):
    """
    Valida un Token contra aToken en el VPS.
    Retorna respuesta exacta compatible con VpsUserAuthManager.kt (L208-L230).
    """
    clean_token = token.replace("TK-", "").replace("-", "").strip().upper()
    init_db(db_file)
    conn = get_db_connection(db_file)
    row = conn.execute("SELECT * FROM device_tokens WHERE token = ?", (clean_token,)).fetchone()
    conn.close()
    
    if not row:
        return {"status": "INVALID", "message": "Token no registrado", "is_valid": False}
        
    d = dict(row)
    now_ms = int(time.time() * 1000)
    rem_days = _calc_days_remaining(d["expires_at"])
    
    if d["status"] != 'active' or d["expires_at"] <= now_ms:
        return {"status": "EXPIRED", "message": "Token expirado o revocado", "token": clean_token, "days": 0, "is_valid": False}
        
    # Compatible con: responseBody.contains("OK") || responseBody.contains(phoneToken)
    return {
        "status": "OK",
        "message": "Token valido y activo",
        "token": clean_token,
        "username": d["username"],
        "days": rem_days,
        "expiration_date": d["expiration_date"],
        "expires_at": d["expires_at"],
        "limit": d["limit_connections"],
        "is_valid": True
    }

def checkuser_query(username, hwid=None, db_file=DB_PATH):
    """
    Responde al demonio CheckUser en el contrato universal esperado por VpsUserAuthManager.kt.
    Soporta verificación de expiración, límite de conexiones y candado HWID.
    """
    init_db(db_file)
    user = get_user(username, db_file)
    
    if not user:
        return {
            "error": "not_found",
            "message": "Usuario no existe",
            "active": False,
            "is_expired": True,
            "days": 0,
            "status": "not_found"
        }
        
    # Verificar candado HWID si aplica
    if user["user_type"] == 'HWID_LOCK' and hwid:
        clean_hwid = hwid.strip()
        if not user.get("hwid"):
            # Primer dispositivo: vinculación automática
            set_hwid_lock(username, clean_hwid, db_file=db_file)
            user["hwid"] = clean_hwid
        elif user["hwid"] != clean_hwid:
            return {
                "error": "device_mismatch",
                "message": "Dispositivo no autorizado para esta cuenta (Candado HWID activo)",
                "active": False,
                "is_expired": False,
                "status": "device_mismatch"
            }
            
    # Contar sesiones activas actuales
    conn = get_db_connection(db_file)
    active_sessions = conn.execute("SELECT COUNT(*) FROM sessions WHERE username = ?", (username,)).fetchone()[0]
    conn.close()
    
    is_exp = user["is_expired"] or user["days_remaining"] <= 0
    st = "expired" if is_exp else user["status"]
    
    return {
        "username": user["username"],
        "user": user["username"],
        "active": not is_exp and st == 'active',
        "is_expired": is_exp,
        "days": user["days_remaining"],
        "expiration_days": user["days_remaining"],
        "expiration_date": user["expiration_date"],
        "expires_at": user["expires_at"],
        "limit": user["limit_connections"],
        "limit_connections": user["limit_connections"],
        "max_connections": user["limit_connections"],
        "active_sessions": active_sessions,
        "count_connections": active_sessions,
        "online": active_sessions,
        "status": st
    }

def record_session(username, protocol, client_ip, pid=None, db_file=DB_PATH):
    """Registra una sesión de conexión activa."""
    init_db(db_file)
    with db_lock:
        conn = get_db_connection(db_file)
        conn.execute("""
            INSERT INTO sessions (username, protocol, client_ip, pid, last_seen)
            VALUES (?, ?, ?, ?, CURRENT_TIMESTAMP)
        """, (username, protocol.upper(), client_ip, pid))
        conn.commit()
        conn.close()

def remove_session(pid=None, username=None, client_ip=None, db_file=DB_PATH):
    """Elimina una sesión activa."""
    with db_lock:
        conn = get_db_connection(db_file)
        if pid:
            conn.execute("DELETE FROM sessions WHERE pid = ?", (pid,))
        elif username and client_ip:
            conn.execute("DELETE FROM sessions WHERE username = ? AND client_ip = ?", (username, client_ip))
        elif username:
            conn.execute("DELETE FROM sessions WHERE username = ?", (username,))
        conn.commit()
        conn.close()

def sync_from_system(db_file=DB_PATH):
    """
    Importa automáticamente cualquier usuario existente de Linux (/etc/passwd, /etc/shadow,
    /etc/SSHPlus/senha/ y /root/usuarios.db) a la base de datos central sin duplicados.
    """
    imported = 0
    init_db(db_file)
    
    # 1. Leer contraseñas de /etc/SSHPlus/senha/
    passwords = {}
    senha_dir = "/etc/SSHPlus/senha"
    if os.path.isdir(senha_dir):
        for fname in os.listdir(senha_dir):
            fpath = os.path.join(senha_dir, fname)
            if os.path.isfile(fpath):
                try:
                    with open(fpath, "r", encoding="utf-8", errors="ignore") as f:
                        passwords[fname] = f.readline().strip()
                except Exception:
                    pass
                    
    # 2. Leer límites de /etc/SSHPlus/usuarios.db o /root/usuarios.db
    limits = {}
    for db_text in ["/etc/SSHPlus/usuarios.db", "/root/usuarios.db", "/etc/ssh-cris/users.db"]:
        if os.path.isfile(db_text):
            try:
                with open(db_text, "r", encoding="utf-8", errors="ignore") as f:
                    for line in f:
                        parts = line.strip().split(":")
                        if len(parts) >= 2:
                            u = parts[0].strip()
                            lim = int(parts[1].strip()) if parts[1].strip().isdigit() else 1
                            limits[u] = lim
            except Exception:
                pass
                
    # 3. Leer usuarios Linux reales (UID >= 1000)
    if os.path.isfile("/etc/passwd"):
        ignored = {'nobody', 'daemon', 'bin', 'sys', 'sync', 'games', 'man', 'lp', 'mail', 'news', 'uucp', 'proxy', 'www-data', 'backup', 'list', 'irc', 'gnats', '_apt', 'sshd', 'statd', 'mysql', 'postfix', 'dovecot', 'redis', 'mongodb'}
        try:
            with open("/etc/passwd", "r", encoding="utf-8", errors="ignore") as f:
                for line in f:
                    parts = line.strip().split(":")
                    if len(parts) >= 6:
                        u = parts[0].strip()
                        uid = int(parts[2].strip()) if parts[2].strip().isdigit() else 0
                        if uid >= 1000 and u not in ignored:
                            # Comprobar si ya existe en SQLite
                            existing = get_user(u, db_file)
                            if not existing:
                                pwd = passwords.get(u, "1234")
                                lim = limits.get(u, 1)
                                create_or_update_user(u, pwd, days=30, limit=lim, user_type='SSH', db_file=db_file)
                                imported += 1
        except Exception:
            pass
            
    return {"success": True, "imported_from_system": imported}

if __name__ == "__main__":
    init_db()
    stats = get_user_stats()
    print(f"✔ Base de datos CRISDEV v2.0 inicializada con éxito.")
    print(f"  Usuarios Totales: {stats['total']} | Activos: {stats['active']} | En Línea: {stats['online']}")

