#!/bin/bash
# vs 05/10/2026
# Arreglo para equipos Ubuntu 26.04 instalados ANTES de que 2-SetupSOdesdeLiveCD.sh
# (v23.9) enmascarase el asistente de bienvenida de GNOME.
#
# Motivo: gnome-initial-setup-upgrade-login.service lanza
# 'gnome-initial-setup --upgrade-user' tras el primer inicio de sesión de cada
# usuario nuevo y provoca un bucle de diálogos de polkit cada minuto
# ("To change your privacy settings you need to authenticate",
# acción com.ubuntu.whoopsiepreferences.change).
#
# Qué hace: enmascara para TODOS los usuarios (locales y de dominio) las unidades
# de usuario gnome-initial-setup-{upgrade,first}-login.service con un enlace a
# /dev/null en /etc/systemd/user (equivale a 'systemctl mask'). Idempotente.
#
# Uso:      sudo ./DesactivaInitialSetup.sh
# Revertir: sudo ./DesactivaInitialSetup.sh --revertir
#           (o: rm /etc/systemd/user/gnome-initial-setup-{upgrade,first}-login.service)

echoverde()    { echo -e "\033[32m$1\033[0m"; }
echorojo()     { echo -e "\033[31m$1\033[0m"; }
echoamarillo() { echo -e "\033[33m$1\033[0m"; }

if [ "$EUID" -ne 0 ]; then
    echorojo "[ERR] Este script debe ejecutarse como root (usa sudo)."
    exit 1
fi

UNIDADES="gnome-initial-setup-upgrade-login.service gnome-initial-setup-first-login.service"
DIRUSER="/etc/systemd/user"

if [ "$1" = "--revertir" ]; then
    for u in $UNIDADES; do
        if [ -L "$DIRUSER/$u" ] && [ "$(readlink "$DIRUSER/$u")" = "/dev/null" ]; then
            rm -f "$DIRUSER/$u"
            echoverde "[OK ] Desenmascarada: $u"
        else
            echoamarillo "[INF] $u no estaba enmascarada; nada que hacer"
        fi
    done
    exit 0
fi

mkdir -p "$DIRUSER" || { echorojo "[ERR] No se pudo crear $DIRUSER"; exit 1; }
for u in $UNIDADES; do
    if ln -sfn /dev/null "$DIRUSER/$u"; then
        echoverde "[OK ] Enmascarada: $DIRUSER/$u -> /dev/null"
    else
        echorojo "[ERR] No se pudo enmascarar $u"
        exit 1
    fi
done

# Cortar el asistente si está corriendo ahora mismo en alguna sesión abierta
# (el enmascarado solo evita que vuelva a arrancar).
if pkill -f 'gnome-initial-setup --upgrade-user' 2>/dev/null; then
    echoverde "[OK ] Procesos 'gnome-initial-setup --upgrade-user' en curso detenidos"
fi

# Recargar el gestor de usuario de las sesiones abiertas para que vean el
# enmascarado sin cerrar sesión (en el resto se aplica en el próximo inicio).
for uid in $(loginctl list-users --no-legend 2>/dev/null | awk '{print $1}'); do
    usr=$(id -nu "$uid" 2>/dev/null) || continue
    [ "$uid" -ge 1000 ] || continue
    if systemctl --user -M "$usr@" daemon-reload 2>/dev/null; then
        echoverde "[OK ] daemon-reload del gestor de usuario de $usr"
    else
        echoamarillo "[INF] No se pudo recargar el gestor de $usr (se aplicará en su próximo inicio de sesión)"
    fi
done

echo ""
ls -l "$DIRUSER"/gnome-initial-setup-*.service
