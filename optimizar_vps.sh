#!/bin/bash

# ==============================================================================
#  OPTIMIZADOR AUTOMÁTICO DE MEMORIA RAM Y SWAP PARA VPS (HTTP CONEXIÓN / SSH-CRIS)
# ==============================================================================

# 1. Sincronizar el sistema de archivos
sync

# 2. Limpiar la caché de páginas y memoria RAM no utilizada (PageCache, dentries, inodes)
echo 3 > /proc/sys/vm/drop_caches

# 3. Optimizar el uso de la memoria Swap
sysctl -w vm.swappiness=10 >/dev/null 2>&1

# Asegurar persistencia de swappiness si se ejecuta como root
if [[ -f /etc/sysctl.conf ]] && ! grep -q "^vm.swappiness" /etc/sysctl.conf 2>/dev/null; then
    echo "vm.swappiness=10" >> /etc/sysctl.conf
fi
