#!/usr/bin/env bash
# Exécution côté conteneur dev
# - Initialise repo git
# - Crée mini-projet
# - Configure le script
# - Déploie HEAD vers SFTP
# - Vérifie côté distant
set -euo pipefail

log() { echo -e "\033[0;34m[dev]\033[0m $*"; }
fail() { echo -e "\033[0;31m[dev]\033[0m $*" >&2; exit 1; }

log "Initialisation du repo de test..."
rm -rf /workspace/tests/project
mkdir -p /workspace/tests/project
cd /workspace/tests/project || fail "cd test project"

git init -q || fail "git init"
git config user.email test@example.com
git config user.name "Test Bot"

# Commit initial vide pour que HEAD ait toujours un parent
git commit --allow-empty -m "chore: initial" -q

log "Création mini-projet avec sous-dossiers..."
mkdir -p web/css web/js
cat > web/index.html << 'EOF'
<!doctype html>
<html>
  <head><title>Test</title></head>
  <body>Hello v1</body>
</html>
EOF
echo "body{color:blue} /* v1 */" > web/css/style.css
echo "console.log('v1')" > web/js/app.js
echo "ignored top-level file" > README.md

git add web/index.html web/css/style.css web/js/app.js README.md
git commit -m "feat: initial commit v1" -q

log "Init config déploiement..."
chmod +x /workspace/src/git-sftp-deploy.sh
/workspace/src/git-sftp-deploy.sh init /workspace/tests/project/deploy.conf

# Ajuster la config: SSH_HOST sftp-test, REMOTE_PATH /var/www/html
sed -i 's#^SSH_HOST=.*#SSH_HOST="sftp-test"#' /workspace/tests/project/deploy.conf
sed -i 's#^REMOTE_PATH=.*#REMOTE_PATH="/var/www/html"#' /workspace/tests/project/deploy.conf
sed -i 's#^LOCAL_ROOT=.*#LOCAL_ROOT="web"#' /workspace/tests/project/deploy.conf

log "Déploiement HEAD (v1)..."
/workspace/src/git-sftp-deploy.sh deploy HEAD /workspace/tests/project/deploy.conf || fail "déploiement v1 échoué"
backup1_abs=$(ls -1d /workspace/src/save-deploy/HEAD/* | sort | tail -n1)
backup1_rel="${backup1_abs#/workspace/src/save-deploy/}"

log "Vérification côté distant..."
ssh sftp-test "ls -laR /var/www/html" || fail "ssh listing"
ssh sftp-test "test -f /var/www/html/index.html" || fail "index.html absent côté distant"
ssh sftp-test "grep -q 'Hello v1' /var/www/html/index.html" || fail "contenu index v1 incorrect"
ssh sftp-test "grep -q 'v1' /var/www/html/css/style.css" || fail "contenu css v1 incorrect"

log "Préparation v2 (modifs + nouveau fichier dans sous-dossier)..."
sed -i 's/Hello v1/Hello v2/' web/index.html
sed -i 's/v1/v2/' web/css/style.css
mkdir -p web/img
echo "LOGO v2" > web/img/logo.txt
git add -A
git commit -m "feat: v2 update and new file" -q

log "Déploiement HEAD (v2)..."
/workspace/src/git-sftp-deploy.sh deploy HEAD /workspace/tests/project/deploy.conf || fail "déploiement v2 échoué"
backup2_abs=$(ls -1d /workspace/src/save-deploy/HEAD/* | sort | tail -n1)
backup2_rel="${backup2_abs#/workspace/src/save-deploy/}"

log "Vérification côté distant (v2)..."
ssh sftp-test "grep -q 'Hello v2' /var/www/html/index.html" || fail "contenu index v2 incorrect"
ssh sftp-test "test -f /var/www/html/img/logo.txt" || fail "logo.txt manquant côté distant"
ssh sftp-test "grep -q 'LOGO v2' /var/www/html/img/logo.txt" || fail "contenu logo.txt incorrect"

log "Restauration (rollback de v2 via backup2)..."
/workspace/src/git-sftp-deploy.sh restore "$backup2_rel" /workspace/tests/project/deploy.conf || fail "restauration échouée"

log "Vérification côté distant après restauration (retour v1)..."
ssh sftp-test "grep -q 'Hello v1' /var/www/html/index.html" || fail "restauration: index attendu v1"
ssh sftp-test "grep -q 'v1' /var/www/html/css/style.css" || fail "restauration: css attendu v1"
ssh sftp-test "test ! -f /var/www/html/img/logo.txt" || fail "restauration: logo.txt devrait être supprimé"

log "OK: déploiement vérifié"
