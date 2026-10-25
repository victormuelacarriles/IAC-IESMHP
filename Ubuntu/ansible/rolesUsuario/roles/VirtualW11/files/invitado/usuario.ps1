# Usuarios del Windows invitado (rol VirtualW11):
#  - <Admin> (p. ej. adminSMRV08): administrador. Lo usa el rol.
#  - <Nombre> (p. ej. SMRV08): usuario ESTÁNDAR del alumno (arranque automático
#    y Escritorio remoto). Se le quita de Administradores (en máquinas antiguas
#    lo era) solo cuando <Admin> ya existe y es administrador.
#  - Desactiva el usuario de la plantilla (<Desactivar>), si existe y es otro.
#  - Quita la pantalla de privacidad del primer inicio de sesión.
# Los que se crean llevan la contraseña dada; a los que ya existen NO se les
# cambia (la puede haber cambiado el alumno), salvo con <forzar>=si (contraseña
# del fichero de claves del profesor): entonces se les pone a los dos.
# Uso: usuario.ps1 <nombre> <admin> <contraseña> <usuario a desactivar> [si|no]
# Salida: 0 = correcto, 1 = error.
param(
    [Parameter(Mandatory)][string]$Nombre,
    [Parameter(Mandatory)][string]$Admin,
    [Parameter(Mandatory)][string]$Password,
    [Parameter(Mandatory)][string]$Desactivar,
    [string]$Forzar = 'no'
)
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

function Asegurar-Usuario([string]$N) {
    $u = Get-LocalUser -Name $N -ErrorAction SilentlyContinue
    if (-not $u) {
        $clave = ConvertTo-SecureString $Password -AsPlainText -Force
        $u = New-LocalUser -Name $N -Password $clave -FullName $N `
                 -Description 'Creado por IAC-IESMHP' -PasswordNeverExpires -AccountNeverExpires
        "Usuario       : $N creado (contraseña inicial)"
    } elseif ($Forzar -eq 'si') {
        # Solo se cambia si no la tiene ya (una comprobación: si no coincide,
        # cuenta como un fallo para el bloqueo de cuentas).
        Add-Type -AssemblyName System.DirectoryServices.AccountManagement
        $ctx = New-Object System.DirectoryServices.AccountManagement.PrincipalContext('Machine')
        $ok = $false
        try { $ok = $ctx.ValidateCredentials($N, $Password) } catch { }
        if ($ok) {
            "Usuario       : $N ya existe (ya tiene la contraseña del fichero de claves)"
        } else {
            Set-LocalUser -Name $N -Password (ConvertTo-SecureString $Password -AsPlainText -Force)
            "Usuario       : $N ya existe (contraseña del fichero de claves puesta)"
        }
    } else {
        "Usuario       : $N ya existe (no se cambia su contraseña)"
    }
    if (-not $u.Enabled) {
        Enable-LocalUser -Name $N
        "Usuario       : $N activado"
    }
}

function Es-Miembro($Grupo, [string]$N) {
    # Por SID del usuario (no depende del idioma). Si Get-LocalGroupMember
    # fallara (SIDs huérfanos en el grupo), se toma como "no es miembro".
    $sid = (Get-LocalUser -Name $N).SID.Value
    return [bool](Get-LocalGroupMember -Group $Grupo -ErrorAction SilentlyContinue |
                  Where-Object { $_.SID.Value -eq $sid })
}

function Agregar([string]$Sid, [string]$N) {
    $g = Get-LocalGroup -SID $Sid
    try {
        Add-LocalGroupMember -Group $g -Member $N -ErrorAction Stop
        "Grupo         : $N añadido a $($g.Name)"
    } catch [Microsoft.PowerShell.Commands.MemberExistsException] {
        "Grupo         : $N ya es de $($g.Name)"
    }
}

try {
    if ($Admin -ieq $Nombre) { throw "El administrador y el usuario no pueden llamarse igual ($Nombre)" }

    # 1. Administrador.
    Asegurar-Usuario $Admin
    Agregar 'S-1-5-32-544' $Admin                 # Administradores

    # 2. Usuario estándar del alumno.
    Asegurar-Usuario $Nombre
    Agregar 'S-1-5-32-545' $Nombre                # Usuarios
    Agregar 'S-1-5-32-555' $Nombre                # Usuarios de escritorio remoto
    $admins = Get-LocalGroup -SID 'S-1-5-32-544'
    if ((Es-Miembro $admins $Admin) -and (Es-Miembro $admins $Nombre)) {
        Remove-LocalGroupMember -Group $admins -Member $Nombre
        "Estándar      : $Nombre quitado de $($admins.Name)"
    }

    # 3. Sin la pantalla de privacidad del primer inicio de sesión ("Permitir
    #    que Microsoft y las aplicaciones usen tu ubicación"...): con el
    #    arranque automático el usuario se quedaría ahí esperando un clic.
    $oobe = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE'
    if (-not (Test-Path $oobe)) { New-Item $oobe -Force | Out-Null }
    if ((Get-ItemProperty $oobe -ErrorAction SilentlyContinue).DisablePrivacyExperience -ne 1) {
        Set-ItemProperty $oobe -Name DisablePrivacyExperience -Value 1 -Type DWord
        "Privacidad    : pantalla del primer inicio de sesión desactivada"
    }

    # 4. Usuario de la plantilla (nunca los dos de arriba).
    $d = Get-LocalUser -Name $Desactivar -ErrorAction SilentlyContinue
    if ($Desactivar -ieq $Nombre -or $Desactivar -ieq $Admin) {
        "Desactivar    : $Desactivar es uno de los usuarios del alumno, no se desactiva"
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
