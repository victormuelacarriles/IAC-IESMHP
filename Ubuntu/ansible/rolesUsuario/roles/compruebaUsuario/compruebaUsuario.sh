#!/bin/bash
# Lanza el rol compruebaUsuario: dice, alumno a alumno, si su usuario entra por
# SSH en su equipo (OK / NO ACCEDE / APAGADO). No cambia nada en los equipos.
# Útil antes de lanzar VirtualW11 o AODappsflatpack: al final saca el -l de los
# que están OK para pasárselo a esos scripts.
#
# Uso:
#   bash compruebaUsuario.sh                     # en local, el usuario actual
#   bash compruebaUsuario.sh SMRD                # todos los alumnos de SMRD
#   bash compruebaUsuario.sh SMRD AOD            # solo los del módulo AOD
#   bash compruebaUsuario.sh SMRD AOD -l 'SMRD-0*'   # de AOD, solo esos
#   bash compruebaUsuario.sh IABD -l IABD-05
#   bash compruebaUsuario.sh SMRD -k             # con contraseña (la pide)
#   bash compruebaUsuario.sh <alumnos.ini> [args de ansible-playbook]
#
# Opciones:
#   SMRD | IABD | <alumnos.ini>   inventario de alumnos (sin él: en local)
#   --modulo M   solo los alumnos del grupo M ([AOD], [SOR]...). Vale también
#                el nombre suelto tras el aula (SMRD AOD) y varios: AOD,SOR.
#                Con -l, se cogen los que cumplen las dos cosas.
#   -l PATRÓN    alumnos (nombres del inventario) como en ansible
#   --forks N    alumnos a la vez (POR DEFECTO 20; también FORKS=N)
#   --timeout S  segundos de espera de la conexión SSH (5 por defecto)
#   -k | --pedir-password   entra con contraseña en vez de con clave SSH: la
#                pide por el terminal, sin eco (la misma para todos). También
#                sin preguntar con la variable COMPRUEBA_PASSWORD=... o con
#                --password-fichero F (la primera línea de F). Necesita sshpass.
#   --breve      en pantalla solo el resumen final (Ansible entero al log)
#   -h | --help | --ayuda
#   El resto de opciones que empiecen por - van a ansible-playbook (-v, -e...).
#
# Sin preguntas salvo con -k (herramienta manual). Salida en pantalla y en
# /var/log/IAC-IESMHP/compruebaUsuario.log (o ~/.local/state/IAC-IESMHP/), que
# se va añadiendo con una cabecera "=====" por ejecución. Al final: tabla por
# alumno, totales, equipos físicos apagados y el -l de los OK y de los que
# fallan. Código de salida 0 solo si todos están OK.
set -o pipefail
T0=$(date +%s)
INICIO=$(date '+%d/%m %H:%M')

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INVDIR="$(cd "$DIR/../.." && pwd)"          # rolesUsuario/ (inventarios de alumnos)

ALUMNOS=""; ARGS=(); LIMITE=""; MODULOS=(); SUELTOS=(); BREVE=0
PEDIR=0; PASSFILE=""; PASSWORD="${COMPRUEBA_PASSWORD:-}"
FORKS="${FORKS:-20}"; TIMEOUT=""

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help|--ayuda|-\?) sed -n '2,37p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -k|--pedir-password|--ask-pass) PEDIR=1 ;;
        --password-fichero)   PASSFILE="$2"; shift ;;
        --password-fichero=*) PASSFILE="${1#*=}" ;;
        --breve)          BREVE=1 ;;
        --timeout)        TIMEOUT="$2"; shift ;;
        --timeout=*)      TIMEOUT="${1#*=}" ;;
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
if [ -n "$TIMEOUT" ]; then
    [[ "$TIMEOUT" =~ ^[1-9][0-9]*$ ]] || { echo "[ERR] --timeout no válido: '$TIMEOUT'" >&2; exit 1; }
    ARGS+=(-e "compruebaUsuario_timeout=$TIMEOUT")
fi

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

# Contraseña: nunca en la línea de órdenes (se vería con ps). Va a un JSON
# temporal (0600) que se pasa con -e @fichero y se borra al salir.
TMPS=()
trap 'rm -f "${TMPS[@]}"' EXIT
if [ -n "$PASSFILE" ]; then
    [ -r "$PASSFILE" ] || { echo "[ERR] No se puede leer $PASSFILE" >&2; exit 1; }
    PASSWORD="$(head -n1 "$PASSFILE")"
fi
if [ "$PEDIR" = 1 ] && [ -z "$PASSWORD" ]; then
    [ -r /dev/tty ] || { echo "[ERR] Sin terminal para pedir la contraseña: usa COMPRUEBA_PASSWORD o --password-fichero" >&2; exit 1; }
    read -r -s -p "Contraseña SSH de los alumnos: " PASSWORD </dev/tty; echo >/dev/tty
    [ -n "$PASSWORD" ] || { echo "[ERR] Contraseña vacía" >&2; exit 1; }
fi
MODO="clave SSH"
if [ -n "$PASSWORD" ]; then
    command -v sshpass >/dev/null || { echo "[ERR] Para entrar con contraseña hace falta sshpass (sudo apt install sshpass)" >&2; exit 1; }
    PJSON=$(mktemp); TMPS+=("$PJSON"); chmod 600 "$PJSON"
    python3 -c 'import json,sys; print(json.dumps({"compruebaUsuario_password": sys.argv[1]}))' "$PASSWORD" >"$PJSON"
    ARGS+=(-e "@$PJSON")
    MODO="contraseña"
fi
unset PASSWORD COMPRUEBA_PASSWORD

LOGDIR=/var/log/IAC-IESMHP
{ mkdir -p "$LOGDIR" && touch "$LOGDIR/compruebaUsuario.log"; } 2>/dev/null \
    || LOGDIR="$HOME/.local/state/IAC-IESMHP"
mkdir -p "$LOGDIR"
LOG="$LOGDIR/compruebaUsuario.log"
cd "$DIR" || exit 1

SAL=$(mktemp); TMPS+=("$SAL")

mmss() { printf '%d:%02d' $(( $1 / 60 )) $(( $1 % 60 )); }

# Resumen a partir de las líneas COMPRUEBA|alumno|ip|usuario|estado|motivo que
# saca el segundo play de compruebaUsuario.yaml.
resumen() {   # resumen <fichero de salida>
    python3 - "$1" <<'PY'
import json, re, sys
filas = {}
for linea in open(sys.argv[1], encoding='utf-8', errors='replace'):
    m = re.search(r'"msg": "(COMPRUEBA\|.*)"\s*$', linea)
    if not m:
        continue
    try:
        txt = json.loads('"' + m.group(1) + '"')
    except Exception:
        txt = m.group(1)
    p = txt.split('|', 5) + [''] * 6
    filas[p[1]] = dict(ip=p[2], usuario=p[3], estado=p[4].strip() or '?', motivo=p[5].strip())
if not filas:
    print('  (no hay resultados: mira el log de Ansible)')
    sys.exit(0)
orden = {'NO ACCEDE': 0, 'APAGADO': 1, 'ERROR': 2, '?': 3, 'OK': 4}
for eq, f in sorted(filas.items(), key=lambda x: (orden.get(x[1]['estado'], 3), x[0])):
    mot = '' if f['estado'] == 'OK' else f['motivo'][:70]
    print('    %-10s %-24s %-15s %-22s %s' % (f['estado'], eq, f['ip'], f['usuario'], mot))
cuenta = {}
for f in filas.values():
    cuenta[f['estado']] = cuenta.get(f['estado'], 0) + 1
print('  Total %d: %s' % (len(filas), ', '.join('%s %d' % (k, n) for k, n in
      sorted(cuenta.items(), key=lambda x: orden.get(x[0], 3)))))
# Equipos físicos (por IP): varios alumnos comparten equipo.
ips = {}
for eq, f in filas.items():
    ips.setdefault(f['ip'], set()).add(f['estado'])
apagados = sorted(ip for ip, e in ips.items() if e == {'APAGADO'})
if apagados:
    print('  Equipos apagados o sin SSH (%d): %s' % (len(apagados), ' '.join(apagados)))
ok = sorted(eq for eq, f in filas.items() if f['estado'] == 'OK')
mal = sorted(eq for eq, f in filas.items() if f['estado'] != 'OK')
if ok and mal:
    print("  -l de los OK:      '%s'" % ','.join(ok))
if mal:
    print("  -l de los que fallan: '%s'" % ','.join(mal))
PY
}

if [ -n "$ALUMNOS" ]; then INV=(-i "$ALUMNOS"); else INV=(-i localhost, --connection=local); fi
# En la cabecera no se ve el fichero de la contraseña, solo el modo.
VISIBLES=()
for a in "${ARGS[@]}"; do [ "$a" = "@${PJSON:-}" ] && VISIBLES+=("@(contraseña)") || VISIBLES+=("$a"); done
echo "===== $(date '+%F %T') compruebaUsuario ($MODO) ${INV[*]} --forks $FORKS ${VISIBLES[*]}" | tee -a "$LOG"

if [ "$BREVE" = 1 ]; then
    echo "Comprobando... (salida de Ansible en $LOG)"
    ansible-playbook "${INV[@]}" --forks "$FORKS" compruebaUsuario.yaml "${ARGS[@]}" </dev/null 2>&1 | tee -a "$LOG" >"$SAL"
else
    ansible-playbook "${INV[@]}" --forks "$FORKS" compruebaUsuario.yaml "${ARGS[@]}" </dev/null 2>&1 | tee -a "$LOG" "$SAL"
fi
RC=$?

{
    echo ""
    echo "===== RESUMEN compruebaUsuario ($MODO)"
    resumen "$SAL"
    echo "  TOTAL: $(mmss $(( $(date +%s) - T0 )))   (inicio $INICIO, fin $(date '+%d/%m %H:%M'))"
    echo "===== fin (código $RC). Log: $LOG"
} | tee -a "$LOG"
exit $RC
