#!/bin/bash
# =============================================================================
#  Reclona-IAC-IESMHP.sh — Borra /opt/IAC-IESMHP y lo vuelve a clonar desde GitHub.
#
#  Uso:
#    sudo bash Reclona-IAC-IESMHP.sh                         # en el equipo local
#    bash Reclona-IAC-IESMHP.sh <inventario.ini> [args ansible...]   # en remoto
#
#  Ejemplos:
#    sudo bash Reclona-IAC-IESMHP.sh
#    bash Reclona-IAC-IESMHP.sh /opt/IAC-IESMHP/Ubuntu/ansible/equiposIABD.ini
#    bash Reclona-IAC-IESMHP.sh /opt/IAC-IESMHP/Ubuntu/ansible/equiposIABD.ini -l IABD-05
#
#  Modo local:
#    - Clona el repo en una carpeta temporal y, solo si el clon sale bien,
#      borra /opt/IAC-IESMHP y pone el nuevo en su sitio. Si falla la red,
#      el equipo no se queda sin repo.
#    - Si el equipo NO se llama "controlubuntu", deja solo la carpeta del SO
#      actual (Ubuntu o Mint) más los ficheros de la raíz (macs.csv,
#      Autorizados.txt...). Usa `git sparse-checkout`, así que `git pull`
#      sigue funcionando y no aparecen como borrados en `git status`.
#    - Log en /var/log/IAC-IESMHP/Reclona-IAC-IESMHP.log.
#
#  Modo inventario:
#    - Copia el inventario y este script a un temporal (el original puede estar
#      dentro de /opt/IAC-IESMHP, que se va a borrar), lanza este mismo script
#      en cada equipo con el módulo `script` de Ansible (como root, según el
#      inventario) y borra el temporal al acabar, también si falla.
#    - Cada equipo decide por su propio nombre si se queda con todo o solo con
#      su SO.
#
#  Sin preguntas: apto para ejecutar sin monitor ni teclado.
# =============================================================================
set -euo pipefail

GITHUB_USER="victormuelacarriles"
REPO="IAC-IESMHP"
GITREPO="https://github.com/${GITHUB_USER}/${REPO}.git"
DESTDIR="/opt/${REPO}"
EQUIPO_CONTROL="controlubuntu"     # este equipo conserva el repo completo
FORKS="${FORKS:-10}"               # equipos en paralelo en modo inventario
LOGDIR="/var/log/${REPO}"
LOG="${LOGDIR}/Reclona-IAC-IESMHP.log"

log()  { echo "[$(date '+%F %T')] [INFO] $*"; }
warn() { echo "[$(date '+%F %T')] [WARN] $*" >&2; }
err()  { echo "[$(date '+%F %T')] [ERR ] $*" >&2; }

# ─────────────── Modo inventario (Ansible) ───────────────
modo_inventario() {
    local inv="$1"; shift
    [[ -f "$inv" ]] || { err "No existe el inventario: $inv"; exit 1; }
    command -v ansible >/dev/null || { err "ansible no está instalado"; exit 1; }

    TMPDIR_INV="$(mktemp -d /tmp/Reclona-IAC-IESMHP.XXXXXX)"
    local tmp="$TMPDIR_INV"
    trap 'rm -rf "$TMPDIR_INV"' EXIT

    cp "$inv" "$tmp/inventario.ini"
    cp "$(readlink -f "${BASH_SOURCE[0]}")" "$tmp/Reclona-IAC-IESMHP.sh"
    log "Inventario copiado a $tmp/inventario.ini"

    # Por si el inventario está dentro de /opt/IAC-IESMHP y el propio equipo de
    # control aparece en él: que no nos quedemos en un directorio borrado.
    cd /

    local rc=0
    ANSIBLE_HOST_KEY_CHECKING=False \
        ansible all -i "$tmp/inventario.ini" -f "$FORKS" \
        -m ansible.builtin.script -a "$tmp/Reclona-IAC-IESMHP.sh" "$@" </dev/null || rc=$?

    if [[ $rc -eq 0 ]]; then
        log "Terminado en todos los equipos."
    else
        warn "Ansible terminó con código $rc (algún equipo falló o no respondió)."
    fi
    exit "$rc"   # el trap borra el temporal
}

# ─────────────── Modo local ───────────────
carpeta_so() {
    local id=""
    id="$(. /etc/os-release 2>/dev/null && echo "${ID:-}")" || true
    case "$id" in
        ubuntu)    echo "Ubuntu" ;;
        linuxmint) echo "Mint" ;;
        *)         echo "" ;;
    esac
}

modo_local() {
    [[ $EUID -eq 0 ]] || { err "Hay que ejecutarlo como root (sudo)."; exit 1; }

    mkdir -p "$LOGDIR"
    exec > >(tee -a "$LOG") 2>&1

    local equipo
    equipo="$(hostname -s | tr '[:upper:]' '[:lower:]')"
    log "=== Reclona-IAC-IESMHP en $equipo ==="

    command -v git >/dev/null || {
        log "Instalando git..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y git </dev/null
    }

    # El repo viejo puede contener este script o el directorio actual.
    cd /

    local nuevo="${DESTDIR}.nuevo"
    rm -rf "$nuevo"
    log "Clonando $GITREPO en $nuevo ..."
    if ! GIT_TERMINAL_PROMPT=0 git clone "$GITREPO" "$nuevo" </dev/null; then
        rm -rf "$nuevo"
        err "Falló el clon. No se ha tocado $DESTDIR."
        exit 1
    fi

    if [[ "$equipo" == "$EQUIPO_CONTROL" ]]; then
        log "Equipo de control: se conserva el repo completo."
    else
        local so
        so="$(carpeta_so)"
        if [[ -z "$so" || ! -d "$nuevo/$so" ]]; then
            warn "SO no reconocido (/etc/os-release). Se conserva el repo completo."
        else
            log "Dejando solo la carpeta $so (más los ficheros de la raíz)..."
            if ! git -C "$nuevo" sparse-checkout set "$so" </dev/null; then
                # git muy antiguo sin sparse-checkout: borrado a mano.
                warn "sparse-checkout no disponible; se borran las carpetas a mano."
                local d
                for d in Mint ThinStation Ubuntu W11; do
                    [[ "$d" == "$so" ]] || rm -rf "${nuevo:?}/$d"
                done
            fi
        fi
    fi

    # Se vacía el CONTENIDO de $DESTDIR y se mete dentro el clon nuevo, sin
    # borrar el directorio en sí: una terminal que estuviera dentro de
    # /opt/IAC-IESMHP sigue viendo el repo (si se borrara el directorio, vería
    # uno vacío y "borrado" hasta hacer cd de nuevo).
    log "Vaciando $DESTDIR y colocando el clon nuevo..."
    mkdir -p "$DESTDIR"
    find "${DESTDIR:?}" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    find "$nuevo" -mindepth 1 -maxdepth 1 -exec mv -t "$DESTDIR" {} +
    rmdir "$nuevo"

    log "Contenido de $DESTDIR: $(ls "$DESTDIR" | tr '\n' ' ')"
    log "Último commit: $(git -C "$DESTDIR" log -1 --oneline 2>/dev/null || echo '?')"
    log "=== Terminado ==="
}

# ─────────────── Principal ───────────────
if [[ $# -ge 1 ]]; then
    modo_inventario "$@"
else
    modo_local
fi
