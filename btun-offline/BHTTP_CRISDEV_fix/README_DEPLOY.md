# BHTTP_CRISDEV — Guía de Instalación y Actualización en VPS

## Contexto: Servicios ya instalados por SCRIP_BASICA

Tu VPS ya tiene los siguientes servicios ocupando puertos:

| Servicio     | Puerto |
|-------------|--------|
| OpenSSH      | 22/tcp |
| Proxy SOCKS  | 80/tcp |
| Dropbear     | 90/tcp |
| Dropbear 2   | 110/tcp |
| SSL Tunnel   | 443/tcp |
| BADVPN udpgw | 7300/tcp+udp |

**El motor BHTTP usa estos puertos** (sin colisión):

| Servicio BHTTP        | Puerto |
|----------------------|--------|
| bilola-server (BHTTP) | 8080/tcp |
| bilola-xhttp (XHTTP TLS) | 8443/tcp |
| btun-server (BTUN)   | 7301/tcp+udp |
| btun-bhttp           | 7082/tcp |
| btun-xhttp           | 7445/tcp |

---

## Instalación Primera Vez en VPS

### Paso 1: Clonar el repo de configuración
```bash
git clone https://github.com/CristianBatero/BHTTP_CRISDEV.git /opt/bhttp-crisdev
```

### Paso 2: Subir el paquete offline de binarios a la VPS
Desde tu PC, sube el contenido de `btun-offline/BTUN/` a la VPS:
```bash
# Desde tu PC (Windows):
scp -r "btun-offline/BTUN/" root@TU_IP_VPS:/opt/bhttp-crisdev-bin/

# O comprimir y subir:
# zip -r bhttp-bin.zip btun-offline/BTUN/
# scp bhttp-bin.zip root@TU_IP_VPS:/tmp/
# En la VPS: unzip /tmp/bhttp-bin.zip -d /opt/bhttp-crisdev-bin/
```

### Paso 3: Ejecutar el setup
```bash
bash /opt/bhttp-crisdev/setup.sh
```

El `setup.sh`:
1. Carga `ports.env` (puertos sin colisión con tu SCRIP_BASICA)
2. Busca los binarios en `/opt/bhttp-crisdev-bin/`
3. Ejecuta `install.sh` del paquete de binarios
4. Opcional: instala cron de actualización automática

---

## Actualización (lo que falló antes y cómo funciona ahora)

### ¿Por qué falló el update anterior?

El `SHA256SUMS` antiguo en GitHub incluía los hashes de los **binarios**
(`./bin/amd64/bilola-server`, etc.) pero esos binarios **no están en el repo git**
(están en `btun-offline/BTUN/` en tu PC). Cuando la VPS ejecutaba:

```bash
sha256sum -c SHA256SUMS  # ← buscaba ./bin/amd64/bilola-server que no existe en /opt/bhttp-crisdev/
```

...fallaba con "SHA256SUMS no coincide" aunque el pull fue exitoso.

### ¿Cómo funciona ahora?

El nuevo `SHA256SUMS` **solo cubre los 3 archivos del repo**:
- `./setup.sh`
- `./update.sh`  
- `./ports.env`

El nuevo `update.sh` además **filtra los archivos que no existen** antes de verificar,
así nunca falla por archivos ausentes.

### Ejecutar actualización manual
```bash
bash /opt/bhttp-crisdev/update.sh
```

### Instalar actualización automática (cron diario a las 4am)
```bash
bash /opt/bhttp-crisdev/update.sh --install-cron
# Log en: /var/log/bhttp-update.log
```

---

## Verificar servicios activos

```bash
bhttp status
# o
systemctl status bilola-go-server bilola-xhttp-server btun-protocol btun-bhttp
```

## Puertos en uso después de instalar BHTTP

```bash
ss -tlnp | grep -E '8080|8443|7301|7082|7445'
```

---

## Subir los fixes al repo BHTTP_CRISDEV en GitHub

Desde tu PC, clona el repo BHTTP_CRISDEV y aplica los archivos de `BHTTP_CRISDEV_fix/`:

```bash
# Clona el repo BHTTP_CRISDEV en tu PC (si no lo tienes)
git clone https://github.com/CristianBatero/BHTTP_CRISDEV.git temp-bhttp
cd temp-bhttp

# Copia los archivos corregidos
copy ..\BHTTP_CRISDEV_fix\update.sh update.sh
copy ..\BHTTP_CRISDEV_fix\setup.sh setup.sh
copy ..\BHTTP_CRISDEV_fix\ports.env ports.env
copy ..\BHTTP_CRISDEV_fix\SHA256SUMS SHA256SUMS

# Commit y push
git add update.sh setup.sh ports.env SHA256SUMS
git commit -m "fix(update): SHA256SUMS solo cubre archivos del repo, no binarios offline; fix ports para no chocar con SCRIP_BASICA"
git push origin main
```
