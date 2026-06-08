# Rol `Docker`

## Qué hace
Instalación de **sistema** (como root) que deja el equipo preparado para que
usuarios **sin privilegios** usen **Docker en modo rootless**. Hace **solo la
parte que requiere root**; la configuración por usuario la completa el rol
[`rolesUsuario/roles/DockerRootless`](../../rolesUsuario/roles/DockerRootless/CLAUDE.md).

Sigue la guía oficial <https://docs.docker.com/engine/security/rootless/>.

Se aplica desde [`../../roles.yaml`](../../roles.yaml) (play `hosts: all`,
`become: yes`).

## Reparto de responsabilidades (root vs usuario)

| Parte | Rol | Se ejecuta como |
|-------|-----|-----------------|
| Repo + paquetes, daemon de sistema, subuid/subgid, lingering | **`roles/Docker`** (este) | root |
| `dockerd-rootless-setuptool.sh`, `DOCKER_HOST`, `systemctl --user` | `rolesUsuario/roles/DockerRootless` | el propio usuario |

## Pasos (tasks/main.yml)
1. **Repo oficial de Docker**: keyring en `/etc/apt/keyrings/docker.asc` +
   entrada APT `download.docker.com/linux/ubuntu`.
2. **Instala el stack + prerrequisitos rootless**: `docker-ce`, `docker-ce-cli`,
   `containerd.io`, `docker-buildx-plugin`, `docker-compose-plugin`,
   `docker-ce-rootless-extras` + `uidmap`, `dbus-user-session`, `slirp4netns`,
   `fuse-overlayfs`.
3. **Desactiva el daemon de sistema** (`docker.service`/`docker.socket`) para
   que no compita con el rootless (configurable, `docker_disable_system_daemon`).
4. **subuid/subgid + lingering por usuario**: para cada usuario de
   `docker_rootless_users` que exista en el sistema, comprueba `/etc/subuid` y
   asigna el rango si falta, y habilita `loginctl enable-linger` (el daemon de
   usuario arranca en el boot sin login gráfico). Los que no existan aún se
   omiten con un aviso.

## Variables (`defaults/`)
| Variable | Por defecto | Para qué |
|----------|-------------|----------|
| `docker_arch` | `amd64` | Arquitectura del repo APT |
| `docker_codename` | `{{ ansible_distribution_release }}` | Codename del repo Docker (ver issue) |
| `docker_packages` / `docker_rootless_prereqs` | listas | Paquetes a instalar |
| `docker_disable_system_daemon` | `true` | Parar/deshabilitar el daemon de sistema |
| `docker_rootless_users` | `[usuario]` | Usuarios a preparar (subuid/subgid + lingering) |
| `docker_subid_range` | `100000-165535` | Rango subuid/subgid si falta (ver aviso) |

## Uso
```bash
# Como parte del despliegue (roles.yaml ya corre con become: yes):
cd /opt/IAC-IESMHP/Ubuntu/ansible
ansible-playbook -i localhost, --connection=local roles.yaml --tags docker

# Preparar usuarios concretos:
ansible-playbook ... roles.yaml --tags docker -e '{"docker_rootless_users":["usuario","alvaro"]}'
```
Después, **cada usuario** completa su Docker rootless con el rol
`DockerRootless` (ver su CLAUDE.md).

## Issues conocidos
- **Codename `resolute` (Ubuntu 26.04)**: si Docker aún no publica el repo para
  `resolute`, "Añadir el repositorio APT de Docker" fallará en `apt update`.
  Solución: `-e docker_codename=noble` (u otro LTS). Considerar fijarlo en
  `defaults/` cuando se confirme cuál sirve en el aula.
- **Rango subuid compartido**: `docker_subid_range` es un único rango; si lo
  aplicas a varios usuarios SIN subids, colisionarían. En la práctica `useradd`
  de Ubuntu asigna un rango distinto a cada usuario al crearlo, así que el
  fallback solo importa para el usuario principal. Ver nota en `defaults/`.

## Relación con otros roles
- Sustituye al antiguo rol `contenedores` (borrado), que estaba incompleto y
  comentado y dependía de sub-roles externos.
- Su contrapartida por usuario es
  [`rolesUsuario/roles/DockerRootless`](../../rolesUsuario/roles/DockerRootless/CLAUDE.md).
