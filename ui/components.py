"""
CRISDEV VPN Manager - UI Components
====================================
Funciones reutilizables para renderizar la interfaz.
"""
import os
import subprocess
import json
from datetime import datetime
from typing import Optional

from ui.theme import (
    C_OK, C_ERROR, C_WARN, C_INFO, C_DIM, C_BOLD, C_ACCENT, C_PROMPT, C_RESET
)


# ============================================================================
# HELPERS DE COLOR
# ============================================================================

def bold(text: str) -> str:
    return f"{C_BOLD}{text}{C_RESET}"

def ok(text: str) -> str:
    return f"{C_OK}{text}{C_RESET}"

def error(text: str) -> str:
    return f"{C_ERROR}{text}{C_RESET}"

def warn(text: str) -> str:
    return f"{C_WARN}{text}{C_RESET}"

def info(text: str) -> str:
    return f"{C_INFO}{text}{C_RESET}"

def dim(text: str) -> str:
    return f"{C_DIM}{text}{C_RESET}"


# ============================================================================
# HELPERS DE SISTEMA
# ============================================================================

def clear_screen():
    os.system("cls" if os.name == "nt" else "clear")

def get_server_ip() -> str:
    try:
        r = subprocess.run(["curl", "-s4", "--max-time", "5", "ifconfig.me"],
                           capture_output=True, text=True, timeout=10)
        if r.stdout.strip():
            return r.stdout.strip()
    except Exception:
        pass
    try:
        r = subprocess.run(["hostname", "-I"], capture_output=True, text=True, timeout=5)
        return r.stdout.strip().split()[0]
    except Exception:
        return "?.?.?.?"

def get_server_os() -> str:
    try:
        with open("/etc/os-release") as f:
            for line in f:
                if line.startswith("PRETTY_NAME="):
                    return line.split("=", 1)[1].strip().strip('"')
    except Exception:
        pass
    return "Linux"

def get_uptime() -> str:
    try:
        r = subprocess.run(["uptime", "-p"], capture_output=True, text=True, timeout=5)
        return r.stdout.strip()
    except Exception:
        return "N/A"

def check_service_status(service: str) -> str:
    try:
        r = subprocess.run(["systemctl", "is-active", service],
                           capture_output=True, text=True, timeout=5)
        return r.stdout.strip()
    except Exception:
        return "not-found"

def check_service_latency(service: str, port: Optional[int] = None) -> Optional[int]:
    if not port:
        return None
    try:
        r = subprocess.run(["bash", "-c", f"echo > /dev/tcp/127.0.0.1/{port}"],
                           capture_output=True, text=True, timeout=3)
        if r.returncode == 0:
            r2 = subprocess.run(["curl", "-so", "/dev/null", "-w", "%{time_total}",
                                 f"http://127.0.0.1:{port}/"],
                                capture_output=True, text=True, timeout=5)
            if r2.returncode == 0:
                return int(float(r2.stdout.strip()) * 1000)
    except Exception:
        pass
    return None

def get_user_stats(users_db: str) -> dict:
    stats = {"total": 0, "active": 0, "expiring_soon": 0, "suspended": 0, "expired": 0}
    try:
        with open(users_db) as f:
            users = json.load(f)
        stats["total"] = len(users)
        now = datetime.now()
        for u in users:
            st = u.get("status", "active")
            if st == "suspended":
                stats["suspended"] += 1
            elif st == "active":
                stats["active"] += 1
                exp = u.get("expires_at")
                if exp:
                    try:
                        exp_dt = datetime.fromisoformat(exp.replace("Z", "+00:00"))
                        days_left = (exp_dt.replace(tzinfo=None) - now).days
                        if 0 < days_left <= 3:
                            stats["expiring_soon"] += 1
                    except Exception:
                        pass
            elif st == "expired":
                stats["expired"] += 1
    except (FileNotFoundError, json.JSONDecodeError):
        pass
    return stats


# ============================================================================
# HEADER - 3 lineas fijas
# ============================================================================

def header():
    ip = get_server_ip()
    os_name = get_server_os()[:25]
    date_str = datetime.now().strftime("%d-%m-%Y %H:%M")
    print()
    print(f"  {bold('CRISDEV VPN MANAGER')}  {dim('v1.1')}  {dim('@CRISIS1823')}")
    print(f"  IP: {bold(ip)}  |  {os_name}  |  {date_str}")
    print(f"  {dim(chr(9472) * 58)}")


# ============================================================================
# DASHBOARD - Status bar compacto
# ============================================================================

def dashboard(users_db: str):
    stats = get_user_stats(users_db)

    active = stats["active"]
    suspended = stats["suspended"]
    expiring = stats["expiring_soon"]
    total = stats["total"]

    exp_str = f" {warn(f'{expiring} por vencer')} " if expiring > 0 else ""

    parts = []
    parts.append(f"{ok(str(active))} activos")
    if suspended:
        parts.append(f"{error(str(suspended))} susp")
    if expiring:
        parts.append(warn(f"{expiring} vence"))
    parts.append(f"total {total}")

    print(f"  USUARIOS: {' | '.join(parts)}")

    services = [
        ("xray", "xray"),
        ("hysteria-server", "hysteria"),
        ("stunnel4", "stunnel"),
        ("udp-custom", "udp"),
        ("sshd", "ssh"),
    ]
    svc_parts = []
    for svc_id, svc_name in services:
        st = check_service_status(svc_id)
        if st == "active":
            svc_parts.append(f"{ok(svc_name)}")
        else:
            svc_parts.append(f"{error(svc_name)}")

    print(f"  SERVICIOS: {' | '.join(svc_parts)}")
    print()


# ============================================================================
# SECTION / SEPARATOR
# ============================================================================

def section(title: str):
    print(f"\n  {bold(title)}")

def separator():
    print(f"  {dim(chr(9472) * 52)}")


# ============================================================================
# MENU
# ============================================================================

def two_col_menu(left_items: list, right_items: list, col_width_left: int = 33):
    max_rows = max(len(left_items), len(right_items))
    for i in range(max_rows):
        left_str = ""
        right_str = ""
        if i < len(left_items):
            n, l = left_items[i]
            left_str = f"    {bold(f'{n})')} {l:<{col_width_left}}"
        if i < len(right_items):
            n, l = right_items[i]
            right_str = f"{bold(f'{n})')} {l}"
        print(f"{left_str}{right_str}")


def prompt_input(message: str = "Opcion") -> str:
    print()
    try:
        return input(f"  {C_PROMPT}{message}: {C_RESET}").strip()
    except (EOFError, KeyboardInterrupt):
        return ""


def confirm_destructive(message: str) -> bool:
    print()
    print(f"  {bold(error('  PELIGRO'))}  {message}")
    print()
    try:
        resp = input(f"  {error('Escribe SI para confirmar: ')}").strip()
    except (EOFError, KeyboardInterrupt):
        return False
    return resp == "SI"


def breadcrumb(path: str):
    print()
    print(f"  {dim(path)}")
    print()


def pause():
    print()
    try:
        input(f"  {dim('Presiona Enter...')}")
    except (EOFError, KeyboardInterrupt):
        pass


def ok_msg(message: str):
    print(f"  {ok('[OK]')} {message}")

def error_msg(message: str):
    print(f"  {error('[!]')} {message}")

def info_msg(message: str):
    print(f"  {info('[i]')} {message}")

def warn_msg(message: str):
    print(f"  {warn('[!]')} {message}")


# ============================================================================
# TABLA DE USUARIOS
# ============================================================================

def user_table(users: list, show_all: bool = False):
    print()
    header_str = (
        f"  {bold('USUARIO'):<15} "
        f"{bold('ESTADO'):<12} "
        f"{bold('EXPIRA'):<14} "
        f"{bold('MAX'):<6} "
        f"{bold('PROTOCOLOS')}"
    )
    print(header_str)
    print(f"  {dim(chr(9472) * 65)}")

    for u in users:
        username = u.get("username", "?")
        status = u.get("status", "unknown")
        expires = u.get("expires_at", "N/A")
        max_conn = u.get("max_connections", 0)
        protocols = u.get("protocols", [])

        if status == "active":
            status_display = ok("active")
        elif status == "suspended":
            status_display = warn("suspended")
        else:
            status_display = error(status)

        proto_str = ", ".join(protocols) if isinstance(protocols, list) else str(protocols)
        if len(proto_str) > 25:
            proto_str = proto_str[:22] + "..."

        print(
            f"  {username:<15} "
            f"{status_display:<22} "
            f"{expires:<14} "
            f"{max_conn:<6} "
            f"{proto_str}"
        )

    print()
    total = len(users)
    active = sum(1 for u in users if u.get("status") == "active")
    print(f"  Total: {bold(str(total))} | Activos: {ok(bold(str(active)))}")


# ============================================================================
# USER DETAIL CARD
# ============================================================================

def user_detail_card(user: dict):
    print()
    print(f"  {bold('DETALLE DE USUARIO')}")
    print(f"  {dim(chr(9472) * 42)}")
    fields = [
        ("Usuario", user.get("username", "?")),
        ("Estado", user.get("status", "?")),
        ("Creado", user.get("created_at", "?")),
        ("Expira", user.get("expires_at", "?")),
        ("Max Conexiones", str(user.get("max_connections", 0))),
        ("Conexiones activas", str(user.get("current_connections", 0))),
        ("Limite BW", f"{user.get('bandwidth_limit', 0)} Mbps"),
        ("Datos usados", f"{user.get('data_used_bytes', 0)} bytes"),
        ("Ultimo login", user.get("last_login") or "Nunca"),
        ("Ultima IP", user.get("last_ip") or "N/A"),
        ("Protocolos", ", ".join(user.get("protocols", []))),
    ]
    for label, value in fields:
        print(f"  {label:<18} {bold(value)}")


# ============================================================================
# SERVICE STATUS TABLE
# ============================================================================

def service_status_table():
    print()
    print(f"  {bold('Servicio'):<20} {bold('Estado'):<12} {bold('Latencia')}")
    print(f"  {dim(chr(9472) * 45)}")

    services = [
        ("xray", "Xray-core", 2053),
        ("hysteria-server", "Hysteria2", 443),
        ("stunnel4", "SSH-SSL", 443),
        ("udp-custom", "udp-custom", 7100),
        ("sshd", "SSH", 22),
        ("fail2ban", "fail2ban", None),
        ("ufw", "Firewall", None),
    ]

    for svc_id, svc_name, port in services:
        status = check_service_status(svc_id)
        if status == "active":
            lat = check_service_latency(svc_id, port)
            status_display = ok("● active")
            lat_display = f"{lat}ms" if lat else dim("N/A")
        elif status == "inactive":
            status_display = warn("○ inactive")
            lat_display = dim("—")
        else:
            status_display = error("✗ dead")
            lat_display = dim("—")

        print(f"  {svc_name:<20} {status_display}        {lat_display}")


# ============================================================================
# BANNER - Solo primera pantalla
# ============================================================================

def banner_welcome():
    print()
    print(f"{C_BOLD}{C_INFO}")
    print("     ██████╗██████╗ ██╗██████╗ ████████╗███████╗██████╗ ███╗   ██╗")
    print("    ██╔════╝██╔══██╗██║██╔══██╗╚══██╔══╝██╔════╝██╔══██╗████╗  ██║")
    print("    ██║     ██████╔╝██║██████╔╝   ██║   █████╗  ██████╔╝██╔██╗ ██║")
    print("    ██║     ██╔══██╗██║██╔═══╝    ██║   ██╔══╝  ██╔══██╗██║╚██╗██║")
    print("    ╚██████╗██║  ██║██║██║        ██║   ███████╗██║  ██║██║ ╚████║")
    print("     ╚═════╝╚═╝  ╚═╝╚═╝╚═╝        ╚═╝   ╚══════╝╚═╝  ╚═╝╚═╝  ╚═══╝")
    print(f"{C_RESET}")
    print(f"          {bold('VPN Manager v1.1')}    {dim('by CRISDEV / @CRISIS1823')}")
    print()


def menu_item(number: int, label: str, col_width: int = 33, destructive: bool = False) -> str:
    prefix = f"{number})"
    if destructive:
        return f"    {error(f'{bold(prefix)} {label}'):<{col_width}}"
    return f"    {bold(prefix)} {label:<{col_width - len(prefix) - 1}}"


def menu_item_right(number: int, label: str, col_width: int = 22) -> str:
    prefix = f"{number})"
    return f"{bold(prefix)} {label:<{col_width - len(prefix) - 1}}"
