# Pone IP estática en la única tarjeta de red activa del invitado.
# Uso: ip.ps1 <IP> <prefijo> <puerta de enlace> <DNS1,DNS2,...>
# Salida: 0 = aplicada o ya estaba, 1 = error.
param(
    [Parameter(Mandatory)][string]$IP,
    [Parameter(Mandatory)][int]$Prefijo,
    [Parameter(Mandatory)][string]$Puerta,
    [Parameter(Mandatory)][string]$DNS
)
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

try {
    $tarjetas = @(Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.HardwareInterface })
    if ($tarjetas.Count -ne 1) {
        "[ERR] Se esperaba una tarjeta de red activa y hay $($tarjetas.Count)"
        exit 1
    }
    $i = $tarjetas[0].ifIndex
    $servidores = $DNS -split ',' | Where-Object { $_ }

    $actual = Get-NetIPAddress -InterfaceIndex $i -AddressFamily IPv4 -ErrorAction SilentlyContinue |
              Where-Object { $_.IPAddress -eq $IP -and $_.PrefixOrigin -eq 'Manual' }
    if ($actual) {
        "IP            : ya tenía $IP/$Prefijo (estática)"
    } else {
        Set-NetIPInterface -InterfaceIndex $i -Dhcp Disabled
        Get-NetIPAddress -InterfaceIndex $i -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Remove-NetIPAddress -Confirm:$false
        Get-NetRoute -InterfaceIndex $i -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
            Remove-NetRoute -Confirm:$false
        New-NetIPAddress -InterfaceIndex $i -IPAddress $IP -PrefixLength $Prefijo -DefaultGateway $Puerta | Out-Null
        "IP            : $IP/$Prefijo, puerta $Puerta ($($tarjetas[0].Name))"
    }
    Set-DnsClientServerAddress -InterfaceIndex $i -ServerAddresses $servidores
    "DNS           : $($servidores -join ', ')"
    exit 0
} catch {
    "[ERR] $_"
    exit 1
}
