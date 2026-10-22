# Rol `obs`

> **⛔ Comentado en `roles.yaml` desde el 2026-10-22.** OBS se recomienda como
> **Flatpak de usuario** (`com.obsproject.Studio`), igual que LibreOffice,
> Shotcut y Edge: ver `Ubuntu/flatpack/preparaFlatpackEnUsuario.sh` y el rol
> [`flatpak`](../flatpak/CLAUDE.md). Este rol se conserva para instalar el
> `.deb` de sistema a mano con su playbook propio `obs.yaml`.

## Qué hace
Instala **OBS Studio** (`.deb` `obs-studio`) desde los repositorios apt configurados:

1. Comprueba si existe `/usr/bin/obs` y, si está, obtiene la versión con `obs --version`.
2. Consulta la versión candidata en apt (`apt-cache policy obs-studio`).
3. Si no se pasó `obs_version` por variable, usa la candidata del repositorio.
4. Instala `obs-studio={{ obs_version }}*` **solo si** no está instalado o la versión instalada no coincide con la objetivo.

## Cómo lanzarlo
Como está comentado en `roles.yaml`, **`roles.yaml --tags obs` ya no lo
ejecuta**. Se usa su playbook propio, `obs.yaml` (hace `apt update` y aplica
esta carpeta como rol con `role: "{{ playbook_dir }}"`, igual que `vscode.yaml`).
Desde `Ubuntu/ansible/roles/obs` (en un equipo: `/opt/IAC-IESMHP/Ubuntu/ansible/roles/obs`):

```bash
# En el propio equipo (local)
sudo ansible-playbook -i localhost, --connection=local obs.yaml

# Una versión concreta
sudo ansible-playbook -i localhost, --connection=local obs.yaml -e obs_version=32.1.0

# En un aula entera por SSH (los inventarios están dos carpetas más arriba)
ansible-playbook -i ../../equiposIABD.ini obs.yaml \
  --ssh-extra-args="-o StrictHostKeyChecking=no"

# Solo un equipo
ansible-playbook -i ../../equiposIABD.ini obs.yaml -l IABD-17

# Ver qué haría sin tocar nada
sudo ansible-playbook -i localhost, --connection=local obs.yaml --check
```

Para volver a instalarlo en todos los equipos con la cadena automática, quitar
el `#` de su línea en `roles.yaml`.

## Desinstalar el `.deb` (para pasar al Flatpak)
```bash
sudo apt purge obs-studio obs-plugins && sudo apt autoremove
flatpak install --user -y flathub com.obsproject.Studio
```
La configuración del `.deb` queda en `~/.config/obs-studio`; la del Flatpak va
en `~/.var/app/com.obsproject.Studio`.

## Estructura
- `tasks/main.yml`
- `obs.yaml` — playbook independiente para lanzar solo este rol desde su carpeta.
- Sin `defaults/`: `obs_version` es opcional y se pasa con `-e obs_version=...`.

## Notas
- Las consultas (`obs --version`, `apt-cache policy`) llevan `check_mode: false`
  para que `--check` muestre qué haría (antes fallaba en `--check`).
- Bloques comentados al final: eliminar el PPA de OBS tras instalar (no activo).
- Por defecto instala la **última versión disponible** en el proxy apt del aula.
- Historial: 2026-10-22 corregido el nombre de la primera tarea (decía «VS Code»,
  copia del rol `vscode`).
