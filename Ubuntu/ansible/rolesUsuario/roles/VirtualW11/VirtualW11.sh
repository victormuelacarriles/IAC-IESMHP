#!/bin/bash
# Lanza solo el rol VirtualW11 (VirtualW11.yaml de esta carpeta).
#
# Uso:
#   bash VirtualW11.sh                      # en local, como el usuario actual
#   bash VirtualW11.sh SMRD                 # aula SMRD (EquiposSMRD-alumnos2627.ini)
#   bash VirtualW11.sh IABD -l IABD-05      # aula IABD, un equipo
#   bash VirtualW11.sh <inventario.ini> [args de ansible-playbook]
#   bash VirtualW11.sh SMRD -l SMRD-04-SMRV24 -e VirtualW11_reemplazar=true   # BORRA y recopia
#
# Sin preguntas (headless). Salida completa en pantalla y en
# /var/log/IAC-IESMHP/VirtualW11.log (o ~/.local/state/IAC-IESMHP/ si no se
# puede escribir ahí).
set -o pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INVDIR="$(cd "$DIR/../.." && pwd)"          # rolesUsuario/ (inventarios de alumnos)

case "${1:-}" in
    -h|--help|--ayuda|-\?)
        sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    SMRD|smrd) INV=(-i "$INVDIR/EquiposSMRD-alumnos2627.ini"); shift ;;
    IABD|iabd) INV=(-i "$INVDIR/equiposIABD-alumnos2627.ini"); shift ;;
    ""|-*)     INV=(-i localhost, --connection=local) ;;
    *)         [ -f "$1" ] || { echo "[ERR] No existe el inventario $1" >&2; exit 1; }
               INV=(-i "$(realpath "$1")"); shift ;;
esac

LOGDIR=/var/log/IAC-IESMHP
{ mkdir -p "$LOGDIR" && touch "$LOGDIR/VirtualW11.log"; } 2>/dev/null \
    || LOGDIR="$HOME/.local/state/IAC-IESMHP"
mkdir -p "$LOGDIR"
LOG="$LOGDIR/VirtualW11.log"

echo "===== $(date '+%F %T') VirtualW11 ${INV[*]} $*" | tee -a "$LOG"
cd "$DIR" || exit 1
ansible-playbook "${INV[@]}" VirtualW11.yaml "$@" </dev/null 2>&1 | tee -a "$LOG"
RC=$?
echo "===== fin (código $RC). Log: $LOG" | tee -a "$LOG"
exit $RC
