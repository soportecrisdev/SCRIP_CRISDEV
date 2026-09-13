#!/usr/bin/env bash
set -euo pipefail

# Wrapper para compilar el motor nativo BHTTP/XHTTP de DoriaXVPN (libbhttpjni.so).
# Delega en el script canónico del proyecto para mantener un único punto de build.
#
# Uso:
#   bash build_jni.sh [output_dir]
#
# Requiere:
#   - Go >= 1.21 (GOOS=android en el path)
#   - Clang del host (arm64 Linux) con NDK 26.1.10909125
#   - ANDROID_NDK_ROOT apuntando al NDK 26.1.10909125 (override por defecto)
#
# Genera libbhttpjni.so para las 4 ABIs: arm64-v8a, armeabi-v7a, x86_64 y x86.

script_dir="$(cd "$(dirname "$0")" && pwd)"

# Ruta canónica de las fuentes del motor Go.
engine_dir="$script_dir/btun-offline/BTUN/sources/bilola_go_port"

if [[ ! -f "$engine_dir/android/build_jni.sh" ]]; then
    echo "[ERROR] No se encontró el motor Go en: $engine_dir" >&2
    exit 1
fi

output="${1:-}"
if [[ -z "$output" ]]; then
    output="$script_dir/build/android-jni"
fi

echo "=== Compilando libbhttpjni.so (4 ABIs) desde $engine_dir ==="
mkdir -p "$output"

bash "$engine_dir/android/build_jni.sh" "$output"
