# Instalación de aplicaciones Flatpak en Ubuntu 26.04

Oct 21, 2026 · @Victor

## Resumen

Este procedimiento instala Microsoft Edge, Google Chrome, LibreOffice, OpenShot y Shotcut como Flatpak de usuario desde Flathub. Antes elimina las versiones previas instaladas como paquetes Debian.

| Parte | Quién la ejecuta | Qué hace |
| --- | --- | --- |
| A | Administrador, con `sudo` | Instala `flatpak` si falta y desinstala los paquetes `.deb` previos |
| B | El propio usuario, sin `sudo` | Añade Flathub, instala las aplicaciones y las mantiene actualizadas |

Las aplicaciones quedan en `~/.local/share/flatpak`, así que cada usuario que las necesite debe ejecutar la parte B en su sesión. Probado en Ubuntu Desktop 26.04 con Flatpak 1.16.6.

## Parte A — Administrador (sudo)

### A1. Instalar Flatpak si no está

```bash
flatpak --version || sudo apt install flatpak
```

### A2. Ver qué paquetes Debian hay instalados

```bash
dpkg -l | grep -E '^ii' | grep -i -E 'libreoffice|openshot|shotcut|google-chrome|microsoft-edge'
snap list | grep -i -E 'libreoffice|openshot|shotcut|chrom|edge'
```

Los nombres habituales de los paquetes `.deb` son `libreoffice-*`, `openshot-qt`, `shotcut`, `google-chrome-stable` y `microsoft-edge-stable`. Usa los nombres exactos que muestre la salida.

### A3. Desinstalar los paquetes Debian

```bash
sudo apt purge 'libreoffice*' openshot-qt shotcut google-chrome-stable microsoft-edge-stable
sudo apt autoremove
```

Quita de la línea los paquetes que no aparecieron en A2, porque apt da error si alguno no existe. Antes de confirmar, revisa la lista de paquetes que apt va a eliminar: solo deben aparecer estas aplicaciones y sus dependencias.

Si alguno estaba como snap: `sudo snap remove <nombre>`.

### A4. Quitar repositorios externos que ya no se usen

```bash
ls /etc/apt/sources.list.d/ | grep -i -E 'google|chrome|edge|microsoft|libreoffice'
```

Borra solo los ficheros de las aplicaciones que has quitado y actualiza:

```bash
sudo rm /etc/apt/sources.list.d/<fichero>
sudo apt update
```

No borres el repositorio de Microsoft si lo usa otra aplicación que mantengas instalada por apt (por ejemplo, VS Code).

## Parte B — Usuario (sin sudo)

### B1. Añadir Flathub para el usuario

```bash
flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak update --user --appstream
```

Si al instalar aparece el error `GPG verification enabled, but no summary found`, recrea el remoto:

```bash
flatpak remote-delete --user flathub
flatpak remote-add --user flathub https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak update --user --appstream
```

Si persiste, comprueba que llegas al servidor con `curl -I https://dl.flathub.org/repo/summary.idx`. Un timeout o una página del filtro indica un problema de red o proxy del centro.

### B2. Instalar las aplicaciones

```bash
flatpak install --user flathub com.microsoft.Edge com.google.Chrome org.libreoffice.LibreOffice org.openshot.OpenShot org.shotcut.Shotcut
```

Cierra sesión y vuelve a entrar para que aparezcan en el menú de aplicaciones.

### B3. Ejecutar desde terminal

| Aplicación | Comando |
| --- | --- |
| Microsoft Edge | `flatpak run com.microsoft.Edge` |
| Google Chrome | `flatpak run com.google.Chrome` |
| LibreOffice | `flatpak run org.libreoffice.LibreOffice` |
| OpenShot | `flatpak run org.openshot.OpenShot` |
| Shotcut | `flatpak run org.shotcut.Shotcut` |

### B4. Actualizar

```bash
flatpak update --user
```

### B5. Ocultar LibreOffice nativo si sigue instalado

Si el administrador no desinstaló el LibreOffice `.deb` (paso A3), el usuario ve dos juegos de iconos: los nativos (`libreoffice-*.desktop`) y los Flatpak (`org.libreoffice.LibreOffice.*.desktop`). Estos pasos ocultan los nativos **solo en el perfil del usuario**, sin `sudo` y sin tocar el sistema.

1. Copiar los lanzadores nativos a `~/.local/share/applications` con `NoDisplay=true`. Esa carpeta tiene prioridad sobre `/usr/share/applications`:

```bash
mkdir -p ~/.local/share/applications
for f in /usr/share/applications/libreoffice-*.desktop; do
  sed -e '/^NoDisplay=/d' \
      -e '0,/^\[Desktop Entry\]/s//&\nNoDisplay=true/' \
      "$f" > ~/.local/share/applications/"$(basename "$f")"
done
update-desktop-database ~/.local/share/applications
```

`NoDisplay=true` se inserta justo debajo de `[Desktop Entry]`. Si se pusiera al final del fichero, caería en las secciones de acciones y no tendría efecto.

2. Abrir los documentos con el Flatpak al hacer doble clic. Si no se hace, pueden seguir abriéndose con el nativo:

```bash
for app in writer calc impress draw math base; do
  for d in ~/.local/share/flatpak/exports/share/applications /var/lib/flatpak/exports/share/applications; do
    f="$d/org.libreoffice.LibreOffice.$app.desktop"
    [ -f "$f" ] || continue
    mimes=$(sed -n 's/^MimeType=//p' "$f" | tr ';' ' ')
    [ -n "$mimes" ] && xdg-mime default "$(basename "$f")" $mimes
    break
  done
done
```

Las asociaciones quedan en `~/.config/mimeapps.list`. El bucle vale tanto para un Flatpak instalado con `--user` como para uno instalado en todo el sistema.

3. Cerrar sesión, volver a entrar y comprobar:

```bash
xdg-mime query default application/vnd.oasis.opendocument.text
# → org.libreoffice.LibreOffice.writer.desktop
```

El LibreOffice nativo deja de salir en el menú, pero sigue disponible en «Abrir con…». Las copias son una foto de los lanzadores nativos de ese momento: si una actualización de apt añade un lanzador nuevo de LibreOffice, ese volverá a aparecer y habrá que repetir el paso 1.

Para deshacerlo:

```bash
rm ~/.local/share/applications/libreoffice-*.desktop
update-desktop-database ~/.local/share/applications
```

## Notas

Solo LibreOffice y Shotcut los publica su propio proyecto en Flathub. Edge, Chrome y OpenShot son paquetes de la comunidad que reempaquetan el binario oficial y no tienen soporte del fabricante.

| Aplicación | ID de Flathub | Publicado por | Versión (21/10/2026) |
| --- | --- | --- | --- |
| [Microsoft Edge](https://flathub.org/apps/com.microsoft.Edge) | `com.microsoft.Edge` | Comunidad (solo x86\_64) | 155.0.4283.62 |
| [Google Chrome](https://flathub.org/apps/com.google.Chrome) | `com.google.Chrome` | Comunidad | 155.0.8059.84 |
| [LibreOffice](https://flathub.org/en/apps/org.libreoffice.LibreOffice) | `org.libreoffice.LibreOffice` | The Document Foundation | 26.8.1.1 |
| [OpenShot](https://flathub.org/en/apps/org.openshot.OpenShot) | `org.openshot.OpenShot` | Comunidad | 3.5.1 |
| [Shotcut](https://flathub.org/en/apps/org.shotcut.Shotcut) | `org.shotcut.Shotcut` | Meltytech, LLC | 26.9.27 |

La configuración de las versiones Flatpak se guarda en `~/.var/app/<ID>`, no en `~/.config`. Los perfiles de las versiones `.deb` desinstaladas siguen en `~/.config` hasta que el usuario los borre o los copie.
