apt install git -y
GITREPO="https://github.com/victormuelacarriles/IAC-IESMHP.git"
OUT="/opt/iesmhpMint/"
rm -r $OUT 2>/dev/null ||true
git clone $GITREPO $OUT
