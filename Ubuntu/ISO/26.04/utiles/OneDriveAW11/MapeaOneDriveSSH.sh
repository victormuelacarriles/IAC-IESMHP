#!/usr/bin/env bash
#
# MapeaOneDriveSSH.sh
#
# Monta en Linux una carpeta de un equipo Windows (típicamente el OneDrive de
# una VM W11) por SFTP (OpenSSH de Windows), autenticando con la clave SSH del
# usuario. No usa carpetas compartidas SMB ni contraseñas.
#
# Configuración: ~/.config/IAC-IESMHP/MapeaOneDriveSSH.env (en el perfil del
# usuario, nunca junto al script, que puede estar en una carpeta de solo
# lectura como /opt/IAC-IESMHP). Lleva un comentario con quién lo generó,
# desde qué script y equipo, y cuándo.
#
# Modos de ejecución:
#   - A mano, sin parámetros: si existe el .env, enseña los valores y pregunta
#     si valen; si no valen o no hay .env, los pregunta uno a uno.
#   - Con parámetros (--equipo, --remota...): los guarda en el .env sin
#     preguntar (solo pregunta los obligatorios que falten).
#   - --configurar: vuelve a preguntar todo (propone los valores guardados).
#   - --desatendido: NUNCA pregunta; usa el .env. Es el modo de cron.
#     Sin terminal (cron, ssh sin -t) se comporta igual aunque no se indique.
#   - --desconfigura: quita la línea del crontab y desmonta. Conserva el .env;
#     para reactivarlo basta con volver a ejecutarlo sin ese parámetro.
#
# Ejemplos:
#   ./MapeaOneDriveSSH.sh
#   ./MapeaOneDriveSSH.sh --equipo 10.0.72.160 --usuario vmuela \
#       --remota "/E:/Usuarios/vmuela/OneDrive - Educantabria" --montaje ~/OneDrive
#   ./MapeaOneDriveSSH.sh --remota "sftp://10.0.72.160/E:/Usuarios/vmuela/OneDrive%20-%20Educantabria"
#
# Lógica en cada ejecución:
#   0. Se autoregistra en el crontab del usuario:
#        * * * * * /ruta/real/MapeaOneDriveSSH.sh --desatendido
#   1. Si el equipo no responde por SSH (Windows apagado), desmonta la
#      carpeta (matando el rclone que la sirve) para que no se cuelgue el
#      escritorio; si no estaba montada, no hace nada.
#   2. Si ya está montado por SFTP con esa ruta y responde, no hace nada.
#   3. Si está montado por otra vía (p. ej. un montaje SMB) o colgado, lo desmonta.
#   4. Monta con "rclone mount" (backend sftp, FUSE de usuario, sin sudo).
#      Sin --allow-other/--allow-root: solo el usuario que monta tiene acceso,
#      ni siquiera root (comportamiento por defecto de FUSE, ver fuse(8)).
#
# Requisitos: sudo apt install rclone fuse3
# La clave debe estar autorizada en Windows y la huella del equipo en
# ~/.ssh/known_hosts (basta con hacer "ssh usuario@equipo" una vez a mano).

set -euo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
SELF_BASE="$(basename "$SELF" .sh)"
USUARIO_LOCAL="$(id -un)"

LOG_FILE="$HOME/.cache/$SELF_BASE.log"
mkdir -p "$(dirname "$LOG_FILE")"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
# Mensajes de "no hay nada que hacer": solo en terminal, no al log
# (cron lo lanza cada minuto y llenaría el log / el correo de cron).
info() { [[ -t 1 ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; return 0; }

uso() {
    cat <<FIN
Uso: $(basename "$SELF") [opciones]

  -e, --equipo IP       Equipo Windows (IP o nombre)
  -p, --puerto N        Puerto SSH (por defecto 22)
  -u, --usuario U       Usuario SSH en Windows (por defecto $USUARIO_LOCAL)
  -k, --clave FICHERO   Clave privada SSH (por defecto ~/.ssh/id_ed25519)
  -r, --remota RUTA     Carpeta remota, p. ej. "/E:/Usuarios/U/OneDrive - Empresa"
                        (también vale una URL sftp://equipo/E:/...)
  -m, --montaje DIR     Carpeta local donde montar (por defecto ~/OneDrive)
  -c, --configurar      Volver a preguntar todos los valores
  -d, --desatendido     No preguntar nada; usar la configuración guardada (cron)
      --desconfigura    Quitar la línea del crontab y desmontar (conserva el .env)
  -h, --ayuda           Esta ayuda

Configuración guardada en: $ENV_FILE
FIN
}

# Nombre del remoto de rclone (solo minúsculas/números, se usa en variables de entorno)
REMOTE_NAME="onedrivessh"
FUSERMOUNT="$(command -v fusermount3 || command -v fusermount || true)"

# --- Utilidades de montaje ---
# Ojo: con el equipo apagado, cualquier acceso a la carpeta montada (stat, ls,
# mountpoint -q...) se queda colgado. Por eso se usa findmnt, que solo lee
# /proc/self/mountinfo y nunca toca el sistema de ficheros montado.
origen_montaje() { findmnt -n -o SOURCE --mountpoint "$1" 2>/dev/null || true; }
montado()        { [[ -n "$(origen_montaje "$1")" ]]; }
es_nuestro()     { [[ "$(origen_montaje "$1")" == "${REMOTE_NAME}"[:{]* ]]; }

# PIDs de los rclone de este usuario que sirven el montaje $1
pids_rclone() {
    local pid arg
    for pid in $(pgrep -u "$(id -u)" -x rclone 2>/dev/null); do
        while IFS= read -r -d '' arg; do
            [[ "$arg" == "$1" ]] && { echo "$pid"; break; }
        done < "/proc/$pid/cmdline" 2>/dev/null || true
    done
}

# Desmonta $1 aunque esté colgado: primero mata el rclone que lo sirve (así el
# kernel corta la conexión FUSE y los programas que esperaban, como Archivos,
# reciben un error en vez de quedarse bloqueados) y después desmonta.
desmonta() {
    local punto="$1" pids
    pids="$(pids_rclone "$punto")"
    if [[ -n "$pids" ]]; then
        # shellcheck disable=SC2086
        kill $pids 2>/dev/null || true
        for _ in {1..5}; do
            pids="$(pids_rclone "$punto")"; [[ -z "$pids" ]] && break; sleep 1
        done
        # shellcheck disable=SC2086
        [[ -n "$pids" ]] && { kill -9 $pids 2>/dev/null || true; }
    fi
    if montado "$punto"; then
        "$FUSERMOUNT" -u "$punto" 2>/dev/null || "$FUSERMOUNT" -uz "$punto" 2>/dev/null || true
    fi
    for _ in {1..10}; do montado "$punto" || return 0; sleep 1; done
    return 1
}

# --- Fichero .env: SIEMPRE en el perfil del usuario ---
ENV_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/IAC-IESMHP/$SELF_BASE.env"

# Valores guardados (si los hay)
VM_IP="" SSH_PORT="" SSH_USER="" SSH_KEY="" REMOTE_PATH="" FINAL_PATH=""
# shellcheck disable=SC1090
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"
MONTAJE_ANTERIOR="${FINAL_PATH/#\~/$HOME}"   # para desmontarlo si se cambia

# --- Parámetros ---
HAY_VALORES=0      # se pasó algún valor de configuración
CONFIGURAR=0
DESATENDIDO=0
DESCONFIGURA=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        -e|--equipo)      VM_IP="${2:?Falta el valor de $1}";       HAY_VALORES=1; shift ;;
        -p|--puerto)      SSH_PORT="${2:?Falta el valor de $1}";    HAY_VALORES=1; shift ;;
        -u|--usuario)     SSH_USER="${2:?Falta el valor de $1}";    HAY_VALORES=1; shift ;;
        -k|--clave)       SSH_KEY="${2:?Falta el valor de $1}";     HAY_VALORES=1; shift ;;
        -r|--remota)      REMOTE_PATH="${2:?Falta el valor de $1}"; HAY_VALORES=1; shift ;;
        -m|--montaje)     FINAL_PATH="${2:?Falta el valor de $1}";  HAY_VALORES=1; shift ;;
        -c|--configurar)  CONFIGURAR=1 ;;
        -d|--desatendido) DESATENDIDO=1 ;;
        --desconfigura)   DESCONFIGURA=1 ;;
        -h|--ayuda)       uso; exit 0 ;;
        *) echo "Opción desconocida: $1" >&2; uso >&2; exit 2 ;;
    esac
    shift
done

# --- --desconfigura: quitar del crontab y desmontar, sin preguntar nada ---
if [[ $DESCONFIGURA -eq 1 ]]; then
    if command -v crontab > /dev/null 2>&1; then
        CRON_ACTUAL="$(crontab -l 2>/dev/null || true)"
        PATRON="^[[:space:]]*[^#].*/$(basename "$SELF" | sed 's/\./\\./g')([[:space:]]|$)"
        if grep -qE "$PATRON" <<< "$CRON_ACTUAL"; then
            { grep -vE "$PATRON" <<< "$CRON_ACTUAL" || true; } | crontab -
            log "Quitado del crontab de $USUARIO_LOCAL."
        else
            log "No estaba en el crontab de $USUARIO_LOCAL."
        fi
    fi
    PUNTO="${FINAL_PATH:-$HOME/OneDrive}"; PUNTO="${PUNTO/#\~/$HOME}"
    if es_nuestro "$PUNTO"; then
        if desmonta "$PUNTO"; then
            log "Desmontado $PUNTO."
        else
            log "ERROR: no se pudo desmontar $PUNTO."
            exit 1
        fi
    else
        log "$PUNTO no estaba montado por este script."
    fi
    [[ -f "$ENV_FILE" ]] && log "Se conserva la configuración en $ENV_FILE (bórrala a mano si no la quieres)."
    log "Para volver a activarlo, ejecuta el script sin --desconfigura."
    exit 0
fi

# Sin terminal (cron, ssh sin -t...) nunca se pregunta: modo desatendido
if ! { : < /dev/tty; } 2>/dev/null; then
    DESATENDIDO=1
fi
if [[ $DESATENDIDO -eq 1 && $CONFIGURAR -eq 1 ]]; then
    log "ERROR: --configurar necesita un terminal (no se puede en modo desatendido)."
    exit 2
fi

# Acepta la carpeta remota como URL: sftp://[usuario@]equipo[:puerto]/E:/ruta%20con%20espacios
# (los datos de la URL rellenan equipo/usuario/puerto si aún están vacíos)
analiza_url() {
    [[ "$REMOTE_PATH" == sftp://* ]] || return 0
    local url autoridad ruta
    url="${REMOTE_PATH#sftp://}"
    autoridad="${url%%/*}"
    ruta="/${url#*/}"
    REMOTE_PATH="$(printf '%b' "${ruta//%/\\x}")"   # decodifica %20, etc.
    if [[ "$autoridad" == *@* ]]; then
        [[ -z "$SSH_USER" ]] && SSH_USER="${autoridad%%@*}"
        autoridad="${autoridad#*@}"
    fi
    if [[ "$autoridad" == *:* ]]; then
        [[ -z "$SSH_PORT" ]] && SSH_PORT="${autoridad##*:}"
        autoridad="${autoridad%%:*}"
    fi
    [[ -z "$VM_IP" ]] && VM_IP="$autoridad"
    return 0
}
analiza_url

clave_por_defecto() {
    local k
    for k in "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_ecdsa" "$HOME/.ssh/id_rsa"; do
        [[ -f "$k" ]] && { echo "$k"; return; }
    done
    echo "$HOME/.ssh/id_ed25519"
}

# Rellena los opcionales vacíos y normaliza rutas
completa_valores() {
    SSH_PORT="${SSH_PORT:-22}"
    SSH_USER="${SSH_USER:-$USUARIO_LOCAL}"
    SSH_KEY="${SSH_KEY:-$(clave_por_defecto)}"
    FINAL_PATH="${FINAL_PATH:-$HOME/OneDrive}"
    SSH_KEY="${SSH_KEY/#\~/$HOME}"
    FINAL_PATH="${FINAL_PATH/#\~/$HOME}"
    if [[ -n "$REMOTE_PATH" ]]; then
        REMOTE_PATH="${REMOTE_PATH%/}"
        [[ "$REMOTE_PATH" == /* ]] || REMOTE_PATH="/$REMOTE_PATH"   # "E:/..." -> "/E:/..."
    fi
}

pregunta() {   # pregunta VARIABLE "Texto" "valor propuesto"
    local var="$1" texto="$2" propuesto="$3" resp=""
    while :; do
        read -r -p "$texto${propuesto:+ [$propuesto]}: " resp < /dev/tty || exit 1
        resp="${resp:-$propuesto}"
        [[ -n "$resp" ]] && break
        echo "  Este valor es obligatorio." > /dev/tty
    done
    printf -v "$var" '%s' "$resp"
}

pregunta_todo() {
    echo "Configuración de $(basename "$SELF") (Intro = valor entre corchetes)" > /dev/tty
    pregunta VM_IP       "Equipo Windows (IP o nombre)"     "$VM_IP"
    pregunta SSH_PORT    "Puerto SSH"                       "${SSH_PORT:-22}"
    pregunta SSH_USER    "Usuario SSH en Windows"           "${SSH_USER:-$USUARIO_LOCAL}"
    pregunta SSH_KEY     "Clave privada SSH"                "${SSH_KEY:-$(clave_por_defecto)}"
    pregunta REMOTE_PATH "Carpeta remota (p. ej. /E:/Usuarios/$USUARIO_LOCAL/OneDrive - Educantabria)" "$REMOTE_PATH"
    pregunta FINAL_PATH  "Carpeta local de montaje"         "${FINAL_PATH:-$HOME/OneDrive}"
    analiza_url      # por si se pegó una URL sftp:// al preguntar
}

muestra_valores() {
    cat > /dev/tty <<FIN
Configuración encontrada en $ENV_FILE:
  Equipo Windows .......: $VM_IP
  Puerto SSH ...........: $SSH_PORT
  Usuario SSH ..........: $SSH_USER
  Clave privada SSH ....: $SSH_KEY
  Carpeta remota .......: $REMOTE_PATH
  Carpeta de montaje ...: $FINAL_PATH
FIN
}

# --- Decidir si preguntar ---
GUARDAR=$HAY_VALORES
if [[ $DESATENDIDO -eq 1 ]]; then
    : # nunca se pregunta
elif [[ $CONFIGURAR -eq 1 ]]; then
    pregunta_todo; GUARDAR=1
elif [[ $HAY_VALORES -eq 1 ]]; then
    # Con parámetros solo se pregunta si falta algún obligatorio
    if [[ -z "$VM_IP" || -z "$REMOTE_PATH" ]]; then pregunta_todo; GUARDAR=1; fi
elif [[ -f "$ENV_FILE" ]]; then
    completa_valores
    muestra_valores
    read -r -p "¿Te vale esta configuración? [S/n]: " resp < /dev/tty || exit 1
    if [[ "${resp,,}" == n* ]]; then pregunta_todo; GUARDAR=1; fi
else
    echo "No hay configuración guardada ($ENV_FILE)." > /dev/tty
    pregunta_todo; GUARDAR=1
fi

completa_valores
KNOWN_HOSTS="$HOME/.ssh/known_hosts"

if [[ -z "$VM_IP" || -z "$REMOTE_PATH" ]]; then
    log "ERROR: falta configuración (equipo y/o carpeta remota) en $ENV_FILE."
    log "Ejecuta el script a mano una vez (sin --desatendido) o pásale los parámetros (--ayuda)."
    exit 1
fi

# --- Guardar el .env (en el perfil del usuario) ---
if [[ $GUARDAR -eq 1 ]]; then
    mkdir -p "$(dirname "$ENV_FILE")"
    ( umask 077
      {
          echo "# Configuración de MapeaOneDriveSSH (montaje SFTP de una carpeta de Windows)."
          echo "# Generado por : $SELF"
          echo "# Equipo       : $(hostname)"
          echo "# Usuario      : $USUARIO_LOCAL (uid $(id -u))"
          echo "# Fecha        : $(date '+%Y-%m-%d %H:%M:%S')"
          echo "# Para cambiarlo: $SELF --configurar"
          echo "# Lo usa cron con: $SELF --desatendido"
          echo "# Datos personales: no lo subas a ningún repositorio."
          printf 'VM_IP=%q\n'       "$VM_IP"
          printf 'SSH_PORT=%q\n'    "$SSH_PORT"
          printf 'SSH_USER=%q\n'    "$SSH_USER"
          printf 'SSH_KEY=%q\n'     "$SSH_KEY"
          printf 'REMOTE_PATH=%q\n' "$REMOTE_PATH"
          printf 'FINAL_PATH=%q\n'  "$FINAL_PATH"
      } > "$ENV_FILE" )
    log "Configuración guardada en $ENV_FILE"
fi


# --- 0. Comprobaciones previas ---
if ! command -v rclone > /dev/null 2>&1; then
    log "ERROR: rclone no está instalado. Ejecuta: sudo apt install rclone"
    exit 1
fi
if [[ ! -f "$SSH_KEY" ]]; then
    log "ERROR: no existe la clave SSH $SSH_KEY"
    exit 1
fi
if [[ -z "$FUSERMOUNT" ]]; then
    log "ERROR: falta fusermount. Ejecuta: sudo apt install fuse3"
    exit 1
fi
if command -v ssh-keygen > /dev/null 2>&1; then
    HOST_KH="$VM_IP"; [[ "$SSH_PORT" != 22 ]] && HOST_KH="[$VM_IP]:$SSH_PORT"
    if ! ssh-keygen -F "$HOST_KH" -f "$KNOWN_HOSTS" > /dev/null 2>&1; then
        log "AVISO: $VM_IP no está en $KNOWN_HOSTS; rclone rechazará la conexión."
        log "       Conéctate una vez a mano: ssh -p $SSH_PORT $SSH_USER@$VM_IP"
    fi
fi

# --- 0b. Autoregistro en el crontab del usuario que lo ejecuta ---
# Debe haber una línea que lance ESTE fichero (su ruta real, esté donde esté)
# con --desatendido. Si falta, se añade; las líneas que lanzaban un fichero
# con el mismo nombre en otra ruta o sin --desatendido se sustituyen.
if command -v crontab > /dev/null 2>&1; then
    SELF_CRON="$(printf '%q' "$SELF")"          # escapa espacios para el sh de cron
    CRON_LINE="* * * * * $SELF_CRON --desatendido"
    CRON_ACTUAL="$(crontab -l 2>/dev/null || true)"
    if ! grep -v '^[[:space:]]*#' <<< "$CRON_ACTUAL" \
            | grep -F -e "$SELF" -e "$SELF_CRON" | grep -qE -- '--desatendido([[:space:]]|$)'; then
        SELF_NAME="$(basename "$SELF")"
        {
            # Conserva todo menos las entradas activas de este script en otra ruta
            grep -v -E "^[[:space:]]*[^#].*/${SELF_NAME//./\\.}([[:space:]]|$)" <<< "$CRON_ACTUAL" || true
            echo "$CRON_LINE"
        } | crontab -
        log "Registrado en el crontab de $USUARIO_LOCAL: $CRON_LINE"
    fi
else
    log "AVISO: no existe el comando crontab; no se puede autoregistrar."
fi

# --- 0c. Si se cambió la carpeta de montaje, quitar el montaje anterior (si era nuestro) ---
if [[ -n "$MONTAJE_ANTERIOR" && "$MONTAJE_ANTERIOR" != "$FINAL_PATH" ]] && es_nuestro "$MONTAJE_ANTERIOR"; then
    desmonta "$MONTAJE_ANTERIOR" || true
    log "Desmontado el montaje anterior en $MONTAJE_ANTERIOR (carpeta de montaje cambiada)."
fi

# --- 1. ¿Está el equipo accesible por SSH? ---
# Si no lo está (Windows apagado), se desconecta nuestro montaje para que el
# escritorio no se bloquee al tocar la carpeta.
if ! timeout 3 bash -c "</dev/tcp/$VM_IP/$SSH_PORT" 2>/dev/null; then
    if es_nuestro "$FINAL_PATH"; then
        if desmonta "$FINAL_PATH"; then
            log "El equipo ($VM_IP:$SSH_PORT) no responde: desmontado $FINAL_PATH para evitar bloqueos."
        else
            log "ERROR: el equipo ($VM_IP:$SSH_PORT) no responde y no se pudo desmontar $FINAL_PATH."
        fi
    else
        info "El equipo ($VM_IP:$SSH_PORT) no responde por SSH. No hay nada montado."
    fi
    exit 0
fi

# --- 2. ¿Qué hay montado ahora en el destino? ---
CUR_SOURCE="$(origen_montaje "$FINAL_PATH")"

if [[ -n "$CUR_SOURCE" ]]; then
    # rclone puede añadir un sufijo al nombre: "onedrivessh{hYZNR}:/E:/..."
    if [[ "$CUR_SOURCE" == "${REMOTE_NAME}"[:{]*":$REMOTE_PATH" ]] \
            && timeout 10 ls "$FINAL_PATH" > /dev/null 2>&1; then
        info "$FINAL_PATH ya está montado por SSH ($CUR_SOURCE)."
        exit 0
    fi

    # --- 3. Montado por otra vía (SMB, otra ruta) o colgado: desmontar ---
    log "Desmontando montaje anterior: $CUR_SOURCE"
    if ! desmonta "$FINAL_PATH"; then
        log "ERROR: no se pudo desmontar $FINAL_PATH."
        log "Si es un montaje de kernel (cifs), ejecuta: sudo umount $FINAL_PATH"
        exit 1
    fi
fi
mkdir -p "$FINAL_PATH"

# --- 4. Definir el remoto SFTP por variables de entorno (sin fichero de rclone) ---
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
# --contimeout/--timeout: si Windows se apaga, las operaciones fallan en
# segundos en vez de esperar los 5 min por defecto (hasta que cron desmonte).
if rclone mount "${REMOTE_NAME}:${REMOTE_PATH}" "$FINAL_PATH" \
    --config="" \
    --daemon \
    --vfs-cache-mode=writes \
    --dir-cache-time=30s \
    --contimeout=5s \
    --timeout=30s \
    --log-file="$LOG_FILE" --log-level=NOTICE; then
    # rclone --daemon puede volver antes de que el montaje esté listo
    for _ in {1..15}; do
        montado "$FINAL_PATH" && break
        sleep 1
    done
fi

if es_nuestro "$FINAL_PATH"; then
    log "Montado por SSH: $SSH_USER@$VM_IP:$REMOTE_PATH -> $FINAL_PATH"
else
    log "ERROR al montar con rclone (sftp). Revisa $LOG_FILE"
    if tail -n 5 "$LOG_FILE" | grep -q 'knownhosts: key mismatch'; then
        # rclone (Go) puede negociar un tipo de clave de servidor (ecdsa, rsa)
        # distinto del guardado en known_hosts y lo da como "mismatch".
        log "PISTA: en $KNOWN_HOSTS faltan claves de $VM_IP o han cambiado."
        log "       Comprueba la huella con: ssh -p $SSH_PORT $SSH_USER@$VM_IP"
        log "       y, si es correcta, añade todas sus claves:"
        log "       ssh-keyscan -p $SSH_PORT $VM_IP >> $KNOWN_HOSTS"
    fi
    exit 1
fi
