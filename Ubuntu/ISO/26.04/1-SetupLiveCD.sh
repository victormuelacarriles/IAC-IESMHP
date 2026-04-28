#!/bin/bash
# =============================================================================
#  1-SetupLiveCD.sh  —  Ubuntu 26.04
#  Instalación manual desde el entorno Live CD (arrancado desde ISO custom).
#  Lanzado por perso.sh tras clonar el repositorio en /opt/IAC-IESMHP.
#
#  Configuraciones de disco soportadas:
#    Distancia : NVMe 0,5 TB (/, /swap, /EFI) + NVMe 2,0 TB (/home)
#    CEIABD    : NVMe 0,5 TB (/, /swap, /EFI) + SDA  1,0 TB (/home)
# =============================================================================
set -e

VERSIONSCRIPT="22.2-20260428-Ubuntu"
REPO="IAC-IESMHP"
GITREPO="https://github.com/victormuelacarriles/$REPO.git"

# CAMBIO: el repo ya está clonado por perso.sh en /opt/$REPO
RAIZSCRIPTSLIVE="/opt/$REPO"
# CAMBIO: Distro Ubuntu en lugar de Mint
DISTRO="Ubuntu"
RAIZSCRIPTS="/opt/$REPO"
RAIZLOG="/var/log/$REPO/$DISTRO"

SCRIPT2="2-SetupSOdesdeLiveCD.sh"
versionDISTRO=$(grep VERSION_ID /etc/os-release | cut -d'"' -f2)

# ─────────────── Colores ───────────────
echoverde()    { echo -e "\033[32m$1\033[0m"; }
echorojo()     { echo -e "\033[31m$1\033[0m"; }
echoamarillo() { echo -e "\033[33m$1\033[0m"; }

# ─────────────── Log ───────────────────
# Redirigimos la salida al log desde el inicio
mkdir -p "$RAIZLOG"
exec > >(tee -a "$RAIZLOG/1-SetupLiveCD.sh.log") 2>&1

# ─────────────── Teclado ───────────────
# || true porque en entorno sin X11 setxkbmap puede fallar
setxkbmap es || true
loadkeys es   || true

# ─────────────── Cabecera ──────────────
echoverde "1-SetupLiveCD (vs$VERSIONSCRIPT)"
echo         "   Script personalizado de instalación de "
echo         "   sistema operativo $DISTRO $versionDISTRO para equipos distancia / CEIABD"
echoamarillo "   (victor.muelacarriles@educantabria.es)"
echoverde "--------------------------------------------------------------------"
echoverde "       Distancia     ->Disco pequeño: NVMe 0,5TB (/EFI, /swap y /)"
echoverde "                     ->Disco grande:  NVMe 2,0TB (/home)"
echoverde "--------------------------------------------------------------------"
echoverde "       CEIABD        ->Disco pequeño: NVMe 0,5TB (/EFI, /swap y /)"
echoverde "                     ->Disco grande:  SDa  1,0TB (/home)"
echoverde "--------------------------------------------------------------------"
sleep 1
echoamarillo "                                                  (comenzará en 10sg)"
echoverde "--------------------------------------------------------------------"
sleep 9

# ─────────────── Carpetas de trabajo ───
mkdir -p "$RAIZSCRIPTSLIVE"   # ya existe (clonado por perso.sh), mkdir -p es seguro
mkdir -p "$RAIZSCRIPTS"
mkdir -p "$RAIZLOG"
echoverde "Carpetas de trabajo: $RAIZSCRIPTSLIVE, $RAIZSCRIPTS, $RAIZLOG"

# ─────────────── Detectar discos ───────
# Ignoramos USB y loop
DISCOS_M2=($(lsblk -dno NAME,SIZE,TRAN | grep -v loop0 | grep -v 'usb' | grep nvme | sort -h -k2 | awk '{print $1}'))
DISCOS_SD=($(lsblk -dno NAME,SIZE,TRAN | grep -v loop0 | grep -v 'usb' | grep sd   | sort -h -k2 | awk '{print $1}'))

lsblk -dno NAME,SIZE | grep -v '^loop0'
echo "DISCOS_M2[0]: ${DISCOS_M2[0]:-<vacío>}"
echo "DISCOS_M2[1]: ${DISCOS_M2[1]:-<vacío>}"
echo "DISCOS_SD[0]: ${DISCOS_SD[0]:-<vacío>}"

if [ -z "${DISCOS_M2[0]:-}" ]; then
    echorojo "No se encontraron discos NVMe. Asegúrate de que el equipo tiene discos conectados."
    sleep 1000 && exit 1
else
    if [ -z "${DISCOS_M2[1]:-}" ]; then
        # Solo hay un NVMe → buscamos un SD como disco grande
        if [ -z "${DISCOS_SD[0]:-}" ]; then
            echorojo "No hay segundo disco SD (hay sólo un NVMe sin disco secundario). Detenemos."
            sleep 1000 && exit 1
        else
            DISK_SMALL="/dev/${DISCOS_M2[0]}"
            DISK_BIG="/dev/${DISCOS_SD[0]}"
            echoverde "Equipo NVME+SD:"
            echoverde "    /     -> NVMe ($DISK_SMALL)"
            echoverde "    /home -> SD   ($DISK_BIG)"
        fi
    else
        DISK_SMALL="/dev/${DISCOS_M2[0]}"
        DISK_BIG="/dev/${DISCOS_M2[1]}"
        echoverde "Equipo 2×NVMe:"
        echoverde "    /     -> pequeño ($DISK_SMALL)"
        echoverde "    /home -> grande  ($DISK_BIG)"
    fi
fi

if [[ "$DISK_SMALL" != *nvme* ]]; then
    echorojo "Error: se esperaba un disco NVMe para el disco pequeño"
    exit 1
fi

# ─────────────── Limpiar LVM si existe ─
if lsblk -o NAME,TYPE | grep -q "lvm"; then
    echoamarillo "Detectadas particiones LVM. Eliminando..."
    vgchange -an || true
    for part in $(lsblk -o NAME,TYPE | grep "lvm" | awk '{print $1}'); do
        echoamarillo "  Borrando LVM: $part"
        sgdisk --zap-all "/dev/$part" || true
    done
    echoverde "Particiones LVM eliminadas"
fi

# ─────────────── Particionar ───────────
echo && echoamarillo "Borrando y particionando: $DISK_SMALL y $DISK_BIG"
lsblk -o NAME,SIZE,TYPE

sgdisk --zap-all "$DISK_SMALL"
sgdisk --zap-all "$DISK_BIG"

parted -s "$DISK_SMALL" mklabel gpt
parted -s "$DISK_BIG"   mklabel gpt

# Disco pequeño: EFI (512 MiB) + swap (8 GiB) + raíz (resto)
parted -s "$DISK_SMALL" mkpart ESP      fat32      1MiB    513MiB
parted -s "$DISK_SMALL" set 1 esp on
parted -s "$DISK_SMALL" mkpart primary  linux-swap 513MiB  8705MiB
parted -s "$DISK_SMALL" mkpart primary  ext4       8705MiB 100%

# Disco grande: /home (todo)
parted -s "$DISK_BIG"   mkpart primary  ext4       1MiB    100%

echoverde "Discos particionados: $DISK_SMALL y $DISK_BIG"

echoamarillo "Esperando detección de particiones por el kernel..."
sleep 5

# ─────────────── Asignar particiones ───
EFI="${DISK_SMALL}p1"
SWAP="${DISK_SMALL}p2"
ROOT="${DISK_SMALL}p3"

# La nomenclatura de partición difiere entre NVMe (/dev/nvmeXnYpZ)
# y discos SD/SATA (/dev/sdXN)
if [[ "$DISK_BIG" == *sd* ]]; then
    HOME_PART="${DISK_BIG}1"
elif [[ "$DISK_BIG" == *nvme* ]]; then
    HOME_PART="${DISK_BIG}p1"
else
    echorojo "Error: no se pudo determinar la partición de /home"
    exit 1
fi

# ─────────────── Formatear ─────────────
echoamarillo "Formateando (EFI=$EFI, SWAP=$SWAP, ROOT=$ROOT, HOME=$HOME_PART)..."
mkfs.fat -F32 "$EFI"
mkswap "$SWAP"
mkfs.ext4 -F "$ROOT"
mkfs.ext4 -F "$HOME_PART"

if ! blkid "$EFI" || ! blkid "$SWAP" || ! blkid "$ROOT" || ! blkid "$HOME_PART"; then
    echorojo "Error: no se pudieron formatear correctamente las particiones"
    sleep 10 && exit 1
fi
echoverde "Particiones formateadas correctamente"

# ─────────────── Montar ────────────────
echoamarillo "Montando sistemas de ficheros..."
mount "$ROOT"      /mnt
mkdir -p /mnt/boot/efi
mkdir -p /mnt/home
mount "$EFI"       /mnt/boot/efi
mount "$HOME_PART" /mnt/home
swapon "$SWAP"
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT
echoverde "Sistemas de ficheros montados"

# ─────────────── Copiar squashfs ───────
# Ubuntu Desktop 26.04 usa casper/filesystem.squashfs (igual que versiones anteriores)
SQUASHFS=$(find /cdrom -name "filesystem.squashfs" -o -name "*.squashfs" 2>/dev/null | head -1)
[[ -n "$SQUASHFS" ]] || { echorojo "No se encontró filesystem.squashfs en /cdrom"; exit 1; }

echoamarillo "Montando squashfs: $SQUASHFS ..."
mkdir -p /tmp/squashfs
mount -o loop "$SQUASHFS" /tmp/squashfs

echoamarillo "Copiando sistema de archivos a /mnt ..."
rsync -av --exclude=/etc/fstab --exclude=/etc/machine-id /tmp/squashfs/ /mnt/
echoverde "Sistema de archivos copiado desde $SQUASHFS"

umount /tmp/squashfs

# ─────────────── Preparar chroot ───────
for dir in /dev /proc /sys /run; do
    mount --bind $dir /mnt$dir
done

# ─────────────── Copiar scripts al destino ─
# RAIZSCRIPTSDISTRO: ruta dentro del sistema instalado donde estarán los scripts
# CAMBIO: corregido $Distro (minúscula, indefinida) → $DISTRO; eliminado /ISO/ redundante
RAIZSCRIPTSDISTRO="/mnt${RAIZSCRIPTS}/${DISTRO}/${versionDISTRO}"
DISTROLOGS="/mnt${RAIZLOG}"

mkdir -p "$RAIZSCRIPTSDISTRO"
mkdir -p "$DISTROLOGS"

echo
echoamarillo "Copiando ${RAIZSCRIPTSLIVE}/*.* → /mnt${RAIZSCRIPTS}/"
cp "${RAIZSCRIPTSLIVE}"/*.* "/mnt${RAIZSCRIPTS}/" 2>/dev/null || true

# CAMBIO: destino usa $DISTRO en lugar de "Mint" hardcodeado
echoamarillo "Copiando ${RAIZSCRIPTSLIVE}/${DISTRO}/ → /mnt${RAIZSCRIPTS}/${DISTRO}/"
mkdir -p "/mnt${RAIZSCRIPTS}/${DISTRO}"
cp -r "${RAIZSCRIPTSLIVE}/${DISTRO}/." "/mnt${RAIZSCRIPTS}/${DISTRO}/"

# ─────────────── Verificar SCRIPT2 ─────
if [ ! -f "$RAIZSCRIPTSDISTRO/$SCRIPT2" ]; then
    echorojo "No se encontró el script de configuración: $RAIZSCRIPTSDISTRO/$SCRIPT2"
    sleep 10 && exit 1
else
    chmod +x "${RAIZSCRIPTSDISTRO}"/*.sh
fi

# ─────────────── Log de este script ────
echoamarillo "Copiando log a $DISTROLOGS/1-SetupLiveCD.sh.log"
cp "$RAIZLOG/1-SetupLiveCD.sh.log" "$DISTROLOGS/1-SetupLiveCD.sh.log"

# ─────────────── Ejecutar SCRIPT2 ──────
echoamarillo "Ejecutando $SCRIPT2 en chroot... (${RAIZSCRIPTSDISTRO#/mnt}/$SCRIPT2)"
chroot /mnt "${RAIZSCRIPTSDISTRO#/mnt}/$SCRIPT2" 2>&1 | tee "$DISTROLOGS/$SCRIPT2.log"

# ─────────────── Resultado ─────────────
echo && echo
if [[ "$(tail -n 1 "$DISTROLOGS/$SCRIPT2.log")" == "Correcto" ]]; then
    echo -e "\e[32mInstalación completada. Reinicia el sistema para iniciar $DISTRO $versionDISTRO.\e[0m"
    sleep 10 && reboot
else
    setxkbmap es || true
    echo -e "\e[31mInstalación fallida. Revisa logs: /mnt${RAIZLOG}\e[0m"
    sleep 100000
fi