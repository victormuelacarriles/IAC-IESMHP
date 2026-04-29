#!/usr/bin/env bash
# =============================================================================
#  0b-Github.sh
#  Script de personalización embebido en la ISO.
#  Se ejecuta como early-command desde el entorno live de Ubuntu.
#  Clona el repositorio IAC-IESMHP y lanza 1-SetupLiveCD.sh.
# =============================================================================
set -euo pipefail

REPO="IAC-IESMHP"
GITREPO="https://github.com/victormuelacarriles/${REPO}.git"
DESTDIR="/opt/${REPO}"
SCRIPT_INSTALL="${DESTDIR}/Ubuntu/ISO/26.04/1-SetupLiveCD.sh"

#export DISPLAY=:0
#export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/999/bus
#zenity --info --text="Configurando..." --timeout=3 || true
# Authorization required, but no authorization protocol specified

# ─────────────── Colores ───────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[perso][+]${NC} $*"; }
warn() { echo -e "${YELLOW}[perso][!]${NC} $*"; }
err()  { echo -e "${RED}[perso][✗]${NC} $*" >&2; exit 1; }
log "=== 0b-Github.sh iniciado: $(date) ==="

# ─────────────── Red: esperar DHCP ─────
log "Comprobando conectividad..."
for i in $(seq 1 12); do
    if ping -c1 -W2 github.com &>/dev/null; then
        log "Red disponible."
        break
    fi
    warn "Sin red, reintento ${i}/12..."
    sleep 5
done
ping -c1 -W2 github.com &>/dev/null || err "No hay conexión a Internet. Abortando."

# ─────────────── git ───────────────────
log "Asegurando que git está instalado..."
rm -f /var/lib/man-db/auto-update

# update-initramfs tarda 2-4 min reconstruyendo el initramfs del kernel.
# En un live CD no sirve para nada; lo sustituimos por un no-op antes de
# llamar a apt para que dpkg no lo ejecute al procesar los triggers pendientes.
mkdir -p /usr/local/sbin
ln -sf /bin/true /usr/local/sbin/update-initramfs
export PATH="/usr/local/sbin:$PATH"
log "update-initramfs enmascarado (no-op en entorno live)."

DEBIAN_FRONTEND=noninteractive apt-get update -qq
# --force-unsafe-io: evita fsync sobre overlayfs (más rápido y sin bloqueos)
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    -o "Dpkg::Options::=--force-unsafe-io" \
    --no-install-recommends git
log "git instalado."


# ─────────────── Clonar repo ───────────
if [[ -d "${DESTDIR}/.git" ]]; then
    warn "El repositorio ya existe en ${DESTDIR}. Actualizando..."
    git -C "${DESTDIR}" pull --ff-only
else
    log "Clonando ${GITREPO} → ${DESTDIR} ..."
    git clone "${GITREPO}" "${DESTDIR}"
fi

# ─────────────── Verificar script ──────
[[ -f "${SCRIPT_INSTALL}" ]] \
    || err "No se encontró el script de instalación: ${SCRIPT_INSTALL}"

chmod +x "${SCRIPT_INSTALL}"

# ─────────────── Lanzar instalación ────


log "Ejecutando ${SCRIPT_INSTALL} ..."
bash "${SCRIPT_INSTALL}"