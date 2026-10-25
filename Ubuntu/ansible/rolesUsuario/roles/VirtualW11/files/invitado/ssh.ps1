# Deja OpenSSH Server instalado, arrancado y automático, con el puerto 22
# abierto, y autoriza una clave pública para los administradores y para
# <usuario> (el estándar del alumno).
# Uso: ssh.ps1 "<clave pública>" [<usuario>]
#
# La clave de <usuario> NO va a C:\Users\<usuario>\.ssh: ese perfil no existe
# hasta que el alumno entra por primera vez (y si se crea a mano, Windows le da
# otra carpeta). Va a C:\ProgramData\ssh\claves\<usuario>, que sshd lee porque
# se añade a AuthorizedKeysFile en sshd_config.
param(
    [Parameter(Mandatory)][string]$ClavePublica,
    [string]$Usuario = ''
)
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

try {
    $svc = Get-Service sshd -ErrorAction SilentlyContinue
    if (-not $svc) {
        "OpenSSH Server: no instalado, instalando (necesita Internet/Windows Update)..."
        $cap = Get-WindowsCapability -Online | Where-Object Name -like 'OpenSSH.Server*' | Select-Object -First 1
        Add-WindowsCapability -Online -Name $cap.Name | Out-Null
        $svc = Get-Service sshd
    }
    "OpenSSH Server: instalado"

    if ($svc.StartType -ne 'Automatic') { Set-Service sshd -StartupType Automatic }
    if ($svc.Status -ne 'Running')      { Start-Service sshd }
    "sshd          : $((Get-Service sshd).Status), arranque $((Get-Service sshd).StartType)"

    $regla = Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue
    if (-not $regla) {
        New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' `
            -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 -Profile Any | Out-Null
    } else {
        Set-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -Enabled True -Profile Any
    }
    "Cortafuegos   : puerto 22 abierto (todos los perfiles)"

    # Los administradores usan este fichero, no el authorized_keys del perfil.
    $f = Join-Path $env:ProgramData 'ssh\administrators_authorized_keys'
    $claves = if (Test-Path $f) { @(Get-Content $f) } else { @() }
    if ($claves -contains $ClavePublica) {
        "Clave         : ya autorizada"
    } else {
        Add-Content -Path $f -Value $ClavePublica -Encoding ascii
        "Clave         : añadida a $f"
    }
    # sshd ignora el fichero si tiene otros permisos.
    icacls.exe $f /inheritance:r /grant '*S-1-5-32-544:F' '*S-1-5-18:F' | Out-Null

    if ($Usuario) {
        # sshd_config: AuthorizedKeysFile (la línea general, antes de los Match)
        # con el fichero de ProgramData además del del perfil.
        $cfg = Join-Path $env:ProgramData 'ssh\sshd_config'
        $extra = '__PROGRAMDATA__/ssh/claves/%u'
        $lineas = @(Get-Content $cfg)
        if (-not ($lineas -match [regex]::Escape($extra))) {
            $hecho = $false
            $nuevas = foreach ($l in $lineas) {
                if (-not $hecho -and $l -match '^\s*#?\s*AuthorizedKeysFile\s') {
                    $hecho = $true
                    "AuthorizedKeysFile .ssh/authorized_keys $extra"
                } else { $l }
            }
            if (-not $hecho) { $nuevas = @("AuthorizedKeysFile .ssh/authorized_keys $extra") + $lineas }
            Set-Content -Path $cfg -Value $nuevas -Encoding ascii
            "sshd_config   : AuthorizedKeysFile también en $extra"
            # Por SSH no se reinicia sshd (cortaría esta misma conexión): se
            # aplica en el siguiente arranque de Windows.
            if ($env:SSH_CONNECTION) {
                "sshd          : se aplicará al reiniciar Windows (se está usando SSH)"
            } else {
                Restart-Service sshd
                "sshd          : reiniciado"
            }
        }
        $d = Join-Path $env:ProgramData 'ssh\claves'
        New-Item $d -ItemType Directory -Force | Out-Null
        $fu = Join-Path $d $Usuario
        $actual = if (Test-Path $fu) { @(Get-Content $fu) } else { @() }
        if ($actual -contains $ClavePublica) {
            "Clave $Usuario : ya autorizada"
        } else {
            Add-Content -Path $fu -Value $ClavePublica -Encoding ascii
            "Clave $Usuario : añadida a $fu"
        }
        # Solo administradores y SYSTEM pueden cambiarla; el usuario, leerla.
        icacls.exe $fu /inheritance:r /grant '*S-1-5-32-544:F' '*S-1-5-18:F' "${Usuario}:R" | Out-Null
        icacls.exe $fu /setowner '*S-1-5-32-544' | Out-Null
    }
    exit 0
} catch {
    "[ERR] $_"
    exit 1
}
