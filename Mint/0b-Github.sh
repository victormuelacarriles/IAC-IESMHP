#!/bin/bash
#Script que descarga desde GIT la última versión de los scripts de instalación de IESMHP
#y los copia a /LiveCDiesmhp, y ejecuta el script de configuración del LiveCD
set -e

RAIZSCRIPTSLIVE="/LiveCDiesmhp"
SCRIPT0="$RAIZSCRIPTSLIVE/Mint/1-SetupLiveCD.sh"
RAIZLOG="/var/log/iesmhpLinux"
GITREPO="https://github.com/victormuelacarriles/IAC-IESMHP.git"
mkdir -p $RAIZLOG
echoverde() {
    echo -e "\033[32m$1\033[0m"
}

echoverde "($0)"

echo "En español (si se puede) y con usuario mint:mint por si hay que depurar"
setxkbmap es || true && loadkeys es ||true

echo "mint:prov" | chpasswd
echo "mint:mint" | chpasswd

echoverde "Actualizamos..."
rm /etc/apt/sources.list 2>/dev/null || true
apt-get update 2>&1 | tee -a $RAIZLOG/$0.log

echoverde "Instalamos ssh y git"
apt-get install -y ssh git 2>&1 | tee -a $RAIZLOG/$0.log

rm -r $RAIZSCRIPTSLIVE 2>/dev/null || true
git clone $GITREPO $RAIZSCRIPTSLIVE 2>&1 | tee -a $RAIZLOG/$0.log
chmod +x $RAIZSCRIPTSLIVE/Mint/*.sh
mkdir -p $RAIZLOG 2>&1 | tee -a $RAIZLOG/$0.log

echoverde "Ejecutamos $SCRIPT0..."
/bin/bash $SCRIPT0 2>&1 | tee -a $RAIZLOG/$SCRIPT0.log



