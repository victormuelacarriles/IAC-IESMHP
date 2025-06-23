#!/bin/bash
#Script que descarga desde GIT la última versión de los scripts de instalación de IESMHP
#y los copia a /LiveCDiesmhp, y ejecuta el script de configuración del LiveCD
set -e

RAIZSCRIPTSLIVE="/LiveCDiesmhp"
SCRIPT1NOMBRE="1-SetupLiveCD.sh"
SCRIPT1="$RAIZSCRIPTSLIVE/Mint/$SCRIPT1NOMBRE"
RAIZLOG="/var/log/iesmhpLinux"
LOG0="$RAIZLOG/$0.log"
GITREPO="https://github.com/victormuelacarriles/IAC-IESMHP.git"
mkdir -p $RAIZLOG
echoverde() {
    TEXTO=$1
    echo -e "\033[32m$TEXTO\033[0m"
    echo $TEXTO >> $LOG0
}

echoverde "($0) $RAIZLOG"

echoverde "En español (si se puede) y con usuarios mint:mint root:root por si hay que depurar"
setxkbmap es || true && loadkeys es ||true
echo "mint:prov" | chpasswd
echo "root:prov" | chpasswd
echo "mint:mint" | chpasswd
echo "root:root" | chpasswd

echoverde "Actualizamos..."
rm /etc/apt/sources.list 2>/dev/null || true
apt-get update 2>&1 | tee -a $LOG0

echoverde "Instalamos ssh y git"
apt-get install -y ssh git 2>&1 | tee -a $LOG0

rm -r $RAIZSCRIPTSLIVE 2>/dev/null || true
git clone $GITREPO $RAIZSCRIPTSLIVE 2>&1 | tee -a $LOG0
chmod +x $RAIZSCRIPTSLIVE/Mint/*.sh
mkdir -p $RAIZLOG 2>&1 | tee -a $LOG0

LOGSig="$RAIZLOG/$SCRIPT1NOMBRE.log"
echoverde "Ejecutamos $SCRIPT1 (log en $LOGSig)..." | tee -a $LOG0
/bin/bash ./$SCRIPT1 2>&1 | tee -a $LOGSig || tee -a $LOG0

#TODO: comprobación final de errores



