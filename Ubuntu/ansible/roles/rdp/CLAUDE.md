# Rol `rdp`

## Contexto
Sustituye al antiguo rol **`xrdp`**. En **Ubuntu Desktop 26.04** ya no tiene
sentido instalar el paquete `xrdp`: GNOME trae un **servidor RDP nativo**
(`gnome-remote-desktop`) que se gestiona con `grdctl --system`. Este rol
configura ese servidor nativo para que el equipo sea accesible por RDP.

## Qué hace
1. Instala el paquete **`gnome-remote-desktop`** (provee el servicio de sistema
   y la herramienta `grdctl`).
2. Crea el directorio de configuración (`rdp_tls_dir`, por defecto
   `/etc/gnome-remote-desktop`).
3. Genera un **certificado TLS autofirmado** (`tls.key` + `tls.crt`) con
   `openssl` **solo si no existe** (`creates:`), válido `rdp_cert_days` días.
4. Asigna propietario `gnome-remote-desktop:gnome-remote-desktop` y permisos
   `0600` a la clave y al certificado (el usuario interno del servicio debe
   poder leerlos).
5. Lee `grdctl --system status` y, **solo si el RDP no está ya habilitado con
   las rutas TLS correctas**, en este orden **determinista**:
   - **Para** `gnome-remote-desktop.service` (clave: evita que un daemon vivo
     pise `grd.conf` — ver bug 2026-05-16 abajo).
   - `grdctl --system rdp set-tls-key …`
   - `grdctl --system rdp set-tls-cert …`
   - `grdctl --system rdp set-credentials <usuario> <contraseña>` (`no_log`)
   - `grdctl --system rdp enable`
6. Asegura que `gnome-remote-desktop.service` (instancia **system**) está
   `started` y `enabled` (arranca leyendo el `grd.conf` recién escrito).
7. **Verifica** con `grdctl --system status` que el RDP quedó realmente
   `enabled` con las rutas TLS correctas; si no, el play **falla** (antes el
   rol terminaba "ok" dejando el RDP apagado en silencio).

## Estructura
- `tasks/main.yml`
- `handlers/main.yml` — **sin handlers** (el de reinicio se eliminó el
  2026-05-16; ver bug abajo).
- `defaults/main.yml`:
  - `rdp_username` / `rdp_password` — credenciales RDP (por defecto
    `ubuntu` / `ubuntu`).
  - `rdp_tls_dir` — directorio del certificado (`/etc/gnome-remote-desktop`).
  - `rdp_cert_days` — validez del certificado autofirmado (3650).
  - `rdp_cert_subject` — *subject* del certificado (`/CN=gnome-remote-desktop`).

## Estado / Notas
- **Activo** en `roles.yaml` (sustituye a la línea comentada `#- xrdp`).
- **Idempotente**: el certificado solo se genera si falta; el bloque de
  configuración (`parar → grdctl set-*/enable → arrancar`) solo se ejecuta si
  `status` no muestra el RDP habilitado con las rutas TLS correctas.
- **Bug 2026-05-16 (corregido)**: con `gnome-remote-desktop 50` y VM sin TPM
  (`Init TPM credentials failed … using GKeyFile as fallback`), el rol dejaba
  el RDP `disabled` tras el primer reboot aunque Ansible terminara `failed=0`.
  Causa: los `grdctl --system` corrían con el daemon **vivo**; escribían
  `grd.conf` en disco pero el daemon mantenía su estado vacío en memoria, y el
  handler que reiniciaba el servicio al final del play hacía que el daemon
  viejo volcara ese estado vacío **sobre** `grd.conf`. Verificado: a mano la
  secuencia idéntica + `systemctl restart` **sí** persiste tras reboot. Fix:
  orden determinista `parar servicio → grdctl set-*/enable → arrancar` +
  verificación final que falla el play si el RDP no quedó `enabled`. Handler de
  reinicio eliminado (reintroducía la carrera). Config persistida en
  `/etc/gnome-remote-desktop/grd.conf` y
  `/var/lib/gnome-remote-desktop/.local/share/gnome-remote-desktop/credentials.ini`.
- Es la instancia **system** del servidor (`grdctl --system`), independiente de
  que haya o no sesión gráfica iniciada — adecuado para el primer arranque
  desatendido.
- Cambiar usuario/contraseña: sobrescribir `rdp_username`/`rdp_password` por
  inventario, `-e` o `vars:` en `roles.yaml`.
