# Rol `Docker`

## Qué hace
Deja **Docker en modo rootless listo para TODOS los usuarios** (UID ≥ 1000,
locales y del dominio AD) sin intervención: instala el sistema como root y,
mediante un hook PAM + un servicio de usuario global (sección 6), configura el
daemon rootless de cada usuario **automáticamente al abrir sesión**. No hay que
lanzar nada por usuario.

Sigue la guía oficial <https://docs.docker.com/engine/security/rootless/>.

Se aplica desde [`../../roles.yaml`](../../roles.yaml) (play `hosts: all`,
`become: yes`).

## Reparto de responsabilidades (root vs usuario)

| Parte | Pieza | Se ejecuta como | Cuándo |
|-------|-------|-----------------|--------|
| Repo + paquetes, `ip_forward`, `nf_tables`, daemon de sistema desactivado | `tasks/main.yml` (pasos 1-4) | root | al aplicar el rol |
| subuid/subgid + lingering | `iac-docker-rootless-prep.sh` (hook PAM) | root | en cada login |
| `dockerd-rootless-setuptool.sh install`, `systemctl --user`, contexto `rootless` | `iac-docker-rootless-user.sh` (servicio de usuario global) | el propio usuario | al arrancar su gestor systemd |

> El antiguo rol manual `rolesUsuario/roles/DockerRootless` se **eliminó el
> 2026-10-21** (redundante con la sección 6). Como reparación manual sigue
> existiendo la PARTE 2 de
> [`rolesUsuario/0-ConfiguracionInicial.sh`](../../rolesUsuario/CLAUDE.md), o
> simplemente `iac-docker-rootless-user.sh` lanzado por el usuario.

## Automatización por usuario en cada login (local **y dominio AD**)

> **Novedad 2026-06-16.** Antes la parte de usuario (antiguo rol `DockerRootless` /
> `0-ConfiguracionInicial.sh` PARTE 2) había que lanzarla **a mano** por cada
> usuario, así que un usuario nuevo o del **dominio** veía
> `failed to connect to the docker API at unix:///var/run/docker.sock` (el
> daemon de sistema está desactivado a propósito y el cliente caía al socket
> inexistente). La **sección 6** del rol lo automatiza para **cualquier** usuario
> que abra sesión, sin intervención.

Dos piezas que reproducen el mismo reparto root/usuario:

| Pieza | Qué hace | Cómo se dispara |
|-------|----------|-----------------|
| `iac-docker-rootless-prep.sh` (root) | `modprobe nf_tables` + subuid/subgid **escritos directamente a `/etc/subuid` + `/etc/subgid`** (rango único por usuario) + `loginctl enable-linger` | **hook `pam_exec`** en `common-session` (perfil pam-config `iac-docker-rootless`, activado con `pam-auth-update`), en cada apertura de sesión |
| `iac-docker-rootless-user.sh` (usuario) | `dockerd-rootless-setuptool.sh install` + `systemctl --user enable --now docker` + `docker context use rootless` | **servicio systemd de usuario global** `iac-docker-rootless.service` (`systemctl --global enable`) |

- **Por qué subuid a fichero y no `usermod`**: `usermod --add-subuids` solo opera
  sobre `/etc/passwd` → **falla con usuarios del dominio** (viven en SSSD). El
  helper ROOT calcula el siguiente rango libre y lo **escribe directamente** a
  `/etc/subuid`/`/etc/subgid` (válido para locales y de dominio; con `flock` para
  serializar logins simultáneos).
- **Por qué `docker context use rootless` y no `DOCKER_HOST` en `~/.bashrc`**: el
  contexto vive en `~/.docker` y lo respeta el cliente en **cualquier** shell
  (login, no-login, gnome-terminal) y en apps gráficas, sin depender de que se
  cargue `~/.bashrc`. (Si un usuario ya tiene `DOCKER_HOST` exportado de una
  ejecución previa, no estorba: apunta al mismo socket.)
- **Orden en el primer login**: el perfil PAM tiene `Priority: 128`, así que
  `pam_exec` queda en `common-session` **antes** de `pam_systemd` (prioridad 0):
  el subuid ya está escrito cuando arranca el gestor systemd del usuario. Por si
  acaso, el servicio de usuario espera hasta ~15 s al subuid; si no aparece, se
  reintenta en el siguiente login (el lingering garantiza que en el próximo boot
  ya está todo).
- **Solo usuarios reales**: el helper de usuario sale enseguida si el UID es
  menor que `docker_rootless_min_uid` (p. ej. `gdm`, `gdm-greeter`), para no
  retrasar ~15 s su `default.target` esperando un subuid que nunca tendrán.
- **Un daemon por usuario en el arranque**: el lingering se activa para todo
  usuario que haya entrado alguna vez, así que al arrancar el equipo se levanta
  un `dockerd` rootless por cada uno (RAM + imágenes en `~/.local/share/docker`).
  Tenerlo en cuenta en aulas con muchos usuarios del dominio.
- **Seguridad**: NO se concede sudo a los usuarios; la parte root la hace el
  hook PAM. El perfil usa `optional` + `quiet`, así que un fallo del helper
  **nunca bloquea el login**.

## Pasos (tasks/main.yml)
1. **Repo oficial de Docker**: keyring en `/etc/apt/keyrings/docker.asc` +
   entrada APT `download.docker.com/linux/ubuntu`.
2. **Instala el stack + prerrequisitos rootless**: `docker-ce`, `docker-ce-cli`,
   `containerd.io`, `docker-buildx-plugin`, `docker-compose-plugin`,
   `docker-ce-rootless-extras` + `uidmap`, `dbus-user-session`, `slirp4netns`,
   `fuse-overlayfs`.
3. **Habilita el reenvío IPv4** (`net.ipv4.ip_forward=1`) en
   `/etc/sysctl.d/99-iac-docker.conf` y lo aplica en caliente. Sin esto,
   `docker compose` falla con *"IPv4 forwarding is disabled. Networking will not
   work."* (configurable, `docker_enable_ip_forward`).
3b. **Carga `nf_tables`** (prerequisito de `dockerd-rootless-setuptool.sh`):
   persistente en `/etc/modules-load.d/iac-docker-rootless.conf` y en caliente
   con `modprobe`. Sin él, la instalación del daemon rootless del usuario aborta
   con *"Missing system requirements … modprobe nf_tables"* (ver Issues). Ubuntu
   26.04 no lo carga de serie en una instalación desde squashfs.
4. **Desactiva el daemon de sistema** (`docker.service`/`docker.socket`) para
   que no compita con el rootless (configurable, `docker_disable_system_daemon`).
5. **subuid/subgid + lingering por usuario**: para cada usuario de
   `docker_rootless_users` que exista en el sistema, comprueba `/etc/subuid` y
   asigna el rango si falta, y habilita `loginctl enable-linger` (el daemon de
   usuario arranca en el boot sin login gráfico). Los que no existan aún se
   omiten con un aviso.
6. **Automatización rootless por usuario en cada login** (`docker_rootless_auto`,
   por defecto `true`): instala el helper ROOT
   (`/usr/local/sbin/iac-docker-rootless-prep.sh`), el helper de usuario
   (`/usr/local/bin/iac-docker-rootless-user.sh`), el servicio de usuario
   `/etc/systemd/user/iac-docker-rootless.service` (lo habilita con
   `systemctl --global enable`) y el perfil pam-config
   `/usr/share/pam-configs/iac-docker-rootless` (lo activa con
   `pam-auth-update --enable`). Ver la sección "Automatización por usuario…"
   arriba. Usa `command` (no el módulo `systemd` con `enabled:`/`daemon_reload:`,
   que cuelga el primer arranque — bugs 2026-05-17).

## Variables (`defaults/`)
| Variable | Por defecto | Para qué |
|----------|-------------|----------|
| `docker_arch` | `amd64` | Arquitectura del repo APT |
| `docker_codename` | `{{ ansible_distribution_release }}` | Codename del repo Docker (ver issue) |
| `docker_packages` / `docker_rootless_prereqs` | listas | Paquetes a instalar |
| `docker_disable_system_daemon` | `true` | Parar/deshabilitar el daemon de sistema |
| `docker_enable_ip_forward` | `true` | Activar `net.ipv4.ip_forward` (fix del aviso de red de `docker compose`) |
| `docker_rootless_users` | `[usuario]` | Usuarios a preparar explícitamente en el rol (subuid/subgid + lingering) |
| `docker_subid_range` | `100000-165535` | Rango subuid/subgid si falta (ver aviso) |
| `docker_rootless_auto` | `true` | Sección 6: hook PAM + servicio de usuario global (automatiza el rootless en cada login, incl. dominio). `false` ⇒ cada usuario debe lanzar a mano la PARTE 2 de `rolesUsuario/0-ConfiguracionInicial.sh` |
| `docker_rootless_min_uid` | `1000` | UID mínimo para preparar a un usuario automáticamente (salta root/sistema); lo usan los dos helpers |
| `docker_subid_block_size` | `65536` | Tamaño del bloque subuid/subgid del helper ROOT |
| `docker_subid_block_start` | `100000` | Primer subuid/subgid disponible (rangos consecutivos sin solape) |

## Uso
```bash
# Como parte del despliegue (roles.yaml ya corre con become: yes):
cd /opt/IAC-IESMHP/Ubuntu/ansible
ansible-playbook -i localhost, --connection=local roles.yaml --tags docker

# Preparar usuarios concretos:
ansible-playbook ... roles.yaml --tags docker -e '{"docker_rootless_users":["usuario","alvaro"]}'
```
No hace falta nada más: cada usuario tiene su Docker rootless al abrir sesión
(en el primer login puede tardar unos segundos en quedar listo). Comprobar como
el usuario: `docker context show` → `rootless` y `docker run hello-world`.

## Issues conocidos
- **`Missing system requirements … modprobe nf_tables` al instalar el daemon
  rootless (2026-06-17)**: `dockerd-rootless-setuptool.sh install` aborta si el
  módulo `nf_tables` no está cargado (iptables-nft lo necesita para el
  port-mapping). Ubuntu 26.04 NO lo carga de serie en una instalación desde
  squashfs, así que tanto el servicio de usuario (sección 6) como el script
  manual `0-ConfiguracionInicial.sh` fallaban en silencio y el usuario se
  quedaba SIN Docker rootless. **Fix**: paso **3b** del rol (modules-load.d +
  `modprobe`) y, como red de seguridad por sesión, `modprobe nf_tables` en el
  hook ROOT `iac-docker-rootless-prep.sh`. El script manual también lo carga
  (vía `sudo`) antes del setuptool. En equipos ya instalados: reaplicar el rol
  (`--tags docker`) o `sudo modprobe nf_tables` + reabrir sesión. Comprobar:
  `lsmod | grep nf_tables`.
- **Usuario nuevo o del dominio: `failed to connect to the docker API at
  unix:///var/run/docker.sock` (2026-06-16)**: el daemon de SISTEMA está
  desactivado (rootless) y el usuario nunca configuró su daemon rootless. **Fix**:
  sección 6 (hook PAM `iac-docker-rootless-prep.sh` + servicio de usuario global
  `iac-docker-rootless.service`) lo configura automáticamente en cada login,
  **incluidos los usuarios del dominio** (el subuid se escribe a fichero, no con
  `usermod`, que no conoce SSSD). Diagnóstico en el equipo:
  `journalctl -t iac-docker-rootless-prep -t iac-docker-rootless-user`,
  `grep iac-docker-rootless-prep /etc/pam.d/common-session`,
  `getent subuid <usuario>`, `systemctl --global is-enabled iac-docker-rootless.service`.
  Tras el **primer** login el daemon puede tardar una sesión en quedar listo
  (race subuid); en la siguiente sesión `docker run hello-world` ya va.
- **"IPv4 forwarding is disabled. Networking will not work." (2026-06-09)**: al
  levantar un `docker compose` la red de los contenedores no funcionaba porque
  el kernel tenía `net.ipv4.ip_forward=0`. **Fix**: paso 3 del rol que fija
  `net.ipv4.ip_forward=1` en `/etc/sysctl.d/99-iac-docker.conf` y lo aplica en
  caliente (`docker_enable_ip_forward`, por defecto `true`). En equipos ya
  instalados basta con reaplicar el rol (`--tags docker`).
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
- Sustituye también al antiguo rol por usuario `rolesUsuario/roles/DockerRootless`
  (eliminado el 2026-10-21; su trabajo lo hace la sección 6 en cada login).
  Reparación manual: PARTE 2 de `rolesUsuario/0-ConfiguracionInicial.sh`.
