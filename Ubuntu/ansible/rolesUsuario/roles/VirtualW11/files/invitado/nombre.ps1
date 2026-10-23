# Cambia el nombre del equipo invitado.
# Uso: nombre.ps1 <nombre>
# Salida: 0 = ya se llama así, 3 = cambiado o pendiente (hace falta reiniciar),
#         1 = error.
param([Parameter(Mandatory)][string]$Nombre)
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

try {
    $tcpip     = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters'
    $actual    = $tcpip.'Hostname'
    $pendiente = $tcpip.'NV Hostname'

    if ($actual -ieq $Nombre) {
        "Nombre        : $actual"
        exit 0
    }
    if ($pendiente -ine $Nombre) {
        # Más de 15 caracteres: Windows recorta el nombre NetBIOS (avisa, no falla).
        Rename-Computer -NewName $Nombre -Force -WarningAction SilentlyContinue
    }
    "Nombre        : $actual -> $Nombre (al reiniciar)"
    exit 3
} catch {
    "[ERR] $_"
    exit 1
}
