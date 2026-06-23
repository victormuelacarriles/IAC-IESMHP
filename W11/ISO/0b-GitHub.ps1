#Requires -Version 5.1
<#
  0b-GitHub.ps1  -  Bootstrap de IAC-IESMHP en Windows 11
  ============================================================================
  Lo lanza el autounattend.xml (FirstLogonCommands) en el primer inicio de
  sesion. Va embebido en la ISO via $OEM$ y acaba en
  C:\Windows\Setup\Scripts\0b-GitHub.ps1 (lo coloca alli 0-CreaIsoW11.sh).

  Hace:
    1. Localiza git (lo instala Order 2 del autounattend; si aun no esta en el
       PATH lo busca en rutas conocidas; como ultimo recurso lo instala con
       winget).
    2. Clona https://github.com/victormuelacarriles/IAC-IESMHP.git en
       "C:\Program Files\IAC-IESMHP" con sparse-checkout en modo cono, dejando
       SOLO los ficheros de la raiz y la subcarpeta W11 (no baja Mint /
       ThinStation / Ubuntu ni ninguna otra). Si ya existe, hace pull.
    3. Ejecuta "C:\Program Files\IAC-IESMHP\W11\ISO\1-Setup.ps1".

  Equivalente Windows de 0b-Github.sh (Ubuntu). Idempotente: se puede relanzar.
  ============================================================================
#>
[CmdletBinding()]
param(
  [string]$RepoUrl  = 'https://github.com/victormuelacarriles/IAC-IESMHP.git',
  [string]$Dest     = 'C:\Program Files\IAC-IESMHP',
  [string]$Subdir   = 'W11',                 # subcarpeta a conservar (+ raiz)
  [string]$Branch   = 'main'
)

$ErrorActionPreference = 'Stop'

# --- Log -------------------------------------------------------------------
$LogDir = 'C:\Windows\Setup\Scripts'
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }
$LogFile = Join-Path $LogDir '0b-GitHub.ps1.log'

function Log {
  param([string]$Msg)
  $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Msg
  Write-Host $line
  Add-Content -Path $LogFile -Value $line -Encoding UTF8
}

Log "===== 0b-GitHub.ps1 inicio ====="
Log "Repo=$RepoUrl  Dest=$Dest  Subdir=$Subdir  Branch=$Branch"

# --- Refrescar PATH del proceso (winget acaba de instalar git) -------------
$env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
            [Environment]::GetEnvironmentVariable('Path','User')

# --- Localizar git.exe -----------------------------------------------------
function Find-Git {
  $g = Get-Command git.exe -ErrorAction SilentlyContinue
  if ($g) { return $g.Source }
  foreach ($p in @(
      "$env:ProgramFiles\Git\cmd\git.exe",
      "${env:ProgramFiles(x86)}\Git\cmd\git.exe",
      "$env:LOCALAPPDATA\Programs\Git\cmd\git.exe")) {
    if (Test-Path $p) { return $p }
  }
  return $null
}

$Git = Find-Git
if (-not $Git) {
  Log "git no encontrado; intento instalarlo con winget..."
  try {
    & winget install --id Git.Git -e --source winget `
        --accept-package-agreements --accept-source-agreements --silent
  } catch { Log "winget fallo: $($_.Exception.Message)" }
  # Refrescar PATH otra vez y reintentar localizar
  $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
              [Environment]::GetEnvironmentVariable('Path','User')
  Start-Sleep -Seconds 5
  $Git = Find-Git
}
if (-not $Git) {
  Log "ERROR: git sigue sin estar disponible. Abortando."
  exit 1
}
Log "git = $Git"

# --- Esperar a que haya red (12 reintentos x 5 s, como en Ubuntu) ----------
$online = $false
for ($i = 1; $i -le 12; $i++) {
  if (Test-Connection -ComputerName 'github.com' -Count 1 -Quiet) { $online = $true; break }
  Log "Sin red, reintento $i/12..."
  Start-Sleep -Seconds 5
}
if (-not $online) { Log "AVISO: no hay conectividad con github.com; intento clonar igualmente." }

# --- Clonar / actualizar con sparse-checkout (cono => raiz + $Subdir) ------
$gitDir = Join-Path $Dest '.git'
try {
  if (Test-Path $gitDir) {
    Log "El repo ya existe; actualizando (fetch + sparse + pull)..."
    & $Git -C $Dest sparse-checkout set $Subdir
    & $Git -C $Dest fetch --depth 1 origin $Branch
    & $Git -C $Dest checkout $Branch
    & $Git -C $Dest pull --ff-only origin $Branch
  } else {
    $parent = Split-Path $Dest -Parent
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    if (Test-Path $Dest) { Remove-Item -Recurse -Force $Dest }  # carpeta vacia/parcial

    Log "Clonando (no-checkout, sin blobs)..."
    & $Git clone --filter=blob:none --no-checkout --depth 1 --branch $Branch $RepoUrl $Dest

    # Modo cono: incluye SIEMPRE los ficheros de la raiz + las carpetas dadas.
    Log "sparse-checkout (cono) -> solo raiz + $Subdir"
    & $Git -C $Dest sparse-checkout init --cone
    & $Git -C $Dest sparse-checkout set $Subdir
    & $Git -C $Dest checkout $Branch
  }
} catch {
  Log "ERROR al clonar/actualizar: $($_.Exception.Message)"
  exit 1
}
Log "Repo listo en $Dest"

# --- Lanzar 1-Setup.ps1 ----------------------------------------------------
$Setup = Join-Path $Dest 'W11\ISO\1-Setup.ps1'
if (Test-Path $Setup) {
  Log "Ejecutando $Setup ..."
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Setup
  Log "1-Setup.ps1 termino con codigo $LASTEXITCODE"
} else {
  Log "AVISO: no existe $Setup (aun). Nada que ejecutar."
}

Log "===== 0b-GitHub.ps1 fin ====="
