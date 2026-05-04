#!/bin/bash
set -e
VERSIONSCRIPT="22.15-20260504"
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
paso "Idioma, teclado y zona horaria"
# ─────────────────────────────────────────────────────────────────────────────
sed -i 's/# es_ES.UTF-8/es_ES.UTF-8/g' /etc/locale.gen
locale-gen es_ES.UTF-8

printf 'LANG=es_ES.UTF-8\nLC_ALL=es_ES.UTF-8\nLANGUAGE=es_ES\n' > /etc/default/locale

printf 'XKBLAYOUT=es\nXKBMODEL=pc105\nXKBVARIANT=\nXKBOPTIONS=\n' > /etc/default/keyboard

mkdir -p /etc/dconf/db/local.d
cat > /etc/dconf/db/local.d/00-language << 'LANGEOF'
[org/gnome/desktop/input-sources]
sources=[('xkb', 'es')]

[org/gnome/system/locale]
region='es_ES.UTF-8'
LANGEOF
ok "Idioma y teclado configurados"

ln -sf /usr/share/zoneinfo/Europe/Madrid /etc/localtime
echo "Europe/Madrid" > /etc/timezone
dpkg-reconfigure -f noninteractive tzdata 2>/dev/null || true
ok "Zona horaria configurada: Europe/Madrid ($(date '+%Z %z'))"

# ─────────────────────────────────────────────────────────────────────────────
paso "Fondo de escritorio (todos los usuarios)"
# ─────────────────────────────────────────────────────────────────────────────
# Estrategia de dos capas para cubrir todos los casos:
#
#  1. GSettings schema override  → establece el DEFAULT de GSettings compilado
#     en disco. No requiere D-Bus. Se aplica a todos los usuarios que no tengan
#     un valor en su user-db (es decir, cualquier usuario recién creado).
#
#  2. dconf system-db:local      → override de sistema en tiempo de ejecución.
#     Tiene prioridad sobre el schema default pero requiere que dconf update
#     compile el fichero binario. En chroot puede fallar; si falla, la capa 1
#     garantiza el fondo correcto igualmente.

# ── Capa 1: GSettings schema override ──────────────────────────────────────
mkdir -p /usr/share/glib-2.0/schemas
cat > /usr/share/glib-2.0/schemas/99-iac-iesmhp-wallpaper.gschema.override << 'GSEOF'
[org.gnome.desktop.background]
picture-uri='file:///usr/share/backgrounds/iac-iesmhp.png'
picture-uri-dark='file:///usr/share/backgrounds/iac-iesmhp.png'
picture-options='zoom'
GSEOF
glib-compile-schemas /usr/share/glib-2.0/schemas/ \
    && ok "GSettings schema de fondo compilado (fondo predeterminado para todos los usuarios)" \
    || info "glib-compile-schemas falló en chroot — se recompilará en el primer arranque"

# Borrar el user-db de skel si contiene un fondo distinto al nuestro,
# para que nuevos usuarios partan del schema default (nuestro fondo).
_SKEL_DCONF=/etc/skel/.config/dconf/user
if [ -f "$_SKEL_DCONF" ]; then
    rm -f "$_SKEL_DCONF"
    ok "Eliminado $_SKEL_DCONF (evita que nuevos usuarios hereden el fondo estándar de Ubuntu)"
fi

# ── Capa 2: dconf system-db:local ──────────────────────────────────────────
mkdir -p /etc/dconf/profile
[ -f /etc/dconf/profile/user ] || printf 'user-db:user\nsystem-db:local\n' > /etc/dconf/profile/user

mkdir -p /etc/dconf/db/local.d
cat > /etc/dconf/db/local.d/01-wallpaper << 'WALLEOF'
[org/gnome/desktop/background]
picture-uri='file:///usr/share/backgrounds/iac-iesmhp.png'
picture-uri-dark='file:///usr/share/backgrounds/iac-iesmhp.png'
picture-options='zoom'
WALLEOF

# Pantalla de inicio de sesión GDM: logotipo del IES
_GDM_WM="$RAIZDISTRO/imagenesIES/watermark.png"
if [ -f "$_GDM_WM" ]; then
    cp "$_GDM_WM" /usr/share/backgrounds/iac-iesmhp-watermark.png
    cat > /etc/dconf/profile/gdm << 'GDMPROF'
user-db:user
system-db:gdm
GDMPROF
    mkdir -p /etc/dconf/db/gdm.d
    cat > /etc/dconf/db/gdm.d/00-login-screen << 'GDMEOF'
[org/gnome/login-screen]
logo='/usr/share/backgrounds/iac-iesmhp-watermark.png'
GDMEOF
    ok "Logo GDM configurado: /usr/share/backgrounds/iac-iesmhp-watermark.png"
else
    info "watermark.png no encontrado en $RAIZDISTRO/imagenesIES/ — logo GDM omitido"
fi

dconf update && ok "dconf actualizado (system-db compilado)" \
    || info "dconf update falló en chroot — el schema override (capa 1) garantiza el fondo igualmente"

# ─────────────────────────────────────────────────────────────────────────────
paso "Eliminar autostart del Live CD del sistema instalado"
# ─────────────────────────────────────────────────────────────────────────────
# iac-iesmhp-setup.desktop se embebe en el squashfs para arrancar el script de
# instalación durante el Live CD. El rsync lo copia al sistema instalado, por
# lo que sin este paso GNOME lo ejecutaría en cada login del sistema ya instalado.
# Se elimina de skel (antes de crear el usuario 'usuario') y del home de ubuntu.
for _autostart_file in \
    /etc/skel/.config/autostart/iac-iesmhp-setup.desktop \
    /home/ubuntu/.config/autostart/iac-iesmhp-setup.desktop
do
    if [ -f "$_autostart_file" ]; then
        rm -f "$_autostart_file"
        ok "Eliminado: $_autostart_file"
    else
        info "No presente: $_autostart_file"
    fi
done

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
if id usuario &>/dev/null; then
    info "Usuario 'usuario' ya existe"
else
    useradd -m -s /bin/bash -p '*' usuario
    ok "Usuario 'usuario' creado"
fi
adduser usuario sudo 2>/dev/null || usermod -aG sudo usuario
ok "Usuario 'usuario' en grupo sudo"

# Ubuntu 26.04: chpasswd usa PAM con pam_pwquality (mínimo 8 chars).
# Escribir hash SHA-512 directamente en /etc/shadow para evitar pam_pwquality.
# IMPORTANTE: 'usuario' debe existir en /etc/shadow antes de este bloque.
# Por eso useradd está ANTES de aquí (movido de su posición original).
python3 - << 'PYEOF'
import subprocess, re, sys
for user, pw in [('root', 'root'), ('usuario', 'usuario')]:
    h = subprocess.check_output(['openssl', 'passwd', '-6', pw], text=True).strip()
    with open('/etc/shadow', 'r') as f:
        content = f.read()
    updated = re.sub(r'^(' + re.escape(user) + r'):[^:]*:',
                     r'\g<1>:' + h.replace('\\', '\\\\') + ':',
                     content, flags=re.MULTILINE)
    if updated == content:
        print(f'[ERR] {user} no encontrado en /etc/shadow', flush=True)
        sys.exit(1)
    else:
        with open('/etc/shadow', 'w') as f:
            f.write(updated)
        with open('/etc/shadow', 'r') as f:
            check = f.read()
        found = re.search(r'^' + re.escape(user) + r':(\$[^:]+):', check, re.MULTILINE)
        if found:
            print(f'[OK ] {user}: hash {found.group(1)[:8]}... escrito en shadow', flush=True)
        else:
            print(f'[ERR] {user}: hash NO quedó en shadow', flush=True)
            sys.exit(1)
PYEOF
ok "Contraseñas root y usuario establecidas en /etc/shadow"

# Diagnóstico: verificar /etc/nologin (bloquea login de TODOS los usuarios normales)
if [ -f /etc/nologin ]; then
    err "/etc/nologin existe — bloqueará logins! Eliminando..."
    rm -f /etc/nologin
else
    ok "Sin /etc/nologin (correcto)"
fi

if [ -f /root/.ssh/authorized_keys ]; then
    mkdir -p /home/usuario/.ssh
    cp /root/.ssh/authorized_keys /home/usuario/.ssh/
    chown usuario:usuario /home/usuario/.ssh/authorized_keys
    chmod 600 /home/usuario/.ssh/authorized_keys
    ok "authorized_keys copiado a /home/usuario/.ssh/"
fi

# ─────────────────────────────────────────────────────────────────────────────
paso "Eliminar usuario ubuntu (Live CD) y deshabilitar auto-login GDM"
# ─────────────────────────────────────────────────────────────────────────────
# El Live CD configura GDM con AutomaticLogin=ubuntu. El rsync copia esa config
# al sistema instalado → arranque sin pantalla de login → sesión como 'ubuntu',
# cuya cuenta puede estar bloqueada en el sistema instalado (PAM la rechaza →
# "cuenta no disponible" en el terminal). El dconf personal de 'ubuntu' también
# sobreescribe el fondo personalizado del IES.
if id ubuntu &>/dev/null; then
    userdel -r ubuntu 2>/dev/null || userdel ubuntu 2>/dev/null || true
    rm -rf /home/ubuntu 2>/dev/null || true
    ok "Usuario 'ubuntu' del Live CD eliminado"
else
    info "Usuario 'ubuntu' no presente"
fi

# AccountsService: GDM lee AccountsService con MAYOR PRIORIDAD que /etc/gdm3/custom.conf.
# El Live CD crea /var/lib/AccountsService/users/ubuntu con AutomaticLogin=true.
# El rsync lo copia al sistema instalado. Tot y que custom.conf diga AutomaticLoginEnable=False,
# GDM intenta auto-loguear 'ubuntu' via AccountsService. Como 'ubuntu' no existe en /etc/passwd,
# GDM queda en la sesión greeter (visible como "GDM Greeter").
ACCTS_DIR=/var/lib/AccountsService/users
info "Contenido de $ACCTS_DIR/ (diagnóstico):"
ls -la "$ACCTS_DIR/" 2>/dev/null | while read -r l; do info "  $l"; done || info "  (directorio no existe)"
if [ -f "$ACCTS_DIR/ubuntu" ]; then
    info "Contenido de $ACCTS_DIR/ubuntu:"
    cat "$ACCTS_DIR/ubuntu" | while read -r l; do info "  $l"; done
    rm -f "$ACCTS_DIR/ubuntu"
    ok "AccountsService: auto-login de ubuntu eliminado"
fi
# Registrar 'usuario' en AccountsService para que GDM lo muestre en el selector
mkdir -p "$ACCTS_DIR"
cat > "$ACCTS_DIR/usuario" << 'ACCTEOF'
[User]
Language=es_ES.UTF-8
XSession=ubuntu
SystemAccount=false
ACCTEOF
ok "AccountsService: usuario 'usuario' registrado"

GDM_CONF=/etc/gdm3/custom.conf
mkdir -p /etc/gdm3

# Diagnóstico: mostrar TODO lo que hay en /etc/gdm3/ para identificar fuentes de auto-login.
info "── Diagnóstico /etc/gdm3/ ──"
find /etc/gdm3 -type f 2>/dev/null | sort | while read -r f; do
    info "Fichero: $f"
    while IFS= read -r l; do info "  $l"; done < "$f"
done || info "  (directorio /etc/gdm3 vacío o no existe)"

# Diagnóstico: PAM gdm — auto-login bypasea contraseña via pam_gdm_autologin
info "── Diagnóstico PAM gdm* ──"
ls /etc/pam.d/gdm* 2>/dev/null | while read -r f; do
    info "Fichero PAM: $f"
    while IFS= read -r l; do info "  $l"; done < "$f"
done || info "  (no hay ficheros pam.d/gdm*)"

# Diagnóstico: debconf values de gdm3 (postinst puede regenerar custom.conf con estos valores)
info "── Diagnóstico debconf gdm3 ──"
debconf-show gdm3 2>/dev/null | while read -r l; do info "  $l"; done || info "  (debconf-show gdm3 falló)"

# Pre-configurar debconf para que el postinst de gdm3 no regenere auto-login.
# dpkg --configure -a (en 3-SetupPrimerInicio.sh) puede ejecutar el postinst de gdm3,
# el cual lee debconf para regenerar custom.conf con AutomaticLoginEnable.
echo "gdm3 gdm3/daemon_section/AutomaticLoginEnable boolean false" | debconf-set-selections 2>/dev/null || true
echo "gdm3 gdm3/daemon_section/AutomaticLogin string " | debconf-set-selections 2>/dev/null || true
info "debconf gdm3 pre-configurado (auto-login=false)"

# Eliminar cualquier fichero drop-in del Live CD que pueda re-habilitar el auto-login.
# Ubuntu 26.04 puede usar /etc/gdm3/custom.conf.d/ para sus overrides de live session.
if [ -d /etc/gdm3/custom.conf.d ]; then
    info "Contenido de /etc/gdm3/custom.conf.d/ antes de limpiar:"
    ls -la /etc/gdm3/custom.conf.d/ | while read -r l; do info "  $l"; done
    rm -rf /etc/gdm3/custom.conf.d
    ok "Directorio /etc/gdm3/custom.conf.d eliminado (evita overrides de auto-login del Live CD)"
fi

cat > "$GDM_CONF" << 'GDMEOF'
[daemon]
AutomaticLoginEnable=false
TimedLoginEnable=false
InitialSetupEnable=false
WaylandEnable=true

[security]

[xdmcp]

[chooser]

[debug]
GDMEOF
ok "GDM config sobrescrita (auto-login e initial-setup deshabilitados, Wayland habilitado)"
info "Contenido final de $GDM_CONF:"
while IFS= read -r l; do info "  $l"; done < "$GDM_CONF"

# gnome-initial-setup se lanza en el primer arranque si no existe este flag.
# GDM lo detecta y muestra el asistente de bienvenida EN VEZ de la pantalla de login,
# resultando en "acceder directamente al escritorio" + "cuenta no disponible" al abrir terminal.
# Rutas antiguas (gnome-initial-setup < 46, Ubuntu <= 24.04)
mkdir -p /var/lib/gdm3/.config
touch /var/lib/gdm3/.config/gnome-initial-setup-done
mkdir -p /etc/skel/.config
touch /etc/skel/.config/gnome-initial-setup-done
# Rutas nuevas (gnome-initial-setup >= 46, Ubuntu 26.04+)
mkdir -p /var/lib/gdm3/.local/share
touch /var/lib/gdm3/.local/share/gnome-initial-setup-done
mkdir -p /etc/skel/.local/share
touch /etc/skel/.local/share/gnome-initial-setup-done
if [ -d /home/usuario ]; then
    mkdir -p /home/usuario/.config /home/usuario/.local/share
    touch /home/usuario/.config/gnome-initial-setup-done
    touch /home/usuario/.local/share/gnome-initial-setup-done
    chown -R usuario:usuario /home/usuario/.config /home/usuario/.local
fi
ok "gnome-initial-setup marcado como completado (rutas antiguas y nuevas)"

# Deshabilitar el bloqueo de pantalla en la sesión del GDM greeter.
# GDM en Ubuntu 26.04 corre el greeter como sesión Wayland del usuario 'gdm'.
# Si el screensaver lo bloquea, aparece "GDM Greeter" en la pantalla de bloqueo
# y el usuario no puede desbloquearlo (no conoce la contraseña del usuario 'gdm').
mkdir -p /etc/dconf/db/gdm.d
cat >> /etc/dconf/db/gdm.d/00-login-screen << 'GDMLOCKEOF'

[org/gnome/desktop/session]
idle-delay=uint32 0

[org/gnome/desktop/screensaver]
lock-enabled=false
lock-delay=uint32 3600
GDMLOCKEOF
ok "Screensaver del GDM greeter deshabilitado (evita pantalla de bloqueo de 'GDM Greeter')"
dconf update && ok "dconf recompilado (gdm screensaver settings incluidos)" \
    || info "dconf update falló en chroot — las bases GDM se compilarán en el primer arranque"

# ── Servicio early-boot: escribe GDM config ANTES de que display-manager arranque ─────
# Garantía final contra auto-login: aunque algo sobreescriba /etc/gdm3/custom.conf
# (casper.service, postinst de gdm3 durante full-upgrade, etc.), este servicio
# se ejecuta en CADA arranque Before=display-manager.service y lo corrige.
# 3-SetupPrimerInicio tiene After=graphical.target → llega tarde; este servicio
# llega a tiempo.
cat > /usr/local/sbin/iac-gdm-noautologin.sh << 'GDMEARLYSCRIPT'
#!/bin/bash
mkdir -p /etc/gdm3
cat > /etc/gdm3/custom.conf << 'GDM3EARLY'
[daemon]
AutomaticLoginEnable=false
TimedLoginEnable=false
InitialSetupEnable=false
WaylandEnable=true

[security]

[xdmcp]

[chooser]

[debug]
GDM3EARLY
GDMEARLYSCRIPT
chmod +x /usr/local/sbin/iac-gdm-noautologin.sh

cat > /etc/systemd/system/iac-gdm-noautologin.service << 'GDMEARLYUNIT'
[Unit]
Description=IAC: enforce GDM sin auto-login antes de display-manager
DefaultDependencies=no
Before=display-manager.service
After=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/iac-gdm-noautologin.sh

[Install]
WantedBy=display-manager.service
GDMEARLYUNIT
systemctl enable iac-gdm-noautologin.service
ok "Servicio iac-gdm-noautologin habilitado (Before=display-manager en cada arranque)"

# Soporte Wayland en VMware: mutter (compositor GNOME) necesita EGL/DRM para Wayland.
# En VMware sin aceleración 3D habilitada, mutter falla al iniciarse → GDM vuelve al
# login sin mensaje de error. LIBGL_ALWAYS_SOFTWARE=1 fuerza llvmpipe (software renderer
# de Mesa) y permite que Wayland funcione sin GPU virtual. Solo se aplica si el chroot
# detecta entorno VMware; las máquinas físicas no entran en este bloque.
_VIRT_CHR=$(systemd-detect-virt 2>/dev/null || true)
info "Entorno de virtualización detectado en chroot: ${_VIRT_CHR:-ninguno}"
if echo "$_VIRT_CHR" | grep -qi "vmware"; then
    grep -q 'LIBGL_ALWAYS_SOFTWARE' /etc/environment 2>/dev/null \
        || echo 'LIBGL_ALWAYS_SOFTWARE=1' >> /etc/environment
    ok "VMware: LIBGL_ALWAYS_SOFTWARE=1 → /etc/environment (Wayland funciona sin GPU 3D)"
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

# Mostrar el menú 5 s antes de arrancar la entrada por defecto
sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=5/'           /etc/default/grub
grep -q '^GRUB_TIMEOUT='       /etc/default/grub || echo 'GRUB_TIMEOUT=5'          >> /etc/default/grub
sed -i 's/^GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=menu/' /etc/default/grub
grep -q '^GRUB_TIMEOUT_STYLE=' /etc/default/grub || echo 'GRUB_TIMEOUT_STYLE=menu' >> /etc/default/grub
ok "GRUB: timeout=5 s y menú visible"

# Ocultar submenu "Advanced options" y entradas "Memory test"
sed -i '/^GRUB_DISABLE_SUBMENU=/d' /etc/default/grub
echo 'GRUB_DISABLE_SUBMENU=y' >> /etc/default/grub
for _memtest in /etc/grub.d/20_memtest86+ /etc/grub.d/30_memtest86+; do
    [ -f "$_memtest" ] && chmod -x "$_memtest" && info "Deshabilitado: $_memtest"
done
ok "GRUB: Advanced options y Memory test deshabilitados (quedan: Ubuntu, texto, UEFI)"

# Segunda entrada GRUB: arrancar sin entorno gráfico (systemd.unit=multi-user.target).
# El script /etc/grub.d/11_iac_texto se ejecuta en cada update-grub, por lo que
# la entrada sobrevive a actualizaciones de paquetes que regeneren grub.cfg.
cat > /etc/grub.d/11_iac_texto << 'GRUBTEXT'
#!/bin/bash
# IAC-IESMHP: entrada GRUB sin entorno grafico
LINUX=$(ls /boot/vmlinuz-* 2>/dev/null | grep -v '\.old$' | sort -V | tail -1)
INITRD=$(ls /boot/initrd.img-* 2>/dev/null | grep -v '\.old$' | sort -V | tail -1)
[ -z "$LINUX" ] && exit 0
[ -z "$INITRD" ] && exit 0
LINUX_BASE="${LINUX#/boot/}"
INITRD_BASE="${INITRD#/boot/}"
ROOT_UUID=$(awk '$2 == "/" && $1 ~ /^UUID=/ { sub(/^UUID=/, "", $1); print $1; exit }' /etc/fstab 2>/dev/null)
[ -z "$ROOT_UUID" ] && ROOT_UUID=$(grub-probe -t fs_uuid / 2>/dev/null || true)
[ -z "$ROOT_UUID" ] && exit 0
cat << EOF
menuentry 'Ubuntu - Sin entorno grafico (modo texto)' --class ubuntu --class gnu-linux --class gnu --class os {
    search --no-floppy --fs-uuid --set=root ${ROOT_UUID}
    linux   /boot/${LINUX_BASE} root=UUID=${ROOT_UUID} ro text systemd.unit=multi-user.target
    initrd  /boot/${INITRD_BASE}
}
EOF
GRUBTEXT
chmod +x /etc/grub.d/11_iac_texto
ok "Script /etc/grub.d/11_iac_texto creado (segunda entrada: sin entorno grafico)"

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
paso "Plymouth: logos personalizados IES Miguel Herrero"
# ─────────────────────────────────────────────────────────────────────────────
# Los ficheros de tema Plymouth se embeben en el initramfs por update-initramfs.
# Se copian ANTES de ese paso para que la imagen instalada use los logos del IES.
_PLY_BGRT="$RAIZDISTRO/imagenesIES/bgrt-fallback.png"
_PLY_WM="$RAIZDISTRO/imagenesIES/watermark.png"
_PLY_COPIED=0
for _ply_dir in /usr/share/plymouth/themes/spinner /usr/share/plymouth/themes/bgrt; do
    if [ -d "$_ply_dir" ] && [ -f "$_PLY_BGRT" ]; then
        cp "$_PLY_BGRT" "$_ply_dir/bgrt-fallback.png"
        ok "bgrt-fallback.png → $_ply_dir/"
        _PLY_COPIED=$((_PLY_COPIED + 1))
    fi
done
if [ -d /usr/share/plymouth/themes/spinner ] && [ -f "$_PLY_WM" ]; then
    cp "$_PLY_WM" /usr/share/plymouth/themes/spinner/watermark.png
    ok "watermark.png → /usr/share/plymouth/themes/spinner/"
    _PLY_COPIED=$((_PLY_COPIED + 1))
fi
[ "$_PLY_COPIED" -gt 0 ] && ok "Logos Plymouth copiados ($_PLY_COPIED fichero/s)" \
                          || info "Ningún directorio de tema Plymouth encontrado — se omite"

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

# Enmascarar casper.service en systemd: en Ubuntu 26.04 casper puede tener un
# servicio de userspace que modifica /etc/gdm3/custom.conf antes del primer login.
ln -sf /dev/null /etc/systemd/system/casper.service 2>/dev/null || true
info "casper.service enmascarado en systemd (symlink → /dev/null)"

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
