#!/bin/bash
# =============================================================================
#  Reclona-IAC-IESMHP.sh — Borra /opt/IAC-IESMHP y lo vuelve a clonar desde GitHub.
#
#  Uso:
#    sudo ./Reclona-IAC-IESMHP.sh                         # en el equipo local
#    ./Reclona-IAC-IESMHP.sh <inventario.ini> [args ansible...]   # en remoto
#    ./Reclona-IAC-IESMHP.sh --help | -? | --ayuda      # ayuda
#
#  Ejemplos:
#    sudo ./Reclona-IAC-IESMHP.sh
#    ./Reclona-IAC-IESMHP.sh /opt/IAC-IESMHP/Ubuntu/ansible/equiposIABD.ini
#    ./Reclona-IAC-IESMHP.sh /opt/IAC-IESMHP/Ubuntu/ansible/equiposIABD.ini -l IABD-05
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

    # Por si el inventario está dentro de /opt/IAC-IESMHP y el propio equipo de
    # control aparece en él: que no nos quedemos en un directorio borrado.
    cd /

    # Salida completa de Ansible a un log; en pantalla solo OK/ERROR por equipo.
    local detalle="${LOGDIR}/Reclona-IAC-IESMHP-inventario.log"
    mkdir -p "$LOGDIR" 2>/dev/null && touch "$detalle" 2>/dev/null \
        || detalle="${HOME}/Reclona-IAC-IESMHP-inventario.log"

    # Equipos a los que se va a lanzar (respeta -l y demás argumentos extra).
    ansible all -i "$tmp/inventario.ini" "$@" --list-hosts 2>/dev/null \
        | tail -n +2 | awk 'NF{print $1}' > "$tmp/equipos.txt" || true
    log "Lanzando en $(wc -l < "$tmp/equipos.txt") equipos (detalle en $detalle)..."

    # El callback 'tree' deja un JSON por equipo en $tmp/arbol/<equipo>.
    ANSIBLE_HOST_KEY_CHECKING=False \
        ansible all -i "$tmp/inventario.ini" -f "$FORKS" -t "$tmp/arbol" \
        -m ansible.builtin.script -a "$tmp/Reclona-IAC-IESMHP.sh" "$@" \
        </dev/null >"$detalle" 2>&1 || true

    local rc=0
    python3 -I - "$tmp/equipos.txt" "$tmp/arbol" <<'PYEOF' || rc=$?
import json, os, sys
equipos = [l.strip() for l in open(sys.argv[1]) if l.strip()]
arbol = sys.argv[2]
ok = mal = 0
for eq in sorted(equipos):
    f = os.path.join(arbol, eq)
    try:
        r = json.load(open(f))
    except Exception:
        r = None
    if r is None:
        estado, motivo = "ERROR", "sin resultado"
    elif r.get("unreachable"):
        estado, motivo = "ERROR", "no responde por SSH"
    elif r.get("failed") or r.get("rc", 0) != 0:
        lineas = (r.get("stderr_lines") or []) + (r.get("stdout_lines") or [])
        lineas = [l for l in lineas if "[ERR" in l] or lineas or [r.get("msg", "")]
        estado, motivo = "ERROR", f"rc={r.get('rc', '?')}: {lineas[-1].strip()}"
    else:
        estado, motivo = "OK", ""
    if estado == "OK":
        ok += 1
    else:
        mal += 1
    print(f"{eq:<16} {estado}" + (f"  ({motivo})" if motivo else ""))
print(f"--- OK: {ok}   ERROR: {mal}")
sys.exit(1 if mal else 0)
PYEOF

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

# ─────────────── Ayuda ───────────────
ayuda() {
    local yo
    yo="$(basename "$0")"
    cat <<EOF
$yo — Borra ${DESTDIR} y lo vuelve a clonar desde GitHub
(${GITREPO}).

USO
  sudo $yo                          En este equipo.
  $yo <inventario.ini> [args]       En todos los equipos del inventario (Ansible).
  $yo --help | -? | --ayuda         Muestra esta ayuda.

QUÉ HACE EN CADA EQUIPO
  1. Clona el repo en ${DESTDIR}.nuevo. Si falla (red, GitHub...), no toca nada.
  2. Si el equipo NO se llama "${EQUIPO_CONTROL}", deja solo la carpeta de su
     sistema (Ubuntu o Mint, según /etc/os-release) y los ficheros de la raíz,
     con git sparse-checkout. En "${EQUIPO_CONTROL}" queda el repo completo.
  3. Vacía ${DESTDIR} y mete dentro el clon nuevo.
  Log: ${LOG}

PARÁMETROS
  (ninguno)         Modo local. Requiere root.
  <inventario.ini>  Modo remoto: copia el inventario y este script a /tmp, los
                    lanza con Ansible (módulo script) y borra el temporal.
                    Muestra una línea OK/ERROR por equipo y un total.
                    Detalle: ${LOGDIR}/Reclona-IAC-IESMHP-inventario.log
  [args]            Lo que vaya tras el inventario se pasa a ansible
                    (p. ej. -l SMRD-05 para un solo equipo, -v...).

VARIABLES DE ENTORNO
  FORKS=<n>         Equipos en paralelo en modo remoto (por defecto ${FORKS}).

EJEMPLOS
  sudo $yo
  .$yo /opt/IAC-IESMHP/Ubuntu/ansible/equiposSMRD.ini
  .$yo /opt/IAC-IESMHP/Ubuntu/ansible/equiposIABD.ini -l IABD-05
  FORKS=20 .$yo /opt/IAC-IESMHP/Ubuntu/ansible/equiposIABD.ini

Para recuperar el repo completo en un equipo recortado:
  git -C ${DESTDIR} sparse-checkout disable
EOF
}

# ─────────────── Principal ───────────────
case "${1:-}" in
    --help|'-?'|--ayuda|-h) ayuda; exit 0 ;;
esac

if [[ $# -ge 1 ]]; then
    modo_inventario "$@"
else
    modo_local
fi
