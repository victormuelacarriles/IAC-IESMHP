#!/usr/bin/env bash
# =============================================================================
#  perso.sh — Script de personalización post-instalación
# =============================================================================

set -euo pipefail

# ── Colores ───────────────────────────────────────────────────────────────────
log()  { echo "[perso] $*"; }
warn() { echo "[perso][WARN] $*" >&2; }
err()  { echo "[perso][ERR]  $*" >&2; exit 1; }

log "========================================"
log "  Inicio de personalización (perso.sh)  "
log "========================================"

# ─────────────────────────────────────────────────────────────────────────────
# 1. VARIABLES DE CONFIGURACIÓN
# ─────────────────────────────────────────────────────────────────────────────
EXTRA_USER="operador"
EXTRA_USER_PASS="Cambiar123!"
HOSTNAME_NUEVO="mi-servidor"

# ─────────────────────────────────────────────────────────────────────────────
# 2. ACTUALIZACIÓN E INSTALACIÓN DE PAQUETES
# ─────────────────────────────────────────────────────────────────────────────
log "Actualizando listas de paquetes..."
# Añadimos || true para que no aborte la instalación si la red tarda en conectar
apt-get update -qq || warn "Fallo al actualizar repositorios"

log "Actualizando paquetes instalados..."
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq || warn "Fallo al actualizar paquetes"

log "Instalando paquetes adicionales..."
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    curl \
    git \
    vim \
    htop \
    net-tools \
    unzip \
    openssh-server # <--- ¡Añadido para que la config de SSH funcione!

# ─────────────────────────────────────────────────────────────────────────────
# 3. USUARIO ADICIONAL
# ─────────────────────────────────────────────────────────────────────────────
if id "$EXTRA_USER" &>/dev/null; then
    log "El usuario ${EXTRA_USER} ya existe, omitiendo creación."
else
    log "Creando usuario: ${EXTRA_USER}"
    useradd -m -s /bin/bash -G sudo "${EXTRA_USER}"
    echo "${EXTRA_USER}:${EXTRA_USER_PASS}" | chpasswd
    chage -d 0 "${EXTRA_USER}"
    log "Usuario ${EXTRA_USER} creado."
fi

# ─────────────────────────────────────────────────────────────────────────────
# 4. CONFIGURACIÓN DE SSH (Protegido por if)
# ─────────────────────────────────────────────────────────────────────────────
log "Endureciendo configuración SSH..."
SSHD_CFG="/etc/ssh/sshd_config"

if [[ -f "$SSHD_CFG" ]]; then
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' "$SSHD_CFG"
else
    warn "No se encontró $SSHD_CFG, omitiendo endurecimiento."
fi

# ─────────────────────────────────────────────────────────────────────────────
# 5. HOSTNAME (Corrección chroot)
# ─────────────────────────────────────────────────────────────────────────────
log "Configurando hostname: ${HOSTNAME_NUEVO}"
# En vez de usar hostnamectl, escribimos el archivo directamente
echo "${HOSTNAME_NUEVO}" > /etc/hostname
echo "127.0.1.1  ${HOSTNAME_NUEVO}" >> /etc/hosts

# ─────────────────────────────────────────────────────────────────────────────
# 6. TIMEZONE (Corrección chroot)
# ─────────────────────────────────────────────────────────────────────────────
log "Configurando timezone..."
# En vez de usar timedatectl, enlazamos el binario local
ln -fs /usr/share/zoneinfo/Europe/Madrid /etc/localtime
DEBIAN_FRONTEND=noninteractive dpkg-reconfigure -f noninteractive tzdata

# ─────────────────────────────────────────────────────────────────────────────
# 7. FIREWALL (UFW) (Corrección chroot)
# ─────────────────────────────────────────────────────────────────────────────
log "Configurando firewall UFW..."
# En vez de usar --force enable (que requiere kernel), editamos la config
sed -i 's/ENABLED=no/ENABLED=yes/' /etc/ufw/ufw.conf
ufw default deny incoming || true
ufw default allow outgoing || true
ufw allow ssh || true

# ─────────────────────────────────────────────────────────────────────────────
# 8. LIMPIEZA
# ─────────────────────────────────────────────────────────────────────────────
log "Limpieza de paquetes..."
apt-get autoremove -y -qq || true
apt-get clean -qq

log "========================================"
log "  perso.sh completado sin errores       "
log "========================================"