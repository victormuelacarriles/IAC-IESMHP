#!/usr/bin/env bash
#
# MapeaOneDriveVictorSSH.sh
#
# Monta el OneDrive de la VM Windows 11 (10.0.72.160) en /home/vmuela/OneDrive
# por SFTP (OpenSSH de Windows), usando la clave SSH del perfil
# (~/.ssh/id_ed25519). Ya NO usa la carpeta compartida SMB de W11.
#
#   Origen:  sftp://10.0.72.160/E:/Usuarios/vmuela/OneDrive - Educantabria
#   Destino: /home/vmuela/OneDrive
#
# Lógica:
#   1. Si la VM no responde por SSH (puerto 22), no hace nada.
#   2. Si ya está montado por SFTP y responde, no hace nada.
#   3. Si está montado por otra vía (el antiguo montaje SMB de rclone,
#      o un montaje SFTP colgado), lo desmonta.
#   4. Monta con "rclone mount" (backend sftp).
#
# Por qué rclone mount (FUSE de usuario):
#  - No requiere sudo.
#  - Sin --allow-other/--allow-root (no los usamos) nadie más que el usuario
#    que montó puede acceder, ni siquiera root (comportamiento por defecto
#    de FUSE, documentado en fuse(8)).
#
# Sin contraseñas: la autenticación es solo con la clave SSH. El remoto de
# rclone se define con variables de entorno (RCLONE_CONFIG_<NOMBRE>_*), así
# que no se escribe ningún fichero de configuración en disco.
# (Los ficheros ~/.config/vmuela-mount/mount.key y mount.pass.enc del
#  montaje SMB anterior ya no se usan.)
#
# Uso: lo lanza cron cada minuto (crontab -e del usuario):
#   * * * * * /home/vmuela/CopiaGitHub/IAC-IESMHP/Ubuntu/ISO/26.04/utiles/OneDriveAW11/MapeaOneDriveVictorSSH.sh
#   (apunta al script del repo: un git pull que lo cambie afecta a cron)
#
# Requisito (una sola vez): sudo apt install rclone fuse3
# La huella del servidor debe estar en ~/.ssh/known_hosts (basta con haber
# hecho "ssh vmuela@10.0.72.160" una vez a mano).

set -euo pipefail

# --- Configuración: ajusta estos valores ---
VM_IP="10.0.72.160"
SSH_PORT="22"
SSH_USER="vmuela"
SSH_KEY="$HOME/.ssh/id_ed25519"
KNOWN_HOSTS="$HOME/.ssh/known_hosts"
REMOTE_PATH="/E:/Usuarios/vmuela/OneDrive - Educantabria"
FINAL_PATH="/home/vmuela/OneDrive"     # punto de montaje final

REMOTE_NAME="onedrivessh"               # solo minúsculas/números (ver env)
LOG_FILE="$HOME/.cache/MapeaOneDriveVictorSSH.log"

mkdir -p "$(dirname "$LOG_FILE")"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
# Mensajes de "no hay nada que hacer": solo en terminal, no al log
# (cron lo lanza cada minuto y llenaría el log / el correo de cron).
info() { [[ -t 1 ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; return 0; }

# --- 0. Comprobaciones previas ---
if ! command -v rclone > /dev/null 2>&1; then
    log "ERROR: rclone no está instalado. Ejecuta: sudo apt install rclone"
    exit 1
fi
if [[ ! -f "$SSH_KEY" ]]; then
    log "ERROR: no existe la clave SSH $SSH_KEY"
    exit 1
fi
FUSERMOUNT="$(command -v fusermount3 || command -v fusermount || true)"
if [[ -z "$FUSERMOUNT" ]]; then
    log "ERROR: falta fusermount. Ejecuta: sudo apt install fuse3"
    exit 1
fi

# --- 1. ¿Está la VM accesible por SSH? ---
if ! timeout 3 bash -c "</dev/tcp/$VM_IP/$SSH_PORT" 2>/dev/null; then
    info "La VM ($VM_IP:$SSH_PORT) no responde por SSH. No se hace nada."
    exit 0
fi

# --- 2. ¿Qué hay montado ahora en el destino? ---
mkdir -p "$FINAL_PATH"
CUR_SOURCE="$(findmnt -n -o SOURCE --mountpoint "$FINAL_PATH" 2>/dev/null || true)"

if [[ -n "$CUR_SOURCE" ]]; then
    # rclone puede añadir un sufijo al nombre: "onedrivessh{hYZNR}:/E:/..."
    if [[ "$CUR_SOURCE" == "${REMOTE_NAME}"[:{]* ]] && timeout 10 ls "$FINAL_PATH" > /dev/null 2>&1; then
        info "$FINAL_PATH ya está montado por SSH ($CUR_SOURCE)."
        exit 0
    fi

    # --- 3. Montado por otra vía (SMB antiguo) o SFTP colgado: desmontar ---
    log "Desmontando montaje anterior: $CUR_SOURCE"
    if ! "$FUSERMOUNT" -u "$FINAL_PATH" 2>/dev/null; then
        log "Desmontaje normal fallido (¿ocupado?); se fuerza desmontaje diferido."
        if ! "$FUSERMOUNT" -uz "$FINAL_PATH" 2>/dev/null; then
            log "ERROR: no se pudo desmontar $FINAL_PATH."
            log "Si es un montaje de kernel (cifs), ejecuta: sudo umount $FINAL_PATH"
            exit 1
        fi
    fi
    # Esperar a que desaparezca el montaje
    for _ in {1..10}; do
        mountpoint -q "$FINAL_PATH" 2>/dev/null || break
        sleep 1
    done
fi

# --- 4. Definir el remoto SFTP por variables de entorno (sin fichero) ---
ENV_PREFIX="RCLONE_CONFIG_${REMOTE_NAME^^}"
export "${ENV_PREFIX}_TYPE=sftp"
export "${ENV_PREFIX}_HOST=$VM_IP"
export "${ENV_PREFIX}_PORT=$SSH_PORT"
export "${ENV_PREFIX}_USER=$SSH_USER"
export "${ENV_PREFIX}_KEY_FILE=$SSH_KEY"
export "${ENV_PREFIX}_KNOWN_HOSTS_FILE=$KNOWN_HOSTS"
export "${ENV_PREFIX}_SHELL_TYPE=cmd"           # OpenSSH de Windows
export "${ENV_PREFIX}_DISABLE_HASHCHECK=true"   # sin md5sum/sha1sum en Windows

# --- 5. Montar (FUSE, sin sudo; sin allow-other/allow-root => solo este usuario) ---
if rclone mount "${REMOTE_NAME}:${REMOTE_PATH}" "$FINAL_PATH" \
    --config="" \
    --daemon \
    --vfs-cache-mode=writes \
    --dir-cache-time=30s \
    --log-file="$LOG_FILE" --log-level=NOTICE; then
    # rclone --daemon puede volver antes de que el montaje esté listo
    for _ in {1..15}; do
        mountpoint -q "$FINAL_PATH" 2>/dev/null && break
        sleep 1
    done
fi

if mountpoint -q "$FINAL_PATH" 2>/dev/null; then
    log "Montado por SSH en $FINAL_PATH"
else
    log "ERROR al montar con rclone (sftp). Revisa $LOG_FILE"
    exit 1
fi
