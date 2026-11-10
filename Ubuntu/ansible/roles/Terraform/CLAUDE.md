# Rol `Terraform`

## Qué hace
Instala **o reinstala** **Terraform** (HashiCorp) para **todo el sistema** con el
`.zip` oficial de `releases.hashicorp.com`. **No** añade el repo apt de HashiCorp
(mismo criterio que `vscode`: no tocar las fuentes apt del aula).

- Binario único en `/usr/local/bin/terraform`: en el PATH de **todos** los
  usuarios (locales y de dominio).
- Autocompletado de bash para todos: `/etc/bash_completion.d/terraform`
  (`complete -C`). No se usa `terraform -install-autocomplete`, que es por
  usuario y toca su `~/.bashrc`.
- Los plugins/proveedores y `~/.terraform.d/` son **de cada usuario**; el rol no
  los toca.

Pasos:
1. Versión instalada: `/usr/local/bin/terraform version -json`.
2. Última versión, URL del `.zip` (linux, `amd64`/`arm64`) y fichero
   `SHA256SUMS`: `https://api.releases.hashicorp.com/v1/releases/terraform/latest`
   (solo versiones estables).
3. Decide:
   - no instalado **o binario roto** (no responde a `version`) → **instalar**;
   - instalado y más viejo que la última → **actualizar** (reinstalar);
   - si no, no hace nada.
   - Sin acceso a la API de HashiCorp no se sabe qué bajar: **no se toca nada**.
4. Si hay que instalar: `unzip` (solo llama a apt si falta), descarga el `.zip`
   **comprobando el sha256** con el `SHA256SUMS` oficial (`get_url checksum`),
   descomprime en una carpeta temporal y copia el binario a `/usr/local/bin`
   (root:root, 0755; `copy` lo cambia de golpe). La carpeta temporal se borra
   siempre (`always`).
5. Si hay **otro terraform** (`/usr/bin/terraform` del repo apt, snap) lo avisa y
   **no lo toca**: manda el de `/usr/local/bin`, que va antes en el PATH.
6. Deja la **actualización automática** (ver abajo).

## Actualización automática (semanal)
Mismo esquema que `vscode` y `AWScli`:

- `iac-actualiza-terraform.timer`: **15 min después de encender** (vscode va a
  los 5 y AWScli a los 10; así no coinciden tres Ansible) y cada 24 h si sigue
  encendido. ±60 s al azar.
- `iac-actualiza-terraform.service` (oneshot, `After=network-online.target`,
  prioridad baja) → `/usr/local/sbin/iac-actualiza-terraform.sh`, que lanza
  `Terraform.yaml` en local.
- **Como mucho cada 7 días** (`terraform_autoactualiza_dias`). Marca en
  `/var/lib/IAC-IESMHP/terraform-ultima-comprobacion`; si falla no se escribe y se
  reintenta en el siguiente disparo.
- El rol escribe la marca de hoy antes de arrancar el timer y **no** arranca el
  service (mismo motivo que en `vscode`).
- Log: `/var/log/IAC-IESMHP/Ubuntu/iac-actualiza-terraform.log` y
  `journalctl -t iac-terraform`.

```bash
systemctl list-timers iac-actualiza-terraform.timer
tail -n 30 /var/log/IAC-IESMHP/Ubuntu/iac-actualiza-terraform.log
# Forzar una comprobación ahora:
sudo rm -f /var/lib/IAC-IESMHP/terraform-ultima-comprobacion
sudo systemctl start iac-actualiza-terraform.service
```

Para quitarlo: `-e terraform_autoactualiza=false` (borra timer, service y script).

## Cómo ejecutarlo

### Lo más fácil — lanzador `Terraform.sh` (estilo `AnalisisEquipo.sh`)
Desde `/opt/IAC-IESMHP/Ubuntu/ansible/roles/Terraform`:

```bash
bash Terraform.sh SMRD                    # toda el aula SMRD
bash Terraform.sh IABD -l IABD-05         # un equipo
bash Terraform.sh IABD -l 'all:!IABD-00'  # todos menos el del profesor
bash Terraform.sh SMRD --check            # solo dice qué haría
bash Terraform.sh SMRD IABD               # varias aulas, una tras otra
sudo bash Terraform.sh                    # en local (este equipo)
bash Terraform.sh                         # en local sin sudo, si entras por clave en root@localhost
bash Terraform.sh --ayuda                 # todas las opciones
```

- **En local sin `sudo`**: `become` pediría la contraseña de sudo y el script
  no pregunta nada (headless). Si el usuario entra por clave en
  `root@localhost` (`Autorizados.txt`), el script lo detecta
  (`ssh -o BatchMode=yes root@localhost true`) y lanza Ansible por SSH como
  root (`-i localhost, --connection=ssh -u root`). Si no, pide `sudo`.
- **Didáctico**: antes de cada `ansible-playbook` muestra en **amarillo** el
  comando exacto (rutas absolutas, comillas solo donde hacen falta), listo para
  copiar y pegar. En el log queda igual, con `$ ` delante y sin color.
- Opciones propias: `-l`, `--forks N` (20), `--check`, `--dias N`,
  `--sin-autoactualiza`, `--sin-autocompletado`. Lo demás que empiece por `-` va
  a `ansible-playbook` (`-v`, `-e`...).
- Al final, **una línea por equipo**: `OK 1.5.0 → 1.17.1 (actualizado)`,
  `OK 1.17.1 (ya es la última)`, `CHECK no → 1.17.1 (haría: instalar)`,
  `ERROR no responde por SSH` o `ERROR <mensaje>`, más recuento y tiempo.
- Salida completa de Ansible en `/var/log/IAC-IESMHP/Terraform.log` (o
  `~/.local/state/IAC-IESMHP/Terraform.log`). Código 1 si algún equipo da ERROR.
  Sin preguntas (headless).

### Playbook del rol / `roles.yaml`
```bash
sudo ansible-playbook -i localhost, --connection=local Terraform.yaml          # desde esta carpeta
sudo ansible-playbook -i localhost, --connection=local roles.yaml --tags Terraform   # desde Ubuntu/ansible
```

Comprobar en un equipo: `terraform version`.

## Estructura
- `tasks/main.yml` — instalar/actualizar, aviso de otros terraform, autocompletado, timer.
- `defaults/main.yml` — `terraform_bin_dir`, `terraform_autocompletado`,
  `terraform_autoactualiza` (+ espera, intervalo, días) y rutas de script/log/marca.
- `templates/` — `iac-actualiza-terraform.sh.j2`, `.service.j2`, `.timer.j2`.
- `Terraform.yaml` — playbook independiente (es el que usa el timer).
- `Terraform.sh` — lanzador para aulas/equipos con resumen por equipo.

## Notas
- En `--check` no se descarga nada; lo útil es «Mostrar estado de Terraform».
- Se comprueba el sha256, pero no la firma GPG del `SHA256SUMS`.
- Probado el 2026-11-10 **sin root** en este equipo, con una copia del rol sin
  `owner/group` y un inventario falso (`ansible_connection=local`): `--check`,
  instalar (1.17.1), «ya es la última», actualizar desde una versión vieja
  falsa, reinstalar un binario roto y el caso «no responde por SSH».
  **Pendiente**: probarlo como root en la VM y sin monitor.
