# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Propósito del proyecto

Automatización del despliegue de Ubuntu 26.04 Desktop en equipos del IES Miguel Herrero (Torrelavega). El flujo genera una ISO personalizada de Ubuntu, que al arrancar particiona los discos, copia el sistema operativo e instala GRUB sin intervención manual.

**Metodología de trabajo**: el usuario arranca la ISO en una máquina virtual (VMware), recoge los logs y los pega aquí para diagnosticar fallos y optimizar el proceso.

### Protocolo de diagnóstico (seguir en este orden)
1. Leer el fichero de cambios más reciente en `Ubuntu/RegistroDeCambios/` para saber qué se tocó en la última sesión y qué consecuencias puede haber tenido.
2. Leer el log pegado o el fichero `Ubuntu/ISO/26.04/logs/Ubuntu/4-Comprobaciones.sh.log`.
3. **Antes de proponer un fix**, cruzar cada `[ERR]` con la lista de falsos positivos conocidos documentada más abajo — muchos errores son del propio script de diagnóstico, no del sistema instalado.
4. Si el error es real (no falso positivo), buscar en el script correspondiente la línea exacta que lo genera y proponer el cambio mínimo necesario.
5. Documentar el fix en `Ubuntu/RegistroDeCambios/YYYYMMDD-Cambios.md` (crear el fichero del día si no existe).

---

## Cadena de ejecución completa

```
0a-CreaISO.sh          ← Se ejecuta en el equipo de desarrollo (Linux), genera la ISO
  └── [ISO bootea]
       └── iac-iesmhp-launch.sh    ← autostart GNOME del Live CD, abre terminal
            └── iac-iesmhp-run.sh  ← instalado en el squashfs por 0a-CreaISO.sh
                 └── 0b-Github.sh  ← clona el repo IAC-IESMHP desde GitHub
                      └── 1-SetupLiveCD.sh         ← particiona discos, monta squashfs capas, prepara chroot
                           └── 2-SetupSOdesdeLiveCD.sh  ← corre DENTRO del chroot, configura el SO instalado
                                └── [reboot → primer arranque]
                                     └── 3-SetupPrimerInicio.service  ← systemd oneshot, configura hostname/IP/Ansible
                                          └── 4-Comprobaciones.sh     ← diagnóstico (llamado desde 2 y 3)
```

---

## Comandos clave

### Generar la ISO (en equipo Linux con Ubuntu)
```bash
# Instalar dependencias
sudo apt install xorriso mtools squashfs-tools gdisk -y

# Actualizar el repo y generar la ISO
cd ~/xIAC-IESMHP/Ubuntu/ISO/26.04
git reset --hard origin/main && git pull && chmod +x ./0a-CreaISO.sh
sudo ./0a-CreaISO.sh ~/Descargas/ubuntu-26.04-desktop-amd64.iso 0b-Github.sh ~/Descargas/mi-ubuntu.iso
# Argumento 4 opcional: ruta a un PNG personalizado como fondo (por defecto FondoIES-Ubuntu-Gris.png)
```

### Ver logs en el equipo instalado
```bash
ls /var/log/IAC-IESMHP/Ubuntu/
# 1-SetupLiveCD.sh.log         ← particionado y copia del FS
# 2-SetupSOdesdeLiveCD.sh.log  ← configuración en chroot
# 2-SetupSOdesdeLiveCD.steps   ← resumen de pasos con timestamps (diagnóstico rápido)
# 3-SetupPrimerInicio.sh.log   ← primer arranque
# 4-Comprobaciones.sh.log      ← diagnóstico
```

---

## Arquitectura y decisiones clave

### 0a-CreaISO.sh — Generación de la ISO
- **Squashfs multicapa (Ubuntu 26.04+)**: la ISO usa capas `minimal.squashfs` / `minimal.standard.squashfs` / `minimal.standard.live.squashfs`. El script detecta la capa `*.live.squashfs` para insertar el autostart de escritorio, que es donde vive el entorno GNOME.
- **snapd enmascarado**: se enmascaran `snapd.service`, `snapd.socket` y `snapd.seeded.service` vía symlinks a `/dev/null` en el squashfs. Esto reduce el tiempo de arranque del Live CD de ~3 min a ~10 s y bloquea definitivamente `ubuntu-desktop-bootstrap` (el instalador snap de Ubuntu 26.04).
- **Autostart GNOME**: se escribe `iac-iesmhp-setup.desktop` tanto en `/etc/skel/.config/autostart` como en `/home/ubuntu/.config/autostart` para cubrir el caso de que el home del usuario `ubuntu` preexista o se cree desde skel. El `.desktop` llama a `iac-iesmhp-launch.sh`, que aplica el fondo y luego abre un terminal con `iac-iesmhp-run.sh`.
- **Boot UEFI únicamente**: se eliminan `isolinux/` y `boot/grub/i386-pc/`. La detección del modo EFI (appended partition GPT vs El Torito) es automática vía `xorriso -report_el_torito`, con fallback a `sfdisk+dd`.

### 0b-Github.sh — Bootstrap en el Live CD
- Se embebe en la raíz del squashfs como `/0b-Github.sh` (no en PATH estándar).
- Enmascara `/usr/sbin/update-initramfs` → `/bin/true` y desactiva `man-db auto-update` antes de cualquier `apt-get install` para evitar bloqueos en el entorno live.
- Espera red con 12 reintentos (5 s cada uno) antes de clonar el repo.
- El repo se clona en `/opt/IAC-IESMHP`.

### 1-SetupLiveCD.sh — Particionado e instalación del FS
- **Detección de discos**: ignora USB y loop; usa `lsblk -dno NAME,SIZE,TRAN`.
  - 2×NVMe → pequeño=`/`, grande=`/home`
  - NVMe+SD → NVMe=`/`, SD=`/home`
- **Esquema de particiones** (disco pequeño, GPT): EFI 512 MiB | swap 8 GiB | root resto. Disco grande: /home entero.
- **Capas squashfs**: Ubuntu 26.04 combina `minimal.squashfs + minimal.standard.squashfs + minimal.standard.live.squashfs` con overlayfs en `/tmp/merged`; Ubuntu <24.04 usa `filesystem.squashfs` único.
- Copia el FS con `rsync` (excluyendo `/etc/fstab` y `/etc/machine-id`).
- Pasa las particiones al chroot mediante `/mnt/tmp/.iac-partitions.env` porque `lsblk` dentro del chroot ve los mount points del host, no del sistema instalado.
- Si `2-SetupSOdesdeLiveCD.sh` termina con la línea literal `Correcto`, reinicia automáticamente; si no, espera 100000 s para diagnóstico.

### 2-SetupSOdesdeLiveCD.sh — Configuración en chroot
- Genera `/etc/fstab` con UUIDs reales leídos de `blkid`.
- **Parche grub.cfg**: `update-grub` en chroot a veces escribe `root=/dev/nvme0n1p3` en lugar de `root=UUID=...`. El script lo detecta y parchea con `sed`.
- **Casper hooks**: se eliminan directamente con `rm -rf` (sin `apt remove`) para evitar que los triggers dpkg se bloqueen en el chroot. Los hooks afectados: `/usr/share/initramfs-tools/hooks/casper` y variantes.
- `update-initramfs -u -k all` tarda 2–4 min; es el paso más lento del chroot.
- Crea el servicio systemd `3-SetupPrimerInicio.service` con `WantedBy=multi-user.target`.
- Termina siempre con `echo "Correcto"` si todo fue bien (1-SetupLiveCD lo comprueba con `tail -n1`).

### 3-SetupPrimerInicio.sh — Primer arranque
- Detecta el aula por el tercer octeto de la IP: 72→IABD, 32→SMRV.
- Configura proxy apt según aula: `10.0.72.140:3128` (IABD) o `10.0.32.119:3128` (SMRV).
- Instala `ssh` y `ansible`, habilita `PermitRootLogin yes` y hace `apt-get full-upgrade`.
- Muestra progreso al usuario mediante diálogos `zenity` en todas las sesiones gráficas activas.
- Se autodeshabilita con triple mecanismo: `systemctl disable` + `rm` del `.service` + `mv "$0" "$0.borrado"`.
- Ejecuta `NombreIP.sh` (resuelve MAC→hostname y opcionalmente convierte DHCP a IP estática).
- Ejecuta `Auto-Ansible.sh` y lanza directamente `ansible-playbook roles.yaml` desde `$RAIZANSIBLE`.

### 4-Comprobaciones.sh — Diagnóstico
Comprueba: kernel e initramfs presentes, NVMe drivers en initramfs, ausencia de hooks casper, grub.cfg con UUIDs, fstab vs blkid, paquetes dpkg rotos, servicio SSH. Genera resumen de errores/warnings al final. Útil como primer análisis al pegar un log.

**Falsos positivos conocidos en 4-Comprobaciones.sh** — verificar antes de asumir que el sistema está roto:

| Mensaje `[ERR]` en el log | Causa real | ¿Es un problema real? |
|---|---|---|
| `casper está instalado` (sección 5, pre-2026-04-30) | dpkg lo marca como instalado pero los hooks ya fueron borrados con `rm -rf` en el chroot | No — los hooks no están en disco; el initramfs se generó limpio |
| `UUID 68 (/boot/efi) → ningún dispositivo` (sección 3, pre-2026-04-30) | Regex `[a-f0-9-]+` trunca UUIDs FAT con mayúsculas (`68AA-2FED` → `68`) | No — la partición EFI existe; era un bug del regex |

**Diagnóstico rápido de la sección 3 (FSTAB)**: si hay un `[ERR]` de UUID para `/boot/efi` pero `lsblk` (sección 4) muestra esa partición con un UUID del tipo `XXXX-YYYY` (4+4 hex en mayúsculas, formato FAT), es falso positivo — el UUID FAT usa mayúsculas y el regex debe ser `[a-fA-F0-9-]+`.

**Diagnóstico rápido de la sección 5 (casper)**: si la sección 1 dice `[OK] Hooks casper: no presentes` pero la sección 5 dice `[ERR] casper está instalado`, es falso positivo — dpkg tiene el registro pero los hooks no existen en disco y no afectan al initramfs.

---

## Configuraciones de hardware soportadas

| Aula      | Disco pequeño       | Disco grande      |
|-----------|---------------------|-------------------|
| Distancia | NVMe 0.5 TB (/, EFI, swap) | NVMe 2.0 TB (/home) |
| CEIABD    | NVMe 0.5 TB (/, EFI, swap) | SDA  1.0 TB (/home) |

---

## Ficheros de datos

- `macs.csv` — en raíz del repo (`/opt/IAC-IESMHP/macs.csv`). Formato: `MAC,hostname`. Usado por `2-SetupSOdesdeLiveCD.sh` y `NombreIP.sh` para asignar nombre al equipo.
- `Autorizados.txt` — claves SSH públicas autorizadas para `root` y `usuario`.
- `FondoIES-Ubuntu-Gris.png` — fondo de escritorio embebido en el squashfs.

---

## Registro de cambios

Los cambios realizados en cada sesión de trabajo se documentan en:
```
Ubuntu/RegistroDeCambios/YYYYMMDD-Cambios.md
```
Antes de modificar un script, consulta ese directorio para evitar repetir correcciones ya aplicadas.

---

## Issues conocidos y áreas en optimización

- **`0b-Github.sh` línea 54**: comentario `#####FALLA AQUí!` — en alguna versión se bloqueaba antes del `apt-get install git`. Mitigado enmascarando `update-initramfs` (tanto `/usr/local/sbin/` como `/usr/sbin/`) y `man-db` antes de cualquier apt.
- **`Auto-Ansible.sh` línea 38**: `ssh-keygen -F $HOSTNAME` falla. Pendiente de corrección.
- **snapd en Live CD**: si en futuras ISOs snapd vuelve a arrancar, los síntomas son arranque lento (~3 min) y bloqueo de `ubuntu-desktop-bootstrap` antes del autostart.

### Bugs corregidos en 4-Comprobaciones.sh (historial para no repetirlos)

- **2026-05-02 — Línea `initrd` ausente en grub.cfg no detectada (sección 2)**: el check solo verificaba la línea `linux` pero no la línea `initrd`. Si `update-grub` corre antes de que exista el initramfs (orden de operaciones en `2-SetupSOdesdeLiveCD.sh`), grub.cfg se genera sin `initrd` → kernel panic `unknown-block(0,0)`. **Fix**: nuevo check de la línea `initrd` en sección 2; en `2-SetupSOdesdeLiveCD.sh` se re-ejecuta `update-grub` tras `update-initramfs` si falta la línea.
- **2026-05-02 — Falso positivo NVMe (sección 1)**: `grep -q nvme` coincide con directorios como `kernel/drivers/nvme/` sin que haya ningún `.ko` real. **Fix**: `grep -qE 'nvme.*\.ko'` para verificar la presencia del módulo real.

- **2026-04-30 — Falso positivo casper (sección 5)**: el check usaba `dpkg -l casper | grep "^ii"`. `2-SetupSOdesdeLiveCD.sh` borra los hooks con `rm -rf` sin pasar por `apt remove`, así que dpkg sigue marcando el paquete como instalado aunque los hooks no existan. **Fix**: buscar hooks en disco con `find /usr/share/initramfs-tools /etc/initramfs-tools -name '*casper*'`; si no hay ficheros → `[OK]`.
- **2026-04-30 — Falso positivo UUID EFI (sección 3)**: el regex `UUID=\K[a-f0-9-]+` trunca los UUIDs FAT/vfat (formato `68AA-2FED`) en la primera letra mayúscula, extrayendo solo `68`. `blkid -U 68` no encuentra nada → `[ERR]` falso. **Fix**: regex `[a-fA-F0-9-]+` (añadir `A-F`).
