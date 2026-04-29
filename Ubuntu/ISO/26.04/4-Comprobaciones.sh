#!/bin/bash
# =============================================================================
#  4-Comprobaciones.sh  —  Ubuntu 26.04
#  Diagnóstico del sistema instalado.
#  Funciona tanto dentro del chroot (llamado desde 2-SetupSOdesdeLiveCD.sh)
#  como en el sistema ya arrancado (llamado desde 3-SetupPrimerInicio.sh).
# =============================================================================
VERSIONSCRIPT="1.0-20260429"
REPO="IAC-IESMHP"
DISTRO="Ubuntu"
RAIZLOG="/var/log/$REPO/$DISTRO"
mkdir -p "$RAIZLOG"
LOGFILE="$RAIZLOG/4-Comprobaciones.sh.log"

ERRORES=0
AVISOS=0

_ok()  { echo -e "\033[32m[OK ] $*\033[0m" | tee -a "$LOGFILE"; }
_err() { echo -e "\033[31m[ERR] $*\033[0m" | tee -a "$LOGFILE"; (( ERRORES++ )) || true; }
_avs() { echo -e "\033[33m[AVS] $*\033[0m" | tee -a "$LOGFILE"; (( AVISOS++ ))  || true; }
_inf() { echo -e "\033[36m[INF] $*\033[0m" | tee -a "$LOGFILE"; }

_sep() { echo "── $* $(printf '─%.0s' {1..50})" | cut -c1-70 | tee -a "$LOGFILE"; }

echo | tee -a "$LOGFILE"
echo "================================================================" | tee -a "$LOGFILE"
echo " 4-Comprobaciones.sh (vs$VERSIONSCRIPT) — $(date)" | tee -a "$LOGFILE"
echo "================================================================" | tee -a "$LOGFILE"

# ─────────────────────────────────────────────────────────────────────────────
_sep "1. KERNEL Y BOOT"

KERNEL=$(ls /boot/vmlinuz-* 2>/dev/null | sort -V | tail -1)
if [ -z "$KERNEL" ]; then
    _err "No se encontró ningún kernel en /boot/"
else
    KVER=$(basename "$KERNEL" | sed 's/vmlinuz-//')
    _ok "Kernel: $KERNEL"

    # Módulos
    if [ -d "/lib/modules/$KVER" ]; then
        _ok "Módulos: /lib/modules/$KVER existe"
    else
        _err "Módulos: /lib/modules/$KVER NO existe — initramfs no puede incluir drivers correctamente"
    fi

    # Initramfs
    INITRD="/boot/initrd.img-$KVER"
    if [ ! -f "$INITRD" ]; then
        _err "Initramfs no encontrado: $INITRD"
    else
        SIZE=$(du -sh "$INITRD" 2>/dev/null | cut -f1)
        _ok "Initramfs: $INITRD ($SIZE)"

        # Extraer lista de contenidos (soporta gzip, lz4, zstd)
        LISTADO=$(lsinitramfs "$INITRD" 2>/dev/null \
                  || zcat "$INITRD" 2>/dev/null | cpio -t 2>/dev/null \
                  || true)

        if [ -z "$LISTADO" ]; then
            _avs "No se pudo inspeccionar el initramfs (herramienta no disponible)"
        else
            # NVMe
            if echo "$LISTADO" | grep -q nvme; then
                _ok "  Driver NVMe: presente en initramfs"
            else
                _err "  Driver NVMe: AUSENTE en initramfs → kernel panic al arrancar"
                _avs "  Fix: echo MODULES=most > /etc/initramfs-tools/conf.d/modules && update-initramfs -u -k $KVER"
            fi

            # Casper (no debe estar en un sistema instalado)
            if echo "$LISTADO" | grep -q casper; then
                _err "  Hooks casper: presentes en initramfs → sistema no arrancará como instalado"
                _avs "  Fix: apt-get remove --purge casper && update-initramfs -u -k $KVER"
            else
                _ok "  Hooks casper: no presentes (correcto para sistema instalado)"
            fi
        fi
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
_sep "2. GRUB"

if [ ! -f /boot/grub/grub.cfg ]; then
    _err "grub.cfg no encontrado en /boot/grub/grub.cfg"
else
    _ok "grub.cfg encontrado"
    GRUB_ROOT_UUID=$(grep -oP 'root=UUID=\K[a-f0-9-]+' /boot/grub/grub.cfg | head -1)

    if [ -z "$GRUB_ROOT_UUID" ]; then
        _err "No hay root=UUID=... en grub.cfg — GRUB no sabe dónde está el root"
        _inf "  Líneas 'linux' en grub.cfg:"
        grep '^\s*linux\s' /boot/grub/grub.cfg | head -5 | sed 's/^/    /' | tee -a "$LOGFILE"
    else
        _inf "  UUID root en grub.cfg: $GRUB_ROOT_UUID"
        DEVICE=$(blkid -U "$GRUB_ROOT_UUID" 2>/dev/null)
        if [ -n "$DEVICE" ]; then
            _ok "  UUID root existe en: $DEVICE"
        else
            _err "  UUID root $GRUB_ROOT_UUID NO existe en ningún dispositivo → kernel panic"
        fi
    fi

    _inf "  Entradas GRUB:"
    grep -E 'menuentry|^\s+linux ' /boot/grub/grub.cfg | grep -v '^#' | head -10 \
        | sed 's/^/    /' | tee -a "$LOGFILE"
fi

# ─────────────────────────────────────────────────────────────────────────────
_sep "3. FSTAB"

if [ ! -f /etc/fstab ]; then
    _err "/etc/fstab no existe"
else
    _inf "Contenido de /etc/fstab:"
    cat /etc/fstab | sed 's/^/  /' | tee -a "$LOGFILE"
    echo | tee -a "$LOGFILE"

    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue
        UUID=$(echo "$line" | grep -oP 'UUID=\K[a-f0-9-]+')
        MP=$(echo "$line" | awk '{print $2}')
        [ -z "$UUID" ] && continue
        DEV=$(blkid -U "$UUID" 2>/dev/null)
        if [ -n "$DEV" ]; then
            _ok "  UUID $UUID ($MP) → $DEV"
        else
            _err "  UUID $UUID ($MP) → ningún dispositivo con ese UUID"
        fi
    done < /etc/fstab
fi

# ─────────────────────────────────────────────────────────────────────────────
_sep "4. PARTICIONES DETECTADAS"
lsblk -o NAME,SIZE,TYPE,FSTYPE,UUID,MOUNTPOINT 2>/dev/null | tee -a "$LOGFILE"

# ─────────────────────────────────────────────────────────────────────────────
_sep "5. PAQUETES CLAVE"

for pkg in casper ubiquity; do
    if dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
        _err "$pkg está instalado (debe eliminarse antes de update-initramfs)"
    else
        _ok "$pkg: no instalado"
    fi
done

BROKEN=$(dpkg --audit 2>/dev/null | wc -l)
if [ "$BROKEN" -gt 0 ]; then
    _avs "dpkg --audit detectó $BROKEN problema(s):"
    dpkg --audit 2>/dev/null | sed 's/^/  /' | tee -a "$LOGFILE"
else
    _ok "dpkg: sin paquetes rotos"
fi

# ─────────────────────────────────────────────────────────────────────────────
_sep "6. INITRAMFS-TOOLS CONFIG"

CONF_MODULES=/etc/initramfs-tools/conf.d/modules
CONF_RESUME=/etc/initramfs-tools/conf.d/resume

if [ -f "$CONF_MODULES" ]; then
    VAL=$(cat "$CONF_MODULES")
    _inf "  $CONF_MODULES: $VAL"
    [[ "$VAL" == *"most"* ]] && _ok "  MODULES=most (correcto para chroot)" \
                             || _avs "  MODULES no es 'most' — puede faltar driver NVMe"
else
    _avs "  $CONF_MODULES no existe (se usará el valor por defecto 'dep')"
fi

if [ -f "$CONF_RESUME" ]; then
    _ok "  $CONF_RESUME: $(cat $CONF_RESUME)"
else
    _avs "  $CONF_RESUME no existe — initramfs puede buscar swap incorrecto"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Servicios systemd (solo si el sistema está arrancado, no en chroot)
if systemctl is-system-running &>/dev/null 2>&1; then
    _sep "7. SERVICIOS SYSTEMD"
    FAILED=$(systemctl --failed --no-legend 2>/dev/null | wc -l)
    if [ "$FAILED" -gt 0 ]; then
        _avs "$FAILED servicio(s) fallido(s):"
        systemctl --failed --no-legend 2>/dev/null | sed 's/^/  /' | tee -a "$LOGFILE"
    else
        _ok "Todos los servicios activos correctamente"
    fi
    if systemctl is-active --quiet ssh 2>/dev/null || systemctl is-active --quiet sshd 2>/dev/null; then
        _ok "SSH: activo"
    else
        _avs "SSH: no activo"
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
echo | tee -a "$LOGFILE"
echo "================================================================" | tee -a "$LOGFILE"
echo " RESUMEN: $ERRORES error(es)  |  $AVISOS aviso(s)" | tee -a "$LOGFILE"
if [ "$ERRORES" -eq 0 ]; then
    echo -e "\033[32m Sistema listo para arrancar correctamente\033[0m" | tee -a "$LOGFILE"
else
    echo -e "\033[31m $ERRORES problema(s) detectado(s) que pueden impedir el arranque\033[0m" | tee -a "$LOGFILE"
fi
echo " Log: $LOGFILE" | tee -a "$LOGFILE"
echo "================================================================" | tee -a "$LOGFILE"
