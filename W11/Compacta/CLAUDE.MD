# CLAUDE.md — W11/Compacta

Herramientas para liberar espacio en disco y compactar máquinas virtuales Windows 11
alojadas en VMware Workstation desde un host Linux Ubuntu Desktop.

---

## Propósito

Las máquinas virtuales VMware con disco dinámico (VMDK thin-provisioned) crecen con
el uso pero **no se reducen automáticamente** cuando se borran ficheros dentro de la
VM. Para recuperar espacio real en el host hay que:

1. **Dentro de la VM (Windows 11)**: borrar todo lo que sobra para que el espacio
   libre del disco virtual sea máximo.
2. **Desde el host (Linux)**: defragmentar el VMDK y luego compactarlo para que
   VMware libere los bloques vacíos al sistema de ficheros del host.

Estos dos pasos los cubren los dos scripts de esta carpeta.

---

## Scripts

### 1. `LimpiaW11.ps1`
**Entorno**: PowerShell como Administrador dentro de la propia VM Windows 11.
**Objetivo**: maximizar el espacio libre del disco virtual antes de la compactación.

Tareas previstas (por orden de ejecución):

| Bloque | Acción |
|--------|--------|
| Limpieza de temp | `%TEMP%`, `C:\Windows\Temp`, `C:\Windows\SoftwareDistribution\Download` |
| Windows Update | Vaciar caché de actualizaciones descargadas (`SoftwareDistribution\Download`) |
| WinSxS / Component Store | `DISM /Online /Cleanup-Image /StartComponentCleanup /ResetBase` |
| Papelera | Vaciar todas las papeleras de todos los perfiles |
| Prefetch | `C:\Windows\Prefetch\*` |
| Minidumps | `C:\Windows\Minidump\*` y `C:\Windows\memory.dmp` |
| Thumbnails / Icon cache | Bases de datos de miniaturas de todos los perfiles |
| Hibernación | `powercfg /h off` (elimina `hiberfil.sys`) |
| Pagefile | Opcional: reducir o eliminar temporalmente el fichero de paginación |
| Event logs | Limpiar todos los registros de eventos de Windows |
| Puntos de restauración | Eliminar todos salvo el más reciente (o todos si se indica) |
| Cleanmgr | Ejecutar `cleanmgr /sagerun:1` en modo silencioso para limpieza adicional |
| SDelete / zero-fill | Ejecutar `sdelete64.exe -z C:` para rellenar el espacio libre con ceros (imprescindible para que VMware compacte eficientemente) |

**Requisito externo**: `sdelete64.exe` de Sysinternals debe estar disponible
(descargado manualmente o con `winget install Microsoft.Sysinternals.SDelete`).

**Salida**: resumen por pantalla del espacio liberado en cada bloque y espacio libre
total antes/después.

---

### 2. `CompactaW11.sh`
**Entorno**: Bash en Ubuntu Desktop (host Linux) con VMware Workstation instalado.
**Objetivo**: defragmentar y compactar los VMDK de la VM Windows 11 para liberar
espacio real en el sistema de ficheros del host.

Tareas previstas (por orden de ejecución):

| Bloque | Acción |
|--------|--------|
| Localizar VM | El script recibe como argumento la ruta al `.vmx` (o la busca con `find` bajo un directorio indicado) |
| Verificar estado | `vmrun list` para confirmar que la VM está **apagada**; abortar si está corriendo o suspendida |
| Localizar VMDKs | Extraer las rutas de los `.vmdk` declarados en el `.vmx` (solo discos, no snapshots intermedios) |
| Espacio previo | Mostrar tamaño real de cada VMDK en el host antes de la operación |
| Defragmentar | `vmware-vdiskmanager -d <disco.vmdk>` (reordena bloques dentro del VMDK) |
| Compactar | `vmware-vdiskmanager -k <disco.vmdk>` (libera bloques de ceros al host) |
| Espacio posterior | Mostrar tamaño real de cada VMDK tras la operación y ahorro conseguido |

**Dependencias**:
- `vmware-vdiskmanager` — incluido con VMware Workstation en `/usr/bin/` o `/usr/lib/vmware/bin/`
- `vmrun` — incluido con VMware Workstation

**Uso previsto**:
```bash
# Compactar una VM concreta
bash CompactaW11.sh /ruta/a/MiVM.vmx

# Buscar y compactar todas las VMs bajo un directorio
bash CompactaW11.sh /ruta/a/carpeta-de-vms/
```

---

## Flujo completo de uso

```
1. Arrancar la VM Windows 11
2. Dentro de la VM: ejecutar LimpiaW11.ps1 como Administrador
   └── Al terminar: apagar la VM (shutdown completo, no suspender)
3. Desde el host Linux: ejecutar CompactaW11.sh apuntando al .vmx
   └── Resultado: VMDK más pequeño → más espacio libre en el host
```

---

## Decisiones de diseño

- **Zero-fill obligatorio**: sin rellenar con ceros el espacio libre (paso `sdelete -z`),
  `vmware-vdiskmanager -k` no puede distinguir bloques vacíos de bloques usados y no
  libera nada. Por eso `LimpiaW11.ps1` termina siempre con ese paso.
- **Defrag antes de compactar**: `vmware-vdiskmanager -d` consolida los datos hacia el
  principio del disco antes de que `-k` recorte la cola vacía; omitirlo reduce el
  ahorro obtenido.
- **Comprobación de estado de la VM**: operar sobre un VMDK mientras la VM corre
  puede corromper el disco; la comprobación con `vmrun list` es obligatoria y el
  script aborta si la VM aparece en la lista.
- **Sin snapshots durante la compactación**: si la VM tiene snapshots activos,
  `vmware-vdiskmanager` rechaza la operación. El script avisará de esta situación
  y dará instrucciones.
- **PowerShell sin dependencias externas (salvo sdelete)**: `LimpiaW11.ps1` usa solo
  cmdlets nativos de PowerShell 5+; la única dependencia externa es `sdelete64.exe`
  para el zero-fill, sin el cual la compactación sería ineficaz.

---

## Ficheros de la carpeta

| Fichero | Descripción |
|---------|-------------|
| `CLAUDE.MD` | Este fichero: descripción del proyecto para Claude Code |
| `LimpiaW11.ps1` | Script PowerShell de limpieza (ejecutar dentro de la VM) |
| `CompactaW11.sh` | Script Bash de defrag+compactación (ejecutar en el host Linux) |

---

## Issues conocidos / limitaciones previstas

- `DISM /ResetBase` es irreversible y puede tardar varios minutos; se incluirá con
  advertencia explícita al usuario.
- `sdelete -z` puede tardar mucho tiempo proporcional al tamaño del disco libre;
  el script mostrará progreso.
- Algunos ficheros de `%TEMP%` pueden estar en uso y no borrarse; el script
  continuará sin abortar.
- La compactación no funciona con discos VMDK de tipo "pre-allocated" (thick); el
  script detectará el tipo y avisará.
