#!/bin/bash
# Añade una máquina virtual a la biblioteca de VMware Workstation del usuario
# (~/.vmware/inventory.vmls). Idempotente: si ya está, no hace nada.
#
# Uso: inventario-vmware.sh <inventory.vmls> <ruta .vmx> <nombre visible>
# Salida: "YA ESTABA" o "AÑADIDA" (Ansible lo usa para changed_when).
set -euo pipefail

INV="$1"
VMX="$2"
NOMBRE="$3"

mkdir -p "$(dirname "$INV")"
[ -s "$INV" ] || printf '.encoding = "UTF-8"\n' > "$INV"

if grep -qF ".config = \"$VMX\"" "$INV"; then
    echo "YA ESTABA"
    exit 0
fi

# Si VMware está abierto, al cerrarse reescribe la biblioteca y puede perder
# la entrada nueva. Solo se avisa: no se espera a nadie (headless).
if pgrep -u "$(id -u)" -x vmware >/dev/null 2>&1; then
    echo "[WARN] VMware está abierto: si al cerrarlo desaparece la máquina, relanzar el rol" >&2
fi

# Siguiente número libre de vmlistN y posición dentro de la raíz (ParentID 0).
N=$(sed -nE 's/^vmlist([0-9]+)\..*/\1/p' "$INV" | sort -n | tail -1)
N=$(( ${N:-0} + 1 ))
SEQ=$(grep -cE '^vmlist[0-9]+\.ParentID = "0"' "$INV" || true)

cat >> "$INV" <<EOF
vmlist$N.config = "$VMX"
vmlist$N.DisplayName = "$NOMBRE"
vmlist$N.ParentID = "0"
vmlist$N.ItemID = "$N"
vmlist$N.SeqID = "$SEQ"
vmlist$N.IsFavorite = "FALSE"
vmlist$N.IsClone = "FALSE"
vmlist$N.CfgVersion = "8"
vmlist$N.State = "normal"
vmlist$N.IsCfgPathNormalized = "TRUE"
EOF
echo "AÑADIDA"
