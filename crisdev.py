#!/usr/bin/env python3
"""
CRISDEV VPN Manager
===================
Panel de administracion VPN para servidores Ubuntu 22.04.
Ejecutar: python3 crisdev.py
"""
import sys
import os

os.environ["TERM"] = os.environ.get("TERM", "xterm-256color")
os.environ["PYTHONIOENCODING"] = "utf-8"

# Limpiar cache de modulos para siempre cargar la ultima version
import importlib
for name in list(sys.modules.keys()):
    if name.startswith("ui.") or name == "ui" or name == "menu":
        del sys.modules[name]

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from menu import menu_main


if __name__ == "__main__":
    try:
        menu_main()
    except KeyboardInterrupt:
        print("\n\nSaliendo...")
        sys.exit(0)
    except Exception as e:
        print(f"\nError inesperado: {e}")
        sys.exit(1)
