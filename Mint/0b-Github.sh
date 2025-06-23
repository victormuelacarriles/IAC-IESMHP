#!/bin/bash
#Script que descarga desde GIT la última versión de los scripts de instalación de IESMHP
#y los copia a /LiveCDiesmhp, y ejecuta el script de configuración del LiveCD

RAIZSCRIPTSLIVE="/LiveCDiesmhp"
SCRIPT0="$RAIZSCRIPTSLIVE/Mint/1-SetupLiveCD.sh"
GITREPO="https://github.com/victormuelacarriles/IAC-IESMHP.git"

set -e
setxkbmap es
echo "mint:mint" | chpasswd
rm /etc/apt/sources.list
#mv /etc/apt/sources.list /sources.list.bak
apt-get update
#Instalamos ssh y vmware-tools
apt-get install -y ssh git

git clone $GITREPO $RAIZSCRIPTSLIVE
/bin/bash $SCRIPT0

