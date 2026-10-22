# OneDriveAW11 — OneDrive de una VM Windows 11 en Ubuntu por SSH

Utilidad **personal y manual** (fuera de la cadena automática de despliegue).
Acceder desde Ubuntu a la carpeta de OneDrive de una VM Windows 11 (VMware) a
través del **OpenSSH de Windows** (SFTP), autenticando con la clave SSH del
usuario. No usa la carpeta compartida SMB de W11 ni contraseñas.

Caso de uso actual: VM W11 de Víctor en `10.0.72.170` (antes `.160`), carpeta
`E:\Usuarios\vmuela\OneDrive - Educantabria`.

Hay **dos métodos**. Ahora mismo se está **evaluando el método B (marcador)**
y el método A (script) está **desactivado** (ver "Estado").

---

## Estado (2026-10-21)

- **Método A desactivado** con `MapeaOneDriveSSH.sh --desconfigura`: sin
  línea en el crontab y `~/OneDrive` desmontado. Se conserva la configuración
  en `~/.config/IAC-IESMHP/MapeaOneDriveSSH.env`.
- **Método B en evaluación**: Víctor usa el marcador de Archivos para ver si
  funciona peor que el script (bloqueos al apagar la VM, rendimiento,
  aplicaciones que no abren bien los ficheros, acceso desde terminal/VS Code).
- Según el resultado: o se queda el marcador y se puede retirar el script, o
  se reactiva el script (ejecutarlo sin parámetros) y se quita el marcador.
  Anotar la conclusión aquí y en `Ubuntu/RegistroDeCambios/`.

---

## Requisitos comunes

- OpenSSH Server activo en Windows y la **clave pública** del usuario de
  Ubuntu autorizada allí.
- Huella del equipo en `~/.ssh/known_hosts`: conectarse una vez a mano con
  `ssh usuario@IP`.
  - Para el método A (rclone 1.60) hacen falta **todas** las claves del
    servidor (ed25519, ecdsa, rsa); si no, falla con `knownhosts: key
    mismatch` aunque `ssh` funcione. Tras comprobar la huella:
    `ssh-keyscan IP >> ~/.ssh/known_hosts`.

---

## Método B — Marcador de Archivos (GVFS) · en evaluación

Sin scripts ni cron: lo gestiona GNOME (GVFS, backend `sftp` con el `ssh` del
sistema).

**Crear el marcador**
1. En Archivos (Nautilus), `Ctrl+L` y escribir:
   `sftp://vmuela@10.0.72.170/E:/Usuarios/vmuela/OneDrive%20-%20Educantabria`
2. Con la carpeta abierta, `Ctrl+D` (o menú ⋮ → *Añadir a marcadores*).
   Se puede renombrar como "OneDrive - Educantabria".

Por línea de comandos, equivale a añadir esta línea a
`~/.config/gtk-3.0/bookmarks`:
```
sftp://vmuela@10.0.72.170/E:/Usuarios/vmuela/OneDrive%20-%20Educantabria OneDrive - Educantabria
```

**Uso**
- Clic en el marcador → conecta. Aparece también en la barra lateral como
  "vmuela en 10.0.72.170" con botón de expulsar.
- Conectar/desconectar desde terminal:
  `gio mount sftp://vmuela@10.0.72.170/` · `gio mount -u sftp://vmuela@10.0.72.170/`
- Mientras está conectado, otros programas (terminal, VS Code) lo ven en:
  `/run/user/$(id -u)/gvfs/sftp:host=10.0.72.170,user=vmuela/E:/Usuarios/vmuela/OneDrive - Educantabria`

**Ventajas**: lo más limpio; nada que mantener; usa `ssh` directamente
(sin problemas de `known_hosts`).

**Limitaciones (a vigilar en la evaluación)**
- Solo se conecta al hacer clic, con sesión gráfica abierta. No está
  disponible por SSH ni desde cron.
- No hay ruta fija tipo `~/OneDrive`; la de `/run/user/...` solo existe
  mientras está conectado.
- Si se apaga la VM, la conexión puede quedarse colgada un rato: expulsarla
  a mano.
- Algunas aplicaciones abren peor los ficheros por GVFS que por un montaje
  FUSE con caché.

---

## Método A — Script `MapeaOneDriveSSH.sh` (rclone + cron) · desactivado

Monta la carpeta en una ruta fija (`~/OneDrive` por defecto) con
`rclone mount` (backend sftp, FUSE de usuario, sin sudo) y se vigila desde
cron cada minuto. Detalle completo en la cabecera del script y en
`Ubuntu/RegistroDeCambios/20261020-Cambios.md` y `20261021-Cambios.md`.

- **Configuración**: `~/.config/IAC-IESMHP/MapeaOneDriveSSH.env` (perfil del
  usuario, nunca junto al script). Se crea con parámetros (`--equipo`,
  `--puerto`, `--usuario`, `--clave`, `--remota`, `--montaje`) o preguntando.
  A mano y sin parámetros enseña la configuración y pregunta si vale.
- **Parámetros de modo**: `--configurar` (volver a preguntar),
  `--desatendido` (nunca pregunta; el de cron), `--desconfigura` (quita la
  línea del crontab y desmonta, conserva el `.env`), `--ayuda`.
- **Cron**: se autoregistra como
  `* * * * * <ruta real>/MapeaOneDriveSSH.sh --desatendido`.
- **Windows apagado**: en la siguiente pasada mata el `rclone` y desmonta,
  para que Archivos no se bloquee. Al volver, monta solo.
- **Log**: `~/.cache/MapeaOneDriveSSH.log`.

**Reactivarlo**: ejecutar el script sin parámetros (o con `--desatendido`):
vuelve al crontab y monta con la configuración guardada.

**Ventajas**: ruta fija para terminal/VS Code/scripts, montaje y desmontaje
automáticos, funciona sin sesión gráfica, caché de escritura de rclone.
**Inconvenientes**: más piezas (rclone, cron, `.env`); rclone 1.60 es más
estricto con `known_hosts`.
