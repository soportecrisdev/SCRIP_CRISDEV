#!/usr/bin/env bash
set -Euo pipefail

MANAGER_VERSION="2.5.5-wakkodev"
ENGINE_VERSION="2.4.1-btun-compat-keepalive"
TITLE="WakkoDev BHTTP"
AMD64_URL="https://www.dropbox.com/scl/fi/xe5uut31ybiiwpio8njlp/wakkodev-bhttp-server-amd64?rlkey=9f92nqgiezysxoq4xjta4lpfc&st=8ezemtuj&dl=1"
ARM64_URL="https://www.dropbox.com/scl/fi/h3pruw07ecgh4iph24gbm/wakkodev-bhttp-server-arm64?rlkey=hzmvl36pl50k7d9qqkgi4ltzz&st=fs95gvtz&dl=1"

SERVICE="wakkodev-bhttp.service"
BIN="/usr/local/bin/wakkodev-bhttp-server"
MANAGER_BIN="/usr/local/sbin/wakkodev-bhttp-manager"
MENU_BIN="/usr/local/bin/bhttp"
BASE="/etc/wakkodev-bhttp"
CONFIG="$BASE/config"
LEGACY_CONFIG="/etc/wakkodev-bhttp.conf"
UNIT="/etc/systemd/system/$SERVICE"
SYSCTL_FILE="/etc/sysctl.d/99-wakkodev-bhttp-performance.conf"
BACKUP_DIR="/var/backups/wakkodev-bhttp"
EXTRA_UNIT_PREFIX="/etc/systemd/system/wakkodev-bhttp-port"

AMD64_FILE="wakkodev-bhttp-server-amd64"
ARM64_FILE="wakkodev-bhttp-server-arm64"
AMD64_SHA="45b091bc3fdcc33335cba60ff1a128aefa9884dfb6fd7fe50e4c0edbb361a13f"
ARM64_SHA="01ed7e655b6f206d25a72bb40ae8774aef3aed2c889f2f997ff50f3e0c02d3b1"

red='\033[1;31m'; green='\033[1;32m'; cyan='\033[1;36m'; yellow='\033[1;33m'; blue='\033[1;34m'; dim='\033[2m'; reset='\033[0m'

ok(){ printf '%b✔%b %s\n' "$green" "$reset" "$*"; }
info(){ printf '%bℹ%b %s\n' "$cyan" "$reset" "$*"; }
warn(){ printf '%b⚠%b %s\n' "$yellow" "$reset" "$*"; }
fail(){ printf '%b✘%b %s\n' "$red" "$reset" "$*" >&2; }
have(){ command -v "$1" >/dev/null 2>&1; }
need_root(){ [ "${EUID:-$(id -u)}" -eq 0 ] || { fail "Ejecuta como root/sudo."; exit 1; }; }
interactive_tty_ready(){ [ -c /dev/tty ] && { : </dev/tty; } 2>/dev/null; }
require_tty(){ interactive_tty_ready || { fail "Esta acción necesita una terminal interactiva (/dev/tty)."; return 1; }; }
prompt_read(){ local __v="$1" __p="$2"; require_tty || return 1; IFS= read -r -p "$__p" "$__v" </dev/tty; }
pause(){ echo; prompt_read _ "Presiona ENTER para continuar..." || true; }
valid_port(){ [[ "${1:-}" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
valid_uint(){ [[ "${1:-}" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ]; }
normalize_ports(){
  local raw="${1:-}" p out=""
  raw="${raw//,/ }"
  for p in $raw; do
    valid_port "$p" || continue
    case " $out " in *" $p "*) ;; *) out="${out:+$out }$p";; esac
  done
  printf '%s' "$out"
}
list_has_port(){ case " ${1:-} " in *" $2 "*) return 0;; *) return 1;; esac; }
list_add_port(){
  local list; list="$(normalize_ports "${1:-}")"
  if list_has_port "$list" "$2"; then printf '%s' "$list"; else printf '%s' "${list:+$list }$2"; fi
}
list_remove_port(){
  local list p out=""; list="$(normalize_ports "${1:-}")"
  for p in $list; do [ "$p" = "$2" ] || out="${out:+$out }$p"; done
  printf '%s' "$out"
}
extra_unit_path(){ printf '%s-%s.service' "$EXTRA_UNIT_PREFIX" "$1"; }

engine_url(){ case "$(arch_name)" in amd64) printf '%s' "$AMD64_URL";; arm64) printf '%s' "$ARM64_URL";; *) printf '';; esac; }
arch_name(){ case "$(uname -m)" in x86_64|amd64) echo amd64;; aarch64|arm64) echo arm64;; *) echo unsupported;; esac; }
engine_filename(){ case "$(arch_name)" in amd64) echo "$AMD64_FILE";; arm64) echo "$ARM64_FILE";; *) echo "";; esac; }
expected_sha(){ case "$(arch_name)" in amd64) echo "$AMD64_SHA";; arm64) echo "$ARM64_SHA";; *) echo "";; esac; }

mem_mb(){ awk '/MemTotal:/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 1024; }
adaptive_sessions(){
  local m; m="$(mem_mb)"
  if [ "$m" -lt 768 ]; then echo 512
  elif [ "$m" -lt 1536 ]; then echo 1024
  elif [ "$m" -lt 3072 ]; then echo 2048
  elif [ "$m" -lt 6144 ]; then echo 4096
  else echo 8192
  fi
}

load_config(){
  BHTTP_PORT=""; BACKEND_PORT=22; SESSION_TTL=180; MAX_SESSIONS="$(adaptive_sessions)"; PROFILE="performance"
  UFW_RULE_ADDED=0; UFW_RULE_PORT=""; FIREWALLD_RULE_ADDED=0; FIREWALLD_RULE_PORT=""
  EXTRA_PORTS=""; EXTRA_UFW_PORTS=""; EXTRA_FIREWALLD_PORTS=""
  if [ -r "$LEGACY_CONFIG" ]; then
    . "$LEGACY_CONFIG" 2>/dev/null || true
  fi
  if [ -r "$CONFIG" ]; then
    . "$CONFIG" 2>/dev/null || true
  fi
  if [ -n "${BHTTP_PORT:-}" ]; then valid_port "$BHTTP_PORT" || BHTTP_PORT=""; fi
  valid_port "${BACKEND_PORT:-}" || BACKEND_PORT=22
  valid_uint "${SESSION_TTL:-}" || SESSION_TTL=180
  valid_uint "${MAX_SESSIONS:-}" || MAX_SESSIONS="$(adaptive_sessions)"
  EXTRA_PORTS="$(normalize_ports "${EXTRA_PORTS:-}")"
  EXTRA_UFW_PORTS="$(normalize_ports "${EXTRA_UFW_PORTS:-}")"
  EXTRA_FIREWALLD_PORTS="$(normalize_ports "${EXTRA_FIREWALLD_PORTS:-}")"
  local auto; auto="$(adaptive_sessions)"
  if [ "$MAX_SESSIONS" -eq 1024 ] && [ "$auto" -gt 1024 ]; then MAX_SESSIONS="$auto"; fi
}

save_config(){
  mkdir -p "$BASE"
  cat > "$CONFIG" <<EOF
BHTTP_PORT=$BHTTP_PORT
BACKEND_PORT=$BACKEND_PORT
SESSION_TTL=$SESSION_TTL
MAX_SESSIONS=$MAX_SESSIONS
PROFILE=$PROFILE
UFW_RULE_ADDED=$UFW_RULE_ADDED
UFW_RULE_PORT=${UFW_RULE_PORT:-}
FIREWALLD_RULE_ADDED=$FIREWALLD_RULE_ADDED
FIREWALLD_RULE_PORT=${FIREWALLD_RULE_PORT:-}
EXTRA_PORTS="${EXTRA_PORTS:-}"
EXTRA_UFW_PORTS="${EXTRA_UFW_PORTS:-}"
EXTRA_FIREWALLD_PORTS="${EXTRA_FIREWALLD_PORTS:-}"
EOF
  chmod 600 "$CONFIG"
  cat > "$LEGACY_CONFIG" <<EOF
BHTTP_PORT=$BHTTP_PORT
BACKEND_PORT=$BACKEND_PORT
SESSION_TTL=$SESSION_TTL
MAX_SESSIONS=$MAX_SESSIONS
EOF
  chmod 600 "$LEGACY_CONFIG"
}

pkg_install_fast(){
  local pkgs=("$@")
  if have apt-get; then
    if DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${pkgs[@]}" >/dev/null 2>&1; then return 0; fi
    DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${pkgs[@]}" >/dev/null
  elif have dnf; then dnf install -y "${pkgs[@]}" >/dev/null
  elif have yum; then yum install -y "${pkgs[@]}" >/dev/null
  else fail "No se detectó apt, dnf ni yum."; return 1
  fi
}

ensure_deps(){
  local missing=0 c
  for c in curl sha256sum systemctl ss sysctl awk grep sed; do have "$c" || missing=1; done
  [ "$missing" -eq 0 ] && return 0
  info "Instalando dependencias mínimas faltantes..."
  if have apt-get; then pkg_install_fast ca-certificates curl coreutils iproute2 procps gawk grep sed
  else pkg_install_fast ca-certificates curl coreutils iproute procps-ng gawk grep sed
  fi
}

apply_performance_tuning(){
  need_root
  info "Aplicando perfil BHTTP HIGH PERFORMANCE + STABILITY..."
  mkdir -p /etc/sysctl.d
  cat > "$SYSCTL_FILE" <<'EOF'
# CRISDEV / WakkoDev BHTTP - ajustes de estabilidad y red
fs.file-max = 1048576
net.core.somaxconn = 16384
net.core.netdev_max_backlog = 16384
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 131072 16777216
net.ipv4.tcp_wmem = 4096 131072 16777216
net.ipv4.ip_local_port_range = 10240 65535
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.tcp_max_tw_buckets = 262144
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 4
net.ipv4.tcp_mtu_probing = 1
EOF
  if have modprobe; then modprobe tcp_bbr >/dev/null 2>&1 || true; fi
  sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1 || true
  ok "Perfil de red aplicado exitosamente."
}

write_unit(){
  load_config; save_config
  if [ -z "${BHTTP_PORT:-}" ]; then
    systemctl disable --now "$SERVICE" >/dev/null 2>&1 || true
    rm -f "$UNIT"
    systemctl daemon-reload >/dev/null 2>&1 || true
    return 0
  fi
  cat > "$UNIT" <<EOF
[Unit]
Description=CRISDEV BHTTP Relay Service - engine $ENGINE_VERSION
After=network-online.target ssh.service sshd.service
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
EnvironmentFile=-$CONFIG
ExecStart=$BIN --listen 0.0.0.0 --port \${BHTTP_PORT} --backend-host 127.0.0.1 --backend-port \${BACKEND_PORT} --session-ttl \${SESSION_TTL} --max-sessions \${MAX_SESSIONS} --request-timeout 30 --read-wait-ms 2 --sequence-wait 6 --max-requests-per-conn 2048
Restart=always
RestartSec=1
TimeoutStopSec=15
KillSignal=SIGTERM
LimitNOFILE=524288
LimitNPROC=131072
TasksMax=infinity
OOMScoreAdjust=-300

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "$SERVICE" >/dev/null
}

write_extra_unit(){
  local p="$1" unit
  unit="$(extra_unit_path "$p")"
  cat > "$unit" <<EOF
[Unit]
Description=CRISDEV BHTTP Extra Port $p - engine $ENGINE_VERSION
After=network-online.target ssh.service sshd.service
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
EnvironmentFile=-$CONFIG
ExecStart=$BIN --listen 0.0.0.0 --port $p --backend-host 127.0.0.1 --backend-port \${BACKEND_PORT} --session-ttl \${SESSION_TTL} --max-sessions \${MAX_SESSIONS} --request-timeout 30 --read-wait-ms 2 --sequence-wait 6 --max-requests-per-conn 2048
Restart=always
RestartSec=1
TimeoutStopSec=15
KillSignal=SIGTERM
LimitNOFILE=524288
LimitNPROC=131072
TasksMax=infinity
OOMScoreAdjust=-300

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "$(basename "$unit")" >/dev/null
}
