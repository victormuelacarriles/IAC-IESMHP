#!/bin/bash
# vs 06/10/2026 — rol Ansible "vmware" (IAC-IESMHP)
# Compila e instala los módulos vmmon/vmnet de VMware Workstation SIN interfaz
# gráfica, para que VMware NUNCA pida "Kernel Module Updater" al usuario.
#
# Motivo: en el primer arranque 3-SetupPrimerInicio.sh hace full-upgrade (kernel
# nuevo) y Ansible corre SIN reiniciar; vmware-modconfig solo compila para el
# kernel EN USO (el viejo) y, al arrancar con el nuevo, VMware pide compilar.
# VMware no usa DKMS, así que este script se llama:
#   - desde el rol (todos los kernels instalados),
#   - desde /etc/kernel/{postinst.d,header_postinst.d}/zz-iac-vmware (kernel nuevo),
#   - desde iac-vmware-modulos.service en cada arranque (--arranque: kernel en uso).
#
# Uso: iac-vmware-modulos.sh                 -> todos los kernels de /lib/modules
#      iac-vmware-modulos.sh <versión> ...    -> esos kernels
#      iac-vmware-modulos.sh --arranque       -> solo uname -r
# Log: /var/log/IAC-IESMHP/Ubuntu/vmware-modulos.log

LOG=/var/log/IAC-IESMHP/Ubuntu/vmware-modulos.log
mkdir -p "$(dirname "$LOG")"
exec > >(tee -a "$LOG") 2>&1 </dev/null
echo "=== $(date '+%F %T') $0 $* ==="

SRC=/usr/lib/vmware/modules/source
if [ ! -d /usr/lib/vmware ]; then
    echo "[INF] VMware no está instalado: nada que hacer"
    exit 0
fi

if [ "$1" = "--arranque" ]; then
    KERNELS="$(uname -r)"
elif [ $# -gt 0 ]; then
    KERNELS="$*"
else
    KERNELS="$(ls /lib/modules)"
fi

RC=0
for k in $KERNELS; do
    if modinfo -k "$k" vmmon >/dev/null 2>&1 && modinfo -k "$k" vmnet >/dev/null 2>&1; then
        echo "[OK ] $k: vmmon/vmnet ya instalados"
        continue
    fi
    if [ ! -d "/lib/modules/$k/build" ]; then
        # Sin cabeceras no se puede compilar. Si es el hook de linux-image, el de
        # linux-headers (header_postinst.d) lo volverá a intentar al instalarlas.
        echo "[AVS] $k: sin cabeceras (/lib/modules/$k/build): se omite"
        continue
    fi
    if [ ! -f "$SRC/vmmon.tar" ] || [ ! -f "$SRC/vmnet.tar" ]; then
        # Respaldo: vmware-modconfig solo sabe compilar para el kernel en uso y
        # necesita una pantalla (aunque sea virtual).
        if [ "$k" = "$(uname -r)" ]; then
            echo "[INF] $k: sin fuentes en $SRC; uso vmware-modconfig"
            xvfb-run -a /usr/lib/vmware/bin/vmware-modconfig --install-all || RC=1
        else
            echo "[ERR] $k: sin fuentes en $SRC y no es el kernel en uso"
            RC=1
        fi
        continue
    fi
    TMP=$(mktemp -d)
    for m in vmmon vmnet; do
        tar -xf "$SRC/$m.tar" -C "$TMP"
        # VM_UNAME fija el kernel destino (por defecto el Makefile usa uname -r)
        if make -C "$TMP/$m-only" VM_UNAME="$k" -j"$(nproc)" >"$TMP/$m.make.log" 2>&1; then
            KO="$TMP/$m-only/$m.ko"
            [ -f "$KO" ] || KO="$TMP/$m.o"
            if [ -f "$KO" ]; then
                install -D -m 644 "$KO" "/lib/modules/$k/misc/$m.ko"
                echo "[OK ] $k: $m compilado e instalado en /lib/modules/$k/misc/"
            else
                echo "[ERR] $k: make de $m terminó pero no generó $m.ko"
                RC=1
            fi
        else
            echo "[ERR] $k: falló la compilación de $m. Últimas líneas:"
            tail -n 30 "$TMP/$m.make.log"
            RC=1
        fi
    done
    depmod -a "$k"
    rm -rf "$TMP"
done

# Cargar los módulos en el kernel en uso (si existen). Si no cargan estando
# compilados, lo habitual es Secure Boot (módulos sin firmar).
if modinfo vmmon >/dev/null 2>&1 && modinfo vmnet >/dev/null 2>&1; then
    modprobe vmmon && modprobe vmnet || echo "[AVS] vmmon/vmnet no cargan (¿Secure Boot? mokutil --sb-state)"
fi
exit $RC
