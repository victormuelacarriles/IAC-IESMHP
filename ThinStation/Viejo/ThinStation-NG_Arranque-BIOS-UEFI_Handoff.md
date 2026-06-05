# ThinStation-NG 7.2 — Arranque BIOS + UEFI: estado y traspaso de sesión

> **Objetivo:** una **única ISO** de ThinStation-NG 7.2 que arranque la sesión gráfica
> (RDP kiosko) **tanto en UEFI como en Legacy BIOS**.
>
> **Estado actual (2026-06-03):** UEFI funciona perfecto. BIOS **arranca el kernel**
> pero **no carga la parte gráfica** (sin `lightdm`, `openssh`, ni el resto de paquetes):
> el `lib.squash` no se monta. **Pendiente de resolver.**
>
> **Update sesión 2 (2026-06-03 noche):** La Capa 2 se ha refinado mucho. El módulo
> `isofs.ko.xz` **YA está en la initramfs y se intenta cargar**, pero `insmod`/`modprobe`
> falla. La causa exacta (símbolo concreto que falta vs. módulo corrupto vs. firma) está a
> **un comando de distancia** de quedar confirmada. Ver **sección 10**.
>
> **Update sesión 3 (2026-06-04):** Descartado todo lo "fácil" (ISO vieja, caché, routing,
> arranque en frío) con **md5 idénticos** y **`fastboot` md5 idéntico** chroot↔VM. Problema
> acotado a una **paradoja de extracción**: el `/boot/initrd` de la ISO **contiene**
> `isofs.ko.xz` (44516 B), la VM corre **ese mismo** initramfs (probado), pero el rootfs del
> kernel **no tiene** isofs (dir `kernel/fs/isofs/` vacío). Hipótesis: `copy_module` lo mete
> como **hardlink** y el unpacker de initramfs del kernel lo descarta. **Fix `cp` real
> aplicado y recompilado → BIOS SIGUE fallando.** Ver **sección 11**. ⚠️ **No verificado aún**
> si el initrd nuevo trae isofs con `nlink=1` ni si la VM ya lo tiene — es lo PRIMERO a hacer.
>
> **Update sesión 4 (2026-06-04 tarde) — CAUSA RAÍZ CONFIRMADA:** No era ni hardlink ni isofs.
> El kernel **aborta la descompresión XZ del initrd a mitad** (`dmesg`: *"Initramfs unpacking
> failed: XZ-compressed data is corrupt"*) y deja solo **8173 de 15117** ficheros; isofs (el
> último) cae en la mitad perdida. Causa: el build comprime el initrd con **`xz --threads=0`**
> (multihilo → stream de **23 bloques**) y el descompresor XZ del kernel solo traga
> **single-block**. UEFI no se entera (usa `vfat` builtin para `lib.squash`); BIOS necesita
> isofs (no builtin) y está en la cola no desempaquetada. **Fix: `--threads=1` en `build:506`.**
> Ver **sección 12**.
>
> **Update sesión 5 (2026-06-04 noche) — ⚠️ CORRIGE la sesión 4:** El `--threads=1` se aplicó y
> **verificó** (initrd single-block, `xz -t` OK, 15117 ficheros, isofs presente, md5
> `25a5499…`), pero **BIOS SIGUE fallando idéntico** (8124 ficheros, mismo "XZ corrupt"). El
> multi-bloque era un **red herring**: ambas ISOs (multihilo y single-block) mueren en ~la mitad
> → **no es el xz**. Hipótesis nueva: **GRUB-BIOS no carga el initrd de 454 MB entero en RAM**
> (UEFI con otro cargador sí). El initrd está sobredimensionado (módulos de FS innecesarios). Ver
> **sección 13**; mañana empezar por el **tamaño del RAMDISK en dmesg** (BIOS) y **si UEFI
> desempaqueta los 15117**.

---

## 0. Contexto de compilación

| Dato | Valor |
|------|-------|
| Repo / rama | `Thinstation/thinstation-ng` · `7.2-Stable` |
| Host de build | Fedora, chroot en `/root/thinstation-ng` |
| Dir de build (chroot) | `/build` → `/ts/build` |
| Kernel | `6.19.14-108.fc42.x86_64` |
| ISO de salida | `/root/thinstation-ng/ts/build/boot-images/grub/thinstation-efi.iso` |
| Etiqueta de volumen ISO | `ThinStation` |
| `build.conf` clave | `param initrdcmd "xz"` · `param fastboot lotsofmem` · build con `--allmodules` |
| Pruebas | VMware Workstation (la **misma VM** alternando firmware UEFI/BIOS); también físico MSI |

Comando de recompilación:
```bash
cd /root/thinstation-ng && ./setup-chroot
cd /build && ./build --allmodules --license ACCEPT --autodl
```

---

## 1. Resumen ejecutivo

El problema tiene **dos capas**. La primera está **resuelta y verificada**; la segunda es
la **causa raíz del fallo que queda** y su arreglo **aún no funciona** (recompilado, pero
BIOS sigue sin gráfico).

1. **Capa 1 — enrutado `boot_device` en GRUB (RESUELTA ✅).**
2. **Capa 2 — el módulo `isofs` no está en la initramfs (CAUSA RAÍZ del fallo restante; fix intentado, NO confirmado ❌).**

Dato de partida importante: **la ISO YA es híbrida BIOS+UEFI** (la afirmación de
`ThinStation-NG_Proceso-Compilacion.md` de que es "solo-UEFI" es **incorrecta**).
Verificado:
```
$ xorriso -indev thinstation-efi.iso -report_el_torito plain
Boot record : El Torito , MBR grub2-mbr cyl-align-off
El Torito boot img : 1  BIOS  ...  /boot/grub2/cdboot.img
El Torito boot img : 2  UEFI  ...  /EFI/BOOT/CDBOOT.EFI
```

---

## 2. Cómo funciona el arranque (verificado en el código del repo)

### Generación de la ISO — `ts/build/build`
El `xorriso -as mkisofs` final mete **los dos arranques + MBR isohíbrido**:
`-eltorito-boot boot/grub2/cdboot.img` (BIOS) · `--grub2-mbr .../boot_hybrid.img` (USB BIOS)
· `$ELTORITO` = `-eltorito-alt-boot -platform efi -b EFI/BOOT/CDBOOT.EFI` (UEFI).

### grub.cfg (plantilla `default`)
`boot-images/templates/grub/default/grub.cfg` lanza:
`linux /boot/vmlinuz $KERNEL_PARAMETERS boot_device=$root machine_id=$machine_id`
→ pasa al kernel `boot_device=$root`, donde `$root` lo fija GRUB según el medio/firmware.

### Enrutado en la initramfs — `packages/base/etc/init.d/fastboot`
La función principal decide **dónde buscar `lib.squash`** según `boot_device`:
```sh
if   [[ "$boot_device" == cd* || "$boot_device" == hd96 || "$boot_device" == hd31 ]]; then
        echo "LM=iso" >> /etc/thinstation.runtime ; iso     # monta /dev/disk/by-label/ThinStation
elif [[ "$boot_device" == hd* ]]; then
        disk ; echo "LM=hd" >> /etc/thinstation.runtime      # busca etiqueta THINSTATION/BOOT/boot
elif [[ "$boot_device" == *tftp* || *http* ]]; then pxe
fi
mount_squash
```
- `iso()` monta `/dev/disk/by-label/$CDVOLNAME` (=`ThinStation`) en `/mnt/cdrom0`.
- `disk()` busca particiones etiquetadas `THINSTATION` / `BOOT` / `boot` (**no existen** en esta ISO).
- `mount_squash()` con `lotsofmem` hace `unsquashfs -f -d / $FILE` (vuelca a RAM).

### Por qué UEFI sí y BIOS no (misma VM)
El build (`wrap_efi()`) crea `CDBOOT.EFI` como **imagen VFAT** que contiene una copia de
`/boot/lib.squash`. **UEFI monta el squashfs desde VFAT** (`vfat` sí está en la initramfs).
**BIOS** debe leer `lib.squash` del **ISO9660** → necesita el módulo **`isofs`**, que **no
está en la initramfs** → el montaje falla.

---

## 3. Capa 1 — enrutado `boot_device` (RESUELTA ✅)

**Problema:** en BIOS-desde-USB `$root=hd0,msdos1` → `boot_device=hd0,...` → rama `disk()`
→ busca etiquetas inexistentes → falla. En UEFI `$root=cd0` → rama `iso()` → OK.

**Fix aplicado** en `boot-images/templates/grub/default/grub.cfg` (y copia local
`ThinStation/grub.cfg` del repo de docs). Menuentry actual:
```cfg
menuentry 'ThinStation' --class thinstation --class gnu-linux --class gnu --class os --unrestricted {
	set enable_progress_indicator=1
	set bootdev="$root"
	if [ "$grub_platform" = "pc" ]; then
		if regexp "^hd" "$root"; then
			set bootdev="cd0"
		fi
	fi
	linux /boot/vmlinuz $KERNEL_PARAMETERS boot_device=$bootdev machine_id=$machine_id
	initrd /boot/initrd
}
```
- UEFI (`efi`) → intacto. BIOS-PXE → `$root` de red, no casa `^hd` → respeta PXE.
- BIOS local (`hd*`) → fuerza `cd0` → rama `iso()`.

**Verificado en VM BIOS** (consola tty1 tras fallo):
- `/proc/cmdline` → `... boot_device=cd0 machine_id=...` ✅
- `/etc/thinstation.runtime` → `LM=iso` ✅ (rama correcta)
- `ls /dev/disk/by-label/` → `ThinStation` **existe** ✅

> Nota: en VMware, arrancando la `.iso` como **CD** en BIOS, `$root` resultó ser `cd0`
> directamente (el `regexp ^hd` ni hizo falta). El enrutado **ya no es el problema**.

---

## 4. Capa 2 — `isofs` ausente en la initramfs (CAUSA RAÍZ; fix NO confirmado ❌)

**Síntoma con enrutado ya correcto** (VM BIOS, RAM 8 GB, 7,3 GB libres):
- `LM=iso`, `by-label/ThinStation` existe, **pero `/mnt/cdrom0` NO se monta** (`df`/`mount` sin él).
- Montaje manual:
  ```
  # mount -t iso9660 /dev/disk/by-label/ThinStation /mnt/test
  mount: /mnt/test: unknown filesystem type 'iso9660'.
  ```
- `ls /lib/modules/6.19.14-108.fc42.x86_64/kernel/fs/isofs/isofs.ko*` → **No such file or directory**
  → **el módulo `isofs` NO está en la initramfs.**
- `modprobe` no está en PATH (vive en el squashfs no montado). **`/bin/busybox.shared` SÍ tiene
  applet `modprobe`/`insmod`.**

**Por qué falta `isofs`:** `--allmodules` llena el squashfs grande (`lib.squash`), **no la
initramfs**. La initramfs (con `param initrdcmd "xz"`) se arma desempaquetando el squashfs
base **`initrd.devices`** en `./tmp-tree` (en `build` ≈línea 1159) y copiando algunos módulos
sueltos. `initrd.devices` incluye `vfat` pero **no `isofs`**. La directiva `module isofs` del
`build.conf` **no llega** a la initramfs bajo este flujo.

Piezas relevantes del `build`:
- `unsquashfs -d ./tmp-tree $INITDIR/initrd.devices` (≈1159) → base de la initramfs.
- `copy_module <mod>.ko.xz $KERNVER ./tmp-tree` → copia (hardlink) un módulo a la initramfs.
  Si no lo encuentra imprime `Notice! Module <x> not found for kernel ...` (no aborta).
- `depmod -b ./tmp-tree $KERNVER` se ejecuta **después** (genera `modules.dep` → `modprobe` puede resolver).
- La comprobación del kernel `if [ ! -e /boot/vmlinuz-$KERNVER ]` está ≈línea 1188 (**después** de 1159).

### Fix intentado esta sesión (recompilado, pero BIOS SIGUE fallando)

**Edición 1** — en `/root/thinstation-ng/ts/build/build`, tras
`unsquashfs -d ./tmp-tree $INITDIR/initrd.devices` y los `mkdir` siguientes:
```sh
# Modulos para montar el CD ISO9660 en arranque BIOS (faltan en initrd.devices)
copy_module isofs.ko.xz $KERNVER ./tmp-tree
copy_module cdrom.ko.xz $KERNVER ./tmp-tree
copy_module sr_mod.ko.xz $KERNVER ./tmp-tree
```

**Edición 2** — en `packages/base/etc/init.d/fastboot`, al inicio de `iso()`:
```sh
iso()
{
	/bin/busybox.shared modprobe isofs 2>/dev/null   # añadido
	timeout=150
	...
```

**Resultado:** tras recompilar y grabar bien la ISO, **BIOS sigue sin parte gráfica**
("funciona como antes"). El fix **no surtió efecto** → hay que averiguar por qué.

---

## 5. Hipótesis a verificar en la próxima sesión (por qué el fix no funcionó)

Por orden de probabilidad:

1. **Nombre/extensión del módulo.** ¿El módulo en el árbol del chroot es `isofs.ko.xz` o
   `.ko.zst`/`.ko`? Si no es `.ko.xz`, `copy_module isofs.ko.xz` no copia nada (silencioso).
   **Comprobar en el CHROOT:** `find /lib/modules -name 'isofs*'` y `ls /lib/modules/$KERNVER/kernel/fs/isofs/`.
2. **`isofs` no existe en el árbol de módulos del chroot** (no instalado/compilado) → `copy_module`
   da `not found`. Buscar en `build.log`: `grep -i 'isofs' /build/build.log`.
3. **`$KERNVER` no está definido** en la línea ≈1159 donde se insertaron los `copy_module`
   → `copy_module` busca en `/lib/modules/` (vacío) y falla. **Mover** los `copy_module` a
   **después** de la comprobación del kernel (≈línea 1188) donde `$KERNVER` ya es válido.
4. **Las ediciones no se aplicaron** al binario que corrió (¿se editó el fichero correcto del
   chroot? ¿el build usó caché y no regeneró la initrd?). Verificar fecha de
   `boot-images/initrd/initrd` y que el build dijo "Building image".
5. **El módulo se copió pero no se carga** (Edición 2 sin efecto): `iso()` quizá no se llega a
   ejecutar, o `busybox.shared modprobe` no resuelve sin `modules.dep`. Confirmar con `lsmod`.

### Verificación directa sin arrancar la VM (en el chroot, sobre la ISO nueva)
```bash
# ¿isofs está en la initramfs de la ISO?  (extraer initrd y mirar)
mkdir -p /tmp/ird && cd /tmp/ird
xorriso -osirrox on -indev /build/boot-images/grub/thinstation-efi.iso \
  -extract /boot/initrd /tmp/ird/initrd
# initrd xz+cpio:
xz -dc /tmp/ird/initrd | cpio -idmv 2>/dev/null
find . -name 'isofs*'        # ¿aparece isofs.ko.xz?
```
Si **no aparece** → Edición 1 no copió el módulo (hipótesis 1/2/3). Si **aparece** pero BIOS
falla → es de carga (hipótesis 5): revisar Edición 2 / `modules.dep` en la initrd.

### Comprobar en el árbol del chroot qué módulos hay y cómo se llaman
```bash
ls -la /lib/modules/6.19.14-108.fc42.x86_64/kernel/fs/isofs/
find /lib/modules -name 'isofs*' -o -name 'cdrom*' -o -name 'sr_mod*'
```

---

## 6. Alternativas si la vía `copy_module` resulta frágil

- **Inyectar `isofs` en `initrd.devices`** (el squashfs base) con
  `boot-images/initrd/rebuild_initrd.sh` (desempaqueta a `squashfs-root/`, añadir
  `lib/modules/.../isofs.ko*`, re-squash). Más manual pero independiente del flujo `--allmodules`.
- **Asegurar carga on-demand:** comprobar si existe `/sbin/modprobe` en la initramfs (probablemente
  no). Si no, la carga explícita en `iso()` (Edición 2) es imprescindible además de la presencia
  del `.ko` (Edición 1).
- **Plan B conceptual:** si fuese inviable, replicar el truco de UEFI (cargar `lib.squash` desde
  una FS ya soportada) — pero lo correcto es simplemente tener `isofs` en la initramfs.

---

## 7. Datos ya descartados (no perder tiempo aquí)

- **RAM**: 7,3 GB libres en la VM. No es el fallo de `lotsofmem`/`No space left on device`.
- **Enrutado GRUB**: resuelto y verificado (`boot_device=cd0`, `LM=iso`).
- **ISO no híbrida**: falso, es híbrida (El Torito BIOS+UEFI + MBR).
- **Ventoy**: no aplica aquí; se prueba la `.iso` directa en VMware.
- **GPU/driver**: en VM da igual; el fallo es previo (no monta el squashfs).
- **Controlador IDE vs SATA del CD**: misma VM en ambos modos → mismo controlador, no es el diferenciador.

---

## 8. Pendiente de documentación (cuando BIOS arranque gráfico)

Actualizar `ThinStation/ThinStation-NG_Proceso-Compilacion.md`:
- **Corregir** la afirmación "la ISO es solo-UEFI / el build elimina Legacy" (es **híbrida**).
- Documentar el **fix de arranque gráfico BIOS**: (a) parche `grub.cfg` (enrutado `cd0`),
  (b) `isofs` en la initramfs.
- Añadir el comando de verificación `xorriso ... -report_el_torito` y la sección "POR HACER"
  (líneas ~497-501) puede cerrarse en parte.

---

## 9. Ficheros tocados / relevantes

| Fichero | Estado |
|---------|--------|
| `boot-images/templates/grub/default/grub.cfg` (chroot) | **Editado** (enrutado `cd0`). Copia en `ThinStation/grub.cfg` |
| `ts/build/build` (chroot, ≈L1159) | **Editado** (3× `copy_module`) — revisar si surte efecto |
| `packages/base/etc/init.d/fastboot` (chroot, `iso()`) | **Editado** (`modprobe isofs`) — revisar |
| `ThinStation/ThinStation-NG_Proceso-Compilacion.md` (repo docs) | Pendiente de actualizar |

*El repo de trabajo de Claude es `IAC-IESMHP` (docs); el código de ThinStation vive en el
chroot Fedora `/root/thinstation-ng`, no en este repo. Las verificaciones del código se han
hecho contra `raw.githubusercontent.com/Thinstation/thinstation-ng/7.2-Stable/...`.*

---

## 10. Sesión 2026-06-03 (noche) — diagnóstico fino de la Capa 2 (CARGA del módulo)

Se ha avanzado mucho. **El problema ya NO es la presencia del módulo** (eso está resuelto),
sino que **`isofs` no se carga en el kernel al arrancar en BIOS**. Estado: causa raíz
acotada a 3 posibilidades, pendiente de **un único comando** para confirmar.

### 10.1 Hechos verificados esta sesión (todos ✅)

Sobre `copy_module` (función real, vista en el código):
```sh
copy_module()   # $1=nombre.ko.xz  $2=KERNVER  $3=destino
  rpath=`find /lib/modules/$2 -name $1 -printf %h | cut -d "/" -f5-`
  src=/lib/modules/$2/$rpath/$1 ; dest=$3/lib/modules/$2/$rpath
  [ ! -e $src ] && { ... "Notice! Module ... not found" ; return 1 ; }
  ln $src $dest/$1          # hardlink
```
- **El módulo SÍ existe y con extensión correcta**: `/lib/modules/6.19.14-108.fc42.x86_64/kernel/fs/isofs/isofs.ko.xz`
  (44516 B). Mi sospecha inicial de `.ko.zst` era **falsa**: Fedora 42 usa `.ko.xz`.
- `cdrom` y `sr_mod` → **builtin** en el kernel (`build.log`: "Module cdrom already builtin").
  No hacen falta como módulo. **Solo `isofs` era el ausente.**
- **`$KERNVER` NO es el problema** pese a que `KERNVER=` está en L1965 y los `copy_module`
  en L1165: el bloque de la initrd (≈L1159-1165) se ejecuta **dentro de una función llamada
  DESPUÉS de L1965**, así que `$KERNVER` sí está definido. **Demostrado** porque el módulo
  acaba dentro del initrd.
- **Edición 1 (copy_module isofs) FUNCIONÓ**: extrayendo el initrd de la ISO nueva aparece
  `./lib64/modules/.../kernel/fs/isofs/isofs.ko.xz` (ojo: el árbol del initrd usa **`lib64`**,
  hay usrmerge `lib`→`lib64`). `modules.dep` lista `isofs.ko.xz:` (sin deps).
- **Edición 2 (cascada de carga en `iso()`) también entró** en el initrd nuevo (verificado con
  `sed -n '/^iso()/,/^}/p'`). NO es caché ni fichero equivocado.
- **`fastboot` no hace `modprobe` en ningún otro sitio** → en el caso UEFI que funciona,
  `vfat` es **builtin**; la maquinaria de cargar un módulo suelto nunca se había usado.
- **Herramientas de carga presentes en el initrd**: `/bin/kmod` (real, fresco) + symlinks
  `/{bin,sbin}/modprobe`→kmod; `liblzma.so.5` y `libzstd.so.1` presentes (kmod descomprime xz);
  busybox trae applets `xz`/`unxz`/`unlzma`. **kmod arranca y descomprime bien.**

### 10.2 La cascada de carga implementada (en `iso()` de `fastboot`, chroot)

Sustituye a la línea única `modprobe isofs` original. **Ya está en la ISO actual:**
```sh
iso()
{
    # Cargar isofs (CD ISO9660) en arranque BIOS.
    # busybox modprobe no descomprime .ko.xz; probamos kmod y, si falla, unxz+insmod.
    if ! /sbin/modprobe isofs 2>/dev/null; then
        KO=$(find /lib/modules /lib64/modules -name 'isofs.ko*' 2>/dev/null | head -n1)
        case "$KO" in
            *.xz) /bin/busybox.shared unxz -c "$KO" > /tmp/isofs.ko 2>/dev/null \
                  && /bin/busybox.shared insmod /tmp/isofs.ko 2>/dev/null ;;
            ?*)   /bin/busybox.shared insmod "$KO" 2>/dev/null ;;
        esac
    fi
    timeout=150
    ...
}
```

### 10.3 EL FALLO actual (lo nuevo y concreto)

En el tty BIOS, `/sbin/modprobe isofs` da:
```
modprobe: ERROR: could not insert 'isofs': Unknown symbol in module, or unknown parameter (see dmesg)
modprobe rc=1
```
**PERO** al revisar `dmesg | grep -iE 'isofs|unknown symbol|version magic|disagrees'`
→ **VACÍO** (no registró nada). Y:
- `uname -r` (VM) = `6.19.14-108.fc42.x86_64` → **coincide** con los módulos (no es desajuste de kernel).
- `modinfo isofs` (chroot): `vermagic` coincide, `depends:` **vacío**, módulo **firmado** por Fedora.
- `modprobe --show-depends -S 6.19.14-108.fc42.x86_64 isofs` → solo `insmod .../isofs.ko.xz`
  (sin dependencias). **No existe `nls_base.ko`** en el árbol → `nls_base` es **builtin**
  (CONFIG_NLS=y). Por eso "añadir nls_base" NO aplica.

**Contradicción a resolver:** módulo sin deps + kernel correcto NO debería dar "Unknown
symbol", y además el kernel no logueó nada → el mensaje `(see dmesg)` que se vio era de
**otra sesión**. Falta capturar la queja del kernel **en el mismo instante** del fallo.

### 10.4 Hipótesis viva (por probabilidad) y comando pendiente

1. **Símbolo Joliet en módulo separado (FAVORITA).** En kernels 6.x, `utf8s_to_utf16s` /
   `utf16s_to_utf8s` se separaron de `nls_base` a **`nls_ucs2_utils.ko`** (presente en el
   árbol: `kernel/fs/nls/nls_ucs2_utils.ko.xz`). isofs lo usa para Joliet y lo carga de forma
   **dinámica** (por eso NO sale en `depmod`/`--show-depends`). → Fix = **un `copy_module`
   más: `nls_ucs2_utils.ko.xz`** (y por seguridad un codepage: `nls_utf8`, `nls_cp437`,
   `nls_iso8859-1`).
2. **Módulo corrupto/truncado** en el initrd (problema de `copy_module`/hardlink/extracción).
3. **Firma / formato** (menos probable: está firmado y vermagic coincide).

**Comando que faltó ejecutar (en el tty BIOS) para decidir entre 1/2/3:**
```sh
dmesg -c >/dev/null 2>&1
modprobe -v isofs ; echo "modprobe rc=$?"
dmesg
# prueba cruda sin kmod:
F=$(find /lib /lib64 -name 'isofs.ko*' 2>/dev/null | head -n1) ; echo "F=$F" ; ls -l "$F"
unxz -c "$F" > /tmp/i.ko 2>/dev/null ; ls -l /tmp/i.ko ; file /tmp/i.ko
insmod /tmp/i.ko ; echo "insmod crudo rc=$?"
dmesg | tail -20
```
Lectura del resultado:
- `Unknown symbol utf8s_to_utf16s` (o similar) → **hipótesis 1** → `copy_module nls_ucs2_utils.ko.xz`.
- `Invalid module format` / `Bad magic` / tamaño ≠ ~44 KB / `file` no dice "ELF relocatable"
  → **hipótesis 2** (corrupto).
- `Key was rejected` → **hipótesis 3** (firma).

### 10.5 Fix preparado para hipótesis 1 (aplicar tras confirmar el símbolo)

En `ts/build/build` (chroot), junto al `copy_module isofs.ko.xz` (~L1165):
```sh
copy_module isofs.ko.xz         $KERNVER ./tmp-tree
copy_module nls_ucs2_utils.ko.xz $KERNVER ./tmp-tree   # utf8s_to_utf16s / utf16s_to_utf8s (Joliet)
copy_module nls_utf8.ko.xz      $KERNVER ./tmp-tree
copy_module nls_cp437.ko.xz     $KERNVER ./tmp-tree
copy_module nls_iso8859-1.ko.xz $KERNVER ./tmp-tree
```
Recompilar (`cd /build && ./build --allmodules --license ACCEPT --autodl`) y, **antes de
arrancar**, verificar en el initrd nuevo: `find . -path '*nls*'` y reproducir la carga.
La `iso()` no necesita más cambios: `/sbin/modprobe isofs` los arrastrará si están presentes
(el de ucs2 por símbolo; los codepages se cargan al montar). Si la carga manual de isofs
funciona solo tras hacer antes `insmod nls_ucs2_utils.ko`, añadir esa carga previa explícita
en `iso()`.

---

## 11. Sesión 2026-06-04 — Descartado ISO vieja/caché; acotado a la EXTRACCIÓN del initramfs por el kernel (fix hardlink aplicado, SIGUE fallando)

Sesión muy productiva en descartes. La hipótesis del **símbolo Joliet (10.4.1)** quedó
**aparcada**: el problema ocurre **antes**, en que `isofs.ko.xz` **no llega al rootfs que el
kernel monta en BIOS**, pese a estar dentro del `/boot/initrd` de la ISO.

### 11.1 Lo que esta sesión DESCARTA definitivamente (con pruebas)

- **No es ISO vieja ni caché de VMware.** `md5sum` de `/build/boot-images/grub/thinstation-efi.iso`
  **==** `md5sum` de la ISO que monta VMware (`/home/vmuela/Descargas/thin/thinstation-efi.iso`):
  ambas `090c409d39a263275712460798dab850`. Arranque en frío (power off, ISO movida de carpeta).
- **No es un segundo initrd ni routing.** La ISO tiene **un único** `/boot/initrd`; el
  `grub.cfg` real (`/boot/grub2/grub.cfg`) es el parcheado (cd0) y carga `initrd /boot/initrd`.
  `/proc/cmdline` en la VM → `boot_device=cd0`. ✅
- **La VM corre EXACTAMENTE ese initramfs.** `md5sum /etc/init.d/fastboot` (VM) **==**
  `md5sum` del `fastboot` extraído del `/boot/initrd` de la ISO: ambos
  `30cd09ba08e5bd8b76654e3a5efee59e`. El `iso()` de la VM tiene la cascada nueva de 10.2.
- **El `/boot/initrd` de la ISO SÍ contiene isofs.** Extracción
  (`xorriso -extract /boot/initrd` + `xz -dc | cpio -idmv`): aparece
  `lib64/modules/.../kernel/fs/isofs/isofs.ko.xz` (**44516 B**) y también
  `nls_ucs2_utils.ko.xz` (8204 B).
- **El initrd NO está concatenado.** `xz --list` → **1 stream, 22 bloques**, ratio 0.822.
  Los 4358 "magic xz" que cuenta un script son los **`.ko.xz` internos** (módulos ya
  comprimidos, guardados en bloques *stored*; por eso ratio ~0.82). El initrd se crea con un
  único `find . -print0 | cpio --null -oV --format=newc | $ts_initrdcmd` desde `tmp-tree`
  (`ts/build/build` **línea 515**).

### 11.2 La paradoja central (estado actual del bug)

En la VM BIOS, con la ISO buena:
- `LM=iso`, `/dev/disk/by-label/ThinStation` existe, `/lib64` **NO** es montaje, `mount` sin
  squashfs/cdrom/loop, `lsmod` **vacío**, no hay `/usr/sbin/lightdm` ni `/usr/bin/Xorg`
  → es el **initramfs puro, mínimo** (lib.squash NO se montó/desplegó).
- `find / -name 'isofs.ko*'` → **vacío**. `ls -la /lib64/modules/$KERNVER/kernel/fs/isofs/`
  → `total 0` (**dir vacío**, fechado 06:03 = base `initrd.devices`).
- En cambio `modules.dep` (675 KB, completo) **sí** lista `kernel/fs/isofs/isofs.ko.xz:`.

> **Mismo cpio**: `cpio` en userspace extrae isofs (44516 B); el **kernel no** lo deja en el
> rootfs. La **única** variable que puede diferir entre ambas extracciones para el mismo
> archivo son los **HARDLINKS**.

### 11.3 La función `copy_module` y por qué genera un hardlink (causa probable)

`ts/build/build` (~L285). El final de la función hace `ln $src $dest/$1` (hardlink), con
`$src=/lib/modules/$KERNVER/.../isofs.ko.xz` **fuera** de `tmp-tree`. Resultado en el cpio:
entrada con `nlink≥2` cuya "pareja" no está en el archivo. GNU cpio la reconstruye; el
unpacker de initramfs del kernel (más estricto con hardlinks) **la descarta** → directorio
creado pero `.ko` ausente. Encaja con:
- `fastboot` (fichero normal, `nlink=1`) → presente en la VM. ✅
- `modules.dep` (lo regenera `depmod`, fichero normal) → presente. ✅
- `isofs.ko.xz` (hardlink vía `copy_module`) → **ausente**. ❌

### 11.4 Fix aplicado esta sesión (en `ts/build/build`, ~L1165) — RECOMPILADO, SIGUE FALLANDO

Se **quitaron** `copy_module cdrom.ko.xz` y `copy_module sr_mod.ko.xz` (ambos **builtin** en
este kernel, `return 3` inútil — confirmado en 10.1). Quedó:
```sh
copy_module isofs.ko.xz $KERNVER ./tmp-tree
# Forzar copia REAL (no hardlink): el unpacker de initramfs del kernel descarta
# entradas con nlink>1 cuyo "par" queda fuera del cpio -> el .ko no llega al rootfs.
for m in isofs nls_ucs2_utils nls_utf8 nls_cp437 nls_iso8859-1; do
    s=$(find /lib/modules/$KERNVER -name "$m.ko.xz" 2>/dev/null | head -n1)
    [ -n "$s" ] && { d="./tmp-tree${s#/}"; mkdir -p "$(dirname "$d")"; \
        cp -f --remove-destination "$s" "$d" && echo "cp-real $m OK" || echo "FALTA $m"; }
done
```
**Resultado:** recompilado y BIOS **sigue sin gráfico**.

### 11.5 ⚠️ Verificaciones que NO se hicieron tras este build (PRIMERO en la próxima sesión)

El fix puede no haber surtido efecto **o** isofs ya estar presente y fallar otra cosa. Falta:
1. **¿El initrd NUEVO trae isofs con `nlink=1`?**
   ```bash
   rm -rf /tmp/ird && mkdir -p /tmp/ird && cd /tmp/ird
   xorriso -osirrox on -indev /build/boot-images/grub/thinstation-efi.iso -extract /boot/initrd ./initrd 2>/dev/null
   xz -dc initrd | cpio -itv 2>/dev/null | grep -E 'isofs|nls_ucs2'
   ```
   (El **2º campo** de `cpio -itv` es el `nlink`. Debe ser **1**.)
2. **¿`build.log` imprimió `cp-real isofs OK`?** `grep -n 'cp-real\|FALTA' /build/build.log`.
   Si no aparece o dice `FALTA`, el `cp` no se ejecutó (¿`$KERNVER` vacío ahí? ¿se editó el
   fichero correcto? ¿build cacheó?). Confirmar también que `$KERNVER` está definido en L1165.
3. **¿La VM con la ISO nueva ya tiene isofs?** (tras copiar ISO a VMware + power off + BIOS):
   ```sh
   lsmod | grep isofs ; find / -name 'isofs.ko*' 2>/dev/null
   ```

### 11.6 Árbol de decisión para la próxima sesión (según 11.5)

- **(A) isofs YA presente en la VM y se carga** (`lsmod` lo muestra) pero `/mnt/cdrom0`/lib.squash
  sigue sin montar → el bug ya **no** es isofs; depurar `iso()`/`mount_squash` con logging
  (¿`systemd-mount` falla? ¿`$CDVOLNAME`/by-label? ¿`squash_loc`?). Por fin tendría sentido el
  test de símbolo de **10.4** si el `modprobe` falla en caliente.
- **(B) isofs presente pero NO carga** (`modprobe`/`insmod` falla) → ejecutar el test crudo de
  **10.4** (`dmesg -c; insmod /tmp/i.ko; dmesg`) para ver el símbolo real → si sale
  `utf8s_to_utf16s`/`utf16s_to_utf8s`, confirmar que `nls_ucs2_utils.ko` está presente (ya se
  copia) y, si hace falta, cargarlo **antes** explícitamente en `iso()`.
- **(C) isofs SIGUE ausente** pese al `cp` (el caso si 11.5.1 da dir vacío / nlink raro) →
  la hipótesis del hardlink **no era** (o el `cp` no se aplicó). Pivotar a **Plan B**:
  - **Inyectar isofs en `initrd.devices`** (el squashfs base) con
    `boot-images/initrd/rebuild_initrd.sh` (desempaquetar `squashfs-root/`, añadir
    `lib64/modules/.../isofs.ko.xz` como fichero normal, re-squash). Así isofs viaja en la
    base, sin pasar por `copy_module` ni hardlinks.
  - O investigar si el kernel **trunca** la extracción del initrd de 455 MB (poco probable
    con 7,8 GB RAM, pero medir): comparar nº de ficheros del cpio (`cpio -itv | wc -l`) contra
    los presentes en la VM, y mirar `dmesg | grep -i initramfs` en arranque.
  - O verificar **cuál** de las tres líneas de `cpio` (512 / 515 / 549) produce realmente el
    `/boot/initrd` de la ISO y si hay un `boot-images/initrd/initrd` intermedio cacheado.

### 11.7 Datos clave para retomar

| Dato | Valor |
|------|-------|
| md5 ISO (build == VMware) | `090c409d39a263275712460798dab850` |
| md5 `fastboot` (chroot == VM) | `30cd09ba08e5bd8b76654e3a5efee59e` |
| isofs en ISO | `lib64/modules/6.19.14-108.fc42.x86_64/kernel/fs/isofs/isofs.ko.xz`, 44516 B |
| nls_ucs2_utils en ISO | `.../kernel/fs/nls/nls_ucs2_utils.ko.xz`, 8204 B |
| initrd | 1 stream xz, 22 bloques, 455067760 B comprimido / 553383936 B descomprimido |
| Línea cpio que arma initrd | `ts/build/build:515` (`find . | cpio newc | $ts_initrdcmd`) |
| Línea del fix | `ts/build/build` ~1165 (tras `copy_module isofs`) |
| copy_module (hardlink) | `ts/build/build` ~285 (`ln $src $dest/$1`) |
| Ruta ISO en VMware | `/home/vmuela/Descargas/thin/thinstation-efi.iso` |
| cmdline VM | `... boot_device=cd0 machine_id=...` (sin `fastboot`/`lotsofmem` visible) |

---

## 12. Sesión 2026-06-04 (tarde) — CAUSA RAÍZ CONFIRMADA: el kernel no descomprime el initrd (xz multihilo)

Tras descartar hardlink y "isofs el último", el `dmesg` de la VM BIOS dio la prueba definitiva.

### 12.1 La prueba (dmesg en la VM BIOS)
```
[ 0.828761] Trying to unpack rootfs image as initramfs...
[ 2.770664] Initramfs unpacking failed: XZ-compressed data is corrupt
```
- `find / -xdev | wc -l` en la VM = **8173**; el cpio del initrd tiene **15117** → el kernel
  desempaqueta ~la mitad y **aborta**. isofs es el fichero **15117** (el último) → nunca llega.
- El `xz` de **userspace** descomprime el initrd **entero** (15117) sin error → el fichero NO
  está corrupto; es el **descompresor XZ del kernel** el que no puede con este stream.

### 12.2 La causa: `xz --threads=0` (multihilo → multi-bloque)
- `xz --list --verbose` del initrd: **Streams: 1, Blocks: 23**, Check **CRC32**, bloques de
  **24 MiB** uncompressed cada uno → firma inequívoca de **xz multihilo**.
- `build:505-506`:
  ```sh
  if [ "$ts_initrdcmd" == "xz" ]; then
          ts_initrdcmd="xz --threads=0 --check=crc32"
  ```
  `--threads=0` = usa los 16 núcleos → stream **multi-bloque**. El descompresor XZ del kernel
  (`lib/decompress_unxz.c`) es single-block y **falla** en multi-bloque (lo reporta como
  "corrupt" a mitad). El `--check=crc32` ya era correcto (el kernel solo trae CRC32).
- **Reconcilia UEFI vs BIOS**: GRUB carga el **mismo** initrd en ambos; el truncado a 8173 pasa
  igual. UEFI funciona porque monta `lib.squash` con `vfat` **builtin** (no necesita la cola del
  initramfs). BIOS necesita **isofs** (no builtin), que está en la cola perdida → falla.

### 12.3 El fix (1 línea, `build:506`)
```sh
ts_initrdcmd="xz --threads=1 --check=crc32"    # antes: --threads=0
```
`--threads=1` → single-thread → **1 solo bloque** → el kernel lo descomprime entero. El
`copy_module`/`cp-real` de la sección 11 puede quedarse (ya no estorba: con el initrd completo,
isofs llega aunque sea el último).

### 12.4 Verificación OBLIGATORIA antes de arrancar (chroot, sobre la ISO nueva)
```bash
xz --list initrd                                     # DEBE decir Blocks: 1 (no 23)
xz -dc initrd | cpio -itv 2>/dev/null | grep -c .    # ~15117 ficheros
```
Y en la VM BIOS: `dmesg | grep -i unpack` NO debe decir "failed"; `find / -name 'isofs.ko*'`
debe encontrarlo; `lsmod | grep isofs` tras el montaje del CD.

> ⚠️ **Resultado real (ver sección 13):** el `--threads=1` se aplicó y verificó (single-block,
> `xz -t` OK, 15117 ficheros), pero **BIOS siguió fallando idéntico** (8124 ficheros, mismo
> "XZ corrupt"). La causa **no era** el multi-bloque. El fix es necesario pero NO suficiente.

---

## 13. Sesión 2026-06-04 (noche) — `--threads=1` VERIFICADO pero BIOS SIGUE igual → NO era el xz; el initrd se trunca al CARGAR

⚠️ **Corrige la conclusión de la sección 12.** El `--threads=1` está bien y se verificó (initrd
single-block, `xz -t` OK), **pero NO arregla el arranque BIOS**. La causa raíz real es otra.

### 13.1 Hechos nuevos (todos verificados)
- **ISO nueva single-block OK** (build con `--threads=1`, tras resolver "disco lleno"):
  `xz --list` → **Streams 1 · Blocks 1 · CRC32**, `xz -t` **OK**, **15117** ficheros, isofs
  presente (44516 B). md5 = **`25a549919ee98af60cda03cb10936874`**.
- **La VM arranca ESA ISO** (no es ISO vieja): VMware *Fedora ThinStation* → CD/DVD (SATA) →
  *Use ISO image* = `/home/vmuela/Descargas/thin2/thinstation-efi.iso`, md5 `25a5499…`,
  *Connect at power on* ✓. La carpeta `thin/` ya no existe.
- **BIOS sigue fallando IGUAL**: `dmesg` → *"Initramfs unpacking failed: XZ-compressed data is
  corrupt"* a ~2.75 s; `find / -xdev | wc -l` = **8124** (multihilo daba 8173); isofs ausente.

### 13.2 Por qué el multi-bloque era un RED HERRING
La ISO multihilo (vieja) fallaba a **8173** ficheros / 2.77 s; la single-block (nueva) a
**8124** / 2.75 s. **Casi el mismo punto.** Si el problema fuese la estructura de bloques xz, la
single-block no fallaría (o fallaría en otro sitio). Que ambas mueran en ~la mitad indica que
**NO es el xz**: se corta la **misma cantidad de datos**, en un punto fijo.

### 13.3 Hipótesis principal: GRUB-BIOS no carga el initrd entero en RAM
El initrd son **454 MB**. Userspace `xz -t` lo valida entero → el **fichero** está bien. Pero el
kernel solo desempaqueta ~la mitad y dice "corrupt" = topa con el final **truncado de lo que
GRUB metió en memoria**. UEFI usa otro cargador (sin ese límite) → arranca. Encaja con que el
punto de fallo sea independiente de la compresión.

### 13.4 LO PRIMERO mañana (2 datos decisivos — NO teorizar antes)
1. **Tamaño del initrd que recibió el kernel en BIOS** (tty BIOS):
   ```sh
   dmesg | grep -iE 'RAMDISK|initrd|Trying to unpack|unpacking'
   ```
   En `RAMDISK: [mem 0x…-0x…]` calcular `fin-inicio`:
   - ≈ **220-260 MB** (mitad de 433 MB comprimidos) → **GRUB-BIOS truncó** → es el **CARGADOR**.
   - ≈ **433 MB** (entero) y aun así "corrupt" → es el **descompresor del kernel** ahogándose con
     un initrd gigante (vía: gzip/zstd o, mejor, adelgazar el initrd).
2. **¿UEFI desempaqueta los 15117 o también ~8124?** (linchpin). UEFI arranca gráfico; si se
   puede abrir un tty (Ctrl+Alt+F2) o terminal: `dmesg | grep -i unpack` y `find / -xdev | wc -l`.
   - UEFI con **15117** y sin "failed" → es **BIOS-loader** (hipótesis 13.3 confirmada).
   - UEFI también ~**8124** con "failed" pero arranca igual (vía `vfat` builtin + lib.squash) →
     es el **descompresor del kernel**, no el cargador BIOS.

### 13.5 Dirección del fix (según 13.4) — el initrd de 454 MB es desproporcionado
La cola del cpio son módulos de FS que un thin-client NO necesita en el initramfs (`gfs2`,
`ceph`, `f2fs`, `erofs`, `dlm`, `ecryptfs`, `coda`, `afs`, `9p`, `befs`, `affs`, `exfat`,
`cachefiles`…). El initramfs solo necesita para arrancar: **isofs, squashfs, loop, overlay**,
más `vfat`/`sr_mod`/`cdrom` (builtin).
- **(Loader truncado o decoder ahogado) → ADELGAZAR `initrd.devices`**: quitar el grueso de
  módulos del squashfs base de la initramfs para bajar el initrd de 454 MB a decenas de MB.
  Investigar `boot-images/initrd/rebuild_initrd.sh` y de dónde sale la lista de módulos de
  `initrd.devices`. Con un initrd pequeño, GRUB-BIOS lo carga entero y el kernel lo descomprime
  sin truncar → isofs (aunque siga al final) llega.
- **(Solo si es decoder y no se puede adelgazar) → `param initrdcmd` a `gzip`/`zstd`** (verificar
  `CONFIG_RD_GZIP`/`CONFIG_RD_ZSTD`) — no ataca el problema de tamaño/carga.
- **(Parche rápido)** forzar `isofs.ko.xz` en la **primera mitad** del cpio (se carga aunque haya
  truncado). Frágil; preferible adelgazar.

### 13.6 Datos clave (estado a cierre de sesión)
| Dato | Valor |
|------|-------|
| ISO buena (single-block) md5 | `25a549919ee98af60cda03cb10936874` |
| Ruta ISO en VMware | `/home/vmuela/Descargas/thin2/thinstation-efi.iso` (VM "Fedora ThinStation") |
| initrd | 453.742.260 B comprimido / 528 MB / **1 bloque CRC32** / 15117 ficheros |
| BIOS desempaqueta | **8124 / 15117** ficheros, luego "XZ corrupt" a ~2.75 s |
| Fix aplicado y verificado | `build:506` `xz --threads=1 --check=crc32` (necesario, NO suficiente) |
| Disco chroot | `/` = 15 G; mantener limpio (`dnf clean packages dbcache` libera ~2 G) |
| `/build` | symlink → `/ts/build`; no existe `/root/thinstation-ng/ts/build/build` (setup-chroot no lo clobbera) |
| RAM VM | 7,8 GB · 16 cpu |
