# Rol `chocolatey`

## Qué hace
Deja **Chocolatey** instalado y configurado en el equipo. Es el **primer rol** del
playbook porque casi todos los demás instalan software con `win_chocolatey`.

1. Comprueba si existe `C:\ProgramData\chocolatey\bin\choco.exe`.
2. Si no está, **descarga** `community.chocolatey.org/install.ps1` a `C:\Windows\Temp`
   (con `win_get_url`, usando el proxy del aula si toca) y **ejecuta el fichero**,
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
- **No se usa el "download cradle" `iex (New-Object Net.WebClient).DownloadString(...)`**:
  Microsoft Defender lo detecta como `Trojan:Win32/Goptaju.D` (firma AMSI sobre la
  línea de comandos que genera `win_shell` como `-encodedcommand`), mata el proceso y
  la API devuelve `CreateProcessW() Access denied (Win32ErrorCode 5)`. Síntoma típico:
  `Gathering Facts`/`win_stat`/`win_ping` van bien (no lanzan ese patrón) pero la tarea
  de instalar Choco falla con *Access denied*. **No es UAC ni permisos** (el token SSH
  es de integridad alta) ni ASR/CFA; es la firma AMSI. Como Tamper Protection suele
  estar activo, no se puede bajar Defender por script: la solución es bajar `install.ps1`
  a fichero y ejecutarlo (no matchea la firma). Ver evento Defender 1116/1117.
- Si añades un aula nueva, actualiza la condición del proxy aquí (también en la tarea
  de descarga `win_get_url`) y la detección de `iac_aula` en `roles.yaml`.
