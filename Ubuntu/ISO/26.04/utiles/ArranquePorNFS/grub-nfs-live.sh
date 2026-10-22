#!/usr/bin/env bash
# grub-nfs-live.sh
# Configura GRUB para que el equipo arranque Ubuntu Live desde un recurso NFS (casper, netboot=nfs).
#
# Uso:
#   sudo ./grub-nfs-live.sh servidor:/ruta/exportada
#   sudo ./grub-nfs-live.sh --restaurar /root/grub-backup-AAAAMMDD-HHMMSS.tar.gz
#
# El recurso NFS debe contener el CONTENIDO de la ISO (carpeta casper/), no el fichero .iso.

set -euo pipefail

DESTINO="/boot/live"                    # Dónde se copian kernel e initrd
SCRIPT_GRUB="/etc/grub.d/09_nfs_live"   # Script que genera la entrada
ENTRY_ID="nfs-live"                     # Id de la entrada (para GRUB_DEFAULT)
TIMEOUT_MONTAJE=20                      # Segundos máximos para comprobar el NFS
MANTENER=("00_header" "05_debian_theme" "09_nfs_live")  # Scripts de grub.d que siguen activos

MNT=""

error() { echo "ERROR: $*" >&2; exit 1; }
info()  { echo ">> $*"; }

limpiar() {
    if [[ -n "$MNT" ]]; then
        if mountpoint -q "$MNT"; then umount "$MNT" 2>/dev/null || true; fi
        rmdir "$MNT" 2>/dev/null || true
        MNT=""
    fi
}
trap limpiar EXIT

# Cambia (o añade) una variable en /etc/default/grub
fijar_variable() {
    local var="$1" valor="$2" f="/etc/default/grub"
    if grep -qE "^#?[[:space:]]*${var}=" "$f"; then
        sed -i -E "s|^#?[[:space:]]*${var}=.*|${var}=${valor}|" "$f"
    else
        echo "${var}=${valor}" >> "$f"
    fi
}

restaurar() {
    local copia="$1"
    [[ -f "$copia" ]] || error "No existe la copia de seguridad: $copia"
    info "Restaurando la configuración de GRUB desde $copia"
    rm -f "$SCRIPT_GRUB"
    tar -xzpf "$copia" -C /
    update-grub
    info "Configuración original restaurada (los ficheros de $DESTINO no se han borrado)."
}

# ---------- Comprobaciones previas ----------
[[ $EUID -eq 0 ]] || error "Ejecuta el script como root (sudo)."
[[ $# -ge 1 ]]    || error "Uso: $0 servidor:/ruta   |   $0 --restaurar copia.tar.gz"

if [[ "$1" == "--restaurar" ]]; then
    [[ $# -eq 2 ]] || error "Indica el fichero de copia de seguridad."
    restaurar "$2"
    exit 0
fi

NFS="$1"
[[ "$NFS" =~ ^[^:/]+:/.+ ]] || error "Formato no válido. Esperado servidor:/ruta (p. ej. 192.168.1.10:/srv/ubuntu-live)"

for cmd in mount.nfs update-grub grub-probe grub-mkrelpath timeout tar; do
    command -v "$cmd" >/dev/null || error "Falta el comando '$cmd' (¿están instalados nfs-common y grub?)"
done

# ---------- 1. Comprobar que el NFS existe ----------
info "Comprobando el recurso NFS $NFS ..."
MNT="$(mktemp -d /tmp/nfs-live.XXXXXX)"
if ! timeout "$TIMEOUT_MONTAJE" mount -t nfs -o ro,nolock,soft "$NFS" "$MNT"; then
    error "No se puede montar $NFS (servidor inaccesible o recurso no exportado)."
fi

[[ -f "$MNT/casper/vmlinuz" ]] || error "El recurso no contiene casper/vmlinuz. ¿Es el contenido de una ISO de Ubuntu?"
INITRD_ORIG="$(ls "$MNT"/casper/initrd* 2>/dev/null | head -n1 || true)"
[[ -n "$INITRD_ORIG" ]] || error "No se encuentra casper/initrd* en el recurso."
compgen -G "$MNT/casper/*.squashfs" >/dev/null || error "No se encuentra ningún .squashfs en casper/."

[[ -f "$MNT/.disk/info" ]] && info "Imagen encontrada: $(cat "$MNT/.disk/info")"

# ---------- 2. Confirmación ----------
echo
echo "ATENCIÓN: se desactivarán TODAS las entradas actuales de GRUB."
echo "El equipo solo arrancará la imagen de $NFS por red (necesita conexión por cable)."
read -rp "¿Quieres reinstalar el sistema operativo a partir de esta imagen? [s/N] " resp
[[ "$resp" =~ ^[sS]$ ]] || { info "Operación cancelada. No se ha modificado nada."; exit 0; }

# ---------- 3. Copiar kernel e initrd de la imagen ----------
info "Copiando kernel e initrd a $DESTINO ..."
mkdir -p "$DESTINO"
install -m 0644 "$MNT/casper/vmlinuz" "$DESTINO/vmlinuz"
install -m 0644 "$INITRD_ORIG"        "$DESTINO/initrd"
limpiar

# ---------- 4. Copia de seguridad de la configuración de GRUB ----------
if [[ -e "$SCRIPT_GRUB" ]]; then
    info "GRUB ya estaba configurado por este script: no se hace nueva copia (conserva la original)."
else
    COPIA="/root/grub-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
    tar -czpf "$COPIA" -C / etc/default/grub etc/grub.d
    info "Copia de seguridad creada: $COPIA"
fi

# ---------- 5. Desactivar el resto de entradas ----------
for f in /etc/grub.d/*; do
    nombre="$(basename "$f")"
    [[ " ${MANTENER[*]} " == *" $nombre "* ]] && continue
    chmod -x "$f"
done

# ---------- 6. Crear la entrada de la opción A ----------
UUID_BOOT="$(grub-probe --target=fs_uuid "$DESTINO/vmlinuz")"
KERNEL_REL="$(grub-mkrelpath "$DESTINO/vmlinuz")"   # Ruta vista por GRUB (tiene en cuenta /boot separado)
INITRD_REL="$(grub-mkrelpath "$DESTINO/initrd")"

cat > "$SCRIPT_GRUB" <<EOF
#!/bin/sh
exec tail -n +3 \$0
menuentry "Ubuntu Live por NFS ($NFS)" --id $ENTRY_ID {
    search --no-floppy --fs-uuid --set=root $UUID_BOOT
    linux $KERNEL_REL boot=casper netboot=nfs nfsroot=$NFS ip=dhcp quiet splash noprompt
    initrd $INITRD_REL
}
EOF
chmod +x "$SCRIPT_GRUB"

# ---------- 7. Entrada por defecto y regenerar grub.cfg ----------
fijar_variable GRUB_DEFAULT "$ENTRY_ID"
fijar_variable GRUB_TIMEOUT_STYLE menu
fijar_variable GRUB_TIMEOUT 5

update-grub

grep -q "nfsroot=$NFS" /boot/grub/grub.cfg || error "La entrada no aparece en /boot/grub/grub.cfg."
info "Entradas en grub.cfg: $(grep -cE '^[[:space:]]*menuentry' /boot/grub/grub.cfg || true)"
info "Listo. En el próximo arranque se cargará la imagen de $NFS."
[[ -n "${COPIA:-}" ]] && info "Para deshacerlo: sudo $0 --restaurar $COPIA"
exit 0
