#!/usr/bin/env bash
# crear-iso.sh
# Genera una ISO arrancable (UEFI con Secure Boot + mensaje de error en BIOS)
# a partir de la carpeta preparada para el USB (usb-nfs).
#
# Uso:
#   ./crear-iso.sh [carpeta] [fichero.iso]
#   ./crear-iso.sh ~/usb-nfs InstalaciónDesdeRed.iso      (valores por defecto)
#
# Dependencias (Ubuntu):
#   sudo apt install xorriso mtools dosfstools grub-pc-bin grub-common
#
# La ISO resultante sirve para:
#   - Arrancar una máquina virtual (como CD/DVD).
#   - Grabarse en un USB con dd, Rufus (modo DD) o balenaEtcher (es ISO híbrida).

set -euo pipefail

CARPETA="${1:-$HOME/usb-nfs}"
ISO="${2:-InstalaciónDesdeRed.iso}"
ETIQUETA="NFSBOOT"                       # Etiqueta de volumen (máx. 32 caracteres, sin espacios)
GRUB_BIOS="/usr/lib/grub/i386-pc"

error() { echo "ERROR: $*" >&2; exit 1; }
info()  { echo ">> $*"; }

TMP=""
limpiar() { [[ -n "$TMP" ]] && rm -rf "$TMP"; return 0; }
trap limpiar EXIT

# ---------- Comprobaciones ----------
for cmd in xorriso mkfs.vfat mmd mcopy grub-mkimage; do
    command -v "$cmd" >/dev/null || error "Falta '$cmd'. Instala: sudo apt install xorriso mtools dosfstools grub-pc-bin grub-common"
done
[[ -f "$GRUB_BIOS/boot_hybrid.img" ]] || error "Falta $GRUB_BIOS (sudo apt install grub-pc-bin)"

[[ -d "$CARPETA" ]] || error "No existe la carpeta $CARPETA"
for f in EFI/boot/bootx64.efi EFI/boot/grubx64.efi .disk/info boot/grub/grub.cfg; do
    [[ -f "$CARPETA/$f" ]] || error "Falta $CARPETA/$f"
done
for d in "$CARPETA"/live/*/; do
    [[ -f "$d/vmlinuz" && -f "$d/initrd" ]] || error "Falta vmlinuz o initrd en $d"
done

if grep -n 'echo' "$CARPETA/boot/grub/grub.cfg" | LC_ALL=C grep -q '[^ -~]'; then
    echo "AVISO: hay 'echo' con tildes o ñ en grub.cfg; en modo BIOS se verán como '?'." >&2
fi

TMP="$(mktemp -d)"
STAGING="$TMP/iso"

# ---------- 1. Copia de trabajo de la carpeta (no se modifica la original) ----------
info "Copiando $CARPETA ..."
cp -a "$CARPETA/." "$STAGING/"

# ---------- 2. Imagen FAT con el cargador UEFI firmado (shim + GRUB) ----------
info "Creando la partición EFI ..."
TAM_KB=$(( $(du -sk "$CARPETA/EFI" | cut -f1) + 2048 ))      # contenido + 2 MiB de margen
mkfs.vfat -C -n EFI "$TMP/efi.img" "$TAM_KB" >/dev/null
mmd   -i "$TMP/efi.img" ::/EFI ::/EFI/boot
mcopy -i "$TMP/efi.img" "$CARPETA"/EFI/boot/* ::/EFI/boot/

# ---------- 3. GRUB de BIOS (solo para mostrar el mensaje de error) ----------
info "Creando el GRUB de BIOS ..."
mkdir -p "$STAGING/boot/grub/i386-pc"
grub-mkimage -O i386-pc-eltorito -p /boot/grub \
    -o "$STAGING/boot/grub/i386-pc/eltorito.img" \
    biosdisk iso9660 part_msdos part_gpt normal configfile test echo sleep halt search

# ---------- 4. Generar la ISO híbrida ----------
info "Generando $ISO ..."
xorriso -as mkisofs \
    -r -J -joliet-long -V "$ETIQUETA" \
    -o "$ISO" \
    --grub2-mbr "$GRUB_BIOS/boot_hybrid.img" \
    -partition_offset 16 \
    --mbr-force-bootable \
    -append_partition 2 0xef "$TMP/efi.img" \
    -appended_part_as_gpt \
    -c boot.catalog \
    -b boot/grub/i386-pc/eltorito.img \
        -no-emul-boot -boot-load-size 4 -boot-info-table --grub2-boot-info \
    -eltorito-alt-boot \
    -e '--interval:appended_partition_2:all::' \
        -no-emul-boot \
    "$STAGING" 2>&1 | grep -vE '^(xorriso|Drive current|Media current|Media status|Media summary|Added to ISO|Written to medium|Writing to|libisofs|$)|UPDATE' || true

[[ -s "$ISO" ]] || error "No se ha generado la ISO."
info "ISO creada: $ISO ($(du -h "$ISO" | cut -f1))"
