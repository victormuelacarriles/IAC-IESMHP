# Rol `vmware`

## ⛔ Requisito: VMware queda instalado y NUNCA pide compilar

Al abrir VMware **no puede aparecer** el diálogo «VMware Kernel Module Updater»
(*"Before you can run VMware, several modules must be compiled…"*) ni la petición
de contraseña para `vmware-modconfig --console --install-all`. El alumno no es
administrador, y los equipos se despliegan sin nadie delante. Cualquier cambio
en este rol, en `roles.yaml` o en `3-SetupPrimerInicio.sh` debe mantenerlo.

**Por qué pasaba** (2026-10-06): en el primer arranque, `3-SetupPrimerInicio.sh`
hace `apt-get full-upgrade`, que instala un **kernel nuevo**, y Ansible corre
**sin reiniciar**. Antes, el rol compilaba vmmon/vmnet solo para `ansible_kernel`
(el kernel en uso, el viejo). Al reiniciar se arrancaba con el kernel nuevo sin
módulos y VMware pedía compilarlos. VMware **no usa DKMS**, así que cualquier
actualización de kernel posterior provocaba lo mismo.

## Qué hace
1. Comprueba si `vmware --version` responde y extrae la versión instalada.
2. Si no está instalado o la versión no coincide con `vmware_version`:
   copia el `.bundle` desde `vmware_bundle_path` (NFS) a `/tmp` y lo ejecuta
   (`--eulas-agreed --required --console`) + `vmware-setup-helper`.
3. **Siempre**, de forma idempotente (re-lanzar el rol arregla equipos ya
   instalados: `ansible-playbook -i localhost, --connection=local roles.yaml --tags vmware`):
   - Instala `build-essential`, `linux-headers-generic` y las **cabeceras de
     todos los kernels** de `/lib/modules`. También `libaio1t64` con el enlace
     `libaio.so.1`, y `xvfb`/`xauth` solo para el respaldo de modconfig.
   - Instala `/usr/local/sbin/iac-vmware-modulos.sh` (`files/`). Compila vmmon/vmnet
     desde `/usr/lib/vmware/modules/source/{vmmon,vmnet}.tar` con
     `make VM_UNAME=<kernel>` **para cada kernel** y los instala en
     `/lib/modules/<k>/misc/` con `depmod`. No necesita interfaz gráfica. Si
     faltan las fuentes, recurre a `xvfb-run vmware-modconfig --install-all`,
     que solo sirve para el kernel en uso.
   - **Kernels futuros**: hook `zz-iac-vmware` en `/etc/kernel/postinst.d/` y
     `/etc/kernel/header_postinst.d/`. Se dispara al instalarse la imagen o las
     cabeceras de un kernel nuevo; si aún no hay cabeceras, lo reintenta el de headers.
   - **Red de seguridad**: `iac-vmware-modulos.service` (oneshot,
     `WantedBy=multi-user.target`, `Before=vmware.service display-manager.service`,
     **sin** dependencias gráficas). En cada arranque compila si faltan los
     módulos para `uname -r`; si ya están, termina enseguida.
   - Compila para todos los kernels y, al final, comprueba que vmmon/vmnet
     cargan y que existen **para cada kernel instalado**.
4. En `roles.yaml` va el **último**, para que nada instalado después le deje
   un kernel sin módulos. Gracias a los hooks no es imprescindible, pero así es
   más fácil de entender.

## Estructura
- `tasks/main.yml`
- `files/iac-vmware-modulos.sh` — compilador sin GUI (`--arranque` = solo `uname -r`;
  sin argumentos = todos; o versiones concretas). Log:
  `/var/log/IAC-IESMHP/Ubuntu/vmware-modulos.log`.
- `files/zz-iac-vmware` — hook de kernel (nunca falla, para no romper apt).
- `files/iac-vmware-modulos.service`
- `defaults/main.yml`: `vmware_version: "26.0.1"`, `vmware_bundle_path` (NFS del
  NAS del departamento, montado por el rol `clienteNAS`).

## Diagnóstico
```bash
uname -r; ls /lib/modules
for k in $(ls /lib/modules); do echo -n "$k: "; modinfo -k $k -F filename vmmon 2>/dev/null || echo FALTA; done
lsmod | grep -E '^vm(mon|net)'
cat /var/log/IAC-IESMHP/Ubuntu/vmware-modulos.log
systemctl status iac-vmware-modulos.service
sudo /usr/local/sbin/iac-vmware-modulos.sh      # recompilar para todos los kernels
mokutil --sb-state    # con Secure Boot activo, los módulos sin firmar NO cargan
```

## Issues conocidos
- **Secure Boot**: los módulos compilados no están firmados; con Secure Boot
  activo no cargan. No se gestiona (equipos del aula con Secure Boot desactivado).
- Un kernel muy nuevo puede no compilar con las fuentes de esta versión de
  VMware. Aparece como `[ERR] … falló la compilación` en el log; la solución es
  actualizar `vmware_version` y el bundle.
- `remote_src: true` → el `.bundle` debe existir **ya en el equipo** (vía NFS).
- TODO: redes virtuales por usuario.
