#!/usr/bin/env bash
#
# preparaFlatpackEnUsuario.sh
# -------------------------------------------------------------------
# Deja Flathub listo para el USUARIO actual (se ejecuta SIN sudo).
# Automatiza el apartado B1 de
#   "Instalación de aplicaciones Flatpak en Ubuntu 26.04.md".
#
# Qué hace:
#   1. Comprueba que el comando `flatpak` existe. Si no, avisa y sale:
#      instalarlo necesita sudo (apartado A1 / rol Ansible `flatpak`).
#   2. Si el remoto `flathub` de usuario no existe, lo añade.
#   3. Comprueba que funciona descargando el appstream.
#      Si falla (p. ej. "GPG verification enabled, but no summary found"),
#      borra el remoto, lo vuelve a crear y repite la prueba.
#   4. Si sigue fallando, prueba a llegar a dl.flathub.org con curl para
#      distinguir un problema de red/proxy del centro.
#   5. Si Flathub funciona, RECOMIENDA las aplicaciones del array
#      APPS_RECOMENDADAS que el usuario aún no tiene, con el comando para
#      instalarlas. No instala nada.
#
# Idempotente: relanzarlo no rompe nada. No hace preguntas.
# Log: ~/.local/state/IAC-IESMHP/preparaFlatpackEnUsuario.log
#
# Uso:
#   bash preparaFlatpackEnUsuario.sh
#
# Códigos de salida: 0 = Flathub listo, 1 = falta flatpak / se lanzó como
# root, 2 = Flathub no responde.
# -------------------------------------------------------------------
set -u
exec </dev/null

REMOTO="flathub"
URL_REPO="https://dl.flathub.org/repo/flathub.flatpakrepo"
URL_PRUEBA="https://dl.flathub.org/repo/summary.idx"

# Aplicaciones Flatpak recomendadas (ID de Flathub). Añade o quita líneas.
APPS_RECOMENDADAS=(
    org.libreoffice.LibreOffice   # LibreOffice
    org.shotcut.Shotcut           # Shotcut
    com.microsoft.Edge            # Microsoft Edge
    com.obsproject.Studio         # OBS Studio
)

LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/IAC-IESMHP"
LOG="$LOG_DIR/preparaFlatpackEnUsuario.log"
mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG") 2>&1

log() { echo "[$(date '+%F %T')] $*"; }

log "==== preparaFlatpackEnUsuario.sh — usuario $(id -un) en $(hostname) ===="

# ---- No ejecutar como root -----------------------------------------
if [ "$(id -u)" -eq 0 ]; then
    log "[ERR] Ejecútalo como el USUARIO, no como root: el remoto es --user."
    exit 1
fi

# ---- 1. ¿Está instalado flatpak? -----------------------------------
if ! command -v flatpak >/dev/null 2>&1; then
    log "[ERR] flatpak no está instalado. Un administrador debe ejecutar:"
    log "      sudo apt install flatpak   (o el rol Ansible 'flatpak')"
    exit 1
fi
log "[OK] $(flatpak --version)"

# ---- Funciones ------------------------------------------------------
existe_remoto() {
    flatpak remotes --user --columns=name 2>/dev/null | grep -qx "$REMOTO"
}

anade_remoto() {
    log "Añadiendo el remoto '$REMOTO' de usuario..."
    flatpak remote-add --user --if-not-exists "$REMOTO" "$URL_REPO"
}

prueba_remoto() {
    log "Descargando appstream de '$REMOTO' para comprobarlo..."
    flatpak update --user --appstream --noninteractive "$REMOTO"
}

# Muestra las apps recomendadas que faltan y cómo instalarlas.
recomienda_apps() {
    local app faltan=()
    for app in "${APPS_RECOMENDADAS[@]}"; do
        if flatpak info "$app" >/dev/null 2>&1; then
            log "[OK]   $app ya instalada."
        else
            log "[RECO] $app no está instalada."
            faltan+=("$app")
        fi
    done
    if [ "${#faltan[@]}" -eq 0 ]; then
        log "[OK] Tienes todas las aplicaciones recomendadas."
    else
        log "Para instalar las que faltan:"
        log "      flatpak install --user -y $REMOTO ${faltan[*]}"
    fi
}

# ---- 2. Añadir el remoto si falta -----------------------------------
if existe_remoto; then
    log "[OK] El remoto '$REMOTO' de usuario ya existe."
else
    anade_remoto || log "[WARN] remote-add ha fallado; se reintentará."
fi

# ---- 3. Comprobar y, si falla, recrear ------------------------------
if existe_remoto && prueba_remoto; then
    log "[OK] Flathub está disponible para $(id -un)."
    recomienda_apps
    exit 0
fi

log "[WARN] Flathub no responde bien. Se recrea el remoto."
flatpak remote-delete --user --force "$REMOTO" 2>/dev/null || true
if anade_remoto && prueba_remoto; then
    log "[OK] Remoto recreado. Flathub está disponible para $(id -un)."
    recomienda_apps
    exit 0
fi

# ---- 4. Diagnóstico de red ------------------------------------------
log "[ERR] Flathub sigue sin funcionar. Probando la red..."
if command -v curl >/dev/null 2>&1; then
    if curl -sSI --max-time 15 "$URL_PRUEBA" | head -n 1; then
        log "      Hay respuesta del servidor: revisa el mensaje de flatpak de arriba."
    else
        log "      No se llega a dl.flathub.org: problema de red o proxy del centro."
        log "      Proxy actual: https_proxy='${https_proxy:-${HTTPS_PROXY:-}}'"
    fi
fi
exit 2
