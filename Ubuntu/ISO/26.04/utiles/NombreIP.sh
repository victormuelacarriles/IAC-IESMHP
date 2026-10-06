#!/bin/bash
#"set -e" significa que el script se detendrá si ocurre un error
#vs 06/10/2026 (fix doble IP: cloud-init 50-cloud-init.yaml + nmcli atómico)
set -e

# Variables comunes del proyecto (REPO, DISTRO, RAIZSCRIPTS, RAIZLOG, URL_MACS,
# redes de aula RED_IABD/RED_SMRD...). Único punto de definición: comun.sh
# (este script vive en ISO/26.04/utiles/, de ahí el "/.." para subir a 26.04).
_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$_DIR/comun.sh"

RAIZLOGS="$RAIZLOG"   # alias histórico usado por el resto del script
mkdir -p "$RAIZLOGS"

# Funciones de colores
echoverde() {  
    echo -e "\033[32m$1\033[0m" 
}
echorojo()  {
      echo -e "\033[31m$1\033[0m" 
}  

#Función para cambiar la ip estática
# Un ÚNICO 'nmcli con modify' (método + dirección + gateway + DNS a la vez): NM
# guarda el perfil vía netplan (/etc/netplan/90-NM-<uuid>.yaml) y así no quedan
# estados intermedios. La reactivación se hace una sola vez, al final del script.
cambiar_ip_estatica() {
    local ncCONEX="$1"
    local IPESTATICAN="$2"
    local IPGATEWAY="$3"
    local IPDNS1="$4"
    local IPDNS2="$5"
    nmcli con modify "$ncCONEX" ipv4.method manual ipv4.addresses "$IPESTATICAN" \
        ipv4.gateway "$IPGATEWAY" ipv4.dns "$IPDNS1 $IPDNS2"
}

# cloud-init (viene en Ubuntu 26.04 Desktop por el instalador) genera en el
# primer arranque /etc/netplan/50-cloud-init.yaml con 'eno1: dhcp4: true'.
# Cuando NM pasa la conexión a manual, escribe 90-NM-<uuid>.yaml SIN 'dhcp4'
# (lo omite por ser el valor por defecto) y netplan FUSIONA ambos ficheros:
# dhcp4=true (del 50) + addresses=.IPf (del 90) => perfil 'auto' + IP fija =>
# DOS IPs en la interfaz en cada arranque (visto en SMRD-01, 2026-10-06).
# Solo se llama cuando el perfil queda en 'manual' (en ese momento 90-NM-*.yaml
# ya define la conexión completa y el 50 sobra). En 'auto' NO se borra el 50:
# si el 90 no lleva dhcp4, el DHCP sale precisamente del 50.
quitar_dhcp_cloudinit() {
    # Que cloud-init no vuelva a escribir la red (idempotente).
    mkdir -p /etc/cloud/cloud.cfg.d
    touch /etc/cloud/cloud-init.disabled
    echo 'network: {config: disabled}' > /etc/cloud/cloud.cfg.d/99-iac-disable-network-config.cfg
    if [ -f /etc/netplan/50-cloud-init.yaml ]; then
        if ls /etc/netplan/90-NM-*.yaml >/dev/null 2>&1; then
            echorojo "Encontrado /etc/netplan/50-cloud-init.yaml (dhcp4: true): se elimina para que no se sume un DHCP a la IP estática."
            rm -f /etc/netplan/50-cloud-init.yaml
            netplan generate || echorojo "[ERR] netplan generate falló"
            nmcli connection reload || true
            BNECESARIORESTABLECERRED="S"
        else
            echorojo "[AVS] Existe 50-cloud-init.yaml pero no hay 90-NM-*.yaml: no se borra (dejaría la interfaz sin configuración)."
        fi
    fi
}

MAC=$(ip link show | awk '/ether/ {print $2}' | head -n 1)
echo "0-MAC: $MAC"
#DOING: descargar desde github usuarios autorizados y claves ssh
# URL_MACS lo define comun.sh (https://raw.githubusercontent.com/.../macs.csv).
# Se descarga a RAIZLOGS (no al clon git de $RAIZSCRIPTS): más abajo este
# fichero se sobreescribe dejando solo la línea de la MAC, y hacerlo sobre
# /opt/IAC-IESMHP/macs.csv ensuciaría el repo clonado.
LOCAL_MACS="$RAIZLOGS/macs.csv"
echo "2-variales cargadas / descargando archivos desde GitHub"
wget --header="Cache-Control: no-cache" -O $LOCAL_MACS $URL_MACS

# Compruebo si la MAC está en el repositorio. Si NO está, se conserva el nombre
# que asignó la instalación en 2-SetupSOdesdeLiveCD.sh (ld+fecha, p. ej.
# ld202606160934), de modo que el hostname único por equipo no cambia en cada
# arranque. Si el equipo aún tiene un nombre genérico (residuo del Live CD o de
# versiones antiguas), se genera uno nuevo ld+AAAAMMDDHHMM.
EQUIPOENMACS="$(hostname)"
case "$EQUIPOENMACS" in
    ubuntu|Ubuntu|mint|Mint|localhost|"") EQUIPOENMACS="ld$(date +%Y%m%d%H%M)" ;;
esac
if [ ! -f $LOCAL_MACS ]; then
    echorojo "No se ha encontrado el archivo de MACs: $LOCAL_MACS"
    echo "Por favor, compruebe la conexión a Internet y que el archivo está disponible en el repositorio."
else
    # Compruebo si la MAC está en el repositorio
    if ! grep -q -i "$MAC" "$LOCAL_MACS"; then
        echorojo "La MAC $MAC no se encuentra en el repositorio."
        echo            "Por favor, compruebe la conexión a Internet y que la MAC está registrada en el repositorio."
    else
        INFO_MACS=$(cat $LOCAL_MACS | grep -i $MAC )
        #Sustituyo el contenido de $LOCAL_MACS por la información de la MAC
        echo "Información de la MAC: $INFO_MACS"
        echo "$INFO_MACS" > $LOCAL_MACS
        #Si se encuentra la MAC, extraigo el nombre del equipo
        EQUIPOENMACS=$(echo $INFO_MACS | cut -d',' -f2 | xargs)
        IPFINALENMACS=$(echo $INFO_MACS | cut -d',' -f3 | xargs)
    fi
fi

EQUIPOACTUAL=$(hostname)
if [ "$EQUIPOACTUAL" != "$EQUIPOENMACS" ]; then
    echo "Equipo identificado: '$EQUIPOENMACS'  Nombre actual del equipo: '$EQUIPOACTUAL'"    

    #Pido confirmación para cambiar el nombre del equipo
    #read -p "¿Desea cambiar el nombre del equipo a '$EQUIPOENMACS'? (s/n): " CONFIRMACION
    CONFIRMACION="S"
    if [[ ! "$CONFIRMACION " != ^[Ss]$ ]]; then
         echorojo "Cambio de nombre del equipo cancelado."
        sleep 100 && exit 0
    else  
        #Cambio el nombre del equipo a $EQUIPOENMACS
        echo "Renombrando el equipo a: $EQUIPOENMACS"
        echo "$EQUIPOENMACS" > /etc/hostname
        echo "127.0.0.1 localhost" > /etc/hosts
        echo "127.0.1.1 $EQUIPOENMACS" >> /etc/hosts
        hostnamectl set-hostname "$EQUIPOENMACS"
    fi
else
    echo "El nombre del equipo ya es correcto: '$EQUIPOENMACS'" 
fi

#IP: vamos a averiguar en que red estamos y a configurar la IP

#usando nmcli, ver cual es la conexión ethernet ACTIVA (y su dispositivo).
# Antes se tomaban TODAS las conexiones ethernet con 'grep ethernet | xargs':
# con dos perfiles se juntaban sus nombres en uno inexistente.
ncCONEXION=$(nmcli -t -f NAME,TYPE,DEVICE connection show --active | awk -F: '$2=="802-3-ethernet"{print $1; exit}')
IP_INTERFAZ=$(nmcli -t -f NAME,TYPE,DEVICE connection show --active | awk -F: '$2=="802-3-ethernet"{print $3; exit}')
if [ -z "$ncCONEXION" ]; then
    # Respaldo: primera conexión ethernet aunque no esté activa
    ncCONEXION=$(nmcli -t -f NAME,TYPE connection show | awk -F: '$2=="802-3-ethernet"{print $1; exit}')
fi
if [ -z "$ncCONEXION" ]; then
    echorojo "No se ha encontrado una conexión Ethernet activa."
    exit 1
fi
if [ -z "$IP_INTERFAZ" ]; then
    IP_INTERFAZ=$(nmcli -g connection.interface-name connection show "$ncCONEXION" 2>/dev/null || true)
fi
echo "Conexión Ethernet activa: $ncCONEXION (dispositivo: ${IP_INTERFAZ:-desconocido})"
#Me quedo con la info de la conexión activa
AULA=$(echo $EQUIPOENMACS | cut -d'-' -f1 | xargs)
IP_METHOD=$(nmcli connection show "$ncCONEXION" | grep ipv4.method | awk '{print $2}' | xargs)
# Esperar a tener IP (hasta 60 s): una tarjeta física tarda más que la de la VM
# en negociar el enlace. Sin IP NO se toca la configuración (antes caía en la
# rama "no es del aula" y se revertía a dinámica sin motivo).
for _i in $(seq 1 30); do
    IP_RED=$(nmcli connection show "$ncCONEXION"| grep IP4.ADDRESS|head -n 1|awk '{print $2}'|xargs)
    [ -n "$IP_RED" ] && break
    echo "Esperando a que '$ncCONEXION' tenga IP ($_i/30)..."
    sleep 2
done
IP_REDAULA=$(echo "$IP_RED"| cut -d'.' -f1-3 | xargs)
IP_IP=$(echo $IP_RED|cut -d'/' -f1|xargs)
IP_SOLOFINAL=$(echo $IP_RED | cut -d'.' -f4| cut -d'/' -f1| xargs)
IP_MASCARA=$(echo $IP_RED | cut -d'.' -f4| cut -d'/' -f2| xargs)
IP_GATEWAY=$(nmcli connection show "$ncCONEXION" | grep IP4.GATEWAY|head -n 1 | awk '{print $2}' | xargs)
IP_DNS1=$(nmcli connection show "$ncCONEXION" | grep "IP4.DNS\[1\]"|head -n 1 | awk '{print $2}' | xargs)
IP_DNS2=$(nmcli connection show "$ncCONEXION" | grep "IP4.DNS\[2\]"|head -n 1 | awk '{print $2}' | xargs)
echo "IP Actual (nmcli): $IP_RED ($IP_METHOD) - Gateway: $IP_GATEWAY - DNS: $IP_DNS1, $IP_DNS2 -> $IP_SOLOFINAL"
echo "Aula: $AULA - IP_REDAULA: $IP_REDAULA"


#Activamos WOL
###  ethtool -s $IP_INTERFAZ wol g  ###por probar si funciona sin el: está dando problemas en nuevas versiones de Linux
nmcli c modify "$ncCONEXION" 802-3-ethernet.wake-on-lan magic
nmcli c modify "$ncCONEXION" 802-3-ethernet.accept-all-mac-addresses 1


BNECESARIORESTABLECERRED="N"
#Compramos si la dirección actual está asociada al aula que corrsponde
if [ -z "$IP_RED" ]; then
    echorojo "[ERR] '$ncCONEXION' sigue sin IP tras 60 s: NO se modifica la configuración IP."
elif [[ ("$IP_REDAULA" == "$RED_IABD" && "$AULA" == "IABD") ||
      ("$IP_REDAULA" == "$RED_SMRD" && "$AULA" == "SMRD") ]]; then
    IPESTATICANUEVA="$IP_REDAULA.$IPFINALENMACS/24"
    if [ "$IP_METHOD" == "auto" ]; then
        echoverde "La IP actual ($IP_RED) es dinámica, vamos a convertirla en estática (-> $IPESTATICANUEVA)"
        echorojo '(la conexión ssh se perderá durante el proceso!)'
        cambiar_ip_estatica "$ncCONEXION" "$IPESTATICANUEVA" "$IP_GATEWAY" "$IP_DNS1" "$IP_DNS2"
        BNECESARIORESTABLECERRED="S"
    else

        if [ "$IP_RED" != "$IPESTATICANUEVA" ]; then
            echo "La IP actual ($IP_IP) no es la correcta ($IPESTATICANUEVA). La cambiamos."
            cambiar_ip_estatica "$ncCONEXION" "$IPESTATICANUEVA" "$IP_GATEWAY" "$IP_DNS1" "$IP_DNS2"
            BNECESARIORESTABLECERRED="S"
        else
            echo "La IP actual ($IP_IP) es la correcta ($IPESTATICANUEVA)."
        fi
    fi
    # Perfil en 'manual': que el 50-cloud-init.yaml (dhcp4: true) no le sume un DHCP.
    quitar_dhcp_cloudinit
else
    if [ "$IP_METHOD" != "auto" ]; then
        echo "La IP actual ($IP_RED) no corresponde al aula $AULA, y tiene una IP estática. Convertimos a dinámica."
        # Vaciar también dirección/gateway/DNS fijos: con 'auto' + ipv4.addresses
        # NM pone la IP fija Y la de DHCP a la vez (dos IPs en la interfaz).
        nmcli con modify "$ncCONEXION" ipv4.method auto ipv4.addresses "" ipv4.gateway "" ipv4.dns ""
        BNECESARIORESTABLECERRED="S"
    else
        echo "La IP actual ($IP_RED) no es de $AULA (pero ya es IP dinámica: nada que hacer)."
    fi
fi

if [ "$BNECESARIORESTABLECERRED" == "S" ]; then
    echorojo "Reseteo la red: podría perderse la conexión"
    # 'up' sobre una conexión activa la reactiva con el perfil nuevo (no hace
    # falta 'down' antes; si 'down' fallaba, con set -e se cortaba el script).
    nmcli connection up "$ncCONEXION" || echorojo "[ERR] No se pudo reactivar '$ncCONEXION'"
fi

# Verificación: la interfaz debe quedar con UNA sola IPv4.
if [ -n "$IP_INTERFAZ" ]; then
    sleep 5
    IPS_FINALES=$(ip -4 -o addr show dev "$IP_INTERFAZ" 2>/dev/null | awk '{print $4, ($0 ~ / dynamic /) ? "(dinámica)" : "(fija)"}')
    NUM_IPS=$(echo "$IPS_FINALES" | grep -c . || true)
    echo "IPv4 final en $IP_INTERFAZ: $(echo $IPS_FINALES)"
    if [ "$NUM_IPS" -gt 1 ]; then
        echorojo "[ERR] $IP_INTERFAZ tiene $NUM_IPS direcciones IPv4. Revisar: nmcli -f ipv4 con show '$ncCONEXION' y ls /etc/netplan/"
    fi
fi


echoverde "Proceso finalizado correctamente."

###
###fwupdmgr update -y
