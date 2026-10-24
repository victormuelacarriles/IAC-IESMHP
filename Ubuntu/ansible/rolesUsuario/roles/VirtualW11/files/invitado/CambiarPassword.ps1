# CambiarPassword.ps1 — arranque automático de Windows (autologon) y cambio de
# la contraseña inicial del usuario. Parte del rol VirtualW11 (IAC-IESMHP).
#
# Dos modos:
#  - Instalación (lo lanza el rol, sin preguntas; argumentos por posición):
#      CambiarPassword.ps1 instalar <usuario> si|no <contraseña inicial>
#    Se copia a C:\ProgramData\IAC-IESMHP\, deja en el escritorio público el
#    acceso directo "Cambiar contraseña y arranque automático" y, con "si",
#    configura el arranque automático de <u> con la contraseña
#    inicial.
#  - Interactivo (el alumno, desde el acceso directo del escritorio):
#    explica qué hace; si el usuario sigue con la contraseña inicial pide una
#    nueva (dos veces), se la pone y configura el arranque automático con ella;
#    si ya la cambió, puede volver a configurar el arranque con la actual.
#
# La contraseña del arranque automático se guarda como secreto LSA
# ("DefaultPassword", como Autologon de Sysinternals), no en texto plano en el
# registro.
param(
    [Parameter(Position = 0)][string]$Accion = '',              # 'instalar' = modo del rol
    [Parameter(Position = 1)][string]$Usuario = $env:USERNAME,
    [Parameter(Position = 2)][string]$Autologon = 'no',         # 'si' = configurarlo
    [Parameter(Position = 3)][string]$PasswordInicial = 'usuario@1'
)
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$Destino = Join-Path $env:ProgramData 'IAC-IESMHP\CambiarPassword.ps1'
$Acceso  = Join-Path $env:PUBLIC 'Desktop\Cambiar contraseña y arranque automático.lnk'
$Winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'

function Set-SecretoLsa([string]$Clave, [string]$Valor) {
    if (-not ('IacLsa' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class IacLsa {
    [StructLayout(LayoutKind.Sequential)]
    struct LSA_UNICODE_STRING { public ushort Length; public ushort MaximumLength; public IntPtr Buffer; }
    [StructLayout(LayoutKind.Sequential)]
    struct LSA_OBJECT_ATTRIBUTES { public int Length; public IntPtr RootDirectory; public IntPtr ObjectName;
        public int Attributes; public IntPtr SecurityDescriptor; public IntPtr SecurityQualityOfService; }
    [DllImport("advapi32.dll")] static extern uint LsaOpenPolicy(IntPtr s, ref LSA_OBJECT_ATTRIBUTES a, uint acc, out IntPtr h);
    [DllImport("advapi32.dll")] static extern uint LsaStorePrivateData(IntPtr h, ref LSA_UNICODE_STRING k, ref LSA_UNICODE_STRING d);
    [DllImport("advapi32.dll")] static extern uint LsaClose(IntPtr h);
    [DllImport("advapi32.dll")] static extern int LsaNtStatusToWinError(uint s);
    static LSA_UNICODE_STRING Cadena(string s) {
        var u = new LSA_UNICODE_STRING();
        u.Buffer = Marshal.StringToHGlobalUni(s);
        u.Length = (ushort)(s.Length * 2);
        u.MaximumLength = (ushort)(s.Length * 2 + 2);
        return u;
    }
    public static void Guardar(string clave, string valor) {
        var oa = new LSA_OBJECT_ATTRIBUTES();
        IntPtr h;
        uint r = LsaOpenPolicy(IntPtr.Zero, ref oa, 0x000F0FFF, out h);   // POLICY_ALL_ACCESS
        if (r != 0) throw new System.ComponentModel.Win32Exception(LsaNtStatusToWinError(r));
        var k = Cadena(clave); var d = Cadena(valor);
        try {
            r = LsaStorePrivateData(h, ref k, ref d);
            if (r != 0) throw new System.ComponentModel.Win32Exception(LsaNtStatusToWinError(r));
        } finally {
            LsaClose(h); Marshal.FreeHGlobal(k.Buffer); Marshal.FreeHGlobal(d.Buffer);
        }
    }
}
'@
    }
    [IacLsa]::Guardar($Clave, $Valor)
}

function Set-ArranqueAutomatico([string]$U, [string]$P) {
    Set-ItemProperty $Winlogon -Name AutoAdminLogon    -Value '1'
    Set-ItemProperty $Winlogon -Name DefaultUserName   -Value $U
    Set-ItemProperty $Winlogon -Name DefaultDomainName -Value $env:COMPUTERNAME
    # Fuera la contraseña en texto plano (si la hubiera) y el contador de usos.
    Remove-ItemProperty $Winlogon -Name DefaultPassword -ErrorAction SilentlyContinue
    Remove-ItemProperty $Winlogon -Name AutoLogonCount  -ErrorAction SilentlyContinue
    Set-SecretoLsa 'DefaultPassword' $P
    # "Solo Windows Hello" impide el inicio automático con contraseña.
    $pl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\PasswordLess\Device'
    if (-not (Test-Path $pl)) { New-Item $pl -Force | Out-Null }
    Set-ItemProperty $pl -Name DevicePasswordLessBuildVersion -Value 0 -Type DWord
}

function Test-Password([string]$U, [string]$P) {
    Add-Type -AssemblyName System.DirectoryServices.AccountManagement
    $ctx = New-Object System.DirectoryServices.AccountManagement.PrincipalContext('Machine')
    try { return $ctx.ValidateCredentials($U, $P) } finally { $ctx.Dispose() }
}

function Get-Texto([Security.SecureString]$s) {
    $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
}

# =================================================================== instalar
if ($Accion -eq 'instalar') {
    $ErrorActionPreference = 'Stop'
    try {
        New-Item (Split-Path $Destino) -ItemType Directory -Force | Out-Null
        if ($PSCommandPath -ne $Destino) { Copy-Item $PSCommandPath $Destino -Force }
        $sh = New-Object -ComObject WScript.Shell
        $l = $sh.CreateShortcut($Acceso)
        $l.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
        $l.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$Destino`" -PasswordInicial `"$PasswordInicial`""
        $l.IconLocation = "$env:SystemRoot\System32\imageres.dll,77"
        $l.Description = 'Cambia la contraseña inicial y configura el arranque automático'
        $l.Save()
        "Script        : $Destino"
        "Escritorio    : $Acceso"
        if ($Autologon -eq 'si') {
            $antes = (Get-ItemProperty $Winlogon -ErrorAction SilentlyContinue)
            Set-ArranqueAutomatico $Usuario $PasswordInicial
            if ($antes.AutoAdminLogon -eq '1' -and $antes.DefaultUserName -eq $Usuario) {
                "Autologon     : $Usuario (ya estaba; contraseña inicial)"
            } else {
                "Autologon     : $Usuario configurado (contraseña inicial)"
            }
        } else {
            "Autologon     : no se toca (el usuario ya cambió la contraseña)"
        }
        exit 0
    } catch {
        "[ERR] $_"
        exit 1
    }
}

# ================================================================ interactivo
# Hace falta ser administrador (elevado): si no, se vuelve a lanzar con UAC.
$yo = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $yo.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"",
        '-Usuario', "`"$Usuario`"", '-PasswordInicial', "`"$PasswordInicial`"")
    exit
}

$Host.UI.RawUI.WindowTitle = 'Contraseña y arranque automático'
Write-Host ''
Write-Host '  CONTRASEÑA Y ARRANQUE AUTOMÁTICO DE WINDOWS' -ForegroundColor Cyan
Write-Host '  ==========================================='
Write-Host ''
Write-Host "  Este script configura el ARRANQUE AUTOMÁTICO de esta máquina: al"
Write-Host "  encenderla, Windows entrará solo con tu usuario ($Usuario)."
Write-Host ''
Write-Host '  Para eso necesita tu contraseña. Si sigues con la contraseña inicial'
Write-Host '  (la misma para todos), DEBES CAMBIARLA: el script te pedirá una nueva,'
Write-Host '  te la pondrá y configurará el arranque automático con ella.'
Write-Host ''

try {
    if (Test-Password $Usuario $PasswordInicial) {
        Write-Host '  Sigues con la contraseña inicial: hay que cambiarla.' -ForegroundColor Yellow
        Write-Host ''
        while ($true) {
            $p1 = Get-Texto (Read-Host '  Nueva contraseña' -AsSecureString)
            $p2 = Get-Texto (Read-Host '  Repite la nueva contraseña' -AsSecureString)
            if ($p1 -ne $p2)              { Write-Host '  No coinciden. Otra vez.' -ForegroundColor Red; continue }
            if ($p1.Length -eq 0)         { Write-Host '  No puede estar vacía. Otra vez.' -ForegroundColor Red; continue }
            if ($p1 -eq $PasswordInicial) { Write-Host '  Tiene que ser distinta de la inicial. Otra vez.' -ForegroundColor Red; continue }
            break
        }
        Set-LocalUser -Name $Usuario -Password (ConvertTo-SecureString $p1 -AsPlainText -Force)
        Write-Host ''
        Write-Host '  Contraseña cambiada.' -ForegroundColor Green
    } else {
        Write-Host '  Ya no tienes la contraseña inicial (bien).' -ForegroundColor Green
        Write-Host '  Para configurar el arranque automático escribe tu contraseña ACTUAL.'
        Write-Host '  (Deja vacío y pulsa Enter para salir sin cambiar nada.)'
        Write-Host ''
        while ($true) {
            $p1 = Get-Texto (Read-Host '  Contraseña actual' -AsSecureString)
            if ($p1.Length -eq 0) { Write-Host '  No se ha cambiado nada.'; Read-Host '  Pulsa Enter para cerrar' | Out-Null; exit 0 }
            if (Test-Password $Usuario $p1) { break }
            Write-Host '  Contraseña incorrecta. Otra vez.' -ForegroundColor Red
        }
    }

    Set-ArranqueAutomatico $Usuario $p1
    Write-Host '  Arranque automático configurado con tu contraseña.' -ForegroundColor Green
    Write-Host ''
    Write-Host '  ¡ACUÉRDATE DE TU NUEVA CONTRASEÑA! La necesitarás para entrar en esta' -ForegroundColor Yellow
    Write-Host '  máquina en remoto desde Remmina (Escritorio remoto, RDP).' -ForegroundColor Yellow
} catch {
    Write-Host ''
    Write-Host "  ERROR: $_" -ForegroundColor Red
    Write-Host '  No se ha completado. Avisa al profesor.' -ForegroundColor Red
}
Write-Host ''
Read-Host '  Pulsa Enter para cerrar' | Out-Null
