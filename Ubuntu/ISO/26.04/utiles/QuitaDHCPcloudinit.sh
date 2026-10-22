#!/bin/bash
# vs 06/10/2026
# Arreglo para equipos Ubuntu 26.04 instalados ANTES de que
# 2-SetupSOdesdeLiveCD.sh (v23.11) desactivase cloud-init.
#
# Síntoma: la interfaz tiene DOS IPv4, la estática de macs.csv y otra de DHCP
# ('secondary dynamic' en 'ip a'), en cada arranque.
# Causa: cloud-init escribió /etc/netplan/50-cloud-init.yaml con 'dhcp4: true';
# NombreIP.sh pasó la conexión a manual y NM escribió 90-NM-<uuid>.yaml SIN
# 'dhcp4'. netplan fusiona los dos ficheros => perfil 'auto' + IP fija.
#
# Qué hace (idempotente):
#   1. Desactiva cloud-init (cloud-init.disabled + network: {config: disabled}).
#   2. Si la conexión ethernet activa está en 'auto' pero tiene ipv4.addresses
#      (el estado roto), la pasa a 'manual' conservando IP/gateway/DNS.
#   3. Borra /etc/netplan/50-cloud-init.yaml (solo si existe un 90-NM-*.yaml,
#      que es el que define la conexión), regenera netplan y reactiva la red.
#
# Uso:  sudo ./QuitaDHCPcloudinit.sh
# ⚠️  Por SSH, conéctate a la IP ESTÁTICA: la de DHCP desaparece al aplicar.
# Log:  /var/log/IAC-IESMHP/Ubuntu/QuitaDHCPcloudinit.log

echoverde()    { echo -e "\033[32m$1\033[0m"; }
echorojo()     { echo -e "\033[31m$1\033[0m"; }
echoamarillo() { echo -e "\033[33m$1\033[0m"; }

if [ "$EUID" -ne 0 ]; then
    echorojo "[ERR] Este script debe ejecutarse como root (usa sudo)."
    exit 1
fi

# Si se lanza por SSH contra la IP de DHCP, la sesión se cae a mitad: que el
# script siga hasta el final igualmente y deje todo en el log.
trap '' HUP
LOG=/var/log/IAC-IESMHP/Ubuntu/QuitaDHCPcloudinit.log
mkdir -p "$(dirname "$LOG")"
exec > >(tee -a "$LOG") 2>&1 </dev/null
echo "=== $(date) — $0 ==="

# 1. cloud-init
mkdir -p /etc/cloud/cloud.cfg.d
touch /etc/cloud/cloud-init.disabled
echo 'network: {config: disabled}' > /etc/cloud/cloud.cfg.d/99-iac-disable-network-config.cfg
echoverde "[OK ] cloud-init desactivado"

# 2. Conexión ethernet activa
CON=$(nmcli -t -f NAME,TYPE,DEVICE connection show --active | awk -F: '$2=="802-3-ethernet"{print $1; exit}')
DEV=$(nmcli -t -f NAME,TYPE,DEVICE connection show --active | awk -F: '$2=="802-3-ethernet"{print $3; exit}')
if [ -z "$CON" ]; then
    echorojo "[ERR] No hay conexión ethernet activa"
    exit 1
fi
METODO=$(nmcli -g ipv4.method connection show "$CON")
DIRS=$(nmcli -g ipv4.addresses connection show "$CON")
echo "Conexión: $CON ($DEV)  método=$METODO  ipv4.addresses=${DIRS:-ninguna}"
echo "IPv4 antes: $(ip -4 -o addr show dev "$DEV" | awk '{print $4}' | xargs)"

if [ "$METODO" = "auto" ] && [ -n "$DIRS" ]; then
    echoamarillo "[INF] Estado roto ('auto' + IP fija): se pasa a 'manual' conservando $DIRS"
    nmcli connection modify "$CON" ipv4.method manual \
        || { echorojo "[ERR] nmcli modify falló"; exit 1; }
    METODO=manual
fi

# 3. 50-cloud-init.yaml
CAMBIO=0
if [ -f /etc/netplan/50-cloud-init.yaml ]; then
    if [ "$METODO" = "manual" ] && ls /etc/netplan/90-NM-*.yaml >/dev/null 2>&1; then
        rm -f /etc/netplan/50-cloud-init.yaml
        echoverde "[OK ] Eliminado /etc/netplan/50-cloud-init.yaml"
        CAMBIO=1
    else
        echoamarillo "[INF] Se conserva 50-cloud-init.yaml (conexión en DHCP o sin 90-NM-*.yaml: es lo que la configura)"
    fi
else
    echo "[INF] No existe /etc/netplan/50-cloud-init.yaml"
fi

if [ "$CAMBIO" = 1 ] || [ "$METODO" = "manual" ]; then
    netplan generate || echorojo "[ERR] netplan generate falló"
    nmcli connection reload || true
    echoamarillo "[INF] Reactivando '$CON' (la IP de DHCP desaparece)..."
    nmcli connection up "$CON" || echorojo "[ERR] No se pudo reactivar '$CON'"
    sleep 5
fi

echo "IPv4 después: $(ip -4 -o addr show dev "$DEV" | awk '{print $4}' | xargs)"
NIPS=$(ip -4 -o addr show dev "$DEV" | wc -l)
if [ "$NIPS" -gt 1 ]; then
    echorojo "[ERR] $DEV sigue con $NIPS IPv4. Revisar: nmcli -f ipv4 con show '$CON'; ls /etc/netplan/"
    exit 1
fi
echoverde "[OK ] $DEV con una sola IPv4"
ls -l /etc/netplan/
