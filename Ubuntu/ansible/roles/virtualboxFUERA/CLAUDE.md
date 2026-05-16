# Rol `virtualboxFUERA`

## Qué hace
Rol **inverso** de [`virtualbox`](../virtualbox/CLAUDE.md): **desinstala** VirtualBox por completo y limpia todo su rastro:

1. Detiene y deshabilita los servicios `vboxdrv`, `vboxautostart-service`, `vboxweb-service` (ignora errores si no existen).
2. `apt purge + autoremove` de `virtualbox*` (todas las versiones/componentes y su configuración).
3. Busca y elimina ficheros de repositorio en `/etc/apt/sources.list.d/` que contengan `virtualbox`/`oracle`.
4. Busca y elimina claves GPG `*oracle*.gpg` / `*virtualbox*.gpg` en `/etc/apt/trusted.gpg.d/`.
5. Fuerza `apt update` + `autoremove` final.
6. Verifica con `dpkg-query` que ya no está y lo informa.

## Estructura
- `tasks/main.yml` (usa un *handler* "Update APT Cache" — vía `notify` — aunque el rol no incluye carpeta `handlers/`; depende de que esté definido a nivel de playbook si se usa).
- Tareas etiquetadas con `tags: virtualbox, uninstall, repository, gpg, cleanup, verification`.
- Sin `defaults/`.

## Estado
- No se referencia en `roles.yaml` (se usa puntualmente cuando hay que limpiar VirtualBox de un equipo).
- Útil como saneamiento previo si `virtualbox` dejó el equipo en estado inconsistente.
