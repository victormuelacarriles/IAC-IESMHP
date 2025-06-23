#!/bin/bash
#Script que descarga desde GIT la última versión de los scripts de instalación de IESMHP
#y los copia a /LiveCDiesmhp, y ejecuta el script de configuración del LiveCD
set -e

RAIZSCRIPTSLIVE="/LiveCDiesmhp"
SCRIPT0="$RAIZSCRIPTSLIVE/Mint/1-SetupLiveCD.sh"
RAIZLOG="/var/log/iesmhpLinux/"
GITREPO="https://github.com/victormuelacarriles/IAC-IESMHP.git"
echoverde() {  
    echo -e "\033[32m$1\033[0m" 
}

echoverde "$($0) - Preconfiguramos equipo para ejecutar la última versión de los scripts de instalación de IESMHP"

#En español (si se puede) y con usuario mint:mint por si hay que depurar
setxkbmap es | true
echo "mint:mint" | chpasswd

rm /etc/apt/sources.list | true
#mv /etc/apt/sources.list /sources.list.bak
apt-get update
#Instalamos ssh y vmware-tools
apt-get install -y ssh git

git clone $GITREPO $RAIZSCRIPTSLIVE
chmod +x $RAIZSCRIPTSLIVE/Mint/*.sh
mkdir -p $RAIZLOG
/bin/bash $SCRIPT0 | tee -a $RAIZLOG/$SCRIPT0.log

#FALLA!!!! el script 1-SetupLiveCD.sh no se ejecuta correctamente y se detiene. Es necesario crear log y depurarlo


