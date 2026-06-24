# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## ⛔ Gestión de git — NO la hagas tú (regla del propietario)

**NUNCA** ejecutes operaciones de git que modifiquen el repositorio o el remoto:
nada de `git add`, `git commit`, `git push`, `git reset`, `git checkout` para
cambiar de rama, crear ramas, etc. **El propietario (Víctor) sube SIEMPRE él mismo
los cambios de código a GitHub.**

- Limita tu trabajo a **crear/editar ficheros** en el árbol de trabajo. Deja los
  cambios **sin commitear**; ya los revisará y subirá él.
- Puedes usar git en **solo lectura** si lo necesitas para diagnosticar
  (`git status`, `git log`, `git diff`), pero **sin** modificar nada.
- Si crees que hace falta un commit/push, **dilo y para**; no lo hagas.

> Nota histórica: en una sesión previa (24/06/2026) sí se hicieron commits/push
> de los arreglos de `W11/ISO/0b-GitHub.ps1`. A partir de ahí el propietario pidió
> expresamente que **no** se gestione git. Respétalo.

## Propósito del proyecto

Automatización del despliegue de Ubuntu 26.04 Desktop en equipos del IES Miguel Herrero (Torrelavega). El flujo genera una ISO personalizada de Ubuntu, que al arrancar particiona los discos, copia el sistema operativo e instala GRUB sin intervención manual.

**Metodología de trabajo**: el usuario arranca la ISO en una máquina virtual (VMware), recoge los logs y los pega aquí para diagnosticar fallos y optimizar el proceso.

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
# 3-SetupPrimerInicio.sh.log   ← primer arranque: log ÚNICO de TODO lo que
#                                 lanza el servicio (este script + NombreIP +
#                                 Auto-Ansible + ansible-playbook + 4-Compro-
#                                 baciones). Cada línea con hora; sobrevive a
#                                 cuelgues NVIDIA (sync periódico). Antes había
#                                 además 5-PrimerArranque.log con el MISMO
#                                 contenido — eliminado el 2026-05-18.
# 4-Comprobaciones.sh.log      ← diagnóstico
```

---

## Arquitectura y decisiones clave

### comun.sh — Variables centralizadas (única fuente de verdad)
- **`Ubuntu/ISO/26.04/comun.sh`** define **una sola vez** todas las rutas y
  constantes "mágicas" del proyecto: `GITHUB_USER`/`REPO`/`GITREPO`/`GITRAW`,
  `DISTRO`/`versionDISTRO`, `RAIZSCRIPTS` (`/opt/IAC-IESMHP`), `RAIZDISTRO`,
  `RAIZANSIBLE`, `RAIZLOG`, rutas absolutas de los sub-scripts
  (`SCRIPT_LIVECD`…`SCRIPT_AUTOANSIBLE`), ficheros de datos (`FICHERO_MACS`,
  `URL_MACS`, `FICHERO_AUTORIZADOS`) y redes/proxy de aula
  (`RED_IABD`/`RED_SMRD`, `PROXY_IABD`/`PROXY_SMRD`).
- Los scripts **1, 2, 3, 4, NombreIP** hacen `source` de él (localizándolo
  relativo a `${BASH_SOURCE[0]}`, sin codificar `/opt/...` a fuego) en lugar de
  redefinir esas variables. **Para cambiar una ruta, editar solo `comun.sh`.**
- **Excepción**: `0b-Github.sh` corre en el Live CD *antes* de clonar el repo,
  así que no puede cargar `comun.sh` aún. Mantiene un bloque de arranque mínimo
  con solo `GITHUB_USER`+`REPO` (única duplicación inevitable, marcada en el
  código) y tras clonar carga `comun.sh`. Si se cambia la URL/nombre del repo,
  actualizar también esas dos líneas de `0b-Github.sh`.
- `comun.sh` es un fichero **nuevo**: hay que hacer commit+push a `main` antes de
  arrancar una ISO (0b lo clona desde GitHub). Ver `Ubuntu/RegistroDeCambios/20260612-Cambios.md`.

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
  Fija una variable explícita `PERFIL` (`CEIABD` | `DISTANCIA`).
  - 2×NVMe (Distancia) → pequeño=`/`, grande=`/home`. **Sin ZFS** (ext4
    íntegro, idéntico a v22.x).
  - NVMe+SD (CEIABD) → NVMe lleva EFI 1G + swap 16G + `/` ext4 100G +
    `p4` ZFS (zpool `rpool` → `/home`). SDA entero ZFS (zpool `tank` →
    `/datos`).
- **Esquema de particiones**:
  - **DISTANCIA**: EFI 512 MiB | swap 8 GiB | root ext4 resto. Disco grande
    1 partición ext4 entera → `/home`.
  - **CEIABD**: sgdisk con typecodes EF00/8200/8300/BF00. NVMe pequeño:
    EFI 1 GiB + swap 16 GiB + `/` ext4 100 GiB + `rpool` ZFS resto. SDA
    entero BF00 → `tank` ZFS.
- **ZFS en CEIABD** (bloque añadido):
  - Instala `zfsutils-linux` en el entorno live.
  - Detecta Fast Dedup (OpenZFS ≥ 2.3) y lo activa si está.
  - `zpool create rpool` con `compression=zstd, dedup=on, recordsize=64K,
    ashift=12, autotrim=on` y altroot `-R /mnt`. Crea el dataset **único y
    definitivo** `rpool/home canmount=on mountpoint=/home`: el rsync vuelca
    /home (squashfs) al pool y los usuarios viven como directorios normales
    dentro (desde 2026-06-12 ya NO hay datasets por usuario ni cuotas).
  - `zpool create tank` análogo pero **sin dedup**, `recordsize=1M`. Crea
    `tank/datos canmount=on mountpoint=/datos setuid=off devices=off`,
    `chmod 1777`.
- **Capas squashfs**: Ubuntu 26.04 combina `minimal.squashfs + minimal.standard.squashfs + minimal.standard.live.squashfs` con overlayfs en `/tmp/merged`; Ubuntu <24.04 usa `filesystem.squashfs` único.
- Copia el FS con `rsync` (excluyendo `/etc/fstab` y `/etc/machine-id`).
- **Tras el rsync (CEIABD)**: copia `/etc/zfs/zpool.cache` y `/etc/hostid`
  del live al sistema instalado para que `zfs-import-cache` lo importe
  sin escanear discos y sin `-f`.
- Pasa las particiones al chroot vía `/mnt/tmp/.iac-partitions.env`. En
  CEIABD el fichero incluye además `PERFIL=`, `ZFS_POOL_HOME=`,
  `ZFS_HOME_DATASET=`, `ZFS_HOME_PARTID=` (by-id), `ZFS_POOL_DATA=`,
  `ZFS_DATA_DATASET=`, `ZFS_DATA_PARTID=`.
- **Pre-reboot (CEIABD)**: `zpool sync` + `zpool export rpool tank` para
  que el sistema instalado no vea los pools "in use" por el hostid del
  live.
- Si `2-SetupSOdesdeLiveCD.sh` termina con `Correcto`, reinicia
  automáticamente; si no, espera 100000 s para diagnóstico (en fallo NO
  exporta los pools — siguen accesibles desde `/mnt`).

### 2-SetupSOdesdeLiveCD.sh — Configuración en chroot
- **Preámbulo**: carga `.iac-partitions.env` al inicio y fija `PERFIL`
  para todos los bloques (default `DISTANCIA` si no hay fichero).
- **fstab bifurcado**: DISTANCIA → 4 líneas como antes. CEIABD → solo `/`,
  `/boot/efi` y `swap` (las entradas `/home` y `/datos` las gestiona
  `zfs-mount.service`; `/` lleva `noatime`).
- **ZFS dentro del chroot (solo CEIABD)**: `apt install linux-headers-generic`
  + `zfsutils-linux zfs-zed zfs-dkms zfs-initramfs`; habilita servicios
  `zfs.target zfs-import-cache zfs-mount zfs-zed`; deshabilita
  `zfs-import-scan` (redundante con cachefile); `zpool set cachefile=` en
  `rpool` y `tank` para regenerar el cache desde el sistema instalado.
- **`/home` = dataset ZFS único (CEIABD, simplificación 2026-06-12)**:
  `rpool/home` (canmount=on, mountpoint=/home, creado en `1-SetupLiveCD.sh`)
  se usa tal cual — ya NO se reestructura en contenedor + dataset por
  usuario, NO hay cuotas y NO existe el helper `nuevo-alumno.sh`. El script
  solo verifica que `rpool/home` está montado en `/home` (red de seguridad:
  abortar antes de escribir al ext4 subyacente) y crea el usuario con
  `useradd -m` estándar (misma rama que DISTANCIA). Alta de usuarios en el
  equipo instalado: `sudo adduser <usuario>`. Snapshot global
  `rpool/home@inicial` tras eliminar el usuario `ubuntu` del Live CD
  (rollback devuelve TODO /home al estado post-instalación).
- **Parche grub.cfg**: `update-grub` en chroot a veces escribe `root=/dev/nvme0n1p3` en lugar de `root=UUID=...`. El script lo detecta y parchea con `sed`.
- **Casper hooks**: se eliminan directamente con `rm -rf` (sin `apt remove`) para evitar que los triggers dpkg se bloqueen en el chroot. Los hooks afectados: `/usr/share/initramfs-tools/hooks/casper` y variantes.
- `update-initramfs -c -k all` tarda 2–4 min; es el paso más lento del chroot. Con `zfs-initramfs` instalado, el initramfs incluye el módulo ZFS (informativo: `/` sigue siendo ext4).
- Crea el servicio systemd `3-SetupPrimerInicio.service` con `WantedBy=multi-user.target`.
- Termina siempre con `echo "Correcto"` si todo fue bien (1-SetupLiveCD lo comprueba con `tail -n1`).

### 3-SetupPrimerInicio.sh — Primer arranque
- Detecta el aula por el tercer octeto de la IP: 72→IABD, 32→SMRV.
- Configura proxy apt según aula: `10.0.72.140:3128` (IABD) o `10.0.32.119:3128` (SMRV).
- Instala `ssh` y `ansible`, habilita `PermitRootLogin yes` y hace `apt-get full-upgrade`.
- Muestra progreso al usuario mediante diálogos `zenity` en todas las sesiones gráficas activas.
- Se autodeshabilita con triple mecanismo: `systemctl disable` + `rm` del `.service` + `mv "$0" "$0.borrado"`.
- Ejecuta `NombreIP.sh` (resuelve MAC→hostname y opcionalmente convierte DHCP a IP estática).
- Ejecuta `Auto-Ansible.sh` y lanza directamente `ansible-playbook roles.yaml` desde `$RAIZANSIBLE` (ver sección **Configuración post-instalación con Ansible**).

### 4-Comprobaciones.sh — Diagnóstico
Comprueba: kernel e initramfs presentes, NVMe drivers en initramfs, ausencia de hooks casper, grub.cfg con UUIDs, fstab vs blkid, paquetes dpkg rotos, servicio SSH. **Sección 9 ZFS (CEIABD)**: salud de pools, datasets esperados (`rpool/home` montado en `/home`, `tank/datos` en `/datos`), dedup ratio + feature `fast_dedup`, servicios `zfs-import-cache`/`zfs-mount`/`zfs-zed` y módulo `zfs.ko` en initramfs. Genera resumen de errores/warnings al final. Útil como primer análisis al pegar un log.

---

## Configuraciones de hardware soportadas

| Aula      | Disco pequeño       | Disco grande      |
|-----------|---------------------|-------------------|
| Distancia | NVMe 0.5 TB (EFI 512M, swap 8G, `/` ext4 resto) | NVMe 2.0 TB (`/home` ext4) |
| CEIABD    | NVMe 0.5 TB (EFI 1G, swap 16G, `/` 100G ext4, `p4` ZFS → `rpool`) | SDA 1.0 TB (ZFS → `tank` → `/datos`) |

**Distancia** = ext4 íntegro (sin ZFS). **CEIABD** = ZFS en `/home` (zpool
`rpool` con dedup+zstd) y `/datos` (zpool `tank` con zstd). Ver detalle
operativo y comandos en [Ubuntu/CLAUDE.md](Ubuntu/CLAUDE.md) sección "ZFS —
operación".

---

## Configuración post-instalación con Ansible

Una vez instalado el SO, `3-SetupPrimerInicio.sh` lanza `ansible-playbook roles.yaml`
para configurar el equipo (software, NFS de aula, drivers, claves SSH…). Toda esta
parte vive en `Ubuntu/ansible/` y está **documentada con sus propios CLAUDE.md**:

- **`Ubuntu/ansible/CLAUDE.md`** — describe `roles.yaml` (el playbook maestro), los
  inventarios `*.ini`, los comandos de ejecución, el estado de cada rol
  (activo / comentado / legacy) y las convenciones (caché apt, detección de aula
  por IP, equipo `-00` = servidor).
- **`Ubuntu/ansible/roles/<rol>/CLAUDE.md`** — un fichero por rol con sus tareas,
  variables (`defaults/`) e issues conocidos. Roles documentados: `basicos`,
  `horaHTTP` (sincroniza la hora en cada arranque por NTP y, si está filtrado el
  UDP 123, por HTTP), `certificados`, `clienteNAS` (cliente NFS del NAS del
  departamento; comentado en `roles.yaml`), `comparteaula` (+ legacy
  `comparteaula32`/`comparteaula72`),
  `DirtyFrag` (mitiga CVE-2026-43284/43500), `flatpak` (soporte Flatpak + Flathub),
  `nvidia`, `obs`, `vscode`, `rdp` (servidor RDP nativo de GNOME; sustituye al
  antiguo `xrdp`), `vmware`, `Docker`
  (instalación de sistema para uso rootless; sustituye al antiguo `contenedores`),
  `preparaAD` (prerequisitos de unión a dominio Active Directory; no une por defecto).

  El estado vigente (activo / comentado / no listado) de cada rol está en la
  tabla de `Ubuntu/ansible/CLAUDE.md`; la fuente de verdad es `roles.yaml`.
- **`Ubuntu/ansible/rolesUsuario/CLAUDE.md`** — configuraciones e **instalaciones
  de software sin permisos root** que **todo usuario** debería tener en su perfil
  (`~/.ssh`, dotfiles…), ejecutadas **como el usuario** (no root). Carpeta nueva,
  en construcción; aún no enganchada a `roles.yaml`.

**Al diagnosticar o modificar la fase Ansible, leer primero esos CLAUDE.md** (en
especial el de `Ubuntu/ansible/` para saber qué roles están activos en `roles.yaml`).

---

## Ficheros de datos

- `macs.csv` — en raíz del repo (`/opt/IAC-IESMHP/macs.csv`). Formato: `MAC,hostname`. Usado por `2-SetupSOdesdeLiveCD.sh` y `NombreIP.sh` para asignar nombre al equipo.
- `Autorizados.txt` — claves SSH públicas autorizadas para `root` y `usuario`.
- `FondoIES-Ubuntu-Gris.png` — fondo de escritorio embebido en el squashfs. Vive en `Ubuntu/ISO/26.04/imagenesIES/` (junto a los demás fondos y los logos Plymouth `bgrt-fallback.png`/`watermark.png`), **no** en la raíz del repo.

---

## Issues conocidos y áreas en optimización

- **`0b-Github.sh` línea 54**: comentario `#####FALLA AQUí!` — en alguna versión se bloqueaba antes del `apt-get install git`. Mitigado enmascarando `update-initramfs` (tanto `/usr/local/sbin/` como `/usr/sbin/`) y `man-db` antes de cualquier apt.
- **`Auto-Ansible.sh` línea 38**: `ssh-keygen -F $HOSTNAME` falla. Pendiente de corrección.
- **snapd en Live CD**: si en futuras ISOs snapd vuelve a arrancar, los síntomas son arranque lento (~3 min) y bloqueo de `ubuntu-desktop-bootstrap` antes del autostart.
