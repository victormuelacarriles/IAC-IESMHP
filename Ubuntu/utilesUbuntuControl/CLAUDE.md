# CLAUDE.md — `Ubuntu/utilesUbuntuControl/`

Utilidades para **controlar las aulas** donde ya está desplegada la imagen de
Ubuntu personalizada (encender, apagar, lanzar comandos en lote). **No forman parte
de la cadena automática de instalación** (`0b-GitHub` → scripts numerados): son
herramientas que se ejecutan **a mano o por cron** desde una **máquina virtual de
control** (Linux) con acceso de red a las aulas.

> Procedencia: estas carpetas vivían antes en `Mint/ControlIABD` y
> `Mint/ControlSMRD` (primera generación) y se movieron aquí en octubre de 2026.
> Algunos comentarios internos aún citan la ruta antigua `Mint/...`.

## Contenido

| Carpeta | Para qué | Detalle |
|---------|----------|---------|
| [`ControlIABD/`](ControlIABD/CLAUDE.md) | Encender (WoL) y apagar (SSH `poweroff`) el aula **IABD** (`10.0.72.x`). Scripts Bash simples con MACs/IPs fijas. | [CLAUDE.md](ControlIABD/CLAUDE.md) |
| [`ControlSMRD/`](ControlSMRD/CLAUDE.md) | Encender y apagar el aula **SMRD** (`10.0.32.x`), apagado automático por cron de equipos sin sesiones, inventario Ansible y ejemplos de comandos ad-hoc. | [CLAUDE.md](ControlSMRD/CLAUDE.md) |
| [`homeAlumno/`](homeAlumno/CLAUDE.md) | `EnciendeAlumno.py`: "portero" SSH. Un alumno/profesor entra por SSH al usuario `alumno` de la VM, se autentica contra el AD y el script **enciende por WoL su equipo asignado** y espera a que responda. | [CLAUDE.md](homeAlumno/CLAUDE.md) |

## Requisitos de la VM de control

- Linux con `bash`, `ssh`, `ping`, `wakeonlan` (paquete `wakeonlan`) y `ansible`.
- **Clave SSH autorizada como `root`** en los equipos del aula (la imagen instala
  `Autorizados.txt` de la raíz del repo en `/root/.ssh/authorized_keys`).
- Python 3 + `venv` con `ldap3` para `homeAlumno/EnciendeAlumno.py`.
- Alcance de red a `10.0.32.0/24` y `10.0.72.0/24`. **Todo el Wake-on-LAN usa
  broadcast dirigido** a la red del aula (`10.0.32.255` / `10.0.72.255`), tanto los
  scripts Bash (`wakeonlan -i`) como `EnciendeAlumno.py`. Desde **otra subred**, el
  router debe dejar pasar ese broadcast dirigido; desde la misma subred funciona sin más.
- Los scripts están en git **sin bit de ejecución**: lanzarlos con `bash script.sh`.

## Convenciones / datos

- Nombres e IPs siguen el esquema del proyecto: `prefijo-NN` ↔ `.120 + NN`
  (`SMRD-00` = `10.0.32.120`, `IABD-20` = `10.0.72.140`). `-00` = equipo del profesor.
- La **fuente de verdad de las MACs es [`macs.csv`](../../macs.csv)** de la raíz.
  Estos scripts **duplican** las MACs a mano y pueden quedarse desfasados (pasó con
  `SMRD-16` en `ControlSMRD/EnciendeSMRD.sh`, corregido el 2026-10-16). Ante una
  discrepancia, manda `macs.csv`.
- Para usar la versión de GitHub en la VM: `cd /opt/IAC-IESMHP && git pull`.
