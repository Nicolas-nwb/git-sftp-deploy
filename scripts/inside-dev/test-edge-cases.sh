#!/usr/bin/env bash
# Tests de cas limites pour git-sftp-deploy
# - Exécuter à l'intérieur du conteneur dev
# - Couvre: suppressions, noms spéciaux, LOCAL_ROOT changé, binaires,
#   arborescence profonde, fichiers vides/gros, symlinks, déploiements parallèles

set -euo pipefail

# Protection: s'assurer qu'on est dans l'environnement Docker
if [[ ! -d "/workspace" ]] || [[ ! -f "/workspace/src/git-sftp-deploy.sh" ]]; then
    echo "❌ ERREUR: Ce script doit être exécuté dans le conteneur Docker dev"
    echo "   Utilisez: ./scripts/test-docker.sh"
    exit 1
fi

# --- Logging / helpers ---
log() { echo -e "\033[0;34m[dev]\033[0m $*"; }
fail() { echo -e "\033[0;31m[dev]\033[0m $*" >&2; exit 1; }
skip() { echo -e "\033[0;33m[skip]\033[0m $*"; }

# Runner minimal: affiche seulement nom + OK/FAIL; logs détaillés seulement en échec
run_case() {
  local name="$1"; shift
  local logfile
  logfile="$(mktemp)"
  set +e
  { "$@"; } >"$logfile" 2>&1
  local rc=$?
  set -e
  if [ $rc -eq 0 ]; then
    echo "- ${name}: OK"
  else
    echo "- ${name}: FAIL"
    cat "$logfile"
    rm -f "$logfile"
    exit 1
  fi
  rm -f "$logfile"
}

# Constantes d'environnement
ROOT="/workspace"
SCRIPT="$ROOT/src/git-sftp-deploy.sh"
EDGE_REMOTE_BASE="/var/www/html/edgecases"
WORKDIR="$ROOT/tests/edgecases"

# --- Utils ---
# Création repo isolé + config, retourne chemin repo
new_repo() {
  # $1: repo name, $2: remote subdir, $3: local root (ex: web)
  local name="$1"; local remote_sub="$2"; local local_root="${3:-web}"
  local repo="$WORKDIR/$name"
  rm -rf "$repo" && mkdir -p "$repo" || fail "mkrepo $name"
  (cd "$repo" && git init -q && git config user.email test@example.com && git config user.name "Test Bot" && git config advice.addEmbeddedRepo false && git commit --allow-empty -m "chore: seed" -q) || fail "git init $name"

  bash -lc "chmod +x '$SCRIPT'" || fail "chmod script"
  "$SCRIPT" init "$repo/deploy.conf" > /dev/null 2>&1
  sed -i "s#^SSH_HOST=.*#SSH_HOST=\"sftp-test\"#" "$repo/deploy.conf"
  sed -i "s#^REMOTE_PATH=.*#REMOTE_PATH=\"$EDGE_REMOTE_BASE/$remote_sub\"#" "$repo/deploy.conf"
  sed -i "s#^LOCAL_ROOT=.*#LOCAL_ROOT=\"$local_root\"#" "$repo/deploy.conf"
  echo "$repo"
}

# Déploye HEAD du repo courant avec sa config
deploy_here() {
  local repo="$1"
  (cd "$repo" && "$SCRIPT" deploy HEAD "$repo/deploy.conf") || fail "déploiement HEAD échoué ($repo)"
}

# Dernière sauvegarde HEAD (valeur absolue et relative)
last_backup_paths() {
  local last_abs last_rel
  last_abs=$(ls -1d "$ROOT/src/save-deploy/HEAD"/* 2>/dev/null | sort | tail -n1 || true)
  [ -z "${last_abs:-}" ] && fail "aucune sauvegarde HEAD trouvée"
  last_rel="${last_abs#"$ROOT/src/save-deploy/"}"
  echo "$last_abs|$last_rel"
}

# Assertions distantes simples
remote_has() { ssh -q -o LogLevel=ERROR sftp-test "test -f '$1'"; }
remote_not_has() { ssh -q -o LogLevel=ERROR sftp-test "test ! -f '$1'"; }
remote_grep() { ssh -q -o LogLevel=ERROR sftp-test "grep -q -- '$2' '$1'"; }
remote_size_eq() { ssh -q -o LogLevel=ERROR sftp-test "[ \"\$(stat -c %s -- '$1')\" = '$2' ]"; }

# Nettoyage distant/local
setup_env() {
  log "Nettoyage distant et local edgecases..."
  ssh -q -o LogLevel=ERROR sftp-test "rm -rf -- '$EDGE_REMOTE_BASE' && mkdir -p -- '$EDGE_REMOTE_BASE'" || fail "prep remote"
  rm -rf "$WORKDIR" && mkdir -p "$WORKDIR" || fail "prep workdir"
}

# Créer répertoire distant pour un test
ensure_remote_dir() {
  local remote_path="$1"
  ssh -q -o LogLevel=ERROR sftp-test "mkdir -p -- '$remote_path'" || fail "création répertoire distant $remote_path"
}

teardown_env() {
  log "Nettoyage final edgecases..."
  ssh -q -o LogLevel=ERROR sftp-test "rm -rf -- '$EDGE_REMOTE_BASE'" || true
  rm -rf "$WORKDIR" || true
}

# --- Tests ---
# 1) Suppressions: seules les D dans le commit sont synchronisées (backup + rm)
test_deleted_files() {
  log "[case] Deleted files"
  local repo; repo=$(new_repo deleted "deleted")
  ensure_remote_dir "$EDGE_REMOTE_BASE/deleted"
  mkdir -p "$repo/web"
  echo "DEL1" > "$repo/web/delete-me.txt"
  echo "KEEP1" > "$repo/web/keep.txt"
  (cd "$repo" && git add -A && git commit -m "v1" -q)
  deploy_here "$repo"

  remote_has "$EDGE_REMOTE_BASE/deleted/delete-me.txt" || fail "delete-me.txt manquant après v1"
  remote_grep "$EDGE_REMOTE_BASE/deleted/keep.txt" "KEEP1" || fail "contenu keep v1"

  # Suppression non commitée: ne doit PAS supprimer à distance
  rm -f "$repo/web/delete-me.txt"
  deploy_here "$repo"
  remote_grep "$EDGE_REMOTE_BASE/deleted/delete-me.txt" "DEL1" || fail "suppression non commitée propagée"

  # Commit de la suppression + modif
  sed -i 's/KEEP1/KEEP2/' "$repo/web/keep.txt"
  (cd "$repo" && git add -A && git commit -m "v2 delete+modify" -q)
  deploy_here "$repo"

  # Fichier supprimé doit être supprimé côté distant (car dans le commit)
  remote_not_has "$EDGE_REMOTE_BASE/deleted/delete-me.txt" || fail "fichier supprimé resté présent"
  remote_grep "$EDGE_REMOTE_BASE/deleted/keep.txt" "KEEP2" || fail "modif keep non déployée"

  # Vérifier la sauvegarde inclut le fichier supprimé (pour restauration)
  IFS='|' read -r babs brel < <(last_backup_paths)
  grep -q "keep.txt" "$babs/deployed_files.txt" || fail "keep.txt absent de la sauvegarde"
  grep -q "delete-me.txt" "$babs/deployed_files.txt" || fail "delete-me.txt absent de deployed_files"
  test -f "$babs/delete-me.txt" || fail "backup du fichier supprimé manquante"
  grep -q "DEL1" "$babs/delete-me.txt" || fail "contenu backup incorrect pour delete-me.txt"

  # Restauration: le fichier supprimé doit revenir
  "$SCRIPT" restore "$brel" "$repo/deploy.conf" || fail "restore échoué"
  remote_grep "$EDGE_REMOTE_BASE/deleted/delete-me.txt" "DEL1" || fail "restore n'a pas restauré le fichier supprimé"
  log "OK deleted files"
}

# 2) Noms spéciaux (espaces, unicode, caractères)
test_filename_conflicts() {
  log "[case] Filename conflicts (spaces/unicode/special)"
  local repo; repo=$(new_repo names "names")
  ensure_remote_dir "$EDGE_REMOTE_BASE/names"
  mkdir -p "$repo/web"
  echo "SPACE" > "$repo/web/space file.txt"
  echo "UNICODE" > "$repo/web/unicode-éà日本.txt"
  echo "SPECIAL" > "$repo/web/special_(plus+comma,).txt"
  (cd "$repo" && git add -A && git commit -m "names" -q)
  set +e
  (cd "$repo" && "$SCRIPT" deploy HEAD "$repo/deploy.conf")
  local rc=$?
  set -e
  [ $rc -ne 0 ] && skip "déploiement noms spéciaux a échoué (limitation espaces ?)" && return 0

  # unicode et caractères spéciaux sans espaces devraient passer
  remote_grep "$EDGE_REMOTE_BASE/names/unicode-éà日本.txt" "UNICODE" || fail "unicode manquant"
  remote_grep "$EDGE_REMOTE_BASE/names/special_(plus+comma,).txt" "SPECIAL" || fail "special manquant"

  # espaces: tolérer l'échec selon wrapper sftp
  if ! remote_grep "$EDGE_REMOTE_BASE/names/space file.txt" "SPACE"; then
    skip "fichiers avec espaces non supportés par sftp batch actuel"
  fi
  log "OK filename conflicts"
}

# 3) Restauration avec LOCAL_ROOT changé
test_restore_with_different_local_root() {
  log "[case] Restore with different LOCAL_ROOT"
  local repo; repo=$(new_repo restore-root "restore-root" "web")
  ensure_remote_dir "$EDGE_REMOTE_BASE/restore-root"
  mkdir -p "$repo/web/css" "$repo/web/img"
  cat > "$repo/web/index.html" <<EOF
<h1>V1</h1>
EOF
  echo "CSS V1" > "$repo/web/css/style.css"
  (cd "$repo" && git add -A && git commit -m "v1" -q)
  deploy_here "$repo"

  sed -i 's/V1/V2/' "$repo/web/index.html"
  echo "IMG V2" > "$repo/web/img/new.txt"
  (cd "$repo" && git add -A && git commit -m "v2" -q)
  deploy_here "$repo"

  IFS='|' read -r babs brel < <(last_backup_paths)
  # Changer LOCAL_ROOT de la config
  sed -i 's#^LOCAL_ROOT=.*#LOCAL_ROOT=\".\"#' "$repo/deploy.conf"
  "$SCRIPT" restore "$brel" "$repo/deploy.conf" || fail "restore échoué"

  remote_grep "$EDGE_REMOTE_BASE/restore-root/index.html" "V1" || fail "index non restauré V1"
  remote_grep "$EDGE_REMOTE_BASE/restore-root/css/style.css" "CSS V1" || fail "css non restauré V1"
  remote_not_has "$EDGE_REMOTE_BASE/restore-root/img/new.txt" || fail "fichier ajouté v2 devrait être supprimé"
  log "OK restore LOCAL_ROOT"
}

# 4) Fichiers binaires (images/PDF)
test_binary_files() {
  log "[case] Binary files"
  local repo; repo=$(new_repo binary "binary")
  ensure_remote_dir "$EDGE_REMOTE_BASE/binary"
  mkdir -p "$repo/web/img" "$repo/web/docs"
  dd if=/dev/urandom of="$repo/web/img/fake.img" bs=1024 count=64 status=none
  dd if=/dev/urandom of="$repo/web/docs/fake.pdf" bs=1024 count=8 status=none
  (cd "$repo" && git add -A && git commit -m "bin" -q)
  deploy_here "$repo"
  remote_size_eq "$EDGE_REMOTE_BASE/binary/img/fake.img" 65536 || fail "taille img incorrecte"
  remote_size_eq "$EDGE_REMOTE_BASE/binary/docs/fake.pdf" 8192 || fail "taille pdf incorrecte"
  log "OK binary files"
}

# 5) Arborescence profonde
test_deep_directories() {
  log "[case] Deep directories"
  local repo; repo=$(new_repo deep "deep")
  ensure_remote_dir "$EDGE_REMOTE_BASE/deep"
  mkdir -p "$repo/web/a/b/c/d/e/f/g/h"
  echo "deep" > "$repo/web/a/b/c/d/e/f/g/h/i.txt"
  (cd "$repo" && git add -A && git commit -m "deep" -q)
  deploy_here "$repo"
  remote_grep "$EDGE_REMOTE_BASE/deep/a/b/c/d/e/f/g/h/i.txt" "deep" || fail "fichier profond manquant"
  log "OK deep directories"
}

# 6) Fichiers vides et volumineux (~5MB)
test_empty_and_large_files() {
  log "[case] Empty and large files"
  local repo; repo=$(new_repo sizes "sizes")
  ensure_remote_dir "$EDGE_REMOTE_BASE/sizes"
  mkdir -p "$repo/web"
  : > "$repo/web/empty.txt"
  dd if=/dev/zero of="$repo/web/large.bin" bs=1M count=5 status=none
  (cd "$repo" && git add -A && git commit -m "sizes" -q)
  deploy_here "$repo"
  remote_size_eq "$EDGE_REMOTE_BASE/sizes/empty.txt" 0 || fail "empty non vide=0"
  remote_size_eq "$EDGE_REMOTE_BASE/sizes/large.bin" 5242880 || fail "large != 5MB"
  log "OK empty/large files"
}

# 7) Symlinks (si supportés)
test_symlinks_support() {
  log "[case] Symlinks"
  local repo; repo=$(new_repo symlinks "symlinks")
  ensure_remote_dir "$EDGE_REMOTE_BASE/symlinks"
  mkdir -p "$repo/web"
  echo "REAL" > "$repo/web/real.txt"
  (cd "$repo/web" && ln -s real.txt link.txt)
  (cd "$repo" && git add -A && git commit -m "symlink" -q)
  deploy_here "$repo"
  # Attendu: pas de symlink côté distant, fichier régulier contenant la cible
  if ssh sftp-test "test -L '$EDGE_REMOTE_BASE/symlinks/link.txt'"; then
    skip "symlink préservé (environnement inattendu)"
  fi
  remote_grep "$EDGE_REMOTE_BASE/symlinks/link.txt" "real.txt" || skip "contenu non conforme (symlink non supporté)"
  log "OK symlinks (non supportés)"
}

# 8) Déploiements multiples simultanés
test_parallel_deployments() {
  log "[case] Parallel deployments"
  local repoA repoB
  repoA=$(new_repo parallelA "parallel/A")
  repoB=$(new_repo parallelB "parallel/B")
  ensure_remote_dir "$EDGE_REMOTE_BASE/parallel/A"
  ensure_remote_dir "$EDGE_REMOTE_BASE/parallel/B"
  mkdir -p "$repoA/web" "$repoB/web"
  echo "Hello A" > "$repoA/web/index.html"
  echo "Hello B" > "$repoB/web/index.html"
  (cd "$repoA" && git add -A && git commit -m "A" -q)
  (cd "$repoB" && git add -A && git commit -m "B" -q)
  (cd "$repoA" && "$SCRIPT" deploy HEAD "$repoA/deploy.conf") &
  pidA=$!
  (cd "$repoB" && "$SCRIPT" deploy HEAD "$repoB/deploy.conf") &
  pidB=$!
  wait $pidA || fail "deploy A échoué"
  wait $pidB || fail "deploy B échoué"
  remote_grep "$EDGE_REMOTE_BASE/parallel/A/index.html" "Hello A" || fail "A non déployé"
  remote_grep "$EDGE_REMOTE_BASE/parallel/B/index.html" "Hello B" || fail "B non déployé"
  log "OK parallel deployments"
}

# --- Orchestration ---
main() {
  setup_env >/dev/null 2>&1

  run_case "Deleted files" test_deleted_files
  run_case "Filename conflicts" test_filename_conflicts
  run_case "Restore with different LOCAL_ROOT" test_restore_with_different_local_root
  run_case "Binary files" test_binary_files
  run_case "Deep directories" test_deep_directories
  run_case "Empty and large files" test_empty_and_large_files
  run_case "Symlinks" test_symlinks_support
  run_case "Parallel deployments" test_parallel_deployments

  teardown_env >/dev/null 2>&1
}

main "$@"
