#!/bin/bash
#"set -e" significa que el script se detendrá si ocurre un error
set -e
VERSIONSCRIPT="3.00-ZFS"       # Versión del script adaptada a ZFS
REPO="IAC-IESMHP"
DISTRO="Mint"
versionDISTRO=$(grep VERSION_ID /etc/os-release | cut -d'"' -f2)
RAIZSCRIPTS="/opt/$REPO"
RAIZLOGS="/var/log/$REPO"
RAIZDISTRO="$RAIZSCRIPTS/$DISTRO/ISO/$versionDISTRO"
SCRIPT3="3-SetupPrimerInicio.sh"

# Funciones de colores
echoverde() { echo -e "\033[32m$1\033[0m"; }
echorojo()  { echo -e "\033[31m$1\033[0m"; }  
echoamarillo() { echo -e "\033[33m$1\033[0m"; }

echoverde "$0 (vs$VERSIONSCRIPT) - MODO ZFS"

# --------------------------------------------------------------------------
# 0. ASEGURAR INTERNET (NECESARIO PARA BAJAR DRIVERS ZFS)
# --------------------------------------------------------------------------
echoamarillo "Comprobando conectividad..."
while ! ping -c 1 1.1.1.1 &> /dev/null; do
    echo "No se puede acceder a Internet. Necesario para instalar ZFS-DKMS."
    echo "Revisa la conexión de red."
    sleep 5
done

# --------------------------------------------------------------------------
# 1. CONFIGURACIÓN IDIOMA
# --------------------------------------------------------------------------
echoamarillo "Configurando el entorno gráfico en español..."
sed -i 's/# es_ES.UTF-8/es_ES.UTF-8/g' /etc/locale.gen
locale-gen es_ES.UTF-8
echo "LANG=es_ES.UTF-8" > /etc/default/locale
echo "LC_ALL=es_ES.UTF-8" >> /etc/default/locale
echo "LANGUAGE=es_ES" >> /etc/default/locale
echo "XKBLAYOUT=es" > /etc/default/keyboard
echo "XKBMODEL=pc105" >> /etc/default/keyboard

mkdir -p /etc/dconf/db/local.d
cat > /etc/dconf/db/local.d/00-language << EOF
[org/gnome/desktop/input-sources]
sources=[('xkb', 'es')]
xkb-options=[]
[org/gnome/system/locale]
region='es_ES.UTF-8'
EOF
dconf update 2>/dev/null || echo "dconf se aplicará en el primer inicio"

# --------------------------------------------------------------------------
# 2. INSTALACIÓN SOPORTE ZFS (CRÍTICO)
# --------------------------------------------------------------------------
echoamarillo "Instalando soporte ZFS (Kernel modules e Initramfs)..."
# Eliminamos paquetes live primero para evitar conflictos, pero con cuidado
apt-get remove -y --purge casper ubiquity ubiquity-frontend-* live-boot live-boot-initramfs-tools || true

apt-get update
# Instalamos zfs-initramfs y zfs-dkms. GRUB-EFI suele venir instalado, pero aseguramos.
apt-get install -y --no-install-recommends zfs-initramfs zfs-dkms zfsutils-linux grub-efi-amd64-signed shim-signed

echoverde "...Paquetes ZFS instalados."

# --------------------------------------------------------------------------
# 3. CONFIGURAR FSTAB (SOLO EFI y SWAP)
# --------------------------------------------------------------------------
echoamarillo "Configurando /etc/fstab para ZFS (Solo EFI y SWAP)..."

# IMPORTANTE: En ZFS, "/" y "/home" NO deben estar en fstab.
# ZFS los monta automáticamente. Solo necesitamos EFI y SWAP.

# Buscamos la partición EFI (normalmente vfat y montada en /boot/efi)
# Nota: Como estamos en chroot, usamos blkid para buscar tipos
UUID_EFI=$(blkid -t TYPE=vfat -s UUID -o value | head -n 1)
UUID_SWAP=$(blkid -t TYPE=swap -s UUID -o value | head -n 1)

if [ -z "$UUID_EFI" ]; then echorojo "ALERTA: No se detectó partición EFI"; fi

cat > /etc/fstab << EOF
# /etc/fstab: static file system information.
# Generado por script SetupZFS

# <file system> <mount point>   <type>  <options>       <dump>  <pass>
proc            /proc           proc    nodev,noexec,nosuid 0       0

# EFI
UUID=$UUID_EFI  /boot/efi       vfat    umask=0077      0       1

# SWAP
UUID=$UUID_SWAP none            swap    sw              0       0
EOF

cat /etc/fstab
echoverde "...Fstab generado (ZFS gestiona Root y Home nativamente)"

# --------------------------------------------------------------------------
# 4. USUARIOS Y MAC (Igual que script original)
# --------------------------------------------------------------------------
echoamarillo "Gestionando usuarios y MAC..."
MAC=$(ip link show | awk '/ether/ {print $2}' | head -n 1)
mkdir -p /root/.ssh
LOCAL_MACS="$RAIZSCRIPTS/macs.csv"
LOCAL_AUTORIZADOS="$RAIZSCRIPTS/Autorizados.txt"
cp $LOCAL_AUTORIZADOS /root/.ssh/authorized_keys 2>/dev/null || true

EQUIPOENMACS="mint"
if [ -f "$LOCAL_MACS" ]; then
    if grep -q -i "$MAC" "$LOCAL_MACS"; then
        INFO_MACS=$(cat $LOCAL_MACS | grep -i $MAC )
        EQUIPOENMACS=$(echo $INFO_MACS | cut -d',' -f2 | xargs)
    fi
fi

if [ "$(hostname)" != "$EQUIPOENMACS" ]; then
    echo "$EQUIPOENMACS" > /etc/hostname
    echo "127.0.0.1 localhost" > /etc/hosts
    echo "127.0.1.1 $EQUIPOENMACS" >> /etc/hosts
    hostnamectl set-hostname "$EQUIPOENMACS" 2>/dev/null || true
fi

echo "root:root" | chpasswd
useradd -m -s /bin/bash usuario || true
echo "usuario:usuario" | chpasswd
adduser usuario sudo 2>/dev/null || true

if [ -f /root/.ssh/authorized_keys ]; then
    mkdir -p /home/usuario/.ssh
    cp /root/.ssh/authorized_keys /home/usuario/.ssh/
    chown -R usuario:usuario /home/usuario/.ssh
    chmod 600 /home/usuario/.ssh/authorized_keys
fi

# --------------------------------------------------------------------------
# 5. GRUB E INITRAMFS PARA ZFS
# --------------------------------------------------------------------------
echoverde "Configurando GRUB para ZFS..."

# Modificar configuración de GRUB
# Quitamos "quiet splash" para ver errores de ZFS si los hay al principio
sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT=""/' /etc/default/grub

# Asegurar que GRUB carga ZFS. A veces grub-probe falla dentro de chroot,
# pero update-grub debería encontrar rpool.
echo "GRUB_PRELOAD_MODULES=\"zfs\"" >> /etc/default/grub

# Actualizar Initramfs (Genera la imagen de arranque con soporte ZFS)
echoverde "Generando Initramfs..."
update-initramfs -c -k all

# Actualizar e Instalar GRUB
echoverde "Actualizando GRUB..."
update-grub

# Instalar en el disco físico. 
# En el script 1, el disco pequeño era el de arranque. 
# Intentamos detectar el disco que contiene la partición EFI montada.
DISK_BOOT=$(lsblk -no pkname /dev/disk/by-uuid/$UUID_EFI | head -n 1)

if [ -z "$DISK_BOOT" ]; then
    # Fallback si no detecta el disco: intentamos adivinar nvme0n1
    DISK_BOOT="nvme0n1" 
fi

echoamarillo "Instalando GRUB en /dev/$DISK_BOOT..."
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=MINT --recheck "/dev/$DISK_BOOT"

if [ $? -eq 0 ]; then
    echoverde "...GRUB instalado correctamente."
else
    echorojo "Error al instalar GRUB. Verifique logs."
fi

# --------------------------------------------------------------------------
# 6. SETUP SERVICIO PRIMER INICIO
# --------------------------------------------------------------------------
echo "Generando machine-id..."
rm -f /etc/machine-id
dbus-uuidgen > /etc/machine-id
ln -sf /etc/machine-id /var/lib/dbus/machine-id

if [ -f "$RAIZDISTRO/$SCRIPT3" ]; then
    echo "Configurando servicio de actualización..."
    chmod +x "$RAIZDISTRO/$SCRIPT3"

CONTENIDOSERVICIO="[Unit]
Description=3-SetupPrimerInicio
DefaultDependencies=no
Wants=network-online.target zfs-mount.service
After=network-online.target graphical.target zfs-mount.service
Conflicts=shutdown.target

[Service]
Type=always
Environment=LC_ALL=es_ES.UTF-8
ExecStart=sudo /bin/bash $RAIZDISTRO/$SCRIPT3 
StandardOutput=append: $RAIZLOGS/$SCRIPT3.log
StandardError=append: $RAIZLOGS/$SCRIPT3.log
TimeoutSec=0
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target"

    echo "$CONTENIDOSERVICIO" > /etc/systemd/system/3-SetupPrimerInicio.service
    systemctl enable 3-SetupPrimerInicio.service
fi

echo && echo "Correcto"