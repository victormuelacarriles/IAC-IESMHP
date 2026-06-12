# Rol `preparaAD`

## Qué hace
Deja el equipo **preconfigurado para unirse a un dominio Active Directory**
(Ubuntu Desktop 26.04) y **comprueba si ya está unido**. Por defecto **NO une
al dominio** (`preparaad_unir: false`): la unión exige credenciales delegadas
y se lanza bajo demanda (ver "Cómo unir el equipo").

Cumple el TODO `predominio` de `roles.yaml`. Sigue la doc oficial de Ubuntu:
<https://ubuntu.com/server/docs/how-to/sssd/with-active-directory/>.

> Guía operativa para humanos (qué hace el rol, cómo comprobar la unión y
> procedimiento recomendado de unión): [`LeemeComoUnirAlDominio.md`](LeemeComoUnirAlDominio.md).

## Prerequisitos que implanta (tasks/main.yml)
1. **Stack de unión** (`preparaad_paquetes`): `realmd` (orquestador
   discover/join), `sssd-ad` + `sssd-tools` + `libnss-sss` + `libpam-sss`
   (identidad/autenticación contra AD), `adcli` (herramienta de unión),
   `krb5-user` (kinit/klist), `packagekit` (lo invoca realmd; preinstalado =
   unión más rápida y sin red a archive), `bind9-dnsutils` (dig/nsupdate).
2. **`pam_mkhomedir`** vía `pam-auth-update --enable mkhomedir`: crea el home
   en el primer login de un usuario del dominio (en Ubuntu no viene activo, a
   diferencia de RHEL). Idempotente: solo corre si `pam_mkhomedir.so` no está
   ya en `/etc/pam.d/common-session`.
3. **Reloj**: Kerberos exige desfase < 5 min con el DC. Si `preparaad_ntp` se
   define (normalmente el propio DC), se escribe
   `/etc/systemd/timesyncd.conf.d/50-iac-ad.conf` y se reinicia timesyncd.
   Siempre se lee `timedatectl … NTPSynchronized` para el resumen.
4. **Hostname**: aviso si supera 15 caracteres (límite NetBIOS de la cuenta
   de equipo en AD). Los `IABD-NN`/`SMRD-NN` van sobrados.
5. **`/etc/krb5.conf`** (solo si se conoce el dominio): realm por defecto en
   mayúsculas, KDC por DNS (SRV), `rdns = false`.
6. **Comprobación de unión**: `realm list --name-only` (fuente de verdad de
   realmd/SSSD); si no está unido y hay dominio, `realm discover` informa de
   si el dominio se resuelve por DNS desde el aula (**no falla** el play).
7. **Unión opcional** (`preparaad_unir=true` + credenciales): `realm join
   --unattended` con la contraseña por stdin (`no_log`), `--computer-ou` si se
   define, y **post-condición ruidosa**: si `realm list` sigue vacío, el play
   falla.
8. **Snippet `/etc/sssd/conf.d/10-iac-ad.conf`** (solo con el equipo **ya
   unido**): `use_fully_qualified_names=False` (login `pepe`, no
   `pepe@dominio`), `fallback_homedir=/home/%u`, `default_shell=/bin/bash`,
   `cache_credentials=True` (login offline) y
   `ad_gpo_access_control=permissive` (el default `enforcing` de SSSD bloquea
   TODOS los logins si las GPO "Allow log on locally" no contemplan Linux).
   Permisos 0600 obligatorios. Reinicia sssd solo si el snippet cambió.
9. **Resumen** (`debug`): unido o no, dominio configurado, dominio visible
   por DNS, reloj sincronizado. Sale en el log de `3-SetupPrimerInicio.sh`.

### ¿Por qué el snippet SOLO tras la unión?
`sssd.service` en Debian/Ubuntu lleva `ConditionPathExists=/etc/sssd/sssd.conf`
y `ConditionDirectoryNotEmpty=/etc/sssd/conf.d/`. Antes de unir no existe
`sssd.conf` (lo escribe realmd al unir) → la unidad se **salta** limpiamente,
sin unidad fallida. Un snippet pre-unión llenaría `conf.d/` → sssd arrancaría
sin dominios → **unidad fallida en cada boot** (saltaría la sección 8 de
`4-Comprobaciones.sh`). Por eso el equipo queda "preparado" con `conf.d/`
vacío y el snippet se aplica en el mismo pase que une (o en re-pases sobre
equipos ya unidos).

## Variables (`defaults/`)
| Variable | Por defecto | Para qué |
|----------|-------------|----------|
| `preparaad_dominio` | `iesmhp.local` | Dominio AD (DNS, minúsculas). Vacío = solo prerequisitos genéricos |
| `preparaad_paquetes` | lista | Stack a instalar |
| `preparaad_ntp` | `""` | NTP del dominio (normalmente el DC). Vacío = default de Ubuntu |
| `preparaad_ou` | `OU=EquiposLinuxAutomatizados,DC=iesmhp,DC=local` | OU de las cuentas de equipo (`--computer-ou`). La crea y delega `utilesAD/1-CreaUsuarioUnionAD.ps1` — si se cambia aquí, re-ejecutar ese script |
| `preparaad_unir` | `false` | Intentar la unión en este pase |
| `preparaad_usuario_union` | `svc-union-linux` | Cuenta delegada de unión (la crea `utilesAD/1-CreaUsuarioUnionAD.ps1`) |
| `preparaad_password_union` | `""` | Su contraseña — **solo vía vault (`utilesAD/2-CreaVault.sh`) o `-e`** |
| `preparaad_fqn` | `false` | `use_fully_qualified_names` |
| `preparaad_fallback_homedir` | `/home/%u` | Home de usuarios del dominio |
| `preparaad_gpo` | `permissive` | `ad_gpo_access_control` (endurecer a `enforcing` con las GPO revisadas) |

## Scripts de apoyo (`utilesAD/`)
| Script | Dónde se ejecuta | Qué hace |
|--------|------------------|----------|
| `1-CreaUsuarioUnionAD.ps1` | Controlador de dominio (admin del dominio) | OU `EquiposLinuxAutomatizados` (si falta) + cuenta `svc-union-linux` (si falta; resetea contraseña si existe) + delegación mínima de unión sobre la OU (crear equipos, reset password, validated writes dNSHostName/SPN, property set Account Restrictions; **sin borrado**). Idempotente: comprueba ACE a ACE. Solo pregunta la contraseña. **Sin tildes a propósito** (PS 5.1 lee UTF-8 sin BOM como ANSI) |
| `2-CreaVault.sh` | Equipo del profesor | Crea `Ubuntu/ansible/vault/preparaAD-vault.yml` (AES256, committeable) con las credenciales de unión. Rechaza contraseñas con comilla simple (limitación del rol) |
| `3-UneAlDominio.sh` | El equipo a unir (root) | Rol preparaAD (prerequisitos) → si no unido: `realm discover` + pregunta contraseña + `realm join` a la OU → verifica → re-pase del rol (despliega el snippet SSSD) |

## Cómo unir el equipo (cuando se decida)

### Manual (un equipo, para probar)
```bash
realm discover iesmhp.local                    # ¿se ve el dominio? (DNS)
realm join --user=svc-union-linux \
  --computer-ou='OU=EquiposLinuxAutomatizados,DC=iesmhp,DC=local' \
  iesmhp.local                                 # pide la contraseña
realm list                                     # verificación
getent passwd alguien@iesmhp.local && su - alguien   # prueba de login
```
O directamente `sudo utilesAD/3-UneAlDominio.sh`, que hace todo esto y además
relanza el rol al final.

### Automatizado (recomendado): cuenta delegada + ansible-vault + pase de aula

Los tres pasos están **scriptados en [`utilesAD/`](utilesAD/)** (ver tabla más
abajo):

1. **En un controlador de dominio** (administrador del dominio, una vez):
   `utilesAD/1-CreaUsuarioUnionAD.ps1`. Crea (si faltan) la OU
   `EquiposLinuxAutomatizados` y la cuenta `svc-union-linux` sin privilegios,
   establece/resetea su contraseña (única pregunta del script) y delega sobre
   la OU los permisos **mínimos** de unión. Si la cuenta se filtrara, el daño
   se limita a dar de alta equipos en esa OU.
2. **En el equipo del profesor**: `utilesAD/2-CreaVault.sh` crea
   `Ubuntu/ansible/vault/preparaAD-vault.yml` cifrado (AES256, committeable)
   con `preparaad_usuario_union`/`preparaad_password_union`. Va en `vault/`,
   **NO en `group_vars/`**: ahí Ansible lo auto-cargaría y TODOS los pases
   (incluido el primer arranque desatendido) exigirían `--ask-vault-pass`.
3. **Pase de aula** (desde el equipo del profesor, NO en el primer arranque):
   ```bash
   ansible-playbook -i equiposIABD.ini roles.yaml --tags preparaad \
     -e preparaad_unir=true -e @vault/preparaAD-vault.yml --ask-vault-pass
   ```

Para un **equipo suelto** sin vault: `sudo utilesAD/3-UneAlDominio.sh` —
lanza el rol (prerequisitos), comprueba si ya está unido, pregunta la
contraseña de `svc-union-linux`, une con `realm join` a la OU delegada y
relanza el rol para desplegar el snippet SSSD.

### ¿Por qué NO unir en el primer arranque (`3-SetupPrimerInicio`)?
- La contraseña del vault no está disponible en un equipo recién instalado
  (habría que embeberla en la ISO/repo = en claro).
- La unión debe hacerse con el **hostname definitivo**; aunque `NombreIP.sh`
  corre antes que Ansible, si fallara la resolución MAC→nombre se crearía una
  cuenta de equipo basura (`ubuntu`) en el dominio.
- Un join fallido (DNS de aula, DC caído) no debe arriesgar el primer
  arranque. El rol en el primer arranque solo instala prerequisitos (rápido,
  sin credenciales, sin red al DC).

### Alternativa más segura (si no se quiere ninguna credencial en juego)
Pre-crear las cuentas de equipo con contraseña de un solo uso desde un equipo
de confianza: `adcli preset-computer --domain DOMINIO --one-time-password XXX
IABD-01 IABD-02 …` y unir cada equipo con
`realm join --one-time-password=XXX DOMINIO` (la OTP solo vale para ese alta;
ninguna cuenta de usuario viaja a los clientes). Más segura pero más
laboriosa: hay que generar/distribuir una OTP por hostname. Plan B si la
cuenta delegada no convence.

## Requisito externo: DNS
La unión y el discover exigen que el equipo **resuelva el dominio** (registros
SRV `_ldap._tcp.dc._msdcs.iesmhp.local`): el DNS que reparte el DHCP del aula
debe ser el del dominio (o reenviar a él). Si `realm discover` dice "No such
realm" con el dominio bien escrito, el problema es el DNS del aula, no el rol.
Comprobar con `resolvectl status` y `dig -t SRV _ldap._tcp.iesmhp.local`.

## Estado / Notas
- **Activo** en `roles.yaml` (modo "solo prerequisitos": sin `preparaad_dominio`
  ni `preparaad_unir`, instala el stack y comprueba; no toca nada del dominio).
- **Idempotente**: paquetes `state: present`; mkhomedir solo si falta; krb5.conf
  y snippet por plantilla (mismo contenido = sin cambios); el join solo corre si
  `realm list` está vacío; sssd solo se reinicia si el snippet cambió.
- **Primer arranque**: solo usa `systemd` con `state: restarted` (los cuelgues
  documentados 2026-05-17 son de `enabled:`/`daemon_reload:` — no se usan).
- **Limitación**: `preparaad_password_union` no debe contener comillas simples
  (se interpola en una orden shell; la tarea va con `no_log`).
- **Salir del dominio**: `realm leave` (borra sssd.conf y deshabilita sssd).
  El snippet `conf.d/10-iac-ad.conf` quedaría huérfano — borrarlo a mano si se
  abandona el dominio definitivamente (si no, sssd intentaría arrancar con un
  dominio sin sección `[sssd]`).
