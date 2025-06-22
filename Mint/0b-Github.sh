#!/bin/bash
#TODO: - scripts en GITHUB
#      - git clone a /opt/iesmhpLinux
#      - Logs en     /var/log/iesmhpLinux/*.log 
#      - Arreglar este script para que acepte parámentros (isoentrada / isosalida)  y que funcione


RAIZSCRIPTS="/opt/iesmhpLinux"
RAIZLOGS="/var/log/iesmhpLinux"
set -e
# Funciones de colores
echoverde() {  
    echo -e "\033[32m$1\033[0m" 
}
echorojo()  {
      echo -e "\033[31m$1\033[0m" 
}  
rm /etc/apt/sources.list
#mv /etc/apt/sources.list /sources.list.bak
apt-get update
#Instalamos ssh y vmware-tools
apt-get install -y ssh git
