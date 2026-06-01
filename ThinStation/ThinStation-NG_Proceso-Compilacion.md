# ThinStation-NG 7.2 — Compilación de una imagen universal en Fedora

> Generación de una imagen **ISO + PXE** de cliente ligero con sesión **RDP en modo kiosco**
> (diálogo de IP al arrancar), acceso **SSH** y máxima compatibilidad de hardware.
>
> - **Repositorio:** [github.com/thinstation/thinstation-ng](https://github.com/thinstation/thinstation-ng) · rama `7.2-Stable`
> - **Verificado contra:** rama oficial `7.2-Stable` (mayo 2026)
> - **Documento origen:** `20260528-thinstation-ng-tutorial-fedora - con icono personalizado.pdf`

---

## 1. Visión general

ThinStation-NG es un sistema operativo de cliente ligero de código abierto. El objetivo de este
proceso es generar **una sola ISO** que arranque en el mayor número posible de equipos, sin afinarla
por modelo, con una sesión RDP que pide la IP del servidor al arrancar. Todo el trabajo se hace por
línea de comandos en un equipo Fedora; el entorno gráfico vive **dentro de la imagen**, no en la
máquina que compila.

El proceso tiene **dos fases**:

| Fase | Herramienta | Duración | ¿Repite al recompilar? |
|------|-------------|----------|------------------------|
| Poblar el chroot (Fedora 42 + herramientas TS) | `./setup-chroot` | ~25–40 min | **No** — queda en disco |
| Compilar la imagen (paquetes + kernel + squashfs + ISO) | `./build` | ~20–40 min | **Sí** — usa caché |

**Ubicación de los artefactos:** tras compilar quedan en `<repo>/ts/build/boot-images/grub/`.
GRUB es el único método de arranque no obsoleto en la 7.2.

---

## 2. Entorno requerido: Fedora

La compilación **solo funciona en Fedora**, por dos motivos verificados en el propio código:

- **El chroot se construye con `dnf`.** El script usa `dnf install --installroot ... --releasever=42`
  para descargar la base del sistema desde los repos de Fedora. Otras distros no tienen `dnf` ni esos
  repos → esta fase falla.
- **El empaquetado final necesita root real.** El último paso, que crea la imagen de arranque EFI,
  usa dispositivos *loop* y `mount`, que requieren privilegios reales sobre el kernel.

> **Si NO usas Fedora:** instala una VM con Fedora (edición Server, sin escritorio) y haz todo el
> proceso dentro de ella. Compilar fuera de Fedora hará que el proceso falle. En adelante «el equipo
> Fedora» se refiere indistintamente a una instalación física o a esa VM. Todo se ejecuta como **root**.

### Requisitos previos

- **8 GB de RAM** (recomendado; con 4 GB irá lento).
- **40–50 GB de disco libre** (el README pide 30, pero una imagen universal ocupa más durante el build).
- **Privilegios de root** (`sudo -i`).
- **Conexión a internet** (descarga la base de Fedora 42 y los paquetes).

---

## 3. Guía paso a paso

### Paso 1 — Instalar dependencias

`coreutils` (que aporta `chroot`) ya viene en Fedora. El resto (mksquashfs, xorriso, grub2) lo
arrastra `setup-chroot`.

```bash
sudo -i                                          # trabajar como root
dnf install -y git util-linux which dosfstools
```

### Paso 2 — Clonar el repositorio

`7.2-Stable` es una **rama**, no una etiqueta. El directorio resultante será la raíz del chroot;
colócalo en una partición con espacio suficiente.

```bash
cd /root
git clone --branch 7.2-Stable \
  https://github.com/thinstation/thinstation-ng.git
cd thinstation-ng
```

> **Working dir:** `/root/thinstation-ng`

### Paso 3 — Poblar el chroot

`./setup-chroot` descarga la base de Fedora 42, instala los paquetes del sistema, monta `/dev`,
`/proc` y `/sys` dentro del chroot y abre su shell. Tarda **~25–40 min** la primera vez.

```bash
./setup-chroot
```

Al terminar verás el prompt del chroot: `[root@TS_chroot]/#`. Es normal ver algunos avisos cosméticos
(paginadores, systemd/dconf dentro de un chroot); no impiden la compilación.

### Paso 4 — Ir al directorio de build

Dentro del chroot, `/build` es un enlace a `/ts/build`, donde están `build.conf`,
`thinstation.conf.buildtime` y `./build`.

```bash
cd /build
```

### Paso 5 — Configurar `build.conf` (paquetes)

Activa (descomenta) estas líneas. Nombres verificados contra `7.2-Stable`. Para máxima compatibilidad
se incluyen los **tres drivers de vídeo abiertos** (Intel, AMD, Nvidia) además de los de VM, y `sshd`:

| Línea a activar | Función |
|-----------------|---------|
| `package xorg7` | Servidor X con driver universal *modesetting* (KMS) |
| `package xorg7-intel` | Driver de GPU Intel |
| `package xorg7-amdgpu` | Driver de GPU AMD/ATI |
| `package xorg7-nouveau` | Driver de GPU Nvidia (abierto) |
| `package xorg7-qxl` / `xorg7-vmware` | Drivers de GPU para máquinas virtuales |
| `package autonet` | Red automática (DHCP) |
| `package freerdp` | Cliente RDP + diálogo de IP + reconexión |
| `package locale-es_ES` | Teclado y locale en español |
| `package sshd` | Servidor SSH (dropbear) para acceso remoto |

> **Nombres que NO existen en 7.2-Stable (causan error):**
> `xorg` → usar `xorg7` · `netbase` → usar `autonet` · `xorg-video-vesa` → no existe (KMS va en `xorg7`)
> · `dialog` / `xterm` → no son paquetes TS-NG.

El **firmware se incluye por completo de serie**: `param allfirmware true` ya es el valor por defecto,
así que no hay que tocar nada para cubrir Wi-Fi, Bluetooth y firmware de GPU.

### Paso 6 — Configurar `thinstation.conf.buildtime`

La clave: el paquete `freerdp` incluye `/etc/cmd/freerdp.getip`, que dispara el diálogo de IP cuando
no hay servidor fijo. **Sin scripts propios.** Sustituye la línea por defecto `SESSION_0_TYPE=xfwm4`
y deja:

```ini
# Sesion RDP en modo kiosco
SESSION_0_TYPE=freerdp
SESSION_0_AUTOSTART=on
# NO poner SESSION_0_FREERDP_SERVER -> dispara el dialogo de IP
SESSION_0_FREERDP_OPTIONS="/multimon /dynamic-resolution +clipboard /network:auto"
FREERDP_CERTIGNORE=on      # equivale a /cert:ignore
RECONNECT_PROMPT=On        # al cerrar, vuelve al dialogo de IP

# Red / zona horaria / idioma
NET_USE=BOTH
NET_USE_DHCP=on
TIME_ZONE=Europe/Madrid
LOCALE=es_ES
```

> **Teclado:** `KEYMAP=es` **NO existe** en 7.2. El teclado español se activa con
> `package locale-es_ES` + `LOCALE=es_ES`.

#### Multimonitor (puestos físicos de doble monitor)

Para que un puesto físico con **dos monitores extienda** el escritorio (no que lo clone), el
mecanismo válido en 7.2 es `USE_XRANDR` + `XRANDR_OPTIONS`, **no** las variables
`SET_RESOLUTION_MULTIMONITOR_*`:

```ini
# Multimonitor: extiende si hay 2 monitores, normal si hay 1
USE_XRANDR=On
XRANDR_OPTIONS="dualscreen"
```

Comportamiento (verificado en `packages/base/etc/thinstation.functions`, función `use_xrandr`):

- **2 monitores conectados** (puesto físico) → extiende con `xrandr --left-of` (primer monitor
  primario). Al **no** fijar `SCREEN_RESOLUTION`, cada monitor usa su **resolución nativa** — ideal
  para parque heterogéneo. La opción `/multimon` de la sesión RDP reparte ambos.
- **1 monitor** (VM o puesto simple) → resolución normal. El valor `dualscreen` es inerte aquí.

> **Variables muertas:** `SET_RESOLUTION_MULTIMONITOR_EXPAND` y `SET_RESOLUTION_MULTIMONITOR_AUTOSCALE`
> aparecen en las plantillas de `conf/*/thinstation.conf.buildtime` pero **ningún script las lee** en
> 7.2 (`grep -rn MULTIMONITOR_EXPAND /build/` solo las encuentra en las plantillas). Poner `mirror`,
> `right`, etc. **no hace nada** — usa `USE_XRANDR`/`XRANDR_OPTIONS`.

### Paso 7 — Compilar la imagen universal

`--allmodules` incluye **todos** los módulos del kernel (red, almacenamiento y, sobre todo, los
DRM/KMS de cualquier GPU) — eso es lo que hace la imagen universal. Las otras dos flags evitan
confirmaciones (aceptan licencias y descargan binarios sin preguntar):

```bash
# En /build, dentro del chroot · ~20-40 min
./build --allmodules --license ACCEPT --autodl 2>&1 | tee /build/build.log
```

Si se interrumpe, **relanza el mismo comando** (usa caché). Al terminar, verifica que la ISO existe y
no quedó en 0 bytes (debe mostrar varios cientos de MB):

```bash
ls -lh /build/boot-images/grub/thinstation-efi.iso
```

Para sacar la ISO a otra máquina o a un USB, cópiala desde:
`/root/thinstation-ng/ts/build/boot-images/grub/thinstation-efi.iso`. Si compilas en una VM, puedes
traerla con `scp`.

### Paso 8 — Arrancar el cliente (UEFI obligatorio · RAM · USB con Ventoy)

Dos requisitos **no negociables** verificados en la puesta en marcha real:

#### La ISO es solo-UEFI

El build elimina el arranque Legacy/BIOS; la imagen **solo arranca en modo UEFI**. Si el equipo (físico
o VM) arranca en **BIOS/CSM**, los síntomas son: no levanta la tarjeta de red (en `ip a` solo aparece
`lo`) y/o no arranca en absoluto. Comprobaciones:

- **En un sistema ya arrancado** (VM que funciona, cualquier Linux):
  ```bash
  [ -d /sys/firmware/efi ] && echo "Arranque UEFI" || echo "Arranque BIOS/Legacy"
  ```
- **En el firmware del equipo físico:** en el menú de arranque (F12/F9/Esc según fabricante) elige la
  entrada con prefijo **`UEFI:`** (la versión sin prefijo es Legacy). En el setup: **Boot Mode = UEFI**,
  **desactiva CSM/Legacy** y **desactiva Secure Boot** (el GRUB de ThinStation-NG no va firmado, así que
  con Secure Boot activo el equipo lo rechaza en silencio).

#### RAM suficiente (la imagen arranca en RAM)

Con `param fastboot lotsofmem` el squashfs (~300 MB) se vuelca a RAM para arrancar rápido. Si la VM o el
equipo tiene **poca memoria**, el sistema de ficheros en RAM se llena y la sesión gráfica **no puede
escribir su config** → cae a consola con errores `No space left on device` (al copiar `/etc/skel`,
`write lastlog failed`, etc.). La NIC y el kernel funcionan, pero **no hay entorno gráfico**.

- **Mínimo sano para la imagen universal: 4 GB de RAM** (initrd 441 MB + squash 301 MB + capa de
  escritura tmpfs). Subir la RAM de la VM y rearrancar lo resuelve sin recompilar.
- **Para equipos con poca RAM**, alternativa: en `build.conf` cambiar `param fastboot lotsofmem` por
  `param fastboot true` (no vuelca el squashfs a RAM; arranca algo más lento pero consume mucha menos
  memoria) y recompilar.

#### USB multiarranque en UEFI con Ventoy

Para llevar la ISO (y otras) en un USB que arranque **todo en UEFI**, la vía recomendada es
[Ventoy](https://www.ventoy.net): copias las `.iso` tal cual y muestra un menú de arranque. **Clave:**
una ISO lanzada por Ventoy **hereda el modo de arranque del propio Ventoy** — si arrancas el USB por la
entrada `UEFI:` del firmware, todas las ISO se lanzan en UEFI; no hay que configurar nada por-ISO.

1. Descarga Ventoy de la web oficial y ejecuta `Ventoy2Disk.exe` (Windows).
2. Selecciona el USB y, en **Option**, pon **Partition Style → GPT** (recomendado para UEFI puro).
   Activa **Secure Boot Support** solo si vas a dejar Secure Boot encendido. Pulsa **Install**
   (⚠️ borra el USB).
3. Copia las `.iso` (incluida `thinstation-efi.iso`) a la partición exFAT que crea Ventoy.
4. Arranca el equipo por la entrada **`UEFI:`** del USB (CSM y Secure Boot desactivados, ver arriba).
   Elige la ISO en el menú de Ventoy.
5. **Usa `Boot in normal mode`** (pulsar Enter directamente sobre la ISO ya lo hace). Si Ventoy
   muestra el submenú con `normal / grub2 / memdisk`, elige **normal**. Orden de preferencia para esta
   ISO EFI/GRUB: **normal → grub2 → (NUNCA memdisk)**.

> Como la ISO es solo-UEFI, **hay que arrancar Ventoy en modo UEFI**; si Ventoy arranca en Legacy, la
> ThinStation no aparecerá como arrancable. Confirma que Ventoy va en UEFI: abajo a la izquierda pone
> **`UEFI`** (no `BIOS`). Si alguna ISO concreta no arrancase con Ventoy (raro), prueba en su menú
> `Ctrl+r` (modo grub2).
>
> **⚠️ NO uses `Boot in memdisk mode` con esta ISO.** Memdisk carga la ISO entera en RAM y la emula
> como disco al estilo BIOS; **no encadena bien el GRUB EFI**, así que la ThinStation no llega a
> gráfico ni levanta la red aunque hayas arrancado el USB en UEFI. Síntoma observado en despliegue
> real (MSI, junio 2026): USB arrancado por `UEFI:` + Ventoy `UEFI`, pero elegido `memdisk` → fallo.
> Solución: `normal mode`.

---

## 4. Por qué la imagen es universal

Una sola ISO para todo el parque, sin afinar por modelo, combinando tres elementos:

| Elemento | Qué aporta | Cómo se activa |
|----------|------------|----------------|
| Todos los módulos de kernel | Drivers de red, almacenamiento y vídeo (DRM/KMS) para casi cualquier hardware | `./build --allmodules` |
| Driver X universal + específicos | *modesetting* (en `xorg7`) funciona con cualquier GPU con KMS; Intel/AMD/Nvidia complementan | paquetes `xorg7`, `xorg7-intel/amdgpu/nouveau` |
| Todo el firmware | Wi-Fi, Bluetooth y firmware de GPU sin listarlos | `param allfirmware true` (por defecto) |

La pieza más importante es **`--allmodules`**: garantiza que el módulo KMS de la GPU del equipo
(`i915` de Intel, `amdgpu` de AMD, `nouveau` de Nvidia…) esté presente, para que el driver
*modesetting* de Xorg inicialice la pantalla. Esa es la diferencia entre arrancar gráfico en una VM y
no hacerlo en un equipo físico.

> **Contrapartida — tamaño:** incluir todos los módulos, drivers y firmware hace la imagen más grande
> (y el arranque algo más lento) que una ajustada a un modelo concreto. Para un parque heterogéneo
> casi siempre compensa.

No hacen falta perfiles `machine ...` ni capturas por modelo: con `--allmodules` la imagen ya lleva
lo de todos. Las líneas `machine` que vengan por defecto en `build.conf` son inocuas.

---

## 5. Acceso y depuración por SSH

El paquete `sshd` (dropbear) del Paso 5 permite administrar el cliente y sacar logs. La imagen es de
solo lectura, así que SSH se incluye **al compilar**, no se instala sobre el cliente arrancado. El
paquete trae `systemctl enable dropbear` (arranca solo) y su `ExecStart` no lleva `-w`, por lo que
**permite login de root**.

> **Credenciales por defecto:** usuario `root`, contraseña `pleasechangeme` (de `param rootpasswd`);
> el usuario normal es `tsuser` con la misma contraseña. **Cámbialas** en `build.conf`
> (`param rootpasswd` / `tsuserpasswd`) antes de cualquier despliegue real.

```bash
ssh root@IP_DEL_THINCLIENT

# Logs utiles (se pueden copiar con scp):
dmesg | grep -iE 'drm|i915|amdgpu|radeon|nouveau'    # driver KMS cargado
lspci | grep -iE 'vga|display|3d'                    # GPU del equipo
ls -la /dev/dri/                                     # ¿card0? si no, el kernel no ligó KMS
journalctl -b | grep -iE 'xorg|lightdm|drm|EE'       # arranque de X y display manager
cat /var/log/boot.log ; cat /var/log/messages.log    # arranque y syslog
```

> **El log de Xorg NO está en `/var/log/Xorg.0.log`.** El FS es de solo lectura, así que Xorg escribe
> bajo `/run/user/<uid>/` (logs por usuario en `/run/user/<uid>/applications/`, ficheros `session.*` y
> `xorg.*`). Para localizarlo sin saber el uid:
> ```bash
> find /run /tmp /home -iname 'xorg*.log' -o -iname 'session*' 2>/dev/null
> ```
> Si X ni siquiera arrancó, lo más fiable es `journalctl -b | grep -i xorg` y revisar `/dev/dri/`.

> **Seguridad:** la clave de host de dropbear viene fijada en el repositorio (igual para todos). Para
> depurar es indiferente, pero en producción conviene regenerarla y no dejar login de root con la
> contraseña por defecto, sobre todo si el equipo queda expuesto a la red.

---

## 6. Recompilación posterior

El chroot persiste en el directorio del repositorio. Para recompilar tras un cambio:

```bash
cd /root/thinstation-ng
./setup-chroot     # detecta que ya esta instalado y entra directo
cd /build && ./build --allmodules --license ACCEPT --autodl
```

> Si solo cambiaste `thinstation.conf.buildtime` (sin tocar `build.conf`), el build solo regenera las
> imágenes de arranque — es lo más rápido. Mantén siempre `--allmodules` para conservar la
> universalidad.

---

## 7. Mecanismo del diálogo de IP nativo

El «pedir IP al arrancar y reconectar al cerrar» no requiere scripts propios; está en el paquete
`freerdp`:

| Elemento | Qué hace |
|----------|----------|
| `freerdp.getip` | Su presencia activa `CMD_GETIP=true` (incluido por defecto) |
| `read_options()` | Con `CMD_GETIP` y `$SERVER` vacío, pone `ALLOW_SERVER_EDITS=true` |
| `dialog_get_server_address()` | Muestra un diálogo GTK editable para teclear la IP |
| `xfreerdp` | Se lanza con la IP y las opciones de `SESSION_0_FREERDP_OPTIONS` |
| `check_reconnect()` | Al cerrar la sesión, con `RECONNECT_PROMPT=On` vuelve al diálogo |

---

## 8. Resolución de problemas

| Síntoma | Causa / Solución |
|---------|------------------|
| Cae a consola con `No space left on device` (al copiar `/etc/skel`, `write lastlog failed`) | El FS en RAM se llenó: **poca RAM**. La imagen arranca en RAM (`fastboot lotsofmem`). Sube la VM/equipo a **≥4 GB** (sin recompilar) o usa `param fastboot true` y recompila. Ver Paso 8 |
| En físico no arranca y/o `ip a` solo muestra `lo` (sin NIC) | (1) Arrancó en **BIOS/Legacy**: la ISO es **solo-UEFI**. Arranca por la entrada `UEFI:` del USB, **desactiva CSM** y **Secure Boot**. Comprueba con `[ -d /sys/firmware/efi ]`. (2) Con Ventoy en UEFI pero elegido **`memdisk mode`** → mismo síntoma; usa **`normal mode`**. Ver Paso 8 |
| Equipo se queda en login de consola sin diálogo («not able to go graphical») | Primero descarta **RAM** (fila anterior). Si hay RAM de sobra: Xorg no levantó — el log **no** está en `/var/log/Xorg.0.log` sino en `/run/user/<uid>/` (ver §5). Revisa `journalctl -b \| grep -i xorg` (*no screens found*), `dmesg \| grep -i drm` y `ls /dev/dri/` (¿ligó un driver KMS?, ¿hay `card0`?) |
| ISO no se genera / 0 bytes; `xorriso: 'Boot image file is empty'` | El paso EFI no pudo usar loop/mount: no estás en un entorno con root real. Compila en Fedora o VM Fedora, no en entornos restringidos |
| `setup-chroot` falla al descargar la base | Casi siempre no estás en Fedora (no hay `dnf` ni repos compatibles) |
| `Error: package X does not exist` | Nombres incorrectos en `build.conf`. Usa `xorg7` y `autonet`; `dialog`/`xterm` no son paquetes TS-NG |
| El build se para pidiendo confirmación | Usa siempre `./build --allmodules --license ACCEPT --autodl` |
| No aparece el diálogo de IP (con X funcionando) | Probablemente quedó `SESSION_0_FREERDP_SERVER` en buildtime, o el tipo de sesión no es `freerdp` |
| No entro por SSH al cliente | Confirma `package sshd`, que el cliente tiene IP (`ip a`) y usa `root` / `pleasechangeme` (o tu `rootpasswd`) |

---

## 8b. Despliegue real en curso — equipo MSI (junio 2026)

> **Estado: diagnóstico en curso.** Esta sección registra el caso real para retomarlo.

**Punto de partida:** ISO `20260601-1030-thinstation-efi.iso` que **funciona en VMware** pero en el
equipo físico **MSI** no llegaba a gráfico ni levantaba la red.

**Resuelto:**
1. **Arranque UEFI confirmado.** En el boot menu del MSI se elige `UEFI: KingstonDataTraveler...`
   (no la entrada del disco interno `ubuntu (WDC...)`). Ventoy 1.1.12 muestra `UEFI` abajo a la
   izquierda. ✅
2. **El fallo inicial era `memdisk mode` en Ventoy.** Se estaba lanzando la ISO con
   `Boot in memdisk mode` → no encadena el GRUB EFI. Cambiado a **`Boot in normal mode`** → la ISO ya
   arranca. ✅

**Pendiente de diagnosticar (siguiente paso):** ya arranca por UEFI en normal mode, pero la sesión
gráfica no aparece. Buscado `/var/log/Xorg.0.log` → **no existe** (esperado: el log vive en
`/run/user/<uid>/`, ver §5). Falta determinar si:
- el driver **KMS** ligó a la GPU del MSI (`ls /dev/dri/` → ¿`card0`?, `dmesg | grep -i drm`),
- qué **GPU** monta (`lspci | grep -i vga`),
- si es cuestión de **RAM** (`free -h`, buscar `No space left on device`),
- y la salida de `journalctl -b | grep -iE 'xorg|lightdm|drm|EE'`.

Hipótesis principal: GPU demasiado nueva cuyo módulo/firmware no está en la imagen → `modesetting` de
Xorg se queda sin pantalla. A confirmar con los comandos de arriba.

---

## 9. Referencia rápida de comandos

| Dónde | Comando | Propósito |
|-------|---------|-----------|
| Fedora (root) | `dnf install -y git util-linux which dosfstools` | Dependencias |
| Fedora (root) | `git clone --branch 7.2-Stable https://github.com/thinstation/thinstation-ng.git` | Clonar repo |
| Fedora (root) | `cd thinstation-ng && ./setup-chroot` | Poblar / entrar al chroot |
| Chroot | `cd /build && ./build --allmodules --license ACCEPT --autodl 2>&1 \| tee /build/build.log` | Compilar imagen universal |
| Chroot | `ls -lh /build/boot-images/grub/thinstation-efi.iso` | Verificar la ISO |
| Cliente | `ssh root@IP_THINCLIENT` · `cat /var/log/Xorg.0.log` · `dmesg \| grep -i drm` | Acceso y diagnóstico |

---

## Anexo A — Personalizar el logo de arranque (`watermark.png`)

El logo centrado en la parte inferior mientras carga ThinStation es la marca de agua (*watermark*) del
tema **spinner** de Plymouth. ThinStation-NG instala `plymouth-theme-spinner` y sustituye únicamente
su `watermark.png`, así que personalizar el logo se reduce a **reemplazar ese único fichero** en el
repositorio y recompilar. El resto del tema (el indicador de progreso) se mantiene.

### Dónde está el fichero

Es el mismo fichero visto desde tres sitios. Editas el del repositorio; el de la imagen arrancada es
de solo lectura.

| Contexto | Ruta |
|----------|------|
| Host Fedora | `/root/thinstation-ng/ts/build/packages/plymouth/build/extra/lib64/plymouth/themes/spinner/watermark.png` |
| Dentro del chroot | `/build/packages/plymouth/build/extra/lib64/plymouth/themes/spinner/watermark.png` |
| Imagen arrancada (solo lectura) | `/usr/lib64/plymouth/themes/spinner/watermark.png` |

> **No edites el logo en el thin client arrancado:** el sistema de ficheros es de solo lectura.
> Reemplaza el PNG en el repositorio (host o chroot) y vuelve a compilar.

### Conserva tamaño y formato

El `watermark.png` original es un PNG de **250 × 54 px** con transparencia (**RGBA**). Tres condiciones
al sustituirlo:

- Mantén el nombre exacto `watermark.png`.
- Conserva el fondo transparente (PNG en modo RGBA).
- Conserva las dimensiones (≈ 250 × 54 px). El tema spinner dibuja la marca **a su tamaño real sin
  escalarla**: si es mayor invade/recorta la pantalla, si es menor se ve diminuta. Encaja tu logo
  dentro de un lienzo del mismo tamaño (centrado, con relleno transparente) en lugar de cambiar el
  tamaño del lienzo.

Adaptar cualquier logo a 250×54 conservando proporción y transparencia con ImageMagick
(`dnf install ImageMagick` si no lo tienes):

```bash
# copia de seguridad del logo original
cp watermark.png watermark.png.orig

# encajar TU logo en un lienzo de 250x54, centrado y transparente
magick mi-logo.png -resize 250x54 -background none \
  -gravity center -extent 250x54 watermark.png

# comprobar: debe decir 250 x 54 y RGBA
identify watermark.png
```

> En versiones antiguas de ImageMagick usa `convert` en lugar de `magick`.

### Aplicar el cambio (recompilar)

Como has modificado un fichero de un paquete (no solo `thinstation.conf.buildtime`), hace falta un
build normal; usa la caché, así que será más rápido que la primera vez:

```bash
cd /root/thinstation-ng
./setup-chroot     # entra al chroot ya existente
cd /build && ./build --allmodules --license ACCEPT --autodl
```

> **Nota:** no existe una opción documentada en `build.conf` para cambiar el tema de Plymouth;
> reemplazar `watermark.png` es la vía soportada para personalizar el logo de arranque.

---

*Documento generado a partir del tutorial verificado contra el repositorio oficial
`thinstation/thinstation-ng` rama `7.2-Stable` (mayo 2026), incorporando las lecciones de la puesta en
marcha real: host Fedora, imagen universal de máximo hardware, acceso SSH y logo personalizado.*
