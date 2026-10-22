#!/usr/bin/env bash
#
# instalaLibreOffice.sh
# -------------------------------------------------------------------
# Instala (o actualiza) la última versión de LibreOffice como Flatpak del
# USUARIO actual (sin sudo) y, si en el sistema hay otro LibreOffice
# (.deb o snap), lo oculta del menú y hace que los documentos se abran con
# el Flatpak. Automatiza los apartados B1, B2 y B5 de
#   "Instalación de aplicaciones Flatpak en Ubuntu 26.04.md".
#
# Qué hace:
#   1. Deja Flathub listo con preparaFlatpackEnUsuario.sh (misma carpeta).
#   2. Instala org.libreoffice.LibreOffice --user, o lo actualiza si ya está.
#      Si ya está como Flatpak de SISTEMA, usa ese (actualizarlo necesita sudo).
#   3. Si hay LibreOffice nativo (/usr/share/applications/libreoffice-*.desktop
#      o lanzadores snap):
#      a. Copia sus lanzadores a ~/.local/share/applications con
#         NoDisplay=true (justo debajo de [Desktop Entry]). Solo en el perfil
#         del usuario; no toca el sistema.
#      b. Asocia los tipos de documento (MimeType) a los lanzadores del
#         Flatpak con xdg-mime (~/.config/mimeapps.list).
#   4. Limpia las copias ocultas que ya no hacen falta (el nativo se
#      desinstaló): las que llevan la marca X-IAC-IESMHP-Oculta o
#      NoDisplay=true y cuyo original ya no existe.
#
# Idempotente: relanzarlo no rompe nada. No hace preguntas.
# Log: ~/.local/state/IAC-IESMHP/instalaLibreOffice.log
#
# Uso:
#   bash instalaLibreOffice.sh                    # instalar/actualizar + lanzadores
#   bash instalaLibreOffice.sh --solo-lanzadores  # solo el paso 3 y 4
#
# Para deshacer lo de los lanzadores:
#   rm ~/.local/share/applications/libreoffice*.desktop
#   update-desktop-database ~/.local/share/applications
#
# Códigos de salida: 0 = bien, 1 = root / falta flatpak, 2 = Flathub no
# disponible, 3 = falló la instalación.
# -------------------------------------------------------------------
set -u
exec </dev/null

APP="org.libreoffice.LibreOffice"
REMOTO="flathub"
MARCA="X-IAC-IESMHP-Oculta=true"
# Lanzadores del Flatpak a los que se asocian los documentos.
MODULOS=(writer calc impress draw math base)
# Dónde puede haber lanzadores del LibreOffice nativo.
DIRS_NATIVO=(/usr/share/applications /var/lib/snapd/desktop/applications)
# Dónde exporta Flatpak sus lanzadores (usuario primero).
DIRS_FLATPAK=("$HOME/.local/share/flatpak/exports/share/applications"
              /var/lib/flatpak/exports/share/applications)
DIR_USUARIO="${XDG_DATA_HOME:-$HOME/.local/share}/applications"

DIR_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/IAC-IESMHP"
LOG="$LOG_DIR/instalaLibreOffice.log"
mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG") 2>&1

log() { echo "[$(date '+%F %T')] $*"; }

SOLO_LANZADORES=0
[ "${1:-}" = "--solo-lanzadores" ] && SOLO_LANZADORES=1

log "==== instalaLibreOffice.sh — usuario $(id -un) en $(hostname) ===="

if [ "$(id -u)" -eq 0 ]; then
    log "[ERR] Ejecútalo como el USUARIO, no como root: el Flatpak es --user."
    exit 1
fi
if ! command -v flatpak >/dev/null 2>&1; then
    log "[ERR] flatpak no está instalado. Un administrador debe ejecutar:"
    log "      sudo apt install flatpak   (o el rol Ansible 'flatpak')"
    exit 1
fi

# ---- Funciones ------------------------------------------------------

# Lista los lanzadores del LibreOffice nativo (.deb o snap).
lanzadores_nativos() {
    local d
    for d in "${DIRS_NATIVO[@]}"; do
        [ -d "$d" ] || continue
        find "$d" -maxdepth 1 -name 'libreoffice*.desktop' 2>/dev/null
    done
}

# ¿La copia del usuario es nuestra (o una copia oculta) y se puede tocar?
es_copia_oculta() {
    grep -qx "$MARCA" "$1" 2>/dev/null || grep -qx 'NoDisplay=true' "$1" 2>/dev/null
}

# 3a. Oculta cada lanzador nativo en el perfil del usuario.
oculta_nativos() {
    local f destino n=0
    mkdir -p "$DIR_USUARIO"
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        destino="$DIR_USUARIO/$(basename "$f")"
        if [ -e "$destino" ] && ! es_copia_oculta "$destino"; then
            log "[WARN] $destino es una personalización del usuario; no se toca."
            continue
        fi
        # NoDisplay justo debajo de [Desktop Entry]: al final del fichero
        # caería en las secciones de acciones y no tendría efecto.
        sed -e '/^NoDisplay=/d' -e "/^${MARCA}\$/d" \
            -e "0,/^\[Desktop Entry\]/s//&\nNoDisplay=true\n${MARCA}/" \
            "$f" > "$destino"
        n=$((n + 1))
    done < <(lanzadores_nativos)
    log "[OK] $n lanzadores nativos ocultos en $DIR_USUARIO."
}

# 3b. Asocia los documentos a los lanzadores del Flatpak.
asocia_documentos() {
    local m d f mimes hecho
    if ! command -v xdg-mime >/dev/null 2>&1; then
        log "[WARN] Falta xdg-mime (xdg-utils): no se cambian las asociaciones."
        return
    fi
    # xdg-mime falla si no existe la carpeta de mimeapps.list (usuario nuevo).
    mkdir -p "${XDG_CONFIG_HOME:-$HOME/.config}"
    for m in "${MODULOS[@]}"; do
        hecho=0
        for d in "${DIRS_FLATPAK[@]}"; do
            f="$d/$APP.$m.desktop"
            [ -f "$f" ] || continue
            mimes=$(sed -n 's/^MimeType=//p' "$f" | tr ';' ' ')
            if [ -n "$mimes" ]; then
                # shellcheck disable=SC2086  # una palabra por tipo MIME
                xdg-mime default "$(basename "$f")" $mimes
                log "[OK] Documentos de $m → $(basename "$f")"
            fi
            hecho=1
            break
        done
        [ "$hecho" -eq 1 ] || log "[WARN] No se encuentra el lanzador Flatpak de $m."
    done
}

# 4. Borra copias ocultas cuyo original ya no existe.
limpia_huerfanas() {
    local f nombre d existe n=0
    for f in "$DIR_USUARIO"/libreoffice*.desktop; do
        [ -f "$f" ] || continue
        es_copia_oculta "$f" || continue
        nombre=$(basename "$f")
        existe=0
        for d in "${DIRS_NATIVO[@]}"; do
            [ -f "$d/$nombre" ] && existe=1 && break
        done
        if [ "$existe" -eq 0 ]; then
            rm -f "$f"
            n=$((n + 1))
        fi
    done
    [ "$n" -gt 0 ] && log "[OK] Borradas $n copias ocultas que ya no hacían falta."
    return 0
}

actualiza_bd_lanzadores() {
    if command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database "$DIR_USUARIO" 2>/dev/null || true
    fi
}

# ---- 1 y 2. Flathub + instalar/actualizar ---------------------------
if [ "$SOLO_LANZADORES" -eq 0 ]; then
    if ! bash "$DIR_SCRIPT/preparaFlatpackEnUsuario.sh"; then
        log "[ERR] Flathub no está disponible: no se puede instalar LibreOffice."
        exit 2
    fi

    if flatpak info --user "$APP" >/dev/null 2>&1; then
        log "LibreOffice Flatpak de usuario ya instalado; actualizando..."
        flatpak update --user -y --noninteractive "$APP" \
            || log "[WARN] La actualización ha fallado; se sigue con la versión instalada."
    elif flatpak info --system "$APP" >/dev/null 2>&1; then
        log "[OK] LibreOffice ya está como Flatpak de SISTEMA; se usa ese."
        log "     (para actualizarlo: sudo flatpak update $APP)"
    else
        log "Instalando LibreOffice Flatpak para $(id -un) (puede tardar)..."
        if ! flatpak install --user -y --noninteractive "$REMOTO" "$APP"; then
            log "[ERR] Falló 'flatpak install --user $REMOTO $APP'."
            exit 3
        fi
    fi
    log "[OK] LibreOffice Flatpak $(flatpak info "$APP" 2>/dev/null \
        | sed -n 's/^ *\(Versión\|Version\): *//p' | head -n1)"
fi

# ---- 3 y 4. Lanzadores y asociaciones -------------------------------
if [ -n "$(lanzadores_nativos)" ]; then
    log "Hay un LibreOffice nativo en el sistema: se oculta para este usuario."
    oculta_nativos
    asocia_documentos
else
    log "[OK] No hay LibreOffice nativo en el sistema: no hace falta ocultar nada."
fi
limpia_huerfanas
actualiza_bd_lanzadores

if command -v xdg-mime >/dev/null 2>&1; then
    log "Writer por defecto: $(xdg-mime query default application/vnd.oasis.opendocument.text)"
fi
log "[OK] Terminado. Cierra sesión y vuelve a entrar para ver el menú actualizado."
exit 0
