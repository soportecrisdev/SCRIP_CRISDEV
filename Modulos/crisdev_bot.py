#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
CRISDEV TELEGRAM BOT — Asistente Inteligente y Soporte Oficial para HTTP Conexión ⚡
Desarrollado para: Conexiones EL CRIS / HTTP Conexión
Sincronización 100% DINÁMICA con Firebase Remote Config + Auto-Descubrimiento de Operadores por País + OCR Vision.
Play Store: https://play.google.com/store/apps/details?id=com.doriaxvpn.unlimited
"""

import os
import sys
import io
import time
import json
import random
import string
import logging
import datetime
import hashlib
import base64
import subprocess
import urllib.request
import urllib.parse
from threading import Thread, Lock

try:
    from Crypto.Cipher import AES
except ImportError:
    AES = None

try:
    from PIL import Image
    import pytesseract
except ImportError:
    Image = None
    pytesseract = None

# ═════════════════════════════════════════════════════════════════════
# CONFIGURACIÓN Y CONSTANTES DEL SERVICIO
# ═════════════════════════════════════════════════════════════════════
BOT_TOKEN = "8717022679:AAE8-9Og3EuU5eWMrSxYaB4_OuQnf2V1yQo"
ADMIN_IDS = [2006027987, 1087968824]
ALLOWED_GROUP_ID = -1001737640771
GROUP_USERNAME = "elcrischat"
ADMIN_USERNAME = "Crisis1823"
APP_NAME = "HTTP Conexión"
PLAYSTORE_URL = "https://play.google.com/store/apps/details?id=com.doriaxvpn.unlimited"

API_URL = f"https://api.telegram.org/bot{BOT_TOKEN}"
FILE_API_URL = f"https://api.telegram.org/file/bot{BOT_TOKEN}"

# Credenciales de Firebase Remote Config
FIREBASE_PROJECT_NUM = "149721662763"
FIREBASE_API_KEY = "AIzaSyCs8YtS4f6yvDiqWdhhWng6YvT6hbyjQmU"
FIREBASE_APP_ID = "1:149721662763:android:43dfafdbb13e6a8016b16e"
DEFAULT_OCKLA_URL = "https://raw.githubusercontent.com/soportecrisdev/Gen/main/new"
DEFAULT_GRETTA_PASS = "©risdev~"

logging.basicConfig(
    format="%(asctime)s - %(levelname)s - %(message)s",
    level=logging.INFO
)

group_user_cooldown = {}
pending_user_appointments = {}
last_broadcast_state = {"date": None, "index": 0}

# ═════════════════════════════════════════════════════════════════════
# MEMORIA Y CONTEXTO CONVERSACIONAL POR USUARIO (MULTI-TURN NLP)
# ═════════════════════════════════════════════════════════════════════
user_contexts = {}
user_context_lock = Lock()

def get_or_create_user_context(user_id, first_name="", username=""):
    now = time.time()
    with user_context_lock:
        ctx = user_contexts.get(user_id)
        if not ctx:
            ctx = {
                "user_id": user_id,
                "first_name": first_name or "Amigo",
                "username": username or "",
                "country_code": None,
                "country_name": None,
                "country_emoji": None,
                "operator": None,
                "state": "IDLE",
                "step": 0,
                "last_topic": None,
                "last_seen": now,
                "history": []
            }
            user_contexts[user_id] = ctx
        else:
            if first_name:
                ctx["first_name"] = first_name
            if username:
                ctx["username"] = username
            # Si pasaron más de 45 minutos de inactividad, reiniciar estado conversacional manteniendo operador/país recordados
            if (now - ctx["last_seen"]) > 2700:
                ctx["state"] = "IDLE"
                ctx["step"] = 0
                ctx["last_topic"] = None
            ctx["last_seen"] = now
        return ctx

def update_user_context_history(user_id, role, text):
    with user_context_lock:
        ctx = user_contexts.get(user_id)
        if ctx:
            ctx["history"].append({"role": role, "text": text, "ts": time.time()})
            if len(ctx["history"]) > 8:
                ctx["history"] = ctx["history"][-8:]

# ═════════════════════════════════════════════════════════════════════
# CACHÉ Y VERIFICACIÓN DE ADMINISTRADORES Y DUEÑOS DEL GRUPO
# ═════════════════════════════════════════════════════════════════════
cached_chat_admins = {}
admin_cache_lock = Lock()

def is_user_group_admin(chat_id, user_id, username="", msg=None):
    """Determina si el emisor del mensaje es el dueño, creador o administrador del grupo/canal."""
    # 1. Chequeo de IDs de Administrador fijas o Bot Anónimo / Canal de Telegram
    if user_id in ADMIN_IDS or user_id in [1087968824, 777000]:
        return True
    if username and username.lower() in [ADMIN_USERNAME.lower(), "crisis1823"]:
        return True
    if msg:
        if "sender_chat" in msg:
            return True
        from_u = msg.get("from", {})
        if from_u.get("username", "").lower() in [ADMIN_USERNAME.lower(), "crisis1823"]:
            return True
        if from_u.get("id") in ADMIN_IDS or from_u.get("id") in [1087968824, 777000]:
            return True

    # 2. Consultar caché local de administradores del grupo
    now = time.time()
    with admin_cache_lock:
        cache = cached_chat_admins.get(chat_id)
        if cache and (now - cache["last_fetch"]) < 600:
            return user_id in cache["admins"]

    # 3. Consulta a la API de Telegram getChatAdministrators
    try:
        url = f"{API_URL}/getChatAdministrators?chat_id={chat_id}"
        req = urllib.request.Request(url)
        with urllib.request.urlopen(req, timeout=8) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            if data.get("ok"):
                admins_set = set()
                for member in data.get("result", []):
                    u = member.get("user", {})
                    if u.get("id"):
                        admins_set.add(u["id"])
                with admin_cache_lock:
                    cached_chat_admins[chat_id] = {"admins": admins_set, "last_fetch": now}
                return user_id in admins_set
    except Exception as e:
        logging.warning(f"Error consultando getChatAdministrators ({chat_id}): {e}")

    return False



# Diccionario de traducción de códigos ISO / Banderas a nombres y emojis
ISO_COUNTRY_MAP = {
    "co": ("Colombia", "🇨🇴"),
    "mx": ("México", "🇲🇽"),
    "te": ("México", "🇲🇽"),
    "pe": ("Perú", "🇵🇪"),
    "ep": ("Perú", "🇵🇪"),
    "ar": ("Argentina", "🇦🇷"),
    "cl": ("Chile", "🇨🇱"),
    "ec": ("Ecuador", "🇪🇨"),
    "tu": ("Ecuador", "🇪🇨"),
    "gt": ("Guatemala", "🇬🇹"),
    "ti": ("Guatemala", "🇬🇹"),
    "sv": ("El Salvador", "🇸🇻"),
    "bo": ("Bolivia", "🇧🇴"),
    "va": ("Bolivia", "🇧🇴"),
    "pa": ("Panamá", "🇵🇦"),
    "cr": ("Costa Rica", "🇨🇷"),
    "do": ("Rep. Dominicana", "🇩🇴"),
    "py": ("Paraguay", "🇵🇾"),
    "ni": ("Nicaragua", "🇳🇮"),
    "hn": ("Honduras", "🇭🇳"),
    "cu": ("Cuba", "🇨🇺"),
    "un": ("Universal / Global", "🌐"),
    "pw": ("Universal / Redes", "🌐")
}

KNOWN_OPERATOR_PATTERNS = [
    ("claro", "Claro"),
    ("tigo", "Tigo"),
    ("movistar", "Movistar"),
    ("wom", "WOM"),
    ("telcel", "Telcel"),
    ("bait", "Bait / Altán"),
    ("altan", "Bait / Altán"),
    ("altán", "Bait / Altán"),
    ("att", "AT&T / Unefon"),
    ("at&t", "AT&T / Unefon"),
    ("unefon", "AT&T / Unefon"),
    ("entel", "Entel"),
    ("bitel", "Bitel"),
    ("personal", "Personal"),
    ("viva", "Viva"),
    ("tuenti", "Tuenti"),
    ("cnt", "CNT"),
    ("digicel", "Digicel"),
    ("+movil", "+Móvil"),
    ("+móvil", "+Móvil"),
    ("kolbi", "Kölbi"),
    ("kölbi", "Kölbi"),
    ("liberty", "Liberty"),
    ("cubacel", "CubaCel"),
    ("etb", "ETB"),
    ("virgin", "Virgin Mobile"),
    ("telecentro", "Telecentro"),
    ("pillofon", "Pillofon"),
    ("didi", "Didi")
]

COUNTRY_KEYWORDS_OCR = [
    ("colombia", "co"),
    ("🇨🇴", "co"),
    ("méxico", "mx"),
    ("mexico", "mx"),
    ("🇲🇽", "mx"),
    ("perú", "pe"),
    ("peru", "pe"),
    ("🇵🇪", "pe"),
    ("guatemala", "gt"),
    ("🇬🇹", "gt"),
    ("ecuador", "ec"),
    ("🇪🇨", "ec"),
    ("el salvador", "sv"),
    ("salvador", "sv"),
    ("🇸🇻", "sv"),
    ("bolivia", "bo"),
    ("🇧🇴", "bo"),
    ("argentina", "ar"),
    ("🇦🇷", "ar"),
    ("chile", "cl"),
    ("🇨🇱", "cl"),
    ("panamá", "pa"),
    ("panama", "pa"),
    ("🇵🇦", "pa"),
    ("costa rica", "cr"),
    ("🇨🇷", "cr"),
    ("rep. dominicana", "do"),
    ("dominicana", "do"),
    ("🇩🇴", "do"),
    ("honduras", "hn"),
    ("🇭🇳", "hn"),
    ("nicaragua", "ni"),
    ("🇳🇮", "ni"),
    ("cuba", "cu"),
    ("🇨🇺", "cu"),
    ("paraguay", "py"),
    ("🇵🇾", "py")
]

# Mensajes motivacionales y recordatorios para el grupo (2 a 3 veces por semana)
MOTIVATIONAL_BROADCAST_POOL = [
    (
        "⚡ <b>¡LA VELOCIDAD ESTÁ EN TUS MANOS!</b> ⚡\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        "¿Sabías que con <b>HTTP Conexión</b> tienes acceso a internet de alta velocidad, seguro y sin interrupciones?\n\n"
        "🔥 <i>Disfruta de tus videos en HD, streaming de películas, juegos sin lag y navegación 100% privada.</i>\n\n"
        "💡 <b>Tip de Rendimiento:</b> Toca el botón <b>Actualizar (🔄)</b> en la app para asegurarte de tener los métodos más recientes de tu operadora.\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        "🚀 ¡Conéctate hoy y vive la verdadera libertad digital!"
    ),
    (
        "🌟 <b>¡CONEXIÓN SIN LÍMITES Y A MÁXIMA POTENCIA!</b> 🌟\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        "No te quedes sin datos a mitad de tu día. Con nuestra infraestructura optimizada en la nube, conectarte a tu operador favorito toma solo 1 segundo.\n\n"
        "📶 <b>Soporte Activo Para:</b>\n"
        "🇨🇴 Colombia • 🇲🇽 México • 🇵🇪 Perú • 🇬🇹 Guatemala • 🇪🇨 Ecuador y 13 países más.\n\n"
        "👉 Abre <b>HTTP Conexión</b>, elige tu servidor y presiona <b>CONECTAR</b>.\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        "✨ ¡La mejor tecnología VPN al servicio de tu día a día!"
    ),
    (
        "🛡️ <b>MÁXIMA ESTABILIDAD Y PRIVACIDAD TOTAL</b> 🛡️\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        "Nuestros servidores se sincronizan continuamente con los métodos más estables para Claro, Tigo, Movistar, Telcel, Bait y más.\n\n"
        "🎯 <b>¿Tienes alguna duda o tu servidor se desconecta?</b>\n"
        "1️⃣ Activa el <b>Modo Avión ✈️</b> 5 segundos para renovar tu IP.\n"
        "2️⃣ Presiona <b>Actualizar (🔄)</b> en la barra superior.\n"
        "3️⃣ Puedes enviar una captura de pantalla aquí en el grupo y te guiaré al instante.\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        "💎 ¡Siempre en línea, siempre contigo!"
    ),
    (
        "🎮 <b>¡FIN DE SEMANA A MÁXIMO STREAMING Y JUEGOS!</b> 🎮\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        "Prepárate para disfrutar de tus series favoritas, partidas online con baja latencia y redes sociales ilimitadas.\n\n"
        "⚡ <b>HTTP Conexión</b> te brinda túneles seguros con cifrado de nivel empresarial totalmente gratis.\n\n"
        "📲 <i>¿Aún no la tienes instalada o te falta actualizarla? Toca abajo para tener la versión más reciente en Play Store.</i>\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        "🚀 ¡Que nada detenga tu navegación!"
    )
]

# ═════════════════════════════════════════════════════════════════════
# MOTOR DE SINCRONIZACIÓN Y PARSER DINÁMICO 100% EN VIVO
# ═════════════════════════════════════════════════════════════════════
JA_TEST = "4paZ4paa4pab4pac4pad4pae4paf4paD4paE4paF4paG4paH4paI4paJ4paK4paQ"
VAR_CHARS = base64.b64decode(JA_TEST).decode("utf-8")

cached_servers_data = {
    "version": "1.0.0",
    "release_notes": "Servidores actualizados.",
    "servers": [],
    "dynamic_countries": {},
    "last_sync": "Pendiente",
    "total": 0
}
data_lock = Lock()

def _gen_string(s):
    res = bytearray()
    for i in range(0, len(s), 2):
        c1 = s[i]
        c2 = s[i+1]
        idx1 = VAR_CHARS.index(c1)
        idx2 = VAR_CHARS.index(c2)
        res.append((idx1 * 16 + idx2) & 0xFF)
    return res.decode("latin-1")

def decrypt_remote_config(password, enc_text):
    if not AES:
        return None
    try:
        b64_cipher = _gen_string(enc_text)
        cipher_bytes = base64.b64decode(b64_cipher)
        hex_pass = password.encode("utf-8").hex().upper()
        key = hashlib.sha256(hex_pass.encode("utf-8")).digest()
        cipher = AES.new(key, AES.MODE_CBC, bytes(16))
        dec = cipher.decrypt(cipher_bytes)
        pad = dec[-1]
        if pad < 16:
            dec = dec[:-pad]
        return dec.decode("utf-8", errors="ignore")
    except Exception as e:
        logging.error(f"Error descifrando configuración: {e}")
        return None

def fetch_firebase_remote_config():
    """Consulta en tiempo real la configuración remota desde Firebase."""
    try:
        url = f"https://firebaseremoteconfig.googleapis.com/v1/projects/{FIREBASE_PROJECT_NUM}/namespaces/firebase:fetch?key={FIREBASE_API_KEY}"
        payload = {
            "appId": FIREBASE_APP_ID,
            "appInstanceId": "crisdev_bot_daemon_instance_01"
        }
        req = urllib.request.Request(
            url,
            data=json.dumps(payload).encode("utf-8"),
            headers={"Content-Type": "application/json"}
        )
        with urllib.request.urlopen(req, timeout=8) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            entries = data.get("entries", {})
            remote_url = entries.get("ockla_url", DEFAULT_OCKLA_URL)
            remote_pass = entries.get("gretta_pass", DEFAULT_GRETTA_PASS)
            return remote_url, remote_pass
    except Exception as e:
        logging.warning(f"Error en Firebase Remote Config ({e}), usando fallback.")
        return DEFAULT_OCKLA_URL, DEFAULT_GRETTA_PASS

def build_dynamic_country_tree(servers_list):
    """
    Analiza y categoriza dinámicamente cada servidor en su país y operador exactos,
    sin listas estáticas ni quemadas en código.
    """
    tree = {}
    for s in servers_list:
        raw_flag = s.get("FLAG", "un").lower().strip()
        name = s.get("Name", "").strip()
        flagg = s.get("FLAGG", "").lower().strip()
        info = s.get("isMinfo", "").strip()

        # Normalizar códigos secundarios
        if raw_flag in ["co"]:
            c_code = "co"
        elif raw_flag in ["mx", "te"]:
            c_code = "mx"
        elif raw_flag in ["pe", "ep"]:
            c_code = "pe"
        elif raw_flag in ["ec", "tu"]:
            c_code = "ec"
        elif raw_flag in ["gt", "ti"]:
            c_code = "gt"
        elif raw_flag in ["bo", "va"]:
            c_code = "bo"
        else:
            c_code = raw_flag

        c_name, c_emoji = ISO_COUNTRY_MAP.get(c_code, (c_code.upper(), "🌐"))

        if c_code not in tree:
            tree[c_code] = {
                "name": c_name,
                "emoji": c_emoji,
                "total": 0,
                "operators": {},
                "servers": []
            }

        tree[c_code]["total"] += 1
        tree[c_code]["servers"].append(s)

        # Detección dinámica de operador
        detected_op = "Multired / Otros"
        search_target = f"{flagg} {name.lower()} {info.lower()}"
        for pattern, op_display in KNOWN_OPERATOR_PATTERNS:
            if pattern in search_target:
                detected_op = op_display
                break

        tree[c_code]["operators"].setdefault(detected_op, []).append(name)

    return tree

def fetch_and_sync_servers():
    """Consulta la base de datos local del VPS / API y procesa el árbol de servidores en tiempo real."""
    global cached_servers_data
    try:
        # 1. Intentar cargar desde la Base de Datos Central del VPS (SQLite WAL / crisdev_db)
        try:
            import crisdev_db
            blob_info = crisdev_db.get_live_cached_blob()
            if blob_info and blob_info.get("raw_json"):
                data = json.loads(blob_info["raw_json"])
                version = data.get("Version", "1.0.0")
                notes = data.get("ReleaseNotes", "Servidores oficiales actualizados.")
                servers_list = data.get("Servers", [])
                dynamic_tree = build_dynamic_country_tree(servers_list)
                now_str = datetime.datetime.now().strftime("%d/%m/%Y %H:%M:%S")
                with data_lock:
                    cached_servers_data = {
                        "version": str(version),
                        "release_notes": notes,
                        "servers": servers_list,
                        "dynamic_countries": dynamic_tree,
                        "last_sync": now_str,
                        "total": len(servers_list)
                    }
                logging.info(f"✔ Servidores sincronizados desde Base de Datos Central VPS: v{version} ({len(servers_list)} servidores en {len(dynamic_tree)} países)")
                return True, f"Versión <b>v{version}</b> con <b>{len(servers_list)} servidores</b> en <b>{len(dynamic_tree)} países</b> cargados."
        except Exception as e:
            logging.warning(f"Aviso leyendo BD local ({e}), consultando fallback...")

        # 2. Fallback: Firebase Remote Config / GitHub
        target_url, target_pass = fetch_firebase_remote_config()
        req = urllib.request.Request(
            target_url,
            headers={"User-Agent": "HTTP-Conexion-Bot/3.0", "Accept": "*/*"}
        )
        with urllib.request.urlopen(req, timeout=12) as resp:
            raw_content = resp.read().decode("utf-8").strip()

        decrypted_json = decrypt_remote_config(target_pass, raw_content)
        if not decrypted_json:
            return False, "Error descifrando el paquete de configuración en la nube."

        data = json.loads(decrypted_json)
        version = data.get("Version", "1.0.0")
        notes = data.get("ReleaseNotes", "Servidores oficiales actualizados.")
        servers_list = data.get("Servers", [])

        # Poblar Base de Datos Local automáticamente con el fallback
        try:
            import crisdev_db
            crisdev_db.save_full_catalog(version, notes, servers_list, target_pass)
        except Exception:
            pass

        # Construir árbol 100% dinámico
        dynamic_tree = build_dynamic_country_tree(servers_list)

        now_str = datetime.datetime.now().strftime("%d/%m/%Y %H:%M:%S")
        with data_lock:
            cached_servers_data = {
                "version": str(version),
                "release_notes": notes,
                "servers": servers_list,
                "dynamic_countries": dynamic_tree,
                "last_sync": now_str,
                "total": len(servers_list)
            }
        logging.info(f"✔ Servidores sincronizados desde la nube: v{version} ({len(servers_list)} servidores en {len(dynamic_tree)} países)")
        return True, f"Versión <b>v{version}</b> con <b>{len(servers_list)} servidores</b> en <b>{len(dynamic_tree)} países</b> cargados."
    except Exception as e:
        logging.error(f"Error sincronizando servidores: {e}")
        return False, "Error de comunicación con el servicio de servidores."


def auto_sync_worker():
    while True:
        fetch_and_sync_servers()
        time.sleep(480)

def group_periodic_motivator_worker():
    """
    Envía mensajes motivacionales y recordatorios en el grupo oficial 2 a 3 veces por semana
    en horarios estratégicos (Martes 10am, Jueves 7:30pm, Sábado 11am) de manera elegante y sin saturar.
    """
    logging.info("Worker de recordatorios motivacionales del grupo iniciado.")
    while True:
        try:
            now = datetime.datetime.now()
            today_str = now.strftime("%Y-%m-%d")
            weekday = now.weekday()  # 0: Lunes, 1: Martes, 2: Miércoles, 3: Jueves, 4: Viernes, 5: Sábado, 6: Domingo
            hour = now.hour
            minute = now.minute

            # Días y horarios programados:
            # - Martes (1) entre 10:00 y 10:15 AM
            # - Jueves (3) entre 19:30 y 19:45 PM
            # - Sábado (5) entre 11:00 y 11:15 AM
            is_scheduled_time = False
            if weekday == 1 and hour == 10 and minute < 15:
                is_scheduled_time = True
            elif weekday == 3 and hour == 19 and 30 <= minute < 45:
                is_scheduled_time = True
            elif weekday == 5 and hour == 11 and minute < 15:
                is_scheduled_time = True

            if is_scheduled_time and last_broadcast_state.get("date") != today_str:
                idx = last_broadcast_state.get("index", 0) % len(MOTIVATIONAL_BROADCAST_POOL)
                msg_content = MOTIVATIONAL_BROADCAST_POOL[idx]
                
                markup = {
                    "inline_keyboard": [
                        [{"text": "📥 Descargar / Actualizar App", "url": PLAYSTORE_URL}],
                        [
                            {"text": "🌐 Ver Servidores en Vivo", "url": "https://t.me/CrisDevVpnBot?start=paises"},
                            {"text": "📅 Solicitar Soporte", "url": "https://t.me/CrisDevVpnBot?start=cita"}
                        ]
                    ]
                }
                
                logging.info(f"Enviando mensaje motivacional programado al grupo ({today_str})...")
                send_message(ALLOWED_GROUP_ID, msg_content, reply_markup=markup)
                last_broadcast_state["date"] = today_str
                last_broadcast_state["index"] = idx + 1

        except Exception as e:
            logging.error(f"Error en worker motivacional: {e}")

        time.sleep(300)

def search_servers_dynamic(keyword, max_results=8):
    """Busca servidores en la memoria dinámica (solo nombres públicos)."""
    with data_lock:
        servers = list(cached_servers_data.get("servers", []))
        version = cached_servers_data.get("version", "1.0.0")
        total_db = cached_servers_data.get("total", 0)

    q = keyword.lower().strip()
    matched = []

    for s in servers:
        name = s.get("Name", "")
        flag = s.get("FLAG", "").lower()
        flagg = s.get("FLAGG", "").lower()
        info = s.get("isMinfo", "").lower()
        combined = f"{name} {flag} {flagg} {info}".lower()

        if q in combined:
            matched.append(name)
            if len(matched) >= max_results:
                break

    return matched, version, total_db

# ═════════════════════════════════════════════════════════════════════
# RECONOCIMIENTO Y ANÁLISIS DE CAPTURAS DE PANTALLA (OCR VISION)
# ═════════════════════════════════════════════════════════════════════
def analyze_screenshot_ocr(image_bytes, user_ctx=None):
    """Analiza con visión inteligente la captura de pantalla de la app enviada por el usuario en su contexto."""
    if not Image or not pytesseract:
        return None, "Módulo de análisis visual no disponible.", None

    try:
        img = Image.open(io.BytesIO(image_bytes))
        text = pytesseract.image_to_string(img, lang="spa+eng")
        txt_lower = text.lower()
        logging.info(f"OCR extraído ({len(text)} chars): {text[:150]}...")

        with data_lock:
            tree = cached_servers_data.get("dynamic_countries", {})
            version = cached_servers_data.get("version", "1.0.0")
            total_active = cached_servers_data.get("total", 0)

        # 1. Pantalla de Selección de Servidores
        if any(k in txt_lower for k in ["selecciona tu servidor", "buscar servidor", "servidores disponibles", "favoritos", "universal", "todos", "colombia", "méxico", "peru", "guatemala"]):
            detected_country_code = None
            for kw, code in COUNTRY_KEYWORDS_OCR:
                if kw in txt_lower or kw in text:
                    detected_country_code = code
                    break

            if detected_country_code and detected_country_code in tree:
                c_data = tree[detected_country_code]
                guidance = (
                    f"⚡ <b>ASISTENTE VISUAL HTTP CONEXIÓN</b> ⚡\n"
                    f"━━━━━━━━━━━━━━━━━━━━\n"
                    f"📱 <b>Pantalla Detectada:</b> <code>Selecciona Tu Servidor</code>\n"
                    f"📍 <b>País Identificado:</b> {c_data['emoji']} <b>{c_data['name'].upper()}</b> (<b>{c_data['total']} Servidores Activos</b>)\n\n"
                    f"📶 <b>OPERADORES ACTIVOS EN TU REGIÓN:</b>\n"
                )
                for op_name, slist in c_data["operators"].items():
                    guidance += f"🔸 <b>{op_name}:</b> <code>{len(slist)} servidores</code>\n"

                guidance += (
                    f"\n📲 <b>¿CÓMO CONECTAR TU OPERADOR?</b>\n"
                    f"1️⃣ En la app toca el <b>Buscador (🔍)</b> y escribe tu operador.\n"
                    f"2️⃣ Selecciona un servidor de la lista y regresa a Inicio.\n"
                    f"3️⃣ Enciende tus <b>datos móviles</b> y pulsa el botón central <b>CONECTAR</b>.\n"
                    f"━━━━━━━━━━━━━━━━━━━━\n"
                    f"👇 <i>¿Deseas consultar otro país? Selecciona en los botones:</i>"
                )
                return "servers_screen", guidance, detected_country_code
            else:
                guidance = (
                    f"⚡ <b>ASISTENTE VISUAL HTTP CONEXIÓN</b> ⚡\n"
                    f"━━━━━━━━━━━━━━━━━━━━\n"
                    f"📱 <b>Pantalla Detectada:</b> <code>Selecciona Tu Servidor</code>\n"
                    f"📊 <b>Disponibilidad:</b> <b>{total_active} Servidores Activos</b> (Versión v{version})\n\n"
                    f"🔍 <b>GUÍA RÁPIDA DE NAVEGACIÓN EN LA APP:</b>\n"
                    f"• <b>Buscador en Vivo (🔍):</b> Escribe el nombre de tu operador (ej: <i>Claro, Tigo, Movistar, Telcel, Bait</i>).\n"
                    f"• <b>Pestañas con Banderas:</b> Toca la bandera de tu país para ver solo tus servidores.\n"
                    f"• <b>Actualizar (🔄):</b> Toca el botón superior para descargar nuevos métodos.\n"
                    f"━━━━━━━━━━━━━━━━━━━━\n"
                    f"👇 <b>Selecciona tu país abajo para ver tus operadores disponibles:</b>"
                )
                return "servers_screen", guidance, None

        # 2. Pantalla Principal de Conexión
        if any(k in txt_lower for k in ["conectar", "desconectar", "conectando", "desconectado", "http conexión", "conexiones el cris", "tiempo restante"]):
            if "conectando" in txt_lower or "reconectando" in txt_lower:
                guidance = (
                    f"⚡ <b>DIAGNÓSTICO VISUAL DE CONEXIÓN</b> ⚡\n"
                    f"━━━━━━━━━━━━━━━━━━━━\n"
                    f"📱 <b>Estado Detectado:</b> ⏳ <b>CONECTANDO AL TÚNEL...</b>\n\n"
                    f"🛠️ <b>SI TARDA EN CONECTAR O SE QUEDA EN BUCLE:</b>\n"
                    f"1️⃣ <b>Modo Avión (✈️):</b> Actívalo 5 segundos y apágalo para renovar la IP de datos móviles.\n"
                    f"2️⃣ <b>Actualizar Servidores (🔄):</b> Toca el botón superior para tener la versión <code>v{version}</code>.\n"
                    f"3️⃣ <b>Probar Otro Servidor:</b> Entra a la lista y selecciona otro servidor de tu operador.\n"
                    f"4️⃣ <b>Comprobar Datos:</b> Enciende los datos móviles y apaga el Wi-Fi.\n"
                    f"━━━━━━━━━━━━━━━━━━━━"
                )
            elif "conectado" in txt_lower and not "desconectado" in txt_lower:
                guidance = (
                    f"🎉 <b>¡TÚNEL VPN 100% CONECTADO Y ACTIVO!</b> 🎉\n"
                    f"━━━━━━━━━━━━━━━━━━━━\n"
                    f"📱 <b>Estado Detectado:</b> 🟢 <b>CONECTADO CON ÉXITO</b>\n\n"
                    f"🚀 Tu conexión está protegida con cifrado de alta velocidad. Ya puedes disfrutar de internet ilimitado, streaming en HD y juegos en línea.\n"
                    f"━━━━━━━━━━━━━━━━━━━━"
                )
            else:
                guidance = (
                    f"⚡ <b>ASISTENTE VISUAL HTTP CONEXIÓN</b> ⚡\n"
                    f"━━━━━━━━━━━━━━━━━━━━\n"
                    f"📱 <b>Pantalla Detectada:</b> <code>Inicio / Conexión Principal</code>\n"
                    f"⭕ <b>Estado:</b> <b>DESCONECTADO</b>\n\n"
                    f"👉 <b>PASOS PARA CONECTAR:</b>\n"
                    f"1️⃣ <b>Elegir Servidor:</b> Toca la barra superior de servidor para abrir el catálogo.\n"
                    f"2️⃣ <b>Encender Datos:</b> Activa tus <b>datos móviles</b>.\n"
                    f"3️⃣ <b>Conectar:</b> Presiona el botón circular <b>CONECTAR</b>.\n"
                    f"━━━━━━━━━━━━━━━━━━━━"
                )
            return "home_screen", guidance, None

        # 3. Pantalla de Registros / Logs
        if any(k in txt_lower for k in ["log", "registro", "ssh", "handshake", "timeout", "refused", "authentication", "fatal", "failed"]):
            if "timeout" in txt_lower or "unreachable" in txt_lower or "refused" in txt_lower:
                guidance = (
                    f"📋 <b>DIAGNÓSTICO TÉCNICO DE REGISTRO (LOGS)</b> 📋\n"
                    f"━━━━━━━━━━━━━━━━━━━━\n"
                    f"⚠️ <b>Problema Detectado:</b> <code>Servidor no responde (Timeout / Host Unreachable)</code>\n\n"
                    f"👉 <b>SOLUCIÓN INMEDIATA:</b>\n"
                    f"1️⃣ El servidor que intentas usar está saturado o en mantenimiento.\n"
                    f"2️⃣ Toca atrás, entra a la lista de servidores y elige <b>otro servidor de tu operador</b>.\n"
                    f"3️⃣ Activa el <b>Modo Avión ✈️</b> 5 segundos para obtener una IP limpia.\n"
                    f"━━━━━━━━━━━━━━━━━━━━"
                )
            elif "authentication" in txt_lower or "auth" in txt_lower:
                guidance = (
                    f"📋 <b>DIAGNÓSTICO TÉCNICO DE REGISTRO (LOGS)</b> 📋\n"
                    f"━━━━━━━━━━━━━━━━━━━━\n"
                    f"🔑 <b>Problema Detectado:</b> <code>Fallo de Autenticación (Auth Failed)</code>\n\n"
                    f"👉 <b>SOLUCIÓN INMEDIATA:</b>\n"
                    f"1️⃣ Presiona el botón <b>Actualizar (🔄)</b> en la app para renovar métodos públicos.\n"
                    f"2️⃣ Si tienes cuenta privada, verifica que tu usuario y clave no hayan vencido.\n"
                    f"3️⃣ Contacta a soporte: @{ADMIN_USERNAME}.\n"
                    f"━━━━━━━━━━━━━━━━━━━━"
                )
            else:
                guidance = (
                    f"📋 <b>DIAGNÓSTICO TÉCNICO DE REGISTRO (LOGS)</b> 📋\n"
                    f"━━━━━━━━━━━━━━━━━━━━\n"
                    f"He analizado los registros de conexión de tu app.\n\n"
                    f"💡 <b>RECOMENDACIONES TÉCNICAS:</b>\n"
                    f"• Si no tienes saldo: Utiliza servidores marcados con <b>SlowDNS</b>.\n"
                    f"• Si tienes redes sociales o paquete: Usa servidores <b>SSL / Directo</b>.\n"
                    f"• Presiona <b>Actualizar (🔄)</b> para sincronizar los métodos más recientes.\n"
                    f"━━━━━━━━━━━━━━━━━━━━"
                )
            return "logs_screen", guidance, None

        # 4. Captura general
        guidance = (
            f"📱 <b>CAPTURA DE PANTALLA RECIBIDA — {APP_NAME}</b>\n"
            f"━━━━━━━━━━━━━━━━━━━━\n"
            f"He analizado tu captura. Para brindarte soporte exacto según tu país y operador, selecciona abajo:"
        )
        return "general_screen", guidance, None
    except Exception as e:
        logging.error(f"Error en OCR: {e}")
        return None, "No se pudo procesar la imagen.", None

# ═════════════════════════════════════════════════════════════════════
# FUNCIONES DE API TELEGRAM
# ═════════════════════════════════════════════════════════════════════
def send_api_request(method, payload):
    url = f"{API_URL}/{method}"
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except Exception as e:
        logging.error(f"Error en API Telegram ({method}): {e}")
        return None

def download_telegram_file(file_id):
    try:
        file_info = send_api_request("getFile", {"file_id": file_id})
        if not file_info or not file_info.get("ok"):
            return None
        file_path = file_info["result"]["file_path"]
        download_url = f"{FILE_API_URL}/{file_path}"
        with urllib.request.urlopen(download_url, timeout=15) as resp:
            return resp.read()
    except Exception as e:
        logging.error(f"Error descargando foto: {e}")
        return None

def send_message(chat_id, text, reply_markup=None, parse_mode="HTML", reply_to_message_id=None):
    payload = {
        "chat_id": chat_id,
        "text": text,
        "parse_mode": parse_mode,
        "disable_web_page_preview": True
    }
    if reply_markup:
        payload["reply_markup"] = reply_markup
    if reply_to_message_id:
        payload["reply_to_message_id"] = reply_to_message_id
    return send_api_request("sendMessage", payload)

def edit_message(chat_id, message_id, text, reply_markup=None, parse_mode="HTML"):
    payload = {
        "chat_id": chat_id,
        "message_id": message_id,
        "text": text,
        "parse_mode": parse_mode,
        "disable_web_page_preview": True
    }
    if reply_markup:
        payload["reply_markup"] = reply_markup
    return send_api_request("editMessageText", payload)

def answer_callback_query(callback_query_id, text=None, show_alert=False):
    payload = {"callback_query_id": callback_query_id}
    if text:
        payload["text"] = text
        payload["show_alert"] = show_alert
    return send_api_request("answerCallbackQuery", payload)

def setup_telegram_bot_commands():
    """Configura el perfil, descripción, información y comandos del Bot en Telegram automáticamente."""
    try:
        # 1. Configurar Nombre Oficial del Bot
        send_api_request("setMyName", {
            "name": "CRISDEV VPN Assistant ⚡"
        })

        # 2. Configurar Descripción Corta (Aparece en el perfil / info del bot - máx 120 caracteres)
        send_api_request("setMyShortDescription", {
            "short_description": "⚡ Asistente oficial de HTTP Conexión. Servidores en vivo, soporte por países y diagnóstico visual."
        })

        # 3. Configurar Descripción Completa (Aparece en la pantalla de inicio antes de pulsar Iniciar)
        full_description = (
            "⚡ Asistente Oficial de HTTP Conexión ⚡\n\n"
            "🚀 Funciones Principales:\n"
            "• 🌐 Servidores y operadores activos por país.\n"
            "• 🔍 Búsqueda rápida de servidores.\n"
            "• 📸 Diagnóstico por capturas de pantalla.\n"
            "• 📅 Agendamiento de soporte y contacto.\n"
            "• 🔄 Guía de actualización y solución de fallas.\n\n"
            "📲 Play Store:\n"
            "https://play.google.com/store/apps/details?id=com.doriaxvpn.unlimited\n\n"
            "👉 Envía /start para iniciar."
        )
        send_api_request("setMyDescription", {
            "description": full_description
        })

        # 4. Comandos para Usuarios
        user_commands = [
            {"command": "start", "description": "⚡ Menú principal y soporte"},
            {"command": "paises", "description": "🌐 Países y operadores disponibles"},
            {"command": "buscar", "description": "🔍 Buscar servidores por operador"},
            {"command": "cita", "description": "📅 Agendar consulta con Cristian"},
            {"command": "guia", "description": "📖 Cómo conectar y buscar en la app"},
            {"command": "actualizar", "description": "🔄 Cómo actualizar los servidores"},
            {"command": "fallas", "description": "🛠️ Solución de fallas de conexión"},
            {"command": "descargar", "description": "📥 Instalar app en Google Play"},
            {"command": "soporte", "description": "👑 Contactar soporte oficial"}
        ]
        
        # 5. Menú público para todos los usuarios y grupos
        send_api_request("setMyCommands", {
            "commands": user_commands,
            "scope": {"type": "default"}
        })
        
        # 6. Menú exclusivo para administradores
        admin_commands = user_commands + [
            {"command": "status", "description": "👑 [Admin] Estado del VPS y servicios"},
            {"command": "sync", "description": "👑 [Admin] Forzar sincronización Firebase"},
            {"command": "crear", "description": "👑 [Admin] Crear nuevo usuario SSH"},
            {"command": "eliminar", "description": "👑 [Admin] Eliminar usuario SSH"}
        ]
        for admin_id in ADMIN_IDS:
            send_api_request("setMyCommands", {
                "commands": admin_commands,
                "scope": {"type": "chat", "chat_id": admin_id}
            })
        logging.info("✔ Perfil, descripción y comandos de Telegram actualizados exitosamente.")
    except Exception as e:
        logging.error(f"Error configurando perfil de Telegram: {e}")

# ═════════════════════════════════════════════════════════════════════
# GESTIÓN DE USUARIOS DEL VPS (ADMINISTRADOR)
# ═════════════════════════════════════════════════════════════════════
def create_ssh_user(username, password, days=30, limit=1):
    try:
        subprocess.run(f"useradd -M -s /bin/false {username}", shell=True, check=True)
        subprocess.run(f"echo '{username}:{password}' | chpasswd", shell=True, check=True)
        exp_date = (datetime.datetime.now() + datetime.timedelta(days=days)).strftime("%d/%m/%Y")
        os.makedirs("/etc/SSHPlus", exist_ok=True)
        with open("/etc/SSHPlus/usuarios.db", "a") as f:
            f.write(f"{username} {exp_date} {limit}\n")
        return True
    except Exception as e:
        logging.error(f"Error creando usuario SSH: {e}")
        return False

def get_system_stats():
    try:
        mem_tot, mem_used = 0, 0
        with open("/proc/meminfo", "r") as f:
            for line in f:
                if line.startswith("MemTotal:"):
                    mem_tot = int(line.split()[1]) // 1024
                elif line.startswith("MemAvailable:"):
                    mem_avail = int(line.split()[1]) // 1024
        mem_used = mem_tot - mem_avail
        ram_pct = int((mem_used / mem_tot) * 100) if mem_tot > 0 else 0

        uptime_raw = subprocess.check_output("uptime -p 2>/dev/null || echo 'Activo'", shell=True).decode().strip()
        users_count = subprocess.check_output("wc -l < /etc/SSHPlus/usuarios.db 2>/dev/null || echo 0", shell=True).decode().strip()
        online_count = subprocess.check_output("ps aux | grep -E 'sshd:|dropbear' | grep -v 'grep' | wc -l", shell=True).decode().strip()

        return {
            "ram_used": mem_used,
            "ram_tot": mem_tot,
            "ram_pct": ram_pct,
            "uptime": uptime_raw,
            "users": users_count,
            "online": online_count
        }
    except Exception:
        return {"ram_used": 0, "ram_tot": 0, "ram_pct": 0, "uptime": "N/A", "users": "0", "online": "0"}

# ═════════════════════════════════════════════════════════════════════
# MENÚS Y TECLADOS INTERACTIVOS DINÁMICOS
# ═════════════════════════════════════════════════════════════════════
def get_main_menu_markup():
    return {
        "inline_keyboard": [
            [
                {"text": "📥 Descargar App en Google Play", "url": PLAYSTORE_URL}
            ],
            [
                {"text": "🌐 Países y Operadores en Vivo", "callback_data": "menu_countries"},
                {"text": "🔍 ¿Cómo Buscar en la App?", "callback_data": "guide_search"}
            ],
            [
                {"text": "🔄 Actualizar Servidores", "callback_data": "guide_update"},
                {"text": "🛠️ Solución de Fallas", "callback_data": "guide_troubleshoot"}
            ],
            [
                {"text": "📅 Agendar Cita / Soporte", "callback_data": "menu_appointment"},
                {"text": "💬 Grupo Oficial", "url": f"https://t.me/{GROUP_USERNAME}"}
            ]
        ]
    }

def get_dynamic_countries_markup():
    """Genera botones interactivos basados estrictamente en los países que existen hoy en el JSON."""
    with data_lock:
        tree = cached_servers_data.get("dynamic_countries", {})

    buttons = []
    row = []
    sorted_countries = sorted(tree.items(), key=lambda x: x[1]["total"], reverse=True)

    for c_code, c_data in sorted_countries:
        btn_text = f"{c_data['emoji']} {c_data['name']} ({c_data['total']})"
        row.append({"text": btn_text, "callback_data": f"country_{c_code}"})
        if len(row) == 2:
            buttons.append(row)
            row = []
    if row:
        buttons.append(row)

    buttons.append([{"text": "🌍 Ver Resumen Global", "callback_data": "country_all"}])
    buttons.append([{"text": "⬅️ Volver al Menú Principal", "callback_data": "main_menu"}])

    return {"inline_keyboard": buttons}

def format_live_country_response(c_code):
    """Construye la tarjeta de soporte con operadores y servidores reales calculados en vivo."""
    with data_lock:
        tree = cached_servers_data.get("dynamic_countries", {})
        version = cached_servers_data.get("version", "1.0.0")

    c_data = tree.get(c_code)
    if not c_data:
        return "❌ País no disponible en la versión actual de servidores."

    text = (
        f"{c_data['emoji']} <b>SERVIDORES Y OPERADORES — {c_data['name'].upper()}</b> {c_data['emoji']}\n"
        f"━━━━━━━━━━━━━━━━━━━━\n"
        f"📱 <b>App Oficial:</b> <a href=\"{PLAYSTORE_URL}\">{APP_NAME}</a>\n"
        f"📦 <b>Versión de Servidores en App:</b> <code>v{version}</code>\n"
        f"📊 <b>Total Activos en {c_data['name']}:</b> <b>{c_data['total']} Servidores</b>\n\n"
        f"📶 <b>DESGLOSE DE OPERADORES DISPONIBLES:</b>\n"
    )

    for op_name, slist in c_data["operators"].items():
        text += f"\n🔸 <b>{op_name}</b> ({len(slist)} servidores):\n"
        for sname in slist[:4]:
            text += f"   • <code>{sname}</code>\n"
        if len(slist) > 4:
            text += f"   <i>... y {len(slist) - 4} servidores más en la app.</i>\n"

    text += (
        f"\n━━━━━━━━━━━━━━━━━━━━\n"
        f"📲 <b>¿CÓMO ENCONTRARLOS EN LA APP?</b>\n"
        f"1️⃣ Abre la app y presiona <b>Actualizar Servidores (🔄)</b>.\n"
        f"2️⃣ Toca la pestaña <b>{c_data['emoji']} {c_data['name']} ({c_data['total']})</b>.\n"
        f"3️⃣ O escribe en el buscador 🔍 tu operador (ej: <i>Claro, Tigo, Movistar</i>).\n"
        f"4️⃣ Selecciona tu servidor y presiona <b>CONECTAR</b>."
    )
    return text

def format_global_summary():
    with data_lock:
        tree = cached_servers_data.get("dynamic_countries", {})
        version = cached_servers_data.get("version", "1.0.0")
        total = cached_servers_data.get("total", 0)
        last_sync = cached_servers_data.get("last_sync", "En línea")

    text = (
        f"🌍 <b>ESTADO GLOBAL DE SERVIDORES — {APP_NAME}</b> 🌍\n"
        f"━━━━━━━━━━━━━━━━━━━━\n"
        f"📦 <b>Versión Actual en Nube:</b> <code>v{version}</code>\n"
        f"📊 <b>Total de Servidores Activos:</b> <b>{total} Servidores</b>\n"
        f"⏱️ <b>Última Sincronización:</b> <code>{last_sync}</code>\n\n"
        f"📍 <b>COBERTURA DINÁMICA POR PAÍS:</b>\n"
    )

    sorted_countries = sorted(tree.items(), key=lambda x: x[1]["total"], reverse=True)
    for c_code, c_data in sorted_countries:
        ops_str = ", ".join(list(c_data["operators"].keys())[:3])
        text += f"{c_data['emoji']} <b>{c_data['name']}:</b> {c_data['total']} servidores ({ops_str})\n"

    text += (
        f"━━━━━━━━━━━━━━━━━━━━\n"
        f"💡 <i>Los servidores se sincronizan en tiempo real directamente desde la nube.</i>"
    )
    return text

def get_search_guide_text():
    with data_lock:
        version = cached_servers_data.get("version", "1.0.0")

    return (
        f"🔍 <b>GUÍA: CÓMO USAR EL BUSCADOR Y FILTROS EN LA APP</b> 🔍\n"
        f"━━━━━━━━━━━━━━━━━━━━\n"
        f"En la aplicación <a href=\"{PLAYSTORE_URL}\"><b>{APP_NAME}</b></a> encontrar tu servidor es muy fácil:\n\n"
        f"1️⃣ <b>Verificar la Versión de Servidores:</b>\n"
        f"Asegúrate de tener la versión <b>v{version}</b> tocando el botón de <b>Actualizar (🔄)</b> en la parte superior.\n\n"
        f"2️⃣ <b>Usar el Buscador en Vivo (🔍):</b>\n"
        f"Al abrir la lista de servidores, toca la <b>Lupa</b> y escribe el nombre de tu operador (ej: <i>Claro, Telcel, Tigo, Bait</i>).\n\n"
        f"3️⃣ <b>Filtrar por Pestañas de País:</b>\n"
        f"Toca la pestaña de tu país con su bandera para ver únicamente tus servidores.\n\n"
        f"4️⃣ <b>Conectar:</b>\n"
        f"Selecciona el servidor deseado y pulsa el botón central de <b>CONECTAR</b>.\n"
        f"━━━━━━━━━━━━━━━━━━━━\n"
        f"✨ ¡Tendrás internet de alta velocidad en segundos!"
    )

def get_update_guide_text():
    with data_lock:
        version = cached_servers_data.get("version", "1.0.0")
        total = cached_servers_data.get("total", 0)

    return (
        f"🔄 <b>¿CÓMO ACTUALIZAR LOS SERVIDORES EN LA APP?</b> 🔄\n"
        f"━━━━━━━━━━━━━━━━━━━━\n"
        f"Nuestros servidores se actualizan constantemente en la nube con nuevos métodos y mejoras.\n\n"
        f"📦 <b>Versión de Servidores en la Nube:</b> <code>v{version}</code> ({total} servidores)\n\n"
        f"<b>Pasos para actualizar:</b>\n"
        f"1️⃣ Abre la app <a href=\"{PLAYSTORE_URL}\"><b>{APP_NAME}</b></a>.\n"
        f"2️⃣ Toca el icono de <b>Actualizar (🔄)</b> en la barra superior o menú.\n"
        f"3️⃣ Espera el aviso de confirmación <i>'Servidores actualizados con éxito'</i>.\n\n"
        f"💡 <i>Si un método deja de conectar o se agrega un nuevo operador, la actualización lo corregirá de inmediato.</i>"
    )

def get_troubleshoot_text():
    return (
        f"🛠️ <b>SOLUCIÓN DE PROBLEMAS: ¿NO CONECTA O SE DESCONECTA?</b> 🛠️\n"
        f"━━━━━━━━━━━━━━━━━━━━\n"
        f"Sigue estos 4 sencillos pasos para resolver la mayoría de fallas:\n\n"
        f"1️⃣ <b>Renovar IP Móvil (Modo Avión):</b>\n"
        f"Activa el <b>Modo Avión</b> por 5 segundos y desactívalo. Esto cambia la IP local asignada por tu operadora.\n\n"
        f"2️⃣ <b>Actualizar Servidores (🔄):</b>\n"
        f"Presiona el botón de actualización en la app para asegurarte de tener la última versión de métodos.\n\n"
        f"3️⃣ <b>Probar Otro Servidor del Mismo Operador:</b>\n"
        f"Dentro de tu operadora dispones de múltiples servidores. Si uno está saturado, prueba con el siguiente.\n\n"
        f"4️⃣ <b>Comprobar tu Método / Saldo:</b>\n"
        f"• Sin saldo: Prueba servidores <b>SlowDNS</b>.\n"
        f"• Con redes o paquete: Prueba servidores <b>SSL / Directo</b>.\n"
        f"━━━━━━━━━━━━━━━━━━━━\n"
        f"💬 ¿Aún necesitas ayuda? Pregunta en el grupo @{GROUP_USERNAME} o escribe a @{ADMIN_USERNAME}."
    )

def get_appointment_prompt_text():
    return (
        f"📅 <b>AGENDAR CITA / ATENCIÓN PERSONALIZADA</b> 📅\n"
        f"━━━━━━━━━━━━━━━━━━━━\n"
        f"¿Requieres soporte directo, cuentas privadas, consultas especiales o un método dedicado para tu país?\n\n"
        f"👉 <b>¿Cómo funciona?</b>\n"
        f"Por favor, responde a este mensaje indicando:\n"
        f"• <b>Tu País y Operador:</b> (ej: Colombia Claro / México Telcel)\n"
        f"• <b>Motivo de tu consulta:</b> (ej: Cuenta dedicada, error persistente, soporte para revendedor)\n\n"
        f"✉️ <i>Tu solicitud será enviada de inmediato a la bandeja privada de <b>Cristian (@Crisis1823)</b> con tu perfil.</i>\n"
        f"━━━━━━━━━━━━━━━━━━━━\n"
        f"✍️ <b>Escribe tu mensaje ahora mismo:</b>"
    )

# ═════════════════════════════════════════════════════════════════════
# PROCESAMIENTO INTELIGENTE Y CONTEXTUAL DE MENSAJES (MULTI-TURN NLP)
# ═════════════════════════════════════════════════════════════════════
def extract_entities_and_intent(text, ctx):
    txt_lower = text.lower().strip()
    words = [w.strip(string.punctuation) for w in txt_lower.split()]

    detected_c_code = None
    detected_c_name = None
    detected_c_emoji = None

    # 1. Búsqueda de País en ISO_COUNTRY_MAP y alias
    for code, (c_name, c_emoji) in ISO_COUNTRY_MAP.items():
        if code in ["un", "pw", "te", "ep", "tu", "ti", "va"]:
            continue
        c_lower = c_name.lower()
        if c_lower in txt_lower or c_emoji in text or f" {code} " in f" {txt_lower} ":
            detected_c_code = code
            detected_c_name = c_name
            detected_c_emoji = c_emoji
            break

    if not detected_c_code:
        if any(w in txt_lower for w in ["colombia", "colombiano", "colombiana", "bogota", "medellin", "cali"]):
            detected_c_code, detected_c_name, detected_c_emoji = "co", "Colombia", "🇨🇴"
        elif any(w in txt_lower for w in ["mexico", "méxico", "mexicano", "cdmx", "monterrey", "guadalajara"]):
            detected_c_code, detected_c_name, detected_c_emoji = "mx", "México", "🇲🇽"
        elif any(w in txt_lower for w in ["peru", "perú", "peruano", "lima"]):
            detected_c_code, detected_c_name, detected_c_emoji = "pe", "Perú", "🇵🇪"
        elif any(w in txt_lower for w in ["ecuador", "ecuatoriano", "quito", "guayaquil"]):
            detected_c_code, detected_c_name, detected_c_emoji = "ec", "Ecuador", "🇪🇨"
        elif any(w in txt_lower for w in ["guatemala", "guatemalteco", "chapin", "chapín"]):
            detected_c_code, detected_c_name, detected_c_emoji = "gt", "Guatemala", "🇬🇹"
        elif any(w in txt_lower for w in ["el salvador", "salvador", "salvadoreño"]):
            detected_c_code, detected_c_name, detected_c_emoji = "sv", "El Salvador", "🇸🇻"
        elif any(w in txt_lower for w in ["argentina", "argentino", "buenos aires"]):
            detected_c_code, detected_c_name, detected_c_emoji = "ar", "Argentina", "🇦🇷"
        elif any(w in txt_lower for w in ["chile", "chileno", "santiago"]):
            detected_c_code, detected_c_name, detected_c_emoji = "cl", "Chile", "🇨🇱"
        elif any(w in txt_lower for w in ["bolivia", "boliviano", "la paz", "santa cruz"]):
            detected_c_code, detected_c_name, detected_c_emoji = "bo", "Bolivia", "🇧🇴"
        elif any(w in txt_lower for w in ["panama", "panamá", "panameño"]):
            detected_c_code, detected_c_name, detected_c_emoji = "pa", "Panamá", "🇵🇦"
        elif any(w in txt_lower for w in ["costa rica", "tico", "tica", "san jose"]):
            detected_c_code, detected_c_name, detected_c_emoji = "cr", "Costa Rica", "🇨🇷"
        elif any(w in txt_lower for w in ["dominicana", "rep dominicana", "santo domingo"]):
            detected_c_code, detected_c_name, detected_c_emoji = "do", "Rep. Dominicana", "🇩🇴"
        elif any(w in txt_lower for w in ["paraguay", "paraguayo", "asuncion"]):
            detected_c_code, detected_c_name, detected_c_emoji = "py", "Paraguay", "🇵🇾"
        elif any(w in txt_lower for w in ["nicaragua", "nicaragüense", "managua"]):
            detected_c_code, detected_c_name, detected_c_emoji = "ni", "Nicaragua", "🇳🇮"
        elif any(w in txt_lower for w in ["honduras", "hondureño", "tegucigalpa", "catracho"]):
            detected_c_code, detected_c_name, detected_c_emoji = "hn", "Honduras", "🇭🇳"
        elif any(w in txt_lower for w in ["cuba", "cubano", "la habana"]):
            detected_c_code, detected_c_name, detected_c_emoji = "cu", "Cuba", "🇨🇺"

    # 2. Búsqueda de Operador
    detected_operator = None
    for pattern, op_name in KNOWN_OPERATOR_PATTERNS:
        if pattern in txt_lower:
            detected_operator = op_name
            break

    # 3. Detección de Intenciones
    GREETING_WORDS = {"hola", "holaa", "holaaa", "buenas", "buen", "buenos", "saludos", "hey", "holi", "holis", "oe", "ola", "qhubo", "quehubo", "wena", "wenas"}
    GREETING_PHRASES = ["buen dia", "buen día", "buenos dias", "buenos días", "buenas tardes", "buenas noches", "que tal", "qué tal", "como estan", "cómo están", "como va", "cómo va", "saludos a todos", "hola a todos", "hola grupo", "q tal"]
    is_greeting = any(p in txt_lower for p in GREETING_PHRASES) or any(w in GREETING_WORDS for w in words)

    NOCONNECT_PHRASES = [
        "no conecta", "no me conecta", "no agarra", "no funciona", "falla", "error al conectar",
        "se desconecta", "se cae", "reconectando", "no da internet", "sin internet", "lento",
        "muy lento", "no me anda", "no abre", "bloqueado", "caducado", "expirado", "se cierra",
        "se queda pegado", "se queda conectando", "no pasa de conectando", "conectando y nada",
        "no entra", "se desconectó", "se corto", "se cortó", "timeout", "no me deja conectar",
        "no conecta nada", "no agarro nada", "no conecta bro"
    ]
    is_noconnect = any(p in txt_lower for p in NOCONNECT_PHRASES)

    FAILED_OUTCOME_PHRASES = [
        "sigue igual", "nada", "no sirvio", "no sirvió", "no funciono", "no funcionó",
        "no agarro", "no agarró", "sigue sin conectar", "sigue sin dar", "todavia no",
        "todavía no", "tampoco", "nada bro", "igual", "sigue fallando", "no dio",
        "no me funciono", "sigue sin andar", "no quiso", "no me sirvio"
    ]
    is_failed_outcome = any(p in txt_lower for p in FAILED_OUTCOME_PHRASES) or (txt_lower in ["no", "nop", "nada", "tampoco", "igual"])

    SUCCESS_OUTCOME_PHRASES = [
        "ya conecto", "ya conectó", "ya sirvio", "ya sirvió", "ya funciono", "ya funcionó",
        "ya me dio", "ya agarro", "ya agarró", "ya anda", "listo gracias", "funciono gracias",
        "ya quedo", "ya quedó", "excelente app", "excelente", "super", "súper", "genial",
        "buenisimo", "buenísimo", "muchas gracias", "gracias bro", "gracias amigo", "mil gracias",
        "la mejor app", "perfecto gracias", "gracias", "muchas gracias"
    ]
    is_success_outcome = any(p in txt_lower for p in SUCCESS_OUTCOME_PHRASES)

    HELP_PHRASES = [
        "ayuda", "necesito ayuda", "alguien me ayuda", "alguien que me ayude", "me ayudan",
        "como se usa", "cómo se usa", "como funciona", "cómo funciona", "como conectar",
        "cómo conectar", "como se conecta", "cómo se conecta", "que hago", "qué hago",
        "como configuro", "cómo configuro", "tutorial", "algun metodo", "algún método",
        "alguien sabe", "alguien me explica", "explicar", "guia", "guía"
    ]
    is_help = any(p in txt_lower for p in HELP_PHRASES)

    APPT_PHRASES = [
        "cita", "agendar", "hablar con cristian", "hablar con el admin", "hablar con el creador",
        "soporte personal", "contacto directo", "hablar con soporte", "contactar soporte", "hablar en privado"
    ]
    is_appointment = any(p in txt_lower for p in APPT_PHRASES)

    DOWNLOAD_PHRASES = [
        "descargar", "descarga", "link", "playstore", "play store", "donde descargo",
        "dónde descargo", "apk", "instalar app", "instalar", "la app", "link de la app", "actualizar app"
    ]
    is_download = any(p in txt_lower for p in DOWNLOAD_PHRASES)

    ACCOUNT_PHRASES = [
        "cuenta", "cuentas", "comprar", "precio", "precios", "cuanto cuesta", "cuánto cuesta",
        "vip", "premium", "renovar", "venden cuentas", "vendes", "demo", "prueba", "pago", "costo",
        "distribuidor", "revendedor", "panel"
    ]
    is_account = any(p in txt_lower for p in ACCOUNT_PHRASES)

    return {
        "country_code": detected_c_code,
        "country_name": detected_c_name,
        "country_emoji": detected_c_emoji,
        "operator": detected_operator,
        "is_greeting": is_greeting,
        "is_noconnect": is_noconnect,
        "is_failed_outcome": is_failed_outcome,
        "is_success_outcome": is_success_outcome,
        "is_help": is_help,
        "is_appointment": is_appointment,
        "is_download": is_download,
        "is_account": is_account,
        "raw_text": text
    }

def handle_group_ai_support(chat_id, user_id, first_name, text, msg_id, chat_type="supergroup"):
    now = time.time()
    # Cooldown por usuario en grupos (12s) para no saturar
    if chat_type != "private":
        if user_id in group_user_cooldown and (now - group_user_cooldown[user_id]) < 12:
            return

    ctx = get_or_create_user_context(user_id, first_name)
    parsed = extract_entities_and_intent(text, ctx)
    update_user_context_history(user_id, "user", text)

    # Actualizar entidades recordadas en la memoria del usuario
    if parsed["country_code"]:
        ctx["country_code"] = parsed["country_code"]
        ctx["country_name"] = parsed["country_name"]
        ctx["country_emoji"] = parsed["country_emoji"]
    if parsed["operator"]:
        ctx["operator"] = parsed["operator"]

    user_c_name = ctx.get("country_name") or ""
    user_c_emoji = ctx.get("country_emoji") or ""
    user_op = ctx.get("operator") or ""
    current_state = ctx.get("state", "IDLE")
    current_step = ctx.get("step", 0)

    # ─────────────────────────────────────────────────────────────────
    # 1. CASO: RESOLUCIÓN EXITOSA O AGRADECIMIENTO (Multi-Turn Outcome)
    # ─────────────────────────────────────────────────────────────────
    if parsed["is_success_outcome"]:
        group_user_cooldown[user_id] = now
        ctx["state"] = "RESOLVED"
        ctx["step"] = 0
        ctx["last_topic"] = "resolved"

        op_txt = f" en <b>{user_op}</b>" if user_op else ""
        c_txt = f" ({user_c_emoji} {user_c_name})" if user_c_name else ""

        reply = (
            f"⚡ <b>¡Excelente noticia {first_name}!</b> 🚀\n\n"
            f"Me alegra mucho saber que ya tienes conexión activa y navegando a máxima velocidad{op_txt}{c_txt} con <b>{APP_NAME}</b>.\n\n"
            f"⭐ Recuerda apoyarnos calificando la app con <b>5 estrellas</b> en Google Play y recomendándola a tus conocidos.\n\n"
            f"¡Que disfrutes tu internet sin límites!"
        )
        markup = {
            "inline_keyboard": [
                [{"text": "⭐ Calificar en Google Play", "url": PLAYSTORE_URL}],
                [{"text": "👥 Invitar al Grupo", "url": f"https://t.me/{GROUP_USERNAME}"}]
            ]
        }
        update_user_context_history(user_id, "bot", reply)
        send_message(chat_id, reply, reply_markup=markup, reply_to_message_id=msg_id)
        return

    # ─────────────────────────────────────────────────────────────────
    # 2. CASO: SEGUIMIENTO DE FALLA EN DIAGNÓSTICO (Follow-up: "Sigue igual", "No conectó")
    # ─────────────────────────────────────────────────────────────────
    if parsed["is_failed_outcome"] or (current_state in ["STEP_AIRPLANE", "STEP_UPDATE_SERVER"] and not parsed["is_greeting"]):
        group_user_cooldown[user_id] = now

        if current_step <= 1 or current_state == "STEP_AIRPLANE":
            # Avanzar a Paso 2: Actualizar servidores en app y cambiar método/SlowDNS
            ctx["state"] = "STEP_UPDATE_SERVER"
            ctx["step"] = 2
            ctx["last_topic"] = "troubleshoot"

            # Buscar servidores reales del operador en la base de datos de la nube
            servers, version, _ = search_servers_dynamic(user_op if user_op else "ssh", max_results=3)
            srv_hint = f"\n👉 Prueba el servidor: <code>{servers[0]}</code>" if servers else ""

            op_desc = f"{user_op} {user_c_name}".strip() or "tu operador"
            reply = (
                f"🔧 <b>Entendido {first_name}, pasemos al Paso 2 para {op_desc}:</b>\n\n"
                f"1️⃣ Abre la app y presiona el botón <b>Actualizar (🔄)</b> arriba para cargar los servidores más recientes (<code>v{version}</code>).\n"
                f"2️⃣ Toca la <b>Lupa (🔍)</b> en la lista de servidores y busca un método alternativo.{srv_hint}\n"
                f"3️⃣ Si tu línea está <b>totalmente sin saldo</b>, selecciona un servidor marcado como <b>SLOWDNS</b> o <b>UDP</b>.\n\n"
                f"📲 <i>Prueba ese servidor y cuéntame si te conecta, o envía una <b>captura de pantalla</b> aquí para ver el error exacto.</i>"
            )
            markup = {
                "inline_keyboard": [
                    [{"text": "🛠️ Guía Completa de Fallas", "url": "https://t.me/CrisDevVpnBot?start=fallas"}],
                    [{"text": "📅 Agendar Soporte", "url": "https://t.me/CrisDevVpnBot?start=cita"}]
                ]
            }
            update_user_context_history(user_id, "bot", reply)
            send_message(chat_id, reply, reply_markup=markup, reply_to_message_id=msg_id)
            return

        elif current_step >= 2 or current_state == "STEP_UPDATE_SERVER":
            # Avanzar a Paso 3: Análisis de tipo de línea (Redes vs Saldo 0) y Soporte Directo
            ctx["state"] = "STEP_SLOWDNS_REDES"
            ctx["step"] = 3
            ctx["last_topic"] = "troubleshoot"

            op_desc = f"{user_op} {user_c_name}".strip() or "tu línea"
            reply = (
                f"⚠️ <b>{first_name}, para resolver definitivamente en {op_desc}:</b>\n\n"
                f"1️⃣ ¿Tienes paquete de redes activas (WhatsApp / Redes) o tu chip está <b>en $0 pesos sin ningún paquete</b>?\n"
                f"2️⃣ Envía una <b>captura de pantalla</b> de la pestaña <b>REGISTRO (LOGS)</b> de la app aquí en el grupo.\n\n"
                f"💬 También puedes agendar una revisión directa con <b>Cristian (@{ADMIN_USERNAME})</b>:"
            )
            markup = {
                "inline_keyboard": [
                    [{"text": "📅 Agendar Soporte con Cristian", "url": "https://t.me/CrisDevVpnBot?start=cita"}],
                    [{"text": "💬 Contactar a @Crisis1823", "url": f"https://t.me/{ADMIN_USERNAME}"}]
                ]
            }
            update_user_context_history(user_id, "bot", reply)
            send_message(chat_id, reply, reply_markup=markup, reply_to_message_id=msg_id)
            return

    # ─────────────────────────────────────────────────────────────────
    # 3. CASO: REPORTE INICIAL DE FALLA DE CONEXIÓN
    # ─────────────────────────────────────────────────────────────────
    if parsed["is_noconnect"]:
        group_user_cooldown[user_id] = now
        ctx["state"] = "STEP_AIRPLANE"
        ctx["step"] = 1
        ctx["last_topic"] = "troubleshoot"

        op_txt = f" en <b>{user_op}</b>" if user_op else ""
        c_txt = f" ({user_c_emoji} {user_c_name})" if user_c_name else ""

        reply = (
            f"🛠️ <b>Diagnóstico de Conexión — {APP_NAME}</b> 🛠️\n\n"
            f"Hola {first_name}, vamos a solucionar el inconveniente de conexión{op_txt}{c_txt}.\n\n"
            f"👉 <b>Paso 1 (Renovar IP Móvil):</b>\n"
            f"Activa el <b>Modo Avión ✈️</b> en tu teléfono durante 5 segundos y vuelve a desactivarlo. Esto obliga a tu operadora a asignarte una IP limpia. Luego presiona <b>CONECTAR</b>.\n\n"
            f"💬 <i>¿Hiciste el Modo Avión? Cuéntame si ya te conectó o si sigue igual para darte el siguiente paso.</i>"
        )
        markup = {
            "inline_keyboard": [
                [{"text": "🛠️ Ver Solución de Fallas", "url": "https://t.me/CrisDevVpnBot?start=fallas"}],
                [{"text": "📅 Agendar Soporte", "url": "https://t.me/CrisDevVpnBot?start=cita"}]
            ]
        }
        update_user_context_history(user_id, "bot", reply)
        send_message(chat_id, reply, reply_markup=markup, reply_to_message_id=msg_id)
        return

    # ─────────────────────────────────────────────────────────────────
    # 4. CASO: MENCIÓN DE OPERADOR O PAÍS ESPECÍFICO
    # ─────────────────────────────────────────────────────────────────
    if parsed["operator"] or parsed["country_code"]:
        group_user_cooldown[user_id] = now
        ctx["state"] = "WAITING_STATUS"
        ctx["last_topic"] = "search_servers"

        if user_op:
            servers, version, _ = search_servers_dynamic(user_op, max_results=5)
            srv_list = "\n".join([f"🔹 <code>{s}</code>" for s in servers]) if servers else f"🔹 Servidores de {user_op} disponibles en la app."
            c_header = f"{user_c_emoji} {user_c_name}" if user_c_name else ""

            reply = (
                f"📶 <b>SERVIDORES DISPONIBLES: {user_op.upper()} {c_header}</b>\n"
                f"━━━━━━━━━━━━━━━━━━━━\n"
                f"📦 <b>Versión en Nube:</b> <code>v{version}</code>\n\n"
                f"🟢 <b>Métodos Activos Hoy en {APP_NAME}:</b>\n"
                f"{srv_list}\n\n"
                f"🔍 <b>¿Cómo encontrarlo?</b> Abre la app, presiona <b>Actualizar (🔄)</b> y busca <code>{user_op}</code>.\n\n"
                f"💬 <i>{first_name}, ¿ya estás conectado o presentas alguna falla al intentar conectar?</i>"
            )
            markup = {
                "inline_keyboard": [
                    [{"text": "🌐 Ver Todos los Países", "url": "https://t.me/CrisDevVpnBot?start=paises"}],
                    [{"text": "📥 Descargar App", "url": PLAYSTORE_URL}]
                ]
            }
            update_user_context_history(user_id, "bot", reply)
            send_message(chat_id, reply, reply_markup=markup, reply_to_message_id=msg_id)
            return

        elif parsed["country_code"]:
            reply = format_live_country_response(parsed["country_code"])
            reply += f"\n\n💬 <i>{first_name}, ¿qué operador usas en {user_c_name} (ej: Claro, Movistar, Tigo, Telcel)?</i>"
            markup = {
                "inline_keyboard": [
                    [{"text": "📥 Descargar en Google Play", "url": PLAYSTORE_URL}],
                    [{"text": "📅 Agendar Consulta", "url": "https://t.me/CrisDevVpnBot?start=cita"}]
                ]
            }
            update_user_context_history(user_id, "bot", reply)
            send_message(chat_id, reply, reply_markup=markup, reply_to_message_id=msg_id)
            return

    # ─────────────────────────────────────────────────────────────────
    # 5. CASO: SALUDOS / CONVERSACIÓN INICIAL (Greetings)
    # ─────────────────────────────────────────────────────────────────
    if parsed["is_greeting"]:
        group_user_cooldown[user_id] = now
        ctx["state"] = "GREETED"
        ctx["last_topic"] = "greeting"

        if user_op or user_c_name:
            c_info = f" ({user_c_emoji} {user_c_name})" if user_c_name else ""
            op_info = f" con <b>{user_op}</b>" if user_op else ""
            reply = (
                f"⚡ <b>¡Hola de nuevo {first_name}! Un gusto saludarte.</b> ⚡\n\n"
                f"Recuerdo que utilizas{op_info}{c_info}.\n\n"
                f"¿En qué te puedo colaborar hoy?\n"
                f"🔹 <b>1.</b> ¿Consultar nuevos servidores y métodos?\n"
                f"🔹 <b>2.</b> ¿Solucionar alguna falla de conexión?\n"
                f"🔹 <b>3.</b> ¿Agendar soporte personalizado con Cristian?\n\n"
                f"Escribe tu duda o toca una opción abajo:"
            )
        else:
            reply = (
                f"⚡ <b>¡Hola {first_name}! Un gusto saludarte. Soy el Asistente Oficial de {APP_NAME}</b> ⚡\n\n"
                f"Estoy aquí para ayudarte con todo lo relacionado a tu conexión:\n\n"
                f"👉 <b>¿De qué país eres o qué operador tienes</b> (ej: <i>Claro, Tigo, Movistar, Telcel, Bait</i>)? Así te diré los métodos que están activos y funcionando al 100% hoy.\n\n"
                f"📸 <i>Tip: También puedes enviar una <b>captura de pantalla</b> de tu app si tienes dudas con algún error.</i>"
            )

        markup = {
            "inline_keyboard": [
                [{"text": "📥 Descargar / Actualizar App", "url": PLAYSTORE_URL}],
                [
                    {"text": "🌐 Ver Países y Servidores", "url": "https://t.me/CrisDevVpnBot?start=paises"},
                    {"text": "📅 Solicitar Soporte / Cita", "url": "https://t.me/CrisDevVpnBot?start=cita"}
                ]
            ]
        }
        update_user_context_history(user_id, "bot", reply)
        send_message(chat_id, reply, reply_markup=markup, reply_to_message_id=msg_id)
        return

    # ─────────────────────────────────────────────────────────────────
    # 6. CASO: AYUDA GENERAL / TUTORIAL / CÓMO USAR
    # ─────────────────────────────────────────────────────────────────
    if parsed["is_help"]:
        group_user_cooldown[user_id] = now
        ctx["state"] = "HELP"
        ctx["last_topic"] = "general_help"

        reply = (
            f"💡 <b>¡Hola {first_name}! Conectarse en {APP_NAME} es muy rápido y fácil:</b>\n\n"
            f"1️⃣ Abre la app <a href=\"{PLAYSTORE_URL}\"><b>{APP_NAME}</b></a> y pulsa el botón <b>Actualizar (🔄)</b> en la barra superior.\n"
            f"2️⃣ Selecciona la bandera de tu país o usa la <b>Lupa (🔍)</b> para buscar tu operador (ej: <i>Claro, Movistar, Tigo, Telcel</i>).\n"
            f"3️⃣ Elige el servidor deseado y presiona <b>CONECTAR</b>.\n\n"
            f"📸 <i>Si te sale algún error, manda una captura aquí en el grupo y te diré qué hacer.</i>"
        )
        markup = {
            "inline_keyboard": [
                [{"text": "🛠️ Guía Paso a Paso", "url": "https://t.me/CrisDevVpnBot?start=buscar"}],
                [
                    {"text": "🌐 Ver Servidores Activos", "url": "https://t.me/CrisDevVpnBot?start=paises"},
                    {"text": "📅 Agendar Soporte", "url": "https://t.me/CrisDevVpnBot?start=cita"}
                ]
            ]
        }
        update_user_context_history(user_id, "bot", reply)
        send_message(chat_id, reply, reply_markup=markup, reply_to_message_id=msg_id)
        return

    # ─────────────────────────────────────────────────────────────────
    # 7. CASO: CITAS / HABLAR CON ADMINISTRADOR
    # ─────────────────────────────────────────────────────────────────
    if parsed["is_appointment"]:
        group_user_cooldown[user_id] = now
        reply = (
            f"👋 ¡Hola {first_name}! Puedes agendar una cita o comunicarte directamente con <b>Cristian (@{ADMIN_USERNAME})</b>:\n\n"
            f"📅 <i>Toca el botón de abajo para enviar tu consulta y te atenderá a la brevedad posible.</i>"
        )
        markup = {
            "inline_keyboard": [
                [{"text": "📅 Agendar Cita en Privado", "url": "https://t.me/CrisDevVpnBot?start=cita"}],
                [{"text": "💬 Escribir a @Crisis1823", "url": f"https://t.me/{ADMIN_USERNAME}"}]
            ]
        }
        update_user_context_history(user_id, "bot", reply)
        send_message(chat_id, reply, reply_markup=markup, reply_to_message_id=msg_id)
        return

    # ─────────────────────────────────────────────────────────────────
    # 8. CASO: DESCARGAS / LINK PLAY STORE
    # ─────────────────────────────────────────────────────────────────
    if parsed["is_download"]:
        group_user_cooldown[user_id] = now
        reply = (
            f"📱 <b>DESCARGA OFICIAL — {APP_NAME} ⚡</b>\n\n"
            f"👋 ¡Hola {first_name}! Puedes descargar e instalar la aplicación oficial directamente desde Google Play Store:\n\n"
            f"🔗 <a href=\"{PLAYSTORE_URL}\"><b>Instalar {APP_NAME} en Google Play</b></a>\n\n"
            f"📲 <i>Al instalar, ábrela y presiona el botón <b>Actualizar (🔄)</b> para cargar la lista más reciente de servidores.</i>"
        )
        markup = {
            "inline_keyboard": [
                [{"text": "📥 Instalar en Google Play", "url": PLAYSTORE_URL}],
                [{"text": "🔍 ¿Cómo Buscar Servidores?", "url": "https://t.me/CrisDevVpnBot?start=buscar"}]
            ]
        }
        update_user_context_history(user_id, "bot", reply)
        send_message(chat_id, reply, reply_markup=markup, reply_to_message_id=msg_id)
        return

    # ─────────────────────────────────────────────────────────────────
    # 9. CASO: CUENTAS PRIVADAS / COMPRA / VIP / REVENTA
    # ─────────────────────────────────────────────────────────────────
    if parsed["is_account"]:
        group_user_cooldown[user_id] = now
        reply = (
            f"💎 <b>ATENCIÓN Y CUENTAS PRIVADAS — {APP_NAME}</b> 💎\n\n"
            f"La aplicación cuenta con servidores públicos y gratuitos para la comunidad. Si requieres cuentas dedicadas, servidores privados de alta velocidad o soporte para revendedores:\n\n"
            f"👉 <b>Administrador Oficial:</b> @{ADMIN_USERNAME}\n"
            f"💬 <b>Comunidad:</b> @{GROUP_USERNAME}"
        )
        markup = {
            "inline_keyboard": [
                [{"text": "📅 Agendar Cita con Cristian", "url": "https://t.me/CrisDevVpnBot?start=cita"}],
                [{"text": "💬 Contactar a @Crisis1823", "url": f"https://t.me/{ADMIN_USERNAME}"}]
            ]
        }
        update_user_context_history(user_id, "bot", reply)
        send_message(chat_id, reply, reply_markup=markup, reply_to_message_id=msg_id)
        return

    # ─────────────────────────────────────────────────────────────────
    # 10. FALLBACK EN PRIVADO (Menú asistido para texto libre)
    # ─────────────────────────────────────────────────────────────────
    if chat_type == "private":
        welcome_private = (
            f"⚡ <b>Hola {first_name}, soy el Asistente de {APP_NAME}</b> ⚡\n\n"
            f"Puedes usar el menú interactivo para consultar servidores, aprender a buscar métodos o resolver problemas:"
        )
        update_user_context_history(user_id, "bot", welcome_private)
        send_message(chat_id, welcome_private, reply_markup=get_main_menu_markup(), reply_to_message_id=msg_id)


# ═════════════════════════════════════════════════════════════════════
# MANEJADOR PRINCIPAL DE MENSAJES, FOTOS Y COMANDOS
# ═════════════════════════════════════════════════════════════════════
def handle_message(msg):
    chat = msg.get("chat", {})
    chat_id = chat.get("id")
    chat_type = chat.get("type", "private")
    from_user = msg.get("from", {})
    user_id = from_user.get("id")
    username = from_user.get("username", "")
    first_name = from_user.get("first_name", "Amigo")
    text = msg.get("text", "").strip()
    msg_id = msg.get("message_id")

    # ── VERIFICACIÓN DE EMISOR ADMINISTRADOR / CANAL / DUEÑO ──
    is_admin_sender = (chat_type != "private" and is_user_group_admin(chat_id, user_id, username, msg)) or (user_id in ADMIN_IDS)

    # ── GESTIÓN DE SOLICITUD DE CITA / CONTACTO PENDIENTE ──
    if user_id in pending_user_appointments and chat_type == "private":
        del pending_user_appointments[user_id]
        now_date_str = datetime.datetime.now().strftime("%d/%m/%Y %H:%M:%S")
        user_link = f"@{username}" if username else f"<a href=\"tg://user?id={user_id}\">{first_name}</a>"

        # Notificación al Administrador
        admin_notice = (
            f"🔔 <b>NUEVA SOLICITUD DE CITA / ATENCIÓN</b> 🔔\n"
            f"━━━━━━━━━━━━━━━━━━━━\n"
            f"👤 <b>Usuario:</b> {first_name} ({user_link})\n"
            f"🆔 <b>ID Telegram:</b> <code>{user_id}</code>\n"
            f"📅 <b>Fecha:</b> <code>{now_date_str}</code>\n\n"
            f"📝 <b>Motivo de la Solicitud:</b>\n"
            f"<i>\"{text}\"</i>\n"
            f"━━━━━━━━━━━━━━━━━━━━\n"
            f"👉 <a href=\"tg://user?id={user_id}\"><b>Abrir chat directo con el usuario</b></a>"
        )
        for adm in ADMIN_IDS:
            send_message(adm, admin_notice)

        # Confirmación al Usuario
        user_confirm = (
            f"✅ <b>¡SOLICITUD ENVIADA CON ÉXITO!</b> ✅\n"
            f"━━━━━━━━━━━━━━━━━━━━\n"
            f"Tu mensaje ha sido remitido directamente a la bandeja privada de <b>Cristian (@{ADMIN_USERNAME})</b>.\n\n"
            f"📱 Se pondrá en contacto contigo en breve para brindarte la atención solicitada.\n"
            f"━━━━━━━━━━━━━━━━━━━━\n"
            f"⚡ ¡Gracias por confiar en {APP_NAME}!"
        )
        send_message(chat_id, user_confirm, reply_markup=get_main_menu_markup())
        return

    # ── DETECCIÓN Y ANÁLISIS DE CAPTURAS DE PANTALLA (FOTOS) CON OCR VISION ──
    if "photo" in msg:
        if is_admin_sender and chat_type != "private":
            return
        photos = msg["photo"]
        largest_photo = photos[-1]
        file_id = largest_photo.get("file_id")
        if file_id:
            img_bytes = download_telegram_file(file_id)
            if img_bytes:
                ctx = get_or_create_user_context(user_id, first_name, username)
                screen_type, guidance_text, detected_c = analyze_screenshot_ocr(img_bytes, user_ctx=ctx)
                
                update_user_context_history(user_id, "user", "[Captura de pantalla enviada]")
                update_user_context_history(user_id, "bot", guidance_text)

                if screen_type == "servers_screen":
                    markup = get_dynamic_countries_markup()
                elif screen_type == "home_screen":
                    markup = get_main_menu_markup()
                elif screen_type == "logs_screen":
                    markup = {
                        "inline_keyboard": [
                            [{"text": "🛠️ Solución de Fallas", "callback_data": "guide_troubleshoot"}],
                            [{"text": "📅 Agendar Soporte", "url": "https://t.me/CrisDevVpnBot?start=cita"}]
                        ]
                    }
                else:
                    markup = get_dynamic_countries_markup()
                
                send_message(chat_id, guidance_text, reply_markup=markup, reply_to_message_id=msg_id)
        return

    # ── BIENVENIDA A NUEVOS MIEMBROS EN EL GRUPO ──
    if "new_chat_members" in msg:
        for new_member in msg["new_chat_members"]:
            if new_member.get("is_bot"):
                continue
            name = new_member.get("first_name", "Amigo")
            welcome_text = (
                f"👋 <b>¡Bienvenido/a {name} a la comunidad oficial de {APP_NAME} ⚡!</b>\n\n"
                f"🚀 <i>Disfruta de internet de alta velocidad, streaming sin cortes y servidores actualizados en vivo para Claro, Tigo, Movistar, Telcel, Bait y más.</i>\n\n"
                f"📥 <b>Descarga la App en Google Play:</b>\n"
                f"🔗 <a href=\"{PLAYSTORE_URL}\">Click aquí para instalar</a>\n\n"
                f"📸 <i>¡Si tienes dudas con alguna pantalla, envía una captura aquí y te guiaré paso a paso!</i>"
            )
            markup = {
                "inline_keyboard": [
                    [{"text": "📥 Descargar en Google Play", "url": PLAYSTORE_URL}],
                    [
                        {"text": "🌐 Ver Países y Servidores", "url": "https://t.me/CrisDevVpnBot?start=paises"},
                        {"text": "📅 Agendar Soporte", "url": "https://t.me/CrisDevVpnBot?start=cita"}
                    ]
                ]
            }
            send_message(chat_id, welcome_text, reply_markup=markup)
        return

    if not text:
        return

    cmd = text.split()[0].lower() if text else ""

    # ── COMANDO /start ──
    if cmd in ["/start", "/start@crisdevvpnbot"]:
        if text.endswith("paises"):
            cmd = "/paises"
        elif text.endswith("buscar"):
            cmd = "/buscar"
        elif text.endswith("fallas"):
            cmd = "/fallas"
        elif text.endswith("cita") or text.endswith("contacto"):
            cmd = "/cita"
        else:
            with data_lock:
                version = cached_servers_data.get("version", "1.0.0")
                total = cached_servers_data.get("total", 0)

            welcome_msg = (
                f"⚡ <b>¡Hola {first_name}! Asistente Oficial de {APP_NAME}</b> ⚡\n\n"
                f"Centro de soporte inteligente conectado en tiempo real con servidores en la nube.\n\n"
                f"📱 <b>Aplicación Oficial:</b> <a href=\"{PLAYSTORE_URL}\">{APP_NAME}</a>\n"
                f"📦 <b>Versión de Servidores:</b> <code>v{version}</code> (<b>{total} servidores activos</b>)\n\n"
                f"📸 <i>Tip: Puedes enviarme una <b>captura de pantalla</b> de la app y te diré exactamente qué hacer.</i>\n\n"
                f"🛠️ <i>Selecciona una opción en el menú:</i>"
            )
            if user_id in ADMIN_IDS:
                welcome_msg += (
                    f"\n\n👑 <b>Panel de Administrador:</b>\n"
                    f"🔸 <code>/sync</code> - Forzar sincronización en la nube.\n"
                    f"🔸 <code>/status</code> - Estado del servidor VPS.\n"
                    f"🔸 <code>/crear &lt;user&gt; &lt;pass&gt; [días] [límite]</code>\n"
                    f"🔸 <code>/eliminar &lt;user&gt;</code>"
                )
            send_message(chat_id, welcome_msg, reply_markup=get_main_menu_markup())
            return

    # ── COMANDO /cita o /contacto ──
    if cmd in ["/cita", "/contacto", "/cita@crisdevvpnbot", "/contacto@crisdevvpnbot"]:
        if chat_type == "private":
            pending_user_appointments[user_id] = True
            send_message(chat_id, get_appointment_prompt_text())
        else:
            send_message(
                chat_id,
                f"👋 {first_name}, para agendar tu consulta o hablar con el creador en privado, presiona el botón abajo:",
                reply_markup={
                    "inline_keyboard": [
                        [{"text": "📅 Agendar Consulta en Privado", "url": "https://t.me/CrisDevVpnBot?start=cita"}]
                    ]
                },
                reply_to_message_id=msg_id
            )
        return

    # ── COMANDO /paises o /operadores ──
    if cmd in ["/paises", "/operadores", "/paises@crisdevvpnbot", "/operadores@crisdevvpnbot"]:
        text_menu = (
            f"🌐 <b>SELECCIONA TU PAÍS PARA VER LOS SERVIDORES EN VIVO</b> 🌐\n\n"
            f"Elige tu país para consultar la lista exacta de servidores y operadores activos hoy en <a href=\"{PLAYSTORE_URL}\">{APP_NAME}</a>:"
        )
        send_message(chat_id, text_menu, reply_markup=get_dynamic_countries_markup())
        return

    # ── COMANDO /buscar o /servidores ──
    if cmd in ["/buscar", "/servidores", "/buscar@crisdevvpnbot", "/servidores@crisdevvpnbot"]:
        parts = text.split(maxsplit=1)
        if len(parts) > 1:
            q = parts[1]
            servers, version, total_db = search_servers_dynamic(q, max_results=8)
            res_text = (
                f"🔍 <b>RESULTADOS DE BÚSQUEDA PARA '{q.upper()}'</b>\n"
                f"━━━━━━━━━━━━━━━━━━━━\n"
                f"📦 <b>Versión de Servidores:</b> <code>v{version}</code>\n\n"
            )
            if servers:
                for s in servers:
                    res_text += f"🔹 <code>{s}</code>\n"
            else:
                res_text += f"❌ No se encontraron servidores con el término '<i>{q}</i>'.\n"

            res_text += (
                f"\n📲 <b>Para encontrarlo en la app:</b>\n"
                f"1. Abre la app y presiona <b>Actualizar (🔄)</b>.\n"
                f"2. Toca el <b>Buscador (🔍)</b> en la lista de servidores y escribe <code>{q}</code>.\n"
                f"3. Selecciona tu servidor y presiona <b>CONECTAR</b>."
            )
            send_message(chat_id, res_text, reply_markup=get_main_menu_markup())
        else:
            send_message(chat_id, "💡 <b>Uso correcto:</b> <code>/buscar &lt;operador o país&gt;</code>\nEjemplo: <code>/buscar claro</code> o <code>/buscar telcel</code>")
        return

    # ── COMANDO /guia, /conectar, /tutorial, /ayuda ──
    if cmd in ["/guia", "/conectar", "/tutorial", "/ayuda", "/guia@crisdevvpnbot", "/conectar@crisdevvpnbot", "/tutorial@crisdevvpnbot", "/ayuda@crisdevvpnbot"]:
        send_message(chat_id, get_search_guide_text(), reply_markup=get_main_menu_markup())
        return

    # ── COMANDO /actualizar ──
    if cmd in ["/actualizar", "/actualizar@crisdevvpnbot"]:
        send_message(chat_id, get_update_guide_text(), reply_markup=get_main_menu_markup())
        return

    # ── COMANDO /fallas o /noconecta ──
    if cmd in ["/fallas", "/noconecta", "/fallas@crisdevvpnbot", "/noconecta@crisdevvpnbot"]:
        send_message(chat_id, get_troubleshoot_text(), reply_markup=get_main_menu_markup())
        return

    # ── COMANDO /descargar o /app ──
    if cmd in ["/descargar", "/app", "/playstore", "/descargar@crisdevvpnbot", "/app@crisdevvpnbot"]:
        with data_lock:
            version = cached_servers_data.get("version", "1.0.0")
            total = cached_servers_data.get("total", 0)

        download_text = (
            f"📱 <b>DESCARGA OFICIAL — {APP_NAME}</b>\n"
            f"━━━━━━━━━━━━━━━━━━━━\n"
            f"⚡ La aplicación más rápida, ligera y optimizada para internet ilimitado.\n\n"
            f"✅ <b>{total} Servidores en Nube</b> (Versión v{version}).\n"
            f"✅ Buscador en vivo y selector por banderas de país.\n"
            f"✅ Compatible con todas las versiones de Android.\n\n"
            f"🔗 <b>Google Play Store:</b>\n"
            f"{PLAYSTORE_URL}"
        )
        markup = {
            "inline_keyboard": [
                [{"text": "📥 Instalar desde Google Play", "url": PLAYSTORE_URL}],
                [{"text": "🔍 ¿Cómo Buscar Servidores?", "callback_data": "guide_search"}]
            ]
        }
        send_message(chat_id, download_text, reply_markup=markup)
        return

    # ── COMANDO /info ──
    if cmd in ["/info", "/info@crisdevvpnbot"]:
        send_message(chat_id, format_global_summary(), reply_markup=get_main_menu_markup())
        return

    # ── COMANDO /soporte ──
    if cmd in ["/soporte", "/soporte@crisdevvpnbot"]:
        soporte_text = (
            f"📞 <b>ATENCIÓN Y SOPORTE OFICIAL — {APP_NAME}</b>\n\n"
            f"¿Tienes alguna consulta especial o requieres asistencia personalizada?\n\n"
            f"👤 <b>Administrador:</b> @{ADMIN_USERNAME}\n"
            f"👥 <b>Grupo de la Comunidad:</b> @{GROUP_USERNAME}\n"
            f"📱 <b>Play Store:</b> <a href=\"{PLAYSTORE_URL}\">{APP_NAME}</a>"
        )
        markup = {
            "inline_keyboard": [
                [{"text": "📅 Agendar Cita / Soporte", "url": "https://t.me/CrisDevVpnBot?start=cita"}],
                [{"text": "💬 Escribir al Administrador", "url": f"https://t.me/{ADMIN_USERNAME}"}],
                [{"text": "👥 Entrar al Grupo", "url": f"https://t.me/{GROUP_USERNAME}"}]
            ]
        }
        send_message(chat_id, soporte_text, reply_markup=markup)
        return

    # ── VERIFICACIÓN Y CONTROL DE COMANDOS EXCLUSIVOS DE ADMINISTRADOR ──
    ADMIN_COMMANDS = [
        "/sync", "/actualizar_servidores", "/reload",
        "/status", "/servidor", "/stats",
        "/crear", "/eliminar"
    ]
    if any(cmd.startswith(ac) for ac in ADMIN_COMMANDS):
        if user_id not in ADMIN_IDS:
            send_message(chat_id, "⛔ <b>Acceso Restringido:</b> Esta función es exclusiva de la administración.", reply_to_message_id=msg_id)
            return

        # 1. Comando /sync
        if cmd in ["/sync", "/actualizar_servidores", "/reload"]:
            ok, msg_sync = fetch_and_sync_servers()
            if ok:
                send_message(chat_id, f"✔ <b>Sincronización Exitosa:</b>\n{msg_sync}")
            else:
                send_message(chat_id, "❌ Error al sincronizar los servidores desde la nube.")
            return

        # 2. Comando /status
        if cmd in ["/status", "/servidor", "/stats"]:
            stats = get_system_stats()
            with data_lock:
                version = cached_servers_data.get("version", "1.0.0")
                total = cached_servers_data.get("total", 0)
                last_sync = cached_servers_data.get("last_sync", "N/A")

            status_text = (
                f"👑 <b>ESTADO DEL SISTEMA (ADMIN)</b> 👑\n"
                f"━━━━━━━━━━━━━━━━━━━━\n"
                f"☁️ <b>Servidores en Nube:</b> <b>Sincronizado [✔]</b>\n"
                f"📦 <b>Versión de Servidores:</b> <code>v{version}</code> (<b>{total} servidores activos</b>)\n"
                f"⏱️ <b>Última Sincronización:</b> <code>{last_sync}</code>\n"
                f"🧠 <b>Memoria RAM VPS:</b> {stats['ram_used']}MB / {stats['ram_tot']}MB ({stats['ram_pct']}%)\n"
                f"⏱️ <b>Uptime VPS:</b> {stats['uptime']}\n"
                f"👥 <b>Usuarios Registrados:</b> {stats['users']}\n"
                f"🟢 <b>Conexiones Activas:</b> {stats['online']}\n"
                f"🛡️ <b>Guardián Watchdog:</b> <b>ACTIVO [✔]</b>\n"
                f"🤖 <b>Bot Telegram:</b> <b>ONLINE [✔]</b>\n"
                f"━━━━━━━━━━━━━━━━━━━━"
            )
            send_message(chat_id, status_text)
            return

        # 3. Comando /crear
        if cmd == "/crear":
            parts = text.split()
            if len(parts) < 3:
                send_message(chat_id, "⚠️ <b>Uso correcto:</b> <code>/crear &lt;usuario&gt; &lt;clave&gt; [días=30] [límite=1]</code>")
                return
            new_u = parts[1]
            new_p = parts[2]
            dias = int(parts[3]) if len(parts) > 3 and parts[3].isdigit() else 30
            limite = int(parts[4]) if len(parts) > 4 and parts[4].isdigit() else 1

            if create_ssh_user(new_u, new_p, days=dias, limit=limite):
                exp_date = (datetime.datetime.now() + datetime.timedelta(days=dias)).strftime("%d/%m/%Y")
                created_msg = (
                    f"✔ <b>CUENTA CREADA CON ÉXITO</b>\n"
                    f"━━━━━━━━━━━━━━━━━━━━\n"
                    f"👤 <b>Usuario:</b> <code>{new_u}</code>\n"
                    f"🔑 <b>Contraseña:</b> <code>{new_p}</code>\n"
                    f"📅 <b>Vencimiento:</b> <b>{exp_date}</b> ({dias} días)\n"
                    f"🔢 <b>Límite de Dispositivos:</b> <b>{limite}</b>\n"
                    f"📱 <b>App:</b> <a href=\"{PLAYSTORE_URL}\">{APP_NAME}</a>\n"
                    f"━━━━━━━━━━━━━━━━━━━━"
                )
                send_message(chat_id, created_msg)
            else:
                send_message(chat_id, f"❌ Error al crear el usuario <code>{new_u}</code>.")
            return

        # 4. Comando /eliminar
        if cmd == "/eliminar":
            parts = text.split()
            if len(parts) < 2:
                send_message(chat_id, "⚠️ <b>Uso correcto:</b> <code>/eliminar &lt;usuario&gt;</code>")
                return
            del_u = parts[1]
            subprocess.run(f"userdel -f {del_u} 2>/dev/null", shell=True)
            subprocess.run(f"sed -i '/^{del_u} /d' /etc/SSHPlus/usuarios.db 2>/dev/null", shell=True)
            send_message(chat_id, f"🗑️ Usuario <code>{del_u}</code> eliminado del sistema.")
            return

    # ── MÓDULO INTELIGENTE DE SOPORTE PARA MENSAJES NATURALES EN GRUPO O PRIVADO ──
    if not cmd.startswith("/"):
        # Si el mensaje proviene del dueño, canal o un administrador en el grupo, IGNORAR (el bot no debe responderles soporte)
        if is_admin_sender and chat_type != "private":
            logging.info(f"Mensaje de administrador/dueño en grupo ({first_name}, id={user_id}) - Silenciando asistente.")
            return
        handle_group_ai_support(chat_id, user_id, first_name, text, msg_id, chat_type)

# ═════════════════════════════════════════════════════════════════════
# MANEJADOR DE CALLBACK QUERIES (BOTONES INTERACTIVOS)
# ═════════════════════════════════════════════════════════════════════
def handle_callback_query(cb):
    cb_id = cb.get("id")
    from_user = cb.get("from", {})
    user_id = from_user.get("id")
    first_name = from_user.get("first_name", "Amigo")
    msg = cb.get("message", {})
    chat_id = msg.get("chat", {}).get("id")
    msg_id = msg.get("message_id")
    data = cb.get("data", "")

    # Menú principal
    if data == "main_menu":
        answer_callback_query(cb_id)
        with data_lock:
            version = cached_servers_data.get("version", "1.0.0")
            total = cached_servers_data.get("total", 0)

        welcome_msg = (
            f"⚡ <b>¡Hola {first_name}! Asistente Oficial de {APP_NAME}</b> ⚡\n\n"
            f"Consulta los servidores actuales, aprende a buscar tu operadora o resuelve fallas.\n\n"
            f"📱 <b>Aplicación Oficial:</b> <a href=\"{PLAYSTORE_URL}\">{APP_NAME}</a>\n"
            f"📦 <b>Versión de Servidores en App:</b> <code>v{version}</code> (<b>{total} servidores activos</b>)"
        )
        edit_message(chat_id, msg_id, welcome_msg, reply_markup=get_main_menu_markup())
        return

    # Menú Países Dinámico
    if data == "menu_countries":
        answer_callback_query(cb_id)
        text_menu = (
            f"🌐 <b>SELECCIONA TU PAÍS PARA VER LOS SERVIDORES EN VIVO</b> 🌐\n\n"
            f"Elige tu país para consultar la lista exacta de servidores y operadores activos hoy en <a href=\"{PLAYSTORE_URL}\">{APP_NAME}</a>:"
        )
        edit_message(chat_id, msg_id, text_menu, reply_markup=get_dynamic_countries_markup())
        return

    # Agendar Cita
    if data == "menu_appointment":
        answer_callback_query(cb_id)
        pending_user_appointments[user_id] = True
        markup = {
            "inline_keyboard": [
                [{"text": "💬 Escribir Directo a @Crisis1823", "url": f"https://t.me/{ADMIN_USERNAME}"}],
                [{"text": "⬅️ Volver al Menú", "callback_data": "main_menu"}]
            ]
        }
        edit_message(chat_id, msg_id, get_appointment_prompt_text(), reply_markup=markup)
        return

    # País específico en vivo
    if data.startswith("country_"):
        c_code = data.replace("country_", "")
        if c_code == "all":
            answer_callback_query(cb_id)
            markup = {"inline_keyboard": [[{"text": "⬅️ Volver a Países", "callback_data": "menu_countries"}]]}
            edit_message(chat_id, msg_id, format_global_summary(), reply_markup=markup)
            return
        else:
            answer_callback_query(cb_id)
            markup = {
                "inline_keyboard": [
                    [{"text": "📥 Descargar App", "url": PLAYSTORE_URL}],
                    [{"text": "⬅️ Volver a Países", "callback_data": "menu_countries"}]
                ]
            }
            edit_message(chat_id, msg_id, format_live_country_response(c_code), reply_markup=markup)
            return

    # Guía: Cómo buscar en la app
    if data == "guide_search":
        answer_callback_query(cb_id)
        markup = {
            "inline_keyboard": [
                [{"text": "📥 Descargar en Google Play", "url": PLAYSTORE_URL}],
                [{"text": "⬅️ Volver al Menú", "callback_data": "main_menu"}]
            ]
        }
        edit_message(chat_id, msg_id, get_search_guide_text(), reply_markup=markup)
        return

    # Guía: Actualizar Servidores
    if data == "guide_update":
        answer_callback_query(cb_id)
        markup = {
            "inline_keyboard": [
                [{"text": "⬅️ Volver al Menú", "callback_data": "main_menu"}]
            ]
        }
        edit_message(chat_id, msg_id, get_update_guide_text(), reply_markup=markup)
        return

    # Guía: Solución de Problemas
    if data == "guide_troubleshoot":
        answer_callback_query(cb_id)
        markup = {
            "inline_keyboard": [
                [{"text": "📅 Agendar Soporte con Cristian", "callback_data": "menu_appointment"}],
                [{"text": "⬅️ Volver al Menú", "callback_data": "main_menu"}]
            ]
        }
        edit_message(chat_id, msg_id, get_troubleshoot_text(), reply_markup=markup)
        return

# ═════════════════════════════════════════════════════════════════════
# INICIALIZACIÓN Y BUCLE DE POLLING DEL BOT
# ═════════════════════════════════════════════════════════════════════
def bot_polling_loop():
    logging.info("Iniciando bucle de polling del Bot Telegram Soporte HTTP Conexión...")
    
    # 1. Configurar comandos y perfil en Telegram (Público vs Admin)
    setup_telegram_bot_commands()

    # 2. Arrancar hilo de sincronización automática en la nube en segundo plano
    sync_thread = Thread(target=auto_sync_worker, daemon=True)
    sync_thread.start()

    # 3. Arrancar hilo de mensajes motivacionales y recordatorios en el grupo
    motivator_thread = Thread(target=group_periodic_motivator_worker, daemon=True)
    motivator_thread.start()

    last_update_id = 0
    while True:
        try:
            url = f"{API_URL}/getUpdates?offset={last_update_id + 1}&timeout=30"
            req = urllib.request.Request(url)
            with urllib.request.urlopen(req, timeout=40) as resp:
                data = json.loads(resp.read().decode("utf-8"))
                if data.get("ok"):
                    for update in data.get("result", []):
                        last_update_id = update["update_id"]
                        if "message" in update:
                            handle_message(update["message"])
                        elif "callback_query" in update:
                            handle_callback_query(update["callback_query"])
        except Exception as e:
            logging.error(f"Error en polling: {e}")
            time.sleep(3)

if __name__ == "__main__":
    bot_polling_loop()
