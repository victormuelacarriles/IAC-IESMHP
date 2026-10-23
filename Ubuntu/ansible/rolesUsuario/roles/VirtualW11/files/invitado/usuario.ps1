# Crea (si no existe) un usuario local administrador y desactiva el usuario
# de la plantilla (si existe y es otro).
# Uso: usuario.ps1 <nombre> <contraseña inicial> <usuario a desactivar>
# Si el usuario ya existe NO se cambia su contraseña (la puede haber cambiado).
# Salida: 0 = correcto, 1 = error.
param(
    [Parameter(Mandatory)][string]$Nombre,
    [Parameter(Mandatory)][string]$Password,
    [Parameter(Mandatory)][string]$Desactivar
)
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

try {
    $u = Get-LocalUser -Name $Nombre -ErrorAction SilentlyContinue
    if (-not $u) {
        $clave = ConvertTo-SecureString $Password -AsPlainText -Force
        $u = New-LocalUser -Name $Nombre -Password $clave -FullName $Nombre `
                 -Description 'Creado por IAC-IESMHP' -PasswordNeverExpires -AccountNeverExpires
        "Usuario       : $Nombre creado (contraseña inicial)"
    } else {
        "Usuario       : $Nombre ya existe (no se cambia su contraseña)"
    }
    if (-not $u.Enabled) {
        Enable-LocalUser -Name $Nombre
        "Usuario       : $Nombre activado"
    }

    # Administradores por SID (el nombre del grupo depende del idioma).
    $admins = Get-LocalGroup -SID 'S-1-5-32-544'
    try {
        Add-LocalGroupMember -Group $admins -Member $Nombre -ErrorAction Stop
        "Administrador : $Nombre añadido a $($admins.Name)"
    } catch [Microsoft.PowerShell.Commands.MemberExistsException] {
        "Administrador : $Nombre ya es de $($admins.Name)"
    }

    # Solo ese usuario (y nunca el que se acaba de crear, si se llaman igual).
    $d = Get-LocalUser -Name $Desactivar -ErrorAction SilentlyContinue
    if ($Desactivar -ieq $Nombre) {
        "Desactivar    : $Desactivar es el propio administrador, no se desactiva"
    } elseif (-not $d) {
        "Desactivar    : no existe $Desactivar"
    } elseif ($d.Enabled) {
        Disable-LocalUser -Name $Desactivar
        "Desactivado   : $Desactivar"
    } else {
        "Desactivar    : $Desactivar ya estaba desactivado"
    }
    exit 0
} catch {
    "[ERR] $_"
    exit 1
}
