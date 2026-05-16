# Rol `virtualbox`

## Qué hace
Instala **Oracle VirtualBox** desde el repositorio oficial de Oracle, intentando fijar una versión concreta:

1. Asegura `wget` y `gnupg`.
2. Descarga la clave GPG de Oracle (`oracle-virtualbox-2016.gpg`) si no existe.
3. Añade el repositorio apt de VirtualBox (`virtualbox_apt_repo`).
4. Refresca la caché apt.
5. Comprueba versión instalada y versión candidata del repositorio.
6. Avisa si hay una versión más reciente que la solicitada.
7. Instala `virtualbox-{{ virtualbox_series }}={{ virtualbox_version }}*`.

## Estructura
- `tasks/main.yml`
- `defaults/main.yml`:
  - `virtualbox_series: "7.1"`
  - `virtualbox_version: "7.1.12"`
  - `virtualbox_apt_repo`: repo `download.virtualbox.org/.../debian noble contrib` (revisar que la suite — `noble` — corresponde a la versión de SO usada).

## Issues conocidos (importantes)
- **No instala la versión exacta solicitada**: tras introducir el servidor de caché apt del aula, apt sirve la **última** versión disponible en vez de la fijada. Por eso el rol está **comentado** en `roles.yaml` (TODO sin resolver).
- Varias tareas marcan `changed` en cada ejecución aunque no cambien nada (gestión del repo/clave GPG) — pendiente de corregir.
- El bloque de "desinstalar versión previa" está comentado porque siempre desinstalaba la versión ya instalada.
- Rol contrario: [`virtualboxFUERA`](../virtualboxFUERA/CLAUDE.md) desinstala VirtualBox y limpia su repositorio/claves.
