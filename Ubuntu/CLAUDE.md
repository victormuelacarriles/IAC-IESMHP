# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Propósito del proyecto

Automatización del despliegue de Ubuntu 26.04 Desktop en equipos del IES Miguel Herrero (Torrelavega). El flujo genera una ISO personalizada de Ubuntu, que al arrancar particiona los discos, copia el sistema operativo e instala GRUB sin intervención manual.

**Metodología de trabajo**: el usuario arranca la ISO en una máquina virtual (VMware), recoge los logs y los pega aquí para diagnosticar fallos y optimizar el proceso.

### Protocolo de diagnóstico (seguir en este orden)
1. Leer el fichero de cambios más reciente en `Ubuntu/RegistroDeCambios/` para saber qué se tocó en la última sesión y qué consecuencias puede haber tenido.
2. Leer el log pegado o los ficheros de log en `Ubuntu/ISO/26.04/logs/ (ficheros *.log y *.steps)
3. **Antes de proponer un fix**, cruzar cada `[ERR]` con la lista de falsos positivos conocidos documentada más abajo — muchos errores son del propio script de diagnóstico, no del sistema instalado.
4. Si el error es real (no falso positivo), buscar en el script correspondiente la línea exacta que lo genera y proponer el cambio mínimo necesario.
5. Documentar el fix en `Ubuntu/RegistroDeCambios/YYYYMMDD-Cambios.md` (crear el fichero del día si no existe. Indicar dentro del fichero la hora de los cambios.).

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

### 2-SetupSOdesdeLiveCD.sh — Configuración en chroot (v22.15-20260504)
- Genera `/etc/fstab` con UUIDs reales leídos de `blkid`.
- **Fondo de escritorio** (dos capas): GSettings schema override (`99-iac-iesmhp-wallpaper.gschema.override`) como valor predeterminado compilado, más `dconf system-db:local` como override en runtime. Si `dconf update` falla en chroot, la capa GSettings garantiza el fondo igualmente.
- **Plymouth logos**: copia `bgrt-fallback.png` y `watermark.png` desde `imagenesIES/` a los temas spinner/bgrt **antes** de `update-initramfs`, para que la imagen instalada use los logos del IES.
- **Elimina autostart del Live CD**: borra `iac-iesmhp-setup.desktop` de `/etc/skel/.config/autostart` y `/home/ubuntu/.config/autostart` para que GNOME no lo ejecute en cada login del sistema instalado.
- **GDM — anti-autologin (multicapa)**:
  1. `AccountsService/users/ubuntu` eliminado + `usuario` registrado.
  2. `debconf-set-selections` pre-configura gdm3 con auto-login=false antes de que `dpkg --configure -a` pueda leer debconf del Live CD.
  3. `/etc/gdm3/custom.conf.d` eliminado + `custom.conf` sobrescrito con `AutomaticLoginEnable=false`, `TimedLoginEnable=false`, `InitialSetupEnable=false`, `WaylandEnable=true`.
  4. `iac-gdm-noautologin.service` (nuevo): `Before=display-manager.service` + `After=local-fs.target`, escribe `custom.conf` en **cada** arranque antes de que GDM lo lea. Cubre el caso de que postinst de gdm3 o `full-upgrade` sobreescriban la config.
  5. `casper.service` enmascarado vía symlink a `/dev/null` para impedir que casper userspace re-habilite auto-login.
- **gnome-initial-setup**: marcadores creados en rutas antiguas (`~/.config/`) y nuevas (`~/.local/share/`, Ubuntu 26.04+) para `gdm3`, `skel` y `usuario`. Evita que GDM lance el asistente de bienvenida como sesión propia ("GDM Greeter").
- **Contraseñas via Python inline**: genera hash SHA-512 con `openssl passwd -6` y lo escribe directamente en `/etc/shadow` via regex, sin pasar por PAM (`pam_pwquality` rechaza contraseñas cortas como 'root'/'usuario'). `useradd` se ejecuta **antes** de este bloque para que el usuario exista en shadow. Si el hash no queda escrito, sale con `sys.exit(1)`.
- **Check `/etc/nologin`**: si existe, bloquea todos los logins normales. El script lo detecta y elimina.
- **VMware — Wayland software rendering**: tras instalar el servicio GDM, detecta VMware con `systemd-detect-virt`. Si es VMware, escribe `LIBGL_ALWAYS_SOFTWARE=1` en `/etc/environment` para que Mesa llvmpipe permita iniciar sesiones Wayland sin aceleración 3D. En máquinas físicas, `systemd-detect-virt` devuelve "none" y este bloque no se ejecuta.
- **Timeout y menú GRUB**: `GRUB_TIMEOUT=5` y `GRUB_TIMEOUT_STYLE=menu` se fijan en `/etc/default/grub` para que el menú sea visible 5 s antes de arrancar la entrada por defecto.
- **Segunda entrada GRUB (modo texto)**: se crea `/etc/grub.d/11_iac_texto`, un script ejecutable que `update-grub` invoca en cada regeneración. Genera una entrada `'Ubuntu - Sin entorno grafico (modo texto)'` con `systemd.unit=multi-user.target`, que arranca en consola sin GDM/GNOME. El script lee el kernel, el initrd y el UUID de root dinámicamente (`/boot/vmlinuz-*`, `/boot/initrd.img-*`, `/etc/fstab`), por lo que sobrevive a actualizaciones de kernel.
- **Parche grub.cfg**: `update-grub` en chroot a veces escribe `root=/dev/nvme0n1p3` en lugar de `root=UUID=...`. El script lo detecta y parchea con `sed`.
- **Casper hooks**: se eliminan directamente con `rm -rf` (sin `apt remove`) para evitar que los triggers dpkg se bloqueen en el chroot. Hooks afectados: `/usr/share/initramfs-tools/hooks/casper` y variantes.
- `update-initramfs -c -k all` (create, no update) tarda 2–4 min; es el paso más lento. Se usa `-c` porque en sistemas instalados desde squashfs no existe initramfs previo y `-u` no crearía uno nuevo.
- **Re-ejecución de `update-grub` tras initramfs**: si grub.cfg no tiene línea `initrd` (generado cuando initrd.img aún no existía), se re-ejecuta `update-grub` y se re-aplica el parche UUID.
- Crea el servicio systemd `3-SetupPrimerInicio.service` con `WantedBy=multi-user.target`.
- Termina siempre con `echo "Correcto"` si todo fue bien (1-SetupLiveCD lo comprueba con `tail -n1`).

### 3-SetupPrimerInicio.sh — Primer arranque
- Detecta el aula por el tercer octeto de la IP: 72→IABD, 32→SMRV.
- Configura proxy apt según aula: `10.0.72.140:3128` (IABD) o `10.0.32.119:3128` (SMRV).
- `export DEBIAN_FRONTEND=noninteractive` + `debconf-set-selections` para gdm3 antes de `dpkg --configure -a`. Evita que el postinst de gdm3 regenere `custom.conf` con auto-login del Live CD.
- `dpkg --configure -a` y `apt-get full-upgrade` usan `-o Dpkg::Options::="--force-confold"` para no reemplazar `custom.conf` con la versión del paquete.
- Bloque **post-upgrade**: sobreescribe `/etc/gdm3/custom.conf` con `AutomaticLoginEnable=false` + `InitialSetupEnable=false` + `WaylandEnable=true` tras el upgrade, por si gdm3 lo regeneró.
- En VMware: instala `open-vm-tools-desktop` y confirma/añade `LIBGL_ALWAYS_SOFTWARE=1` en `/etc/environment`.
- Instala `ssh` y `ansible`, habilita `PermitRootLogin yes` y hace `apt-get full-upgrade`.
- Muestra progreso al usuario mediante diálogos `zenity` en todas las sesiones gráficas activas.
- Se autodeshabilita con triple mecanismo: `systemctl disable` + `rm` del `.service` + `mv "$0" "$0.borrado"`.
- Ejecuta `NombreIP.sh` (resuelve MAC→hostname y opcionalmente convierte DHCP a IP estática).
- Ejecuta `Auto-Ansible.sh` y lanza directamente `ansible-playbook roles.yaml` desde `$RAIZANSIBLE`.

### 4-Comprobaciones.sh — Diagnóstico (v1.2-20260502)
Comprueba en 8 secciones: (1) kernel+initramfs+NVMe+casper, (2) grub.cfg con UUIDs+línea initrd, (3) fstab vs blkid, (4) lsblk particiones, (5) paquetes clave (casper por ficheros en disco, no dpkg; ubiquity; dpkg --audit), (6) initramfs-tools config (MODULES=most, RESUME=none), (7) GRUB EFI instalado (grubx64.efi, módulos), (8) servicios systemd fallidos + SSH (solo si sistema arrancado, no en chroot). Genera resumen ERRORES/AVISOS al final. **Cuando ERRORES=0, reinicia automáticamente tras cuenta atrás de 30 s.** Útil como primer análisis al pegar un log.

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
Antes de modificar un script, consulta ese directorio para evitar repetir correcciones ya aplicadas que funcionaron mal. Los nuevos cambios regístralos allí indicando también la hora y minuto en que los realizastes. 

---

## Issues conocidos y áreas en optimización

- **`0b-Github.sh` línea 54**: comentario `#####FALLA AQUí!` — en alguna versión se bloqueaba antes del `apt-get install git`. Mitigado enmascarando `update-initramfs` (tanto `/usr/local/sbin/` como `/usr/sbin/`) y `man-db` antes de cualquier apt.
- **`Auto-Ansible.sh` línea 38**: `ssh-keygen -F $HOSTNAME` falla. Pendiente de corrección.
- **snapd en Live CD**: si en futuras ISOs snapd vuelve a arrancar, los síntomas son arranque lento (~3 min) y bloqueo de `ubuntu-desktop-bootstrap` antes del autostart.
- **Wayland en VMware sin 3D**: si la sesión Wayland sigue fallando en la VM (GDM vuelve al login sin mensaje de error), verificar **Habilitar aceleración 3D** en Display → Accelerate 3D graphics de VMware. Con eso y `open-vm-tools-desktop`, Wayland funciona sin necesidad de `LIBGL_ALWAYS_SOFTWARE`.

### Bugs corregidos (historial para no repetirlos)

- **2026-05-04 — GRUB sin menú visible y sin opción de modo texto**: el timeout era 0 (`GRUB_TIMEOUT_STYLE=hidden`) y solo existía una entrada de arranque. **Fix**: `GRUB_TIMEOUT=5` + `GRUB_TIMEOUT_STYLE=menu` en `/etc/default/grub`; nuevo `/etc/grub.d/11_iac_texto` que genera la segunda entrada `systemd.unit=multi-user.target` en cada `update-grub`.
- **2026-05-03 — Login imposible: `useradd` después del bloque Python de contraseñas**: el bloque Python (línea ~252) corría antes de `useradd`. 'usuario' no existía en `/etc/shadow` → Python imprimía `[WARN]` y continuaba; `useradd` creaba al usuario con contraseña bloqueada (`*`). **Fix**: `useradd` movido antes del bloque Python; `[WARN]` → `[ERR]` + `sys.exit(1)` si el usuario no existe en shadow.
- **2026-05-03 — Contraseñas rechazadas por `pam_pwquality`**: `chpasswd` en Ubuntu 26.04 aplica PAM con mínimo 8 caracteres. 'root' (4) y 'usuario' (7) son rechazadas silenciosamente. **Fix**: Python inline genera hash SHA-512 con `openssl passwd -6` y lo escribe directamente en `/etc/shadow` via regex, sin pasar por PAM.
- **2026-05-03 — GDM Greeter automático en primer arranque**: `3-SetupPrimerInicio.service` llega `After=graphical.target` → tarde para corregir `custom.conf` si casper.service o postinst de gdm3 lo sobreescribieron. **Fix**: nuevo `iac-gdm-noautologin.service` con `Before=display-manager.service` que escribe `custom.conf` en cada arranque antes de que GDM lo lea.
- **2026-05-03 — `gnome-initial-setup` lanzado como sesión GDM**: Ubuntu 26.04 necesita `InitialSetupEnable=false` en `custom.conf` y marcadores en `~/.local/share/gnome-initial-setup-done` (ruta nueva ≥ 46) además de `~/.config/`. **Fix**: añadido `InitialSetupEnable=false` a todos los configs GDM; marcadores creados en ambas rutas.
- **2026-05-03 — Auto-login en squashfs rompía Live CD**: escribir `AutomaticLoginEnable=false` en `0a-CreaISO.sh` impedía que casper configurara el auto-login del Live CD en runtime. **Fix**: revertido; el fix correcto es solo en el chroot (`2-SetupSOdesdeLiveCD.sh`).
- **2026-05-02 — Línea `initrd` ausente en grub.cfg (sección 2 de comprobaciones)**: `update-grub` corre antes de que exista el initramfs → grub.cfg sin línea `initrd` → kernel panic `unknown-block(0,0)`. **Fix**: re-ejecutar `update-grub` tras `update-initramfs`; nuevo check en sección 2 de `4-Comprobaciones.sh`.
- **2026-05-02 — Falso positivo NVMe (sección 1)**: `grep -q nvme` coincidía con directorios sin `.ko` real. **Fix**: `grep -qE 'nvme.*\.ko'`.
- **2026-04-30 — Falso positivo casper (sección 5)**: check con `dpkg -l` marcaba error aunque los hooks ya estuvieran borrados del disco. **Fix**: `find` en disco; si no hay ficheros → `[OK]`.
- **2026-04-30 — Falso positivo UUID EFI (sección 3)**: regex `[a-f0-9-]+` truncaba UUIDs FAT con mayúsculas (`68AA-2FED` → `68`). **Fix**: `[a-fA-F0-9-]+`.
