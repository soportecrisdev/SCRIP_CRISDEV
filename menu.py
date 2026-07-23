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
# CONFIG
# ============================================================================

USERS_DB = "/etc/crisdev/data/users.json"
AUDIT_LOG = "/etc/crisdev/logs/audit.log"
SERVER_CONFIG = "/etc/crisdev/data/server_config.json"

PORT_SSH = 22
PORT_XRAY_WS = 2053
PORT_XRAY_GRPC = 2083
PORT_HYSTERIA = 443
PORT_UDP_CUSTOM = "7100-7200"


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
        print(f"    {bold('[1]>')}  Ajustes SSH        {bold('[9]>')}  BadVPN-UDPGW")
        print(f"    {bold('[2]>')}  Dropbear          {bold('[10]>')} Squid")
        print(f"    {bold('[3]>')}  SOCKS Python      {bold('[11]>')} OpenVPN")
        print(f"    {bold('[4]>')}  Stunnel (SSL)     {bold('[12]>')} CheckUser Online")
        print(f"    {bold('[5]>')}  SlowDNS           {bold('[13]>')} ATKEN / HASH")
        print(f"    {bold('[6]>')}  WS-EPRO           {bold('[14]>')} FileBrowser")
        print(f"    {bold('[7]>')}  UDP-Custom        {bold('[15]>')} V2Ray / Xray")
        print(f"    {bold('[8]>')}  UDP-Hysteria      {bold('[16]>')} WireGuard")
        print(f"    {bold('[17]>')} Abrir puerto       {bold('[18]>')} Cerrar puerto")
        print(f"    {bold('[19]>')} Modo panico")
        print()
        separator()
        print(f"    {dim('[0] Volver')}")

        opt = prompt_input("Opcion")
        if opt == "0":
            return
        elif opt == "1":
            _port_ssh_menu()
        elif opt == "2":
            _port_service_menu("dropbear", "Dropbear", "110,8080")
        elif opt == "3":
            _port_service_menu("python3", "SOCKS Python", "7777")
        elif opt == "4":
            _port_service_menu("stunnel4", "Stunnel SSL", "442")
        elif opt == "5":
            _port_service_menu("slowdns", "SlowDNS", "5300")
        elif opt == "6":
            _port_service_menu("ws-epro", "WS-EPRO", "80")
        elif opt == "7":
            _port_service_menu("udp-custom", "UDP-Custom", "36717")
        elif opt == "8":
            _port_service_menu("udp-hysteria", "UDP-Hysteria", "36712")
        elif opt == "9":
            _port_service_menu("badvpn-udpgw", "BadVPN-UDPGW", "7300")
        elif opt == "10":
            _port_service_menu("squid", "Squid", "3128")
        elif opt == "11":
            _port_service_menu("openvpn", "OpenVPN", "1194")
        elif opt == "12":
            _port_service_menu("checkuser", "CheckUser Online", "80")
        elif opt == "13":
            _port_service_menu("atken", "ATKEN/HASH", "N/A")
        elif opt == "14":
            _port_service_menu("filebrowser", "FileBrowser", "8080")
        elif opt == "15":
            _port_service_menu("xray", "V2Ray/Xray", "443")
        elif opt == "16":
            _port_service_menu("wireguard", "WireGuard", "51820")
        elif opt == "17":
            _fw_open()
        elif opt == "18":
            _fw_close()
        elif opt == "19":
            _fw_panic()
        else:
            error_msg("Opcion invalida")
        pause()


def _scan_ports():
    """Escanea servicios reales del sistema y retorna dict {service: port}."""
    detected = {}

    # Mapeo de servicio systemd -> nombre display y puertos default
    services = [
        ("sshd", "SSH", "22"),
        ("dropbear", "Dropbear", "110"),
        ("stunnel4", "Stunnel", "442"),
        ("slowdns", "SlowDNS", "5300"),
        ("udp-custom", "UDP-Custom", "36717"),
        ("udp-hysteria", "UDP-Hysteria", "36712"),
        ("hysteria-server", "UDP-Hysteria", "36712"),
        ("xray", "Xray", "443"),
        ("badvpn-udpgw", "BadVPN", "7300"),
        ("squid", "Squid", "3128"),
        ("openvpn", "OpenVPN", "1194"),
        ("wireguard", "WireGuard", "51820"),
        ("filebrowser", "FileBrowser", "8080"),
        ("ufw", "Firewall", ""),
    ]

    for svc_id, name, default_port in services:
        st = check_service_status(svc_id)
        if st == "active":
            # Intentar detectar puerto real con ss
            real_port = _cmd(
                f"ss -tlnp 2>/dev/null | grep '{svc_id}' | awk '{{print $4}}' | "
                f"grep -oP '\\d+$' | head -1"
            )
            if not real_port:
                # Para servicios UDP o con otro nombre
                real_port = _cmd(
                    f"ss -ulnp 2>/dev/null | grep '{svc_id}' | awk '{{print $4}}' | "
                    f"grep -oP '\\d+$' | head -1"
                )
            detected[name] = {
                "port": real_port or default_port,
                "status": True,
                "svc_id": svc_id,
            }
        else:
            detected[name] = {
                "port": default_port,
                "status": False,
                "svc_id": svc_id,
            }

    # Detectar servicios extras que no son systemd
    # Python SOCKS
    py_sock = _cmd("ss -tlnp 2>/dev/null | grep python | awk '{print $4}' | grep -oP '\\d+$' | head -1")
    if py_sock:
        detected["SOCKS Python"] = {"port": py_sock, "status": True, "svc_id": "python3"}
    else:
        detected["SOCKS Python"] = {"port": "7777", "status": False, "svc_id": "python3"}

    # WS-EPRO / Badvpn
    ws_epro = _cmd("ss -tlnp 2>/dev/null | grep ':80 ' | awk '{print $4}' | head -1")
    if ws_epro:
        detected["WS-EPRO"] = {"port": "80", "status": True, "svc_id": "ws-epro"}
    else:
        detected["WS-EPRO"] = {"port": "80", "status": False, "svc_id": "ws-epro"}

    # CheckUser
    detected["CheckUser"] = {"port": "80", "status": False, "svc_id": "checkuser"}

    # ATKEN
    detected["ATKEN/HASH"] = {"port": "N/A", "status": False, "svc_id": "atken"}

    return detected


def _puertos_dashboard():
    """Muestra el cuadro de servicios con puertos."""
    detected = _scan_ports()

    # Lista de servicios para mostrar en el cuadro
    display = [
        ("BADVPN", detected.get("BadVPN", {}).get("port", "7300")),
        ("DROPBEAR", detected.get("Dropbear", {}).get("port", "110")),
        ("PYTHON3", detected.get("SOCKS Python", {}).get("port", "7777")),
        ("SLOWDNS", detected.get("SlowDNS", {}).get("port", "5300")),
        ("SSH", detected.get("SSH", {}).get("port", "22")),
        ("STUNNEL", detected.get("Stunnel", {}).get("port", "442")),
        ("UDP-CUSTOM", detected.get("UDP-Custom", {}).get("port", "36717")),
        ("UDP-HYSTERIA", detected.get("UDP-Hysteria", {}).get("port", "36712")),
        ("WS-EPRO", detected.get("WS-EPRO", {}).get("port", "80")),
        ("XRAY", detected.get("Xray", {}).get("port", "443")),
    ]

    print()
    print(f"  {dim(chr(9552) * 58)}")
    print(f"  {bold('ADMINISTRADOR DE PROTOCOLOS'):^58}")
    print(f"  {dim(chr(9552) * 58)}")

    # Imprimir en dos columnas
    col_width = 29
    for i in range(0, len(display), 2):
        left_name, left_port = display[i]
        if i + 1 < len(display):
            right_name, right_port = display[i + 1]
            left_str = f"  {left_name:<15} {bold(left_port):<12}"
            right_str = f"{right_name:<15} {bold(right_port)}"
            print(f"{left_str}{right_str}")
        else:
            print(f"  {left_name:<15} {bold(left_port)}")

    print(f"  {dim(chr(9552) * 58)}")


def _port_service_menu(svc_id, svc_name, default_port):
    """Submenu para un servicio individual."""
    st = check_service_status(svc_id)
    is_active = st == "active"

    status_str = ok("ON") if is_active else error("OFF")
    port_info = ""

    if is_active:
        real_port = _cmd(
            f"ss -tlnp 2>/dev/null | grep '{svc_id}' | awk '{{print $4}}' | "
            f"grep -oP '\\d+$' | head -1"
        )
        if not real_port:
            real_port = _cmd(
                f"ss -ulnp 2>/dev/null | grep '{svc_id}' | awk '{{print $4}}' | "
                f"grep -oP '\\d+$' | head -1"
            )
        port_info = real_port or default_port
    else:
        port_info = default_port

    separator()
    print()
    print(f"  {bold(svc_name.upper())}  [{status_str}]  Puerto: {bold(port_info)}")
    print()

    if is_active:
        print(f"    {bold('1)')} Reiniciar servicio")
        print(f"    {bold('2)')} Detener servicio")
        print(f"    {bold('3)')} Ver logs recientes")
        print(f"    {bold('4)')} Ver configuracion")
    else:
        print(f"    {bold('1)')} Iniciar servicio")
        print(f"    {bold('2)')} Instalar servicio")

    print()
    opt = prompt_input("Opcion")

    if is_active:
        if opt == "1":
            _cmd(f"systemctl restart {svc_id}")
            new_st = check_service_status(svc_id)
            if new_st == "active":
                ok_msg(f"{svc_name} reiniciado correctamente")
            else:
                error_msg(f"{svc_name} fallo al reiniciar")
        elif opt == "2":
            if confirm_destructive(f"Detener {svc_name}?"):
                _cmd(f"systemctl stop {svc_id}")
                ok_msg(f"{svc_name} detenido")
        elif opt == "3":
            output = _cmd(f"journalctl -u {svc_id} --no-pager -n 30 2>/dev/null")
            print(f"\n{output}" if output else dim("  No hay logs"))
        elif opt == "4":
            # Mostrar archivos de configuracion relevantes
            configs = {
                "ssh": "/etc/ssh/sshd_config",
                "stunnel4": "/etc/stunnel/stunnel.conf",
                "xray": "/usr/local/etc/xray/config.json",
                "udp-custom": "/etc/udp-custom/config.json",
                "slowdns": "/etc/slowdns/config",
            }
            cfg = configs.get(svc_id)
            if cfg and os.path.exists(cfg):
                output = _cmd(f"cat {cfg} 2>/dev/null | head -30")
                print(f"\n  {dim(cfg)}")
                print(output)
            else:
                warn_msg("No se encontro archivo de configuracion")
    else:
        if opt == "1":
            _cmd(f"systemctl start {svc_id}")
            new_st = check_service_status(svc_id)
            if new_st == "active":
                ok_msg(f"{svc_name} iniciado")
            else:
                error_msg(f"No se pudo iniciar {svc_name}")
        elif opt == "2":
            info_msg(f"Para instalar {svc_name} usa: crisdev.sh --install")


def _port_ssh_menu():
    """Submenu especifico para SSH."""
    st = check_service_status("sshd")
    is_active = st == "active"
    status_str = ok("ON") if is_active else error("OFF")

    separator()
    print()
    print(f"  {bold('SSH / SSH-SSL')}  [{status_str}]  Puerto: {bold('22')}")
    print()

    print(f"    {bold('1)')} Ver estado SSH")
    print(f"    {bold('2)')} Reiniciar SSH")
    print(f"    {bold('3)')} Ver intentos fallidos (fail2ban)")
    print(f"    {bold('4)')} Desbanear IP")
    print(f"    {bold('5)')} Ver config SSH")
    print(f"    {bold('6)')} Stunnel (SSH-SSL) estado")
    print(f"    {bold('7)')} Reiniciar Stunnel")

    print()
    opt = prompt_input("Opcion")

    if opt == "1":
        st = check_service_status("sshd")
        if st == "active":
            print(f"\n  SSH: {ok('activo')} en puerto 22")
            # Mostrar conexiones activas
            conns = _cmd("ss -tn | grep ':22 ' | wc -l")
            print(f"  Conexiones activas: {bold(conns)}")
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
    elif opt == "5":
        output = _cmd("cat /etc/ssh/sshd_config 2>/dev/null | grep -v '^#' | grep -v '^$' | head -30")
        print(f"\n  {dim('/etc/ssh/sshd_config')}")
        print(output)
    elif opt == "6":
        st = check_service_status("stunnel4")
        if st == "active":
            print(f"\n  Stunnel: {ok('activo')} en puerto 442")
        else:
            print(f"\n  Stunnel: {error(st)}")
    elif opt == "7":
        _cmd("systemctl restart stunnel4")
        ok_msg("Stunnel reiniciado")


def _fw_open():
    separator()
    port = prompt_input("Puerto a abrir")
    proto = prompt_input("Protocolo (tcp/udp) [tcp]") or "tcp"
    _cmd(f"echo y | ufw allow {port}/{proto}")
    ok_msg(f"Puerto {port}/{proto} abierto")


def _fw_close():
    separator()
    port = prompt_input("Puerto a cerrar")
    proto = prompt_input("Protocolo (tcp/udp) [tcp]") or "tcp"
    _cmd(f"echo y | ufw delete allow {port}/{proto}")
    ok_msg(f"Puerto {port}/{proto} cerrado")


def _fw_panic():
    separator()
    if confirm_destructive("ACTIVAR MODO PANICO? Se cerraran TODOS los puertos excepto SSH."):
        _cmd("ufw disable 2>/dev/null")
        _cmd("echo y | ufw reset 2>/dev/null")
        _cmd("ufw default deny incoming 2>/dev/null")
        _cmd("ufw default allow outgoing 2>/dev/null")
        _cmd(f"ufw allow {PORT_SSH}/tcp comment 'SSH-emergency'")
        _cmd("echo y | ufw enable 2>/dev/null")
        _audit("PANIC", "Modo panico activado")
        warn_msg("MODO PANICO ACTIVADO")


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
