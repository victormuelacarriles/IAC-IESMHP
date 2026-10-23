#!/bin/bash
# Crea, si no existe, un perfil RDP de Remmina (lanzador) para la máquina
# virtual, con el usuario y la IP de destino. SIN contraseña: la guardará el
# propio usuario la primera vez que conecte. Se ejecuta como el usuario.
#
# Uso: remmina-perfil.sh <nombre> <servidor> <usuario>
# Salida: "CREADO <fichero>", "YA EXISTE <fichero>" o
#         "ACTUALIZADO <fichero> (servidor viejo -> nuevo)".
#
# Si ya hay un perfil con ese nombre no se toca, salvo la IP del servidor si
# ha cambiado (la máquina puede haber pasado de DHCP a estática).
set -euo pipefail

NOMBRE="$1"; SERVIDOR="$2"; USUARIO="$3"

PREF="$HOME/.config/remmina/remmina.pref"
DATADIR=$(sed -n 's/^datadir_path=//p' "$PREF" 2>/dev/null | head -1 || true)
DATADIR="${DATADIR:-$HOME/.local/share/remmina}"
mkdir -p "$DATADIR"

# ¿Ya hay un perfil con este nombre?
EXISTE=$(grep -lx "name=$NOMBRE" "$DATADIR"/*.remmina 2>/dev/null | head -1 || true)
if [ -n "$EXISTE" ]; then
    VIEJO=$(sed -n 's/^server=//p' "$EXISTE" | head -1)
    if [ "$VIEJO" != "$SERVIDOR" ]; then
        sed -i "s|^server=.*|server=$SERVIDOR|" "$EXISTE"
        echo "ACTUALIZADO $EXISTE ($VIEJO -> $SERVIDOR)"
    else
        echo "YA EXISTE $EXISTE"
    fi
    exit 0
fi

F="$DATADIR/group_rdp_$(printf '%s' "$NOMBRE" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9-' '-')_$(printf '%s' "$SERVIDOR" | tr '.' '-').remmina"
umask 077
cat > "$F" <<EOF
[remmina]
name=$NOMBRE
protocol=RDP
server=$SERVIDOR
username=$USUARIO
password=
domain=
group=
colordepth=99
quality=0
resolution_mode=2
scale=2
viewmode=1
window_maximize=1
ignore-tls-errors=1
cert_ignore=0
sound=off
disableclipboard=0
disablepasswordstoring=0
enable-autostart=0
EOF
echo "CREADO $F"
