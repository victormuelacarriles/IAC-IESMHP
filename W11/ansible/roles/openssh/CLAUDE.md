# Rol `openssh`

## Qué hace
Deja el **servidor OpenSSH de Windows** instalado y configurado de forma
idempotente, reproduciendo el procedimiento manual de
[`W11/Utiles/Openssh/ProcedimientoOpenss.txt`](../../../Utiles/Openssh/ProcedimientoOpenss.txt):

1. Instala las capacidades `OpenSSH.Client` y `OpenSSH.Server` (solo si faltan).
2. Servicio `sshd` en modo **automático** y arrancado (+ `ssh-agent`).
3. Regla de **firewall** `OpenSSH-Server-In-TCP` (TCP 22 entrante).
4. **PowerShell como shell por defecto** (`HKLM:\SOFTWARE\OpenSSH\DefaultShell`).
5. Descarga `Autorizados.txt` del repo y añade las claves que falten a
   `%ProgramData%\ssh\administrators_authorized_keys`, arreglando los **permisos**
   con `icacls` (sin herencia, solo `Administrators` y `SYSTEM`).

## Estructura
- `tasks/main.yml`
- `defaults/main.yml` → `openssh_autorizados_url` (raw de `Autorizados.txt` en GitHub).

## Notas
- **Importante**: `administrators_authorized_keys` aplica a *todos* los miembros del
  grupo Administradores; por eso la conexión Ansible funciona con cualquier cuenta
  admin. Si los permisos del fichero no son estrictos, `sshd` lo ignora en silencio
  → el paso `icacls` es imprescindible.
- Este rol es la "gallina y el huevo": para la primera conexión, el SSH ya debe
  estar montado a mano (el `ProcedimientoOpenss.txt`). A partir de ahí, Ansible lo
  mantiene (claves nuevas, servicio, firewall).
