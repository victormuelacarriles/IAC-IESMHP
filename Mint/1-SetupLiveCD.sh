#!/bin/bash
#TODO: - scripts en GITHUB
#      - git clone a /opt/iesmhpLinux
#      - Logs en     /var/log/iesmhpLinux/*.log 
#      - Arreglar este script para que acepte parámentros (isoentrada / isosalida)  y que funcione
set -e

GITREPO="https://github.com/victormuelacarriles/IAC-IESMHP.git"
RAIZSCRIPTSLIVE="/LiveCDiesmhp"
DISTRO="Mint"
RAIZSCRIPTS="/opt/iesmhp$DISTRO"
RAIZLOGS="/var/log/iesmhp$DISTRO"
SCRIPT2="2-SetupSOdesdeLiveCD.sh"

# Funciones de colores
echoverde() {  
    echo -e "\033[32m$1\033[0m" 
}
echorojo()  {
      echo -e "\033[31m$1\033[0m" 
}  
#Por si hay que depurar, establecemos español 
setxkbmap es || true && loadkeys es ||true




echoverde "1-SetupLiveCD -"
echo      "   Script personalizado de instalación de "
echo      "   sistema operativo Linux Mint 22.1 para equipos distancia / CEIABD"
echoverde "--------------------------------------------------------------------"
echoverde "       Distancia     ->Disco pequeño: NVMe 0,5TB (/EFI, /swap y /)"
echoverde "                     ->Disco grande:  NVMe 2,0TB (/home)"
echoverde "--------------------------------------------------------------------"
echoverde "       CEIABD        ->Disco pequeño: NVMe 0,5TB (/EFI, /swap y /)"
echoverde "                     ->Disco grande:  SDa  1,0TB (/home)"
echoverde "--------------------------------------------------------------------"
sleep 1
echorojo "                                                  (comenzará en 10sg)"
echoverde "--------------------------------------------------------------------"
sleep 9

# Detectamos discos (ignorando los discos USB y loop0)
DISCOS_M2=($(lsblk -dno NAME,SIZE,TRAN | grep -v loop0| grep -v 'usb'| grep nvme | sort -h -k2 | awk '{print $1}'))
DISCOS_SD=($(lsblk -dno NAME,SIZE,TRAN | grep -v loop0| grep -v 'usb'| grep sd | sort -h -k2 | awk '{print $1}'))
lsblk -dno NAME,SIZE | grep -v '^loop0'
echo "DISCOS_M2[0]: ${DISCOS_M2[0]}"
echo "DISCOS_M2[1]: ${DISCOS_M2[1]}"
echo "DISCOS_SD[0]: ${DISCOS_SD[0]}"
echo "DISCOS_SD[1]: ${DISCOS_SD[1]}"

if [ -z "${DISCOS_M2}" ]; then 
    echorojo "No se encontraron discos NVMe ni discos SD. Asegúrate de que el equipo tiene discos conectados."
    sleep 1000  && exit 1
            
else
    if [ -z "${DISCOS_M2[1]}" ]; then 
        #Hay un discos NVME, buscamos un sd
        if [ -z "${DISCOS_SD[0]}" ]; then 
            # Si no hay discos SD no es distancias ni CEIABD: podríamo seguir pero parmos.
            echorojo "No hay segundo disco SD (hay sólo un NVME sin disco secundario). Detenemos la instalación."
            sleep 1000  && exit 1
        else
            DISK_SMALL="/dev/${DISCOS_M2[0]}"
            DISK_BIG="/dev/${DISCOS_SD[0]}"
            echoverde "Equipo con disco NVME+SD: "
            echoverde "    montaremos /     -> en disco NVME($DISK_SMALL)"
            echoverde "               /home -> en disco SD  ($DISK_BIG)"
        fi
    else
        DISK_SMALL="/dev/${DISCOS_M2[0]}"
        DISK_BIG="/dev/${DISCOS_M2[1]}"
        echoverde "Equipo con 2 NMVE: "
        echoverde "    montaremos /     -> pequeño($DISK_SMALL)"
        echoverde "               /home -> grande ($DISK_BIG)"
    fi
fi

if [[ "$DISK_SMALL" != *nvme* ]]; then
    echorojo "#Error: se esperaba un disco NVMe para el disco pequeño"
    exit 1
fi

echo && echo "Borrando y particionando discos: $DISK_SMALL y $DISK_BIG"
lsblk -o NAME,SIZE,TYPE
# Borrar particiones antiguas
sgdisk --zap-all "$DISK_SMALL"
sgdisk --zap-all "$DISK_BIG"
parted -s "$DISK_SMALL" mklabel gpt >/dev/null
parted -s "$DISK_BIG" mklabel gpt >/dev/null
# Crear particiones en disco pequeño
parted -s "$DISK_SMALL" mkpart ESP fat32 1MiB 513MiB >/dev/null
parted -s "$DISK_SMALL" set 1 esp on >/dev/null
parted -s "$DISK_SMALL" mkpart primary linux-swap 513MiB 8705MiB >/dev/null
parted -s "$DISK_SMALL" mkpart primary ext4 8705MiB 100% >/dev/null
# Crear partición en disco grande
parted -s "$DISK_BIG" mkpart primary ext4 1MiB 100% >/dev/null

# Esperar a que el kernel detecte los cambios
echo && echoverde "...Borrados y particidos los discos: $DISK_SMALL y $DISK_BIG" && echo 
 
echo && echo "Esperando a que el kernel detecte los cambios..." && sleep 5 

# Asignar particiones
EFI="${DISK_SMALL}p1"
SWAP="${DISK_SMALL}p2"
ROOT="${DISK_SMALL}p3"
#COMPROBAR! Funciona con NVMe pero no estoy seguro con SD [ Original:   HOME="${DISK_BIG}p1"     ]
#Si DISK_BIG contiene /sd, entonces la partición de /home es 1
if [[ "$DISK_BIG" == *sd* ]]; then
    HOME="${DISK_BIG}1"
else
    if [[ "$DISK_BIG" == *nvme* ]]; then
        HOME="${DISK_BIG}p1"
    else
        echorojo "#Error: no se pudo asignar la partición de /home separada"
        exit 1
    fi
fi
# Formatear particiones
echo "Formateando particiones (EFI=$EFI, SWAP=$SWAP, ROOT=$ROOT, HOME=$HOME)..."
mkfs.fat -F32 "$EFI" >/dev/null
mkswap "$SWAP" >/dev/null
mkfs.ext4 -F "$ROOT" >/dev/null
mkfs.ext4 -F "$HOME" >/dev/null

# Comprobar que las particiones se han formateado correctamente
if ! blkid "$EFI" || ! blkid "$SWAP" || ! blkid "$ROOT" || ! blkid "$HOME"; then
    echorojo "#Error: no se pudieron formatear las particiones"
    sleep 10 && exit 1
else
    #TODO: comprobar que las particiones son del tipo correcto
    echoverde "...Formateadas correctamente las particiones"
fi


# Step 2: Mount target filesystems
echo "Montado sistemas de ficheros..."
mount "$ROOT" /mnt
mkdir -p /mnt/boot/efi
mkdir -p /mnt/home
mount "$EFI" /mnt/boot/efi
mount "$HOME" /mnt/home
swapon "$SWAP"
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT
echo && echoverde "...Montados sistemas de ficheros" 

# Step 3: Copy the live system to the target
#TODO: acelerar? copiar el filesystem.squashfs a /tmp antes de montar el CD, y luego montarlo desde /tmp 

# Find the squashfs file (containing the live filesystem)
SQUASHFS=$(find /cdrom -name "filesystem.squashfs" -o -name "*.squashfs" | head -1)

# Mount the squashfs
echo "Montado sistema squashfs ..."
mkdir -p /tmp/squashfs
mount -o loop "$SQUASHFS" /tmp/squashfs

# Copy the filesystem to the target
echo "Copiando el sistema de archivos..."
rsync -av --exclude=/etc/fstab --exclude=/etc/machine-id /tmp/squashfs/ /mnt/
echoverde "...Copiado el sistema de archivos desde $SQUASHFS a /mnt"

# Unmount squashfs
umount /tmp/squashfs

# Step 4: Prepare chroot environment
for dir in /dev /proc /sys /run; do
    mount --bind $dir /mnt$dir
done

#HA FALLADO AQUÍ 23/6/2025

#Por si no existiera, creamos directorio y movemos scripts
RAIZSCRIPTSDISTRO="/mnt$RAIZSCRIPTS/$DISTRO"
DISTROLOGS="/mnt$RAIZLOGS" 
mkdir -p $RAIZSCRIPTSDISTRO
mkdir -p $DISTROLOGS


#Los scripts de GITHUB están en "$RAIZSCRIPTSLIVE/Mint" 
#Los movemos a /mnt$RAIZSCRIPTS (raiz)
echo 
echo "Moviendo auxiliares a '/mnt$RAIZSCRIPTS' desde '$RAIZSCRIPTSLIVE'" && echo
cp $RAIZSCRIPTSLIVE/*.* /mnt$RAIZSCRIPTS/ 
mv $RAIZSCRIPTSLIVE/$DISTRO/ $RAIZSCRIPTSDISTRO

# Paso 2-SetupSOdesdeLiveCD.sh  
#Comprobamos que el script existe
if [ ! -f "$RAIZSCRIPTSDISTRO/$SCRIPT2" ]; then
    echorojo "No se encontró el script de configuración: $RAIZSCRIPTSDISTRO/$SCRIPT2"
    sleep 10 && exit 1
else
    chmod +x /$RAIZSCRIPTSDISTRO/*.sh
fi
#--------------------------------------------------------------------------------------
echoverde "Ejecutamos $SCRIPT2 en el entorno chroot... ($RAIZSCRIPTS/$SCRIPT2)"
chroot /mnt $RAIZSCRIPTS/$DISTRO/$SCRIPT2 2>&1 | tee $DISTROLOGS/$SCRIPT2.log
#---------------------------------------------------------------------------------------

echo && echo 
# Check installation result
if [[ $(tail -n 1 $DISTROLOGS/$SCRIPT2.log) == "Correcto" ]]; then
    echo -e "\e[32mInstalación completada. Reinicia el sistema para iniciar Linux Mint.\e[0m"
    sleep 10 && reboot
else
    setxkbmap es
    echo -e "\e[31mInstalación fallida. Revisa logs de instalación: /mnt$RAIZLOGS\e[0m"
    sleep 100000
    
fi
###
###


#Conexión   (como root/root o mint/mint)
#ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@10.0.72.42

#quiero ver los ultimos mensajes del log (y que se sigan viendo los nuevos)
#tail -f /var/log/first-boot-update.log


###05/06/2025 18:40  ... el script hace lo que tiene que hacer, 
# pero se queda negro tras la actualización. Se puede arreglar arrancando como "nomodeset",
# pero bajaría rendimiento gráfico. (POR INVESTIGAR!!!!)



