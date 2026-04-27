#!/bin/bash

## Asegurar la última versión de este script mediante: git -C /opt/IAC-IESMHP pull
set -e
VERSIONSCRIPT="3.00"       # Versión del script: adaptado para Ubuntu 26.04 moderno
SISTEMAOPERATIVO="Ubuntu"  # Nombre del sistema operativo
VERSION="26.04"            # Versión de la ISO del SO
NOMBREISOFINAL="$SISTEMAOPERATIVO-CEIABD-SMRV-v$VERSION"
OUTPUT="${NOMBREISOFINAL}.iso" # Definimos el nombre del archivo de salida

# Funciones de colores
verde() { echo -e "\033[32m$1\033[0m"; }
rojo() { echo -e "\033[31m$1\033[0m"; }

verde "(vs $VERSIONSCRIPT) Iniciando creación de ISO personalizada $SISTEMAOPERATIVO $VERSION..."

# Verifica si es root
if [ "$EUID" -ne 0 ]; then
    rojo "Este script debe ejecutarse como root."
    sleep 5 && exit 1
fi

# Verifica que se pasó una ISO
if [ -z "$1" ]; then
    ISO="/tmp/ubuntu-26.04-desktop-amd64.iso"
    rojo "No se ha especificado una ISO. Se usará $ISO."
else
    ISO="$1"
fi

# Verifica que la ISO existe
if [ ! -f "$ISO" ]; then
    rojo "La ISO especificada no existe: $ISO"
    sleep 5 && exit 1
fi
    
# Verifica que existen utilidades necesarias (Eliminado isolinux, añadido lo necesario para squash y repos)
verde "Comprobando utilidades de creación de ISO..."
apt-get update -yqq || true
apt-get install -y xorriso squashfs-tools rsync git

# Creamos un directorio temporal para trabajar
WORKDIR=$(mktemp -d ./livecd.XXXXXX) && chmod 755 "$WORKDIR"

# Sobre el directorio de trabajo, creamos los subdirectorios necesarios
GITREPO="https://github.com/victormuelacarriles/IAC-IESMHP.git"
RAIZGIT="$WORKDIR/IAC-IESMHP"
MOUNTDIR="$WORKDIR/mount" 
EXTRACTDIR="$WORKDIR/extract"
SQUASHFS_DIR="$WORKDIR/squashfs"
NOMBRESCRIPINICIAL="0b-Github.sh"
SCRIPT_GIT="$RAIZGIT/$SISTEMAOPERATIVO/ISO/$VERSION/$NOMBRESCRIPINICIAL"

verde "Descargo los scripts en $RAIZGIT"
git clone "$GITREPO" "$RAIZGIT"

# Verifica que existe el script de setup
if [ ! -f "$SCRIPT_GIT" ]; then
    rojo "No se encontró $SCRIPT_GIT"
    sleep 5 && exit 1
fi

verde "Montando ISO sobre la carpeta $MOUNTDIR ..."
mkdir -p "$MOUNTDIR"
mount -o loop "$ISO" "$MOUNTDIR"

verde "Copiando contenido de la ISO en $EXTRACTDIR ..."
mkdir -p "$EXTRACTDIR"
rsync -a "$MOUNTDIR/" "$EXTRACTDIR/"

# Buscar dinámicamente el archivo squashfs principal de Ubuntu
SQUASHFS_FILE=$(find "$MOUNTDIR/casper" -maxdepth 1 -name "*.squashfs" | head -n 1)
if [ -z "$SQUASHFS_FILE" ]; then
    rojo "Error crítico: No se ha encontrado ningún archivo .squashfs en $MOUNTDIR/casper/"
    umount -l "$MOUNTDIR"
    exit 1
fi

verde "Extrayendo $SQUASHFS_FILE en '$SQUASHFS_DIR'..."
unsquashfs -d "$SQUASHFS_DIR" "$SQUASHFS_FILE"

verde "Copio el script inicial en la raíz del entorno live"
cp "$SCRIPT_GIT" "$SQUASHFS_DIR/"

verde "Creando servicio autostart del usuario live para ejecutar el script al iniciar sesión..."
# CORRECCIÓN: El usuario de LiveCD en Ubuntu es 'ubuntu'
AUTOSTART_DIR="$SQUASHFS_DIR/home/ubuntu/.config/autostart"
mkdir -p "$AUTOSTART_DIR"

# Crear un .desktop que ejecute el script en un terminal
cat <<EOF-AUTOSTART > "$AUTOSTART_DIR/setup.desktop"
[Desktop Entry]
Type=Application
Exec=x-terminal-emulator -e sudo /bin/bash /$NOMBRESCRIPINICIAL
Name=SetupLiveCD
Comment=Script de configuración personalizado para el LiveCD
X-GNOME-Autostart-enabled=true
EOF-AUTOSTART

# Ajustar permisos para que el usuario live no tenga conflictos (uid tipico de live en ubuntu: 999)
chown -R 999:999 "$SQUASHFS_DIR/home/ubuntu" 2>/dev/null || true

verde "Reempaquetando el sistema de archivos (esto tardará un poco)..."
SQUASHFS_BASENAME=$(basename "$SQUASHFS_FILE")
rm -f "$EXTRACTDIR/casper/$SQUASHFS_BASENAME" # Evita conflictos y añade en limpio
mksquashfs "$SQUASHFS_DIR" "$EXTRACTDIR/casper/$SQUASHFS_BASENAME" -comp xz -b 1M -noappend

# Personalizamos GRUB de la LiveCD ISO
verde "Configurando menú de arranque (GRUB)..."
# Hacemos copia de seguridad del grub.cfg original
cp "$EXTRACTDIR/boot/grub/grub.cfg" "$EXTRACTDIR/boot/grub/grub.cfg.$(date +%Y%m%d-%H%M).backup"

# Localizar el initrd (que ya no suele llamarse .lz)
INITRD_FILE=$(find "$EXTRACTDIR/casper" -maxdepth 1 -name "initrd*" -exec basename {} \; | head -n 1)

# Creo un nuevo grub.cfg. IMPORTANTE: Usamos \ antes de las variables exclusivas de GRUB.
cat <<EOF-NUEVOGRUB > "$EXTRACTDIR/boot/grub/grub.cfg"
loadfont unicode
set color_normal=white/black
set color_highlight=black/light-gray
set timeout=5
set timeout_style=menu
set default=0

menuentry "Instalación 'ON FIRE!' - by Victor Muela  [vs $VERSION $(date +%Y%m%d-%H%M)]" --class ubuntu {
    set gfxpayload=keep
    linux   /casper/vmlinuz boot=casper username=ubuntu hostname=ubuntu iso-scan/filename=\${iso_path} quiet splash nomodeset -- 
    initrd  /casper/$INITRD_FILE
}

grub_platform
if [ "\$grub_platform" = "efi" ]; then
    menuentry 'Boot from next volume' {
        exit 1
    }
    menuentry 'UEFI Firmware Settings' {
        fwsetup
    }
fi
EOF-NUEVOGRUB

verde "Creando nueva ISO personalizada..."
# CORRECCIÓN: Comando xorriso actualizado para ISOs modernas basadas íntegramente en GRUB 2.
xorriso -as mkisofs -r -V "$NOMBREISOFINAL" \
    -cache-inodes -J -l \
    -c boot.cat \
    -b boot/grub/i386-pc/eltorito.img \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
    -eltorito-alt-boot \
    -e boot/grub/efi.img \
    -no-emul-boot -isohybrid-gpt-basdat -isohybrid-atapi \
    -o "$OUTPUT" "$EXTRACTDIR"

verde "ISO personalizada creada con éxito: $OUTPUT"

# Limpieza
verde "Desmontando sistema y limpiando temporales..."
umount -l "$MOUNTDIR" || true
rm -rf "$WORKDIR"