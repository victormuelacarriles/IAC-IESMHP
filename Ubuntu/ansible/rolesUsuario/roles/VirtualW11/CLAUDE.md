# CLAUDE.md — rol `VirtualW11`

Copia la **máquina virtual Windows 11 de plantilla** (VMware) desde el NAS al
perfil del usuario y la añade a su **VMware Workstation**. Es la base: la
configuración de la máquina se irá añadiendo poco a poco a este rol.

- Plantilla: `/mnt/nasDepInfo/PruebaRapidosX3/SMRV/VMWARE-Plantillas/Win11`
  (NFS del NAS, montado en cada equipo; ~15 GB: un `.vmx` + un `.vmdk`).
- Destino: `~/vmware/Win11-<usuario>` (p. ej. `~/vmware/Win11-SMRV08`).
  Se conservan los nombres de fichero de la plantilla
  (`Windows 11 25H2.vmx`…); solo cambian la carpeta y el nombre visible.

## Qué hace

1. **Usuario** (igual que `compruebaUsuario`): inventario IABD
   (`usuario=CEGSIABD14`) → `CEGSIABD14@iesmhp.local`; inventario SMRD
   (`ansible_user=SMRV08@iesmhp.local`) → ese mismo. El `<usuario>` de la
   carpeta es la parte antes de `@`. Si sale `root`, falla (no se copia a `/root`).
2. **Como el usuario**: si Ansible entra como `root` (IABD), las tareas van con
   `become_user: <usuario>`; si entra como el usuario (SMRD), directamente. Así
   todo queda a su nombre.
3. Comprueba que existe su **HOME** (si no, no ha iniciado sesión nunca en el
   equipo → falla con ese motivo) y que la **plantilla** está accesible (un
   único `.vmx`; si no, ¿NAS montado?).
4. Si la máquina **no existe**: comprueba el **espacio libre** (tamaño de la
   plantilla + `VirtualW11_margen_gb`) y copia con `rsync` a
   `~/vmware/Win11-<usuario>.copiando`, que se renombra al terminar. Permisos
   `700`/`600`. La copia va en segundo plano (`async`, hasta
   `VirtualW11_timeout_copia`) para que no se corte el SSH. Si se corta,
   al relanzar `rsync` sigue por donde iba.
   **Si ya existe, no se copia nunca** (no se pierde el trabajo del alumno).
5. **Ajustes del `.vmx`** (solo si la máquina no está encendida, es decir, sin
   `<vmx>.lck`; si lo está, avisa y no lo toca):
   - Primera vez (aún sin `uuid.action`): quita `uuid.bios`, `uuid.location`
     y la MAC generada → VMware crea unos propios al arrancarla.
   - `uuid.action = "create"`: VMware **no pregunta** «¿la has movido o
     copiado?» (la pregunta dejaría la máquina esperando un clic).
   - `displayName = "Win11-<usuario>"`.
6. **Biblioteca de VMware**: `files/inventario-vmware.sh` añade la máquina a
   `~/.vmware/inventory.vmls` (entrada `vmlistN` en la raíz), si no estaba ya.
   Si VMware está abierto avisa: al cerrarse reescribe ese fichero y podría
   perder la entrada (relanzar el rol).
7. Mensaje final por equipo: `COPIADA` / `YA EXISTÍA` y biblioteca
   `AÑADIDA` / `YA ESTABA`.

## Uso

```bash
cd /opt/IAC-IESMHP/Ubuntu/ansible/rolesUsuario
ansible-playbook -i EquiposSMRD-alumnos2627.ini rolesUsuario.yaml --tags VirtualW11
ansible-playbook -i equiposIABD-alumnos2627.ini rolesUsuario.yaml --tags VirtualW11 -l IABD-05
# Volver a empezar desde la plantilla (BORRA la máquina del alumno):
ansible-playbook -i EquiposSMRD-alumnos2627.ini rolesUsuario.yaml --tags VirtualW11 \
                 -l SMRD-04-SMRV24 -e VirtualW11_reemplazar=true
```

Con `--tags VirtualW11` no se ejecuta `compruebaUsuario`; sin tags, va primero
y los equipos en los que el usuario no entra se quedan fuera.

> Varios alumnos comparten equipo en SMRD: cada uno tiene su copia (~15 GB por
> alumno). `/home` es ZFS con dedup (`rpool/home`), así que las copias de la
> misma plantilla ocupan mucho menos en disco que la suma.

## Variables (`defaults/main.yml`)

| Variable | Defecto | Para qué |
|----------|---------|----------|
| `VirtualW11_origen` | `/mnt/nasDepInfo/.../VMWARE-Plantillas/Win11` | Carpeta de la plantilla |
| `VirtualW11_carpeta` | `vmware` | Carpeta de las VMs dentro del HOME |
| `VirtualW11_prefijo` | `Win11` | Nombre: `<prefijo>-<usuario>` |
| `VirtualW11_dominio` | `iesmhp.local` | Dominio que se añade a `usuario` |
| `VirtualW11_margen_gb` | `5` | GB libres que deben quedar tras copiar |
| `VirtualW11_timeout_copia` | `7200` | Segundos máximos de la copia |
| `VirtualW11_reemplazar` | `false` | `true` = borra y vuelve a copiar |

## Pruebas

- 2026-10-22, en local con una plantilla pequeña y un HOME de prueba: copia,
  2ª ejecución sin cambios, UUID nuevo de VMware respetado, máquina encendida
  (`.lck`), sin espacio, plantilla inexistente y `reemplazar`. Correcto.
- **Pendiente**: probar contra un equipo del aula (copia real de 15 GB,
  `become_user` desde root en IABD) y abrir VMware para ver que la máquina
  aparece y arranca sin preguntas.

## Pendiente / ideas

- Configuración de la máquina (se irá indicando).
- Snapshot inicial tras la copia, para que el alumno pueda volver atrás.
