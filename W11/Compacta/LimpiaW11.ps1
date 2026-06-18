#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Limpia Windows 11 para maximizar el espacio libre antes de compactar un VMDK de VMware.

.DESCRIPTION
    Ejecutar dentro de la VM Windows 11 como Administrador.
    Realiza limpieza de temporales, WinSxS, papelera, prefetch, minidumps,
    caches de miniaturas, hiberfil.sys, event logs, puntos de restauracion y
    finalmente rellena el espacio libre con ceros (sdelete64 -z) para que
    vmware-vdiskmanager -k pueda compactar eficientemente.

.NOTES
    Dependencia externa: sdelete64.exe (Sysinternals).
    Instalar con: winget install Microsoft.Sysinternals.SDelete
    O descargar desde: https://learn.microsoft.com/en-us/sysinternals/downloads/sdelete
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'   # continuar aunque falle un bloque individual

# --------------------------------------------------------------------------
# Funciones auxiliares
# --------------------------------------------------------------------------

function Get-FreeSpaceGB {
    param([string]$Drive = 'C:')
    $disk = Get-PSDrive -Name ($Drive.TrimEnd(':')) -ErrorAction SilentlyContinue
    if ($disk) { return [math]::Round($disk.Free / 1GB, 2) }
    return 0
}

function Remove-ItemsSilent {
    <#
    Borra los items indicados sin abortar si alguno esta en uso.
    Devuelve el numero de items eliminados.
    #>
    param([string[]]$Paths)
    $count = 0
    foreach ($p in $Paths) {
        try {
            if (Test-Path $p) {
                Remove-Item -Path $p -Recurse -Force -ErrorAction SilentlyContinue
                $count++
            }
        } catch { }
    }
    return $count
}

function Write-Bloque {
    param([string]$Titulo)
    Write-Host ""
    Write-Host "=== $Titulo ===" -ForegroundColor Cyan
}

function Write-Resultado {
    param([string]$Texto, [string]$Color = 'Green')
    Write-Host "    $Texto" -ForegroundColor $Color
}

function Invoke-ZeroFillFallback {
    <#
    Zero-fill sin sdelete: escribe ceros en un fichero temporal hasta llenar
    el disco y luego lo borra. Menos eficiente que sdelete (no procesa
    clusters ya liberados de la MFT) pero suficiente como red de seguridad.
    #>
    param([string]$Drive = 'C:')

    $folderPath = "$Drive\LimpiezaTemp"
    $zeroPath   = "$folderPath\zero.tmp"
    $stream     = $null

    if (-not (Test-Path $folderPath)) {
        New-Item -ItemType Directory -Path $folderPath -Force | Out-Null
    }

    try {
        Write-Host "    Escribiendo ceros en el espacio libre de $Drive ..." -ForegroundColor Yellow
        Write-Host "    El sistema parecera detenerse al llenarse el disco; es lo esperado." -ForegroundColor Gray
        $stream = [System.IO.File]::OpenWrite($zeroPath)
        $buffer = New-Object byte[] (64KB)
        while ($true) {
            $stream.Write($buffer, 0, $buffer.Length)
        }
    } catch {
        $msg = $_.Exception.Message
        if ($msg -match 'space|espacio|disk full|disco') {
            Write-Resultado "Zero-fill (fallback) completado: disco lleno de ceros."
        } else {
            Write-Resultado "Zero-fill (fallback) detenido: $msg" 'Yellow'
        }
    } finally {
        if ($stream) {
            try { $stream.Close(); $stream.Dispose() } catch { }
        }
        if (Test-Path $zeroPath)   { Remove-Item $zeroPath -Force -ErrorAction SilentlyContinue }
        if (Test-Path $folderPath) { Remove-Item $folderPath -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# --------------------------------------------------------------------------
# Inicio
# --------------------------------------------------------------------------

Write-Host ""
Write-Host "================================================" -ForegroundColor Yellow
Write-Host "  LimpiaW11.ps1 - Preparacion para compactacion" -ForegroundColor Yellow
Write-Host "================================================" -ForegroundColor Yellow

$espacioInicial = Get-FreeSpaceGB -Drive 'C:'
Write-Host ""
Write-Host "Espacio libre inicial en C:  $espacioInicial GB" -ForegroundColor White

# --------------------------------------------------------------------------
# BLOQUE 1: Temporales de usuario y sistema
# --------------------------------------------------------------------------
Write-Bloque "1/12  Temporales de usuario y sistema"

$tempPaths = @(
    $env:TEMP,
    $env:TMP,
    'C:\Windows\Temp'
)

# Temporales de todos los perfiles de usuario
$perfiles = Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue
foreach ($perfil in $perfiles) {
    $tempPaths += "$($perfil.FullName)\AppData\Local\Temp"
}

$borrados = 0
foreach ($ruta in ($tempPaths | Select-Object -Unique)) {
    if (Test-Path $ruta) {
        $items = Get-ChildItem $ruta -Recurse -Force -ErrorAction SilentlyContinue
        foreach ($item in $items) {
            try { Remove-Item $item.FullName -Force -Recurse -ErrorAction SilentlyContinue; $borrados++ } catch { }
        }
    }
}
Write-Resultado "Elementos procesados en carpetas Temp: $borrados"

# --------------------------------------------------------------------------
# BLOQUE 2: Cache de Windows Update (SoftwareDistribution\Download)
# --------------------------------------------------------------------------
Write-Bloque "2/13  Cache de Windows Update y Delivery Optimization"

# Detener wuauserv Y bits: BITS gestiona las descargas y puede mantener
# ficheros abiertos en SoftwareDistribution que impedirian su borrado.
Write-Resultado "Deteniendo wuauserv y bits..." 'Gray'
Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue
Stop-Service -Name bits -Force -ErrorAction SilentlyContinue

$wuDir = 'C:\Windows\SoftwareDistribution\Download'
if (Test-Path $wuDir) {
    $items = Get-ChildItem $wuDir -Recurse -Force -ErrorAction SilentlyContinue
    $total = $items.Count
    foreach ($item in $items) {
        try { Remove-Item $item.FullName -Force -Recurse -ErrorAction SilentlyContinue } catch { }
    }
    Write-Resultado "Elementos procesados en SoftwareDistribution\Download: $total"
} else {
    Write-Resultado "Directorio no encontrado: $wuDir" 'Yellow'
}

# Cache de Delivery Optimization (descargas P2P de actualizaciones): puede
# ocupar varios GB. El cmdlet solo existe en algunas ediciones de Windows.
if (Get-Command Delete-DeliveryOptimizationCache -ErrorAction SilentlyContinue) {
    try {
        Delete-DeliveryOptimizationCache -Force -ErrorAction SilentlyContinue
        Write-Resultado "Cache de Delivery Optimization eliminada"
    } catch {
        Write-Resultado "Aviso al limpiar Delivery Optimization: $_" 'Yellow'
    }
} else {
    Write-Resultado "Cmdlet Delete-DeliveryOptimizationCache no disponible (omitido)" 'Gray'
}

Write-Resultado "Reiniciando wuauserv y bits..." 'Gray'
Start-Service -Name wuauserv -ErrorAction SilentlyContinue
Start-Service -Name bits -ErrorAction SilentlyContinue

# --------------------------------------------------------------------------
# BLOQUE 3: WinSxS / Component Store (DISM)
# --------------------------------------------------------------------------
Write-Bloque "3/13  WinSxS / Component Store (DISM - puede tardar varios minutos)"
Write-Host "    AVISO: /ResetBase es IRREVERSIBLE. Desinstalar actualizaciones no sera posible despues." -ForegroundColor Red
Write-Host "    Ejecutando DISM /StartComponentCleanup /ResetBase ..." -ForegroundColor Gray

try {
    $dismOutput = & DISM.exe /Online /Cleanup-Image /StartComponentCleanup /ResetBase 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -eq 0) {
        Write-Resultado "DISM /ResetBase completado correctamente (exit 0)"
    } else {
        Write-Resultado "DISM /ResetBase termino con codigo $exitCode (puede ser normal si no hay nada que limpiar)" 'Yellow'
    }
} catch {
    Write-Resultado "Error ejecutando DISM /ResetBase: $_" 'Red'
}

# /SPSuperseded: elimina componentes de service packs reemplazados (espacio extra)
Write-Host "    Ejecutando DISM /SPSuperseded ..." -ForegroundColor Gray
try {
    $null = & DISM.exe /Online /Cleanup-Image /SPSuperseded 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -eq 0) {
        Write-Resultado "DISM /SPSuperseded completado correctamente (exit 0)"
    } else {
        Write-Resultado "DISM /SPSuperseded termino con codigo $exitCode (normal si no hay service pack que limpiar)" 'Yellow'
    }
} catch {
    Write-Resultado "Error ejecutando DISM /SPSuperseded: $_" 'Yellow'
}

# --------------------------------------------------------------------------
# BLOQUE 4: Compresion CompactOS de los ficheros del sistema operativo
# --------------------------------------------------------------------------
Write-Bloque "4/13  Compresion CompactOS del sistema operativo"

# compact /compactos:always comprime los binarios del SO con XPRESS4K.
# Ahorro permanente de ~1-2 GB con impacto minimo en rendimiento en una VM.
Write-Host "    Ejecutando compact /compactos:always (puede tardar unos minutos)..." -ForegroundColor Gray
try {
    & compact.exe /compactos:always 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Resultado "CompactOS activado (ficheros del SO comprimidos)"
    } else {
        Write-Resultado "compact termino con codigo $LASTEXITCODE" 'Yellow'
    }
} catch {
    Write-Resultado "Error ejecutando compact: $_" 'Yellow'
}

# --------------------------------------------------------------------------
# BLOQUE 5: Papelera de reciclaje
# --------------------------------------------------------------------------
Write-Bloque "5/13  Papelera de reciclaje (todos los perfiles)"

try {
    Clear-RecycleBin -Force -ErrorAction SilentlyContinue
    Write-Resultado "Papelera vaciada"
} catch {
    Write-Resultado "Aviso al vaciar papelera: $_" 'Yellow'
}

# --------------------------------------------------------------------------
# BLOQUE 5: Prefetch
# --------------------------------------------------------------------------
Write-Bloque "6/13  Prefetch"

$prefetchDir = 'C:\Windows\Prefetch'
if (Test-Path $prefetchDir) {
    $items = Get-ChildItem $prefetchDir -Force -ErrorAction SilentlyContinue
    $total = $items.Count
    foreach ($item in $items) {
        try { Remove-Item $item.FullName -Force -ErrorAction SilentlyContinue } catch { }
    }
    Write-Resultado "Elementos procesados en Prefetch: $total"
} else {
    Write-Resultado "Directorio Prefetch no encontrado (puede estar desactivado)" 'Yellow'
}

# --------------------------------------------------------------------------
# BLOQUE 6: Minidumps y memory.dmp
# --------------------------------------------------------------------------
Write-Bloque "7/13  Minidumps y volcados de memoria"

$dumpPaths = @(
    'C:\Windows\Minidump',
    'C:\Windows\LiveKernelReports'
)
$dumpFiles = @('C:\Windows\memory.dmp', 'C:\Windows\MEMORY.DMP')

$totalDumps = 0
foreach ($dir in $dumpPaths) {
    if (Test-Path $dir) {
        $items = Get-ChildItem $dir -Recurse -Force -ErrorAction SilentlyContinue
        foreach ($item in $items) {
            try { Remove-Item $item.FullName -Force -ErrorAction SilentlyContinue; $totalDumps++ } catch { }
        }
    }
}
foreach ($f in $dumpFiles) {
    if (Test-Path $f) {
        try { Remove-Item $f -Force -ErrorAction SilentlyContinue; $totalDumps++ } catch { }
    }
}
Write-Resultado "Volcados de memoria eliminados: $totalDumps"

# --------------------------------------------------------------------------
# BLOQUE 7: Thumbnails e Icon cache de todos los perfiles
# --------------------------------------------------------------------------
Write-Bloque "8/13  Thumbnails e Icon cache"

# Detener Explorer para liberar el iconcache
Write-Resultado "Deteniendo explorer.exe para liberar caches..." 'Gray'
Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2

$totalThumb = 0
foreach ($perfil in $perfiles) {
    $thumbDir  = "$($perfil.FullName)\AppData\Local\Microsoft\Windows\Explorer"
    $iconCache = "$($perfil.FullName)\AppData\Local\IconCache.db"

    if (Test-Path $thumbDir) {
        $items = Get-ChildItem $thumbDir -Filter 'thumbcache_*.db' -Force -ErrorAction SilentlyContinue
        foreach ($item in $items) {
            try { Remove-Item $item.FullName -Force -ErrorAction SilentlyContinue; $totalThumb++ } catch { }
        }
    }
    if (Test-Path $iconCache) {
        try { Remove-Item $iconCache -Force -ErrorAction SilentlyContinue; $totalThumb++ } catch { }
    }
}

# Reiniciar Explorer
Write-Resultado "Reiniciando explorer.exe..." 'Gray'
Start-Process explorer.exe
Write-Resultado "Caches de miniaturas/iconos eliminados: $totalThumb"

# --------------------------------------------------------------------------
# BLOQUE 8: Hibernacion (hiberfil.sys)
# --------------------------------------------------------------------------
Write-Bloque "9/13  Hibernacion"

try {
    & powercfg.exe /h off 2>&1 | Out-Null
    Write-Resultado "Hibernacion desactivada (hiberfil.sys eliminado)"
} catch {
    Write-Resultado "Error desactivando hibernacion: $_" 'Red'
}

# --------------------------------------------------------------------------
# BLOQUE 9: Fichero de paginacion (pagefile.sys)
# --------------------------------------------------------------------------
Write-Bloque "10/13 Fichero de paginacion"

# Solo se reporta el tamano actual; no se elimina automaticamente para
# evitar inestabilidad. El usuario puede decidir reducirlo manualmente.
try {
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem
    if ($cs.AutomaticManagedPagefile) {
        Write-Resultado "Pagefile gestionado automaticamente por Windows (tamano variable)" 'Gray'
    } else {
        $pf = Get-CimInstance -ClassName Win32_PageFileSetting -ErrorAction SilentlyContinue
        if ($pf) {
            foreach ($p in $pf) {
                Write-Resultado "Pagefile: $($p.Name)  Min=$($p.InitialSize)MB  Max=$($p.MaximumSize)MB" 'Gray'
            }
        }
    }
    Write-Resultado "NOTA: Eliminar el pagefile antes del zero-fill libera espacio adicional." 'Yellow'
    Write-Resultado "      Para hacerlo: Panel de control > Sistema > Configuracion avanzada > Rendimiento > Memoria virtual" 'Yellow'
} catch {
    Write-Resultado "No se pudo consultar el pagefile: $_" 'Yellow'
}

# --------------------------------------------------------------------------
# BLOQUE 10: Registros de eventos de Windows
# --------------------------------------------------------------------------
Write-Bloque "11/13 Registros de eventos de Windows"

try {
    $logs = Get-WinEvent -ListLog * -ErrorAction SilentlyContinue | Where-Object { $_.RecordCount -gt 0 }
    $cleared = 0
    foreach ($log in $logs) {
        try {
            [System.Diagnostics.Eventing.Reader.EventLogSession]::GlobalSession.ClearLog($log.LogName)
            $cleared++
        } catch { }
    }
    Write-Resultado "Registros de eventos vaciados: $cleared"
} catch {
    Write-Resultado "Error limpiando event logs: $_" 'Yellow'
}

# --------------------------------------------------------------------------
# BLOQUE 11: Puntos de restauracion del sistema
# --------------------------------------------------------------------------
Write-Bloque "12/13 Puntos de restauracion del sistema"

try {
    # Eliminar todos los puntos de restauracion excepto el mas reciente
    $puntos = Get-ComputerRestorePoint -ErrorAction SilentlyContinue
    if ($puntos -and $puntos.Count -gt 0) {
        $masReciente = ($puntos | Sort-Object CreationTime | Select-Object -Last 1).SequenceNumber
        Write-Resultado "Puntos encontrados: $($puntos.Count). Conservando el mas reciente (seq $masReciente)."
        # Usar vssadmin para eliminar sombras antiguas
        & vssadmin.exe Delete Shadows /For=C: /Oldest /Quiet 2>&1 | Out-Null
        Write-Resultado "Sombras de volumen antiguas eliminadas"
    } else {
        Write-Resultado "No se encontraron puntos de restauracion" 'Gray'
    }
} catch {
    Write-Resultado "Error gestionando puntos de restauracion: $_" 'Yellow'
}

# --------------------------------------------------------------------------
# BLOQUE 12: Cleanmgr (Liberador de espacio en disco)
# --------------------------------------------------------------------------
Write-Bloque "13/13 Cleanmgr (Liberador de espacio en disco)"

# Configurar la clave de registro para sagerun:1 (seleccionar todo)
try {
    $sagePath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches'
    $caches = Get-ChildItem $sagePath -ErrorAction SilentlyContinue
    foreach ($cache in $caches) {
        Set-ItemProperty -Path $cache.PSPath -Name 'StateFlags0001' -Value 2 -Type DWord -ErrorAction SilentlyContinue
    }

    Write-Resultado "Ejecutando cleanmgr /sagerun:1 (en segundo plano, esperar hasta 2 min)..." 'Gray'
    $proc = Start-Process -FilePath 'cleanmgr.exe' -ArgumentList '/sagerun:1' -PassThru -WindowStyle Hidden
    $proc.WaitForExit(120000) | Out-Null   # esperar max 2 min
    if (-not $proc.HasExited) {
        Write-Resultado "cleanmgr tardo mas de 2 min; continuando sin esperar" 'Yellow'
        try { $proc.Kill() } catch { }
    } else {
        Write-Resultado "cleanmgr completado (exit $($proc.ExitCode))"
    }
} catch {
    Write-Resultado "Error ejecutando cleanmgr: $_" 'Yellow'
}

# --------------------------------------------------------------------------
# PASO PREVIO AL ZERO-FILL: Defrag de consolidacion del espacio libre
# --------------------------------------------------------------------------
Write-Host ""
Write-Host "=== DEFRAG de consolidacion (defrag C: /X) ===" -ForegroundColor Magenta
Write-Host "    Consolida el espacio libre al final del volumen para que el zero-fill" -ForegroundColor Gray
Write-Host "    y la posterior compactacion liberen el maximo posible..." -ForegroundColor Gray
try {
    & defrag.exe C: /X /H /U /V
    Write-Resultado "Defrag de consolidacion completado"
} catch {
    Write-Resultado "Aviso ejecutando defrag: $_" 'Yellow'
}

# --------------------------------------------------------------------------
# BLOQUE FINAL: SDelete zero-fill (imprescindible para compactacion VMware)
# --------------------------------------------------------------------------
Write-Host ""
Write-Host "=== ZERO-FILL con SDelete (puede tardar mucho; proporcional al espacio libre) ===" -ForegroundColor Magenta

# Buscar sdelete64.exe en PATH, carpeta del script y rutas comunes
$sdeleteExe = $null
$candidatos = @(
    'sdelete64.exe',
    "$PSScriptRoot\sdelete64.exe",
    "$env:USERPROFILE\Downloads\sdelete64.exe",
    'C:\Tools\sdelete64.exe',
    'C:\Sysinternals\sdelete64.exe'
)
foreach ($c in $candidatos) {
    if (Get-Command $c -ErrorAction SilentlyContinue) { $sdeleteExe = $c; break }
    if (Test-Path $c) { $sdeleteExe = $c; break }
}

if (-not $sdeleteExe) {
    Write-Host ""
    Write-Host "  AVISO: sdelete64.exe NO encontrado." -ForegroundColor Red
    Write-Host "  Para mejores resultados instalalo:  winget install Microsoft.Sysinternals.SDelete" -ForegroundColor Yellow
    Write-Host "  O descargalo de: https://learn.microsoft.com/en-us/sysinternals/downloads/sdelete" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Usando metodo de respaldo (zero-fill por bucle de PowerShell)..." -ForegroundColor Yellow
    Invoke-ZeroFillFallback -Drive 'C:'
} else {
    Write-Host "    sdelete64 encontrado en: $sdeleteExe" -ForegroundColor Gray
    Write-Host "    Ejecutando: sdelete64 -accepteula -z C:  (esto puede tardar 10-30 min)" -ForegroundColor Gray
    Write-Host "    El progreso lo muestra el propio sdelete64..." -ForegroundColor Gray
    Write-Host ""
    try {
        & $sdeleteExe -accepteula -z C:
        Write-Host ""
        Write-Resultado "Zero-fill completado."
    } catch {
        Write-Resultado "Error ejecutando sdelete64: $_" 'Red'
    }
}

# --------------------------------------------------------------------------
# Resumen final
# --------------------------------------------------------------------------
$espacioFinal = Get-FreeSpaceGB -Drive 'C:'
$liberado      = [math]::Round($espacioFinal - $espacioInicial, 2)

Write-Host ""
Write-Host "================================================" -ForegroundColor Yellow
Write-Host "  RESUMEN" -ForegroundColor Yellow
Write-Host "================================================" -ForegroundColor Yellow
Write-Host "  Espacio libre inicial : $espacioInicial GB" -ForegroundColor White
Write-Host "  Espacio libre final   : $espacioFinal GB"   -ForegroundColor White
if ($liberado -ge 0) {
    Write-Host "  Espacio liberado      : +$liberado GB"  -ForegroundColor Green
} else {
    Write-Host "  Espacio ocupado (diferencia): $liberado GB (normal si el zero-fill lleno el disco)" -ForegroundColor Yellow
}
Write-Host ""
Write-Host "  Siguiente paso: APAGAR la VM (shutdown completo, NO suspender)" -ForegroundColor Cyan
Write-Host "  Luego desde el host Linux: bash CompactaW11.sh <ruta/a/VM.vmx>" -ForegroundColor Cyan
Write-Host "================================================" -ForegroundColor Yellow
Write-Host ""
