apt update && apt install git -y
GITREPO="https://github.com/victormuelacarriles/IAC-IESMHP.git"
OUT="/opt/iesmhpMint"
cd /opt
rm -r "$OUT/" 2>/dev/null ||true
git clone $GITREPO "$OUT/"
cd "$OUT/Mint/utiles"
sh ./Auto-Ansible.sh
cd "/opt/iesmhpMint/Mint/ansible/ProbandoRoles"
clear
ls
echo 'ansible-playbook -i localhost, --connection=local roles.yaml --ssh-extra-args="-o StrictHostKeyChecking=no"'
