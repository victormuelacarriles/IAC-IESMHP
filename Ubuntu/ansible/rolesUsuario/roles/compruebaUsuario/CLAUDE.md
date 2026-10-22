# CLAUDE.md — rol `compruebaUsuario`

Comprueba, en cada equipo del inventario, si **el usuario asignado puede entrar
por SSH**. No cambia nada en el equipo.

## Qué hace

1. Calcula el usuario del host (`set_fact`, en el controlador):
   - Inventario IABD (`usuario=CEGSIABD14`) → `CEGSIABD14@iesmhp.local`
     (dominio en `compruebaUsuario_dominio`).
   - Inventario SMRD (`ansible_user=SMRV08@iesmhp.local`) → ese mismo.
2. Mira si el puerto 22 del equipo está abierto (`wait_for` desde el
   controlador, 5 s).
3. Si lo está, entra como ese usuario y ejecuta `id -un` con `raw` (sin Python
   ni `~/.ansible/tmp`, por si el usuario de dominio aún no tiene `$HOME`).
   Las tareas sustituyen `ansible_user` del inventario (aunque el grupo tenga
   `ansible_user=root`) y usan `StrictHostKeyChecking=accept-new` para no
   quedarse preguntando.
4. Saca un resumen, una línea por host: `OK`, `NO ACCEDE` o `APAGADO`.

`NO ACCEDE` no distingue entre "el usuario no existe" y "existe pero no tiene la
clave pública / contraseña": en los dos casos SSH rechaza el login.

## Credenciales

- **Por defecto, clave SSH** del que lanza el playbook (copiada antes con
  `ssh-copy-id SMRV05@iesmhp.local@10.0.32.160`).
- **Con contraseña**: añadir `-k` (pide una sola contraseña para todos; necesita
  `sshpass`).

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
| `compruebaUsuario_timeout` | `5` | Segundos de espera al puerto 22 |
