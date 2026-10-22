# Rol `DesinstalaLibreOffice`

> **Desactivado por defecto**: en `roles.yaml` está como línea **comentada**. Se
> lanza a mano (opciones A/B) cuando se quiera que los usuarios usen LibreOffice
> **Flatpak** (ver `Ubuntu/flatpack/Instalación de aplicaciones Flatpak en Ubuntu 26.04.md`).

## Qué hace
Quita el **LibreOffice nativo** de Ubuntu para que cada usuario instale el suyo
como Flatpak (`flatpak install --user flathub org.libreoffice.LibreOffice`) sin
iconos duplicados:

1. Lista los paquetes `.deb` presentes que casan con `desinstalalibreoffice_patrones`
   (`libreoffice*`, `python3-uno`), instalados o con configuración residual (`rc`).
2. Comprueba si hay un **snap** `libreoffice` (Ubuntu no lo trae, pero por si acaso).
3. Muestra el estado: nº de paquetes, snap sí/no y acción (`desinstalar`/`ninguna`).
4. **Purga** los `.deb` (`apt purge`) y, con `autoremove`, sus dependencias huérfanas
   (`ure`, `libuno-*`, `uno-libs-private`...).
5. Quita el snap si existía (`snap remove --purge`).
6. Deja el pin `/etc/apt/preferences.d/iac-sin-libreoffice` (`Pin-Priority: -1`)
   para que ningún `full-upgrade` ni metapaquete lo vuelva a meter.

No toca los Flatpak ni los perfiles de usuario (`~/.config/libreoffice` se queda:
el Flatpak usa el suyo en `~/.var/app/org.libreoffice.LibreOffice/`).

Probado en el equipo de desarrollo (simulación `apt-get -s purge 'libreoffice*'`):
solo arrastra `python3-uno`; **no** quita `ubuntu-desktop` (LibreOffice es
`Recommends`, no `Depends`).

## Cómo ejecutarlo

### Opción A — solo el rol, desde su carpeta (sin `roles.yaml`)
El rol trae su propio playbook, `DesinstalaLibreOffice.yaml` (hace `apt update` y
aplica esta carpeta como rol con `role: "{{ playbook_dir }}"`). Desde
`Ubuntu/ansible/roles/DesinstalaLibreOffice` (en un equipo:
`/opt/IAC-IESMHP/Ubuntu/ansible/roles/DesinstalaLibreOffice`):

```bash
# En el propio equipo (local)
sudo ansible-playbook -i localhost, --connection=local DesinstalaLibreOffice.yaml

# En un aula entera por SSH (los inventarios están dos carpetas más arriba)
ansible-playbook -i ../../equiposIABD.ini DesinstalaLibreOffice.yaml \
  --ssh-extra-args="-o StrictHostKeyChecking=no"

# Solo un equipo
ansible-playbook -i ../../equiposIABD.ini DesinstalaLibreOffice.yaml -l IABD-17

# Ver qué haría sin tocar nada
sudo ansible-playbook -i localhost, --connection=local DesinstalaLibreOffice.yaml --check

# Quitar el bloqueo (permitir volver a instalar el .deb)
sudo ansible-playbook -i localhost, --connection=local DesinstalaLibreOffice.yaml \
  -e desinstalalibreoffice_bloquear=false
```

### Opción B — a través de `roles.yaml` con `--tags`
Primero hay que **descomentar** su línea en `roles.yaml`
(`#- { role: DesinstalaLibreOffice, tags: DesinstalaLibreOffice }`); comentada,
`--tags` no la encuentra. Después, desde `Ubuntu/ansible`:

```bash
sudo ansible-playbook -i localhost, --connection=local roles.yaml --tags DesinstalaLibreOffice
ansible-playbook -i ./equiposIABD.ini roles.yaml --tags DesinstalaLibreOffice -l IABD-17
```

Si se quiere que lo hagan **todos** los equipos nuevos, basta con dejar esa línea
descomentada: el primer arranque lo aplicará con el resto de roles.

## Variables (`defaults/main.yml`)
| Variable | Defecto | Uso |
|----------|---------|-----|
| `desinstalalibreoffice_patrones` | `['libreoffice*', 'python3-uno']` | Patrones `dpkg-query` de lo que se purga |
| `desinstalalibreoffice_autoremove` | `true` | `apt autoremove` tras purgar |
| `desinstalalibreoffice_snap` | `true` | Quitar también el snap `libreoffice` |
| `desinstalalibreoffice_bloquear` | `true` | Pin -1 en APT; `false` borra el pin |
| `desinstalalibreoffice_pin` | `/etc/apt/preferences.d/iac-sin-libreoffice` | Ruta del pin |

## Estructura
- `tasks/main.yml`
- `defaults/main.yml`
- `DesinstalaLibreOffice.yaml` — playbook independiente para lanzar solo este rol desde su carpeta.

## Notas
- **Idempotente**: si no queda nada, la acción es `ninguna` y solo se reasegura el pin.
- Las consultas (`dpkg-query`, `snap list`) llevan `check_mode: false`, así que
  `--check` muestra la lista real de lo que se purgaría.
- **Sin interacción** (requisito headless): `apt` y `snap` no preguntan nada.
- `autoremove` quita **todo** lo huérfano del equipo, no solo lo de LibreOffice. En
  un equipo recién desplegado no es problema; si molesta: `-e desinstalalibreoffice_autoremove=false`.
- Con el pin puesto, `apt install libreoffice` falla con «no tiene candidato para
  instalar»: es lo esperado. Para reinstalarlo, `-e desinstalalibreoffice_bloquear=false`.
- Para que el usuario no vea iconos duplicados **sin** desinstalar (sin `sudo`), ver
  el apartado B5 del documento de Flatpak.
