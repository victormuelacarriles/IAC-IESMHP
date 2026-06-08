#!/usr/bin/env bash
#
# 0-ConfiguracionInicial.sh
# -------------------------------------------------------------------
# Configuración inicial de CADA usuario (se ejecuta COMO el usuario,
# NO como root). Forma parte de la carpeta `rolesUsuario`.
#
# Qué hace:
#   1. Asegura que el usuario tiene un par de claves SSH ed25519
#      (~/.ssh/id_ed25519). Si no existe, lo crea sin passphrase.
#   2. Asegura que el usuario puede conectarse a SÍ MISMO con esa
#      clave: añade su clave pública a ~/.ssh/authorized_keys y
#      registra el host en ~/.ssh/known_hosts.
#   3. Verifica la conexión (ssh localhost "exit 0").
#
# Idempotente: relanzarlo no rompe nada ni duplica entradas.
#
# Uso:
#   bash 0-ConfiguracionInicial.sh          # como el usuario actual
# -------------------------------------------------------------------
set -u

# ---- No ejecutar como root -----------------------------------------
if [ "$(id -u)" -eq 0 ]; then
    echo "[ERR] Este script debe ejecutarse como el USUARIO, no como root." >&2
    echo "      (configura el ~/.ssh del usuario que lo lanza)." >&2
    exit 1
fi

USUARIO="$(id -un)"
HOME_DIR="${HOME:-/home/$USUARIO}"
SSH_DIR="$HOME_DIR/.ssh"
CLAVE_PRIV="$SSH_DIR/id_ed25519"
CLAVE_PUB="$CLAVE_PRIV.pub"
AUTH_KEYS="$SSH_DIR/authorized_keys"
KNOWN="$SSH_DIR/known_hosts"

log()  { echo "[INFO] $*"; }
ok()   { echo "[OK]   $*"; }
warn() { echo "[WARN] $*" >&2; }
err()  { echo "[ERR]  $*" >&2; }

log "Configuración inicial para el usuario '$USUARIO' (home: $HOME_DIR)"

# ---- 1. Directorio ~/.ssh ------------------------------------------
GRUPO="$(id -gn)"

if [ ! -d "$SSH_DIR" ]; then
    if ! mkdir -p "$SSH_DIR" 2>/dev/null; then
        # El home puede pertenecer a root; intentamos crearlo con sudo.
        warn "No se pudo crear $SSH_DIR como usuario; reintentando con sudo…"
        sudo mkdir -p "$SSH_DIR" && sudo chown "$USUARIO:$GRUPO" "$SSH_DIR" \
            || { err "No se pudo crear $SSH_DIR."; exit 1; }
    fi
    log "Creado $SSH_DIR"
fi

# Asegurar que el USUARIO es propietario de ~/.ssh y de su contenido.
# En equipos ya provisionados, authorized_keys/.ssh pueden haber quedado
# como root:root (el instalador escribió las claves como root sin chown),
# y entonces el usuario no puede ni hacer chmod ni escribir su clave.
NEEDFIX=0
[ -e "$SSH_DIR" ]   && [ ! -O "$SSH_DIR" ]   && NEEDFIX=1
[ -e "$AUTH_KEYS" ] && [ ! -O "$AUTH_KEYS" ] && NEEDFIX=1
if [ "$NEEDFIX" -eq 1 ]; then
    warn "$SSH_DIR no pertenece a '$USUARIO' (seguramente root). Corrigiendo propiedad…"
    if command -v sudo >/dev/null 2>&1; then
        if sudo chown -R "$USUARIO:$GRUPO" "$SSH_DIR"; then
            ok "Propiedad de $SSH_DIR reasignada a $USUARIO:$GRUPO (contenido intacto)."
        else
            err "No se pudo cambiar la propiedad de $SSH_DIR."
            err "Hazlo manualmente:  sudo chown -R $USUARIO:$GRUPO $SSH_DIR"
            exit 1
        fi
    else
        err "Falta 'sudo' y $SSH_DIR no es tuyo. Pide a un administrador:"
        err "  chown -R $USUARIO:$GRUPO $SSH_DIR"
        exit 1
    fi
fi

chmod 700 "$SSH_DIR"

# ---- 2. Par de claves ed25519 --------------------------------------
if [ -f "$CLAVE_PRIV" ]; then
    ok "Ya existe la clave privada ($CLAVE_PRIV); no se regenera."
else
    log "No existe clave; generando par ed25519 sin passphrase…"
    if ssh-keygen -t ed25519 -C "$USUARIO@$(hostname)" -f "$CLAVE_PRIV" -N "" >/dev/null; then
        ok "Clave generada: $CLAVE_PRIV"
    else
        err "Fallo al generar la clave SSH."
        exit 1
    fi
fi
chmod 600 "$CLAVE_PRIV" 2>/dev/null || true
chmod 644 "$CLAVE_PUB"  2>/dev/null || true

# ---- 3. authorized_keys (login a sí mismo) -------------------------
PUB_CONTENT="$(cat "$CLAVE_PUB")"
touch "$AUTH_KEYS"
chmod 600 "$AUTH_KEYS"
if grep -qF "$PUB_CONTENT" "$AUTH_KEYS" 2>/dev/null; then
    ok "La clave pública ya está en authorized_keys."
else
    printf '%s\n' "$PUB_CONTENT" >> "$AUTH_KEYS"
    ok "Clave pública añadida a authorized_keys."
fi

# ---- 4. known_hosts: registrar localhost ---------------------------
touch "$KNOWN"
chmod 644 "$KNOWN"
for destino in localhost 127.0.0.1 "$(hostname)"; do
    [ -z "$destino" ] && continue
    if ssh-keygen -F "$destino" >/dev/null 2>&1; then
        continue   # ya está en known_hosts
    fi
    if ssh-keyscan -t ed25519,rsa "$destino" 2>/dev/null >> "$KNOWN"; then
        log "Host '$destino' añadido a known_hosts."
    else
        warn "No se pudo escanear '$destino' (¿servicio ssh no arrancado?)."
    fi
done

# ---- 5. Verificar conexión a sí mismo ------------------------------
log "Verificando conexión SSH a localhost…"
if ssh -o BatchMode=yes \
       -o StrictHostKeyChecking=accept-new \
       -o ConnectTimeout=5 \
       -i "$CLAVE_PRIV" \
       localhost "exit 0" 2>/dev/null; then
    ok "Conexión a sí mismo correcta (ssh localhost)."
    echo "Correcto"
    exit 0
else
    warn "No se pudo conectar por SSH a localhost con la clave."
    warn "Causas habituales: el servicio 'ssh' (sshd) no está instalado o"
    warn "no está arrancado en este equipo. La clave y authorized_keys SÍ"
    warn "quedaron configurados; la conexión funcionará cuando sshd esté activo."
    exit 2
fi
