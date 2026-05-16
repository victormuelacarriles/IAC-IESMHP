# Rol `nvidia`

## Contexto
Pensado para **Ubuntu Desktop 26.04**, que trae **soporte nativo de drivers
NVIDIA**: el metapaquete `ubuntu-drivers-common` selecciona e instala el driver
**recomendado** por Ubuntu para la GPU detectada (ya no hay que fijar a fuego
una serie antigua como `nvidia-driver-535`).

## Qué hace
Instala el driver propietario de NVIDIA **solo si se detecta una GPU NVIDIA** en el equipo:

1. `lspci` → detecta si hay cadena `NVIDIA` (`has_nvidia`).
2. Si **no** hay GPU NVIDIA: muestra mensaje y salta todo el bloque (el playbook continúa, *no* aborta).
3. Si **hay** GPU NVIDIA:
   - Instala `ubuntu-drivers-common` (gestor nativo de drivers de Ubuntu).
   - Comprueba si el driver ya está operativo (`nvidia-smi`). Si lo está, **no
     reinstala** (idempotente).
   - Si no lo está, instala el driver:
     - `required_nvidia_driver == ""` → `ubuntu-drivers install` (driver
       **recomendado** por Ubuntu 26.04, comportamiento por defecto).
     - `required_nvidia_driver == "NNN"` → fuerza `nvidia-driver-NNN` (pin
       manual a una serie concreta).
   - **Reinicia** el equipo solo si se acaba de instalar el driver.
   - Comprueba la versión instalada con `nvidia-smi`.
   - Informa del driver **recomendado** por `ubuntu-drivers devices` y lo
     compara con el instalado (solo informa, no actualiza).

## Estructura
- `tasks/main.yml`
- `defaults/main.yml`:
  - `required_nvidia_driver: ""` — vacío = driver recomendado por Ubuntu
    (nativo 26.04). Asignar una serie (`"570"`, `"575"`, …) solo si hay que
    pinear manualmente.

> La variable `required_kernel` se eliminó: la comprobación de kernel estaba
> comentada y Ubuntu 26.04 gestiona la compatibilidad kernel/driver de forma
> nativa vía DKMS.

## Notas
- El reinicio (`reboot`) se dispara dentro del playbook **solo** cuando el
  driver no estaba operativo y se acaba de instalar:
  `connect_timeout=5`, `reboot_timeout=600`, `post_reboot_delay=30`.
- Si el driver ya está cargado, el rol es idempotente (no instala, no reinicia).
- Solo **avisa** si el driver recomendado difiere del instalado; no actualiza
  automáticamente.
- En equipos sin NVIDIA (la mayoría de las VMs de prueba) el rol es prácticamente un no-op.
