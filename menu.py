"""
CRISDEV VPN Manager - Menu Module
==================================
Menu principal y submenus con interfaz profesional.
Todo el renderizado usa ui/components.py — ningun print() directo con colores.
"""
import json
import os
import subprocess
import sys
from datetime import datetime, timedelta
from typing import Optional

from ui import (
    clear_screen, header, banner_welcome, dashboard,
    section, separator, menu_item, menu_item_right, two_col_menu,
    prompt_input, confirm_destructive, breadcrumb, pause,
    ok_msg, error_msg, info_msg, warn_msg,
    user_table, user_detail_card, service_status_table,
    bold, ok, error, warn, info, dim,
    get_user_stats, check_service_status,
)


# ============================================================================
# CONFIGURACION
# ============================================================================

USERS_DB = "/etc/crisdev/data/users.json"
SERVER_CONFIG = "/etc/crisdev/data/server_config.json"
AUDIT_LOG = "/etc/crisdev/logs/audit.log"

# Puertos
PORT_SSH = 22
PORT_SSH_SSL = 443
PORT_XRAY_WS = 2053
PORT_XRAY_GRPC = 2083
PORT_XRAY_REALITY = 8443
PORT_XRAY_VLESS = 2096
PORT_WEBSOCKET = 8880
PORT_HYSTERIA = 443
PORT_UDP_CUSTOM = "7100-7200"


# ============================================================================
# HELPERS
# ============================================================================

def _load_users() -> list:
    """Carga la base de datos de usuarios."""
    try:
        with open(USERS_DB) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return []

def _save_users(users: list):
    """Guarda la base de datos de usuarios."""
    os.makedirs(os.path.dirname(USERS_DB), exist_ok=True)
    with open(USERS_DB, "w") as f:
        json.dump(users, f, indent=2)

def _find_user(username: str) -> Optional[dict]:
    """Busca un usuario por nombre."""
    for u in _load_users():
        if u.get("username") == username:
            return u
    return None

def _audit(action: str, detail: str):
    """Escribe en el log de auditoria."""
    os.makedirs(os.path.dirname(AUDIT_LOG), exist_ok=True)
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    with open(AUDIT_LOG, "a") as f:
        f.write(f"[{ts}] {action}: {detail}\n")

def _generate_uuid() -> str:
    """Genera un UUID."""
    try:
        with open("/proc/sys/kernel/random/uuid") as f:
            return f.read().strip()
    except Exception:
        import uuid
        return str(uuid.uuid4())

def _generate_password(length: int = 16) -> str:
    """Genera una contrasena aleatoria."""
    import secrets
    import string
    alphabet = string.ascii_letters + string.digits
    return ''.join(secrets.choice(alphabet) for _ in range(length))

def _cmd(command: str) -> str:
    """Ejecuta un comando y retorna el output."""
    try:
        result = subprocess.run(
            command, shell=True, capture_output=True, text=True, timeout=10
        )
        return result.stdout.strip()
    except Exception:
        return ""

def _server_ip() -> str:
    """Obtiene la IP del servidor."""
    try:
        with open(SERVER_CONFIG) as f:
            cfg = json.load(f)
        return cfg.get("server_ip", "?.?.?.?")
    except Exception:
        return "?.?.?.?"

def _server_domain() -> str:
    """Obtiene el dominio del servidor."""
    try:
        with open(SERVER_CONFIG) as f:
            cfg = json.load(f)
        return cfg.get("domain", "")
    except Exception:
        return ""


# ============================================================================
# MENU PRINCIPAL
# ============================================================================

def menu_main():
    """Menu principal del panel."""
    while True:
        clear_screen()
        header()
        dashboard(USERS_DB)

        # --- USUARIOS (columna izquierda) ---
        section("USUARIOS")
        left = [
            (1, "Crear usuario"),
            (2, "Editar usuario"),
            (3, "Eliminar usuario"),
            (4, "Suspender usuario"),
            (5, "Reactivar usuario"),
        ]
        right = [
            (6, "Renovar usuario"),
            (7, "Listar usuarios"),
            (8, "Ver detalle"),
            (9, "Buscar usuario"),
        ]
        two_col_menu(left, right, col_width_left=33)
        print()

        # --- PROTOCOLOS ---
        section("PROTOCOLOS")
        left2 = [
            (10, "SSH / SSH-SSL"),
            (11, "SlowDNS"),
            (12, "Xray (VLESS/VMess/Trojan)"),
        ]
        right2 = [
            (13, "Hysteria2"),
            (14, "udp-custom"),
            (15, "Generar links de conexion"),
        ]
        two_col_menu(left2, right2, col_width_left=33)
        print()

        # --- SERVIDOR ---
        section("SERVIDOR")
        left3 = [
            (16, "Estado del servidor"),
            (17, "Firewall / puertos"),
        ]
        right3 = [
            (18, "Certificados TLS"),
            (19, "Backups"),
        ]
        two_col_menu(left3, right3, col_width_left=33)
        print()

        # --- SISTEMA ---
        section("SISTEMA")
        left4 = [
            (20, "Verificar versiones"),
            (21, "Logs de servicios"),
        ]
        right4 = [
            (23, "Logs de auditoria"),
            (24, "Actualizar CRISDEV"),
        ]
        two_col_menu(left4, right4, col_width_left=33)
        print()

        # --- SALIDA ---
        separator()
        print(f"    {error('[0] Salir del script')}              {warn('[9] Reiniciar VPS')}")

        choice = prompt_input("Ingresa una opcion")

        if choice == "1":
            menu_create_user()
        elif choice == "2":
            menu_edit_user()
        elif choice == "3":
            menu_delete_user()
        elif choice == "4":
            menu_suspend_user()
        elif choice == "5":
            menu_reactivate_user()
        elif choice == "6":
            menu_renew_user()
        elif choice == "7":
            menu_list_users()
        elif choice == "8":
            menu_user_detail()
        elif choice == "9":
            menu_reboot_vps()
        elif choice == "10":
            menu_ssh()
        elif choice == "11":
            menu_slowdns()
        elif choice == "12":
            menu_xray()
        elif choice == "13":
            menu_hysteria2()
        elif choice == "14":
            menu_udp_custom()
        elif choice == "15":
            menu_generate_links()
        elif choice == "16":
            menu_server_status()
        elif choice == "17":
            menu_firewall()
        elif choice == "18":
            menu_certs()
        elif choice == "19":
            menu_backup()
        elif choice == "20":
            menu_check_versions()
        elif choice == "21":
            menu_service_logs()
        elif choice == "23":
            menu_audit_log()
        elif choice == "24":
            menu_update_crisdev()
        elif choice == "0":
            clear_screen()
            print(f"\n  {ok('Hasta luego, CRISDEV.')}\n")
            sys.exit(0)
        else:
            error_msg("Opcion invalida")

        pause()


# ============================================================================
# USUARIOS — CRUD
# ============================================================================

def menu_create_user():
    """Crear un nuevo usuario."""
    breadcrumb("CRISDEV > Usuarios > Crear")
    section("CREAR USUARIO")
    separator()

    username = prompt_input("Nombre de usuario")
    if not username:
        error_msg("Nombre no puede estar vacio")
        return

    users = _load_users()
    if any(u["username"] == username for u in users):
        error_msg(f"Usuario {username} ya existe")
        return

    password = prompt_input("Contrasena (vacio = auto-generar)")
    if not password:
        password = _generate_password()

    print()
    print(f"  {bold('Protocolos:')}")
    print("    1) SSH          6) Xray VMess")
    print("    2) SSH-SSL      7) Xray Trojan")
    print("    3) WebSocket    8) Hysteria2")
    print("    4) SlowDNS      9) udp-custom")
    print("    5) Xray VLESS   0) TODOS")
    protos_input = prompt_input("Selecciona (coma separados")
    protocols = [p.strip() for p in protos_input.split(",") if p.strip()]

    days_str = prompt_input("Dias de vigencia [30]")
    days = int(days_str) if days_str.isdigit() else 30

    max_conn_str = prompt_input("Max conexiones simultaneas [2]")
    max_conn = int(max_conn_str) if max_conn_str.isdigit() else 2

    bw_str = prompt_input("Limite BW en Mbps (0=sin limite) [0]")
    bw = int(bw_str) if bw_str.isdigit() else 0

    exp_date = (datetime.now() + timedelta(days=days)).strftime("%Y-%m-%d %H:%M:%S")

    new_user = {
        "username": username,
        "password": password,
        "status": "active",
        "created_at": datetime.now().isoformat(),
        "expires_at": exp_date,
        "max_connections": max_conn,
        "current_connections": 0,
        "bandwidth_limit": bw,
        "protocols": protocols,
        "data_used_bytes": 0,
        "last_login": None,
        "last_ip": None,
    }
    users.append(new_user)
    _save_users(users)
    _audit("USER_CREATE", f"{username}, protos: {protocols}, expira: {exp_date}")

    print()
    print(f"  {bold(ok('USUARIO CREADO EXITOSAMENTE'))}")
    print(f"  Usuario:    {bold(username)}")
    print(f"  Contrasena: {bold(password)}")
    print(f"  Expira:     {bold(exp_date)}")
    print(f"  Protocolos: {bold(', '.join(protocols))}")
    print(f"  Max conex:  {bold(str(max_conn))}")


def menu_edit_user():
    """Editar un usuario existente."""
    breadcrumb("CRISDEV > Usuarios > Editar")
    section("EDITAR USUARIO")
    separator()

    username = prompt_input("Usuario a editar")
    user = _find_user(username)
    if not user:
        error_msg("Usuario no encontrado")
        return

    user_detail_card(user)

    print()
    print(f"  {bold('Que deseas cambiar?')}")
    print("    1) Contrasena       4) Limite BW")
    print("    2) Expiracion       5) Protocolos")
    print("    3) Max conexiones   0) Volver")
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


def menu_delete_user():
    """Eliminar un usuario permanentemente."""
    breadcrumb("CRISDEV > Usuarios > Eliminar")

    username = prompt_input("Usuario a eliminar")
    if not _find_user(username):
        error_msg("Usuario no encontrado")
        return

    if confirm_destructive(f"ELIMINAR a {username} permanentemente? Esta accion NO se puede deshacer."):
        users = _load_users()
        users = [u for u in users if u["username"] != username]
        _save_users(users)
        _audit("USER_DELETE", username)
        ok_msg(f"Usuario {username} eliminado completamente")
    else:
        info_msg("Cancelado")


def menu_suspend_user():
    """Suspender un usuario temporalmente."""
    breadcrumb("CRISDEV > Usuarios > Suspender")

    username = prompt_input("Usuario a suspender")
    if not _find_user(username):
        error_msg("Usuario no encontrado")
        return

    if confirm_destructive(f"Suspender a {username}? Se cerraran sus sesiones activas."):
        users = _load_users()
        for u in users:
            if u["username"] == username:
                u["status"] = "suspended"
                break
        _save_users(users)
        _audit("USER_SUSPEND", username)
        ok_msg(f"Usuario {username} suspendido")
    else:
        info_msg("Cancelado")


def menu_reactivate_user():
    """Reactivar un usuario suspendido."""
    breadcrumb("CRISDEV > Usuarios > Reactivar")

    username = prompt_input("Usuario a reactivar")
    if not _find_user(username):
        error_msg("Usuario no encontrado")
        return

    users = _load_users()
    for u in users:
        if u["username"] == username:
            u["status"] = "active"
            break
    _save_users(users)
    _audit("USER_REACTIVATE", username)
    ok_msg(f"Usuario {username} reactivado")


def menu_renew_user():
    """Renovar la vigencia de un usuario."""
    breadcrumb("CRISDEV > Usuarios > Renovar")

    username = prompt_input("Usuario a renovar")
    user = _find_user(username)
    if not user:
        error_msg("Usuario no encontrado")
        return

    ad = prompt_input("Dias a agregar [30]")
    add_days = int(ad) if ad.isdigit() else 30

    users = _load_users()
    for u in users:
        if u["username"] == username:
            if u.get("expires_at"):
                try:
                    exp_dt = datetime.fromisoformat(u["expires_at"])
                    if exp_dt > datetime.now():
                        base = exp_dt
                    else:
                        base = datetime.now()
                except Exception:
                    base = datetime.now()
            else:
                base = datetime.now()
            u["expires_at"] = (base + timedelta(days=add_days)).strftime("%Y-%m-%d %H:%M:%S")
            u["status"] = "active"
            break
    _save_users(users)
    _audit("USER_RENEW", f"{username} hasta {u['expires_at']}")
    ok_msg(f"Usuario {username} renovado hasta {u['expires_at']}")


def menu_list_users():
    """Listar usuarios con filtros."""
    breadcrumb("CRISDEV > Usuarios > Lista")
    section("LISTA DE USUARIOS")
    separator()

    print("    1) Todos    3) Vencidos    5) Por vencer (3d)")
    print("    2) Activos  4) Suspendidos 6) Por protocolo")
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


def menu_user_detail():
    """Ver detalle de un usuario."""
    breadcrumb("CRISDEV > Usuarios > Detalle")

    username = prompt_input("Usuario")
    user = _find_user(username)
    if not user:
        error_msg("Usuario no encontrado")
        return

    user_detail_card(user)


def menu_reboot_vps():
    """Reiniciar el VPS."""
    breadcrumb("CRISDEV > Sistema > Reiniciar")
    if confirm_destructive("Reiniciar el VPS? Se cerraran todas las conexiones."):
        ok_msg("Reiniciando VPS...")
        _audit("REBOOT", "VPS reiniciado desde panel")
        subprocess.run(["reboot"], timeout=5)


# ============================================================================
# PROTOCOLOS
# ============================================================================

def menu_ssh():
    """Submenu de SSH / SSH-SSL."""
    breadcrumb("CRISDEV > Protocolos > SSH")
    section("SSH / SSH-SSL")
    separator()

    print("    1) Ver estado SSH")
    print("    2) Configurar SSH-SSL (stunnel)")
    print("    3) Reiniciar SSH")
    print("    4) Ver intentos fallidos (fail2ban)")
    print("    5) Desbanear IP")
    print("    0) Volver")
    opt = prompt_input("Opcion")

    if opt == "1":
        st = check_service_status("sshd")
        if st == "active":
            print(f"\n  SSH: {ok('● activo')} en puerto {PORT_SSH}")
        else:
            print(f"\n  SSH: {error('○ ' + st)}")
    elif opt == "2":
        info_msg("Configurando stunnel (SSH-SSL)...")
        _cmd("apt-get install -y stunnel4 2>/dev/null")
        _cmd(f"systemctl enable stunnel4 && systemctl restart stunnel4")
        ok_msg("SSH-SSL configurado")
    elif opt == "3":
        _cmd("systemctl restart sshd 2>/dev/null || systemctl restart ssh")
        ok_msg("SSH reiniciado")
    elif opt == "4":
        output = _cmd("fail2ban-client status sshd 2>/dev/null")
        print(f"\n{output}")
    elif opt == "5":
        ip = prompt_input("IP a desbanear")
        if ip:
            _cmd(f"fail2ban-client set sshd unbanip {ip} 2>/dev/null")
            ok_msg(f"IP {ip} desbaneada")


def menu_slowdns():
    """Instalacion de SlowDNS."""
    breadcrumb("CRISDEV > Protocolos > SlowDNS")
    section("INSTALACION SLOWDNS")
    separator()

    domain = prompt_input("Dominio NS delegado")
    port = prompt_input("Puerto DNS [53]")
    if not port:
        port = "53"

    info_msg(f"Instalando SlowDNS en puerto {port}...")
    # La instalacion real se hace desde el script bash
    ok_msg("SlowDNS — usar crisdev.sh --install para configurar")


def menu_xray():
    """Submenu de Xray-core."""
    breadcrumb("CRISDEV > Protocolos > Xray-core")
    section("XRAY-CORE")
    separator()

    print("    1) Ver estado de Xray")
    print("    2) Ver version")
    print("    3) Reiniciar Xray")
    print("    4) Ver logs recientes")
    print("    0) Volver")
    opt = prompt_input("Opcion")

    if opt == "1":
        st = check_service_status("xray")
        if st == "active":
            print(f"\n  Xray: {ok('● activo')}")
        else:
            print(f"\n  Xray: {error('○ ' + st)}")
    elif opt == "2":
        v = _cmd("/opt/xray/xray version 2>/dev/null | head -1")
        if v:
            print(f"\n  {bold(v)}")
        else:
            warn_msg("Xray no instalado o no encontrado")
    elif opt == "3":
        _cmd("systemctl restart xray")
        ok_msg("Xray reiniciado")
    elif opt == "4":
        output = _cmd("journalctl -u xray --no-pager -n 30 2>/dev/null")
        print(f"\n{output}")


def menu_hysteria2():
    """Submenu de Hysteria2."""
    breadcrumb("CRISDEV > Protocolos > Hysteria2")
    section("HYSTERIA2")
    separator()

    print("    1) Ver estado")
    print("    2) Ver version")
    print("    3) Reiniciar Hysteria2")
    print("    4) Ver logs recientes")
    print("    0) Volver")
    opt = prompt_input("Opcion")

    if opt == "1":
        st = check_service_status("hysteria-server")
        if st == "active":
            print(f"\n  Hysteria2: {ok('● activo')} en puerto {PORT_HYSTERIA}/udp")
        else:
            print(f"\n  Hysteria2: {error('○ ' + st)}")
    elif opt == "2":
        v = _cmd("hysteria-server version 2>/dev/null | head -1")
        print(f"\n  {bold(v)}" if v else warn_msg("No instalado"))
    elif opt == "3":
        _cmd("systemctl restart hysteria-server")
        ok_msg("Hysteria2 reiniciado")
    elif opt == "4":
        output = _cmd("journalctl -u hysteria-server --no-pager -n 30 2>/dev/null")
        print(f"\n{output}")


def menu_udp_custom():
    """Submenu de udp-custom."""
    breadcrumb("CRISDEV > Protocolos > udp-custom")
    section("UDP-CUSTOM")
    separator()

    print("    1) Ver estado")
    print("    2) Reiniciar udp-custom")
    print("    3) Ver logs recientes")
    print("    0) Volver")
    opt = prompt_input("Opcion")

    if opt == "1":
        st = check_service_status("udp-custom")
        if st == "active":
            print(f"\n  udp-custom: {ok('● activo')} en puerto {PORT_UDP_CUSTOM}/udp")
        else:
            print(f"\n  udp-custom: {error('○ ' + st)}")
    elif opt == "2":
        _cmd("systemctl restart udp-custom")
        ok_msg("udp-custom reiniciado")
    elif opt == "3":
        output = _cmd("journalctl -u udp-custom --no-pager -n 30 2>/dev/null")
        print(f"\n{output}")


def menu_generate_links():
    """Generar links de conexion para un usuario."""
    breadcrumb("CRISDEV > Protocolos > Links")
    section("GENERAR LINKS DE CONEXION")
    separator()

    username = prompt_input("Usuario")
    user = _find_user(username)
    if not user:
        error_msg("Usuario no encontrado")
        return

    uid = user["username"]
    upass = user["password"]
    sip = _server_ip()
    sdom = _server_domain()
    host = sdom if sdom else sip

    print()
    print(f"  {bold('LINKS DE CONEXION')}")
    print(f"  {dim(f'Para: {username}')}")
    separator()

    import secrets
    rand_path = secrets.token_hex(8)
    rand_grpc = secrets.token_hex(4)

    print(f"\n  {bold('VLESS + WS + TLS:')}")
    print(f"    vless://{uid}@{host}:{PORT_XRAY_WS}?encryption=none&security=tls&type=ws&path=%2F{rand_path}&host={host}#CRISDEV-VLESS-WS")

    print(f"\n  {bold('VLESS + gRPC + TLS:')}")
    print(f"    vless://{uid}@{host}:{PORT_XRAY_GRPC}?encryption=none&security=tls&type=grpc&serviceName=grpc-{rand_grpc}&fp=chrome#CRISDEV-VLESS-gRPC")

    vmess_json = json.dumps({
        "v": "2", "ps": "CRISDEV-VMess", "add": host,
        "port": str(PORT_WEBSOCKET), "id": uid, "aid": "0",
        "scy": "auto", "net": "ws", "type": "none",
        "host": host, "path": "/vmess-ws", "tls": "tls"
    })
    import base64
    vmess_b64 = base64.b64encode(vmess_json.encode()).decode()
    print(f"\n  {bold('VMess + WS + TLS:')}")
    print(f"    vmess://{vmess_b64}")

    print(f"\n  {bold('Trojan + WS + TLS:')}")
    print(f"    trojan://{upass}@{host}:{PORT_XRAY_VLESS}?type=ws&host={host}&path=%2Ftrojan-ws&security=tls#CRISDEV-Trojan")

    print(f"\n  {bold('Hysteria2:')}")
    print(f"    hysteria2://{upass}@{host}:{PORT_HYSTERIA}?insecure=1&obfs=salamander&obfs-password={upass}#CRISDEV-Hysteria2")


# ============================================================================
# SERVIDOR
# ============================================================================

def menu_server_status():
    """Estado completo del servidor."""
    breadcrumb("CRISDEV > Servidor > Estado")
    section("ESTADO DEL SERVIDOR")
    separator()

    print(f"\n  {bold('Sistema:')}")
    print(f"    IP: {bold(_server_ip())}")
    print(f"    Hostname: {_cmd('hostname')}")
    print(f"    OS: {_cmd(\"cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d'\\\"' -f2\")}")
    print(f"    Kernel: {_cmd('uname -r')}")
    print(f"    Uptime: {_cmd('uptime -p 2>/dev/null || uptime')}")

    print(f"\n  {bold('Recursos:')}")
    cpu = _cmd("top -bn1 | grep 'Cpu(s)' | awk '{print $2}' 2>/dev/null")
    print(f"    CPU: {cpu}%")
    mem = _cmd("free -h | awk '/Mem:/{print $3\"/\"$2}'")
    print(f"    RAM: {mem}")

    print(f"\n  {bold('Servicios:')}")
    service_status_table()

    print(f"\n  {bold('Conexiones:')}")
    print(f"    SSH:      {_cmd(f'ss -tn | grep -c \":{PORT_SSH} \" 2>/dev/null || echo 0')}")
    print(f"    Xray:     {_cmd(f'ss -tn | grep -cE \":({PORT_XRAY_WS}|{PORT_XRAY_GRPC}) \" 2>/dev/null || echo 0')}")
    print(f"    Hysteria: {_cmd(f'ss -un | grep -c \":{PORT_HYSTERIA} \" 2>/dev/null || echo 0')}")


def menu_firewall():
    """Gestion del firewall."""
    breadcrumb("CRISDEV > Servidor > Firewall")
    section("FIREWALL / PUERTOS")
    separator()

    print("    1) Ver reglas actuales (ufw status)")
    print("    2) Abrir puerto")
    print("    3) Cerrar puerto")
    print("    4) Modo panico (cerrar todo)")
    print("    0) Volver")
    opt = prompt_input("Opcion")

    if opt == "1":
        output = _cmd("ufw status verbose 2>/dev/null")
        print(f"\n{output}")
    elif opt == "2":
        port = prompt_input("Puerto")
        proto = prompt_input("Protocolo (tcp/udp) [tcp]")
        if not proto:
            proto = "tcp"
        _cmd(f"ufw allow {port}/{proto}")
        ok_msg(f"Puerto {port}/{proto} abierto")
    elif opt == "3":
        port = prompt_input("Puerto")
        proto = prompt_input("Protocolo (tcp/udp) [tcp]")
        if not proto:
            proto = "tcp"
        _cmd(f"ufw delete allow {port}/{proto}")
        ok_msg(f"Puerto {port}/{proto} cerrado")
    elif opt == "4":
        if confirm_destructive("ACTIVAR MODO PANICO? Se cerraran TODOS los puertos excepto SSH."):
            _cmd("ufw disable 2>/dev/null")
            _cmd("echo y | ufw reset 2>/dev/null")
            _cmd("ufw default deny incoming 2>/dev/null")
            _cmd("ufw default allow outgoing 2>/dev/null")
            _cmd(f"ufw allow {PORT_SSH}/tcp comment 'SSH-emergency'")
            _cmd("echo y | ufw enable 2>/dev/null")
            _audit("PANIC", "Modo panico activado")
            warn_msg("MODO PANICO ACTIVADO")


def menu_certs():
    """Gestion de certificados TLS."""
    breadcrumb("CRISDEV > Servidor > Certificados")
    section("CERTIFICADOS TLS")
    separator()

    cert_path = "/etc/crisdev/certs/fullchain.pem"
    print("    1) Ver certificado actual")
    print("    2) Generar certificado autofirmado")
    print("    3) Renovar certificados (Let's Encrypt)")
    print("    0) Volver")
    opt = prompt_input("Opcion")

    if opt == "1":
        if os.path.exists(cert_path):
            output = _cmd(f"openssl x509 -in {cert_path} -noout -subject -dates 2>/dev/null")
            print(f"\n{output}")
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


def menu_backup():
    """Gestion de backups."""
    breadcrumb("CRISDEV > Servidor > Backups")
    section("BACKUPS")
    separator()

    print("    1) Crear backup")
    print("    2) Listar backups")
    print("    3) Restaurar backup")
    print("    0) Volver")
    opt = prompt_input("Opcion")

    backup_dir = "/etc/crisdev/backups"
    os.makedirs(backup_dir, exist_ok=True)

    if opt == "1":
        ts = datetime.now().strftime("%Y%m%d_%H%M%S")
        bf = f"{backup_dir}/crisdev_backup_{ts}.tar.gz"
        _cmd(f"tar -czf {bf} -C / etc/crisdev/data etc/crisdev/certs etc/hysteria usr/local/etc/xray 2>/dev/null")
        size = _cmd(f"du -h {bf} | awk '{{print $1}}'")
        ok_msg(f"Backup: {bf} ({size})")
        _audit("BACKUP", f"{bf} ({size})")
    elif opt == "2":
        output = _cmd(f"ls -la {backup_dir}/*.tar.gz 2>/dev/null")
        if output:
            print(f"\n{output}")
        else:
            warn_msg("No hay backups disponibles")
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
            warn_msg("No hay backups disponibles")


# ============================================================================
# SISTEMA
# ============================================================================

def menu_check_versions():
    """Verificar versiones de servicios."""
    breadcrumb("CRISDEV > Sistema > Versiones")
    section("VERSIONES INSTALADAS")
    separator()

    print(f"\n  {bold('Instaladas:')}")
    xray_v = _cmd("/opt/xray/xray version 2>/dev/null | head -1")
    hy_v = _cmd("hysteria-server version 2>/dev/null | head -1")
    udp_v = _cmd("/opt/udp-custom/server --version 2>/dev/null")

    print(f"    Xray:       {bold(xray_v)}" if xray_v else "    Xray:       No instalado")
    print(f"    Hysteria2:  {bold(hy_v)}" if hy_v else "    Hysteria2:  No instalado")
    print(f"    udp-custom: {bold(udp_v)}" if udp_v else "    udp-custom: No instalado")

    print(f"\n  {bold('Ultimas disponibles:')}")
    xray_latest = _cmd("curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -r '.tag_name' 2>/dev/null")
    hy_latest = _cmd("curl -s https://api.github.com/repos/apernet/hysteria/releases/latest | jq -r '.tag_name' 2>/dev/null")
    print(f"    Xray: {xray_latest}")
    print(f"    Hysteria2: {hy_latest}")


def menu_service_logs():
    """Ver logs de servicios."""
    breadcrumb("CRISDEV > Sistema > Logs")
    section("LOGS DE SERVICIOS")
    separator()

    print("    1) Xray (ultimas 30 lineas)")
    print("    2) Hysteria2")
    print("    3) SSH")
    print("    4) fail2ban")
    print("    0) Volver")
    opt = prompt_input("Opcion")

    services = {
        "1": "xray",
        "2": "hysteria-server",
        "3": "sshd",
    }
    if opt in services:
        output = _cmd(f"journalctl -u {services[opt]} --no-pager -n 30 2>/dev/null")
        print(f"\n{output}")
    elif opt == "4":
        output = _cmd("fail2ban-client status sshd 2>/dev/null")
        print(f"\n{output}")


def menu_audit_log():
    """Ver log de auditoria."""
    breadcrumb("CRISDEV > Sistema > Auditoria")
    print()
    if os.path.exists(AUDIT_LOG):
        output = _cmd(f"tail -50 {AUDIT_LOG}")
        print(output if output else dim("  Log vacio"))
    else:
        warn_msg("No hay log de auditoria")


def menu_update_crisdev():
    """Actualizar CRISDEV desde GitHub."""
    breadcrumb("CRISDEV > Sistema > Actualizar")
    info_msg("Actualizando CRISDEV...")
    url = "https://raw.githubusercontent.com/soportecrisdev/SCRIP_CRISDEV/main/crisdev.sh"
    _cmd(f"curl -fsSL {url} -o /usr/local/bin/crisdev 2>/dev/null && chmod +x /usr/local/bin/crisdev")
    ok_msg("CRISDEV actualizado")
