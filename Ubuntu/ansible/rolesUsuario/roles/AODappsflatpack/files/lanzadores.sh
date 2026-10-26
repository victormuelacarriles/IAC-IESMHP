#!/usr/bin/env bash
#
# lanzadores.sh — parte de "menú" del rol AODappsflatpack (como el USUARIO).
# Generaliza los apartados B5 de "Ubuntu/flatpack/Instalación de aplicaciones
# Flatpak en Ubuntu 26.04.md" e instalaLibreOffice.sh a varias aplicaciones.
#
# Uso:
#   bash lanzadores.sh --ocultar  'ID|patrón1,patrón2|documentos(0/1)' ...
#   bash lanzadores.sh --deshacer 'ID|patrón1,patrón2|documentos(0/1)' ...
#   (ej.: 'org.libreoffice.LibreOffice|libreoffice*.desktop|1')
#
# --ocultar, para cada aplicación:
#   1. Copia cada lanzador del sistema (.deb: /usr/share/applications, snap:
#      /var/lib/snapd/desktop/applications) que case con los patrones a
#      ~/.local/share/applications con NoDisplay=true (justo debajo de
#      [Desktop Entry]) y la marca X-IAC-IESMHP-Oculta=true. Solo en el perfil
#      del usuario; el sistema no se toca.
#      Si el lanzador del sistema se llama IGUAL que uno del Flatpak
#      (org.shotcut.Shotcut.desktop...) NO se copia: el del Flatpak ya tiene
#      prioridad (XDG_DATA_DIRS) y ocultarlo ocultaría también el Flatpak.
#   2. documentos=1 y hay versión del sistema: asocia los MimeType de los lanzadores del Flatpak con
#      xdg-mime (~/.config/mimeapps.list).
#   3. Favoritos del dock (org.gnome.shell favorite-apps): cambia los
#      lanzadores ocultos por los del Flatpak (libreoffice-writer.desktop →
#      org.libreoffice.LibreOffice.writer.desktop). Solo si hay bus de sesión
#      del usuario; si no, avisa y sigue. La lista original se guarda una vez
#      en ~/.local/state/IAC-IESMHP/AODappsflatpack-favoritos.orig.
#   4. Borra copias ocultas cuyo original ya no existe.
# --deshacer: borra las copias con la marca, quita las asociaciones al
#   Flatpak y devuelve los favoritos guardados.
#
# Sin preguntas. Log: ~/.local/state/IAC-IESMHP/AODappsflatpack.log
# Salida: líneas [OK]/[WARN] y al final "RESUMEN|ocultos=N|asociados=N|mime=igual/cambiado|favoritos=cambiados/no/sin_bus".
set -u
exec </dev/null

MARCA="X-IAC-IESMHP-Oculta=true"
DIRS_NATIVO=(/usr/share/applications /var/lib/snapd/desktop/applications)
[ -n "${AODAPPS_DIRS_NATIVO:-}" ] && read -r -a DIRS_NATIVO <<<"$AODAPPS_DIRS_NATIVO"   # pruebas
DIRS_FLATPAK=("$HOME/.local/share/flatpak/exports/share/applications"
              /var/lib/flatpak/exports/share/applications)
DIR_USUARIO="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
CONF="${XDG_CONFIG_HOME:-$HOME/.config}"
ESTADO="${XDG_STATE_HOME:-$HOME/.local/state}/IAC-IESMHP"
FAV_ORIG="$ESTADO/AODappsflatpack-favoritos.orig"
mkdir -p "$ESTADO" "$DIR_USUARIO"
exec > >(tee -a "$ESTADO/AODappsflatpack.log") 2>&1

# Por SSH no se carga /etc/profile.d/flatpak.sh: sin esto xdg-mime/gio no
# verían los lanzadores del Flatpak.
export XDG_DATA_DIRS="$HOME/.local/share/flatpak/exports/share:/var/lib/flatpak/exports/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"

log() { echo "[$(date '+%F %T')] $*"; }

MODO="${1:-}"; shift || true
case "$MODO" in --ocultar|--deshacer) ;; *) echo "Uso: $0 --ocultar|--deshacer 'ID|patrones|doc' ..." >&2; exit 1 ;; esac
log "==== lanzadores.sh $MODO — $(id -un) en $(hostname) ===="

OCULTOS=0; ASOCIADOS=0; FAVORITOS=no
declare -A CAMBIO_FAV=()      # lanzador del sistema → lanzador del Flatpak

# Lanzador exportado por el Flatpak con ese nombre (o vacío).
lanzador_flatpak() {
    local d
    for d in "${DIRS_FLATPAK[@]}"; do
        [ -f "$d/$1" ] && { echo "$d/$1"; return; }
    done
}

# Lanzadores del sistema que casan con los patrones (separados por comas).
nativos() {
    local d p
    for d in "${DIRS_NATIVO[@]}"; do
        [ -d "$d" ] || continue
        for p in ${1//,/ }; do
            find "$d" -maxdepth 1 -name "$p" 2>/dev/null
        done
    done | sort -u
}

es_copia_oculta() { grep -qx "$MARCA" "$1" 2>/dev/null; }

oculta() {   # oculta <ID> <patrones>
    local id="$1" f nombre destino mod equiv n=0
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        nombre=$(basename "$f")
        if [ -n "$(lanzador_flatpak "$nombre")" ]; then
            log "[OK] $nombre: mismo nombre que el del Flatpak, ya lo tapa (no se toca)."
            continue
        fi
        destino="$DIR_USUARIO/$nombre"
        if [ -e "$destino" ] && ! es_copia_oculta "$destino"; then
            if grep -qx 'NoDisplay=true' "$destino"; then
                log "[OK] $nombre ya estaba oculto."
            else
                log "[WARN] $destino es una personalización del usuario; no se toca."
            fi
            continue
        fi
        # NoDisplay justo debajo de [Desktop Entry]: al final caería en las
        # secciones de acciones y no tendría efecto.
        sed -e '/^NoDisplay=/d' -e "/^${MARCA}\$/d" \
            -e "0,/^\[Desktop Entry\]/s//&\nNoDisplay=true\n${MARCA}/" \
            "$f" > "$destino.nuevo"
        if cmp -s "$destino.nuevo" "$destino"; then
            rm -f "$destino.nuevo"            # ya estaba igual: no cuenta como cambio
        else
            mv -f "$destino.nuevo" "$destino"
            n=$((n + 1))
        fi
        # Equivalente en el Flatpak para los favoritos: libreoffice-writer →
        # <ID>.writer si existe; si no, <ID>.
        mod="${nombre%.desktop}"; mod="${mod##*-}"
        equiv="$id.$mod.desktop"
        [ -n "$(lanzador_flatpak "$equiv")" ] || equiv="$id.desktop"
        CAMBIO_FAV["$nombre"]="$equiv"
    done < <(nativos "$2")
    OCULTOS=$((OCULTOS + n))
    log "[OK] $id: $n lanzadores del sistema ocultos."
}

asocia() {   # asocia <ID>
    local id="$1" d f mimes
    command -v xdg-mime >/dev/null 2>&1 || { log "[WARN] Falta xdg-mime: no se asocian documentos a $id."; return; }
    mkdir -p "$CONF"
    for d in "${DIRS_FLATPAK[@]}"; do
        for f in "$d/$id".*.desktop "$d/$id.desktop"; do
            [ -f "$f" ] || continue
            mimes=$(sed -n 's/^MimeType=//p' "$f" | tr ';' ' ')
            [ -n "${mimes// /}" ] || continue
            # shellcheck disable=SC2086  # una palabra por tipo MIME
            if xdg-mime default "$(basename "$f")" $mimes; then
                ASOCIADOS=$((ASOCIADOS + 1))
                log "[OK] Documentos de $(basename "$f")"
            else
                log "[WARN] xdg-mime falló con $(basename "$f")"
            fi
        done
        [ "$ASOCIADOS" -gt 0 ] && break      # el Flatpak de usuario manda
    done
}

desasocia() {   # desasocia <ID>
    local f="$CONF/mimeapps.list"
    [ -f "$f" ] || return 0
    local antes; antes=$(wc -l <"$f")
    sed -i "/^[^=]*=$(sed 's/\./\\./g' <<<"$1")[.a-z]*\.desktop;\{0,1\}\$/d" "$f"
    log "[OK] $1: $(( antes - $(wc -l <"$f") )) asociaciones de documentos quitadas."
}

limpia_huerfanas() {
    local f nombre d existe n=0
    for f in "$DIR_USUARIO"/*.desktop; do
        [ -f "$f" ] && es_copia_oculta "$f" || continue
        nombre=$(basename "$f"); existe=0
        for d in "${DIRS_NATIVO[@]}"; do [ -f "$d/$nombre" ] && existe=1 && break; done
        [ "$existe" -eq 0 ] && { rm -f "$f"; n=$((n + 1)); }
    done
    [ "$n" -gt 0 ] && log "[OK] Borradas $n copias ocultas que ya no hacían falta."
    return 0
}

# gsettings necesita el bus de sesión del usuario (pam_systemd lo crea al
# entrar por SSH; con lingering también existe).
hay_bus() {
    command -v gsettings >/dev/null 2>&1 || return 1
    # gsettings LEE del $HOME pero ESCRIBE por el bus en el HOME real: con
    # otro HOME (pruebas) se machacarían los favoritos reales.
    [ "$HOME" = "$(getent passwd "$(id -un)" | cut -d: -f6)" ] || return 1
    if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ -S "/run/user/$(id -u)/bus" ]; then
        export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus"
    fi
    [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ] && gsettings get org.gnome.shell favorite-apps >/dev/null 2>&1
}

favoritos_ocultar() {
    [ "${#CAMBIO_FAV[@]}" -gt 0 ] || return 0
    hay_bus || { FAVORITOS=sin_bus; log "[WARN] Sin bus de sesión: no se cambian los favoritos del dock."; return 0; }
    local actual nuevo k
    actual=$(gsettings get org.gnome.shell favorite-apps)
    nuevo="$actual"
    for k in "${!CAMBIO_FAV[@]}"; do
        if [[ "$nuevo" == *"'${CAMBIO_FAV[$k]}'"* ]]; then
            nuevo="${nuevo//"'$k', "/}"; nuevo="${nuevo//", '$k'"/}"; nuevo="${nuevo//"'$k'"/}"
        else
            nuevo="${nuevo//"'$k'"/"'${CAMBIO_FAV[$k]}'"}"
        fi
    done
    [ "$nuevo" = "$actual" ] && { log "[OK] Favoritos del dock: nada que cambiar."; return 0; }
    [ -f "$FAV_ORIG" ] || echo "$actual" > "$FAV_ORIG"
    if gsettings set org.gnome.shell favorite-apps "$nuevo"; then
        FAVORITOS=cambiados; log "[OK] Favoritos del dock: $nuevo"
    else
        log "[WARN] No se pudieron cambiar los favoritos del dock."
    fi
}

favoritos_deshacer() {
    [ -f "$FAV_ORIG" ] || return 0
    hay_bus || { FAVORITOS=sin_bus; log "[WARN] Sin bus de sesión: los favoritos guardados en $FAV_ORIG no se devuelven."; return 0; }
    if gsettings set org.gnome.shell favorite-apps "$(cat "$FAV_ORIG")"; then
        rm -f "$FAV_ORIG"; FAVORITOS=cambiados; log "[OK] Favoritos del dock devueltos."
    fi
}

MIME_ANTES=$(md5sum "$CONF/mimeapps.list" 2>/dev/null)
for spec in "$@"; do
    IFS='|' read -r ID PATRONES DOC <<<"$spec"
    [ -n "$ID" ] || continue
    if [ "$MODO" = --ocultar ]; then
        oculta "$ID" "$PATRONES"
        # Documentos: solo si hay versión del sistema que se los quite.
        if [ "$DOC" = 1 ] && [ -n "$(nativos "$PATRONES")" ]; then asocia "$ID"; fi
    else
        n=0
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            g="$DIR_USUARIO/$(basename "$f")"
            es_copia_oculta "$g" && { rm -f "$g"; n=$((n + 1)); }
        done < <(nativos "$PATRONES")
        OCULTOS=$((OCULTOS + n))
        log "[OK] $ID: $n lanzadores del sistema vuelven a verse."
        [ "$DOC" = 1 ] && desasocia "$ID"
    fi
done

if [ "$MODO" = --ocultar ]; then favoritos_ocultar; limpia_huerfanas; else favoritos_deshacer; fi
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$DIR_USUARIO" 2>/dev/null
[ "$MIME_ANTES" = "$(md5sum "$CONF/mimeapps.list" 2>/dev/null)" ] && MIME=igual || MIME=cambiado
echo "RESUMEN|ocultos=$OCULTOS|asociados=$ASOCIADOS|mime=$MIME|favoritos=$FAVORITOS"
exit 0
