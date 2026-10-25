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
#   bash VirtualW11.sh SMRD AOD             # solo los alumnos del módulo AOD
#   bash VirtualW11.sh SMRD --modulo AOD -l 'SMRD-0*'   # de AOD, solo esos equipos
#   bash VirtualW11.sh SMRD -l SMRD-04-SMRV24 -e VirtualW11_reemplazar=true   # BORRA y recopia
#   bash VirtualW11.sh <alumnos.ini> [args de ansible-playbook]
#   Opciones: --sin-cache (solo parte 2)   --solo-cache (solo parte 1)
#             --modulo M  solo los alumnos del grupo M del inventario de alumnos
#                       ([AOD], [SOR]...). Vale también poner el nombre suelto
#                       tras el aula (SMRD AOD) y varios: --modulo AOD,SOR.
#                       Con -l, se cogen los que cumplen las dos cosas.
#             --claves F  fichero de claves de los alumnos (USUARIO,clave por línea;
#                       # = comentario). Por defecto .clavesalumnos junto a este
#                       script, si existe. Los dos usuarios de Windows de cada
#                       alumno que esté en él llevan SU clave (en vez de usuario@1),
#                       también en máquinas ya creadas, y no se pone el acceso
#                       directo para cambiarla. --sin-claves: no usarlo.
#             --forks-cache N   equipos a la vez en la parte 1 (5 por defecto)
#             --forks-alumno N  alumnos a la vez en la parte 2 (5 por defecto), por
#                       tandas de N (con 1, de uno en uno)
#             (también con las variables FORKS_CACHE=N / FORKS_ALUMNO=N)
#             --nat     red NAT de VMware (POR DEFECTO): IP fija <subred vmnet8>.(100+N)
#                       si el usuario acaba en número N (SMRV02 → .102); si no,
#                       la que le dé el DHCP, fija.
#             --bridge  red del aula (bridged): IP fija = IP del equipo físico + 30
#                       (10.0.32.138 → 10.0.32.168). Equivale a -e VirtualW11_red=bridged.
#   bash VirtualW11.sh SMRD --forks-cache 3 --forks-alumno 10
#   bash VirtualW11.sh SMRD AOD --BORRAR -l SMRD-04-SMRV24   # BORRA máquina + accesos
#
#   --BORRAR   deshace todo para los alumnos elegidos (mismos filtros: aula,
#              módulo, -l): apaga y BORRA ~/vmware/Win11-<usuario>, la quita de
#              VMware y borra su lanzador de Remmina y su marcador de Archivos.
#              No hace la parte 1. Antes enseña la lista y pide escribir BORRAR
#              (--si: sin preguntar, para usarlo desde otro script).
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

CACHE=1; ALUMNO=1; ALUMNOS=""; AULA=""; ARGS=(); LIMITE=""; MODULOS=(); SUELTOS=()
FORKS_CACHE="${FORKS_CACHE:-5}"; FORKS_ALUMNO="${FORKS_ALUMNO:-5}"
CLAVES="$DIR/.clavesalumnos"; CLAVES_DADO=0; BORRAR=0; SIN_PREGUNTAR=0

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help|--ayuda|-\?) sed -n '2,55p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        --sin-cache)  CACHE=0 ;;
        --BORRAR|--borrar) BORRAR=1 ;;
        --si)         SIN_PREGUNTAR=1 ;;
        --solo-cache) ALUMNO=0 ;;
        --nat)        ARGS+=(-e VirtualW11_red=nat) ;;
        --bridge|--bridged) ARGS+=(-e VirtualW11_red=bridged) ;;
        --forks-cache)    FORKS_CACHE="$2"; shift ;;
        --forks-cache=*)  FORKS_CACHE="${1#*=}" ;;
        --forks-alumno)   FORKS_ALUMNO="$2"; shift ;;
        --forks-alumno=*) FORKS_ALUMNO="${1#*=}" ;;
        SMRD|smrd)    ALUMNOS="$INVDIR/EquiposSMRD-alumnos2627.ini"; AULA="$AULADIR/equiposSMRD.ini" ;;
        IABD|iabd)    ALUMNOS="$INVDIR/equiposIABD-alumnos2627.ini"; AULA="$AULADIR/equiposIABD.ini" ;;
        --claves)     CLAVES="$2"; CLAVES_DADO=1; shift ;;
        --claves=*)   CLAVES="${1#*=}"; CLAVES_DADO=1 ;;
        --sin-claves) CLAVES="" ;;
        --modulo|-m)  MODULOS+=("$2"); shift ;;
        --modulo=*)   MODULOS+=("${1#*=}") ;;
        -l|--limit)   LIMITE="$2"; shift ;;
        --limit=*)    LIMITE="${1#--limit=}" ;;
        -l?*)         LIMITE="${1#-l}" ;;
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
            elif [ -n "$ALUMNOS" ] && [ "${#ARGS[@]}" -eq 0 ] && [[ "$1" =~ ^[A-Za-z][A-Za-z0-9_]*$ ]]; then
                SUELTOS+=("$1")       # posible módulo (SMRD AOD): se comprueba abajo
            else
                ARGS+=("$1")
            fi ;;
    esac
    shift
done

# Grupos que hay en el inventario de alumnos (para validar los módulos).
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
    for s in "${SUELTOS[@]}"; do
        if [[ "$GRUPOS" == *" $s "* ]]; then MODULOS+=("$s")
        else echo "[ERR] '$s' no es un módulo de $ALUMNOS (hay:$GRUPOS)" >&2; exit 1; fi
    done
    PATRON=""
    for m in "${MODULOS[@]}"; do
        for g in ${m//,/ }; do
            [[ "$GRUPOS" == *" $g "* ]] || { echo "[ERR] No existe el módulo '$g' en $ALUMNOS (hay:$GRUPOS)" >&2; exit 1; }
            PATRON="${PATRON:+$PATRON:}$g"
        done
    done
    # Módulos (unión) y, si hay -l, solo los que también lo cumplen.
    SEL=$(equipos "$PATRON")
    if [ -n "$LIMITE" ]; then
        SEL=$(comm -12 <(tr , '\n' <<<"$SEL" | sort) <(equipos "$LIMITE" | tr , '\n' | sort) | paste -sd,)
    fi
    [ -n "$SEL" ] || { echo "[ERR] Ningún alumno de '$PATRON'${LIMITE:+ con -l '$LIMITE'} en $ALUMNOS" >&2; exit 1; }
    echo "Módulo $PATRON${LIMITE:+ y -l '$LIMITE'}: $(tr , '\n' <<<"$SEL" | wc -l) alumnos"
    LIMITE="$SEL"
fi
[ -n "$LIMITE" ] && ARGS+=(-l "$LIMITE")

# Fichero de claves: se lee en ESTE equipo (el que lanza Ansible).
[ "$BORRAR" = 1 ] && CLAVES=""
if [ -n "$CLAVES" ]; then
    if [ -f "$CLAVES" ]; then
        CLAVES="$(realpath "$CLAVES")"
        echo "Claves de los alumnos: $CLAVES ($(grep -cvE '^[[:space:]]*(#|$)' "$CLAVES") alumnos)"
        ARGS+=(-e "$(python3 -c 'import json,sys; print(json.dumps({"VirtualW11_claves_fichero": sys.argv[1]}))' "$CLAVES")")
    elif [ "$CLAVES_DADO" = 1 ]; then
        echo "[ERR] No existe el fichero de claves $CLAVES" >&2; exit 1
    else
        echo "Claves de los alumnos: no hay $CLAVES → contraseña inicial usuario@1"
    fi
fi

# --BORRAR: sin parte 1, lista de afectados y confirmación (herramienta manual:
# es la única pregunta del script; con --si no pregunta).
if [ "$BORRAR" = 1 ]; then
    CACHE=0
    if [ -n "$ALUMNOS" ]; then
        LISTA=$(equipos "${LIMITE:-all}" | tr , '\n')
        [ -n "$LISTA" ] || { echo "[ERR] Ningún alumno coincide con la selección" >&2; exit 1; }
        echo "Se va a BORRAR la máquina Win11 (y su lanzador de Remmina y su marcador de Archivos) de $(wc -l <<<"$LISTA") alumnos de $ALUMNOS:"
        sed 's/^/    /' <<<"$LISTA"
    else
        echo "Se va a BORRAR ~/vmware/Win11-$(id -un) de $(id -un) en este equipo (y su lanzador de Remmina y su marcador de Archivos)."
    fi
    if [ "$SIN_PREGUNTAR" != 1 ]; then
        if [ ! -t 0 ] && [ ! -r /dev/tty ]; then
            echo "[ERR] Sin terminal para confirmar: usa --si para borrar sin preguntar" >&2; exit 1
        fi
        read -r -p "Se perderá todo lo que haya dentro. Escribe BORRAR para confirmar: " RESP </dev/tty
        [ "$RESP" = "BORRAR" ] || { echo "Cancelado: no se ha borrado nada."; exit 1; }
    fi
    ARGS+=(-e VirtualW11_borrar=true)
fi

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
    grep -oE 'TIEMPO\|[a-z]+\|[^|]+\|[0-9]+\|[A-Z_]+' "$f" | sort -u -t'|' -k3,3 \
        | while IFS='|' read -r _ _ eq seg est; do
              printf '    %-26s %8s  %s\n' "$eq" "$(mmss "$seg")" "${est//_/ }"
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
    echo "===== $(date '+%F %T') VirtualW11 parte 2 (alumno$([ "$BORRAR" = 1 ] && echo ', BORRAR')) ${INV[*]} --forks $FORKS_ALUMNO ${ARGS[*]}" | tee -a "$LOG"
    t=$(date +%s)
    ansible-playbook "${INV[@]}" --forks "$FORKS_ALUMNO" -e "VirtualW11_serie=$FORKS_ALUMNO" VirtualW11.yaml "${ARGS[@]}" </dev/null 2>&1 | tee -a "$LOG" "$SAL2"
    RC2=$?; T2=$(( $(date +%s) - t ))
fi

RC=$(( RC2 != 0 ? RC2 : RC1 ))
{
    echo ""
    echo "===== TIEMPOS"
    if [ -s "$SAL1" ]; then tiempos "$SAL1" "Parte 1 — sincronización NAS → caché, por equipo (total parte: $(mmss $T1))"; fi
    if [ -s "$SAL2" ]; then tiempos "$SAL2" "Parte 2 — $([ "$BORRAR" = 1 ] && echo borrado || echo configuración) de Win11, por usuario (total parte: $(mmss $T2))"; fi
    echo "  TOTAL GENERAL: $(mmss $(( $(date +%s) - T0 )))"
    echo "===== fin (caché: código $RC1, alumno: código $RC2). Log: $LOG"
} | tee -a "$LOG"
exit $RC
