#!/bin/bash
# Lanza el rol AWScli: instala la consola de AWS (AWS CLI v2) para todo el
# sistema o la actualiza si hay una versión más nueva. Al final, una línea por
# equipo: versión que tenía → versión que tiene y qué se ha hecho.
#
# Uso:
#   bash AWScli.sh SMRD                    # toda el aula SMRD
#   bash AWScli.sh IABD -l IABD-05         # un equipo
#   bash AWScli.sh IABD -l 'all:!IABD-00'  # todos menos el del profesor
#   bash AWScli.sh SMRD --check            # solo dice qué haría (no instala nada)
#   bash AWScli.sh SMRD IABD               # varias aulas (una tras otra)
#   bash AWScli.sh <equipos.ini> [args de ansible-playbook]
#   sudo bash AWScli.sh                    # en local (este equipo)
#
# Opciones:
#   SMRD | IABD | <equipos.ini>   inventario(s) de aula (ansible_user=root). Sin él: en local
#   -l PATRÓN          equipos como en ansible (SMRD-05, 'SMRD-0*', 'all:!SMRD-00')
#   --forks N          equipos a la vez (20 por defecto; cada uno descarga ~60 MB)
#   --check            no cambia nada: muestra instalada, última y la acción
#   --dias N           el timer comprueba como mucho cada N días (7)
#   --sin-autoactualiza  quita el timer de actualización automática
#   --conservar-versiones  no borra las versiones antiguas de /usr/local/aws-cli/v2
#   --sin-autocompletado   no instala /etc/bash_completion.d/aws-cli
#   -h | --help | --ayuda
#   El resto de opciones que empiecen por - van a ansible-playbook (-v, -e...).
#
# Sin preguntas (headless). Salida completa de Ansible en
# /var/log/IAC-IESMHP/AWScli.log (o ~/.local/state/IAC-IESMHP/AWScli.log si no
# se puede escribir allí). Código de salida 1 si algún equipo da ERROR.
set -o pipefail
T0=$(date +%s)

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INVDIR="$(cd "$DIR/../.." && pwd)"          # Ubuntu/ansible/ (inventarios de aula)

INVENTARIOS=(); ARGS=(); LIMITE=""; RESUMEN_OPC=""
FORKS="${FORKS:-20}"

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help|--ayuda|-\?) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
        SMRD|smrd)        INVENTARIOS+=("$INVDIR/equiposSMRD.ini") ;;
        IABD|iabd)        INVENTARIOS+=("$INVDIR/equiposIABD.ini") ;;
        -l|--limit)       LIMITE="$2"; shift ;;
        --limit=*)        LIMITE="${1#--limit=}" ;;
        -l?*)             LIMITE="${1#-l}" ;;
        --forks)          FORKS="$2"; shift ;;
        --forks=*)        FORKS="${1#*=}" ;;
        --check|-C)       ARGS+=(--check); RESUMEN_OPC+=" check" ;;
        --dias)
            [[ "$2" =~ ^[1-9][0-9]*$ ]] || { echo "[ERR] --dias necesita un número: '$2'" >&2; exit 1; }
            ARGS+=(-e "awscli_autoactualiza_dias=$2"); RESUMEN_OPC+=" dias=$2"; shift ;;
        --sin-autoactualiza)    ARGS+=(-e awscli_autoactualiza=false); RESUMEN_OPC+=" sin-autoactualiza" ;;
        --conservar-versiones)  ARGS+=(-e awscli_borra_versiones_viejas=false); RESUMEN_OPC+=" conservar-versiones" ;;
        --sin-autocompletado)   ARGS+=(-e awscli_autocompletado=false); RESUMEN_OPC+=" sin-autocompletado" ;;
        -*)               ARGS+=("$1") ;;
        *)
            if [ "${#ARGS[@]}" -eq 0 ] && [ -f "$1" ]; then
                INVENTARIOS+=("$(realpath "$1")")
            elif [ "${#ARGS[@]}" -eq 0 ]; then
                echo "[ERR] No existe el inventario $1" >&2; exit 1
            else
                ARGS+=("$1")
            fi ;;
    esac
    shift
done

[[ "$FORKS" =~ ^[1-9][0-9]*$ ]] || { echo "[ERR] --forks no válido: '$FORKS'" >&2; exit 1; }
command -v ansible-playbook >/dev/null 2>&1 || { echo "[ERR] ansible-playbook no está instalado." >&2; exit 1; }

if [ "${#INVENTARIOS[@]}" -eq 0 ] && [ "$(id -u)" -ne 0 ] && [[ " ${ARGS[*]} " != *"ansible_become=false"* ]]; then
    echo "[ERR] En local hay que lanzarlo como root: sudo bash $0 $*" >&2; exit 1
fi

LOGDIR=/var/log/IAC-IESMHP
{ mkdir -p "$LOGDIR" && touch "$LOGDIR/AWScli.log"; } 2>/dev/null \
    || LOGDIR="$HOME/.local/state/IAC-IESMHP"
mkdir -p "$LOGDIR"
LOG="$LOGDIR/AWScli.log"
cd "$DIR" || exit 1

SAL=$(mktemp); trap 'rm -f "$SAL"' EXIT
mmss() { printf '%d:%02d' $(( $1 / 60 )) $(( $1 % 60 )); }

# Una línea por equipo a partir de la salida de Ansible: los mensajes
# «Mostrar estado» y «Resultado» del rol y el PLAY RECAP (fallos / sin SSH).
resumen() {   # resumen <salida>  → imprime líneas y devuelve 1 si hay ERROR
    python3 - "$1" <<'PY'
import re, sys
txt = open(sys.argv[1], encoding='utf-8', errors='replace').read()
estado, ahora, fallo = {}, {}, {}
for eq, ins, ult, acc in re.findall(
        r'ok: \[([^\]]+)\] => \{\s*"msg": "AWS CLI instalado: (.*?) \| última: (.*?) \| acción: (\w+)"', txt):
    estado[eq] = (ins, ult, acc)
for eq, v in re.findall(r'ok: \[([^\]]+)\] => \{\s*"msg": "AWS CLI ahora: ([0-9.]*)', txt):
    ahora[eq] = v
for eq, msg in re.findall(r'fatal: \[([^\]]+)\]: (?:FAILED|UNREACHABLE)! => (.*)', txt):
    m = re.search(r'"msg": "((?:[^"\\]|\\.)*)"', msg)
    fallo.setdefault(eq, (m.group(1) if m else msg)[:120])
recap = dict(re.findall(r'^(\S+)\s+: (ok=.*)$', txt, re.M))
hay_error, cuenta = False, {}
for eq in sorted(set(recap) | set(estado)):
    r = recap.get(eq, '')
    sin_ssh = re.search(r'unreachable=[1-9]', r)
    fallido = re.search(r'failed=[1-9]', r)
    ins, ult, acc = estado.get(eq, ('?', '?', '?'))
    if sin_ssh:
        linea, tipo = 'ERROR  no responde por SSH', 'ERROR'
    elif fallido:
        linea, tipo = 'ERROR  ' + fallo.get(eq, 'falló una tarea (ver log)'), 'ERROR'
    elif acc == 'ninguna':
        linea, tipo = 'OK     %s (ya es la última)' % ins, 'al día'
    elif eq in ahora:
        linea = 'OK     %s → %s (%s)' % (ins, ahora[eq], 'instalado' if acc == 'instalar' else 'actualizado')
        tipo = 'instalado' if acc == 'instalar' else 'actualizado'
    elif acc in ('instalar', 'actualizar'):
        linea, tipo = 'CHECK  %s → %s (haría: %s)' % (ins, ult, acc), 'haría ' + acc
    else:
        linea, tipo = 'OK     (sin datos del rol, ver log)', 'sin datos'
    hay_error |= tipo == 'ERROR'
    cuenta[tipo] = cuenta.get(tipo, 0) + 1
    print('    %-22s %s' % (eq, linea))
if not cuenta:
    print('    (ningún equipo)')
else:
    print('  Equipos: ' + ', '.join('%s %d' % (k, n) for k, n in sorted(cuenta.items())))
sys.exit(1 if hay_error else 0)
PY
}

: > "$SAL"
RC=0
if [ "${#INVENTARIOS[@]}" -eq 0 ]; then INVENTARIOS=(""); fi
for INVENTARIO in "${INVENTARIOS[@]}"; do
    if [ -n "$INVENTARIO" ]; then
        INV=(-i "$INVENTARIO")
        if [ -n "$LIMITE" ]; then
            ansible "${INV[@]}" --list-hosts -l "$LIMITE" all 2>/dev/null | grep -q 'hosts ([1-9]' \
                || { echo "[AVISO] El -l '$LIMITE' no coincide con ningún equipo de $INVENTARIO; se salta." | tee -a "$LOG"; continue; }
        fi
    else
        INV=(-i localhost, --connection=local)
    fi
    LIM=(); [ -n "$LIMITE" ] && LIM=(-l "$LIMITE")
    echo "===== $(date '+%F %T') AWScli ($(o="${RESUMEN_OPC# }"; echo "${o:-instalar/actualizar}")) ${INV[*]} --forks $FORKS ${LIM[*]} ${ARGS[*]}" | tee -a "$LOG"
    ANSIBLE_NOCOLOR=1 ansible-playbook "${INV[@]}" --forks "$FORKS" AWScli.yaml "${LIM[@]}" "${ARGS[@]}" \
        </dev/null >> "$SAL" 2>&1
    R=$?
    [ $R -ne 0 ] && RC=1
done
cat "$SAL" >> "$LOG"

RES="$(resumen "$SAL")" || RC=1     # fuera del { } | tee: allí RC no saldría
{
    echo ""
    echo "===== Resultado por equipo"
    echo "$RES"
    echo "  Tiempo total: $(mmss $(( $(date +%s) - T0 )))"
    echo "===== fin (código $RC). Salida completa de Ansible: $LOG"
} | tee -a "$LOG"
exit $RC
