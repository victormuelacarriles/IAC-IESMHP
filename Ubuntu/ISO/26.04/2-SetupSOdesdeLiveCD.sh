#!/bin/bash
set -e
VERSIONSCRIPT="22.4-20260502"
REPO="IAC-IESMHP"
DISTRO="Ubuntu"
versionDISTRO=$(grep VERSION_ID /etc/os-release | cut -d'"' -f2)
RAIZSCRIPTS="/opt/$REPO"
RAIZDISTRO="$RAIZSCRIPTS/$DISTRO/ISO/$versionDISTRO"
RAIZLOG="/var/log/$REPO/$DISTRO"
SCRIPT3="3-SetupPrimerInicio.sh"

# ─── Logging propio ───────────────────────────────────────────────────────────
# Todo stdout/stderr va al terminal (via tee del padre) Y a este log.
# Además se genera un fichero .steps con una línea por paso, para diagnóstico rápido.
mkdir -p "$RAIZLOG"
LOG2="$RAIZLOG/2-SetupSOdesdeLiveCD.sh.log"
STEPS="$RAIZLOG/2-SetupSOdesdeLiveCD.steps"
exec > >(tee -a "$LOG2") 2>&1
: > "$STEPS"   # vaciar/crear fichero de pasos

_PASO=0
paso() {
    _PASO=$((_PASO + 1))
    local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo ""
    echo "════════════════════════════════════════════════════════════"
    echo "  PASO ${_PASO}: $*"
    echo "  ${ts}"
    echo "════════════════════════════════════════════════════════════"
    echo "[PASO${_PASO}][${ts}] INICIO: $*" >> "$STEPS"
}
ok()   { echo -e "  \033[32m[OK ]\033[0m  $(date '+%H:%M:%S') $*";  echo "  [OK ] $(date '+%H:%M:%S') $*" >> "$STEPS"; }
err()  { echo -e "  \033[31m[ERR]\033[0m  $(date '+%H:%M:%S') $*" >&2; echo "  [ERR] $(date '+%H:%M:%S') $*" >> "$STEPS"; }
info() { echo -e "  \033[36m[INF]\033[0m  $(date '+%H:%M:%S') $*";  echo "  [INF] $(date '+%H:%M:%S') $*" >> "$STEPS"; }

# Funciones de colores (compatibilidad con código existente)
echoverde()    { echo -e "\033[32m$1\033[0m"; }
echorojo()     { echo -e "\033[31m$1\033[0m"; }
echoamarillo() { echo -e "\033[33m$1\033[0m"; }

paso "Inicio — $0 (vs$VERSIONSCRIPT) — chroot $(hostname)"
info "RAIZLOG=$RAIZLOG  RAIZDISTRO=$RAIZDISTRO"
info "Log completo : $LOG2"
info "Fichero pasos: $STEPS"

# ─────────────────────────────────────────────────────────────────────────────
paso "Idioma y teclado español"
# ─────────────────────────────────────────────────────────────────────────────
sed -i 's/# es_ES.UTF-8/es_ES.UTF-8/g' /etc/locale.gen
locale-gen es_ES.UTF-8

printf 'LANG=es_ES.UTF-8\nLC_ALL=es_ES.UTF-8\nLANGUAGE=es_ES\n' > /etc/default/locale

printf 'XKBLAYOUT=es\nXKBMODEL=pc105\nXKBVARIANT=\nXKBOPTIONS=\n' > /etc/default/keyboard

mkdir -p /etc/dconf/db/local.d
cat > /etc/dconf/db/local.d/00-language << 'LANGEOF'
[org/gnome/desktop/input-sources]
sources=[('xkb', 'es')]
xkb-options=[]

[org/gnome/system/locale]
region='es_ES.UTF-8'
LANGEOF
ok "Idioma y teclado configurados"

# ─────────────────────────────────────────────────────────────────────────────
paso "Fondo de escritorio (dconf)"
# ─────────────────────────────────────────────────────────────────────────────
mkdir -p /etc/dconf/profile
[ -f /etc/dconf/profile/user ] || printf 'user-db:user\nsystem-db:local\n' > /etc/dconf/profile/user

mkdir -p /etc/dconf/db/local.d
cat > /etc/dconf/db/local.d/01-wallpaper << 'WALLEOF'
[org/gnome/desktop/background]
picture-uri='file:///usr/share/backgrounds/iac-iesmhp.png'
picture-uri-dark='file:///usr/share/backgrounds/iac-iesmhp.png'
picture-options='zoom'
WALLEOF

# En chroot no hay entorno gráfico; dconf update puede fallar — se aplicará en el primer login.
dconf update 2>/dev/null && ok "dconf actualizado" || info "dconf se aplicará en el primer inicio (normal en chroot)"

# ─────────────────────────────────────────────────────────────────────────────
paso "Configurar /etc/fstab"
# ─────────────────────────────────────────────────────────────────────────────
# lsblk dentro del chroot ve los mount points del HOST (/mnt, /mnt/boot/efi…),
# no los del sistema instalado. Las particiones vienen del fichero creado por 1-SetupLiveCD.sh.
PARTS_FILE=/tmp/.iac-partitions.env
if [ -f "$PARTS_FILE" ]; then
    # shellcheck disable=SC1090
    source "$PARTS_FILE"
    EFI="${PART_EFI##*/}"
    SWAP="${PART_SWAP##*/}"
    ROOT="${PART_ROOT##*/}"
    HOME_DEV="${PART_HOME##*/}"
    ok "Particiones leídas: EFI=$EFI  SWAP=$SWAP  ROOT=$ROOT  HOME=$HOME_DEV"
else
    err "AVISO: $PARTS_FILE no encontrado — detección automática (puede fallar en chroot)"
    EFI=$(lsblk  -rno NAME,MOUNTPOINT | awk '$2 == "/mnt/boot/efi" {print $1}')
    SWAP=$(lsblk -rno NAME,MOUNTPOINT | awk '$2 == "[SWAP]"        {print $1}')
    ROOT=$(lsblk -rno NAME,MOUNTPOINT | awk '$2 == "/mnt"          {print $1}')
    HOME_DEV=$(lsblk -rno NAME,MOUNTPOINT | awk '$2 == "/mnt/home" {print $1}')
fi

info "EFI=/dev/$EFI  SWAP=/dev/$SWAP  ROOT=/dev/$ROOT  HOME=/dev/$HOME_DEV"
[ -n "$ROOT" ] || { err "ERROR: no se pudo determinar la partición root"; exit 1; }

UUID_ROOT=$(blkid -s UUID -o value "/dev/$ROOT")
UUID_EFI=$(blkid  -s UUID -o value "/dev/$EFI")
UUID_HOME=$(blkid -s UUID -o value "/dev/$HOME_DEV")
UUID_SWAP=$(blkid -s UUID -o value "/dev/$SWAP")
info "UUID ROOT=$UUID_ROOT  EFI=$UUID_EFI  HOME=$UUID_HOME  SWAP=$UUID_SWAP"

cat > /etc/fstab << EOF
# /etc/fstab — generado por $0 el $(date)
UUID=$UUID_ROOT  /          ext4  defaults  0 1
UUID=$UUID_EFI   /boot/efi  vfat  umask=0077  0 1
UUID=$UUID_HOME  /home      ext4  defaults  0 2
UUID=$UUID_SWAP  none       swap  sw          0 0
EOF
cat /etc/fstab
ok "fstab generado con UUIDs"

# ─────────────────────────────────────────────────────────────────────────────
paso "Verificar conectividad a Internet"
# ─────────────────────────────────────────────────────────────────────────────
while ! ping -c 1 -W 3 1.1.1.1 &>/dev/null; do
    echoamarillo "Sin Internet. Reintentando en 10 s… (Ctrl+C para abortar)"
    sleep 10
done
ok "Internet disponible"

# ─────────────────────────────────────────────────────────────────────────────
paso "MAC, hostname y claves SSH autorizadas"
# ─────────────────────────────────────────────────────────────────────────────
MAC=$(ip link show | awk '/ether/ {print $2}' | head -n 1)
info "MAC detectada: $MAC"
mkdir -p /root/.ssh
LOCAL_MACS="$RAIZSCRIPTS/macs.csv"
LOCAL_AUTORIZADOS="$RAIZSCRIPTS/Autorizados.txt"
cp "$LOCAL_AUTORIZADOS" /root/.ssh/authorized_keys
ok "authorized_keys copiado"

EQUIPOENMACS=$DISTRO
if [ ! -f "$LOCAL_MACS" ]; then
    err "No se encontró $LOCAL_MACS — el equipo quedará con nombre '$DISTRO'"
else
    if ! grep -q -i "$MAC" "$LOCAL_MACS"; then
        err "MAC $MAC no encontrada en macs.csv — nombre por defecto '$DISTRO'"
    else
        INFO_MACS=$(grep -i "$MAC" "$LOCAL_MACS")
        info "Entrada en macs.csv: $INFO_MACS"
        echo "$INFO_MACS" > "$LOCAL_MACS"
        EQUIPOENMACS=$(echo "$INFO_MACS" | cut -d',' -f2 | xargs)
    fi
fi

EQUIPOACTUAL=$(hostname)
if [ "$EQUIPOACTUAL" != "$EQUIPOENMACS" ]; then
    echo "$EQUIPOENMACS" > /etc/hostname
    printf '127.0.0.1 localhost\n127.0.1.1 %s\n' "$EQUIPOENMACS" > /etc/hosts
    hostnamectl set-hostname "$EQUIPOENMACS" 2>/dev/null || true
    ok "Hostname cambiado: $EQUIPOACTUAL → $EQUIPOENMACS"
else
    ok "Hostname correcto: $EQUIPOENMACS"
fi

# ─────────────────────────────────────────────────────────────────────────────
paso "Usuarios (root y usuario)"
# ─────────────────────────────────────────────────────────────────────────────
echo "root:root" | chpasswd
ok "Contraseña root establecida"

if id usuario &>/dev/null; then
    info "Usuario 'usuario' ya existe"
else
    useradd -m -s /bin/bash usuario
    ok "Usuario 'usuario' creado"
fi
echo "usuario:usuario" | chpasswd
adduser usuario sudo 2>/dev/null || usermod -aG sudo usuario
ok "Usuario 'usuario' en grupo sudo"

if [ -f /root/.ssh/authorized_keys ]; then
    mkdir -p /home/usuario/.ssh
    cp /root/.ssh/authorized_keys /home/usuario/.ssh/
    chown usuario:usuario /home/usuario/.ssh/authorized_keys
    chmod 600 /home/usuario/.ssh/authorized_keys
    ok "authorized_keys copiado a /home/usuario/.ssh/"
fi

# ─────────────────────────────────────────────────────────────────────────────
paso "GRUB (grub-install + update-grub)"
# ─────────────────────────────────────────────────────────────────────────────
info "Instalando GRUB EFI en /boot/efi  (bootloader-id=$DISTRO)"
grub-install --target=x86_64-efi --efi-directory=/boot/efi \
             --bootloader-id="$DISTRO" --recheck --no-floppy
ok "grub-install OK"

sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"/' /etc/default/grub
grep -q "GRUB_CMDLINE_LINUX_DEFAULT" /etc/default/grub \
    || echo 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"' >> /etc/default/grub

info "Ejecutando update-grub..."
update-grub
ok "update-grub OK"
info "Entradas 'linux' en grub.cfg (verificación root=):"
grep -E '^\s*linux\s' /boot/grub/grub.cfg 2>/dev/null | sed 's/^/    /' || info "  (grub.cfg no encontrado aún)"

# update-grub en chroot a veces genera root=/dev/XXX en lugar de root=UUID=...
# porque grub-probe no puede resolver el UUID del dispositivo desde dentro del chroot.
# Lo corregimos reemplazando la ruta de dispositivo por el UUID real en grub.cfg.
GRUB_CFG=/boot/grub/grub.cfg
if grep -q 'root=UUID=' "$GRUB_CFG" 2>/dev/null; then
    ok "grub.cfg usa UUID para root — correcto"
else
    ROOT_DEV="/dev/$ROOT"
    ROOT_UUID=$(blkid -s UUID -o value "$ROOT_DEV" 2>/dev/null || true)
    if [ -n "$ROOT_UUID" ]; then
        # Reemplazar root=/dev/nvme0n1p3 → root=UUID=xxxx en todas las entradas linux
        sed -i "s|root=${ROOT_DEV}\b|root=UUID=${ROOT_UUID}|g" "$GRUB_CFG"
        ok "grub.cfg parcheado: root=${ROOT_DEV} → root=UUID=${ROOT_UUID}"
    else
        err "grub.cfg usa nombre de dispositivo para root y no se pudo obtener UUID de $ROOT_DEV"
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
paso "Machine-ID"
# ─────────────────────────────────────────────────────────────────────────────
rm -f /etc/machine-id
dbus-uuidgen > /etc/machine-id
ln -sf /etc/machine-id /var/lib/dbus/machine-id
ok "machine-id generado: $(cat /etc/machine-id)"

# ─────────────────────────────────────────────────────────────────────────────
paso "Eliminar hooks de casper y generar initramfs"
# ─────────────────────────────────────────────────────────────────────────────
# casper tiene hooks en /usr/share/initramfs-tools/hooks/ diseñados para Live CD.
# Si están presentes, update-initramfs los ejecuta, fallan silenciosamente y el
# initramfs no se genera → el sistema no arranca.
#
# NO usamos apt-get remove porque el procesamiento de dpkg triggers (man-db,
# initramfs-tools, etc.) se bloquea en el chroot. Borramos directamente los
# ficheros de hooks — es todo lo que necesitamos para que update-initramfs funcione.

info "Eliminando hooks de casper directamente (sin apt, sin triggers dpkg)..."
CASPER_HOOKS_REMOVED=0
for f in \
    /usr/share/initramfs-tools/hooks/casper \
    /usr/share/initramfs-tools/scripts/casper \
    /usr/share/initramfs-tools/scripts/casper-bottom \
    /usr/share/initramfs-tools/scripts/casper-premount \
    /etc/initramfs-tools/hooks/casper \
    /etc/casper.conf \
; do
    if [ -e "$f" ]; then
        rm -rf "$f"
        info "  Eliminado: $f"
        CASPER_HOOKS_REMOVED=$((CASPER_HOOKS_REMOVED + 1))
    fi
done
# Eliminar cualquier otro fichero de casper en initramfs-tools que pudiera existir
find /usr/share/initramfs-tools /etc/initramfs-tools \
     -name '*casper*' -exec rm -rf {} + 2>/dev/null || true
ok "Hooks de casper eliminados ($CASPER_HOOKS_REMOVED ficheros/dirs encontrados)"

info "Configurando MODULES=most y RESUME=none..."
mkdir -p /etc/initramfs-tools/conf.d
echo "MODULES=most" > /etc/initramfs-tools/conf.d/modules
echo "RESUME=none"  > /etc/initramfs-tools/conf.d/resume

# Recuperar update-initramfs si fue enmascarado como /bin/true.
# El rsync copia desde el squashfs (read-only), que normalmente no incluye
# las modificaciones del live, pero verificamos de todas formas.
# En merged-usr Ubuntu 26.04: /usr/sbin → bin, así que comprobamos también /usr/bin.
_UPDATE_INITRAMFS_REAL=true
for _masked in /usr/local/sbin/update-initramfs /usr/sbin/update-initramfs /usr/bin/update-initramfs; do
    if [ -L "$_masked" ] && readlink "$_masked" | grep -qE "(^|/)true$"; then
        rm -f "$_masked"
        info "  Eliminada máscara: $_masked → $(readlink $_masked)"
        _UPDATE_INITRAMFS_REAL=false
    fi
done
if [ "$_UPDATE_INITRAMFS_REAL" = "false" ]; then
    info "Reinstalando initramfs-tools para recuperar update-initramfs real..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y --reinstall initramfs-tools 2>&1 | sed 's/^/    /'
    ok "update-initramfs restaurado: $(readlink -f $(command -v update-initramfs))"
fi

# Protección extra: verificar que el binario no es un no-op por tamaño
_UI_BIN=$(readlink -f "$(command -v update-initramfs 2>/dev/null || echo '')" 2>/dev/null || echo "")
if [ -n "$_UI_BIN" ]; then
    _UI_SIZE=$(stat -c%s "$_UI_BIN" 2>/dev/null || echo "0")
    info "update-initramfs → $_UI_BIN (${_UI_SIZE} bytes)"
    if [ "$_UI_SIZE" -lt 200 ]; then
        info "  → binario sospechoso, reinstalando initramfs-tools..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y --reinstall initramfs-tools 2>&1 | sed 's/^/    /'
    fi
fi

# update-initramfs sale silenciosamente con código 0 si detecta entorno de
# contenedor/chroot. Causas: /run bind-mount trae /run/systemd/container del
# live CD (VMware), o DPKG_MAINTSCRIPT_PACKAGE heredad de apt previo activa
# la guarda ischroot. Limpiamos antes de llamarlo.
unset DPKG_MAINTSCRIPT_PACKAGE DPKG_MAINTSCRIPT_NAME DPKG_RUNNING_VERSION 2>/dev/null || true
rm -f /run/systemd/container /run/container_type 2>/dev/null || true

# Kernel instalado: preferir el de /lib/modules/ (el del chroot) sobre uname -r (kernel del host live)
KERNEL_INSTALADO=$(ls /lib/modules/ 2>/dev/null | sort -V | tail -1)
info "Kernels en /lib/modules/: $(ls /lib/modules/ 2>/dev/null | tr '\n' ' ' || echo 'NINGUNO')"
info "Ficheros en /boot/ antes de generar initramfs:"
ls -lh /boot/ 2>/dev/null | sed 's/^/    /' || info "  /boot/ vacío o inaccesible"

# Usar -c (create) en lugar de -u (update): -u no crea initramfs nuevos si no
# existe uno previo, lo que ocurre en sistemas instalados desde squashfs live.
info "Ejecutando update-initramfs -c -k all -v (puede tardar 2-4 min)..."
update-initramfs -c -k all -v
ok "update-initramfs terminado"

# Verificar que el initramfs se creó; usar kernel del chroot, no del host live
KERNEL="${KERNEL_INSTALADO:-$(uname -r)}"
if [ -f "/boot/initrd.img-${KERNEL}" ]; then
    INITRAMFS_SIZE=$(du -sh "/boot/initrd.img-${KERNEL}" | cut -f1)
    ok "Initramfs generado: /boot/initrd.img-${KERNEL} (${INITRAMFS_SIZE})"
else
    err "Initramfs NO encontrado en /boot/initrd.img-${KERNEL} — el sistema no arrancará"
    info "Ficheros en /boot/:"
    ls -lh /boot/ | sed 's/^/    /'
    info "Kernels en /lib/modules/: $(ls /lib/modules/ 2>/dev/null | tr '\n' ' ')"
    exit 1
fi

# ── Asegurar línea initrd en grub.cfg ──────────────────────────────────────────
# grub.cfg se generó en el paso anterior cuando initrd.img-${KERNEL} aún no existía
# (solo había symlinks colgantes). grub/10_linux usa 'test -e' → omite la línea
# initrd → el kernel arranca sin initramfs → VFS panic (unknown-block 0,0).
# Ahora que el initramfs existe, regeneramos grub.cfg con la línea initrd correcta.
info "Verificando línea initrd en grub.cfg..."
if ! grep -qE '^\s+initrd\s' "$GRUB_CFG" 2>/dev/null; then
    info "  grub.cfg sin línea initrd — re-ejecutando update-grub..."
    update-grub 2>&1 | grep -E '^(Found|Generating|done|Warning|Adding)' | sed 's/^/    /' || true
    # Re-aplicar parche UUID (update-grub en chroot escribe root=/dev/...)
    ROOT_DEV_STEP10="/dev/$ROOT"
    ROOT_UUID_STEP10=$(blkid -s UUID -o value "$ROOT_DEV_STEP10" 2>/dev/null || true)
    if [ -n "$ROOT_UUID_STEP10" ] && grep -q "root=${ROOT_DEV_STEP10}" "$GRUB_CFG" 2>/dev/null; then
        sed -i "s|root=${ROOT_DEV_STEP10}\b|root=UUID=${ROOT_UUID_STEP10}|g" "$GRUB_CFG"
        ok "grub.cfg re-parcheado: root=${ROOT_DEV_STEP10} → root=UUID=${ROOT_UUID_STEP10}"
    fi
    ok "grub.cfg regenerado con línea initrd"
else
    ok "grub.cfg ya tiene línea initrd — correcto"
fi
info "Líneas linux+initrd en grub.cfg (verificación final):"
grep -E '^\s*(linux|initrd)\s' "$GRUB_CFG" 2>/dev/null | head -8 | sed 's/^/    /' || true

# ─────────────────────────────────────────────────────────────────────────────
paso "Servicio 3-SetupPrimerInicio (primer arranque)"
# ─────────────────────────────────────────────────────────────────────────────
if [ ! -f "$RAIZDISTRO/$SCRIPT3" ]; then
    err "No se encontró $RAIZDISTRO/$SCRIPT3"
    exit 1
fi
chmod +x "$RAIZDISTRO/$SCRIPT3"

cat > /etc/systemd/system/3-SetupPrimerInicio.service << EOF
[Unit]
Description=IAC-IESMHP Configuracion primer arranque
DefaultDependencies=no
Wants=network-online.target
After=network-online.target graphical.target
Conflicts=shutdown.target

[Service]
Type=oneshot
Environment=LC_ALL=es_ES.UTF-8
ExecStart=/bin/bash $RAIZDISTRO/$SCRIPT3
StandardOutput=append:$RAIZLOG/$SCRIPT3.log
StandardError=append:$RAIZLOG/$SCRIPT3.log
TimeoutSec=0
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl enable 3-SetupPrimerInicio.service
ok "Servicio 3-SetupPrimerInicio habilitado"
info "ExecStart=/bin/bash $RAIZDISTRO/$SCRIPT3"
info "Log primer arranque: $RAIZLOG/$SCRIPT3.log"

# ─────────────────────────────────────────────────────────────────────────────
paso "Comprobaciones finales (4-Comprobaciones.sh)"
# ─────────────────────────────────────────────────────────────────────────────
SCRIPT4="$RAIZDISTRO/4-Comprobaciones.sh"
if [ -f "$SCRIPT4" ]; then
    chmod +x "$SCRIPT4"
    bash "$SCRIPT4" || true   # diagnóstico no bloquea el proceso
else
    info "4-Comprobaciones.sh no encontrado en $SCRIPT4 — omitiendo diagnóstico"
fi

paso "FIN — 2-SetupSOdesdeLiveCD.sh completado"
info "Log completo : $LOG2"
info "Resumen pasos: $STEPS"
echo ""
echo "Correcto"
