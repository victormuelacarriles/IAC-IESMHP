# Rol `clienteNAS`

## Qué hace
Configura el equipo como **cliente NFS del NAS del departamento** y monta, en
**solo lectura** y de forma **persistente**, todos los recursos que el NAS
exporta. No hay lista fija: el rol **autodescubre** los exports con
`showmount -e`.

### Lógica
1. Instala `nfs-common` (aporta `mount.nfs` y `showmount`).
2. Crea la carpeta base `{{ nas_base_mount }}` (por defecto `/mnt/nasDepInfo`).
3. Ejecuta `showmount -e {{ nas_server_ip }}` (por defecto `10.0.1.100`), con
   reintentos (`nas_showmount_retries`/`nas_showmount_delay`) porque el NAS
   puede tardar en responder en el primer arranque.
4. Extrae la 1ª columna de cada línea (la ruta exportada) y descarta lo que no
   empiece por `/` (así se ignora la cabecera `Export list for ...` sin
   depender de `--no-headers`).

Ejemplo real: `showmount -e 10.0.1.100` → `/mnt/DiscosRapidos/PruebaRapidosX3 *`
⇒ se monta `10.0.1.100:/mnt/DiscosRapidos/PruebaRapidosX3` en
`/mnt/nasDepInfo/PruebaRapidosX3`.
5. Construye el mapa export remoto → punto de montaje local
   `{{ nas_base_mount }}/<nombre>` según `nas_subdir_strategy`.
6. Detecta con `mountpoint -q` qué puntos ya están montados y **crea solo los
   que faltan** (ver *Idempotencia / re-ejecución* abajo).
7. Monta cada export con el módulo `mount` (`state: mounted` → escribe
   `/etc/fstab` **y** monta ahora).

## Estructura
- `tasks/main.yml`
- `defaults/main.yml` — todas las variables (rol **parametrizado**):

| Variable | Por defecto | Para qué |
|---|---|---|
| `nas_server_ip` | `10.0.1.100` | IP del NAS que exporta los recursos |
| `nas_base_mount` | `/mnt/nasDepInfo` | Carpeta base local de los montajes |
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

## Cómo apuntar a otro NAS
Sobreescribir las variables (en `defaults/main.yml`, en el playbook o con
`-e`). Nada en `tasks/main.yml` está cableado: cambiar `nas_server_ip` y/o
`nas_base_mount` basta.

## Estado
- ✅ **activo** en `roles.yaml` (2º rol, tras `basicos`).
- A diferencia de `comparteaula`/`comparteaula32` (NFS de **aula**, lista o
  ruta fija), este rol es **NAS de departamento** y **autodescubre** todos los
  exports. No detecta aula por IP.

## Notas
- Solo lectura por diseño: los equipos no escriben en el NAS.
- Idempotente: `showmount` con `changed_when: false`; `mount` solo marca
  cambio si toca `/etc/fstab` o el estado de montaje.
- Si el NAS no exporta nada, el rol no falla: avisa con `debug` y no monta.
- Si `showmount` no responde tras los reintentos, el rol **falla** (red/NAS
  caídos) — es deliberado para que se vea en el log del primer arranque.
- Útil para depurar: `showmount -e 10.0.1.100`.
