#!/bin/bash
tput setaf 7 ; tput setab 4 ; tput bold ; printf '%35s%s%-20s\n' "TCP Tweaker 1.0" ; tput sgr0
if [[ `grep -c "^#PH56" /etc/sysctl.conf` -eq 1 ]]
then
	echo ""
	echo "La configuración de red de TCP Tweaker ya está aplicada en el sistema."
	echo ""
	read -p "¿Eliminar la configuración de TCP Tweaker? [s/n]: " -e -i n resposta0
	if [[ "$resposta0" = 's' ]]; then
		grep -v "^#PH56
net.ipv4.tcp_window_scaling = 1
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 16384 16777216
net.ipv4.tcp_low_latency = 1
net.ipv4.tcp_slow_start_after_idle = 0" /etc/sysctl.conf > /tmp/syscl && mv /tmp/syscl /etc/sysctl.conf
sysctl -p /etc/sysctl.conf > /dev/null
		echo ""
		echo "La configuración de red de TCP Tweaker se eliminó correctamente."
		echo ""
	exit
	else 
		echo ""
		exit
	fi
else
	echo ""
	echo "Script experimental. Úselo bajo su responsabilidad."
	echo "Modificará parámetros de red del sistema para reducir latencia."
	echo ""
	read -p "¿Continuar con la instalación? [s/n]: " -e -i n resposta
	if [[ "$resposta" = 's' ]]; then
	echo ""
	echo "Aplicando la siguiente configuración:"
	echo " " >> /etc/sysctl.conf
	echo "#PH56" >> /etc/sysctl.conf
echo "net.ipv4.tcp_window_scaling = 1
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 16384 16777216
net.ipv4.tcp_low_latency = 1
net.ipv4.tcp_slow_start_after_idle = 0" >> /etc/sysctl.conf
echo ""
sysctl -p /etc/sysctl.conf
		echo ""
		echo "La configuración de red de TCP Tweaker se aplicó correctamente."
		echo ""
	else
		echo ""
		echo "Instalación cancelada."
		echo ""
	fi
fi
exit
