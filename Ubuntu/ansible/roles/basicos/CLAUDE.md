# Rol `basicos`

## Qué hace
Reinstala/asegura el software base que el equipo *debería* traer ya desde el Live CD, pero que se vuelve a comprobar por si la ISO no lo dejó instalado:

- `python3`
- `python3-pip`
- `pipx`
- `ansible` (vía apt)

## Estructura
- `tasks/main.yml` — cuatro tareas `apt`, todas con `state: present` y `update_cache: false` (la caché ya se refresca una vez en `pre_tasks` de `roles.yaml`).
- Sin `defaults/`: no tiene variables.

## Notas
- Idempotente: si los paquetes ya están, no marca cambios.
- Es el primer rol de `roles.yaml`; el resto de roles asume que `python3`/`ansible` ya existen.
- No fija versiones: instala lo disponible en los repositorios configurados (proxy apt del aula).
