# Rol `contenedores`

## Qué hace
Pretende instalar **Docker y Podman** (y sus respectivos `compose`) delegando en sub-roles externos:

- Incluye los roles `docker` y `podman` (`include_role`) si el sistema **no** es ya un contenedor (`ansible_virtualization_type` ≠ docker/podman).
- Incluye `docker_compose` y `podman_compose` bajo la misma condición.

## Estructura
- `tasks/main.yml`
- Sin `defaults/`.

## Estado (importante)
- **Incompleto / no funcional tal cual**: depende de roles externos (`docker`, `podman`, `docker_compose`, `podman_compose`) que **no están** en `roles/`. Habría que instalarlos (p. ej. desde Ansible Galaxy / `roles.yaml` de requirements) o reescribir las tareas inline.
- **Comentado** en `roles.yaml` con la nota "por hacer".
- TODO en el código: comprobar que `docker-compose` y `podman-compose` realmente funcionan tras instalarse.
