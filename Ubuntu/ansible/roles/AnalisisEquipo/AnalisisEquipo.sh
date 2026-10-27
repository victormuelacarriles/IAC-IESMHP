#!/bin/bash
# Lanza el rol AnalisisEquipo: análisis de hardware de cada equipo COMO ROOT
# (memoria, discos, CPU, GPU NVIDIA, estrés largo y errores del kernel). Mide
# los tiempos y deja un resumen por equipo.
#
# Uso:
#   bash AnalisisEquipo.sh SMRD                     # toda el aula SMRD
#   bash AnalisisEquipo.sh IABD -l IABD-05          # un equipo
#   bash AnalisisEquipo.sh SMRD --sin-estres        # rápido (~3-5 min por equipo)
#   bash AnalisisEquipo.sh SMRD --estres-min 30 --gpu-min 15
#   bash AnalisisEquipo.sh SMRD --soloKernelPanics  # solo kernels + panics (segundos)
#   bash AnalisisEquipo.sh <equipos.ini> [args de ansible-playbook]
#   sudo bash AnalisisEquipo.sh                     # en local (este equipo)
#
# Opciones:
#   SMRD | IABD | <equipos.ini>   inventario de aula (ansible_user=root). Sin él: en local
#   -l PATRÓN          equipos como en ansible (SMRD-05, 'SMRD-0*', 'all:!SMRD-00')
#   --forks N          equipos a la vez (30 por defecto; cada uno se mide a sí mismo)
#   --pasos L          solo esos: kernels,sistema,cpu,memoria,discos,gpu,estres,kernel,panics
#   --soloKernelPanics solo los kernels instalados y los panics/oops/cuelgues de
#                      los arranques anteriores: no instala nada ni mide nada más
#                      (también --solo-kernel-panics)
#   --arranques N      arranques anteriores que se revisan buscando panics (10)
#   --sin-estres       sin stress-ng, memtester ni estrés de GPU
#   --sin-pruebas      solo datos y salud (sin pruebas de rendimiento ni estrés)
#   --estres-min N     minutos de estrés CPU+RAM (10; 0 = no)
#   --memtester-pct N  % de la RAM disponible para memtester (25; 0 = no)
#   --memtester-max N  minutos máximos de memtester (30)
#   --gpu-min N        minutos de estrés de la GPU NVIDIA (5; 0 = no)
#   --disco-gb N       GB del fichero de prueba de escritura (2)
#   --temp-max N       °C de CPU a los que se corta el estrés (95)
#   --forzar           estrés aunque haya usuarios con sesión (por defecto se salta)
#   --sin-instalar     no instala con apt las herramientas que falten
#   -h | --help | --ayuda
#   El resto de opciones que empiecen por - van a ansible-playbook (-v, -e...).
#
# Sin preguntas (headless). Salida en pantalla y en
# /var/log/IAC-IESMHP/AnalisisEquipo.log (o ~/.local/state/IAC-IESMHP/). En la
# carpeta AnalisisEquipo/ de al lado:
#   <equipo>/resumen-<fecha>.txt   resumen de cada equipo (lo trae del equipo)
#   <equipo>-ultimo.txt            el último de ese equipo
#   AnalisisEquipo-<fecha>.csv     una fila por equipo para comparar (separador ;)
# En cada equipo queda además /var/log/IAC-IESMHP/AnalisisEquipo/.
# Al final, tabla de TIEMPOS por equipo y paso.
set -o pipefail
T0=$(date +%s)
INICIO=$(date '+%d/%m %H:%M')
FECHA=$(date +%Y%m%d-%H%M)

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INVDIR="$(cd "$DIR/../.." && pwd)"          # Ubuntu/ansible/ (inventarios de aula)

INVENTARIO=""; ARGS=(); LIMITE=""; RESUMEN_OPC=""; SOLO_PANICS=0
FORKS="${FORKS:-30}"

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help|--ayuda|-\?) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
        SMRD|smrd)        INVENTARIO="$INVDIR/equiposSMRD.ini" ;;
        IABD|iabd)        INVENTARIO="$INVDIR/equiposIABD.ini" ;;
        -l|--limit)       LIMITE="$2"; shift ;;
        --limit=*)        LIMITE="${1#--limit=}" ;;
        -l?*)             LIMITE="${1#-l}" ;;
        --forks)          FORKS="$2"; shift ;;
        --forks=*)        FORKS="${1#*=}" ;;
        --pasos)          ARGS+=(-e "AnalisisEquipo_pasos=$2"); RESUMEN_OPC+=" pasos=$2"; shift ;;
        --sin-estres)     ARGS+=(-e AnalisisEquipo_estres_min=0 -e AnalisisEquipo_memtester_pct=0 -e AnalisisEquipo_gpu_min=0); RESUMEN_OPC+=" sin-estrés" ;;
        --sin-pruebas)    ARGS+=(-e AnalisisEquipo_pruebas=false); RESUMEN_OPC+=" sin-pruebas" ;;
        --soloKernelPanics|--solo-kernel-panics)
            ARGS+=(-e AnalisisEquipo_pasos=kernels,panics -e AnalisisEquipo_instalar=false)
            RESUMEN_OPC+=" solo-kernel-panics"; SOLO_PANICS=1 ;;
        --estres-min|--memtester-pct|--memtester-max|--gpu-min|--disco-gb|--temp-max|--arranques)
            [[ "$2" =~ ^[0-9]+$ ]] || { echo "[ERR] $1 necesita un número: '$2'" >&2; exit 1; }
            V=${1#--}; V=${V//-/_}
            ARGS+=(-e "AnalisisEquipo_$V=$2"); RESUMEN_OPC+=" ${1#--}=$2"; shift ;;
        --forzar)         ARGS+=(-e AnalisisEquipo_forzar=true); RESUMEN_OPC+=" forzar" ;;
        --sin-instalar)   ARGS+=(-e AnalisisEquipo_instalar=false); RESUMEN_OPC+=" sin-instalar" ;;
        -*)               ARGS+=("$1") ;;
        *)
            if [ -z "$INVENTARIO" ] && [ "${#ARGS[@]}" -eq 0 ] && [ -f "$1" ]; then
                INVENTARIO="$(realpath "$1")"
            elif [ -z "$INVENTARIO" ] && [ "${#ARGS[@]}" -eq 0 ]; then
                echo "[ERR] No existe el inventario $1" >&2; exit 1
            else
                ARGS+=("$1")
            fi ;;
    esac
    shift
done

[[ "$FORKS" =~ ^[1-9][0-9]*$ ]] || { echo "[ERR] --forks no válido: '$FORKS'" >&2; exit 1; }

if [ -z "$INVENTARIO" ] && [ "$(id -u)" -ne 0 ] && [[ " ${ARGS[*]} " != *"AnalisisEquipo_sin_root=true"* ]]; then
    echo "[ERR] En local hay que lanzarlo como root: sudo bash $0 $*" >&2; exit 1
fi

equipos() {   # nombres del inventario que cumplen un patrón, separados por comas
    ansible-inventory -i "$INVENTARIO" --list --limit "$1" 2>/dev/null | python3 -c '
import json, sys
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
print(",".join(sorted(d.get("_meta", {}).get("hostvars", {}))))'
}
if [ -n "$LIMITE" ]; then
    if [ -n "$INVENTARIO" ] && [ -z "$(equipos "$LIMITE")" ]; then
        echo "[ERR] El -l '$LIMITE' no coincide con ningún equipo de $INVENTARIO" >&2; exit 1
    fi
    ARGS+=(-l "$LIMITE")
fi

LOGDIR=/var/log/IAC-IESMHP
{ mkdir -p "$LOGDIR" && touch "$LOGDIR/AnalisisEquipo.log"; } 2>/dev/null \
    || LOGDIR="$HOME/.local/state/IAC-IESMHP"
mkdir -p "$LOGDIR"
LOG="$LOGDIR/AnalisisEquipo.log"
LOGEQ="$LOGDIR/AnalisisEquipo"             # resúmenes por equipo + CSV
mkdir -p "$LOGEQ"
CSV="$LOGEQ/AnalisisEquipo-$FECHA.csv"
cd "$DIR" || exit 1

SAL=$(mktemp); trap 'rm -f "$SAL"' EXIT
mmss() { printf '%d:%02d' $(( $1 / 60 )) $(( $1 % 60 )); }

# Tabla de tiempos (TIEMPO|equipo|... del playbook y TIEMPOPASO|... de
# analiza.sh) y CSV comparativo (DATOS|<equipo>|k=v;k=v...).
tiempos() {   # tiempos <salida> <csv>
    python3 - "$1" "$2" <<'PY'
import re, sys, csv
txt = open(sys.argv[1], encoding='utf-8', errors='replace').read()
mmss = lambda s: '%d:%02d' % (s // 60, s % 60)
equipos, pasos, datos = {}, {}, {}
for eq, seg, est in re.findall(r'TIEMPO\|equipo\|([^|]+)\|(\d+)\|([A-Z_?]+)', txt):
    equipos[eq] = (int(seg), est)
for eq, paso, seg, est, corto in re.findall(r'TIEMPOPASO\|([^|]+)\|([^|]+)\|(\d+)\|([A-Z_]+)\|([^"\n]*)', txt):
    pasos.setdefault(eq, {})[paso] = (int(seg), est, corto.strip())
for eq, kv in re.findall(r'DATOS\|([^|]+)\|([^"\n]*)', txt):
    datos[eq] = dict(p.split('=', 1) for p in kv.split(';') if '=' in p)
for eq in re.findall(r'^(\S+)\s+: ok=.*unreachable=[1-9]', txt, re.M):
    equipos.setdefault(eq, (None, 'SIN_RESPUESTA'))
cuenta = {}
for eq in sorted(set(equipos) | set(pasos)):
    seg, est = equipos.get(eq, (None, '?'))
    cuenta[est] = cuenta.get(est, 0) + 1
    print('    %-22s %8s  %s' % (eq, mmss(seg) if seg is not None else '-', est.replace('_', ' ')))
    for paso, (s, e, c) in pasos.get(eq, {}).items():
        print('        %-9s %7s  %-10s %s' % (paso, mmss(s), e.replace('_', ' '), c[:110]))
if cuenta:
    print('  Equipos: ' + ', '.join('%s %d' % (k.replace('_', ' '), n) for k, n in sorted(cuenta.items())))
# Media por paso (solo los que se midieron)
por_paso = {}
for d in pasos.values():
    for paso, (s, e, c) in d.items():
        if e not in ('NO_APLICA',): por_paso.setdefault(paso, []).append(s)
if por_paso:
    print('  Por paso: ' + ' · '.join('%s medio %s máx %s' % (p, mmss(sum(l) // len(l)), mmss(max(l))) for p, l in por_paso.items()))
if datos:
    primeras = ['estado', 't_total', 'modelo', 'cpu', 'hilos', 'ram_gb', 'gpu']
    resto = sorted({k for d in datos.values() for k in d} - set(primeras))
    with open(sys.argv[2], 'w', newline='', encoding='utf-8') as f:
        w = csv.writer(f, delimiter=';')
        w.writerow(['equipo'] + primeras + resto)
        for eq in sorted(datos):
            w.writerow([eq] + [datos[eq].get(k, '') for k in primeras + resto])
    print('  CSV comparativo: ' + sys.argv[2])
PY
}

if [ -n "$INVENTARIO" ]; then INV=(-i "$INVENTARIO"); else INV=(-i localhost, --connection=local); fi
echo "===== $(date '+%F %T') AnalisisEquipo (${RESUMEN_OPC:- completo}) ${INV[*]} --forks $FORKS ${ARGS[*]}" | tee -a "$LOG"
if [ "$SOLO_PANICS" = 1 ]; then
    echo "      Solo kernels y panics: unos segundos por equipo (van $FORKS a la vez)." | tee -a "$LOG"
else
    echo "      Con estrés tarda ~30-50 min por equipo (van $FORKS a la vez). No se ve nada hasta que acaba cada uno." | tee -a "$LOG"
fi

# Latido: el análisis va en async y Ansible no saca nada en pantalla hasta que
# termina. Si la salida lleva 60 s quieta, se avisa en pantalla (no en el log)
# de cuánto lleva y cuántos equipos han terminado.
latido() {   # latido <pid de ansible>
    local tam=-1 n quieto=0 hechos
    while kill -0 "$1" 2>/dev/null; do
        sleep 10
        n=$(stat -c %s "$SAL" 2>/dev/null || echo 0)
        if [ "$n" != "$tam" ]; then tam=$n; quieto=0; continue; fi
        quieto=$((quieto + 10))
        [ $((quieto % 60)) -eq 0 ] || continue
        hechos=$(grep -c 'TIEMPO|equipo|' "$SAL")
        printf '   … analizando: lleva %s en total, %s equipos terminados. [%s]\n' \
            "$(mmss $(( $(date +%s) - T0 )))" "$hechos" "$(date +%T)" >/dev/tty 2>/dev/null \
            || printf '   … analizando (%s)\n' "$(mmss $(( $(date +%s) - T0 )))" >&2
    done
}

( ansible-playbook "${INV[@]}" --forks "$FORKS" -e "AnalisisEquipo_destino=$LOGEQ" AnalisisEquipo.yaml "${ARGS[@]}" </dev/null 2>&1 | tee -a "$LOG" "$SAL" ) &
PID=$!
latido "$PID" &
PID_LATIDO=$!
trap 'kill "$PID_LATIDO" 2>/dev/null; rm -f "$SAL"' EXIT
# Ctrl+C: el análisis que ya corre en cada equipo (async) sigue hasta acabar;
# su resumen queda en /var/log/IAC-IESMHP/AnalisisEquipo/ de ese equipo.
trap 'echo; echo "[AVISO] Interrumpido. El análisis sigue en los equipos hasta acabar (resumen en su /var/log/IAC-IESMHP/AnalisisEquipo/)."' INT
wait "$PID"
RC=$?
kill "$PID_LATIDO" 2>/dev/null

# Copia "<equipo>-ultimo.txt" del resumen más nuevo de cada equipo.
for d in "$LOGEQ"/*/; do
    [ -d "$d" ] || continue
    u=$(ls -1t "$d"resumen-*.txt 2>/dev/null | head -1)
    [ -n "$u" ] && cp -f "$u" "$LOGEQ/$(basename "$d")-ultimo.txt"
done

{
    echo ""
    echo "===== TIEMPOS por equipo y paso"
    tiempos "$SAL" "$CSV"
    echo "  TOTAL GENERAL: $(mmss $(( $(date +%s) - T0 )))   (inicio $INICIO, fin $(date '+%d/%m %H:%M'))"
    echo "===== fin (código $RC). Log: $LOG"
    echo "      Resumen de cada equipo: $LOGEQ/<equipo>-ultimo.txt (histórico en $LOGEQ/<equipo>/)"
} | tee -a "$LOG"
exit $RC
