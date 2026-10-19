#!/usr/bin/env bash
set -euo pipefail

# Wrapper de compatibilidad para compilar el motor nativo BHTTP/XHTTP
# (libbhttpjni.so).
#
# ANTES este script delegaba en btun-offline/BTUN/sources/bilola_go_port, que es
# una copia PRE-V2 del motor: compilaba un .so sin los exports
# Java_com_btun_client_GoBhttpV2Bridge_*, y en runtime la app caia siempre al
# fallback Java con "No implementation found for ... GoBhttpV2Bridge".
#
# Ahora delega en el script canonico de la raiz del proyecto, que apunta a la
# fuente V2 (BHTTP_CRISDEV/sources/bilola_go_port) e incluye un gate que aborta
# si el .so resultante no exporta el motor V2.
#
# Uso:
#   bash build_jni.sh [NDK_ROOT]
#
# Ver build_bhttp_ndk.sh en la raiz para el detalle de flags y autodeteccion.

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
canonical="$repo_root/build_bhttp_ndk.sh"

if [[ ! -f "$canonical" ]]; then
    echo "[ERROR] No se encontró el script canónico: $canonical" >&2
    exit 1
fi

echo "=== Delegando en $canonical (fuente V2 + gate de símbolos) ==="

# El script canonico lee NDK de ANDROID_NDK_ROOT / ANDROID_NDK_HOME; si el
# llamador paso una ruta explicita, se respeta.
if [[ $# -ge 1 && -n "${1:-}" ]]; then
    export ANDROID_NDK_ROOT="$1"
    export ANDROID_NDK_HOME="$1"
    echo "    NDK forzado por el llamador: $1"
fi

exec bash "$canonical"