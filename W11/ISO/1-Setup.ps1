#Requires -Version 5.1
<#
  1-Setup.ps1  -  Configuracion del W11 instalado (post-clonado)
  ============================================================================
  Lo lanza 0b-GitHub.ps1 tras clonar el repo, desde
  C:\Program Files\IAC-IESMHP\W11\ISO\1-Setup.ps1  (corre como administrador).

  Hace:
    1a) Busca la MAC de las tarjetas de red del equipo en ..\..\macs.csv
        (raiz del repo). Si una coincide:
          - Renombra el equipo a su 'Equipo' (SIN reiniciar).
          - Convierte su IPv4 a ESTATICA conservando mascara, puerta de enlace y
            DNS actuales, pero cambiando el ULTIMO OCTETO por el 'IPf' del CSV.
    1b) Instala OpenSSH (cliente+servidor) segun
        ..\Utiles\Openssh\ProcedimientoOpenss.txt y autoriza las claves de
        ..\..\Autorizados.txt para conexion como administrador.

  Equivalente Windows de NombreIP.sh + alta de SSH (Ubuntu). Idempotente.
  Log: C:\Windows\Setup\Scripts\1-Setup.ps1.log
  ============================================================================
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'

# --- Log -------------------------------------------------------------------
$LogDir = 'C:\Windows\Setup\Scripts'
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }
$LogFile = Join-Path $LogDir '1-Setup.ps1.log'
function Log {
  param([string]$Msg)
  $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Msg
  Write-Host $line
  Add-Content -Path $LogFile -Value $line -Encoding UTF8
}

# --- Localizar la raiz del repo --------------------------------------------
$Here = $PSScriptRoot
if (-not $Here) { $Here = Split-Path -Parent $MyInvocation.MyCommand.Path }
$RepoRoot = Split-Path (Split-Path $Here -Parent) -Parent   # ...\IAC-IESMHP
$CsvFile  = Join-Path $RepoRoot 'macs.csv'
$AuthSrc  = Join-Path $RepoRoot 'Autorizados.txt'

Log "===== 1-Setup.ps1 inicio ====="
Log "Repo en: $RepoRoot"

# --- Utilidades ------------------------------------------------------------
function ConvertTo-NormMac {
  param([string]$s)
  $h = (($s -replace '[^0-9A-Fa-f]', '')).ToLower()
  if ($h.Length -ne 12) { return $null }
  return (($h -split '(.{2})' | Where-Object { $_ }) -join ':')
}

# ===========================================================================
# 1a) MAC -> nombre + IP estatica
# ===========================================================================
try {
  if (-not (Test-Path $CsvFile)) {
    Log "AVISO: no encuentro $CsvFile; me salto el renombrado/IP."
  } else {
    # --- Parsear macs.csv -> tabla  mac(normalizada) -> {Name, Octet} ------
    # Formato: MAC, Equipo, IPf, Comentario  (separado por COMAS). Se ignoran
    # las lineas que empiezan por '#' y la cabecera (1er campo no es una MAC).
    $macRe = '([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}'
    $map = @{}
    foreach ($line in Get-Content -Path $CsvFile) {
      $t = $line.Trim()
      if ($t -eq '' -or $t.StartsWith('#')) { continue }
      $f = $t -split ','
      if ($f.Count -lt 3) { continue }
      $rawMac = $f[0].Trim()
      if ($rawMac -notmatch ('^' + $macRe + '$')) { continue }   # cabecera/otras
      $mac = ConvertTo-NormMac $rawMac
      if (-not $mac) { continue }
      $name  = $f[1].Trim()
      $octet = $f[2].Trim()
      if ($name -eq '' -or $octet -notmatch '^\d{1,3}$') { continue }
      $map[$mac] = [pscustomobject]@{ Name = $name; Octet = [int]$octet }
    }
    Log "macs.csv: $($map.Count) equipos en el listado."

    # --- Buscar una NIC del equipo que este en el listado ------------------
    $entry = $null; $adapter = $null
    foreach ($a in (Get-NetAdapter -ErrorAction SilentlyContinue)) {
      $nmac = ConvertTo-NormMac $a.MacAddress
      if ($nmac -and $map.ContainsKey($nmac)) { $entry = $map[$nmac]; $adapter = $a; break }
    }

    if (-not $entry) {
      Log "Ninguna MAC del equipo esta en macs.csv; no se cambia nombre ni IP."
    } else {
      Log "Coincide '$($adapter.Name)' (MAC $($adapter.MacAddress)) -> Equipo=$($entry.Name) octeto=$($entry.Octet)"

      # --- Renombrar (sin reiniciar) ---------------------------------------
      if ($env:COMPUTERNAME -ieq $entry.Name) {
        Log "El equipo ya se llama $($entry.Name); no se renombra."
      } else {
        try {
          Rename-Computer -NewName $entry.Name -Force -ErrorAction Stop
          Log "Renombrado a $($entry.Name) (efectivo tras el proximo reinicio)."
        } catch { Log "ERROR al renombrar: $($_.Exception.Message)" }
      }

      # --- IP estatica conservando mascara/gw/dns, cambiando el ultimo octeto
      $idx = $adapter.ifIndex
      $cfg = Get-NetIPConfiguration -InterfaceIndex $idx -ErrorAction SilentlyContinue
      $ipObj = Get-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue |
               Where-Object { $_.IPAddress -notlike '169.254*' -and $_.IPAddress -ne '127.0.0.1' } |
               Select-Object -First 1

      if (-not $ipObj) {
        Log "AVISO: la NIC no tiene IPv4 valida (sin lease DHCP?); no se fija IP estatica."
      } else {
        $curIP  = $ipObj.IPAddress
        $prefix = [int]$ipObj.PrefixLength
        $gw     = $null
        if ($cfg -and $cfg.IPv4DefaultGateway) { $gw = ($cfg.IPv4DefaultGateway | Select-Object -First 1).NextHop }
        $dns    = @((Get-DnsClientServerAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses)

        $oct = $curIP.Split('.')
        $newIP = '{0}.{1}.{2}.{3}' -f $oct[0], $oct[1], $oct[2], $entry.Octet
        Log "IP actual=$curIP/$prefix gw=$gw dns=$($dns -join ',') -> nueva estatica=$newIP"

        try {
          # Pasar a estatica: deshabilitar DHCP y limpiar config previa
          Set-NetIPInterface -InterfaceIndex $idx -AddressFamily IPv4 -Dhcp Disabled -ErrorAction SilentlyContinue
          Get-NetRoute -InterfaceIndex $idx -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
            Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
          Get-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue

          if ($gw) {
            New-NetIPAddress -InterfaceIndex $idx -IPAddress $newIP -PrefixLength $prefix -DefaultGateway $gw -ErrorAction Stop | Out-Null
          } else {
            New-NetIPAddress -InterfaceIndex $idx -IPAddress $newIP -PrefixLength $prefix -ErrorAction Stop | Out-Null
          }
          if ($dns -and $dns.Count -gt 0) {
            Set-DnsClientServerAddress -InterfaceIndex $idx -ServerAddresses $dns -ErrorAction SilentlyContinue
          }
          Log "IP estatica $newIP/$prefix aplicada en '$($adapter.Name)'."
        } catch { Log "ERROR al fijar la IP estatica: $($_.Exception.Message)" }
      }
    }
  }
} catch { Log "ERROR en el bloque 1a (MAC/nombre/IP): $($_.Exception.Message)" }

# ===========================================================================
# 1b) OpenSSH (cliente+servidor) + claves autorizadas (administradores)
# ===========================================================================
try {
  Log "OpenSSH: instalando capacidades (si faltan)..."
  foreach ($cap in 'OpenSSH.Client', 'OpenSSH.Server') {
    $c = Get-WindowsCapability -Online -Name "$cap*" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c -and $c.State -ne 'Installed') {
      try { Add-WindowsCapability -Online -Name $c.Name -ErrorAction Stop | Out-Null; Log "  + $($c.Name) instalado." }
      catch { Log "  ERROR instalando $cap : $($_.Exception.Message)" }
    } else {
      Log "  $cap ya instalado."
    }
  }

  # Servicio sshd: arranque automatico + iniciado
  Set-Service -Name sshd -StartupType Automatic -ErrorAction SilentlyContinue
  Start-Service sshd -ErrorAction SilentlyContinue
  Log "OpenSSH: servicio sshd en automatico e iniciado."

  # Regla de firewall (la crea el setup; verificar)
  if (-not (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' `
      -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 -ErrorAction SilentlyContinue | Out-Null
    Log "OpenSSH: regla de firewall creada."
  } else {
    Log "OpenSSH: regla de firewall ya existe."
  }

  # Shell por defecto del sshd = PowerShell (lo exige Ansible W11)
  if (-not (Test-Path 'HKLM:\SOFTWARE\OpenSSH')) { New-Item -Path 'HKLM:\SOFTWARE\OpenSSH' -Force | Out-Null }
  New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell `
    -Value 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -PropertyType String -Force | Out-Null
  Log "OpenSSH: DefaultShell = powershell.exe"

  # Claves autorizadas para administradores (desde el Autorizados.txt local)
  $sshDir   = Join-Path $env:ProgramData 'ssh'
  $authFile = Join-Path $sshDir 'administrators_authorized_keys'
  if (-not (Test-Path $sshDir)) { New-Item -ItemType Directory -Force -Path $sshDir | Out-Null }

  if (-not (Test-Path $AuthSrc)) {
    Log "AVISO: no encuentro $AuthSrc; no se anaden claves."
  } else {
    $nuevas = Get-Content -Path $AuthSrc | Where-Object { $_.Trim() -ne '' -and -not $_.Trim().StartsWith('#') }
    $exist  = @()
    if (Test-Path $authFile) { $exist = Get-Content -Path $authFile | Where-Object { $_.Trim() -ne '' } }
    $add = 0
    foreach ($k in $nuevas) {
      $kk = $k.Trim()
      if ($exist -notcontains $kk) {
        Add-Content -Path $authFile -Value $kk -Encoding Ascii
        $exist += $kk; $add++
      }
    }
    Log "OpenSSH: $add clave(s) nueva(s) anadida(s) a administrators_authorized_keys."

    # Permisos correctos (si no, sshd ignora el fichero)
    & icacls $authFile /inheritance:r            | Out-Null
    & icacls $authFile /grant '*S-1-5-18:F'      | Out-Null   # SYSTEM
    & icacls $authFile /grant '*S-1-5-32-544:F'  | Out-Null   # Administradores (cualquier idioma)
    Log "OpenSSH: permisos (icacls) aplicados a $authFile."
  }
} catch { Log "ERROR en el bloque 1b (OpenSSH): $($_.Exception.Message)" }

Log "===== 1-Setup.ps1 fin ====="
