############################################################################################################
#Para ejecutar:
 cd /opt/IAC-IESMHP/Ubuntu/ansible/
 ansible-playbook -i localhost, --connection=local roles.yaml --ssh-extra-args="-o StrictHostKeyChecking=no"

#Para probar solo un rol concreto (por ejemplo, "vmware"):
#ansible-playbook -i localhost, --connection=local roles.yaml --ssh-extra-args="-o StrictHostKeyChecking=no" --tags "vmware"
#ansible-playbook -i localhost, --connection=local roles.yaml --ssh-extra-args="-o StrictHostKeyChecking=no" --tags "certificados"

#Para probar solo un rol concreto pero en todos los equipos (por ejemplo, "certificados"):
#ansible-playbook -i equiposSMRD.ini roles.yaml  --tags "certificados"

############################################################################################################
