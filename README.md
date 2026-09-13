# SSH-CRIS MASTER SUITE v1

Suite privada de administración y aprovisionamiento de túneles VPN para VPS Linux (Ubuntu / Debian). Diseñada exclusivamente para **CRISDEV / HTTP Conexión / HTTP Team**.

---

## 🚀 Instalación en 1 Línea (VPS Limpio)

Ejecuta el siguiente comando como `root` en tu VPS:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/soportecrisdev/SCRIP_CRISDEV/main/install.sh)
```

O también:

```bash
curl -fsSL https://raw.githubusercontent.com/soportecrisdev/SCRIP_CRISDEV/main/ssh-cris -o /usr/local/bin/ssh-cris && chmod +x /usr/local/bin/ssh-cris && ssh-cris
```

---

## ⚡ Comandos Globales Registrados

Una vez instalado, puedes abrir el menú en cualquier momento escribiendo cualquiera de estos comandos:

```bash
ssh-cris    # Menú maestro completo
cris        # Acceso rápido
menu        # Menú estándar
```

---

## 🛠️ Protocolos y Servicios Integrados

| Protocolo | Puertos Soportados | Descripción |
|---|---|---|
| **OpenSSH** | `22` | SSH directo con `AllowTcpForwarding` y keepalive activo. |
| **Stunnel4 (SSL/TLS)** | `443` | Wrapper SSL hacia OpenSSH con certificado auto-firmado. |
| **BHTTP Multi-Puerto** | `8080`, `80`, `8888`, `8081` | Motor de Relay BHTTP (Wakko Engine) compatible con `BHP1`. Permite abrir múltiples puertos simultáneos. |
| **UDP CRIS / Hysteria** | `36712` (Port hopping `6000:50000`) | Núcleo UDP Hysteria v1/v2 con OBFS y buffer optimizado para LTE. |
| **BadVPN UDPGW** | `7300` | Reenvío UDP para llamadas de WhatsApp y videojuegos online. |
| **SlowDNS / DNSTT** | `53` (UDP) | Servidor de túnel DNS con generación de clave pública/privada y NS. |
| **Xray / V2Ray** | `443`, `8443` | Soporte para VMess, VLESS Reality y Trojan. |

---

## 👥 Gestión de Usuarios y Multi-Login

- **Crear / Renovar:** Creación de usuarios SSH con fecha de expiración automática (`chage -E`).
- **Limitador de Conexiones:** Script en segundo plano `/usr/local/bin/ssh-cris-limiter` que detecta y termina sesiones excedentes en tiempo real.
- **Base de Datos:** Almacenada localmente en `/etc/ssh-cris/users.db`.

---

## 📤 Exportar Datos al GEN

El menú incluye la opción **[6] Ver Datos del Servidor**, que lista todas las IPs, puertos activos y credenciales formateadas listas para agregar en **ServerEditorActivity** de tu app Android GEN.
