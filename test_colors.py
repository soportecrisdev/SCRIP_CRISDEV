#!/usr/bin/env python3
"""
CRISDEV VPN Manager - Test de Colores ANSI
Ejecuta: python3 test_colors.py
Si ves colores y NO ves \\033 como texto, todo funciona.
"""
import sys
import os

# Agregar directorio actual al path
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ui.theme import C_OK, C_ERROR, C_WARN, C_INFO, C_DIM, C_BOLD, C_RESET, ESC
from ui.components import bold, ok, error, warn, info, dim

print("=" * 60)
print("  CRISDEV - TEST DE COLORES ANSI")
print("=" * 60)
print()

# Test 1: Verificar que ESC es el caracter real
print(f"Test 1: ESC character = ord({ord(ESC)}) (debe ser 27)")
if ord(ESC) == 27:
    print(f"  {ok('PASS')} ESC es el caracter real (27)")
else:
    print(f"  {error('FAIL')} ESC NO es el caracter real")
    sys.exit(1)

# Test 2: Verificar longitud de colores
print(f"\nTest 2: Longitud de C_OK = {len(C_OK)} (debe ser 5)")
if len(C_OK) == 5:
    print(f"  {ok('PASS')} Longitud correcta")
else:
    print(f"  {error('FAIL')} Longitud incorrecta")
    sys.exit(1)

# Test 3: Imprimir cada color directamente
print(f"\nTest 3: Colores directos:")
print(f"  {C_OK}> C_OK (verde - activo/OK){C_RESET}")
print(f"  {C_ERROR}> C_ERROR (rojo - destruir/expirado){C_RESET}")
print(f"  {C_WARN}> C_WARN (amarillo - advertencia){C_RESET}")
print(f"  {C_INFO}> C_INFO (cyan - informacion){C_RESET}")
print(f"  {C_DIM}> C_DIM (gris - secundario){C_RESET}")
print(f"  {C_BOLD}> C_BOLD (negrita - titulos){C_RESET}")

# Test 4: Funciones helper
print(f"\nTest 4: Funciones helper:")
print(f"  {bold('Texto en negrita')}")
print(f"  {ok('Texto verde (OK)')}")
print(f"  {error('Texto rojo (ERROR)')}")
print(f"  {warn('Texto amarillo (WARN)')}")
print(f"  {info('Texto cyan (INFO)')}")
print(f"  {dim('Texto gris (DIM)')}")

# Test 5: Ejemplo de menu
print(f"\nTest 5: Ejemplo de menu:")
print(f"  {bold('USUARIOS')}")
print(f"    {bold('1)')} Crear usuario          {bold('5)')} Reactivar usuario")
print(f"    {bold('2)')} Editar usuario         {bold('6)')} Renovar usuario")
print(f"    {bold('3)')} {error('Eliminar usuario')}{C_RESET}       {bold('7)')} Listar usuarios")
print(f"    {bold('4)')} Suspender usuario")
print()
print(f"  {bold('PROTOCOLOS')}")
print(f"    {bold('8)')} SSH / SSH-SSL          {bold('11)')} Hysteria2")
print(f"    {bold('9)')} SlowDNS                {bold('12)')} udp-custom")
print(f"    {bold('10)')} Xray (VLESS/VMess/Trojan)")
print()
print(f"  {bold('SALIDA')}")
print(f"    {error('[0] Salir del script')}              {warn('[9] Reiniciar VPS')}")

# Test 6: Confirmacion destructiva
print(f"\nTest 6: Confirmacion destructiva:")
print(f"  {C_BOLD}{C_ERROR}╔══════════════════════════════════════════════════╗{C_RESET}")
print(f"  {C_BOLD}{C_ERROR}║  ⚠  ACCION DESTRUCTIVA                         ║{C_RESET}")
print(f"  {C_ERROR}║{C_RESET}  Eliminar usuario permanentemente?")
print(f"  {C_BOLD}{C_ERROR}╚══════════════════════════════════════════════════╝{C_RESET}")
print(f"  {C_ERROR}Escribe {bold('SI')} para confirmar: {C_RESET}(no se ejecuta, es demo)")

print()
print("=" * 60)
print(f"  {ok('TEST COMPLETADO')}")
print("  Si ves colores arriba (no \\033 como texto), todo funciona.")
print("=" * 60)
