# CLAUDE.md — `ControlIABD/`

Scripts Bash para encender y apagar el **aula IABD** (CEIABD, red `10.0.72.x`,
equipos `IABD-00` … `IABD-20`, IP = `10.0.72.120 + NN`). Se lanzan a mano desde
la VM de control. Contexto general en [`../CLAUDE.md`](../CLAUDE.md).

## Ficheros

| Fichero | Qué hace |
|---------|----------|
| `EnciendeAula.sh` | Array asociativo `nombre → MAC` de los 21 equipos (`IABD-00`…`IABD-20`) y `wakeonlan` a cada uno. |
| `EnciendeProfe.sh` | Solo `IABD-00` (profesor). Luego espera 60 s; la llamada posterior para arrancar una VM Windows (`SBD-ArrancaW11victor.sh`) está **comentada**. |
| `EnciendeProfeSinWin.sh` | Igual que el anterior pero sin la espera ni la parte Windows. |
| `EnciendeVictor.sh` | Enciende solo `IABD-01` (+ espera 60 s, parte Windows comentada). Equipo de pruebas personal. |
| `ApagaAula.sh` | `ssh root@10.0.72.120..140 poweroff` en paralelo (`&`), sin comprobar host key. |
| `cosas.txt` | Chuleta: `apt upgrade` no interactivo y listar usuarios `ciabd*`. No es un script. |

## Notas

- **WoL por broadcast dirigido** (desde 2026-10-16): los `Enciende*.sh` definen
  `BROADCAST=10.0.72.255` y llaman a `wakeonlan -i "$BROADCAST" <MAC>`, así que
  funcionan aunque la VM de control esté en otra subred, **siempre que el router
  permita el broadcast dirigido** hacia `10.0.72.0/24`. Antes iban a
  `255.255.255.255` y solo funcionaban desde la misma red.
- Salidas descartadas con `/dev/null` (antes `>null` y `UserKnownHostsFile=NUL`/`NULL`,
  herencia de Windows que en Linux creaba ficheros `null`/`NUL`/`NULL`).
- Llevan `#!/bin/bash` (el `declare -A` no funciona en `sh`/`dash`). En git están
  **sin bit de ejecución**: lanzarlos con `bash script.sh`.
- Las MACs están duplicadas a mano; la fuente de verdad es [`macs.csv`](../../../macs.csv)
  (revisadas el 2026-10-16: todas coinciden).
- Comentarios del tipo "Explicación (bing chat)" son solo didácticos.
