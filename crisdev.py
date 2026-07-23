#!/usr/bin/env python3
"""
CRISDEV VPN Manager
===================
Panel de administración VPN para servidores Ubuntu 22.04.
Ejecutar: python3 crisdev.py
"""
import sys
import os

# Ensure the script's directory is in the path for ui/ imports
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
