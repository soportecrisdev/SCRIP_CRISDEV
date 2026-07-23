"""
CRISDEV VPN Manager - Theme Module
===================================
Constantes de color y estilo centralizadas.
Ningun modulo de logica debe usar codigos ANSI directamente.
"""
import sys
import os

# ============================================================================
# DETECCION DE SOPORTE ANSI
# ============================================================================
# Windows necesita habilitar secuencias ANSI virtual (VT100) en la terminal.
# Linux/Mac lo soportan nativamente.

def _enable_ansi_windows():
    """Habilita soporte ANSI en Windows 10+ (terminal moderna)."""
    if sys.platform == "win32":
        try:
            import ctypes
            kernel32 = ctypes.windll.kernel32
            # STD_OUTPUT_HANDLE = -11
            handle = kernel32.GetStdHandle(-11)
            # ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0004
            mode = ctypes.c_ulong()
            kernel32.GetConsoleMode(handle, ctypes.byref(mode))
            kernel32.SetConsoleMode(handle, mode.value | 0x0004)
        except Exception:
            # Si falla, los colores no funcionaran pero el script no crashea
            pass

_enable_ansi_windows()

# Forzar UTF-8 en stdout para box-drawing chars y ANSI codes
if hasattr(sys.stdout, "reconfigure"):
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

# En Linux, asegurar que TERM soporta colores
if sys.platform != "win32":
    if "TERM" not in os.environ or os.environ["TERM"] == "dumb":
        os.environ["TERM"] = "xterm-256color"


# ============================================================================
# CODIGOS ANSI — CADA COLOR TIENE UN SIGNIFICADO FIJO
# ============================================================================
# CONVENCION (NO ROMPER):
#   Verde   = activo / OK / exito
#   Rojo    = expirado / bloqueado / detenido / accion destructiva
#   Amarillo= advertencia / por vencer / atencion
#   Cyan    = informacion neutra / encabezados de seccion
#   Gris    = texto secundario / deshabilitado
#   Negrita = titulos de bloque
#   Blanco  = prompt de entrada

ESC = chr(27)  # Caracter ESC real — chr(27) es infalible en cualquier Python

# Colores de texto
C_OK      = f"{ESC}[32m"      # Verde
C_ERROR   = f"{ESC}[31m"      # Rojo
C_WARN    = f"{ESC}[33m"      # Amarillo
C_INFO    = f"{ESC}[36m"      # Cyan
C_DIM     = f"{ESC}[2m"       # Gris apagado
C_BOLD    = f"{ESC}[1m"       # Negrita
C_ACCENT  = f"{ESC}[35m"      # Magenta (acento especial)
C_PROMPT  = f"{ESC}[1;37m"    # Blanco brillante (prompt)

# Reset
C_RESET   = f"{ESC}[0m"


# ============================================================================
# VERIFICACION DE INTEGRIDAD
# ============================================================================
def _verify_colors():
    """
    Verifica que los colores sean bytes reales, no strings literales.
    Si \033 se imprime como '\033' en vez de ESC, el modulo esta roto.
    """
    if len(C_OK) != 5:  # \033 + [32m = 5 chars reales
        raise RuntimeError(
            "ANSI colors not working. Check that strings use double quotes "
            "and NOT raw strings (r'...'). C_OK should be 5 characters."
        )
    # Verificar que ESC es el caracter real (codigo 27)
    if ord(ESC) != 27:
        raise RuntimeError(
            f"ESC character is wrong: ord={ord(ESC)}, expected 27. "
            f"This means \\033 is being escaped somewhere."
        )

_verify_colors()
