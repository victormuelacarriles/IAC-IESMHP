# CLAUDE.md — rol `VirtualW11`

Copia la **máquina virtual Windows 11 de plantilla** (VMware) desde el NAS al
perfil del usuario y la añade a su **VMware Workstation**. Es la base: la
configuración de la máquina se irá añadiendo poco a poco a este rol.

- Plantilla: `/mnt/nasDepInfo/PruebaRapidosX3/SMRV/VMWARE-Plantillas/Win11`
  (NFS del NAS, montado en cada equipo; ~15 GB: un `.vmx` + un `.vmdk`).
- **Caché local** (2026-10-23): para no leer los 15 GB del NAS una vez por
  alumno, la **parte 1** la copia una vez por equipo físico a
  `/datos/nasCache/SMRV/VMWARE-Plantillas/Win11` (si existe `/datos`) o a
  `/home/nasCache/SMRV/VMWARE-Plantillas/Win11`, y el rol (**parte 2**) copia
  desde ahí. Ver "Parte 1: caché local".
- Destino: `~/vmware/Win11-<usuario>` (p. ej. `~/vmware/Win11-SMRV08`).
  Se conservan los nombres de fichero de la plantilla
  (`Windows 11 25H2.vmx`…); solo cambian la carpeta y el nombre visible.

## Qué hace

1. **Usuario**: el `ansible_user` de cada equipo del inventario
   (`ansible_user=SMRV08@iesmhp.local`, mismo formato en SMRD e IABD desde
   2026-10-23), o el usuario actual en local. El `<usuario>` de la carpeta es
   la parte antes de `@`. Si sale `root`, falla (no se copia a `/root`).
2. Todo se ejecuta **como el alumno** (Ansible entra con su usuario), así
   que lo que crea queda a su nombre. Ya no hay `become_user` desde root.
3. Comprueba que existe su **HOME** (si no, no ha iniciado sesión nunca en el
   equipo → falla con ese motivo) y que la **plantilla** está accesible (un
   único `.vmx`; si no, ¿NAS montado?).
4. **Solo copia si la carpeta `~/vmware/Win11-<usuario>` no existe o está
   vacía** (2026-10-22). Entonces comprueba el **espacio libre** (tamaño de la
   plantilla + `VirtualW11_margen_gb`) y copia con `rsync` a
   `~/vmware/Win11-<usuario>.copiando`, que se renombra al terminar. Permisos
   `700`/`600`. La copia va en segundo plano (`async`, hasta
   `VirtualW11_timeout_copia`) para que no se corte el SSH. Si se corta,
   al relanzar `rsync` sigue por donde iba.
   Si la carpeta tiene **cualquier contenido**, no se copia nunca (no se pierde
   el trabajo del alumno). Si además falta el `.vmx` de la plantilla (otra
   cosa en la carpeta), avisa con `[WARN]` y no toca nada más (ni `.vmx` ni
   biblioteca). Si la carpeta existe vacía, se borra antes del `mv` final
   (si no, la copia quedaría *dentro* de ella).
5. **Ajustes del `.vmx`** (solo sin `<vmx>.lck`, que existe si la máquina
   está **encendida o abierta en una pestaña de VMware**; si existe, avisa y no
   lo toca, porque VMware lo reescribiría al cerrarla):
   - Primera vez (aún sin `uuid.action`): quita `uuid.bios` y `uuid.location`
     → VMware crea un UUID propio al arrancarla.
   - **MAC** (`files/mac-nueva.sh`, en cada ejecución): cada tarjeta
     `ethernetN` cuya MAC (`address` o `generatedAddress`, sin distinguir
     mayúsculas) sea **igual a la de la plantilla** recibe una MAC nueva
     aleatoria del rango estático de VMware (`00:50:56:00:00:00`–
     `00:50:56:3F:FF:FF`): `ethernetN.addressType = "static"` +
     `ethernetN.address`. Si ya es distinta, no se toca (la MAC no cambia en
     cada ejecución). Así también se corrigen máquinas copiadas antes.
   - `uuid.action = "create"`: VMware **no pregunta** «¿la has movido o
     copiado?» (la pregunta dejaría la máquina esperando un clic).
   - `displayName = "Win11-<usuario>"`.
   - **Red** (antes de encender): tiene que haber **una sola** tarjeta
     (`ethernetN.present`); si hay más, error. Se pone
     `ethernet0.connectionType = "<VirtualW11_red>"` y se quita
     `ethernet0.vnet`:
     - `nat` (**por defecto** desde 2026-10-24): red `vmnet8` del equipo físico;
     - `bridged`: red del aula (`-e VirtualW11_red=bridged`).

     Si hay que cambiarla pero la máquina está encendida o abierta en VMware
     (`.lck`), **error y se para**: hay que cerrarla y relanzar.
6. **Biblioteca de VMware**: `files/inventario-vmware.sh` añade la máquina a
   `~/.vmware/inventory.vmls` (entrada `vmlistN` en la raíz), si no estaba ya.
   Si VMware está abierto avisa: al cerrarse reescribe ese fichero y podría
   perder la entrada (relanzar el rol).
7. Mensaje final por equipo: `COPIADA` / `YA EXISTÍA` y biblioteca
   `AÑADIDA` / `YA ESTABA`.

8. **Comprobación de arranque** (`VirtualW11_comprobar_arranque`, por
   defecto `true`; añadida 2026-10-22):
   - **Estado previo**, tres casos (2026-10-22):

     | Situación | Cómo se detecta | Qué hace |
     |-----------|-----------------|----------|
     | Encendida | sale en `vmrun -T ws list` | Consulta las Tools; **no** la apaga |
     | Abierta en VMware (pestaña), apagada | no sale en `vmrun list`, hay `<vmx>.lck` y el usuario tiene VMware abierto (`pgrep -x vmware`) | La enciende **en esa ventana**: `vmrun start <vmx> gui` con el entorno gráfico (`DISPLAY`, `WAYLAND_DISPLAY`, `XAUTHORITY`, `XDG_RUNTIME_DIR`, `DBUS_SESSION_BUS_ADDRESS`) copiado de `/proc/<pid de vmware>/environ`, así funciona también por SSH. Es el **único** caso con GUI: `nogui` falla con *"The file is already in use"* |
     | Cerrada (o `.lck` huérfano) | resto | La arranca **sin ventana** (abajo) |

     **Regla: siempre headless salvo que no quede otro remedio.** Con VMware
     abierto pero **sin esa máquina en una pestaña**, se arranca sin ventana
     (probado). El apagado (`vmrun stop`) funciona sin entorno gráfico en los
     dos casos.
   - Si la máquina no está encendida (`vmrun -T ws list`), la arranca **sin
     ventana**: `vmrun -T ws start <vmx> nogui`, quitando `DISPLAY` y
     `WAYLAND_DISPLAY`, igual que por SSH en un equipo sin monitor.
   - Espera a que `vmrun checkToolsState` diga `running` **o** a que la última
     `Tools: Changing running status: X => 1|2` del `vmware.log` de la máquina
     diga que laten (checkToolsState solo da `running` un instante), como mucho
     `VirtualW11_timeout_tools` s. Si no llega, la tarea **falla** (el mensaje
     remite a `vmware.log` de la máquina).
     Antes de fallar **guarda una captura de la pantalla de Windows** en
     `<carpeta de la máquina>/fallo-tools-<fecha>.png` (`vmrun captureScreen`
     con el usuario físico o el de la plantilla), para ver qué hacía sin
     monitor.
   - Muestra lo que devuelven las Tools, sin usuario ni contraseña de Windows
     (`getGuestIPAddress` + `readVariable runtimeConfig`):
     ```
     Máquina : Win11-SMRV08 (arrancada por el rol)
     Tools   : running — VMware Tools 13.1.5.25544008
     Windows : Windows 11 Pro, 64-bit (Build 26200.9711)
     IP      : 172.16.179.134
     MAC     : 00:50:56:19:19:a2        (o "xx (generada)" si es de tipo generated)
     UUID    : 56 4d 21 1a ...
     ```
   - **Siempre** (también si falla) la apaga si la ha encendido el rol:
     `stop soft` (hasta `VirtualW11_timeout_apagado` s) y, si no termina,
     `stop hard`. Si ya estaba encendida (el alumno la está usando), solo
     consulta y **no la apaga**.
   - Todos los `vmrun` llevan `timeout`: nunca se queda colgado.
9. **Configuración del Windows invitado** (`VirtualW11_configurar_invitado`,
   por defecto `true`; 2026-10-22). Va entre la espera de las Tools y el
   apagado. Cualquier fallo **para el rol**, y la máquina se apaga igual.

   **Cómo se entra en el Windows** (`files/invitado/invitado.sh`): copia un
   `.ps1`, lo ejecuta y recoge su salida y su código. Hay dos formas:
   - **`tools:<usuario>`** — VMware Tools (`vmrun runProgramInGuest`). No usa
     la red, así que cambiar la IP no corta nada.
     > El servicio de las Tools corre como SYSTEM, pero las operaciones de
     > `vmrun` en el invitado **exigen usuario y contraseña de Windows** y
     > corren como ese usuario (comprobado: sin credenciales, *"Command
     > requires valid user name and password"*). Un administrador corre
     > **elevado**.
   - **`ssh:<usuario>`** — `scp` + `ssh` con la clave. No usa contraseña.

   **El método se averigua una vez** (`invitado.sh --detecta`), al principio
   y otra vez tras crear el administrador, y todas las operaciones usan ese.
   Orden:
   1. Tools como `admin<usuario>` con `usuario@1`, un único intento.
   2. SSH con la clave como `admin<usuario>` y, en máquinas de antes, como
      `<usuario>`, que era administrador (`ssh:<usuario>`). Hasta 6 vueltas,
      cada 5 s, porque recién arrancada `sshd` tarda.
   3. Tools como `<usuario>` (máquinas de antes) y como `usuario` de la
      plantilla (la primera vez).

   > ⚠ **Bloqueo de cuentas de Windows 11**: cada contraseña errónea cuenta
   > (por defecto 10 fallos → cuenta **bloqueada 10 min**), y una cuenta
   > bloqueada no entra **ni por SSH con clave** (*"Connection reset"* tras el
   > banner) ni por Tools (*"Invalid user name or password"* aunque la
   > contraseña sea buena). Pasó al probar (2026-10-22): la versión anterior
   > probaba Tools con `usuario@1` en **cada** operación tras cambiar el alumno
   > la contraseña y bloqueó la cuenta. Por eso ahora se detecta una vez: con
   > la contraseña cambiada, solo 1 fallo por ejecución.

   Los scripts se copian antes a `~/.cache/IAC-IESMHP/VirtualW11/` del equipo
   físico.

   1. **Usuarios** (`usuario.ps1`; dos por alumno desde 2026-10-24):
      - `<usuario físico>` (`SMRV08`, `vmuela`…): **estándar**. Es el del
        arranque automático y el de Remmina: se mete en *Usuarios* y en
        *Usuarios de escritorio remoto* (S-1-5-32-555), sin el cual un
        usuario estándar no puede entrar por RDP;
      - `admin<usuario físico>` (`adminSMRV08`, prefijo
        `VirtualW11_admin_prefijo`): **administrador**. Es el que usa el rol
        (Tools y SSH);
      - los dos con la **misma contraseña**, `usuario@1` al crearlos
        (`VirtualW11_invitado_password`). A los que ya existen **no** se les
        cambia;
      - **fichero de claves** (`.clavesalumnos`, ver más abajo): si el alumno
        está en él, los dos llevan **su clave** en vez de `usuario@1`, y se les
        **pone también si ya existen** (solo si no la tienen ya: una
        comprobación). La plantilla (`usuario`) sigue entrando con `usuario@1`
        (`IAC_PLANTILLA`/`IAC_PASSWORD_PLANTILLA` en `invitado.sh`);
      - **máquinas de antes**, donde `<usuario físico>` era administrador: se
        le quita de *Administradores* solo cuando `admin<usuario>` ya existe y
        lo es. Si el alumno ya había cambiado su contraseña, `admin<usuario>`
        se crea con `usuario@1` (el rol no conoce la nueva); se igualan cuando
        el alumno usa el script del escritorio;
      - desactiva **solo `usuario`** (el de la plantilla) y la **pantalla de
        privacidad del primer inicio de sesión** (`DisablePrivacyExperience=1`;
        sin ella, con el arranque automático el usuario se quedaba en *"Permitir
        que Microsoft y las aplicaciones usen tu ubicación"* esperando un clic).

      La primera vez se entra con `usuario` de la plantilla; como el script lo
      desactiva, la salida se recoge con el administrador nuevo.
   2. **SSH** (`ssh.ps1`): clave del usuario del equipo físico (`id_ed25519`,
      `id_ecdsa` o `id_rsa`; si no tiene, se genera `~/.ssh/id_ed25519` sin
      contraseña). En el invitado:
      - si falta `sshd`, se instala `OpenSSH.Server` (necesita Windows Update);
      - se deja arrancado y automático;
      - regla `OpenSSH-Server-In-TCP` (22) en todos los perfiles;
      - la clave pública va a `C:\ProgramData\ssh\administrators_authorized_keys`
        (el fichero de los administradores) con sus permisos.
      - y también para `<usuario>` (estándar, 2026-10-25): en
        `C:\ProgramData\ssh\claves\<usuario>` (administradores y SYSTEM
        control total, el usuario solo lectura, propietario Administradores),
        con `AuthorizedKeysFile .ssh/authorized_keys __PROGRAMDATA__/ssh/claves/%u`
        en `sshd_config`. No en `C:\Users\<usuario>\.ssh`: ese perfil no
        existe hasta el primer inicio de sesión. Si el rol entra por SSH, sshd
        no se reinicia (cortaría la conexión): vale tras reiniciar Windows.

      **Después de fijar la IP** (paso 3; cambio 2026-10-24) se entra desde el equipo físico (`ssh <usuario físico>@<IP final>`) y se
      comprueba con `whoami /groups` (vale con cmd o PowerShell como shell) que
      es administrador elevado. La salida de Windows viene en cp850: se filtra
      a ASCII.
   2b. **Escritorio remoto** (`rdp.ps1`, si `VirtualW11_remmina`): RDP activado
      con NLA, reglas `RemoteDesktop-UserMode-In-*` en todos los perfiles y
      `TermService` arrancado (en la plantilla ya venía activo).
   3. **IP estática** (`ip.ps1`, por VMware Tools; va antes de la comprobación
      por SSH, porque si se cambió el modo de red la máquina arranca con la IP
      del modo anterior, que puede no ser alcanzable), según `VirtualW11_red`:
      - **`nat`** (por defecto): subred de `vmnet8` del equipo físico; puerta
        y DNS = el NAT de VMware (`ip =` de `/etc/vmware/vmnet8/nat/nat.conf`,
        el `.2`). Último octeto:
        - usuario acabado en número N → **100 + N** (`SMRV02` → `.102`,
          `CEGSIABD14` → `.114`). Así los alumnos que comparten equipo (SMRD)
          no chocan;
        - usuario sin número (`vmuela`) → **la IP que le dio el DHCP**, fija.
      - **`bridged`**: misma máscara, puerta y DNS que el equipo físico (`ip
        route`, `nmcli`/`resolvectl`) y último octeto **+ `VirtualW11_ip_suma`
        (30)** (`10.0.32.138` → `10.0.32.168`).
      - Antes se mira si está libre: ping **y** ARP (`ip neigh`), porque
        Windows no contesta a ping y sí a ARP. Solo cuenta `REACHABLE`: una
        entrada `STALE` de la caché ARP, de un equipo que ya no está, no la da
        por ocupada. Si está ocupada, o pasa de `.254`, no se cambia (`[WARN]`,
        se queda con la que tenía, normalmente DHCP).
      - Si la máquina ya tiene esa IP, no se mira.
      - ⚠ En `nat` el DHCP de VMware reparte por defecto `.128`–`.254`: con
        N ≥ 28 (`.128` o más) y en usuarios sin número, la IP fija cae dentro
        de ese rango.
   4. **Nombre** (`nombre.ps1`): `Win11-<usuario>`. Si cambia, hay que
      reiniciar: `vmrun reset soft` y se espera (hasta
      `VirtualW11_timeout_reinicio`) a que vuelva con el nombre nuevo. Si el
      alumno la tenía encendida, no se reinicia: solo avisa.
   6. **Lanzador en Remmina** (`files/remmina-perfil.sh`, en el equipo físico,
      si `VirtualW11_remmina`): antes se comprueba que el 3389 responde. Crea
      el perfil RDP `Win11-<usuario>` (`~/.local/share/remmina/group_rdp_…`)
      con **usuario e IP de destino, sin contraseña** (la guarda el usuario
      la primera vez que conecta). Si ya hay un perfil con ese nombre no lo
      toca, salvo `server=` si la IP ha cambiado.
      **Marcador en el gestor de archivos** (`files/marcador-sftp.sh`,
      `VirtualW11_marcador`; 2026-10-25): línea
      `sftp://<usuario>@<IP>/C:/Users/<usuario> W11-<usuario>` en
      `~/.config/gtk-3.0/bookmarks` (Nautilus); si ya hay uno con ese nombre y
      otra IP, se sustituye. Entra con la clave SSH del alumno (necesita la del
      usuario estándar, ver paso 2). Además mete la clave de host de la máquina
      en `~/.ssh/known_hosts` (`ssh-keyscan`; se renueva si cambió) para que
      Nautilus no pregunte la primera vez.
   7. **Arranque automático (último paso)** (`CambiarPassword.ps1`,
      `VirtualW11_autologon_activar`; 2026-10-23):
      - del usuario **estándar** `<usuario físico>`, y **solo si su contraseña
        sigue siendo la inicial** (una única comprobación). Si el alumno ya la
        cambió, no se toca su arranque automático, porque lo rompería;
      - Winlogon `AutoAdminLogon=1` + `DefaultUserName` + `DefaultDomainName`
        (nombre del equipo), y la contraseña como **secreto LSA**
        `DefaultPassword` (como Autologon de Sysinternals), **no** en texto
        plano en el registro; `DevicePasswordLessBuildVersion=0` ("solo
        Windows Hello" impide el inicio automático);
      - se copia a `C:\ProgramData\IAC-IESMHP\CambiarPassword.ps1` y deja en
        el **escritorio público** el acceso directo *"Cambiar contraseña y
        arranque automático"* (doble clic en un `.ps1` lo abriría en el Bloc de
        notas). El script interactivo:
        1. pide permisos de administrador: como `<usuario>` es estándar,
           Windows pide en la ventana de UAC `admin<usuario>` y su contraseña;
           explica que configura el arranque automático;
        2. si sigue la contraseña inicial, pide una nueva **dos veces**
           (no vacía ni igual a la inicial), **se la pone a los dos usuarios**
           y configura el arranque automático de `<usuario>` con ella;
        3. si ya la cambió, pide la actual de `<usuario>`, deja
           `admin<usuario>` con la misma y reconfigura el arranque;
        4. termina avisando de que **recuerde la contraseña para entrar por
           Remmina**;
      - **con clave del fichero**: arranque automático con esa clave y **sin**
        acceso directo (si lo había, se quita): la contraseña la fija el
        profesor;
      - si lo configuró (o puso la clave del fichero) y la máquina la encendió
        el rol, **reinicia y comprueba**
        que el usuario entra solo (su `explorer.exe` en `listProcessesInGuest`).
   5. **Comprobación final** por SSH a la IP final (`hostname`) y resumen:
      ```
      Usuarios: SMRV02 (estándar, arranque automático y Remmina) + adminSMRV02 (administrador), contraseña inicial usuario@1; Desactivado: usuario
      SSH     : ssh -i ~/.ssh/id_ed25519 adminSMRV02@10.0.32.168
      IP      : 10.0.32.168/24 estática, puerta 10.0.32.254, DNS 10.0.1.48,10.0.1.54
      Nombre  : Win11-SMRV02
      ```

## Parte 1: caché local (`tasks/cache.yml` + `CacheNAS.yaml`)

Necesita **root**, así que va con el **inventario de aula**
(`../../../equiposSMRD.ini` / `equiposIABD.ini`: un equipo por línea,
`ansible_user=root`), no con el de alumnos.

1. Disco: el primero que exista de `VirtualW11_cache_discos` (`/datos`, `/home`).
2. Comprueba que la plantilla del NAS está (un único `.vmx`).
3. Crea `<disco>/nasCache/SMRV/VMWARE-Plantillas/Win11`, todos los niveles
   con **1777**.
4. `rsync -a --delete --chmod=D1777,F0666` del NAS a la caché: solo copia lo
   que cambie (sin cambios, segundos) y borra lo que ya no esté en el NAS.
   Va en `async` (hasta `VirtualW11_timeout_cache`).

**Permisos** (petición del propietario):
- el interior es de lectura/escritura para todos: carpetas `1777` y ficheros `666`;
- `nasCache` es de root y está dentro de `/home` o `/datos`, que son de root:
  **solo un administrador puede borrarlo**;
- el bit *sticky* impide además que un usuario borre lo que no es suyo.

> ⚠ Con `666` cualquier alumno **puede modificar** la plantilla en caché y
> afectaría a las copias posteriores en ese equipo; la siguiente parte 1 la
> vuelve a dejar igual que el NAS.

En la **parte 2**, el rol busca la plantilla por orden en `/datos/nasCache/…`,
`/home/nasCache/…` y el NAS (o en `VirtualW11_origen` si se fija). Si acaba en
el NAS, avisa con `[WARN]`.

En `/home` (ZFS `rpool/home` con dedup), la caché y las copias de los alumnos
se deduplican entre sí.

## Uso en solitario: `VirtualW11.sh` (parte 1 + parte 2)

`VirtualW11.sh` lanza las dos partes seguidas:

1. `CacheNAS.yaml`, con el inventario de **aula**, como root.
2. `VirtualW11.yaml`, con el inventario de **alumnos**.

`VirtualW11.yaml` aplica esta carpeta como rol (`role: "{{ playbook_dir }}"`,
`become: no`), como el rol [`vscode`](../../../roles/vscode/CLAUDE.md).

```bash
cd /opt/IAC-IESMHP/Ubuntu/ansible/rolesUsuario/roles/VirtualW11
bash VirtualW11.sh                        # local (caché con sudo -n; si no, avisa)
bash VirtualW11.sh SMRD                   # caché equiposSMRD.ini + alumnos SMRD
bash VirtualW11.sh IABD -l IABD-05        # un equipo
bash VirtualW11.sh SMRD AOD               # solo los alumnos del módulo AOD
bash VirtualW11.sh SMRD --modulo AOD,SOR  # varios módulos (unión)
bash VirtualW11.sh SMRD AOD -l 'SMRD-0*'  # de AOD, solo esos equipos (intersección)
bash VirtualW11.sh SMRD -l SMRD-04-SMRV24 -e VirtualW11_reemplazar=true   # BORRA y recopia
bash VirtualW11.sh otro-alumnos.ini       # el de aula se deduce del grupo [SMRD]/[IABD]
bash VirtualW11.sh SMRD --solo-cache      # solo la parte 1
bash VirtualW11.sh SMRD --sin-cache       # solo la parte 2
bash VirtualW11.sh SMRD --forks-cache 3 --forks-alumno 10   # equipos a la vez
bash VirtualW11.sh SMRD --bridge -l SMRD-04-SMRV24     # red del aula (bridged)
bash VirtualW11.sh SMRD --nat                           # red NAT (por defecto)
bash VirtualW11.sh --help
```

- **Claves de los alumnos:** `--claves F` (por defecto `.clavesalumnos` junto
  al script, si existe; `--sin-claves` para no usarlo). Formato: una línea
  `USUARIO,clave` por alumno, `#` = comentario; el usuario no distingue
  mayúsculas. Se lee en el **equipo que lanza** el script (lookup de Ansible),
  no hace falta en los equipos de los alumnos. Está en `.gitignore` (texto
  plano: no subirlo nunca). Alumno que no esté en el fichero → `usuario@1` y
  acceso directo, como siempre. Si se da `--claves` con un fichero que no
  existe, error.
- **Módulo:** `--modulo M` (o `-m M`, o el nombre suelto tras el aula:
  `SMRD AOD`) elige los alumnos de los grupos `[AOD]`/`[SOR]`... del
  inventario de alumnos. Varios con comas (unión). Con `-l`, solo los que
  cumplen las dos cosas. El script lo traduce a una lista de equipos (`-l`
  de la parte 2 y, por su IP, equipos físicos de la parte 1). Si el módulo no
  existe en el inventario o no queda nadie, da error y para.
- **Modo de red:** `--nat` (por defecto) o `--bridge`. Equivalen a
  `-e VirtualW11_red=nat|bridged` y solo van a la parte 2. En una máquina ya
  creada también vale: se cambia antes de encenderla. Si está encendida o
  abierta en VMware, avisa y para.
- **Tiempos** (2026-10-24): al final, tabla con lo que tarda cada **equipo**
  en la parte 1 (sincronización NAS → caché), cada **usuario** en la parte 2
  (configuración de Win11), el total de cada parte y el **total general**
  (desde que se lanza el script). Cada playbook usa `strategy: free` (cada
  equipo a su ritmo, así su tiempo es real) y, en un `always` (también si
  falla), saca `TIEMPO|parte|equipo|segundos|OK/ERROR`. Los que no responden
  (`unreachable` en el `PLAY RECAP`) salen como `SIN RESPUESTA`.
- **Equipos a la vez** (`--forks` de Ansible), uno por parte, por defecto 5:
  - `--forks-cache N` (o `FORKS_CACHE=N`) para la parte 1: cada equipo lee
    ~15 GB del NAS la primera vez, así que conviene un número bajo;
  - `--forks-alumno N` (o `FORKS_ALUMNO=N`) para la parte 2: en SMRD hay
    varios alumnos por equipo y cada uno copia y arranca su máquina (8 GB de
    RAM). Va por **tandas** de N alumnos (`serial`, variable
    `VirtualW11_serie`): con 1, de uno en uno de verdad (solo `--forks` no
    basta con `strategy: free`). Un equipo apagado (`SIN RESPUESTA`) o un
    alumno que falla (`ERROR`) no paran a los siguientes.

  Un valor que no sea un número positivo da error.

- **`-l`:** lleva nombres del inventario de alumnos. Para la parte 1 se
  traduce a los equipos físicos por su IP (`ansible-inventory --limit` →
  `-e VirtualW11_ips=…`). Si no coincide con ninguno, error y no se lanza nada.
- **Resto de argumentos:** (`-e`, `-v`…) van solo a la parte 2.
- **Si la parte 1 falla en un equipo** (apagado…), se sigue con la parte 2: en
  ese equipo copiará desde el NAS.
- **Sin preguntas:** stdin a `/dev/null`. Devuelve el código de la parte 2 o,
  si esa va bien, el de la 1.
- **Log:** `/var/log/IAC-IESMHP/VirtualW11.log` o
  `~/.local/state/IAC-IESMHP/VirtualW11.log`, con una línea `=====` por parte.
- **No pasa por `compruebaUsuario`.**

## Uso dentro de `rolesUsuario.yaml`

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
| `VirtualW11_carpeta` | `vmware` | Carpeta de las VMs dentro del HOME |
| `VirtualW11_prefijo` | `Win11` | Nombre: `<prefijo>-<usuario>` |
| `VirtualW11_margen_gb` | `5` | GB libres que deben quedar tras copiar |
| `VirtualW11_timeout_copia` | `7200` | Segundos máximos de la copia |
| `VirtualW11_reemplazar` | `false` | `true` = borra y vuelve a copiar |
| `VirtualW11_nas_raiz` | `/mnt/nasDepInfo/PruebaRapidosX3` | Raíz del NAS |
| `VirtualW11_plantilla_ruta` | `SMRV/VMWARE-Plantillas/Win11` | Ruta de la plantilla (igual en NAS y caché) |
| `VirtualW11_cache_discos` | `[/datos, /home]` | Disco de la caché: el primero que exista |
| `VirtualW11_cache_carpeta` | `nasCache` | Carpeta de la caché en ese disco |
| `VirtualW11_timeout_cache` | `7200` | Segundos máximos de la copia NAS → caché |
| `VirtualW11_origen` | `""` | Origen fijo de la plantilla (vacío = caché o NAS) |
| `VirtualW11_comprobar_arranque` | `true` | Arrancar y esperar a las Tools |
| `VirtualW11_timeout_tools` | `1200` | Segundos máximos esperando a las Tools (normalmente 15-20 s; a veces muchos minutos) |
| `VirtualW11_apagar_tras_comprobar` | `true` | Apagarla al terminar (si la encendió el rol) |
| `VirtualW11_timeout_apagado` | `180` | Segundos de apagado `soft` antes del `hard` |
| `VirtualW11_red` | `nat` | Modo de red de `ethernet0`: `nat` o `bridged` |
| `VirtualW11_configurar_invitado` | `true` | Usuario, SSH, IP y nombre del invitado |
| `VirtualW11_invitado_password` | `usuario@1` | Contraseña inicial de `<usuario>` y `admin<usuario>` (y la de `usuario` de la plantilla) |
| `VirtualW11_claves_fichero` | `""` | Fichero `USUARIO,clave` (en el equipo que lanza). `VirtualW11.sh` pasa `.clavesalumnos` si existe |
| `VirtualW11_admin_prefijo` | `admin` | Nombre del administrador: `admin<usuario>` |
| `VirtualW11_invitado_usuario` | `usuario` | Usuario de la plantilla: solo para entrar la primera vez (luego queda desactivado) |
| `VirtualW11_ip_suma` | `30` | Solo `bridged`: IP del invitado = IP física + esto |
| `VirtualW11_timeout_reinicio` | `600` | Espera tras reiniciar por el nombre |
| `VirtualW11_remmina` | `true` | RDP en el invitado + lanzador en Remmina |
| `VirtualW11_marcador` | `true` | Marcador SFTP al perfil de Windows en el gestor de archivos |
| `VirtualW11_marcador_nombre` | `W11-<usuario>` | Nombre del marcador |
| `VirtualW11_autologon_activar` | `true` | Arranque automático + acceso directo para cambiar la contraseña |

## Pruebas

- 2026-10-22, en local con una plantilla pequeña y un HOME de prueba: copia,
  2ª ejecución sin cambios, UUID nuevo de VMware respetado, máquina encendida
  (`.lck`), sin espacio, plantilla inexistente y `reemplazar`. Correcto.
- 2026-10-22, condición de copia (carpeta inexistente / vacía / con otra cosa /
  máquina ya copiada / con otra cosa + `reemplazar`): correcto.
- 2026-10-22, MAC: copia nueva → MAC nueva; 2ª ejecución → igual; máquina
  antigua con la MAC de la plantilla (en mayúsculas) → MAC nueva; con `.lck`
  → no se toca; 200 MACs generadas, todas dentro del rango.
- 2026-10-22, `VirtualW11.sh` en local con la misma plantilla de prueba: correcto.
- 2026-10-22, **con la plantilla real** (copia de 17 GB en un HOME de prueba,
  ~2 min desde el NAS): arranque sin `DISPLAY` sin ninguna pregunta, UUID nuevo
  generado, Tools `running` a los ~16 s, datos correctos y apagado `soft` en
  ~4 s (ejecución completa ~40 s). También: máquina ya encendida (no la apaga),
  Tools que no responden (`-e VirtualW11_timeout_tools=0` → falla y la apaga)
  y `VirtualW11_comprobar_arranque=false`.
- 2026-10-22, en SMRD-18 con VMware abierto y la máquina en una pestaña
  (apagada): antes fallaba con *"The file is already in use"*; ahora avisa y
  acaba sin fallos. Con VMware abierto pero sin la máquina en una pestaña: la
  arranca, lee las Tools y la apaga.
- 2026-10-22, máquina abierta en una pestaña y script lanzado **sin**
  `DISPLAY`/`WAYLAND_DISPLAY`/`XAUTHORITY` (como por SSH): se enciende en la
  ventana, Tools en ~16 s, se apaga y la pestaña sigue abierta.
- 2026-10-22, configuración del invitado con la copia de prueba en SMRD-18
  (`10.0.32.138`):
  - 1ª ejecución, 1,5 min: NAT → bridged, DHCP `10.0.32.11`, admin OK,
    clave generada y autorizada, SSH OK, estática `10.0.32.168`, nombre
    `Win11-vmuela` con reinicio, SSH final OK.
  - 2ª ejecución, 1 min: sin cambios ni reinicio.
  - IP ocupada (`-e VirtualW11_ip_suma=0`): avisa y deja la que tenía.
  - Contraseña mala: error y la apaga.
- 2026-10-23, administrador = usuario físico, con la copia de prueba:
  - desde cero: `tools:usuario` → crea `vmuela`, desactiva `usuario` →
    `tools:vmuela`, `.168`, nombre; 4 min con la copia. (Con la primera
    versión también desactivaba `adminw11`, que trae la plantilla; ahora se
    queda como está);
  - con la contraseña inicial: todo por `tools:vmuela`;
  - con la contraseña cambiada por el alumno: 1 intento fallido y todo por
    `ssh`.

  Cortafuegos del invitado revisado: dos reglas para el 22 (`OpenSSH-Server-In-TCP`
  del rol y `sshd` de la plantilla), las dos `Allow`, perfil `Any`; la red
  queda como `Public`. Política de bloqueo de la plantilla: umbral 10,
  duración 10 min.
- 2026-10-23, desde cero: solo se desactiva `usuario` (`adminw11` sigue
  activo), RDP ya activo, 3389 responde, perfil de Remmina creado sin
  contraseña.
- **Arranque lento de las Tools — RESUELTO el 2026-10-25**: no era Windows,
  era `checkToolsState`, que solo devuelve `running` en el instante de una
  operación en el invitado y el resto del tiempo `installed`, aunque las Tools
  funcionen (en `vmware.log`: `running status: 0 => 1` a los ~12 s). Ahora la
  espera mira también el `vmware.log`. Lo de abajo queda como historia.
- **Arranque lento de las Tools — causa sin aclarar** (2026-10-24, tras varias
  pruebas): a veces Windows tarda muchos minutos (6, 7, más de 10) en arrancar
  el servicio de las Tools, tanto en copias nuevas (que se quedan en la
  pantalla de bloqueo: la plantilla tiene `AutoAdminLogon=0`) como en máquinas
  ya usadas. Las operaciones de `vmrun` dentro de Windows esperan a que el
  servicio esté listo, y `checkToolsState=running` llega a la vez, así que es la
  señal correcta. **No** era la pantalla de privacidad: esa era otro problema
  (dejaba al alumno esperando un clic) y está resuelto, pero un caso lento se dio
  en la pantalla de bloqueo. Mitigación: `VirtualW11_timeout_tools=1200` y
  captura automática al fallar.
- **Intermitente** (también 2026-10-24, y no solo en el primer arranque: una
  máquina que había arrancado bien no levantó las Tools en 600 s al arrancar
  de nuevo; al minuto siguiente, sí). Ahora se guarda una captura automática al
  fallar. Antes: una copia nueva (2026-10-23 07:26) no levantó las Tools en
  600 s (dos veces seguidas); a los 30 min, otra copia nueva las levantó en
  45 s. No reproducido; si vuelve a pasar, mirar la pantalla con
  `vmrun -gu usuario -gp usuario@1 captureScreen <vmx> pantalla.png`.
- 2026-10-23, caché (sin root, con discos y NAS falsos): 1ª copia, 2ª «al
  día», cambio en el NAS → solo lo nuevo, con `/datos` → `/datos/nasCache`,
  permisos 1777/666; la parte 2 copia desde la caché y, sin caché, desde el
  NAS con aviso. `VirtualW11.sh` probado con un `ansible-playbook` falso
  (traducción del `-l`, `--sin-cache`, `--solo-cache`, `-l` inexistente).
  **Falta probar la parte 1 con root real en un equipo del aula.**
- **Pendiente**: probar contra un equipo del aula (copia real de 15 GB,
  `become_user` desde root en IABD) y abrir VMware para ver que la máquina
  aparece y arranca sin preguntas.

## Pendiente / ideas

- **Misma IP para varios alumnos (SMRD)**: los alumnos del mismo equipo
  físico calculan la misma IP (`física + 30`). La comprobación de libre solo
  ve las máquinas **encendidas**: si otra está apagada, las dos acaban con la
  misma IP estática y chocarán cuando se enciendan a la vez.
- **Nombres de más de 15 caracteres** (`Win11-CEGSIABD14` = 16): Windows
  recorta el nombre NetBIOS (el DNS queda completo). Sin probar.
- Si falta OpenSSH en el invitado, instalarlo necesita Windows Update (proxy
  de aula). La plantilla actual ya lo trae.
- La contraseña del invitado va en `defaults/` y en la línea de órdenes de
  `vmrun` (visible con `ps` en el equipo físico mientras se ejecuta).

- **Varios alumnos en el mismo equipo (SMRD)**: Ansible los procesa en
  paralelo, así que un equipo puede copiar varias máquinas y arrancar varias a
  la vez (8 GB de RAM cada una). Si da problemas, lanzar por equipo o con
  `--forks` bajo.

- Configuración de la máquina (se irá indicando).
- Snapshot inicial tras la copia, para que el alumno pueda volver atrás.
