############################################################################################################
#Para ejecutar:
 cd /opt/IAC-IESMHP/Ubuntu/ansible/
 ansible-playbook -i localhost, --connection=local roles.yaml --ssh-extra-args="-o StrictHostKeyChecking=no"

 #Para probar solo un rol concreto (por ejemplo, "vmware"):
#ansible-playbook -i localhost, --connection=local roles.yaml --ssh-extra-args="-o StrictHostKeyChecking=no" --tags "vmware"
############################################################################################################
