#!/bin/bash
set -e
VERSIONSCRIPT="3.00-ZFS"       # Versión ZFS
REPO="IAC-IESMHP"
GITREPO="https://github.com/victormuelacarriles/$REPO.git"
RAIZSCRIPTSLIVE="/LiveCDiesmhp"
DISTRO="Mint"
RAIZSCRIPTS="/opt/$REPO"
RAIZLOGS="/var/log/$REPO"
SCRIPT2="2-SetupSOdesdeLiveCD.sh"
versionDISTRO=$(grep VERSION_ID /etc/os-release | cut -d'"' -f2)

# Funciones de colores
echoverde() { echo -e "\033[32m$1\033[0m"; }
echorojo()  { echo -e "\033[31m$1\033[0m"; }
echoamarillo() { echo -e "\033[33m$1\033[0m"; }

# Configuración idioma
setxkbmap es || true && loadkeys es ||true

# --------------------------------------------------------------------------
# PRE-REQUISITO: ZFS
# --------------------------------------------------------------------------
if ! command -v zpool &> /dev/null; then
    echoamarillo "Herramientas ZFS no detectadas. Instalando zfsutils-linux..."
    apt-get update && apt-get install -y zfsutils-linux
    modprobe zfs
fi

echoverde "1-SetupLiveCD (vs$VERSIONSCRIPT) - MODO ZFS + DEDUP"
echo         "   Instalación Linux Mint $versionDISTRO sobre ZFS Root"
echoamarillo "   ADVERTENCIA: La deduplicación requiere mucha RAM."
echoverde "--------------------------------------------------------------------"
sleep 5

# Carpetas de trabajo 
mkdir -p $RAIZSCRIPTSLIVE
mkdir -p $RAIZSCRIPTS
mkdir -p $RAIZLOGS

# Detectamos discos
DISCOS_M2=($(lsblk -dno NAME,SIZE,TRAN | grep -v loop0| grep -v 'usb'| grep nvme | sort -h -k2 | awk '{print $1}'))
DISCOS_SD=($(lsblk -dno NAME,SIZE,TRAN | grep -v loop0| grep -v 'usb'| grep sd | sort -h -k2 | awk '{print $1}'))

if [ -z "${DISCOS_M2}" ]; then 
    echorojo "No se encontraron discos NVMe. Saliendo."
    sleep 10 && exit 1
else
    if [ -z "${DISCOS_M2[1]}" ]; then 
        if [ -z "${DISCOS_SD[0]}" ]; then 
            echorojo "Error: Solo 1 disco detectado. Se requieren 2."
            sleep 10 && exit 1
        else
            DISK_SMALL="/dev/${DISCOS_M2[0]}"
            DISK_BIG="/dev/${DISCOS_SD[0]}"
        fi
    else
        DISK_SMALL="/dev/${DISCOS_M2[0]}"
        DISK_BIG="/dev/${DISCOS_M2[1]}"
    fi
fi

if [[ "$DISK_SMALL" != *nvme* ]]; then
    echorojo "#Error: se esperaba un disco NVMe para el disco pequeño"
    exit 1
fi

# --------------------------------------------------------------------------
# LIMPIEZA DE DISCOS (LVM Y ZFS ANTIGUO)
# --------------------------------------------------------------------------
echoamarillo "Limpiando rastros de LVM y ZFS previos..."

# Desactivar LVM
vgchange -an || true
# Importar y destruir pools ZFS previos si existen para liberar discos
zpool import -f -aN || true 2>/dev/null
for pool in $(zpool list -H -o name); do
    zpool destroy -f "$pool" || true
done

# Limpieza discos
sgdisk --zap-all "$DISK_SMALL"
sgdisk --zap-all "$DISK_BIG"
wipefs -a "$DISK_SMALL"
wipefs -a "$DISK_BIG"

# --------------------------------------------------------------------------
# PARTICIONADO
# --------------------------------------------------------------------------
echoamarillo "Particionando $DISK_SMALL (EFI, SWAP, ZFS-ROOT)..."
parted -s "$DISK_SMALL" mklabel gpt
parted -s "$DISK_SMALL" mkpart ESP fat32 1MiB 513MiB
parted -s "$DISK_SMALL" set 1 esp on
parted -s "$DISK_SMALL" mkpart primary linux-swap 513MiB 8705MiB
# El resto para ZFS rpool
parted -s "$DISK_SMALL" mkpart primary 8705MiB 100%

echoamarillo "Particionando $DISK_BIG (ZFS-HOME)..."
parted -s "$DISK_BIG" mklabel gpt
parted -s "$DISK_BIG" mkpart primary 1MiB 100%

# Esperar kernel
partprobe "$DISK_SMALL"
partprobe "$DISK_BIG"
sleep 5

# Definir particiones
EFI="${DISK_SMALL}p1"
SWAP="${DISK_SMALL}p2"
PART_RPOOL="${DISK_SMALL}p3"

if [[ "$DISK_BIG" == *sd* ]]; then
    PART_HPOOL="${DISK_BIG}1"
else
    PART_HPOOL="${DISK_BIG}p1"
fi

# Formatear EFI y SWAP (ZFS no usa mkfs)
echoamarillo "Formateando EFI y SWAP..."
mkfs.fat -F32 "$EFI"
mkswap "$SWAP"

# --------------------------------------------------------------------------
# CREACIÓN DE ZFS POOLS Y DATASETS
# --------------------------------------------------------------------------
echoamarillo "Creando Pools ZFS con Deduplicación..."

# Opciones comunes: LZ4 compression, Dedup ON, y optimizaciones
ZFS_OPTS="-o ashift=12 -O acltype=posixacl -O xattr=sa -O dnodesize=auto -O compression=lz4 -O normalization=formD -O dedup=on"

# 1. Crear RPOOL (Sistema) en /mnt
# Usamos -R /mnt para que todas las operaciones se monten relativas a /mnt
zpool create -f $ZFS_OPTS -m none -R /mnt rpool "$PART_RPOOL"

# 2. Crear HPOOL (Home) en /mnt
zpool create -f $ZFS_OPTS -m none -R /mnt hpool "$PART_HPOOL"

echoamarillo "Creando Datasets..."

# Crear contenedor ROOT y dataset del sistema operativo
zfs create -o canmount=off -o mountpoint=none rpool/ROOT
zfs create -o canmount=noauto -o mountpoint=/ rpool/ROOT/mint

# Montar root manualmente
zfs mount rpool/ROOT/mint

# Crear dataset para HOME
zfs create -o canmount=on -o mountpoint=/home hpool/HOME

# Verificación de montaje
echoamarillo "Verificando puntos de montaje ZFS..."
zfs list -r -o name,mountpoint,mounted
lsblk

# --------------------------------------------------------------------------
# PREPARACIÓN PARA COPIA
# --------------------------------------------------------------------------
echoamarillo "Preparando directorios adicionales..."
mkdir -p /mnt/boot/efi
mount "$EFI" /mnt/boot/efi
swapon "$SWAP"

# Copia del sistema (SquashFS)
SQUASHFS=$(find /cdrom -name "filesystem.squashfs" -o -name "*.squashfs" | head -1)
echoamarillo "Montando SquashFS y copiando sistema (esto tardará)..."
mkdir -p /tmp/squashfs
mount -o loop "$SQUASHFS" /tmp/squashfs

rsync -av --exclude=/etc/fstab --exclude=/etc/machine-id /tmp/squashfs/ /mnt/
umount /tmp/squashfs

# Generar un fstab básico (ZFS monta automáticamente, pero EFI y SWAP necesitan fstab)
echoamarillo "Generando fstab para EFI y Swap..."
echo "# /etc/fstab: static file system information." > /mnt/etc/fstab
echo "proc /proc proc nodev,noexec,nosuid 0 0" >> /mnt/etc/fstab
# Añadir EFI UUID
UUID_EFI=$(blkid -s UUID -o value "$EFI")
echo "UUID=$UUID_EFI /boot/efi vfat defaults 0 1" >> /mnt/etc/fstab
# Añadir Swap UUID
UUID_SWAP=$(blkid -s UUID -o value "$SWAP")
echo "UUID=$UUID_SWAP none swap sw 0 0" >> /mnt/etc/fstab

# Preparar Chroot
for dir in /dev /proc /sys /run; do
    mount --bind $dir /mnt$dir
done

# Copiar scripts al destino
RAIZSCRIPTSDISTRO="/mnt$RAIZSCRIPTS/$DISTRO/ISO/$versionDISTRO"
DISTROLOGS="/mnt$RAIZLOGS" 
mkdir -p $RAIZSCRIPTSDISTRO
mkdir -p $DISTROLOGS

cp $RAIZSCRIPTSLIVE/*.* /mnt$RAIZSCRIPTS/ 
mkdir -p /mnt$RAIZSCRIPTS/Mint
cp -r $RAIZSCRIPTSLIVE/$DISTRO/* /mnt$RAIZSCRIPTS/Mint/ || true

# --------------------------------------------------------------------------
# EJECUCIÓN SCRIPT 2 (ATENCIÓN: EL SCRIPT 2 DEBE SOPORTAR ZFS)
# --------------------------------------------------------------------------
if [ ! -f "$RAIZSCRIPTSDISTRO/$SCRIPT2" ]; then
    echorojo "No se encontró el script 2: $RAIZSCRIPTSDISTRO/$SCRIPT2"
    sleep 10 && exit 1
else
    chmod +x /$RAIZSCRIPTSDISTRO/*.sh
fi

echoamarillo "Entrando en Chroot para ejecutar $SCRIPT2..."
# NOTA: El script 2 debe instalar 'zfs-initramfs' y configurar grub para ZFS
chroot /mnt ${RAIZSCRIPTSDISTRO#/mnt}/$SCRIPT2 2>&1 | tee $DISTROLOGS/$SCRIPT2.log

# Finalizar
if [[ $(tail -n 1 $DISTROLOGS/$SCRIPT2.log) == "Correcto" ]]; then
    echoverde "Instalación completada."
    # Exportar pools para asegurar integridad antes del reboot
    echoamarillo "Desmontando y exportando pools ZFS..."
    umount /mnt/boot/efi
    zfs umount -a
    zpool export -a
    sleep 5 && reboot
else
    echorojo "Instalación fallida. Revisa los logs."
    sleep 100000
fi