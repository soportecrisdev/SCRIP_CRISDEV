# CRISDEV VPN Manager v1.0

Script privada de administración VPN para VPS. Un solo comando `crisdev` con menú de texto completo, sin dependencias gráficas, corre por SSH en cualquier VPS mínimo.

**Autor:** CRISDEV / @CRISIS1823

---

## Requisitos del VPS

| Mínimo | Recomendado |
|---|---|
| 1 vCPU | 2+ vCPU |
| 1 GB RAM | 2+ GB RAM |
| 10 GB disco | 20+ GB disco |
| Ubuntu 20.04+ / Debian 11+ | Ubuntu 22.04 LTS |
| Puerto 22 abierto | Puerto 22 + 443 abiertos |

---

## Instalación en VPS nuevo

### Opción 1 — Una línea (recomendado)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/soportecrisdev/SCRIP_CRISDEV/main/install.sh)
```

Esto descarga todo desde GitHub, instala dependencias y ejecuta la configuración inicial con menú interactivo.

### Opción 2 — Clonar y ejecutar

```bash
git clone https://github.com/soportecrisdev/SCRIP_CRISDEV.git /opt/crisdev
cd /opt/crisdev
chmod +x crisdev.sh install.sh
./install.sh
```

### Opción 3 — Solo el script

```bash
wget https://raw.githubusercontent.com/soportecrisdev/SCRIP_CRISDEV/main/crisdev.sh
chmod +x crisdev.sh
./crisdev.sh --install
```

---

## Uso después de instalar

Una vez instalado, el comando `crisdev` queda disponible en cualquier parte:

```bash
crisdev          # Menú interactivo completo
crisdev --help   # Ver todos los comandos
crisdev --status # Estado rápido del servidor
crisdev --backup # Crear respaldo
crisdev --users  # Listar usuarios
```

---

## Menú principal

Al ejecutar `crisdev` se muestra el siguiente menú:

```
  MENÚ PRINCIPAL
───────────────────────────────────────

  USUARIOS
    1) Crear usuario
    2) Editar usuario
    3) Eliminar usuario
    4) Suspender usuario
    5) Reactivar usuario
    6) Renovar usuario
    7) Listar usuarios
    8) Ver detalle de usuario
    9) Buscar usuario

  PROTOCOLOS
   10) SSH / SSH-SSL
   11) SlowDNS
   12) Xray-core (VLESS/VMess/Trojan)
   13) Hysteria2
   14) udp-custom
   15) Generar links de conexión

  SERVIDOR
   16) Estado del servidor
   17) Consumo de ancho de banda
   18) Firewall
   19) Certificados TLS
   20) Modo pánico

  SISTEMA
   21) Backup
   22) Restaurar backup
   23) Verificar/actualizar versiones
   24) Logs de auditoría
   25) Logs de servicios
   26) Actualizar CRISDEV
```

---

## Protocolos y puertos

| Protocolo | Puerto | Transporte | Bypass DPI | Velocidad |
|---|---|---|---|---|
| SSH directo | 22, 80 | TCP | No | Básica |
| SSH-SSL (stunnel) | 443 | TCP/TLS | Sí | Media |
| Xray VLESS+WS+TLS | 2053 | TCP/TLS+WebSocket | Sí | Alta |
| Xray VLESS+gRPC+TLS | 2083 | TCP/TLS+gRPC | Sí | Alta |
| Xray VLESS+REALITY | 8443 | TCP | Sí (camuflaje) | Muy alta |
| Xray VMess+WS+TLS | 8880 | TCP/TLS+WebSocket | Sí | Alta |
| Xray Trojan+WS+TLS | 2096 | TCP/TLS+WebSocket | Sí | Alta |
| SlowDNS | 53 | UDP/TCP | Sí (túnel DNS) | Baja |
| Hysteria2 | 443 | UDP/QUIC | Sí | Muy alta |
| udp-custom | 7100-7200 | UDP | Parcial | Alta |

---

## Guía de uso por módulo

### 1. Crear usuario (opción 1)

```
Nombre de usuario: usuario1
Contraseña: (Enter = auto-generar)
Protocolos: 1,2,5,8       ← SSH, SSH-SSL, VLESS, Hysteria2
Días de vigencia: 30
Límite de conexiones: 2
Límite de BW (Mbps): 0    ← 0 = sin límite
```

El usuario se crea en la base de datos JSON y se habilita en los protocolos seleccionados.

### 2. Generar links de conexión (opción 15)

Después de crear un usuario, genera automáticamente los links para importar en la app:

```
vless://uuid@ip:2053?...#CRISDEV-VLESS-WS
vmess://base64...#CRISDEV-VMess-WS
trojan://pass@ip:2096?...#CRISDEV-Trojan-WS
hysteria2://pass@ip:443?...#CRISDEV-Hysteria2
```

También genera código QR si `qrencode` está instalado.

### 3. Estado del servidor (opción 16)

Muestra en una sola pantalla:
- IP, hostname, OS, uptime
- Uso de CPU, RAM, disco
- Estado de cada servicio (activo/inactivo)
- Puertos abiertos
- Conexiones activas por protocolo
- Resumen de usuarios

### 4. Firewall (opción 18)

```
  1) Ver reglas actuales      → ufw status verbose
  2) Abrir puerto             → ufw allow X/tcp
  3) Cerrar puerto            → ufw delete allow X/tcp
  4) Restablecer firewall     → reset con puertos base
  5) Modo pánico              → cerrar TODO excepto SSH
```

### 5. Certificados TLS (opción 19)

Si tienes dominio apuntando al VPS:
```
  2) Emitir certificado       → acme.sh Let's Encrypt automático
  4) Renovar todos            → renueva y reinicia servicios
```

Si no tienes dominio, se genera certificado autofirmado (10 años).

### 6. Modo pánico (opción 20)

Cierra TODOS los puertos excepto SSH. Usa cuando sospeches abuso o ataque. Solo podrás entrar por SSH para recuperar el servidor.

---

## Puertos que abre el firewall

Al instalar, UFW se configura automáticamente con estos puertos:

```
TCP: 22, 80, 443, 2053, 2083, 2096, 8443, 8880
UDP: 53, 443, 7100-7200
```

Puertos adicionales se abren automáticamente al habilitar cada protocolo.

---

## Estructura de archivos en el VPS

```
/etc/crisdev/
├── data/
│   ├── users.json          # Base de datos de usuarios
│   ├── server_config.json  # Configuración del servidor
│   └── state.json          # Estado de servicios
├── logs/
│   └── audit.log           # Log de auditoría
├── backups/
│   └── crisdev_backup_*.tar.gz
└── certs/
    ├── fullchain.pem       # Certificado TLS
    ├── privkey.pem         # Llave privada
    └── self-signed.pem     # Certificado autofirmado

/usr/local/etc/xray/
└── config.json             # Configuración Xray-core

/etc/hysteria/
└── config.yaml             # Configuración Hysteria2

/opt/xray/
└── xray                    # Binario Xray-core

/opt/slowdns/
├── server                  # Binario SlowDNS
├── server.key              # Llave privada
└── server.pub              # Llave pública

/opt/udp-custom/
├── server                  # Binario udp-custom
└── config.json             # Configuración udp-custom
```

---

## Backups

### Crear backup (opción 21)

Guarda todo: usuarios, configuraciones, certificados, llaves.

```bash
crisdev --backup
# O desde el menú: opción 21
```

Archivo: `/etc/crisdev/backups/crisdev_backup_YYYYMMDD_HHMMSS.tar.gz`

### Restaurar backup (opción 22)

Lista backups disponibles y restaura el que elijas. Sobreescribe configuraciones actuales.

---

## Actualizaciones

### Actualizar servicios individuales (opción 23)

```
  1) Xray-core    → descarga última versión desde GitHub
  2) Hysteria2    → ejecuta script oficial
```

### Actualizar CRISDEV (opción 26)

Descarga la última versión del script desde el repositorio sin perder configuración.

---

## Desarrollo y pushes

### PUSH.bat — Windows

Doble clic en `PUSH.bat` para subir cambios:

1. Muestra archivos modificados
2. Pide mensaje de commit (o Enter para auto-generar)
3. Ejecuta `git add -A` → `git commit` → `git push`

### Push manual

```bash
git add -A
git commit -m "Mensaje de cambios"
git push origin main
```

### Para que no pida token cada vez

```bash
git config --global credential.helper store
```

---

## Solución de problemas

| Problema | Solución |
|---|---|
| `crisdev: command not found` | Ejecuta `ln -sf /opt/crisdev/crisdev.sh /usr/local/bin/crisdev` |
| Xray no inicia | `journalctl -u xray -n 50` para ver el error |
| Hysteria2 no conecta | Verificar que el puerto UDP 443 esté abierto: `ufw status` |
| Usuario no puede conectar | Verificar expiración: opción 7 en el menú |
| Certificado vencido | Opción 19 → 4 (renovar todos) |
| Firewall bloqueando | Opción 18 → 1 (ver reglas) |
| Modo pánico activado | Solo puedes entrar por SSH puerto 22, desactivar con `ufw disable` |
| Token de GitHub expirado | Generar nuevo en GitHub > Settings > Developer settings > Tokens |

---

## Comandos rápidos

```bash
# Estado del servidor
crisdev --status

# Listar todos los usuarios
crisdev --users

# Crear backup rápido
crisdev --backup

# Ver logs de Xray
journalctl -u xray -f

# Ver logs de Hysteria2
journalctl -u hysteria-server -f

# Reiniciar todos los servicios
systemctl restart xray hysteria-server stunnel4 slowdns udp-custom

# Verificar puertos abiertos
ss -tuln | grep LISTEN

# Ver conexiones activas
ss -tn | grep ESTAB
```

---

## Soporte

- **Repositorio:** https://github.com/soportecrisdev/SCRIP_CRISDEV
- **Autor:** CRISDEV / @CRISIS1823
- **Issues:** https://github.com/soportecrisdev/SCRIP_CRISDEV/issues
