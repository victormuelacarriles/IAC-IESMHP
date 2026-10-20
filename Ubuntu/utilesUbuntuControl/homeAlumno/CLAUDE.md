# CLAUDE.md — `homeAlumno/`

Contiene **`EnciendeAlumno.py`**, un "portero" de encendido remoto que se instala
en el `home` del usuario **`alumno`** de la VM de control. Contexto general en
[`../CLAUDE.md`](../CLAUDE.md).

## Flujo

1. El usuario (alumno o profesor) hace `ssh alumno@<VM>`; `alumno` no tiene
   contraseña y su `.bashrc` lanza el script con `exec` (al terminar, se cierra la sesión).
2. Pide el **usuario de dominio** y lo busca en la matriz `DATOS_USUARIOS`
   (`[usuario, equipo, IP, MAC, nombre real, tipo]`, tipo `A` alumno / `P` profesor).
3. Pide la contraseña (`getpass`) y la valida contra el **AD** por LDAP
   (`ldap3`, bind simple `usuario@iesmhp.local` contra `10.0.1.48`; NTLM se
   descartó porque fallaba en SMRD).
4. Elige el equipo (`elegir_equipo`): si el usuario tiene **uno**, se usa sin
   preguntar; si tiene **varios** (profesor en varias aulas), los lista y pide cuál.
5. Hace `ping` al equipo elegido; si no responde, envía **Wake-on-LAN**.
6. Si es **profesor** (con uno o varios equipos), ofrece encender el **aula del
   equipo elegido** (`encender_aula`): todos los equipos de `DATOS_USUARIOS`
   (alumnos y profesores) de la misma red `/24`, **solo esa aula**, un WoL por MAC.
7. Si el equipo no estaba encendido, comprueba con `ping` cada 10 s durante 5 min.

## Wake-on-LAN (broadcast dirigido)

`enviar_wol(mac, ip_destino)` construye el paquete mágico en Python (no depende
de `wakeonlan`) y lo envía al **broadcast de la red del equipo destino**, no a
`255.255.255.255`: `10.0.32.120` → red `10.0.32.0/24` → `10.0.32.255:9`.
Así funciona aunque la VM esté en otra subred, **siempre que el router permita
el broadcast dirigido** hacia esa red. Constantes: `PREFIJO_RED_WOL = 24`,
`PUERTO_WOL = 9` (cerca de `DOMINIO`/`SERVIDOR_AD`).

## Mantenimiento

- **Datos duplicados a mano**: `DATOS_USUARIOS` repite MACs/IPs de
  [`macs.csv`](../../../macs.csv). Un mismo equipo puede estar asignado a
  varios alumnos (turnos) y un profesor puede aparecer en dos aulas (p. ej.
  `vmuela`); `buscar_datos_usuario` devuelve **todas sus filas**. Los equipos de
  `macs.csv` sin usuario están en la matriz **comentados** (usuario `-`): al
  descomentarlos entran en el encendido del aula. Ante discrepancias de MAC, manda
  `macs.csv` (se comprueba a mano; el script no lo lee).
- Cada cambio actualiza la constante `VERSION` (fecha + motivo), que se muestra
  en la cabecera.
- **La copia en `/home/alumno/` es la que se ejecuta** y puede ser más nueva que
  la de GitHub; no sobrescribirla a ciegas (ver comentario `d)` al final del script).
- Instrucciones completas de instalación (usuario `alumno`, `PermitEmptyPasswords`,
  venv con `ldap3`, bloque del `.bashrc`) en los comentarios al final del `.py`.
- Es interactivo **por diseño** (lo usa una persona por SSH): la regla
  "sin preguntas interactivas" del proyecto aplica a la cadena de despliegue, no aquí.
