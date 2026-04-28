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
SCRIPT_INSTALL="${DESTDIR}/Ubuntu/26.04/1-SetupLiveCD.sh"
LOG_DIR="/var/log/${REPO}"
LOG_FILE="${LOG_DIR}/0b-Github.sh.log"

# ─────────────── Colores ───────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[perso][+]${NC} $*"; }
warn() { echo -e "${YELLOW}[perso][!]${NC} $*"; }
err()  { echo -e "${RED}[perso][✗]${NC} $*" >&2; exit 1; }

# ─────────────── Log ───────────────────
mkdir -p "${LOG_DIR}"
exec > >(tee -a "${LOG_FILE}") 2>&1
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
apt-get update -qq
apt-get install -y -qq git

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