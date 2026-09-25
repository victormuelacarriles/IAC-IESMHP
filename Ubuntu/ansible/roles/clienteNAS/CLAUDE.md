# Rol `clienteNAS`

## Qué hace
Configura el equipo como **cliente NFS del NAS del departamento** y monta, en
**solo lectura** y de forma **persistente**, todos los recursos que el NAS
exporta. No hay lista fija: el rol **autodescubre** los exports con
`showmount -e`.

### Lógica
1. Instala `nfs-common` (aporta `mount.nfs` y `showmount`).
2. Crea la carpeta base `{{ nas_base_mount }}` (por defecto `/mnt/nasDepInfo`).
3. **Elige la interfaz del NAS** según la red del equipo (3 primeros octetos
   de `ansible_default_ipv4.address`): si la red está en `nas_ips_por_red` usa
   su interfaz dedicada (`10.0.72.x` → `10.0.72.253`, `10.0.32.x` →
   `10.0.32.253`); si no, la general `nas_ip_general` (`10.0.1.253`). Ejecuta
   `showmount -e <IP elegida>` con
   reintentos (`nas_showmount_retries`/`nas_showmount_delay`) porque el NAS
   puede tardar en responder en el primer arranque.
4. Extrae la 1ª columna de cada línea (la ruta exportada) y descarta lo que no
   empiece por `/` (así se ignora la cabecera `Export list for ...` sin
   depender de `--no-headers`).
   **Plan B**: si la interfaz dedicada no responde tras los reintentos, se
   repite con la general (el fallo previo sale en el log como `...ignoring`).

Ejemplo real: `showmount -e 10.0.72.253` → `/mnt/DiscosRapidos/PruebaRapidosX3 *`
⇒ se monta `10.0.72.253:/mnt/DiscosRapidos/PruebaRapidosX3` en
`/mnt/nasDepInfo/PruebaRapidosX3`.
4b. **Exclusiones**: descarta los exports cuya ruta contenga alguna palabra de
   `nas_excluir` (sin distinguir mayúsculas; por defecto `LiveCDs` y
   `OtroAexcluir`). Si un excluido ya estaba montado de una ejecución
   anterior, lo **desmonta** y **quita su línea de `/etc/fstab`**.
5. Construye el mapa export remoto → punto de montaje local
   `{{ nas_base_mount }}/<nombre>` según `nas_subdir_strategy`.
6. Detecta con `mountpoint -q` qué puntos ya están montados y **crea solo los
   que faltan** (ver *Idempotencia / re-ejecución* abajo).
7. Escribe la entrada de cada export en `/etc/fstab` con `lineinfile` y luego
   monta con `command: mount <punto>` **solo** los puntos que aún no estaban
   montados (reutiliza `nas_mp_check`). Se hace a mano —en vez del módulo
   `ansible.posix.mount`— porque ese módulo emite varios
   `[DEPRECATION WARNING]` en su código interno; gestionarlo manualmente
   acota el silenciado a este rol sin desactivar `deprecation_warnings`
   globalmente (ver `Ubuntu/RegistroDeCambios/20260608-Cambios.md`).

## Estructura
- `tasks/main.yml`
- `defaults/main.yml` — todas las variables (rol **parametrizado**):

| Variable | Por defecto | Para qué |
|---|---|---|
| `nas_ip_general` | `10.0.1.253` | Interfaz general del NAS (todo el centro); se usa si la red no tiene interfaz dedicada y como plan B |
| `nas_ips_por_red` | `10.0.72`→`10.0.72.253`, `10.0.32`→`10.0.32.253` | Interfaces dedicadas por red (clave = 3 primeros octetos) |
| `nas_server_ip` | `""` | Si no está vacío, **fuerza** esa IP (sin detección ni plan B) |
| `nas_base_mount` | `/mnt/nasDepInfo` | Carpeta base local de los montajes |
| `nas_excluir` | `[LiveCDs, OtroAexcluir]` | Palabras: no se monta ningún export cuya ruta contenga alguna (vacía = montar todo) |
| `nas_fstype` | `nfs` | Tipo de FS |
| `nas_mount_options` | `ro,defaults,_netdev` | Solo lectura; `_netdev` espera a la red |
| `nas_subdir_strategy` | `basename` | `basename` o `fullpath` (ver abajo) |
| `nas_showmount_retries` | `5` | Reintentos de `showmount` |
| `nas_showmount_delay` | `5` | Segundos entre reintentos |

### `nas_subdir_strategy`
- `basename` → `/mnt/nasDepInfo/<último segmento>` (p. ej. export
  `/volume1/DepInfo` → `/mnt/nasDepInfo/DepInfo`). Rutas cortas.
- `fullpath` → `/mnt/nasDepInfo/<ruta completa sin / inicial>` (p. ej.
  `/volume1/DepInfo` → `/mnt/nasDepInfo/volume1/DepInfo`). **Úsalo si dos
  exports comparten el mismo basename** (colisión de carpeta local).

## Cómo apuntar a otro NAS / añadir una red
- **Nueva red con interfaz propia en el NAS**: añadir una línea a
  `nas_ips_por_red` en `defaults/main.yml` (`"10.0.NN": "10.0.NN.253"`).
- **Forzar una IP** (pruebas): `-e nas_server_ip=10.0.1.253`.
- Nada en `tasks/main.yml` está cableado; `nas_base_mount` también se cambia en
  `defaults/main.yml`.

## Estado
- ✅ **activo** en `roles.yaml` (tras `vscode`).
- A diferencia de `comparteaula`/`comparteaula32` (NFS de **aula**, lista o
  ruta fija), este rol es **NAS de departamento** y **autodescubre** todos los
  exports. Usa la IP del equipo **solo** para elegir la interfaz del NAS.

## Notas
- Solo lectura por diseño: los equipos no escriben en el NAS.
- Idempotente: `showmount` con `changed_when: false`; `lineinfile` solo marca
  cambio si modifica `/etc/fstab`; el `mount` final solo corre sobre puntos no
  montados (`when: item.rc != 0`).
- Si el NAS no exporta nada, el rol no falla: avisa con `debug` y no monta.
- Si `showmount` no responde tras los reintentos (y el plan B con la general
  también falla), el rol **falla** (red/NAS caídos) — es deliberado para que se vea en el log del primer arranque.
- Útil para depurar: `showmount -e 10.0.1.253` (general) o `showmount -e 10.0.72.253` (dedicada).
- Si un equipo cambia de red, en la re-ejecución la línea de `/etc/fstab` se
  reescribe con la nueva IP (se busca por punto de montaje), pero el montaje
  activo no se rehace hasta reiniciar o hacer `umount`/`mount`.

### Idempotencia / re-ejecución

La creación de los puntos de montaje va en **dos tareas**:

1. *Detectar qué puntos ya están montados* (`mountpoint -q`, con
   `changed_when: false` y `failed_when: false`).
2. *Crear los puntos que aún no están montados* (`when: item.rc != 0`,
   iterando sobre `nas_mp_check.results`).

**Por qué**: el export se monta `ro`. En una re-ejecución, el punto destino
ya tiene el NFS montado encima en solo lectura; si se usara una única tarea
`file: state=directory` con `owner/group/mode`, el módulo intentaría aplicar
`chmod`/`chown` sobre el montaje RO y fallaría con
`[Errno 30] Read-only file system`. Un punto ya montado existe por
definición, así que se omite. Corregido el **2026-06-05** (ver
`Ubuntu/RegistroDeCambios/20260605-Cambios.md`).
