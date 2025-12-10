#!/usr/bin/env bash
# Tests unitaires pour les fonctions utilitaires de git-sftp-deploy
# - Peut être exécuté localement (sans Docker) ou dans le conteneur
# - Teste les fonctions pures sans dépendances réseau/git

set -euo pipefail

# --- Configuration ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
MAIN_SCRIPT="$ROOT_DIR/src/git-sftp-deploy.sh"

# --- Logging ---
log() { echo -e "\033[0;34m[unit]\033[0m $*"; }
fail() { echo -e "\033[0;31m[FAIL]\033[0m $*" >&2; exit 1; }
pass() { echo -e "\033[0;32m[PASS]\033[0m $*"; }

# --- Extraction des fonctions à tester ---
# On source uniquement les fonctions utilitaires sans exécuter le script
extract_functions() {
    # Extraire collect_remote_directories du script principal
    sed -n '/^collect_remote_directories()/,/^}/p' "$MAIN_SCRIPT"
}

# Charger les fonctions dans le contexte courant
eval "$(extract_functions)"

# --- Tests ---

# Test 1: collect_remote_directories avec entrée normale (vraies newlines)
test_collect_dirs_normal_input() {
    log "Test: collect_remote_directories avec entrée normale"

    local input="views/sites/strasbourg/categorie.twig
web/css/sites/strasbourg/style.css
web/js/app.js
index.html"

    local result
    result=$(collect_remote_directories "$input")

    # Vérifier que les répertoires sont présents
    echo "$result" | grep -Fxq "views" || fail "Manque: views"
    echo "$result" | grep -Fxq "views/sites" || fail "Manque: views/sites"
    echo "$result" | grep -Fxq "views/sites/strasbourg" || fail "Manque: views/sites/strasbourg"
    echo "$result" | grep -Fxq "web" || fail "Manque: web"
    echo "$result" | grep -Fxq "web/css" || fail "Manque: web/css"
    echo "$result" | grep -Fxq "web/css/sites" || fail "Manque: web/css/sites"
    echo "$result" | grep -Fxq "web/css/sites/strasbourg" || fail "Manque: web/css/sites/strasbourg"
    echo "$result" | grep -Fxq "web/js" || fail "Manque: web/js"

    # Vérifier qu'aucun fichier n'est dans la liste
    echo "$result" | grep -q "\.twig$" && fail "Fichier .twig présent dans les répertoires"
    echo "$result" | grep -q "\.css$" && fail "Fichier .css présent dans les répertoires"
    echo "$result" | grep -q "\.js$" && fail "Fichier .js présent dans les répertoires"
    echo "$result" | grep -q "\.html$" && fail "Fichier .html présent dans les répertoires"

    pass "collect_remote_directories avec entrée normale"
}

# Test 2: REGRESSION - Vérifier que printf '%b' corrige le bug des newlines littérales
# Ce test vérifie que le pattern utilisé dans restore_backup (après correction) fonctionne
test_collect_dirs_literal_newline_bug() {
    log "Test: REGRESSION - Correction du bug newlines littérales"

    # Simuler la construction de restore_files comme dans restore_backup
    # Construit avec \n littéral (pattern du code)
    local restore_files=""
    restore_files+="views/sites/stay_in_strasbourg/categorie.twig\n"
    restore_files+="web/css/sites/stay_in_strasbourg/components/_categorie.scss\n"
    restore_files+="web/css/sites/stay_in_strasbourg/frontyxo.min.css\n"

    # CORRECTION: avec printf '%b' pour interpréter \n (comme dans le code corrigé)
    local result
    result=$(collect_remote_directories "$(printf '%b' "$restore_files")")

    # Vérifier que les vrais répertoires sont présents
    echo "$result" | grep -Fxq "views" || fail "Manque: views"
    echo "$result" | grep -Fxq "views/sites" || fail "Manque: views/sites"
    echo "$result" | grep -Fxq "views/sites/stay_in_strasbourg" || fail "Manque: views/sites/stay_in_strasbourg"
    echo "$result" | grep -Fxq "web/css/sites/stay_in_strasbourg/components" || fail "Manque: web/css/.../components"

    # CRUCIAL: vérifier qu'aucun fichier n'apparaît comme répertoire
    # C'est le bug qui était présent avant la correction
    echo "$result" | grep -q "\.twig" && fail "BUG: fichier .twig présent dans les répertoires"
    echo "$result" | grep -q "\.scss" && fail "BUG: fichier .scss présent dans les répertoires"
    echo "$result" | grep -q "\.css" && fail "BUG: fichier .css présent dans les répertoires"

    pass "REGRESSION - Correction newlines littérales OK"
}

# Test 3: collect_remote_directories avec fichiers à la racine (pas de sous-dossier)
test_collect_dirs_root_files() {
    log "Test: collect_remote_directories avec fichiers à la racine"

    local input="index.html
style.css
app.js"

    local result
    result=$(collect_remote_directories "$input")

    # Les fichiers à la racine ne doivent pas générer de répertoires
    [ -z "$result" ] || fail "Des répertoires ont été générés pour des fichiers racine: '$result'"

    pass "collect_remote_directories avec fichiers à la racine"
}

# Test 4: collect_remote_directories déduplique les répertoires
test_collect_dirs_deduplication() {
    log "Test: collect_remote_directories déduplique les répertoires"

    local input="web/css/a.css
web/css/b.css
web/css/c.css
web/js/a.js
web/js/b.js"

    local result
    result=$(collect_remote_directories "$input")

    # Compter les occurrences de chaque répertoire
    local count_web count_css count_js
    count_web=$(echo "$result" | grep -Fxc "web" || echo 0)
    count_css=$(echo "$result" | grep -Fxc "web/css" || echo 0)
    count_js=$(echo "$result" | grep -Fxc "web/js" || echo 0)

    [ "$count_web" -eq 1 ] || fail "web apparaît $count_web fois (attendu: 1)"
    [ "$count_css" -eq 1 ] || fail "web/css apparaît $count_css fois (attendu: 1)"
    [ "$count_js" -eq 1 ] || fail "web/js apparaît $count_js fois (attendu: 1)"

    pass "collect_remote_directories déduplique les répertoires"
}

# Test 5: collect_remote_directories avec arborescence profonde
test_collect_dirs_deep_tree() {
    log "Test: collect_remote_directories avec arborescence profonde"

    local input="a/b/c/d/e/f/g/h/file.txt"

    local result
    result=$(collect_remote_directories "$input")

    # Vérifier tous les niveaux intermédiaires
    echo "$result" | grep -Fxq "a" || fail "Manque: a"
    echo "$result" | grep -Fxq "a/b" || fail "Manque: a/b"
    echo "$result" | grep -Fxq "a/b/c" || fail "Manque: a/b/c"
    echo "$result" | grep -Fxq "a/b/c/d" || fail "Manque: a/b/c/d"
    echo "$result" | grep -Fxq "a/b/c/d/e" || fail "Manque: a/b/c/d/e"
    echo "$result" | grep -Fxq "a/b/c/d/e/f" || fail "Manque: a/b/c/d/e/f"
    echo "$result" | grep -Fxq "a/b/c/d/e/f/g" || fail "Manque: a/b/c/d/e/f/g"
    echo "$result" | grep -Fxq "a/b/c/d/e/f/g/h" || fail "Manque: a/b/c/d/e/f/g/h"

    # Le fichier ne doit pas être présent
    echo "$result" | grep -q "file\.txt" && fail "file.txt présent dans les répertoires"

    pass "collect_remote_directories avec arborescence profonde"
}

# Test 6: collect_remote_directories avec entrée vide
test_collect_dirs_empty_input() {
    log "Test: collect_remote_directories avec entrée vide"

    local result
    result=$(collect_remote_directories "")

    [ -z "$result" ] || fail "Résultat non vide pour entrée vide: '$result'"

    pass "collect_remote_directories avec entrée vide"
}

# Test 7: Cas réel du bug utilisateur (capture d'écran)
test_real_user_bug_case() {
    log "Test: Cas réel du bug utilisateur (restauration cms_front)"

    # Reproduire exactement le cas de l'utilisateur
    local restore_files=""
    restore_files+="views/sites/stay_in_strasbourg/categorie.twig\n"
    restore_files+="web/css/sites/stay_in_strasbourg/components/_categorie.scss\n"
    restore_files+="web/css/sites/stay_in_strasbourg/components/_footer.scss\n"
    restore_files+="web/css/sites/stay_in_strasbourg/frontyxo.min.css\n"
    restore_files+="web/css/sites/stay_in_strasbourg/frontyxo.min.css.map\n"

    # Avec la correction (printf '%b')
    local result
    result=$(collect_remote_directories "$(printf '%b' "$restore_files")")

    # Le chemin qui causait l'erreur NE DOIT PAS être présent
    if echo "$result" | grep -q "views/sites/stay_in_strasbourg/categorie\.twig"; then
        fail "BUG: 'views/sites/stay_in_strasbourg/categorie.twig' apparaît comme répertoire!"
    fi

    # Vérifier les vrais répertoires
    echo "$result" | grep -Fxq "views/sites/stay_in_strasbourg" || fail "Manque: views/sites/stay_in_strasbourg"
    echo "$result" | grep -Fxq "web/css/sites/stay_in_strasbourg/components" || fail "Manque: web/css/.../components"

    # Aucune extension de fichier ne doit apparaître
    echo "$result" | grep -qE "\.(twig|scss|css|map)$" && fail "Extension de fichier trouvée dans les répertoires"

    pass "Cas réel du bug utilisateur corrigé"
}

# --- Orchestration ---
main() {
    log "Démarrage des tests unitaires..."
    echo ""

    local failed=0
    local passed=0

    for test_fn in \
        test_collect_dirs_normal_input \
        test_collect_dirs_literal_newline_bug \
        test_collect_dirs_root_files \
        test_collect_dirs_deduplication \
        test_collect_dirs_deep_tree \
        test_collect_dirs_empty_input \
        test_real_user_bug_case
    do
        if $test_fn; then
            ((passed++)) || true
        else
            ((failed++)) || true
        fi
        echo ""
    done

    echo "========================================"
    if [ $failed -eq 0 ]; then
        echo -e "\033[0;32m✓ Tous les tests passent ($passed/$passed)\033[0m"
        exit 0
    else
        echo -e "\033[0;31m✗ $failed test(s) échoué(s) sur $((passed + failed))\033[0m"
        exit 1
    fi
}

main "$@"
