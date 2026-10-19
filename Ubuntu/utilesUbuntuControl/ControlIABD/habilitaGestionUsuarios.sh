#!/usr/bin/env bash
#
# reparte_clave.sh
# Conecta como root a cada IP, crea ~/.ssh del usuario correspondiente
# y añade la clave pública a su authorized_keys.
#
set -euo pipefail

# Clave pública a instalar
PUBKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJrhNj7QiqWQ1ZmqYRYsq0nLMqlv+NTV8SbFVrQ4wXi2 vmuela@W11-00-VMUELA"

# Mapa IP -> usuario (columna ID de la tabla)
declare -A USUARIOS=(
  [10.0.72.120]="CEGSIABD14"
  [10.0.72.121]="CEGSIABD16"
  [10.0.72.122]="CEGSIABD08"
  [10.0.72.123]="CEGSIABD11"
  [10.0.72.124]="CEGSIABD01"
  [10.0.72.125]="CEGSIABD09"
  [10.0.72.126]="CEGSIABD15"
  [10.0.72.127]="CEGSIABD13"
  [10.0.72.128]="CEGSIABD02"
  [10.0.72.129]="CEGSIABD10"
  [10.0.72.130]="CEGSIABD06"
  [10.0.72.131]="CEGSIABD04"
)

for IP in "${!USUARIOS[@]}"; do
  USER="${USUARIOS[$IP]}"
  echo "==> $IP  (usuario: $USER)"

  # Todo el trabajo remoto en una sola sesión SSH como root.
  # La clave y el usuario se pasan por variables de entorno para no
  # tener problemas de comillas/expansión.
  if ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
         root@"$IP" \
         "USER='$USER' PUBKEY='$PUBKEY' bash -s" <<'REMOTO'
    set -euo pipefail

    # Comprobar que el usuario existe en la máquina
    if ! id "$USER" >/dev/null 2>&1; then
      echo "   ERROR: el usuario $USER no existe en esta máquina" >&2
      exit 1
    fi

    HOME_DIR="$(getent passwd "$USER" | cut -d: -f6)"
    SSH_DIR="$HOME_DIR/.ssh"
    AUTH="$SSH_DIR/authorized_keys"

    mkdir -p "$SSH_DIR"
    touch "$AUTH"

    # Añadir la clave solo si no está ya (evita duplicados)
    if ! grep -qF "$PUBKEY" "$AUTH"; then
      echo "$PUBKEY" >> "$AUTH"
      echo "   clave añadida"
    else
      echo "   clave ya presente, no se duplica"
    fi

    # Permisos y propietario correctos
    chmod 700 "$SSH_DIR"
    chmod 600 "$AUTH"
    chown -R "$USER":"$USER" "$SSH_DIR"
REMOTO
  then
    echo "   OK"
  else
    echo "   FALLO en $IP" >&2
  fi
  echo
done