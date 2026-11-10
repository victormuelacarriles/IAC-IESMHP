# Rol `AWScli`

## Qué hace
Instala **o actualiza** la **consola de AWS (AWS CLI v2)** para **todo el sistema**
con el instalador oficial de AWS (no hay paquete apt de la v2; el snap no se usa):

- Programa en `/usr/local/aws-cli/v2/<versión>` (enlace `v2/current`).
- Ejecutables `/usr/local/bin/aws` y `/usr/local/bin/aws_completer`: en el PATH
  de **todos** los usuarios (locales y de dominio).
- Autocompletado de bash para todos: `/etc/bash_completion.d/aws-cli`.
- La configuración (`aws configure`, `~/.aws/`) es **de cada usuario**; el rol no
  la toca.

Pasos:
1. Versión instalada: `/usr/local/bin/aws --version` (`aws-cli/2.x.y ...`).
2. Última versión: la etiqueta `2.x.y` más alta del repo de GitHub
   (`git ls-remote --tags https://github.com/aws/aws-cli '2.*'`). Se usa
   `git ls-remote` y no la API de GitHub porque la API solo admite 60
   consultas/hora por IP, y todo el aula sale por la misma.
3. Decide:
   - no instalado → **instalar**;
   - instalado y más viejo que la última → **actualizar**;
   - si no, no hace nada.
   - Sin acceso a GitHub: si ya está instalado, **no se toca**; si no, se instala
     la última del enlace genérico.
4. Si hay que instalar: `unzip` (solo llama a apt si falta), descarga
   `https://awscli.amazonaws.com/awscli-exe-linux-<x86_64|aarch64>.zip` (~60 MB),
   descomprime en una carpeta temporal y ejecuta
   `./aws/install -i /usr/local/aws-cli -b /usr/local/bin --update`. La carpeta
   temporal se borra siempre (`always`).
   - Si la carpeta de esa misma versión ya existe pero no es la activa
     (instalación rota), se borra antes: si no, el instalador responde
     «Found same AWS CLI version… Skipping install» y no arregla nada.
5. Borra las **versiones antiguas** de `/usr/local/aws-cli/v2/` (todas menos la
   de `current`; cada una ocupa ~200 MB). `awscli_borra_versiones_viejas: false`
   para conservarlas.
6. Deja la **actualización automática** (ver abajo).

## Actualización automática (semanal)
Mismo esquema que el rol `vscode`: un timer **vuelve a lanzar este rol** en local,
sin nadie delante (funciona sin monitor).

- `iac-actualiza-awscli.timer`: **10 min después de encender** (`OnBootSec`; 10 y
  no 5 para no coincidir con `iac-actualiza-vscode`) y cada 24 h si sigue
  encendido. ±60 s al azar.
- `iac-actualiza-awscli.service` (oneshot, `After=network-online.target`,
  prioridad baja) → `/usr/local/sbin/iac-actualiza-awscli.sh`, que ejecuta
  `ansible-playbook -i localhost, --connection=local /opt/IAC-IESMHP/Ubuntu/ansible/roles/AWScli/AWScli.yaml`.
- **Como mucho cada 7 días** (`awscli_autoactualiza_dias`): AWS publica versión
  casi a diario y cada descarga son ~60 MB por equipo. La fecha de la última
  comprobación correcta está en `/var/lib/IAC-IESMHP/awscli-ultima-comprobacion`;
  si falla, no se escribe y se reintenta en el siguiente disparo.
- El rol escribe la marca de hoy **antes** de arrancar el timer y **no** arranca
  el service (mismo motivo que en `vscode`: evitar dos Ansible a la vez o que el
  service se espere a sí mismo).
- Log: `/var/log/IAC-IESMHP/Ubuntu/iac-actualiza-awscli.log` (pasa a `.1` al
  llegar a 1 MB) y `journalctl -t iac-awscli`.

```bash
systemctl list-timers iac-actualiza-awscli.timer
tail -n 30 /var/log/IAC-IESMHP/Ubuntu/iac-actualiza-awscli.log
# Forzar una comprobación ahora:
sudo rm -f /var/lib/IAC-IESMHP/awscli-ultima-comprobacion
sudo systemctl start iac-actualiza-awscli.service
```

Para quitarlo: `-e awscli_autoactualiza=false` (borra timer, service y script).

## Cómo ejecutarlo

### Lo más fácil — lanzador `AWScli.sh` (estilo `AnalisisEquipo.sh`)
Desde `/opt/IAC-IESMHP/Ubuntu/ansible/roles/AWScli`:

```bash
bash AWScli.sh SMRD                    # toda el aula SMRD
bash AWScli.sh IABD -l IABD-05         # un equipo
bash AWScli.sh IABD -l 'all:!IABD-00'  # todos menos el del profesor
bash AWScli.sh SMRD --check            # solo dice qué haría
bash AWScli.sh SMRD IABD               # varias aulas, una tras otra
sudo bash AWScli.sh                    # en local (este equipo)
bash AWScli.sh                         # en local sin sudo, si entras por clave en root@localhost
bash AWScli.sh --ayuda                 # todas las opciones
```

- **En local sin `sudo`**: `become` pediría la contraseña de sudo y el script
  no pregunta nada (headless). Si el usuario entra por clave en
  `root@localhost` (`Autorizados.txt`), el script lo detecta
  (`ssh -o BatchMode=yes root@localhost true`) y lanza Ansible por SSH como
  root (`-i localhost, --connection=ssh -u root`). Si no, pide `sudo`.
- **Didáctico**: antes de cada `ansible-playbook` muestra en **amarillo** el
  comando exacto (rutas absolutas, comillas solo donde hacen falta), listo para
  copiar y pegar. En el log queda igual, con `$ ` delante y sin color.
- **Sin comprobar la clave de host** (`ANSIBLE_HOST_KEY_CHECKING=False`, igual
  que `Reclona-IAC-IESMHP.sh`): los equipos se reinstalan, cambian de clave SSH
  y el `known_hosts` de quien lanza los rechazaba → todos «no responde por SSH»
  (2026-11-10). Un `ERROR no responde por SSH` lleva ahora el motivo: clave
  rechazada, puerto cerrado, no contesta (¿apagado?), DNS...
- Opciones propias: `-l`, `--forks N` (20), `--check`, `--dias N`,
  `--sin-autoactualiza`, `--conservar-versiones`, `--sin-autocompletado`. Lo
  demás que empiece por `-` va a `ansible-playbook` (`-v`, `-e`...).
- En pantalla, al final, **una línea por equipo**:
  `OK 2.0.1 → 2.39.6 (actualizado)`, `OK 2.39.6 (ya es la última)`,
  `CHECK no → 2.39.6 (haría: instalar)`, `ERROR no responde por SSH` o
  `ERROR <mensaje de la tarea>`, más el recuento y el tiempo.
- Salida completa de Ansible en `/var/log/IAC-IESMHP/AWScli.log` (o
  `~/.local/state/IAC-IESMHP/AWScli.log` sin permisos). Código 1 si algún
  equipo da ERROR. Sin preguntas (headless).
- Un `-l` que no coincide con ningún equipo de un inventario da aviso y se salta
  ese inventario.

### Opción A — solo el rol, desde su carpeta
`AWScli.yaml` aplica esta carpeta como rol (sin `apt update`: el rol solo usa apt
para `unzip`, con `cache_valid_time`). Desde
`/opt/IAC-IESMHP/Ubuntu/ansible/roles/AWScli`:

```bash
sudo ansible-playbook -i localhost, --connection=local AWScli.yaml
ansible-playbook -i ../../equiposIABD.ini AWScli.yaml --ssh-extra-args="-o StrictHostKeyChecking=no"
ansible-playbook -i ../../equiposIABD.ini AWScli.yaml -l IABD-17
sudo ansible-playbook -i localhost, --connection=local AWScli.yaml --check   # solo dice qué haría
```

### Opción B — a través de `roles.yaml`
Desde `/opt/IAC-IESMHP/Ubuntu/ansible`:

```bash
sudo ansible-playbook -i localhost, --connection=local roles.yaml --tags AWScli
ansible-playbook -i ./equiposIABD.ini roles.yaml --tags AWScli -l IABD-17
```

Comprobar en un equipo: `aws --version`.

## Estructura
- `tasks/main.yml` — instalar/actualizar, limpieza de versiones, autocompletado, timer.
- `defaults/main.yml` — rutas de instalación, `awscli_borra_versiones_viejas`,
  `awscli_autocompletado`, `awscli_autoactualiza` (+ espera, intervalo, días) y rutas
  de script/log/marca.
- `templates/` — `iac-actualiza-awscli.sh.j2`, `.service.j2`, `.timer.j2`.
- `AWScli.yaml` — playbook independiente (es el que usa el timer).
- `AWScli.sh` — lanzador para aulas/equipos con resumen por equipo.

## Notas
- En `--check` no se descarga ni se instala nada (el bloque se salta); lo útil es
  el mensaje «Mostrar estado de AWS CLI».
- Si hay otro `aws` antes en el PATH de un usuario (p. ej. `pip install --user
  awscli` en `~/.local/bin`), ese usuario usará el suyo. El snap `aws-cli`
  (`/snap/bin`) va después de `/usr/local/bin`, así que no molesta.
- No se verifica la firma GPG del `.zip` (solo HTTPS desde `awscli.amazonaws.com`).
- Probado el 2026-11-09 sin root en una carpeta temporal (instalar, «ya en la
  última», actualizar desde una versión vieja con restos en disco, script del
  timer). **Pendiente**: probarlo como root en la VM.
