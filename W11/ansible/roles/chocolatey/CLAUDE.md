# Rol `chocolatey`

## Qué hace
Deja **Chocolatey** instalado y configurado en el equipo. Es el **primer rol** del
playbook porque casi todos los demás instalan software con `win_chocolatey`.

1. Comprueba si existe `C:\ProgramData\chocolatey\bin\choco.exe`.
2. Si no está, lo instala con el script oficial (`community.chocolatey.org/install.ps1`),
   forzando TLS 1.2 (`SecurityProtocol -bor 3072`).
3. Configura el **proxy del aula** según `iac_aula` (variable que fija `roles.yaml`
   en `pre_tasks` a partir del 3er octeto de la IP):
   - `IABD` (`10.0.72.x`) → `http://10.0.72.140:3128`
   - `SMRD` (`10.0.32.x`) → `http://10.0.32.119:3128`
   - cualquier otra red → se **quita** el proxy (acceso directo).

> Mismos proxys que usa el Ubuntu (`3-SetupPrimerInicio.sh`).

## Estructura
- `tasks/main.yml` — sin `defaults/`.

## Notas
- `win_chocolatey` sabe autoinstalar Choco, pero lo hacemos explícito para poder
  fijar el proxy **antes** de la primera descarga de paquetes.
- Si añades un aula nueva, actualiza la condición del proxy aquí y la detección
  de `iac_aula` en `roles.yaml`.
