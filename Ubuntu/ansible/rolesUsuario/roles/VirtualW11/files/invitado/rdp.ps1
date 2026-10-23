# Activa el Escritorio remoto (RDP, con NLA) y abre su regla del cortafuegos.
# Salida: 0 = activo, 1 = error.
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

try {
    $ts = 'HKLM:\System\CurrentControlSet\Control\Terminal Server'
    if ((Get-ItemProperty $ts).fDenyTSConnections -ne 0) {
        Set-ItemProperty $ts -Name fDenyTSConnections -Value 0
        "RDP           : activado"
    } else {
        "RDP           : ya estaba activado"
    }
    # NLA: autenticación antes de abrir la sesión (Remmina la soporta).
    Set-ItemProperty "$ts\WinStations\RDP-Tcp" -Name UserAuthentication -Value 1

    # Reglas de "Escritorio remoto" por nombre interno (no depende del idioma).
    Get-NetFirewallRule -Name 'RemoteDesktop-UserMode-In-*' |
        Set-NetFirewallRule -Enabled True -Profile Any
    "Cortafuegos   : puerto 3389 abierto (todos los perfiles)"

    if ((Get-Service TermService).Status -ne 'Running') { Start-Service TermService }
    "TermService   : $((Get-Service TermService).Status)"
    exit 0
} catch {
    "[ERR] $_"
    exit 1
}
