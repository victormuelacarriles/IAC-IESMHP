# CLAUDE.md — `Ubuntu/ISO/26.04/utiles/ArranquePorNFS/`

Herramientas para **arrancar la imagen Live de instalación por red (NFS)** en
lugar de hacerlo desde un USB/DVD. Así se puede **reinstalar un aula entera
desde un NAS**, incluso **en remoto** si el equipo ya tiene Linux y SSH.

> Carpeta añadida el 2026-10-08 (commit `f2e9a37`). Son **herramientas manuales
> del operador**, **no** forman parte de la cadena automática
> `0a → 0b → 1 → 2 → 3 → 4`. Ningún script de la cadena las llama.

---

## Idea general

```
NAS (NFS)  10.0.72.253:/mnt/DiscosRapidos/LiveCDs/Ubuntu26.04-IESMHP
   └── CONTENIDO extraído de la ISO (casper/vmlinuz, casper/initrd,
       casper/*.squashfs, .disk/info…), NO el fichero .iso
          ▲
          │  boot=casper netboot=nfs nfsroot=<servidor:/ruta> ip=dhcp
          │
   ┌──────┴──────────────────────────────┬────────────────────────────────────┐
   │ Opción A — grub-nfs-live.sh         │ Opción B — USB/ISO de arranque NFS │
   │ Equipo que YA tiene Linux + SSH.    │ Equipo sin SO o sin acceso SSH.    │
   │ Se reescribe su GRUB para que el    │ Un USB UEFI pequeño (solo kernel + │
   │ próximo arranque cargue el Live     │ initrd) con un menú de servidores  │
   │ por NFS. Sin USB, en remoto.        │ NFS. Sirve también para la VM.     │
   └─────────────────────────────────────┴────────────────────────────────────┘
          │
          ▼
   Live de Ubuntu por red → (si es la imagen IESMHP) arranca la cadena de
   instalación habitual → reinstalación completa del equipo.
```

- Por el nombre (`Ubuntu26.04-IESMHP`) el export del NAS contiene la **ISO
  personalizada** que genera `0a-CreaISO.sh`, así que al arrancarla se lanza la
  instalación desatendida. Cualquier Live de Ubuntu con `casper/` también vale.
- **El kernel y el initrd se copian en local** (en `/boot/live` o en el USB),
  pero el `*.squashfs` se lee por NFS. Kernel/initrd **tienen que ser los de la
  misma imagen** que el squashfs: si se actualiza la imagen del NAS, hay que
  volver a copiarlos (repitiendo el script o rehaciendo el USB). Si no, el
  kernel no encuentra sus módulos.
- Requiere **cable** y **DHCP** en la red durante el arranque (`ip=dhcp` en el
  initramfs), aunque luego el equipo instalado use IP estática.

Servidores NFS que aparecen en los ficheros:

| Servidor | Ruta | Aula |
|----------|------|------|
| `10.0.72.253` | `/mnt/DiscosRapidos/LiveCDs/Ubuntu26.04-IESMHP` | NAS IABD |
| `10.0.32.253` | `/mnt/DiscosRapidos/LiveCDs/Ubuntu26.04-IESMHP` | NAS SMRV |
| `10.0.1.253`  | `/mnt/DiscosRapidos/LiveCDs/Ubuntu26.04-IESMHP` | NAS Centro |
| `10.0.72.140` | `/srv/ubuntu-live` | IABD-20 (también es el proxy del aula) |

Para ver qué exporta un servidor: `showmount -e 10.0.72.253`.

---

## Ficheros

| Fichero | Qué es |
|---------|--------|
| `grub-nfs-live.sh` | **Opción A.** Script que reconfigura GRUB del equipo para arrancar el Live por NFS. Con `--restaurar` lo deshace. |
| `Pasos para conectar desde Win a Linux el script.txt` | Chuleta para copiar `grub-nfs-live.sh` por SSH (desde PowerShell o desde Linux) a un equipo y ejecutarlo como root. |
| `Pasos para generar una iso autorrancable.md` | **Opción B.** Pasos para preparar la carpeta `~/usb-nfs` (cargador UEFI firmado + kernel/initrd + `grub.cfg` con el menú de servidores) y generar la ISO. **Versión más reciente** (incluye el enlace a la conversación de Claude y el paso final de `crea-iso-arranque-nfs.sh`). |
| `iso arranque por nfs/crea-iso-arranque-nfs.sh` | **Opción B.** Genera la ISO híbrida a partir de `~/usb-nfs`. |
| `iso arranque por nfs/Pasos para generar una iso autorrancable.md` | Copia **anterior** del `.md` de arriba (sin el enlace ni el último paso). Duplicado. |
| `MInt vs Ubuntu (desde casa).mp4` | Vídeo (32 MB) de demostración del arranque Mint vs Ubuntu. No es código. |

---

## Opción A — `grub-nfs-live.sh`

### Uso

```bash
sudo ./grub-nfs-live.sh 10.0.72.253:/mnt/DiscosRapidos/LiveCDs/Ubuntu26.04-IESMHP
sudo ./grub-nfs-live.sh --restaurar /root/grub-backup-AAAAMMDD-HHMMSS.tar.gz
```

Copiarlo al equipo (desde la carpeta en Windows, con la clave SSH de root
autorizada en `Autorizados.txt`):

```powershell
$ip=Read-Host "IP Linux?"
Get-Content .\grub-nfs-live.sh -Raw | ssh root@$ip "cat > grub-nfs-live.sh && chmod +x grub-nfs-live.sh"
ssh root@$ip
```

> El `.txt` menciona también `./nfsgrub.sh`: es un **nombre antiguo**, ese
> fichero no existe; usar `grub-nfs-live.sh`.

### Qué hace, paso a paso

Constantes al principio: `DESTINO=/boot/live`, `SCRIPT_GRUB=/etc/grub.d/09_nfs_live`,
`ENTRY_ID=nfs-live`, `TIMEOUT_MONTAJE=20`, `MANTENER=(00_header 05_debian_theme 09_nfs_live)`.

0. **Comprobaciones**: root; argumento con formato `servidor:/ruta`; existen
   `mount.nfs`, `update-grub`, `grub-probe`, `grub-mkrelpath`, `timeout`, `tar`
   (hace falta `nfs-common`).
1. **Comprueba el NFS**: lo monta en `/tmp/nfs-live.XXXXXX` (`ro,nolock,soft`,
   máximo 20 s) y exige `casper/vmlinuz`, `casper/initrd*` y algún
   `casper/*.squashfs`. Si existe, muestra `.disk/info`. El `trap limpiar EXIT`
   desmonta y borra el punto de montaje pase lo que pase.
2. **Confirmación interactiva** (`read -rp "... [s/N]"`). Cualquier respuesta
   distinta de `s`/`S` cancela **sin tocar nada**.
3. **Copia** `vmlinuz` e `initrd` a `/boot/live/` y desmonta el NFS.
4. **Copia de seguridad** de `/etc/default/grub` + `/etc/grub.d/` en
   `/root/grub-backup-<fecha>.tar.gz`. **Solo la primera vez**: si
   `09_nfs_live` ya existe, no la rehace, para conservar la original.
5. **Desactiva el resto de entradas**: `chmod -x` a todo `/etc/grub.d/*` salvo
   los de `MANTENER` (cae `10_linux`, `30_os-prober`, `30_uefi-firmware`,
   `40_custom`…). El equipo **deja de poder arrancar su SO instalado**.
6. **Crea `/etc/grub.d/09_nfs_live`**: una única `menuentry` con
   `--id nfs-live` que busca la partición por UUID (`grub-probe`) y usa rutas
   relativas (`grub-mkrelpath`, que tiene en cuenta un `/boot` separado):
   `linux … boot=casper netboot=nfs nfsroot=<NFS> ip=dhcp quiet splash noprompt`.
7. **`/etc/default/grub`**: `GRUB_DEFAULT=nfs-live`, `GRUB_TIMEOUT_STYLE=menu`,
   `GRUB_TIMEOUT=5` (con `fijar_variable`, que sustituye la línea, aunque esté
   comentada, o la añade). Ejecuta `update-grub` y comprueba que `nfsroot=`
   aparece en `/boot/grub/grub.cfg`. Al final indica cómo restaurar.

**`--restaurar <copia>`**: borra `09_nfs_live`, extrae el tar en `/` (con `-p`
recupera los permisos de ejecución) y lanza `update-grub`. **No** borra
`/boot/live/`.

### Observaciones (sin corregir; documentadas al analizar el 2026-10-08)

- **Es interactivo a propósito**: es la excepción que el `CLAUDE.md` raíz
  permite en la regla 4 (herramienta que lanza a mano el operador). Para varios
  equipos por SSH sin teclear, la respuesta se puede pasar por stdin
  (`echo s | ./grub-nfs-live.sh …`), porque `read` lee de stdin.
- **Sin vuelta atrás desde GRUB**: como se desactivan todas las demás
  entradas, si el NFS no responde al arrancar, casper acaba en la shell de
  initramfs y el equipo **se queda ahí sin SSH**. Sin monitor solo se recupera
  arrancando por otro medio (o, si la instalación llegó a empezar, terminándola).
  Antes de reiniciar, comprobar que el NFS y el DHCP del aula funcionan.
- **Segunda ejecución**: no se crea una copia nueva y `COPIA` queda vacía, así
  que no se muestra el comando de restaurar. La copia buena es la
  `/root/grub-backup-*.tar.gz` **más antigua**.
- `quiet splash` en la entrada: con Plymouth y sin salida de vídeo puede haber
  problemas (regla 6 del `CLAUDE.md` raíz). Comprobar sin monitor.
- El comentario `# ---------- 6. Crear la entrada de la opción A ----------` se
  refiere a la "opción A" de la conversación de Claude donde se diseñó.

---

## Opción B — USB / ISO de arranque por NFS

### Preparar la carpeta `~/usb-nfs` (resumen del `.md`)

```
~/usb-nfs/
├── EFI/boot/{bootx64.efi, grubx64.efi, mmx64.efi}   ← copiados de la ISO oficial de Ubuntu 26.04 (shim + GRUB firmados)
├── .disk/info                                        ← de la misma ISO (ver nota)
├── boot/grub/grub.cfg                                ← menú con una entrada por servidor NFS
└── live/img1/{vmlinuz, initrd}                       ← de casper/ del export NFS (montado con vers=3)
```

- `grub.cfg` empieza con `if [ "$grub_platform" != "efi" ]`: en modo BIOS
  muestra un error, espera 30 s y hace `halt`. **El USB solo arranca en UEFI**
  (con Secure Boot, porque se usan shim y GRUB firmados por Canonical).
- Menú: `timeout=10`, `default=0`, con 4 entradas (IABD-20, NAS IABD, NAS SMRV,
  NAS Centro). Todas usan el mismo `live/img1` (kernel único).
- **`.disk/info` es obligatorio**: el `grubx64.efi` firmado de la ISO de Ubuntu
  localiza su volumen buscando ese fichero y luego carga `/boot/grub/grub.cfg`.
  Sin él, GRUB no encuentra el menú.
- Las etiquetas de las entradas de los NAS dicen `/srv/ubuntu-live`, pero el
  `nfsroot=` real es `/mnt/DiscosRapidos/LiveCDs/Ubuntu26.04-IESMHP`. Solo es el texto.

### `crea-iso-arranque-nfs.sh [carpeta] [fichero.iso]`

Valores por defecto: `~/usb-nfs` y `InstalaciónDesdeRed.iso`. Dependencias:
`sudo apt install xorriso mtools dosfstools grub-pc-bin grub-common`. (La
cabecera lo llama `crear-iso.sh`, su nombre anterior.)

1. **Comprueba** los comandos, `/usr/lib/grub/i386-pc/boot_hybrid.img`, los
   ficheros obligatorios (`EFI/boot/bootx64.efi`, `grubx64.efi`, `.disk/info`,
   `boot/grub/grub.cfg`) y que cada `live/*/` tenga `vmlinuz` + `initrd`
   (admite varias imágenes `img1`, `img2`…). **Avisa** si algún `echo` del
   `grub.cfg` lleva tildes/ñ (en BIOS se ven como `?`).
2. Copia la carpeta a un temporal (**no modifica la original**).
3. Crea `efi.img` (FAT, tamaño de `EFI/` + 2 MiB) con `EFI/boot/*` dentro.
4. Crea un GRUB de BIOS `i386-pc-eltorito` mínimo, **solo para mostrar el
   mensaje de error** de `grub.cfg` y apagar.
5. `xorriso -as mkisofs`: ISO **híbrida** (CD/DVD o USB grabado con `dd`, Rufus
   en modo DD o balenaEtcher) con MBR de GRUB, El Torito BIOS y `efi.img`
   añadida como partición GPT 2 (`0xef`) para UEFI. Etiqueta `NFSBOOT`. Filtra
   la salida de xorriso y comprueba que la ISO no esté vacía.

La ISO pesa poco (solo kernel + initrd + cargador): el sistema se lee del NFS.

---

## Requisito "sin monitor" (ver `CLAUDE.md` raíz)

- Los menús de GRUB tienen un timeout finito (5 s en la opción A, 10 s en la B):
  no esperan ninguna tecla. En la opción B la entrada por defecto es la primera
  (**IABD-20**); en otra aula, sin nadie que elija, arrancará contra ese
  servidor. Para un aula concreta conviene poner su NAS como `default`.
- **Cuidado (comprobar)**: en la ISO IESMHP, la instalación arranca con un
  **autostart de la sesión GNOME** del Live (`iac-iesmhp-launch.sh` →
  `iac-iesmhp-run.sh`, ver `Ubuntu/CLAUDE.md`). Es decir, la cadena del Live
  depende de que la sesión gráfica se inicie. Esto viene de `0a-CreaISO.sh`, no
  de esta carpeta, pero afecta igual al arrancar por NFS un equipo sin monitor.
  Si una reinstalación por NFS se queda parada sin pantalla, mirar primero ahí.
