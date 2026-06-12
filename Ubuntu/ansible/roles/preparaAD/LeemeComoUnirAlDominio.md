# Léeme — Cómo unir los equipos al dominio Active Directory (rol `preparaAD`)

Este documento explica **qué deja preparado el rol `preparaAD`**, cómo
comprobar si un equipo está unido al dominio y **cuál es el procedimiento
recomendado para automatizar la unión** cuando se decida dar el paso.

> Documentación técnica del rol (tareas, variables, issues): [`CLAUDE.md`](CLAUDE.md).
> Scripts de apoyo (cuenta delegada en el DC, vault, unión de un equipo): [`utilesAD/`](utilesAD/).
> Referencia oficial: [Ubuntu Server docs — SSSD with Active Directory](https://ubuntu.com/server/docs/how-to/sssd/with-active-directory/).

---

## 1. Qué hace el rol (y qué NO hace)

El rol deja el equipo **preconfigurado** para unirse a un dominio AD.
**Por defecto NO une al dominio** (`preparaad_unir: false`): la unión exige
credenciales y se lanza bajo demanda (sección 4).

### Prerequisitos que implanta en cada equipo

1. **Paquetes del stack de unión**: `realmd` (orquestador `realm
   discover/join/leave`), `sssd-ad` + `sssd-tools` + `libnss-sss` +
   `libpam-sss` (identidad y autenticación contra AD), `adcli` (herramienta
   de unión), `krb5-user` (`kinit`/`klist` para diagnóstico), `packagekit` y
   `bind9-dnsutils` (`dig`/`nsupdate`).
2. **`pam_mkhomedir`** (`pam-auth-update --enable mkhomedir`): en Ubuntu no
   viene activo y, sin él, los usuarios del dominio entrarían **sin carpeta
   personal**. Con esto el home se crea solo en el primer login.
3. **Reloj**: Kerberos exige menos de **5 minutos** de desfase con el
   controlador de dominio. La variable opcional `preparaad_ntp` apunta
   `systemd-timesyncd` al DC; el resumen del rol siempre informa de si hay
   sincronización NTP.
4. **Hostname**: aviso si supera **15 caracteres** (límite NetBIOS de la
   cuenta de equipo en AD). Los `IABD-NN`/`SMRD-NN` van sobrados.
5. **`/etc/krb5.conf`** con el realm por defecto (`IESMHP.LOCAL`) y
   localización de los KDC por DNS (`preparaad_dominio: iesmhp.local` en
   `defaults/main.yml`).

### Detalles de diseño importantes

- El snippet de configuración SSSD (`/etc/sssd/conf.d/10-iac-ad.conf`) solo
  se despliega **después** de la unión. Antes dejaría `sssd.service` como
  unidad fallida en cada arranque (y saltaría la sección 8 de
  `4-Comprobaciones.sh`).
- El módulo `systemd` de Ansible solo se usa con `state: restarted` — nunca
  `enabled:`/`daemon_reload:`, que cuelgan el primer arranque (bugs
  2026-05-17 del rol `rdp`).

---

## 2. Cómo saber si un equipo está unido

El rol lo comprueba en cada pase y lo imprime en su **resumen final** (sale
en el log del play y en `3-SetupPrimerInicio.sh.log`). A mano:

```bash
realm list --name-only     # vacío = NO unido; nombre del dominio = unido
realm list                 # detalle completo (proveedor sssd, políticas…)

# Con el equipo unido, pruebas de fuego:
getent passwd alguien@iesmhp.local   # ¿se resuelve un usuario del dominio?
kinit alguien@IESMHP.LOCAL           # ¿Kerberos da ticket? (realm en MAYÚSCULAS)
su - alguien                         # ¿login real? (crea el home vía mkhomedir)
```

Si el equipo **no** está unido y hay dominio definido, el rol ejecuta además
`realm discover` (informativo, no falla el play): detecta el problema más
habitual, que el **DNS del aula no resuelva el dominio** (ver sección 5).

---

## 3. Unión de UN equipo: `utilesAD/3-UneAlDominio.sh`

En el equipo a unir (como root, asume que la cuenta `svc-union-linux` ya
existe — sección 4, paso 1):

```bash
sudo /opt/IAC-IESMHP/Ubuntu/ansible/roles/preparaAD/utilesAD/3-UneAlDominio.sh
```

El script: (1) lanza el rol preparaAD (prerequisitos); (2) si ya está unido,
termina sin tocar nada; (3) si no, comprueba el DNS (`realm discover`),
**pregunta la contraseña de `svc-union-linux`** y une con `realm join` a la
OU delegada; (4) verifica y relanza el rol para desplegar el snippet SSSD.

<details><summary>Equivalente a mano (para entender qué hace)</summary>

```bash
realm discover iesmhp.local                    # ¿se ve el dominio por DNS?
sudo realm join --user=svc-union-linux \
  --computer-ou='OU=EquiposLinuxAutomatizados,DC=iesmhp,DC=local' \
  iesmhp.local                                 # pide la contraseña
realm list                                     # verificación
# y reaplicar el rol para el snippet SSSD del IES:
cd /opt/IAC-IESMHP/Ubuntu/ansible
ansible-playbook -i localhost, --connection=local roles.yaml --tags preparaad
```
</details>

---

## 4. Unión automatizada (recomendada): cuenta delegada + vault + pase de aula

La cuestión clave es **cómo manejar el usuario del dominio con permisos de
unión** sin que su contraseña acabe en claro en el repo o en la ISO.

Los pasos 1 y 2 están **scriptados en [`utilesAD/`](utilesAD/)**.

### Paso 1 — En un controlador de dominio: `1-CreaUsuarioUnionAD.ps1`

```powershell
.\1-CreaUsuarioUnionAD.ps1     # solo pregunta la contraseña a establecer
```

Idempotente; con permisos de administrador del dominio: crea (si faltan) la
OU `EquiposLinuxAutomatizados` y la cuenta `svc-union-linux` **sin privilegios
de administrador**, establece/resetea su contraseña y le delega sobre esa OU
los permisos **mínimos** para unir equipos (crear objetos equipo + reset
password/escrituras validadas sobre los equipos de la OU; sin borrado). Si la
contraseña se filtrara, el daño se limita a dar de alta equipos en esa OU.
Auditoría: `dsacls "OU=EquiposLinuxAutomatizados,DC=iesmhp,DC=local"`.

### Paso 2 — En el equipo del profesor: `2-CreaVault.sh`

```bash
/opt/IAC-IESMHP/Ubuntu/ansible/roles/preparaAD/utilesAD/2-CreaVault.sh
```

Pide la contraseña de `svc-union-linux` (la del paso 1) y luego la contraseña
**del vault** (la pide `ansible-vault`; es la que protege el fichero y la que
se teclea en cada pase con `--ask-vault-pass` — no confundir ambas). Genera
`Ubuntu/ansible/vault/preparaAD-vault.yml`, cifrado AES256 y **committeable**.

> ⚠️ El vault va en `vault/`, **NO en `group_vars/`**: ahí Ansible lo
> auto-cargaría en TODOS los pases y cualquier ejecución sin
> `--ask-vault-pass` (incluido el primer arranque desatendido) fallaría.

### Paso 3 — Pase de aula (desde el equipo del profesor)

```bash
cd /opt/IAC-IESMHP/Ubuntu/ansible
ansible-playbook -i equiposIABD.ini roles.yaml --tags preparaad \
  -e preparaad_unir=true -e @vault/preparaAD-vault.yml --ask-vault-pass
```

El rol une solo los equipos que no lo estén (idempotente) a la OU delegada,
despliega el snippet SSSD y falla ruidosamente si alguno no queda unido.

El rol une solo los equipos que no lo estén ya (idempotente), despliega el
snippet SSSD y **falla ruidosamente** si algún equipo no queda unido.

### ¿Por qué NO unir en el primer arranque (`3-SetupPrimerInicio`)?

- La contraseña del vault no está disponible en un equipo recién instalado
  (habría que embeberla en claro en la ISO o el repo).
- La unión debe hacerse con el **hostname definitivo**; si `NombreIP.sh`
  fallara, se crearía una cuenta de equipo basura en el dominio.
- Un join fallido (DNS del aula, DC caído) **no debe arriesgar el
  despliegue**. El primer arranque deja solo los prerequisitos: rápido, sin
  credenciales y sin necesitar ver al DC.

### Alternativa más segura (plan B): one-time passwords

Si no se quiere ninguna credencial circulando: pre-crear las cuentas de
equipo desde un equipo de confianza con
`adcli preset-computer --domain DOMINIO --one-time-password XXX IABD-01 …`
y unir cada equipo con `realm join --one-time-password=XXX DOMINIO`. La OTP
solo vale para ese alta y ninguna cuenta de usuario viaja a los clientes.
Más segura pero más laboriosa (una OTP por hostname).

---

## 5. Requisito externo imprescindible: DNS

La unión y el `realm discover` exigen que el equipo **resuelva el dominio**
(registros SRV `_ldap._tcp.dc._msdcs.iesmhp.local`): el DNS que reparte el
DHCP del aula debe ser el del dominio o reenviar a él. Si `realm discover`
dice *"No such realm"* con el dominio bien escrito, el problema es el DNS
del aula, no el rol. Diagnóstico:

```bash
resolvectl status                       # ¿qué DNS está usando el equipo?
dig -t SRV _ldap._tcp.iesmhp.local      # ¿se resuelven los SRV del dominio?
```

---

## 6. Qué falta para activarlo de verdad

El dominio (`iesmhp.local`) y la OU (`EquiposLinuxAutomatizados`) ya están
fijados en [`defaults/main.yml`](defaults/main.yml). Queda:

1. **Crear la cuenta delegada**: ejecutar
   [`utilesAD/1-CreaUsuarioUnionAD.ps1`](utilesAD/1-CreaUsuarioUnionAD.ps1)
   en un controlador de dominio (sección 4, paso 1).
2. **Crear el vault**: [`utilesAD/2-CreaVault.sh`](utilesAD/2-CreaVault.sh)
   en el equipo del profesor (sección 4, paso 2) — solo para pases de aula;
   para un equipo suelto basta `3-UneAlDominio.sh`, que pregunta la
   contraseña.
3. **Verificar el DNS de las aulas** (sección 5).
4. Opcional: `preparaad_ntp` apuntando al DC.

Tras la primera unión real, revisar `ad_gpo_access_control` (el rol lo deja
en `permissive` para evitar el bloqueo típico de logins cuando las GPO no
contemplan Linux; endurecer a `enforcing` cuando estén revisadas).
