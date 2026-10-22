# Rol `vscode`

## Qué hace
Instala **o actualiza** **Visual Studio Code** descargando el `.deb` oficial de Microsoft (no usa el repositorio de Microsoft, para no contaminar las fuentes apt del equipo):

1. Lee la versión instalada con `dpkg-query -W code` (sin el sufijo de build).
2. Consulta la última estable en
   `https://update.code.visualstudio.com/api/update/linux-deb-x64/stable/latest`
   (`productVersion`, `url`, `sha256hash`).
3. Decide:
   - no instalado → **instalar**;
   - instalado y más viejo que la última → **actualizar**;
   - si no, no hace nada.
   - Si la API no responde, un equipo con VS Code **no se toca**; uno sin él lo
     instala con la URL genérica `code.visualstudio.com/sha/download?build=stable&os=linux-deb-x64`.
4. Si hay que instalar (en un `block`):
   1. **Copia de seguridad** de `/etc/apt` → `/etc/apt.preVSCODE.bak` (borra antes la copia anterior).
   2. Descarga el `.deb` (comprueba el `sha256` si la API lo dio).
   3. Lo instala con `apt`.
   4. En `always` (también si falla): borra el `.deb`, **restaura `/etc/apt`** desde la copia (deshace el repo de Microsoft que añade el postinst) y hace `apt update`.

## Cómo ejecutarlo

### Opción A — solo el rol, desde su carpeta (sin `roles.yaml`)
El rol trae su propio playbook, `vscode.yaml` (hace `apt update` y aplica esta
carpeta como rol con `role: "{{ playbook_dir }}"`). Desde
`Ubuntu/ansible/roles/vscode` (en un equipo: `/opt/IAC-IESMHP/Ubuntu/ansible/roles/vscode`):

```bash
# En el propio equipo (local)
sudo ansible-playbook -i localhost, --connection=local vscode.yaml

# En un aula entera por SSH (los inventarios están dos carpetas más arriba)
ansible-playbook -i ../../equiposIABD.ini vscode.yaml \
  --ssh-extra-args="-o StrictHostKeyChecking=no"

# Solo un equipo
ansible-playbook -i ../../equiposIABD.ini vscode.yaml -l IABD-17

# Ver qué haría sin tocar nada
sudo ansible-playbook -i localhost, --connection=local vscode.yaml --check
```

### Opción B — a través de `roles.yaml` con `--tags`
Desde la carpeta `Ubuntu/ansible` (en un equipo: `/opt/IAC-IESMHP/Ubuntu/ansible`):

```bash
# En el propio equipo (local)
sudo ansible-playbook -i localhost, --connection=local roles.yaml --tags vscode

# En un aula entera por SSH
ansible-playbook -i ./equiposIABD.ini roles.yaml --tags vscode \
  --ssh-extra-args="-o StrictHostKeyChecking=no"

# Solo un equipo del aula
ansible-playbook -i ./equiposIABD.ini roles.yaml --tags vscode -l IABD-17

# Ver qué haría (instalar/actualizar/nada) sin tocar nada
ansible-playbook -i ./equiposIABD.ini roles.yaml --tags vscode --check
```

> Con `--tags vscode` también corren los `pre_tasks` de `roles.yaml` (`apt update`).
> En `--check` la tarea «Instalar el .deb» da error porque no se descarga nada;
> lo útil es el mensaje de «Mostrar estado de VS Code».

## Estructura
- `tasks/main.yml`
- `vscode.yaml` — playbook independiente para lanzar solo este rol desde su carpeta.
- Sin `defaults/`: no tiene variables; siempre deja la última versión estable.

## Notas
- El patrón backup/restore de `/etc/apt` es **deliberado**: evita que VS Code deje su repo y rompa el proxy apt del aula.
- Idempotente: si ya está en la última versión, no cambia nada.
- Las consultas llevan `check_mode: false`, así que `--check --tags vscode` muestra qué haría (instalar/actualizar/nada).
- Para actualizar un aula: `ansible-playbook -i ./equiposIABD.ini roles.yaml --tags vscode`.
- Historial: hasta 2026-10-22 solo instalaba si faltaba `/usr/bin/code` (no actualizaba).
