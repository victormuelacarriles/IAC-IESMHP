############################################################################################################
#Para ejecutar:
 cd /opt/IAC-IESMHP/Ubuntu/ansible/rolesUsuario/
 
 #Dede cada equipo (localmente)
 #ansible-playbook -i localhost, --connection=local rolesUsuario.yaml --ssh-extra-args="-o StrictHostKeyChecking=no"

#IABD
#Desde el servidor de Ansible (remotamente)
ansible-playbook -i ./equiposIABD-alumnos2627.ini rolesUsuario.yaml

#SMRD
ansible-playbook -i ./EquiposSMRD-alumnos2627.ini rolesUsuario.yaml

############################################################################################################
