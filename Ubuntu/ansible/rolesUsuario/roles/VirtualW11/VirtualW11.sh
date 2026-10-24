#!/bin/bash
# Lanza el rol VirtualW11 en dos partes:
#   1) CACHÉ (CacheNAS.yaml, como root, inventario de AULA): copia/actualiza la
#      plantilla del NAS en el disco de cada equipo físico
#      (/datos/nasCache/... o /home/nasCache/...). Una vez por equipo.
#   2) ALUMNO (VirtualW11.yaml, como el alumno, inventario de ALUMNOS): copia la
#      máquina a su perfil desde la caché (o desde el NAS si no hay caché) y la
#      configura.
#
# Uso:
#   bash VirtualW11.sh                      # en local (la caché con sudo -n)
#   bash VirtualW11.sh SMRD                 # aula SMRD
#   bash VirtualW11.sh IABD -l IABD-05      # aula IABD, un equipo
#   bash VirtualW11.sh SMRD -l SMRD-04-SMRV24 -e VirtualW11_reemplazar=true   # BORRA y recopia
#   bash VirtualW11.sh <alumnos.ini> [args de ansible-playbook]
#   Opciones: --sin-cache (solo parte 2)   --solo-cache (solo parte 1)
#             --forks-cache N   equipos a la vez en la parte 1 (5 por defecto)
#             --forks-alumno N  alumnos a la vez en la parte 2 (5 por defecto)
#             (también con las variables FORKS_CACHE=N / FORKS_ALUMNO=N)
#             --nat     red NAT de VMware (POR DEFECTO): IP fija <subred vmnet8>.(100+N)
#                       si el usuario acaba en número N (SMRV02 → .102); si no,
#                       la que le dé el DHCP, fija.
#             --bridge  red del aula (bridged): IP fija = IP del equipo físico + 30
#                       (10.0.32.138 → 10.0.32.168). Equivale a -e VirtualW11_red=bridged.
#   bash VirtualW11.sh SMRD --forks-cache 3 --forks-alumno 10
#   bash VirtualW11.sh SMRD --bridge -l SMRD-04-SMRV24   # ese alumno, en modo bridge
#
# Cambiar de modo en una máquina ya creada funciona igual (se cambia antes de
# encenderla), salvo que esté encendida o abierta en VMware: entonces avisa y
# para (cerrarla y relanzar).
#
# El -l (nombres del inventario de alumnos) se traduce para la parte 1 a los
# equipos físicos por su IP. El resto de argumentos van solo a la parte 2.
# Sin preguntas (headless). Salida en pantalla y en
# /var/log/IAC-IESMHP/VirtualW11.log (o ~/.local/state/IAC-IESMHP/).
set -o pipefail
T0=$(date +%s)            # total general: desde aquí hasta el final

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INVDIR="$(cd "$DIR/../.." && pwd)"          # rolesUsuario/ (inventarios de alumnos)
AULADIR="$(cd "$DIR/../../.." && pwd)"      # ansible/      (inventarios de aula)

CACHE=1; ALUMNO=1; ALUMNOS=""; AULA=""; ARGS=(); LIMITE=""
FORKS_CACHE="${FORKS_CACHE:-5}"; FORKS_ALUMNO="${FORKS_ALUMNO:-5}"

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help|--ayuda|-\?) sed -n '2,37p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        --sin-cache)  CACHE=0 ;;
        --solo-cache) ALUMNO=0 ;;
        --nat)        ARGS+=(-e VirtualW11_red=nat) ;;
        --bridge|--bridged) ARGS+=(-e VirtualW11_red=bridged) ;;
        --forks-cache)    FORKS_CACHE="$2"; shift ;;
        --forks-cache=*)  FORKS_CACHE="${1#*=}" ;;
        --forks-alumno)   FORKS_ALUMNO="$2"; shift ;;
        --forks-alumno=*) FORKS_ALUMNO="${1#*=}" ;;
        SMRD|smrd)    ALUMNOS="$INVDIR/EquiposSMRD-alumnos2627.ini"; AULA="$AULADIR/equiposSMRD.ini" ;;
        IABD|iabd)    ALUMNOS="$INVDIR/equiposIABD-alumnos2627.ini"; AULA="$AULADIR/equiposIABD.ini" ;;
        -l|--limit)   LIMITE="$2"; ARGS+=("$1" "$2"); shift ;;
        --limit=*)    LIMITE="${1#--limit=}"; ARGS+=("$1") ;;
        -l?*)         LIMITE="${1#-l}"; ARGS+=("$1") ;;
        -*)           ARGS+=("$1") ;;
        *)
            if [ -z "$ALUMNOS" ] && [ "${#ARGS[@]}" -eq 0 ] && [ -f "$1" ]; then
                ALUMNOS="$(realpath "$1")"
                # Inventario de aula según el grupo del de alumnos ([SMRD]/[IABD]).
                case "$(grep -m1 -oE '^\[[A-Za-z]+\]' "$ALUMNOS")" in
                    "[SMRD]") AULA="$AULADIR/equiposSMRD.ini" ;;
                    "[IABD]") AULA="$AULADIR/equiposIABD.ini" ;;
                esac
            elif [ -z "$ALUMNOS" ] && [ "${#ARGS[@]}" -eq 0 ]; then
                echo "[ERR] No existe el inventario $1" >&2; exit 1
            else
                ARGS+=("$1")
            fi ;;
    esac
    shift
done

for n in "$FORKS_CACHE" "$FORKS_ALUMNO"; do
    [[ "$n" =~ ^[1-9][0-9]*$ ]] || { echo "[ERR] Número de equipos a la vez no válido: '$n'" >&2; exit 1; }
done

LOGDIR=/var/log/IAC-IESMHP
{ mkdir -p "$LOGDIR" && touch "$LOGDIR/VirtualW11.log"; } 2>/dev/null \
    || LOGDIR="$HOME/.local/state/IAC-IESMHP"
mkdir -p "$LOGDIR"
LOG="$LOGDIR/VirtualW11.log"
cd "$DIR" || exit 1

# Salida de cada parte (para el resumen de tiempos del final).
SAL1=$(mktemp); SAL2=$(mktemp); trap 'rm -f "$SAL1" "$SAL2"' EXIT
T1=0; T2=0

mmss() { printf '%d:%02d' $(( $1 / 60 )) $(( $1 % 60 )); }

# Tabla de tiempos de una parte: líneas TIEMPO|parte|equipo|segundos|estado
# (las saca cada playbook al terminar cada equipo, también si falla) y los
# equipos que no respondieron (unreachable en el PLAY RECAP).
tiempos() {   # tiempos <fichero de salida> <título>
    local f="$1"
    echo "  $2"
    grep -oE 'TIEMPO\|[a-z]+\|[^|]+\|[0-9]+\|[A-Z]+' "$f" | sort -u -t'|' -k3,3 \
        | while IFS='|' read -r _ _ eq seg est; do
              printf '    %-26s %8s  %s\n' "$eq" "$(mmss "$seg")" "$est"
          done
    grep -E '^[^ ]+ +: ok=.*unreachable=[1-9]' "$f" | awk '{print $1}' | sort -u \
        | while read -r eq; do printf '    %-26s %8s  %s\n' "$eq" "-" "SIN RESPUESTA"; done
}

RC1=0; RC2=0

# ------------------------------------------------------------ 1. caché (root)
if [ "$CACHE" = 1 ]; then
    if [ -z "$ALUMNOS" ]; then
        echo "===== $(date '+%F %T') VirtualW11 parte 1 (caché) en local" | tee -a "$LOG"
        if sudo -n true 2>/dev/null; then
            t=$(date +%s)
            sudo -n ansible-playbook -i localhost, --connection=local CacheNAS.yaml </dev/null 2>&1 | tee -a "$LOG" "$SAL1"
            RC1=$?; T1=$(( $(date +%s) - t ))
        else
            echo "[WARN] Sin sudo sin contraseña: no se crea la caché local (la parte 2 copiará desde el NAS)" | tee -a "$LOG"
        fi
    elif [ -z "$AULA" ] || [ ! -f "$AULA" ]; then
        echo "[WARN] No sé qué inventario de aula corresponde a $ALUMNOS: no se actualiza la caché" | tee -a "$LOG"
    else
        EXTRA=()
        if [ -n "$LIMITE" ]; then
            # IPs de los alumnos elegidos con -l → equipos físicos de la parte 1.
            IPS=$(ansible-inventory -i "$ALUMNOS" --list --limit "$LIMITE" 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(",".join(sorted({v["ansible_host"] for v in d.get("_meta", {}).get("hostvars", {}).values() if "ansible_host" in v})))')
            if [ -z "$IPS" ]; then
                echo "[ERR] El -l '$LIMITE' no coincide con ningún equipo de $ALUMNOS" | tee -a "$LOG"; exit 1
            fi
            EXTRA=(-e "VirtualW11_ips=$IPS")
        fi
        echo "===== $(date '+%F %T') VirtualW11 parte 1 (caché) -i $AULA --forks $FORKS_CACHE ${EXTRA[*]}" | tee -a "$LOG"
        t=$(date +%s)
        ansible-playbook -i "$AULA" --forks "$FORKS_CACHE" CacheNAS.yaml "${EXTRA[@]}" </dev/null 2>&1 | tee -a "$LOG" "$SAL1"
        RC1=$?; T1=$(( $(date +%s) - t ))
        # Si falla en algún equipo (apagado...), se sigue: allí la parte 2
        # copiará desde el NAS.
    fi
fi

# --------------------------------------------------------- 2. alumno (rol)
if [ "$ALUMNO" = 1 ]; then
    if [ -n "$ALUMNOS" ]; then INV=(-i "$ALUMNOS"); else INV=(-i localhost, --connection=local); fi
    echo "===== $(date '+%F %T') VirtualW11 parte 2 (alumno) ${INV[*]} --forks $FORKS_ALUMNO ${ARGS[*]}" | tee -a "$LOG"
    t=$(date +%s)
    ansible-playbook "${INV[@]}" --forks "$FORKS_ALUMNO" VirtualW11.yaml "${ARGS[@]}" </dev/null 2>&1 | tee -a "$LOG" "$SAL2"
    RC2=$?; T2=$(( $(date +%s) - t ))
fi

RC=$(( RC2 != 0 ? RC2 : RC1 ))
{
    echo ""
    echo "===== TIEMPOS"
    if [ -s "$SAL1" ]; then tiempos "$SAL1" "Parte 1 — sincronización NAS → caché, por equipo (total parte: $(mmss $T1))"; fi
    if [ -s "$SAL2" ]; then tiempos "$SAL2" "Parte 2 — configuración de Win11, por usuario (total parte: $(mmss $T2))"; fi
    echo "  TOTAL GENERAL: $(mmss $(( $(date +%s) - T0 )))"
    echo "===== fin (caché: código $RC1, alumno: código $RC2). Log: $LOG"
} | tee -a "$LOG"
exit $RC
