#!/bin/bash
# Lanzador de Ansible para las aulas: aplica uno o varios roles a equipos
# sueltos, a un aula o a todas, y tiene utilidades rápidas (ping, info, un
# comando suelto, reiniciar o apagar). Al final saca una línea por equipo.
#
# Uso:
#   bash roles.sh ping IABD                      # ping-pong a toda el aula IABD
#   bash roles.sh ping TODAS                     # IABD y SMRD
#   bash roles.sh info SMRD                      # SO, kernel, IP, encendido, RAM, disco...
#   bash roles.sh vscode IABD-05                 # un rol en un equipo
#   bash roles.sh vscode,AWScli IABD-05 SMRD-03  # varios roles en varios equipos
#   bash roles.sh rol certificados SMRD -l 'all:!SMRD-00'
#   bash roles.sh todos IABD -x vmware,nvidia    # roles activos de roles.yaml menos esos
#   bash roles.sh todos IABD-07 --check          # solo dice qué cambiaría
#   bash roles.sh cmd 'df -h /' TODAS            # comando suelto (shell, como root)
#   bash roles.sh reinicia SMRD -l 'all:!SMRD-00'
#   bash roles.sh apaga IABD
#   bash roles.sh lista                          # roles disponibles y si están activos
#   bash roles.sh equipos TODAS                  # equipos de los inventarios (sin conectar)
#   sudo bash roles.sh vscode                    # sin aula ni equipos: en local
#
# Acciones (la primera palabra; si no se pone ninguna: ping):
#   ping              comprueba que Ansible entra por SSH (pong)
#   info              una línea por equipo: Ubuntu, kernel, IP, tiempo encendido,
#                     carga, RAM y disco libre en /, usuarios con sesión
#   cmd 'COMANDO'     ejecuta COMANDO con sh en cada equipo (como root)
#   reinicia          reinicia y espera a que vuelva (solo con aula o equipos)
#   apaga             apaga (solo con aula o equipos)
#   rol R1[,R2...]    aplica esos roles. Vale cualquier carpeta de roles/, también
#                     las que no están activas en roles.yaml. La palabra «rol» se
#                     puede omitir: «roles.sh vscode IABD»
#   todos             todos los roles activos de roles.yaml (como el primer arranque)
#   lista             roles de roles/: activos en roles.yaml (con su orden) o no
#   equipos           equipos de los inventarios elegidos (no se conecta)
#
# Análisis de hardware (rol AnalisisEquipo, prueba típica sin más parámetros):
#   bash roles.sh analisis IABD-05               # un equipo
#   bash roles.sh analisis IABD-05 SMRD-03       # varios equipos
#   bash roles.sh analisis SMRD -l 'all:!SMRD-00'
#   Sistema, CPU, memoria, discos, GPU NVIDIA, estrés (~10 min de CPU+RAM, 5 de
#   GPU) y errores del kernel; resumen por equipo + CSV. Para más opciones (sin
#   estrés, solo kernel panics, minutos de estrés...) usa el script completo:
#     bash roles/AnalisisEquipo/AnalisisEquipo.sh --ayuda
#
# Equipos (se pueden mezclar; sin ninguno: este equipo, en local):
#   IABD | SMRD | SMRV        toda el aula (SMRV usa el inventario de SMRD)
#   TODAS                     IABD y SMRD
#   IABD-05, SMRD-03...       equipos sueltos (el inventario sale del prefijo;
#                             SMRV-03 = SMRD-03)
#   <fichero.ini>             otro inventario
#   -l PATRÓN                 como en ansible (SMRD-0*, 'all:!SMRD-00'). Con un
#                             aula, la limita; con equipos sueltos, se suma
#
# Opciones:
#   -x | --excepto R1[,R2]    quita esos roles (con «todos» o con una lista)
#   --check | -C              no cambia nada (solo roles): dice qué haría
#   --sin-apt-update          no refresca la caché de apt antes de los roles
#   --forks N                 equipos a la vez (20)
#   --timeout N               segundos para conectar por SSH (10)
#   -h | --help | --ayuda
#   El resto de opciones que empiecen por - van a ansible / ansible-playbook
#   (-v, -e var=valor...). Las que llevan valor, como --opción=valor (salvo -e).
#
# Los roles se aplican en el orden de roles.yaml (vmware el último) y después
# los que no están en él, en el orden dado. Si un rol falla en un equipo, se
# anota y ese equipo sigue con el siguiente rol. Los roles con lanzador propio
# (roles/AWScli/AWScli.sh, roles/AnalisisEquipo/AnalisisEquipo.sh) dan un
# resumen más detallado de lo suyo.
#
# Pedagógico: antes de cada ansible / ansible-playbook se enseña en amarillo el
# comando exacto («$ ...», relativo a esta carpeta), listo para copiarlo y
# lanzarlo a mano. Con roles, el playbook generado queda en
# roles-ultimo-playbook.yaml junto al log. Sin color: NO_COLOR=1.
#
# Sin preguntas (headless). Salida completa de Ansible en
# /var/log/IAC-IESMHP/roles.log (o ~/.local/state/IAC-IESMHP/roles.log si no se
# puede escribir allí). Código de salida 1 si algún equipo da ERROR.
set -o pipefail
T0=$(date +%s)

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # Ubuntu/ansible/
ROLESDIR="$DIR/roles"

ACCION=""; CMD=""; ROLES_PED=(); EXCEPTO=(); ARGS=(); LIMITE=""
CHECK=0; APT=1; TIMEOUT=10
FORKS="${FORKS:-20}"
INVENTARIOS=()            # en el orden en que se piden, sin repetir
declare -A COMPLETA=()    # inventario → 1 si se pidió el aula entera
declare -A SUELTOS=()     # inventario → "EQ1,EQ2" (equipos sueltos)

err() { echo "[ERR] $*" >&2; exit 1; }

# Pedagógico: cada ansible / ansible-playbook se enseña antes de lanzarlo, en
# amarillo (si la salida es una terminal y no hay NO_COLOR), tal cual se podría
# copiar y pegar desde esta carpeta. También queda en el log.
AMARILLO=""; NORMAL=""
if [ -t 2 ] && [ -z "$NO_COLOR" ]; then AMARILLO=$'\e[1;33m'; NORMAL=$'\e[0m'; fi
cita() {          # cita ARG... → línea de shell con comillas solo donde hacen falta
    local a out=()
    for a in "$@"; do
        a="${a/#"$DIR"\//}"                      # rutas relativas a esta carpeta
        if [[ "$a" =~ ^[A-Za-z0-9_./:=,@%+-]+$ ]]; then out+=("$a")
        else out+=("'${a//\'/\'\\\'\'}'"); fi
    done
    echo "${out[*]}"
}
muestra() {       # muestra CMD ARG... → «$ comando» en amarillo (a stderr) y al log
    local c; c="$(cita "$@")"
    echo "${AMARILLO}\$ $c${NORMAL}" >&2
    [ -n "$LOG" ] && echo "\$ $c" >> "$LOG"
    return 0
}

anade_inv() {
    local i
    for i in "${INVENTARIOS[@]}"; do [ "$i" = "$1" ] && return; done
    INVENTARIOS+=("$1")
}
inv_aula() {      # inv_aula IABD → ruta del inventario
    case "${1^^}" in
        IABD)      echo "$DIR/equiposIABD.ini" ;;
        SMRD|SMRV) echo "$DIR/equiposSMRD.ini" ;;
        *)         return 1 ;;
    esac
}
rol_real() {      # nombre del rol sin distinguir mayúsculas → nombre de la carpeta
    local d n
    for d in "$ROLESDIR"/*/; do
        n="${d%/}"; n="${n##*/}"
        [ -d "$ROLESDIR/$n/tasks" ] && [ "${n,,}" = "${1,,}" ] && { echo "$n"; return 0; }
    done
    return 1
}
son_roles() {     # son_roles "a,b" → 0 si todos existen
    local t r
    IFS=, read -ra t <<< "$1"
    [ "${#t[@]}" -gt 0 ] || return 1
    for r in "${t[@]}"; do [ -z "$r" ] || rol_real "$r" >/dev/null || return 1; done
}
anade_roles() {   # anade_roles "a,b" ARRAY
    local -n dest="$2"
    local t r real
    IFS=, read -ra t <<< "$1"
    for r in "${t[@]}"; do
        [ -z "$r" ] && continue
        real=$(rol_real "$r") || err "No existe el rol «$r» en $ROLESDIR (ver: bash $0 lista)"
        dest+=("$real")
    done
}

# ---------------------------------------------------------------- argumentos
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help|--ayuda|-\?) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
        -l|--limit)       [ $# -ge 2 ] || err "-l necesita un patrón"; LIMITE="$2"; shift ;;
        --limit=*)        LIMITE="${1#--limit=}" ;;
        -l?*)             LIMITE="${1#-l}" ;;
        -x|--excepto)     [ $# -ge 2 ] || err "$1 necesita roles"; anade_roles "$2" EXCEPTO; shift ;;
        --excepto=*)      anade_roles "${1#*=}" EXCEPTO ;;
        --check|-C)       CHECK=1 ;;
        --sin-apt-update) APT=0 ;;
        --forks)          FORKS="$2"; FORKS_DADO=1; shift ;;
        --forks=*)        FORKS="${1#*=}"; FORKS_DADO=1 ;;
        --timeout)        TIMEOUT="$2"; shift ;;
        --timeout=*)      TIMEOUT="${1#*=}" ;;
        -e|--extra-vars)  [ $# -ge 2 ] || err "$1 necesita un valor"; ARGS+=("$1" "$2"); shift ;;
        -*)               ARGS+=("$1") ;;
        *)
            p="$1"; P="${p^^}"
            if [ -z "$ACCION" ] && [[ "${p,,}" =~ ^(ping|info|cmd|reinicia|apaga|rol|roles|todos|lista|equipos|analisis|análisis)$ ]]; then
                ACCION="${p,,}"; [ "$ACCION" = roles ] && ACCION=rol; [ "$ACCION" = análisis ] && ACCION=analisis
                if [ "$ACCION" = cmd ]; then
                    [ $# -ge 2 ] || err "cmd necesita el comando entre comillas: cmd 'uptime' IABD"
                    CMD="$2"; shift
                elif [ "$ACCION" = rol ]; then
                    [ $# -ge 2 ] || err "rol necesita uno o varios roles: rol vscode,AWScli IABD"
                    anade_roles "$2" ROLES_PED; shift
                fi
            elif [ "$P" = TODAS ]; then
                for a in IABD SMRD; do inv=$(inv_aula $a); anade_inv "$inv"; COMPLETA[$inv]=1; done
            elif inv=$(inv_aula "$p"); then
                anade_inv "$inv"; COMPLETA[$inv]=1
            elif [[ "$P" =~ ^(IABD|SMRD|SMRV)-([0-9]+)$ ]]; then
                inv=$(inv_aula "${BASH_REMATCH[1]}"); anade_inv "$inv"
                eq="${BASH_REMATCH[1]/SMRV/SMRD}-${BASH_REMATCH[2]}"
                SUELTOS[$inv]+="${SUELTOS[$inv]:+,}$eq"
            elif [ -f "$p" ]; then
                inv="$(realpath "$p")"; anade_inv "$inv"; COMPLETA[$inv]=1
            elif { [ -z "$ACCION" ] || [ "$ACCION" = rol ]; } && son_roles "$p"; then
                ACCION=rol; anade_roles "$p" ROLES_PED
            else
                err "No entiendo «$p»: no es una acción, aula, equipo, inventario ni rol (ver: bash $0 --ayuda)"
            fi ;;
    esac
    shift
done
ACCION="${ACCION:-ping}"
cd "$DIR" || exit 1      # los comandos que se enseñan son relativos a esta carpeta

[[ "$FORKS" =~ ^[1-9][0-9]*$ ]]   || err "--forks no válido: '$FORKS'"
[[ "$TIMEOUT" =~ ^[1-9][0-9]*$ ]] || err "--timeout no válido: '$TIMEOUT'"
[ "${#EXCEPTO[@]}" -eq 0 ] || [[ "$ACCION" =~ ^(rol|todos)$ ]] || err "-x solo vale con roles (rol ... o todos)"
[ "$CHECK" -eq 0 ] || [[ "$ACCION" =~ ^(rol|todos)$ ]] || err "--check solo vale con roles (rol ... o todos)"

# Roles activos de roles.yaml, en su orden (líneas «- { role: X ...» sin comentar)
mapfile -t ACTIVOS < <(sed -nE 's/^[[:space:]]*-[[:space:]]*\{[[:space:]]*role:[[:space:]]*([A-Za-z0-9_-]+).*/\1/p' "$DIR/roles.yaml")

# ---------------------------------------------------------------- lista
if [ "$ACCION" = lista ]; then
    echo "Roles de $ROLESDIR (✅ activo en roles.yaml, con su orden; ⛔ no se aplica con «todos»):"
    for d in "$ROLESDIR"/*/; do
        r="${d%/}"; r="${r##*/}"
        [ -d "$ROLESDIR/$r/tasks" ] || continue
        n=0; orden=""
        for a in "${ACTIVOS[@]}"; do n=$((n + 1)); [ "$a" = "$r" ] && orden=$n; done
        # Comentario de su línea en roles.yaml (activa o comentada), si lo hay
        desc=$(grep -E "^[[:space:]]*#?[[:space:]]*-[[:space:]]*\{[[:space:]]*role:[[:space:]]*$r[[:space:]]*," "$DIR/roles.yaml" \
               | head -1 | sed -nE 's/^[^}]*\}[[:space:]]*#[[:space:]]*(.*)/\1/p' | cut -c1-70)
        extra=""
        [ -f "$ROLESDIR/$r/$r.sh" ] && extra=" [lanzador: roles/$r/$r.sh]"
        # Clave de orden delante (activos por su orden; el resto detrás) y se quita
        if [ -n "$orden" ]; then printf '%03d\t  %2s ✅ %-22s %s%s\n' "$orden" "$orden" "$r" "$desc" "$extra"
        else                     printf '999\t     ⛔ %-22s %s%s\n' "$r" "$desc" "$extra"; fi
    done | sort -s -k1,1 | cut -f2-
    exit 0
fi

# ---------------------------------------------------------------- roles a aplicar
if [[ "$ACCION" =~ ^(rol|todos)$ ]]; then
    [ "$ACCION" = todos ] && ROLES_PED=("${ACTIVOS[@]}")
    [ "${#ROLES_PED[@]}" -gt 0 ] || err "No hay roles que aplicar"
    ROLES=()
    en() { local x="$1" y; shift; for y in "$@"; do [ "$x" = "$y" ] && return 0; done; return 1; }
    for r in "${ACTIVOS[@]}";   do en "$r" "${ROLES_PED[@]}" && ! en "$r" "${EXCEPTO[@]}" && ! en "$r" "${ROLES[@]}" && ROLES+=("$r"); done
    for r in "${ROLES_PED[@]}"; do ! en "$r" "${EXCEPTO[@]}" && ! en "$r" "${ROLES[@]}" && ROLES+=("$r"); done
    [ "${#ROLES[@]}" -gt 0 ] || err "Con -x no queda ningún rol que aplicar"
fi

# ---------------------------------------------------------------- comprobaciones previas
command -v ansible >/dev/null 2>&1 || err "Ansible no está instalado."
if [ "${#INVENTARIOS[@]}" -eq 0 ]; then
    [ -n "$LIMITE" ] && err "-l necesita un aula o un inventario (IABD, SMRD, TODAS, fichero.ini)"
    case "$ACCION" in
        reinicia|apaga) err "«$ACCION» necesita aula o equipos: no se hace en este equipo" ;;
        equipos)        err "«equipos» necesita aula o inventario (IABD, SMRD, TODAS...)" ;;
        rol|todos)
            if [ "$(id -u)" -ne 0 ] && [[ " ${ARGS[*]} " != *"ansible_become=false"* ]]; then
                err "En local hay que lanzarlo como root: sudo bash $0 (mismos argumentos)"
            fi ;;
    esac
fi

# Límite de cada inventario: aula entera → -l; equipos sueltos → sueltos + -l
limite_de() {
    local inv="$1"
    if [ -n "${COMPLETA[$inv]}" ]; then echo "$LIMITE"
    else local s="${SUELTOS[$inv]}"; echo "$s${s:+${LIMITE:+,}}$LIMITE"; fi
}
cuantos() {       # cuantos <inventario> <límite> → nº de equipos que coinciden
    local L=(); [ -n "$2" ] && L=(-l "$2")
    local n
    muestra ansible -i "$1" --list-hosts "${L[@]}" all
    n=$(ansible -i "$1" --list-hosts "${L[@]}" all 2>/dev/null | sed -nE 's/^[[:space:]]*hosts \(([0-9]+)\).*/\1/p')
    echo "${n:-0}"
}

# ---------------------------------------------------------------- equipos
if [ "$ACCION" = equipos ]; then
    for inv in "${INVENTARIOS[@]}"; do
        lim=$(limite_de "$inv"); L=(); [ -n "$lim" ] && L=(-l "$lim")
        echo "== ${inv#"$DIR"/}${lim:+ (-l $lim)}"
        # Equipos que cumplen el -l (list-hosts) y su IP (ansible-inventory)
        muestra ansible -i "$inv" --list-hosts "${L[@]}" all
        sel=$(ansible -i "$inv" --list-hosts "${L[@]}" all 2>/dev/null | sed -n 's/^ \{4,\}//p')
        [ -n "$sel" ] || { echo "    (ningún equipo)"; continue; }
        muestra ansible-inventory -i "$inv" --list
        ansible-inventory -i "$inv" --list 2>/dev/null | python3 -c '
import json, re, sys
d = json.load(sys.stdin)
sel = set(sys.argv[1:])
hv = d.get("_meta", {}).get("hostvars", {})
clave = lambda h: [int(t) if t.isdigit() else t for t in re.split(r"(\d+)", h)]
for h in sorted(sel, key=clave):
    print("    %-22s %s" % (h, hv.get(h, {}).get("ansible_host", "")))
' $sel || echo "$sel" | sed 's/^/    /'
    done
    exit 0
fi

# ---------------------------------------------------------------- analisis
# Delega en el lanzador propio del rol, con sus opciones por defecto. Ese
# script admite un solo inventario: se lanza una vez por cada uno.
if [ "$ACCION" = analisis ]; then
    AE="$ROLESDIR/AnalisisEquipo/AnalisisEquipo.sh"
    [ -f "$AE" ] || err "No encuentro $AE"
    [ "${#ARGS[@]}" -eq 0 ] || err "analisis no admite más opciones; usa: bash ${AE#"$DIR"/} --ayuda"
    echo "[INFO] Análisis típico de AnalisisEquipo (opciones por defecto; con el estrés, 15 min o más; los equipos van en paralelo)."
    echo "[INFO] Para más opciones: bash ${AE#"$DIR"/} --ayuda"
    F=(); [ -n "$FORKS_DADO" ] && F=(--forks "$FORKS")
    if [ "${#INVENTARIOS[@]}" -eq 0 ]; then
        muestra bash "$AE" "${F[@]}"
        bash "$AE" "${F[@]}" </dev/null; exit $?
    fi
    RC=0
    for inv in "${INVENTARIOS[@]}"; do
        lim=$(limite_de "$inv")
        [ "$(cuantos "$inv" "$lim")" -gt 0 ] \
            || { echo "[AVISO] Ningún equipo de ${inv#"$DIR"/} coincide${lim:+ con '$lim'}; se salta."; continue; }
        L=(); [ -n "$lim" ] && L=(-l "$lim")
        muestra bash "$AE" "$inv" "${L[@]}" "${F[@]}"
        bash "$AE" "$inv" "${L[@]}" "${F[@]}" </dev/null || RC=1
    done
    exit $RC
fi

# ---------------------------------------------------------------- log
LOGDIR=/var/log/IAC-IESMHP
{ mkdir -p "$LOGDIR" && touch "$LOGDIR/roles.log"; } 2>/dev/null \
    || LOGDIR="$HOME/.local/state/IAC-IESMHP"
mkdir -p "$LOGDIR"
LOG="$LOGDIR/roles.log"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
SAL="$TMP/salida.txt"; : > "$SAL"
mmss() { printf '%d:%02d' $(( $1 / 60 )) $(( $1 % 60 )); }

export ANSIBLE_NOCOLOR=1 ANSIBLE_HOST_KEY_CHECKING=False ANSIBLE_ROLES_PATH="$ROLESDIR"

# ---------------------------------------------------------------- qué se lanza
# En una sola línea, para que el comando que se enseña sea legible
INFO_CMD='. /etc/os-release; ip=$(hostname -I | cut -d" " -f1); up=$(uptime -p | sed "s/^up //"); carga=$(cut -d" " -f1 /proc/loadavg); ram=$(free -h | awk "/^Mem:/ {print \$7\"/\"\$2}"); disco=$(df -h --output=avail / | tail -1 | tr -d " "); us=$(who | cut -d" " -f1 | sort -u | paste -sd, -); echo "$PRETTY_NAME | $(uname -r) | $ip | encendido $up | carga $carga | RAM libre $ram | / libre $disco | sesiones: ${us:-ninguna}"'

case "$ACCION" in
    ping)     MOD=(-m ping);                         QUE="ping" ;;
    info)     MOD=(-m shell -a "$INFO_CMD");         QUE="info" ;;
    cmd)      MOD=(-m shell -a "$CMD");              QUE="cmd: $CMD" ;;
    reinicia) MOD=(-m reboot -a "reboot_timeout=900"); QUE="reinicia" ;;
    apaga)    MOD=(-m shell -a "systemd-run --on-active=3 systemctl poweroff && echo apagando"); QUE="apaga" ;;
    rol|todos)
        QUE="roles: ${ROLES[*]}$([ $CHECK -eq 1 ] && echo ' (check)')"
        # Junto al log (no en /tmp) para que el comando que se enseña se pueda
        # relanzar y el playbook se pueda leer después. Se reescribe en cada uso.
        PB="$LOGDIR/roles-ultimo-playbook.yaml"
        {
            echo "---"
            echo "# Generado por roles.sh: cada rol en un block/rescue para que un fallo"
            echo "# se anote y el equipo siga con el siguiente rol."
            echo "- hosts: all"
            echo "  become: yes"
            echo "  tasks:"
            pasos=(); [ $APT -eq 1 ] && pasos+=(apt-update); pasos+=("${ROLES[@]}")
            for r in "${pasos[@]}"; do
                echo "    - block:"
                if [ "$r" = apt-update ]; then
                    echo "        - name: Actualizar caché apt (una vez, como roles.yaml)"
                    echo "          ansible.builtin.apt: { update_cache: yes }"
                else
                    echo "        - name: \"Rol $r\""
                    echo "          ansible.builtin.include_role: { name: $r }"
                fi
                echo "        - name: IAC-ROL"
                echo "          ansible.builtin.debug: { msg: \"IAC-ROL $r: OK\" }"
                echo "      rescue:"
                echo "        - name: IAC-ROL"
                echo "          ansible.builtin.debug:"
                echo "            msg: \"IAC-ROL $r: ERROR [{{ ansible_failed_task.name | default('?') }}] {{ (ansible_failed_result.msg | default('falló una tarea')) | string | truncate(160) }}\""
                echo "        - ansible.builtin.set_fact:"
                echo "            iac_fallidos: \"{{ iac_fallidos | default([]) + ['$r'] }}\""
            done
            echo "    - name: IAC-RESUMEN"
            echo "      ansible.builtin.fail: { msg: \"Roles con error: {{ iac_fallidos | join(', ') }}\" }"
            echo "      when: iac_fallidos | default([]) | length > 0"
        } > "$PB"
        [ $CHECK -eq 1 ] && ARGS=(--check "${ARGS[@]}") ;;
esac

# ---------------------------------------------------------------- ejecución
RC=0
LISTA_INV=("${INVENTARIOS[@]}"); [ "${#LISTA_INV[@]}" -eq 0 ] && LISTA_INV=("")
for INVENTARIO in "${LISTA_INV[@]}"; do
    LIM=()
    if [ -n "$INVENTARIO" ]; then
        INV=(-i "$INVENTARIO")
        lim=$(limite_de "$INVENTARIO")
        # Avisa de los equipos sueltos que no están (con uno solo y sin -l ya lo
        # dice la comprobación general de abajo)
        IFS=, read -ra sueltos <<< "${SUELTOS[$INVENTARIO]}"
        if [ -z "${COMPLETA[$INVENTARIO]}" ] && [ "$lim" != "${SUELTOS[$INVENTARIO]}" -o "${#sueltos[@]}" -gt 1 ]; then
            for e in "${sueltos[@]}"; do
                [ "$(cuantos "$INVENTARIO" "$e")" = 0 ] \
                    && echo "[AVISO] $e no está en ${INVENTARIO#"$DIR"/} (¿comentado?); se salta." | tee -a "$LOG"
            done
        fi
        n=$(cuantos "$INVENTARIO" "$lim")
        [ "${n:-0}" -gt 0 ] || { echo "[AVISO] Ningún equipo de ${INVENTARIO#"$DIR"/} coincide${lim:+ con '$lim'}; se salta." | tee -a "$LOG"; continue; }
        [ -n "$lim" ] && LIM=(-l "$lim")
    else
        INV=(-i localhost, --connection=local); n=1
    fi
    echo "===== $(date '+%F %T') $QUE → $([ -n "$INVENTARIO" ] && echo "${INVENTARIO#"$DIR"/}" || echo local) ($n equipo/s) ${LIM[*]} --forks $FORKS ${ARGS[*]}" | tee -a "$LOG"
    if [[ "$ACCION" =~ ^(rol|todos)$ ]]; then
        muestra ANSIBLE_HOST_KEY_CHECKING=False ANSIBLE_ROLES_PATH="$ROLESDIR" \
            ansible-playbook "${INV[@]}" "${LIM[@]}" --forks "$FORKS" -T "$TIMEOUT" "$PB" "${ARGS[@]}"
        ansible-playbook "${INV[@]}" "${LIM[@]}" --forks "$FORKS" -T "$TIMEOUT" "$PB" "${ARGS[@]}" \
            </dev/null >> "$SAL" 2>&1 || RC=1
    else
        muestra ANSIBLE_HOST_KEY_CHECKING=False \
            ansible "${INV[@]}" all "${LIM[@]}" --forks "$FORKS" -T "$TIMEOUT" -o "${MOD[@]}" "${ARGS[@]}"
        ansible "${INV[@]}" all "${LIM[@]}" --forks "$FORKS" -T "$TIMEOUT" -o "${MOD[@]}" "${ARGS[@]}" \
            </dev/null >> "$SAL" 2>&1 || RC=1
    fi
done
cat "$SAL" >> "$LOG"

# ---------------------------------------------------------------- resumen por equipo
resumen() {   # resumen <salida> <acción>  → líneas por equipo; código 1 si hay ERROR
    python3 - "$1" "$2" <<'PY'
import json, re, sys
txt = open(sys.argv[1], encoding='utf-8', errors='replace').read()
accion = sys.argv[2]
clave = lambda h: [int(t) if t.isdigit() else t for t in re.split(r'(\d+)', h)]

def motivo_ssh(m):
    m = m or ''
    if 'Permission denied' in m:   return 'SSH: permiso denegado (¿clave en authorized_keys?)'
    if 'Host key verification' in m: return 'SSH: la clave del equipo ha cambiado'
    if 'Connection refused' in m:  return 'SSH: conexión rechazada (¿sshd parado?)'
    if 'No route' in m or 'timed out' in m or 'Timeout' in m: return 'no responde por SSH (¿apagado?)'
    if 'Could not resolve' in m:   return 'no se resuelve el nombre'
    return 'no responde por SSH: ' + m.strip()[:100]

def desescapa(s):
    try: return json.loads('"%s"' % s)
    except Exception: return s

filas, cuenta, hay_error = {}, {}, False
def anota(eq, estado, texto, tipo=None):
    global hay_error
    if eq in filas:      # ansible 2.20 repite un fallo (línea corta + JSON): vale la 1ª
        return
    filas[eq] = (estado, texto)
    t = tipo or estado
    cuenta[t] = cuenta.get(t, 0) + 1
    hay_error |= estado == 'ERROR'

if accion in ('rol', 'todos'):
    roles = {}
    for eq, msg in re.findall(r'^ok: \[([^\]]+)\] => \{\s*"msg": "((?:[^"\\]|\\.)*)"', txt, re.M):
        m = re.match(r'IAC-ROL (\S+): (OK|ERROR)\s*(.*)', desescapa(msg), re.S)
        if m: roles.setdefault(eq, []).append(m.groups())
    inalc = {}
    for eq, msg in re.findall(r'^fatal: \[([^\]]+)\]: UNREACHABLE! => (.*)$', txt, re.M):
        inalc.setdefault(eq, msg)
    fallo = {}
    for eq, msg in re.findall(r'^fatal: \[([^\]]+)\]: FAILED! => (.*)$', txt, re.M):
        m = re.search(r'"msg": "((?:[^"\\]|\\.)*)"', msg)
        fallo.setdefault(eq, desescapa(m.group(1)) if m else msg)
    recap = dict(re.findall(r'^(\S+)\s+: (ok=.*)$', txt, re.M))
    for eq in sorted(set(recap) | set(roles), key=clave):
        r = recap.get(eq, '')
        bien = [n for n, e, _ in roles.get(eq, []) if e == 'OK']
        mal = [(n, d) for n, e, d in roles.get(eq, []) if e == 'ERROR']
        hechos = ('OK: ' + ', '.join(bien)) if bien else ''
        if re.search(r'unreachable=[1-9]', r):
            anota(eq, 'ERROR', motivo_ssh(inalc.get(eq)) + ('  (antes: %s)' % hechos if hechos else ''))
        elif mal:
            lineas = ['%s %s' % (n, d[:160]) for n, d in mal]
            if hechos: lineas.append(hechos)
            anota(eq, 'ERROR', '\n'.join(lineas))
        elif re.search(r'failed=[1-9]', r):
            anota(eq, 'ERROR', (fallo.get(eq) or 'falló una tarea (ver log)')[:160])
        else:
            anota(eq, 'OK', hechos or '(sin datos de los roles, ver log)')
else:
    pat = re.compile(r'^(\S+) \| (SUCCESS|CHANGED|FAILED!?|UNREACHABLE!)(?: \| rc=(-?\d+))?(?: \| \(stdout\) ?(.*)| => (.*)|: (.*))?$')
    for linea in txt.splitlines():
        m = pat.match(linea)
        if not m: continue
        eq, est, rc, sal, js, txt2 = m.groups()
        datos = {'msg': txt2} if txt2 else {}
        if js:
            try: datos = json.loads(js)
            except Exception: datos = {'msg': js}
        if est == 'UNREACHABLE!':
            anota(eq, 'ERROR', motivo_ssh(datos.get('msg'))); continue
        if sal is not None:
            sal, _, serr = sal.partition(' (stderr) ')
            texto = '\n'.join(x for x in (sal.replace('\\n', '\n').strip(),
                                         serr.replace('\\n', '\n').strip()) if x)
        else:
            texto = (datos.get('ping') or datos.get('stdout') or datos.get('msg') or '')
            if accion == 'reinicia' and datos.get('rebooted'):
                texto = 'reiniciado (%ss)' % datos.get('elapsed', '?')
            if not texto and est in ('FAILED', 'FAILED!'):
                texto = datos.get('stderr') or json.dumps(datos)[:160]
        if est.startswith('FAILED') or (rc not in (None, '0')):
            anota(eq, 'ERROR', ('rc=%s  ' % rc if rc else '') + str(texto))
        else:
            anota(eq, 'OK', str(texto))

for eq in sorted(filas, key=clave):
    estado, texto = filas[eq]
    lineas = str(texto).splitlines() or ['']
    print('    %-22s %-6s %s' % (eq, estado, lineas[0]))
    for l in lineas[1:]:
        print('    %-22s %-6s %s' % ('', '', l))
if not filas:
    print('    (ningún equipo; ver el log)')
    hay_error = True
else:
    print('  Equipos: ' + ', '.join('%s %d' % (k, n) for k, n in sorted(cuenta.items())))
sys.exit(1 if hay_error else 0)
PY
}

RES="$(resumen "$SAL" "$ACCION")" || RC=1     # fuera del { } | tee: allí RC no saldría
{
    echo ""
    echo "===== Resultado por equipo ($QUE)"
    echo "$RES"
    echo "  Tiempo total: $(mmss $(( $(date +%s) - T0 )))"
    echo "===== fin (código $RC). Salida completa de Ansible: $LOG"
} | tee -a "$LOG"
exit $RC
