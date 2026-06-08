# Rol `DockerRootless`

## Qué hace
Instala **Docker en modo rootless** para el **usuario que ejecuta el playbook**
(no para root), siguiendo la guía oficial
<https://docs.docker.com/engine/security/rootless/>. El daemon corre dentro del
namespace de usuario: sin privilegios, con el socket en
`/run/user/<uid>/docker.sock`.

Es el primer rol de `rolesUsuario/` y se invoca desde
[`../../rolesUsuario.yaml`](../../rolesUsuario.yaml).

## Pasos (tasks/main.yml)
1. **Aborta si uid 0** — el rol es para un usuario normal, no root.
2. **Repo oficial de Docker** (`become: yes`): keyring en
   `/etc/apt/keyrings/docker.asc` + entrada APT `download.docker.com/linux/ubuntu`.
3. **Instala el stack** (`become: yes`): `docker-ce`, `docker-ce-cli`,
   `containerd.io`, `docker-buildx-plugin`, `docker-compose-plugin`,
   `docker-ce-rootless-extras` + prerrequisitos `uidmap`, `dbus-user-session`,
   `slirp4netns`, `fuse-overlayfs`.
4. **Desactiva el daemon de sistema** (`docker.service`/`docker.socket`) para
   que no compita con el rootless (configurable, `dr_disable_system_docker`).
5. **subuid/subgid**: si el usuario no tiene rango asignado en `/etc/subuid`,
   lo añade con `usermod --add-subuids/--add-subgids` (65 536 ids).
6. **Lingering** (`loginctl enable-linger`): el daemon de usuario arranca en el
   boot sin necesidad de que el usuario inicie sesión gráfica.
7. **`dockerd-rootless-setuptool.sh install`** (COMO el usuario): crea la unit
   `~/.config/systemd/user/docker.service`. Idempotente (se salta si la unit ya
   existe).
8. **`~/.bashrc`**: exporta `PATH=/usr/bin:$PATH` y
   `DOCKER_HOST=unix:///run/user/<uid>/docker.sock` (bloque marcado, idempotente).
9. **`systemctl --user enable --now docker`** + verificación final con
   `docker info`.

## Estructura
- `tasks/main.yml`
- `defaults/main.yml` — usuario/home/uid (de los facts), codename del repo,
  listas de paquetes, rango de subids, flag para desactivar el daemon de sistema.

## Variables (`defaults/`)
| Variable | Por defecto | Para qué |
|----------|-------------|----------|
| `dr_user` / `dr_user_uid` / `dr_user_home` | facts del usuario | Quién recibe el Docker rootless |
| `dr_arch` | `amd64` | Arquitectura del repo APT |
| `dr_codename` | `{{ ansible_distribution_release }}` | Codename del repo Docker (ver issue) |
| `dr_docker_packages` / `dr_prereqs` | listas | Paquetes a instalar |
| `dr_subid_range` | `100000-165535` | Rango subuid/subgid si falta |
| `dr_disable_system_docker` | `true` | Parar el daemon de sistema |

## Uso
```bash
# Como el USUARIO (no root). -K pide la contraseña de sudo para las tareas root.
cd /opt/IAC-IESMHP/Ubuntu/ansible/rolesUsuario
ansible-playbook -i localhost, --connection=local -K rolesUsuario.yaml

# Solo este rol:
ansible-playbook -i localhost, --connection=local -K rolesUsuario.yaml --tags docker
```
Tras instalarlo, en una **sesión nueva** del usuario (para que `~/.bashrc`
exporte `DOCKER_HOST`):
```bash
docker run --rm hello-world
```

## Issues conocidos
- **Codename `resolute` (Ubuntu 26.04)**: si Docker aún no publica el repo para
  `resolute`, la tarea "Añadir el repositorio APT de Docker" fallará en
  `apt update`. Solución: pasar un codename LTS compatible, p. ej.
  `-e dr_codename=noble`. Considerar fijarlo en `defaults/` cuando se confirme
  cuál sirve en el aula.
- **`docker info` falla justo tras la instalación**: el bus/manager systemd del
  usuario puede no estar listo en la misma ejecución (sobre todo si el lingering
  se acaba de habilitar y no hay sesión activa). El servicio queda `enabled`; se
  resuelve al reiniciar la sesión del usuario o el equipo. La tarea de
  verificación es `failed_when: false` para no abortar el playbook por esto.
- **No enganchado al despliegue todavía**: `rolesUsuario.yaml` se lanza a mano.
  Pendiente decidir cómo integrarlo en el primer arranque (ver
  [`../../CLAUDE.md`](../../CLAUDE.md) → "Por hacer").

## Relación con otros roles
- [`roles/contenedores`](../../../roles/contenedores/CLAUDE.md) instalaría Docker
  **de sistema** (como root) vía sub-roles externos; está incompleto y comentado.
  `DockerRootless` es el enfoque **por usuario**, autónomo e independiente de
  aquel.
