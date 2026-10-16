# CLAUDE.md — `ControlSMRD/`

Control del **aula SMRD** (distancia, red `10.0.32.x`, equipos `SMRD-00` …
`SMRD-18`, IP = `10.0.32.120 + NN`). Combina scripts Bash y **Ansible ad-hoc**
con un inventario propio. Contexto general en [`../CLAUDE.md`](../CLAUDE.md).

## Ficheros

| Fichero | Qué hace |
|---------|----------|
| `equiposSMRD.ini` | Inventario Ansible: grupo `docente` (`SMRD-00`) y `alumnos` (`SMRD-01`…`18`), `ansible_user=root`, `ansible_python_interpreter=/usr/bin/python3.12`. Comentarios con averías conocidas (SMRD-07 disco NVMe, SMRD-16 USB delantero). |
| `EnciendeSMRD.sh` | `wakeonlan` a las 19 MACs del aula (array asociativo). |
| `ApagaAulaSMRD.sh` | `ansible all -i equiposSMRD.ini -a "poweroff" -u root`. Incluye, comentado, el one-liner de "apagar solo si no hay conexiones". |
| `ApagaEquiposSinConexion.sh` | Recorre `10.0.32.120..138`; si responde al ping, entra por SSH y hace `poweroff` **solo si no hay conexiones SSH (22) ni RDP (3389) establecidas**, ignorando las que vienen de `10.0.32.119` (servidor/proxy del aula). Pensado para **cron** en `10.0.32.119` (01, 03, 05, 07, 21 y 23 h). |
| `EjemplosAnsibleSMRD.txt.sh` | Chuleta de comandos Ansible ad-hoc (ping, reboot, shutdown, copy, comandos, instalar paquetes). **No es para ejecutarlo entero.** |
| `actualizaDesdeGit.sh` | Clona el repo de GitHub en un directorio temporal (`mktemp`). Esbozo incompleto: no hace nada más tras clonar. |

## Notas

- **Cron de `10.0.32.119`**: la línea correcta (documentada al final de
  `ApagaEquiposSinConexion.sh`) es
  `0 1,3,5,7,21,23 * * * bash /opt/IAC-IESMHP/Ubuntu/utilesUbuntuControl/ControlSMRD/ApagaEquiposSinConexion.sh`.
  Antes apuntaba a `Mint/ControlSMRD/` (ruta que ya no existe tras el traslado).
  Se lanza con `bash` porque el fichero está en git **sin bit de ejecución**.
  **El `crontab` real de `10.0.32.119` hay que cambiarlo a mano** (`crontab -e`).
- **MAC de `SMRD-16`** corregida el 2026-10-16 en `EnciendeSMRD.sh`
  (`bc:fc:e7:05:73:41` → `bc:fc:e7:04:30:c0`, la de `macs.csv`). Manda `macs.csv`.
- **WoL por broadcast dirigido**: `EnciendeSMRD.sh` define `BROADCAST=10.0.32.255`
  y usa `wakeonlan -i "$BROADCAST" <MAC>`; funciona desde otra subred si el router
  permite el broadcast dirigido hacia `10.0.32.0/24`.
- Salidas descartadas con `/dev/null` (antes `>null` y `UserKnownHostsFile=NULL`,
  herencia de Windows que creaba ficheros `null`/`NULL`).
- Los scripts Ansible se lanzan **desde esta carpeta** (usan `-i equiposSMRD.ini`
  relativo). Limitar a equipos concretos con `--limit=SMRD-00,SMRD-01`.
- Para instalar software de forma estable, mejor un rol en
  [`Ubuntu/ansible/`](../../ansible/CLAUDE.md) que comandos ad-hoc.
