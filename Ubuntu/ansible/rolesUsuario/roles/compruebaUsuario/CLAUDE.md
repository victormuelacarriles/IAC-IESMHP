# CLAUDE.md — rol `compruebaUsuario`

Comprueba, en cada equipo del inventario, si **el usuario asignado puede entrar
por SSH**. No cambia nada en el equipo.

## Qué hace

1. El usuario es el `ansible_user` de cada equipo en el inventario
   (`ansible_user=SMRV08@iesmhp.local`; el mismo formato en SMRD e IABD desde
   2026-10-23), o el usuario actual en local.
2. **Desde el controlador** (`delegate_to: localhost`) lanza
   `ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -l <usuario> <ip> id -un`
   y lee el código de salida y el error:
   - `rc=0` → `OK`.
   - `Permission denied` → `NO ACCEDE`.
   - Otro error (timeout, `No route to host`, `Connection refused`) → `APAGADO`.
3. Saca un resumen, una línea por host.
4. Al final, tarea `fail` para los que no son `OK`: en el `PLAY RECAP` salen como
   **`failed=1`** (no como `ignored`), con el motivo en el mensaje.

> **Por qué el ssh va desde el controlador y no con la conexión de Ansible**
> (cambio 2026-10-22): con la conexión normal, un login rechazado es
> `UNREACHABLE` y, para seguir, hacía falta `ignore_unreachable`; el recap
> quedaba con `failed=0 ignored=1` y parecía que todo iba bien.

`NO ACCEDE` no distingue entre "el usuario no existe" y "existe pero no tiene la
clave pública / contraseña": en los dos casos SSH rechaza el login.

## Credenciales

- **Por defecto, clave SSH** del que lanza el playbook (copiada antes con
  `ssh-copy-id SMRV05@iesmhp.local@10.0.32.160`). `BatchMode=yes`: nunca se
  queda preguntando.
- **Con contraseña**: `-e compruebaUsuario_password=...` (o desde un vault);
  usa `sshpass`, que tiene que estar instalado. El `-k` de `ansible-playbook`
  **no** sirve, porque el ssh no lo hace Ansible; el `-k` de
  `compruebaUsuario.sh` sí (pide la contraseña y la pasa en esa variable).

## Uso

Lo más cómodo, con el lanzador `compruebaUsuario.sh` (2026-10-26), mismo
esquema que `VirtualW11.sh` / `AODappsflatpack.sh`:

```bash
cd /opt/IAC-IESMHP/Ubuntu/ansible/rolesUsuario/roles/compruebaUsuario
bash compruebaUsuario.sh                     # en local, el usuario actual
bash compruebaUsuario.sh SMRD                # todos los alumnos de SMRD
bash compruebaUsuario.sh SMRD AOD            # solo el módulo AOD (o --modulo AOD,SOR)
bash compruebaUsuario.sh IABD -l IABD-05
bash compruebaUsuario.sh SMRD --breve        # en pantalla solo el resumen
bash compruebaUsuario.sh SMRD -k             # con contraseña (la pide, sin eco)
./compruebaUsuario.sh --ayuda
```

- Opciones: `SMRD`/`IABD`/`<alumnos.ini>`, módulo suelto o `--modulo`, `-l`,
  `--forks N` (20 por defecto, `FORKS=N`), `--timeout S`, `--breve`. El resto
  de opciones que empiezan por `-` van a `ansible-playbook`.
- **Contraseña**: `-k` la pide por el terminal (única pregunta, y solo si se
  pide); sin preguntar con `COMPRUEBA_PASSWORD=...` o `--password-fichero F`.
  Nunca va en la línea de órdenes: se pasa con `-e @<json temporal 0600>`, que
  se borra al salir.
- **Resumen final**: una línea por alumno (primero los que fallan, con el
  motivo), totales por estado, **equipos físicos apagados** (por IP: varios
  alumnos comparten equipo) y el **`-l` de los OK y de los que fallan**, para
  pegarlo en `VirtualW11.sh` / `AODappsflatpack.sh`.
- Log: `/var/log/IAC-IESMHP/compruebaUsuario.log` (o
  `~/.local/state/IAC-IESMHP/`), con cabecera `=====` por ejecución. Código de
  salida 0 solo si todos están OK (2 si alguno falla).
- Usa su playbook propio `compruebaUsuario.yaml`: incluye el rol, recoge su
  `fail` con `rescue` y un segundo play saca
  `COMPRUEBA|alumno|ip|usuario|estado|motivo` por alumno (lo lee el `.sh`) y
  marca como `failed` a los que no son OK. Sin `ping` previo (el rol no usa la
  conexión de Ansible).

También dentro del playbook general:

```bash
cd /opt/IAC-IESMHP/Ubuntu/ansible/rolesUsuario
ansible-playbook -i EquiposSMRD-alumnos2627.ini rolesUsuario.yaml --tags compruebaUsuario
ansible-playbook -i equiposIABD-alumnos2627.ini rolesUsuario.yaml --tags compruebaUsuario -l IABD-05
```

> **2026-10-26**: con contraseña, `sshpass` sale con `rc=5` y sin mensaje si
> la contraseña es mala; antes salía `APAGADO`, ahora `NO ACCEDE (sshpass:
> contraseña incorrecta)`. Y la tarea `Resultado` ya no rompe si el resultado
> del ssh llega sin `stderr` (pasó una vez en pruebas).

## Variables (`defaults/main.yml`)

| Variable | Defecto | Para qué |
|----------|---------|----------|
| `compruebaUsuario_timeout` | `5` | `ConnectTimeout` del ssh (segundos) |
| `compruebaUsuario_password` | `""` | Contraseña (vacía = clave SSH) |
