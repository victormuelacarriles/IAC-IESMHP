# Rol `AnalisisEquipo` (como root)

Análisis de hardware de cada equipo del aula: **sistema, CPU, memoria, discos,
GPU NVIDIA, estrés largo y errores del kernel**. Mide el tiempo de cada paso y
deja **un resumen por equipo** (y un CSV para comparar todos).

Mismo esquema que los roles de [`rolesUsuario`](../../rolesUsuario/CLAUDE.md)
(`VirtualW11`, `AODappsflatpack`): playbook propio en la carpeta del rol,
lanzador `.sh` con parámetros y tabla de tiempos. La diferencia: **entra
siempre como root**, con los inventarios de aula (`equiposSMRD.ini`,
`equiposIABD.ini`, `ansible_user=root`). **No está en `roles.yaml`**: se lanza
a mano.

Creado el 2026-10-26.

## Uso — `AnalisisEquipo.sh`

```bash
cd /opt/IAC-IESMHP/Ubuntu/ansible/roles/AnalisisEquipo
bash AnalisisEquipo.sh SMRD                       # toda el aula, completo (~30-50 min)
bash AnalisisEquipo.sh IABD -l IABD-05            # un equipo
bash AnalisisEquipo.sh SMRD --sin-estres          # rápido (~3-5 min por equipo)
bash AnalisisEquipo.sh SMRD --estres-min 30 --gpu-min 15
bash AnalisisEquipo.sh SMRD --pasos discos,kernel # solo salud de discos y errores
sudo bash AnalisisEquipo.sh                       # en local (este equipo)
bash AnalisisEquipo.sh --ayuda
```

| Opción | Qué hace |
|---|---|
| `SMRD` / `IABD` / `<equipos.ini>` | Inventario de aula (`Ubuntu/ansible/equipos*.ini`). Sin él, en local (como root) |
| `-l PATRÓN` | Equipos, como en Ansible (`SMRD-05`, `'SMRD-0*'`, `'all:!SMRD-00'`) |
| `--forks N` | Equipos a la vez (**30**: cada uno se mide a sí mismo; también `FORKS=N`) |
| `--pasos L` | Solo esos: `sistema,cpu,memoria,discos,gpu,estres,kernel` |
| `--sin-estres` | Sin stress-ng, memtester ni estrés de GPU |
| `--sin-pruebas` | Solo datos y salud: sin pruebas de rendimiento ni estrés |
| `--estres-min N` | Minutos de stress-ng CPU+RAM (**10**; 0 = no) |
| `--memtester-pct N` | % de la RAM disponible para memtester (**25**; 0 = no; máx 80) |
| `--memtester-max N` | Minutos máximos de memtester (**30**) |
| `--gpu-min N` | Minutos de estrés de la GPU NVIDIA (**5**; 0 = no) |
| `--disco-gb N` | GB del fichero de prueba de escritura (**2**) |
| `--temp-max N` | °C de CPU a los que se **corta** el estrés (**95**) |
| `--forzar` | Estrés aunque haya usuarios con sesión (por defecto se salta) |
| `--sin-instalar` | No instala con apt las herramientas que falten |
| resto (`-v`, `-e …`) | A `ansible-playbook` |

Sin preguntas (headless). En otros equipos la clave SSH de root del que lanza
tiene que estar autorizada (rol `certificados`).

### Resultados
- **En el equipo que lanza** (`/var/log/IAC-IESMHP/` o
  `~/.local/state/IAC-IESMHP/` si no se puede escribir allí):
  - `AnalisisEquipo.log`: salida completa de cada ejecución (se va añadiendo).
  - `AnalisisEquipo/<equipo>-ultimo.txt`: **el resumen más reciente de cada
    equipo**. Histórico en `AnalisisEquipo/<equipo>/resumen-<fecha>.txt`.
  - `AnalisisEquipo/AnalisisEquipo-<fecha>.csv`: una fila por equipo con todos
    los datos (modelo, CPU, RAM, tiempos, MB/s, temperaturas, salud de
    discos…). Separador `;`, decimales con punto.
- **En cada equipo**, `/var/log/IAC-IESMHP/AnalisisEquipo/`:
  `resumen-<fecha>.txt`, `ultimo-resumen.txt` y `analisis-<fecha>.log` (salida
  bruta de cada herramienta: smartctl, fio, stress-ng…). Para seguirlo en
  marcha: `ssh root@equipo tail -f /var/log/IAC-IESMHP/AnalisisEquipo/analisis-*.log`.
- Al final, **tabla de TIEMPOS**: por equipo (total y estado) y debajo una
  línea por paso (tiempo, estado y el dato clave), recuento de estados y
  tiempo medio/máximo por paso.

### Estados
Por paso y global (el peor de los pasos): `OK` < `NO_APLICA` (sin NVIDIA) <
`NO_MEDIDO` (falta una herramienta, disco sin SMART, estrés saltado) < `AVISO`
< `ERROR`. Además, en la tabla: `SIN_RESPUESTA` (apagado / sin SSH) y
`FALLO_ANALISIS` (no se pudo ejecutar el script). Códigos de `analiza.sh`:
0 OK · 1 avisos · 2 errores de hardware · 3 no se pudo analizar. Los avisos y
errores de hardware **no** cuentan como fallo de Ansible.

## Estructura

| Fichero | Qué es |
|---|---|
| `AnalisisEquipo.sh` | Lanzador: parámetros, latido, `<equipo>-ultimo.txt`, tabla de tiempos y CSV |
| `AnalisisEquipo.yaml` | Playbook: `become: yes`, `strategy: free`, ping y salto de los apagados, `rescue` por equipo, línea `TIEMPO\|equipo\|…` |
| `defaults/main.yml` | Duraciones, paquetes, directorios de prueba |
| `tasks/main.yml` | Comprueba root, instala herramientas (tolerante), copia y lanza `analiza.sh` en `async`, trae el resumen con `fetch` |
| `files/analiza.sh` | **Todo el análisis**, en el equipo. Vale suelto: `sudo bash analiza.sh --ayuda` |

## Qué mide cada paso (`files/analiza.sh`)

| Paso | Datos y salud | Prueba con tiempos | Avisos / errores |
|---|---|---|---|
| `sistema` | Fabricante, modelo, placa, BIOS, nº de serie, SO, kernel, red (IP, MAC, velocidad), Secure Boot, sesiones abiertas | — | Red < 1000 Mb/s |
| `cpu` | Modelo, núcleos/hilos, MHz máx, gobernador, temperatura en reposo | sysbench (primos hasta 10000): 20000 eventos con 1 hilo y 20000×N con todos → **segundos** y eventos/s | ≥ 70 °C en reposo |
| `memoria` | Total, disponible, swap, módulos (dmidecode: ranura, tamaño, tipo, velocidad configurada/máxima, fabricante, modelo), ECC/EDAC | sysbench memory: 20 GB con 1 hilo y 100 GB con todos → segundos y MiB/s | EDAC: corregibles = AVISO, no corregibles = ERROR |
| `discos` | Por disco: tipo, tamaño, modelo, SMART (smartctl JSON: estado, temperatura, horas, desgaste/reserva/errores NVMe, sectores reasignados/pendientes SATA); ocupación; pools ZFS (salud, dedup, errores, último scrub) | `fio` **solo lectura** sobre el disco en bruto (secuencial 1M y aleatoria 4k, 15 s cada una) y, una vez por disco/pool, escribir y leer `--disco-gb` GB en `/`, `/home`, `/datos` (+ 4k aleatoria 15 s); fichero borrado al acabar | SMART falla o aviso crítico NVMe = ERROR; desgaste ≥ 90 %, reserva ≤ 10 %, sectores malos, ≥ 70 °C, NVMe < 500 MB/s, SSD < 200 MB/s, FS ≥ 90 %; pool ZFS no ONLINE = ERROR |
| `gpu` | Solo NVIDIA: modelo, driver, memoria, temperatura, consumo, enlace PCIe actual/máximo | `clpeak` (OpenCL): GFLOPS simple precisión y GB/s de memoria, tiempo, gen PCIe con carga | NVIDIA sin driver = ERROR; PCIe con menos carriles o generación de la posible |
| `estres` | — | **stress-ng** N min (todos los hilos `--cpu-method all` + 2 trabajadores con el 40 % de la RAM disponible y `--verify`), vigilando temperatura y MHz cada 5 s; **memtester** (1 pasada, % de la RAM disponible); **GPU** N min con `gpu_burn` si está o `clpeak` en bucle, vigilando temperatura, consumo, reloj y motivos de bajada | Corte por `--temp-max` = ERROR; fallos de stress-ng/memtester/gpu_burn = ERROR; CPU ≥ 90 °C, bajadas de frecuencia por calor, < 50 % de los MHz máx; GPU ≥ 90 °C, bajada de reloj por calor/hardware; errores Xid nuevos = ERROR |
| `kernel` | Mensajes del kernel desde el arranque: MCE, Hardware Error, EDAC, I/O error, NVMe timeout/reset, ATA, Xid, Oops, lockups, thermal (agrupados, los 8 más repetidos) | — | MCE = ERROR; otros = AVISO (cuenta aparte los aparecidos durante el análisis) |

## Notas y avisos

- **El estrés se salta si hay alguien con sesión** (UID ≥ 1000, sin
  `gdm-greeter`): no se le cuelga el equipo a un alumno. Sale `NO_MEDIDO`
  «saltado (sesión de X)». Lanzarlo con el aula vacía o `--forzar`.
- **El `-00` suele ser el servidor del aula**: con estrés va lento durante
  ~30 min. Si hace falta, excluirlo: `-l 'all:!SMRD-00'`.
- **Un solo análisis a la vez por equipo** (`flock` en
  `/var/log/IAC-IESMHP/AnalisisEquipo/.en-marcha`). Ctrl+C en el lanzador **no
  para** el análisis en los equipos (va en `async`); su resumen se queda en
  el equipo. Relanzar mientras sigue da `FALLO_ANALISIS` («ya hay un análisis
  en marcha»).
- **ZFS**: la lectura del fichero de prueba puede salir de la caché ARC
  (velocidades infladas) y la escritura incluye compresión zstd y, en `rpool`,
  dedup (datos aleatorios con `--refill_buffers`, así que no deduplica). La
  lectura **en bruto** del disco (fio `--readonly` sobre `/dev/…`) sí es
  real y es segura aunque sea miembro de un pool.
- **GPU** (pendiente de probar en un equipo con NVIDIA): `clpeak` necesita el
  OpenCL de NVIDIA (`/etc/OpenCL/vendors/nvidia.icd`, viene con el driver que
  pone el rol [`nvidia`](../nvidia/CLAUDE.md)). Si no lo ve, sale
  `NO_MEDIDO`. Con varias GPU se mide la 0. Para un estrés más duro, instalar
  `gpu_burn` en el `PATH` (se usa si está; detecta resultados `FAULTY`).
- Con un fallo de `apt` (sin red, repo roto) el rol **sigue**: lo que falte
  sale `NO_MEDIDO`. `clpeak`/`clinfo` solo se instalan si hay NVIDIA.
- Tiempo máximo del `async`: 25 min + estrés + memtester-max + gpu-min.
- Sin dependencias gráficas: nada de `zenity`/`notify-send`, stdin a
  `/dev/null`, todo a fichero.

## Pruebas (2026-10-26, en el equipo del propietario, local y sin root)

Con `ANALISIS_SIN_ROOT=1` / `-e AnalisisEquipo_sin_root=true -e ansible_become=false`
y las herramientas extraídas de sus `.deb` (sin instalar), en un Ryzen 9 7900X:
- `analiza.sh` completo corto (`--estres-min 1 --memtester-pct 2`): sysbench
  CPU 3,2 s (1 hilo) / 6,5 s (24 hilos), memoria 46 / 77 GiB/s, stress-ng 1 min
  (94 °C máx → AVISO), memtester correcto.
- Discos: ext4 `/var/tmp` escribir 1 GB 1,7 s (602 MB/s); ZFS `rpool/home`
  2,2 s (465 MB/s); un directorio en tmpfs se salta con aviso; ficheros de
  prueba borrados. SMART y lectura en bruto necesitan root (salen `NO_MEDIDO`).
- Cadena completa `AnalisisEquipo.sh` → playbook → rol → `fetch`: tabla de
  tiempos, `<equipo>-ultimo.txt` y CSV correctos. Errores de parámetros
  (`-l` inexistente, número mal, inventario o paso desconocido).
- Corregido en las pruebas: `gdm-greeter` contaba como sesión (saltaba siempre
  el estrés) y la línea «failed: 0» de stress-ng daba un ERROR falso.
- **Pendiente**: probarlo como root en un equipo real (`SMRD -l <uno>`), en
  uno con NVIDIA (IABD) y la duración real del estrés completo.
