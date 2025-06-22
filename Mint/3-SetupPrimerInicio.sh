#!/bin/bash

#"set -e" significa que el script se detendrá si ocurre un error
set -e

RAIZSCRIPTS="/opt/iesmhpLinux"
RAIZLOGS="/var/log/iesmhpLinux"

#Fichero de log del servicio
FLOG="$RAIZLOGS/3-SetupPrimerInicio.log"

# Function to show a message to all graphical sessions
mostrar_mensaje() {
    local MENSAJE="${1:-'hola mundo'}"
    local TIEMPO="${2:-3000000}"
    while read -r sid; do
        USERNAME=$(loginctl show-session "$sid" -p Name --value)
        DISPLAY=$(loginctl show-session "$sid" -p Display --value)
        TYPE=$(loginctl show-session "$sid" -p Type --value)
        # Continuar solo si hay DISPLAY
        [[ -z "$DISPLAY" ]] && continue
        # Obtener UID
        USER_ID=$(id -u "$USERNAME")
        # Obtener DBUS address de la sesión (si existe)
        DBUS_ADDRESS=$(grep -z DBUS_SESSION_BUS_ADDRESS /proc/$(pgrep -u "$USERNAME" -n gnome-session 2>/dev/null || pgrep -u "$USERNAME" -n xfce4-session 2>/dev/null || echo 0)/environ 2>/dev/null | tr '\0' '\n' | grep DBUS_SESSION_BUS_ADDRESS= | cut -d= -f2-)
        # Ejecutar zenity como el usuario
        sudo -u "$USERNAME" DISPLAY="$DISPLAY" DBUS_SESSION_BUS_ADDRESS="$DBUS_ADDRESS" \
            zenity --info --text="$MENSAJE" --title="Aviso del administrador" --timeout=$TIEMPO &
    done < <(loginctl list-sessions --no-legend | awk '{print $1}')
}

echoverde() {  
    echo -e "\033[32m$1\033[0m" 
    echo $1 >> $FLOG
    mostrar_mensaje "$1"
}
echorojo()  {
    echo -e "\033[31m$1\033[0m"
    echo $1 >> $FLOG 
    mostrar_mensaje "ROJO - $1"
}

echoverde "Lanzando mensaje en sesiones gráficas activas..."
mostrar_mensaje "Actualizando Sistema: no apagar. (log en $FLOG)"  
echoverde "Ejecutando actualización del sistema en primer arranque en 20sg.."
sleep 20 # Espera 20 segundos para asegurar que el sistema esté completamente arrancado


echoverde "Arreglando posibles problemas de configuración de paquetes..." 
dpkg --configure -a >> $FLOG

echoverde "Voy a actualizar lista de paquetes" 
apt-get update --fix-missing >> $FLOG




#Instalado SSH server
echoverde "Instalando servidor SSH y limpiando..."
apt-get install -y ssh >> $FLOG
# Configurar SSH para permitir el acceso root
sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
# Reiniciar el servicio SSH para aplicar los cambios
service ssh restart >> $FLOG

#Obtener la IP de la máquina
IP=$(hostname -I | awk '{print $1}')
mostrar_mensaje "Actualizando Sistema: no apagar. Disponible SSH root/root en $IP ($(hostname)). (log en /var/log/3-SetupPrimerInicio.log)"

# Limpiar caché de paquetes
echoverde "Limpiando caché de paquetes..."
apt-get clean >> $FLOG
apt-get autoremove -y >> $FLOG

echoverde "Ping..."
ping -c 3 google.com 


echoverde "Actualizando el sistema..." 
apt-get update -y >> $FLOG
apt-get full-upgrade -y >> $FLOG
echoverde "Actualizado el sistema..." 

# Limpiar caché de paquetes
echoverde "Limpiando caché de paquetes segunda vez..."
apt-get clean >> $FLOG
apt-get autoremove -y >> $FLOG


echoverde "Desactivando y borrando el servicio de actualización en primer arranque...">> /var/log/3-SetupPrimerInicio.log
systemctl disable 3-SetupPrimerInicio.service
rm /etc/systemd/system/3-SetupPrimerInicio.service
rm -- "$0"
mostrar_mensaje "Sistema actualizado $IP ($(hostname)). El sistema se reiniciará en 30 segundos." 30


#Reinciando en 30 segundos y avisando a los usuarios
echoverde "Reiniciando el sistema en 30 segundos..." >> $FLOG
sleep 30
echo "Reiniciando el sistema..." >> $FLOG
reboot now