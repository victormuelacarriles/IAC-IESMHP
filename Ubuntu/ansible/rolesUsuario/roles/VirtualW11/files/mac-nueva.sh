#!/bin/bash
# Si una tarjeta de red de la copia tiene la MISMA MAC que en la plantilla, le
# pone una MAC nueva aleatoria del rango estático de VMware
# (00:50:56:00:00:00 - 00:50:56:3F:FF:FF).
#
# Uso: mac-nueva.sh <vmx plantilla> <vmx copia>
# Salida: una línea por tarjeta cambiada ("CAMBIADA ethernet0 vieja -> nueva")
#         o "SIN CAMBIOS" (Ansible lo usa para changed_when).
set -euo pipefail

PLANTILLA="$1"
COPIA="$2"

# MAC de una tarjeta en un .vmx: la estática (address) o la generada.
mac_de() {   # <vmx> <ethernetN>
    sed -nE "s/^$2\.(address|generatedAddress)[[:space:]]*=[[:space:]]*\"([^\"]+)\".*/\2/p" "$1" \
        | head -1 | tr 'A-F' 'a-f'
}

mac_aleatoria() {
    local b
    read -r -a b < <(od -An -N3 -tu1 /dev/urandom)
    printf '00:50:56:%02x:%02x:%02x' $(( b[0] % 64 )) "${b[1]}" "${b[2]}"
}

CAMBIOS=0
for nic in $(sed -nE 's/^(ethernet[0-9]+)\.present[[:space:]]*=.*/\1/p' "$COPIA" | sort -u); do
    actual=$(mac_de "$COPIA" "$nic")
    origen=$(mac_de "$PLANTILLA" "$nic")
    [ -n "$actual" ] && [ "$actual" = "$origen" ] || continue

    nueva=$(mac_aleatoria)
    while [ "$nueva" = "$origen" ]; do nueva=$(mac_aleatoria); done

    # Quita la MAC generada y la anterior, y fija la nueva como estática.
    sed -i -E "/^$nic\.(addressType|address|generatedAddress|generatedAddressOffset)[[:space:]]*=/d" "$COPIA"
    printf '%s.addressType = "static"\n%s.address = "%s"\n' "$nic" "$nic" "$nueva" >> "$COPIA"
    echo "CAMBIADA $nic $actual -> $nueva"
    CAMBIOS=1
done

[ "$CAMBIOS" = 1 ] || echo "SIN CAMBIOS"
