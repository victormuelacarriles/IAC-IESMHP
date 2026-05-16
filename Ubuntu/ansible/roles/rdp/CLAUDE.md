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
   las rutas TLS correctas**, ejecuta:
   - `grdctl --system rdp set-tls-key …`
   - `grdctl --system rdp set-tls-cert …`
   - `grdctl --system rdp set-credentials <usuario> <contraseña>` (`no_log`)
   - `grdctl --system rdp enable`
6. Asegura que `gnome-remote-desktop.service` (instancia **system**) está
   `started` y `enabled`.
7. Un **handler** reinicia `gnome-remote-desktop.service` solo si el
   certificado se acaba de generar o se reconfiguró el RDP.

## Estructura
- `tasks/main.yml`
- `handlers/main.yml` — `Reiniciar gnome-remote-desktop`.
- `defaults/main.yml`:
  - `rdp_username` / `rdp_password` — credenciales RDP (por defecto
    `ubuntu` / `ubuntu`).
  - `rdp_tls_dir` — directorio del certificado (`/etc/gnome-remote-desktop`).
  - `rdp_cert_days` — validez del certificado autofirmado (3650).
  - `rdp_cert_subject` — *subject* del certificado (`/CN=gnome-remote-desktop`).

## Estado / Notas
- **Activo** en `roles.yaml` (sustituye a la línea comentada `#- xrdp`).
- **Idempotente**: el certificado solo se genera si falta; la reconfiguración
  de `grdctl` solo se ejecuta si `status` no muestra el RDP habilitado con las
  rutas TLS correctas; el reinicio del servicio va por handler.
- Es la instancia **system** del servidor (`grdctl --system`), independiente de
  que haya o no sesión gráfica iniciada — adecuado para el primer arranque
  desatendido.
- Cambiar usuario/contraseña: sobrescribir `rdp_username`/`rdp_password` por
  inventario, `-e` o `vars:` en `roles.yaml`.
