# Rol `AODappsflatpack` (por usuario)

Instala (o actualiza) como **Flatpak del alumno** (`--user`, en
`~/.local/share/flatpak`) la **última versión de Flathub** de:

| Nombre (`--apps`) | ID de Flathub | Lanzadores del sistema que oculta |
|---|---|---|
| `libreoffice` | `org.libreoffice.LibreOffice` | `libreoffice*.desktop` (+ asocia los documentos al Flatpak) |
| `obs` | `com.obsproject.Studio` | `com.obsproject.Studio.desktop`, `obs.desktop`, `obs-studio*.desktop` |
| `shotcut` | `org.shotcut.Shotcut` | `org.shotcut.Shotcut.desktop`, `shotcut*.desktop` |
| `openshot` | `org.openshot.OpenShot` | `org.openshot.OpenShot.desktop`, `openshot*.desktop` |

y **le quita del menú** las versiones instaladas por el sistema (`.deb` en
`/usr/share/applications`, snap en `/var/lib/snapd/desktop/applications`),
**solo en su perfil**: el sistema no se toca (para quitarlas del todo están
los roles de sistema [`DesinstalaLibreOffice`](../../../roles/DesinstalaLibreOffice/CLAUDE.md)
y, para OBS, no aplicar [`obs`](../../../roles/obs/CLAUDE.md)).

Mismo esquema que [`VirtualW11`](../VirtualW11/CLAUDE.md): playbook propio en
la carpeta del rol, lanzador `.sh` con parámetros, Ansible entra **como el
alumno**, un log por alumno y tabla de tiempos. Nace de las pruebas de
`Ubuntu/flatpack/` (`preparaFlatpackEnUsuario.sh`, `instalaLibreOffice.sh` y
el `.md` de instrucciones), generalizadas a varias aplicaciones.

Creado el 2026-10-26.

## Uso — `AODappsflatpack.sh`

```bash
cd /opt/IAC-IESMHP/Ubuntu/ansible/rolesUsuario/roles/AODappsflatpack
bash AODappsflatpack.sh SMRD AOD                     # alumnos del módulo AOD (lo normal)
bash AODappsflatpack.sh SMRD                         # todos los de SMRD
bash AODappsflatpack.sh SMRD AOD -l SMRD-04-SMRV24   # de AOD, solo ese
bash AODappsflatpack.sh SMRD AOD --apps libreoffice,obs
bash AODappsflatpack.sh SMRD AOD --forks 5           # 5 alumnos a la vez
bash AODappsflatpack.sh SMRD AOD --deshacer          # las quita y devuelve los lanzadores
bash AODappsflatpack.sh                              # en local, el usuario actual
bash AODappsflatpack.sh --ayuda
```

| Opción | Qué hace |
|---|---|
| `SMRD` / `IABD` / `<alumnos.ini>` | Inventario de alumnos (`rolesUsuario/*-alumnos2627.ini`). Sin él, en local |
| `AOD` (suelto) / `--modulo M` | Solo los del grupo del inventario (`[AOD]`, `[SOR]`…); varios con comas. Con `-l`, la intersección |
| `-l PATRÓN` | Alumnos (nombres del inventario) |
| `--apps L` | Solo esas (`libreoffice,obs,shotcut,openshot`). Por defecto, todas |
| `--forks N` | Alumnos a la vez, por tandas de N (**1 por defecto: de uno en uno**, o `FORKS=N`) |
| `--sin-actualizar` | Las que ya tiene no se actualizan |
| `--sin-ocultar` | No oculta lanzadores ni toca favoritos/documentos |
| `--proxy URL` | Proxy para flatpak (por defecto directo: el HTTPS del aula no va por proxy) |
| `--deshacer` | Desinstala esos Flatpak y vuelve a mostrar los lanzadores del sistema. **Los datos de `~/.var/app/<ID>` se quedan** |
| resto (`-v`, `-e …`) | A `ansible-playbook` |

Sin preguntas (headless). Requisito: la clave del que lanza en cada alumno
(`ssh-copy-id SMRV05@iesmhp.local@10.0.32.160`), como en VirtualW11.

### Logs y tiempos
- `/var/log/IAC-IESMHP/AODappsflatpack.log` (o `~/.local/state/IAC-IESMHP/`
  si no se puede escribir allí): salida completa de cada ejecución.
- `…/AODappsflatpack/AODappsflatpack-<alumno>.log`: **un log por alumno**
  (la salida de Ansible repartida por equipo, con el nombre de cada tarea). Se
  van añadiendo, con una cabecera `=====` por ejecución.
- En el equipo del alumno, `lanzadores.sh` deja su parte en
  `~/.local/state/IAC-IESMHP/AODappsflatpack.log`.
- Al final, **tabla de TIEMPOS**: por alumno (total y `OK`/`ERROR`/`SIN
  RESPUESTA`), debajo una línea por aplicación (tiempo, estado, versión) y un
  resumen por aplicación (cuántos de cada estado, tiempo medio y máximo,
  versiones). Sale de las líneas `TIEMPO|alumno|…` (playbook) y
  `TIEMPOAPP|<equipo>|<app>|<seg>|<estado>|<versión>` (`tasks/app.yml`).

Estados por aplicación: `NUEVA`, `ACTUALIZADA`, `AL DIA`, `SISTEMA` (ya estaba
como Flatpak de sistema y se usa esa), `SIN ACTUALIZAR` (`--sin-actualizar`),
`ERROR`; con `--deshacer`: `QUITADA`, `NO_ESTABA`, `ERROR`.

## Estructura

| Fichero | Qué es |
|---|---|
| `AODappsflatpack.sh` | Lanzador: parámetros, módulos, logs por alumno, tabla de tiempos |
| `AODappsflatpack.yaml` | Playbook: `strategy: free` + `serial` (= `--forks`), ping y salto de los apagados, `rescue` por alumno, línea `TIEMPO` |
| `defaults/main.yml` | Lista de aplicaciones (`AODappsflatpack_apps`) y opciones |
| `tasks/main.yml` | Comprobaciones (flatpak, no root, espacio), remoto Flathub del usuario, bucle de apps, lanzadores, limpieza |
| `tasks/app.yml` | Una aplicación: instalar/actualizar con `flatpak install --user --or-update` (async); si falla, recrea el remoto y reintenta una vez; estado por commit antes/después |
| `tasks/deshacer.yml` | `--deshacer` |
| `files/lanzadores.sh` | Se copia y ejecuta en el equipo del alumno: oculta/restaura lanzadores, documentos y favoritos |

## Qué hace, paso a paso (por alumno)

1. Comprueba que hay `flatpak` (si no: aplicar antes el rol de sistema
   [`flatpak`](../../../roles/flatpak/CLAUDE.md)), que **no** es root y que
   quedan ≥ `AODappsflatpack_margen_gb` (5 GB) libres en el HOME.
2. Añade el remoto `flathub` **del usuario** si falta.
3. Por cada aplicación (si una falla se anota y se sigue con las demás):
   `flatpak install --user --or-update -y --noninteractive flathub <ID>`.
   Si ya está como Flatpak **de sistema** y no del usuario, se usa esa
   (`AODappsflatpack_usar_sistema`). Si falla (p. ej. *GPG verification
   enabled, but no summary found*), recrea el remoto y reintenta una vez.
4. `lanzadores.sh --ocultar`, **solo con las que se han instalado bien**:
   - Copia los lanzadores del sistema a `~/.local/share/applications` con
     `NoDisplay=true` justo debajo de `[Desktop Entry]` y la marca
     `X-IAC-IESMHP-Oculta=true` (para reconocerlas y deshacer).
   - **Si el lanzador del sistema se llama igual que el del Flatpak**
     (`org.shotcut.Shotcut.desktop`, `com.obsproject.Studio.desktop`) **no** se
     copia: el del Flatpak ya lo tapa (sus exports van antes que `/usr/share`
     en `XDG_DATA_DIRS`) y ocultarlo ocultaría también el Flatpak.
   - Una copia que existe **sin** la marca es una personalización del alumno:
     no se toca.
   - LibreOffice (`documentos: true`), **solo si hay LibreOffice del sistema**:
     asocia los `MimeType` de los lanzadores del Flatpak con `xdg-mime`
     (`~/.config/mimeapps.list`). Shotcut/OpenShot no: los vídeos se abrirían en
     el editor.
   - Favoritos del dock: cambia los ocultos por su equivalente Flatpak
     (`libreoffice-writer.desktop` → `org.libreoffice.LibreOffice.writer.desktop`).
     Necesita el bus de sesión del alumno (`/run/user/<uid>/bus`, lo crea
     `pam_systemd` al entrar por SSH); si no lo hay, avisa y sigue. La lista
     original se guarda una vez en
     `~/.local/state/IAC-IESMHP/AODappsflatpack-favoritos.orig`.
   - Borra copias marcadas cuyo original ya no existe.
5. `flatpak uninstall --user --unused`: borra runtimes viejos que ya no usa
   ninguna aplicación del alumno (`AODappsflatpack_limpiar`).

Idempotente: relanzarlo solo actualiza lo que tenga versión nueva; sin cambios
sale `AL DIA` y no marca `changed`.

## Notas y avisos

- **Parece colgado, pero está descargando** (prueba real con SMRD-04-SMRV24,
  2026-10-26): `flatpak install` va en `async`. Ansible no saca nada en
  pantalla hasta que la tarea termina (las líneas `ASYNC POLL` salen todas
  juntas al final), y la primera vez LibreOffice tardó **5:37**. Por eso:
  - antes de cada instalación sale la tarea `<app>: aviso`;
  - `AODappsflatpack.sh` saca un **latido** si la salida lleva 30 s quieta
    (`… 1:30 sin novedades (obs: descargando/instalando de Flathub)`). Va solo
    a la pantalla, no al log.
- **Ctrl+C no para la instalación en el alumno**: el `flatpak install` en
  `async` sigue en su equipo hasta acabar. En la prueba, OBS se terminó de
  instalar después de cortar, y la siguiente ejecución lo dio como `AL DIA`.
  Relanzar es seguro: lo que ya está sale `AL DIA` en unos 11 s.

- **Cada alumno descarga lo suyo**: es `--user`, así que nada se comparte
  entre usuarios del mismo equipo. La primera vez son **~2-3 GB por alumno**
  (las cuatro apps + runtimes freedesktop/KDE). Con 17 alumnos de AOD, ~40 GB
  desde Flathub: por eso por defecto va **de uno en uno** (`--forks 1`, desde
  2026-10-26; antes 10). Con `--forks N` van N alumnos a la vez. Las actualizaciones
  posteriores son deltas pequeños.
- Los ajustes del Flatpak viven en `~/.var/app/<ID>`, no en `~/.config`: el
  perfil de la versión del sistema no se migra solo.
- Las copias ocultas son una foto de los lanzadores del sistema: si un
  `apt upgrade` añade un lanzador nuevo de LibreOffice, saldrá hasta la
  siguiente ejecución del rol.
- Para el alumno, los cambios del menú aparecen al momento en GNOME (vigila
  `~/.local/share/applications`); si no, cerrar sesión y volver a entrar.
- `lanzadores.sh` solo toca los favoritos si `$HOME` es el HOME real del
  usuario: `gsettings` lee del `$HOME` pero escribe por el bus en el real, y
  con un HOME de pruebas machacaría los favoritos de verdad (pasó en la prueba
  del 2026-10-26).
- Para pruebas, `AODAPPS_DIRS_NATIVO="dir1 dir2"` cambia dónde busca
  `lanzadores.sh` los lanzadores del sistema.

## Pruebas (2026-10-26, en el equipo del propietario, local)
- `lanzadores.sh` con HOME falso y lanzadores simulados: oculta los `.deb`,
  respeta los de mismo nombre que el Flatpak, no toca `obsidian.desktop`,
  segunda pasada sin cambios, limpia huérfanas, `--deshacer` lo devuelve todo.
- `AODappsflatpack.sh` en local: `--sin-actualizar` (4 × `SIN ACTUALIZAR`),
  `--apps shotcut` (`AL DIA`, 11 s), instalación desde cero + `--deshacer` en
  HOME falso.
- Parámetros con un `ansible-playbook` falso contra
  `EquiposSMRD-alumnos2627.ini` (`SMRD AOD` → 17 alumnos, `AOD,SOR` → 27,
  errores de módulo, app y `-l` inexistentes).
- **Pendiente**: probarlo contra alumnos reales (`SMRD AOD -l <uno>`) y
  comprobar en su sesión gráfica el menú, el dock y el doble clic en un `.odt`.
