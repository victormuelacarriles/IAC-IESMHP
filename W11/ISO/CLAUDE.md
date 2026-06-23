# CLAUDE.md — ISO desatendida de Windows 11 (IAC-IESMHP)

Generación de una **ISO de Windows 11 personalizada** que instala el SO sin
intervención y, en el primer inicio de sesión, prepara el equipo y se engancha
con el repo de configuración. Es el equivalente Windows de `Ubuntu/ISO/26.04/`.

> La **instalación de software** (Office, Chrome, VS Code…) NO la hace esta ISO:
> la hace **Ansible por SSH** desde el equipo de control una vez el equipo está
> en red (ver [`../ansible/CLAUDE.md`](../ansible/CLAUDE.md)). Esta carpeta solo
> cubre instalar Windows + dejar el equipo listo y con el repo clonado.

---

## Cadena de ejecución

```
0-CreaIsoW11.sh        ← en Linux (Ubuntu): inserta autounattend.xml + embebe
  │                       0b-GitHub.ps1 (vía $OEM$) y reconstruye la ISO
  └── [ISO bootea → Windows Setup lee autounattend.xml de la raíz]
       │   · Bypass requisitos W11 (TPM/SecureBoot/RAM/CPU/disco)
       │   · Particiona disco 0 (EFI+MSR+C:) e instala la edición elegida
       │   · Crea la cuenta administradora  usuario / usuario@1  + autologon
       └── [primer inicio de sesión → FirstLogonCommands]
            ├─ 1) Escritorio Remoto SEGURO (RDP + NLA + firewall)
            ├─ 2) winget install Git.Git (acepta licencia y fuente)
            └─ 3) C:\Windows\Setup\Scripts\0b-GitHub.ps1   (embebido en la ISO)
                 └── clona el repo (sparse: raíz + W11) en
                     "C:\Program Files\IAC-IESMHP"
                      └── C:\Program Files\IAC-IESMHP\W11\ISO\1-Setup.ps1
```

---

## Ficheros de esta carpeta

| Fichero | Dónde corre | Qué hace |
|---------|-------------|----------|
| `0-CreaIsoW11.sh` | Linux (build) | Monta la ISO original, añade `autounattend.xml` a la raíz, embebe `0b-GitHub.ps1` en `$OEM$`, trocea `install.wim` si >4 GiB y reconstruye con `xorriso`. |
| `autounattend.xml` | Windows Setup | Answer file: bypass requisitos, particionado, edición sin clave, cuenta `usuario`/`usuario@1` + autologon y `FirstLogonCommands` (RDP seguro, git, lanzar `0b-GitHub.ps1`). |
| `0b-GitHub.ps1` | Windows (1er login) | Localiza git, clona el repo con **sparse-checkout cono** (solo raíz + `W11`) en `C:\Program Files\IAC-IESMHP` y lanza `1-Setup.ps1`. Embebido por el build en `C:\Windows\Setup\Scripts\`. Log: `C:\Windows\Setup\Scripts\0b-GitHub.ps1.log`. |
| `1-Setup.ps1` | Windows (post-clonado) | Configuración local: (1a) busca la MAC del equipo en `macs.csv` (raíz del repo) → renombra (sin reiniciar) y fija **IP estática** conservando máscara/gw/DNS y cambiando solo el último octeto (`IPf`); (1b) instala **OpenSSH** (cliente+servidor, sshd auto, firewall, `DefaultShell=powershell`) y autoriza las claves de `Autorizados.txt`. Log: `…\1-Setup.ps1.log`. |
| `tutorial-iso-windows11-autounattend.md` | — | Tutorial largo (teoría + métodos Windows `oscdimg` y Linux `xorriso`). |

---

## Construir la ISO

```bash
sudo apt install xorriso wimtools
cd W11/ISO
chmod +x 0-CreaIsoW11.sh

# autounattend.xml y 0b-GitHub.ps1 se toman de esta misma carpeta por defecto
./0-CreaIsoW11.sh -i ~/Descargas/Win11_original.iso \
                  -a autounattend.xml \
                  -o ~/Descargas/Win11_custom.iso
#   -s OTRO.ps1   usa otro script de bootstrap (por defecto ./0b-GitHub.ps1)
#   --split       fuerza trocear install.wim aunque no llegue a 4 GiB
```

Verifica que la ISO lleva arranque BIOS+UEFI, `autounattend.xml` en la raíz y
`0b-GitHub.ps1` en `/sources/$OEM$/$$/Setup/Scripts/` (el script lo comprueba al
final). **Prueba SIEMPRE en una VM (UEFI + TPM) antes de hardware real.**

---

## Decisiones y convenciones

- **Nomenclatura `0-…` / `0b-…` / `1-…`** alineada con Ubuntu (`0a-CreaISO.sh`,
  `0b-Github.sh`, `1-SetupLiveCD.sh`). El bootstrap se llama **`0b-GitHub.ps1`**
  (no `0-GitHub.ps1`).
- **Cuenta por defecto `usuario` / `usuario@1`** (password EN CLARO en el XML;
  trátalo como secreto). Es administrador y tiene autologon (lo exige
  `FirstLogonCommands`).
- **Escritorio Remoto seguro** = RDP con **NLA** (`UserAuthentication=1`), mismos
  ajustes que el rol Ansible [`escritorioRemoto`](../ansible/roles/escritorioRemoto/CLAUDE.md):
  `fDenyTSConnections=0` + grupo de firewall por id (`@FirewallAPI.dll,-28752`,
  independiente del idioma de Windows).
- **Git por winget** con `--accept-package-agreements --accept-source-agreements`
  para no detenerse a aceptar licencia/fuente. Se instala antes de clonar.
- **`$OEM$` para embeber el script**: lo que cuelga de `sources/$OEM$/$$/` acaba
  en `C:\Windows\`; por eso `…/$$/Setup/Scripts/0b-GitHub.ps1` →
  `C:\Windows\Setup\Scripts\0b-GitHub.ps1`. Windows Setup lo copia solo al usar
  un answer file. Robustez frente a no tener red en el 1er arranque (no depende
  de descargar el bootstrap, solo el repo).
- **Sparse-checkout en modo cono** (`git sparse-checkout init --cone` +
  `set W11`): incluye **siempre** los ficheros de la raíz del repo + la carpeta
  `W11` (y sus descendientes), y **excluye** `Mint/`, `ThinStation/`, `Ubuntu/`…
  El clonado es `--filter=blob:none --no-checkout --depth 1` para no traer el
  histórico ni blobs de lo que no se materializa.
- **`xorriso -as mkisofs`, no método nativo** (`replay`/`keep`): las ISOs de
  Win11 24H2/25H2 ocultan las imágenes El Torito → `replay` falla y `keep` a un
  fichero distinto solo escribe una sesión incremental (ISO de pocos KB). Por eso
  se monta en RO y se reconstruye. Detalle en `tutorial-iso-…md` §11.
- **`install.wim` > 4 GiB**: ISO 9660 limita a 4 GiB por fichero; se trocea en
  `.swm` con `wimlib-imagex split` (<3800 MB) y se excluye el `.wim` original.

---

## `1-Setup.ps1` — detalle

- **1a) MAC → nombre + IP estática** (equivalente a `NombreIP.sh` de Ubuntu):
  parsea `macs.csv` de la raíz del repo (`MAC, Equipo, IPf, Comentario`,
  **separado por comas**). El parser divide cada línea por comas, valida que el
  1er campo sea una MAC (regex anclada) e ignora `#` y la cabecera. Si una NIC
  del equipo está en el listado:
  `Rename-Computer` **sin** reiniciar y conversión a IP estática manteniendo
  máscara, puerta de enlace y DNS actuales, sustituyendo solo el **último octeto**
  por `IPf`. Si no hay coincidencia, no toca nada.
- **1b) OpenSSH** siguiendo `../Utiles/Openssh/ProcedimientoOpenss.txt`, pero
  leyendo `Autorizados.txt` **del repo local** (no por `Invoke-RestMethod`), con
  dedup contra `administrators_authorized_keys` y los `icacls` correctos
  (`SYSTEM` + `S-1-5-32-544`). Deja `DefaultShell=powershell` (lo exige Ansible).
- **Idempotente** y tolerante a fallos (cada bloque en su `try/catch`; un fallo
  no aborta el resto). Log: `C:\Windows\Setup\Scripts\1-Setup.ps1.log`.

## TODO / pendientes

1. **winget en el 1er logon**: en imágenes recién instaladas App Installer puede
   tardar en registrarse: en el primer logon el alias `winget.exe` de
   `WindowsApps` aún no existe y `winget` "no se reconoce" (confirmado en VM
   2026-06-23). `0b-GitHub.ps1` lo maneja: **espera** a que winget aparezca
   (hasta ~60 s) y, si no, **descarga el instalador oficial de Git** desde
   GitHub y lo instala en silencio (`/VERYSILENT`). El `winget install` del
   `FirstLogonCommands` (Order 2) queda como vía rápida best-effort.
3. **Edición de Windows**: `autounattend.xml` fija `Windows 11 Pro`; ajustar al
   nombre exacto del `install.wim` (`wiminfo sources/install.wim`).
4. **Activación**: clave en blanco ⇒ sin activar (puede autoactivarse con clave
   OEM en firmware o KMS de red). Ver `tutorial-…md` §5 y §12.
