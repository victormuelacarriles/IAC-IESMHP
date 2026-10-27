#!/bin/bash
# analiza.sh — análisis de hardware de ESTE equipo: sistema, CPU, memoria,
# discos, GPU NVIDIA, estrés largo y errores del kernel. Mide el tiempo de cada
# paso y deja un resumen en /var/log/IAC-IESMHP/AnalisisEquipo/.
#
# Lo copia y lanza el rol AnalisisEquipo (como root), pero vale suelto:
#   sudo bash analiza.sh                         # todo, valores por defecto
#   sudo bash analiza.sh --sin-estres            # sin el estrés largo
#   sudo bash analiza.sh --pasos cpu,discos      # solo esos pasos
#
# Opciones:
#   --equipo NOMBRE      nombre en el resumen (por defecto, hostname)
#   --pasos L            kernels,sistema,cpu,memoria,discos,gpu,estres,kernel,panics (todos)
#   --solo-kernel-panics solo kernels instalados + panics/cuelgues de los
#                        arranques anteriores (sin pruebas; también --soloKernelPanics)
#   --arranques N        arranques anteriores que se revisan en "panics" (10)
#   --sin-pruebas        solo datos y salud: sin pruebas de rendimiento ni estrés
#   --sin-estres         igual que quitar "estres" de --pasos
#   --estres-min N       minutos de estrés de CPU+RAM con stress-ng (10; 0 = no)
#   --memtester-pct N    % de la RAM disponible que prueba memtester (25; 0 = no)
#   --memtester-max N    minutos máximos de memtester (30)
#   --gpu-min N          minutos de estrés de la GPU NVIDIA (5; 0 = no)
#   --disco-gb N         GB del fichero de prueba de escritura en disco (2)
#   --dirs "D1 D2"       dónde se prueba la escritura ("/ /home /datos")
#   --temp-max N         °C de CPU a los que se corta el estrés (95)
#   --forzar             hace el estrés aunque haya usuarios con sesión abierta
#
# Sin preguntas (headless): stdin a /dev/null, nada gráfico.
# Salida: resumen en pantalla + líneas para el lanzador (TIEMPOPASO|..., DATOS|...,
# GLOBAL|..., FICHERO|..., PANICFILE|...). Detalle bruto en analisis-<fecha>.log.
# Un fichero por kernel panic en panics/panic-<equipo>-<fecha>-<arranque>.txt.
# Código de salida: 0 = OK · 1 = hay AVISOS · 2 = hay ERRORES de hardware ·
# 3 = no se pudo analizar (no es root, ya hay otro análisis, opción mala).
set -u
export LC_ALL=C
exec </dev/null

EQUIPO=$(hostname -s)
PASOS="kernels,sistema,cpu,memoria,discos,gpu,estres,kernel,panics"
ARRANQUES=10
PRUEBAS=1
ESTRES_MIN=10
MEMTESTER_PCT=25
MEMTESTER_MAX=30
GPU_MIN=5
DISCO_GB=2
DIRS_DISCO="/ /home /datos"
TEMP_MAX=95
GPU_TEMP_AVISO=90
FORZAR=0
DIR_SAL="${ANALISIS_DIR_SAL:-/var/log/IAC-IESMHP/AnalisisEquipo}"

numero() { [[ "$2" =~ ^[0-9]+$ ]] || { echo "[ERR] $1 necesita un número: '$2'" >&2; exit 3; }; }
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help|--ayuda) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
        --equipo)        EQUIPO="$2"; shift ;;
        --pasos)         PASOS="$2"; shift ;;
        --sin-pruebas)   PRUEBAS=0 ;;
        --sin-estres)    PASOS=$(tr , '\n' <<<"$PASOS" | grep -vx estres | paste -sd,) ;;
        --estres-min)    numero "$1" "$2"; ESTRES_MIN="$2"; shift ;;
        --memtester-pct) numero "$1" "$2"; MEMTESTER_PCT="$2"; shift ;;
        --memtester-max) numero "$1" "$2"; MEMTESTER_MAX="$2"; shift ;;
        --gpu-min)       numero "$1" "$2"; GPU_MIN="$2"; shift ;;
        --disco-gb)      numero "$1" "$2"; DISCO_GB="$2"; shift ;;
        --dirs)          DIRS_DISCO="$2"; shift ;;
        --temp-max)      numero "$1" "$2"; TEMP_MAX="$2"; shift ;;
        --forzar)        FORZAR=1 ;;
        --solo-kernel-panics|--soloKernelPanics) PASOS="kernels,panics" ;;
        --arranques)     numero "$1" "$2"; ARRANQUES="$2"; shift ;;
        *) echo "[ERR] Opción desconocida: $1" >&2; exit 3 ;;
    esac
    shift
done
for p in ${PASOS//,/ }; do
    case "$p" in kernels|sistema|cpu|memoria|discos|gpu|estres|kernel|panics) ;;
        *) echo "[ERR] Paso desconocido: '$p' (hay: kernels,sistema,cpu,memoria,discos,gpu,estres,kernel,panics)" >&2; exit 3 ;;
    esac
done
[ "$MEMTESTER_PCT" -le 80 ] || { echo "[ERR] --memtester-pct como mucho 80" >&2; exit 3; }

# ANALISIS_SIN_ROOT=1 solo para pruebas del script (faltan SMART, dmidecode...).
if [ "$(id -u)" -ne 0 ] && [ "${ANALISIS_SIN_ROOT:-0}" != 1 ]; then
    echo "[ERR] Hay que ejecutarlo como root (sudo bash $0)" >&2; exit 3
fi

mkdir -p "$DIR_SAL" || { echo "[ERR] No se puede crear $DIR_SAL" >&2; exit 3; }
# Un solo análisis a la vez (un Ctrl+C en el lanzador no para el de aquí).
exec 9>"$DIR_SAL/.en-marcha"
flock -n 9 || { echo "[ERR] Ya hay un análisis en marcha en $EQUIPO (ver $DIR_SAL)" >&2; exit 3; }

FECHA=$(date +%Y%m%d-%H%M%S)
T0=$(date +%s)
RAW="$DIR_SAL/analisis-$FECHA.log"         # salida bruta de cada herramienta
RES="$DIR_SAL/resumen-$FECHA.txt"          # resumen final
TMP=$(mktemp -d)
CUERPO="$TMP/cuerpo"; MAQ="$TMP/maquina"; : >"$CUERPO"; : >"$MAQ"
PIDS_FONDO=(); DIRS_PRUEBA=()

limpia() {
    local p d
    for p in "${PIDS_FONDO[@]}"; do kill "$p" 2>/dev/null; done
    pkill -TERM -x stress-ng 2>/dev/null
    for d in "${DIRS_PRUEBA[@]}"; do rm -rf "$d"; done
    rm -rf "$TMP"
}
trap limpia EXIT
trap 'echo "[AVISO] Análisis interrumpido" >>"$RAW"; exit 3' INT TERM

# ------------------------------------------------------------------ utilidades
log()  { printf '[%s] %s\n' "$(date +%T)" "$*" >>"$RAW"; }
r()    { printf '%s\n' "$*" >>"$CUERPO"; printf '%s\n' "$*" >>"$RAW"; }
hay()  { command -v "$1" >/dev/null 2>&1; }
mmss() { printf '%d:%02d' $(( $1 / 60 )) $(( $1 % 60 )); }
ahora(){ date +%s.%N; }
dif()  { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.1f", b - a }'; }
# Ejecuta un comando dejando su salida en el log bruto (y en $TMP/ultima).
corre() { log "\$ $*"; "$@" >"$TMP/ultima" 2>&1; local rc=$?; cat "$TMP/ultima" >>"$RAW"; return $rc; }
quita() { tr -d '|;="' <<<"$*"; }

# Estado de cada paso: OK < NO_APLICA < NO_MEDIDO < AVISO < ERROR
rango() { case "$1" in OK) echo 0 ;; NO_APLICA) echo 1 ;; NO_MEDIDO) echo 2 ;; AVISO) echo 3 ;; ERROR) echo 4 ;; *) echo 0 ;; esac; }
sube()  { [ "$(rango "$1")" -gt "$(rango "$ESTADO")" ] && ESTADO=$1; }
GLOBAL=OK; AVISOS=(); DATOS=(); TABLA=()

paso() {   # paso <clave> <título>
    PASO=$1; ESTADO=OK; CORTO=(); T_PASO=$(date +%s)
    r ""; r "== $2"
    log "---- paso $1"
}
aviso()    { sube AVISO;     r "   [AVISO] $*"; AVISOS+=("AVISO $PASO: $*"); }
error()    { sube ERROR;     r "   [ERROR] $*"; AVISOS+=("ERROR $PASO: $*"); }
nomedido() { sube NO_MEDIDO; r "   [--] $*"; }
corto()    { CORTO+=("$*"); }                       # dato clave para la tabla de tiempos
dato()     { DATOS+=("$1=$(quita "$2")"); }         # columna del CSV comparativo
fin_paso() {
    local s=$(( $(date +%s) - T_PASO )) c
    c=""; for x in "${CORTO[@]}"; do c+="${c:+ · }$x"; done
    r "   (paso $PASO: $(mmss $s), $ESTADO)"
    TABLA+=("$(printf '   %-9s %6s  %-10s %s' "$PASO" "$(mmss $s)" "$ESTADO" "$c")")
    printf 'TIEMPOPASO|%s|%s|%s|%s|%s\n' "$EQUIPO" "$PASO" "$s" "$ESTADO" "$(quita "$c")" >>"$MAQ"
    [ "$(rango "$ESTADO")" -gt "$(rango "$GLOBAL")" ] && GLOBAL=$ESTADO
    dato "t_$PASO" "$s"
}
quiere() { [[ ",$PASOS," == *",$1,"* ]]; }

# Temperatura de la CPU (°C): hwmon coretemp/k10temp, o la zona x86_pkg_temp.
cpu_temp() {
    local h n z
    for h in /sys/class/hwmon/hwmon*; do
        n=$(cat "$h/name" 2>/dev/null)
        case "$n" in coretemp|k10temp|zenpower)
            [ -r "$h/temp1_input" ] && { echo $(( $(cat "$h/temp1_input") / 1000 )); return; } ;;
        esac
    done
    for z in /sys/class/thermal/thermal_zone*; do
        [ "$(cat "$z/type" 2>/dev/null)" = x86_pkg_temp ] && { echo $(( $(cat "$z/temp") / 1000 )); return; }
    done
}
mhz_medio() { awk '/^cpu MHz/ { s += $4; n++ } END { if (n) printf "%d", s / n }' /proc/cpuinfo; }
throttle_cuenta() { cat /sys/devices/system/cpu/cpu*/thermal_throttle/core_throttle_count 2>/dev/null | awk '{ s += $1 } END { print s + 0 }'; }
usuarios_con_sesion() {
    # Columnas: SESIÓN UID USUARIO ... Personas: UID >= 1000, sin los de GDM (gdm-greeter es 60578).
    loginctl list-sessions --no-legend 2>/dev/null | awk '$2 >= 1000 && $3 !~ /^gdm/ && $3 != "" { print $3 }' | sort -u | paste -sd, -
}
MEM_DISP_MB() { awk '/^MemAvailable:/ { printf "%d", $2 / 1024 }' /proc/meminfo; }

log "===== analiza.sh en $EQUIPO: pasos=$PASOS pruebas=$PRUEBAS estres=${ESTRES_MIN}m memtester=${MEMTESTER_PCT}% gpu=${GPU_MIN}m disco=${DISCO_GB}G"

NVIDIA=0; NVIDIA_OK=0
lspci 2>/dev/null | grep -qi 'nvidia' && NVIDIA=1
[ "$NVIDIA" = 1 ] && hay nvidia-smi && nvidia-smi -L >/dev/null 2>&1 && NVIDIA_OK=1

# =================================================================== KERNELS
# Lo primero: qué kernels hay (los 5 más nuevos) y con cuál se ha arrancado.
if quiere kernels; then
    paso kernels "Kernels instalados"
    ACTUAL=$(uname -r)
    mapfile -t KBOOT < <(ls -1 /boot/vmlinuz-* 2>/dev/null | sed 's|^/boot/vmlinuz-||' | sort -V)
    NK=${#KBOOT[@]}
    if [ "$NK" -eq 0 ]; then
        nomedido "no hay /boot/vmlinuz-*"
    else
        NUEVO=${KBOOT[$((NK - 1))]}
        GDEF=$(sed -n 's/^GRUB_DEFAULT=//p' /etc/default/grub 2>/dev/null | tr -d '"' | tail -1)
        ARRANQUE=$(date -d "$(uptime -s 2>/dev/null)" +%s 2>/dev/null || echo 0)
        r "   $NK en /boot$([ "$NK" -gt 5 ] && echo ', se muestran los 5 más nuevos') · en uso: $ACTUAL · GRUB_DEFAULT=${GDEF:-?}"
        for (( i = NK - 1; i >= 0 && i >= NK - 5; i-- )); do
            k=${KBOOT[$i]}; notas=""
            [ "$k" = "$ACTUAL" ] && notas+=" ← EN USO"
            [ "$k" = "$NUEVO" ] && [ "${GDEF:-0}" = 0 ] && notas+=" · arranca por defecto"
            [ -e "/boot/initrd.img-$k" ] || { notas+=" · SIN initrd"; aviso "kernel $k sin /boot/initrd.img-$k: no arrancaría"; }
            [ -d "/lib/modules/$k" ] || { notas+=" · SIN módulos"; aviso "kernel $k sin /lib/modules/$k"; }
            r "     $k  (instalado $(date -r "/boot/vmlinuz-$k" '+%F %H:%M' 2>/dev/null))$notas"
        done
        RESTOS=0
        for d in /lib/modules/*/; do
            d=${d%/}; d=${d##*/}
            [ -e "/boot/vmlinuz-$d" ] || RESTOS=$((RESTOS + 1))
        done
        [ "$RESTOS" -gt 0 ] && r "   + $RESTOS carpetas en /lib/modules de kernels ya quitados"
        if [ "$ACTUAL" != "$NUEVO" ]; then
            if [ "$(stat -c %Y "/boot/vmlinuz-$NUEVO")" -gt "$ARRANQUE" ]; then
                r "   El más nuevo ($NUEVO) se instaló después de arrancar: falta reiniciar"
            else
                aviso "no arranca con el kernel más nuevo ($NUEVO) aunque ya estaba al arrancar: ¿GRUB_DEFAULT o falló y se eligió otro a mano?"
            fi
        fi
        dato kernel_actual "$ACTUAL"; dato kernel_nuevo "$NUEVO"; dato kernels_n "$NK"
        corto "$NK kernels, en uso $ACTUAL"
    fi
    fin_paso
fi

# =================================================================== SISTEMA
if quiere sistema; then
    paso sistema "Sistema"
    dmi() { cat "/sys/class/dmi/id/$1" 2>/dev/null | sed 's/[[:space:]]*$//'; }
    FAB=$(dmi sys_vendor); MOD=$(dmi product_name); PLACA="$(dmi board_vendor) $(dmi board_name)"
    BIOS="$(dmi bios_version) ($(dmi bios_date))"; SERIE=$(dmi product_serial)
    SO=$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-?}")
    r "   Equipo:   $FAB $MOD"
    r "   Placa:    $PLACA · BIOS $BIOS"
    [ -n "$SERIE" ] && r "   Nº serie: $SERIE"
    r "   SO:       $SO · kernel $(uname -r)"
    r "   Encendido desde: $(uptime -s 2>/dev/null) ($(uptime -p 2>/dev/null))"
    IFACE=$(ip route show default 2>/dev/null | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }')
    if [ -n "$IFACE" ]; then
        r "   Red:      $IFACE $(ip -4 -br addr show "$IFACE" | awk '{ print $3 }') · MAC $(cat "/sys/class/net/$IFACE/address" 2>/dev/null) · $(cat "/sys/class/net/$IFACE/speed" 2>/dev/null || echo ?) Mb/s"
        VEL=$(cat "/sys/class/net/$IFACE/speed" 2>/dev/null)
        [[ "$VEL" =~ ^[0-9]+$ ]] && [ "$VEL" -lt 1000 ] && [ "$VEL" -gt 0 ] && aviso "la red $IFACE va a $VEL Mb/s (¿cable o puerto del switch?)"
    fi
    if hay mokutil; then r "   Secure Boot: $(mokutil --sb-state 2>/dev/null | head -1)"; fi
    SES=$(usuarios_con_sesion)
    r "   Sesiones abiertas: ${SES:-ninguna}"
    dato modelo "$FAB $MOD"; dato bios "$BIOS"; dato serie "$SERIE"; dato kernel "$(uname -r)"
    corto "$MOD"
    fin_paso
fi

# ======================================================================= CPU
if quiere cpu; then
    paso cpu "CPU"
    lscpu >"$TMP/lscpu" 2>/dev/null; cat "$TMP/lscpu" >>"$RAW"
    lc() { awk -F: -v k="$1" '$1 == k { sub(/^[ \t]+/, "", $2); print $2; exit }' "$TMP/lscpu"; }
    CPUMOD=$(lc "Model name"); HILOS=$(nproc)
    NUCLEOS=$(awk -v a="$(lc "Core(s) per socket")" -v b="$(lc "Socket(s)")" 'BEGIN { print (a * b > 0) ? a * b : "?" }')
    MAXMHZ=$(lc "CPU max MHz" | cut -d. -f1)
    GOV=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)
    T_REPOSO=$(cpu_temp)
    r "   $CPUMOD · $NUCLEOS núcleos / $HILOS hilos · máx ${MAXMHZ:-?} MHz · gobernador ${GOV:-?}"
    r "   Temperatura en reposo: ${T_REPOSO:-?} °C · frecuencia media ahora $(mhz_medio) MHz"
    dato cpu "$CPUMOD"; dato nucleos "$NUCLEOS"; dato hilos "$HILOS"; dato cpu_temp_reposo "${T_REPOSO:-}"
    [ -n "$T_REPOSO" ] && [ "$T_REPOSO" -ge 70 ] && aviso "CPU a $T_REPOSO °C en reposo (¿ventilador o pasta térmica?)"
    corto "$HILOS hilos"
    if [ "$PRUEBAS" = 1 ]; then
        if hay sysbench; then
            # Trabajo fijo (primos hasta 10000): se mide lo que TARDA. ~10 s en un núcleo actual.
            cpu_bench() {   # cpu_bench <hilos> <eventos> → "segundos eventos/s"
                corre sysbench cpu --cpu-max-prime=10000 --threads="$1" --events="$2" --time=0 run || return 1
                awk '/total time:/ { gsub("s", "", $3); t = $3 } /events per second:/ { e = $4 } END { printf "%.1f %d", t, e }' "$TMP/ultima"
            }
            if R1=$(cpu_bench 1 20000); then
                read -r S1 E1 <<<"$R1"
                r "   sysbench 1 hilo:    ${S1} s (${E1} eventos/s)"
                dato cpu1_s "$S1"; dato cpu1_evs "$E1"; corto "1 hilo ${S1} s"
            else nomedido "sysbench 1 hilo falló (ver $RAW)"; fi
            if RN=$(cpu_bench "$HILOS" $(( 20000 * HILOS ))); then
                read -r SN EN <<<"$RN"
                r "   sysbench $HILOS hilos: ${SN} s (${EN} eventos/s)"
                dato cpuN_s "$SN"; dato cpuN_evs "$EN"; corto "$HILOS hilos ${SN} s"
            else nomedido "sysbench $HILOS hilos falló (ver $RAW)"; fi
        else
            nomedido "sin sysbench: no se mide el rendimiento"
        fi
    fi
    fin_paso
fi

# =================================================================== MEMORIA
if quiere memoria; then
    paso memoria "Memoria"
    TOTAL_MB=$(awk '/^MemTotal:/ { printf "%d", $2 / 1024 }' /proc/meminfo)
    SWAP_MB=$(awk '/^SwapTotal:/ { printf "%d", $2 / 1024 }' /proc/meminfo)
    RAM_GB=$(awk -v m="$TOTAL_MB" 'BEGIN { printf "%.1f", m / 1024 }')
    r "   Total ${RAM_GB} GB · disponible $(MEM_DISP_MB) MB · swap ${SWAP_MB} MB"
    dato ram_gb "$RAM_GB"; corto "${RAM_GB} GB"
    if hay dmidecode && dmidecode -t 17 >"$TMP/dmi17" 2>/dev/null; then
        cat "$TMP/dmi17" >>"$RAW"
        # Una línea por ranura: tamaño | ranura | tipo | velocidad | configurada | fabricante | modelo
        awk -F': ' '
            /^Memory Device/ { if (n) print l; n = 1; l = "" ; s = loc = t = v = cv = f = p = "" }
            /^\tSize:/ { s = $2 } /^\tLocator:/ { loc = $2 } /^\tType:/ { t = $2 }
            /^\tSpeed:/ { v = $2 } /^\tConfigured Memory Speed:/ { cv = $2 }
            /^\tManufacturer:/ { f = $2 } /^\tPart Number:/ { p = $2 }
            { l = s "|" loc "|" t "|" v "|" cv "|" f "|" p }
            END { if (n) print l }' "$TMP/dmi17" >"$TMP/modulos"
        RANURAS=$(wc -l <"$TMP/modulos")
        USADAS=$(grep -vc '^No Module Installed\|^0\|^Unknown' "$TMP/modulos")
        r "   Módulos: $USADAS de $RANURAS ranuras ocupadas"
        while IFS='|' read -r s loc t v cv f p; do
            case "$s" in "No Module Installed"|""|0*) continue ;; esac
            r "     - $loc: $s $t a ${cv:-?} (máx. $v) · $f $(sed 's/ *$//' <<<"$p")"
        done <"$TMP/modulos"
        dato ram_modulos "$USADAS/$RANURAS"
        dato ram_velocidad "$(awk -F'|' '$1 !~ /^No Module|^0|^$/ { print $5; exit }' "$TMP/modulos")"
    else
        nomedido "sin dmidecode: no se ven los módulos"
    fi
    # Errores ECC (solo si la placa tiene EDAC).
    if ls /sys/devices/system/edac/mc/mc* >/dev/null 2>&1; then
        CE=$(cat /sys/devices/system/edac/mc/mc*/ce_count 2>/dev/null | awk '{ s += $1 } END { print s + 0 }')
        UE=$(cat /sys/devices/system/edac/mc/mc*/ue_count 2>/dev/null | awk '{ s += $1 } END { print s + 0 }')
        r "   ECC (EDAC): corregibles $CE · no corregibles $UE"
        [ "$UE" -gt 0 ] && error "$UE errores de memoria NO corregibles (EDAC)"
        [ "$CE" -gt 0 ] && aviso "$CE errores de memoria corregibles (EDAC)"
    fi
    if [ "$PRUEBAS" = 1 ]; then
        if hay sysbench; then
            mem_bench() {   # mem_bench <hilos> <GB> → "segundos MiB/s"
                corre sysbench memory --memory-block-size=1M --memory-total-size="$2G" \
                      --memory-oper=write --threads="$1" --time=0 run || return 1
                awk '/total time:/ { gsub("s", "", $3); t = $3 }
                     /MiB transferred/ { gsub(/[()]/, "", $4); m = $4 }
                     END { printf "%.1f %d", t, m }' "$TMP/ultima"
            }
            HILOS=$(nproc)
            if R1=$(mem_bench 1 20); then
                read -r S1 M1 <<<"$R1"; r "   Escritura 1 hilo:    20 GB en ${S1} s (${M1} MiB/s)"
                dato mem1_mibs "$M1"; corto "1 hilo ${M1} MiB/s"
            else nomedido "sysbench memory 1 hilo falló"; fi
            if RN=$(mem_bench "$HILOS" 100); then
                read -r SN MN <<<"$RN"; r "   Escritura $HILOS hilos: 100 GB en ${SN} s (${MN} MiB/s)"
                dato memN_mibs "$MN"; corto "$HILOS hilos ${MN} MiB/s"
            else nomedido "sysbench memory $HILOS hilos falló"; fi
        else
            nomedido "sin sysbench: no se mide el ancho de banda"
        fi
    fi
    fin_paso
fi

# ==================================================================== DISCOS
if quiere discos; then
    paso discos "Discos"
    lsblk -d -n -b -o NAME,TYPE,SIZE,ROTA,TRAN,MODEL -e 7,11 2>/dev/null | awk '$2 == "disk" && $1 !~ /^zram/' >"$TMP/discos"
    cat "$TMP/discos" >>"$RAW"
    NDISCOS=0
    while read -r NOM _ TAM ROTA TRAN MODELO; do
        NDISCOS=$((NDISCOS + 1))
        GB=$(( TAM / 1000000000 ))
        TIPO=$([ "$ROTA" = 1 ] && echo HDD || { [[ "$NOM" == nvme* ]] && echo NVMe || echo SSD; })
        r "   /dev/$NOM: $TIPO ${GB} GB · ${MODELO:-?} (${TRAN:-?})"
        dato "disco_${NOM}" "$TIPO ${GB}GB ${MODELO}"
        SALUD="?"
        # ---- SMART (también NVMe) en JSON
        if hay smartctl; then
            smartctl -j -a "/dev/$NOM" >"$TMP/smart.json" 2>/dev/null
            smartctl -a "/dev/$NOM" >>"$RAW" 2>&1
            python3 - "$TMP/smart.json" >"$TMP/smart" 2>/dev/null <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
o = {}
ss = d.get('smart_status')
if ss is not None: o['ok'] = 1 if ss.get('passed') else 0
t = d.get('temperature', {}).get('current')
if t is not None: o['temp'] = t
h = d.get('power_on_time', {}).get('hours')
if h is not None: o['horas'] = h
n = d.get('nvme_smart_health_information_log')
if n:
    for k, c in (('percentage_used', 'usado'), ('media_errors', 'err_medio'),
                 ('critical_warning', 'critico'), ('available_spare', 'reserva'),
                 ('unsafe_shutdowns', 'apagados_sucios')):
        if k in n: o[c] = n[k]
    if 'data_units_written' in n: o['escrito_tb'] = round(n['data_units_written'] * 512000 / 1e12, 1)
for a in d.get('ata_smart_attributes', {}).get('table', []):
    if a.get('id') in (5, 187, 197, 198, 199):
        o['ata%d' % a['id']] = a.get('raw', {}).get('value', 0)
print(' '.join('%s=%s' % kv for kv in o.items()))
PY
            declare -A S=()
            for kv in $(cat "$TMP/smart"); do S[${kv%%=*}]=${kv#*=}; done
            if [ -z "${S[ok]:-}" ]; then
                nomedido "/dev/$NOM sin datos SMART (disco virtual o USB)"
                SALUD="sin SMART"
            else
                linea="     SMART: $([ "${S[ok]}" = 1 ] && echo correcto || echo FALLA) · ${S[temp]:-?} °C · ${S[horas]:-?} h encendido"
                [ -n "${S[usado]:-}" ] && linea+=" · desgaste ${S[usado]} % · reserva ${S[reserva]:-?} % · escritos ${S[escrito_tb]:-?} TB · errores ${S[err_medio]:-0}"
                [ -n "${S[ata5]:-}" ] && linea+=" · reasignados ${S[ata5]} · pendientes ${S[ata197]:-0} · irrecuperables ${S[ata198]:-0} · CRC ${S[ata199]:-0}"
                r "$linea"
                SALUD=OK
                [ "${S[ok]}" = 0 ] && { error "/dev/$NOM: SMART dice que el disco FALLA"; SALUD=FALLA; }
                [ "${S[critico]:-0}" != 0 ] && { error "/dev/$NOM: aviso crítico NVMe (${S[critico]})"; SALUD=FALLA; }
                [ "${S[usado]:-0}" -ge 90 ] && { aviso "/dev/$NOM: desgaste ${S[usado]} %"; SALUD=AVISO; }
                [ -n "${S[reserva]:-}" ] && [ "${S[reserva]}" -le 10 ] && { aviso "/dev/$NOM: reserva NVMe al ${S[reserva]} %"; SALUD=AVISO; }
                [ "${S[err_medio]:-0}" -gt 0 ] && { aviso "/dev/$NOM: ${S[err_medio]} errores de medio NVMe"; SALUD=AVISO; }
                for a in 5 197 198; do
                    [ "${S[ata$a]:-0}" -gt 0 ] && { aviso "/dev/$NOM: atributo SMART $a = ${S[ata$a]} (sectores malos)"; SALUD=AVISO; }
                done
                [ "${S[temp]:-0}" -ge 70 ] && aviso "/dev/$NOM a ${S[temp]} °C"
                dato "disco_${NOM}_horas" "${S[horas]:-}"; dato "disco_${NOM}_desgaste" "${S[usado]:-}"
            fi
            unset S
        else
            nomedido "sin smartctl: no se ve la salud de /dev/$NOM"
        fi
        dato "disco_${NOM}_salud" "$SALUD"
        # ---- Lectura en bruto (solo lectura: seguro aunque esté montado o en ZFS)
        if [ "$PRUEBAS" = 1 ]; then
            if hay fio; then
                fio_bruto() {   # fio_bruto <rw> <bs> <iodepth> → JSON en $TMP/fio.json
                    corre fio --name=bruto --filename="/dev/$NOM" --readonly --rw="$1" --bs="$2" \
                        --iodepth="$3" --ioengine=libaio --direct=1 --runtime=15 --time_based \
                        --output-format=json --output="$TMP/fio.json"
                }
                fio_lee() { python3 -c 'import json,sys; j=json.load(open(sys.argv[1]))["jobs"][0][sys.argv[2]]; print(int(j["bw"]/1024), int(j["iops"]))' "$TMP/fio.json" "$1" 2>/dev/null; }
                if fio_bruto read 1M 16 && L=$(fio_lee read); then
                    read -r MBS _ <<<"$L"
                    if fio_bruto randread 4k 32 && L=$(fio_lee read); then read -r _ IOPS <<<"$L"; else IOPS="?"; fi
                    r "     Lectura secuencial ${MBS} MB/s · aleatoria 4k ${IOPS} IOPS (15 s cada una)"
                    dato "disco_${NOM}_lec_mbs" "$MBS"; dato "disco_${NOM}_iops4k" "$IOPS"
                    corto "$NOM ${MBS} MB/s"
                    [ "$TIPO" = NVMe ] && [ "$MBS" -lt 500 ] && aviso "/dev/$NOM (NVMe) lee solo a $MBS MB/s"
                    [ "$TIPO" = SSD ] && [ "$MBS" -lt 200 ] && aviso "/dev/$NOM (SSD) lee solo a $MBS MB/s"
                else
                    nomedido "fio no pudo leer /dev/$NOM (ver $RAW)"
                fi
            else
                nomedido "sin fio: no se mide /dev/$NOM"
            fi
        fi
    done <"$TMP/discos"
    [ "$NDISCOS" = 0 ] && nomedido "no se ve ningún disco con lsblk"

    # ---- Sistemas de ficheros: ocupación
    r "   Ocupación:"
    df -hPT -x tmpfs -x devtmpfs -x squashfs -x overlay -x efivarfs -x nfs -x nfs4 -x fuse 2>/dev/null \
        | awk 'NR > 1 && $7 !~ "^/(snap|boot/efi|run)" { printf "     %-22s %-6s %6s usados de %6s (%s)\n", $7, $2, $4, $3, $6 }' >"$TMP/df"
    while IFS= read -r l; do r "$l"; done <"$TMP/df"
    while read -r pct mp; do
        pct=${pct%\%}; [ "$pct" -ge 90 ] && aviso "$mp lleno al $pct %"
    done < <(df -P -x tmpfs -x devtmpfs -x squashfs -x overlay -x efivarfs -x nfs -x nfs4 -x fuse 2>/dev/null | awk 'NR > 1 && $6 !~ "^/(snap|run)" { print $5, $6 }')

    # ---- ZFS
    if hay zpool && [ -n "$(zpool list -H -o name 2>/dev/null)" ]; then
        r "   ZFS:"
        zpool status >>"$RAW" 2>&1
        while IFS=$'\t' read -r nom tam usado salud dedup frag; do
            r "     $nom: $salud · $usado usados de $tam · dedup $dedup · fragmentación $frag"
            [ "$salud" != ONLINE ] && error "pool ZFS $nom en estado $salud"
            ERRS=$(zpool status "$nom" 2>/dev/null | awk '$2 ~ /^(ONLINE|DEGRADED|FAULTED|UNAVAIL)$/ && NF >= 5 { n += $3 + $4 + $5 } END { print n + 0 }')
            [ "$ERRS" -gt 0 ] && aviso "pool ZFS $nom con $ERRS errores de lectura/escritura/checksum"
            SCRUB=$(zpool status "$nom" 2>/dev/null | sed -n 's/^ *scan: //p')
            r "       último scrub: ${SCRUB:-nunca}"
            dato "zfs_$nom" "$salud"
        done < <(zpool list -H -o name,size,alloc,health,dedupratio,frag 2>/dev/null)
    fi

    # ---- Escritura/lectura sobre el sistema de ficheros (una vez por disco/pool)
    if [ "$PRUEBAS" = 1 ] && hay fio; then
        declare -A VISTO=()
        for d in $DIRS_DISCO; do
            [ -d "$d" ] || continue
            SRC=$(findmnt -n -o SOURCE --target "$d" | head -1); FST=$(findmnt -n -o FSTYPE --target "$d" | head -1)
            case "$FST" in nfs*|cifs|tmpfs|overlay|fuse*|squashfs|"") r "   $d está en ${FST:-?}: no se prueba la escritura"; continue ;; esac
            CLAVE=$SRC; [ "$FST" = zfs ] && CLAVE="zfs:${SRC%%/*}"
            [ -n "${VISTO[$CLAVE]:-}" ] && continue
            VISTO[$CLAVE]=1
            LIBRE_GB=$(df -Pk "$d" | awk 'NR == 2 { printf "%d", $4 / 1048576 }')
            if [ "$LIBRE_GB" -lt $(( DISCO_GB * 2 + 2 )) ]; then
                nomedido "$d: solo $LIBRE_GB GB libres, no se prueba la escritura"; continue
            fi
            TD="$d/.IAC-AnalisisEquipo.$$"; mkdir -p "$TD" && DIRS_PRUEBA+=("$TD")
            K=${d#/}; K=${K:-raiz}; K=${K//\//_}
            fio_fs() {   # fio_fs <rw> <bs> <extra...>
                local rw=$1 bs=$2; shift 2
                corre fio --name=fs --directory="$TD" --filename=prueba --size="${DISCO_GB}G" --rw="$rw" --bs="$bs" \
                    --ioengine=libaio --iodepth=16 --direct="$DIRECTO" --refill_buffers \
                    --output-format=json --output="$TMP/fio.json" "$@"
            }
            fio_lee() { python3 -c 'import json,sys; j=json.load(open(sys.argv[1]))["jobs"][0][sys.argv[2]]; print(int(j["bw"]/1024), int(j["iops"]))' "$TMP/fio.json" "$1" 2>/dev/null; }
            DIRECTO=1
            A=$(ahora)
            if ! fio_fs write 1M --end_fsync=1; then
                DIRECTO=0; A=$(ahora)                 # algún FS no admite O_DIRECT
                fio_fs write 1M --end_fsync=1 || { nomedido "$d: fio no pudo escribir (ver $RAW)"; continue; }
            fi
            SW=$(dif "$A" "$(ahora)")
            WMBS=$(awk -v g="$DISCO_GB" -v s="$SW" 'BEGIN { printf "%d", g * 1024 / s }')
            A=$(ahora); fio_fs read 1M; SR=$(dif "$A" "$(ahora)"); RMBS=$(fio_lee read | cut -d' ' -f1)
            fio_fs randwrite 4k --runtime=15 --time_based --end_fsync=1; WIOPS=$(fio_lee write | cut -d' ' -f2)
            rm -rf "$TD"
            r "   $d ($FST $SRC): escribir ${DISCO_GB} GB ${SW} s (${WMBS} MB/s) · leerlos ${SR} s (${RMBS:-?} MB/s) · escritura 4k ${WIOPS:-?} IOPS$([ "$DIRECTO" = 0 ] && echo ' · sin O_DIRECT')"
            [ "$FST" = zfs ] && r "     (ZFS: la lectura puede salir de la caché ARC y la escritura incluye compresión/dedup)"
            dato "fs_${K}_esc_mbs" "$WMBS"; dato "fs_${K}_esc_s" "$SW"; dato "fs_${K}_lec_mbs" "${RMBS:-}"; dato "fs_${K}_iops4k_esc" "${WIOPS:-}"
            corto "$d esc ${WMBS} MB/s"
        done
        unset VISTO
    elif [ "$PRUEBAS" = 1 ]; then
        nomedido "sin fio: no se prueba la escritura"
    fi
    fin_paso
fi

# ======================================================================= GPU
gpu_q() { nvidia-smi -i 0 --query-gpu="$1" --format=csv,noheader,nounits 2>/dev/null | head -1 | sed 's/, */|/g'; }
gpu_razones() {   # máscara de motivos de bajada de reloj (nombre nuevo y viejo del campo)
    gpu_q clocks_event_reasons.active | grep -q '^0x' && { gpu_q clocks_event_reasons.active; return; }
    gpu_q clocks_throttle_reasons.active
}
if quiere gpu; then
    paso gpu "GPU"
    lspci 2>/dev/null | grep -Ei 'vga|3d|display' | sed 's/^/   /' | while IFS= read -r l; do r "$l"; done
    if [ "$NVIDIA" = 0 ]; then
        sube NO_APLICA; r "   Sin GPU NVIDIA: no se mide"; corto "sin NVIDIA"; dato gpu "-"
    elif [ "$NVIDIA_OK" = 0 ]; then
        error "hay GPU NVIDIA pero nvidia-smi no funciona: driver no cargado (rol nvidia, ¿Secure Boot?)"
        dato gpu "NVIDIA sin driver"; corto "driver NO operativo"
    else
        nvidia-smi -q >>"$RAW" 2>&1
        IFS='|' read -r GNOM GDRV GMEM GTEMP GPOT GPLIM GGEN GGENMAX GANCHO GANCHOMAX <<<"$(gpu_q name,driver_version,memory.total,temperature.gpu,power.draw,power.limit,pcie.link.gen.current,pcie.link.gen.max,pcie.link.width.current,pcie.link.width.max)"
        NGPU=$(nvidia-smi -L 2>/dev/null | wc -l)
        r "   $GNOM · driver $GDRV · ${GMEM} MiB · $NGPU GPU(s) (se mide la 0)"
        r "   Reposo: ${GTEMP} °C · ${GPOT} W de ${GPLIM} W · PCIe gen $GGEN/$GGENMAX x$GANCHO/x$GANCHOMAX"
        dato gpu "$GNOM"; dato gpu_driver "$GDRV"; dato gpu_mem_mib "$GMEM"; dato gpu_temp_reposo "$GTEMP"
        corto "$GNOM"
        [ -n "$GANCHO" ] && [ -n "$GANCHOMAX" ] && [ "$GANCHO" -lt "$GANCHOMAX" ] 2>/dev/null \
            && aviso "GPU en PCIe x$GANCHO de x$GANCHOMAX posibles (¿mal asentada o ranura equivocada?)"
        if [ "$PRUEBAS" = 1 ]; then
            if hay clpeak; then
                # Muestras de nvidia-smi mientras corre, para ver el PCIe y la temperatura con carga.
                ( while :; do gpu_q temperature.gpu,power.draw,clocks.sm,pcie.link.gen.current >>"$TMP/gpu_carga"; sleep 2; done ) &
                PM=$!; PIDS_FONDO+=("$PM")
                A=$(ahora)
                corre timeout 900 clpeak --global-bandwidth --compute-sp; RC=$?
                SC=$(dif "$A" "$(ahora)"); kill "$PM" 2>/dev/null
                read -r GBPS GFLOPS < <(python3 - "$TMP/ultima" <<'PY'
import re, sys
txt = open(sys.argv[1], errors='replace').read()
i = txt.find('Platform: NVIDIA')
if i < 0:
    print('- -'); sys.exit()
txt = txt[i:]
j = txt.find('Platform:', 10)
txt = txt if j < 0 else txt[:j]
def mejor(titulo):
    m = re.search(titulo + r'[^\n]*\n((?:[ \t]+[\w ]+:[ \t]*[\d.]+[ \t]*\n)+)', txt)
    return '%.0f' % max(float(x) for x in re.findall(r':\s*([\d.]+)', m.group(1))) if m else '-'
print(mejor('Global memory bandwidth'), mejor('Single-precision compute'))
PY
)
                GGENC=$(awk -F'|' '{ print $4 }' "$TMP/gpu_carga" 2>/dev/null | sort -n | tail -1)
                if [ "$RC" = 0 ] && [ "${GFLOPS:--}" != - ]; then
                    r "   clpeak (OpenCL): ${GFLOPS} GFLOPS simple precisión · memoria ${GBPS} GB/s · ${SC} s · PCIe gen ${GGENC:-?} con carga"
                    dato gpu_gflops "$GFLOPS"; dato gpu_gbps "$GBPS"; corto "${GFLOPS} GFLOPS"
                    [ -n "$GGENC" ] && [ -n "$GGENMAX" ] && [ "$GGENC" -lt "$GGENMAX" ] 2>/dev/null \
                        && aviso "GPU con carga en PCIe gen $GGENC de $GGENMAX"
                else
                    nomedido "clpeak no midió la NVIDIA (rc $RC; ¿falta el OpenCL de NVIDIA, /etc/OpenCL/vendors/nvidia.icd?)"
                fi
            else
                nomedido "sin clpeak: no se mide el rendimiento de la GPU"
            fi
        fi
    fi
    fin_paso
fi

# ==================================================================== ESTRÉS
if quiere estres && [ "$PRUEBAS" = 1 ]; then
    paso estres "Estrés largo"
    SES=$(usuarios_con_sesion)
    if [ -n "$SES" ] && [ "$FORZAR" = 0 ]; then
        sube NO_MEDIDO
        r "   [--] SALTADO: hay usuarios con sesión ($SES). Para hacerlo igual: --forzar"
        corto "saltado (sesión de $SES)"
    else
        # ---- CPU + RAM con stress-ng
        if [ "$ESTRES_MIN" -gt 0 ]; then
            if hay stress-ng; then
                HILOS=$(nproc)
                VM_MB=$(( $(MEM_DISP_MB) * 40 / 100 / 2 ))     # 2 trabajadores vm, 40 % de lo disponible
                TH0=$(throttle_cuenta)
                r "   stress-ng ${ESTRES_MIN} min: $HILOS hilos de CPU + 2×${VM_MB} MB de RAM con verificación (corta a ${TEMP_MAX} °C)"
                A=$(ahora)
                stress-ng --cpu "$HILOS" --cpu-method all --vm 2 --vm-bytes "${VM_MB}M" --verify \
                    --timeout "${ESTRES_MIN}m" --metrics-brief --yaml "$TMP/stress.yaml" >"$TMP/stress.out" 2>&1 &
                PS=$!
                # Vigilante: temperatura y frecuencia cada 5 s; corta si se pasa de TEMP_MAX.
                ( while kill -0 "$PS" 2>/dev/null; do
                      t=$(cpu_temp); echo "${t:-0} $(mhz_medio)" >>"$TMP/cpu_carga"
                      if [ -n "$t" ] && [ "$t" -ge "$TEMP_MAX" ]; then echo "$t" >"$TMP/caliente"; kill -TERM "$PS"; break; fi
                      sleep 5
                  done ) &
                PV=$!; PIDS_FONDO+=("$PV")
                wait "$PS"; RC=$?
                kill "$PV" 2>/dev/null
                SS=$(dif "$A" "$(ahora)")
                cat "$TMP/stress.out" >>"$RAW"
                TMAX=$(awk '{ print $1 }' "$TMP/cpu_carga" 2>/dev/null | sort -n | tail -1)
                MHZ=$(awk '{ s += $2; n++ } END { if (n) printf "%d", s / n }' "$TMP/cpu_carga" 2>/dev/null)
                TH=$(( $(throttle_cuenta) - TH0 ))
                BOGO=$(sed -n '/stressor: cpu/,/stressor:/ s/.*bogo-ops-per-second-real-time: *\([0-9.]*\).*/\1/p' "$TMP/stress.yaml" 2>/dev/null | head -1 | cut -d. -f1)
                r "   Resultado: ${SS} s · temperatura máx ${TMAX:-?} °C · frecuencia media ${MHZ:-?} MHz (máx ${MAXMHZ:-?}) · ${BOGO:-?} bogo-ops/s CPU"
                dato estres_temp_max "${TMAX:-}"; dato estres_mhz "${MHZ:-}"; dato estres_bogops "${BOGO:-}"
                corto "CPU+RAM ${TMAX:-?} °C ${MHZ:-?} MHz"
                if [ -s "$TMP/caliente" ]; then
                    error "estrés CORTADO a los ${SS} s: CPU a $(cat "$TMP/caliente") °C (refrigeración)"
                    dato estres "CALIENTE"
                elif [ "$RC" != 0 ] || grep -qE 'failed: [1-9]|stress-ng: fail:|unsuccessful run|verification.*(fail|error)' "$TMP/stress.out"; then
                    error "stress-ng terminó con fallos (rc $RC): $(grep -E 'failed: [1-9]|fail:|unsuccessful' "$TMP/stress.out" | head -2 | tr '\n' ' ')"
                    dato estres "FALLO"
                else
                    dato estres "OK"
                fi
                [ -n "$TMAX" ] && [ "$TMAX" -ge 90 ] && [ ! -s "$TMP/caliente" ] && aviso "CPU a $TMAX °C con carga"
                [ "$TH" -gt 0 ] && aviso "la CPU bajó frecuencia por temperatura $TH veces"
                [ -n "${MHZ:-}" ] && [ -n "${MAXMHZ:-}" ] && [ "$MHZ" -lt $(( MAXMHZ * 50 / 100 )) ] \
                    && aviso "con carga va a $MHZ MHz, menos de la mitad de los $MAXMHZ (¿perfil de energía o calor?)"
            else
                nomedido "sin stress-ng: no se hace el estrés de CPU+RAM"
            fi
        fi
        # ---- memtester
        if [ "$MEMTESTER_PCT" -gt 0 ]; then
            if hay memtester; then
                MT_MB=$(( $(MEM_DISP_MB) * MEMTESTER_PCT / 100 ))
                r "   memtester: ${MT_MB} MB (${MEMTESTER_PCT} % de lo disponible), 1 pasada, máx ${MEMTESTER_MAX} min"
                A=$(ahora)
                corre timeout -k 30 $(( MEMTESTER_MAX * 60 )) memtester "${MT_MB}M" 1; RC=$?
                SM=$(dif "$A" "$(ahora)")
                case "$RC" in
                    0)   r "   Resultado: correcto en ${SM} s"; dato memtester OK ;;
                    124) aviso "memtester no terminó en $MEMTESTER_MAX min (sin errores hasta ahí)"; dato memtester "INCOMPLETO" ;;
                    1)   nomedido "memtester no pudo reservar ${MT_MB} MB"; dato memtester "-" ;;
                    *)   error "memtester encontró ERRORES en la RAM (rc $RC): $(grep -i 'fail' "$TMP/ultima" | head -2 | tr '\n' ' ')"; dato memtester "FALLO" ;;
                esac
                dato memtester_s "$SM"; corto "memtester ${SM} s"
            else
                nomedido "sin memtester"
            fi
        fi
        # ---- GPU
        if [ "$GPU_MIN" -gt 0 ] && [ "$NVIDIA_OK" = 1 ]; then
            XID0=$(journalctl -k -b --no-pager 2>/dev/null | grep -c 'NVRM: Xid')
            ( while :; do echo "$(gpu_q temperature.gpu,power.draw,clocks.sm)|$(gpu_razones)" >>"$TMP/gpu_estres"; sleep 5; done ) &
            PG=$!; PIDS_FONDO+=("$PG")
            A=$(ahora); FIN=$(( $(date +%s) + GPU_MIN * 60 )); RC=0
            if hay gpu_burn; then
                r "   GPU ${GPU_MIN} min con gpu_burn"
                corre timeout -k 30 $(( GPU_MIN * 60 + 120 )) gpu_burn $(( GPU_MIN * 60 )); RC=$?
                grep -q 'FAULTY' "$TMP/ultima" && error "gpu_burn: la GPU da resultados ERRÓNEOS (FAULTY)"
            elif hay clpeak; then
                r "   GPU ${GPU_MIN} min con clpeak en bucle"
                while [ "$(date +%s)" -lt "$FIN" ]; do
                    corre timeout 900 clpeak --compute-sp || { RC=$?; break; }
                done
            else
                RC=-1
            fi
            kill "$PG" 2>/dev/null
            SG=$(dif "$A" "$(ahora)")
            if [ "$RC" = -1 ]; then
                nomedido "sin gpu_burn ni clpeak: no se estresa la GPU"
            else
                GTMAX=$(awk -F'|' '{ print $1 }' "$TMP/gpu_estres" | sort -n | tail -1)
                GPMAX=$(awk -F'|' '{ print $2 }' "$TMP/gpu_estres" | sort -n | tail -1)
                GCMIN=$(awk -F'|' '$3 > 0 { print $3 }' "$TMP/gpu_estres" | sort -n | head -1)
                GCMAX=$(awk -F'|' '{ print $3 }' "$TMP/gpu_estres" | sort -n | tail -1)
                RAZ=$(awk -F'|' '{ print $4 }' "$TMP/gpu_estres" | sort -u | paste -sd' ')
                r "   Resultado: ${SG} s · ${GTMAX:-?} °C máx · ${GPMAX:-?} W máx · reloj ${GCMIN:-?}-${GCMAX:-?} MHz"
                dato gpu_temp_max "${GTMAX:-}"; dato gpu_w_max "${GPMAX:-}"
                corto "GPU ${GTMAX:-?} °C"
                [ "$RC" != 0 ] && error "la prueba de GPU terminó con error (rc $RC, ver $RAW)"
                [ -n "$GTMAX" ] && [ "${GTMAX%.*}" -ge "$GPU_TEMP_AVISO" ] && aviso "GPU a $GTMAX °C con carga"
                # Bits de bajada de reloj por calor o hardware: 0x8 HW slowdown, 0x20 SW thermal,
                # 0x40 HW thermal, 0x80 HW power brake.
                for m in $RAZ; do
                    [[ "$m" =~ ^0x ]] && [ $(( m & 0xE8 )) -ne 0 ] && { aviso "la GPU bajó reloj por temperatura/hardware (motivos $m)"; break; }
                done
                XID=$(( $(journalctl -k -b --no-pager 2>/dev/null | grep -c 'NVRM: Xid') - XID0 ))
                [ "$XID" -gt 0 ] && error "$XID errores Xid de NVIDIA durante el estrés"
            fi
        elif [ "$GPU_MIN" -gt 0 ] && [ "$NVIDIA" = 1 ]; then
            nomedido "GPU NVIDIA sin driver: no se estresa"
        fi
    fi
    fin_paso
fi

# ==================================================================== KERNEL
if quiere kernel; then
    paso kernel "Errores del kernel"
    journalctl -k -b --no-pager -o short-monotonic 2>/dev/null >"$TMP/dmesg"
    [ -s "$TMP/dmesg" ] || dmesg >"$TMP/dmesg" 2>/dev/null
    if [ ! -s "$TMP/dmesg" ]; then
        nomedido "no se puede leer el log del kernel"
    else
        PATRON='Machine Check|mce: |Hardware Error|EDAC .*(CE|UE)|I/O error|nvme.*(timeout|reset|I/O)|ata[0-9.]+: (failed|exception|hard resetting)|NVRM: Xid|BUG:|Oops|soft lockup|hard LOCKUP|thermal.*(critical|throttl)|segfault.*kernel|watchdog: BUG'
        grep -E "$PATRON" "$TMP/dmesg" >"$TMP/kerr"
        N=$(wc -l <"$TMP/kerr")
        # Los del propio análisis (desde que empezó) pesan más.
        DUR=$(journalctl -k --since "@$T0" --no-pager 2>/dev/null | grep -cE "$PATRON")
        r "   Desde el arranque: $N mensajes de hardware/errores ($DUR durante este análisis)"
        if [ "$N" -gt 0 ]; then
            sed -E 's/^\[[^]]*\] *//; s/^[^ ]+ +[^ ]+ +//' "$TMP/kerr" | sed -E 's/[0-9]+/N/g' | sort | uniq -c | sort -rn | head -8 \
                | while read -r c l; do r "     ${c}× ${l:0:150}"; done
            if grep -qE 'Machine Check|Hardware Error|mce: ' "$TMP/kerr"; then error "errores de máquina (MCE) en el kernel: CPU/RAM/placa"
            elif [ "$DUR" -gt 0 ]; then aviso "$DUR errores de hardware en el kernel durante el análisis"
            else aviso "$N errores de hardware en el kernel desde el arranque"; fi
        fi
        dato kernel_errores "$N"; corto "$N errores"
    fi
    fin_paso
fi

# ==================================================================== PANICS
# Panics, oops y cuelgues de los ARRANQUES ANTERIORES (un panic no se ve en el
# arranque en el que ocurre: el equipo se para). Fuentes: el journal de cada
# arranque (persistente en /var/log/journal), pstore (volcado del panic que la
# UEFI guarda y systemd-pstore deja en /var/lib/systemd/pstore) y /var/crash
# (kdump, apport). Un arranque que acaba sin apagado limpio = cuelgue, panic
# sin registrar o corte de luz.
# Cada panic distinto (un arranque con panic/oops, o un volcado que no es de
# ninguno) deja su propio fichero en $DIR_SAL/panics/ con todo lo que se sabe.
GRAVE_RE='Kernel panic|kernel BUG at|BUG: unable to handle|BUG: kernel NULL|Oops:|general protection fault|Unable to handle kernel|hard LOCKUP|Machine Check Exception|mce: \[Hardware Error\]'
LEVE_RE='soft lockup|rcu: INFO: rcu_[a-z]+ (self-)?detected stall|detected stalls on CPUs|blocked for more than [0-9]+ seconds|NVRM: Xid'

# Firma de un panic: primera línea grave (sin números ni direcciones) + la
# función de la línea RIP/PC. Dos panics con la misma firma son el mismo fallo.
firma_panic() {   # firma_panic <fichero>
    python3 - "$1" "$GRAVE_RE" <<'PY'
import re, sys
t = open(sys.argv[1], errors='replace').read()
g = re.compile(sys.argv[2])
prim = next((l for l in t.splitlines() if g.search(l)), '')
prim = re.sub(r'^.*?kernel: ', '', prim)
prim = re.sub(r'^\S+\s+\S+\s+kernel:\s*', '', prim)
prim = re.sub(r'^<\d+>', '', prim)
prim = re.sub(r'^\[\s*[\d.]+\]\s*', '', prim)
prim = re.sub(r'0x[0-9a-fA-F]+|[0-9a-f]{8,}|\d+', 'N', prim).strip()
m = re.search(r'(?:RIP|pc) ?: ?(?:\S+:)?([A-Za-z_][\w.]*)', t)
f = (prim[:100] or 'sin traza reconocible') + (' @ ' + m.group(1) if m else '')
print(f.replace('|', '/'))
PY
}

# Letras de "Tainted:" del kernel → texto.
explica_tainted() {   # explica_tainted "P           OE"
    local l
    for l in $(grep -o '[A-Z]' <<<"$1" | sort -u); do
        case "$l" in
            P) echo "     P: módulo propietario cargado (p. ej. nvidia)" ;;
            O) echo "     O: módulo fuera del árbol del kernel (zfs, nvidia, vmmon/vmnet…)" ;;
            E) echo "     E: módulo sin firmar" ;;
            G) ;;
            D) echo "     D: el kernel ya había muerto antes (oops previo): mirar el PRIMER error" ;;
            W) echo "     W: hubo un WARNING del kernel antes" ;;
            M) echo "     M: la CPU avisó de un Machine Check (hardware)" ;;
            B) echo "     B: página de memoria mala detectada (hardware/RAM)" ;;
            L) echo "     L: hubo un soft lockup antes" ;;
            C) echo "     C: driver de staging" ;;
            I) echo "     I: apaño por firmware/BIOS defectuoso" ;;
            F) echo "     F: módulo cargado a la fuerza" ;;
            R) echo "     R: módulo descargado a la fuerza" ;;
            S) echo "     S: CPU fuera de especificación" ;;
            U) echo "     U: marcado por el usuario" ;;
            A) echo "     A: tabla ACPI sustituida" ;;
            K) echo "     K: kernel con live patch" ;;
            *) echo "     $l: (ver https://docs.kernel.org/admin-guide/tainted-kernels.html)" ;;
        esac
    done
}

# Paquetes instalados/actualizados/quitados en los 7 días antes del panic.
apt_antes() {   # apt_antes <epoch>
    python3 - "$1" "$APTLOG_DIR" <<'PY'
import gzip, glob, os, re, sys, time
t = int(sys.argv[1]); d = sys.argv[2]
bloques = []
for f in sorted(glob.glob(os.path.join(d, 'history.log*'))):
    try:
        txt = (gzip.open(f, 'rt', errors='replace') if f.endswith('.gz') else open(f, errors='replace')).read()
    except Exception:
        continue
    for b in txt.split('\n\n'):
        m = re.search(r'Start-Date: (\S+\s+\S+)', b)
        if not m: continue
        try: e = time.mktime(time.strptime(m.group(1), '%Y-%m-%d %H:%M:%S'))
        except Exception: continue
        if t - 7 * 86400 <= e <= t:
            bloques.append((e, b.strip()))
if not bloques:
    print('   (ningún cambio de paquetes con apt en esos 7 días)')
for e, b in sorted(bloques):
    for l in b.splitlines():
        if l.startswith(('Start-Date', 'Commandline', 'Install', 'Upgrade', 'Remove', 'Purge')):
            k, _, v = l.partition(': ')
            # Lo que más afecta a un panic, delante.
            imp = [p for p in re.split(r'\), ', v) if re.search(r'linux-|nvidia|zfs|firmware|mesa|vmware|microcode|dkms', p)]
            if k in ('Install', 'Upgrade', 'Remove', 'Purge') and imp:
                print('   %-11s %s' % (k + ':', '), '.join(imp)[:900]))
                resto = len(re.split(r'\), ', v)) - len(imp)
                if resto: print('   %-11s + %d paquetes más' % ('', resto))
            else:
                print('   %-11s %s' % (k + ':', v[:300]))
    print()
PY
}

# Escribe el fichero de un panic. Deja su ruta y su firma en INC_FICH/INC_FIRMA.
incidente() {   # incidente <boot id o -> <volcados "tipo|ruta" por línea> <epoch de referencia>
    local id=$1 volc=$2 tref=$3 tipo1="" idx="-" t1=0 t2=0 sig="" k="?" fin="-" f nom tipo ruta x fuentes="" sigl
    : >"$TMP/ik"; : >"$TMP/iv"
    if [ "$id" != - ]; then
        read -r idx _ t1 t2 < <(awk -v id="$id" '$2 == id' "$TMP/arranques")
        sig=$(awk -v id="$id" 'f { print $2; exit } $2 == id { f = 1 }' "$TMP/arranques")
        journalctl -b "$id" -k -o short-iso --no-pager >"$TMP/ik" 2>/dev/null
        k=$(grep -m1 -o 'Linux version [^ ]*' "$TMP/ik" | awk '{ print $3 }')
        tref=$t2
        if journalctl -b "$id" -n 80 -o cat --no-pager 2>/dev/null \
               | grep -qE 'Journal stopped|systemd-shutdown|Reached target .*(Power-Off|Reboot|Halt|Kexec|Shutdown)|reboot: (Restarting|Power down)'; then
            fin="apagado limpio"
        else
            fin="SIN APAGADO LIMPIO"
        fi
        [ "$idx" = 0 ] && fin="en curso"
        fuentes="journal ($(grep -cE "$GRAVE_RE" "$TMP/ik") líneas de fallo)"
    fi
    # Contenido de los volcados (texto; las partes binarias/base64 de apport fuera).
    while IFS='|' read -r tipo ruta; do
        [ -n "$tipo" ] || continue
        tipo1=${tipo1:-$tipo}
        fuentes+="${fuentes:+ · }$tipo ${ruta##*/}"
        for x in $ruta; do
            if [ -d "$x" ]; then
                find "$x" -type f | sort -V | while read -r y; do
                    echo "----- $tipo: $y ($(date -r "$y" '+%F %H:%M'))"; tr -d '\000' <"$y" | head -3000
                done
            elif [ -f "$x" ]; then
                echo "----- $tipo: $x ($(date -r "$x" '+%F %H:%M'))"
                tr -d '\000' <"$x" | grep -av '^ [A-Za-z0-9+/=]\{60,\}$' | head -3000
            fi
        done >>"$TMP/iv"
    done <<<"$volc"
    cat "$TMP/ik" "$TMP/iv" >"$TMP/itodo"
    sigl=$(firma_panic "$TMP/itodo")
    nom="panic-${EQUIPO}-$(date -d "@$tref" '+%Y%m%d-%H%M')-$([ "$id" != - ] && echo "${id:0:8}" || echo "${tipo1:-volcado}").txt"
    f="$PANDIR/$nom"
    {
        echo "================================================================"
        echo " Kernel panic en $EQUIPO · $(date -d "@$tref" '+%F %H:%M')"
        echo "================================================================"
        echo " Firma:      $sigl"
        if [ "$id" != - ]; then
            echo " Arranque:   índice $idx · id $id"
            echo "             $(date -d "@$t1" '+%F %H:%M:%S') → $(date -d "@$t2" '+%F %H:%M:%S') ($(mmss $(( (t2 - t1) / 60 )) | sed 's/:/h/'))"
            echo " Kernel:     $k"
            echo " Final:      $fin"
        else
            echo " Arranque:   no está en el journal (volcado más antiguo que el journal)"
        fi
        echo " Fuentes:    ${fuentes:-?}"
        echo " Generado:   $(date '+%F %H:%M') por analiza.sh ($RAW)"
        echo ""
        echo "== Resumen del fallo"
        grep -ahE "$GRAVE_RE|$LEVE_RE" "$TMP/itodo" | awk '{ m = $0; sub(/^[^ ]+ [^ ]+ kernel: /, "", m); n = m; gsub(/[0-9a-f]{8,}|[0-9]+/, "N", n); if (!(n in v)) { v[n] = 1; print "   " substr($0, 1, 220) } }' | head -12
        TAINT=$(grep -aoE 'Tainted: [A-Z ]+' "$TMP/itodo" | head -1 | sed 's/Tainted: //')
        grep -ahE -m1 'CPU: [0-9]+ .*PID: [0-9]+ .*Comm:' "$TMP/itodo" | sed 's/^/   Proceso:  /' | cut -c1-250
        grep -ahE -m1 'Hardware name:' "$TMP/itodo" | sed 's/^.*Hardware name: */   Equipo:   /'
        grep -ahE -m2 '(RIP|pc) ?:' "$TMP/itodo" | sed 's/^/   /' | cut -c1-250
        if [ -n "$TAINT" ]; then echo "   Tainted:  $TAINT"; explica_tainted "$TAINT"; fi
        grep -ahE -m1 'Modules linked in:' "$TMP/itodo" | sed 's/^.*Modules linked in: */   Módulos cargados: /' | fold -s -w 110 | sed '2,$s/^/      /'
        echo ""
        echo "== Pila de llamadas (Call Trace) del primer fallo"
        awk '/Call Trace:|Call trace:/ { c = 1; n = 0 } c { print "   " $0; if (++n > 45 || /---\[ end trace|<\/TASK>/) exit }' "$TMP/itodo" | cut -c1-200 >"$TMP/ipila"
        if [ -s "$TMP/ipila" ]; then cat "$TMP/ipila"; else echo "   (no se guardó la pila)"; fi
        echo ""
        if [ "$id" != - ]; then
            echo "== Contexto del arranque"
            grep -aE -m1 'Command line:' "$TMP/ik" | sed 's/^.*Command line: */   Línea de arranque: /'
            grep -aE -m1 'DMI:' "$TMP/ik" | sed 's/^.*DMI: */   DMI\/BIOS: /'
            grep -aE 'microcode:' "$TMP/ik" | head -2 | sed 's/^\S* \S* kernel: /   /'
            grep -aE 'taints kernel|module verification failed|loading out-of-tree' "$TMP/ik" | sed 's/^\S* \S* kernel: /   /' | sort -u | head -8
            if [ "$k" != "?" ]; then
                for m in zfs nvidia vmmon vmnet; do
                    v=$(modinfo -k "$k" -F version "$m" 2>/dev/null | head -1)
                    [ -n "$v" ] && echo "   Módulo $m para $k: $v"
                done
                v=$(dpkg-query -W -f='${Version} ${db:Status-Abbrev}' "linux-image-$k" 2>/dev/null)
                echo "   Paquete linux-image-$k: ${v:-no instalado (ya quitado)}"
            fi
            echo ""
            echo "== Bloque del fallo (log del kernel, desde 150 líneas antes del primer error)"
            N1=$(grep -anE "$GRAVE_RE" "$TMP/ik" | head -1 | cut -d: -f1)
            if [ -n "$N1" ]; then
                tail -n +"$(( N1 > 150 ? N1 - 150 : 1 ))" "$TMP/ik" | head -2000 | sed 's/^/   /'
            else
                echo "   (el journal no guardó el fallo: el equipo se paró antes de escribirlo; ver los volcados)"
                echo "   Últimas 40 líneas del kernel en ese arranque:"
                tail -n 40 "$TMP/ik" | sed 's/^/   /'
            fi
            echo ""
            echo "== Últimas 200 líneas de TODO el journal de ese arranque (qué estaba pasando)"
            journalctl -b "$id" -n 200 -o short-iso --no-pager 2>/dev/null | sed 's/^/   /' | cut -c1-300
            echo ""
            echo "== Avisos y errores del kernel en ese arranque (warning o más, máx. 300)"
            journalctl -b "$id" -k -p warning -o short-iso --no-pager 2>/dev/null | head -300 | sed 's/^/   /' | cut -c1-300
            echo ""
            if [ -n "$sig" ]; then
                echo "== Arranque siguiente ($sig): primeras líneas y avisos de recuperación"
                journalctl -b "$sig" -k -o short-iso --no-pager 2>/dev/null >"$TMP/isig"
                head -3 "$TMP/isig" | sed 's/^/   /'
                grep -aiE 'pstore|efi-pstore|EDAC|mce:|Hardware Error|unclean|recover|dirty|orphan|zfs.*(import|error)|fsck' "$TMP/isig" | head -30 | sed 's/^/   /' | cut -c1-250
                echo ""
            fi
        fi
        echo "== Paquetes cambiados con apt en los 7 días anteriores"
        apt_antes "$tref"
        if [ -s "$TMP/iv" ]; then
            echo "== Volcados (pstore / kdump / apport)"
            sed 's/^/   /' "$TMP/iv" | cut -c1-300
            echo ""
        fi
    } >"$f"
    INC_FICH+=("$f"); INC_FIRMA+=("$sigl"); INC_IDX+=("$idx")
}

# Arranque al que pertenece un volcado.
#   pstore: lo guarda systemd-pstore al arrancar DESPUÉS del panic → si cae en
#           los 15 primeros minutos de un arranque, es del anterior.
#   kdump:  su carpeta lleva la hora del panic → el arranque que la contiene.
#   Entre dos arranques (equipo apagado) → el anterior. Antes del journal → ninguno.
arranque_de() {   # arranque_de <tipo> <epoch>
    local tipo=$1 t=$2 prev="-" i id t1 t2
    while read -r i id t1 t2; do
        if [ "$t" -lt $((t1 - 60)) ]; then echo "$prev"; return; fi
        if [ "$t" -le $((t2 + 120)) ]; then
            if [ "$tipo" = pstore ] && [ "$t" -le $((t1 + 900)) ]; then echo "$prev"; else echo "$id"; fi
            return
        fi
        prev=$id
    done <"$TMP/arranques"
    echo "$prev"
}

if quiere panics; then
    paso panics "Kernel panics y cuelgues (últimos $ARRANQUES arranques)"
    PSTORE_RUTAS="${ANALISIS_PSTORE:-/var/lib/systemd/pstore /sys/fs/pstore}"   # variables solo para pruebas
    CRASH_DIR="${ANALISIS_CRASH:-/var/crash}"
    APTLOG_DIR="${ANALISIS_APTLOG:-/var/log/apt}"
    PANDIR="$DIR_SAL/panics"; mkdir -p "$PANDIR"
    INC_FICH=(); INC_FIRMA=(); INC_IDX=()
    declare -A INC=() VOLC=()
    [ -d /var/log/journal ] || nomedido "journal no persistente (/var/log/journal no existe): solo se ve el arranque actual"
    # índice id primera-entrada última-entrada (segundos)
    journalctl --list-boots --no-pager -o json 2>/dev/null | python3 -c '
import json, sys
try: l = json.load(sys.stdin)
except Exception: sys.exit(0)
for b in l: print(b["index"], b["boot_id"], int(b["first_entry"]) // 10**6, int(b["last_entry"]) // 10**6)' >"$TMP/arranques"
    if [ ! -s "$TMP/arranques" ]; then      # systemd viejo: formato texto
        journalctl --list-boots --no-pager 2>/dev/null | awk '$1 ~ /^-?[0-9]+$/' | while read -r i id d1 f1 h1 z1 d2 f2 h2 z2; do
            echo "$i $id $(date -d "$f1 $h1 $z1" +%s 2>/dev/null || echo 0) $(date -d "$f2 $h2 $z2" +%s 2>/dev/null || echo 0)"
        done >"$TMP/arranques"
    fi
    tail -n "$((ARRANQUES + 1))" "$TMP/arranques" >"$TMP/arr" 2>/dev/null
    NB=0; SUCIOS=0; CONGRAVE=0; CONLEVE=0
    declare -A PK_N=() PK_S=() PK_P=()
    if [ ! -s "$TMP/arr" ]; then
        nomedido "no se puede leer la lista de arranques del journal"
    else
        r "   Arranque              Duración  Kernel              Final"
        while read -r i id t1 t2; do
            NB=$((NB + 1))
            journalctl -b "$id" -k -o short-iso --no-pager 2>/dev/null >"$TMP/bk"
            K=$(grep -m1 -o 'Linux version [^ ]*' "$TMP/bk" | awk '{ print $3 }')
            grep -E "$GRAVE_RE" "$TMP/bk" >"$TMP/bg"; NG=$(wc -l <"$TMP/bg")
            grep -E "$LEVE_RE" "$TMP/bk" >"$TMP/bl"; NL=$(wc -l <"$TMP/bl")
            if [ "$i" = 0 ]; then
                FINAL="en curso"
            elif journalctl -b "$id" -n 80 -o cat --no-pager 2>/dev/null \
                   | grep -qE 'Journal stopped|systemd-shutdown|Reached target .*(Power-Off|Reboot|Halt|Kexec|Shutdown)|reboot: (Restarting|Power down)'; then
                FINAL="apagado limpio"
            else
                FINAL="SIN APAGADO LIMPIO"; SUCIOS=$((SUCIOS + 1)); PK_S[${K:-?}]=$(( ${PK_S[${K:-?}]:-0} + 1 ))
            fi
            PK_N[${K:-?}]=$(( ${PK_N[${K:-?}]:-0} + 1 ))
            [ "$NG" -gt 0 ] && { CONGRAVE=$((CONGRAVE + 1)); PK_P[${K:-?}]=$(( ${PK_P[${K:-?}]:-0} + 1 )); FINAL+=" · $NG panic/oops"; INC[$id]=1; }
            [ "$NL" -gt 0 ] && { CONLEVE=$((CONLEVE + 1)); FINAL+=" · $NL cuelgues/stalls"; }
            r "$(printf '   %3s %s  %8s  %-18s  %s' "$i" "$(date -d "@$t1" '+%F %H:%M')" "$(mmss $(( (t2 - t1) / 60 )) | sed 's/:/h/')" "${K:-?}" "$FINAL")"
            # Las primeras líneas distintas de cada tipo, con su hora.
            cat "$TMP/bg" "$TMP/bl" | awk '{ t = $1; $1 = $2 = ""; sub(/^ +kernel: /, ""); sub(/^ +/, ""); m = $0; gsub(/[0-9a-f]{8,}|[0-9]+/, "N", m); if (!(m in v)) { v[m] = 1; print "         " substr(t, 12, 8) " " substr($0, 1, 140) } }' \
                | head -4 | while IFS= read -r l; do r "$l"; done
        done <"$TMP/arr"
        r "   Por kernel:"
        for k in "${!PK_N[@]}"; do
            r "     $k: ${PK_N[$k]} arranques · ${PK_S[$k]:-0} sin apagado limpio · ${PK_P[$k]:-0} con panic/oops"
        done
        [ "$NB" -le 1 ] && r "   (en el journal solo está el arranque actual)"
    fi
    # ---- Volcados: "tipo|ruta|epoch". En /sys/fs/pstore las partes de un mismo
    # registro (dmesg-efi-NNNN01, …02) van juntas.
    : >"$TMP/volcados"
    for base in $PSTORE_RUTAS; do
        if [ "$base" = /sys/fs/pstore ] || [[ "$base" == *sys-pstore* ]]; then
            for x in "$base"/*; do [ -f "$x" ] && echo "${x%[0-9][0-9]}"; done | sort -u | while read -r g; do
                echo "pstore|${g}*|$(stat -c %Y ${g}* | sort -n | tail -1)"
            done >>"$TMP/volcados"
        else
            for x in "$base"/*; do
                [ -e "$x" ] || continue
                echo "pstore|$x|$(find "$x" -type f -printf '%T@\n' 2>/dev/null | sort -n | tail -1 | cut -d. -f1)" >>"$TMP/volcados"
            done
        fi
    done
    for d in "$CRASH_DIR"/[0-9]*/; do
        [ -d "$d" ] || continue
        n=$(basename "$d")
        t=$(date -d "${n:0:8} ${n:8:2}:${n:10:2}" +%s 2>/dev/null || stat -c %Y "$d")
        echo "kdump|${d%/}|$t" >>"$TMP/volcados"
    done
    for x in "$CRASH_DIR"/linux-image-*.crash "$CRASH_DIR"/*kernel*.crash; do
        [ -f "$x" ] && echo "apport|$x|$(stat -c %Y "$x")" >>"$TMP/volcados"
    done
    NPS=0; NKD=0; SOLOS=()
    while IFS='|' read -r tipo ruta t; do
        [ -n "$tipo" ] || continue
        b=$(arranque_de "$tipo" "${t:-0}")
        L=$(cat $ruta 2>/dev/null | tr -d '\000' | grep -aE -m1 "$GRAVE_RE|$LEVE_RE" | head -1 | cut -c1-120)
        [ -d "${ruta%\*}" ] && L=$(find "$ruta" -type f -exec cat {} + 2>/dev/null | tr -d '\000' | grep -aE -m1 "$GRAVE_RE|$LEVE_RE" | cut -c1-120)
        BIDX=$(awk -v id="$b" '$2 == id { print $1 }' "$TMP/arranques")
        r "   $tipo $(date -d "@${t:-0}" '+%F %H:%M') ${ruta##*/} → arranque ${BIDX:-?}: ${L:-(sin línea de panic reconocible)}"
        case "$tipo" in pstore) NPS=$((NPS + 1)) ;; kdump) NKD=$((NKD + 1)) ;; apport) aviso "oops del kernel recogido por apport: ${ruta##*/}" ;; esac
        if [ "$b" != - ]; then
            INC[$b]=1; VOLC[$b]+="$tipo|$ruta"$'\n'
        else
            SOLOS+=("$tipo|$ruta|$t")
        fi
    done <"$TMP/volcados"
    [ "$NPS" -gt 0 ] && error "$NPS volcados de kernel panic en pstore (se pueden borrar tras revisarlos: rm -rf /var/lib/systemd/pstore/*)"
    [ "$NKD" -gt 0 ] && error "$NKD volcados de kdump en $CRASH_DIR"

    # ---- Un fichero por panic (en el orden de los arranques; luego los volcados sueltos)
    while read -r i id t1 t2; do
        [ -n "${INC[$id]:-}" ] && incidente "$id" "${VOLC[$id]:-}" "$t2"
    done <"$TMP/arranques"
    for s in "${SOLOS[@]}"; do
        IFS='|' read -r tipo ruta t <<<"$s"
        incidente - "$tipo|$ruta" "$t"
    done
    if [ "${#INC_FICH[@]}" -gt 0 ]; then
        declare -A NFIRMA=()
        for s in "${INC_FIRMA[@]}"; do NFIRMA[$s]=$(( ${NFIRMA[$s]:-0} + 1 )); done
        r "   Un fichero por panic (${#INC_FICH[@]}, ${#NFIRMA[@]} fallos distintos) en $PANDIR/:"
        for n in "${!INC_FICH[@]}"; do
            s=${INC_FIRMA[$n]}
            r "     ${INC_FICH[$n]##*/}  (arranque ${INC_IDX[$n]})"
            r "        $s$([ "${NFIRMA[$s]}" -gt 1 ] && echo "  [×${NFIRMA[$s]}, mismo fallo]")"
            # Al final de cada fichero, los otros panics con la misma firma.
            {
                echo "== Otros panics con la misma firma"
                otros=0
                for m in "${!INC_FICH[@]}"; do
                    [ "$m" != "$n" ] && [ "${INC_FIRMA[$m]}" = "$s" ] && { echo "   ${INC_FICH[$m]##*/}"; otros=1; }
                done
                [ "$otros" = 0 ] && echo "   ninguno"
            } >>"${INC_FICH[$n]}"
            printf 'PANICFILE|%s\n' "${INC_FICH[$n]}" >>"$MAQ"
        done
        dato panics_ficheros "${#INC_FICH[@]}"; dato panics_distintos "${#NFIRMA[@]}"
        unset NFIRMA
    fi

    # ---- veredicto
    [ "$CONGRAVE" -gt 0 ] && error "$CONGRAVE de $NB arranques con kernel panic/oops"
    [ "$CONLEVE" -gt 0 ] && aviso "$CONLEVE de $NB arranques con cuelgues de CPU/tareas (soft lockup, stall, tareas bloqueadas, Xid)"
    [ "$SUCIOS" -ge 2 ] && aviso "$SUCIOS de $NB arranques terminaron sin apagado limpio (cuelgue, panic sin registrar o corte de luz)"
    [ "$SUCIOS" -eq 1 ] && r "   1 arranque terminó sin apagado limpio (puede ser un corte de luz o apagado a botón)"
    dato arranques "$NB"; dato arranques_sucios "$SUCIOS"; dato arranques_panic "$CONGRAVE"; dato pstore "$NPS"
    corto "$NB arranques · $SUCIOS sin apagado limpio · $CONGRAVE con panic · pstore $NPS · ${#INC_FICH[@]} ficheros"
    unset PK_N PK_S PK_P INC VOLC
    fin_paso
fi

# ================================================================== RESUMEN
TOTAL=$(( $(date +%s) - T0 ))
{
    echo "================================================================"
    echo " Análisis de $EQUIPO · $(date -d "@$T0" '+%F %H:%M') → $(date '+%H:%M') · total $(mmss $TOTAL)"
    echo " Estado: $GLOBAL"
    echo "================================================================"
    echo " Tiempos por paso"
    printf '%s\n' "${TABLA[@]}"
    echo " Avisos y errores"
    if [ "${#AVISOS[@]}" -eq 0 ]; then echo "   ninguno"; else printf '   - %s\n' "${AVISOS[@]}"; fi
    echo "----------------------------------------------------------------"
    cat "$CUERPO"
    echo ""
    echo "Detalle bruto: $RAW"
} >"$RES"
cp -f "$RES" "$DIR_SAL/ultimo-resumen.txt"
cat "$RES"
cat "$MAQ"
printf 'DATOS|%s|%s\n' "$EQUIPO" "$(IFS=';'; echo "estado=$GLOBAL;t_total=$TOTAL;${DATOS[*]}")"
printf 'GLOBAL|%s|%s|%s\n' "$EQUIPO" "$TOTAL" "$GLOBAL"
printf 'FICHERO|%s\n' "$RES"
log "===== fin: $GLOBAL en $(mmss $TOTAL)"
case "$GLOBAL" in ERROR) exit 2 ;; AVISO) exit 1 ;; *) exit 0 ;; esac
