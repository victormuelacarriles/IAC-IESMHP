# CLAUDE.md — rol `compruebaUsuario`

Comprueba, en cada equipo del inventario, si **el usuario asignado puede entrar
por SSH**. No cambia nada en el equipo.

## Qué hace

1. Calcula el usuario del host (`set_fact`, en el controlador):
   - Inventario IABD (`usuario=CEGSIABD14`) → `CEGSIABD14@iesmhp.local`
     (dominio en `compruebaUsuario_dominio`).
   - Inventario SMRD (`ansible_user=SMRV08@iesmhp.local`) → ese mismo.
   El `ansible_user=root` del grupo no se usa.
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
  usa `sshpass`, que tiene que estar instalado. `-k` **no** sirve, porque el
  ssh no lo hace Ansible.

## Uso

```bash
cd /opt/IAC-IESMHP/Ubuntu/ansible/rolesUsuario
ansible-playbook -i EquiposSMRD-alumnos2627.ini rolesUsuario.yaml --tags compruebaUsuario
ansible-playbook -i equiposIABD-alumnos2627.ini rolesUsuario.yaml --tags compruebaUsuario -l IABD-05
```

## Variables (`defaults/main.yml`)

| Variable | Defecto | Para qué |
|----------|---------|----------|
| `compruebaUsuario_dominio` | `iesmhp.local` | Dominio que se añade a `usuario` |
| `compruebaUsuario_timeout` | `5` | `ConnectTimeout` del ssh (segundos) |
| `compruebaUsuario_password` | `""` | Contraseña (vacía = clave SSH) |
