"""
CRISDEV VPN Manager - UI Components
====================================
Funciones reutilizables para renderizar la interfaz.
Ningun modulo de logica de negocio debe hacer print() directo —
todos usan estas funciones.
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
# HELPERS DE COLOR — Funciones basicas
# ============================================================================

def bold(text: str) -> str:
    """Texto en negrita."""
    return f"{C_BOLD}{text}{C_RESET}"

def ok(text: str) -> str:
    """Texto verde (activo/OK/exito)."""
    return f"{C_OK}{text}{C_RESET}"

def error(text: str) -> str:
    """Texto rojo (expirado/bloqueado/destructivo)."""
    return f"{C_ERROR}{text}{C_RESET}"

def warn(text: str) -> str:
    """Texto amarillo (advertencia/atencion)."""
    return f"{C_WARN}{text}{C_RESET}"

def info(text: str) -> str:
    """Texto cyan (informacion neutra)."""
    return f"{C_INFO}{text}{C_RESET}"

def dim(text: str) -> str:
    """Texto gris apagado (secundario)."""
    return f"{C_DIM}{text}{C_RESET}"


# ============================================================================
# HELPERS DE SISTEMA
# ============================================================================

def clear_screen():
    """Limpia la pantalla de la terminal."""
    os.system("cls" if os.name == "nt" else "clear")

def get_server_ip() -> str:
    """Obtiene la IP publica del servidor."""
    try:
        result = subprocess.run(
            ["curl", "-s4", "--max-time", "5", "ifconfig.me"],
            capture_output=True, text=True, timeout=10
        )
        ip = result.stdout.strip()
        if ip:
            return ip
    except Exception:
        pass
    try:
        result = subprocess.run(
            ["hostname", "-I"], capture_output=True, text=True, timeout=5
        )
        return result.stdout.strip().split()[0]
    except Exception:
        return "?.?.?.?"

def get_server_os() -> str:
    """Obtiene el nombre del OS."""
    try:
        with open("/etc/os-release") as f:
            for line in f:
                if line.startswith("PRETTY_NAME="):
                    return line.split("=", 1)[1].strip().strip('"')
    except Exception:
        pass
    return "Linux"

def get_uptime() -> str:
    """Obtiene el uptime del servidor."""
    try:
        result = subprocess.run(["uptime", "-p"], capture_output=True, text=True, timeout=5)
        return result.stdout.strip()
    except Exception:
        return "N/A"

def check_service_status(service: str) -> str:
    """Retorna 'active', 'inactive', 'dead' o 'not-found'."""
    try:
        result = subprocess.run(
            ["systemctl", "is-active", service],
            capture_output=True, text=True, timeout=5
        )
        return result.stdout.strip()
    except Exception:
        return "not-found"

def check_service_latency(service: str, port: Optional[int] = None) -> Optional[int]:
    """
    Mide latencia real de un servicio (ms).
    Retorna None si no se pudo medir.
    """
    if port:
        try:
            result = subprocess.run(
                ["bash", "-c", f"echo > /dev/tcp/127.0.0.1/{port}"],
                capture_output=True, text=True, timeout=3
            )
            if result.returncode == 0:
                # Medir con curl para latencia real
                result2 = subprocess.run(
                    ["curl", "-so", "/dev/null", "-w", "%{time_total}",
                     f"http://127.0.0.1:{port}/"],
                    capture_output=True, text=True, timeout=5
                )
                if result2.returncode == 0:
                    ms = int(float(result2.stdout.strip()) * 1000)
                    return ms
        except Exception:
            pass
    return None

def get_user_stats(users_db: str) -> dict:
    """
    Retorna estadisticas de usuarios desde la base de datos JSON.
    Retorna dict con: total, active, expiring_soon, suspended, expired
    """
    stats = {"total": 0, "active": 0, "expiring_soon": 0, "suspended": 0, "expired": 0}
    try:
        with open(users_db) as f:
            users = json.load(f)
        stats["total"] = len(users)
        now = datetime.now()
        for u in users:
            status = u.get("status", "active")
            if status == "suspended":
                stats["suspended"] += 1
            elif status == "active":
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
            elif status == "expired":
                stats["expired"] += 1
    except (FileNotFoundError, json.JSONDecodeError):
        pass
    return stats


# ============================================================================
# COMPONENTES DE INTERFAZ
# ============================================================================

def header():
    """
    Encabezado compacto — se repite en TODAS las pantallas internas.
    3 lineas fijas, sin banner ASCII.
    """
    ip = get_server_ip()
    os_name = get_server_os()[:20]
    date_str = datetime.now().strftime("%d-%m-%Y %H:%M")
    print(f"{C_INFO}{'━' * 62}{C_RESET}")
    print(f" {bold('CRISDEV VPN MANAGER v1.1.0')}                    {dim('@CRISIS1823')}")
    print(f" IP: {bold(ip)}   |   {os_name}   |   {date_str}")
    print(f"{C_INFO}{'━' * 62}{C_RESET}")


def banner_welcome():
    """
    Banner ASCII grande — SOLO para la primera pantalla de bienvenida.
    """
    print()
    print(f"{C_BOLD}{C_INFO}")
    print("     ██████╗██████╗ ██╗██████╗ ████████╗███████╗██████╗ ███╗   ██╗")
    print("    ██╔════╝██╔══██╗██║██╔══██╗╚══██╔══╝██╔════╝██╔══██╗████╗  ██║")
    print("    ██║     ██████╔╝██║██████╔╝   ██║   █████╗  ██████╔╝██╔██╗ ██║")
    print("    ██║     ██╔══██╗██║██╔═══╝    ██║   ██╔══╝  ██╔══██╗██║╚██╗██║")
    print("    ╚██████╗██║  ██║██║██║        ██║   ███████╗██║  ██║██║ ╚████║")
    print("     ╚═════╝╚═╝  ╚═╝╚═╝╚═╝        ╚═╝   ╚══════╝╚═╝  ╚═╝╚═╝  ╚═══╝")
    print(f"{C_RESET}")
    print(f"          {bold('VPN Manager v1.1.0')}    {dim('by CRISDEV / @CRISIS1823')}")
    print()


def dashboard(users_db: str):
    """
    Panel de estado en vivo — siempre debajo del encabezado en el menu principal.
    Muestra: activos/expirados/suspendidos/bloqueados y servicios con latencia.
    """
    stats = get_user_stats(users_db)
    print()

    # Contadores de usuarios
    total = stats["total"]
    active = stats["active"]
    expiring = stats["expiring_soon"]
    suspended = stats["suspended"]

    # Linea de usuarios
    exp_str = f" {warn(f'({expiring} vencen en <3d)')}" if expiring > 0 else ""
    print(
        f"  {bold('USUARIOS')}  "
        f"{ok(f'ACTIVOS: {active}')}{exp_str}  "
        f"{error(f'SUSPENDIDOS: {suspended}')}  "
        f"TOTAL: {total}"
    )

    # Servicios con indicador y latencia
    services = [
        ("xray", 2053),
        ("hysteria-server", 443),
        ("stunnel4", 443),
        ("udp-custom", 7100),
        ("sshd", 22),
    ]
    parts = []
    for svc_name, port in services:
        status = check_service_status(svc_name)
        if status == "active":
            lat = check_service_latency(svc_name, port)
            if lat:
                parts.append(f"{ok('●')}{svc_name}{dim(f' ({lat}ms)')}")
            else:
                parts.append(f"{ok('●')}{svc_name}")
        else:
            parts.append(f"{error('○')}{svc_name}")

    print(f"  {bold('SERVICOS')}  {' '.join(parts)}")
    print()


def section(title: str):
    """Encabezado de seccion del menu."""
    print(f"  {bold(f'{C_INFO}{title}{C_RESET}')}")


def separator():
    """Linea separadora visual."""
    print(f"  {dim('─' * 52)}")


def menu_item(number: int, label: str, col_width: int = 33, destructive: bool = False) -> str:
    """
    Retorna un string de item de menu alineado.
    - number: numero de la opcion
    - label: texto de la opcion
    - col_width: ancho fijo de la columna izquierda
    - destructive: si es True, se muestra en rojo
    """
    prefix = f"{number})"
    if destructive:
        return f"    {error(f'{bold(prefix)} {label}'):<{col_width}}"
    return f"    {bold(prefix)} {label:<{col_width - len(prefix) - 1}}"


def menu_item_right(number: int, label: str, col_width: int = 22) -> str:
    """Item de menu para la columna derecha (2 columnas)."""
    prefix = f"{number})"
    return f"{bold(prefix)} {label:<{col_width - len(prefix) - 1}}"


def two_col_menu(left_items: list, right_items: list, col_width_left: int = 33):
    """
    Renderiza un menu en 2 columnas alineadas.
    left_items: [(number, label), ...]
    right_items: [(number, label), ...]
    """
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


def prompt_input(message: str = "Ingresa una opcion") -> str:
    """Prompt de entrada con estilo."""
    print()
    try:
        return input(f"  {C_PROMPT}{message}: {C_RESET}").strip()
    except (EOFError, KeyboardInterrupt):
        return ""


def confirm_destructive(message: str) -> bool:
    """
    Confirmacion de doble paso para acciones destructivas.
    Requiere escribir literalmente 'SI' en mayusculas.
    Fondo visual rojo para distinguir de prompts normales.
    """
    print()
    print(f"  {C_BOLD}{C_ERROR}╔══════════════════════════════════════════════════╗{C_RESET}")
    print(f"  {C_BOLD}{C_ERROR}║  ⚠  ACCION DESTRUCTIVA                         ║{C_RESET}")
    print(f"  {C_ERROR}║{C_RESET}  {message}")
    print(f"  {C_BOLD}{C_ERROR}╚══════════════════════════════════════════════════╝{C_RESET}")
    print()
    try:
        resp = input(f"  {C_ERROR}Escribe {bold('SI')} para confirmar: {C_RESET}").strip()
    except (EOFError, KeyboardInterrupt):
        return False
    return resp == "SI"


def breadcrumb(path: str):
    """Breadcrumb de navegacion en submenus."""
    print()
    print(f"  {dim(path)}")
    print()


def pause():
    """Espera a que el usuario presione Enter."""
    print()
    try:
        input(f"  {dim('Presiona Enter para continuar...')}")
    except (EOFError, KeyboardInterrupt):
        pass


def ok_msg(message: str):
    """Mensaje de exito."""
    print(f"  {ok('[OK]')} {message}")

def error_msg(message: str):
    """Mensaje de error."""
    print(f"  {error('[ERROR]')} {message}")

def info_msg(message: str):
    """Mensaje informativo."""
    print(f"  {ok('[INFO]')} {message}")

def warn_msg(message: str):
    """Mensaje de advertencia."""
    print(f"  {warn('[WARN]')} {message}")


# ============================================================================
# TABLA DE USUARIOS
# ============================================================================

def user_table(users: list, show_all: bool = False):
    """
    Renderiza la tabla de usuarios con colores semanticos.
    users: lista de dicts del JSON
    """
    print()
    # Headers con ancho fijo
    header_str = (
        f"  {bold('USUARIO'):<15} "
        f"{bold('ESTADO'):<12} "
        f"{bold('EXPIRA'):<14} "
        f"{bold('MAX'):<6} "
        f"{bold('PROTOCOLOS')}"
    )
    print(header_str)
    print(f"  {dim('─' * 65)}")

    for u in users:
        username = u.get("username", "?")
        status = u.get("status", "unknown")
        expires = u.get("expires_at", "N/A")
        max_conn = u.get("max_connections", 0)
        protocols = u.get("protocols", [])

        # Color por estado
        if status == "active":
            status_display = ok("active")
        elif status == "suspended":
            status_display = warn("suspended")
        else:
            status_display = error(status)

        # Protocolos como string abreviado
        proto_str = ", ".join(protocols) if isinstance(protocols, list) else str(protocols)

        # Truncar protocolos si es muy largo
        if len(proto_str) > 25:
            proto_str = proto_str[:22] + "..."

        print(
            f"  {username:<15} "
            f"{status_display:<22} "  # 12 chars + color codes
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
    """Renderiza el detalle de un usuario como tarjeta visual."""
    print()
    print(f"  {C_BOLD}{C_INFO}┌─────────────────────────────────────────────┐{C_RESET}")
    print(f"  {C_BOLD}{C_INFO}│  DETALLE DE USUARIO                         │{C_RESET}")
    print(f"  {C_BOLD}{C_INFO}└─────────────────────────────────────────────┘{C_RESET}")
    print()
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
    """Tabla de estado de servicios con indicador visual y latencia."""
    print()
    print(f"  {bold('Servicio'):<20} {bold('Estado'):<12} {bold('Latencia')}")
    print(f"  {dim('─' * 45)}")

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
