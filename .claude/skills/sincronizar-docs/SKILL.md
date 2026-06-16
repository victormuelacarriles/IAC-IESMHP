---
name: sincronizar-docs
description: >-
  Detecta incongruencias entre la documentación (ficheros CLAUDE.md/MD) y los
  ficheros reales del repo IAC-IESMHP: estado de roles en roles.yaml vs las
  tablas de los CLAUDE.md, lista de roles documentados vs directorios reales,
  rutas/variables de comun.sh, y ficheros de datos. Úsalo cuando el usuario
  pida "sincroniza/revisa/comprueba la documentación", tras editar roles.yaml o
  comun.sh, al añadir/quitar/renombrar un rol, o periódicamente para cazar
  "drift" entre docs y código. Solo REPORTA y, si el usuario confirma la fuente
  de verdad, corrige los MD; nunca cambia el comportamiento (no comenta ni
  descomenta roles por su cuenta).
---

# Sincronizar documentación (IAC-IESMHP)

Verifica que los ficheros `CLAUDE.md`/`*.md` describen fielmente lo que hacen
los ficheros reales del repo. El patrón habitual de error es **"drift"**: el
código cambia (sobre todo `roles.yaml`) y las tablas/listas de los MD se quedan
atrás.

## Principio rector: fuente de verdad

| Aspecto | Fuente de verdad (gana siempre) |
|---|---|
| Rol activo / comentado / no listado | `Ubuntu/ansible/roles.yaml` |
| Rutas, variables, URLs, redes/proxy | `Ubuntu/ISO/26.04/comun.sh` |
| Qué roles existen | directorios bajo `Ubuntu/ansible/roles/` y `…/rolesUsuario/roles/` |
| Qué scripts/ficheros existen | el sistema de ficheros |

Los `CLAUDE.md`/MD son documentación: **deben seguir al código**, no al revés.

## Regla de oro

- **Reporta primero.** Presenta una tabla de incongruencias con
  `fichero:línea`, "lo que dice el MD" y "lo que dice la realidad".
- **No cambies comportamiento.** Si un rol está comentado en `roles.yaml` pero
  los MD lo dan por activo (o viceversa), hay DOS arreglos posibles:
  (a) corregir los MD, o (b) (des)comentar el rol. Solo el usuario sabe la
  intención → **pregunta cuál es la fuente de verdad antes de tocar nada**.
  Por defecto, asume que `roles.yaml` manda y que se corrigen los MD.
- **No hagas commits ni push** (los hace el usuario).

## Procedimiento

### 1. Estado de roles: `roles.yaml` ↔ MD
- Lee `Ubuntu/ansible/roles.yaml` y clasifica cada rol en:
  - **activo** (línea `- nombre` sin `#`),
  - **comentado** (línea `#     - nombre`),
  - **no listado** (existe el directorio pero no aparece ni comentado).
- Cruza con la tabla "Roles y su estado actual" de
  `Ubuntu/ansible/CLAUDE.md` (columna ✅/⛔/legacy/no listado).
- Cruza con la sección `## Estado` de cada `roles/<rol>/CLAUDE.md`.
- Cruza con la lista de roles documentados del `CLAUDE.md` raíz y de
  `Ubuntu/CLAUDE.md` (sección "Configuración … con Ansible").
- Marca cualquier rol cuyo estado difiera entre estos cuatro sitios.

### 2. Inventario de roles: directorios ↔ documentación
- Lista `Ubuntu/ansible/roles/*/` y `Ubuntu/ansible/rolesUsuario/roles/*/`.
- Cada directorio de rol **debe** tener su `CLAUDE.md` y aparecer en la tabla
  de `Ubuntu/ansible/CLAUDE.md` y en las listas de roles documentados.
- Cada rol nombrado en los MD **debe** existir como directorio.
- Reporta: roles sin documentar, roles documentados que ya no existen, roles
  sin `CLAUDE.md`.

### 3. Variables y rutas: `comun.sh` ↔ MD
- Lee las definiciones de `Ubuntu/ISO/26.04/comun.sh` (`GITHUB_USER`, `REPO`,
  `RAIZSCRIPTS`, `RAIZDISTRO`, `RAIZANSIBLE`, `RAIZLOG`, `SCRIPT_*`,
  `FICHERO_*`, `URL_MACS`, `RED_*`, `PROXY_*`, `DISTRO`, `versionDISTRO`…).
- Verifica que los valores citados en los CLAUDE.md (rutas `/opt/...`, IPs de
  proxy, redes `10.0.72`/`10.0.32`, nombres de sub-scripts) coinciden con
  `comun.sh`. Si un MD codifica un valor a fuego que difiere → incongruencia.

### 4. Ficheros de datos y scripts referenciados
- Comprueba que existen los ficheros que los MD dan por presentes y **en la
  ruta indicada**: `macs.csv`, `Autorizados.txt` (raíz del repo),
  `FondoIES-*.png` y logos Plymouth (`Ubuntu/ISO/26.04/imagenesIES/`),
  sub-scripts (`1-…`/`2-…`/`3-…`/`4-…`, `utiles/NombreIP.sh`,
  `utiles/Auto-Ansible.sh`), inventarios `*.ini`, `roles.yaml`.
- Si un MD nombra una carpeta (p. ej. `pruebas/`, `rolesUsuario/`) verifica que
  exista y que el estado ("enganchado a roles.yaml" o no) sea correcto.

### 5. Coherencia entre los tres CLAUDE.md de nivel alto
- `CLAUDE.md` raíz (resumen), `Ubuntu/CLAUDE.md` (detalle ISO/ZFS) y
  `Ubuntu/ansible/CLAUDE.md` (Ansible) describen partes solapadas (cadena de
  ejecución, proxies, detección de aula, lista de roles). Señala divergencias
  de hechos entre ellos (no de redacción).

## Comandos útiles

```bash
# Estado de roles en el playbook (activo / comentado)
grep -nE '^\s*#?\s*- ' Ubuntu/ansible/roles.yaml

# Directorios de rol existentes
ls -d Ubuntu/ansible/roles/*/ Ubuntu/ansible/rolesUsuario/roles/*/

# Estado declarado en cada CLAUDE.md de rol
grep -rn 'activo\|comentado\|no listado\|✅\|⛔' Ubuntu/ansible/roles/*/CLAUDE.md

# Variables/valores definidos en comun.sh
grep -nE '^[A-Z_]+=' Ubuntu/ISO/26.04/comun.sh
```

## Salida esperada

1. **Tabla de incongruencias** con: descripción, `fichero:línea` del MD,
   valor en el MD, valor real (fuente de verdad), y severidad
   (real / menor).
2. Para las que tocan estado de roles, **una pregunta**: ¿la verdad es
   `roles.yaml` (corrijo los MD) o el rol debería (des)comentarse?
3. Solo tras la confirmación, aplica las correcciones a los MD (ediciones
   mínimas, sin reescribir secciones enteras).
4. Si el usuario quiere registrar el cambio, anótalo en
   `Ubuntu/RegistroDeCambios/AAAAMMDD-Cambios.md` con la hora (convención del
   proyecto). No hagas commit.
