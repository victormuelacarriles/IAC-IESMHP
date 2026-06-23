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

# --- Helpers ---------------------------------------------------------------
function Sync-ProcessPath {
  # Reconstruye el PATH del proceso desde Maquina + Usuario e incluye
  # explicitamente WindowsApps, donde vive el ALIAS de ejecucion winget.exe.
  # En el primer inicio de sesion ese alias puede no estar aun en el PATH.
  $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
              [Environment]::GetEnvironmentVariable('Path','User') + ';' +
              (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps')
}

function Find-Git {
  Sync-ProcessPath
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

function Find-Winget {
  Sync-ProcessPath
  $w = Get-Command winget.exe -ErrorAction SilentlyContinue
  if ($w) { return $w.Source }
  $alias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
  if (Test-Path $alias) { return $alias }
  return $null
}

function Install-GitViaWinget {
  # CAUSA DEL FALLO ORIGINAL: en el primer inicio de sesion del usuario recien
  # creado, winget (App Installer, paquete MSIX) aun NO esta registrado para
  # ese usuario -> 'winget' no se reconoce. Se registra unos segundos despues.
  # Por eso esperamos a que aparezca (hasta ~60 s) en lugar de rendirnos.
  $winget = $null
  for ($i = 1; $i -le 12; $i++) {
    $winget = Find-Winget
    if ($winget) { break }
    Log "winget aun no registrado, espero ($i/12)..."
    Start-Sleep -Seconds 5
  }
  if (-not $winget) { Log "winget no aparecio; paso a descarga directa."; return $false }
  Log "winget = $winget ; instalando Git.Git..."
  try {
    & $winget install --id Git.Git -e --source winget `
        --accept-package-agreements --accept-source-agreements --silent
    return ($LASTEXITCODE -eq 0)
  } catch { Log "winget fallo: $($_.Exception.Message)"; return $false }
}

function Install-GitViaDownload {
  # PLAN B (no depende de winget/MSIX): descarga el instalador oficial de Git
  # para Windows desde GitHub y lo ejecuta en silencio. Solo necesita red.
  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $api = 'https://api.github.com/repos/git-for-windows/git/releases/latest'
    Log "Descarga directa: consultando $api ..."
    $rel   = Invoke-RestMethod -Uri $api -Headers @{ 'User-Agent' = 'IAC-IESMHP' }
    $asset = $rel.assets |
             Where-Object { $_.name -match 'Git-.*-64-bit\.exe$' } |
             Select-Object -First 1
    if (-not $asset) { Log "No encuentro instalador Git 64-bit en la release."; return $false }
    $exe = Join-Path $env:TEMP $asset.name
    Log "Descargando $($asset.name) ..."
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $exe -UseBasicParsing
    Log "Instalando Git en silencio ..."
    $p = Start-Process -FilePath $exe `
           -ArgumentList '/VERYSILENT','/NORESTART','/SUPPRESSMSGBOXES','/NOCANCEL','/SP-' `
           -Wait -PassThru
    Log "Instalador Git termino con codigo $($p.ExitCode)"
    return ($p.ExitCode -eq 0)
  } catch { Log "Descarga/instalacion directa de Git fallo: $($_.Exception.Message)"; return $false }
}

# --- Esperar a que haya red (necesaria para instalar git y clonar) ---------
$online = $false
for ($i = 1; $i -le 12; $i++) {
  if (Test-Connection -ComputerName 'github.com' -Count 1 -Quiet) { $online = $true; break }
  Log "Sin red, reintento $i/12..."
  Start-Sleep -Seconds 5
}
if (-not $online) { Log "AVISO: sin conectividad ICMP con github.com; intento continuar igualmente." }

# --- Asegurar git: PATH -> winget (con espera) -> descarga directa ----------
$Git = Find-Git
if (-not $Git) {
  Log "git no encontrado; intento instalarlo con winget..."
  if (Install-GitViaWinget) { $Git = Find-Git }
}
if (-not $Git) {
  Log "git sigue sin estar; intento descarga directa del instalador..."
  if (Install-GitViaDownload) { $Git = Find-Git }
}
if (-not $Git) {
  Log "ERROR: git sigue sin estar disponible. Abortando."
  exit 1
}
Log "git = $Git"

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
