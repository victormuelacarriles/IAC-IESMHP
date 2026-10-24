#!/bin/bash
# Ejecuta un script PowerShell DENTRO del Windows invitado.
#
#   invitado.sh --detecta <vmx>                  → dice cómo se puede entrar
#   invitado.sh <vmx> <script.ps1> [argumentos]  → ejecuta el script
#
# Formas de entrar (IAC_METODO, la que devuelve --detecta):
#   tools:<usuario>  por VMware Tools (vmrun). No usa la red: funciona aunque se
#                    cambie la IP. Las operaciones de vmrun en el invitado
#                    exigen usuario y contraseña de Windows (IAC_PASSWORD).
#   ssh:<usuario>    por SSH con la clave IAC_SSH_KEY en IAC_IP, como el primero
#                    de IAC_SSH_USUARIO ("u1 u2") que entre. No usa contraseña.
#
# ⚠ Cada contraseña errónea cuenta para el BLOQUEO de cuentas de Windows 11
# (por defecto 10 fallos → cuenta bloqueada 10 min, también para SSH). Por
# eso --detecta prueba cada usuario UNA vez y el rol usa luego siempre el
# método que funcionó, en vez de reintentar contraseñas en cada operación.
#
# Orden de --detecta: Tools como el 1er usuario de IAC_USUARIOS → SSH →
# Tools como el resto de IAC_USUARIOS (p. ej. el de la plantilla, la 1ª vez).
#
# Variables: IAC_USUARIOS="u1 u2"  IAC_PASSWORD  IAC_SSH_KEY  IAC_SSH_USUARIO
#            IAC_IP  IAC_METODO  IAC_SSH_INTENTOS (6, cada 5 s)
#            TIMEOUT (segundos por llamada a vmrun, 300 por defecto)
#
# Ejecutar: muestra la salida del script y sale con su código. Códigos
# propios: 90 = no se pudo entrar, 91 = no se pudo recoger la salida,
# 92 = salida sin código.
set -uo pipefail

G='C:\Windows\Temp'
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
SSH_O=(-i "${IAC_SSH_KEY:-/dev/null}" -o BatchMode=yes -o StrictHostKeyChecking=no
       -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10)

vm() {   # vm <usuario> <orden vmrun...>
    local u="$1"; shift
    timeout "${TIMEOUT:-300}" vmrun -T ws -gu "$u" -gp "${IAC_PASSWORD:-}" "$@"
}

hay_ssh() {
    [ -n "${IAC_SSH_KEY:-}" ] && [ -n "${IAC_IP:-}" ]
}

# ------------------------------------------------------------------ detectar
if [ "${1:-}" = "--detecta" ]; then
    VMX="$2"; ERRORES=""
    read -r -a USUARIOS <<< "${IAC_USUARIOS:-}"

    probar_tools() {   # una sola autenticación por usuario
        local out
        if out=$(vm "$1" directoryExistsInGuest "$VMX" 'C:\Windows' 2>&1); then
            echo "tools:$1"; exit 0
        fi
        ERRORES+="Tools como $1: ${out:-sin respuesta}. "
    }

    [ "${#USUARIOS[@]}" -gt 0 ] && probar_tools "${USUARIOS[0]}"
    if hay_ssh && [ -n "${IAC_SSH_USUARIO:-}" ]; then
        # Recién arrancada, sshd puede tardar: se reintenta (la clave no
        # cuenta para el bloqueo de cuentas). Cada vuelta prueba todos.
        for i in $(seq "${IAC_SSH_INTENTOS:-6}"); do
            for su in ${IAC_SSH_USUARIO}; do
                if out=$(ssh "${SSH_O[@]}" -l "$su" "$IAC_IP" hostname 2>&1 </dev/null); then
                    echo "ssh:$su"; exit 0
                fi
            done
            sleep 5
        done
        ERRORES+="SSH como ${IAC_SSH_USUARIO// //}@$IAC_IP: ${out:-sin respuesta}. "
    fi
    for u in "${USUARIOS[@]:1}"; do probar_tools "$u"; done

    echo "[ERR] No se puede entrar en el invitado. $ERRORES" | tr -s '\n' ' '
    echo
    exit 90
fi

# ------------------------------------------------------------------ ejecutar
VMX="$1"; PS1="$2"; shift 2
ID="iac-$$-$RANDOM"
METODO="${IAC_METODO:-}"
[ -n "$METODO" ] || METODO=$("$0" --detecta "$VMX") || { echo "$METODO"; exit 90; }

# Cada argumento entre comillas dobles (pueden llevar espacios).
ARGS=""
for a in "$@"; do ARGS+=" \"$a\""; done

salida() {   # muestra la salida sin la marca del código y sale con él
    local rc
    rc=$(sed -n 's/^IAC_RC=\([0-9]*\).*/\1/p' "$1" | tail -1)
    sed '/^IAC_RC=/d' "$1" | tr -d '\r' | iconv -f UTF-8 -t UTF-8 -c
    exit "${rc:-92}"
}

case "$METODO" in
tools:*)
    U="${METODO#tools:}"
    if ! out=$(vm "$U" CopyFileFromHostToGuest "$VMX" "$PS1" "$G\\$ID.ps1" 2>&1); then
        echo "[ERR] No se pudo copiar el script al invitado (Tools como $U): ${out:-sin respuesta}"
        exit 90
    fi
    echo "[invitado] por VMware Tools como $U" >&2
    # cmd /v:on: !ERRORLEVEL! se evalúa al final (%ERRORLEVEL% se expandiría antes).
    vm "$U" runProgramInGuest "$VMX" 'C:\Windows\System32\cmd.exe' \
      "/v:on /c powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $G\\$ID.ps1$ARGS > $G\\$ID.out 2>&1 & echo IAC_RC=!ERRORLEVEL!>> $G\\$ID.out" \
      >/dev/null 2>&1
    # El script puede haber desactivado el usuario con el que entró (usuario.ps1
    # desactiva el de la plantilla): entonces la salida se recoge con el
    # primero de IAC_USUARIOS (el administrador recién creado).
    read -r -a USUARIOS <<< "${IAC_USUARIOS:-}"
    for U2 in "$U" "${USUARIOS[0]:-$U}"; do
        if vm "$U2" CopyFileFromGuestToHost "$VMX" "$G\\$ID.out" "$TMP/out" >/dev/null 2>&1; then
            vm "$U2" runProgramInGuest "$VMX" 'C:\Windows\System32\cmd.exe' \
                "/c del /q $G\\$ID.ps1 $G\\$ID.out" >/dev/null 2>&1 || true
            salida "$TMP/out"
        fi
        [ "$U2" = "${USUARIOS[0]:-$U}" ] && break
    done
    echo "[ERR] No se pudo recoger la salida del invitado"
    exit 91
    ;;
ssh:*)
    SU="${METODO#ssh:}"
    hay_ssh || { echo "[ERR] Faltan IAC_SSH_KEY/IAC_IP"; exit 90; }
    # Un .cmd que ejecuta el script y escribe su código: así no depende de si
    # el shell de sshd es cmd o PowerShell (PowerShell no devuelve el código).
    printf '@echo off\r\npowershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File %s\\%s.ps1%s\r\necho IAC_RC=%%ERRORLEVEL%%\r\n' \
        "$G" "$ID" "$ARGS" > "$TMP/$ID.cmd"
    cp "$PS1" "$TMP/$ID.ps1"   # scp de varios ficheros conserva el nombre
    if ! out=$(scp "${SSH_O[@]}" "$TMP/$ID.ps1" "$TMP/$ID.cmd" "$SU@$IAC_IP:C:/Windows/Temp/" 2>&1); then
        echo "[ERR] No se pudo copiar el script al invitado (SSH): ${out:-sin respuesta}"
        exit 90
    fi
    echo "[invitado] por SSH como $SU@$IAC_IP" >&2
    ssh "${SSH_O[@]}" -l "$SU" "$IAC_IP" "$G\\$ID.cmd" > "$TMP/out" 2>&1 </dev/null
    ssh "${SSH_O[@]}" -l "$SU" "$IAC_IP" "cmd /c del /q $G\\$ID.ps1 $G\\$ID.cmd" >/dev/null 2>&1 </dev/null || true
    salida "$TMP/out"
    ;;
*)
    echo "[ERR] Método desconocido: $METODO"
    exit 90
    ;;
esac
