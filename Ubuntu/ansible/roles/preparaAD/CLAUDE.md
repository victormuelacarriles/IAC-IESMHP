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
   define (normalmente el propio DC), el rol **detecta el cliente NTP** del
   equipo, lo apunta al DC y **espera a que sincronice ANTES de continuar** (sin
   la espera, la unión posterior pillaba el reloj aún desfasado → *"join a
   medias"*, ver Estado/Notas). Prioridad a chrony:
   - **chrony** (Mint/Debian; no traen timesyncd): añade `server <ntp> iburst
     prefer trust` **+ `maxdistance 16.0`** a `chrony.conf` (bloque marcado,
     idempotente), reinicia el servicio, **arma el salto** (`chronyc makestep
     0.1 3` — step, no slew, en las próximas muestras) y **espera** (`chronyc
     waitsync 30 0.05 0 1`, máx ~30 s). OJO: un `chronyc makestep` lanzado al
     instante tras el restart es un **no-op** (chrony aún no tiene muestras del
     NTP); de ahí el armar+esperar. **El `maxdistance` es imprescindible con DC
     Windows**: w32time anuncia una *distancia de raíz* alta (~10 s) y el
     `maxdistance` por defecto de chrony (3 s) marca la fuente `^?`
     (inutilizable) → chrony **nunca la selecciona** y `makestep`/`waitsync` se
     quedan sin fuente (síntoma: `chronyc sources -v` con `^? <DC> ... 377 ...
     +/- 10s` pese a `Reach 377`). Relajarlo a 16 s acepta el DC; para Kerberos
     basta < 5 min. El arreglo de fondo es sincronizar el w32time del DC con un
     NTP fiable (si el DC va muy desfasado, su reloj CMOS deriva y la dispersión
     crece).
   - **systemd-timesyncd** (Ubuntu Desktop por defecto): escribe
     `/etc/systemd/timesyncd.conf.d/50-iac-ad.conf`, lo reinicia y **sondea**
     `timedatectl … NTPSynchronized` hasta `yes` o ~30 s.
   - Si no hay ninguno de los dos, avisa (`debug`) y no toca el reloj.
   El resumen final muestra SÍ/NO con pista accionable (NTP/conectividad al DC)
   leyendo `timedatectl … NTPSynchronized`.
4. **Hostname**: aviso si supera 15 caracteres (límite NetBIOS de la cuenta
   de equipo en AD). Los `IABD-NN`/`SMRD-NN` van sobrados.
5. **`/etc/krb5.conf`** (solo si se conoce el dominio): realm por defecto en
   mayúsculas, KDC por DNS (SRV), `rdns = false`.
6. **Comprobación de unión y DNS con auto-arreglo**: `realm list --name-only`
   (fuente de verdad de realmd/SSSD) y, si hay dominio, `realm discover`
   comprueba que se resuelve por DNS (**no falla** el play). Si **NO** se
   resuelve y hay `preparaad_dominio_dnss`, fuerza **split-DNS** con un
   drop-in de systemd-resolved (`/etc/systemd/resolved.conf.d/50-iac-ad.conf`:
   `DNS=<DCs>` + `Domains=~iesmhp.local`) — solo las consultas del dominio
   van a los DC, el resto sigue por el DNS del aula; no se toca
   NetworkManager ni el DHCP —, reinicia systemd-resolved y reintenta el
   discover. Además (6b), si el dominio termina en **`.local`** antepone
   `dns` a `mdns4_minimal` en la línea `hosts:` de `/etc/nsswitch.conf`:
   `.local` es el TLD de mDNS y el `[NOTFOUND=return]` de Ubuntu corta la
   resolución de getaddrinfo (ping, **kinit, adcli**) antes de llegar a
   systemd-resolved — `realm discover`/SSSD no lo sufren (resolver propio),
   por lo que sin este ajuste el resumen diría "visible por DNS: SÍ" pero la
   unión podría fallar. Los nombres mDNS legítimos siguen funcionando como
   fallback. Desactivable con `preparaad_arregla_nsswitch: false`.
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

## Variables

### `entornoAD.yml` — ÚNICO PUNTO DE CAMBIO del entorno (dominio/DNS/OU)
Fichero en la **raíz del rol** (`roles/preparaAD/entornoAD.yml`). Es la **única
fuente de verdad** del dominio al que se une el equipo, compartida por:
- el **rol** (`tasks/main.yml` lo carga con `include_vars` como tarea 0),
- los **scripts** `utilesAD/2-CreaVault.sh` y `utilesAD/3-UneAlDominio.sh` (lo
  parsean vía `utilesAD/entornoAD.sh`),
- `utilesAD/1-CreaUsuarioUnionAD.ps1` (lee de él la OU y la cuenta; el dominio
  lo autodetecta con `Get-ADDomain`).

Conmutar **producción ⇄ pruebas** = editar SOLO este fichero.

| Variable (en `entornoAD.yml`) | Valor | Para qué |
|----------|-------------|----------|
| `preparaad_dominio` | prod `iesmhp.local` / test `mhpies.local` | Dominio AD (DNS, minúsculas). Vacío = solo prerequisitos genéricos |
| `preparaad_dominio_dnss` | prod `10.0.1.48,10.0.1.54` / test `10.0.72.118` | IPs (separadas por comas) que resuelven el dominio (DNS de los DC). Solo si el DNS del equipo NO resuelve → split-DNS vía systemd-resolved. Vacío = sin auto-arreglo |
| `preparaad_nombre_ou` | `ComputersLinux` | Nombre (hoja) de la OU de las cuentas de equipo. La crea y delega `utilesAD/1-CreaUsuarioUnionAD.ps1` con este nombre |
| `preparaad_ou` | *(derivada)* `OU={{ nombre_ou }},DC=...` | OU completa (DN), **calculada** a partir de `preparaad_dominio` + `preparaad_nombre_ou`. No editar: cambia sola con el dominio |
| `preparaad_usuario_union` | `svc-union-linux` | Cuenta delegada de unión (la crea `utilesAD/1-CreaUsuarioUnionAD.ps1`) |
| `preparaad_ntp` | prod `10.0.1.48` / test `10.0.72.118` | NTP del dominio (normalmente el DC), o varios separados por comas. El rol detecta el cliente NTP (chrony en Mint/Debian, systemd-timesyncd en Ubuntu) y lo apunta aquí + `chronyc makestep`. Vacío = no se toca el reloj |

Todas se pueden pisar puntualmente con `-e` (extra-vars > include_vars).

### `defaults/main.yml` — comportamiento del rol (no del entorno)
| Variable | Por defecto | Para qué |
|----------|-------------|----------|
| `preparaad_arregla_nsswitch` | `true` | En dominios `.local`: anteponer `dns` a `mdns4_minimal` en `/etc/nsswitch.conf` (sin esto, ping/kinit/adcli no resuelven `*.local` aunque el split-DNS funcione) |
| `preparaad_paquetes` | lista | Stack a instalar |
| `preparaad_unir` | `false` | Intentar la unión en este pase |
| `preparaad_password_union` | `""` | Contraseña de la cuenta de unión — **solo vía vault (`utilesAD/2-CreaVault.sh`) o `-e`** |
| `preparaad_fqn` | `false` | `use_fully_qualified_names` |
| `preparaad_fallback_homedir` | `/home/%u` | Home de usuarios del dominio |
| `preparaad_gpo` | `permissive` | `ad_gpo_access_control` (endurecer a `enforcing` con las GPO revisadas) |

## Scripts de apoyo (`utilesAD/`)
| Script | Dónde se ejecuta | Qué hace |
|--------|------------------|----------|
| `1-CreaUsuarioUnionAD.ps1` | Controlador de dominio (admin del dominio) | OU `ComputersLinux` (si falta) + cuenta `svc-union-linux` (si falta; resetea contraseña si existe) + delegación mínima sobre la OU para **unir Y sacar** equipos (crear equipos, **borrar equipos**, reset password, validated writes dNSHostName/SPN, property set Account Restrictions). El borrado (`DeleteChild` de la clase equipo) queda **acotado a esta OU**. Idempotente: comprueba ACE a ACE. Lee OU/usuario de `entornoAD.yml`; el dominio lo autodetecta con `Get-ADDomain`. Solo pregunta la contraseña. **Sin tildes a propósito** (PS 5.1 lee UTF-8 sin BOM como ANSI) |
| `2-CreaVault.sh` | Equipo del profesor | Crea `Ubuntu/ansible/vault/preparaAD-vault.yml` (AES256, committeable) con las credenciales de unión. Rechaza contraseñas con comilla simple (limitación del rol) |
| `3-UneAlDominio.sh` | El equipo a unir (root) | Rol preparaAD (prerequisitos) → si no unido: `realm discover` + **guarda de reloj** (verifica `NTPSynchronized`; si no, fuerza `chronyc makestep`+`waitsync` / reinicia timesyncd y, si sigue desfasado, **aborta antes de pedir credenciales** para no dejar un objeto de equipo huérfano en AD) + pregunta la contraseña de `svc-union-linux` (**en blanco** = pide OTRO usuario del dominio con permisos de unión y su contraseña) + `realm join` a la OU → verifica → re-pase del rol (despliega el snippet SSSD) |
| `4-SacaDelDominio.sh` | El equipo a sacar (root) | **Inverso de 3**. Comprueba si está unido (si no, termina) → pide confirmación → pregunta la contraseña de `svc-union-linux` (**en blanco** = OTRO usuario con permisos de borrado) + `realm leave -U` (borra la cuenta de equipo en AD y deshace la config local) → verifica → elimina el snippet SSSD huérfano. Deja krb5/split-DNS/nsswitch intactos (facilitan reunir) |

## Cómo unir el equipo (cuando se decida)

### Manual (un equipo, para probar)
```bash
realm discover iesmhp.local                    # ¿se ve el dominio? (DNS)
realm join --user=svc-union-linux \
  --computer-ou='OU=ComputersLinux,DC=iesmhp,DC=local' \
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
   `ComputersLinux` y la cuenta `svc-union-linux` sin privilegios,
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

## Requisito externo: DNS (con auto-arreglo)
La unión y el discover exigen que el equipo **resuelva el dominio** (registros
SRV `_ldap._tcp.dc._msdcs.iesmhp.local`). Si el DNS que reparte el DHCP del
aula no lo resuelve, el rol lo arregla solo: split-DNS hacia los DC de
`preparaad_dominio_dnss` (drop-in `/etc/systemd/resolved.conf.d/50-iac-ad.conf`,
solo afecta a las consultas del dominio). Si el resumen sigue diciendo
"NO — ni con split-DNS", el problema es de **conectividad** con esas IPs
(routing/firewall del aula hacia `10.0.1.48`/`10.0.1.54`), no de DNS.
Diagnóstico: `resolvectl status`, `dig -t SRV _ldap._tcp.iesmhp.local @10.0.1.48`.

El rol arregla **las dos rutas de resolución** del equipo: la de
systemd-resolved (split-DNS — la que usan `realm`/SSSD) y la de
nsswitch/getaddrinfo (reorden del mDNS — la que usan `ping`/`kinit`/`adcli`).
Verificar cada una por separado: `resolvectl query iesmhp.local` (resolved) y
`getent hosts iesmhp.local` (nsswitch).

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
- **Reloj = requisito DURO, no opcional**: si `preparaad_ntp` está vacío o el
  reloj no sincroniza, `realm join` hace un **"join a medias"**: crea la cuenta
  de equipo por LDAP pero falla la finalización Kerberos (keytab/auth de
  máquina) → el equipo **aparece unido** pero la **autenticación falla** y queda
  un objeto huérfano en la OU. Síntoma del mensaje "posible fallo de
  sincronización de reloj". Por eso el rol ahora **espera** a la sincronización
  (chrony `waitsync` / sondeo de timesyncd) y `3-UneAlDominio.sh` aborta si el
  reloj no está OK. Limpiar un objeto huérfano: `adcli delete-computer
  --domain=DOMINIO --login-user=svc-union-linux HOSTNAME`.
- **Salir del dominio**: `utilesAD/4-SacaDelDominio.sh` (borra la cuenta de
  equipo de la OU con `realm leave -U`, deshace la config local y elimina el
  snippet `conf.d/10-iac-ad.conf` huérfano). A mano: `realm leave` deshace solo
  la config local (deja la cuenta en AD); en ese caso borrar el snippet a mano
  (si no, sssd intentaría arrancar con un dominio sin sección `[sssd]`).
