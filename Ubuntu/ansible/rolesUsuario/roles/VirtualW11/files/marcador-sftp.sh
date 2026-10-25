#!/bin/bash
# Marcador en el gestor de archivos (Nautilus/GTK) del usuario del equipo
# físico que abre por SFTP el perfil de Windows de su máquina virtual:
#   sftp://<usuario>@<ip>/C:/Users/<usuario>   con el nombre <nombre>
# y la clave de host de la máquina en ~/.ssh/known_hosts (si no, la primera vez
# Nautilus pregunta si se fía del equipo).
#
# Uso: marcador-sftp.sh <nombre> <usuario> <ip>
# Salida (1ª línea): CREADO / ACTUALIZADO / YA EXISTE + fichero.
set -u
NOMBRE="$1"; U="$2"; IP="$3"
F="$HOME/.config/gtk-3.0/bookmarks"
URL="sftp://$U@$IP/C:/Users/$U"

mkdir -p "$(dirname "$F")"
touch "$F"
if grep -qxF "$URL $NOMBRE" "$F"; then
    echo "YA EXISTE $NOMBRE → $URL ($F)"
elif grep -qE " $NOMBRE\$" "$F"; then
    # Mismo nombre con otra dirección (cambió la IP): se sustituye.
    t=$(mktemp)
    awk -v n=" $NOMBRE" -v l="$URL $NOMBRE" '
        substr($0, length($0) - length(n) + 1) == n { print l; next } { print }' "$F" > "$t"
    cat "$t" > "$F"; rm -f "$t"
    echo "ACTUALIZADO $NOMBRE → $URL ($F)"
else
    echo "$URL $NOMBRE" >> "$F"
    echo "CREADO $NOMBRE → $URL ($F)"
fi

# Clave de host: se renueva si cambió (máquina recopiada) o no estaba.
mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
K="$HOME/.ssh/known_hosts"
nuevas=$(ssh-keyscan -T 5 -t ed25519,ecdsa,rsa "$IP" 2>/dev/null | grep -v "^#")
if [ -z "$nuevas" ]; then
    echo "Clave de host: no se pudo leer de $IP (Nautilus preguntará la primera vez)"
elif [ -f "$K" ] && [ -z "$(comm -23 <(awk '{print $2, $3}' <<<"$nuevas" | sort) \
        <(ssh-keygen -F "$IP" -f "$K" 2>/dev/null | awk '!/^#/ {print $2, $3}' | sort))" ]; then
    # Todas las claves que da ahora la máquina ya están (vale con known_hosts
    # con nombres cifrados, HashKnownHosts).
    echo "Clave de host: ya estaba en $K"
else
    ssh-keygen -R "$IP" -f "$K" >/dev/null 2>&1
    echo "$nuevas" >> "$K"
    chmod 600 "$K"
    echo "Clave de host: añadida a $K"
fi
exit 0
