#!/bin/bash
# Lanza el rol AODappsflatpack: instala (o actualiza) como Flatpak DEL ALUMNO
# la última versión de LibreOffice, OBS Studio, Shotcut y OpenShot, y le
# oculta del menú las versiones instaladas por el sistema (.deb/snap).
# Ansible entra como cada alumno (inventario de alumnos): no se toca root.
#
# Uso:
#   bash AODappsflatpack.sh                       # en local, el usuario actual
#   bash AODappsflatpack.sh SMRD                  # todos los alumnos de SMRD
#   bash AODappsflatpack.sh SMRD AOD              # solo los del módulo AOD
#   bash AODappsflatpack.sh SMRD AOD -l SMRD-04-SMRV24     # de AOD, solo ese
#   bash AODappsflatpack.sh SMRD AOD --apps libreoffice,obs
#   bash AODappsflatpack.sh SMRD AOD --deshacer   # las quita y devuelve los lanzadores
#   bash AODappsflatpack.sh <alumnos.ini> [args de ansible-playbook]
#
# Opciones:
#   SMRD | IABD | <alumnos.ini>   inventario de alumnos (sin él: en local)
#   --modulo M   solo los alumnos del grupo M ([AOD], [SOR]...). Vale también
#                el nombre suelto tras el aula (SMRD AOD) y varios: AOD,SOR.
#                Con -l, se cogen los que cumplen las dos cosas.
#   -l PATRÓN    alumnos (nombres del inventario) como en ansible
#   --apps L     solo esas, separadas por comas: libreoffice, obs, shotcut,
#                openshot (por defecto, todas)
#   --forks N    alumnos a la vez, por tandas de N (POR DEFECTO 1: de uno en
#                uno; también FORKS=N). Cada alumno descarga sus aplicaciones
#                (~2-3 GB la primera vez): no subirlo mucho.
#   --sin-actualizar   las que ya tiene no se actualizan
#   --sin-ocultar      no oculta los lanzadores del sistema ni toca favoritos
#   --proxy URL        proxy para flatpak (http://10.0.32.119:3128). Por
#                      defecto directo (el HTTPS del aula no usa proxy).
#   --deshacer   desinstala esos Flatpak del alumno y vuelve a mostrar los
#                lanzadores del sistema (sus datos de ~/.var/app se quedan)
#   -h | --help | --ayuda
#   El resto de opciones que empiecen por - van a ansible-playbook (-v, -e...).
#
# Sin preguntas (headless). Salida en pantalla y en
# /var/log/IAC-IESMHP/AODappsflatpack.log (o ~/.local/state/IAC-IESMHP/),
# más un log por alumno en la carpeta AODappsflatpack/ de al lado:
#   AODappsflatpack-<alumno>.log
# Todos se van añadiendo, con una cabecera "=====" por ejecución. Al final,
# tabla de TIEMPOS por alumno y por aplicación.
set -o pipefail
T0=$(date +%s)
INICIO=$(date '+%d/%m %H:%M')

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INVDIR="$(cd "$DIR/../.." && pwd)"          # rolesUsuario/ (inventarios de alumnos)

ALUMNOS=""; ARGS=(); LIMITE=""; MODULOS=(); SUELTOS=(); APPS=""; DESHACER=0
FORKS="${FORKS:-1}"         # de uno en uno por defecto

# Nombres de aplicación válidos (los de defaults/main.yml).
VALIDAS=$(sed -n 's/^ *- nombre: *//p' "$DIR/defaults/main.yml" | tr '\n' ' ')

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help|--ayuda|-\?) sed -n '2,41p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        --deshacer)       DESHACER=1 ;;
        --sin-actualizar) ARGS+=(-e AODappsflatpack_actualizar=false) ;;
        --sin-ocultar)    ARGS+=(-e AODappsflatpack_ocultar=false) ;;
        --proxy)          ARGS+=(-e "AODappsflatpack_proxy=$2"); shift ;;
        --proxy=*)        ARGS+=(-e "AODappsflatpack_proxy=${1#*=}") ;;
        --apps)           APPS="$2"; shift ;;
        --apps=*)         APPS="${1#*=}" ;;
        --forks)          FORKS="$2"; shift ;;
        --forks=*)        FORKS="${1#*=}" ;;
        SMRD|smrd)        ALUMNOS="$INVDIR/EquiposSMRD-alumnos2627.ini" ;;
        IABD|iabd)        ALUMNOS="$INVDIR/equiposIABD-alumnos2627.ini" ;;
        --modulo|-m)      MODULOS+=("$2"); shift ;;
        --modulo=*)       MODULOS+=("${1#*=}") ;;
        -l|--limit)       LIMITE="$2"; shift ;;
        --limit=*)        LIMITE="${1#--limit=}" ;;
        -l?*)             LIMITE="${1#-l}" ;;
        -*)               ARGS+=("$1") ;;
        *)
            if [ -z "$ALUMNOS" ] && [ "${#ARGS[@]}" -eq 0 ] && [ -f "$1" ]; then
                ALUMNOS="$(realpath "$1")"
            elif [ -z "$ALUMNOS" ] && [ "${#ARGS[@]}" -eq 0 ]; then
                echo "[ERR] No existe el inventario $1" >&2; exit 1
            elif [ -n "$ALUMNOS" ] && [[ "$1" =~ ^[A-Za-z][A-Za-z0-9_,]*$ ]]; then
                SUELTOS+=("$1")       # posible módulo (SMRD AOD): se comprueba abajo
            else
                ARGS+=("$1")
            fi ;;
    esac
    shift
done

[[ "$FORKS" =~ ^[1-9][0-9]*$ ]] || { echo "[ERR] --forks no válido: '$FORKS'" >&2; exit 1; }

# --apps: comprobar los nombres.
if [ -n "$APPS" ]; then
    APPS="${APPS// /}"
    for a in ${APPS//,/ }; do
        [[ " $VALIDAS" == *" $a "* ]] || { echo "[ERR] Aplicación '$a' desconocida (hay: $VALIDAS)" >&2; exit 1; }
    done
    ARGS+=(-e "AODappsflatpack_elegidas=$APPS")
fi
[ "$DESHACER" = 1 ] && ARGS+=(-e AODappsflatpack_deshacer=true)

# Grupos del inventario de alumnos (para validar los módulos).
grupos_inventario() {
    ansible-inventory -i "$ALUMNOS" --list 2>/dev/null | python3 -c '
import json, sys
print(" ".join(g for g in json.load(sys.stdin) if g not in ("_meta", "all", "ungrouped")))'
}
# Nombres de equipo de un patrón de Ansible, separados por comas.
equipos() {
    ansible-inventory -i "$ALUMNOS" --list --limit "$1" 2>/dev/null | python3 -c '
import json, sys
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
print(",".join(sorted(d.get("_meta", {}).get("hostvars", {}))))'
}

if [ "${#MODULOS[@]}" -gt 0 ] || [ "${#SUELTOS[@]}" -gt 0 ]; then
    [ -n "$ALUMNOS" ] || { echo "[ERR] --modulo necesita un inventario de alumnos (SMRD, IABD o <alumnos.ini>)" >&2; exit 1; }
    GRUPOS=" $(grupos_inventario) "
    PATRON=""
    for m in "${MODULOS[@]}" "${SUELTOS[@]}"; do
        for g in ${m//,/ }; do
            [[ "$GRUPOS" == *" $g "* ]] || { echo "[ERR] '$g' no es un módulo de $ALUMNOS (hay:$GRUPOS)" >&2; exit 1; }
            PATRON="${PATRON:+$PATRON:}$g"
        done
    done
    SEL=$(equipos "$PATRON")
    if [ -n "$LIMITE" ]; then
        SEL=$(comm -12 <(tr , '\n' <<<"$SEL" | sort) <(equipos "$LIMITE" | tr , '\n' | sort) | paste -sd,)
    fi
    [ -n "$SEL" ] || { echo "[ERR] Ningún alumno de '$PATRON'${LIMITE:+ con -l '$LIMITE'} en $ALUMNOS" >&2; exit 1; }
    echo "Módulo $PATRON${LIMITE:+ y -l '$LIMITE'}: $(tr , '\n' <<<"$SEL" | wc -l) alumnos"
    LIMITE="$SEL"
fi
if [ -n "$LIMITE" ]; then
    if [ -n "$ALUMNOS" ] && [ -z "$(equipos "$LIMITE")" ]; then
        echo "[ERR] El -l '$LIMITE' no coincide con ningún alumno de $ALUMNOS" >&2; exit 1
    fi
    ARGS+=(-l "$LIMITE")
fi

LOGDIR=/var/log/IAC-IESMHP
{ mkdir -p "$LOGDIR" && touch "$LOGDIR/AODappsflatpack.log"; } 2>/dev/null \
    || LOGDIR="$HOME/.local/state/IAC-IESMHP"
mkdir -p "$LOGDIR"
LOG="$LOGDIR/AODappsflatpack.log"
LOGEQ="$LOGDIR/AODappsflatpack"            # un log por alumno
mkdir -p "$LOGEQ"
cd "$DIR" || exit 1

SAL=$(mktemp); trap 'rm -f "$SAL"' EXIT

# Reparte la salida de Ansible en un log por alumno
# (<carpeta>/AODappsflatpack-<alumno>.log). Cada línea va al alumno que nombra
# ("ok: [SMRD-04-SMRV24]", "fatal: [...]", el PLAY RECAP...) con el nombre de
# la tarea delante; las de continuación van al último alumno, y los bloques
# [ERROR]/[WARNING] al siguiente que aparece. Se lee aunque vayan a la vez.
separa_log() {   # separa_log <salida> <prefijo> <cabecera>
    python3 - "$1" "$LOGEQ" "$2" "$3" <<'PY'
import re, sys, os
sal, carpeta, prefijo, cabecera = sys.argv[1:5]
estado = re.compile(r'^(ok|changed|skipping|failed|fatal|FAILED - RETRYING|unreachable|rescued|ignored|included): \[([^\]]+)\]')
recap = re.compile(r'^(\S+)\s+: ok=\d+')
por_equipo, tarea, actual, pendiente, ya = {}, '', None, [], set()
def poner(eq, linea):
    l = por_equipo.setdefault(eq, [])
    if tarea and (eq, tarea) not in ya:
        ya.add((eq, tarea)); l.append(''); l.append(tarea)
    l.extend(pendiente); pendiente.clear()
    l.append(linea)
for linea in open(sal, encoding='utf-8', errors='replace').read().splitlines():
    if linea.startswith(('TASK [', 'PLAY [', 'PLAY RECAP')):
        tarea = re.sub(r'^TASK \[\S*AODappsflatpack : ', 'TASK [', linea.rstrip('* '))
        actual = None; pendiente.clear(); continue
    m = estado.match(linea) or recap.match(linea)
    if m:
        actual = m.group(m.lastindex); poner(actual, linea); continue
    if linea.startswith('[ERROR]') or linea.startswith('[WARNING]'):
        actual = None
    if actual is None:
        if linea.strip(): pendiente.append(linea)
    elif linea.strip():
        por_equipo[actual].append(linea)
for eq, lineas in por_equipo.items():
    nombre = re.sub(r'[^A-Za-z0-9._-]', '_', eq)
    with open(os.path.join(carpeta, prefijo + nombre + '.log'), 'a', encoding='utf-8') as f:
        f.write(cabecera + '\n' + '\n'.join(lineas) + '\n\n')
PY
}

mmss() { printf '%d:%02d' $(( $1 / 60 )) $(( $1 % 60 )); }

# Tabla de tiempos: una línea por alumno (TIEMPO|alumno|<equipo>|<seg>|<estado>)
# y debajo una por aplicación (TIEMPOAPP|<equipo>|<app>|<seg>|<estado>|<versión>),
# más los que no respondieron (unreachable en el PLAY RECAP) y un resumen por
# aplicación (cuántos de cada estado, tiempo medio y máximo).
tiempos() {   # tiempos <fichero de salida>
    python3 - "$1" <<'PY'
import re, sys
txt = open(sys.argv[1], encoding='utf-8', errors='replace').read()
mmss = lambda s: '%d:%02d' % (s // 60, s % 60)
alumnos, apps = {}, {}
for eq, seg, est in re.findall(r'TIEMPO\|alumno\|([^|]+)\|(\d+)\|([A-Z_]+)', txt):
    alumnos[eq] = (int(seg), est)
for eq, app, seg, est, ver in re.findall(r'TIEMPOAPP\|([^|]+)\|([^|]+)\|(\d+)\|([A-Z_]+)\|([^\s"]*)', txt):
    apps.setdefault(eq, {})[app] = (int(seg), est, ver)
for eq in re.findall(r'^(\S+)\s+: ok=.*unreachable=[1-9]', txt, re.M):
    alumnos.setdefault(eq, (None, 'SIN_RESPUESTA'))
for eq in sorted(set(alumnos) | set(apps)):
    seg, est = alumnos.get(eq, (None, '?'))
    print('    %-26s %8s  %s' % (eq, mmss(seg) if seg is not None else '-', est.replace('_', ' ')))
    for app, (s, e, v) in apps.get(eq, {}).items():
        print('        %-22s %8s  %-14s %s' % (app, mmss(s), e.replace('_', ' '), v))
por_app = {}
for d in apps.values():
    for app, (s, e, v) in d.items():
        por_app.setdefault(app, []).append((s, e, v))
if por_app:
    print('  Por aplicación:')
    for app, l in por_app.items():
        cuenta = {}
        for s, e, v in l: cuenta[e] = cuenta.get(e, 0) + 1
        versiones = sorted({v for s, e, v in l if v not in ('', '-', '?')})
        segs = [s for s, e, v in l]
        print('    %-14s medio %6s  máx %6s  %s  %s' % (app, mmss(sum(segs) // len(segs)), mmss(max(segs)),
              ', '.join('%s %d' % (k.replace('_', ' '), n) for k, n in sorted(cuenta.items())),
              ('versión ' + ', '.join(versiones)) if versiones else ''))
PY
}

ACCION=$([ "$DESHACER" = 1 ] && echo "DESHACER" || echo "instalar/actualizar")
if [ -n "$ALUMNOS" ]; then INV=(-i "$ALUMNOS"); else INV=(-i localhost, --connection=local); fi
echo "===== $(date '+%F %T') AODappsflatpack ($ACCION${APPS:+: $APPS}) ${INV[*]} --forks $FORKS ${ARGS[*]}" | tee -a "$LOG"
# Latido: mientras flatpak descarga (async), Ansible no saca nada en pantalla
# hasta que termina la tarea (LibreOffice la 1ª vez: ~5 min), y parece colgado.
# Si la salida lleva 30 s quieta, se avisa en pantalla (no en el log) de cuánto
# lleva y cuál fue la última tarea. Si la tarea es "qué hacer", lo que corre
# es la instalación.
latido() {   # latido <pid de ansible>
    local tam=-1 n quieto=0 tarea
    while kill -0 "$1" 2>/dev/null; do
        sleep 5
        n=$(stat -c %s "$SAL" 2>/dev/null || echo 0)
        if [ "$n" != "$tam" ]; then tam=$n; quieto=0; continue; fi
        quieto=$((quieto + 5))
        [ $((quieto % 30)) -eq 0 ] || continue
        tarea=$(grep -E '^TASK \[' "$SAL" | tail -n1 | sed -E 's/^TASK \[(\S*AODappsflatpack : )?//; s/\] \**$//')
        case "$tarea" in
            *": aviso"|*": qué hacer"|*": falló; se recrea"*)
                tarea="${tarea%%:*}: descargando/instalando de Flathub" ;;
        esac
        printf '   … %s sin novedades (%s). Sigue trabajando. [%s]\n' \
            "$(mmss "$quieto")" "$tarea" "$(date +%T)" >/dev/tty 2>/dev/null \
            || printf '   … %s sin novedades (%s)\n' "$(mmss "$quieto")" "$tarea" >&2
    done
}

( ansible-playbook "${INV[@]}" --forks "$FORKS" -e "AODappsflatpack_serie=$FORKS" AODappsflatpack.yaml "${ARGS[@]}" </dev/null 2>&1 | tee -a "$LOG" "$SAL" ) &
PID=$!
latido "$PID" &
PID_LATIDO=$!
trap 'kill "$PID_LATIDO" 2>/dev/null; rm -f "$SAL"' EXIT
# Ctrl+C: ojo, la instalación que ya corre en el equipo del alumno (async)
# sigue hasta acabar aunque se pare aquí.
trap 'echo; echo "[AVISO] Interrumpido. La instalación que estaba en marcha en el equipo del alumno sigue sola hasta terminar."' INT
wait "$PID"
RC=$?
kill "$PID_LATIDO" 2>/dev/null

[ -s "$SAL" ] && separa_log "$SAL" "AODappsflatpack-" "===== $INICIO AODappsflatpack ($ACCION${APPS:+: $APPS})"
{
    echo ""
    echo "===== TIEMPOS ($ACCION), por alumno y aplicación"
    tiempos "$SAL"
    echo "  TOTAL GENERAL: $(mmss $(( $(date +%s) - T0 )))   (inicio $INICIO, fin $(date '+%d/%m %H:%M'))"
    echo "===== fin (código $RC). Log: $LOG"
    echo "      Logs por alumno: $LOGEQ/"
} | tee -a "$LOG"
exit $RC
