# CLAUDE.md — `rolesUsuario` (configuración por usuario)

Esta carpeta agrupa las **configuraciones que TODO usuario debería tener** en su
propio perfil. A diferencia de `roles/` (roles de Ansible que se aplican **como
root** sobre el equipo durante el primer arranque), aquí los scripts/roles se
ejecutan **como el usuario** y tocan su `$HOME` (`~/.ssh`, dotfiles, ajustes de
escritorio, etc.).

| Carpeta hermana | Se ejecuta como | Ámbito |
|-----------------|-----------------|--------|
| `roles/`        | root (Ansible)  | Sistema: software, drivers, NFS, claves SSH de root |
| `rolesUsuario/` | el propio usuario | Perfil personal: claves SSH del usuario, configuración de entorno |
| `pruebas/`      | —               | Experimentación, no forma parte del despliegue |

> **Estado**: carpeta nueva (2026-06-08), en construcción. Todavía no está
> enganchada a `roles.yaml` ni a `3-SetupPrimerInicio.sh`; los scripts y el
> playbook se lanzan manualmente mientras se prueban.

---

## Contenido

### `rolesUsuario.yaml` — playbook por usuario
Playbook Ansible análogo a `../roles.yaml` pero **scoped al perfil del usuario**:
`hosts: localhost`, `connection: local`, **`become: no` global**. Solo las tareas
que necesitan root usan `become: yes` puntual (por eso se lanza con `-K`). Sus
roles viven en `rolesUsuario/roles/`.

```bash
cd /opt/IAC-IESMHP/Ubuntu/ansible/rolesUsuario
ansible-playbook -i localhost, --connection=local -K rolesUsuario.yaml
```

Roles actuales:

| Rol | Estado | Qué hace |
|-----|--------|----------|
| [`DockerRootless`](roles/DockerRootless/CLAUDE.md) | ✅ activo (1º) | Completa Docker **rootless** para el usuario actual (socket en `/run/user/<uid>/docker.sock`). La parte de sistema la hace [`../roles/Docker`](../roles/Docker/CLAUDE.md) como root |

### `0-ConfiguracionInicial.sh`
Configuración mínima de SSH del usuario. **Se ejecuta como el usuario, no como
root** (aborta si detecta `uid 0`). Es idempotente.

1. Asegura `~/.ssh` con permisos `0700`. **Self-heal de propiedad**: si
   `~/.ssh` o `authorized_keys` pertenecen a root (caso habitual en equipos ya
   provisionados, donde el instalador escribió las claves como root sin
   `chown`), el script lo detecta (`[ -O ... ]`) y reasigna la propiedad al
   usuario con `sudo chown -R` (el contenido —claves de admin/profes— se
   conserva). Si falta `sudo`, indica el comando exacto a ejecutar y aborta.
2. Si el usuario **no tiene** par de claves, genera `~/.ssh/id_ed25519`
   (ed25519, sin passphrase, comentario `usuario@hostname`). Si ya existe, no
   lo regenera.
3. Añade la clave pública a `~/.ssh/authorized_keys` (`0600`) para permitir el
   **login a sí mismo**.
4. Registra `localhost` / `127.0.0.1` / `$(hostname)` en `~/.ssh/known_hosts`
   con `ssh-keyscan`.
5. Verifica la conexión con `ssh localhost "exit 0"`. Si funciona, imprime
   `Correcto` y sale `0`.

**Códigos de salida**: `0` = todo OK (conexión verificada) · `1` = error
(lanzado como root o fallo al generar la clave) · `2` = clave/authorized_keys
configurados pero la conexión SSH falla (típicamente porque `sshd` no está
instalado/arrancado todavía).

**Uso**:
```bash
bash 0-ConfiguracionInicial.sh        # como el usuario actual
```

**Relación con el rol `certificados`**: aquel hace lo mismo pero **para root**
(`/root/.ssh`), vía Ansible. Este script es el equivalente para el usuario
normal. Ver [../roles/certificados/CLAUDE.md](../roles/certificados/CLAUDE.md).

---

## Convenciones de esta carpeta

- **Numeración**: los scripts llevan prefijo de orden (`0-`, `1-`, …) según la
  secuencia en que deben ejecutarse.
- **Idempotencia**: relanzar cualquier script no debe duplicar entradas ni
  romper configuración existente.
- **Nunca como root**: estos scripts configuran el perfil del usuario; si
  necesitan privilegios deben pedirlos puntualmente, no ejecutarse enteros como
  root.

## Por hacer
- Enganchar la ejecución al despliegue (¿perfil de `/etc/skel`, autostart en el
  primer login del usuario, o un rol Ansible que itere sobre los usuarios?).
- Dotfiles / ajustes de GNOME comunes.
