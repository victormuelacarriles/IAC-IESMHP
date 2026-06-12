<#
.SYNOPSIS
    Prepara en Active Directory la cuenta delegada para unir equipos Linux
    al dominio (pareja del rol Ansible preparaAD de IAC-IESMHP).

.DESCRIPTION
    EJECUTAR EN UN CONTROLADOR DE DOMINIO (o equipo con RSAT y el modulo
    ActiveDirectory) con permisos de administrador del dominio.

    Es IDEMPOTENTE; hace tres cosas:
      1. OU "EquiposLinuxAutomatizados": si no existe la crea en la raiz del
         dominio, protegida contra borrado accidental.
      2. Usuario "svc-union-linux": si no existe lo crea (cuenta normal, SIN
         grupos privilegiados, PasswordNeverExpires). En ambos casos
         establece/resetea su contrasena — es el UNICO dato que pide el
         script.
      3. Delegacion MINIMA sobre la OU para que la cuenta pueda
         EXCLUSIVAMENTE unir equipos al dominio dentro de esa OU:
           - Crear objetos EQUIPO (en la OU y sub-OUs).
           - Sobre los equipos descendientes: Reset Password, escritura
             validada de dNSHostName y servicePrincipalName, y
             lectura/escritura del property set "Account Restrictions".
         NO se delega el borrado: re-unir un equipo reinstalado REUTILIZA su
         cuenta via reset password, no necesita borrarla.
         Comprueba ACE a ACE y solo anade las que falten.

    Los valores por defecto DEBEN COINCIDIR con defaults/main.yml del rol
    (preparaad_usuario_union, preparaad_ou). Tras ejecutar esto, generar el
    vault con 2-CreaVault.sh (misma contrasena).

    (Sin tildes a proposito: PowerShell 5.1 lee UTF-8 sin BOM como ANSI.)

.EXAMPLE
    .\1-CreaUsuarioUnionAD.ps1
    .\1-CreaUsuarioUnionAD.ps1 -Usuario otro-svc -NombreOU OtraOU
#>
#Requires -Modules ActiveDirectory
[CmdletBinding()]
param(
    [string]$Usuario  = 'svc-union-linux',
    [string]$NombreOU = 'EquiposLinuxAutomatizados'
)

$ErrorActionPreference = 'Stop'
Import-Module ActiveDirectory   # crea tambien la unidad AD: para Get/Set-Acl

function ConvertFrom-SecureStringPlain {
    param([securestring]$Seguro)
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Seguro)
    try     { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

$dominio   = Get-ADDomain
$dnDominio = $dominio.DistinguishedName
$dnOU      = "OU=$NombreOU,$dnDominio"

Write-Host "Dominio : $($dominio.DNSRoot)  ($dnDominio)"
Write-Host "OU      : $dnOU"
Write-Host "Usuario : $Usuario"
Write-Host ""

# ---------------------------------------------------------------------------
# 0. Contrasena a establecer (UNICA pregunta del script)
# ---------------------------------------------------------------------------
$pwd1 = Read-Host -Prompt "Contrasena a establecer a '$Usuario'" -AsSecureString
$pwd2 = Read-Host -Prompt "Repite la contrasena" -AsSecureString
$plano = ConvertFrom-SecureStringPlain $pwd1
if ($plano -ne (ConvertFrom-SecureStringPlain $pwd2)) { throw "Las contrasenas no coinciden." }
if ($plano.Length -eq 0) { throw "La contrasena no puede estar vacia." }
# El rol preparaAD interpola la contrasena en una orden shell entre comillas
# simples: una comilla simple la romperia.
if ($plano.Contains("'")) { throw "La contrasena no puede contener comillas simples (limitacion del rol preparaAD)." }
$plano = $null

# ---------------------------------------------------------------------------
# 1. OU (crearla si no existe)
# ---------------------------------------------------------------------------
try {
    $null = Get-ADOrganizationalUnit -Identity $dnOU
    Write-Host "[OK ] La OU ya existe: $dnOU"
}
catch {
    New-ADOrganizationalUnit -Name $NombreOU -Path $dnDominio `
        -ProtectedFromAccidentalDeletion $true `
        -Description "Cuentas de equipo Linux unidas automaticamente (IAC-IESMHP, rol preparaAD)"
    Write-Host "[OK ] OU creada: $dnOU"
}

# ---------------------------------------------------------------------------
# 2. Usuario (crearlo si no existe) + contrasena
# ---------------------------------------------------------------------------
$cuenta = Get-ADUser -LDAPFilter "(sAMAccountName=$Usuario)"
if (-not $cuenta) {
    $cuenta = New-ADUser -Name $Usuario -SamAccountName $Usuario `
        -UserPrincipalName "$Usuario@$($dominio.DNSRoot)" `
        -AccountPassword $pwd1 -Enabled $true `
        -PasswordNeverExpires $true -CannotChangePassword $true `
        -KerberosEncryptionType AES128,AES256 `
        -Description "Cuenta delegada SOLO para unir equipos Linux a la OU $NombreOU (IAC-IESMHP, rol preparaAD)" `
        -PassThru
    Write-Host "[OK ] Usuario '$Usuario' creado (sin grupos privilegiados) y contrasena establecida."
}
else {
    Set-ADAccountPassword -Identity $cuenta -Reset -NewPassword $pwd1
    if (-not $cuenta.Enabled) { Enable-ADAccount -Identity $cuenta }
    Set-ADUser -Identity $cuenta -PasswordNeverExpires $true
    Write-Host "[OK ] El usuario '$Usuario' ya existia: contrasena reseteada (y cuenta habilitada)."
}

# ---------------------------------------------------------------------------
# 3. Delegacion minima de union sobre la OU (solo las ACE que falten)
# ---------------------------------------------------------------------------
# GUIDs bien conocidos del esquema de AD:
$guidEquipo   = [Guid]'bf967a86-0de6-11d0-a285-00aa003049e2'  # clase: computer
$guidResetPwd = [Guid]'00299570-246d-11d0-a768-00aa006e0529'  # extended right: Reset Password
$guidDnsHost  = [Guid]'72e39547-7b18-11d1-adef-00c04fd8d5cd'  # validated write: dNSHostName
$guidSpn      = [Guid]'f3a64788-5306-11d1-a9c5-0000f80367c1'  # validated write: servicePrincipalName
$guidAcctRest = [Guid]'4c164200-20c0-11d0-a768-00aa006e0529'  # property set: Account Restrictions

$sid = $cuenta.SID
$nt  = $sid.Translate([System.Security.Principal.NTAccount]).Value

$tipo  = [System.Security.AccessControl.AccessControlType]::Allow
$herAll  = [System.DirectoryServices.ActiveDirectorySecurityInheritance]::All
$herDesc = [System.DirectoryServices.ActiveDirectorySecurityInheritance]::Descendents

$reglas = @(
    # Crear objetos EQUIPO en la OU (y sub-OUs). Sin DeleteChild a proposito.
    (New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
        $sid, [System.DirectoryServices.ActiveDirectoryRights]::CreateChild, $tipo, $guidEquipo, $herAll)),
    # Sobre los objetos EQUIPO descendientes de la OU:
    (New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
        $sid, [System.DirectoryServices.ActiveDirectoryRights]::ExtendedRight, $tipo, $guidResetPwd, $herDesc, $guidEquipo)),
    (New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
        $sid, [System.DirectoryServices.ActiveDirectoryRights]::Self, $tipo, $guidDnsHost, $herDesc, $guidEquipo)),
    (New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
        $sid, [System.DirectoryServices.ActiveDirectoryRights]::Self, $tipo, $guidSpn, $herDesc, $guidEquipo)),
    (New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
        $sid, ([System.DirectoryServices.ActiveDirectoryRights]::ReadProperty -bor
               [System.DirectoryServices.ActiveDirectoryRights]::WriteProperty), $tipo, $guidAcctRest, $herDesc, $guidEquipo))
)

function Test-ReglaPresente {
    param($Acl, $Regla, $Cuenta)
    foreach ($ace in $Acl.Access) {
        if ($ace.IdentityReference.Value   -ne $Cuenta)                     { continue }
        if ($ace.AccessControlType         -ne $Regla.AccessControlType)    { continue }
        if ($ace.ActiveDirectoryRights     -ne $Regla.ActiveDirectoryRights){ continue }
        if ($ace.ObjectType                -ne $Regla.ObjectType)           { continue }
        if ($ace.InheritedObjectType       -ne $Regla.InheritedObjectType)  { continue }
        return $true
    }
    return $false
}

$rutaAcl = "AD:\$dnOU"
$acl = Get-Acl -Path $rutaAcl
$nuevas = 0
foreach ($regla in $reglas) {
    if (-not (Test-ReglaPresente -Acl $acl -Regla $regla -Cuenta $nt)) {
        $acl.AddAccessRule($regla)
        $nuevas++
    }
}
if ($nuevas -gt 0) {
    Set-Acl -Path $rutaAcl -AclObject $acl
    Write-Host "[OK ] Delegacion aplicada sobre la OU ($nuevas ACE nuevas de $($reglas.Count))."
}
else {
    Write-Host "[OK ] La delegacion ya estaba completa (0 cambios)."
}

# ---------------------------------------------------------------------------
# Resumen
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "================================================================"
Write-Host " Listo. '$nt' SOLO puede unir equipos al dominio en:"
Write-Host "   $dnOU"
Write-Host " (crear equipos + reset password/validated writes; sin borrado,"
Write-Host "  sin grupos privilegiados, sin permisos fuera de la OU)."
Write-Host ""
Write-Host " Siguiente paso (en el equipo del profesor, Linux):"
Write-Host "   utilesAD/2-CreaVault.sh   (misma contrasena que acabas de teclear)"
Write-Host ""
Write-Host " Auditoria manual de la delegacion:  dsacls `"$dnOU`""
Write-Host "================================================================"
