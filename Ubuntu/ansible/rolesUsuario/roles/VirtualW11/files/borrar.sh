#!/bin/bash
# Deshace lo que crea el rol VirtualW11 para el usuario que lo ejecuta:
#   - apaga la máquina si está encendida (ordenado y, si no, forzado);
#   - la quita de la biblioteca de VMware (~/.vmware/inventory.vmls);
#   - BORRA su carpeta (~/<carpeta>/<nombre>, y <nombre>.copiando si quedó);
#   - borra el perfil de Remmina <nombre> y el marcador <marcador> de Archivos;
#   - quita de ~/.ssh/known_hosts la clave de host de su IP;
#   - borra los scripts del rol en ~/.cache/IAC-IESMHP/VirtualW11.
# No toca nada fuera de eso.
#
# Uso: borrar.sh <carpeta> <nombre> <marcador>     (p. ej. vmware Win11-SMRV08 W11-SMRV08)
# Salida: una línea por cosa; código 0 = bien, 1 = algo no se pudo borrar.
set -u
CARPETA="$1"; NOMBRE="$2"; MARCADOR="$3"
RC=0

# Seguridad: nombres simples, sin rutas.
for v in "$CARPETA" "$NOMBRE" "$MARCADOR"; do
    case "$v" in ''|*/*|.|..) echo "[ERR] Argumento no válido: '$v'"; exit 1 ;; esac
done
DIR="$HOME/$CARPETA/$NOMBRE"
unset DISPLAY WAYLAND_DISPLAY      # vmrun sin ventanas (headless)

# --------------------------------------------------------------- 1. apagar
VMXS=()
[ -d "$DIR" ] && while IFS= read -r -d '' f; do VMXS+=("$f"); done \
    < <(find "$DIR" -maxdepth 1 -name '*.vmx' -print0)
for vmx in "${VMXS[@]}"; do
    if vmrun -T ws list 2>/dev/null | grep -qxF "$vmx"; then
        timeout 180 vmrun -T ws stop "$vmx" soft >/dev/null 2>&1 \
            || timeout 60 vmrun -T ws stop "$vmx" hard >/dev/null 2>&1
        if vmrun -T ws list 2>/dev/null | grep -qxF "$vmx"; then
            echo "[ERR] Máquina : no se pudo apagar $vmx (no se borra)"; exit 1
        fi
        echo "Máquina  : apagada"
    fi
done
if pgrep -u "$(id -u)" -x vmware >/dev/null 2>&1; then
    echo "[WARN] VMware está abierto: ciérralo (si al cerrarlo vuelve a salir la máquina, quítala de la lista)"
fi

# ------------------------------------------------- 2. biblioteca de VMware
INV="$HOME/.vmware/inventory.vmls"
if [ -f "$INV" ]; then
    # Números N de las entradas vmlistN cuya .config está en la carpeta.
    NS=$(grep -E '^vmlist[0-9]+\.config = ' "$INV" | grep -F "\"$DIR/" \
         | sed -E 's/^vmlist([0-9]+)\..*/\1/' | sort -u)
    if [ -n "$NS" ]; then
        patron=$(printf '%s\n' $NS | sed 's/.*/^vmlist&\\./' | paste -sd'|')
        t=$(mktemp); grep -vE "$patron" "$INV" > "$t"; cat "$t" > "$INV"; rm -f "$t"
        echo "VMware   : quitada de la biblioteca ($INV)"
    else
        echo "VMware   : no estaba en la biblioteca"
    fi
fi

# -------------------------------------------------------- 3. carpeta
habia=0
for d in "$DIR" "$DIR.copiando"; do
    if [ -e "$d" ]; then
        habia=1
        if rm -rf -- "$d"; then echo "Carpeta  : BORRADA $d"
        else echo "[ERR] Carpeta : no se pudo borrar $d"; RC=1; fi
    fi
done
[ "$habia" = 1 ] || echo "Carpeta  : no existía $DIR"
rmdir "$HOME/$CARPETA" 2>/dev/null && echo "Carpeta  : quitada $HOME/$CARPETA (vacía)"

# --------------------------------------------- 4. Remmina y marcador (IPs)
IPS=()
PREF="$HOME/.config/remmina/remmina.pref"
DATADIR=$(sed -n 's/^datadir_path=//p' "$PREF" 2>/dev/null | head -1)
DATADIR="${DATADIR:-$HOME/.local/share/remmina}"
hay=0
for f in $(grep -lx "name=$NOMBRE" "$DATADIR"/*.remmina 2>/dev/null); do
    IPS+=("$(sed -n 's/^server=//p' "$f" | head -1 | sed 's/:.*//')")
    rm -f -- "$f" && echo "Remmina  : borrado $f"; hay=1
done
[ "$hay" = 1 ] || echo "Remmina  : no había perfil $NOMBRE"

B="$HOME/.config/gtk-3.0/bookmarks"
if [ -f "$B" ] && grep -qE " $MARCADOR\$" "$B"; then
    while read -r url; do
        h=${url#*://}; h=${h#*@}; IPS+=("${h%%/*}")
    done < <(grep -E " $MARCADOR\$" "$B" | awk '{print $1}')
    t=$(mktemp)
    awk -v n=" $MARCADOR" 'substr($0, length($0) - length(n) + 1) != n' "$B" > "$t"
    cat "$t" > "$B"; rm -f "$t"
    echo "Archivos : quitado el marcador $MARCADOR"
else
    echo "Archivos : no había marcador $MARCADOR"
fi

# ------------------------------------------------------ 5. known_hosts
K="$HOME/.ssh/known_hosts"
for ip in $(printf '%s\n' "${IPS[@]}" | grep -E '^[0-9.]+$' | sort -u); do
    if [ -f "$K" ] && ssh-keygen -F "$ip" -f "$K" >/dev/null 2>&1; then
        ssh-keygen -R "$ip" -f "$K" >/dev/null 2>&1 && echo "SSH      : quitada la clave de host de $ip"
    fi
done

# --------------------------------------------------------- 6. scripts
rm -rf -- "$HOME/.cache/IAC-IESMHP/VirtualW11"
exit $RC
