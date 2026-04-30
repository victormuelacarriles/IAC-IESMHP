# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Propósito del proyecto

**IAC-IESMHP** (Infraestructura como Código — IES Miguel Herrero, Torrelavega): automatización completa del despliegue y configuración de equipos Linux en las aulas del centro. Cubre dos distribuciones:

| Distribución   | Carpeta    | Estado        |
|----------------|------------|---------------|
| Linux Mint 22.x Cinnamon | `Mint/`  | Producción    |
| Ubuntu 26.04 Desktop     | `Ubuntu/` | Producción    |

El flujo general en ambos casos es idéntico: se genera una ISO personalizada → la ISO arranca en el equipo → particiona los discos e instala el SO sin intervención → al primer arranque se instala Ansible y se ejecutan los playbooks.

---

## Estructura del repositorio

```
IAC-IESMHP/
├── macs.csv            ← Mapeo MAC → hostname → octeto IP final (compartido por Mint y Ubuntu)
├── Autorizados.txt     ← Claves SSH públicas autorizadas en root y usuario
│
├── Mint/
│   ├── CLAUDE.md       ← Documentación detallada de Mint
│   ├── ControlIABD/    ← Scripts Wake-on-LAN para aula IABD
│   ├── ControlSMRD/    ← Scripts Wake-on-LAN para aula SMRD
│   ├── ISO/
│   │   ├── 22.1/       ← Scripts completos para Mint 22.1
│   │   └── 22.3/       ← Solo utiles/ por ahora (pendiente 0a-CreaISO.sh)
│   ├── ansible/        ← Playbooks y 13 roles Ansible
│   └── utiles/         ← Versión más actualizada de Auto-Ansible.sh, NombreIP.sh, etc.
│
└── Ubuntu/
    ├── CLAUDE.md       ← Documentación detallada de Ubuntu
    └── ISO/
        └── 26.04/      ← Scripts completos para Ubuntu 26.04
```

**Para documentación detallada de cada distribución, leer su propio `CLAUDE.md`.**

---

## Datos compartidos entre distribuciones

### `macs.csv` — Registro de equipos
Formato: `MAC, Equipo, IPf, Comentario`
- `MAC`: dirección MAC de la interfaz de red principal.
- `Equipo`: hostname asignado (prefijo-número, ej: `IABD-01`). El `-00` se reserva para el profesor.
- `IPf`: último octeto de la IP (la subred se detecta por aula).
- Líneas con `#` son comentarios.

Aulas registradas:
- **IABD** (CEIABD): IABD-00 a IABD-20 → subred `10.0.72.x`
- **SMRD** (Distancia): SMRD-00 a SMRD-18 → subred `10.0.32.x`
- VMs de prueba: VM-01, VM-02

### `Autorizados.txt` — Claves SSH
Claves SSH públicas que se copian a `/root/.ssh/authorized_keys` y `/home/usuario/.ssh/authorized_keys` durante la instalación. Permite acceso sin contraseña desde los equipos de gestión.

---

## Red y proxies

| Aula    | Subred         | Proxy apt                |
|---------|----------------|--------------------------|
| IABD    | 10.0.72.0/24   | 10.0.72.140:3128         |
| SMRD    | 10.0.32.0/24   | 10.0.32.119:3128         |

La detección del aula se hace por el tercer octeto de la IP en tiempo de ejecución.

---

## Cadena de ejecución (resumen)

### Mint
```
0a-CreaISO.sh → ISO bootea → setup.desktop (autostart Cinnamon) → 0b-Github.sh
  → 1-SetupLiveCD.sh → 2-SetupSOdesdeLiveCD.sh (chroot) → reboot
  → 3-SetupPrimerInicio.service (full-upgrade + Ansible)
```

### Ubuntu 26.04
```
0a-CreaISO.sh → ISO bootea → iac-iesmhp-launch.sh (autostart GNOME) → iac-iesmhp-run.sh
  → 0b-Github.sh → 1-SetupLiveCD.sh → 2-SetupSOdesdeLiveCD.sh (chroot) → reboot
  → 3-SetupPrimerInicio.service → 4-Comprobaciones.sh
```

---

## Diferencias clave entre Mint y Ubuntu

| Aspecto                   | Mint 22.x                             | Ubuntu 26.04                          |
|---------------------------|---------------------------------------|---------------------------------------|
| squashfs                  | Único (`filesystem.squashfs`)         | Multicapa (minimal + standard + live) |
| Arranque                  | BIOS + UEFI (isolinux + grub/efi)     | Solo UEFI                             |
| Autostart                 | `setup.desktop` en `/home/mint/`      | `iac-iesmhp-setup.desktop` en skel + home ubuntu |
| snapd                     | No relevante                          | Enmascarado (`/dev/null`) para evitar bootstrap snap y reducir arranque de 3 min a 10 s |
| Comprobaciones            | No hay script dedicado                | `4-Comprobaciones.sh` (diagnóstico)   |
| Versión GRUB bootloader-id| `MINT`                                | `ubuntu` (genera update-grub)         |
| Ansible                   | En `Mint/ansible/` con 13 roles       | No incluido aún en Ubuntu             |
| Control de aulas (WoL)    | `ControlIABD/`, `ControlSMRD/`        | No incluido                           |

---

## Comandos más frecuentes

### Actualizar el repo en los equipos instalados
```bash
cd /opt/IAC-IESMHP && git reset --hard origin/main && git pull
```

### Ping a todos los equipos de un aula
```bash
ansible all -i /opt/IAC-IESMHP/Mint/ansible/equiposIABD.ini -m ping
```

### Ejecutar un rol Ansible en un equipo concreto
```bash
cd /opt/IAC-IESMHP/Mint/ansible
ansible-playbook -i ./equiposIABD.ini roles.yaml -l IABD-17
```

### Encender/apagar aulas (desde equipo con `wakeonlan`)
```bash
bash /opt/IAC-IESMHP/Mint/ControlIABD/EnciendeAula.sh
bash /opt/IAC-IESMHP/Mint/ControlSMRD/EnciendeSMRD.sh
```

---

## Convenciones del proyecto

- Los scripts se numeran `0a`, `0b`, `1`, `2`, `3`, `4`... para reflejar el orden de ejecución.
- Los logs se guardan en `/var/log/IAC-IESMHP/<Distro>/`.
- El repo se clona siempre en `/opt/IAC-IESMHP/` en los equipos instalados.
- Los scripts terminan con `echo "Correcto"` cuando tienen éxito; el script anterior comprueba la última línea del log para decidir si reiniciar o esperar.
- Las claves SSH usan `ed25519`; la clave pública de cada equipo se agrega a su propio `authorized_keys` para que Ansible pueda conectar en local.
