#!/bin/bash
# ===========================================================================
# 3-UneAlDominio.sh — prepara y une ESTE equipo al dominio Active Directory
# (rol preparaAD de IAC-IESMHP).
# ---------------------------------------------------------------------------
# Ejecutar COMO ROOT en el equipo a unir. Flujo:
#   1. Lanza el rol preparaAD en local (--tags preparaad): instala los
#      prerequisitos (realmd, SSSD, adcli, Kerberos, pam_mkhomedir...).
#   2. Si el equipo YA está unido (realm list) → termina sin tocar nada.
#   3. Si no: comprueba que el dominio se ve por DNS (realm discover),
#      pregunta la contraseña de 'svc-union-linux' (se SUPONE que la cuenta
#      existe — la crea 1-CreaUsuarioUnionAD.ps1 en el DC) y une el equipo
#      con realm join en la OU delegada.
#   4. Verifica la unión y relanza el rol para que despliegue el snippet
#      SSSD del IES (/etc/sssd/conf.d/10-iac-ad.conf) — solo se aplica con
#      el equipo ya unido.
#
# Para unir un AULA entera mejor usar el vault (2-CreaVault.sh) y:
#   ansible-playbook -i equiposIABD.ini roles.yaml --tags preparaad \
#     -e preparaad_unir=true -e @vault/preparaAD-vault.yml --ask-vault-pass
# ===========================================================================
set -euo pipefail

# DEBEN COINCIDIR con defaults/main.yml del rol (preparaad_*). Se pueden
# sobreescribir por entorno:  DOMINIO=otro.local ./3-UneAlDominio.sh
USUARIO_UNION="${USUARIO_UNION:-svc-union-linux}"
DOMINIO="${DOMINIO:-iesmhp.local}"
OU="${OU:-OU=EquiposLinuxAutomatizados,DC=iesmhp,DC=local}"

[[ $EUID -eq 0 ]] || { echo "[ERR] Ejecutar como root (sudo $0)"; exit 1; }

# El script vive en roles/preparaAD/utilesAD/ → la raíz ansible está 3 niveles arriba
_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANSIBLE_DIR="$(cd "$_DIR/../../.." && pwd)"
command -v ansible-playbook >/dev/null || { echo "[ERR] ansible-playbook no encontrado (sudo apt install ansible)"; exit 1; }

# --- 1. Prerequisitos (rol preparaAD en modo local) -------------------------
echo "=== [1/4] Prerequisitos AD (rol preparaAD) ==="
cd "$ANSIBLE_DIR"
ansible-playbook -i localhost, --connection=local roles.yaml --tags preparaad

# --- 2. ¿Ya está unido? -----------------------------------------------------
echo "=== [2/4] ¿Unido ya a un dominio? ==="
UNIDO="$(realm list --name-only 2>/dev/null || true)"
if [[ -n "$UNIDO" ]]; then
    echo "[OK] Este equipo YA está unido a: $UNIDO — nada que hacer."
    exit 0
fi
echo "No unido. Se intentará la unión a '$DOMINIO'."

# --- 3. Unión ----------------------------------------------------------------
echo "=== [3/4] Unión al dominio ==="
if ! realm discover "$DOMINIO" >/dev/null 2>&1; then
    echo "[ERR] El dominio '$DOMINIO' NO se resuelve desde este equipo."
    echo "      El rol ya intentó el split-DNS hacia los DC (preparaad_dominio_dnss),"
    echo "      así que lo probable es que NO haya conectividad con ellos"
    echo "      (routing/firewall del aula). Diagnóstico:"
    echo "        resolvectl status"
    echo "        dig -t SRV _ldap._tcp.$DOMINIO"
    echo "        dig -t SRV _ldap._tcp.$DOMINIO @<IP_de_un_DC>"
    exit 1
fi
echo "[OK] Dominio visible por DNS."

read -rs -p "Contraseña de '$USUARIO_UNION': " PASS; echo
[[ -n "$PASS" ]] || { echo "[ERR] Contraseña vacía."; exit 1; }

# realm join lee la contraseña por stdin con --unattended (sin tty).
# Crea la cuenta de equipo en la OU delegada, escribe /etc/sssd/sssd.conf,
# genera /etc/krb5.keytab y habilita+arranca sssd.
if ! printf '%s\n' "$PASS" | realm join --unattended \
        --user="$USUARIO_UNION" --computer-ou="$OU" "$DOMINIO"; then
    unset PASS
    echo "[ERR] realm join ha fallado. Causas típicas: contraseña incorrecta,"
    echo "      reloj desfasado >5 min con el DC (timedatectl), cuenta sin"
    echo "      delegación en la OU, u OU inexistente ($OU)."
    exit 1
fi
unset PASS

UNIDO="$(realm list --name-only 2>/dev/null || true)"
[[ -n "$UNIDO" ]] || { echo "[ERR] realm join terminó pero 'realm list' sigue vacío."; exit 1; }
echo "[OK] Equipo unido a: $UNIDO"

# --- 4. Snippet SSSD del IES (re-pase del rol, ya unido) ---------------------
echo "=== [4/4] Configuración SSSD del IES (re-pase del rol) ==="
ansible-playbook -i localhost, --connection=local roles.yaml --tags preparaad

echo
echo "================================================================"
echo " Correcto: $(hostname) unido a $UNIDO (OU: $OU)"
echo " Pruebas sugeridas:"
echo "   realm list"
echo "   getent passwd <usuario_del_dominio>"
echo "   su - <usuario_del_dominio>   (crea el home vía pam_mkhomedir)"
echo "================================================================"
