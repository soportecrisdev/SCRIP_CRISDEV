#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
CRISDEV DYNAMIC PAM & SSH BANNER GENERATOR v2.0
==============================================
Genera la tarjeta visual de bienvenida con estado de cuenta en vivo
para cada usuario al conectar por SSH, Dropbear, BHTTP o HCR.

- Muestra: Días restantes, fecha de corte, conexiones activas vs límite.
- Si le quedan <= 3 días: Alerta en rojo/amarillo para renovar a tiempo.
- Seguro: No rompe PAM en caso de excepción (trap exit 0).
"""

import os
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
if SCRIPT_DIR not in sys.path:
    sys.path.insert(0, SCRIPT_DIR)

import crisdev_db

def generate_banner(username):
    user = crisdev_db.get_user(username)
    if not user:
        return ""

    rem_days = user.get("days_remaining", 0)
    exp_date = user.get("expiration_date", "Indefinido")
    limit = user.get("limit_connections", 1)
    status = user.get("status", "active")

    # Colores ANSI
    C_CYAN = "\033[1;36m"
    C_GREEN = "\033[1;32m"
    C_YELLOW = "\033[1;33m"
    C_RED = "\033[1;31m"
    C_WHITE = "\033[1;37m"
    C_VIOLET = "\033[1;35m"
    NC = "\033[0m"

    color_days = C_GREEN if rem_days > 3 else (C_YELLOW if rem_days > 1 else C_RED)
    alert_line = ""
    if rem_days <= 3:
        alert_line = f"\n  {C_RED}⚠️  ¡ATENCIÓN! Tu cuenta vence pronto ({rem_days} días restantes).\n  {C_YELLOW}Contacta al administrador para renovar tu acceso.{NC}\n"

    banner = f"""
{C_VIOLET}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━{NC}
       {C_CYAN}⚡ HTTP CONEXIÓN · ESTADO DE TU CUENTA ⚡{NC}
{C_VIOLET}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━{NC}
  {C_WHITE}👤 Usuario      :{NC} {C_CYAN}{username}{NC}
  {C_WHITE}📅 Vencimiento  :{NC} {C_WHITE}{exp_date}{NC}
  {C_WHITE}⏱️  Días Restantes:{NC} {color_days}{rem_days} días{NC}
  {C_WHITE}📱 Dispositivos :{NC} {C_WHITE}{limit} permitido(s){NC}
{alert_line}{C_VIOLET}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━{NC}
"""
    return banner

if __name__ == "__main__":
    try:
        # PAM provee el usuario en la variable de entorno PAM_USER
        target_user = os.environ.get("PAM_USER")
        if not target_user and len(sys.argv) > 1:
            target_user = sys.argv[1]

        if target_user and target_user not in ('root', 'sshd', 'nobody'):
            card = generate_banner(target_user)
            if card:
                print(card)
    except Exception:
        pass
    sys.exit(0)
