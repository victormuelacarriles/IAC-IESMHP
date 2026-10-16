# Cambiar la contraseña de `usuario` en todo el aula (Ansible ad-hoc)

Cambia de golpe la contraseña del usuario local `usuario` en todos los equipos de un
inventario, usando `chpasswd` por SSH. No necesita playbook ni dependencias extra.

El inventario ya conecta como `root` (`ansible_user=root` en `[all:vars]`), así que
no hace falta `become`.

## Comando (SMRD)

```bash
cd /opt/IAC-IESMHP/Ubuntu/ansible/
read -s -p "Nueva clave: " PW; echo
ansible SMRD -i equiposSMRD.ini -f 20 -m ansible.builtin.shell \
  -a "echo 'usuario:$PW' | chpasswd"
unset PW
```

- `read -s` pide la clave sin mostrarla y sin que quede en el historial de bash.
- `-f 20` lanza todos los equipos a la vez (por defecto Ansible va de 5 en 5).
- La clave pasa en claro por la línea de comandos remota durante un instante. Para
  el aula es aceptable; si no, usa el módulo `ansible.builtin.user` con
  `password_hash('sha512')`.
- Evita usar comillas simples (`'`) en la clave: rompen el `echo`.

Para el aula IABD, cambia el grupo y el inventario:
`ansible IABD -i equiposIABD.ini ...` (comprueba el nombre del grupo en el `.ini`).

## Variantes útiles

| Qué | Cómo |
|-----|------|
| Comprobar antes qué equipos responden | `ansible SMRD -i equiposSMRD.ini -f 20 -m ping` |
| Excluir el equipo del profesor | añade `--limit 'SMRD:!SMRD-00'` |
| Solo algunos equipos | añade `--limit SMRD-03,SMRD-05` |
| Obligar a cambiarla en el siguiente login | `ansible SMRD -i equiposSMRD.ini -f 20 -m shell -a "chage -d 0 usuario"` |

Los equipos apagados salen como `UNREACHABLE` y no afectan al resto. Al encenderlos,
repite el comando solo para ellos con `--limit`.
