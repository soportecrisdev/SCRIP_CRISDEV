#!/bin/bash
# Script para crear usuario SSHPlus real con respuesta JSON
# Uso: ./crearusuario.sh NOMBRE CONTRASEÑA DIAS LIMITE

# --- Verificación de parámetros ---
if [[ $# -ne 4 ]]; then
    echo '{"status":"error","msg":"Uso: crearusuario.sh NOMBRE CONTRASEÑA DIAS LIMITE"}'
    exit 1
fi

USUARIO="$1"
CONTRASEÑA="$2"
EXP_DIAS="$3"
LIMITE="$4"

# --- Verificar si el usuario ya existe ---
if id "$USUARIO" &>/dev/null; then
    echo "{\"status\":\"error\",\"msg\":\"El usuario $USUARIO ya existe\"}"
    exit 1
fi

# --- Crear usuario con expiración ---
useradd -M -N -s /bin/false -e $(date -d "+$EXP_DIAS days" "+%Y-%m-%d") "$USUARIO"

# --- Establecer contraseña ---
echo -e "$CONTRASEÑA\n$CONTRASEÑA" | passwd "$USUARIO" &>/dev/null

# --- Guardar contraseña en SSHPlus ---
mkdir -p /etc/SSHPlus/senha
echo "$CONTRASEÑA" > /etc/SSHPlus/senha/"$USUARIO"

# --- Registrar usuario en base de datos ---
echo "$USUARIO $LIMITE" >> /root/usuarios.db

# --- Respuesta JSON ---
echo "{\"status\":\"success\",\"usuario\":\"$USUARIO\",\"contraseña\":\"$CONTRASEÑA\",\"expira_en_dias\":$EXP_DIAS,\"limite\":$LIMITE}"
