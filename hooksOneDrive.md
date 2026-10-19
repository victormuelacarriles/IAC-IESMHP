# Copia automática del repo a OneDrive tras cada commit (hook `post-commit`)

Cada vez que se hace un commit en este equipo (con el botón **Commit** de VS Code o
con `git commit` en la terminal), git ejecuta un **hook `post-commit`** que hace una
**copia espejo completa** del repo (incluida la carpeta `.git`) en OneDrive:

```
D:\datos\victor\OneDrive - Educantabria\CopiaGitHub\IAC-IESMHP
```

> **Los hooks no se suben a GitHub.** La carpeta `.git/hooks` es local de cada clon.
> En cada equipo nuevo (o tras volver a clonar) hay que **crear estos dos ficheros a
> mano** siguiendo esta guía.

---

## Requisitos

- **Windows** con **Git for Windows**, que ejecuta los hooks con su `sh`.
- **PowerShell** (`powershell.exe`, ya viene con Windows) y **`robocopy`** (también
  viene con Windows).
- La carpeta padre del destino tiene que existir (por ejemplo
  `...\OneDrive - Educantabria\CopiaGitHub`). La carpeta `IAC-IESMHP` la crea
  `robocopy` si no existe.

---

## Paso 1: crear `.git/hooks/post-commit`

Es un fichero **sin extensión**, con finales de línea **LF**. Solo sirve para que git
llame al script de PowerShell:

```sh
#!/bin/sh
# Tras cada commit, copia completa del repo a OneDrive (ver post-commit.ps1)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".git/hooks/post-commit.ps1"
exit 0
```

## Paso 2: crear `.git/hooks/post-commit.ps1`

Es el script que hace la copia. **Si en el otro equipo el destino es distinto,
cambia `$destino`.**

```powershell
# Copia completa (incluida .git) del repo a OneDrive tras cada commit.
# /MIR: el destino queda idéntico al origen (borra allí lo que ya no exista aquí).
$origen  = (git rev-parse --show-toplevel) -replace '/', '\'
$destino = 'D:\datos\victor\OneDrive - Educantabria\CopiaGitHub\IAC-IESMHP'
$log     = Join-Path $origen '.git\post-commit-copia.log'

robocopy $origen $destino /MIR /R:1 /W:1 /NFL /NDL /NP /LOG:$log | Out-Null
# robocopy: 0-7 = correcto, >=8 = errores
if ($LASTEXITCODE -ge 8) {
    Write-Host "post-commit: la copia a OneDrive ha fallado (codigo $LASTEXITCODE). Ver $log"
} else {
    Write-Host "post-commit: copia a OneDrive correcta."
}
exit 0
```

## Paso 3: probarlo sin hacer commit

Desde la raíz del repo, en **Git Bash**:

```sh
sh .git/hooks/post-commit
tail -n 14 .git/post-commit-copia.log
```

Tiene que mostrar `post-commit: copia a OneDrive correcta.` y, en el log, la tabla
de `robocopy` con `ERROR 0`. La primera vez se copia todo; las siguientes solo lo que
haya cambiado.

No hace falta reiniciar VS Code: el hook se activa en el siguiente commit.

---

## Comportamiento y avisos

| Aspecto | Detalle |
|---------|---------|
| **Cuándo se ejecuta** | Justo **después** de que el commit termine. Si la copia falla, el commit sigue siendo válido. |
| **Qué copia** | El **árbol de trabajo completo + `.git`**, no solo lo commiteado. También van los cambios que no hayas metido en el commit. |
| **`/MIR` (espejo)** | Lo que se borre en el repo **también se borra en la copia**. Para que solo añada y actualice, cambia `/MIR` por `/E`. |
| **Sin `.git`** | Si no quieres copiar el historial, añade `/XD .git` a la línea de `robocopy`. |
| **Log** | `.git/post-commit-copia.log` (se sobrescribe en cada commit). |
| **Mensajes** | Aparecen en la salida de git (VS Code: panel *Output* → *Git*). |
| **Push** | No hay hook `post-push`. Si prefieres copiar al hacer push, usa `pre-push`, que se ejecuta justo antes de empujar. |

## Desactivarlo

Borra o renombra `.git/hooks/post-commit` (por ejemplo a `post-commit.off`).
