#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
CRISDEV V2Ray / Xray Pro Core Manager
Manipula /etc/v2ray/config.json de forma segura (respaldo + validacion + rollback).
Soporta Modo Multi-Puerto Pro, Modo Puerto Unico, gestion de UUIDs y generador de JSON/Links.
"""
import argparse
import base64
import json
import os
import shutil
import socket
import subprocess
import sys
import uuid as uuid_lib

CONFIG_PATHS = [
    "/etc/v2ray/config.json",
    "/usr/local/etc/v2ray/config.json",
    "/usr/local/etc/xray/config.json",
    "/etc/xray/config.json",
]
SSL_CERT = "/etc/ssl/crisdev/fullchain.crt"
SSL_KEY = "/etc/ssl/crisdev/private.key"
ROUTES_FILE = "/etc/v2ray/wsproxy_routes.conf"
EXPORT_DIR = "/root/v2ray_configs"

RESERVED_SERVICES = {
    22: "OpenSSH",
    80: "wsproxy.py (SSH/V2Ray Passthrough)",
    90: "hcr-server",
    110: "Dropbear",
    443: "stunnel4 (SSH-SSL)",
    2053: "xhttp-server (BHTTP-TLS)",
    2082: "bhttp-server",
    2083: "xhttp-server (BHTTP-TLS)",
    2086: "bhttp-server",
    8080: "bhttp-server",
    8088: "bhttp-server",
    8090: "hcr-server",
    8444: "xhttp-server (BHTTP-TLS)",
    8881: "bhttp-server",
}


def run_cmd(cmd):
    return subprocess.run(cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)


def get_config_path():
    for p in CONFIG_PATHS:
        if os.path.isfile(p):
            return p
    os.makedirs("/etc/v2ray", exist_ok=True)
    return "/etc/v2ray/config.json"


def get_v2ray_bin():
    for b in ("/usr/bin/v2ray/v2ray", "/usr/local/bin/v2ray", "/usr/local/bin/xray", "/usr/bin/xray/xray"):
        if os.path.isfile(b) and os.access(b, os.X_OK):
            return b
    return "v2ray"


def get_service_name():
    if os.path.isfile("/etc/systemd/system/v2ray.service"):
        return "v2ray"
    if os.path.isfile("/etc/systemd/system/xray.service"):
        return "xray"
    return "v2ray"


def ensure_cert():
    if os.path.isfile(SSL_CERT) and os.path.isfile(SSL_KEY):
        return SSL_CERT, SSL_KEY
    os.makedirs(os.path.dirname(SSL_CERT), exist_ok=True)
    run_cmd(
        f"openssl ecparam -name prime256v1 -genkey -noout -out {SSL_KEY} && "
        f"openssl req -new -x509 -key {SSL_KEY} -out {SSL_CERT} -days 3650 "
        f"-subj '/CN=ip.crispdev.online' && chmod 644 {SSL_CERT} && chmod 600 {SSL_KEY}"
    )
    return SSL_CERT, SSL_KEY


def port_owner_other_than_v2ray(port):
    r = run_cmd(f"ss -tlpn 2>/dev/null | grep -E ':{port}\\b'")
    out = r.stdout.strip()
    if not out:
        return None
    if "v2ray" in out or "xray" in out:
        return None
    return out.splitlines()[0]


def load_config():
    path = get_config_path()
    if not os.path.isfile(path):
        return None
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def extract_existing_clients(cfg):
    """Preserva UUIDs existentes al reconfigurar para no desconectar usuarios activos."""
    seen = {}
    if not cfg:
        return []
    for ib in cfg.get("inbounds", []):
        for c in ib.get("settings", {}).get("clients", []):
            cid = c.get("id", "").strip()
            if cid and cid not in seen:
                seen[cid] = c.get("email", "")
    return [{"id": k, "email": v} for k, v in seen.items()]


def make_inbound(tag, port, listen, protocol, use_tls, ws_path, clients, cert_crt, cert_key):
    if protocol == "vmess":
        ib_clients = [{"id": c["id"], "alterId": 0, **({"email": c["email"]} if c.get("email") else {})} for c in clients]
        settings = {"clients": ib_clients}
    else:
        ib_clients = [{"id": c["id"], **({"email": c["email"]} if c.get("email") else {})} for c in clients]
        settings = {"clients": ib_clients, "decryption": "none"}

    stream = {
        "network": "ws",
        "security": "tls" if use_tls else "none",
        "wsSettings": {"path": ws_path},
    }
    if use_tls:
        stream["tlsSettings"] = {
            "alpn": ["http/1.1"],
            "minVersion": "1.2",
            "certificates": [{"certificateFile": cert_crt, "keyFile": cert_key}],
        }

    return {
        "tag": tag,
        "port": int(port),
        "listen": listen,
        "protocol": protocol,
        "settings": settings,
        "streamSettings": stream,
        "sniffing": {"enabled": True, "destOverride": ["http", "tls"]},
    }


def write_wsproxy_routes(cfg):
    """Exporta rutas WS planas a /etc/v2ray/wsproxy_routes.conf para passthrough dinamico en wsproxy.py."""
    lines = []
    for ib in cfg.get("inbounds", []):
        ss = ib.get("streamSettings", {})
        if ss.get("network") == "ws" and ss.get("security", "none") == "none":
            p = ss.get("wsSettings", {}).get("path", "").strip()
            port = ib.get("port")
            if p and p != "/" and port:
                lines.append(f"{p.rstrip('/')}={port}")
    os.makedirs(os.path.dirname(ROUTES_FILE), exist_ok=True)
    with open(ROUTES_FILE, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + ("\n" if lines else ""))


def open_iptables_ports(cfg):
    for ib in cfg.get("inbounds", []):
        listen = ib.get("listen", "0.0.0.0")
        port = ib.get("port")
        if port and listen != "127.0.0.1":
            run_cmd(
                f"iptables -C INPUT -p tcp --dport {port} -j ACCEPT 2>/dev/null || "
                f"iptables -I INPUT 1 -p tcp --dport {port} -j ACCEPT"
            )


def save_validate_restart(cfg):
    path = get_config_path()
    bak = path + ".bak_manager"
    if os.path.isfile(path):
        shutil.copy2(path, bak)

    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(cfg, f, indent=2)

    vbin = get_v2ray_bin()
    test_cmd = f"{vbin} test -c {path}"
    r = run_cmd(test_cmd)
    if r.returncode != 0:
        # Fallback para xray -test
        r2 = run_cmd(f"{vbin} -test -c {path}")
        if r2.returncode != 0:
            if os.path.isfile(bak):
                shutil.copy2(bak, path)
            print("ERROR: Configuracion invalida, se restauro respaldo automatico:")
            print(r.stdout or r.stderr or r2.stderr)
            sys.exit(1)

    write_wsproxy_routes(cfg)
    open_iptables_ports(cfg)
    svc = get_service_name()
    run_cmd(f"systemctl enable {svc} >/dev/null 2>&1; systemctl restart {svc}")
    st = run_cmd(f"systemctl is-active {svc}").stdout.strip()
    print(f"OK: {svc} reiniciado (estado: {st})")


def has_ipv6_egress():
    """Detecta si la VPS tiene conectividad IPv6 real de salida."""
    r = run_cmd("ip -6 route get 2606:4700:4700::1111 2>/dev/null")
    return r.returncode == 0 and ("via " in r.stdout or "dev " in r.stdout) and "unreachable" not in r.stdout


def apply_pro_tuning(cfg):
    """Aplica tuning Pro a una config V2Ray/Xray preservando todos los inbounds y UUIDs."""
    # 1. Policy nivel 0 optimizada (handshake rapido + connIdle 300s)
    cfg["policy"] = {
        "levels": {
            "0": {
                "handshake": 4,
                "connIdle": 300,
                "uplinkOnly": 1,
                "downlinkOnly": 1,
            }
        },
        "system": {
            "statsInboundUplink": False,
            "statsInboundDownlink": False,
        },
    }

    # 2. DNS rapido IPv4 en el servidor
    cfg["dns"] = {
        "queryStrategy": "UseIPv4",
        "servers": ["1.1.1.1", "8.8.8.8", "localhost"],
    }

    # 3. Outbound direct con UseIPv4 + sockopt keepalive
    outbounds = cfg.get("outbounds", [])
    has_direct = False
    has_block = False
    for ob in outbounds:
        if ob.get("protocol") == "freedom":
            has_direct = True
            ob.setdefault("tag", "direct")
            ob.setdefault("settings", {})["domainStrategy"] = "UseIPv4"
            ob.setdefault("streamSettings", {}).setdefault("sockopt", {}).update({
                "tcpKeepAliveInterval": 30,
                "tcpNoDelay": True,
            })
        elif ob.get("protocol") == "blackhole":
            has_block = True
            ob.setdefault("tag", "block")
    if not has_direct:
        outbounds.insert(0, {
            "protocol": "freedom",
            "settings": {"domainStrategy": "UseIPv4"},
            "streamSettings": {"sockopt": {"tcpKeepAliveInterval": 30, "tcpNoDelay": True}},
            "tag": "direct",
        })
    if not has_block:
        outbounds.append({"protocol": "blackhole", "settings": {}, "tag": "block"})
    cfg["outbounds"] = outbounds

    # 4. Enrutamiento anti-privadas + bloqueo inteligente de IPv6 si la VPS no tiene salida IPv6
    block_ips = [
        "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "169.254.0.0/16",
        "172.16.0.0/12", "192.0.0.0/24", "192.168.0.0/16",
        "::1/128", "fc00::/7", "fe80::/10",
    ]
    ipv6_blocked = False
    if not has_ipv6_egress():
        block_ips.append("::/0")
        ipv6_blocked = True

    cfg["routing"] = {
        "domainStrategy": "AsIs",
        "rules": [
            {
                "type": "field",
                "ip": block_ips,
                "outboundTag": "block",
            }
        ],
    }
    return cfg, ipv6_blocked


def base_config(inbounds):
    cfg = {
        "log": {
            "access": "/var/log/v2ray/access.log",
            "error": "/var/log/v2ray/error.log",
            "loglevel": "warning",
        },
        "inbounds": inbounds,
        "outbounds": [],
        "routing": {},
    }
    cfg, _ = apply_pro_tuning(cfg)
    return cfg


def cmd_optimize(_args):
    cfg = load_config()
    if not cfg or not cfg.get("inbounds"):
        print("ERROR: No existe /etc/v2ray/config.json activo. Ejecuta primero la instalacion.")
        sys.exit(1)
    cfg, ipv6_blocked = apply_pro_tuning(cfg)
    save_validate_restart(cfg)
    # Aplicar sysctl BBR + TCP FastOpen + MTU probing
    sysctl_conf = (
        "net.core.default_qdisc = fq\n"
        "net.ipv4.tcp_congestion_control = bbr\n"
        "net.core.rmem_max = 16777216\n"
        "net.core.wmem_max = 16777216\n"
        "net.ipv4.tcp_rmem = 4096 65536 16777216\n"
        "net.ipv4.tcp_wmem = 4096 65536 16777216\n"
        "net.core.somaxconn = 65535\n"
        "net.ipv4.tcp_fastopen = 3\n"
        "net.ipv4.tcp_mtu_probing = 1\n"
    )
    os.makedirs("/etc/sysctl.d", exist_ok=True)
    with open("/etc/sysctl.d/99-crisdev-v2ray-bbr.conf", "w", encoding="utf-8") as f:
        f.write(sysctl_conf)
    run_cmd("sysctl -p /etc/sysctl.d/99-crisdev-v2ray-bbr.conf >/dev/null 2>&1 || true")
    print(f"Tuning Pro aplicado -> IPv6_BLOCK={'ACTIVO (::/0)' if ipv6_blocked else 'NO REQUERIDO (IPv6 nativo)'} | Policy L0 + DNS IPv4 + BBR/TFO OK")


def cmd_status(_args):
    svc = get_service_name()
    st = run_cmd(f"systemctl is-active {svc}").stdout.strip() or "inactive"
    cfg = load_config()
    inbounds = cfg.get("inbounds", []) if cfg else []
    clients = extract_existing_clients(cfg)
    cert_info = "No configurado"
    if os.path.isfile(SSL_CERT):
        iss = run_cmd(f"openssl x509 -in {SSL_CERT} -noout -issuer -enddate 2>/dev/null").stdout.strip().replace("\n", " | ")
        cert_info = iss or "Presente"
    mode = "Multi-Puerto" if len(inbounds) > 1 else ("Puerto Unico" if len(inbounds) == 1 else "Sin configurar")
    ports_str = ", ".join(
        f"{ib['port']}({ib['protocol'].upper()}{'+TLS' if ib.get('streamSettings',{}).get('security')=='tls' else ''})"
        for ib in inbounds
    )
    print(f"SERVICE={svc}")
    print(f"STATE={st}")
    print(f"MODE={mode}")
    print(f"PORTS={ports_str or 'Ninguno'}")
    print(f"USERS={len(clients)}")
    print(f"CERT={cert_info}")


def cmd_init_multi(args):
    existing = load_config()
    clients = extract_existing_clients(existing)
    if not clients:
        first_uuid = args.uuid.strip() if args.uuid else str(uuid_lib.uuid4())
        clients = [{"id": first_uuid, "email": "admin"}]
    cert_crt, cert_key = ensure_cert()

    inbounds = [
        make_inbound("vmess-ws-tls-8443", 8443, "0.0.0.0", "vmess", True, "/b7YMkKX8/", clients, cert_crt, cert_key),
        make_inbound("vless-ws-tls-2096", 2096, "0.0.0.0", "vless", True, "/vless", clients, cert_crt, cert_key),
        make_inbound("vmess-ws-plain-8880", 8880, "0.0.0.0", "vmess", False, "/b7YMkKX8/", clients, cert_crt, cert_key),
        make_inbound("vless-ws-plain-8882", 8882, "127.0.0.1", "vless", False, "/vless", clients, cert_crt, cert_key),
    ]
    save_validate_restart(base_config(inbounds))
    print(f"Modo Multi-Puerto Pro activo. Usuarios preservados: {len(clients)}")


def cmd_init_single(args):
    port = int(args.port)
    owner = port_owner_other_than_v2ray(port)
    if owner:
        print(f"ERROR: El puerto {port} ya esta ocupado por otro servicio:\n  {owner}")
        sys.exit(1)
    existing = load_config()
    clients = extract_existing_clients(existing)
    if not clients:
        first_uuid = args.uuid.strip() if args.uuid else str(uuid_lib.uuid4())
        clients = [{"id": first_uuid, "email": "admin"}]
    cert_crt, cert_key = ensure_cert()
    use_tls = str(args.tls).lower() in ("1", "true", "si", "s", "yes", "y")
    path = args.path if args.path.startswith("/") else "/" + args.path
    tag = f"{args.protocol}-ws-{'tls' if use_tls else 'plain'}-{port}"
    inbounds = [make_inbound(tag, port, "0.0.0.0", args.protocol, use_tls, path, clients, cert_crt, cert_key)]
    save_validate_restart(base_config(inbounds))
    print(f"Modo Puerto Unico activo en puerto {port} ({args.protocol.upper()} | TLS={use_tls} | path={path})")


def cmd_list_ports(_args):
    cfg = load_config()
    if not cfg or not cfg.get("inbounds"):
        print("No hay inbounds configurados.")
        return
    print(f"{'IDX':<4} {'PUERTO':<7} {'PROTO':<7} {'TLS':<5} {'LISTEN':<11} {'PATH':<16} {'ESTADO'}")
    print("-" * 68)
    for idx, ib in enumerate(cfg["inbounds"], 1):
        port = ib.get("port")
        proto = ib.get("protocol", "?").upper()
        ss = ib.get("streamSettings", {})
        tls = "SI" if ss.get("security") == "tls" else "NO"
        listen = ib.get("listen", "0.0.0.0")
        path = ss.get("wsSettings", {}).get("path", "/")
        listening = "LISTEN" if run_cmd(f"ss -tlpn 2>/dev/null | grep -E ':{port}\\b'").stdout.strip() else "INACTIVO"
        print(f"{idx:<4} {port:<7} {proto:<7} {tls:<5} {listen:<11} {path:<16} {listening}")
    print("\nPuertos reservados por otros servicios (protegidos contra colision):")
    for p, desc in sorted(RESERVED_SERVICES.items()):
        print(f"  - {p}: {desc}")


def cmd_add_port(args):
    port = int(args.port)
    if port in RESERVED_SERVICES:
        print(f"ERROR: Puerto {port} reservado para {RESERVED_SERVICES[port]}. Elige otro puerto libre (ej: 8443, 2096, 8880, 2087, 2095).")
        sys.exit(1)
    owner = port_owner_other_than_v2ray(port)
    if owner:
        print(f"ERROR: Puerto {port} ocupado por:\n  {owner}")
        sys.exit(1)
    cfg = load_config()
    if not cfg:
        print("ERROR: V2Ray no esta inicializado. Ejecuta primero la instalacion.")
        sys.exit(1)
    for ib in cfg.get("inbounds", []):
        if int(ib.get("port", 0)) == port:
            print(f"ERROR: El puerto {port} ya existe en V2Ray.")
            sys.exit(1)
    clients = extract_existing_clients(cfg) or [{"id": str(uuid_lib.uuid4()), "email": "admin"}]
    cert_crt, cert_key = ensure_cert()
    use_tls = str(args.tls).lower() in ("1", "true", "si", "s", "yes", "y")
    path = args.path if args.path.startswith("/") else "/" + args.path
    listen = "127.0.0.1" if args.local_only else "0.0.0.0"
    tag = f"{args.protocol}-ws-{'tls' if use_tls else 'plain'}-{port}"
    cfg["inbounds"].append(make_inbound(tag, port, listen, args.protocol, use_tls, path, clients, cert_crt, cert_key))
    save_validate_restart(cfg)
    print(f"Puerto {port} agregado correctamente ({args.protocol.upper()} | TLS={use_tls} | path={path}).")


def cmd_del_port(args):
    port = int(args.port)
    cfg = load_config()
    if not cfg:
        sys.exit(1)
    before = len(cfg.get("inbounds", []))
    cfg["inbounds"] = [ib for ib in cfg.get("inbounds", []) if int(ib.get("port", 0)) != port]
    if len(cfg["inbounds"]) == before:
        print(f"ERROR: Puerto {port} no encontrado en V2Ray.")
        sys.exit(1)
    if not cfg["inbounds"]:
        print("ERROR: No puedes eliminar el ultimo puerto activo.")
        sys.exit(1)
    save_validate_restart(cfg)
    print(f"Puerto {port} eliminado.")


def cmd_list_users(_args):
    cfg = load_config()
    clients = extract_existing_clients(cfg)
    if not clients:
        print("No hay usuarios UUID configurados.")
        return
    print(f"{'IDX':<4} {'NOMBRE':<18} {'UUID'}")
    print("-" * 62)
    for idx, c in enumerate(clients, 1):
        print(f"{idx:<4} {(c['email'] or 'sin-nombre'):<18} {c['id']}")


def cmd_add_user(args):
    cfg = load_config()
    if not cfg or not cfg.get("inbounds"):
        print("ERROR: V2Ray no esta inicializado.")
        sys.exit(1)
    new_uuid = args.uuid.strip() if args.uuid else str(uuid_lib.uuid4())
    email = args.name.strip() if args.name else f"user-{new_uuid[:6]}"
    for ib in cfg["inbounds"]:
        clients = ib.setdefault("settings", {}).setdefault("clients", [])
        if any(c.get("id") == new_uuid for c in clients):
            continue
        entry = {"id": new_uuid, "email": email}
        if ib.get("protocol") == "vmess":
            entry["alterId"] = 0
        clients.append(entry)
    save_validate_restart(cfg)
    print(f"Usuario creado en todos los puertos -> Nombre: {email} | UUID: {new_uuid}")


def cmd_del_user(args):
    cfg = load_config()
    if not cfg:
        sys.exit(1)
    target = args.uuid.strip()
    removed = 0
    for ib in cfg.get("inbounds", []):
        clients = ib.get("settings", {}).get("clients", [])
        new_clients = [c for c in clients if c.get("id") != target and c.get("email") != target]
        removed += len(clients) - len(new_clients)
        if not new_clients:
            print("ERROR: No puedes eliminar el ultimo usuario activo.")
            sys.exit(1)
        ib["settings"]["clients"] = new_clients
    if removed == 0:
        print(f"ERROR: Usuario '{target}' no encontrado.")
        sys.exit(1)
    save_validate_restart(cfg)
    print(f"Usuario '{target}' eliminado de todos los inbounds.")


def cmd_gen_client(args):
    cfg = load_config()
    clients = extract_existing_clients(cfg)
    if not clients:
        print("ERROR: No hay usuarios UUID configurados.")
        sys.exit(1)

    uid = args.uuid.strip() if args.uuid else clients[0]["id"]
    if uid.isdigit() and 1 <= int(uid) <= len(clients):
        uid = clients[int(uid) - 1]["id"]

    proto = args.protocol.lower()
    port = int(args.port)
    address = args.address.strip()
    host = args.host.strip() or address
    sni = args.sni.strip() or host
    path = args.path.strip() or ("/vless" if proto == "vless" else "/b7YMkKX8/")
    use_tls = str(args.tls).lower() in ("1", "true", "si", "s", "yes", "y")
    use_mux = str(args.mux).lower() in ("1", "true", "si", "s", "yes", "y")
    remark = args.remark.strip() or f"CRISDEV-{proto.upper()}-{port}"

    # 1. Enlace directo
    if proto == "vless":
        sec = "tls" if use_tls else "none"
        qs = f"encryption=none&security={sec}&type=ws&host={host}&path={path.replace('/', '%2F')}"
        if use_tls:
            qs += f"&sni={sni}&fp=chrome&alpn=http%2F1.1"
        link = f"vless://{uid}@{address}:{port}?{qs}#{remark}"
    else:
        vm_obj = {
            "v": "2", "ps": remark, "add": address, "port": str(port),
            "id": uid, "aid": "0", "scy": "auto", "net": "ws", "type": "none",
            "host": host, "path": path, "tls": "tls" if use_tls else "",
            "sni": sni if use_tls else "", "alpn": "http/1.1" if use_tls else "",
        }
        link = "vmess://" + base64.b64encode(json.dumps(vm_obj, separators=(",", ":")).encode()).decode()

    # 2. JSON Cliente Pro (compatible con HTTP Conexion, HTTP Custom y v2rayNG)
    user_obj = {"id": uid, "encryption": "none"} if proto == "vless" else {"id": uid, "alterId": 0, "security": "auto"}
    stream = {
        "network": "ws",
        "security": "tls" if use_tls else "none",
        "wsSettings": {"path": path, "headers": {"Host": host}},
        "sockopt": {"tcpKeepAliveInterval": 30, "tcpNoDelay": True},
    }
    if use_tls:
        stream["tlsSettings"] = {
            "serverName": sni,
            "fingerprint": "chrome",
            "allowInsecure": False,
            "alpn": ["http/1.1"],
        }

    client_json = {
        "log": {"loglevel": "warning"},
        "dns": {"queryStrategy": "UseIPv4", "servers": ["1.1.1.1", "1.0.0.1"]},
        "inbounds": [
            {
                "tag": "socks", "port": 10808, "listen": "127.0.0.1", "protocol": "socks",
                "sniffing": {"enabled": True, "destOverride": ["http", "tls"]},
                "settings": {"auth": "noauth", "udp": True},
            }
        ],
        "outbounds": [
            {
                "tag": "proxy",
                "protocol": proto,
                "settings": {"vnext": [{"address": address, "port": port, "users": [user_obj]}]},
                "streamSettings": stream,
                "mux": {"enabled": use_mux, "concurrency": 8} if use_mux else {"enabled": False},
            },
            {"tag": "direct", "protocol": "freedom"},
            {"tag": "block", "protocol": "blackhole"},
        ],
        "routing": {
            "domainStrategy": "IPIfNonMatch",
            "rules": [
                {"type": "field", "network": "udp", "port": "443", "outboundTag": "block"}
            ],
        },
    }

    print("\n================ ENLACE DIRECTO ================")
    print(link)
    print("\n================ JSON CLIENTE PRO ================")
    json_str = json.dumps(client_json, indent=2)
    print(json_str)

    if args.save:
        os.makedirs(EXPORT_DIR, exist_ok=True)
        out_file = os.path.join(EXPORT_DIR, f"{remark.replace(' ', '_')}.json")
        with open(out_file, "w", encoding="utf-8") as f:
            f.write(json_str + "\n")
        print(f"\nGuardado en: {out_file}")


def main():
    p = argparse.ArgumentParser(description="CRISDEV V2Ray/Xray Core Manager")
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("status").set_defaults(func=cmd_status)
    sub.add_parser("optimize").set_defaults(func=cmd_optimize)

    p_m = sub.add_parser("init-multi")
    p_m.add_argument("--uuid", default="")
    p_m.set_defaults(func=cmd_init_multi)

    p_s = sub.add_parser("init-single")
    p_s.add_argument("--port", required=True)
    p_s.add_argument("--protocol", choices=["vless", "vmess"], default="vless")
    p_s.add_argument("--tls", default="1")
    p_s.add_argument("--path", default="/vless")
    p_s.add_argument("--uuid", default="")
    p_s.set_defaults(func=cmd_init_single)

    sub.add_parser("list-ports").set_defaults(func=cmd_list_ports)

    p_ap = sub.add_parser("add-port")
    p_ap.add_argument("--port", required=True)
    p_ap.add_argument("--protocol", choices=["vless", "vmess"], default="vless")
    p_ap.add_argument("--tls", default="1")
    p_ap.add_argument("--path", default="/vless")
    p_ap.add_argument("--local-only", action="store_true")
    p_ap.set_defaults(func=cmd_add_port)

    p_dp = sub.add_parser("del-port")
    p_dp.add_argument("--port", required=True)
    p_dp.set_defaults(func=cmd_del_port)

    sub.add_parser("list-users").set_defaults(func=cmd_list_users)

    p_au = sub.add_parser("add-user")
    p_au.add_argument("--name", default="")
    p_au.add_argument("--uuid", default="")
    p_au.set_defaults(func=cmd_add_user)

    p_du = sub.add_parser("del-user")
    p_du.add_argument("--uuid", required=True)
    p_du.set_defaults(func=cmd_del_user)

    p_gc = sub.add_parser("gen-client")
    p_gc.add_argument("--uuid", default="")
    p_gc.add_argument("--protocol", choices=["vless", "vmess"], default="vless")
    p_gc.add_argument("--port", required=True)
    p_gc.add_argument("--address", required=True)
    p_gc.add_argument("--host", default="")
    p_gc.add_argument("--sni", default="")
    p_gc.add_argument("--path", default="")
    p_gc.add_argument("--tls", default="0")
    p_gc.add_argument("--mux", default="1")
    p_gc.add_argument("--remark", default="")
    p_gc.add_argument("--save", action="store_true")
    p_gc.set_defaults(func=cmd_gen_client)

    args = p.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
