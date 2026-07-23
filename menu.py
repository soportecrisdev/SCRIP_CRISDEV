"""
CRISDEV VPN Manager - Menu Module
==================================
Estructura modular: cada opcion del principal abre un submenu.
"""
import json
import os
import subprocess
import sys
from datetime import datetime, timedelta
from typing import Optional

from ui import (
    clear_screen, header, dashboard, separator, prompt_input,
    confirm_destructive, breadcrumb, pause,
    ok_msg, error_msg, info_msg, warn_msg,
    user_table, user_detail_card, service_status_table,
    bold, ok, error, warn, info, dim,
    check_service_status,
)


# ============================================================================
# CONFIG - Puertos compatibles con Cloudflare Free
# ============================================================================
# Cloudflare free solo permite: 80, 443, 8080, 8443, 2053, 2083, 2087, 2096
# Para VPN, usar estos puertos para que funcione a traves de Cloudflare proxy

USERS_DB = "/etc/crisdev/data/users.json"
AUDIT_LOG = "/etc/crisdev/logs/audit.log"
SERVER_CONFIG = "/etc/crisdev/data/server_config.json"
CERT_DIR = "/etc/crisdev/certs"

# Puertos Cloudflare-compatible
PORT_SSH = 22
PORT_STUNNEL = 443          # SSH-SSL via Stunnel (puerto estandar HTTPS)
PORT_XRAY_WS = 443          # Xray WebSocket (via Cloudflare)
PORT_XRAY_GRPC = 2083       # Xray gRPC (Cloudflare compatible)
PORT_XRAY_VLESS = 2096      # Xray VLESS
PORT_HYSTERIA = 443         # Hysteria2 UDP
PORT_UDP_CUSTOM = "7100-7200"
PORT_BADVPN = 7300
PORT_SLOWDNS = 5300
PORT_SOCKS = 7777           # Python SOCKS proxy
PORT_WS_EPRO = 80           # WebSocket Python (Cloudflare HTTP)


# ============================================================================
# HELPERS
# ============================================================================

def _load_users() -> list:
    try:
        with open(USERS_DB) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return []

def _save_users(users: list):
    os.makedirs(os.path.dirname(USERS_DB), exist_ok=True)
    with open(USERS_DB, "w") as f:
        json.dump(users, f, indent=2)

def _find_user(username: str) -> Optional[dict]:
    for u in _load_users():
        if u.get("username") == username:
            return u
    return None

def _audit(action: str, detail: str):
    os.makedirs(os.path.dirname(AUDIT_LOG), exist_ok=True)
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    with open(AUDIT_LOG, "a") as f:
        f.write(f"[{ts}] {action}: {detail}\n")

def _generate_password(length: int = 16) -> str:
    import secrets, string
    return ''.join(secrets.choice(string.ascii_letters + string.digits) for _ in range(length))

def _cmd(command: str) -> str:
    try:
        r = subprocess.run(command, shell=True, capture_output=True, text=True, timeout=10)
        return r.stdout.strip()
    except Exception:
        return ""

def _server_ip() -> str:
    try:
        with open(SERVER_CONFIG) as f:
            return json.load(f).get("server_ip", "?.?.?.?")
    except Exception:
        return "?.?.?.?"

def _server_domain() -> str:
    try:
        with open(SERVER_CONFIG) as f:
            return json.load(f).get("domain", "")
    except Exception:
        return ""


# ============================================================================
# HELPERS - Puertos y Certificados
# ============================================================================

def _get_real_port(svc_name: str) -> str:
    """Detecta el puerto real de un servicio usando ss."""
    # Buscar en TCP
    port = _cmd(
        f"ss -tlnp 2>/dev/null | grep -i '{svc_name}' | awk '{{print $4}}' | "
        f"grep -oP '\\d+$' | head -1"
    )
    if port:
        return port
    # Buscar en UDP
    port = _cmd(
        f"ss -ulnp 2>/dev/null | grep -i '{svc_name}' | awk '{{print $4}}' | "
        f"grep -oP '\\d+$' | head -1"
    )
    return port or ""


def _get_all_listening_ports() -> dict:
    """Obtiene todos los puertos TCP/UDP activos del servidor."""
    ports = {}
    # TCP
    output = _cmd("ss -tlnp 2>/dev/null | tail -n +2")
    for line in output.splitlines():
        parts = line.split()
        if len(parts) >= 4:
            addr = parts[3]
            port = addr.rsplit(":", 1)[-1] if ":" in addr else ""
            proc = ""
            if "users:" in line:
                proc = line.split("users:")[1].split('"')[1] if '"' in line.split("users:")[1] else ""
            if port and port.isdigit():
                ports[port] = {"proto": "tcp", "proc": proc}
    # UDP
    output = _cmd("ss -ulnp 2>/dev/null | tail -n +2")
    for line in output.splitlines():
        parts = line.split()
        if len(parts) >= 4:
            addr = parts[3]
            port = addr.rsplit(":", 1)[-1] if ":" in addr else ""
            proc = ""
            if "users:" in line:
                proc = line.split("users:")[1].split('"')[1] if '"' in line.split("users:")[1] else ""
            if port and port.isdigit():
                ports[port] = {"proto": "udp", "proc": proc}
    return ports


def _is_port_open(port: str) -> bool:
    """Verifica si un puerto esta escuchando."""
    result = _cmd(f"ss -tlnp 2>/dev/null | grep ':{port} '")
    if not result:
        result = _cmd(f"ss -ulnp 2>/dev/null | grep ':{port} '")
    return bool(result)


def _generate_self_signed_cert(domain: str = "crisdev-vpn"):
    """Genera certificado SSL autofirmado de alta calidad (4096 bits, 10 anios)."""
    os.makedirs(CERT_DIR, exist_ok=True)
    key_path = f"{CERT_DIR}/server.key"
    cert_path = f"{CERT_DIR}/server.crt"
    info_msg("Generando certificado SSL de alta calidad...")

    # Generar key RSA 4096 bits
    _cmd(f"openssl genrsa -out {key_path} 4096 2>/dev/null")

    # Generar certificado con mejor calidad
    _cmd(
        f"openssl req -new -x509 -days 3650 -key {key_path} -out {cert_path} "
        f"-subj '/C=US/ST=VPN/L=CRISDEV/O=CRISDEV/CN={domain}' "
        f"-addext 'subjectAltName=DNS:{domain},DNS:*.{domain},IP:{_server_ip()}' "
        f"2>/dev/null"
    )

    # Verificar que se genero correctamente
    if os.path.exists(cert_path) and os.path.exists(key_path):
        size = _cmd(f"openssl x509 -in {cert_path} -noout -text 2>/dev/null | grep 'Public-Key:'")
        ok_msg(f"Certificado generado correctamente")
        print(f"  {dim(f'Ubicacion: {CERT_DIR}/')}")
        print(f"  {dim(f'Tamano: {size.strip()}')}")
        print(f"  {dim('Validez: 10 anios')}")
        _audit("CERT_GENERATE", f"Self-signed para {domain}")
        return True
    else:
        error_msg("Error al generar certificado")
        return False


def _generate_cloudflare_origin_cert(domain: str):
    """Genera certificado Cloudflare Origin (si el usuario tiene acceso a CF dashboard)."""
    os.makedirs(CERT_DIR, exist_ok=True)
    info_msg("Certificado Cloudflare Origin")
    print()
    print(f"  {dim('Para usar Cloudflare Origin Certificate:')}")
    print(f"  1) Ve a Cloudflare Dashboard > SSL/TLS > Origin Server")
    print(f"  2) Crea un certificado para: {domain}")
    print(f"  3) Copia el certificado y la clave a estos archivos:")
    print(f"     {CERT_DIR}/cf-origin.pem")
    print(f"     {CERT_DIR}/cf-origin.key")
    print()
    cf_cert = prompt_input("Pega el certificado (o Enter para saltar)")
    if cf_cert:
        with open(f"{CERT_DIR}/cf-origin.pem", "w") as f:
            f.write(cf_cert)
        cf_key = prompt_input("Pega la clave privada")
        if cf_key:
            with open(f"{CERT_DIR}/cf-origin.key", "w") as f:
                f.write(cf_key)
            ok_msg("Certificado Cloudflare Origin guardado")
            return True
    return False


def _setup_stunnel_ssl():
    """Configura Stunnel para SSH-SSL con el certificado generado."""
    cert_file = f"{CERT_DIR}/server.crt"
    key_file = f"{CERT_DIR}/server.key"

    if not os.path.exists(cert_file):
        info_msg("No hay certificado SSL. Generando uno nuevo...")
        _generate_self_signed_cert()

    # Configurar stunnel
    stunnel_conf = f"""pid = /var/run/stunnel4/stunnel.pid
foreground = no
debug = 4
logfile = /var/log/stunnel4.log

[ssh]
accept = 443
connect = 127.0.0.1:{PORT_SSH}
cert = {cert_file}
key = {key_file}
"""
    os.makedirs("/etc/stunnel", exist_ok=True)
    with open("/etc/stunnel/stunnel.conf", "w") as f:
        f.write(stunnel_conf)

    _cmd("systemctl enable stunnel4 2>/dev/null")
    _cmd("systemctl restart stunnel4 2>/dev/null")
    ok_msg("Stunnel SSL configurado en puerto 443")
    _audit("STUNNEL_CONFIG", "Puerto 443 SSL")


def _get_service_info():
    """Retorna informacion de todos los servicios con puertos reales."""
    services = []

    # Definicion de servicios: (svc_id, display_name, default_port, cloudflare_ok)
    defs = [
        ("sshd", "SSH", "22", False),
        ("dropbear", "Dropbear", "110", False),
        ("stunnel4", "Stunnel SSL", "443", True),
        ("slowdns", "SlowDNS", "5300", False),
        ("udp-custom", "UDP-Custom", "7100", False),
        ("hysteria-server", "Hysteria2", "443", True),
        ("xray", "Xray/V2Ray", "443", True),
        ("badvpn-udpgw", "BadVPN-UDPGW", "7300", False),
        ("squid", "Squid", "3128", False),
        ("openvpn", "OpenVPN", "1194", False),
        ("wireguard", "WireGuard", "51820", False),
        ("filebrowser", "FileBrowser", "8080", True),
    ]

    for svc_id, name, default_port, cf_ok in defs:
        st = check_service_status(svc_id)
        is_active = st == "active"
        real_port = ""
        if is_active:
            real_port = _get_real_port(svc_id)
        port = real_port or default_port
        services.append({
            "id": svc_id,
            "name": name,
            "port": port,
            "active": is_active,
            "cloudflare": cf_ok,
        })

    # Python SOCKS
    py_port = _get_real_port("python3")
    services.append({
        "id": "python3",
        "name": "SOCKS Python",
        "port": py_port or "7777",
        "active": bool(py_port),
        "cloudflare": False,
    })

    # WS-EPRO (Python en puerto 80)
    ws_active = _is_port_open("80")
    services.append({
        "id": "ws-epro",
        "name": "WS-EPRO",
        "port": "80",
        "active": ws_active,
        "cloudflare": True,
    })

    return services


# ============================================================================
# MENU PRINCIPAL
# ============================================================================

def menu_main():
    while True:
        clear_screen()
        header()
        dashboard(USERS_DB)

        print()
        print(f"    {bold('1)')} Usuarios")
        print(f"    {bold('2)')} Xray / V2Ray")
        print(f"    {bold('3)')} Puertos")
        print(f"    {bold('4)')} Herramientas")
        print(f"    {bold('5)')} Bot y API")
        print(f"    {bold('6)')} Configuracion")
        print()
        separator()
        print(f"    {error('[0] Salir')}")

        choice = prompt_input("Opcion")

        if choice == "1":
            mod_usuarios()
        elif choice == "2":
            mod_xray()
        elif choice == "3":
            mod_puertos()
        elif choice == "4":
            mod_herramientas()
        elif choice == "5":
            mod_bot_api()
        elif choice == "6":
            mod_config()
        elif choice == "0":
            clear_screen()
            print(f"\n  {ok('Hasta luego, CRISDEV.')}\n")
            sys.exit(0)
        else:
            error_msg("Opcion invalida")


# ============================================================================
# MODULO 1: USUARIOS
# ============================================================================

def mod_usuarios():
    while True:
        clear_screen()
        header()
        breadcrumb("> USUARIOS")
        print()
        print(f"    {bold('1)')} Crear usuario")
        print(f"    {bold('2)')} Editar usuario")
        print(f"    {bold('3)')} {error('Eliminar usuario')}")
        print(f"    {bold('4)')} Suspender usuario")
        print(f"    {bold('5)')} Reactivar usuario")
        print(f"    {bold('6)')} Renovar usuario")
        print(f"    {bold('7)')} Listar usuarios")
        print(f"    {bold('8)')} Ver detalle")
        print()
        separator()
        print(f"    {dim('[0] Volver')}")

        opt = prompt_input("Opcion")
        if opt == "1":
            _usr_create()
        elif opt == "2":
            _usr_edit()
        elif opt == "3":
            _usr_delete()
        elif opt == "4":
            _usr_suspend()
        elif opt == "5":
            _usr_reactivate()
        elif opt == "6":
            _usr_renew()
        elif opt == "7":
            _usr_list()
        elif opt == "8":
            _usr_detail()
        elif opt == "0":
            return
        else:
            error_msg("Opcion invalida")
        pause()


def _usr_create():
    separator()
    username = prompt_input("Nombre de usuario")
    if not username:
        return error_msg("Nombre vacio")
    if any(u["username"] == username for u in _load_users()):
        return error_msg(f"Usuario {username} ya existe")

    password = prompt_input("Contrasena (vacio = auto-generar)")
    if not password:
        password = _generate_password()

    print()
    print(f"  Protocolos:")
    print(f"    1) SSH         4) SlowDNS    7) Xray Trojan")
    print(f"    2) SSH-SSL     5) Xray VLESS 8) Hysteria2")
    print(f"    3) WebSocket   6) Xray VMess 9) udp-custom")
    proto_input = prompt_input("Selecciona (coma separados)")
    protocols = [p.strip() for p in proto_input.split(",") if p.strip()]

    days_str = prompt_input("Dias de vigencia [30]")
    days = int(days_str) if days_str.isdigit() else 30

    max_conn_str = prompt_input("Max conexiones [2]")
    max_conn = int(max_conn_str) if max_conn_str.isdigit() else 2

    exp_date = (datetime.now() + timedelta(days=days)).strftime("%Y-%m-%d %H:%M:%S")

    new_user = {
        "username": username,
        "password": password,
        "status": "active",
        "created_at": datetime.now().isoformat(),
        "expires_at": exp_date,
        "max_connections": max_conn,
        "current_connections": 0,
        "bandwidth_limit": 0,
        "protocols": protocols,
        "data_used_bytes": 0,
        "last_login": None,
        "last_ip": None,
    }
    users = _load_users()
    users.append(new_user)
    _save_users(users)
    _audit("USER_CREATE", f"{username}")

    print()
    print(f"  {bold(ok('USUARIO CREADO'))}")
    print(f"  Usuario:    {bold(username)}")
    print(f"  Contrasena: {bold(password)}")
    print(f"  Expira:     {bold(exp_date)}")
    print(f"  Protocolos: {bold(', '.join(protocols))}")


def _usr_edit():
    separator()
    username = prompt_input("Usuario a editar")
    user = _find_user(username)
    if not user:
        return error_msg("Usuario no encontrado")

    user_detail_card(user)
    print()
    print(f"  Que deseas cambiar?")
    print(f"    1) Contrasena       4) Limite BW")
    print(f"    2) Expiracion       5) Protocolos")
    print(f"    3) Max conexiones   0) Volver")
    opt = prompt_input("Opcion")

    users = _load_users()
    for u in users:
        if u["username"] == username:
            if opt == "1":
                np = prompt_input("Nueva contrasena")
                if np:
                    u["password"] = np
            elif opt == "2":
                nd = prompt_input("Dias a agregar")
                if nd.isdigit():
                    base = datetime.fromisoformat(u["expires_at"]) if u.get("expires_at") else datetime.now()
                    if base < datetime.now():
                        base = datetime.now()
                    u["expires_at"] = (base + timedelta(days=int(nd))).strftime("%Y-%m-%d %H:%M:%S")
            elif opt == "3":
                nm = prompt_input("Nuevo max")
                if nm.isdigit():
                    u["max_connections"] = int(nm)
            elif opt == "4":
                nb = prompt_input("Nuevo BW (0=sin limite)")
                if nb.isdigit():
                    u["bandwidth_limit"] = int(nb)
            elif opt == "5":
                np2 = prompt_input("Nuevos protos (coma)")
                u["protocols"] = [p.strip() for p in np2.split(",")]
            else:
                return
            break
    _save_users(users)
    _audit("USER_EDIT", username)
    ok_msg(f"Usuario {username} actualizado")


def _usr_delete():
    separator()
    username = prompt_input("Usuario a eliminar")
    if not _find_user(username):
        return error_msg("Usuario no encontrado")
    if confirm_destructive(f"ELIMINAR a {username} permanentemente? Esta accion NO se puede deshacer."):
        users = _load_users()
        users = [u for u in users if u["username"] != username]
        _save_users(users)
        _audit("USER_DELETE", username)
        ok_msg(f"Usuario {username} eliminado")


def _usr_suspend():
    separator()
    username = prompt_input("Usuario a suspender")
    if not _find_user(username):
        return error_msg("Usuario no encontrado")
    if confirm_destructive(f"Suspender a {username}? Se cerraran sus sesiones."):
        users = _load_users()
        for u in users:
            if u["username"] == username:
                u["status"] = "suspended"
                break
        _save_users(users)
        _audit("USER_SUSPEND", username)
        ok_msg(f"Usuario {username} suspendido")


def _usr_reactivate():
    separator()
    username = prompt_input("Usuario a reactivar")
    if not _find_user(username):
        return error_msg("Usuario no encontrado")
    users = _load_users()
    for u in users:
        if u["username"] == username:
            u["status"] = "active"
            break
    _save_users(users)
    _audit("USER_REACTIVATE", username)
    ok_msg(f"Usuario {username} reactivado")


def _usr_renew():
    separator()
    username = prompt_input("Usuario a renovar")
    user = _find_user(username)
    if not user:
        return error_msg("Usuario no encontrado")

    ad = prompt_input("Dias a agregar [30]")
    add_days = int(ad) if ad.isdigit() else 30

    users = _load_users()
    for u in users:
        if u["username"] == username:
            if u.get("expires_at"):
                try:
                    exp_dt = datetime.fromisoformat(u["expires_at"])
                    base = exp_dt if exp_dt > datetime.now() else datetime.now()
                except Exception:
                    base = datetime.now()
            else:
                base = datetime.now()
            u["expires_at"] = (base + timedelta(days=add_days)).strftime("%Y-%m-%d %H:%M:%S")
            u["status"] = "active"
            break
    _save_users(users)
    _audit("USER_RENEW", f"{username}")
    ok_msg(f"Usuario {username} renovado hasta {u['expires_at']}")


def _usr_list():
    separator()
    print(f"  1) Todos    3) Vencidos    5) Por vencer (3d)")
    print(f"  2) Activos  4) Suspendidos 6) Por protocolo")
    f = prompt_input("Filtro")

    users = _load_users()
    now = datetime.now()

    if f == "2":
        users = [u for u in users if u.get("status") == "active"]
    elif f == "3":
        users = [u for u in users if u.get("expires_at") and datetime.fromisoformat(u["expires_at"]) < now]
    elif f == "4":
        users = [u for u in users if u.get("status") == "suspended"]
    elif f == "5":
        users = [u for u in users if u.get("status") == "active" and u.get("expires_at")
                 and 0 < (datetime.fromisoformat(u["expires_at"]) - now).days <= 3]
    elif f == "6":
        pf = prompt_input("Protocolo")
        users = [u for u in users if pf.lower() in [p.lower() for p in u.get("protocols", [])]]
    user_table(users)


def _usr_detail():
    separator()
    username = prompt_input("Usuario")
    user = _find_user(username)
    if not user:
        return error_msg("Usuario no encontrado")
    user_detail_card(user)


# ============================================================================
# MODULO 2: XRAY / V2RAY
# ============================================================================

def mod_xray():
    while True:
        clear_screen()
        header()
        breadcrumb("> XRAY / V2Ray")
        print()
        print(f"    {bold('1)')} Estado Xray-core")
        print(f"    {bold('2)')} Reiniciar Xray")
        print(f"    {bold('3)')} Ver logs Xray")
        print(f"    {bold('4)')} Hysteria2 estado")
        print(f"    {bold('5)')} Reiniciar Hysteria2")
        print(f"    {bold('6)')} udp-custom estado")
        print(f"    {bold('7)')} Reiniciar udp-custom")
        print(f"    {bold('8)')} Generar links de conexion")
        print()
        separator()
        print(f"    {dim('[0] Volver')}")

        opt = prompt_input("Opcion")
        if opt == "1":
            _xray_status()
        elif opt == "2":
            _xray_restart("xray")
        elif opt == "3":
            _xray_logs()
        elif opt == "4":
            _svc_status("hysteria-server", "Hysteria2", PORT_HYSTERIA)
        elif opt == "5":
            _xray_restart("hysteria-server")
        elif opt == "6":
            _svc_status("udp-custom", "udp-custom", 7100)
        elif opt == "7":
            _xray_restart("udp-custom")
        elif opt == "8":
            _generate_links()
        elif opt == "0":
            return
        else:
            error_msg("Opcion invalida")
        pause()


def _xray_status():
    separator()
    st = check_service_status("xray")
    if st == "active":
        print(f"\n  Xray-core: {ok('activo')}")
        v = _cmd("/opt/xray/xray version 2>/dev/null | head -1")
        if v:
            print(f"  Version:   {bold(v)}")
    else:
        print(f"\n  Xray-core: {error(st)}")

    services = [
        ("xray", "Xray", PORT_XRAY_WS),
        ("hysteria-server", "Hysteria2", PORT_HYSTERIA),
        ("udp-custom", "udp-custom", 7100),
    ]
    print()
    for svc_id, svc_name, port in services:
        st = check_service_status(svc_id)
        if st == "active":
            print(f"  {svc_name:<15} {ok('activo')}  puerto {port}")
        else:
            print(f"  {svc_name:<15} {error(st)}")


def _svc_status(svc_id, svc_name, port):
    separator()
    st = check_service_status(svc_id)
    if st == "active":
        print(f"\n  {svc_name}: {ok('activo')} en puerto {port}")
    else:
        print(f"\n  {svc_name}: {error(st)}")


def _xray_restart(svc_id):
    separator()
    _cmd(f"systemctl restart {svc_id}")
    st = check_service_status(svc_id)
    if st == "active":
        ok_msg(f"{svc_id} reiniciado correctamente")
    else:
        error_msg(f"{svc_id} fallo al reiniciar")


def _xray_logs():
    separator()
    output = _cmd("journalctl -u xray --no-pager -n 30 2>/dev/null")
    print(f"\n{output}" if output else dim("  No hay logs"))


def _generate_links():
    separator()
    username = prompt_input("Usuario")
    user = _find_user(username)
    if not user:
        return error_msg("Usuario no encontrado")

    uid = user["username"]
    upass = user["password"]
    sip = _server_ip()
    sdom = _server_domain()
    host = sdom if sdom else sip

    import secrets, base64
    rand_path = secrets.token_hex(8)
    rand_grpc = secrets.token_hex(4)

    print()
    print(f"  {bold('LINKS DE CONEXION')}")
    print(f"  {dim(f'Para: {username}')}")
    separator()

    print(f"\n  {bold('VLESS + WS + TLS:')}")
    print(f"    vless://{uid}@{host}:{PORT_XRAY_WS}?encryption=none&security=tls&type=ws&path=%2F{rand_path}&host={host}#CRISDEV-VLESS-WS")

    print(f"\n  {bold('VLESS + gRPC + TLS:')}")
    print(f"    vless://{uid}@{host}:{PORT_XRAY_GRPC}?encryption=none&security=tls&type=grpc&serviceName=grpc-{rand_grpc}&fp=chrome#CRISDEV-VLESS-gRPC")

    vmess_json = json.dumps({
        "v": "2", "ps": "CRISDEV-VMess", "add": host,
        "port": str(8880), "id": uid, "aid": "0",
        "scy": "auto", "net": "ws", "type": "none",
        "host": host, "path": "/vmess-ws", "tls": "tls"
    })
    vmess_b64 = base64.b64encode(vmess_json.encode()).decode()
    print(f"\n  {bold('VMess + WS + TLS:')}")
    print(f"    vmess://{vmess_b64}")

    print(f"\n  {bold('Trojan + WS + TLS:')}")
    print(f"    trojan://{upass}@{host}:2096?type=ws&host={host}&path=%2Ftrojan-ws&security=tls#CRISDEV-Trojan")

    print(f"\n  {bold('Hysteria2:')}")
    print(f"    hysteria2://{upass}@{host}:{PORT_HYSTERIA}?insecure=1&obfs=salamander&obfs-password={upass}#CRISDEV-Hysteria2")


# ============================================================================
# MODULO 3: PUERTOS
# ============================================================================

def mod_puertos():
    while True:
        clear_screen()
        header()
        _puertos_dashboard()

        print()
        print(f"    {bold('[1]>')}  SSH              {bold('[9]>')}  BadVPN-UDPGW")
        print(f"    {bold('[2]>')}  Dropbear         {bold('[10]>')} Squid")
        print(f"    {bold('[3]>')}  SOCKS Python     {bold('[11]>')} OpenVPN")
        print(f"    {bold('[4]>')}  Stunnel SSL      {bold('[12]>')} WireGuard")
        print(f"    {bold('[5]>')}  SlowDNS          {bold('[13]>')} FileBrowser")
        print(f"    {bold('[6]>')}  WS-EPRO (Py)     {bold('[14]>')} V2Ray / Xray")
        print(f"    {bold('[7]>')}  UDP-Custom       {bold('[15]>')} Certificados SSL")
        print(f"    {bold('[8]>')}  UDP-Hysteria     {bold('[16]>')} Firewall (UFW)")
        print()
        separator()
        print(f"    {dim('[0] Volver')}")

        opt = prompt_input("Opcion")
        if opt == "0":
            return
        elif opt == "1":
            _port_ssh_menu()
        elif opt == "2":
            _port_svc_menu("dropbear", "Dropbear", "110")
        elif opt == "3":
            _port_svc_menu("python3", "SOCKS Python", "7777")
        elif opt == "4":
            _port_stunnel_menu()
        elif opt == "5":
            _port_svc_menu("slowdns", "SlowDNS", "5300")
        elif opt == "6":
            _port_wsepro_menu()
        elif opt == "7":
            _port_svc_menu("udp-custom", "UDP-Custom", "7100")
        elif opt == "8":
            _port_svc_menu("hysteria-server", "UDP-Hysteria", "443")
        elif opt == "9":
            _port_svc_menu("badvpn-udpgw", "BadVPN-UDPGW", "7300")
        elif opt == "10":
            _port_svc_menu("squid", "Squid", "3128")
        elif opt == "11":
            _port_svc_menu("openvpn", "OpenVPN", "1194")
        elif opt == "12":
            _port_svc_menu("wireguard", "WireGuard", "51820")
        elif opt == "13":
            _port_svc_menu("filebrowser", "FileBrowser", "8080")
        elif opt == "14":
            _port_xray_menu()
        elif opt == "15":
            _port_ssl_menu()
        elif opt == "16":
            _port_firewall_menu()
        else:
            error_msg("Opcion invalida")
        pause()


def _puertos_dashboard():
    """Panel principal con todos los servicios y puertos reales."""
    services = _get_service_info()

    print()
    print(f"  {dim(chr(9552) * 58)}")
    print(f"  {bold('ADMINISTRADOR DE PROTOCOLOS'):^58}")
    print(f"  {dim(chr(9552) * 58)}")

    # Organizar en dos columnas
    col1 = []
    col2 = []
    for i, svc in enumerate(services[:12]):
        name = svc["name"].upper()
        port = svc["port"]
        if svc["active"]:
            status = ok("ON")
        else:
            status = error("OFF")
        line = f"  {name:<16} {bold(port):<8} [{status}]"
        if i < 6:
            col1.append(line)
        else:
            col2.append(line)

    for i in range(max(len(col1), len(col2))):
        left = col1[i] if i < len(col1) else " " * 36
        right = col2[i] if i < len(col2) else ""
        print(f"{left}{right}")

    print(f"  {dim(chr(9552) * 58)}")


def _port_ssh_menu():
    """Submenu SSH con opciones completas."""
    st = check_service_status("sshd")
    is_active = st == "active"
    port = _get_real_port("sshd") or "22"
    stunnel_st = check_service_status("stunnel4")
    stunnel_active = stunnel_st == "active"

    separator()
    print()
    print(f"  {bold('SSH / SSH-SSL')}")
    print(f"  SSH:      [{ok('ON') if is_active else error('OFF')}]  Puerto: {bold(port)}")
    print(f"  Stunnel:  [{ok('ON') if stunnel_active else error('OFF')}]  Puerto: {bold('443')}")
    conns = _cmd("ss -tn | grep ':22 ' | wc -l").strip() if is_active else "0"
    print(f"  Conexiones activas: {bold(conns)}")
    print()

    print(f"    {bold('1)')} Ver estado detallado")
    print(f"    {bold('2)')} Reiniciar SSH")
    print(f"    {bold('3)')} Cambiar puerto SSH")
    print(f"    {bold('4)')} Ver config SSH")
    print(f"    {bold('5)')} Ver intentos fallidos (fail2ban)")
    print(f"    {bold('6)')} Desbanear IP")
    print(f"    {bold('7)')} Configurar Stunnel SSL (puerto 443)")
    print(f"    {bold('8)')} Reiniciar Stunnel")

    print()
    opt = prompt_input("Opcion")

    if opt == "1":
        print()
        if is_active:
            print(f"  SSH: {ok('activo')} en puerto {port}")
            print(f"  Conexiones: {bold(conns)}")
            # Mostrar usuarios conectados
            users = _cmd("ss -tn | grep ':22 ' | awk '{print $5}' | cut -d: -f1 | sort | uniq")
            if users:
                print(f"  IPs conectadas:")
                for u in users.splitlines()[:5]:
                    print(f"    {u}")
        else:
            print(f"  SSH: {error(st)}")
    elif opt == "2":
        _cmd("systemctl restart sshd 2>/dev/null || systemctl restart ssh")
        ok_msg("SSH reiniciado")
    elif opt == "3":
        new_port = prompt_input(f"Nuevo puerto SSH (actual: {port})")
        if new_port and new_port.isdigit():
            _cmd(f"ufw allow {new_port}/tcp")
            _cmd(f"sed -i 's/^Port .*/Port {new_port}/' /etc/ssh/sshd_config")
            _cmd("systemctl restart sshd")
            ok_msg(f"SSH cambiado a puerto {new_port}")
            _audit("SSH_PORT", f"Cambiado a {new_port}")
    elif opt == "4":
        output = _cmd("cat /etc/ssh/sshd_config 2>/dev/null | grep -v '^#' | grep -v '^$' | head -30")
        print(f"\n  {dim('/etc/ssh/sshd_config')}")
        print(output)
    elif opt == "5":
        output = _cmd("fail2ban-client status sshd 2>/dev/null")
        print(f"\n{output}" if output else dim("  No hay datos"))
    elif opt == "6":
        ip = prompt_input("IP a desbanear")
        if ip:
            _cmd(f"fail2ban-client set sshd unbanip {ip} 2>/dev/null")
            ok_msg(f"IP {ip} desbaneada")
    elif opt == "7":
        _setup_stunnel_ssl()
    elif opt == "8":
        _cmd("systemctl restart stunnel4")
        ok_msg("Stunnel reiniciado")


def _port_stunnel_menu():
    """Submenu Stunnel SSL."""
    st = check_service_status("stunnel4")
    is_active = st == "active"
    port = _get_real_port("stunnel4") or "443"
    cert_exists = os.path.exists(f"{CERT_DIR}/server.crt")

    separator()
    print()
    print(f"  {bold('STUNNEL SSL')}")
    print(f"  Estado:  [{ok('ON') if is_active else error('OFF')}]")
    print(f"  Puerto:  {bold(port)}")
    print(f"  Cert:    [{ok('SI') if cert_exists else error('NO')}]")
    print()

    print(f"    {bold('1)')} Ver estado")
    print(f"    {bold('2)')} Reiniciar Stunnel")
    print(f"    {bold('3)')} Cambiar puerto (acepta 443, 8443, etc)")
    print(f"    {bold('4)')} Ver configuracion")
    print(f"    {bold('5)')} Generar certificado SSL")
    print(f"    {bold('6)')} Configurar Stunnel automaticamente")

    print()
    opt = prompt_input("Opcion")

    if opt == "1":
        st = check_service_status("stunnel4")
        if st == "active":
            print(f"\n  Stunnel: {ok('activo')} en puerto {port}")
            print(f"  SSL: {'Conectado' if cert_exists else 'Sin certificado'}")
        else:
            print(f"\n  Stunnel: {error(st)}")
    elif opt == "2":
        _cmd("systemctl restart stunnel4")
        ok_msg("Stunnel reiniciado")
    elif opt == "3":
        new_port = prompt_input(f"Nuevo puerto (actual: {port})")
        if new_port and new_port.isdigit():
            _cmd(f"echo y | ufw allow {new_port}/tcp")
            # Actualizar config
            conf = "/etc/stunnel/stunnel.conf"
            if os.path.exists(conf):
                _cmd(f"sed -i 's/^accept = .*/accept = {new_port}/' {conf}")
            _cmd("systemctl restart stunnel4")
            ok_msg(f"Stunnel cambiado a puerto {new_port}")
            _audit("STUNNEL_PORT", f"Cambiado a {new_port}")
    elif opt == "4":
        conf = "/etc/stunnel/stunnel.conf"
        if os.path.exists(conf):
            output = _cmd(f"cat {conf}")
            print(f"\n  {dim(conf)}")
            print(output)
        else:
            warn_msg("No hay config. Usa opcion 6 para configurar.")
    elif opt == "5":
        domain = prompt_input("Dominio (vacio = IP directa)") or _server_ip()
        _generate_self_signed_cert(domain)
    elif opt == "6":
        _setup_stunnel_ssl()


def _port_wsepro_menu():
    """Submenu WS-EPRO (Python WebSocket en puerto 80)."""
    port_80 = _is_port_open("80")
    is_active = port_80

    separator()
    print()
    print(f"  {bold('WS-EPRO (Python WebSocket)')}")
    print(f"  Estado:  [{ok('ON') if is_active else error('OFF')}]")
    print(f"  Puerto:  {bold('80')}")
    print(f"  Nota:    {dim('Puerto 80 compatible con Cloudflare')}")
    print()

    print(f"    {bold('1)')} Ver estado")
    print(f"    {bold('2)')} Iniciar WS-EPRO")
    print(f"    {bold('3)')} Detener WS-EPRO")
    print(f"    {bold('4)')} Configurar WS-EPRO")
    print(f"    {bold('5)')} Ver logs")

    print()
    opt = prompt_input("Opcion")

    if opt == "1":
        if is_active:
            print(f"\n  WS-EPRO: {ok('activo')} en puerto 80")
            conns = _cmd("ss -tn | grep ':80 ' | wc -l").strip()
            print(f"  Conexiones: {bold(conns)}")
        else:
            print(f"\n  WS-EPRO: {error('inactivo')}")
    elif opt == "2":
        # Buscar script de WS-EPRO
        ws_script = _cmd("find / -name 'ws_epro.py' -o -name 'wsepro.py' 2>/dev/null | head -1")
        if ws_script:
            _cmd(f"nohup python3 {ws_script} > /var/log/ws-epro.log 2>&1 &")
            ok_msg("WS-EPRO iniciado en puerto 80")
        else:
            warn_msg("No se encontro ws_epro.py. Instalalo primero.")
    elif opt == "3":
        _cmd("pkill -f 'ws_epro\\|wsepro' 2>/dev/null")
        ok_msg("WS-EPRO detenido")
    elif opt == "4":
        print(f"\n  {dim('Configuracion de WS-EPRO:')}")
        print(f"  Puerto: 80 (fijo, compatible con Cloudflare)")
        print(f"  Path: /ws")
        print()
        info_msg("Edita /etc/crisdev/ws-epro.json para configurar")
    elif opt == "5":
        output = _cmd("tail -30 /var/log/ws-epro.log 2>/dev/null")
        print(f"\n{output}" if output else dim("  No hay logs"))


def _port_xray_menu():
    """Submenu Xray/V2Ray."""
    st = check_service_status("xray")
    is_active = st == "active"
    port = _get_real_port("xray") or "443"

    separator()
    print()
    print(f"  {bold('V2RAY / XRAY')}")
    print(f"  Estado:  [{ok('ON') if is_active else error('OFF')}]")
    print(f"  Puerto:  {bold(port)}")
    print(f"  Config:  {dim('/usr/local/etc/xray/config.json')}")
    print()

    print(f"    {bold('1)')} Ver estado")
    print(f"    {bold('2)')} Reiniciar Xray")
    print(f"    {bold('3)')} Ver version")
    print(f"    {bold('4)')} Ver config")
    print(f"    {bold('5)')} Ver logs")
    print(f"    {bold('6)')} Cambiar puerto")

    print()
    opt = prompt_input("Opcion")

    if opt == "1":
        if is_active:
            print(f"\n  Xray: {ok('activo')} en puerto {port}")
            v = _cmd("/opt/xray/xray version 2>/dev/null | head -1")
            if v:
                print(f"  Version: {bold(v)}")
        else:
            print(f"\n  Xray: {error(st)}")
    elif opt == "2":
        _cmd("systemctl restart xray")
        ok_msg("Xray reiniciado")
    elif opt == "3":
        v = _cmd("/opt/xray/xray version 2>/dev/null | head -1")
        print(f"\n  {bold(v)}" if v else warn_msg("No instalado"))
    elif opt == "4":
        output = _cmd("cat /usr/local/etc/xray/config.json 2>/dev/null | head -40")
        print(f"\n  {dim('/usr/local/etc/xray/config.json')}")
        print(output)
    elif opt == "5":
        output = _cmd("journalctl -u xray --no-pager -n 30 2>/dev/null")
        print(f"\n{output}" if output else dim("  No hay logs"))
    elif opt == "6":
        new_port = prompt_input(f"Nuevo puerto (actual: {port})")
        if new_port and new_port.isdigit():
            _cmd(f"echo y | ufw allow {new_port}/tcp")
            # Actualizar config xray
            conf = "/usr/local/etc/xray/config.json"
            if os.path.exists(conf):
                _cmd(f"sed -i 's/\"port\":{port}/\"port\":{new_port}/' {conf}")
            _cmd("systemctl restart xray")
            ok_msg(f"Xray cambiado a puerto {new_port}")


def _port_ssl_menu():
    """Menu de certificados SSL."""
    separator()
    print()
    print(f"  {bold('CERTIFICADOS SSL')}")
    cert_exists = os.path.exists(f"{CERT_DIR}/server.crt")
    cf_cert = os.path.exists(f"{CERT_DIR}/cf-origin.pem")

    if cert_exists:
        info = _cmd(f"openssl x509 -in {CERT_DIR}/server.crt -noout -subject -dates 2>/dev/null")
        print(f"  Self-signed: {ok('INSTALADO')}")
        if info:
            for line in info.splitlines():
                print(f"    {dim(line)}")
    else:
        print(f"  Self-signed: {error('NO INSTALADO')}")

    if cf_cert:
        print(f"  Cloudflare:  {ok('INSTALADO')}")
    else:
        print(f"  Cloudflare:  {dim('no disponible')}")
    print()

    print(f"    {bold('1)')} Generar certificado self-signed (4096 bits)")
    print(f"    {bold('2)')} Importar certificado Cloudflare Origin")
    print(f"    {bold('3)')} Verificar certificado actual")
    print(f"    {bold('4)')} Configurar HTTPS en Nginx/Apache")

    print()
    opt = prompt_input("Opcion")

    if opt == "1":
        domain = prompt_input("Dominio (vacio = IP directa)") or _server_ip()
        _generate_self_signed_cert(domain)
    elif opt == "2":
        domain = prompt_input("Tu dominio Cloudflare")
        if domain:
            _generate_cloudflare_origin_cert(domain)
    elif opt == "3":
        if cert_exists:
            output = _cmd(f"openssl x509 -in {CERT_DIR}/server.crt -noout -text 2>/dev/null | head -20")
            print(f"\n{output}")
        else:
            warn_msg("No hay certificado instalado")
    elif opt == "4":
        info_msg("Para configurar HTTPS:")
        print(f"  1) Instala Nginx: apt install nginx")
        print(f"  2) Copia los certificados a /etc/nginx/ssl/")
        print(f"  3) Configura el virtual host con SSL")
        print(f"  {dim('Los certificados estan en: ' + CERT_DIR)}")


def _port_firewall_menu():
    """Menu de firewall UFW."""
    separator()
    print()
    print(f"  {bold('FIREWALL (UFW)')}")
    # Mostrar estado
    ufw_status = _cmd("ufw status 2>/dev/null | head -1")
    print(f"  Estado: {bold(ufw_status)}")

    # Mostrar reglas activas
    rules = _cmd("ufw status numbered 2>/dev/null | tail -n +4")
    if rules:
        print(f"\n  {dim('Reglas activas:')}")
        for line in rules.splitlines()[:10]:
            print(f"    {line}")
    print()

    print(f"    {bold('1)')} Ver reglas completas")
    print(f"    {bold('2)')} Abrir puerto")
    print(f"    {bold('3)')} Cerrar puerto")
    print(f"    {bold('4)')} Abrir puertos Cloudflare (80,443,8080,8443)")
    print(f"    {bold('5)')} Abrir puertos VPN (todos)")
    print(f"    {bold('6)')} Activar UFW")
    print(f"    {bold('7)')} Desactivar UFW")
    print(f"    {bold('8)')} Modo panico (solo SSH)")

    print()
    opt = prompt_input("Opcion")

    if opt == "1":
        output = _cmd("ufw status verbose 2>/dev/null")
        print(f"\n{output}")
    elif opt == "2":
        port = prompt_input("Puerto a abrir")
        proto = prompt_input("Protocolo (tcp/udp/both) [tcp]") or "tcp"
        if proto == "both":
            _cmd(f"echo y | ufw allow {port}")
        else:
            _cmd(f"echo y | ufw allow {port}/{proto}")
        ok_msg(f"Puerto {port}/{proto} abierto")
    elif opt == "3":
        port = prompt_input("Puerto a cerrar")
        proto = prompt_input("Protocolo (tcp/udp) [tcp]") or "tcp"
        _cmd(f"echo y | ufw delete allow {port}/{proto}")
        ok_msg(f"Puerto {port}/{proto} cerrado")
    elif opt == "4":
        # Puertos esenciales para Cloudflare
        cf_ports = [80, 443, 8080, 8443, 2053, 2083, 2087, 2096]
        for p in cf_ports:
            _cmd(f"echo y | ufw allow {p}/tcp")
        ok_msg(f"Puertos Cloudflare abiertos: {', '.join(map(str, cf_ports))}")
        _audit("FIREWALL", "Puertos Cloudflare abiertos")
    elif opt == "5":
        # Puertos para VPN
        vpn_ports = [22, 80, 443, 110, 442, 1194, 3128, 5300, 7300, 7777,
                     8080, 8443, 2053, 2083, 2087, 2096, 51820, "7100:7200"]
        for p in vpn_ports:
            _cmd(f"echo y | ufw allow {p}")
        ok_msg("Puertos VPN abiertos")
        _audit("FIREWALL", "Puertos VPN abiertos")
    elif opt == "6":
        _cmd("echo y | ufw enable")
        ok_msg("UFW activado")
    elif opt == "7":
        if confirm_destructive("Desactivar UFW?"):
            _cmd("ufw disable")
            ok_msg("UFW desactivado")
    elif opt == "8":
        if confirm_destructive("MODO PANICO? Solo SSH abierto."):
            _cmd("ufw disable 2>/dev/null")
            _cmd("echo y | ufw reset 2>/dev/null")
            _cmd("ufw default deny incoming 2>/dev/null")
            _cmd("ufw default allow outgoing 2>/dev/null")
            _cmd(f"ufw allow {PORT_SSH}/tcp comment 'SSH-emergency'")
            _cmd("echo y | ufw enable 2>/dev/null")
            _audit("PANIC", "Modo panico activado")
            warn_msg("MODO PANICO ACTIVADO")


def _port_svc_menu(svc_id, svc_name, default_port):
    """Submenu generico para servicios."""
    st = check_service_status(svc_id)
    is_active = st == "active"
    port = _get_real_port(svc_id) or default_port

    separator()
    print()
    print(f"  {bold(svc_name.upper())}")
    print(f"  Estado:  [{ok('ON') if is_active else error('OFF')}]")
    print(f"  Puerto:  {bold(port)}")
    print()

    if is_active:
        print(f"    {bold('1)')} Ver estado")
        print(f"    {bold('2)')} Reiniciar servicio")
        print(f"    {bold('3)')} Detener servicio")
        print(f"    {bold('4)')} Ver logs")
        print(f"    {bold('5)')} Ver configuracion")
        print(f"    {bold('6)')} Cambiar puerto")
    else:
        print(f"    {bold('1)')} Ver estado")
        print(f"    {bold('2)')} Iniciar servicio")
        print(f"    {bold('3)')} Verificar instalacion")

    print()
    opt = prompt_input("Opcion")

    if is_active:
        if opt == "1":
            st = check_service_status(svc_id)
            if st == "active":
                print(f"\n  {svc_name}: {ok('activo')} en puerto {port}")
            else:
                print(f"\n  {svc_name}: {error(st)}")
        elif opt == "2":
            _cmd(f"systemctl restart {svc_id}")
            new_st = check_service_status(svc_id)
            if new_st == "active":
                ok_msg(f"{svc_name} reiniciado correctamente")
            else:
                error_msg(f"{svc_name} fallo al reiniciar")
        elif opt == "3":
            if confirm_destructive(f"Detener {svc_name}?"):
                _cmd(f"systemctl stop {svc_id}")
                ok_msg(f"{svc_name} detenido")
        elif opt == "4":
            output = _cmd(f"journalctl -u {svc_id} --no-pager -n 30 2>/dev/null")
            print(f"\n{output}" if output else dim("  No hay logs"))
        elif opt == "5":
            configs = {
                "dropbear": "/etc/dropbear/dropbear_config",
                "slowdns": "/etc/slowdns/config",
                "udp-custom": "/etc/udp-custom/config.json",
                "hysteria-server": "/etc/hysteria/config.json",
                "badvpn-udpgw": "/etc/default/badvpn-udpgw",
                "squid": "/etc/squid/squid.conf",
                "openvpn": "/etc/openvpn/server.conf",
                "wireguard": "/etc/wireguard/wg0.conf",
                "filebrowser": "/etc/filebrowser/config.json",
            }
            cfg = configs.get(svc_id)
            if cfg and os.path.exists(cfg):
                output = _cmd(f"cat {cfg} 2>/dev/null | head -30")
                print(f"\n  {dim(cfg)}")
                print(output)
            else:
                warn_msg("No se encontro archivo de configuracion")
        elif opt == "6":
            new_port = prompt_input(f"Nuevo puerto (actual: {port})")
            if new_port and new_port.isdigit():
                _cmd(f"echo y | ufw allow {new_port}")
                ok_msg(f"Puerto {new_port} abierto en firewall")
                info_msg("Reinicia el servicio para aplicar el cambio de puerto")
    else:
        if opt == "1":
            st = check_service_status(svc_id)
            print(f"\n  {svc_name}: {error(st)}")
        elif opt == "2":
            _cmd(f"systemctl start {svc_id}")
            new_st = check_service_status(svc_id)
            if new_st == "active":
                ok_msg(f"{svc_name} iniciado")
            else:
                error_msg(f"No se pudo iniciar {svc_name}")
        elif opt == "3":
            # Verificar si esta instalado
            result = _cmd(f"which {svc_id} 2>/dev/null")
            if result:
                print(f"\n  {svc_name}: {ok('instalado')} en {result}")
            else:
                warn_msg(f"{svc_name} no encontrado. Instala con: crisdev.sh --install")


# ============================================================================
# MODULO 4: HERRAMIENTAS
# ============================================================================

def mod_herramientas():
    while True:
        clear_screen()
        header()
        breadcrumb("> HERRAMIENTAS")
        print()
        print(f"    {bold('1)')} Estado del servidor")
        print(f"    {bold('2)')} Verificar versiones")
        print(f"    {bold('3)')} Logs de servicios")
        print(f"    {bold('4)')} Reiniciar servicios")
        print(f"    {bold('5)')} SSH / SSH-SSL")
        print()
        separator()
        print(f"    {dim('[0] Volver')}")

        opt = prompt_input("Opcion")
        if opt == "1":
            _tool_server_status()
        elif opt == "2":
            _tool_versions()
        elif opt == "3":
            _tool_logs()
        elif opt == "4":
            _tool_restart_all()
        elif opt == "5":
            _tool_ssh()
        elif opt == "0":
            return
        else:
            error_msg("Opcion invalida")
        pause()


def _tool_server_status():
    separator()
    print(f"\n  {bold('Sistema:')}")
    print(f"    IP:       {bold(_server_ip())}")
    print(f"    Hostname: {_cmd('hostname')}")
    print(f"    Kernel:   {_cmd('uname -r')}")
    print(f"    Uptime:   {_cmd('uptime -p 2>/dev/null || uptime')}")

    print(f"\n  {bold('Recursos:')}")
    cpu = _cmd("top -bn1 | grep 'Cpu(s)' | awk '{print $2}' 2>/dev/null")
    mem = _cmd("free -h | awk '/Mem:/{print $3\"/\"$2}'")
    print(f"    CPU: {cpu}%")
    print(f"    RAM: {mem}")

    print(f"\n  {bold('Servicios:')}")
    service_status_table()


def _tool_versions():
    separator()
    xray_v = _cmd("/opt/xray/xray version 2>/dev/null | head -1")
    hy_v = _cmd("hysteria-server version 2>/dev/null | head -1")
    udp_v = _cmd("/opt/udp-custom/server --version 2>/dev/null")

    print(f"\n  Xray:       {bold(xray_v)}" if xray_v else "  Xray:       No instalado")
    print(f"  Hysteria2:  {bold(hy_v)}" if hy_v else "  Hysteria2:  No instalado")
    print(f"  udp-custom: {bold(udp_v)}" if udp_v else "  udp-custom: No instalado")


def _tool_logs():
    separator()
    print(f"  1) Xray    3) SSH")
    print(f"  2) Hysteria2  4) fail2ban")
    opt = prompt_input("Servicio")

    services = {"1": "xray", "2": "hysteria-server", "3": "sshd"}
    if opt in services:
        output = _cmd(f"journalctl -u {services[opt]} --no-pager -n 30 2>/dev/null")
        print(f"\n{output}" if output else dim("  No hay logs"))
    elif opt == "4":
        output = _cmd("fail2ban-client status sshd 2>/dev/null")
        print(f"\n{output}" if output else dim("  No hay logs"))


def _tool_restart_all():
    separator()
    services = [
        ("xray", "Xray"), ("hysteria-server", "Hysteria2"),
        ("stunnel4", "Stunnel4"), ("udp-custom", "UDP Custom"),
        ("sshd", "SSH"),
    ]
    for svc_id, svc_name in services:
        st = check_service_status(svc_id)
        if st == "active":
            _cmd(f"systemctl restart {svc_id}")
            new_st = check_service_status(svc_id)
            if new_st == "active":
                ok_msg(f"{svc_name} reiniciado")
            else:
                error_msg(f"{svc_name} fallo")
        else:
            warn_msg(f"{svc_name} no esta activo")
    ok_msg("Reinicio completado")


def _tool_ssh():
    separator()
    print(f"  1) Ver estado SSH")
    print(f"  2) Reiniciar SSH")
    print(f"  3) Ver intentos fallidos (fail2ban)")
    print(f"  4) Desbanear IP")
    opt = prompt_input("Opcion")

    if opt == "1":
        st = check_service_status("sshd")
        if st == "active":
            print(f"\n  SSH: {ok('activo')} en puerto {PORT_SSH}")
        else:
            print(f"\n  SSH: {error(st)}")
    elif opt == "2":
        _cmd("systemctl restart sshd 2>/dev/null || systemctl restart ssh")
        ok_msg("SSH reiniciado")
    elif opt == "3":
        output = _cmd("fail2ban-client status sshd 2>/dev/null")
        print(f"\n{output}" if output else dim("  No hay datos"))
    elif opt == "4":
        ip = prompt_input("IP a desbanear")
        if ip:
            _cmd(f"fail2ban-client set sshd unbanip {ip} 2>/dev/null")
            ok_msg(f"IP {ip} desbaneada")


# ============================================================================
# MODULO 5: BOT Y API
# ============================================================================

def mod_bot_api():
    while True:
        clear_screen()
        header()
        breadcrumb("> BOT Y API")
        print()
        print(f"    {bold('1)')} Configurar bot Telegram")
        print(f"    {bold('2)')} Ver estado bot")
        print(f"    {bold('3)')} Reiniciar bot")
        print(f"    {bold('4)')} Configurar API HTTP")
        print(f"    {bold('5)')} Ver estado API")
        print()
        separator()
        print(f"    {dim('[0] Volver')}")

        opt = prompt_input("Opcion")
        if opt == "1":
            _bot_config()
        elif opt == "2":
            _bot_status()
        elif opt == "3":
            _bot_restart()
        elif opt == "4":
            _api_config()
        elif opt == "5":
            _api_status()
        elif opt == "0":
            return
        else:
            error_msg("Opcion invalida")
        pause()


def _bot_config():
    separator()
    info_msg("Configuracion del bot Telegram")
    token = prompt_input("Token del bot (de @BotFather)")
    if token:
        os.makedirs("/etc/crisdev/bot", exist_ok=True)
        with open("/etc/crisdev/bot/token.txt", "w") as f:
            f.write(token)
        ok_msg("Token guardado. Reinicia el bot para aplicar.")
    else:
        error_msg("Token vacio")


def _bot_status():
    separator()
    st = check_service_status("crisdev-bot")
    if st == "active":
        print(f"\n  Bot Telegram: {ok('activo')}")
    else:
        print(f"\n  Bot Telegram: {error(st)}")
    token_file = "/etc/crisdev/bot/token.txt"
    if os.path.exists(token_file):
        with open(token_file) as f:
            t = f.read().strip()
        if t:
            print(f"  Token: {t[:10]}...{t[-5:]}")
    else:
        print(f"  Token: {dim('no configurado')}")


def _bot_restart():
    separator()
    _cmd("systemctl restart crisdev-bot 2>/dev/null")
    st = check_service_status("crisdev-bot")
    if st == "active":
        ok_msg("Bot reiniciado")
    else:
        warn_msg("Servicio crisdev-bot no encontrado o no activo")


def _api_config():
    separator()
    info_msg("Configuracion de la API HTTP")
    port = prompt_input("Puerto de la API [8080]") or "8080"
    os.makedirs("/etc/crisdev/api", exist_ok=True)
    with open("/etc/crisdev/api/config.json", "w") as f:
        json.dump({"port": int(port)}, f, indent=2)
    ok_msg(f"API configurada en puerto {port}. Reinicia para aplicar.")


def _api_status():
    separator()
    st = check_service_status("crisdev-api")
    if st == "active":
        print(f"\n  API HTTP: {ok('activo')}")
    else:
        print(f"\n  API HTTP: {error(st)}")
    cfg_file = "/etc/crisdev/api/config.json"
    if os.path.exists(cfg_file):
        with open(cfg_file) as f:
            cfg = json.load(f)
        print(f"  Puerto: {cfg.get('port', 'N/A')}")
    else:
        print(f"  Puerto: {dim('no configurado')}")


# ============================================================================
# MODULO 6: CONFIGURACION
# ============================================================================

def mod_config():
    while True:
        clear_screen()
        header()
        breadcrumb("> CONFIGURACION")
        print()
        print(f"    {bold('1)')} Certificados TLS")
        print(f"    {bold('2)')} Backups")
        print(f"    {bold('3)')} Logs de auditoria")
        print(f"    {bold('4)')} Actualizar CRISDEV")
        print(f"    {bold('5)')} {error('Reiniciar VPS')}")
        print()
        separator()
        print(f"    {dim('[0] Volver')}")

        opt = prompt_input("Opcion")
        if opt == "1":
            _cfg_certs()
        elif opt == "2":
            _cfg_backups()
        elif opt == "3":
            _cfg_audit()
        elif opt == "4":
            _cfg_update()
        elif opt == "5":
            _cfg_reboot()
        elif opt == "0":
            return
        else:
            error_msg("Opcion invalida")
        pause()


def _cfg_certs():
    separator()
    cert_path = "/etc/crisdev/certs/fullchain.pem"
    print(f"  1) Ver certificado actual")
    print(f"  2) Generar certificado autofirmado")
    print(f"  3) Renovar certificados (Let's Encrypt)")
    opt = prompt_input("Opcion")

    if opt == "1":
        if os.path.exists(cert_path):
            output = _cmd(f"openssl x509 -in {cert_path} -noout -subject -dates 2>/dev/null")
            print(f"\n{output}" if output else dim("  No se pudo leer"))
        else:
            warn_msg("No hay certificado instalado")
    elif opt == "2":
        os.makedirs("/etc/crisdev/certs", exist_ok=True)
        _cmd("openssl req -x509 -nodes -days 3650 -newkey rsa:2048 "
             "-keyout /etc/crisdev/certs/self-signed-key.pem "
             "-out /etc/crisdev/certs/self-signed.pem "
             "-subj '/CN=crisdev-vpn/O=CRISDEV/C=US' 2>/dev/null")
        ok_msg("Certificado autofirmado generado (10 anios)")
    elif opt == "3":
        info_msg("Renovando certificados...")
        _cmd("~/.acme.sh/acme.sh --renew-all 2>/dev/null")
        ok_msg("Certificados renovados")


def _cfg_backups():
    separator()
    backup_dir = "/etc/crisdev/backups"
    os.makedirs(backup_dir, exist_ok=True)

    print(f"  1) Crear backup")
    print(f"  2) Listar backups")
    print(f"  3) Restaurar backup")
    opt = prompt_input("Opcion")

    if opt == "1":
        ts = datetime.now().strftime("%Y%m%d_%H%M%S")
        bf = f"{backup_dir}/crisdev_{ts}.tar.gz"
        _cmd(f"tar -czf {bf} -C / etc/crisdev/data etc/crisdev/certs 2>/dev/null")
        size = _cmd(f"du -h {bf} | awk '{{print $1}}'")
        ok_msg(f"Backup creado: {bf} ({size})")
        _audit("BACKUP", f"{bf}")
    elif opt == "2":
        output = _cmd(f"ls -la {backup_dir}/*.tar.gz 2>/dev/null")
        print(f"\n{output}" if output else dim("  No hay backups"))
    elif opt == "3":
        output = _cmd(f"ls {backup_dir}/*.tar.gz 2>/dev/null | nl")
        if output:
            print(f"\n{output}")
            num = prompt_input("Numero de backup")
            bf = _cmd(f"ls {backup_dir}/*.tar.gz 2>/dev/null | sed -n '{num}p'")
            if bf and os.path.exists(bf):
                if confirm_destructive(f"Restaurar desde {os.path.basename(bf)}?"):
                    _cmd(f"tar -xzf {bf} -C / 2>/dev/null")
                    _cmd("systemctl daemon-reload && systemctl restart xray hysteria-server stunnel4 2>/dev/null")
                    ok_msg("Backup restaurado")
            else:
                error_msg("Backup no encontrado")
        else:
            warn_msg("No hay backups")


def _cfg_audit():
    separator()
    if os.path.exists(AUDIT_LOG):
        output = _cmd(f"tail -50 {AUDIT_LOG}")
        print(f"\n{output}" if output else dim("  Log vacio"))
    else:
        warn_msg("No hay log de auditoria")


def _cfg_update():
    separator()
    info_msg("Descargando ultima version...")
    repo = "https://raw.githubusercontent.com/soportecrisdev/SCRIP_CRISDEV/main"
    d = "/etc/crisdev"
    files = ["crisdev.py", "menu.py", "ui/theme.py", "ui/components.py", "ui/__init__.py"]
    for f in files:
        url = f"{repo}/{f}"
        _cmd(f"curl -fsSL {url} -o {d}/{f} 2>/dev/null")
        ok_msg(f"  {f}")
    ok_msg("CRISDEV actualizado. Reabre el panel.")


def _cfg_reboot():
    separator()
    if confirm_destructive("Reiniciar el VPS? Se cerraran todas las conexiones."):
        ok_msg("Reiniciando VPS...")
        _audit("REBOOT", "VPS reiniciado desde panel")
        subprocess.run(["reboot"], timeout=5)
