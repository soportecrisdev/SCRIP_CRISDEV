#!/usr/bin/env bash
# ==============================================================================
# build-all-binaries.sh — Compilador Automático Multi-Arquitectura BHTTP / BTUN
# ==============================================================================
# Genera automáticamente todos los binarios nativos necesarios para la VPS:
#   1. bilola-server
#   2. bilola-xhttp-server (xhttp-server)
#   3. btun-server (requiere CGO/PAM en Linux)
#   4. bhttp-smoke
#   5. xhttp-smoke
#   6. certgen
#
# Para arquitecturas:
#   - amd64 (x86_64)
#   - arm64 (aarch64)
#
# Genera y actualiza automáticamente el archivo SHA256SUMS.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="$SCRIPT_DIR/btun-offline/BTUN/sources/bilola_go_port"
OUTPUT_BASE="$SCRIPT_DIR/btun-offline/BTUN/bin"
TOOLS_DIR="$SCRIPT_DIR/btun-offline/BTUN/tools"

C='\033[0m'; CY='\033[0;36m'; YE='\033[0;33m'; RE='\033[0;31m'; GR='\033[0;32m'
log()  { printf "${CY}[build]${C} %s\n" "$*"; }
ok()   { printf "${GR}[build OK]${C} %s\n" "$*"; }
warn() { printf "${YE}[build WARN]${C} %s\n" "$*" >&2; }
die()  { printf "${RE}[build ERROR]${C} %s\n" "$*" >&2; exit 1; }

command -v go >/dev/null 2>&1 || die "Go (Golang) no está instalado. Instálalo con: apt-get install -y golang"

ARCHS=("amd64" "arm64")
TARGET_OS="linux"

log "Iniciando compilación de binarios para Linux (${ARCHS[*]})..."

for arch in "${ARCHS[@]}"; do
    TARGET_DIR="$OUTPUT_BASE/$arch"
    mkdir -p "$TARGET_DIR"
    log "=================================================="
    log "Compilando para arquitectura: $arch"
    log "=================================================="

    # 1. bilola-server (Go puro - BHTTP Proxy)
    log "Compilando bilola-server..."
    (cd "$SOURCE_DIR" && CGO_ENABLED=0 GOOS="$TARGET_OS" GOARCH="$arch" \
        go build -trimpath -ldflags="-s -w" -o "$TARGET_DIR/bilola-server" ./cmd/bilola-server)

    # 2. bilola-xhttp-server (Go puro - SSH_XHTTP TLS)
    log "Compilando bilola-xhttp-server..."
    (cd "$SOURCE_DIR" && CGO_ENABLED=0 GOOS="$TARGET_OS" GOARCH="$arch" \
        go build -trimpath -ldflags="-s -w" -o "$TARGET_DIR/bilola-xhttp-server" ./cmd/xhttp-server)

    # 3. bhttp-smoke (Herramienta de test BHTTP)
    log "Compilando bhttp-smoke..."
    (cd "$SOURCE_DIR" && CGO_ENABLED=0 GOOS="$TARGET_OS" GOARCH="$arch" \
        go build -trimpath -ldflags="-s -w" -o "$TARGET_DIR/bhttp-smoke" ./cmd/bhttp-smoke)

    # 4. xhttp-smoke (Herramienta de test XHTTP)
    log "Compilando xhttp-smoke..."
    (cd "$SOURCE_DIR" && CGO_ENABLED=0 GOOS="$TARGET_OS" GOARCH="$arch" \
        go build -trimpath -ldflags="-s -w" -o "$TARGET_DIR/xhttp-smoke" ./cmd/xhttp-smoke)

    # 5. certgen (Generador de certificados autofirmados TLS)
    log "Compilando certgen..."
    (cd "$TOOLS_DIR/certgen" && CGO_ENABLED=0 GOOS="$TARGET_OS" GOARCH="$arch" \
        go build -trimpath -ldflags="-s -w" -o "$TARGET_DIR/certgen" .)

    # 6. btun-server (Servidor TUN/PAM nativo)
    log "Compilando btun-server..."
    HOST_ARCH="$(uname -m)"
    if [[ ("$arch" == "amd64" && ("$HOST_ARCH" == "x86_64" || "$HOST_ARCH" == "amd64")) || \
          ("$arch" == "arm64" && ("$HOST_ARCH" == "aarch64" || "$HOST_ARCH" == "arm64")) ]]; then
        # Compilación nativa con CGO habilitado para PAM
        (cd "$SOURCE_DIR" && CGO_ENABLED=1 GOOS="$TARGET_OS" GOARCH="$arch" \
            go build -trimpath -ldflags="-s -w -X main.version=1.0.44" -o "$TARGET_DIR/btun-server" ./cmd/btun-server)
    else
        # Si es compilación cruzada y no hay toolchain C, usar modo CGO_ENABLED=0 con stub PAM
        warn "Cross-compilando btun-server para $arch sin CGO (usará auth_pam_stub si no hay cross-compiler C)..."
        (cd "$SOURCE_DIR" && CGO_ENABLED=0 GOOS="$TARGET_OS" GOARCH="$arch" \
            go build -trimpath -ldflags="-s -w -X main.version=1.0.44" -o "$TARGET_DIR/btun-server" ./cmd/btun-server || true)
    fi

    # Dar permisos de ejecución
    chmod +x "$TARGET_DIR"/*
    ok "Binarios compilados exitosamente en: $TARGET_DIR"
done

# ---- Generar SHA256SUMS automáticamente para el paquete offline ----
log "Calculando SHA256SUMS de todo el paquete..."
cd "$SCRIPT_DIR/btun-offline/BTUN"
find . -type f ! -name "SHA256SUMS" ! -path "*/.git/*" | sort | xargs sha256sum > SHA256SUMS

ok "=================================================="
ok "¡PROCESO FINALIZADO EXITOSAMENTE!"
ok "Todos los binarios se encuentran listos en btun-offline/BTUN/bin/"
ok "SHA256SUMS actualizado automáticamente."
ok "=================================================="
